package billing

// Issue #21 / ARCH-3 / 2026-06-10 audit QW-5 — regression coverage.
//
// PR #14 set MaxOpenConns(1) on requestlog.OpenStore (which billing reuses
// via billing.NewStore(reqStore.DB())) and CI hung deterministically at
// phase4-coordinator/internal/billing on the slow ubuntu runner. The root
// cause was three places where the billing code held an outer *sql.Rows
// cursor open while running an inner Query against the same shared
// *sql.DB — at cap=1, the inner Query waits forever for the connection
// the outer cursor pins. PR #14 was closed unmerged; the cap landed only
// for auth + audit (which had no nested-query patterns) and requestlog
// stayed uncapped, leaving the bug latent on production under sustained
// contention as p99 latency degradation + post-inference 500s.
//
// This file pins the THREE confirmed nested-cursor sites — rebuildLegacy-
// ConfigSnapshots, the providers admin handler, and buyerEquivalentCredits
// (called by the reconcile admin handler) — against the cap=1 pool.
// requestlog.OpenStore now caps the shared pool to 1 at construction;
// newRequestAndBillingStores uses requestlog.OpenStore, so this file
// exercises the cap by extension. If any of the three loops regress to
// holding the outer cursor open across an inner Query, these tests will
// hang and the package timeout will surface them.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The pool-cap assertion itself lives in
// internal/requestlog/store_test.go `TestOpenStoreCapsPoolAtOneConn`,
// next to the SetMaxOpenConns(1) call it pins. The tests below run
// AT cap=1 (newRequestAndBillingStores opens via requestlog.OpenStore)
// and would deadlock if any of the nested-cursor sites regressed.

// TestRebuildLegacyConfigSnapshots_NestedCursorAtCap1 covers
// billing/store.go rebuildLegacyConfigSnapshots: outer PRAGMA index_list +
// inner PRAGMA index_info per row. Pre-refactor, this loop held the outer
// cursor open while issuing the inner Query — deadlock at cap=1. After
// refactor the outer cursor closes before any inner Query runs.
//
// To force the loop to actually enter the inner-query path, this test
// creates a legacy single-column UNIQUE(config_hash) index on
// ledger_config_snapshots BEFORE calling rebuildLegacyConfigSnapshots —
// without that index the outer cursor finds nothing of interest and the
// inner query never runs, so the test would pass even if the refactor
// regressed. (Code-lane r1 audit M1 noted this gap.)
func TestRebuildLegacyConfigSnapshots_NestedCursorAtCap1(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	// Plant the legacy unique index — exactly the shape rebuildLegacy-
	// ConfigSnapshots was written to detect and rebuild. The outer
	// PRAGMA index_list now returns this row, and the inner
	// PRAGMA index_info(name) is the call that used to deadlock at cap=1.
	if _, err := store.db.ExecContext(context.Background(),
		`CREATE UNIQUE INDEX idx_legacy_config_hash_unique ON ledger_config_snapshots(config_hash)`,
	); err != nil {
		t.Fatalf("plant legacy unique index: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := store.rebuildLegacyConfigSnapshots(ctx); err != nil {
		t.Fatalf("rebuildLegacyConfigSnapshots at cap=1 with legacy unique index: %v", err)
	}
	// Post-condition: the legacy unique should no longer be present —
	// the rebuild swaps the table for one without the unique constraint.
	var idxCount int
	if err := store.db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM pragma_index_list('ledger_config_snapshots') WHERE name = 'idx_legacy_config_hash_unique'`,
	).Scan(&idxCount); err != nil {
		t.Fatal(err)
	}
	if idxCount != 0 {
		t.Fatalf("legacy unique index still present after rebuild (count=%d)", idxCount)
	}
}

// TestProvidersHandler_PendingPayoutAtCap1 covers billing/endpoints.go
// providers handler. Pre-refactor (issue #21 r1): outer aggregate scan
// over ledger_request_credits + per-row h.sum(...) on
// ledger_payout_ready — deadlocked at cap=1, was an N+1 with up to 200
// statements serialized on the only connection, wasn't snapshot-
// consistent, and silently emitted pending_payout_credits=0 on inner
// query error (h.sum swallows errors). r2 refactor (per architect +
// security M1 convergent finding): one grouped LEFT JOIN — single
// statement, single connection acquisition, point-in-time consistent,
// errors surface.
//
// Two providers + non-zero pending_payout on one of them pin the
// JOIN's grouped-subquery payout aggregation against the multi-row
// outer aggregate. If a future contributor reverts to the N+1 sum-per-
// row shape, this test still passes at cap=1 (just serializes more
// statements) — the JOIN-vs-loop guard lives in the SQL string itself
// + the security/architect audit lanes.
func TestProvidersHandler_PendingPayoutAtCap1(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	now := time.Now().UTC()
	// Two providers. Provider-a has a ready payout row to verify the
	// grouped LEFT JOIN populates pending_payout_credits correctly;
	// provider-b has none so we also verify the COALESCE-to-0 path.
	insertCredit(t, store.db, "provider-a", now, 500)
	insertCredit(t, store.db, "provider-b", now, 600)
	if _, err := store.db.ExecContext(context.Background(), `
INSERT INTO ledger_payout_ready (
    provider_id, window_start_utc, window_end_utc, cadence_days,
    source_credit_count, gross_credits, provider_credits, operator_credits,
    min_payout_credits, payout_currency, payout_external_id, status,
    idempotency_key, created_at_utc
) VALUES ('provider-a', ?, ?, 7, 1, 1000, 900, 100, 100, NULL, NULL, 'ready', 'idem-a', ?)`,
		now.Format(time.RFC3339Nano), now.Add(7*24*time.Hour).Format(time.RFC3339Nano), now.Format(time.RFC3339Nano),
	); err != nil {
		t.Fatalf("insert payout: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/providers", nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s — providers handler errored at cap=1", w.Code, w.Body.String())
	}
	var resp struct {
		Providers []struct {
			ProviderID           string `json:"provider_id"`
			PendingPayoutCredits int64  `json:"pending_payout_credits"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Providers) != 2 {
		t.Fatalf("providers=%d want 2", len(resp.Providers))
	}
	byID := map[string]int64{}
	for _, p := range resp.Providers {
		byID[p.ProviderID] = p.PendingPayoutCredits
	}
	if byID["provider-a"] != 900 {
		t.Fatalf("provider-a pending_payout_credits=%d want 900 (grouped JOIN must surface ready-row provider_credits)", byID["provider-a"])
	}
	if byID["provider-b"] != 0 {
		t.Fatalf("provider-b pending_payout_credits=%d want 0 (COALESCE on missing payout row)", byID["provider-b"])
	}
}

// TestBuyerEquivalentCredits_NestedCursorAtCap1 covers
// billing/endpoints.go buyerEquivalentCredits (called by the reconcile
// admin handler). Pre-refactor: outer request_log scan + inner
// byteEstimatedLedgerGross + inner snapshotAt per row — both inner
// Queries deadlocked at cap=1. r1 refactor: drain outer scan into a
// typed slice, close cursor, then run per-row work. r2 refactor: carry
// raw tsText through the first pass so the 503 filter applies BEFORE
// time.Parse (preserves origin/main's silent-503 behavior on malformed
// 503 timestamps).
//
// This test exercises multiple request_log rows including a 503 row
// with a deliberately-malformed ts_utc — the second pass must skip it
// silently, not error. Code-lane r1 audit L1 noted that the prior
// single-row test wouldn't have caught a regression of either the
// multi-row scan path OR the 503-before-parse ordering.
func TestBuyerEquivalentCredits_NestedCursorAtCap1(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	// Row 1: normal 200, hits the snapshotAt path through ComputeCredits.
	ts := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	prompt, completion := int64(1000), int64(2000)
	input := HotPathInput{
		RequestID: "row-200-snapshot", AttemptN: 0, ProviderAssignedID: "assigned-a", ProviderID: "provider-a",
		Model: "model-a", Status: 200, TSUtc: ts, PromptTokens: &prompt, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, "model-a"),
		MultiplierPPM: 1000000, ProviderShareBps: 9000,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, requestLogRow(input), input); err != nil {
		t.Fatal(err)
	}
	// Row 2: another normal 200, different request_id — drives the
	// multi-row outer-scan path (a single row would not have exercised
	// it; code-lane r1 L1).
	input2 := input
	input2.RequestID = "row-200-snapshot-2"
	input2.TSUtc = ts.Add(time.Second)
	if err := store.WriteHotPath(context.Background(), reqStore, requestLogRow(input2), input2); err != nil {
		t.Fatal(err)
	}
	// Row 3: a 503 row with a deliberately malformed ts_utc. r2 of the
	// refactor must skip this BEFORE time.Parse — otherwise the parse
	// failure on the malformed string would surface as a hard error
	// and the reconcile endpoint would 500. Origin/main filtered 503s
	// before parsing; we MUST preserve that.
	if _, err := store.db.ExecContext(context.Background(), `
INSERT INTO request_log (
    ts_utc, request_id, model, provider_assigned_id, prompt_tokens,
    completion_tokens, estimated_completion_tokens, total_tokens,
    latency_ms, routing_ms, status, stream, error_code, retried
) VALUES ('not-a-timestamp', 'row-503-malformed', 'model-a', 'assigned-a',
    0, 0, 0, 0, 0, 0, 503, 0, NULL, 0)`,
	); err != nil {
		t.Fatalf("insert malformed 503 row: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/reconcile?from=2026-06-01&to=2026-06-08", nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s — reconcile/buyerEquivalentCredits deadlocked, errored, or failed the 503-before-parse check at cap=1", w.Code, w.Body.String())
	}
}

