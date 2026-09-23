package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func network(args ...string) (string, error) {
	text, err := commandRunner("/usr/sbin/networksetup", args...)
	// Some networksetup failures return exit status zero.
	if err == nil && (strings.Contains(text, "** Error") || strings.Contains(text, "must be root") || strings.Contains(text, "not authorized") || strings.Contains(text, "Authorization failed")) {
		err = errors.New("网络设置未获授权，请使用管理员账号并检查系统授权提示")
	}
	return text, err
}
func readProxy(service, kind string) (proxyEntry, error) {
	text, err := network("-get"+kind+"proxy", service)
	if err != nil {
		return proxyEntry{}, err
	}
	fields := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		if pair := strings.SplitN(line, ": ", 2); len(pair) == 2 {
			fields[pair[0]] = strings.TrimSpace(pair[1])
		}
	}
	if fields["Enabled"] != "Yes" && fields["Enabled"] != "No" {
		return proxyEntry{}, errors.New("无法识别系统代理状态，请导出诊断报告")
	}
	port, _ := strconv.Atoi(fields["Port"])
	return proxyEntry{Service: service, Kind: kind, Server: fields["Server"], Port: port, Enabled: fields["Enabled"] == "Yes", Authenticated: fields["Authenticated Proxy Enabled"] == "1"}, nil
}
func inspectSystemProxy() (*systemProxyState, error) {
	output, err := network("-listallnetworkservices")
	if err != nil {
		return nil, err
	}
	state := &systemProxyState{}
	for index, line := range strings.Split(strings.TrimSpace(output), "\n") {
		service := strings.TrimSpace(line)
		if index == 0 || service == "" || strings.HasPrefix(service, "*") {
			continue
		}
		for _, query := range []string{"-getautoproxyurl", "-getproxyautodiscovery"} {
			v, e := network(query, service)
			if e != nil {
				return nil, e
			}
			if strings.Contains(v, "Enabled: Yes") || strings.Contains(v, ": On") {
				return nil, errors.New("检测到已有自动代理，请先暂停该代理后再开启视频号捕获；原设置不会被覆盖")
			}
		}
		for _, kind := range []string{"web", "secureweb"} {
			entry, e := readProxy(service, kind)
			if e != nil {
				return nil, e
			}
			if entry.Enabled {
				if entry.Authenticated {
					return nil, errors.New("当前网络代理需要账号认证，暂时无法安全接续；原设置未修改")
				}
				address, e := proxyAddress(net.JoinHostPort(entry.Server, strconv.Itoa(entry.Port)))
				if e != nil {
					return nil, e
				}
				current := &state.UpstreamHTTP
				if kind == "secureweb" {
					current = &state.UpstreamHTTPS
				}
				if *current != "" && *current != address {
					return nil, errors.New("检测到多组不同网络代理，暂时无法安全接续；原设置未修改")
				}
				*current = address
			}
			state.Entries = append(state.Entries, entry)
		}
	}
	if len(state.Entries) == 0 {
		return nil, errors.New("没有找到可配置的网络服务")
	}
	return state, nil
}
func (s *systemProxyState) enable(directory string, port int) error {
	s.Port = port
	if err := writePrivateJSON(snapshotPath(directory), s); err != nil {
		return errors.New("无法保存网络恢复记录，未启用捕获")
	}
	for _, entry := range s.Entries {
		if _, err := network("-set"+entry.Kind+"proxy", entry.Service, "127.0.0.1", strconv.Itoa(port)); err != nil {
			_ = s.restore(directory)
			return err
		}
		if _, err := network("-set"+entry.Kind+"proxystate", entry.Service, "on"); err != nil {
			_ = s.restore(directory)
			return err
		}
		current, err := readProxy(entry.Service, entry.Kind)
		if err != nil || !current.Enabled || current.Server != "127.0.0.1" || current.Port != port {
			_ = s.restore(directory)
			return errors.New("临时网络代理未生效，请检查系统权限后重试")
		}
	}
	return nil
}
func (s *systemProxyState) restore(directory string) error {
	for _, entry := range s.Entries {
		current, err := readProxy(entry.Service, entry.Kind)
		if err != nil {
			return err
		}
		// Respect changes made by the user or a different proxy while capture ran.
		if current.Server != "127.0.0.1" || current.Port != s.Port {
			continue
		}
		host, port := entry.Server, entry.Port
		// Disable our proxy first so a failure restoring an empty host cannot
		// leave networking dependent on this helper.
		if _, err = network("-set"+entry.Kind+"proxystate", entry.Service, "off"); err != nil {
			return err
		}
		if host == "" || host == "(null)" {
			host = ""
			port = 0
		}
		if _, err = network("-set"+entry.Kind+"proxy", entry.Service, host, strconv.Itoa(port)); err != nil {
			return err
		}
		on := "off"
		if entry.Enabled {
			on = "on"
		}
		if _, err = network("-set"+entry.Kind+"proxystate", entry.Service, on); err != nil {
			return err
		}
	}
	if err := os.Remove(snapshotPath(directory)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
func trustCertificate(path string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	_, err = commandRunner("/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", filepath.Join(home, "Library/Keychains/login.keychain-db"), path)
	if err != nil {
		return fmt.Errorf("未完成本机捕获证书信任，请允许系统授权后重试：%w", err)
	}
	return nil
}
