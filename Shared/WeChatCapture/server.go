package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type diagnostic struct {
	Time    string `json:"time"`
	Stage   string `json:"stage"`
	Code    string `json:"code"`
	Message string `json:"message"`
}
type captureServer struct {
	mu                     sync.Mutex
	directory, token, base string
	captureToken           string
	store                  *captureStore
	proxy                  *captureProxy
	proxyState             *systemProxyState
	ca                     *localCA
	events                 []diagnostic
	pageCount, scriptCount int
	metrics                map[string]int
	lastMessage            string
	client                 *http.Client
}

func randomToken() string {
	data := make([]byte, 32)
	if _, e := rand.Read(data); e != nil {
		panic(e)
	}
	return hex.EncodeToString(data)
}
func newServer(directory string) (*captureServer, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	if err := recoverSystemProxy(directory); err != nil {
		return nil, fmt.Errorf("上次捕获的网络设置尚未恢复：%w", err)
	}
	store, err := openStore(filepath.Join(directory, "Captures"))
	if err != nil {
		return nil, err
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	if state, e := inspectSystemProxy(); e == nil {
		transport.Proxy = state.proxyFor
	}
	transport.ResponseHeaderTimeout = 30 * time.Second
	client := &http.Client{Transport: transport, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) > 5 {
			return errors.New("媒体跳转次数过多")
		}
		_, e := mediaURL(req.URL.String())
		return e
	}}
	return &captureServer{directory: directory, token: randomToken(), captureToken: randomToken(), store: store, client: client, lastMessage: "尚未开启捕获"}, nil
}
func (s *captureServer) record(stage, code, message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, diagnostic{time.Now().Format(time.RFC3339), stage, code, message})
	if len(s.events) > 100 {
		s.events = s.events[len(s.events)-100:]
	}
	s.lastMessage = message
	s.saveDiagnosticsLocked()
}
func (s *captureServer) saveDiagnosticsLocked() {
	_ = writePrivateJSON(filepath.Join(s.directory, "diagnostics.json"), map[string]any{
		"adapterVersion": adapterVersion, "active": s.proxy != nil, "pages": s.pageCount, "scripts": s.scriptCount,
		"capturedCount": len(s.store.previews()), "metrics": s.metrics, "events": s.events,
	})
}
func (s *captureServer) state() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return map[string]any{"active": s.proxy != nil, "message": s.lastMessage, "pages": s.pageCount, "scripts": s.scriptCount, "adapterVersion": adapterVersion, "captures": s.store.previews()}
}
func sendJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func (s *captureServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != "" {
		sendJSON(w, 403, map[string]string{"error": "不允许网页访问本机控制接口"})
		return
	}
	provided := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if subtle.ConstantTimeCompare([]byte(provided), []byte(s.token)) != 1 {
		sendJSON(w, 401, map[string]string{"error": "本机连接已失效，请重新打开视频号面板"})
		return
	}
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/state":
		sendJSON(w, 200, s.state())
	case r.Method == "POST" && r.URL.Path == "/api/start":
		var consent struct {
			Consent bool `json:"consent"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&consent)
		if !consent.Consent {
			sendJSON(w, 400, map[string]string{"error": "需要先确认本机证书和临时代理设置"})
			return
		}
		if err := s.startCapture(); err != nil {
			s.record("setup", "START_FAILED", err.Error())
			sendJSON(w, 409, map[string]string{"error": err.Error()})
			return
		}
		s.record("capture", "STARTED", "捕获已开启，请在电脑微信重新打开并播放目标视频")
		sendJSON(w, 200, s.state())
	case r.Method == "POST" && r.URL.Path == "/api/stop":
		if e := s.stopCapture(); e != nil {
			sendJSON(w, 500, map[string]string{"error": e.Error()})
			return
		}
		sendJSON(w, 200, s.state())
	case r.Method == "POST" && r.URL.Path == "/api/clear":
		if e := s.store.clear(); e != nil {
			sendJSON(w, 500, map[string]string{"error": "清理捕获记录失败"})
			return
		}
		sendJSON(w, 200, s.state())
	case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/api/manifest/"):
		id := strings.TrimPrefix(r.URL.Path, "/api/manifest/")
		if !validID(id) {
			sendJSON(w, 400, map[string]string{"error": "作品标识无效"})
			return
		}
		path, e := s.store.manifest(id, s.base, s.token)
		if e != nil {
			sendJSON(w, 404, map[string]string{"error": e.Error()})
			return
		}
		sendJSON(w, 200, map[string]string{"path": path})
	case r.Method == "GET" && r.URL.Path == "/api/diagnostics":
		s.mu.Lock()
		events := append([]diagnostic{}, s.events...)
		s.mu.Unlock()
		sendJSON(w, 200, map[string]any{"component": "BiliFetch WeChat Capture", "adapterVersion": adapterVersion, "state": s.diagnosticState(), "events": events})
	case (r.Method == "GET" || r.Method == "HEAD") && strings.HasPrefix(r.URL.Path, "/media/"):
		s.serveMedia(w, r)
	default:
		sendJSON(w, 404, map[string]string{"error": "未找到本机接口"})
	}
}
func (s *captureServer) diagnosticState() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return map[string]any{"active": s.proxy != nil, "pages": s.pageCount, "scripts": s.scriptCount, "capturedCount": len(s.store.previews()), "metrics": s.metrics}
}
func (s *captureServer) startCapture() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.proxy != nil {
		return nil
	}
	// Inspect conflicts before changing trust or proxy settings.
	state, err := inspectSystemProxy()
	if err != nil {
		return err
	}
	ca, err := loadCA(s.directory)
	if err != nil {
		return err
	}
	if err = trustCertificate(ca.path); err != nil {
		return err
	}
	proxy, err := newCaptureProxy(ca, s)
	if err != nil {
		return err
	}
	proxy.transport.Proxy = state.proxyFor
	proxy.upstreamHTTPS = state.UpstreamHTTPS
	if err = state.enable(s.directory, proxy.port()); err != nil {
		if restoreError := state.restore(s.directory); restoreError != nil {
			s.ca, s.proxy, s.proxyState = ca, proxy, state
			return errors.New("捕获设置未完成，部分网络设置尚未恢复；请点击关闭捕获重试")
		}
		proxy.close()
		return err
	}
	s.ca = ca
	s.proxy = proxy
	s.proxyState = state
	transport := s.client.Transport.(*http.Transport).Clone()
	transport.Proxy = state.proxyFor
	next := *s.client
	next.Transport = transport
	s.client = &next
	return nil
}
func (s *captureServer) stopCapture() error {
	s.mu.Lock()
	proxy, state := s.proxy, s.proxyState
	if proxy == nil {
		s.mu.Unlock()
		return nil
	}
	if err := state.restore(s.directory); err != nil {
		s.mu.Unlock()
		s.record("proxy", "RESTORE_FAILED", err.Error())
		return err
	}
	s.proxy = nil
	s.proxyState = nil
	s.mu.Unlock()
	proxy.close()
	s.record("capture", "STOPPED", "捕获已关闭，原网络设置已恢复；已捕获的视频仍可下载")
	return nil
}
func (s *captureServer) captureEvent(w http.ResponseWriter, r *http.Request, token string) {
	if r.Method != "POST" || subtle.ConstantTimeCompare([]byte(token), []byte(s.captureToken)) != 1 {
		http.Error(w, "not found", 404)
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" && origin != "https://channels.weixin.qq.com" {
		http.Error(w, "forbidden", 403)
		return
	}
	var event struct {
		Type    string         `json:"type"`
		Feed    capturedFeed   `json:"feed"`
		Reason  string         `json:"reason"`
		Metrics map[string]int `json:"metrics"`
	}
	if e := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024*1024)).Decode(&event); e != nil {
		http.Error(w, "invalid capture", 400)
		return
	}
	if event.Type == "page_ready" {
		s.mu.Lock()
		s.pageCount++
		s.mu.Unlock()
		s.record("capture", "PAGE_READY", "已连接视频号页面，等待视频播放")
		sendJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	if event.Type == "metrics" {
		metrics := map[string]int{}
		for _, name := range []string{"candidates", "videoElements", "visiblePlaying", "flowReferences", "msePlayers", "bridgeAvailable", "bridgeCalls", "bridgeResponses", "pageStoreReady"} {
			value := event.Metrics[name]
			if value >= 0 && value <= 1000 {
				metrics[name] = value
			}
		}
		s.mu.Lock()
		s.metrics = metrics
		s.saveDiagnosticsLocked()
		s.mu.Unlock()
		sendJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	if event.Type == "playback_unconfirmed" {
		message := "检测到播放，但无法确认作品身份；为避免收录预加载视频，本次已跳过。请重新打开作品或导出诊断。"
		if event.Reason == "multiple_players" {
			message = "多个画面同时处于播放状态，暂不捕获；请单独打开目标作品播放。"
		}
		s.record("playback", "IDENTITY_UNCONFIRMED", message)
		sendJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	if event.Type != "capture" {
		http.Error(w, "unsupported", 400)
		return
	}
	c, err := normalizeCapture(event.Feed)
	if err != nil {
		s.record("parse", "UNSUPPORTED_MEDIA", err.Error())
		sendJSON(w, 422, map[string]string{"error": err.Error()})
		return
	}
	if err = s.store.add(c); err != nil {
		s.record("storage", "WRITE_FAILED", "无法保存捕获结果")
		sendJSON(w, 500, map[string]string{"error": "无法保存捕获结果"})
		return
	}
	s.record("capture", "VIDEO_CAPTURED", "已捕获正在播放的视频，可以在列表中预览并选择下载")
	sendJSON(w, 200, map[string]bool{"ok": true})
}
func (s *captureServer) serveMedia(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/media/"), "/")
	if len(parts) != 2 {
		http.NotFound(w, r)
		return
	}
	c, ok := s.store.get(parts[0])
	index, e := strconv.Atoi(parts[1])
	if !ok || e != nil || index < 0 || index >= len(c.Formats) {
		http.NotFound(w, r)
		return
	}
	f := c.Formats[index]
	if _, e = mediaURL(f.URL); e != nil {
		http.Error(w, "invalid media", 400)
		return
	}
	upstream, e := http.NewRequestWithContext(r.Context(), r.Method, f.URL, nil)
	if e != nil {
		http.Error(w, "invalid media", 400)
		return
	}
	upstream.Header.Set("Accept-Encoding", "identity")
	upstream.Header.Set("Referer", "https://channels.weixin.qq.com/")
	upstream.Header.Set("User-Agent", "Mozilla/5.0")
	if value := r.Header.Get("Range"); value != "" {
		if strings.Contains(value, ",") || !strings.HasPrefix(value, "bytes=") {
			http.Error(w, "unsupported range", 416)
			return
		}
		upstream.Header.Set("Range", value)
	}
	s.mu.Lock()
	client := s.client
	s.mu.Unlock()
	response, e := client.Do(upstream)
	if e != nil {
		s.record("download", "CONNECT_FAILED", "媒体连接失败，请检查网络或重新播放以更新捕获")
		http.Error(w, "media connection failed", 502)
		return
	}
	defer response.Body.Close()
	if response.StatusCode != 200 && response.StatusCode != 206 {
		s.record("download", fmt.Sprintf("HTTP_%d", response.StatusCode), "媒体地址暂不可用或已过期，请在微信重新播放后更新捕获")
		http.Error(w, "media unavailable; replay the video to refresh the capture", response.StatusCode)
		return
	}
	if encoding := response.Header.Get("Content-Encoding"); encoding != "" && encoding != "identity" {
		http.Error(w, "unexpected media encoding", 502)
		return
	}
	offset := int64(0)
	if response.StatusCode == 206 {
		var end, total int64
		if n, _ := fmt.Sscanf(response.Header.Get("Content-Range"), "bytes %d-%d/%d", &offset, &end, &total); n != 3 || offset < 0 || end < offset || total <= end {
			http.Error(w, "invalid content range", 502)
			return
		}
		if requested := r.Header.Get("Range"); requested != "" {
			first := strings.Split(strings.TrimPrefix(requested, "bytes="), "-")[0]
			if first != "" {
				start, parseError := strconv.ParseInt(first, 10, 64)
				if parseError != nil || start != offset {
					http.Error(w, "mismatched content range", 502)
					return
				}
			}
		}
	}
	var stream []byte
	if f.EncryptedLength > 0 {
		if f.EncryptedLength > 4*1024*1024 {
			http.Error(w, "invalid encrypted length", 422)
			return
		}
		key, err := strconv.ParseUint(f.Key, 10, 64)
		if err != nil {
			http.Error(w, "invalid decode key", 422)
			return
		}
		stream = keyStream(key, f.EncryptedLength)
	}
	for _, name := range []string{"Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified"} {
		if v := response.Header.Get(name); v != "" {
			w.Header().Set(name, v)
		}
	}
	w.Header().Set("Content-Type", "video/mp4")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(response.StatusCode)
	if r.Method == "HEAD" {
		return
	}
	buffer := make([]byte, 64*1024)
	for {
		n, err := response.Body.Read(buffer)
		if n > 0 {
			xorAt(buffer[:n], stream, offset)
			if _, e = w.Write(buffer[:n]); e != nil {
				return
			}
			offset += int64(n)
		}
		if err != nil {
			if err != io.EOF && r.Context().Err() == nil {
				s.record("download", "STREAM_INTERRUPTED", "媒体传输中断，临时文件可用于续传")
			}
			return
		}
	}
}

func serve(directory string) error {
	s, err := newServer(directory)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	s.base = "http://" + listener.Addr().String()
	server := &http.Server{Handler: s, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}
	defer listener.Close()
	defer s.stopCapture()
	go func() {
		_, _ = io.Copy(io.Discard, os.Stdin)
		// Keep the forwarding proxy alive if restoration fails. Retry instead of
		// exiting with the user's system still pointing at a dead local port.
		for s.stopCapture() != nil {
			time.Sleep(5 * time.Second)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()
	_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"event": "ready", "baseURL": s.base, "token": s.token, "adapterVersion": adapterVersion})
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
