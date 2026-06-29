package sqlite

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// TestExplorerAccountIDsForRequest_CapAt10WithTruncationFlag pins the
// SPEC-007 v0.4 §6.4 normative cap on matched_account_ids. #231:
// when the underlying UNION resolves to >10 distinct accounts, the
// returned slice is capped at 10 AND MatchedAccountIDsTruncated is
// true. The bounded forensic sample (cap ExplorerForensicMatchedAccountIDsCap)
// is preserved on MatchedAccountIDsForensicSample for the handler's
// audit_events emit.
func TestExplorerAccountIDsForRequest_CapAt10WithTruncationFlag(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	const sharedRequestID = "amb-cap-test-uuid"

	// Seed 15 accounts each with one feedback_events row carrying the
	// SAME request_id. The cross-account union should resolve to all
	// 15 distinct account_ids but the response cap is N=10.
	for i := 0; i < 15; i++ {
		accountID := fmt.Sprintf("acct_%02d", i)
		createAccount(t, store, accountID)
		if err := store.InsertFeedbackEvent(ctx, storage.FeedbackEvent{
			EventID:   fmt.Sprintf("evt_%02d", i),
			RequestID: sharedRequestID,
			AccountID: accountID,
			Scope:     "request",
			Rating:    1,
			Comment:   "collision flood",
			CreatedAt: fixedTime(),
		}); err != nil {
			t.Fatalf("InsertFeedbackEvent(%s): %v", accountID, err)
		}
	}

	got, err := store.ExplorerSessionDetail(ctx, "", sharedRequestID)
	if !errors.Is(err, storage.ErrExplorerAmbiguousRequestID) {
		t.Fatalf("unscoped lookup: err=%v, want ErrExplorerAmbiguousRequestID", err)
	}
	if !got.MatchedAccountIDsTruncated {
		t.Errorf("MatchedAccountIDsTruncated=false, want true (>cap accounts)")
	}
	if want := storage.ExplorerMatchedAccountIDsCap; len(got.MatchedAccountIDs) != want {
		t.Errorf("len(MatchedAccountIDs)=%d, want exactly %d (cap)", len(got.MatchedAccountIDs), want)
	}
	if len(got.MatchedAccountIDsForensicSample) != 15 {
		t.Errorf("len(MatchedAccountIDsForensicSample)=%d, want 15 (forensic sample <= cap)", len(got.MatchedAccountIDsForensicSample))
	}
	if got.MatchedAccountIDsForensicDegraded {
		t.Errorf("MatchedAccountIDsForensicDegraded=true on healthy DB; want false")
	}
	// Returned list MUST be the first 10 lexicographic — deterministic
	// truncation under the ORDER BY account_id LIMIT 11 contract.
	for i := 0; i < storage.ExplorerMatchedAccountIDsCap; i++ {
		want := fmt.Sprintf("acct_%02d", i)
		if got.MatchedAccountIDs[i] != want {
			t.Errorf("MatchedAccountIDs[%d]=%q, want %q (lexicographic truncation)", i, got.MatchedAccountIDs[i], want)
		}
	}
}

// TestExplorerAccountIDsForRequest_BelowCapDoesNotTruncate pins the
// happy-path: 2 ≤ N ≤ cap accounts return the full list with
// MatchedAccountIDsTruncated=false. This guards against an off-by-one
// in the cap+1 probe where the 10th account would be incorrectly
// flagged as truncation.
func TestExplorerAccountIDsForRequest_BelowCapDoesNotTruncate(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	const sharedRequestID = "amb-belowcap-uuid"
	// Seed exactly cap (10) accounts.
	for i := 0; i < storage.ExplorerMatchedAccountIDsCap; i++ {
		accountID := fmt.Sprintf("acct_%02d", i)
		createAccount(t, store, accountID)
		if err := store.InsertFeedbackEvent(ctx, storage.FeedbackEvent{
			EventID:   fmt.Sprintf("evt_%02d", i),
			RequestID: sharedRequestID,
			AccountID: accountID,
			Scope:     "request",
			Rating:    3,
			Comment:   "normal traffic",
			CreatedAt: fixedTime(),
		}); err != nil {
			t.Fatalf("InsertFeedbackEvent(%s): %v", accountID, err)
		}
	}
	got, err := store.ExplorerSessionDetail(ctx, "", sharedRequestID)
	if !errors.Is(err, storage.ErrExplorerAmbiguousRequestID) {
		t.Fatalf("unscoped lookup: err=%v", err)
	}
	if got.MatchedAccountIDsTruncated {
		t.Errorf("MatchedAccountIDsTruncated=true at exactly cap; want false")
	}
	if len(got.MatchedAccountIDs) != storage.ExplorerMatchedAccountIDsCap {
		t.Errorf("len=%d, want %d (full list)", len(got.MatchedAccountIDs), storage.ExplorerMatchedAccountIDsCap)
	}
	if len(got.MatchedAccountIDsForensicSample) != 0 {
		t.Errorf("forensic sample populated at non-truncation: %v", got.MatchedAccountIDsForensicSample)
	}
}

// TestExplorerAccountIDsForRequest_ForensicCapAtN101 pins #231 R2
// SEC closure: the forensic SELECT MUST be bounded at
// ExplorerForensicMatchedAccountIDsCap+1 rows (=101) so a
// collision-flood attacker cannot drive an unbounded
// scan/materialization through the audit path.
func TestExplorerAccountIDsForRequest_ForensicCapAtN101(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping forensic-cap regression in -short mode")
	}
	ctx := context.Background()
	store := newTestStore(t)
	const sharedRequestID = "amb-forensic-cap-uuid"
	// Seed 105 accounts colliding on the same request_id.
	for i := 0; i < 105; i++ {
		accountID := fmt.Sprintf("acct_%03d", i)
		createAccount(t, store, accountID)
		if err := store.InsertFeedbackEvent(ctx, storage.FeedbackEvent{
			EventID:   fmt.Sprintf("evt_%03d", i),
			RequestID: sharedRequestID,
			AccountID: accountID,
			Scope:     "request",
			Rating:    2,
			Comment:   "forensic-cap test",
			CreatedAt: fixedTime(),
		}); err != nil {
			t.Fatalf("InsertFeedbackEvent(%s): %v", accountID, err)
		}
	}
	got, err := store.ExplorerSessionDetail(ctx, "", sharedRequestID)
	if !errors.Is(err, storage.ErrExplorerAmbiguousRequestID) {
		t.Fatalf("unscoped lookup: err=%v", err)
	}
	// Response body cap stays at 10.
	if len(got.MatchedAccountIDs) != storage.ExplorerMatchedAccountIDsCap {
		t.Errorf("response cap drift: len=%d want %d", len(got.MatchedAccountIDs), storage.ExplorerMatchedAccountIDsCap)
	}
	// Forensic sample is bounded at forensic-cap+1 (=101) — NOT the
	// full 105. Caller emits payload.forensic_truncated_at=100.
	want := storage.ExplorerForensicMatchedAccountIDsCap + 1
	if len(got.MatchedAccountIDsForensicSample) != want {
		t.Errorf("forensic sample len=%d, want %d (cap+1 probe)", len(got.MatchedAccountIDsForensicSample), want)
	}
}
