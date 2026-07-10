# SPEC-005 operator pre-commitments

Lock each decision below by filling the rightmost column. The BUILD
session (`specs/BUILD_SPEC_005_PROMPT.md`, to be drafted in Step 2 of
the execution plan) will encode these as normative § 2 pre-commitments
with no further design space.

Read `specs/SPEC-005-design.md` Q1–Q12 for full tradeoffs before
deciding. The "Options" column below is a one-line summary only.

| # | Design question | Options (from design.md) | Operator Decision |
|---|---|---|---|
| D1 | Billing model | A) pre-paid Stripe bundles / B) post-paid credit card / C) API key + running balance / D) **donation-only, no per-provider tip jar (recommended — keeps SPEC-006 free-tier lock; ledger records provider credit, not buyer revenue)** | **D** — donation-only; no tip jar in v1; SPEC-005 ledger tracks provider credits only, not buyer revenue; no Stripe, no checkout, no credit card collection. |
| D2 | Settlement cadence | A) **real-time accrue + weekly payout batch UTC Monday 00:00 (recommended)** / B) monthly batch / C) threshold-triggered / D) manual operator-triggered | **A** — real-time accrue + weekly settlement-ready batch UTC Monday 00:00; `settlement.cadence_days: 7` in coordinator.yaml; in-process goroutine (no new ops surface). |
| D3 | Provider reward formula | A) flat global $/M tokens / B) **per-model rate card with global multiplier (recommended — rewards larger-model supply, single tuning knob)** / C) dynamic market-rate peg / D) reputation-weighted (uptime × quality × supply) | **B** — per-model rate card with global multiplier; initial rates (placeholder, tuned once live traffic data available): 7B models = 1,000,000 prompt / 2,000,000 completion credits per Mtok; 3B models = 500,000 prompt / 1,000,000 completion credits per Mtok; default fallback = 3B rates; `global_multiplier: 1.0`; rate card stored in coordinator.yaml (git-auditable), NOT in database; unknown models fall back to default. |
| D4 | Min payout threshold | A) no threshold (every cycle) / B) **$0.50 nominal, configurable (recommended — small Macs see first payout within weeks)** / C) $5 mid / D) $25 high | **B** — $0.50 nominal = 500,000 credits (using 1 credit = $0.000001); `settlement.min_payout_credits: 500000` in coordinator.yaml; sub-threshold credits roll forward to next weekly cycle (`settled=0`); configurable for SPEC-007 gas calibration. |
| D5 | Revenue split | A) 100/0 provider/operator / B) **90/10 global, stored per-credit-row for auditability (recommended)** / C) 70/30 SaaS-style / D) per-provider negotiated | **B** — 90/10 global; `rewards.provider_share: 0.90`; stored as `provider_share_bps=9000` INTEGER on every `ledger_request_credits` row at creation time (historical splits immutable); operator share recorded as `ledger_operator_credits`; not publicly exposed in v1 but visible in per-provider earnings endpoint. |
| D6 | Currency / unit | A) abstract undenominated credits / B) **internal credits pegged 1:1 to USD micro-dollars, INTEGER storage (recommended — stable mental model, SPEC-007-convertible)** / C) USDC micro-amounts / D) fiat USD cents | **B** — internal credits; 1 credit = 1 micro-dollar = $0.000001; all columns INTEGER, never FLOAT; all credit arithmetic is integer arithmetic; SPEC-007 converts credits to USDC at payout time; `payout_currency` column on `ledger_payout_ready` is nullable for SPEC-007 to populate. |
| D7 | Buyer balance enforcement | A) **hard limit at account-day boundary per SPEC-006 §17.7; SPEC-005 credits providers for actual reported usage regardless (recommended)** / B) soft limit + grace / C) rolling 24h window / D) hard + manual override | **A** — hard limit at account-day boundary per SPEC-006 §17.7 (not re-implemented in SPEC-005); provider is credited for actual reported usage regardless of buyer quota state; provider is never zero-credited for legitimate completed work. |
| D8 | Failed-request accounting | **Direct 1:1 mapping of provider credit to SPEC-006 §17.7 D3 buyer-debit matrix (recommended — closes H-005 by construction). Null-usage error paths → 0 credit. Buyer cancels → full credit per reported usage.** Alternative: winner-takes-all per request. | **Recommended** — 1:1 mapping to SPEC-006 §17.7 D3 matrix for every request state: null-usage error paths (`error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, `error_internal`) → 0 provider credit; buyer cancel with reported usage → full credit per actual tokens; provider-not-reached → 0 credit. Closes H-005 by construction. |
| D9 | Crash recovery policy | A) best-effort / B) **same-SQLite-transaction write of request_log + ledger rows + startup scan (24h) + nightly reconcile (7d) (recommended — ACID-grounded, deterministic recovery)** / C) full 2PC / D) eventual-only reconciliation | **B** — request_log JOIN + ledger rows written in the same SQLite transaction (ACID); coordinator startup scans last 24h for uncommitted ledger rows; nightly goroutine reconciles 7-day window; no 2PC; recovery algorithm must be deterministic and testable without live network. |
| D10 | Multi-provider attribution | A) winner-takes-all / B) **per-attempt credit derived from per-attempt request_log rows; share request_id, distinct attempt_n + provider_id (recommended — mirrors SPEC-006 per-attempt debit)** / C) proportional split / D) operator-configurable | **B** — per-attempt credit; each attempt row in `request_log` has its own `provider_id` and `attempt_n`; `ledger_request_credits` keyed by `(request_id, attempt_n, provider_id)`; mirrors SPEC-006 per-attempt debit exactly; winner-takes-all explicitly rejected. |
| D11 | Operator dashboard scope | A) raw SQLite only / B) **four JSON endpoints: /admin/ledger/summary, /admin/ledger/providers, /admin/ledger/reconcile, /providers/{id}/earnings (recommended — covers operator + provider visibility; no charts in v1)** / C) full web dashboard / D) Slack/email digest | **B** — all four JSON endpoints in v1: `GET /admin/ledger/summary`, `GET /admin/ledger/providers`, `GET /admin/ledger/reconcile`, `GET /providers/{id}/earnings`; no charts; no Slack/email; provider endpoint authenticated via existing FR-P12 bearer tokens; no new auth surface required. |
| D12 | Fraud floor for degraded providers | A) full credit until breaker trips / B) reduced (50%) credit for fault-contributing requests / C) **zero credit for FR-P11a fault-classified requests; provider returns to full eligibility after recovery preflight; degraded/unavailable state earns nothing because no traffic routed (recommended — mirrors SPEC-006 work-actually-performed rule)** / D) zero credit until full re-warmup | **C** — zero credit for requests fault-classified under FR-P11a; full earnings restored after recovery preflight passes; `degraded` and `unavailable` states receive no traffic so earning rate is moot; no reduced-credit tier in v1; no extended re-warmup penalty beyond recovery preflight. |

---

## Gate checks before moving to BUILD

- [x] All 12 rows have a decision.
- [x] D8 decision is consistent with SPEC-006 §17.7 D3 matrix (every D3 row has a corresponding credit rule).
- [x] No decision contradicts a locked constraint:
  - `request_log` (SPEC-002 FR-B9) is read-only and extended via JOIN, not ALTER.
  - SPEC-001 v1.2.4 wire format is frozen.
  - No billing logic in the gateway (SPEC-006 §1.8).
  - No on-chain settlement in v1.
  - SPEC-007 boundary respected: SPEC-005 emits `ledger_payout_ready`; SPEC-007 consumes it.
- [x] D3 rate-card placeholder values reviewed; operator accepts initial rates of 1M/2M credits per Mtok (7B) and 500k/1M (3B), explicitly marked as placeholder pending live traffic data.
- [x] D5 split numerator chosen: 0.90 (provider_share_bps = 9000).
- [x] D11 endpoint set confirmed: all four endpoints in v1, authenticated via existing FR-P12 bearer tokens.
- [ ] File committed to git before opening Step 2 (Claude writes BUILD prompt).
