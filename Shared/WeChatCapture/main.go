package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println("BiliFetch WeChat Capture 1")
		return
	}
	directory := flag.String("data-dir", "", "Private application data directory")
	recoverOnly := flag.Bool("recover", false, "Restore the previous capture proxy settings only")
	flag.Parse()
	if *directory == "" {
		fmt.Fprintln(os.Stderr, "必须指定捕获数据目录")
		os.Exit(2)
	}
	var err error
	unlock, err := acquireDataLock(*directory)
	if err == nil {
		defer unlock()
		if *recoverOnly {
			err = recoverSystemProxy(*directory)
		} else {
			err = serve(*directory)
		}
	}
	if err != nil {
		_ = json.NewEncoder(os.Stderr).Encode(map[string]string{"error": err.Error()})
		os.Exit(1)
	}
}
