package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func sampleCapture(t *testing.T) capture {
	t.Helper()
	c, e := normalizeCapture(capturedFeed{ID: "sample-feed", Title: "当前作品", Author: "示例", Media: []capturedMedia{{
		URL: "https://finder.video.qq.com/sample.mp4?token=private-token&watermark=1", DecodeKey: "123456789", Width: 1920, Height: 1080, Duration: 3,
		Spec: []mediaSpec{{FileFormat: "hd", Width: 3840, Height: 2160}},
	}}})
	if e != nil {
		t.Fatal(e)
	}
	return c
}
func testServer(t *testing.T) *captureServer {
	t.Helper()
	s, e := newServer(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	return s
}
func apiRequest(s *captureServer, method, route, body, token, origin string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, route, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func TestAuthenticatedControlAndConsent(t *testing.T) {
	s := testServer(t)
	for _, c := range []struct {
		token, origin string
		want          int
	}{{"", "", 401}, {s.token, "https://example.com", 403}, {s.token, "", 200}} {
		if got := apiRequest(s, "GET", "/api/state", "", c.token, c.origin).Code; got != c.want {
			t.Fatalf("status %d want %d", got, c.want)
		}
	}
	if got := apiRequest(s, "POST", "/api/start", `{"consent":false}`, s.token, "").Code; got != 400 {
		t.Fatal(got)
	}
	if _, e := os.Stat(filepath.Join(s.directory, "ca.pem")); !os.IsNotExist(e) {
		t.Fatal("state/denied start must not create certificate")
	}
}
func TestCaptureStoreManifestAndDiagnostics(t *testing.T) {
	s := testServer(t)
	c := sampleCapture(t)
	if e := s.store.add(c); e != nil {
		t.Fatal(e)
	}
	s.base = "http://127.0.0.1:43210"
	path, e := s.store.manifest(c.ID, s.base, s.token)
	if e != nil {
		t.Fatal(e)
	}
	data, _ := os.ReadFile(path)
	if bytes.Contains(data, []byte("private-token")) || bytes.Contains(data, []byte(c.Formats[0].Key)) {
		t.Fatal("manifest leaked upstream secrets")
	}
	if !bytes.Contains(data, []byte(s.base+"/media/")) {
		t.Fatal("manifest missing local media URL")
	}
	for _, route := range []string{"/api/state", "/api/diagnostics"} {
		data := apiRequest(s, "GET", route, "", s.token, "").Body.Bytes()
		for _, secret := range []string{s.token, "private-token", "123456789", "decodeKey"} {
			if bytes.Contains(data, []byte(secret)) {
				t.Fatal("public state or diagnostics leaked secret")
			}
		}
	}
	reopened, e := openStore(s.store.directory)
	if e != nil || len(reopened.previews()) != 1 {
		t.Fatal("persistence failed")
	}
	if !strings.Contains(c.Formats[1].URL, "watermark=1") {
		t.Fatal("watermark parameter changed")
	}
	if e := s.store.clear(); e != nil {
		t.Fatal(e)
	}
	if len(s.store.previews()) != 0 {
		t.Fatal("clear failed")
	}
}
func TestRejectNonMediaAndInvalidKeys(t *testing.T) {
	for _, raw := range []string{"http://finder.video.qq.com/v", "https://finder.video.qq.com.evil.test/v", "https://127.0.0.1/v", "https://user:pass@finder.video.qq.com/v", "https://finder.video.qq.com:8000/v"} {
		if _, e := mediaURL(raw); e == nil {
			t.Fatal("accepted", raw)
		}
	}
	for _, key := range []string{"-1", "18446744073709551616", "not-a-number"} {
		if _, e := normalizeCapture(capturedFeed{ID: "x", Media: []capturedMedia{{URL: "https://finder.video.qq.com/v", DecodeKey: key}}}); e == nil {
			t.Fatal("accepted key", key)
		}
	}
	if _, e := normalizeCapture(capturedFeed{ID: "x", Media: []capturedMedia{{URL: "https://finder.video.qq.com/v"}, {URL: "https://finder.video.qq.com/b"}}}); e == nil {
		t.Fatal("ambiguous multiple media accepted")
	}
}

func TestDefaultCDNDoesNotClaimOriginalQuality(t *testing.T) {
	s := testServer(t)
	c := sampleCapture(t)
	if c.Formats[0].Width != 0 || c.Formats[0].Height != 0 || c.Formats[0].Size != 0 || !c.Formats[0].DefaultQuality {
		t.Fatal("default CDN URL mislabeled with uploaded-original metadata")
	}
	if c.Formats[1].Width != 3840 || c.Formats[1].DefaultQuality {
		t.Fatal("advertised variant lost its quality")
	}
	// Load an adapter-1 record to exercise the migration as well.
	c.Formats[0].DefaultQuality = false
	c.Formats[0].Width, c.Formats[0].Height, c.Formats[0].Size = 4096, 2160, 999999
	if err := s.store.add(c); err != nil {
		t.Fatal(err)
	}
	reopened, err := openStore(s.store.directory)
	if err != nil {
		t.Fatal(err)
	}
	p, err := reopened.manifest(c.ID, "http://127.0.0.1:43210", "local-token")
	if err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(p)
	var manifest struct {
		Formats []map[string]any `json:"formats"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	defaultFormat, best := manifest.Formats[0], manifest.Formats[1]
	if defaultFormat["preference"] != float64(-10) || defaultFormat["width"] != nil || defaultFormat["filesize"] != nil {
		t.Fatal("default quality still outranks advertised formats")
	}
	if best["width"] != float64(3840) {
		t.Fatal("advertised dimensions missing")
	}
}
func TestISAACOffsetBoundaries(t *testing.T) {
	original := bytes.Repeat([]byte("range-and-resume-fixture"), 10000)
	stream := keyStream(123456789, 131072)
	encrypted := append([]byte{}, original...)
	xorAt(encrypted, stream, 0)
	for _, offset := range []int{0, 1, 7, 8, 65530, 131060, 131072, 160000} {
		result := append([]byte{}, encrypted[offset:]...)
		xorAt(result, stream, int64(offset))
		if !bytes.Equal(result, original[offset:]) {
			t.Fatalf("incorrect decoding at offset %d", offset)
		}
	}
}

func TestISAACAgainstPublicDomainReference(t *testing.T) {
	cc, e := exec.LookPath("cc")
	if e != nil {
		t.Skip("C reference compiler unavailable")
	}
	binary := filepath.Join(t.TempDir(), "isaac64-reference")
	if output, e := exec.Command(cc, "testdata/isaac64-reference.c", "-o", binary).CombinedOutput(); e != nil {
		t.Fatal(e, string(output))
	}
	for _, seed := range []uint64{0, 1, 123456789, 18446744073709551615} {
		output, e := exec.Command(binary, fmt.Sprint(seed)).Output()
		if e != nil {
			t.Fatal(e)
		}
		want, e := hex.DecodeString(string(output))
		if e != nil {
			t.Fatal(e)
		}
		if !bytes.Equal(keyStream(seed, 2400), want) {
			t.Fatalf("reference mismatch for seed %d", seed)
		}
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func fixtureMediaClient(data []byte, observe func(*http.Request)) *http.Client {
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if observe != nil {
			observe(r)
		}
		w := httptest.NewRecorder()
		http.ServeContent(w, r, "fixture.mp4", time.Time{}, bytes.NewReader(data))
		return w.Result(), nil
	})}
}
func TestMediaRangeDecodingAndAuthorization(t *testing.T) {
	s := testServer(t)
	c := sampleCapture(t)
	c.Formats = c.Formats[:1]
	_ = s.store.add(c)
	plain := bytes.Repeat([]byte("verified-media-bytes"), 12000)
	encrypted := append([]byte{}, plain...)
	xorAt(encrypted, keyStream(123456789, 131072), 0)
	s.client = fixtureMediaClient(encrypted, func(r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			t.Error("local secret forwarded to CDN")
		}
	})
	for _, offset := range []int{0, 13, 131066, 131072, 180000} {
		r := httptest.NewRequest("GET", "/media/"+c.ID+"/0", nil)
		r.Header.Set("Authorization", "Bearer "+s.token)
		r.Header.Set("Range", fmt.Sprintf("bytes=%d-", offset))
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), plain[offset:]) {
			t.Fatalf("range failed at %d: %d", offset, w.Code)
		}
	}
	if got := apiRequest(s, "GET", "/media/"+c.ID+"/0", "", "", "").Code; got != 401 {
		t.Fatal(got)
	}
	s.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 206, Header: http.Header{"Content-Range": {"bytes 0-9/20"}}, Body: io.NopCloser(strings.NewReader("1234567890"))}, nil
	})}
	r := httptest.NewRequest("GET", "/media/"+c.ID+"/0", nil)
	r.Header.Set("Range", "bytes=10-")
	r.Header.Set("Authorization", "Bearer "+s.token)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != 502 {
		t.Fatal("accepted mismatched range")
	}
}
func TestCaptureEventValidation(t *testing.T) {
	s := testServer(t)
	w := httptest.NewRecorder()
	s.captureEvent(w, httptest.NewRequest("POST", "/", strings.NewReader(`{"type":"page_ready"}`)), "wrong")
	if w.Code != 404 {
		t.Fatal(w.Code)
	}
	w = httptest.NewRecorder()
	s.captureEvent(w, httptest.NewRequest("POST", "/", strings.NewReader(`{"type":"page_ready"}`)), s.captureToken)
	if len(s.store.previews()) != 0 {
		t.Fatal("page readiness captured a video")
	}
	f := capturedFeed{ID: "a", Media: []capturedMedia{{URL: "https://finder.video.qq.com/test.mp4"}}}
	body, _ := json.Marshal(map[string]any{"type": "capture", "feed": f})
	for i := 0; i < 2; i++ {
		w = httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/", bytes.NewReader(body))
		r.Header.Set("Origin", "https://channels.weixin.qq.com")
		s.captureEvent(w, r, s.captureToken)
		if w.Code != 200 {
			t.Fatal(w.Code)
		}
	}
	if len(s.store.previews()) != 1 {
		t.Fatal("capture not deduplicated")
	}
}
func TestPrivateCertificateAndTargetedTLS(t *testing.T) {
	s := testServer(t)
	ca, e := loadCA(s.directory)
	if e != nil {
		t.Fatal(e)
	}
	ca2, e := loadCA(s.directory)
	if e != nil || ca2.path != ca.path {
		t.Fatal("CA persistence failed")
	}
	if _, e := ca.leaf("example.com"); e == nil {
		t.Fatal("issued unrelated host certificate")
	}
	proxy, e := newCaptureProxy(ca, s)
	if e != nil {
		t.Fatal(e)
	}
	defer proxy.close()
	proxy.server.ErrorLog = log.New(os.Stderr, "capture-test: ", 0)
	scriptFixture := `const store={flowTab:{value:{feeds:[],currentFeedIndex:0}}};const {flowTab:ref}=store;const object={flowTab:ref};`
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, ".js") {
			w.Header().Set("Content-Type", "application/javascript")
			w.Write([]byte(scriptFixture))
			return
		}
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte("<html><head></head><body>fixture</body></html>"))
	}))
	defer upstream.Close()
	target, _ := url.Parse(upstream.URL)
	proxy.transport = upstream.Client().Transport.(*http.Transport).Clone()
	proxy.transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, target.Host)
	}
	// The fixture certificate is valid for example.com, not the intercepted domain.
	proxy.transport.TLSClientConfig.ServerName = "example.com"
	roots := x509.NewCertPool()
	pem, _ := os.ReadFile(ca.path)
	if !roots.AppendCertsFromPEM(pem) {
		t.Fatal("CA PEM invalid")
	}
	proxyURL, _ := url.Parse("http://" + proxy.listener.Addr().String())
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSClientConfig: &tls.Config{RootCAs: roots}}, Timeout: 5 * time.Second}
	response, e := client.Get("https://channels.weixin.qq.com/test")
	if e != nil {
		t.Fatal(e, s.events)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 200 || !bytes.Contains(body, []byte("__BiliFetchCapture")) {
		t.Fatalf("injection failed %d %s", response.StatusCode, body)
	}
	if bytes.Contains(body, []byte(s.token)) {
		t.Fatal("page sees local control credential")
	}
	response, e = client.Get("https://res.wx.qq.com/finder/player.js")
	if e != nil {
		t.Fatal(e)
	}
	body, _ = io.ReadAll(response.Body)
	response.Body.Close()
	if string(body) != scriptFixture {
		t.Fatal("platform JS including destructuring must remain unchanged")
	}
}
func TestSingleInstanceLock(t *testing.T) {
	dir := t.TempDir()
	unlock, e := acquireDataLock(dir)
	if e != nil {
		t.Fatal(e)
	}
	if second, e := acquireDataLock(dir); e == nil {
		second()
		t.Fatal("second helper acquired same data directory")
	}
	unlock()
	unlock, e = acquireDataLock(dir)
	if e != nil {
		t.Fatal(e)
	}
	unlock()
}
func TestYTDLPAria2ResumeIntegration(t *testing.T) {
	root, media := os.Getenv("BILIFETCH_TEST_ROOT"), os.Getenv("BILIFETCH_TEST_MEDIA")
	if root == "" || media == "" {
		t.Skip("requires existing authorized MP4 fixture and bundled macOS tools")
	}
	plain, e := os.ReadFile(media)
	if e != nil {
		t.Fatal(e)
	}
	encrypted := append([]byte{}, plain...)
	xorAt(encrypted, keyStream(123456789, 131072), 0)
	s := testServer(t)
	c := sampleCapture(t)
	c.Formats = c.Formats[:1]
	c.Formats[0].Size = int64(len(plain))
	_ = s.store.add(c)
	var ranges []string
	var mu sync.Mutex
	s.client = fixtureMediaClient(encrypted, func(r *http.Request) { mu.Lock(); ranges = append(ranges, r.Header.Get("Range")); mu.Unlock() })
	server := httptest.NewServer(s)
	defer server.Close()
	s.base = server.URL
	manifest, e := s.store.manifest(c.ID, s.base, s.token)
	if e != nil {
		t.Fatal(e)
	}
	for _, engine := range []string{"native", "aria2"} {
		t.Run(engine, func(t *testing.T) {
			dir := t.TempDir()
			out := filepath.Join(dir, "verified.mp4")
			if e := os.WriteFile(out+".part", plain[:12345], 0600); e != nil {
				t.Fatal(e)
			}
			args := []string{"--ignore-config", "--load-info-json", manifest, "--proxy", "", "--continue", "--no-part", "--output", out, "--format", "best", "--no-simulate", "--no-warnings"}
			// Use ordinary .part continuation exactly as the app does.
			args[6] = "--part"
			if engine == "aria2" {
				args = append(args, "--downloader", filepath.Join(root, "Vendor/Tools/aria2c"), "--downloader-args", "aria2c:--continue=true --all-proxy= --file-allocation=none")
			}
			// The bundled one-file yt-dlp needs about 24 seconds just to start on
			// a cold macOS host; keep the integration deadline above cold startup
			// plus media validation (it is not a product network timeout).
			ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, filepath.Join(root, "Vendor/Tools/yt-dlp"), args...)
			if output, e := command.CombinedOutput(); e != nil {
				t.Fatal(e, string(output))
			}
			got, e := os.ReadFile(out)
			if e != nil {
				t.Fatal(e)
			}
			a, b := sha256.Sum256(got), sha256.Sum256(plain)
			if a != b {
				t.Fatalf("file hash mismatch %s", hex.EncodeToString(a[:]))
			}
			if output, e := exec.Command(filepath.Join(root, "Vendor/Tools/ffprobe"), "-v", "error", "-show_entries", "stream=codec_type", "-of", "json", out).CombinedOutput(); e != nil || !bytes.Contains(output, []byte("video")) || !bytes.Contains(output, []byte("audio")) {
				t.Fatal("final media validation failed", e, string(output))
			}
		})
	}
	mu.Lock()
	defer mu.Unlock()
	found := false
	for _, r := range ranges {
		if strings.HasPrefix(r, "bytes=12345-") {
			found = true
		}
	}
	if !found {
		t.Fatal("did not exercise a nonzero resume range")
	}
}
