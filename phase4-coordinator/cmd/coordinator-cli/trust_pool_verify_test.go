package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// signVerifyChain signs a root registration, a genesis manifest carrying one
// pool model entry and one attested member, and a window-only successor.
func signVerifyChain(t *testing.T, f signFixture) (root, v1, v2 string) {
	t.Helper()
	var out bytes.Buffer
	root = filepath.Join(f.dir, "root.json")
	if err := trustPoolAdmin(f.rootArgs("verify-nonce-1", f.now.Add(time.Hour).Format(time.RFC3339Nano), root), os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-root: %v", err)
	}
	notBefore := f.now.Add(-time.Minute).Truncate(time.Second)
	expiresAt := notBefore.Add(time.Hour)
	models := writePoolModels(t, f, 360)
	v1 = filepath.Join(f.dir, "manifest-v1.json")
	if err := trustPoolAdmin(append(f.manifestArgs("verify-manifest-1", v1, notBefore, expiresAt), "--pool-models", models), os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-manifest v1: %v", err)
	}
	v2 = filepath.Join(f.dir, "manifest-v2.json")
	succ := withoutFlag(f.manifestArgs("verify-manifest-2", v2, expiresAt, expiresAt.Add(time.Hour)), "--manifest-authority-key")
	succ = append(succ, "--prev", v1, "--pool-models", models)
	if err := trustPoolAdmin(succ, os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-manifest v2: %v", err)
	}
	return root, v1, v2
}

func TestTrustPoolVerifyManifestPrintsVerifiedCores(t *testing.T) {
	f := newSignFixture(t)
	root, v1, v2 := signVerifyChain(t, f)
	var out bytes.Buffer
	if err := trustPoolAdmin([]string{"verify-manifest", "--root", root, "--manifest", v2, "--manifest", v1}, os.Getenv, nil, &out); err != nil {
		t.Fatalf("verify-manifest: %v", err)
	}
	var got trustPoolManifestVerification
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("decode output: %v", err)
	}
	if got.Schema != trustPoolManifestVerificationSchema || got.PoolID != f.poolID || got.CreatorAccountID != f.creator ||
		got.LaunchEnvironment != "candidate" || len(got.RootEventSHA256) != 64 || len(got.Manifests) != 2 {
		t.Fatalf("verification header = %+v", got)
	}
	first, second := got.Manifests[0], got.Manifests[1]
	if first.ManifestVersion != 1 || second.ManifestVersion != 2 || second.PrevManifestCoreHash != first.ManifestCoreDigest {
		t.Fatalf("chain = %+v / %+v", first, second)
	}
	if first.ManifestTermsDigest != second.ManifestTermsDigest || first.ManifestCoreDigest == second.ManifestCoreDigest {
		t.Fatal("a window-only successor keeps the terms digest under a new core")
	}
	if len(first.ModelEntries) != 1 || first.ModelEntries[0].PoolModelID != "pool/"+f.poolID+"/creator-gguf" ||
		first.ModelEntries[0].CompletionRatePerMtok != 360 || first.ModelEntries[0].ArtifactHash != signModelsGGUFHash {
		t.Fatalf("model entries = %+v", first.ModelEntries)
	}
	if len(first.AttestedMembers) != 1 || first.AttestedMembers[0].ProviderAccountID != "acct-member-1" {
		t.Fatalf("attested members = %+v", first.AttestedMembers)
	}
	if first.SettlementMode != "enforce" || first.Encoding != 2 || first.NotBeforeUnix == 0 || second.NotBeforeUnix != first.ExpiresAtUnix {
		t.Fatalf("core fields = %+v", first)
	}
}

func TestTrustPoolVerifyManifestRejectsTamperedOrForeignEvents(t *testing.T) {
	f := newSignFixture(t)
	root, v1, v2 := signVerifyChain(t, f)
	other := newSignFixture(t)
	otherRoot, otherV1, _ := signVerifyChain(t, other)

	tamper := func(path, field, value string) string {
		t.Helper()
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var doc map[string]any
		if err := json.Unmarshal(raw, &doc); err != nil {
			t.Fatal(err)
		}
		doc[field] = value
		edited, _ := json.Marshal(doc)
		out := filepath.Join(t.TempDir(), "tampered.json")
		if err := os.WriteFile(out, edited, 0o644); err != nil {
			t.Fatal(err)
		}
		return out
	}
	cases := map[string][]string{
		"core digest edited":     {"--root", root, "--manifest", tamper(v1, "manifest_core_digest", strings.Repeat("a", 64))},
		"foreign root":           {"--root", otherRoot, "--manifest", v1},
		"foreign chain manifest": {"--root", root, "--manifest", v2, "--manifest", otherV1},
		"duplicate version":      {"--root", root, "--manifest", v1, "--manifest", v1},
		"manifest as root":       {"--root", v1, "--manifest", v1},
		"root as manifest":       {"--root", root, "--manifest", root},
		"unknown field":          {"--root", root, "--manifest", tamper(v1, "injected_field", "x")},
		"no manifest":            {"--root", root},
	}
	for name, args := range cases {
		var out bytes.Buffer
		if err := trustPoolAdmin(append([]string{"verify-manifest"}, args...), os.Getenv, nil, &out); err == nil {
			t.Errorf("%s: verify-manifest accepted it", name)
		}
	}
}
