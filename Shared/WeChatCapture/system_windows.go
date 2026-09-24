package main

import (
	"errors"
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

var (
	winInet             = syscall.NewLazyDLL("wininet.dll")
	internetQueryOption = winInet.NewProc("InternetQueryOptionW")
	internetSetOption   = winInet.NewProc("InternetSetOptionW")
	globalFree          = syscall.NewLazyDLL("kernel32.dll").NewProc("GlobalFree")
	nativeWindowsProxy  = windowsProxyBackend{read: readWindowsInternetSettings, write: writeWindowsInternetSettings}
)

// INTERNET_PER_CONN_OPTION contains an 8-byte union, aligned like uint64
// (8 bytes on Win64, 4 bytes on Win32).
type internetOption struct {
	option uint32
	value  uint64
}
type internetOptionList struct {
	size        uint32
	connection  *uint16 // NULL means the user's LAN/default Internet settings.
	count       uint32
	optionError uint32
	options     *internetOption
}

func internetError(operation string, err error) error {
	var code syscall.Errno
	_ = errors.As(err, &code)
	return fmt.Errorf("%s Windows 系统代理失败（WinINet，错误码 %d）", operation, code)
}

func readWindowsInternetSettings() (windowsInternetSettings, error) {
	// FLAGS_UI is preferred on Windows 8+; older systems may only support FLAGS.
	for _, flagsOption := range []uint32{10, 1} {
		settings, err := queryWindowsInternetSettings(flagsOption)
		if err == nil {
			return settings, nil
		}
		if flagsOption == 1 {
			return settings, err
		}
	}
	return windowsInternetSettings{}, errors.New("无法读取 Windows 系统代理")
}

func queryWindowsInternetSettings(flagsOption uint32) (windowsInternetSettings, error) {
	options := []internetOption{{option: flagsOption}, {option: 2}, {option: 3}, {option: 4}}
	list := internetOptionList{count: uint32(len(options)), options: &options[0]}
	list.size = uint32(unsafe.Sizeof(list))
	size := list.size
	defer func() {
		for _, option := range options[1:] {
			if option.value != 0 {
				_, _, _ = globalFree.Call(uintptr(option.value))
			}
		}
	}()
	ok, _, err := internetQueryOption.Call(0, 75, uintptr(unsafe.Pointer(&list)), uintptr(unsafe.Pointer(&size)))
	runtime.KeepAlive(options)
	if ok == 0 {
		return windowsInternetSettings{}, internetError("读取", err)
	}
	readString := func(ptr uintptr) string {
		if ptr == 0 {
			return ""
		}
		return syscall.UTF16ToString((*[1 << 20]uint16)(unsafe.Pointer(ptr))[:])
	}
	return windowsInternetSettings{Flags: uint32(options[0].value), Server: readString(uintptr(options[1].value)), Bypass: readString(uintptr(options[2].value)), AutoConfigURL: readString(uintptr(options[3].value))}, nil
}

func writeWindowsInternetSettings(settings windowsInternetSettings) error {
	texts := make([][]uint16, 3)
	for i, text := range []string{settings.Server, settings.Bypass, settings.AutoConfigURL} {
		encoded, err := syscall.UTF16FromString(text)
		if err != nil {
			return errors.New("系统代理设置包含无效字符")
		}
		texts[i] = encoded
	}
	options := []internetOption{
		{option: 1, value: uint64(settings.Flags)},
		{option: 2, value: uint64(uintptr(unsafe.Pointer(&texts[0][0])))},
		{option: 3, value: uint64(uintptr(unsafe.Pointer(&texts[1][0])))},
		{option: 4, value: uint64(uintptr(unsafe.Pointer(&texts[2][0])))},
	}
	list := internetOptionList{count: uint32(len(options)), options: &options[0]}
	list.size = uint32(unsafe.Sizeof(list))
	ok, _, err := internetSetOption.Call(0, 75, uintptr(unsafe.Pointer(&list)), uintptr(list.size))
	runtime.KeepAlive(options)
	runtime.KeepAlive(texts)
	if ok == 0 {
		return internetError("设置", err)
	}
	// Notify WinINet consumers and refresh their cached settings.
	for _, option := range []uintptr{39, 37} {
		ok, _, err = internetSetOption.Call(0, option, 0, 0)
		if ok == 0 {
			return internetError("刷新", err)
		}
	}
	return nil
}

func inspectSystemProxy() (*systemProxyState, error) {
	return inspectWindowsSystemProxy(nativeWindowsProxy)
}
func (s *systemProxyState) enable(directory string, port int) error {
	return s.enableWindowsProxy(directory, port, nativeWindowsProxy)
}
func (s *systemProxyState) restore(directory string) error {
	return s.restoreWindowsProxy(directory, nativeWindowsProxy)
}
func trustCertificate(path string) error {
	_, err := commandRunner("certutil.exe", "-user", "-addstore", "Root", path)
	if err != nil {
		return errors.New("未完成本机捕获证书信任，请允许系统授权后重试")
	}
	return nil
}
