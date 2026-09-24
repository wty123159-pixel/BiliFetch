//go:build windows

// This GUI bootstrapper runs outside the application directory and its job.
// PowerShell itself cannot reliably start with Node's DETACHED_PROCESS flag;
// without that flag libuv's job kills it when the Electron parent exits.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func main() {
	root := os.Getenv("SystemRoot")
	if root == "" {
		root = `C:\Windows`
	}
	command := exec.Command(filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), os.Args[1:]...)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW, no DETACHED_PROCESS
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	if err := command.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "Update bootstrapper:", err)
		if exit, ok := err.(*exec.ExitError); ok {
			os.Exit(exit.ExitCode())
		}
		os.Exit(1)
	}
}
