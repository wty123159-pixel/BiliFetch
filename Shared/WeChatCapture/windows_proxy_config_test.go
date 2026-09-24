package main

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
)

func memoryWindowsProxy(settings windowsInternetSettings) (*windowsInternetSettings, windowsProxyBackend) {
	current := settings
	return &current, windowsProxyBackend{
		read:  func() (windowsInternetSettings, error) { return current, nil },
		write: func(next windowsInternetSettings) error { current = next; return nil },
	}
}
func TestWindowsProxyConfigurations(t *testing.T) {
	for _, test := range []struct {
		name                     string
		flags                    uint32
		server, pac, http, https string
		rejected                 bool
	}{
		{"clean install", windowsProxyDirect, "", "", "", "", false},
		{"default automatic detection", windowsProxyDirect | windowsProxyAutoDetect, "", "", "", "", false},
		{"disabled manual and PAC leftovers", windowsProxyDirect, "127.0.0.1:7897", "https://example.test/proxy.pac", "", "", false},
		{"arbitrary user port", windowsProxyManual | windowsProxyAutoDetect, "127.0.0.1:10809", "", "http://127.0.0.1:10809", "http://127.0.0.1:10809", false},
		{"separate protocols", windowsProxyManual, " HTTP =127.0.0.1:8000; HTTPS =[::1]:8001;socks=localhost:9000", "", "http://127.0.0.1:8000", "http://[::1]:8001", false},
		{"active PAC", windowsProxyAutoURL, "", "https://example.test/proxy.pac", "", "", true},
		{"missing manual address", windowsProxyManual, "", "", "", "", true},
		{"socks only", windowsProxyManual, "socks=127.0.0.1:1080", "", "", "", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			original := windowsInternetSettings{Flags: test.flags, Server: test.server, Bypass: "<local>;*.lan", AutoConfigURL: test.pac}
			current, backend := memoryWindowsProxy(original)
			state, err := inspectWindowsSystemProxy(backend)
			if test.rejected {
				if err == nil {
					t.Fatal("expected rejection")
				}
				if *current != original {
					t.Fatal("inspection changed settings")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if state.UpstreamHTTP != test.http || state.UpstreamHTTPS != test.https {
				t.Fatal("wrong upstream", state)
			}
			dir := t.TempDir()
			if err = state.enableWindowsProxy(dir, 45231, backend); err != nil {
				t.Fatal(err)
			}
			if current.Flags != windowsProxyDirect|windowsProxyManual || current.Server != "127.0.0.1:45231" {
				t.Fatal("temporary proxy not active", current)
			}
			// Simulate process restart by decoding the persisted restoration record.
			data, err := os.ReadFile(snapshotPath(dir))
			if err != nil {
				t.Fatal(err)
			}
			var recovered systemProxyState
			if err = json.Unmarshal(data, &recovered); err != nil {
				t.Fatal(err)
			}
			if err = recovered.restoreWindowsProxy(dir, backend); err != nil {
				t.Fatal(err)
			}
			if *current != original {
				t.Fatal("original settings not restored", current)
			}
			if _, err = os.Stat(snapshotPath(dir)); !os.IsNotExist(err) {
				t.Fatal("record not removed")
			}
		})
	}
}
func TestWindowsProxyFailuresAndOwnership(t *testing.T) {
	t.Run("failed read makes no writes", func(t *testing.T) {
		_, backend := memoryWindowsProxy(windowsInternetSettings{})
		backend.read = func() (windowsInternetSettings, error) {
			return windowsInternetSettings{}, errors.New("WinINet denied")
		}
		backend.write = func(windowsInternetSettings) error { t.Fatal("unexpected write"); return nil }
		if _, err := inspectWindowsSystemProxy(backend); err == nil {
			t.Fatal("read error missing")
		}
	})
	t.Run("partial setup rolls back", func(t *testing.T) {
		original := windowsInternetSettings{Flags: 9, Bypass: "original"}
		current, backend := memoryWindowsProxy(original)
		state, _ := inspectWindowsSystemProxy(backend)
		write := backend.write
		first := true
		backend.write = func(next windowsInternetSettings) error {
			_ = write(next)
			if first {
				first = false
				return errors.New("refresh failed")
			}
			return nil
		}
		if err := state.enableWindowsProxy(t.TempDir(), 45232, backend); err == nil {
			t.Fatal("setup error missing")
		}
		if *current != original {
			t.Fatal("partial setup not rolled back")
		}
	})
	t.Run("restore failure retains recovery record", func(t *testing.T) {
		_, backend := memoryWindowsProxy(windowsInternetSettings{Flags: 1})
		state, _ := inspectWindowsSystemProxy(backend)
		dir := t.TempDir()
		_ = state.enableWindowsProxy(dir, 45233, backend)
		backend.write = func(windowsInternetSettings) error { return errors.New("denied") }
		if err := state.restoreWindowsProxy(dir, backend); err == nil {
			t.Fatal("failure missing")
		}
		if _, err := os.Stat(snapshotPath(dir)); err != nil {
			t.Fatal("recovery record lost")
		}
	})
	t.Run("external change preserved", func(t *testing.T) {
		current, backend := memoryWindowsProxy(windowsInternetSettings{Flags: 1})
		state, _ := inspectWindowsSystemProxy(backend)
		dir := t.TempDir()
		_ = state.enableWindowsProxy(dir, 45234, backend)
		external := windowsInternetSettings{Flags: 3, Server: "127.0.0.1:9999", Bypass: "new"}
		*current = external
		if err := state.restoreWindowsProxy(dir, backend); err != nil {
			t.Fatal(err)
		}
		if *current != external {
			t.Fatal("external settings overwritten")
		}
	})
	t.Run("legacy recovery", func(t *testing.T) {
		current, backend := memoryWindowsProxy(windowsInternetSettings{Flags: 11, Server: "127.0.0.1:45235", Bypass: "<local>", AutoConfigURL: "stored PAC"})
		state := systemProxyState{Port: 45235, Windows: map[string]json.RawMessage{"ProxyEnable": json.RawMessage(`0`), "ProxyServer": json.RawMessage(`"old:1234"`), "ProxyOverride": json.RawMessage(`"*.local"`)}}
		if err := state.restoreWindowsProxy(t.TempDir(), backend); err != nil {
			t.Fatal(err)
		}
		if current.Flags != 9 || current.Server != "old:1234" || current.Bypass != "*.local" || current.AutoConfigURL != "stored PAC" {
			t.Fatal("legacy recovery changed automatic settings", current)
		}
	})
	t.Run("legacy empty registry snapshot", func(t *testing.T) {
		current, backend := memoryWindowsProxy(windowsInternetSettings{Flags: 11, Server: "127.0.0.1:45237", Bypass: "<local>"})
		state := systemProxyState{Port: 45237}
		if err := state.restoreWindowsProxy(t.TempDir(), backend); err != nil {
			t.Fatal(err)
		}
		if current.Flags != 9 || current.Server != "" || current.Bypass != "" {
			t.Fatal("empty legacy snapshot not restored", current)
		}
	})
	t.Run("rollback failure is actionable", func(t *testing.T) {
		_, backend := memoryWindowsProxy(windowsInternetSettings{Flags: 1})
		state, _ := inspectWindowsSystemProxy(backend)
		write := backend.write
		backend.write = func(next windowsInternetSettings) error { _ = write(next); return errors.New("refresh denied") }
		err := state.enableWindowsProxy(t.TempDir(), 45236, backend)
		if err == nil || !strings.Contains(err.Error(), "恢复记录已保留") {
			t.Fatal("rollback failure hidden", err)
		}
	})
}
