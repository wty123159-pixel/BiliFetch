package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
)

func mockNetwork(t *testing.T) map[string]proxyEntry {
	t.Helper()
	original := commandRunner
	t.Cleanup(func() { commandRunner = original })
	entries := map[string]proxyEntry{
		"web": {Service: "Wi-Fi", Kind: "web"}, "secureweb": {Service: "Wi-Fi", Kind: "secureweb"},
	}
	commandRunner = func(name string, args ...string) (string, error) {
		switch args[0] {
		case "-listallnetworkservices":
			return "An asterisk denotes disabled services.\nWi-Fi\n", nil
		case "-getautoproxyurl":
			return "URL: (null)\nEnabled: No\n", nil
		case "-getproxyautodiscovery":
			return "Auto Proxy Discovery: Off\n", nil
		}
		kind := "web"
		if strings.Contains(args[0], "secureweb") {
			kind = "secureweb"
		}
		entry := entries[kind]
		if strings.HasPrefix(args[0], "-get") {
			enabled := "No"
			if entry.Enabled {
				enabled = "Yes"
			}
			return fmt.Sprintf("Enabled: %s\nServer: %s\nPort: %d\n", enabled, entry.Server, entry.Port), nil
		}
		if strings.HasSuffix(args[0], "proxystate") {
			entry.Enabled = args[2] == "on"
		} else {
			entry.Server = args[2]
			entry.Port, _ = strconv.Atoi(args[3])
			entry.Enabled = true
		}
		entries[kind] = entry
		return "", nil
	}
	return entries
}
func TestSystemProxyEnableRestoreAndConflict(t *testing.T) {
	entries := mockNetwork(t)
	state, e := inspectSystemProxy()
	if e != nil {
		t.Fatal(e)
	}
	dir := t.TempDir()
	if e = state.enable(dir, 43210); e != nil {
		t.Fatal(e)
	}
	for _, v := range entries {
		if !v.Enabled || v.Port != 43210 {
			t.Fatal("proxy was not enabled")
		}
	}
	chain, e := inspectSystemProxy()
	if e != nil || chain.UpstreamHTTPS != "http://127.0.0.1:43210" {
		t.Fatal("existing proxy was not preserved", e)
	}
	if e = state.restore(dir); e != nil {
		t.Fatal(e)
	}
	for _, v := range entries {
		if v.Enabled || v.Server != "" || v.Port != 0 {
			t.Fatal("original settings not restored", v)
		}
	}
	if _, e = os.Stat(snapshotPath(dir)); !os.IsNotExist(e) {
		t.Fatal("restore snapshot remains")
	}
}
func TestSystemProxyRespectsExternalChanges(t *testing.T) {
	entries := mockNetwork(t)
	state, _ := inspectSystemProxy()
	dir := t.TempDir()
	_ = state.enable(dir, 43210)
	external := proxyEntry{Service: "Wi-Fi", Kind: "web", Server: "user-proxy", Port: 9999, Enabled: true}
	entries["web"] = external
	if e := recoverSystemProxy(dir); e != nil {
		t.Fatal(e)
	}
	if entries["web"] != external {
		t.Fatal("user change overwritten")
	}
	if entries["secureweb"].Enabled {
		t.Fatal("owned proxy not restored")
	}
}

func TestExistingProxyRoundTrip(t *testing.T) {
	entries := mockNetwork(t)
	for kind, entry := range entries {
		entry.Server = "127.0.0.1"
		entry.Port = 7897
		entry.Enabled = true
		entries[kind] = entry
	}
	state, e := inspectSystemProxy()
	if e != nil {
		t.Fatal(e)
	}
	if state.UpstreamHTTP != "http://127.0.0.1:7897" || state.UpstreamHTTPS != state.UpstreamHTTP {
		t.Fatal("missing upstream")
	}
	dir := t.TempDir()
	if e = state.enable(dir, 43001); e != nil {
		t.Fatal(e)
	}
	if e = state.restore(dir); e != nil {
		t.Fatal(e)
	}
	for _, entry := range entries {
		if entry.Port != 7897 || !entry.Enabled {
			t.Fatal("original proxy lost")
		}
	}
}
func TestSystemProxyPartialSetupRollsBack(t *testing.T) {
	entries := mockNetwork(t)
	original := commandRunner
	once := false
	commandRunner = func(name string, args ...string) (string, error) {
		if args[0] == "-setsecurewebproxy" && !once {
			once = true
			return "", errors.New("simulated denied setup")
		}
		return original(name, args...)
	}
	state, _ := inspectSystemProxy()
	if e := state.enable(t.TempDir(), 43210); e == nil {
		t.Fatal("failure missing")
	}
	for _, v := range entries {
		if v.Enabled {
			t.Fatal("partial setup left enabled proxy")
		}
	}
}

func TestAuthenticatedProxyRejectedBeforeChanges(t *testing.T) {
	entries := mockNetwork(t)
	entries["web"] = proxyEntry{Service: "Wi-Fi", Kind: "web", Server: "proxy.example", Port: 8000, Enabled: true}
	original := commandRunner
	commandRunner = func(name string, args ...string) (string, error) {
		if strings.HasPrefix(args[0], "-set") {
			t.Fatal("settings changed before inspection completed")
		}
		text, err := original(name, args...)
		if args[0] == "-getwebproxy" {
			text += "Authenticated Proxy Enabled: 1\n"
		}
		return text, err
	}
	if _, err := inspectSystemProxy(); err == nil || !strings.Contains(err.Error(), "认证") {
		t.Fatal("authentication was not detected", err)
	}
}
