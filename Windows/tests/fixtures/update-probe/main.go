// Native Windows updater fixture. It never touches a real installation.
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	exe, _ := os.Executable()
	root := filepath.Dir(exe)
	version, _ := os.ReadFile(filepath.Join(root, "version.txt"))
	if len(os.Args) > 1 && os.Args[1] == "--wait-for-exit" {
		for i := 0; i < 1200; i++ {
			if _, err := os.Stat(filepath.Join(root, "exit.txt")); err == nil {
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
		return
	}
	_ = os.WriteFile(filepath.Join(root, "restarted.txt"), []byte(string(version)+"\n"+exe), 0600)
	if string(version) == "no-startup" {
		return
	}
	for _, arg := range os.Args[1:] {
		if strings.HasPrefix(arg, "--bilifetch-update=") {
			id := strings.TrimPrefix(arg, "--bilifetch-update=")
			payload, _ := json.Marshal(map[string]string{"attemptId": id, "version": string(version), "executable": exe})
			_ = os.WriteFile(filepath.Join(os.Getenv("BILIFETCH_INSTALL_TEST_UPDATES"), "install-"+id+".json.started"), payload, 0600)
		}
	}
	time.Sleep(2 * time.Second)
}
