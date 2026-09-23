package main

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"unicode/utf16"
)

func ps(script string) (string, error) {
	words := utf16.Encode([]rune("$ErrorActionPreference='Stop';" + script))
	data := make([]byte, len(words)*2)
	for i, v := range words {
		binary.LittleEndian.PutUint16(data[i*2:], v)
	}
	return commandRunner("powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", base64.StdEncoding.EncodeToString(data))
}

const registryPath = `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`

func registryState() (map[string]json.RawMessage, error) {
	output, err := ps(`$p=Get-ItemProperty '` + registryPath + `';$r=@{};foreach($n in @('ProxyEnable','ProxyServer','ProxyOverride','AutoConfigURL','AutoDetect')){if($null -ne $p.$n){$r[$n]=$p.$n}};$r|ConvertTo-Json -Compress`)
	if err != nil {
		return nil, err
	}
	var values map[string]json.RawMessage
	if json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(output, "\ufeff"))), &values) != nil {
		return nil, errors.New("无法读取系统代理设置")
	}
	return values, nil
}
func registryString(values map[string]json.RawMessage, key string) string {
	var value string
	_ = json.Unmarshal(values[key], &value)
	return value
}
func registryNumber(values map[string]json.RawMessage, key string) int {
	var value int
	_ = json.Unmarshal(values[key], &value)
	return value
}
func inspectSystemProxy() (*systemProxyState, error) {
	values, err := registryState()
	if err != nil {
		return nil, err
	}
	if registryString(values, "AutoConfigURL") != "" || registryNumber(values, "AutoDetect") == 1 {
		return nil, errors.New("当前使用自动代理，暂不支持接续；请在原代理软件切换到 HTTP/HTTPS 系统代理后重试，无需退出原代理软件")
	}
	state := &systemProxyState{Windows: values}
	if registryNumber(values, "ProxyEnable") != 0 {
		raw := registryString(values, "ProxyServer")
		if strings.Contains(raw, "=") {
			for _, pair := range strings.Split(raw, ";") {
				parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
				if len(parts) != 2 {
					continue
				}
				if parts[0] != "http" && parts[0] != "https" {
					continue
				}
				address, e := proxyAddress(parts[1])
				if e != nil {
					return nil, e
				}
				if parts[0] == "http" {
					state.UpstreamHTTP = address
				} else {
					state.UpstreamHTTPS = address
				}
			}
			if state.UpstreamHTTP == "" && state.UpstreamHTTPS == "" {
				return nil, errors.New("当前代理没有 HTTP/HTTPS 转发入口，原设置未修改")
			}
		} else {
			address, e := proxyAddress(raw)
			if e != nil {
				return nil, e
			}
			state.UpstreamHTTP = address
			state.UpstreamHTTPS = address
		}
	}
	return state, nil
}

const refreshInternet = `Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class BiliFetchInternet{[DllImport("wininet.dll")]public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);}';[void][BiliFetchInternet]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0);[void][BiliFetchInternet]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0);`

func (s *systemProxyState) enable(directory string, port int) error {
	s.Port = port
	if err := writePrivateJSON(snapshotPath(directory), s); err != nil {
		return errors.New("无法保存网络恢复记录，未启用捕获")
	}
	_, err := ps(`$p='` + registryPath + `';Set-ItemProperty $p ProxyServer '127.0.0.1:` + strconv.Itoa(port) + `';Set-ItemProperty $p ProxyOverride '<local>';Set-ItemProperty $p ProxyEnable 1;` + refreshInternet)
	if err == nil {
		current, readError := registryState()
		if readError != nil || registryNumber(current, "ProxyEnable") != 1 || registryString(current, "ProxyServer") != "127.0.0.1:"+strconv.Itoa(port) {
			err = errors.New("临时网络代理未生效，请检查系统权限后重试")
		}
	}
	if err != nil {
		_ = s.restore(directory)
	}
	return err
}
func (s *systemProxyState) restore(directory string) error {
	current, err := registryState()
	if err != nil {
		return err
	}
	if registryString(current, "ProxyServer") == "127.0.0.1:"+strconv.Itoa(s.Port) {
		data, _ := json.Marshal(s.Windows)
		encoded := base64.StdEncoding.EncodeToString(data)
		script := `$p='` + registryPath + `';$v=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('` + encoded + `'))|ConvertFrom-Json;foreach($n in @('ProxyServer','ProxyOverride','ProxyEnable')){if($null -ne $v.$n){Set-ItemProperty $p $n $v.$n}else{Remove-ItemProperty $p $n -ErrorAction SilentlyContinue}};` + refreshInternet
		if _, err = ps(script); err != nil {
			return err
		}
	}
	if err = os.Remove(snapshotPath(directory)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
func trustCertificate(path string) error {
	_, err := commandRunner("certutil.exe", "-user", "-addstore", "Root", path)
	if err != nil {
		return errors.New("未完成本机捕获证书信任，请允许系统授权后重试")
	}
	return nil
}
