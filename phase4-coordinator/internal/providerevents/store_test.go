package providerevents

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func openTestStore(t *testing.T) *SQLiteStore {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	store, err := NewSQLiteStore(db)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	return store
}

func TestNormalizeFailureReasonTaxonomy(t *testing.T) {
	cases := map[string]string{
		"invalid_token":                         ReasonInvalidToken,
		"invalid_token: stale":                  ReasonInvalidToken,
		"version_unsupported: binary_version x": ReasonVersionUnsupported,
		"no_common_aead_suite":                  ReasonNoCommonAEADSuite,
		"tier2 attestation failed":              ReasonTier2AttestationFailed,
		"warmup_failed":                         ReasonWarmupFailed,
		"provider inactive past threshold":      ReasonHeartbeatStale,
		"provider websocket disconnected":       ReasonProviderWebsocketDisconnected,
		"unrecognized auth message":             ReasonUnrecognizedAuthMessage,
		"invalid_hello: read":                   ReasonInvalidAuthRequest,
		"too_many_unauthenticated_connections":  ReasonPoolFull,
		"too_many_auth_attempts":                ReasonPoolFull,
		"credential_bootstrap_outstanding_full": ReasonPoolFull,
		"Bearer mpk_secret_value exploded":      ReasonOther,
	}
	for in, want := range cases {
		if got := NormalizeFailureReason(in); got != want {
			t.Fatalf("NormalizeFailureReason(%q)=%q want %q", in, got, want)
		}
	}
}

func TestRedactDiagnosticStripsSecretsAndBounds(t *testing.T) {
	raw := "Authorization: Bearer mpk_abc123DEF and more text that should be clipped eventually because it is long"
	got := RedactDiagnostic(raw, 40)
	if containsAny(got, "mpk_", "Bearer mpk", "Authorization: Bearer", "opaque") {
		t.Fatalf("secret leaked in %q", got)
	}
	opaque := RedactDiagnostic("Authorization: Bearer opaque-secret-value trailing", 120)
	if containsAny(opaque, "opaque-secret", "Bearer opaque") {
		t.Fatalf("opaque bearer leaked: %q", opaque)
	}
	hyphen := RedactDiagnostic("token=mpk_alpha-beta-gamma leftover", 80)
	if strings.Contains(hyphen, "beta") || strings.Contains(hyphen, "mpk_") {
		t.Fatalf("hyphenated mpk fragment leaked: %q", hyphen)
	}
	hex := strings.Repeat("ab", 32)
	gotHex := RedactDiagnostic("raw "+hex+" tail", 80)
	if strings.Contains(gotHex, hex) {
		t.Fatalf("64-hex token leaked: %q", gotHex)
	}
	urlCredential := RedactDiagnostic("dial wss://user:password@host.example/private/path?api_key=secret#fragment failed", 120)
	if containsAny(urlCredential, "user:password", "/private", "api_key", "secret", "fragment") {
		t.Fatalf("URL credential leaked: %q", urlCredential)
	}
	path := RedactDiagnostic("open /Users/alice/.macprovider/config.yaml failed", 120)
	if containsAny(path, "/Users/alice", "config.yaml") {
		t.Fatalf("local path leaked: %q", path)
	}
	if len([]rune(got)) > 40 {
		t.Fatalf("length %d exceeds bound", len([]rune(got)))
	}
}

func TestRecordRetentionAndPerProviderCap(t *testing.T) {
	store := openTestStore(t)
	store.retention = time.Hour
	store.perProviderCap = 3
	fixed := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	store.now = func() time.Time { return fixed }

	ctx := context.Background()
	old := Event{
		ProviderID:    "p1",
		Kind:          KindAuthRejected,
		Outcome:       OutcomeFailure,
		FailureReason: ReasonInvalidToken,
		OccurredAt:    fixed.Add(-2 * time.Hour),
		Diagnostic:    "Bearer mpk_should_not_persist",
	}
	if err := store.Record(ctx, old); err != nil {
		t.Fatalf("record old: %v", err)
	}
	for i := 0; i < 5; i++ {
		if err := store.Record(ctx, Event{
			ProviderID:    "p1",
			Kind:          KindAuthRejected,
			Outcome:       OutcomeFailure,
			FailureReason: ReasonInvalidToken,
			OccurredAt:    fixed.Add(-time.Duration(i) * time.Minute),
			Diagnostic:    "ok",
		}); err != nil {
			t.Fatalf("record %d: %v", i, err)
		}
	}
	if err := store.ReconcileBounds(ctx); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	events, err := store.ListEvents(ctx, "p1", 50)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(events) != 3 {
		t.Fatalf("per-provider cap not enforced: got %d want 3", len(events))
	}
	for _, ev := range events {
		if containsAny(ev.Diagnostic, "mpk_", "Bearer ") {
			t.Fatalf("persisted secret diagnostic: %#v", ev)
		}
		if ev.FailureReason != ReasonInvalidToken {
			t.Fatalf("failure_reason=%q", ev.FailureReason)
		}
	}
}

func TestAnonymousBucketCapped(t *testing.T) {
	store := openTestStore(t)
	store.anonymousCap = 2
	store.globalCap = 100
	ctx := context.Background()
	for i := 0; i < 5; i++ {
		if err := store.Record(ctx, Event{
			Kind:          KindUpgradeFailed,
			Outcome:       OutcomeFailure,
			FailureReason: ReasonUpgradeFailed,
		}); err != nil {
			t.Fatalf("record: %v", err)
		}
	}
	events, err := store.ListEvents(ctx, AnonymousProviderID, 50)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(events) != 2 {
		t.Fatalf("anonymous cap got %d want 2", len(events))
	}
}

func TestRejectCredentialShapedIdentifiers(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	err := store.Record(ctx, Event{
		ProviderID:    "mpk_should_reject",
		Kind:          KindAuthRejected,
		Outcome:       OutcomeFailure,
		FailureReason: ReasonInvalidToken,
	})
	if err == nil {
		t.Fatal("expected credential-shaped provider_id rejection")
	}
}

func TestFixedWidthOrderingNearFractionalBoundary(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	a := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	b := time.Date(2026, 7, 22, 12, 0, 0, 500000000, time.UTC)
	if err := store.Record(ctx, Event{
		ProviderID: "p1", Kind: KindDisconnect, Outcome: OutcomeFailure,
		FailureReason: ReasonProviderWebsocketDisconnected, OccurredAt: a,
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.Record(ctx, Event{
		ProviderID: "p1", Kind: KindAuthRejected, Outcome: OutcomeFailure,
		FailureReason: ReasonInvalidToken, OccurredAt: b,
	}); err != nil {
		t.Fatal(err)
	}
	events, err := store.ListEvents(ctx, "p1", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 || events[0].Kind != KindAuthRejected {
		t.Fatalf("ordering wrong: %#v", events)
	}
}

func TestListLastKnownOpaqueCursorStableAcrossSeenUpdate(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	t1 := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	t2 := t1.Add(time.Second)
	for i, id := range []string{"a", "b", "c"} {
		seen := t1
		if i == 0 {
			seen = t2
		}
		if err := store.UpsertLastKnown(ctx, LastKnown{ProviderID: id, LastSeenAt: seen}); err != nil {
			t.Fatal(err)
		}
	}
	page1, err := store.ListLastKnown(ctx, 2, "", "")
	if err != nil || len(page1) != 2 {
		t.Fatalf("page1=%v err=%v", page1, err)
	}
	cursorID := page1[1].ProviderID
	cursorSeen := FormatFixedUTC(page1[1].LastSeenAt)
	// Mutate the cursor row's last_seen after page1; opaque cursor must not reshuffle.
	if err := store.UpsertLastKnown(ctx, LastKnown{ProviderID: cursorID, LastSeenAt: t2.Add(time.Minute)}); err != nil {
		t.Fatal(err)
	}
	page2, err := store.ListLastKnown(ctx, 2, cursorSeen, cursorID)
	if err != nil {
		t.Fatal(err)
	}
	for _, snap := range page2 {
		if snap.ProviderID == page1[0].ProviderID {
			t.Fatalf("duplicated %q across pages", snap.ProviderID)
		}
	}
}

func TestLastKnownOfflineRepresentation(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	seen := time.Date(2026, 7, 22, 11, 0, 0, 0, time.UTC)
	hb := seen.Add(-time.Minute)
	if err := store.UpsertLastKnown(ctx, LastKnown{
		ProviderID:      "augustass-macbook-air",
		AssignedID:      "asg-1",
		BinaryVersion:   "1.8.57",
		ModelID:         "qwen",
		State:           "unavailable",
		AuthState:       "bearer_validated",
		LastHeartbeatAt: &hb,
		LastSeenAt:      seen,
		RoutingEligible: false,
	}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if err := store.Record(ctx, Event{
		ProviderID:    "augustass-macbook-air",
		Kind:          KindDisconnect,
		Outcome:       OutcomeFailure,
		FailureReason: ReasonProviderWebsocketDisconnected,
		SessionID:     "asg-1",
	}); err != nil {
		t.Fatalf("record disconnect: %v", err)
	}
	snap, ok, err := store.GetLastKnown(ctx, "augustass-macbook-air")
	if err != nil || !ok {
		t.Fatalf("get last known: ok=%v err=%v", ok, err)
	}
	if snap.BinaryVersion != "1.8.57" || snap.ModelID != "qwen" {
		t.Fatalf("last known incomplete: %#v", snap)
	}
	events, err := store.ListEvents(ctx, "augustass-macbook-air", 10)
	if err != nil || len(events) == 0 {
		t.Fatalf("events missing: len=%d err=%v", len(events), err)
	}
}

func TestLastKnownStoresRedactedDiagnosticStatus(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	seen := time.Date(2026, 7, 22, 11, 0, 0, 0, time.UTC)
	diagAt := seen.Add(-time.Second)
	if err := store.UpsertLastKnown(ctx, LastKnown{
		ProviderID:    "augustass-macbook-air",
		AssignedID:    "asg-1",
		BinaryVersion: "1.8.65",
		ModelID:       "qwen",
		ModelLoaded:   true,
		ModelHash:     strings.Repeat("a", 64),
		State:         "ready",
		LastSeenAt:    seen,
		Diagnostic:    "network_offline: Authorization: Bearer mpk_should_redact wss://user:password@host/private?api_key=secret /Users/alice/config.yaml",
		DiagnosticAt:  &diagAt,
	}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	snap, ok, err := store.GetLastKnown(ctx, "augustass-macbook-air")
	if err != nil || !ok {
		t.Fatalf("get: ok=%v err=%v", ok, err)
	}
	if !snap.ModelLoaded || snap.ModelHash != strings.Repeat("a", 64) {
		t.Fatalf("diagnostic identity missing: %#v", snap)
	}
	if snap.DiagnosticAt == nil || !snap.DiagnosticAt.Equal(diagAt) {
		t.Fatalf("diagnostic_at=%v want %v", snap.DiagnosticAt, diagAt)
	}
	if containsAny(snap.Diagnostic, "mpk_", "Bearer mpk", "user:password", "api_key", "/Users/alice") {
		t.Fatalf("diagnostic leaked secret: %q", snap.Diagnostic)
	}
}

func TestLastKnownClassificationScalarsRoundTrip(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	seen := time.Date(2026, 8, 27, 3, 0, 0, 0, time.UTC)
	if err := store.UpsertLastKnown(ctx, LastKnown{
		ProviderID:               "augustass-macbook-air",
		AssignedID:               "asg-1",
		LastSeenAt:               seen,
		Hostname:                 "augustass-macbook-air.local",
		Tier:                     "trusted",
		HashStatus:               "hash_verified",
		AttestationStatus:        "attested",
		AttestationTier:          "hardware",
		EncryptedLeg:             true,
		CatalogAdmissionMode:     "strict",
		BenchmarkQuarantined:     true,
		AdmissionCeilingExcluded: true,
		AdmissionEvidenceStale:   true,
		AdmissionSandboxed:       true,
	}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	snap, ok, err := store.GetLastKnown(ctx, "augustass-macbook-air")
	if err != nil || !ok {
		t.Fatalf("get: ok=%v err=%v", ok, err)
	}
	if snap.Hostname != "augustass-macbook-air.local" || snap.Tier != "trusted" {
		t.Fatalf("hostname/tier round-trip failed: %#v", snap)
	}
	if snap.HashStatus != "hash_verified" || snap.AttestationStatus != "attested" || snap.AttestationTier != "hardware" {
		t.Fatalf("hash/attestation round-trip failed: %#v", snap)
	}
	if snap.CatalogAdmissionMode != "strict" {
		t.Fatalf("catalog_admission_mode round-trip failed: %#v", snap)
	}
	if !snap.EncryptedLeg || !snap.BenchmarkQuarantined || !snap.AdmissionCeilingExcluded ||
		!snap.AdmissionEvidenceStale || !snap.AdmissionSandboxed {
		t.Fatalf("bool classification flags round-trip failed: %#v", snap)
	}

	// Older snapshot must not clobber a fresher non-empty classification.
	older := seen.Add(-time.Hour)
	if err := store.UpsertLastKnown(ctx, LastKnown{
		ProviderID: "augustass-macbook-air",
		AssignedID: "asg-1",
		LastSeenAt: older,
		Tier:       "provisional",
	}); err != nil {
		t.Fatalf("stale upsert: %v", err)
	}
	snap, ok, err = store.GetLastKnown(ctx, "augustass-macbook-air")
	if err != nil || !ok {
		t.Fatalf("get after stale: ok=%v err=%v", ok, err)
	}
	if snap.Tier != "trusted" {
		t.Fatalf("stale upsert clobbered tier: %q", snap.Tier)
	}
}

func TestMigrateAddsClassificationColumnsBackCompat(t *testing.T) {
	ctx := context.Background()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "legacy.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	// Simulate a pre-classification schema: original columns only, plus a row.
	if _, err := db.ExecContext(ctx, `
CREATE TABLE provider_last_known (
	provider_id TEXT PRIMARY KEY,
	assigned_id TEXT NOT NULL DEFAULT '',
	binary_version TEXT NOT NULL DEFAULT '',
	model_id TEXT NOT NULL DEFAULT '',
	model_loaded INTEGER NOT NULL DEFAULT 0,
	model_hash TEXT NOT NULL DEFAULT '',
	state TEXT NOT NULL DEFAULT '',
	auth_state TEXT NOT NULL DEFAULT '',
	connected_at_utc TEXT NOT NULL DEFAULT '',
	last_heartbeat_at_utc TEXT NOT NULL DEFAULT '',
	last_activity_at_utc TEXT NOT NULL DEFAULT '',
	last_seen_at_utc TEXT NOT NULL,
	routing_eligible INTEGER NOT NULL DEFAULT 0,
	diagnostic TEXT NOT NULL DEFAULT '',
	diagnostic_at_utc TEXT NOT NULL DEFAULT ''
)`); err != nil {
		t.Fatalf("create legacy table: %v", err)
	}
	if _, err := db.ExecContext(ctx, `
INSERT INTO provider_last_known (provider_id, binary_version, last_seen_at_utc)
VALUES ('legacy-mac', '1.8.57', '2026-08-27T00:00:00.000000000Z')`); err != nil {
		t.Fatalf("insert legacy row: %v", err)
	}

	// Opening the store must run the backward-compatible ALTERs, not error.
	store, err := NewSQLiteStore(db)
	if err != nil {
		t.Fatalf("migrate legacy db: %v", err)
	}

	// New columns must exist.
	cols := map[string]bool{}
	rows, err := db.QueryContext(ctx, `PRAGMA table_info(provider_last_known)`)
	if err != nil {
		t.Fatalf("table_info: %v", err)
	}
	for rows.Next() {
		var (
			cid         int
			name, ctype string
			notnull, pk int
			dflt        sql.NullString
		)
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			rows.Close()
			t.Fatalf("scan table_info: %v", err)
		}
		cols[name] = true
	}
	rows.Close()
	for _, want := range []string{
		"hostname", "tier", "hash_status", "attestation_status", "attestation_tier",
		"encrypted_leg", "catalog_admission_mode", "benchmark_quarantined",
		"admission_ceiling_excluded", "admission_evidence_stale", "admission_sandboxed",
	} {
		if !cols[want] {
			t.Fatalf("migration did not add column %q", want)
		}
	}

	// Legacy row must read back with zero-value classification defaults.
	snap, ok, err := store.GetLastKnown(ctx, "legacy-mac")
	if err != nil || !ok {
		t.Fatalf("get legacy row: ok=%v err=%v", ok, err)
	}
	if snap.BinaryVersion != "1.8.57" {
		t.Fatalf("legacy row lost binary_version: %#v", snap)
	}
	if snap.Tier != "" || snap.Hostname != "" || snap.EncryptedLeg || snap.BenchmarkQuarantined {
		t.Fatalf("legacy row did not default cleanly: %#v", snap)
	}

	// A subsequent upsert must persist the new fields on the migrated table.
	if err := store.UpsertLastKnown(ctx, LastKnown{
		ProviderID: "legacy-mac",
		LastSeenAt: time.Date(2026, 8, 27, 4, 0, 0, 0, time.UTC),
		Tier:       "trusted",
		HashStatus: "hash_verified",
	}); err != nil {
		t.Fatalf("upsert after migration: %v", err)
	}
	snap, _, err = store.GetLastKnown(ctx, "legacy-mac")
	if err != nil {
		t.Fatalf("get after migration upsert: %v", err)
	}
	if snap.Tier != "trusted" || snap.HashStatus != "hash_verified" {
		t.Fatalf("post-migration upsert not persisted: %#v", snap)
	}
}

func containsAny(s string, parts ...string) bool {
	for _, p := range parts {
		if p != "" && strings.Contains(s, p) {
			return true
		}
	}
	return false
}
