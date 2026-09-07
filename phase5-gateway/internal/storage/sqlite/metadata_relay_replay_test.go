package sqlite

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestWalletMetadataRelayReplayRetentionWithoutCleanup(t *testing.T) {
	for _, tc := range []struct {
		name   string
		offset time.Duration
		want   error
	}{
		{"before_second", -time.Second, storage.ErrRelayBlindReplay},
		{"before_nanosecond", -time.Nanosecond, storage.ErrRelayBlindReplay},
		{"at", 0, storage.ErrRateLimit},
		{"after_nanosecond", time.Nanosecond, storage.ErrRateLimit},
		{"after_second", time.Second, storage.ErrRateLimit},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store, req, replay := metadataRelayReplayFixture(t)
			recordMetadataRelayReplay(t, store, replay)
			req.CreatedAt = replay.RetentionExpiresAt.Add(tc.offset)
			// The candidate's clock and expiry must not replace admission time or stored retention.
			replay.CreatedAt = fixedTime().Add(time.Hour)
			if tc.offset >= 0 {
				replay.CreatedAt = fixedTime().Add(-time.Hour)
			}
			replay.RetentionExpiresAt = req.CreatedAt.Add(time.Hour)
			req.RelayBlindReplay = &replay
			assertMetadataRelayReplayRejected(t, store, req, tc.want)
			var rows int
			if err := store.db.QueryRow(`SELECT COUNT(*) FROM relay_blind_replays`).Scan(&rows); err != nil {
				t.Fatal(err)
			}
			if rows != 1 {
				t.Fatalf("retained rows=%d want 1 without cleanup", rows)
			}
		})
	}
}

func TestWalletMetadataRelayReplayFractionalExpiryAfterWholeSecond(t *testing.T) {
	store, req, replay := metadataRelayReplayFixture(t)
	req.CreatedAt = fixedTime().Add(10 * time.Second)
	replay.RetentionExpiresAt = req.CreatedAt.Add(time.Nanosecond)
	recordMetadataRelayReplay(t, store, replay)
	req.RelayBlindReplay = &replay
	assertMetadataRelayReplayRejected(t, store, req, storage.ErrRelayBlindReplay)
}

func TestWalletMetadataRelayReplayAnyRetainedMatchingRowWins(t *testing.T) {
	for _, firstExpired := range []bool{true, false} {
		t.Run(fmt.Sprintf("first_expired_%t", firstExpired), func(t *testing.T) {
			store, req, first := metadataRelayReplayFixture(t)
			second := first
			second.RequestID = "second-inner-request"
			second.RequestReplayNonceDigest = []byte("second-inner-nonce")
			second.BuyerEphemeralPublicKeyDigest = []byte("second-inner-buyer-key")
			second.EnvelopeDigest = []byte("second-inner-envelope")
			second.RetentionExpiresAt = fixedTime().Add(20 * time.Second)
			if !firstExpired {
				first.RetentionExpiresAt, second.RetentionExpiresAt = second.RetentionExpiresAt, first.RetentionExpiresAt
			}
			recordMetadataRelayReplay(t, store, first)
			recordMetadataRelayReplay(t, store, second)
			req.CreatedAt = fixedTime().Add(11 * time.Second)
			// This candidate matches the first request ID and the second nonce.
			first.RequestReplayNonceDigest = second.RequestReplayNonceDigest
			req.RelayBlindReplay = &first
			assertMetadataRelayReplayRejected(t, store, req, storage.ErrRelayBlindReplay)
		})
	}
}

func TestWalletMetadataRelayReplayMatchesEachIdentity(t *testing.T) {
	for _, identity := range []string{"request_id", "nonce", "buyer_key", "envelope"} {
		t.Run(identity, func(t *testing.T) {
			store, req, replay := metadataRelayReplayFixture(t)
			recordMetadataRelayReplay(t, store, replay)
			candidate := replay
			candidate.RequestID = "fresh-inner-request"
			candidate.RequestReplayNonceDigest = []byte("fresh-nonce")
			candidate.BuyerEphemeralPublicKeyDigest = []byte("fresh-buyer-key")
			candidate.EnvelopeDigest = []byte("fresh-envelope")
			switch identity {
			case "request_id":
				candidate.RequestID = replay.RequestID
			case "nonce":
				candidate.RequestReplayNonceDigest = replay.RequestReplayNonceDigest
			case "buyer_key":
				candidate.BuyerEphemeralPublicKeyDigest = replay.BuyerEphemeralPublicKeyDigest
			case "envelope":
				candidate.EnvelopeDigest = replay.EnvelopeDigest
			}
			req.RelayBlindReplay = &candidate
			assertMetadataRelayReplayRejected(t, store, req, storage.ErrRelayBlindReplay)
		})
	}
}

func TestWalletMetadataRelayReplayBindsAdmissionScope(t *testing.T) {
	for _, tc := range []struct {
		name          string
		storedAccount string
		storedSession string
		want          error
	}{
		{"candidate_cannot_override_scope", "acct_metadata_relay", "ws_metadata_relay", storage.ErrRelayBlindReplay},
		{"other_account", "acct_other", "ws_metadata_relay", storage.ErrRateLimit},
		{"other_session", "acct_metadata_relay", "ws_other", storage.ErrRateLimit},
		{"api_key_scope", "acct_metadata_relay", "", storage.ErrRateLimit},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store, req, replay := metadataRelayReplayFixture(t)
			replay.AccountID, replay.WalletSessionID = tc.storedAccount, tc.storedSession
			recordMetadataRelayReplay(t, store, replay)
			if tc.want == storage.ErrRelayBlindReplay {
				replay.AccountID, replay.WalletSessionID = "acct_other", "ws_other"
			}
			req.RelayBlindReplay = &replay
			originalScope := [2]string{replay.AccountID, replay.WalletSessionID}
			assertMetadataRelayReplayRejected(t, store, req, tc.want)
			if got := [2]string{replay.AccountID, replay.WalletSessionID}; got != originalScope {
				t.Fatal("admission mutated caller-owned replay scope")
			}
		})
	}
}

func TestWalletMetadataRelayReplayFreshAndAbsentCandidatesRemainRateLimited(t *testing.T) {
	for _, present := range []bool{false, true} {
		t.Run(fmt.Sprintf("candidate_%t", present), func(t *testing.T) {
			store, req, replay := metadataRelayReplayFixture(t)
			recordMetadataRelayReplay(t, store, replay)
			if present {
				replay.RequestID = "fresh-inner-request"
				replay.RequestReplayNonceDigest = []byte("fresh-nonce")
				replay.BuyerEphemeralPublicKeyDigest = []byte("fresh-buyer-key")
				replay.EnvelopeDigest = []byte("fresh-envelope")
				req.RelayBlindReplay = &replay
			}
			assertMetadataRelayReplayRejected(t, store, req, storage.ErrRateLimit)
		})
	}
}

func TestWalletMetadataRelayReplayOnlyClassifiesTemporalRejection(t *testing.T) {
	for _, rateLimit := range []int{0, 2} {
		t.Run(fmt.Sprintf("rate_limit_%d", rateLimit), func(t *testing.T) {
			store, req, replay := metadataRelayReplayFixture(t)
			recordMetadataRelayReplay(t, store, replay)
			req.RateLimit = rateLimit
			req.RelayBlindReplay = &replay
			before := metadataRelayReplayState(t, store)
			if err := store.AdmitWalletSessionMetadata(context.Background(), req); err != nil {
				t.Fatalf("metadata admission with available rate budget: %v", err)
			}
			want := before
			want[0]++
			want[1]++
			if got := metadataRelayReplayState(t, store); got != want {
				t.Fatalf("state=%v want only one new metadata replay %v", got, want)
			}
		})
	}
}

func TestWalletMetadataRelayReplayExistingGuardsKeepPrecedence(t *testing.T) {
	for _, tc := range []struct {
		name string
		want error
	}{
		{"outer_duplicate", storage.ErrWalletSessionReplayDuplicate},
		{"outer_mismatch", storage.ErrWalletSessionReplayMismatch},
		{"hard_rows", storage.ErrWalletSessionReplayCapacity},
		{"hard_bytes", storage.ErrWalletSessionReplayCapacity},
		{"revoked_session", storage.ErrWalletSessionInactive},
		{"expired_session", storage.ErrWalletSessionInactive},
		{"inactive_account", storage.ErrWalletSessionInactive},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store, req, replay := metadataRelayReplayFixture(t)
			recordMetadataRelayReplay(t, store, replay)
			req.RelayBlindReplay = &replay
			switch tc.name {
			case "outer_duplicate", "outer_mismatch":
				req.Replay.RequestID = "outer-seed"
				req.MaxReplayRows, req.MaxReplayBytes = 1, 1
				if tc.name == "outer_mismatch" {
					req.Replay.RawBodyHash = []byte("different-body")
				}
			case "hard_rows":
				req.MaxReplayRows = 1
			case "hard_bytes":
				req.MaxReplayBytes = 2*req.Replay.BodyBytes - 1
			case "revoked_session":
				if err := store.RevokeWalletSession(context.Background(), req.AccountID, req.SessionID, "test", "test", req.CreatedAt); err != nil {
					t.Fatal(err)
				}
			case "expired_session":
				if _, err := store.db.Exec(`UPDATE wallet_sessions SET expires_at = ? WHERE session_id = ?`, encodeTime(req.CreatedAt), req.SessionID); err != nil {
					t.Fatal(err)
				}
			case "inactive_account":
				if _, err := store.db.Exec(`UPDATE accounts SET status = 'blocked' WHERE account_id = ?`, req.AccountID); err != nil {
					t.Fatal(err)
				}
			}
			assertMetadataRelayReplayRejected(t, store, req, tc.want)
		})
	}
}

func TestWalletMetadataRelayReplayLookupErrorFailsClosed(t *testing.T) {
	store, req, replay := metadataRelayReplayFixture(t)
	recordMetadataRelayReplay(t, store, replay)
	req.RelayBlindReplay = &replay
	if _, err := store.db.Exec(`ALTER TABLE relay_blind_replays RENAME COLUMN retention_expires_at TO unavailable_retention_expires_at`); err != nil {
		t.Fatal(err)
	}
	before := metadataRelayReplayState(t, store)
	err := store.AdmitWalletSessionMetadata(context.Background(), req)
	if err == nil || errors.Is(err, storage.ErrRateLimit) || errors.Is(err, storage.ErrRelayBlindReplay) || !strings.Contains(err.Error(), "retention_expires_at") {
		t.Fatalf("lookup error=%v want storage error naming missing retention column", err)
	}
	if got := metadataRelayReplayState(t, store); got != before {
		t.Fatalf("failed lookup changed state: before=%v after=%v", before, got)
	}
}

func TestWalletMetadataRelayReplayCorruptRetentionFailsClosed(t *testing.T) {
	store, req, replay := metadataRelayReplayFixture(t)
	recordMetadataRelayReplay(t, store, replay)
	req.RelayBlindReplay = &replay
	if _, err := store.db.Exec(`UPDATE relay_blind_replays SET retention_expires_at = 'invalid-timestamp' WHERE request_id = ?`, replay.RequestID); err != nil {
		t.Fatal(err)
	}
	before := metadataRelayReplayState(t, store)
	err := store.AdmitWalletSessionMetadata(context.Background(), req)
	if err == nil || errors.Is(err, storage.ErrRateLimit) || errors.Is(err, storage.ErrRelayBlindReplay) {
		t.Fatalf("corrupt retention error=%v want storage error", err)
	}
	if got := metadataRelayReplayState(t, store); got != before {
		t.Fatalf("corrupt retention lookup changed state: before=%v after=%v", before, got)
	}
}

func TestWalletMetadataRelayReplayConcurrentRejectionsPreserveState(t *testing.T) {
	store, req, replay := metadataRelayReplayFixture(t)
	recordMetadataRelayReplay(t, store, replay)
	req.RelayBlindReplay = &replay
	if _, err := store.AdmitWalletSessionInference(context.Background(), walletAdmission(req.AccountID, req.SessionID, "reserved-before-rejections", 20)); err != nil {
		t.Fatalf("seed inference reservation: %v", err)
	}
	before := metadataRelayReplayState(t, store)
	const attempts = 16
	start := make(chan struct{})
	results := make(chan error, attempts)
	var wg sync.WaitGroup
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			candidate := req
			candidate.Replay.RequestID = fmt.Sprintf("concurrent-outer-%d", i)
			<-start
			results <- store.AdmitWalletSessionMetadata(context.Background(), candidate)
		}(i)
	}
	close(start)
	wg.Wait()
	close(results)
	for err := range results {
		if !errors.Is(err, storage.ErrRelayBlindReplay) {
			t.Errorf("concurrent rejection=%v want ErrRelayBlindReplay", err)
		}
	}
	if got := metadataRelayReplayState(t, store); got != before {
		t.Fatalf("rejected lookups changed state: before=%v after=%v", before, got)
	}
	used, reserved, err := store.DailyUsage(context.Background(), req.AccountID, "2026-05-29")
	if err != nil || used != 0 || reserved != 20 {
		t.Fatalf("daily usage after rejection: used=%d reserved=%d err=%v want 0,20,nil", used, reserved, err)
	}
}

func metadataRelayReplayFixture(t *testing.T) (*Store, storage.WalletSessionMetadataAdmissionRequest, storage.RelayBlindReplayMaterial) {
	t.Helper()
	store := newTestStore(t)
	createWalletSession(t, store, "acct_metadata_relay", "ws_metadata_relay", 1000, 100)
	req := storage.WalletSessionMetadataAdmissionRequest{
		AccountID:      "acct_metadata_relay",
		SessionID:      "ws_metadata_relay",
		Replay:         walletReplay("ws_metadata_relay", "outer-seed", "POST", "/v1/chat/completions", []byte("outer-body"), 128, "192.0.2.1"),
		WindowStart:    fixedTime().Add(-time.Minute),
		RateLimit:      1,
		MaxReplayRows:  100,
		MaxReplayBytes: 100000,
		CreatedAt:      fixedTime(),
	}
	if err := store.AdmitWalletSessionMetadata(context.Background(), req); err != nil {
		t.Fatalf("seed metadata rate budget: %v", err)
	}
	req.Replay.RequestID = "outer-retry"
	req.CreatedAt = fixedTime().Add(time.Second)
	return store, req, storage.RelayBlindReplayMaterial{
		AccountID:                     req.AccountID,
		WalletSessionID:               req.SessionID,
		RequestID:                     "inner-request",
		RequestReplayNonceDigest:      []byte("inner-nonce"),
		BuyerEphemeralPublicKeyDigest: []byte("inner-buyer-key"),
		ProviderBindingDigest:         []byte("provider-binding"),
		KIDDigest:                     []byte("kid"),
		EnvelopeDigest:                []byte("inner-envelope"),
		EnvelopeBytes:                 128,
		RetentionExpiresAt:            fixedTime().Add(10 * time.Second),
		CreatedAt:                     fixedTime(),
	}
}

func recordMetadataRelayReplay(t *testing.T, store *Store, replay storage.RelayBlindReplayMaterial) {
	t.Helper()
	if err := store.RecordRelayBlindReplay(context.Background(), replay); err != nil {
		t.Fatalf("seed inner replay: %v", err)
	}
}

func assertMetadataRelayReplayRejected(t *testing.T, store *Store, req storage.WalletSessionMetadataAdmissionRequest, want error) {
	t.Helper()
	before := metadataRelayReplayState(t, store)
	if err := store.AdmitWalletSessionMetadata(context.Background(), req); !errors.Is(err, want) {
		t.Fatalf("metadata rejection=%v want %v", err, want)
	}
	if got := metadataRelayReplayState(t, store); got != before {
		t.Fatalf("rejection changed state: before=%v after=%v", before, got)
	}
}

func metadataRelayReplayState(t *testing.T, store *Store) [9]int64 {
	t.Helper()
	var state [9]int64
	err := store.db.QueryRow(`SELECT
		(SELECT COUNT(*) FROM wallet_session_replays),
		(SELECT COUNT(*) FROM wallet_session_replays WHERE state = 'metadata_only'),
		(SELECT COUNT(*) FROM relay_blind_replays),
		(SELECT COUNT(*) FROM wallet_session_reservations),
		(SELECT COALESCE(SUM(reserved_tokens), 0) FROM wallet_session_reservations),
		(SELECT COUNT(*) FROM quota_reservations),
		(SELECT COALESCE(SUM(reserved_tokens), 0) FROM quota_reservations),
		(SELECT COUNT(*) FROM wallet_session_request_map),
		(SELECT COUNT(*) FROM usage_events)`).Scan(
		&state[0], &state[1], &state[2], &state[3], &state[4], &state[5], &state[6], &state[7], &state[8])
	if err != nil {
		t.Fatalf("read admission state: %v", err)
	}
	return state
}
