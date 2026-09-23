package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func prepareCommand(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true} }
func acquireDataLock(directory string) (func(), error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	name, err := syscall.UTF16PtrFromString(filepath.Join(directory, "capture.lock"))
	if err != nil {
		return nil, err
	}
	handle, err := syscall.CreateFile(name, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil, syscall.OPEN_ALWAYS, syscall.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, errors.New("已有视频号捕获组件正在运行，请先在原窗口关闭捕获")
	}
	return func() { _ = syscall.CloseHandle(handle) }, nil
}
