package providerevents

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDefaultDBPathAndOpen(t *testing.T) {
	if got := DefaultDBPath("/var/lib/x/coord.db"); got != filepath.Join("/var/lib/x", "provider_connection_events.db") {
		t.Fatalf("DefaultDBPath sibling = %q", got)
	}
	if got := DefaultDBPath("coord.db"); got != "provider_connection_events.db" {
		t.Fatalf("DefaultDBPath bare = %q", got)
	}
	if _, err := Open("   "); err == nil {
		t.Fatal("Open with blank path must fail")
	}
	if _, err := NewSQLiteStore(nil); err == nil {
		t.Fatal("NewSQLiteStore(nil) must fail")
	}
	path := filepath.Join(t.TempDir(), "ev.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	ctx := context.Background()
	if err := s.Record(ctx, Event{ProviderID: "p", Kind: KindAuthAccepted, Outcome: OutcomeSuccess}); err != nil {
		t.Fatalf("record: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	s2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer s2.Close()
	evs, err := s2.ListEvents(ctx, "p", 10)
	if err != nil || len(evs) != 1 {
		t.Fatalf("durable events = %v, %v", evs, err)
	}
}

func TestSanitizeEventRules(t *testing.T) {
	now := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	ev, err := sanitizeEvent(Event{Kind: KindDisconnect}, now)
	if err != nil {
		t.Fatal(err)
	}
	if ev.ProviderID != AnonymousProviderID || ev.Outcome != OutcomeFailure ||
		ev.FailureReason != ReasonOther || !ev.OccurredAt.Equal(now) {
		t.Fatalf("defaults wrong: %#v", ev)
	}
	ev, err = sanitizeEvent(Event{ProviderID: "p", Kind: KindAuthAccepted, Outcome: OutcomeSuccess, FailureReason: "invalid_token"}, now)
	if err != nil || ev.FailureReason != "" {
		t.Fatalf("success must clear failure reason: %#v %v", ev, err)
	}
	ev, err = sanitizeEvent(Event{ProviderID: "p", Kind: KindDisconnect, CloseReason: "free text Bearer abc", FailureReason: "warmup_failed: x"}, now)
	if err != nil || ev.CloseReason != ReasonOther || ev.FailureReason != ReasonWarmupFailed {
		t.Fatalf("close reason must be normalised: %#v %v", ev, err)
	}
	for name, bad := range map[string]Event{
		"kind":    {Kind: "bogus"},
		"outcome": {Kind: KindDisconnect, Outcome: "maybe"},
		"session": {Kind: KindDisconnect, SessionID: "mpk_secret"},
		"attempt": {Kind: KindDisconnect, AttemptID: "Bearer x"},
	} {
		if _, err := sanitizeEvent(bad, now); err == nil {
			t.Fatalf("%s: expected rejection", name)
		}
	}
}

func TestRecordEventsLatestAndOrdering(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	base := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	store.now = func() time.Time { return base }
	for i, reason := range []string{"warmup_failed", "invalid_token"} {
		if err := store.Record(ctx, Event{ProviderID: "p1", Kind: KindAuthRejected, FailureReason: reason,
			OccurredAt: base.Add(time.Duration(i) * time.Minute), CloseCode: 4001 + i}); err != nil {
			t.Fatal(err)
		}
	}
	ev, ok, err := store.LatestEventProvider(ctx, " p1 ")
	if err != nil || !ok || ev.FailureReason != ReasonInvalidToken || ev.CloseCode != 4002 {
		t.Fatalf("latest = %#v ok=%v err=%v", ev, ok, err)
	}
	if _, ok, _ := store.LatestEventProvider(ctx, "nobody"); ok {
		t.Fatal("unknown provider must report not found")
	}
	if _, ok, _ := store.LatestEventProvider(ctx, AnonymousProviderID); ok {
		t.Fatal("anonymous bucket must not be reported")
	}
	if _, ok, _ := store.LatestEventProvider(ctx, ""); ok {
		t.Fatal("blank provider must not be found")
	}
	evs, err := store.ListEvents(ctx, "p1", 1)
	if err != nil || len(evs) != 1 || evs[0].FailureReason != ReasonInvalidToken {
		t.Fatalf("limit/order: %#v %v", evs, err)
	}
	if _, err := store.ListEvents(ctx, "  ", 5); err == nil {
		t.Fatal("blank provider must error")
	}
}

func TestPruneAndReconcileDropOldRowsAndCapLastKnown(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	store.now = func() time.Time { return now }
	store.retention = time.Hour
	store.lastKnownCap = 2
	store.globalCap = 3

	for i, age := range []time.Duration{3 * time.Hour, 10 * time.Minute} {
		pid := []string{"old", "new"}[i]
		if err := store.Record(ctx, Event{ProviderID: pid, Kind: KindDisconnect, OccurredAt: now.Add(-age)}); err != nil {
			t.Fatal(err)
		}
	}
	for i, pid := range []string{"a", "b", "c", "d"} {
		if err := store.UpsertLastKnown(ctx, LastKnown{ProviderID: pid, LastSeenAt: now.Add(-time.Duration(i) * time.Minute)}); err != nil {
			t.Fatal(err)
		}
	}
	n, err := store.Prune(ctx, now.Add(-time.Hour))
	if err != nil || n != 1 {
		t.Fatalf("prune removed %d err=%v", n, err)
	}
	if err := store.ReconcileBounds(ctx); err != nil {
		t.Fatal(err)
	}
	// Newest two last-known rows survive the cap.
	list, err := store.ListLastKnown(ctx, 0, "", "")
	if err != nil || len(list) != 2 || list[0].ProviderID != "a" || list[1].ProviderID != "b" {
		t.Fatalf("last-known cap: %#v %v", list, err)
	}
	if evs, _ := store.ListEvents(ctx, "old", 10); len(evs) != 0 {
		t.Fatalf("old event survived: %#v", evs)
	}
	if evs, _ := store.ListEvents(ctx, "new", 10); len(evs) != 1 {
		t.Fatalf("new event lost: %#v", evs)
	}
	// Pruning last-known by age.
	if n, err := store.Prune(ctx, now.Add(-30*time.Second)); err != nil || n != 1 {
		t.Fatalf("second prune n=%d err=%v", n, err)
	}
	if _, ok, _ := store.GetLastKnown(ctx, "b"); ok {
		t.Fatal("stale last-known row must be pruned")
	}
	if _, ok, _ := store.GetLastKnown(ctx, "a"); !ok {
		t.Fatal("fresh last-known row must remain")
	}
}

func TestGlobalCapKeepsNewest(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	store.globalCap = 2
	base := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	store.now = func() time.Time { return base }
	for i, pid := range []string{"a", "b", "c"} {
		if err := store.Record(ctx, Event{ProviderID: pid, Kind: KindDisconnect, OccurredAt: base.Add(time.Duration(i) * time.Second)}); err != nil {
			t.Fatal(err)
		}
	}
	if evs, _ := store.ListEvents(ctx, "a", 5); len(evs) != 0 {
		t.Fatalf("oldest must be evicted: %#v", evs)
	}
	for _, pid := range []string{"b", "c"} {
		if evs, _ := store.ListEvents(ctx, pid, 5); len(evs) != 1 {
			t.Fatalf("%s evicted", pid)
		}
	}
}

func TestUpsertLastKnownMergeSemantics(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	t1 := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	t2 := t1.Add(time.Minute)
	conn := t1.Add(-time.Hour)
	first := LastKnown{ProviderID: "p", AssignedID: "asg", BinaryVersion: "1.0", ModelID: "m1", ModelLoaded: true,
		ModelHash: strings.ToUpper(strings.Repeat("ab", 32)), State: "ready", AuthState: "ok", ConnectedAt: &conn,
		LastSeenAt: t2, RoutingEligible: true, Diagnostic: "diag1", Hostname: "h", EncryptedLeg: true}
	if err := store.UpsertLastKnown(ctx, first); err != nil {
		t.Fatal(err)
	}
	got, ok, err := store.GetLastKnown(ctx, "p")
	if err != nil || !ok {
		t.Fatalf("get: %v %v", ok, err)
	}
	if got.ModelHash != strings.Repeat("ab", 32) || got.ConnectedAt == nil || !got.ConnectedAt.Equal(conn) {
		t.Fatalf("hash/connected not normalised: %#v", got)
	}
	// Newer update with empty text fields keeps old text but takes bools.
	if err := store.UpsertLastKnown(ctx, LastKnown{ProviderID: "p", LastSeenAt: t2.Add(time.Minute)}); err != nil {
		t.Fatal(err)
	}
	got, _, _ = store.GetLastKnown(ctx, "p")
	if got.AssignedID != "asg" || got.State != "ready" || got.ModelID != "m1" || got.Diagnostic != "diag1" || got.Hostname != "h" {
		t.Fatalf("empty fields must not clobber: %#v", got)
	}
	if got.RoutingEligible || got.ModelLoaded || got.EncryptedLeg {
		t.Fatalf("newer snapshot must overwrite bool flags: %#v", got)
	}
	if !got.LastSeenAt.Equal(t2.Add(time.Minute)) {
		t.Fatalf("last_seen = %v", got.LastSeenAt)
	}
	// Stale (older) update changes nothing.
	if err := store.UpsertLastKnown(ctx, LastKnown{ProviderID: "p", State: "stale", ModelID: "m0", RoutingEligible: true, LastSeenAt: t1}); err != nil {
		t.Fatal(err)
	}
	after, _, _ := store.GetLastKnown(ctx, "p")
	if after.State != "ready" || after.ModelID != "m1" || after.RoutingEligible || !after.LastSeenAt.Equal(t2.Add(time.Minute)) {
		t.Fatalf("stale update applied: %#v", after)
	}
	// Defaults LastSeenAt to now when zero.
	store.now = func() time.Time { return t2.Add(time.Hour) }
	if err := store.UpsertLastKnown(ctx, LastKnown{ProviderID: "q"}); err != nil {
		t.Fatal(err)
	}
	q, _, _ := store.GetLastKnown(ctx, "q")
	if !q.LastSeenAt.Equal(t2.Add(time.Hour)) {
		t.Fatalf("default last seen = %v", q.LastSeenAt)
	}
	for name, bad := range map[string]LastKnown{
		"blank":     {ProviderID: " "},
		"anonymous": {ProviderID: AnonymousProviderID},
		"cred":      {ProviderID: "mpk_zzz"},
		"assigned":  {ProviderID: "p", AssignedID: "Bearer x"},
	} {
		if err := store.UpsertLastKnown(ctx, bad); err == nil {
			t.Fatalf("%s must be rejected", name)
		}
	}
	if _, ok, err := store.GetLastKnown(ctx, "  "); ok || err != nil {
		t.Fatalf("blank get = %v %v", ok, err)
	}
	if _, ok, err := store.GetLastKnown(ctx, "missing"); ok || err != nil {
		t.Fatalf("missing get = %v %v", ok, err)
	}
}

func TestListLastKnownPagination(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	base := time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC)
	// b and c tie on last_seen; ties order by provider_id ascending.
	for pid, off := range map[string]int{"a": 3, "b": 2, "c": 2, "d": 1} {
		if err := store.UpsertLastKnown(ctx, LastKnown{ProviderID: pid, LastSeenAt: base.Add(time.Duration(off) * time.Minute)}); err != nil {
			t.Fatal(err)
		}
	}
	page1, err := store.ListLastKnown(ctx, 2, "", "")
	if err != nil || len(page1) != 2 || page1[0].ProviderID != "a" || page1[1].ProviderID != "b" {
		t.Fatalf("page1 = %#v %v", page1, err)
	}
	page2, err := store.ListLastKnown(ctx, 10, FormatFixedUTC(page1[1].LastSeenAt), "b")
	if err != nil || len(page2) != 2 || page2[0].ProviderID != "c" || page2[1].ProviderID != "d" {
		t.Fatalf("page2 = %#v %v", page2, err)
	}
	// Negative limit falls back to the default page cap (all rows).
	all, err := store.ListLastKnown(ctx, -1, "", "")
	if err != nil || len(all) != 4 {
		t.Fatalf("default limit = %d %v", len(all), err)
	}
}

func TestLegacyTimestampsAndCorruptRows(t *testing.T) {
	store := openTestStore(t)
	ctx := context.Background()
	legacy := "2026-07-22T12:00:00.123456789+02:00"
	if _, err := store.db.Exec(`INSERT INTO provider_connection_events
		(provider_id, session_id, attempt_id, occurred_at_utc, kind, outcome, failure_reason, auth_stage, message_family, binary_version, close_code, close_reason, diagnostic)
		VALUES ('p','','',?,?,?,'','','','',0,'','')`, legacy, KindDisconnect, OutcomeSuccess); err != nil {
		t.Fatal(err)
	}
	ev, ok, err := store.LatestEventProvider(ctx, "p")
	if err != nil || !ok {
		t.Fatalf("legacy row: %v %v", ok, err)
	}
	want := time.Date(2026, 7, 22, 10, 0, 0, 123456789, time.UTC)
	if !ev.OccurredAt.Equal(want) || ev.OccurredAt.Location() != time.UTC {
		t.Fatalf("legacy parse = %v want %v", ev.OccurredAt, want)
	}
	if _, err := store.db.Exec(`UPDATE provider_connection_events SET occurred_at_utc='garbage'`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ListEvents(ctx, "p", 5); err == nil {
		t.Fatal("corrupt event timestamp must error")
	}
	if _, _, err := store.LatestEventProvider(ctx, "p"); err == nil {
		t.Fatal("corrupt latest timestamp must error")
	}

	if err := store.UpsertLastKnown(ctx, LastKnown{ProviderID: "k", LastSeenAt: want}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE provider_last_known SET last_seen_at_utc=?`, legacy); err != nil {
		t.Fatal(err)
	}
	k, ok, err := store.GetLastKnown(ctx, "k")
	if err != nil || !ok || !k.LastSeenAt.Equal(want) {
		t.Fatalf("legacy last_seen = %v %v %v", k.LastSeenAt, ok, err)
	}
	for _, col := range []string{"connected_at_utc", "last_heartbeat_at_utc", "last_activity_at_utc", "diagnostic_at_utc", "last_seen_at_utc"} {
		if _, err := store.db.Exec(`UPDATE provider_last_known SET last_seen_at_utc=?, `+col+`='nope'`, FormatFixedUTC(want)); err != nil {
			t.Fatal(err)
		}
		if _, _, err := store.GetLastKnown(ctx, "k"); err == nil {
			t.Fatalf("corrupt %s must error", col)
		}
		if _, err := store.ListLastKnown(ctx, 5, "", ""); err == nil {
			t.Fatalf("list with corrupt %s must error", col)
		}
		if _, err := store.db.Exec(`UPDATE provider_last_known SET `+col+`=?`, FormatFixedUTC(want)); err != nil {
			t.Fatal(err)
		}
	}
}

func TestClosedStoreAndSanitizeModelHash(t *testing.T) {
	ctx := context.Background()
	var nilStore *SQLiteStore
	if err := nilStore.Record(ctx, Event{Kind: KindDisconnect}); err == nil {
		t.Fatal("nil store Record must error")
	}
	if err := nilStore.UpsertLastKnown(ctx, LastKnown{ProviderID: "p"}); err == nil {
		t.Fatal("nil store Upsert must error")
	}
	if err := nilStore.ReconcileBounds(ctx); err == nil {
		t.Fatal("nil store Reconcile must error")
	}
	hex := strings.Repeat("0f", 32)
	if got := SanitizeModelHash("  " + strings.ToUpper(hex) + " "); got != hex {
		t.Fatalf("hash = %q", got)
	}
	nonHex := strings.Repeat("z", 64)
	if got := SanitizeModelHash(nonHex); got != nonHex {
		t.Fatalf("non-hex 64 passes through redaction unchanged, got %q", got)
	}
	if got := SanitizeModelHash("mpk_secret_value"); strings.Contains(got, "secret") {
		t.Fatalf("secret leaked via hash: %q", got)
	}
	if got := SanitizeModelHash("short"); got != "short" {
		t.Fatalf("short = %q", got)
	}
}

func TestTaxonomyRemainingBranches(t *testing.T) {
	for in, want := range map[string]string{
		"":                           ReasonOther,
		"upgrade failed: x":          ReasonUpgradeFailed,
		"heartbeat stale":            ReasonHeartbeatStale,
		"no_common_aead_suite extra": ReasonNoCommonAEADSuite,
		"provider_disconnected":      ReasonProviderWebsocketDisconnected,
		"invalid_auth_request":       ReasonInvalidAuthRequest,
		"provisional_pool exhausted": ReasonPoolFull,
	} {
		if got := NormalizeFailureReason(in); got != want {
			t.Fatalf("NormalizeFailureReason(%q)=%q want %q", in, got, want)
		}
	}
	for _, c := range []string{"mpk_abc", "Bearer xyz", strings.Repeat("ab", 32)} {
		if !LooksLikeCredential(c) {
			t.Fatalf("%q must look like a credential", c)
		}
	}
	for _, c := range []string{"", "  ", "provider-123"} {
		if LooksLikeCredential(c) {
			t.Fatalf("%q must not look like a credential", c)
		}
	}
	if KnownKind("nope") || !KnownKind(KindDisconnect) || KnownOutcome("x") || !KnownOutcome(OutcomeSuccess) {
		t.Fatal("known kind/outcome mismatch")
	}
	if got := RedactDiagnostic("héllo wörld", 5); got != "héllo" {
		t.Fatalf("rune-bounded clip = %q", got)
	}
	if got := RedactDiagnostic("   ", 5); got != "" {
		t.Fatalf("blank = %q", got)
	}
}
