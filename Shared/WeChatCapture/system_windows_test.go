package main

import (
	"net"
	"os"
	"testing"
	"unsafe"
)

func TestWindowsNativeRead(t *testing.T) {
	if unsafe.Sizeof(uintptr(0)) == 8 && (unsafe.Sizeof(internetOption{}) != 16 || unsafe.Sizeof(internetOptionList{}) != 32) {
		t.Fatal("WinINet ABI layout mismatch")
	}
	settings, err := readWindowsInternetSettings()
	if err != nil {
		t.Fatal(err)
	}
	// Never include private proxy addresses or PAC URLs in the test log.
	t.Logf("WinINet read succeeded; flags=%d", settings.Flags)
}
func TestWindowsNativeProxyRoundTrip(t *testing.T) {
	if os.Getenv("BILIFETCH_TEST_WINDOWS_PROXY") != "1" {
		t.Skip("requires an isolated Windows test machine")
	}
	original, err := readWindowsInternetSettings()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := writeWindowsInternetSettings(original); err != nil {
			t.Errorf("restore original settings: %v", err)
		}
	})
	for _, flags := range []uint32{windowsProxyDirect, windowsProxyDirect | windowsProxyAutoDetect} {
		before := windowsInternetSettings{Flags: flags}
		if err := writeWindowsInternetSettings(before); err != nil {
			t.Fatal(err)
		}
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		state, err := inspectSystemProxy()
		if err != nil {
			listener.Close()
			t.Fatal(err)
		}
		if state.UpstreamHTTP != "" || state.UpstreamHTTPS != "" {
			t.Fatal("direct mode unexpectedly requires an upstream proxy")
		}
		dir := t.TempDir()
		if err = state.enable(dir, listener.Addr().(*net.TCPAddr).Port); err != nil {
			listener.Close()
			t.Fatal(err)
		}
		if err = recoverSystemProxy(dir); err != nil {
			listener.Close()
			t.Fatal(err)
		}
		listener.Close()
		after, err := readWindowsInternetSettings()
		if err != nil || after != before {
			t.Fatalf("roundtrip failed: %v", err)
		}
	}
}
