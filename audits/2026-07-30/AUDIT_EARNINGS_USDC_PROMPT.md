# AUDIT — earnings usdc_* fix (fix/earnings-usdc-fields, money-path)

Repo: /Users/augstar/macprovider-earnings-usdc. Audit the full diff of commit
2c0f8bf9 vs origin/main (git diff origin/main -- phase4-coordinator/).

## What it does
The Malibu client (phase3-binary ProviderEarningsClient) decodes usdc_today/
usdc_week/usdc_pending/usdc_lifetime, but the coordinator /providers/{id}/earnings
endpoint (phase4-coordinator/internal/billing/endpoints.go earnings handler)
emitted only *_credits — so every provider card showed $0.00 despite real
payable credits. This adds the usdc_* fields.

Changes:
- billing/store.go: new usdPerMillionCreditsBits atomic.Uint64 +
  SetUsdPerMillionCredits/UsdPerMillionCredits/creditsToUSD. NaN/Inf/neg → 0.
- billing/endpoints.go earnings(): compute totalCredits/weekCredits/todayCredits
  once; pending = total - paidOut (payouts not 'ready'/'voided'); emit
  usdc_today/week/pending/lifetime = creditsToUSD(...).
- cmd/coordinator/main.go: SetUsdPerMillionCredits at startup + SIGHUP reload
  from cfg.Stats.Rollup.UsdPerMillionCredits.

## Questions each lane must answer
1. CODE: correctness of the credits→USD math + windows (today=midnight UTC,
   week=Monday UTC, lifetime=all payable, pending=total-paidOut); float
   precision/overflow; concurrency of the atomic rate read vs SIGHUP write;
   any behavior change to existing *_credits fields or other response fields.
2. SECURITY (money-path): can usdc_* mislead a provider about owed money?
   pending semantics (is total-paidOut correct given payout statuses
   'ready'/'voided'/paid)? Any way to over/under-report USD; NaN/Inf/negative
   guarded; rate source trust (cfg.Stats.Rollup.UsdPerMillionCredits).
3. ARCHITECT: is Store the right home for the rate; startup+reload wiring
   complete and race-free; does this match the buyer-side usd_per_million
   usage; any spec (SPEC-005 §11.4 earnings) contract concerns.

## Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM. LOW/INFO may be carried.
