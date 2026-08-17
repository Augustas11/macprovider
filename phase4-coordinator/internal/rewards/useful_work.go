package rewards

import (
	"context"
	"fmt"
)

const usefulWorkBatchLimit = 500

type usefulWorkRewardRow struct {
	RequestID       string
	AttemptN        int
	ProviderID      string
	ProviderCredits int64
}

// RunUsefulWorkAccrualOnce runs one verified-useful-work accrual pass.
func (r *Runner) RunUsefulWorkAccrualOnce(ctx context.Context) error {
	return r.runUsefulWorkAccrual(ctx)
}

func (r *Runner) runUsefulWorkAccrual(ctx context.Context) error {
	if !r.cfg.UsefulWorkEnabled {
		return nil
	}
	rows, err := r.listUnrewardedUsefulWork(ctx, usefulWorkBatchLimit)
	if err != nil {
		return err
	}
	for _, row := range rows {
		amount := r.usefulWorkMALIBU(row.ProviderCredits)
		if amount <= 0 {
			continue
		}
		if err := r.accrueProviderReward(ctx, row.ProviderID, amount, ReasonMalibuVerifiedUsefulWorkV02, usefulWorkExternalRef(row)); err != nil {
			r.logger.Warn().
				Err(err).
				Str("provider_id", row.ProviderID).
				Str("request_id", row.RequestID).
				Int("attempt_n", row.AttemptN).
				Msg("useful work reward accrual failed")
		}
	}
	return nil
}

func (r *Runner) listUnrewardedUsefulWork(ctx context.Context, limit int) ([]usefulWorkRewardRow, error) {
	if limit <= 0 {
		limit = usefulWorkBatchLimit
	}
	rows, err := r.db.QueryContext(ctx, `
        SELECT lrc.request_id, lrc.attempt_n, lrc.provider_id, lrc.provider_credits
          FROM ledger_request_credits lrc
         WHERE COALESCE(lrc.spec022_verified, FALSE) = TRUE
           AND lrc.provider_credits > 0
           AND NOT EXISTS (
                SELECT 1
                  FROM provider_rewards_ledger prl
                 WHERE prl.external_ref = 'spec022:' || lrc.request_id || ':' || lrc.attempt_n::TEXT || ':' || lrc.provider_id
                   AND prl.amount_malibu IS NOT NULL
           )
         ORDER BY lrc.ts_utc ASC, lrc.id ASC
         LIMIT $1
    `, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []usefulWorkRewardRow
	for rows.Next() {
		var row usefulWorkRewardRow
		if err := rows.Scan(&row.RequestID, &row.AttemptN, &row.ProviderID, &row.ProviderCredits); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func (r *Runner) usefulWorkMALIBU(providerCredits int64) float64 {
	if providerCredits <= 0 || r.cfg.UsefulWorkMALIBUPer1KCredits <= 0 {
		return 0
	}
	return (float64(providerCredits) / 1000.0) * r.cfg.UsefulWorkMALIBUPer1KCredits
}

func usefulWorkExternalRef(row usefulWorkRewardRow) string {
	return fmt.Sprintf("spec022:%s:%d:%s", row.RequestID, row.AttemptN, row.ProviderID)
}
