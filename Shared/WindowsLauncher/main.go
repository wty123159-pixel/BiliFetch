//go:build windows

// BiliFetch.exe remains a small compatibility entry point for older updaters
// and user shortcuts. The actual application runs under its new display name.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"
)

func main() {
	executable, err := os.Executable()
	if err == nil {
		command := exec.Command(filepath.Join(filepath.Dir(executable), "记住你宇哥.exe"), os.Args[1:]...)
		command.Dir = filepath.Dir(executable)
		err = command.Start()
		if err == nil {
			return
		}
	}
	title, _ := syscall.UTF16PtrFromString("记住你宇哥")
	message, _ := syscall.UTF16PtrFromString("未能启动软件。请完整解压安装包，再打开“记住你宇哥.exe”，不要单独移动启动文件。")
	_, _, _ = syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(message)), uintptr(unsafe.Pointer(title)), 0x10)
	os.Exit(1)
}
