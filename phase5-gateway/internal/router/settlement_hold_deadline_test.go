package router

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

// #1816 VM A-1 (b), A-3 and A-9: a hold's reconcile backoff grows with every
// "held" answer (four request-scoped nudges in the first seconds already push
// it to 40 minutes), so a hold whose coordinator finality only becomes final
// at its receipt deadline, or that an older gateway binary held for a policy
// version it did not know, was not looked at again for up to hours: the
// operator drain (runbook s9 rollback step 2) and the sweep both skipped it.
// The reservation's expiry is the receipt (or local fallback) deadline the
// gateway clamped it to; once it passes, the hold is due again, once.
func TestSettlementHoldDueAtReceiptDeadlineDespiteBackoff(t *testing.T) {
	type tc struct {
		finality     coordinatorRequestSettlementFinality
		deadlineAgo  time.Duration // < 0: the deadline is still ahead
		wantFirst    func(SettlementReconcileSummary) bool
		wantSettled  bool
		wantRefunded bool
		// reheldAfterDeadline: the older binary's own sweep answered "held"
		// again after the deadline, so only a startup pass sees the hold.
		reheldAfterDeadline bool
	}
	verifiedV2 := coordinatorRequestSettlementFinality{
		Mode: "enforce", PolicyVersion: settlementPolicyVersionV2, Outcome: "verified", ReceiptResult: "valid",
		Reason: "verified_settlement", Closed: true, PromptTokens: 8, CompletionTokens: 20, TotalTokens: 28,
		TokenSource: "pool_operator_attested", VerifiedAttempts: 1,
	}
	cases := map[string]tc{
		// A-1 (b): held by a pre-#1816 gateway (invalid_settlement_policy_version,
		// local fallback deadline), settled by this binary.
		"A-1 v2 pool-model hold from an older gateway settles": {
			finality: verifiedV2, deadlineAgo: 10 * time.Minute,
			wantFirst:   func(s SettlementReconcileSummary) bool { return s.Verified == 1 },
			wantSettled: true,
		},
		// A-1 (b), a long mixed window: the older gateway's sweep re-held it
		// after its deadline (backoff up to 6 h); this binary's startup
		// catch-up re-checks every hold once.
		"A-1 hold re-held after its deadline settles at startup": {
			finality: verifiedV2, deadlineAgo: 10 * time.Minute, reheldAfterDeadline: true,
			wantFirst:   func(s SettlementReconcileSummary) bool { return s.Verified == 1 },
			wantSettled: true,
		},
		// A-3: st_dc pending/missing_receipt until the deadline; the lookup
		// after it closes the verdict quarantined.
		"A-3 disconnect hold refunds at the receipt deadline": {
			finality: coordinatorRequestSettlementFinality{
				Mode: "enforce", PolicyVersion: settlementPolicyVersion, Outcome: "quarantined", ReceiptResult: "invalid",
				Reason: "missing_receipt_deadline_elapsed", Closed: true, QuarantinedAttempts: 1,
			},
			deadlineAgo:  time.Minute,
			wantFirst:    func(s SettlementReconcileSummary) bool { return s.Refunded == 1 },
			wantRefunded: true,
		},
		// A-9: a member revoked in flight, zero-billed and closed quarantined
		// (pool_manifest_route_not_settlement_eligible) at the deadline.
		"A-9 revoked-member zero-credit hold refunds": {
			finality: coordinatorRequestSettlementFinality{
				Mode: "enforce", PolicyVersion: settlementPolicyVersionV2, Outcome: "quarantined", ReceiptResult: "invalid",
				Reason: "missing_receipt_deadline_elapsed", Closed: true, QuarantinedAttempts: 1,
			},
			deadlineAgo:  time.Minute,
			wantFirst:    func(s SettlementReconcileSummary) bool { return s.Refunded == 1 },
			wantRefunded: true,
		},
		// Still pending after the deadline: one re-check, then the backoff
		// governs again (no lookup every sweep).
		"pending after the deadline is re-checked once": {
			finality: coordinatorRequestSettlementFinality{
				Mode: "enforce", PolicyVersion: settlementPolicyVersion, Outcome: "pending", ReceiptResult: "inconclusive",
				Reason: "receipt_verdict_pending", PendingAttempts: 1,
			},
			deadlineAgo: time.Minute,
			wantFirst:   func(s SettlementReconcileSummary) bool { return s.Scanned == 1 && s.Held == 1 },
		},
		// Before the deadline the backoff still applies.
		"backed-off hold before its deadline is not due": {
			finality:    verifiedV2,
			deadlineAgo: -time.Minute,
			wantFirst:   func(s SettlementReconcileSummary) bool { return s.Scanned == 0 },
		},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			const (
				accountID         = "acct_hold_deadline"
				requestID         = "req_hold_deadline"
				internalRequestID = "internal_hold_deadline"
			)
			lookups := 0
			coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				lookups++
				f := c.finality
				f.RequestID, f.RequiredInternalRequestID = requestID, internalRequestID
				_ = json.NewEncoder(w).Encode(f)
			}))
			defer coordinator.Close()
			h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
				cfg.Coordinator.OperatorURL = coordinator.URL
				cfg.Coordinator.OperatorKey = "operator-key"
				cfg.Coordinator.ServiceToken = "service-token"
			}, WithHTTPClient(coordinator.Client()), WithNow(func() time.Time { return time.Now().UTC() }))
			ctx := context.Background()
			now := time.Now().UTC()
			createdAt := now.Add(-20 * time.Minute)
			deadline := now.Add(-c.deadlineAgo)
			if err := store.CreateAccount(ctx, storage.Account{
				AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: createdAt,
			}); err != nil {
				t.Fatal(err)
			}
			if _, err := store.ReserveQuota(ctx, storage.ReservationRequest{
				AccountID: accountID, RequestID: requestID, WindowDate: createdAt.Format("2006-01-02"),
				RequestedTokens: 175, DailyQuota: 100000, CreatedAt: createdAt, ExpiresAt: createdAt.Add(time.Hour),
			}); err != nil {
				t.Fatal(err)
			}
			if err := store.ClampReservationExpiry(ctx, accountID, requestID, deadline); err != nil {
				t.Fatal(err)
			}
			seedBoundSettlementCandidate(t, store, accountID, requestID, internalRequestID, createdAt, 175, "")
			// The request-scoped nudges' four "held" answers right after the
			// request: attempt_count 4, next attempt 40 minutes out.
			db, err := sql.Open("sqlite", dbPath)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			lastAttempt := createdAt.Add(5 * time.Second)
			if c.reheldAfterDeadline {
				lastAttempt = deadline.Add(time.Minute)
			}
			if _, err := db.Exec(`INSERT INTO settlement_reconcile_attempts
				(account_id, request_id, reservation_created_at, attempt_count, first_attempt_at, last_attempt_at, last_result, next_attempt_after)
				VALUES (?, ?, ?, 4, ?, ?, 'held', ?)`,
				accountID, requestID, createdAt.Format(time.RFC3339Nano), createdAt.Add(time.Second).Format(time.RFC3339Nano),
				lastAttempt.Format(time.RFC3339Nano), lastAttempt.Add(40*time.Minute).Format(time.RFC3339Nano)); err != nil {
				t.Fatal(err)
			}

			sweep := func() SettlementReconcileSummary {
				req := httptest.NewRequest(http.MethodPost, "/admin/settlement/reconcile?limit=10", nil)
				req.Header.Set("Authorization", "Bearer operator-key")
				resp := httptest.NewRecorder()
				h.ServeHTTP(resp, req)
				if resp.Code != http.StatusOK {
					t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
				}
				var summary SettlementReconcileSummary
				if err := json.Unmarshal(resp.Body.Bytes(), &summary); err != nil {
					t.Fatal(err)
				}
				return summary
			}
			if c.reheldAfterDeadline {
				if s := sweep(); s.Scanned != 0 {
					t.Fatalf("sweep summary=%+v, want the backoff to govern a hold re-held after its deadline", s)
				}
				srv := New(cfg, store, fakeOAuth{}, WithHTTPClient(coordinator.Client()), WithNow(func() time.Time { return time.Now().UTC() }))
				if first, err := srv.CatchUpSettlementHolds(ctx, 500); err != nil || !c.wantFirst(first) {
					t.Fatalf("startup catch-up summary=%+v err=%v", first, err)
				}
			} else if first := sweep(); !c.wantFirst(first) {
				t.Fatalf("first sweep summary=%+v", first)
			}
			state := gatewaySettlementSnapshot(t, dbPath, accountID)
			switch {
			case c.wantSettled:
				if state.settledRows != 1 || state.usageRows != 1 || state.activeRows != 0 {
					t.Fatalf("state=%+v, want settled", state)
				}
			case c.wantRefunded:
				if state.refundedRows != 1 || state.usageRows != 0 || state.activeRows != 0 {
					t.Fatalf("state=%+v, want refunded", state)
				}
			default:
				if state.activeRows != 1 || state.heldRows != 1 {
					t.Fatalf("state=%+v, want still held", state)
				}
				before := lookups
				if second := sweep(); second.Scanned != 0 || lookups != before {
					t.Fatalf("second sweep summary=%+v lookups=%d->%d, want the backoff to govern", second, before, lookups)
				}
			}
		})
	}
}
