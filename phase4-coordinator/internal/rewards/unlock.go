package rewards

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/google/uuid"
	_ "modernc.org/sqlite"
)

type trustEvalState struct {
	UptimeOKSince         sql.NullTime
	WalletBalanceOKSince  sql.NullTime
	UnlockPairOKSince     sql.NullTime
	DemotionCooldownUntil sql.NullTime
	TrustTier             string
}

// RunUnlockEvalOnce runs a single unlock evaluation pass (test hook).
func (r *Runner) RunUnlockEvalOnce(ctx context.Context) error {
	return r.runUnlockEval(ctx)
}

func (r *Runner) runUnlockEval(ctx context.Context) error {
	providers, err := r.listEligibleProviders(ctx)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	for _, pid := range providers {
		if err := r.evaluateProviderTrust(ctx, pid, now); err != nil {
			r.logger.Warn().Err(err).Str("provider_id", pid).Msg("trust eval failed")
		}
	}
	return nil
}

func (r *Runner) evaluateProviderTrust(ctx context.Context, providerID string, now time.Time) error {
	st, err := r.loadTrustEvalState(ctx, providerID)
	if err != nil {
		return err
	}
	if st.TrustTier == "" {
		st.TrustTier = TierProvisional
	}

	receiptCount, err := r.countVerifiedReceipts(ctx, providerID)
	if err != nil {
		return err
	}
	walletBound, err := r.providerWalletBound(ctx, providerID)
	if err != nil {
		return err
	}
	appAttested, err := r.providerAppAttested(ctx, providerID)
	if err != nil {
		return err
	}
	operatorPromoted, err := r.providerOperatorPromoted(ctx, providerID)
	if err != nil {
		return err
	}

	uptimeContinuous := r.providerUptimeOK(providerID, now)
	uptimeSince := advanceWindow(st.UptimeOKSince, uptimeContinuous, now)
	uptimeOK := uptimeSince.Valid && now.Sub(uptimeSince.Time) >= uptimeRequiredWindow

	walletBalanceInstantOK, err := r.walletBalanceInstantOK(ctx, providerID, walletBound)
	if err != nil {
		return err
	}
	walletBalSince := advanceWindow(st.WalletBalanceOKSince, walletBalanceInstantOK, now)
	walletBalanceOK := walletBalSince.Valid && now.Sub(walletBalSince.Time) >= trustRequalifyWindow

	economic, additional := satisfiedCriteria(satisfiedInput{
		ReceiptCount:     receiptCount,
		WalletBound:      walletBound,
		WalletBalanceOK:  walletBalanceOK,
		OperatorPromoted: operatorPromoted,
		UptimeOK:         uptimeOK,
		AppAttested:      appAttested,
	})

	pairOK := distinctUnlockPair(economic, additional)
	unlockSince := advanceWindow(st.UnlockPairOKSince, pairOK, now)

	if err := r.persistTrustEvalState(ctx, providerID, trustEvalPersist{
		UptimeOKSince:        uptimeSince,
		WalletBalanceOKSince: walletBalSince,
		UnlockPairOKSince:    unlockSince,
		EvalAt:               now,
	}); err != nil {
		return err
	}

	if st.TrustTier == TierTrusted {
		if !pairOK {
			return r.demoteProvider(ctx, providerID, now)
		}
		return nil
	}

	if !pairOK {
		return nil
	}
	if st.DemotionCooldownUntil.Valid && now.Before(st.DemotionCooldownUntil.Time) {
		return nil
	}
	if st.DemotionCooldownUntil.Valid {
		if !unlockSince.Valid || now.Sub(unlockSince.Time) < trustRequalifyWindow {
			return nil
		}
	}
	return r.promoteProvider(ctx, providerID, now)
}

type satisfiedInput struct {
	ReceiptCount     int
	WalletBound      bool
	WalletBalanceOK  bool
	OperatorPromoted bool
	UptimeOK         bool
	AppAttested      bool
}

func satisfiedCriteria(in satisfiedInput) (economic, additional []string) {
	if in.ReceiptCount >= minVerifiedReceipts {
		economic = append(economic, CriterionE1Receipts)
		additional = append(additional, CriterionE1Receipts)
	}
	if in.WalletBound && in.WalletBalanceOK {
		economic = append(economic, CriterionE2WalletEconomic)
		additional = append(additional, CriterionWalletBalance72h)
	}
	if in.OperatorPromoted {
		economic = append(economic, CriterionE3Operator)
	}
	if in.UptimeOK {
		additional = append(additional, CriterionUptime72h)
	}
	if in.AppAttested {
		additional = append(additional, CriterionAppAttest)
	}
	return economic, additional
}

func distinctUnlockPair(economic, additional []string) bool {
	for _, e := range economic {
		for _, a := range additional {
			if criteriaOverlap(e, a) {
				continue
			}
			return true
		}
	}
	return false
}

func criteriaOverlap(economic, additional string) bool {
	if economic == additional {
		return true
	}
	if (economic == CriterionE2WalletEconomic && additional == CriterionWalletBalance72h) ||
		(economic == CriterionWalletBalance72h && additional == CriterionE2WalletEconomic) {
		return true
	}
	return false
}

func (r *Runner) providerUptimeOK(providerID string, now time.Time) bool {
	if r.connectivity == nil {
		return false
	}
	return r.connectivity.HeartbeatOK(providerID, now)
}

func (r *Runner) countVerifiedReceipts(ctx context.Context, providerID string) (int, error) {
	source, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(r.cfg.SQLitePayoutDBPath))
	if err != nil {
		return 0, fmt.Errorf("open billing sqlite: %w", err)
	}
	defer source.Close()
	source.SetMaxOpenConns(1)
	if !tableExists(ctx, source, "settlement_receipt_verdicts") {
		return 0, nil
	}
	var count int
	err = source.QueryRowContext(ctx, `
        SELECT COUNT(*)
          FROM settlement_receipt_verdicts
         WHERE provider_id = ?
           AND closed = 1
           AND settlement_outcome = 'verified'
           AND receipt_result = 'valid'
    `, providerID).Scan(&count)
	return count, err
}

func (r *Runner) providerWalletBound(ctx context.Context, providerID string) (bool, error) {
	var addr sql.NullString
	err := r.db.QueryRowContext(ctx, `
        SELECT address
          FROM provider_payout_addresses_proj
         WHERE provider_id = $1 AND payout_allowed = 1
    `, providerID).Scan(&addr)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return addr.Valid && strings.TrimSpace(addr.String) != "", nil
}

func (r *Runner) providerAppAttested(ctx context.Context, providerID string) (bool, error) {
	var attested bool
	err := r.db.QueryRowContext(ctx, `
        SELECT attested FROM provider_identities WHERE provider_id = $1
    `, providerID).Scan(&attested)
	if err == sql.ErrNoRows {
		return false, nil
	}
	return attested, err
}

func (r *Runner) providerOperatorPromoted(ctx context.Context, providerID string) (bool, error) {
	var exists bool
	err := r.db.QueryRowContext(ctx, `
        SELECT EXISTS (
            SELECT 1 FROM provider_trust_operator_promotions WHERE provider_id = $1
        )
    `, providerID).Scan(&exists)
	return exists, err
}

func (r *Runner) walletBalanceInstantOK(ctx context.Context, providerID string, walletBound bool) (bool, error) {
	if !walletBound || len(r.cfg.BaseUSDCBalanceRPCURLs) == 0 || r.balanceChecker == nil {
		return false, nil
	}
	addr, err := r.providerWalletAddress(ctx, providerID)
	if err != nil || addr == "" {
		return false, err
	}
	ok, _, err := r.balanceChecker.USDCBalanceAtLeast(ctx, addr, minUSDCMicro)
	return ok, err
}

func (r *Runner) walletBalanceCriterionMet(ctx context.Context, providerID string, walletBound bool, st trustEvalState, now time.Time) (bool, error) {
	instant, err := r.walletBalanceInstantOK(ctx, providerID, walletBound)
	if err != nil || !instant {
		return false, err
	}
	if !st.WalletBalanceOKSince.Valid {
		return false, nil
	}
	return now.Sub(st.WalletBalanceOKSince.Time) >= trustRequalifyWindow, nil
}

func (r *Runner) providerWalletAddress(ctx context.Context, providerID string) (string, error) {
	var addr string
	err := r.db.QueryRowContext(ctx, `
        SELECT address FROM provider_payout_addresses_proj
         WHERE provider_id = $1 AND payout_allowed = 1
    `, providerID).Scan(&addr)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return addr, err
}

func (r *Runner) loadTrustEvalState(ctx context.Context, providerID string) (trustEvalState, error) {
	var st trustEvalState
	err := r.db.QueryRowContext(ctx, `
        SELECT pes.trust_tier, pes.demotion_cooldown_until,
               ptes.uptime_ok_since, ptes.wallet_balance_ok_since, ptes.unlock_pair_ok_since
          FROM provider_emission_state pes
          LEFT JOIN provider_trust_eval_state ptes ON ptes.provider_id = pes.provider_id
         WHERE pes.provider_id = $1
    `, providerID).Scan(
		&st.TrustTier, &st.DemotionCooldownUntil,
		&st.UptimeOKSince, &st.WalletBalanceOKSince, &st.UnlockPairOKSince,
	)
	if err == sql.ErrNoRows {
		return trustEvalState{TrustTier: TierProvisional}, nil
	}
	return st, err
}

type trustEvalPersist struct {
	UptimeOKSince        sql.NullTime
	WalletBalanceOKSince sql.NullTime
	UnlockPairOKSince    sql.NullTime
	EvalAt               time.Time
}

func (r *Runner) persistTrustEvalState(ctx context.Context, providerID string, p trustEvalPersist) error {
	_, err := r.db.ExecContext(ctx, `
        INSERT INTO provider_trust_eval_state
            (provider_id, uptime_ok_since, wallet_balance_ok_since, unlock_pair_ok_since, last_eval_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $5)
        ON CONFLICT (provider_id) DO UPDATE SET
            uptime_ok_since = EXCLUDED.uptime_ok_since,
            wallet_balance_ok_since = EXCLUDED.wallet_balance_ok_since,
            unlock_pair_ok_since = EXCLUDED.unlock_pair_ok_since,
            last_eval_at = EXCLUDED.last_eval_at,
            updated_at = EXCLUDED.updated_at
    `, providerID, p.UptimeOKSince, p.WalletBalanceOKSince, p.UnlockPairOKSince, p.EvalAt)
	return err
}

func (r *Runner) promoteProvider(ctx context.Context, providerID string, now time.Time) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := setTrustTier(ctx, tx, providerID, TierTrusted); err != nil {
		return err
	}
	if err := auditTrustTierChangedTx(ctx, tx, providerID, TierTrusted, now); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	r.notifyTrustTierChanged(providerID, TierTrusted)
	r.logger.Info().Str("provider_id", providerID).Time("at", now).Msg("trust tier promoted to trusted")
	return nil
}

func (r *Runner) demoteProvider(ctx context.Context, providerID string, now time.Time) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := setTrustTier(ctx, tx, providerID, TierProvisional); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
        UPDATE provider_trust_eval_state
           SET unlock_pair_ok_since = NULL, updated_at = $2
         WHERE provider_id = $1
    `, providerID, now)
	if err != nil {
		return err
	}
	if err := auditTrustTierChangedTx(ctx, tx, providerID, TierProvisional, now); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	r.notifyTrustTierChanged(providerID, TierProvisional)
	r.logger.Info().Str("provider_id", providerID).Time("at", now).Msg("trust tier demoted to provisional")
	return nil
}

func (r *Runner) notifyTrustTierChanged(providerID, tier string) {
	if r == nil {
		return
	}
	r.observerMu.RLock()
	observer := r.observer
	r.observerMu.RUnlock()
	if observer != nil {
		observer.ProviderTrustTierChanged(providerID, tier)
	}
}

func advanceWindow(current sql.NullTime, ok bool, now time.Time) sql.NullTime {
	if !ok {
		return sql.NullTime{}
	}
	if current.Valid {
		return current
	}
	return sql.NullTime{Time: now, Valid: true}
}

// QueryTrustCriteriaStatus returns unlock progress for the provider read API.
func QueryTrustCriteriaStatus(ctx context.Context, db *sql.DB, providerID string, cfg Config, connectivity ProviderConnectivity) (TrustCriteriaStatus, error) {
	cfg = cfg.DefaultsApplied()
	runner := &Runner{db: db, cfg: cfg, connectivity: connectivity}
	now := time.Now().UTC()
	st, err := runner.loadTrustEvalState(ctx, providerID)
	if err != nil {
		return TrustCriteriaStatus{}, err
	}
	receiptCount, err := runner.countVerifiedReceipts(ctx, providerID)
	if err != nil {
		return TrustCriteriaStatus{}, err
	}
	walletBound, err := runner.providerWalletBound(ctx, providerID)
	if err != nil {
		return TrustCriteriaStatus{}, err
	}
	appAttested, err := runner.providerAppAttested(ctx, providerID)
	if err != nil {
		return TrustCriteriaStatus{}, err
	}
	operatorPromoted, err := runner.providerOperatorPromoted(ctx, providerID)
	if err != nil {
		return TrustCriteriaStatus{}, err
	}
	uptimeContinuous := runner.providerUptimeOK(providerID, now)
	uptimeSince := advanceWindow(st.UptimeOKSince, uptimeContinuous, now)
	uptimeOK := uptimeSince.Valid && now.Sub(uptimeSince.Time) >= uptimeRequiredWindow
	walletBalanceOK, err := runner.walletBalanceCriterionMet(ctx, providerID, walletBound, st, now)
	if err != nil {
		return TrustCriteriaStatus{}, err
	}
	economic, additional := satisfiedCriteria(satisfiedInput{
		ReceiptCount:     receiptCount,
		WalletBound:      walletBound,
		WalletBalanceOK:  walletBalanceOK,
		OperatorPromoted: operatorPromoted,
		UptimeOK:         uptimeOK,
		AppAttested:      appAttested,
	})
	met := len(uniqueCriterionIDs(append(append([]string{}, economic...), additional...)))
	var cooldown *time.Time
	if st.DemotionCooldownUntil.Valid {
		t := st.DemotionCooldownUntil.Time
		cooldown = &t
	}
	var pairSince *time.Time
	if st.UnlockPairOKSince.Valid {
		t := st.UnlockPairOKSince.Time
		pairSince = &t
	}
	tier := st.TrustTier
	if tier == "" {
		tier = TierProvisional
	}
	return TrustCriteriaStatus{
		TrustTier:             tier,
		DemotionCooldownUntil: cooldown,
		EconomicSatisfied:     economic,
		AdditionalSatisfied:   additional,
		CriteriaMet:           met,
		CriteriaRequired:      2,
		UnlockPairOKSince:     pairSince,
		VerifiedReceiptCount:  receiptCount,
		WalletBound:           walletBound,
		AppAttested:           appAttested,
		OperatorPromoted:      operatorPromoted,
		UptimeOK:              uptimeOK,
		WalletBalanceOK:       walletBalanceOK,
	}, nil
}

func uniqueCriterionIDs(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, id := range in {
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out
}

// WalletBalanceChecker verifies Base USDC balance via dual-RPC reads.
type WalletBalanceChecker interface {
	USDCBalanceAtLeast(ctx context.Context, wallet string, minMicro int64) (ok bool, balanceMicro int64, err error)
}

// RequestTrustPromotion records a pending operator promotion (E3 step 1).
func RequestTrustPromotion(ctx context.Context, db *sql.DB, pendingID, providerID, requestedBy, reason, incidentID string) error {
	if pendingID == "" {
		return errors.New("pending_id is required")
	}
	if _, err := uuid.Parse(pendingID); err != nil {
		return fmt.Errorf("pending_id must be UUID: %w", err)
	}
	if providerID == "" || requestedBy == "" || reason == "" {
		return errors.New("provider_id, requested_by, and reason are required")
	}
	_, err := db.ExecContext(ctx, `
        INSERT INTO provider_trust_promotion_pending
            (pending_id, provider_id, requested_by, reason, incident_id, status)
        VALUES ($1, $2, $3, $4, NULLIF($5, ''), 'pending')
    `, pendingID, providerID, requestedBy, reason, incidentID)
	return err
}

// ApproveTrustPromotion commits dual-control operator promotion (E3 step 2).
func ApproveTrustPromotion(ctx context.Context, db *sql.DB, pendingID, approvedBy string) (providerID string, err error) {
	if pendingID == "" || approvedBy == "" {
		return "", errors.New("pending_id and approved_by are required")
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback() }()

	var requestedBy, reason string
	err = tx.QueryRowContext(ctx, `
        SELECT provider_id, requested_by, reason
          FROM provider_trust_promotion_pending
         WHERE pending_id = $1 AND status = 'pending'
         FOR UPDATE
    `, pendingID).Scan(&providerID, &requestedBy, &reason)
	if err == sql.ErrNoRows {
		return "", errors.New("pending promotion not found")
	}
	if err != nil {
		return "", err
	}
	if requestedBy == approvedBy {
		return "", errors.New("approved_by must differ from requested_by")
	}
	now := time.Now().UTC()
	trustTierChanged, err := commitTrustPromotionTx(ctx, tx, providerID, approvedBy, reason, pendingID, now)
	if err != nil {
		return "", err
	}
	if trustTierChanged {
		if err := auditTrustTierChangedTx(ctx, tx, providerID, TierTrusted, now); err != nil {
			return "", err
		}
	}
	return providerID, tx.Commit()
}

func commitTrustPromotionTx(ctx context.Context, tx *sql.Tx, providerID, approvedBy, reason, pendingID string, now time.Time) (bool, error) {
	previousTier, err := trustTierTx(ctx, tx, providerID)
	if err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx, `
        UPDATE provider_trust_promotion_pending
           SET status = 'committed', approved_by = $2, committed_at = $3
         WHERE pending_id = $1
    `, pendingID, approvedBy, now); err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx, `
        INSERT INTO provider_trust_operator_promotions
            (provider_id, promoted_by, reason, pending_id, promoted_at)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (provider_id) DO UPDATE SET
            promoted_by = EXCLUDED.promoted_by,
            reason = EXCLUDED.reason,
            pending_id = EXCLUDED.pending_id,
            promoted_at = EXCLUDED.promoted_at
    `, providerID, approvedBy, reason, pendingID, now); err != nil {
		return false, err
	}
	if err := setTrustTier(ctx, tx, providerID, TierTrusted); err != nil {
		return false, err
	}
	return !strings.EqualFold(strings.TrimSpace(previousTier), TierTrusted), nil
}

func trustTierTx(ctx context.Context, tx *sql.Tx, providerID string) (string, error) {
	var tier string
	err := tx.QueryRowContext(ctx, `
        SELECT trust_tier
          FROM provider_emission_state
         WHERE provider_id = $1
    `, providerID).Scan(&tier)
	if err == sql.ErrNoRows {
		return TierProvisional, nil
	}
	return tier, err
}
