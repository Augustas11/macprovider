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

func containsAny(s string, parts ...string) bool {
	for _, p := range parts {
		if p != "" && strings.Contains(s, p) {
			return true
		}
	}
	return false
}
