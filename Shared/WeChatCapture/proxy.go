package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"crypto/tls"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed capture.js
var captureScript string

// Debugging records public static asset locations only, never page HTML,
// request headers, account state, or query strings.
var publicScriptURL = regexp.MustCompile(`(?:https:)?//res\.wx\.qq\.com/[A-Za-z0-9_./-]+\.js`)

func interceptHost(host string) bool {
	return host == "channels.weixin.qq.com" || host == "res.wx.qq.com"
}

type captureProxy struct {
	listener      net.Listener
	server        *http.Server
	transport     *http.Transport
	ca            *localCA
	owner         *captureServer
	connections   sync.Map
	upstreamHTTPS string
}

func newCaptureProxy(ca *localCA, owner *captureServer) (*captureProxy, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.Proxy = nil
	tr.DisableCompression = true
	tr.ResponseHeaderTimeout = 30 * time.Second
	p := &captureProxy{listener: listener, transport: tr, ca: ca, owner: owner}
	p.server = &http.Server{Handler: p, ReadHeaderTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, ErrorLog: log.New(io.Discard, "", 0)}
	go func() { _ = p.server.Serve(listener) }()
	return p, nil
}
func (p *captureProxy) port() int { return p.listener.Addr().(*net.TCPAddr).Port }
func (p *captureProxy) close() {
	_ = p.server.Close()
	p.connections.Range(func(key, value any) bool { _ = key.(net.Conn).Close(); return true })
	p.transport.CloseIdleConnections()
}
func (p *captureProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		p.connect(w, r)
		return
	}
	if r.URL.Scheme != "http" || r.URL.Host == "" {
		http.Error(w, "proxy request required", 400)
		return
	}
	p.forward(w, r, false)
}

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(b []byte) (int, error) { return c.reader.Read(b) }

type oneListener struct {
	conn net.Conn
	used bool
	done chan struct{}
	once sync.Once
}

func (l *oneListener) Accept() (net.Conn, error) {
	if !l.used {
		l.used = true
		return &closeNotifyConn{Conn: l.conn, done: func() { l.once.Do(func() { close(l.done) }) }}, nil
	}
	<-l.done
	return nil, net.ErrClosed
}
func (l *oneListener) Close() error   { l.once.Do(func() { close(l.done) }); return l.conn.Close() }
func (l *oneListener) Addr() net.Addr { return l.conn.LocalAddr() }

type closeNotifyConn struct {
	net.Conn
	done func()
}

func (c *closeNotifyConn) Close() error { c.done(); return c.Conn.Close() }
func (p *captureProxy) connect(w http.ResponseWriter, r *http.Request) {
	host, port, e := net.SplitHostPort(r.Host)
	if e != nil || host == "" || port == "" {
		http.Error(w, "invalid target", 400)
		return
	}
	host = strings.ToLower(host)
	var upstream net.Conn
	targeted := port == "443" && interceptHost(host)
	if !targeted {
		upstream, e = dialThroughProxy(r.Context(), r.Host, p.upstreamHTTPS)
		if e != nil {
			http.Error(w, "upstream unavailable", 502)
			return
		}
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		if upstream != nil {
			upstream.Close()
		}
		http.Error(w, "connection unsupported", 500)
		return
	}
	conn, buffer, e := hijacker.Hijack()
	if e != nil {
		if upstream != nil {
			upstream.Close()
		}
		return
	}
	p.connections.Store(conn, true)
	_, _ = buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
	if buffer.Flush() != nil {
		conn.Close()
		p.connections.Delete(conn)
		return
	}
	wrapped := &bufferedConn{conn, buffer.Reader}
	if !targeted {
		defer conn.Close()
		defer upstream.Close()
		defer p.connections.Delete(conn)
		done := make(chan struct{}, 1)
		go func() { _, _ = io.Copy(upstream, wrapped); done <- struct{}{} }()
		_, _ = io.Copy(conn, upstream)
		_ = conn.Close()
		_ = upstream.Close()
		<-done
		return
	}
	leaf, e := p.ca.leaf(host)
	if e != nil {
		p.owner.record("certificate", "LEAF_FAILED", "无法生成本机页面证书，请关闭捕获后重试")
		conn.Close()
		p.connections.Delete(conn)
		return
	}
	secure := tls.Server(wrapped, &tls.Config{Certificates: []tls.Certificate{leaf}, MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"}})
	secure.SetDeadline(time.Now().Add(20 * time.Second))
	if e = secure.Handshake(); e != nil {
		conn.Close()
		p.connections.Delete(conn)
		p.owner.record("certificate", "TLS_REJECTED", "微信未接受本机捕获证书，请确认信任设置并重新打开视频")
		return
	}
	secure.SetDeadline(time.Time{})
	listener := &oneListener{conn: secure, done: make(chan struct{})}
	inner := &http.Server{ReadHeaderTimeout: 20 * time.Second, IdleTimeout: 45 * time.Second, ErrorLog: p.server.ErrorLog, Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestHost := strings.Split(request.Host, ":")[0]
		if requestHost != host {
			http.Error(writer, "host mismatch", 400)
			return
		}
		request.URL.Scheme = "https"
		request.URL.Host = host
		if host == "channels.weixin.qq.com" && strings.HasPrefix(request.URL.Path, "/__bilifetch_capture/") {
			p.owner.captureEvent(writer, request, strings.TrimPrefix(request.URL.Path, "/__bilifetch_capture/"))
			return
		}
		p.forward(writer, request, true)
	})}
	_ = inner.Serve(listener)
	_ = listener.Close()
	p.connections.Delete(conn)
}

func stripHopHeaders(header http.Header) {
	for _, name := range []string{"Connection", "Proxy-Connection", "Proxy-Authorization", "Keep-Alive", "TE", "Trailer", "Transfer-Encoding", "Upgrade"} {
		header.Del(name)
	}
}
func (p *captureProxy) forward(w http.ResponseWriter, r *http.Request, targeted bool) {
	request := r.Clone(r.Context())
	request.RequestURI = ""
	request.Header = r.Header.Clone()
	stripHopHeaders(request.Header)
	eligible := targeted && (r.URL.Hostname() == "channels.weixin.qq.com" || strings.Contains(r.URL.Path, "/finder/"))
	if eligible {
		request.Header.Set("Accept-Encoding", "identity")
		request.Header.Del("If-None-Match")
		request.Header.Del("If-Modified-Since")
	}
	response, err := p.transport.RoundTrip(request)
	if err != nil {
		http.Error(w, "upstream connection failed", 502)
		return
	}
	defer response.Body.Close()
	header := response.Header.Clone()
	stripHopHeaders(header)
	body := io.Reader(response.Body)
	contentType := strings.ToLower(header.Get("Content-Type"))
	isHTML := r.URL.Hostname() == "channels.weixin.qq.com" && strings.Contains(contentType, "text/html")
	isJS := r.URL.Hostname() == "res.wx.qq.com" && strings.Contains(r.URL.Path, "/finder/") && (strings.Contains(contentType, "javascript") || strings.HasSuffix(r.URL.Path, ".js"))
	if eligible && response.StatusCode == 200 && (isHTML || isJS) {
		raw, readErr := io.ReadAll(io.LimitReader(response.Body, 16*1024*1024+1))
		if readErr != nil || len(raw) > 16*1024*1024 {
			http.Error(w, "page response too large", 502)
			return
		}
		decoded := raw
		if header.Get("Content-Encoding") == "gzip" {
			if reader, e := gzip.NewReader(bytes.NewReader(raw)); e == nil {
				decoded, readErr = io.ReadAll(io.LimitReader(reader, 32*1024*1024+1))
				reader.Close()
			}
		} else if enc := header.Get("Content-Encoding"); enc != "" && enc != "identity" {
			decoded = nil
		}
		changed := false
		if decoded != nil && readErr == nil && len(decoded) <= 32*1024*1024 {
			content := string(decoded)
			if isHTML {
				if _, e := os.Stat(filepath.Join(p.owner.directory, "diagnostic-assets.enabled")); e == nil {
					_ = writePrivateJSON(filepath.Join(p.owner.directory, "public-assets.json"), publicScriptURL.FindAllString(content, 100))
				}
				endpoint, _ := json.Marshal("https://channels.weixin.qq.com/__bilifetch_capture/" + p.owner.captureToken)
				script := strings.Replace(captureScript, "__BILIFETCH_ENDPOINT__", string(endpoint), 1)
				if at := strings.Index(strings.ToLower(content), "<head>"); at >= 0 {
					content = content[:at+6] + "<script>" + script + "</script>" + content[at+6:]
					changed = true
				}
			} else {
				// Preserve platform JavaScript byte for byte. Rewriting an
				// object-property pattern also rewrites destructuring bindings.
				p.owner.mu.Lock()
				p.owner.scriptCount++
				p.owner.mu.Unlock()
				if _, e := os.Stat(filepath.Join(p.owner.directory, "diagnostic-assets.enabled")); e == nil {
					dir := filepath.Join(p.owner.directory, "DiagnosticAssets")
					_ = os.MkdirAll(dir, 0700)
					identity := fmt.Sprintf("%x", sha256.Sum256([]byte(r.URL.Path)))[:16]
					_ = os.WriteFile(filepath.Join(dir, identity+".js"), decoded, 0600)
					_ = os.WriteFile(filepath.Join(dir, identity+".url.txt"), []byte("https://res.wx.qq.com"+r.URL.Path), 0600)
				}
			}
			if changed {
				raw = []byte(content)
				header.Del("Content-Encoding")
				header.Del("ETag")
				header.Del("Content-Security-Policy")
				header.Del("Content-Security-Policy-Report-Only")
				header.Set("Cache-Control", "no-store")
			}
		}
		header.Set("Content-Length", strconv.Itoa(len(raw)))
		body = bytes.NewReader(raw)
	}
	for name, values := range header {
		w.Header()[name] = values
	}
	w.WriteHeader(response.StatusCode)
	_, _ = io.Copy(w, body)
}
