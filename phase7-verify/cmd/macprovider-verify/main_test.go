package main

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"github.com/augstar/macprovider/phase7-verify/internal/version"
)

func TestRunVersion(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"--version"}, &stdout, &stderr, func(string) string { return "" })

	if code != 0 {
		t.Fatalf("run(--version) exit code = %d, want 0; stderr=%q", code, stderr.String())
	}
	want := fmt.Sprintf("macprovider-verify %s (verifies up to SPEC-015 v%s)\n", version.BinaryVersion, version.MaxSPECVersion)
	if stdout.String() != want {
		t.Fatalf("run(--version) stdout = %q, want %q", stdout.String(), want)
	}
}

func TestRunHelp(t *testing.T) {
	requiredFlags := []string{
		"--receipt",
		"--prompt-hash",
		"--output-hash",
		"--bundle",
		"--pubkey",
		"--provider-id",
		"--json",
		"--offline",
		"--quiet",
		"--coordinator",
		"--explain",
	}
	var stdout, stderr bytes.Buffer

	code := run([]string{"--help"}, &stdout, &stderr, func(string) string { return "" })

	if code != 0 {
		t.Fatalf("run(--help) exit code = %d, want 0; stderr=%q", code, stderr.String())
	}
	for _, flagName := range requiredFlags {
		t.Run(flagName, func(t *testing.T) {
			if !strings.Contains(stdout.String(), flagName) {
				t.Fatalf("help output missing %s:\n%s", flagName, stdout.String())
			}
		})
	}
}

func TestRunUsageStub(t *testing.T) {
	tests := []struct {
		name string
		args []string
	}{
		{
			name: "no args",
			args: nil,
		},
		{
			name: "bundle placeholder",
			args: []string{"--bundle", "/dev/null"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer

			code := run(tt.args, &stdout, &stderr, func(string) string { return "" })

			if code != exitUsage {
				t.Fatalf("run(%v) exit code = %d, want %d", tt.args, code, exitUsage)
			}
			if !strings.Contains(stderr.String(), "TODO: Step 7") {
				t.Fatalf("stderr missing Step 7 TODO, got %q", stderr.String())
			}
		})
	}
}
