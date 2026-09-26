package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"time"
)

// ErrWholesaleNoGeneration fails a statement closed when a row has no linked
// config snapshot and no snapshot was in effect at its timestamp.
var ErrWholesaleNoGeneration = errors.New("wholesale row has no billing config generation")

// ErrWholesaleConflictingGenerations fails a statement closed when the
// identity at a row's persisted attempt ordinal and the identity at its
// hot-path-derived ordinal link generations that price the row differently
// (SPEC-005 §11.7).
var ErrWholesaleConflictingGenerations = errors.New("wholesale row links conflicting billing config generations")

// wholesaleRate is the list price of one row at one generation: the resolved
// rate-card row and the generation's global multiplier. The cache-hit rate is
// not part of list price (SPEC-005 §11.7).
type wholesaleRate struct {
	rowKey         string
	promptRate     int64
	completionRate int64
	multiplierPPM  int64
}

type wholesaleGeneration struct {
	rateCard      map[string]RateCardEntry
	multiplierPPM int64
}

func (g wholesaleGeneration) rateFor(model string) wholesaleRate {
	key, entry := RateKeyFor(g.rateCard, model)
	return wholesaleRate{rowKey: key, promptRate: entry.PromptCreditsPerMtok, completionRate: entry.CompletionCreditsPerMtok, multiplierPPM: g.multiplierPPM}
}

type wholesaleGroup struct {
	rate       wholesaleRate
	prompt     *big.Int
	completion *big.Int
}

type wholesaleLineTotal struct {
	model            string
	requestCount     int64
	promptTokens     int64
	completionTokens int64
	grossCredits     int64
}

type wholesaleLineSums struct {
	requestCount int64
	prompt       *big.Int
	completion   *big.Int
	groups       map[wholesaleRate]*wholesaleGroup
}

// wholesaleLineTotals prices the account's status-200 request_log rows in
// [startText, endText) per model. Each row is priced at its own generation
// (SPEC-005 §11.7, §13 "config changes affect only new request-credit rows"):
// the config_snapshot_id linked through its provider identity row, else the
// snapshot in effect at its ts_utc. Rows are grouped by (model, resolved rate
// row, multiplier); a group's gross is WholesaleGross over its summed
// persisted tokens and a model's gross is the sum of its groups.
func (s *Store) wholesaleLineTotals(ctx context.Context, accountID, startText, endText string) ([]wholesaleLineTotal, error) {
	// The identity row is keyed by the attempt ordinal its writer used: the
	// persisted request_log ordinal (exact key) or, for an ambiguous attempt,
	// the larger id ordinal the hot path re-derived (hotpath.go). Both are
	// looked up independently; an identity with a NULL config_snapshot_id
	// counts as absent. UNIQUE(request_id, attempt_n, provider_assigned_id)
	// makes each lookup return at most one identity.
	identityAt := func(ordinal string) string {
		return `FROM ledger_provider_identity_snapshots lpis
         WHERE lpis.request_id = r.request_id
           AND lpis.provider_assigned_id = r.provider_assigned_id
           AND lpis.attempt_n = r.` + ordinal
	}
	rows, err := s.db.QueryContext(ctx, `
WITH r AS (
SELECT rl.id, rl.request_id, rl.provider_assigned_id, rl.model, rl.ts_utc, rl.prompt_tokens, rl.completion_tokens,
       `+requestLogAttemptOrdinalSQL("rl")+` AS attempt_ordinal,
       `+requestLogIDOrdinalSQL("rl")+` AS id_ordinal
  FROM request_log rl
 WHERE rl.account_id = ?
   AND rl.status = 200
   AND julianday(rl.ts_utc) >= julianday(?)
   AND julianday(rl.ts_utc) < julianday(?)
)
SELECT r.model, r.ts_utc, r.prompt_tokens, r.completion_tokens,
       (SELECT lpis.config_snapshot_id `+identityAt("attempt_ordinal")+`) AS exact_snapshot_id,
       CASE
         WHEN r.id_ordinal > r.attempt_ordinal
           THEN (SELECT lpis.config_snapshot_id `+identityAt("id_ordinal")+`)
       END AS derived_snapshot_id
  FROM r
 ORDER BY r.id`, accountID, startText, endText)
	if err != nil {
		return nil, err
	}
	type scanned struct {
		model      string
		tsText     string
		prompt     sql.NullInt64
		completion sql.NullInt64
		exact      sql.NullInt64
		derived    sql.NullInt64
	}
	var scan []scanned
	for rows.Next() {
		var r scanned
		if err := rows.Scan(&r.model, &r.tsText, &r.prompt, &r.completion, &r.exact, &r.derived); err != nil {
			rows.Close()
			return nil, err
		}
		scan = append(scan, r)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()

	generations := map[int64]wholesaleGeneration{}
	generation := func(id int64) (wholesaleGeneration, error) {
		if g, ok := generations[id]; ok {
			return g, nil
		}
		rewards, multiplier, _, err := snapshotByIDQueryer(ctx, s.db, id)
		if err != nil {
			return wholesaleGeneration{}, fmt.Errorf("config snapshot %d: %w", id, err)
		}
		g := wholesaleGeneration{rateCard: rewards.RateCard, multiplierPPM: wholesaleMultiplierPPM(multiplier)}
		generations[id] = g
		return g, nil
	}

	lines := map[string]*wholesaleLineSums{}
	for _, r := range scan {
		rate, err := s.wholesaleRowRate(ctx, r.model, r.tsText, r.exact, r.derived, generation)
		if err != nil {
			return nil, err
		}
		prompt, completion := big.NewInt(r.prompt.Int64), big.NewInt(r.completion.Int64)
		line := lines[r.model]
		if line == nil {
			line = &wholesaleLineSums{prompt: new(big.Int), completion: new(big.Int), groups: map[wholesaleRate]*wholesaleGroup{}}
			lines[r.model] = line
		}
		line.requestCount++
		line.prompt.Add(line.prompt, prompt)
		line.completion.Add(line.completion, completion)
		group := line.groups[rate]
		if group == nil {
			group = &wholesaleGroup{rate: rate, prompt: new(big.Int), completion: new(big.Int)}
			line.groups[rate] = group
		}
		group.prompt.Add(group.prompt, prompt)
		group.completion.Add(group.completion, completion)
	}

	models := make([]string, 0, len(lines))
	for model := range lines {
		models = append(models, model)
	}
	sort.Strings(models)
	out := make([]wholesaleLineTotal, 0, len(models))
	for _, model := range models {
		line := lines[model]
		if !line.prompt.IsInt64() || !line.completion.IsInt64() {
			return nil, fmt.Errorf("model %q token totals: %w", model, ErrWholesaleGrossOverflow)
		}
		total := wholesaleLineTotal{model: model, requestCount: line.requestCount, promptTokens: line.prompt.Int64(), completionTokens: line.completion.Int64()}
		for _, group := range line.groups {
			gross, err := WholesaleGross(group.prompt, group.completion, RateCardEntry{
				PromptCreditsPerMtok:     group.rate.promptRate,
				CompletionCreditsPerMtok: group.rate.completionRate,
			}, group.rate.multiplierPPM)
			if err != nil {
				return nil, fmt.Errorf("model %q: %w", model, err)
			}
			var ok bool
			if total.grossCredits, ok = checkedAdd(total.grossCredits, gross); !ok {
				return nil, fmt.Errorf("model %q: %w", model, ErrWholesaleGrossOverflow)
			}
		}
		out = append(out, total)
	}
	return out, nil
}

// wholesaleRowRate resolves one row's list price. Exactly one non-null
// linked config_snapshot_id prices the row at that generation. Two non-null
// ids must resolve to the same (rate row, multiplier) or the statement fails
// closed with ErrWholesaleConflictingGenerations. With neither, the snapshot
// in effect at ts_utc prices the row.
func (s *Store) wholesaleRowRate(ctx context.Context, model, tsText string, exact, derived sql.NullInt64, generation func(int64) (wholesaleGeneration, error)) (wholesaleRate, error) {
	rateAt := func(id int64) (wholesaleRate, error) {
		g, err := generation(id)
		if err != nil {
			return wholesaleRate{}, err
		}
		return g.rateFor(model), nil
	}
	switch {
	case exact.Valid && derived.Valid:
		exactRate, err := rateAt(exact.Int64)
		if err != nil {
			return wholesaleRate{}, err
		}
		derivedRate, err := rateAt(derived.Int64)
		if err != nil {
			return wholesaleRate{}, err
		}
		if exactRate != derivedRate {
			return wholesaleRate{}, fmt.Errorf("model %q at %s: snapshots %d and %d: %w", model, tsText, exact.Int64, derived.Int64, ErrWholesaleConflictingGenerations)
		}
		return exactRate, nil
	case exact.Valid:
		return rateAt(exact.Int64)
	case derived.Valid:
		return rateAt(derived.Int64)
	}
	ts, err := time.Parse(time.RFC3339Nano, tsText)
	if err != nil {
		return wholesaleRate{}, fmt.Errorf("request_log ts_utc %q: %w", tsText, err)
	}
	_, rewards, multiplier, _, err := snapshotAtQueryer(ctx, s.db, ts)
	if errors.Is(err, ErrNoSnapshot) {
		return wholesaleRate{}, fmt.Errorf("model %q at %s: %w", model, tsText, ErrWholesaleNoGeneration)
	}
	if err != nil {
		return wholesaleRate{}, err
	}
	return wholesaleGeneration{rateCard: rewards.RateCard, multiplierPPM: wholesaleMultiplierPPM(multiplier)}.rateFor(model), nil
}

// wholesaleMultiplierPPM keeps the statement's historical treatment of an
// unset multiplier (1.0).
func wholesaleMultiplierPPM(ppm int64) int64 {
	if ppm == 0 {
		return globalMultiplierDenom
	}
	return ppm
}
