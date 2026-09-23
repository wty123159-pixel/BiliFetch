package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestExistingHTTPProxyIsUsedForTunnelAndRestored(t *testing.T) {
	echo, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer echo.Close()
	go func() {
		connection, e := echo.Accept()
		if e != nil {
			return
		}
		defer connection.Close()
		_, _ = io.Copy(connection, connection)
	}()
	var target string
	var mu sync.Mutex
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "CONNECT" {
			http.Error(w, "CONNECT required", 400)
			return
		}
		mu.Lock()
		target = r.Host
		mu.Unlock()
		upstream, e := net.Dial("tcp", echo.Addr().String())
		if e != nil {
			t.Error(e)
			return
		}
		connection, buffer, e := w.(http.Hijacker).Hijack()
		if e != nil {
			upstream.Close()
			t.Error(e)
			return
		}
		defer connection.Close()
		defer upstream.Close()
		buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		buffer.Flush()
		go func() { _, _ = io.Copy(upstream, buffer); upstream.Close() }()
		_, _ = io.Copy(connection, upstream)
	}))
	defer proxy.Close()
	connection, e := dialThroughProxy(context.Background(), "channels.weixin.qq.com:443", proxy.URL)
	if e != nil {
		t.Fatal(e)
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(3 * time.Second))
	_, e = connection.Write([]byte("tunnel-fixture"))
	if e != nil {
		t.Fatal(e)
	}
	b := make([]byte, 14)
	_, e = io.ReadFull(connection, b)
	if e != nil || string(b) != "tunnel-fixture" {
		t.Fatal("upstream tunnel failed", e, string(b))
	}
	mu.Lock()
	defer mu.Unlock()
	if target != "channels.weixin.qq.com:443" {
		t.Fatal("wrong target", target)
	}
}
func TestProxyRouteSelection(t *testing.T) {
	state := &systemProxyState{UpstreamHTTP: "http://127.0.0.1:7897", UpstreamHTTPS: "http://127.0.0.1:7898"}
	for _, entry := range []struct{ scheme, port string }{{"http", "7897"}, {"https", "7898"}} {
		r := httptest.NewRequest("GET", entry.scheme+"://example.com/", nil)
		u, e := state.proxyFor(r)
		if e != nil || u.Port() != entry.port {
			t.Fatal("wrong upstream")
		}
	}
	for _, bad := range []string{"http://user:pass@proxy:80", "file:///tmp/p", "socks5://localhost:80", "http://localhost:80/path"} {
		if _, e := proxyAddress(bad); e == nil {
			t.Fatal("accepted unsupported proxy", bad)
		}
	}
	if got, e := proxyAddress("127.0.0.1:7897"); e != nil || !strings.HasPrefix(got, "http://") {
		t.Fatal(got, e)
	}
}
