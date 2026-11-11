package main

import (
	"bytes"
	"errors"
	"flag"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestResolvePruneCutoff(t *testing.T) {
	before := time.Now().UTC()
	got, err := resolvePruneCutoff("168h")
	after := time.Now().UTC()
	if err != nil {
		t.Fatalf("duration: %v", err)
	}
	if got.Before(before.Add(-168*time.Hour)) || got.After(after.Add(-168*time.Hour)) {
		t.Fatalf("cutoff %v not 168h before now", got)
	}

	got, err = resolvePruneCutoff("2026-01-02T03:04:05+02:00")
	if err != nil {
		t.Fatalf("rfc3339: %v", err)
	}
	if want := time.Date(2026, 1, 2, 1, 4, 5, 0, time.UTC); !got.Equal(want) || got.Location() != time.UTC {
		t.Fatalf("cutoff = %v, want %v UTC", got, want)
	}

	if _, err := resolvePruneCutoff("yesterday"); err == nil || !strings.Contains(err.Error(), "expected duration") {
		t.Fatalf("garbage error = %v", err)
	}
}

func TestParseReferralExpiry(t *testing.T) {
	got, err := parseReferralExpiry("  ")
	if err != nil || got != nil {
		t.Fatalf("blank = %v, %v; want nil, nil", got, err)
	}
	got, err = parseReferralExpiry(" 2026-03-04T05:06:07-08:00 ")
	if err != nil || got == nil {
		t.Fatalf("valid: %v %v", got, err)
	}
	if want := time.Date(2026, 3, 4, 13, 6, 7, 0, time.UTC); !got.Equal(want) || got.Location() != time.UTC {
		t.Fatalf("expiry = %v, want %v UTC", got, want)
	}
	if _, err := parseReferralExpiry("2026-03-04"); err == nil || !strings.Contains(err.Error(), "--expires-at must be RFC3339") {
		t.Fatalf("bad date error = %v", err)
	}
}

func TestReferralParseErrorSwallowsHelpOnly(t *testing.T) {
	if err := referralParseError(flag.ErrHelp); err != nil {
		t.Fatalf("ErrHelp = %v, want nil", err)
	}
	boom := errors.New("boom")
	if err := referralParseError(boom); !errors.Is(err, boom) {
		t.Fatalf("other error = %v, want boom", err)
	}
	if err := referralParseError(nil); err != nil {
		t.Fatalf("nil = %v", err)
	}
}

func TestArchiveVerifyCommandsRejectBadArgs(t *testing.T) {
	cmds := map[string]func([]string, *bytes.Buffer) error{
		"audit-log-archive": func(a []string, b *bytes.Buffer) error { return auditLogArchive(a, b) },
		"ledger-rollup-archive": func(a []string, b *bytes.Buffer) error {
			return ledgerRollupArchive(a, b)
		},
	}
	missing := filepath.Join(t.TempDir(), "nope.jsonl.gz")
	for name, fn := range cmds {
		var out bytes.Buffer
		if err := fn(nil, &out); err == nil || !strings.Contains(err.Error(), "usage: "+name+" verify") {
			t.Fatalf("%s no args error = %v", name, err)
		}
		if err := fn([]string{"check"}, &out); err == nil || !strings.Contains(err.Error(), "usage: "+name) {
			t.Fatalf("%s wrong subcommand error = %v", name, err)
		}
		if err := fn([]string{"verify"}, &out); err == nil || !strings.Contains(err.Error(), "--archive is required") {
			t.Fatalf("%s missing flag error = %v", name, err)
		}
		if err := fn([]string{"verify", "--bogus"}, &out); err == nil {
			t.Fatalf("%s unknown flag accepted", name)
		}
		if err := fn([]string{"verify", "--archive", missing}, &out); err == nil {
			t.Fatalf("%s nonexistent archive verified", name)
		}
		if out.Len() != 0 {
			t.Fatalf("%s wrote output on failure: %q", name, out.String())
		}
	}
}
