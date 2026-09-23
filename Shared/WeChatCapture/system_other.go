//go:build !darwin && !windows

package main

import "errors"

func inspectSystemProxy() (*systemProxyState, error) {
	return nil, errors.New("当前系统不支持视频号捕获")
}
func (s *systemProxyState) enable(directory string, port int) error {
	return errors.New("unsupported platform")
}
func (s *systemProxyState) restore(directory string) error { return errors.New("unsupported platform") }
func trustCertificate(path string) error                   { return errors.New("unsupported platform") }
