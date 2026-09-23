package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// SPEC-023-R010 A-side evidence: `.row-continuity-target` is an explicit,
// bounded, signature-verified list. It is never a walk of releases/.

func writeRowContinuityTarget(t *testing.T, root string, lines ...string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, ".row-continuity-target"), []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func rowContinuityReleaseLine(version, sha string) string {
	return "releases/" + version + "-" + strings.ToLower(sha[:16])
}

func TestLoadCompatibleAutotuneCatalogsLoadsSignedRowContinuityRelease(t *testing.T) {
	t.Parallel()
	pub, priv := mustRestampKey(t)
	current := mustParseRestampCatalog(t, restampCandidateFeed("published-current", "2026-09-23T00:00:00Z"), "test-key")
	bakedRaw := restampCandidateFeed("published-baked-v1", "2026-09-02T00:00:00Z")
	baked := mustParseRestampCatalog(t, bakedRaw, "test-key")
	root := t.TempDir()
	writeSignedRestampDir(t, root, baked, bakedRaw, "test-key", priv)
	writeRowContinuityTarget(t, root, "# fleet baked catalogs", rowContinuityReleaseLine(baked.Version, baked.SHA256))

	got, err := loadCompatibleAutotuneCatalogs(restampFeedConfig(root, pub, nil), current)
	if err != nil {
		t.Fatalf("loadCompatibleAutotuneCatalogs: %v", err)
	}
	if len(got) != 1 || got[0].Version != baked.Version || !got[0].RowContinuityOnly || got[0].SignerKeyID != "test-key" {
		t.Fatalf("row-continuity catalogs = %+v", got)
	}
}

func TestLoadRowContinuityAutotuneCatalogsSkipsUnsignedAndUntrusted(t *testing.T) {
	t.Parallel()
	pub, _ := mustRestampKey(t)
	_, otherPriv := mustRestampKey(t)
	current := mustParseRestampCatalog(t, restampCandidateFeed("published-current", "2026-09-23T00:00:00Z"), "test-key")
	untrustedRaw := restampCandidateFeed("published-untrusted-v1", "2026-09-02T00:00:00Z")
	untrusted := mustParseRestampCatalog(t, untrustedRaw, "test-key")
	root := t.TempDir()
	// Signed with a key the keyring does not trust under "test-key".
	writeSignedRestampDir(t, root, untrusted, untrustedRaw, "test-key", otherPriv)
	writeRowContinuityTarget(t, root,
		rowContinuityReleaseLine(untrusted.Version, untrusted.SHA256),
		"releases/published-missing-v1",
	)
	got, err := loadRowContinuityAutotuneCatalogs(restampFeedConfig(root, pub, nil), current, nil)
	if err != nil {
		t.Fatalf("loadRowContinuityAutotuneCatalogs: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("unverifiable row-continuity releases admitted: %+v", got)
	}
}

func TestLoadRowContinuityAutotuneCatalogsNeverWalksReleases(t *testing.T) {
	t.Parallel()
	pub, priv := mustRestampKey(t)
	current := mustParseRestampCatalog(t, restampCandidateFeed("published-current", "2026-09-23T00:00:00Z"), "test-key")
	unlistedRaw := restampCandidateFeed("published-unlisted-v1", "2026-09-02T00:00:00Z")
	unlisted := mustParseRestampCatalog(t, unlistedRaw, "test-key")
	root := t.TempDir()
	writeSignedRestampDir(t, root, unlisted, unlistedRaw, "test-key", priv)

	got, err := loadCompatibleAutotuneCatalogs(restampFeedConfig(root, pub, nil), current)
	if err != nil {
		t.Fatalf("loadCompatibleAutotuneCatalogs: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("an unlisted signed release under releases/ was loaded: %+v", got)
	}
}

func TestLoadRowContinuityAutotuneCatalogsOmitsTombstonedAndDuplicateVersions(t *testing.T) {
	t.Parallel()
	pub, priv := mustRestampKey(t)
	current := mustParseRestampCatalog(t, restampCandidateFeed("published-current", "2026-09-23T00:00:00Z"), "test-key")
	tombRaw := restampCandidateFeed("published-2026-07-07-p2-qwen3-8b", "2026-07-07T00:00:00Z")
	tomb := mustParseRestampCatalog(t, tombRaw, "test-key")
	previousRaw := restampCandidateFeed("published-previous-v1", "2026-09-20T00:00:00Z")
	previous := mustParseRestampCatalog(t, previousRaw, "test-key")
	sameAsCurrentRaw := restampCandidateFeed("published-current", "2026-09-22T00:00:00Z")
	sameAsCurrent := mustParseRestampCatalog(t, sameAsCurrentRaw, "test-key")
	root := t.TempDir()
	writeSignedRestampDir(t, root, tomb, tombRaw, "test-key", priv)
	writeSignedRestampDir(t, root, previous, previousRaw, "test-key", priv)
	writeSignedRestampDir(t, root, sameAsCurrent, sameAsCurrentRaw, "test-key", priv)
	// The tombstoned line names the bare release id so the target reader's
	// own tombstone filter applies; the loader re-checks the parsed version.
	writeRowContinuityTarget(t, root,
		rowContinuityReleaseLine(tomb.Version, tomb.SHA256),
		rowContinuityReleaseLine(previous.Version, previous.SHA256),
		rowContinuityReleaseLine(sameAsCurrent.Version, sameAsCurrent.SHA256),
	)
	got, err := loadRowContinuityAutotuneCatalogs(restampFeedConfig(root, pub, nil), current, nil)
	if err != nil {
		t.Fatalf("loadRowContinuityAutotuneCatalogs: %v", err)
	}
	if len(got) != 1 || got[0].Version != previous.Version {
		t.Fatalf("row-continuity catalogs = %+v, want only %s", got, previous.Version)
	}
	// Already retained by the previous-target window: that entry keeps its
	// "previous" admission and the row-continuity copy is dropped.
	got, err = loadRowContinuityAutotuneCatalogs(restampFeedConfig(root, pub, nil), current, got)
	if err != nil {
		t.Fatalf("loadRowContinuityAutotuneCatalogs(retained): %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("duplicate retained version reloaded as row continuity: %+v", got)
	}
}

func TestLoadRowContinuityAutotuneCatalogsRejectsOverCapAndBadLines(t *testing.T) {
	t.Parallel()
	pub, _ := mustRestampKey(t)
	current := mustParseRestampCatalog(t, restampCandidateFeed("published-current", "2026-09-23T00:00:00Z"), "test-key")
	for name, lines := range map[string][]string{
		"nine lines": {"releases/a", "releases/b", "releases/c", "releases/d", "releases/e", "releases/f", "releases/g", "releases/h", "releases/i"},
		"traversal":  {"releases/../current"},
		"dot":        {"releases/."},
		"dot-dot":    {"releases/.."},
		"absolute":   {"/etc/passwd"},
	} {
		lines := lines
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			writeRowContinuityTarget(t, root, lines...)
			if _, err := loadCompatibleAutotuneCatalogs(restampFeedConfig(root, pub, nil), current); err == nil {
				t.Fatalf("%s must fail closed", name)
			}
		})
	}
}
