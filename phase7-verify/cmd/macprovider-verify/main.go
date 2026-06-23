package main

import (
	"io"
	"os"
	"strings"

	"github.com/augstar/macprovider/phase7-verify/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr, os.Getenv))
}

func run(args []string, stdout, stderr io.Writer, getenv func(string) string) int {
	return cli.Run(args, strings.NewReader(""), stdout, stderr, getenv)
}
