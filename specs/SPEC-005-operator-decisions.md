# SPEC-005 operator pre-commitments

Lock each decision below by filling the rightmost column. The BUILD
session (`specs/BUILD_SPEC_005_PROMPT.md`, to be drafted in Step 2 of
the execution plan) will encode these as normative § 2 pre-commitments
with no further design space.

Read `specs/SPEC-005-design.md` Q1–Q12 for full tradeoffs before
deciding. The "Options" column below is a one-line summary only.

| # | Design question | Options (from design.md) | Operator Decision |
|---|---|---|---|
| D1 | Billing model | A) pre-paid Stripe bundles / B) post-paid credit card / C) API key + running balance / D) **donation-only, no per-provider tip jar (recommended — keeps SPEC-006 free-tier lock; ledger records provider credit, not buyer revenue)** | |
| D2 | Settlement cadence | A) **real-time accrue + weekly payout batch UTC Monday 00:00 (recommended)** / B) monthly batch / C) threshold-triggered / D) manual operator-triggered | |
| D3 | Provider reward formula | A) flat global $/M tokens / B) **per-model rate card with global multiplier (recommended — rewards larger-model supply, single tuning knob)** / C) dynamic market-rate peg / D) reputation-weighted (uptime × quality × supply) | |
| D4 | Min payout threshold | A) no threshold (every cycle) / B) **$0.50 nominal, configurable (recommended — small Macs see first payout within weeks)** / C) $5 mid / D) $25 high | |
| D5 | Revenue split | A) 100/0 provider/operator / B) **90/10 global, stored per-credit-row for auditability (recommended)** / C) 70/30 SaaS-style / D) per-provider negotiated | |
| D6 | Currency / unit | A) abstract undenominated credits / B) **internal credits pegged 1:1 to USD micro-dollars, INTEGER storage (recommended — stable mental model, SPEC-007-convertible)** / C) USDC micro-amounts / D) fiat USD cents | |
| D7 | Buyer balance enforcement | A) **hard limit at account-day boundary per SPEC-006 §17.7; SPEC-005 credits providers for actual reported usage regardless (recommended)** / B) soft limit + grace / C) rolling 24h window / D) hard + manual override | |
| D8 | Failed-request accounting | **Direct 1:1 mapping of provider credit to SPEC-006 §17.7 D3 buyer-debit matrix (recommended — closes H-005 by construction). Null-usage error paths → 0 credit. Buyer cancels → full credit per reported usage.** Alternative: winner-takes-all per request. | |
| D9 | Crash recovery policy | A) best-effort / B) **same-SQLite-transaction write of request_log + ledger rows + startup scan (24h) + nightly reconcile (7d) (recommended — ACID-grounded, deterministic recovery)** / C) full 2PC / D) eventual-only reconciliation | |
| D10 | Multi-provider attribution | A) winner-takes-all / B) **per-attempt credit derived from per-attempt request_log rows; share request_id, distinct attempt_n + provider_id (recommended — mirrors SPEC-006 per-attempt debit)** / C) proportional split / D) operator-configurable | |
| D11 | Operator dashboard scope | A) raw SQLite only / B) **four JSON endpoints: /admin/ledger/summary, /admin/ledger/providers, /admin/ledger/reconcile, /providers/{id}/earnings (recommended — covers operator + provider visibility; no charts in v1)** / C) full web dashboard / D) Slack/email digest | |
| D12 | Fraud floor for degraded providers | A) full credit until breaker trips / B) reduced (50%) credit for fault-contributing requests / C) **zero credit for FR-P11a fault-classified requests; provider returns to full eligibility after recovery preflight; degraded/unavailable state earns nothing because no traffic routed (recommended — mirrors SPEC-006 work-actually-performed rule)** / D) zero credit until full re-warmup | |

---

## Gate checks before moving to BUILD

- [ ] All 12 rows have a decision.
- [ ] D8 decision is consistent with SPEC-006 §17.7 D3 matrix (every D3 row has a corresponding credit rule).
- [ ] No decision contradicts a locked constraint:
  - `request_log` (SPEC-002 FR-B9) is read-only and extended via JOIN, not ALTER.
  - SPEC-001 v1.2.4 wire format is frozen.
  - No billing logic in the gateway (SPEC-006 §1.8).
  - No on-chain settlement in v1.
  - SPEC-007 boundary respected: SPEC-005 emits `ledger_payout_ready`; SPEC-007 consumes it.
- [ ] D3 rate-card placeholder values reviewed; operator either accepts the design.md placeholders or supplies starting numbers.
- [ ] D5 split numerator chosen (recommendation: 0.90).
- [ ] D11 endpoint set trimmed if any of the four endpoints are not wanted in v1.
- [ ] File committed to git before opening Step 2 (Claude writes BUILD prompt).
