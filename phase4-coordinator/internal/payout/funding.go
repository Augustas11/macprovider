package payout

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/rs/zerolog"
)

// usdcTransferTopic is the 32-byte keccak256("Transfer(address,
// address,uint256)") event topic — common to all ERC-20s.
// Lowercase 0x-prefixed.
const usdcTransferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

// FundingService backs the §4.9 POST /admin/payout/record-funding
// endpoint. It supports two acceptance modes:
//
//  1. source='manual' — accepted ONLY when payout_runner_state.
//     payout_bootstrap_complete = 0 AND the three bootstrap
//     triggers are present (intra-txn count == 3). Closes the
//     v0.1.4 operator-key-compromise fake-funding attack class.
//
//  2. source='rpc-confirmed' — accepted when BOTH RPCs return a
//     receipt with matching to=USDC, USDC Transfer log with
//     from=request.from_address, to=hot_wallet, value=amount,
//     block_number, status=success.
type FundingService struct {
	db               *sql.DB
	rpcs             *TwoRPCs
	hotWalletAddress string // EIP-55 checksummed
	usdcAddress      string // EIP-55 checksummed (USDC contract on Base)
	actor            string // §7.1 actor=operator_key:<label>
	log              zerolog.Logger
	nowFn            func() time.Time
}

// FundingOptions bundles the dependencies for the funding service.
type FundingOptions struct {
	DB               *sql.DB
	RPCs             *TwoRPCs
	HotWalletAddress string
	USDCAddress      string
	// Actor is the §7.1 actor=operator_key field surfaced on
	// payout_funding_recorded. Non-secret label like
	// "operator_key:coordinator". Codex Step 3 r1 [code:1.4]
	// MEDIUM closure.
	Actor  string
	Logger zerolog.Logger
	NowFn  func() time.Time
}

// NewFundingService constructs the service. usdcAddress is the
// USDC contract address on Base (constant; pinned via
// payout.security.usdc_contract per §4.4). hotWalletAddress is
// payout.security.hot_wallet_address, the only legal recipient.
func NewFundingService(opts FundingOptions) (*FundingService, error) {
	if opts.DB == nil {
		return nil, errors.New("payout.NewFundingService: DB required")
	}
	if opts.HotWalletAddress == "" {
		return nil, errors.New("payout.NewFundingService: HotWalletAddress required")
	}
	if opts.USDCAddress == "" {
		return nil, errors.New("payout.NewFundingService: USDCAddress required")
	}
	nowFn := opts.NowFn
	if nowFn == nil {
		nowFn = time.Now
	}
	return &FundingService{
		db:               opts.DB,
		rpcs:             opts.RPCs,
		hotWalletAddress: opts.HotWalletAddress,
		usdcAddress:      opts.USDCAddress,
		actor:            opts.Actor,
		log:              opts.Logger,
		nowFn:            nowFn,
	}, nil
}

// recordFundingRequest mirrors the §4.9 request body verbatim.
type recordFundingRequest struct {
	FromAddress     string `json:"from_address"`
	ToAddress       string `json:"to_address"`
	AmountBaseUnits int64  `json:"amount_base_units"`
	TxHash          string `json:"tx_hash"`
	BlockNumber     uint64 `json:"block_number"`
	Source          string `json:"source"`
	OperatorNote    string `json:"operator_note"`
}

// ServeRecordFunding handles POST /admin/payout/record-funding.
//
// Response table per §4.9:
//   - 201 Created on insert + payout_funding_recorded event.
//   - 400 missing_field / amount_base_units<=0 / to!=hot /
//     from==hot (v0.1.20 round-20 C2: hot wallet may not fund
//     itself per §3.2 deny-list).
//   - 409 Conflict — UNIQUE(tx_hash) violation.
//   - 422 receipt_mismatch / receipt_not_available /
//     bootstrap_complete / bootstrap_trigger_missing /
//     idempotency_key_mismatch.
func (s *FundingService) ServeRecordFunding(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64*1024))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_format")
		return
	}
	var req recordFundingRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_format")
		return
	}
	if req.AmountBaseUnits <= 0 ||
		req.FromAddress == "" || req.ToAddress == "" ||
		req.TxHash == "" || req.Source == "" {
		writeError(w, http.StatusBadRequest, "missing_field")
		return
	}
	// SPEC §4.9: idempotency-key MUST equal tx_hash (case-insensitive
	// lowercase 0x-hex). v0.1.20 round-20 C1 closure.
	idemHeader := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if idemHeader == "" || !strings.EqualFold(idemHeader, req.TxHash) {
		writeError(w, http.StatusUnprocessableEntity, "idempotency_key_mismatch")
		return
	}
	// Normalize addresses to lowercase 0x... for storage; comparison
	// against hot_wallet is case-insensitive per §3.2.
	fromLower := strings.ToLower(strings.TrimSpace(req.FromAddress))
	toLower := strings.ToLower(strings.TrimSpace(req.ToAddress))
	hotLower := strings.ToLower(s.hotWalletAddress)
	usdcLower := strings.ToLower(s.usdcAddress)
	if !strings.EqualFold(toLower, hotLower) {
		writeError(w, http.StatusBadRequest, "to_address_must_equal_hot_wallet")
		return
	}
	if strings.EqualFold(fromLower, hotLower) {
		// v0.1.20 round-20 C2 closure: §3.2 deny-list — hot wallet
		// may not fund itself.
		writeError(w, http.StatusBadRequest, "from_address_is_hot_wallet")
		return
	}

	switch req.Source {
	case "manual":
		s.serveManual(w, r, req, fromLower, toLower)
	case "rpc-confirmed":
		s.serveRPCConfirmed(w, r, req, fromLower, toLower, usdcLower)
	default:
		writeError(w, http.StatusBadRequest, "invalid_source")
	}
}

// serveManual handles source='manual' — the bootstrap-only path.
// SPEC §4.8a intra-txn trigger-presence check + bootstrap-window
// check both run inside one BEGIN IMMEDIATE so a DROP+UPDATE+
// CREATE attack inside the same cadence is detected at the
// money-path call boundary.
func (s *FundingService) serveManual(
	w http.ResponseWriter, r *http.Request,
	req recordFundingRequest, fromLower, toLower string,
) {
	conn, err := s.db.Conn(r.Context())
	if err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	defer conn.Close()
	if _, err := conn.ExecContext(r.Context(), `BEGIN IMMEDIATE`); err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	// Step 1 — intra-txn bootstrap-trigger presence check
	// (SPEC §4.8a NORMATIVE, L2514-2538). Count MUST be 3.
	var triggerCount int
	err = conn.QueryRowContext(r.Context(), `
SELECT count(*) FROM sqlite_master
 WHERE type='trigger'
   AND name IN ('trg_prs_bootstrap_one_way',
                'trg_pa_bootstrap_flip',
                'trg_pa_bootstrap_flip_insert')`).Scan(&triggerCount)
	if err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if triggerCount != 3 {
		s.log.Error().
			Str("event", "payout_invariant_violation").
			Str("where", "bootstrap_trigger_missing").
			Int("trigger_count", triggerCount).
			Str("severity", "PAGE").
			Send()
		writeError(w, http.StatusUnprocessableEntity, "bootstrap_trigger_missing")
		return
	}

	// Step 2 — bootstrap-window check. payout_bootstrap_complete
	// MUST be 0 for source='manual'.
	var bootstrapComplete int
	err = conn.QueryRowContext(r.Context(),
		`SELECT payout_bootstrap_complete FROM payout_runner_state WHERE id = 1`,
	).Scan(&bootstrapComplete)
	if err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	// Step 2b — durable bootstrap-reopen defense (codex Step 3 r1
	// [sec:1] CRITICAL closure). An attacker with raw DB write
	// could DROP trg_prs_bootstrap_one_way (the one-way trigger),
	// UPDATE payout_bootstrap_complete back to 0, CREATE the
	// trigger again, and then call source='manual'. At THIS point
	// the trigger-count check passes (count=3) AND the flag is
	// back to 0. The attack class is closed by binding manual-
	// funding acceptance to DURABLE payout history: if ANY
	// payout_attempts row has ever confirmed, source='manual' is
	// FORBIDDEN regardless of the flag's current value.
	var confirmedExists int
	if err := conn.QueryRowContext(r.Context(), `
SELECT EXISTS(
    SELECT 1 FROM payout_attempts
     WHERE confirmed_at_utc IS NOT NULL
     LIMIT 1
)`).Scan(&confirmedExists); err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if bootstrapComplete != 0 || confirmedExists != 0 {
		// If the flag was reset to 0 but a confirmed row exists,
		// emit payout_invariant_violation where='bootstrap_flag_reopened'
		// per §7.1 (severity=PAGE) BEFORE returning 422. This is
		// the tamper-signal class — the SPEC §4.8a sentinel-asymmetry
		// detector at startup HALTs on this; but a runtime endpoint
		// hit can see it too if the attack lands between boots.
		if bootstrapComplete == 0 && confirmedExists != 0 {
			s.log.Error().
				Str("event", "payout_invariant_violation").
				Str("where", "bootstrap_flag_reopened").
				Str("severity", "PAGE").
				Msg("source='manual' rejected: payout_bootstrap_complete=0 but confirmed payout_attempts exist (DROP+RESET+CREATE tamper signal)")
		}
		writeError(w, http.StatusUnprocessableEntity, "bootstrap_complete")
		return
	}

	// Step 3 — INSERT.
	if err := insertFundingRowTx(r.Context(), conn,
		fromLower, toLower, req.AmountBaseUnits, req.TxHash,
		req.BlockNumber, "manual", req.OperatorNote, s.nowFn(),
	); err != nil {
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "tx_hash_already_recorded")
			return
		}
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}

	if _, err := conn.ExecContext(r.Context(), `COMMIT`); err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	committed = true

	s.emitFundingRecorded(req, "manual", s.actor)
	writeJSON(w, http.StatusCreated, map[string]any{
		"ok":     true,
		"source": "manual",
	})
}

// serveRPCConfirmed handles source='rpc-confirmed' — verify the
// funding tx receipt on BOTH RPCs per §4.9.
func (s *FundingService) serveRPCConfirmed(
	w http.ResponseWriter, r *http.Request,
	req recordFundingRequest, fromLower, toLower, usdcLower string,
) {
	if s.rpcs == nil {
		s.log.Error().Str("event", "payout_funding_rpc_unavailable").Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	ctx := r.Context()
	recA, errA := s.rpcs.Primary.TransactionReceipt(ctx, req.TxHash)
	recB, errB := s.rpcs.Secondary.TransactionReceipt(ctx, req.TxHash)
	if errA != nil || errB != nil {
		s.log.Warn().AnErr("primary", errA).AnErr("secondary", errB).
			Str("event", "payout_funding_rpc_error").Send()
		writeError(w, http.StatusUnprocessableEntity, "receipt_not_available")
		return
	}
	if recA == nil || recB == nil {
		writeError(w, http.StatusUnprocessableEntity, "receipt_not_available")
		return
	}
	if err := verifyFundingReceipt(recA, req, fromLower, toLower, usdcLower); err != nil {
		s.log.Warn().Err(err).Str("side", "primary").
			Str("event", "payout_funding_receipt_mismatch").Send()
		writeError(w, http.StatusUnprocessableEntity, "receipt_mismatch")
		return
	}
	if err := verifyFundingReceipt(recB, req, fromLower, toLower, usdcLower); err != nil {
		s.log.Warn().Err(err).Str("side", "secondary").
			Str("event", "payout_funding_receipt_mismatch").Send()
		writeError(w, http.StatusUnprocessableEntity, "receipt_mismatch")
		return
	}

	// Both receipts verified — insert via a simpler txn (no
	// bootstrap-trigger check needed; rpc-confirmed is the
	// post-bootstrap path).
	conn, err := s.db.Conn(ctx)
	if err != nil {
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	defer conn.Close()
	if err := insertFundingRowDirect(ctx, conn,
		fromLower, toLower, req.AmountBaseUnits, req.TxHash,
		req.BlockNumber, "rpc-confirmed", req.OperatorNote, s.nowFn(),
	); err != nil {
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "tx_hash_already_recorded")
			return
		}
		s.log.Error().Err(err).Send()
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	s.emitFundingRecorded(req, "rpc-confirmed", s.actor)
	writeJSON(w, http.StatusCreated, map[string]any{
		"ok":     true,
		"source": "rpc-confirmed",
	})
}

// verifyFundingReceipt asserts the §4.9 receipt invariants
// against ONE RPC's view. Called for both primary and secondary
// receipts; both MUST pass before insert.
func verifyFundingReceipt(rec *Receipt, req recordFundingRequest, fromLower, toLower, usdcLower string) error {
	if rec.Status != 1 {
		return fmt.Errorf("receipt status != success (got %d)", rec.Status)
	}
	if !strings.EqualFold(rec.To, usdcLower) {
		return fmt.Errorf("receipt to %s != USDC %s", rec.To, usdcLower)
	}
	if rec.BlockNumber != req.BlockNumber {
		return fmt.Errorf("receipt block_number %d != request %d", rec.BlockNumber, req.BlockNumber)
	}
	// Find the USDC Transfer log with from=request.from_address,
	// to=hot_wallet, value=amount_base_units.
	for _, lg := range rec.Logs {
		if !strings.EqualFold(lg.Address, usdcLower) {
			continue
		}
		if len(lg.Topics) != 3 {
			continue
		}
		if !strings.EqualFold(lg.Topics[0], usdcTransferTopic) {
			continue
		}
		logFrom := strings.ToLower(addressFromTopic(lg.Topics[1]))
		logTo := strings.ToLower(addressFromTopic(lg.Topics[2]))
		if !strings.EqualFold(logFrom, fromLower) {
			continue
		}
		if !strings.EqualFold(logTo, toLower) {
			continue
		}
		// Codex Step 3 r1 [sec:2] HIGH closure: strict uint256
		// decode. The ABI mandates a 32-byte word; reject any
		// other length AND any non-zero high 24 bytes (would
		// represent a value > uint64 max that the previous
		// low-8-byte parser would silently truncate to match).
		if len(lg.Data) != 32 {
			return fmt.Errorf("transfer log value must be 32 bytes, got %d", len(lg.Data))
		}
		for i := 0; i < 24; i++ {
			if lg.Data[i] != 0 {
				return fmt.Errorf("transfer log value exceeds uint64 (non-zero byte at offset %d)", i)
			}
		}
		got := new(big.Int).SetBytes(lg.Data)
		want := big.NewInt(req.AmountBaseUnits)
		if got.Cmp(want) != 0 {
			return fmt.Errorf("transfer log value %s != request amount %d", got.String(), req.AmountBaseUnits)
		}
		return nil
	}
	return errors.New("no matching USDC Transfer log on receipt")
}

// addressFromTopic strips the 12-byte left-pad from a 32-byte
// indexed-address topic, returning a 0x-prefixed 20-byte hex
// string. The topic is the ABI-encoded address, left-padded.
func addressFromTopic(topic string) string {
	t := strings.TrimPrefix(strings.ToLower(topic), "0x")
	if len(t) < 40 {
		return topic
	}
	return "0x" + t[len(t)-40:]
}

// insertFundingRowTx INSERTs into payout_hot_wallet_funding using
// an existing connection inside a transaction the caller manages.
func insertFundingRowTx(
	ctx context.Context, conn *sql.Conn,
	fromAddr, toAddr string, amount int64, txHash string,
	blockNumber uint64, source, operatorNote string, now time.Time,
) error {
	stamp := now.UTC().Format(time.RFC3339Nano)
	var noteCol any
	if operatorNote == "" {
		noteCol = nil
	} else {
		noteCol = operatorNote
	}
	_, err := conn.ExecContext(ctx, `
INSERT INTO payout_hot_wallet_funding
    (from_address, to_address, amount_base_units, tx_hash,
     block_number, observed_at_utc, source, operator_note)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		fromAddr, toAddr, amount, strings.ToLower(strings.TrimSpace(txHash)),
		blockNumber, stamp, source, noteCol,
	)
	return err
}

// insertFundingRowDirect runs the same INSERT but using the
// connection's autocommit. Used by serveRPCConfirmed which does
// not need the intra-txn bootstrap check.
func insertFundingRowDirect(
	ctx context.Context, conn *sql.Conn,
	fromAddr, toAddr string, amount int64, txHash string,
	blockNumber uint64, source, operatorNote string, now time.Time,
) error {
	stamp := now.UTC().Format(time.RFC3339Nano)
	var noteCol any
	if operatorNote == "" {
		noteCol = nil
	} else {
		noteCol = operatorNote
	}
	_, err := conn.ExecContext(ctx, `
INSERT INTO payout_hot_wallet_funding
    (from_address, to_address, amount_base_units, tx_hash,
     block_number, observed_at_utc, source, operator_note)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		fromAddr, toAddr, amount, strings.ToLower(strings.TrimSpace(txHash)),
		blockNumber, stamp, source, noteCol,
	)
	return err
}

// emitFundingRecorded emits the §7.1 payout_funding_recorded event.
// Field set per §7.1 row: from_address, to_address,
// amount_base_units, tx_hash, block_number, source, operator_note,
// actor=operator_key, ts_utc. Codex Step 3 r1 [code:1.4] MEDIUM
// closure added operator_note + actor.
func (s *FundingService) emitFundingRecorded(req recordFundingRequest, source, actor string) {
	s.log.Info().
		Str("event", "payout_funding_recorded").
		Str("from_address", strings.ToLower(req.FromAddress)).
		Str("to_address", strings.ToLower(req.ToAddress)).
		Int64("amount_base_units", req.AmountBaseUnits).
		Str("tx_hash", strings.ToLower(req.TxHash)).
		Uint64("block_number", req.BlockNumber).
		Str("source", source).
		Str("operator_note", req.OperatorNote).
		Str("actor", actor).
		Str("ts_utc", s.nowFn().UTC().Format(time.RFC3339Nano)).
		Send()
}
