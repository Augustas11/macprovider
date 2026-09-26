package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("stdout closed") }

// #1690 review LOW (B7 keygen): a keygen that fails after creating
// --out-dir leaves no partial key directory behind.
func TestTrustPoolKeygenFailureLeavesNoPartialDirectory(t *testing.T) {
	keys := filepath.Join(t.TempDir(), "keys")
	err := trustPoolAdmin([]string{"keygen", "--out-dir", keys,
		"--manifest-authority-key-id", "a-1", "--policy-signer-key-id", "p-1"}, os.Getenv, nil, failingWriter{})
	if err == nil {
		t.Fatal("keygen succeeded with a failing output writer")
	}
	if _, statErr := os.Lstat(keys); !os.IsNotExist(statErr) {
		t.Fatalf("failed keygen left %s behind (stat err=%v)", keys, statErr)
	}
}

// #1690 review LOW (B7 --prev): a successor chains to the --prev event's
// manifest_core_digest and version, so both must be the snapshot's last
// accepted policy core; a mismatch fails before anything is signed.
func TestTrustPoolSignManifestPrevMustMatchSnapshot(t *testing.T) {
	f := newSignFixture(t)
	var out bytes.Buffer
	genesis := filepath.Join(f.dir, "manifest-v1.json")
	notBefore := f.now.Add(-time.Minute).Truncate(time.Second)
	expiresAt := notBefore.Add(30 * 24 * time.Hour)
	if err := trustPoolAdmin(f.manifestArgs("m1-manifest-1", genesis, notBefore, expiresAt), os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-manifest genesis: %v", err)
	}
	prev := readSignedEvent(t, genesis)
	for _, tc := range []struct {
		name   string
		mutate func(e *trustpool.DurableEvent)
		want   string
	}{
		{name: "digest", mutate: func(e *trustpool.DurableEvent) { e.ManifestCoreDigest = strings.Repeat("0", 64) }, want: "manifest_core_digest does not match"},
		{name: "version", mutate: func(e *trustpool.DurableEvent) { e.ManifestVersion++ }, want: "manifest_version"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bad := prev
			tc.mutate(&bad)
			raw, err := json.Marshal(bad)
			if err != nil {
				t.Fatal(err)
			}
			badPath := filepath.Join(f.dir, "prev-bad-"+tc.name+".json")
			if err := os.WriteFile(badPath, raw, 0o644); err != nil {
				t.Fatal(err)
			}
			outPath := filepath.Join(f.dir, "successor-"+tc.name+".json")
			args := withoutFlag(f.manifestArgs("m1-manifest-2-"+tc.name, outPath, expiresAt, expiresAt.Add(30*24*time.Hour)), "--manifest-authority-key")
			args = append(args, "--prev", badPath)
			err = trustPoolAdmin(args, os.Getenv, nil, &out)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("mismatched --prev %s: err=%v, want %q", tc.name, err, tc.want)
			}
			if _, statErr := os.Lstat(outPath); !os.IsNotExist(statErr) {
				t.Fatalf("a successor was written for a mismatched --prev %s", tc.name)
			}
		})
	}
}

// #1690 review LOW (B7 key read): the owner-only checks and the read use
// one O_NOFOLLOW handle; a symlink or a non-regular file is refused.
func TestReadOwnerOnlyFileRefusesLinksAndSpecialFiles(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "key.pem")
	if err := os.WriteFile(key, []byte("k"), 0o600); err != nil {
		t.Fatal(err)
	}
	if raw, err := readOwnerOnlyFile(key, "--key"); err != nil || string(raw) != "k" {
		t.Fatalf("owner-only regular file: %q, %v", raw, err)
	}
	link := filepath.Join(dir, "link.pem")
	if err := os.Symlink(key, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readOwnerOnlyFile(link, "--key"); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("symlink: err=%v", err)
	}
	if _, err := readOwnerOnlyFile(dir, "--key"); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("directory: err=%v", err)
	}
}
