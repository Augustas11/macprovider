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

func TestRunUsageErrors(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want int
	}{
		{
			name: "no args",
			args: nil,
			want: 64,
		},
		{
			name: "bundle placeholder",
			args: []string{"--bundle", "/dev/null"},
			want: 65,
		},
		{
			name: "malformed pubkey value",
			args: []string{"--pubkey", "not-real-base64!!", "--bundle", "/dev/null"},
			want: 64,
		},
		{
			name: "explicit pubkey but no other input",
			args: []string{"--pubkey", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},
			want: 64,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer

			code := run(tt.args, &stdout, &stderr, func(string) string { return "" })

			if code != tt.want {
				t.Fatalf("run(%v) exit code = %d, want %d", tt.args, code, tt.want)
			}
			if stderr.Len() == 0 {
				t.Fatalf("stderr empty for usage error")
			}
		})
	}
}

// TestRunUnknownFlag asserts that an unknown CLI flag exits 64 (usage error)
// per SPEC-015 v0.2.4 §10.4.3. flag.ContinueOnError returns the parse error;
// the scaffold maps that to exit 64.
func TestRunUnknownFlag(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"--bogus-flag"}, &stdout, &stderr, func(string) string { return "" })

	if code != 64 {
		t.Fatalf("run(--bogus-flag) exit code = %d, want %d", code, 64)
	}
	// flag package writes "flag provided but not defined" to stderr; the scaffold
	// passes that through. Don't assert the exact phrase (it's a stdlib internal),
	// just confirm SOMETHING was written to stderr to aid the user.
	if stderr.Len() == 0 {
		t.Fatalf("run(--bogus-flag) wrote nothing to stderr; user has no error context")
	}
}
