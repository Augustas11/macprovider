package payout

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// reconcileSQL is the SPEC §7.4 weekly reconciliation queries
// file embedded at build time. The file is read at runtime by
// ParseLabeledQueries so operators MAY edit reconcile.sql
// without recompiling — but the build pins a specific version
// so a smoke test can assert checksum parity against the SPEC.
//
//go:embed reconcile.sql
var reconcileSQL string

// LabeledQueries are the §7.4 named queries A through F. The
// unlabeled regression queries (per-provider delta, NULL
// payout_currency detector, chain-balance recon) are accessed via
// UnlabeledQueries instead because the SPEC reserves A/B/C/D/E/F
// for the labeled set.
type LabeledQueries map[string]string

// ParseLabeledQueries walks the embedded reconcile.sql file and
// returns:
//
//   - labeled: a map of "A"…"F" → SQL statement (without the
//     `-- @label: X` directive line).
//   - unlabeled: a slice of SQL statements that appear without
//     a label directive — these are the three SPEC §7.4
//     regression queries (per-provider delta, NULL payout_currency
//     detector, chain-balance recon).
//
// Parsing rule: statements are delimited by `;` followed by an
// end-of-line; a comment line of the form `-- @label: X` at the
// top of a statement sets the label for that statement.
func ParseLabeledQueries() (labeled LabeledQueries, unlabeled []string) {
	labeled = make(LabeledQueries)
	// Strip the file-level header (everything before the first
	// SELECT) so the parser sees just the statement bodies.
	body := reconcileSQL
	stmts := splitStatements(body)
	for _, raw := range stmts {
		stmt := strings.TrimSpace(raw)
		if stmt == "" {
			continue
		}
		label, sql := extractLabel(stmt)
		if label != "" {
			labeled[label] = sql
		} else if hasSelect(sql) {
			unlabeled = append(unlabeled, sql)
		}
	}
	return labeled, unlabeled
}

// hasSelect filters out pure-comment chunks that fall between
// statements (the SPEC file has --- separator banners between
// each query that the splitter would otherwise treat as
// "statements"). Detects SELECT on its own line (the SPEC SQL
// pattern) OR with a trailing space (selects with same-line
// projection).
func hasSelect(s string) bool {
	for _, line := range strings.Split(s, "\n") {
		stripped := strings.TrimSpace(stripLineComment(line))
		upper := strings.ToUpper(stripped)
		if upper == "SELECT" || strings.HasPrefix(upper, "SELECT ") || strings.HasPrefix(upper, "SELECT\t") {
			return true
		}
	}
	return false
}

// splitStatements walks line-by-line, ignoring `;` characters that
// appear inside `--` line comments. SPEC §7.4 reconcile.sql has
// explanatory comments that contain semicolons (e.g. "non-zero
// result is a SEV-1 incident; ..."); a naive split-on-`;` would
// fracture those comments and break ParseLabeledQueries.
//
// Conservative tokenizer: only `--` line comments are recognised
// (the SPEC SQL has no `/* */` block comments or string literals
// containing `;`). If those appear in a future SPEC version, this
// function will need a fuller tokenizer.
func splitStatements(s string) []string {
	var stmts []string
	var cur strings.Builder
	for _, line := range strings.Split(s, "\n") {
		// Strip the comment tail so a `;` inside a comment does
		// not affect statement boundaries.
		stripped := stripLineComment(line)
		// Find the first `;` in the comment-stripped portion;
		// split the statement there.
		for {
			idx := strings.Index(stripped, ";")
			if idx < 0 {
				cur.WriteString(line)
				cur.WriteByte('\n')
				break
			}
			// We have a statement terminator. Append everything up
			// to and including the `;` to the current statement.
			cur.WriteString(line[:idx+1])
			out := strings.TrimSpace(cur.String())
			if out != "" {
				stmts = append(stmts, out)
			}
			cur.Reset()
			// Continue parsing the rest of the line for additional
			// statements (multiple per line is rare but legal).
			line = line[idx+1:]
			stripped = stripped[idx+1:]
		}
	}
	if leftover := strings.TrimSpace(cur.String()); leftover != "" {
		stmts = append(stmts, leftover)
	}
	return stmts
}

// stripLineComment returns the portion of line before the first
// `--` line-comment marker, OR the entire line if there is none.
// Used by splitStatements to ignore `;` characters inside
// comments.
func stripLineComment(line string) string {
	if idx := strings.Index(line, "--"); idx >= 0 {
		return line[:idx]
	}
	return line
}

// extractLabel scans the LEADING comment/blank prefix of a statement
// looking for `-- @label: X` and returns (label, statement_without_label_comment).
// Returns ("", original) if no label found.
//
// Step 4 r1 [code:r1-6] LOW closure: the scan stops as soon as a
// non-comment, non-blank line is encountered. A `-- @label:` directive
// that appears inside the SQL body (e.g. a body comment) is preserved
// verbatim in the output rather than stripped.
func extractLabel(stmt string) (string, string) {
	lines := strings.Split(stmt, "\n")
	var sqlLines []string
	label := ""
	leadingBlock := true // true while we are still in the leading comment prefix
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if leadingBlock {
			if trimmed == "" {
				// blank line — still in leading prefix; keep it
				sqlLines = append(sqlLines, line)
				continue
			}
			if strings.HasPrefix(trimmed, "-- @label:") {
				// directive line in the leading block — extract and drop it
				label = strings.TrimSpace(strings.TrimPrefix(trimmed, "-- @label:"))
				continue
			}
			if strings.HasPrefix(trimmed, "--") {
				// other comment line in the leading block — keep it, still leading
				sqlLines = append(sqlLines, line)
				continue
			}
			// First non-comment, non-blank line: SQL body begins here
			leadingBlock = false
		}
		sqlLines = append(sqlLines, line)
	}
	return label, strings.TrimSpace(strings.Join(sqlLines, "\n"))
}

// ReconcileSQLRaw returns the embedded reconcile.sql file
// verbatim. Used by the audit pipeline to assert checksum parity
// against the SPEC body.
func ReconcileSQLRaw() string {
	return reconcileSQL
}

// ----------------------------------------------------------------------
// SPEC §7.4 chain-balance reconciliation worker (Step 4).
// ----------------------------------------------------------------------

// balanceOfSelector is keccak256("balanceOf(address)")[:4] —
// the ABI function selector for ERC-20 balanceOf.
var balanceOfSelector = []byte{0x70, 0xa0, 0x82, 0x31}

// usdcBalanceCalldata returns the 36-byte ABI-encoded calldata
// for `balanceOf(address)` against the given holder.
func usdcBalanceCalldata(holderAddr string) []byte {
	// Strip 0x prefix, pad to 32 bytes, prepend the 4-byte
	// selector. Lower-case for parity with the per-byte decode.
	h := strings.TrimPrefix(strings.ToLower(holderAddr), "0x")
	// Left-pad to 64 hex chars (32 bytes).
	for len(h) < 64 {
		h = "0" + h
	}
	addrBytes := make([]byte, 32)
	for i := 0; i < 32; i++ {
		hi := hexDigit(h[2*i])
		lo := hexDigit(h[2*i+1])
		addrBytes[i] = byte(hi<<4 | lo)
	}
	out := make([]byte, 4+32)
	copy(out[:4], balanceOfSelector)
	copy(out[4:], addrBytes)
	return out
}

func hexDigit(c byte) uint8 {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10
	}
	return 0
}

// ChainBalanceConfig bundles the immutable §6.5
// `payout.security.chain_recon_*` keys + the hot wallet address.
// Pure-value type — no shared mutable state with the SIGHUP
// tuning provider. SPEC §6.5 architectural invariant.
type ChainBalanceConfig struct {
	Interval      time.Duration
	ToleranceUSDC int64 // base units
	HotWalletAddr string
	USDCContract  string
}

// ChainBalanceWorker periodically reconciles in-DB
// total_funded - total_paid_out against on-chain
// balanceOf(hot_wallet) (queried from BOTH RPCs). Drift outside
// the tolerance emits a SIGNED §7.1 event:
//
//   - on_chain - expected > tolerance → payout_chain_balance_drift_positive (WARN).
//   - on_chain - expected < -tolerance → payout_chain_balance_drift_negative (PAGE)
//     AND the worker HALTs the runner via the supplied haltFn callback
//     (the operator-key-compromise fake-funding signature; SPEC §7.4).
//
// Two-RPC disagreement on balanceOf emits
// payout_chain_balance_rpc_disagreement and SKIPs that tick (no
// drift comparison, no halt) — the next tick re-evaluates after the
// transient stabilises. Named distinctly from payout_rpc_disagreement
// (§7.1 payout-row receipts schema) to avoid consumer misparse.
type ChainBalanceWorker struct {
	db         *sql.DB
	rpcs       TwoRPCs
	cfg        ChainBalanceConfig
	haltRunner func(reason string)
	log        zerolog.Logger
	nowFn      func() time.Time

	mu       sync.Mutex
	cancel   context.CancelFunc
	done     chan struct{}
	started  bool
	stopOnce sync.Once
}

// NewChainBalanceWorker constructs a stopped worker. haltRunner
// is invoked from the negative-drift PAGE path; the implementation
// is supplied by main.go and typically calls Runner.Halt OR sets
// a runtime flag the next runner cycle observes. It MUST be safe
// to call from any goroutine.
func NewChainBalanceWorker(
	db *sql.DB,
	rpcs TwoRPCs,
	cfg ChainBalanceConfig,
	haltRunner func(reason string),
	log zerolog.Logger,
) (*ChainBalanceWorker, error) {
	if db == nil {
		return nil, errors.New("payout.NewChainBalanceWorker: DB required")
	}
	if cfg.Interval <= 0 {
		return nil, errors.New("payout.NewChainBalanceWorker: Interval must be > 0")
	}
	if cfg.ToleranceUSDC < 0 {
		return nil, errors.New("payout.NewChainBalanceWorker: ToleranceUSDC must be >= 0")
	}
	if cfg.HotWalletAddr == "" {
		return nil, errors.New("payout.NewChainBalanceWorker: HotWalletAddr required")
	}
	if cfg.USDCContract == "" {
		cfg.USDCContract = USDCContractAddressBase
	}
	return &ChainBalanceWorker{
		db:         db,
		rpcs:       rpcs,
		cfg:        cfg,
		haltRunner: haltRunner,
		log:        log,
		nowFn:      time.Now,
	}, nil
}

// Start launches the background loop at cfg.Interval cadence.
// Mirrors Runner/Reaper/ReorgPoller Start/Stop semantics: eager
// first pass + ticker; idempotent.
func (w *ChainBalanceWorker) Start(ctx context.Context) {
	w.mu.Lock()
	if w.started {
		w.mu.Unlock()
		return
	}
	innerCtx, cancel := context.WithCancel(ctx)
	w.cancel = cancel
	w.done = make(chan struct{})
	w.started = true
	w.mu.Unlock()

	go func() {
		defer close(w.done)
		ticker := time.NewTicker(w.cfg.Interval)
		defer ticker.Stop()
		w.runOnce(innerCtx)
		for {
			select {
			case <-innerCtx.Done():
				return
			case <-ticker.C:
				w.runOnce(innerCtx)
			}
		}
	}()
}

// Stop signals the loop to exit and waits up to ctx.Done() for
// it to finish. Returns true on clean exit, false on ctx
// timeout. Mirrors Runner.Stop / Reaper.Stop / ReorgPoller.Stop.
func (w *ChainBalanceWorker) Stop(ctx context.Context) bool {
	w.mu.Lock()
	if !w.started {
		w.mu.Unlock()
		return true
	}
	w.mu.Unlock()
	w.stopOnce.Do(func() {
		if w.cancel != nil {
			w.cancel()
		}
	})
	select {
	case <-w.done:
		return true
	case <-ctx.Done():
		return false
	}
}

// runOnce performs ONE reconciliation tick. Errors are emitted
// as §7.1 events; the worker NEVER panics out of the tick
// (degraded telemetry is preferred to a process crash on
// transient RPC failure).
func (w *ChainBalanceWorker) runOnce(ctx context.Context) {
	calldata := usdcBalanceCalldata(w.cfg.HotWalletAddr)
	// Query BOTH RPCs.
	resA, errA := w.rpcs.Primary.CallContract(ctx, w.cfg.USDCContract, calldata)
	resB, errB := w.rpcs.Secondary.CallContract(ctx, w.cfg.USDCContract, calldata)
	if errA != nil || errB != nil {
		w.log.Warn().AnErr("primary", errA).AnErr("secondary", errB).
			Str("event", "payout_chain_balance_rpc_error").
			Str("severity", "WARN").
			Str("ts_utc", w.nowFn().UTC().Format(time.RFC3339Nano)).Send()
		return
	}
	balA, ok := parseBalanceResult(resA)
	if !ok {
		w.log.Warn().Str("event", "payout_chain_balance_decode_error").
			Str("side", "primary").Send()
		return
	}
	balB, ok := parseBalanceResult(resB)
	if !ok {
		w.log.Warn().Str("event", "payout_chain_balance_decode_error").
			Str("side", "secondary").Send()
		return
	}

	// SPEC §7.4: BOTH RPCs MUST agree within the SAME tolerance;
	// disagreement triggers payout_chain_balance_rpc_disagreement
	// and SKIPs the drift comparison.
	//
	// Step 4 r3 [code:r3-3] MEDIUM closure: renamed from
	// payout_rpc_disagreement to payout_chain_balance_rpc_disagreement
	// to avoid schema collision with §7.1 payout_rpc_disagreement
	// (payout-row receipts disagreement schema: payout_id, attempt_seq,
	// rpc_a_state, rpc_b_state). This event emits chain-balance-specific
	// fields (primary_balance, secondary_balance, tolerance); the distinct
	// name prevents consumer misparse.
	tol := big.NewInt(w.cfg.ToleranceUSDC)
	diff := new(big.Int).Sub(balA, balB)
	if absBig(diff).Cmp(tol) > 0 {
		// Step 4 r4 [code:r4-2] MEDIUM closure: add hot_wallet field so
		// multi-wallet or rotated-wallet logs are attributable.
		w.log.Error().
			Str("event", "payout_chain_balance_rpc_disagreement").
			Str("severity", "PAGE").
			Str("primary_balance", balA.String()).
			Str("secondary_balance", balB.String()).
			Int64("tolerance", w.cfg.ToleranceUSDC).
			Str("hot_wallet", w.cfg.HotWalletAddr).
			Str("ts_utc", w.nowFn().UTC().Format(time.RFC3339Nano)).Send()
		return
	}

	// Use primary as the canonical on-chain reading (already
	// agreed within tolerance).
	onChain := balA
	expected, err := w.computeExpectedBalance(ctx)
	if err != nil {
		w.log.Warn().Err(err).
			Str("event", "payout_chain_balance_db_error").Send()
		return
	}
	drift := new(big.Int).Sub(onChain, expected)
	if drift.Sign() == 0 || absBig(drift).Cmp(tol) <= 0 {
		// Within tolerance — green tick.
		w.log.Debug().
			Str("event", "payout_chain_balance_ok").
			Str("on_chain", onChain.String()).
			Str("expected", expected.String()).
			Str("drift", drift.String()).Send()
		return
	}
	if drift.Sign() > 0 {
		// Positive drift: on_chain > expected. Operator likely
		// forgot to record a funding deposit. WARN.
		// Step 4 r2 [code:r2-4] MEDIUM closure: §7.1 field names —
		// from_address, in_db_expected_usdc_base_units,
		// on_chain_usdc_base_units, drift_usdc_base_units (was
		// hot_wallet / expected / on_chain / drift).
		w.log.Warn().
			Str("event", "payout_chain_balance_drift_positive").
			Str("severity", "WARN").
			Str("from_address", w.cfg.HotWalletAddr).
			Str("in_db_expected_usdc_base_units", expected.String()).
			Str("on_chain_usdc_base_units", onChain.String()).
			Str("drift_usdc_base_units", drift.String()).
			Int64("tolerance", w.cfg.ToleranceUSDC).
			Str("ts_utc", w.nowFn().UTC().Format(time.RFC3339Nano)).Send()
		return
	}
	// Negative drift: on_chain < expected. SPEC §7.4: fake-funding
	// signature; PAGE + HALT the runner.
	// Step 4 r2 [code:r2-4] MEDIUM closure: §7.1 field names same as above.
	w.log.Error().
		Str("event", "payout_chain_balance_drift_negative").
		Str("severity", "PAGE").
		Str("from_address", w.cfg.HotWalletAddr).
		Str("in_db_expected_usdc_base_units", expected.String()).
		Str("on_chain_usdc_base_units", onChain.String()).
		Str("drift_usdc_base_units", drift.String()).
		Int64("tolerance", w.cfg.ToleranceUSDC).
		Str("ts_utc", w.nowFn().UTC().Format(time.RFC3339Nano)).Send()
	if w.haltRunner != nil {
		w.haltRunner("payout_chain_balance_drift_negative")
	}
}

// computeExpectedBalance returns the unlabeled §7.4 chain-recon
// SQL: total_funded - total_paid_out (cancel rows excluded).
func (w *ChainBalanceWorker) computeExpectedBalance(ctx context.Context) (*big.Int, error) {
	hotLower := strings.ToLower(w.cfg.HotWalletAddr)
	var fundedTxt, paidTxt sql.NullString
	err := w.db.QueryRowContext(ctx, `
SELECT
  COALESCE(SUM(amount_base_units), 0)
  FROM payout_hot_wallet_funding
 WHERE lower(to_address) = ?`, hotLower).Scan(&fundedTxt)
	if err != nil {
		return nil, fmt.Errorf("funded: %w", err)
	}
	err = w.db.QueryRowContext(ctx, `
SELECT
  COALESCE(SUM(amount_base_units), 0)
  FROM payout_attempts
 WHERE confirmed_at_utc IS NOT NULL
   AND abandoned_at_utc IS NULL
   AND is_cancel_self_transfer = 0
   AND lower(from_address) = ?`, hotLower).Scan(&paidTxt)
	if err != nil {
		return nil, fmt.Errorf("paid: %w", err)
	}
	funded, _ := new(big.Int).SetString(fundedTxt.String, 10)
	if funded == nil {
		funded = big.NewInt(0)
	}
	paid, _ := new(big.Int).SetString(paidTxt.String, 10)
	if paid == nil {
		paid = big.NewInt(0)
	}
	return new(big.Int).Sub(funded, paid), nil
}

// parseBalanceResult decodes the 32-byte ABI uint256 returned by
// eth_call. Returns (value, true) on success, (nil, false) if the
// result is shorter than 32 bytes (RPC quirk; treat as decode
// error). Higher bytes pass through unchecked because USDC
// supply > uint64 is legal at scale.
func parseBalanceResult(data []byte) (*big.Int, bool) {
	if len(data) < 32 {
		return nil, false
	}
	return new(big.Int).SetBytes(data[len(data)-32:]), true
}

// absBig returns |n| as a new big.Int.
func absBig(n *big.Int) *big.Int {
	if n.Sign() < 0 {
		return new(big.Int).Neg(n)
	}
	return new(big.Int).Set(n)
}
