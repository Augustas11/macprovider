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
		got.LaunchEnvironment != "candidate" || len(got.RootEventSHA256) != 64 || len(got.Manifests) != 2 || got.NewestManifestVersion != 2 {
		t.Fatalf("verification header = %+v", got)
	}
	first, second := got.Manifests[0], got.Manifests[1]
	if first.ManifestVersion != 1 || second.ManifestVersion != 2 || second.PrevManifestCoreHash != first.ManifestCoreDigest ||
		first.PrevManifestCoreHash != strings.Repeat("0", 64) || first.EventSHA256 == nil || second.EventSHA256 == nil {
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

// The newest event alone proves the whole contiguous history.
func TestTrustPoolVerifyManifestDerivesTheCompleteHistoryFromTheNewest(t *testing.T) {
	f := newSignFixture(t)
	root, v1, v2 := signVerifyChain(t, f)
	var out bytes.Buffer
	if err := trustPoolAdmin([]string{"verify-manifest", "--root", root, "--manifest", v2}, os.Getenv, nil, &out); err != nil {
		t.Fatalf("verify-manifest: %v", err)
	}
	var got trustPoolManifestVerification
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Manifests) != 2 || got.Manifests[0].EventSHA256 != nil || got.Manifests[1].EventSHA256 == nil {
		t.Fatalf("history from the newest event = %+v", got.Manifests)
	}
	// Supplying only an older event yields only its own history.
	out.Reset()
	if err := trustPoolAdmin([]string{"verify-manifest", "--root", root, "--manifest", v1}, os.Getenv, nil, &out); err != nil {
		t.Fatalf("verify-manifest v1: %v", err)
	}
	if err := json.Unmarshal(out.Bytes(), &got); err != nil || got.NewestManifestVersion != 1 || len(got.Manifests) != 1 {
		t.Fatalf("v1-only history = %+v (%v)", got, err)
	}
}

func TestTrustPoolVerifyManifestRejectsTamperedOrForeignEvents(t *testing.T) {
	f := newSignFixture(t)
	root, v1, v2 := signVerifyChain(t, f)
	other := newSignFixture(t)
	otherRoot, otherV1, _ := signVerifyChain(t, other)

	rewrite := func(path string, edit func([]byte) []byte) string {
		t.Helper()
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		out := filepath.Join(t.TempDir(), "edited.json")
		if err := os.WriteFile(out, edit(raw), 0o644); err != nil {
			t.Fatal(err)
		}
		return out
	}
	tamper := func(path, field, value string) string {
		return rewrite(path, func(raw []byte) []byte {
			var doc map[string]any
			if err := json.Unmarshal(raw, &doc); err != nil {
				t.Fatal(err)
			}
			doc[field] = value
			edited, _ := json.Marshal(doc)
			return edited
		})
	}
	duplicate := rewrite(v1, func(raw []byte) []byte {
		return bytes.Replace(raw, []byte(`"event_type":`), []byte(`"event_type":"manifest_accepted","event_type":`), 1)
	})
	trailing := rewrite(v1, func(raw []byte) []byte { return append(append([]byte{}, raw...), []byte(` {}`)...) })
	cases := map[string][]string{
		"core digest edited":     {"--root", root, "--manifest", tamper(v1, "manifest_core_digest", strings.Repeat("a", 64))},
		"foreign root":           {"--root", otherRoot, "--manifest", v1},
		"foreign chain manifest": {"--root", root, "--manifest", v2, "--manifest", otherV1},
		"duplicate version":      {"--root", root, "--manifest", v1, "--manifest", v1},
		"manifest as root":       {"--root", v1, "--manifest", v1},
		"root as manifest":       {"--root", root, "--manifest", root},
		"unknown field":          {"--root", root, "--manifest", tamper(v1, "injected_field", "x")},
		"duplicate key":          {"--root", root, "--manifest", duplicate},
		"trailing value":         {"--root", root, "--manifest", trailing},
		"no manifest":            {"--root", root},
	}
	for name, args := range cases {
		var out bytes.Buffer
		if err := trustPoolAdmin(append([]string{"verify-manifest"}, args...), os.Getenv, nil, &out); err == nil {
			t.Errorf("%s: verify-manifest accepted it", name)
		}
	}
}

func TestTrustPoolVerifyRouteSnapshotRecomputesGoldenDigests(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "spec015", "route_snapshot_golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Vectors []struct {
			ID                  string          `json:"id"`
			RouteSnapshot       json.RawMessage `json:"route_snapshot"`
			RouteSnapshotDigest string          `json:"route_snapshot_digest"`
		} `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	args := []string{"verify-route-snapshot"}
	for _, v := range doc.Vectors {
		path := filepath.Join(dir, v.ID+".json")
		if err := os.WriteFile(path, v.RouteSnapshot, 0o644); err != nil {
			t.Fatal(err)
		}
		args = append(args, "--snapshot", path)
	}
	var out bytes.Buffer
	if err := trustPoolAdmin(args, os.Getenv, nil, &out); err != nil {
		t.Fatalf("verify-route-snapshot: %v", err)
	}
	var got []struct {
		RouteSnapshotDigest string `json:"route_snapshot_digest"`
	}
	if err := json.Unmarshal(out.Bytes(), &got); err != nil || len(got) != len(doc.Vectors) {
		t.Fatalf("output = %s (%v)", out.String(), err)
	}
	for i, v := range doc.Vectors {
		if got[i].RouteSnapshotDigest != v.RouteSnapshotDigest {
			t.Errorf("%s digest = %s, want %s", v.ID, got[i].RouteSnapshotDigest, v.RouteSnapshotDigest)
		}
	}
	native := doc.Vectors[1].RouteSnapshot
	for name, edited := range map[string][]byte{
		"unknown field":  bytes.Replace(native, []byte(`{`), []byte(`{"injected":1,`), 1),
		"duplicate key":  bytes.Replace(native, []byte(`{`), []byte(`{"attempt_n":0,`), 1),
		"invalid source": bytes.Replace(native, []byte(`"pool_manifest"`), []byte(`"catalog_feed"`), 1),
		"trailing value": append(append([]byte{}, native...), []byte(` {}`)...),
	} {
		path := filepath.Join(dir, "bad.json")
		if err := os.WriteFile(path, edited, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := trustPoolAdmin([]string{"verify-route-snapshot", "--snapshot", path}, os.Getenv, nil, &out); err == nil {
			t.Errorf("%s: verify-route-snapshot accepted it", name)
		}
	}
}
