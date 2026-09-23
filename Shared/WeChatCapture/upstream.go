package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func proxyAddress(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	u, e := url.Parse(raw)
	if e != nil || u.Hostname() == "" || u.User != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("暂不支持这组代理地址；原代理未修改")
	}
	if u.Port() == "" {
		u.Host = net.JoinHostPort(u.Hostname(), "80")
		if u.Scheme == "https" {
			u.Host = net.JoinHostPort(u.Hostname(), "443")
		}
	}
	return u.String(), nil
}
func (s *systemProxyState) proxyFor(r *http.Request) (*url.URL, error) {
	raw := s.UpstreamHTTP
	if r.URL.Scheme == "https" {
		raw = s.UpstreamHTTPS
	}
	if raw == "" {
		return nil, nil
	}
	return url.Parse(raw)
}
func dialThroughProxy(ctx context.Context, target, upstream string) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: 20 * time.Second}
	if upstream == "" {
		return dialer.DialContext(ctx, "tcp", target)
	}
	u, e := url.Parse(upstream)
	if e != nil {
		return nil, e
	}
	var connection net.Conn
	if u.Scheme == "https" {
		d := &tls.Dialer{NetDialer: dialer, Config: &tls.Config{ServerName: u.Hostname(), MinVersion: tls.VersionTLS12}}
		connection, e = d.DialContext(ctx, "tcp", u.Host)
	} else {
		connection, e = dialer.DialContext(ctx, "tcp", u.Host)
	}
	if e != nil {
		return nil, e
	}
	connection.SetDeadline(time.Now().Add(20 * time.Second))
	request := &http.Request{Method: "CONNECT", URL: &url.URL{Opaque: target}, Host: target, Header: make(http.Header)}
	if e = request.Write(connection); e != nil {
		connection.Close()
		return nil, e
	}
	reader := bufio.NewReader(connection)
	response, e := http.ReadResponse(reader, request)
	if e != nil {
		connection.Close()
		return nil, e
	}
	if response.StatusCode != 200 {
		connection.Close()
		return nil, fmt.Errorf("原代理未能建立连接（HTTP %d）", response.StatusCode)
	}
	connection.SetDeadline(time.Time{})
	return &bufferedConn{connection, reader}, nil
}
