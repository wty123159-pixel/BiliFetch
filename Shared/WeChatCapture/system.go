package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type proxyEntry struct {
	Service       string
	Kind          string
	Server        string
	Port          int
	Enabled       bool
	Authenticated bool
}
type systemProxyState struct {
	Port          int                        `json:"port"`
	Entries       []proxyEntry               `json:"entries,omitempty"`
	Windows       map[string]json.RawMessage `json:"windows,omitempty"`
	UpstreamHTTP  string                     `json:"upstreamHTTP,omitempty"`
	UpstreamHTTPS string                     `json:"upstreamHTTPS,omitempty"`
}

var commandRunner = func(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	prepareCommand(cmd)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("系统网络设置操作失败（%s），请检查授权后重试", filepath.Base(name))
	}
	return string(output), nil
}

func snapshotPath(directory string) string { return filepath.Join(directory, "proxy-restore.json") }
func recoverSystemProxy(directory string) error {
	data, err := os.ReadFile(snapshotPath(directory))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var state systemProxyState
	if json.Unmarshal(data, &state) != nil || state.Port < 1 || state.Port > 65535 {
		return errors.New("网络恢复记录无效，请导出诊断报告")
	}
	return state.restore(directory)
}
