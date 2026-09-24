package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

const (
	windowsProxyDirect     uint32 = 1
	windowsProxyManual     uint32 = 2
	windowsProxyAutoURL    uint32 = 4
	windowsProxyAutoDetect uint32 = 8
)

// Keep the complete WinINet configuration, including automatic detection, so
// capture can temporarily use its loopback listener and restore the user's state.
type windowsInternetSettings struct {
	Flags         uint32 `json:"flags"`
	Server        string `json:"server"`
	Bypass        string `json:"bypass"`
	AutoConfigURL string `json:"autoConfigURL"`
}

type windowsProxyBackend struct {
	read  func() (windowsInternetSettings, error)
	write func(windowsInternetSettings) error
}

func inspectWindowsSystemProxy(backend windowsProxyBackend) (*systemProxyState, error) {
	settings, err := backend.read()
	if err != nil {
		return nil, err
	}
	if settings.Flags&windowsProxyAutoURL != 0 && settings.AutoConfigURL != "" {
		return nil, errors.New("当前启用了自动代理脚本（PAC），暂不支持接续；请切换为手动 HTTP/HTTPS 代理或关闭自动代理脚本后重试，原设置未修改")
	}
	state := &systemProxyState{WindowsInternet: &settings}
	if settings.Flags&windowsProxyManual == 0 {
		return state, nil
	}
	raw := strings.TrimSpace(settings.Server)
	if raw == "" {
		return nil, errors.New("系统手动代理已启用但地址为空，请检查 Windows 代理设置，原设置未修改")
	}
	if !strings.Contains(raw, "=") {
		address, e := proxyAddress(raw)
		if e != nil {
			return nil, e
		}
		state.UpstreamHTTP, state.UpstreamHTTPS = address, address
		return state, nil
	}
	for _, pair := range strings.Split(raw, ";") {
		parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
		if len(parts) != 2 {
			continue
		}
		protocol := strings.ToLower(strings.TrimSpace(parts[0]))
		if protocol != "http" && protocol != "https" {
			continue
		}
		address, e := proxyAddress(strings.TrimSpace(parts[1]))
		if e != nil {
			return nil, e
		}
		if protocol == "http" {
			state.UpstreamHTTP = address
		} else {
			state.UpstreamHTTPS = address
		}
	}
	if state.UpstreamHTTP == "" && state.UpstreamHTTPS == "" {
		return nil, errors.New("当前代理没有 HTTP/HTTPS 转发入口，原设置未修改")
	}
	return state, nil
}

func (s *systemProxyState) enableWindowsProxy(directory string, port int, backend windowsProxyBackend) error {
	if port < 1 || port > 65535 || s.WindowsInternet == nil {
		return errors.New("临时代理设置无效，原设置未修改")
	}
	s.Port = port
	if err := writePrivateJSON(snapshotPath(directory), s); err != nil {
		return errors.New("无法保存网络恢复记录，未启用捕获")
	}
	temporary := *s.WindowsInternet
	temporary.Flags = windowsProxyDirect | windowsProxyManual
	temporary.Server = "127.0.0.1:" + strconv.Itoa(port)
	temporary.Bypass = "<local>"
	err := backend.write(temporary)
	if err == nil {
		current, readErr := backend.read()
		if readErr != nil {
			err = readErr
		} else if current != temporary {
			err = errors.New("临时网络代理未生效，请检查系统权限后重试")
		}
	}
	if err != nil {
		if restoreErr := s.restoreWindowsProxy(directory, backend); restoreErr != nil {
			return fmt.Errorf("%v；恢复原网络设置失败，恢复记录已保留：%v", err, restoreErr)
		}
	}
	return err
}

func (s *systemProxyState) originalWindowsSettings(current windowsInternetSettings) (windowsInternetSettings, error) {
	if s.WindowsInternet != nil {
		return *s.WindowsInternet, nil
	}
	// Compatibility with restore records created before native WinINet support.
	// That implementation changed only ProxyEnable/Server/Override, not PAC/WPAD.
	if s.Windows == nil && len(s.Entries) != 0 {
		return windowsInternetSettings{}, errors.New("网络恢复记录不属于 Windows，请导出诊断报告")
	}
	// Old clean-install snapshots omitted an empty Windows map (omitempty).
	// The owned loopback server still identifies this as our recovery record.
	restored := current
	restored.Flags &^= windowsProxyManual
	var enabled int
	_ = json.Unmarshal(s.Windows["ProxyEnable"], &enabled)
	if enabled != 0 {
		restored.Flags |= windowsProxyManual
	} else {
		restored.Flags |= windowsProxyDirect
	}
	restored.Server, restored.Bypass = "", ""
	_ = json.Unmarshal(s.Windows["ProxyServer"], &restored.Server)
	_ = json.Unmarshal(s.Windows["ProxyOverride"], &restored.Bypass)
	return restored, nil
}

func (s *systemProxyState) restoreWindowsProxy(directory string, backend windowsProxyBackend) error {
	current, err := backend.read()
	if err != nil {
		return err
	}
	if current.Server == "127.0.0.1:"+strconv.Itoa(s.Port) {
		original, e := s.originalWindowsSettings(current)
		if e != nil {
			return e
		}
		if e = backend.write(original); e != nil {
			return e
		}
		restored, e := backend.read()
		if e != nil {
			return e
		}
		if restored != original {
			return errors.New("原网络设置尚未恢复，恢复记录已保留，请重试关闭捕获")
		}
	}
	if err = os.Remove(snapshotPath(directory)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
