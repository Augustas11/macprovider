package payout

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// SPEC-016 §4.6 — /admin/payout/abandon-attempt endpoint.
//
// Closes the v0.1.11 codex round-12 MAJOR-1 race class: the
// runner-active gate (lease-presence check) AND the §4.3 step 6
// CAS predicate extensions (AND confirmed_at_utc IS NULL AND
// abandoned_at_utc IS NULL) compose to defang the
// abandon-vs-sign race from both sides.

// AbandonRequest is the JSON body of POST /admin/payout/abandon-attempt.
type AbandonRequest struct {
	PayoutID                    int64   `json:"payout_id"`
	AttemptSeq                  int     `json:"attempt_seq"`
	BroadcastCancelSelfTransfer bool    `json:"broadcast_cancel_self_transfer"`
	Confirm                     bool    `json:"confirm"`
	TipMultiplier               float64 `json:"tip_multiplier"`
	Reason                      string  `json:"reason"`
}

// AbandonResponse is the 200 OK body.
type AbandonResponse struct {
	PayoutID            int64  `json:"payout_id"`
	AbandonedAttemptSeq int    `json:"abandoned_attempt_seq"`
	CancelAttemptSeq    *int   `json:"cancel_attempt_seq,omitempty"`
	CancelTxHash        string `json:"cancel_tx_hash,omitempty"`
	CancelBroadcasted   bool   `json:"cancel_broadcasted"`
	CapApplied          bool   `json:"cap_applied,omitempty"`
}

// AbandonService bundles the dependencies for the §4.6 endpoint.
type AbandonService struct {
	DB          *sql.DB
	Security    SecurityConfig
	RPCs        TwoRPCs
	Signer      Signer
	RunInterval time.Duration
	Logger      zerolog.Logger
	NowFn       func() time.Time

	// Per-actor rate-limit state.
	mu         sync.Mutex
	actorCalls map[string][]time.Time
}

// NewAbandonService validates wiring and returns a usable service.
func NewAbandonService(db *sql.DB, sec SecurityConfig, rpcs TwoRPCs, signer Signer,
	runInterval time.Duration, log zerolog.Logger,
) (*AbandonService, error) {
	if db == nil {
		return nil, errors.New("AbandonService: db required")
	}
	if signer == nil {
		return nil, errors.New("AbandonService: signer required")
	}
	if sec.HotWalletAddress == "" {
		return nil, errors.New("AbandonService: hot wallet address required")
	}
	if runInterval < 5*time.Minute {
		return nil, fmt.Errorf("AbandonService: runInterval too low (%s)", runInterval)
	}
	return &AbandonService{
		DB:          db,
		Security:    sec,
		RPCs:        rpcs,
		Signer:      signer,
		RunInterval: runInterval,
		Logger:      log,
		NowFn:       time.Now,
		actorCalls:  map[string][]time.Time{},
	}, nil
}

// ServeAbandon implements POST /admin/payout/abandon-attempt.
// Caller is responsible for operator-key authentication BEFORE
// invoking this — the service operates on already-authenticated
// requests and uses `actor` from the bearer/header for rate-limit
// scoping.
//
// The handler does NOT log raw_signed_tx bytes per the SPEC §4.3
// step 6 side-channel discipline (cancel rows follow the same).
//
// SPEC v0.1.21 §4.6 status codes:
//
//	200 OK     — atomic txn committed; cancel attempted post-COMMIT
//	400        — missing fields
//	404        — no matching (payout_id, attempt_seq) row
//	409        — already_confirmed / already_abandoned / runner_active
//	422        — gas-cap exceeded
//	429        — per-actor rate limit exceeded
func (s *AbandonService) ServeAbandon(w http.ResponseWriter, r *http.Request, actor string,
	caps AbandonCaps,
) {
	ctx := r.Context()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var req AbandonRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_format")
		return
	}
	if req.PayoutID == 0 || req.AttemptSeq <= 0 || !req.Confirm || strings.TrimSpace(req.Reason) == "" {
		writeError(w, http.StatusBadRequest, "missing_field")
		return
	}
	if r.Header.Get("Idempotency-Key") == "" {
		writeError(w, http.StatusBadRequest, "missing_field")
		return
	}
	if !s.allowRate(actor, caps.AbandonRatePerHour) {
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	// Tip multiplier cap (silently floored per SPEC).
	capApplied := false
	tipMult := req.TipMultiplier
	if tipMult > caps.CancelMaxTipMultiplier {
		tipMult = caps.CancelMaxTipMultiplier
		capApplied = true
	}
	if tipMult < 1.0 {
		tipMult = 1.0
	}
	// Compute gas estimate for the cancel tx (1-wei self-transfer
	// is ~21000 gas; the operator's tip multiplier scales the tip).
	gasEstimate := estimateCancelGas(tipMult)
	if gasEstimate > caps.CancelMaxGasNativeWei {
		writeError(w, http.StatusUnprocessableEntity, "cancel_gas_exceeds_per_request_cap")
		return
	}

	// BEGIN IMMEDIATE — runner-active gate + abandon UPDATE + cancel INSERT.
	conn, err := s.DB.Conn(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	// Runner-active gate.
	active, err := IsLeaseActive(ctx, conn, s.RunInterval)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if active {
		writeError(w, http.StatusConflict, "runner_active")
		return
	}

	// 24h-aggregate gas check (durable side).
	last24h := s.NowFn().Add(-24 * time.Hour).UTC().Format(time.RFC3339Nano)
	used, err := sumCancelGasLast24h(ctx, conn, s.Security.HotWalletAddress, last24h)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if used+gasEstimate > caps.CancelMaxGasNativeWeiPer24h {
		writeError(w, http.StatusUnprocessableEntity, "cancel_gas_exceeds_24h_aggregate")
		return
	}

	// Abandon-marker UPDATE.
	now := s.NowFn().UTC().Format(time.RFC3339Nano)
	res, err := conn.ExecContext(ctx, `
UPDATE payout_attempts
   SET abandoned_at_utc = ?,
       abandoned_reason = ?,
       updated_at_utc   = ?
 WHERE payout_id = ?
   AND attempt_seq = ?
   AND confirmed_at_utc IS NULL
   AND abandoned_at_utc IS NULL`,
		now, req.Reason, now, req.PayoutID, req.AttemptSeq)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	rowsAffected, err := res.RowsAffected()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if rowsAffected == 0 {
		// Disambiguate.
		var abandonedAt, confirmedAt sql.NullString
		row := conn.QueryRowContext(ctx,
			`SELECT abandoned_at_utc, confirmed_at_utc FROM payout_attempts WHERE payout_id=? AND attempt_seq=?`,
			req.PayoutID, req.AttemptSeq,
		)
		if err := row.Scan(&abandonedAt, &confirmedAt); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusNotFound, "not_found")
				return
			}
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		if confirmedAt.Valid {
			writeError(w, http.StatusConflict, "already_confirmed")
			return
		}
		if abandonedAt.Valid {
			writeError(w, http.StatusConflict, "already_abandoned")
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}

	resp := AbandonResponse{
		PayoutID:            req.PayoutID,
		AbandonedAttemptSeq: req.AttemptSeq,
		CapApplied:          capApplied,
	}

	// Cancel-row INSERT if requested.
	if req.BroadcastCancelSelfTransfer {
		// Read the original nonce.
		var origNonce int64
		err := conn.QueryRowContext(ctx,
			`SELECT nonce FROM payout_attempts WHERE payout_id=? AND attempt_seq=?`,
			req.PayoutID, req.AttemptSeq,
		).Scan(&origNonce)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		cancelSeq, err := NextAttemptSeq(ctx, conn, req.PayoutID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		// Build the cancel envelope (1-wei native self-transfer to
		// the hot wallet at the original nonce).
		tx, err := buildCancelTx(s.Security.HotWalletAddress, origNonce, tipMult)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		unsigned, err := tx.UnsignedRLP()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		signedBytes, txHash, err := s.Signer.SignTx(ctx, unsigned)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		// Cancel-broadcast preflight verification (v0.1.14 NORMATIVE).
		if err := verifyCancelEnvelope(tx, signedBytes, txHash, s.Security.HotWalletAddress); err != nil {
			s.emitChainValueMismatch(req.PayoutID, cancelSeq, txHash, "prebroadcast_signed_tx", err.Error())
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		// INSERT cancel row. gas_reserved_native_wei carries the
		// estimate so the 24h aggregate cap counts pending cancels
		// per codex round-1 [sec:2.1] closure.
		if _, err := conn.ExecContext(ctx, `
INSERT INTO payout_attempts
  (payout_id, attempt_seq, chain, from_address, to_address,
   amount_base_units, nonce, raw_signed_tx, tx_hash,
   is_cancel_self_transfer, gas_reserved_native_wei, updated_at_utc)
VALUES (?, ?, 'base-mainnet', ?, ?, 1, ?, ?, ?, 1, ?, ?)`,
			req.PayoutID, cancelSeq, strings.ToLower(s.Security.HotWalletAddress),
			strings.ToLower(s.Security.HotWalletAddress), origNonce,
			signedBytes, txHash, gasEstimate, now,
		); err != nil {
			if isUniqueViolation(err) {
				// idx_pa_from_nonce_active partial UNIQUE
				// trip — the abandon already lifted the
				// original row out so this should not fire
				// in a healthy SPEC implementation. Surface
				// as 500 + log for forensic review.
				s.Logger.Error().
					Err(err).
					Int64("payout_id", req.PayoutID).
					Int("cancel_seq", cancelSeq).
					Msg("cancel INSERT tripped idx_pa_from_nonce_active despite abandon-in-same-txn")
				writeError(w, http.StatusInternalServerError, "internal_error")
				return
			}
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		resp.CancelAttemptSeq = &cancelSeq
		resp.CancelTxHash = txHash
		// COMMIT BEFORE broadcasting.
		if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		committed = true
		// Post-COMMIT broadcast on both RPCs.
		acceptedAny, _, _, _, _ := s.RPCs.BroadcastBoth(ctx, signedBytes)
		if acceptedAny {
			resp.CancelBroadcasted = true
			// CAS-stamp broadcast_at_utc.
			_ = StampBroadcastAt(ctx, s.DB, req.PayoutID, cancelSeq, now)
		}
	} else {
		if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		committed = true
	}

	// §7.1 PAGE event.
	s.Logger.Warn().
		Str("event", "payout_attempt_abandoned").
		Str("severity", "PAGE").
		Int64("payout_id", req.PayoutID).
		Int("attempt_seq", req.AttemptSeq).
		Str("cancel_self_transfer_tx_hash", resp.CancelTxHash).
		Bool("cap_applied", capApplied).
		Str("reason", req.Reason).
		Str("actor", actor).
		Str("ts_utc", now).
		Send()

	writeJSON(w, http.StatusOK, resp)
}

// AbandonCaps groups the per-call cap config for ServeAbandon.
type AbandonCaps struct {
	CancelMaxTipMultiplier      float64
	CancelMaxGasNativeWei       int64
	CancelMaxGasNativeWeiPer24h int64
	AbandonRatePerHour          int
}

func (s *AbandonService) allowRate(actor string, ratePerHour int) bool {
	if ratePerHour <= 0 {
		return true
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := s.NowFn().Add(-time.Hour)
	kept := s.actorCalls[actor][:0]
	for _, t := range s.actorCalls[actor] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= ratePerHour {
		s.actorCalls[actor] = kept
		return false
	}
	s.actorCalls[actor] = append(kept, s.NowFn())
	return true
}

func (s *AbandonService) emitChainValueMismatch(payoutID int64, attemptSeq int, txHash, class, detail string) {
	s.Logger.Error().
		Str("event", "payout_chain_value_mismatch").
		Str("severity", "PAGE").
		Int64("payout_id", payoutID).
		Int("attempt_seq", attemptSeq).
		Str("tx_hash", txHash).
		Str("mismatch_class", class).
		Str("observed", detail).
		Str("ts_utc", s.NowFn().UTC().Format(time.RFC3339Nano)).
		Send()
}

// buildCancelTx builds a 1-wei native self-transfer at the
// original nonce with the requested tip multiplier applied.
func buildCancelTx(hotWalletAddress string, nonce int64, tipMultiplier float64) (EIP1559Tx, error) {
	hotBytes, err := AddressBytes(hotWalletAddress)
	if err != nil {
		return EIP1559Tx{}, err
	}
	var to [20]byte
	copy(to[:], hotBytes[:])
	baseTip := int64(2_000_000_000)
	tip := int64(float64(baseTip) * tipMultiplier)
	feeBaseFee := int64(20_000_000_000)
	maxFee := tip + feeBaseFee
	return EIP1559Tx{
		ChainID:              BaseMainnetChainID,
		Nonce:                uint64(nonce),
		MaxPriorityFeePerGas: big.NewInt(tip),
		MaxFeePerGas:         big.NewInt(maxFee),
		GasLimit:             21_000,
		To:                   to,
		Value:                big.NewInt(1),
		Data:                 nil,
	}, nil
}

// verifyCancelEnvelope is the v0.1.14 cancel-side preflight
// verification.
func verifyCancelEnvelope(unsigned EIP1559Tx, signed []byte, returnedHash, hotWalletAddress string) error {
	decoded, _, _, _, err := DecodeSignedEIP1559(signed)
	if err != nil {
		return fmt.Errorf("decode: %w", err)
	}
	if decoded.Nonce != unsigned.Nonce {
		return fmt.Errorf("nonce mismatch")
	}
	if decoded.ChainID != BaseMainnetChainID {
		return fmt.Errorf("chain_id != Base")
	}
	hotBytes, _ := AddressBytes(hotWalletAddress)
	for i := 0; i < 20; i++ {
		if decoded.To[i] != hotBytes[i] {
			return fmt.Errorf("to != hot_wallet")
		}
	}
	if decoded.Value == nil || decoded.Value.Sign() != 1 || decoded.Value.Int64() != 1 {
		return fmt.Errorf("value != 1 wei")
	}
	if len(decoded.Data) != 0 {
		return fmt.Errorf("input not empty")
	}
	if TxHash(signed) != returnedHash {
		return fmt.Errorf("tx_hash mismatch")
	}
	recovered, err := RecoverTxSender(signed)
	if err != nil {
		return fmt.Errorf("ecrecover: %w", err)
	}
	if !addressEqualFold(recovered, hotWalletAddress) {
		return fmt.Errorf("recovered sender != hot_wallet")
	}
	return nil
}

func estimateCancelGas(tipMultiplier float64) int64 {
	// Simplified: 21000 gas × (baseFee + tip*multiplier).
	// Real impl would query block-level base-fee; the cap-check
	// just needs an upper bound.
	baseTip := int64(2_000_000_000)
	tip := int64(float64(baseTip) * tipMultiplier)
	baseFee := int64(20_000_000_000)
	return int64(21_000) * (baseFee + tip)
}

// sumCancelGasLast24h returns the rolling 24h aggregate cancel
// gas — the live tally that the §4.6 endpoint compares against
// cancel_max_gas_native_wei_per_24h.
//
// Codex round-1 [sec:2.1] HIGH closure: the SUM now coalesces
// gas_used_native_wei (post-confirm) with gas_reserved_native_wei
// (post-INSERT, pre-confirm). Without this, a stolen operator
// key could fire abandon-attempt repeatedly while prior cancels
// are still pending — each request would see the same
// undercounted aggregate.
//
// The WHERE clause filters abandoned_at_utc IS NULL so abandoned
// cancels drop out of the budget. Confirmed rows are matched by
// broadcast_at_utc; pending unbroadcast cancels are also counted
// (their broadcast_at_utc is NULL but their reservation lives).
func sumCancelGasLast24h(ctx context.Context, conn *sql.Conn, fromAddress, since string) (int64, error) {
	var n sql.NullInt64
	if err := conn.QueryRowContext(ctx, `
SELECT COALESCE(SUM(COALESCE(gas_used_native_wei, gas_reserved_native_wei)), 0)
  FROM payout_attempts
 WHERE from_address = ?
   AND is_cancel_self_transfer = 1
   AND abandoned_at_utc IS NULL
   AND (
        (broadcast_at_utc IS NOT NULL AND broadcast_at_utc >= ?)
        OR (broadcast_at_utc IS NULL AND gas_reserved_native_wei IS NOT NULL)
   )`, strings.ToLower(fromAddress), since,
	).Scan(&n); err != nil {
		return 0, err
	}
	if !n.Valid {
		return 0, nil
	}
	return n.Int64, nil
}
