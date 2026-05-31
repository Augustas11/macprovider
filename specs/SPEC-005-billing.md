# SPEC-005 - Billing, Settlement, and Provider Rewards

**Version:** 0.1 (2026-05-31, initial draft from locked operator decisions)
**Depends on:** SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-003 v0.7, SPEC-004 v0.3.1, SPEC-006 v0.8.1

**Change log v0.1:**
- Initial draft following `specs/SPEC-005-design.md` and `specs/SPEC-005-operator-decisions.md`.
- Encodes D1-D12 as read-only locked decisions in § 2.
- Defines the coordinator-side provider-credit ledger, weekly settlement-ready batch, recovery algorithm, and four JSON endpoints.
- Closes H-005 by mirroring SPEC-006 v0.8.1 § 17.7 with deterministic provider-credit formulas.

---

## 1. Scope

### 1.1 Mission

SPEC-005 defines Mac Provider's billing, settlement-ready batching, and provider-rewards layer.
The layer is a coordinator-side provider-credit ledger.
It records nominal provider credits for work the coordinator already routed.
It does not collect buyer revenue.
It does not pay providers by itself.
It does not alter the provider binary.
It does not add billing state to the gateway.
It emits `ledger_payout_ready` rows that SPEC-007 may later consume.
### 1.2 In scope

- Provider-credit ledger rows written by the coordinator.
- Operator-credit rows that preserve the D5 split.
- Weekly settlement-ready rows for SPEC-007 consumption.
- Coordinator-local recovery and reconciliation scans.
- Four JSON visibility endpoints from D11.
- No-live-network acceptance criteria and deterministic fixtures.
- Rate-card configuration in coordinator.yaml.
- H-005 closure against SPEC-006 § 17.7.

### 1.3 Out of scope for v1

- AntFeed USDC payment rail.
- On-chain settlement of any kind.
- Stripe, checkout, credit cards, fiat invoices, refunds, or buyer revenue.
- Billing logic in the Phase 5 gateway.
- SPEC-001 wire-format changes.
- Per-provider negotiated splits.
- Reputation-weighted reward formulas.
- Dynamic market-rate pegging.
- Tier 2 attested-provider reward multipliers.
- KYC, 1099, tax, or regulatory paperwork.
- Refund or clawback workflows.
- Multi-currency ledger entries written by SPEC-005.
- Web charts and dashboards.
- Slack, email, webhook, or digest notification surfaces.
- Multi-coordinator or multi-region ledger replication.
- Buyer-visible donation buttons, tip jars, or payment-adjacent SPEC-006 UI.

### 1.4 Cross-spec boundaries

**SPEC-001 v1.2.4:**
- frozen Phase 3 binary wire format.
- usage object has prompt_tokens, completion_tokens, total_tokens.
- cancel usage is authoritative for v1.2.4+ providers.
- SPEC-005 MUST NOT require new provider fields.
**SPEC-002 v1.3.3:**
- coordinator owns request_log and provider auth.
- request_log is read-only to SPEC-005.
- FR-P11a supplies fault categories.
- FR-P12 supplies provider bearer-token auth.
- FR-R3 distinguishes stable provider_id from assigned_id.
- FR-R4 excludes non-ready providers from routing.
**SPEC-003 v0.7:**
- provider onboarding is stranger-readable.
- provider docs must be honest that rewards/billing were deferred to SPEC-005.
- SPEC-005 docs must avoid cash-payout promises.
**SPEC-004 v0.3.1:**
- smart-router attempts must preserve accounting.
- retried is a fallback but not a full attempt ordinal.
- FR-SR-18 composes routing with FR-P11a and eligibility checks.
**SPEC-006 v0.8.1:**
- gateway has no billing state.
- § 17.7 is the buyer-debit source of truth.
- SPEC-005 mirrors rather than edits the matrix.
**SPEC-007 future:**
- owns AntFeed and USDC conversion.
- consumes payout-ready rows.
- may populate payout_currency later.
**SPEC-008 v0.3 informational:**
- attestation_class is nullable storage only.
- no v1 reward multiplier may use attestation_class.

## 2. Locked decisions

This section reproduces the operator pre-commitments from `specs/SPEC-005-operator-decisions.md`.
It is read-only. It records decisions; it does not reopen them.
Any change to D1-D12 requires operator review and a reopened SCOPE stage.

### 2.1 D1 - Billing model

**Operator decision:** **D** — donation-only; no tip jar in v1; SPEC-005 ledger tracks provider credits only, not buyer revenue; no Stripe, no checkout, no credit card collection.
**Normative effect:** Implementations MUST satisfy D1 exactly as written.
**Reference discipline:** Later sections may cite D1; they MUST NOT weaken it.

### 2.2 D2 - Settlement cadence

**Operator decision:** **A** — real-time accrue + weekly settlement-ready batch UTC Monday 00:00; `settlement.cadence_days: 7` in coordinator.yaml; in-process goroutine (no new ops surface).
**Normative effect:** Implementations MUST satisfy D2 exactly as written.
**Reference discipline:** Later sections may cite D2; they MUST NOT weaken it.

### 2.3 D3 - Provider reward formula

**Operator decision:** **B** — per-model rate card with global multiplier; initial rates (placeholder, tuned once live traffic data available): 7B models = 1,000,000 prompt / 2,000,000 completion credits per Mtok; 3B models = 500,000 prompt / 1,000,000 completion credits per Mtok; default fallback = 3B rates; `global_multiplier: 1.0`; rate card stored in coordinator.yaml (git-auditable), NOT in database; unknown models fall back to default.
**Normative effect:** Implementations MUST satisfy D3 exactly as written.
**Reference discipline:** Later sections may cite D3; they MUST NOT weaken it.

### 2.4 D4 - Minimum payout threshold

**Operator decision:** **B** — $0.50 nominal = 500,000 credits (using 1 credit = $0.000001); `settlement.min_payout_credits: 500000` in coordinator.yaml; sub-threshold credits roll forward to next weekly cycle (`settled=0`); configurable for SPEC-007 gas calibration.
**Normative effect:** Implementations MUST satisfy D4 exactly as written.
**Reference discipline:** Later sections may cite D4; they MUST NOT weaken it.

### 2.5 D5 - Revenue split

**Operator decision:** **B** — 90/10 global; `rewards.provider_share: 0.90`; stored as `provider_share_bps=9000` INTEGER on every `ledger_request_credits` row at creation time (historical splits immutable); operator share recorded as `ledger_operator_credits`; not publicly exposed in v1 but visible in per-provider earnings endpoint.
**Normative effect:** Implementations MUST satisfy D5 exactly as written.
**Reference discipline:** Later sections may cite D5; they MUST NOT weaken it.

### 2.6 D6 - Currency / unit

**Operator decision:** **B** — internal credits; 1 credit = 1 micro-dollar = $0.000001; all columns INTEGER, never FLOAT; all credit arithmetic is integer arithmetic; SPEC-007 converts credits to USDC at payout time; `payout_currency` column on `ledger_payout_ready` is nullable for SPEC-007 to populate.
**Normative effect:** Implementations MUST satisfy D6 exactly as written.
**Reference discipline:** Later sections may cite D6; they MUST NOT weaken it.

### 2.7 D7 - Buyer balance enforcement

**Operator decision:** **A** — hard limit at account-day boundary per SPEC-006 §17.7 (not re-implemented in SPEC-005); provider is credited for actual reported usage regardless of buyer quota state; provider is never zero-credited for legitimate completed work.
**Normative effect:** Implementations MUST satisfy D7 exactly as written.
**Reference discipline:** Later sections may cite D7; they MUST NOT weaken it.

### 2.8 D8 - Failed-request accounting

**Operator decision:** **Recommended** — 1:1 mapping to SPEC-006 §17.7 D3 matrix for every request state: null-usage error paths (`error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, `error_internal`) → 0 provider credit; buyer cancel with reported usage → full credit per actual tokens; provider-not-reached → 0 credit. Closes H-005 by construction.
**Normative effect:** Implementations MUST satisfy D8 exactly as written.
**Reference discipline:** Later sections may cite D8; they MUST NOT weaken it.

### 2.9 D9 - Crash recovery policy

**Operator decision:** **B** — request_log JOIN + ledger rows written in the same SQLite transaction (ACID); coordinator startup scans last 24h for uncommitted ledger rows; nightly goroutine reconciles 7-day window; no 2PC; recovery algorithm must be deterministic and testable without live network.
**Normative effect:** Implementations MUST satisfy D9 exactly as written.
**Reference discipline:** Later sections may cite D9; they MUST NOT weaken it.

### 2.10 D10 - Multi-provider attribution

**Operator decision:** **B** — per-attempt credit; each attempt row in `request_log` has its own `provider_id` and `attempt_n`; `ledger_request_credits` keyed by `(request_id, attempt_n, provider_id)`; mirrors SPEC-006 per-attempt debit exactly; winner-takes-all explicitly rejected.
**Normative effect:** Implementations MUST satisfy D10 exactly as written.
**Reference discipline:** Later sections may cite D10; they MUST NOT weaken it.

### 2.11 D11 - Operator dashboard scope

**Operator decision:** **B** — all four JSON endpoints in v1: `GET /admin/ledger/summary`, `GET /admin/ledger/providers`, `GET /admin/ledger/reconcile`, `GET /providers/{id}/earnings`; no charts; no Slack/email; provider endpoint authenticated via existing FR-P12 bearer tokens; no new auth surface required.
**Normative effect:** Implementations MUST satisfy D11 exactly as written.
**Reference discipline:** Later sections may cite D11; they MUST NOT weaken it.

### 2.12 D12 - Fraud floor for degraded providers

**Operator decision:** **C** — zero credit for requests fault-classified under FR-P11a; full earnings restored after recovery preflight passes; `degraded` and `unavailable` states receive no traffic so earning rate is moot; no reduced-credit tier in v1; no extended re-warmup penalty beyond recovery preflight.
**Normative effect:** Implementations MUST satisfy D12 exactly as written.
**Reference discipline:** Later sections may cite D12; they MUST NOT weaken it.

## 3. Terms and definitions

- **credit:** integer accounting unit; one credit equals one USD micro-dollar.
- **USD micro-dollar:** one millionth of one United States dollar.
- **gross credits:** pre-split request value produced by the rate card.
- **provider credits:** provider-share net amount recorded in ledger_request_credits.
- **operator credits:** operator-share amount recorded in ledger_operator_credits.
- **rate card:** coordinator.yaml mapping from model to prompt/completion rates per million tokens.
- **default rate row:** fallback rate-card entry for unknown models.
- **global multiplier:** operator volume knob parsed to integer parts per million.
- **settlement window:** half-open UTC interval used by the weekly job.
- **settlement-ready row:** ledger_payout_ready row emitted above threshold.
- **payout:** future SPEC-007 action; not executed by SPEC-005.
- **provider_id:** stable provider identity for economics.
- **provider_assigned_id:** session-scoped routing identity copied for diagnostics.
- **attempt_n:** zero-based monotonic attempt ordinal.
- **fault_flag:** ledger diagnostic for FR-P11a or null-error zeroing.
- **attestation_class:** nullable SPEC-008 future-proofing field.
- **recovery_source:** hot_path, startup_scan, or nightly_reconcile.
- **quarantined row:** row requiring operator review.
- **reconciliation delta:** provider gross credits minus buyer-equivalent credits.
- **creditable row:** request_log row that reached a provider and has a deterministic credit outcome.
- **provider-not-reached:** SPEC-006 503 path with no provider to credit.

## 4. Storage layer

### 4.1 Storage invariants

- SPEC-005 adds side tables only.
- SPEC-005 MUST NOT ALTER request_log.
- SPEC-005 reads request_log by JOIN only.
- Every credit amount column is INTEGER.
- No FLOAT or REAL credit arithmetic is allowed.
- Every economic row snapshots config values used at issuance.
- Hot-path ledger rows are append-only.
- Settlement may update settled and settlement_id only.
- Recovery may update quarantined and quarantine_reason only.
- Migrations are additive and idempotent.

### 4.2 request_log read-only contract

SPEC-005 reads request_id, ts_utc, model, provider_assigned_id, prompt_tokens, completion_tokens, total_tokens, status, stream, error, provider_header, and retried.
SPEC-005 never changes these columns.
The D10 attempt_n need is a SPEC-002 v1.3.4 cross-spec patch candidate.
Until attempt_n exists, v0.1 supports at most two attempts from current retried semantics.
Ambiguous 2+ retry rows MUST be quarantined instead of guessed.

### 4.3 Table `ledger_request_credits`

| Column | Type | Constraint | Meaning | Update rule |
|---|---|---|---|---|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | local row id | insert only |
| `request_id` | TEXT | NOT NULL | joins request_log.request_id | insert only |
| `attempt_n` | INTEGER | NOT NULL CHECK(attempt_n >= 0) | zero-based attempt ordinal | insert only |
| `provider_id` | TEXT | NOT NULL | stable SPEC-002 FR-R3 provider id | insert only |
| `provider_assigned_id` | TEXT | NULL | session-scoped assigned id | insert only |
| `ts_utc` | TEXT | NOT NULL | request timestamp | insert only |
| `model` | TEXT | NOT NULL | model id used for rate card | insert only |
| `status` | INTEGER | NOT NULL | buyer-visible HTTP status | insert only |
| `stream` | INTEGER | NOT NULL CHECK(stream IN (0,1)) | streaming flag | insert only |
| `prompt_tokens` | INTEGER | NULL CHECK(prompt_tokens IS NULL OR prompt_tokens >= 0) | prompt tokens | insert only |
| `completion_tokens` | INTEGER | NULL CHECK(completion_tokens IS NULL OR completion_tokens >= 0) | reported completion tokens | insert only |
| `estimated_completion_tokens` | INTEGER | NULL CHECK(estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0) | byte-estimated completion tokens | insert only |
| `usage_source` | TEXT | NOT NULL CHECK(usage_source IN ('provider_reported','byte_estimated','null_error','provider_not_reached')) | usage source | insert only |
| `prompt_rate_per_mtok` | INTEGER | NOT NULL CHECK(prompt_rate_per_mtok >= 0) | rate snapshot | insert only |
| `completion_rate_per_mtok` | INTEGER | NOT NULL CHECK(completion_rate_per_mtok >= 0) | rate snapshot | insert only |
| `global_multiplier_ppm` | INTEGER | NOT NULL CHECK(global_multiplier_ppm >= 0) | multiplier snapshot | insert only |
| `gross_credits` | INTEGER | NOT NULL CHECK(gross_credits >= 0) | pre-split credits | insert only |
| `provider_share_bps` | INTEGER | NOT NULL CHECK(provider_share_bps BETWEEN 0 AND 10000) | share snapshot | insert only |
| `provider_credits` | INTEGER | NOT NULL CHECK(provider_credits >= 0) | provider net credits | insert only |
| `overshoot_flag` | INTEGER | NOT NULL DEFAULT 0 CHECK(overshoot_flag IN (0,1)) | quota overshoot advisory | insert only |
| `fault_flag` | TEXT | NOT NULL DEFAULT 'none' CHECK(fault_flag IN ('none','breaker_qualifying','null_usage_error')) | fault diagnostic | insert only |
| `attestation_class` | TEXT | NULL | SPEC-008 future-proofing | insert only |
| `settled` | INTEGER | NOT NULL DEFAULT 0 CHECK(settled IN (0,1)) | settlement marker | 0 to 1 only |
| `settlement_id` | INTEGER | NULL | ledger_payout_ready id | set once |
| `quarantined` | INTEGER | NOT NULL DEFAULT 0 CHECK(quarantined IN (0,1)) | operator-review marker | 0 to 1 only |
| `quarantine_reason` | TEXT | NULL | quarantine explanation | set by recovery |
| `recovery_source` | TEXT | NOT NULL DEFAULT 'hot_path' CHECK(recovery_source IN ('hot_path','startup_scan','nightly_reconcile')) | row origin | insert only |
| `created_at_utc` | TEXT | NOT NULL | creation time | insert only |
| `updated_at_utc` | TEXT | NULL | settlement/quarantine update time | bounded update |

Indexes and uniqueness constraints:
- `UNIQUE(request_id, attempt_n, provider_id)`
- `INDEX idx_lrc_provider_ts(provider_id, ts_utc)`
- `INDEX idx_lrc_unsettled(provider_id, settled, ts_utc)`
- `INDEX idx_lrc_request(request_id)`
- `INDEX idx_lrc_quarantine(quarantined, ts_utc)`
- `INDEX idx_lrc_fault(provider_id, fault_flag, ts_utc)`

### 4.4 Table `ledger_operator_credits`

| Column | Type | Constraint | Meaning | Update rule |
|---|---|---|---|---|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | local row id | insert only |
| `request_credit_id` | INTEGER | NOT NULL REFERENCES ledger_request_credits(id) | request credit row | insert only |
| `request_id` | TEXT | NOT NULL | copy for joins | insert only |
| `attempt_n` | INTEGER | NOT NULL CHECK(attempt_n >= 0) | attempt ordinal | insert only |
| `provider_id` | TEXT | NOT NULL | stable provider id | insert only |
| `ts_utc` | TEXT | NOT NULL | request timestamp | insert only |
| `gross_credits` | INTEGER | NOT NULL CHECK(gross_credits >= 0) | gross request credits | insert only |
| `operator_share_bps` | INTEGER | NOT NULL CHECK(operator_share_bps BETWEEN 0 AND 10000) | operator share | insert only |
| `operator_credits` | INTEGER | NOT NULL CHECK(operator_credits >= 0) | operator net credits | insert only |
| `fault_flag` | TEXT | NOT NULL DEFAULT 'none' CHECK(fault_flag IN ('none','breaker_qualifying','null_usage_error')) | fault diagnostic | insert only |
| `created_at_utc` | TEXT | NOT NULL | creation time | insert only |

Indexes and uniqueness constraints:
- `UNIQUE(request_credit_id)`
- `INDEX idx_loc_request(request_id)`
- `INDEX idx_loc_provider_ts(provider_id, ts_utc)`
- `INDEX idx_loc_ts(ts_utc)`

### 4.5 Table `ledger_payout_ready`

| Column | Type | Constraint | Meaning | Update rule |
|---|---|---|---|---|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | local row id | insert only |
| `provider_id` | TEXT | NOT NULL | stable provider id | insert only |
| `window_start_utc` | TEXT | NOT NULL | inclusive window start | insert only |
| `window_end_utc` | TEXT | NOT NULL | exclusive window end | insert only |
| `cadence_days` | INTEGER | NOT NULL CHECK(cadence_days > 0) | cadence snapshot | insert only |
| `source_credit_count` | INTEGER | NOT NULL CHECK(source_credit_count > 0) | source row count | insert only |
| `gross_credits` | INTEGER | NOT NULL CHECK(gross_credits >= 0) | gross included credits | insert only |
| `provider_credits` | INTEGER | NOT NULL CHECK(provider_credits >= 0) | provider included credits | insert only |
| `operator_credits` | INTEGER | NOT NULL CHECK(operator_credits >= 0) | operator included credits | insert only |
| `min_payout_credits` | INTEGER | NOT NULL CHECK(min_payout_credits >= 0) | threshold snapshot | insert only |
| `payout_currency` | TEXT | NULL | SPEC-007 reserved; SPEC-005 writes NULL | SPEC-007 only |
| `payout_external_id` | TEXT | NULL | SPEC-007 reserved; SPEC-005 writes NULL | SPEC-007 only |
| `status` | TEXT | NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','consumed','voided')) | payout row status | SPEC-007 only after ready |
| `idempotency_key` | TEXT | NOT NULL | rerun-safe key | insert only |
| `created_at_utc` | TEXT | NOT NULL | creation time | insert only |

Indexes and uniqueness constraints:
- `UNIQUE(provider_id, window_start_utc, window_end_utc)`
- `UNIQUE(idempotency_key)`
- `INDEX idx_lpr_provider_status(provider_id, status, window_end_utc)`
- `INDEX idx_lpr_status(status, window_end_utc)`

### 4.6 Table `ledger_reconciliation_runs`

| Column | Type | Constraint | Meaning | Update rule |
|---|---|---|---|---|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | local row id | insert only |
| `run_type` | TEXT | NOT NULL CHECK(run_type IN ('startup_scan','nightly_reconcile','admin_reconcile')) | caller type | insert only |
| `from_utc` | TEXT | NOT NULL | inclusive scan start | insert only |
| `to_utc` | TEXT | NOT NULL | exclusive scan end | insert only |
| `request_log_rows_scanned` | INTEGER | NOT NULL CHECK(request_log_rows_scanned >= 0) | source row count | insert only |
| `missing_credit_rows_created` | INTEGER | NOT NULL CHECK(missing_credit_rows_created >= 0) | recovery count | insert only |
| `orphan_credit_rows_quarantined` | INTEGER | NOT NULL CHECK(orphan_credit_rows_quarantined >= 0) | quarantine count | insert only |
| `buyer_debit_credits` | INTEGER | NOT NULL CHECK(buyer_debit_credits >= 0) | derived buyer total | insert only |
| `provider_gross_credits` | INTEGER | NOT NULL CHECK(provider_gross_credits >= 0) | ledger gross total | insert only |
| `reconciliation_delta_credits` | INTEGER | NOT NULL | provider minus buyer gross | insert only |
| `started_at_utc` | TEXT | NOT NULL | run start | insert only |
| `finished_at_utc` | TEXT | NULL | run finish | set once |
| `status` | TEXT | NOT NULL CHECK(status IN ('running','complete','failed')) | run status | running to final |
| `error` | TEXT | NULL | failure text | set on failure |
| `created_at_utc` | TEXT | NOT NULL | creation time | insert only |

Indexes and uniqueness constraints:
- `INDEX idx_lrr_type_started(run_type, started_at_utc)`
- `INDEX idx_lrr_range(from_utc, to_utc)`

### 4.7 Migration ordering

- MIG-005-001 creates ledger_request_credits.
- MIG-005-002 creates ledger_operator_credits.
- MIG-005-003 creates ledger_payout_ready.
- MIG-005-004 creates ledger_reconciliation_runs.
- MIG-005-005 validates request_log columns by read-only introspection.
- No SPEC-005 migration alters request_log.

## 5. Units and arithmetic

### 5.1 Unit definition

1 credit = 1 USD micro-dollar = $0.000001.
All credit columns MUST be INTEGER.
All split fields use INTEGER basis points or INTEGER PPM.
YAML decimal multiplier MUST be converted to exact integer PPM before arithmetic.

### 5.2 Rounding rule

SPEC-005 uses round half to even.
If twice the remainder is below denominator, round down.
If twice the remainder is above denominator, round up.
If exactly half, choose the nearest even integer.
Operator credits equal gross minus provider credits so split sums exactly.

### 5.3 Closed-form request formula

```text
effective_completion_tokens = completion_tokens when usage_source = provider_reported
effective_completion_tokens = estimated_completion_tokens when usage_source = byte_estimated
effective_completion_tokens = 0 when usage_source in {null_error, provider_not_reached}
base_numerator = prompt_tokens * prompt_rate_per_mtok + effective_completion_tokens * completion_rate_per_mtok
rate_scaled_numerator = base_numerator * global_multiplier_ppm
gross_credits = round_half_even(rate_scaled_numerator, 1_000_000 * 1_000_000)
provider_credits = round_half_even(gross_credits * provider_share_bps, 10_000)
operator_credits = gross_credits - provider_credits
```
Fault and null-error overrides set gross, provider, and operator credits to 0 before split.

### 5.4 Worked examples

- 200 with 1000 prompt and 2000 completion tokens on 7B rates: gross=5000, provider=4500, operator=500.
- 502 prompt-only with 1000 prompt tokens on 7B rates: gross=1000, provider=900, operator=100.
- Null usage error path: gross=0, provider=0, operator=0.
- Unknown model: default rates 500000 prompt and 1000000 completion are snapshotted.
- global_multiplier 0.5: parse to 500000 PPM before the formula.

## 6. Credit calculation: D8 mapping

SPEC-006 v0.8.1 § 17.7 is the source of truth for buyer debits.
SPEC-005 mirrors every row with a provider-credit derivation.

### 6.1 200 success

**SPEC-006 § 17.7 status:** 200.
**Completion-token state:** as reported.
**Buyer debit:** prompt + completion.
**SPEC-005 provider-credit rule:** Write ledger row; provider_reported; compute prompt plus completion.
**Closed form:** apply § 5.3 to this row after its token-source selection and overrides.

### 6.2 503 no provider reached

**SPEC-006 § 17.7 status:** 503.
**Completion-token state:** 0.
**Buyer debit:** none.
**SPEC-005 provider-credit rule:** Write no provider or operator ledger row.
**Closed form:** apply § 5.3 to this row after its token-source selection and overrides.

### 6.3 502 zero completion

**SPEC-006 § 17.7 status:** 502.
**Completion-token state:** 0.
**Buyer debit:** prompt only.
**SPEC-005 provider-credit rule:** Write prompt-only ledger row unless FR-P11a override applies.
**Closed form:** apply § 5.3 to this row after its token-source selection and overrides.

### 6.4 502 partial stream

**SPEC-006 § 17.7 status:** 502.
**Completion-token state:** >0 partial.
**Buyer debit:** prompt + actual completion.
**SPEC-005 provider-credit rule:** Write prompt plus actual completion ledger row unless FR-P11a override applies.
**Closed form:** apply § 5.3 to this row after its token-source selection and overrides.

### 6.5 504 zero completion

**SPEC-006 § 17.7 status:** 504.
**Completion-token state:** 0.
**Buyer debit:** prompt only.
**SPEC-005 provider-credit rule:** Write prompt-only ledger row unless FR-P11a override applies.
**Closed form:** apply § 5.3 to this row after its token-source selection and overrides.

### 6.6 504 partial stream

**SPEC-006 § 17.7 status:** 504.
**Completion-token state:** >0 partial.
**Buyer debit:** prompt + actual completion.
**SPEC-005 provider-credit rule:** Write prompt plus actual completion ledger row unless FR-P11a override applies.
**Closed form:** apply § 5.3 to this row after its token-source selection and overrides.

### 6.7 Client disconnect v1.2.4+

**SPEC-006 § 17.7 status:** client_disconnect.
**Completion-token state:** provider reported actual.
**Buyer debit:** prompt + actual completion.
**SPEC-005 provider-credit rule:** Use provider usage exactly.
**Closed form:** apply § 5.3 to this row after its token-source selection and overrides.

### 6.8 Client disconnect pre-v1.2.4

**SPEC-006 § 17.7 status:** client_disconnect.
**Completion-token state:** byte estimated.
**Buyer debit:** prompt + ceil(bytes/4).
**SPEC-005 provider-credit rule:** Use the same estimate as buyer debit.
**Closed form:** apply § 5.3 to this row after its token-source selection and overrides.

### 6.9 Null usage error path

If completion_tokens IS NULL because SPEC-001 returned error_model_not_loaded, error_context_exceeded, error_queue_full, or error_internal, provider credit is 0.
A provider-reached null-error path writes a zero-credit row for audit completeness.
The row sets usage_source=null_error and fault_flag=null_usage_error unless FR-P11a breaker_qualifying is more specific.

### 6.10 Buyer-cancel exclusion

Buyer-initiated cancels are not faults.
Cancel with provider-reported usage credits actual tokens.
Cancel with absent usage on pre-v1.2.4 providers credits the same byte estimate used by the buyer side.
A cancel MUST NOT be zeroed merely because the buyer disconnected.

### 6.11 FR-P11a fault override

FR-P11a breaker-qualifying categories are relay-timeout-mid-inference, dead-WS-mid-inference, and qualified zero-token-completion.
A breaker-qualifying row writes ledger_request_credits with fault_flag=breaker_qualifying.
gross_credits, provider_credits, and operator_credits are all 0.
The corresponding ledger_operator_credits row is also 0.
This override takes precedence over prompt-only credit.

## 7. Settlement

### 7.1 Cadence

Weekly cadence is locked by D2.
The job runs as an in-process coordinator goroutine.
The boundary is UTC Monday 00:00.
settlement.cadence_days defaults to 7.
No cron or external scheduler is introduced in v1.

### 7.2 Threshold

settlement.min_payout_credits defaults to 500000.
Below-threshold rows remain unsettled and roll forward.
At or above threshold, one payout-ready row per provider per week is emitted.
The threshold is configurable for SPEC-007 gas calibration.

### 7.3 Split recording

provider_share_bps is snapshotted on every request-credit row.
operator_share_bps is derived as 10000 - provider_share_bps.
Historical rows are immutable after share changes.
operator_credits is gross_credits minus provider_credits.

### 7.4 Idempotency

The idempotency key is provider_id plus window_start_utc plus window_end_utc.
Re-running a window cannot create duplicate payout-ready rows.
If payout-ready exists and source rows are unsettled, rerun may mark only matching source rows settled.
Conflicting settlement_id values quarantine rows.

### 7.5 Update exception

The hot path never updates ledger_request_credits.
Settlement may update settled and settlement_id.
Recovery may update quarantine fields.
No process may update tokens, rates, split snapshots, or credit amounts.

## 8. Multi-attempt attribution (D10)

### 8.1 Key

Every credit row is keyed by request_id, attempt_n, and provider_id.
The unique index rejects duplicate attempt credits.
Stable provider_id is the economic identity.

### 8.2 Derivation

When SPEC-002 exposes attempt_n, copy it exactly.
Until then, first attempt uses 0 and one explicit retry uses 1.
More than two rows for one request before the patch are ambiguous and quarantined.

### 8.3 Invariant

Every attempt independently runs through § 6.
Request-level gross is the sum of attempt gross credits.
Winner-takes-all is forbidden.
No attempt may borrow tokens from another attempt.

### 8.4 Cross-spec patch

SPEC-002 needs an attempt_n column or equivalent monotonic attempt ordinal.
SPEC-005 does not apply that patch.
The operator must gate that patch in audit or v0.2 work.

## 9. Fraud floor and FR-P11a integration (D12)

### 9.1 Fault categories

relay-timeout-mid-inference qualifies.
dead-WS-mid-inference qualifies.
qualified zero-token-completion qualifies.
buyer-initiated cancel does not qualify.

### 9.2 Zero-credit audit row

Every provider-reached fault writes a row.
The row sets fault_flag=breaker_qualifying.
All economic amounts are 0.
The provider earnings endpoint exposes the count.

### 9.3 Degraded and unavailable states

FR-R4 routes no traffic to degraded or unavailable providers.
No routed traffic means no new earning rows.
Rows that contradict state must be quarantined unless timing proves otherwise.

### 9.4 Recovery

After FR-P11a recovery preflight returns ready, normal credits resume.
No carry-over penalty.
No reduced-credit tier.
No extra re-warmup beyond FR-P11a.

## 10. Crash recovery and reconciliation (D9)

### 10.1 Transaction contract

Hot path MUST use BEGIN IMMEDIATE; ...; COMMIT.
request_log, ledger_request_credits, and ledger_operator_credits are written together.
Crash before COMMIT loses all rows together.
Crash after COMMIT preserves all rows together.
No 2PC is used.

### 10.2 Startup scan

Startup scans prior 24 hours.
Creditable request_log rows missing ledger rows get recovery rows.
Recovery rows set recovery_source=startup_scan.
The scan is idempotent.

### 10.3 Nightly reconcile

Nightly goroutine scans prior 7 days.
It uses the same deterministic classifier as startup.
It writes ledger_reconciliation_runs.
It quarantines orphan ledger rows.
It does not delete rows.

### 10.4 Deterministic algorithm

Function signature: RecoverLedger(requestLogRows, ledgerRows, configSnapshot, scanWindow).
Outputs: recoveryRows, quarantineUpdates, reconciliationSummary.
Same inputs produce byte-identical outputs.
Time is explicit input.
No live network call may affect output.

### 10.5 Quarantine

Absent request_log join quarantines ledger rows.
Inconsistent immutable math quarantines ledger rows.
Ambiguous attempt_n fallback quarantines rows.
Quarantine is review, not deletion.
Quarantined rows are exposed in admin endpoints.

## 11. Operator and provider endpoints (D11)

### 11.1 `GET /admin/ledger/summary`

Auth: operator key.
Purpose: totals, this week, last 4 weeks, pending payouts, quarantined rows.
Response MUST be JSON.
Response fields:
- `total_gross_credits`
- `total_provider_credits`
- `total_operator_credits`
- `current_window_provider_credits`
- `pending_payout_count`
- `pending_payout_credits`
- `quarantined_count`
- `fault_count`
- `last_reconciliation_delta_credits`
No HTML, chart markup, Slack payload, or email body is returned.

### 11.2 `GET /admin/ledger/providers`

Auth: operator key.
Purpose: per-provider breakdown.
Response MUST be JSON.
Response fields:
- `provider_id`
- `total_provider_credits`
- `current_window_credits`
- `pending_payout_credits`
- `last_activity_utc`
- `fault_count`
- `quarantined_count`
- `attestation_class`
No HTML, chart markup, Slack payload, or email body is returned.

### 11.3 `GET /admin/ledger/reconcile?from=YYYY-MM-DD&to=YYYY-MM-DD`

Auth: operator key.
Purpose: H-005 reconciliation report.
Response MUST be JSON.
Response fields:
- `from_utc`
- `to_utc`
- `buyer_debit_credits`
- `provider_gross_credits`
- `delta_credits`
- `rows_scanned`
- `rows_recovered`
- `rows_quarantined`
No HTML, chart markup, Slack payload, or email body is returned.

### 11.4 `GET /providers/{provider_id}/earnings`

Auth: FR-P12 provider bearer token.
Purpose: provider-owned earnings view.
Response MUST be JSON.
Response fields:
- `provider_id`
- `total_credits`
- `current_window_credits`
- `last_payout_ready`
- `provider_share_bps`
- `models_served`
- `rate_card_excerpt`
- `fault_count`
No HTML, chart markup, Slack payload, or email body is returned.

### 11.5 Provider endpoint authorization

Provider endpoint MUST use FR-P12 bearer-token auth.
Token subject MUST equal path provider_id.
Wrong-subject token returns 403.
Missing token returns 401.
Unknown provider_id returns 404 without enumerating valid providers.

## 12. Buyer-balance interaction (D7)

SPEC-005 does not enforce buyer quota.
SPEC-006 gateway quota is authoritative.
If the gateway forwarded and the provider performed work, provider credit follows § 6.
Over-quota overshoot does not zero provider credit.
overshoot_flag is advisory only.
Operator recourse is quota tuning, not provider clawback.

## 13. Configuration

All SPEC-005 configuration lives in coordinator.yaml.
Config changes affect only new request-credit rows.

| Key | Type | Default | Notes |
|---|---|---|---|
| `rewards.global_multiplier` | number | `1.0` | operator volume knob; parse to PPM |
| `rewards.provider_share` | number | `0.90` | parse to provider_share_bps=9000 |
| `rewards.rate_card.default.prompt_credits_per_mtok` | integer | `500000` | default prompt rate |
| `rewards.rate_card.default.completion_credits_per_mtok` | integer | `1000000` | default completion rate |
| `rewards.rate_card.<model>.prompt_credits_per_mtok` | integer | `model-specific` | enumerated model prompt rate |
| `rewards.rate_card.<model>.completion_credits_per_mtok` | integer | `model-specific` | enumerated model completion rate |
| `settlement.cadence_days` | integer | `7` | weekly cadence |
| `settlement.min_payout_credits` | integer | `500000` | threshold |
| `settlement.startup_reconcile_window_hours` | integer | `24` | startup scan window |
| `settlement.nightly_reconcile_window_days` | integer | `7` | nightly scan window |
| `settlement.job_enabled` | boolean | `true` | test-disable switch for scheduler only |

### 13.1 Initial placeholder rate card

| Model class | prompt credits/Mtok | completion credits/Mtok |
|---|---:|---:|
| 7B, e.g. `mlx-community/Qwen2.5-7B-Instruct-4bit` | 1000000 | 2000000 |
| 3B, e.g. `mlx-community/Llama-3.2-3B-Instruct-4bit` | 500000 | 1000000 |
| default | 500000 | 1000000 |

### 13.2 Hot reload

New values apply only after reload acknowledgement.
Rows snapshot the applied values.
Invalid reload keeps prior valid config.
Cold start without default rate-card row fails.

## 14. Instrumentation and metrics

- Metric: per-provider total credits. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: current-window credits. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: pending payout-ready rows. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: pending payout-ready credits. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: quarantined rows. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: breaker-qualifying faults. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: null-usage zero-credit rows. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: startup recovery rows. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: nightly recovery rows. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: reconciliation delta. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: rate-card default fallback count. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: unknown model count. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: overshoot flag count. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: settlement job duration. Source: § 11 endpoints. No new metrics surface in v1.
- Metric: idempotent settlement replay count. Source: § 11 endpoints. No new metrics surface in v1.

## 15. Backward compatibility

### 15.1 Pre-v1.2.4 cancel usage

Use byte-estimation fallback only when usage is absent.
Use the same estimate as SPEC-006 buyer debit.
Set usage_source=byte_estimated.

### 15.2 attempt_n fallback

No-retry and one explicit retry are supported before SPEC-002 patch.
Ambiguous 2+ retry rows are quarantined.
§ 20 surfaces the patch.

### 15.3 Unknown models

Use default rate-card row.
Snapshot default rates on row.
Expose fallback count to operator metrics.

### 15.4 Missed settlement

Rerun is safe.
Idempotency key prevents duplicate payout-ready rows.
All unsettled rows up to window end are included.

## 16. Security and privacy

### 16.1 Admin auth

/admin/ledger/* uses existing operator-key auth.
Invalid or missing key returns 403.
Admin endpoints are coordinator-side, not gateway-side.

### 16.2 Provider auth

Provider earnings uses FR-P12.
Authenticated provider must match path provider.
Provider earnings are provider-private.

### 16.3 Buyer secrecy

No SPEC-005 endpoint is buyer-facing.
No buyer-visible response may leak provider earnings.
SPEC-005 adds no buyer-visible headers.

### 16.4 Rate-card privacy

Full rate card is not public.
Provider endpoint may return only models served by that provider.
Admin endpoint may expose full operator view.

### 16.5 Audit trail

Hot-path rows append only.
Settlement and quarantine are bounded exceptions.
Future manual review should append audit events.

## 17. Failure modes

| Failure | Surface | Result | Required behavior |
|---|---|---|---|
| Admin key invalid | /admin/ledger/* | 403 | no ledger data |
| Admin key missing | /admin/ledger/* | 403 | no ledger data |
| Provider token missing | /providers/{provider_id}/earnings | 401 | no provider data |
| Provider token invalid | /providers/{provider_id}/earnings | 401 | no provider data |
| Provider token wrong subject | /providers/{provider_id}/earnings | 403 | no provider data |
| Unknown provider_id | /providers/{provider_id}/earnings | 404 | no enumeration |
| Settlement crash before payout row | settlement goroutine | retry | source rows remain unsettled |
| Settlement crash after payout row | settlement goroutine | repair | rerun marks matching source rows |
| Missing ledger row | startup/nightly | repair | write deterministic recovery row |
| Orphan ledger row | startup/nightly | quarantine | quarantined=1 |
| Missing default rate | config load | startup failure | unknown models cannot be priced |
| Invalid multiplier | config reload | reload failure | keep prior valid config |

## 18. Acceptance criteria

Every AC is deterministic and requires no live network.
Fixtures may use in-memory SQLite, temporary SQLite, or pure functions.

### AC-D1: Billing model encoded

**Verification:** Parse § 2 and locate D1; then locate at least one later normative reference.
**Expected:** D1 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D2: Settlement cadence encoded

**Verification:** Parse § 2 and locate D2; then locate at least one later normative reference.
**Expected:** D2 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D3: Provider reward formula encoded

**Verification:** Parse § 2 and locate D3; then locate at least one later normative reference.
**Expected:** D3 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D4: Minimum payout threshold encoded

**Verification:** Parse § 2 and locate D4; then locate at least one later normative reference.
**Expected:** D4 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D5: Revenue split encoded

**Verification:** Parse § 2 and locate D5; then locate at least one later normative reference.
**Expected:** D5 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D6: Currency / unit encoded

**Verification:** Parse § 2 and locate D6; then locate at least one later normative reference.
**Expected:** D6 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D7: Buyer balance enforcement encoded

**Verification:** Parse § 2 and locate D7; then locate at least one later normative reference.
**Expected:** D7 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D8: Failed-request accounting encoded

**Verification:** Parse § 2 and locate D8; then locate at least one later normative reference.
**Expected:** D8 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D9: Crash recovery policy encoded

**Verification:** Parse § 2 and locate D9; then locate at least one later normative reference.
**Expected:** D9 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D10: Multi-provider attribution encoded

**Verification:** Parse § 2 and locate D10; then locate at least one later normative reference.
**Expected:** D10 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D11: Operator dashboard scope encoded

**Verification:** Parse § 2 and locate D11; then locate at least one later normative reference.
**Expected:** D11 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D12: Fraud floor for degraded providers encoded

**Verification:** Parse § 2 and locate D12; then locate at least one later normative reference.
**Expected:** D12 exists in § 2 and is enforced outside § 2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-H005: H-005 symmetry

**Verification:** Construct all eight SPEC-006 § 17.7 states and run the § 6 credit function.
**Expected:** Each buyer-debit state has the specified provider-credit state; provider-not-reached writes no row.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ROW-200: 200 success formula

**Verification:** Fixture prompt=1000 completion=2000 7B rates share=9000.
**Expected:** gross=5000 provider=4500 operator=500.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ROW-503: 503 no provider reached

**Verification:** Fixture status=503 provider_assigned_id=NULL.
**Expected:** No ledger_request_credits or ledger_operator_credits row.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ROW-502-0: 502 prompt-only

**Verification:** Fixture status=502 prompt=1000 completion=0.
**Expected:** Gross uses prompt only.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ROW-502-PARTIAL: 502 partial

**Verification:** Fixture status=502 prompt=1000 completion=17.
**Expected:** Gross uses prompt plus 17 completion tokens.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ROW-504-0: 504 prompt-only

**Verification:** Fixture status=504 prompt=1000 completion=0.
**Expected:** Gross uses prompt only.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ROW-504-PARTIAL: 504 partial

**Verification:** Fixture status=504 prompt=1000 completion=19.
**Expected:** Gross uses prompt plus 19 completion tokens.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-DISCONNECT-ACTUAL: Cancel actual usage

**Verification:** Fixture cancel usage prompt=1000 completion=30.
**Expected:** usage_source=provider_reported and gross includes 30 completion.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-DISCONNECT-ESTIMATE: Cancel byte estimate

**Verification:** Fixture bytes_emitted=120 prompt=1000 usage absent.
**Expected:** estimated_completion_tokens=30 and gross includes 30 completion.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-NULL: Null usage zero credit

**Verification:** Fixture provider reached, SPEC-001 error_internal, completion_tokens NULL.
**Expected:** One zero-credit row with usage_source=null_error.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-FAULT: FR-P11a fault zero credit

**Verification:** Fixture relay-timeout-mid-inference.
**Expected:** One zero-credit row with fault_flag=breaker_qualifying.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-MULTIHOP: Two-attempt attribution

**Verification:** Fixture two providers and one request_id.
**Expected:** Two rows with distinct attempt_n/provider_id keys; sums match attempt totals.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ATTEMPT-FALLBACK: retried fallback limit

**Verification:** Fixture three rows before attempt_n patch.
**Expected:** Ambiguous row is quarantined.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-CRASH: ACID crash boundary

**Verification:** Abort a transaction before COMMIT and commit a second transaction.
**Expected:** Abort leaves no partial rows; commit leaves request_log plus ledger rows.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-STARTUP-SCAN: Startup scan recovery

**Verification:** Seed a prior-24h creditable request_log row without ledger row.
**Expected:** Exactly one startup_scan recovery row.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-NIGHTLY: Nightly reconcile recovery

**Verification:** Seed a prior-7d row outside startup window without ledger row.
**Expected:** Exactly one nightly_reconcile recovery row.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-QUARANTINE: Orphan quarantine

**Verification:** Seed ledger row with absent request_log.
**Expected:** quarantined=1 with reason.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-THRESHOLD-BELOW: Below threshold roll forward

**Verification:** Seed 499999 unsettled provider credits.
**Expected:** No payout-ready row; source rows remain unsettled.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-THRESHOLD-AT: At threshold payout ready

**Verification:** Seed 500000 unsettled provider credits.
**Expected:** One payout-ready row; source rows settled=1.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-SETTLEMENT-IDEMPOTENT: Settlement rerun safe

**Verification:** Run same settlement window twice.
**Expected:** Exactly one payout-ready row.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-SPLIT: Split immutable

**Verification:** Create one row at 9000 bps; change config to 9500; create second row.
**Expected:** Old row stays 9000; new row uses 9500.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-RATE-CARD-DEFAULT: Unknown model fallback

**Verification:** Create row for unknown model.
**Expected:** Default rates are snapshotted.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-RATE-CARD-HOT-RELOAD: New rates only

**Verification:** Create row, reload config, create second row.
**Expected:** Only second row uses new rates.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-INTEGER-ARITHMETIC: No float storage

**Verification:** Inspect SQLite schema.
**Expected:** No credit/split/payout amount column uses REAL or FLOAT.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ROUND-HALF-EVEN: Rounding exactness

**Verification:** Run half, below-half, above-half fixtures.
**Expected:** Half rounds to even.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ENDPOINTS-SHAPE: Endpoint JSON shape

**Verification:** Invoke handlers with fixture stores.
**Expected:** All four endpoints return documented JSON fields.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ENDPOINTS-AUTH: Endpoint auth

**Verification:** Invoke without credentials.
**Expected:** Admin 403; provider 401; no data leak.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-PROVIDER-SCOPE: Provider isolation

**Verification:** Token for provider A requests provider B path.
**Expected:** 403; no B earnings leak.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-NO-WIRE-CHANGE: No SPEC-001 wire change

**Verification:** Grep SPEC-005 for Phase 3 new-field requirements.
**Expected:** No such requirement.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-NO-GATEWAY-CHANGE: No gateway billing state

**Verification:** Grep SPEC-005 for gateway ledger write/read requirements.
**Expected:** No such requirement.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-NO-ONCHAIN: No AntFeed/on-chain

**Verification:** Grep SPEC-005 for AntFeed call, on-chain state, USDC-specific column type.
**Expected:** No such requirement.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-REQUEST-LOG-READONLY: request_log read only

**Verification:** Grep migrations for ALTER TABLE request_log.
**Expected:** No ALTER appears.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-CONFIG-DEFAULTS: Config defaults

**Verification:** Load empty SPEC-005 config fixture.
**Expected:** Defaults match § 13.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-METRICS: Metrics through endpoints

**Verification:** Compare § 14 metrics to endpoint fixture output.
**Expected:** Every metric is available through § 11 endpoints.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-DOCS-HONESTY: Provider docs honest

**Verification:** Render provider docs snippet.
**Expected:** Snippet says v1 accrues credits and payout requires SPEC-007/operator decision.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

## 19. Audit categories

- **Category A: Locked-decision fidelity.** D1-D12 encoded and referenced.
- **Category B: Storage completeness.** Every table, column, type, constraint, index, and migration is listed.
- **Category C: request_log boundary.** JOIN-only, never ALTER.
- **Category D: Credit arithmetic.** integer-only, exact rounding, split sums.
- **Category E: SPEC-006 symmetry.** each § 17.7 row maps to one credit rule.
- **Category F: FR-P11a fraud floor.** fault rows present and zero-credit.
- **Category G: Crash recovery.** same transaction plus deterministic scans.
- **Category H: Settlement idempotency.** reruns safe, no duplicate payout-ready rows.
- **Category I: Endpoint auth.** operator/provider auth scopes correct.
- **Category J: Rate-card reload.** new rows only, old rows immutable.
- **Category K: Out-of-scope discipline.** no AntFeed, on-chain, gateway, Stripe, KYC, or dashboard creep.
- **Category L: Provider-facing honesty.** no cash-payout promise in v1.
- **Category M: Backward compatibility.** pre-v1.2.4 fallback and retried fallback deterministic.
- **Category N: Acceptance criteria quality.** every AC has no-live-network verification.

## 20. Open questions to operator

### OQ-1: SPEC-002 attempt_n patch

SPEC-005 v0.1 needs a monotonic attempt_n for full multi-attempt accounting. Current fallback quarantines ambiguity.

### OQ-2: Rounding rule acceptance

This draft chooses round half to even. Operator should confirm before v0.2.

### OQ-3: Recovery windows

Defaults are 24h startup and 7d nightly. Operator should confirm the operational fit.

### OQ-4: Provider docs wording

Provider-facing copy should say v1 accrues credits and payout requires SPEC-007/operator decision.

### OQ-5: Manual quarantine resolution

SPEC-005 exposes quarantine but does not define force-credit or force-void admin actions.

## Appendix A. Self-verification checklist

- [x] dependency pins current
- [x] D1-D12 present
- [x] storage columns complete
- [x] request_log read-only
- [x] attempt_n patch surfaced
- [x] integer arithmetic defined
- [x] rounding rule defined
- [x] D8 matrix complete
- [x] weekly settlement specified
- [x] multi-attempt key specified
- [x] FR-P11a fault names present
- [x] BEGIN IMMEDIATE named
- [x] deterministic recovery signature named
- [x] four endpoints specified
- [x] config keys specified
- [x] ACs deterministic
- [x] out-of-scope guards explicit
- [x] no SPEC-001 change
- [x] no SPEC-006 change
- [x] no gateway billing state
- [x] Go coordinator assumed
- [x] single SQLite deployment assumed

## Appendix B. Decision traceability matrix

| Decision | § 2 anchor | Normative anchors | AC anchor |
|---|---|---|---|
| D1 | § 2.1 | § 1.3, § 12, § 16 | AC-D1 |
| D2 | § 2.2 | § 7, § 13 | AC-D2 |
| D3 | § 2.3 | § 5, § 13 | AC-D3 |
| D4 | § 2.4 | § 7.2, § 13 | AC-D4 |
| D5 | § 2.5 | § 5.3, § 7.3 | AC-D5 |
| D6 | § 2.6 | § 5 | AC-D6 |
| D7 | § 2.7 | § 12 | AC-D7 |
| D8 | § 2.8 | § 6 | AC-D8 |
| D9 | § 2.9 | § 10 | AC-D9 |
| D10 | § 2.10 | § 8 | AC-D10 |
| D11 | § 2.11 | § 11 | AC-D11 |
| D12 | § 2.12 | § 9 | AC-D12 |

## Appendix C. Column contract detail

### Appendix C - `ledger_request_credits` columns

#### `ledger_request_credits.id`

- Type: INTEGER.
- Constraint: PRIMARY KEY AUTOINCREMENT.
- Meaning: local row id.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.request_id`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: joins request_log.request_id.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.attempt_n`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(attempt_n >= 0).
- Meaning: zero-based attempt ordinal.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.provider_id`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: stable SPEC-002 FR-R3 provider id.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.provider_assigned_id`

- Type: TEXT.
- Constraint: NULL.
- Meaning: session-scoped assigned id.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.ts_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: request timestamp.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.model`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: model id used for rate card.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.status`

- Type: INTEGER.
- Constraint: NOT NULL.
- Meaning: buyer-visible HTTP status.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.stream`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(stream IN (0,1)).
- Meaning: streaming flag.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.prompt_tokens`

- Type: INTEGER.
- Constraint: NULL CHECK(prompt_tokens IS NULL OR prompt_tokens >= 0).
- Meaning: prompt tokens.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.completion_tokens`

- Type: INTEGER.
- Constraint: NULL CHECK(completion_tokens IS NULL OR completion_tokens >= 0).
- Meaning: reported completion tokens.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.estimated_completion_tokens`

- Type: INTEGER.
- Constraint: NULL CHECK(estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0).
- Meaning: byte-estimated completion tokens.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.usage_source`

- Type: TEXT.
- Constraint: NOT NULL CHECK(usage_source IN ('provider_reported','byte_estimated','null_error','provider_not_reached')).
- Meaning: usage source.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.prompt_rate_per_mtok`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(prompt_rate_per_mtok >= 0).
- Meaning: rate snapshot.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.completion_rate_per_mtok`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(completion_rate_per_mtok >= 0).
- Meaning: rate snapshot.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.global_multiplier_ppm`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(global_multiplier_ppm >= 0).
- Meaning: multiplier snapshot.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.gross_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(gross_credits >= 0).
- Meaning: pre-split credits.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.provider_share_bps`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(provider_share_bps BETWEEN 0 AND 10000).
- Meaning: share snapshot.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.provider_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(provider_credits >= 0).
- Meaning: provider net credits.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.overshoot_flag`

- Type: INTEGER.
- Constraint: NOT NULL DEFAULT 0 CHECK(overshoot_flag IN (0,1)).
- Meaning: quota overshoot advisory.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.fault_flag`

- Type: TEXT.
- Constraint: NOT NULL DEFAULT 'none' CHECK(fault_flag IN ('none','breaker_qualifying','null_usage_error')).
- Meaning: fault diagnostic.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.attestation_class`

- Type: TEXT.
- Constraint: NULL.
- Meaning: SPEC-008 future-proofing.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.settled`

- Type: INTEGER.
- Constraint: NOT NULL DEFAULT 0 CHECK(settled IN (0,1)).
- Meaning: settlement marker.
- Update rule: 0 to 1 only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.settlement_id`

- Type: INTEGER.
- Constraint: NULL.
- Meaning: ledger_payout_ready id.
- Update rule: set once.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.quarantined`

- Type: INTEGER.
- Constraint: NOT NULL DEFAULT 0 CHECK(quarantined IN (0,1)).
- Meaning: operator-review marker.
- Update rule: 0 to 1 only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.quarantine_reason`

- Type: TEXT.
- Constraint: NULL.
- Meaning: quarantine explanation.
- Update rule: set by recovery.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.recovery_source`

- Type: TEXT.
- Constraint: NOT NULL DEFAULT 'hot_path' CHECK(recovery_source IN ('hot_path','startup_scan','nightly_reconcile')).
- Meaning: row origin.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.created_at_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: creation time.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.updated_at_utc`

- Type: TEXT.
- Constraint: NULL.
- Meaning: settlement/quarantine update time.
- Update rule: bounded update.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

### Appendix C - `ledger_operator_credits` columns

#### `ledger_operator_credits.id`

- Type: INTEGER.
- Constraint: PRIMARY KEY AUTOINCREMENT.
- Meaning: local row id.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.request_credit_id`

- Type: INTEGER.
- Constraint: NOT NULL REFERENCES ledger_request_credits(id).
- Meaning: request credit row.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.request_id`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: copy for joins.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.attempt_n`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(attempt_n >= 0).
- Meaning: attempt ordinal.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.provider_id`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: stable provider id.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.ts_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: request timestamp.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.gross_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(gross_credits >= 0).
- Meaning: gross request credits.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.operator_share_bps`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(operator_share_bps BETWEEN 0 AND 10000).
- Meaning: operator share.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.operator_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(operator_credits >= 0).
- Meaning: operator net credits.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.fault_flag`

- Type: TEXT.
- Constraint: NOT NULL DEFAULT 'none' CHECK(fault_flag IN ('none','breaker_qualifying','null_usage_error')).
- Meaning: fault diagnostic.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_operator_credits.created_at_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: creation time.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

### Appendix C - `ledger_payout_ready` columns

#### `ledger_payout_ready.id`

- Type: INTEGER.
- Constraint: PRIMARY KEY AUTOINCREMENT.
- Meaning: local row id.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.provider_id`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: stable provider id.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.window_start_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: inclusive window start.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.window_end_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: exclusive window end.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.cadence_days`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(cadence_days > 0).
- Meaning: cadence snapshot.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.source_credit_count`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(source_credit_count > 0).
- Meaning: source row count.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.gross_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(gross_credits >= 0).
- Meaning: gross included credits.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.provider_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(provider_credits >= 0).
- Meaning: provider included credits.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.operator_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(operator_credits >= 0).
- Meaning: operator included credits.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.min_payout_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(min_payout_credits >= 0).
- Meaning: threshold snapshot.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.payout_currency`

- Type: TEXT.
- Constraint: NULL.
- Meaning: SPEC-007 reserved; SPEC-005 writes NULL.
- Update rule: SPEC-007 only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.payout_external_id`

- Type: TEXT.
- Constraint: NULL.
- Meaning: SPEC-007 reserved; SPEC-005 writes NULL.
- Update rule: SPEC-007 only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.status`

- Type: TEXT.
- Constraint: NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','consumed','voided')).
- Meaning: payout row status.
- Update rule: SPEC-007 only after ready.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.idempotency_key`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: rerun-safe key.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.created_at_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: creation time.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

### Appendix C - `ledger_reconciliation_runs` columns

#### `ledger_reconciliation_runs.id`

- Type: INTEGER.
- Constraint: PRIMARY KEY AUTOINCREMENT.
- Meaning: local row id.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.run_type`

- Type: TEXT.
- Constraint: NOT NULL CHECK(run_type IN ('startup_scan','nightly_reconcile','admin_reconcile')).
- Meaning: caller type.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.from_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: inclusive scan start.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.to_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: exclusive scan end.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.request_log_rows_scanned`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(request_log_rows_scanned >= 0).
- Meaning: source row count.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.missing_credit_rows_created`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(missing_credit_rows_created >= 0).
- Meaning: recovery count.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.orphan_credit_rows_quarantined`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(orphan_credit_rows_quarantined >= 0).
- Meaning: quarantine count.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.buyer_debit_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(buyer_debit_credits >= 0).
- Meaning: derived buyer total.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.provider_gross_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(provider_gross_credits >= 0).
- Meaning: ledger gross total.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.reconciliation_delta_credits`

- Type: INTEGER.
- Constraint: NOT NULL.
- Meaning: provider minus buyer gross.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.started_at_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: run start.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.finished_at_utc`

- Type: TEXT.
- Constraint: NULL.
- Meaning: run finish.
- Update rule: set once.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.status`

- Type: TEXT.
- Constraint: NOT NULL CHECK(status IN ('running','complete','failed')).
- Meaning: run status.
- Update rule: running to final.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.error`

- Type: TEXT.
- Constraint: NULL.
- Meaning: failure text.
- Update rule: set on failure.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.created_at_utc`

- Type: TEXT.
- Constraint: NOT NULL.
- Meaning: creation time.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

## Appendix D. D8 deterministic fixture catalog

### Fixture: 200 success

- SPEC-006 status: 200.
- Completion-token state: as reported.
- Buyer debit basis: prompt + completion.
- Provider credit action: Write ledger row; provider_reported; compute prompt plus completion.
- Verification function: pass fixture through the § 5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: 503 no provider reached

- SPEC-006 status: 503.
- Completion-token state: 0.
- Buyer debit basis: none.
- Provider credit action: Write no provider or operator ledger row.
- Verification function: pass fixture through the § 5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: 502 zero completion

- SPEC-006 status: 502.
- Completion-token state: 0.
- Buyer debit basis: prompt only.
- Provider credit action: Write prompt-only ledger row unless FR-P11a override applies.
- Verification function: pass fixture through the § 5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: 502 partial stream

- SPEC-006 status: 502.
- Completion-token state: >0 partial.
- Buyer debit basis: prompt + actual completion.
- Provider credit action: Write prompt plus actual completion ledger row unless FR-P11a override applies.
- Verification function: pass fixture through the § 5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: 504 zero completion

- SPEC-006 status: 504.
- Completion-token state: 0.
- Buyer debit basis: prompt only.
- Provider credit action: Write prompt-only ledger row unless FR-P11a override applies.
- Verification function: pass fixture through the § 5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: 504 partial stream

- SPEC-006 status: 504.
- Completion-token state: >0 partial.
- Buyer debit basis: prompt + actual completion.
- Provider credit action: Write prompt plus actual completion ledger row unless FR-P11a override applies.
- Verification function: pass fixture through the § 5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: Client disconnect v1.2.4+

- SPEC-006 status: client_disconnect.
- Completion-token state: provider reported actual.
- Buyer debit basis: prompt + actual completion.
- Provider credit action: Use provider usage exactly.
- Verification function: pass fixture through the § 5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: Client disconnect pre-v1.2.4

- SPEC-006 status: client_disconnect.
- Completion-token state: byte estimated.
- Buyer debit basis: prompt + ceil(bytes/4).
- Provider credit action: Use the same estimate as buyer debit.
- Verification function: pass fixture through the § 5.3 arithmetic after row-specific token selection.
- Expected network use: none.

## Appendix E. Acceptance criterion fixture details

### AC-D1 fixture detail

- Claim: Billing model encoded.
- Setup: Parse § 2 and locate D1; then locate at least one later normative reference.
- Oracle: D1 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D2 fixture detail

- Claim: Settlement cadence encoded.
- Setup: Parse § 2 and locate D2; then locate at least one later normative reference.
- Oracle: D2 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D3 fixture detail

- Claim: Provider reward formula encoded.
- Setup: Parse § 2 and locate D3; then locate at least one later normative reference.
- Oracle: D3 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D4 fixture detail

- Claim: Minimum payout threshold encoded.
- Setup: Parse § 2 and locate D4; then locate at least one later normative reference.
- Oracle: D4 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D5 fixture detail

- Claim: Revenue split encoded.
- Setup: Parse § 2 and locate D5; then locate at least one later normative reference.
- Oracle: D5 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D6 fixture detail

- Claim: Currency / unit encoded.
- Setup: Parse § 2 and locate D6; then locate at least one later normative reference.
- Oracle: D6 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D7 fixture detail

- Claim: Buyer balance enforcement encoded.
- Setup: Parse § 2 and locate D7; then locate at least one later normative reference.
- Oracle: D7 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D8 fixture detail

- Claim: Failed-request accounting encoded.
- Setup: Parse § 2 and locate D8; then locate at least one later normative reference.
- Oracle: D8 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D9 fixture detail

- Claim: Crash recovery policy encoded.
- Setup: Parse § 2 and locate D9; then locate at least one later normative reference.
- Oracle: D9 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D10 fixture detail

- Claim: Multi-provider attribution encoded.
- Setup: Parse § 2 and locate D10; then locate at least one later normative reference.
- Oracle: D10 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D11 fixture detail

- Claim: Operator dashboard scope encoded.
- Setup: Parse § 2 and locate D11; then locate at least one later normative reference.
- Oracle: D11 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D12 fixture detail

- Claim: Fraud floor for degraded providers encoded.
- Setup: Parse § 2 and locate D12; then locate at least one later normative reference.
- Oracle: D12 exists in § 2 and is enforced outside § 2.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-H005 fixture detail

- Claim: H-005 symmetry.
- Setup: Construct all eight SPEC-006 § 17.7 states and run the § 6 credit function.
- Oracle: Each buyer-debit state has the specified provider-credit state; provider-not-reached writes no row.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ROW-200 fixture detail

- Claim: 200 success formula.
- Setup: Fixture prompt=1000 completion=2000 7B rates share=9000.
- Oracle: gross=5000 provider=4500 operator=500.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ROW-503 fixture detail

- Claim: 503 no provider reached.
- Setup: Fixture status=503 provider_assigned_id=NULL.
- Oracle: No ledger_request_credits or ledger_operator_credits row.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ROW-502-0 fixture detail

- Claim: 502 prompt-only.
- Setup: Fixture status=502 prompt=1000 completion=0.
- Oracle: Gross uses prompt only.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ROW-502-PARTIAL fixture detail

- Claim: 502 partial.
- Setup: Fixture status=502 prompt=1000 completion=17.
- Oracle: Gross uses prompt plus 17 completion tokens.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ROW-504-0 fixture detail

- Claim: 504 prompt-only.
- Setup: Fixture status=504 prompt=1000 completion=0.
- Oracle: Gross uses prompt only.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ROW-504-PARTIAL fixture detail

- Claim: 504 partial.
- Setup: Fixture status=504 prompt=1000 completion=19.
- Oracle: Gross uses prompt plus 19 completion tokens.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-DISCONNECT-ACTUAL fixture detail

- Claim: Cancel actual usage.
- Setup: Fixture cancel usage prompt=1000 completion=30.
- Oracle: usage_source=provider_reported and gross includes 30 completion.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-DISCONNECT-ESTIMATE fixture detail

- Claim: Cancel byte estimate.
- Setup: Fixture bytes_emitted=120 prompt=1000 usage absent.
- Oracle: estimated_completion_tokens=30 and gross includes 30 completion.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-NULL fixture detail

- Claim: Null usage zero credit.
- Setup: Fixture provider reached, SPEC-001 error_internal, completion_tokens NULL.
- Oracle: One zero-credit row with usage_source=null_error.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-FAULT fixture detail

- Claim: FR-P11a fault zero credit.
- Setup: Fixture relay-timeout-mid-inference.
- Oracle: One zero-credit row with fault_flag=breaker_qualifying.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-MULTIHOP fixture detail

- Claim: Two-attempt attribution.
- Setup: Fixture two providers and one request_id.
- Oracle: Two rows with distinct attempt_n/provider_id keys; sums match attempt totals.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ATTEMPT-FALLBACK fixture detail

- Claim: retried fallback limit.
- Setup: Fixture three rows before attempt_n patch.
- Oracle: Ambiguous row is quarantined.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-CRASH fixture detail

- Claim: ACID crash boundary.
- Setup: Abort a transaction before COMMIT and commit a second transaction.
- Oracle: Abort leaves no partial rows; commit leaves request_log plus ledger rows.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-STARTUP-SCAN fixture detail

- Claim: Startup scan recovery.
- Setup: Seed a prior-24h creditable request_log row without ledger row.
- Oracle: Exactly one startup_scan recovery row.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-NIGHTLY fixture detail

- Claim: Nightly reconcile recovery.
- Setup: Seed a prior-7d row outside startup window without ledger row.
- Oracle: Exactly one nightly_reconcile recovery row.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-QUARANTINE fixture detail

- Claim: Orphan quarantine.
- Setup: Seed ledger row with absent request_log.
- Oracle: quarantined=1 with reason.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-THRESHOLD-BELOW fixture detail

- Claim: Below threshold roll forward.
- Setup: Seed 499999 unsettled provider credits.
- Oracle: No payout-ready row; source rows remain unsettled.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-THRESHOLD-AT fixture detail

- Claim: At threshold payout ready.
- Setup: Seed 500000 unsettled provider credits.
- Oracle: One payout-ready row; source rows settled=1.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-SETTLEMENT-IDEMPOTENT fixture detail

- Claim: Settlement rerun safe.
- Setup: Run same settlement window twice.
- Oracle: Exactly one payout-ready row.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-SPLIT fixture detail

- Claim: Split immutable.
- Setup: Create one row at 9000 bps; change config to 9500; create second row.
- Oracle: Old row stays 9000; new row uses 9500.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-RATE-CARD-DEFAULT fixture detail

- Claim: Unknown model fallback.
- Setup: Create row for unknown model.
- Oracle: Default rates are snapshotted.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-RATE-CARD-HOT-RELOAD fixture detail

- Claim: New rates only.
- Setup: Create row, reload config, create second row.
- Oracle: Only second row uses new rates.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-INTEGER-ARITHMETIC fixture detail

- Claim: No float storage.
- Setup: Inspect SQLite schema.
- Oracle: No credit/split/payout amount column uses REAL or FLOAT.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ROUND-HALF-EVEN fixture detail

- Claim: Rounding exactness.
- Setup: Run half, below-half, above-half fixtures.
- Oracle: Half rounds to even.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ENDPOINTS-SHAPE fixture detail

- Claim: Endpoint JSON shape.
- Setup: Invoke handlers with fixture stores.
- Oracle: All four endpoints return documented JSON fields.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ENDPOINTS-AUTH fixture detail

- Claim: Endpoint auth.
- Setup: Invoke without credentials.
- Oracle: Admin 403; provider 401; no data leak.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-PROVIDER-SCOPE fixture detail

- Claim: Provider isolation.
- Setup: Token for provider A requests provider B path.
- Oracle: 403; no B earnings leak.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-NO-WIRE-CHANGE fixture detail

- Claim: No SPEC-001 wire change.
- Setup: Grep SPEC-005 for Phase 3 new-field requirements.
- Oracle: No such requirement.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-NO-GATEWAY-CHANGE fixture detail

- Claim: No gateway billing state.
- Setup: Grep SPEC-005 for gateway ledger write/read requirements.
- Oracle: No such requirement.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-NO-ONCHAIN fixture detail

- Claim: No AntFeed/on-chain.
- Setup: Grep SPEC-005 for AntFeed call, on-chain state, USDC-specific column type.
- Oracle: No such requirement.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-REQUEST-LOG-READONLY fixture detail

- Claim: request_log read only.
- Setup: Grep migrations for ALTER TABLE request_log.
- Oracle: No ALTER appears.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-CONFIG-DEFAULTS fixture detail

- Claim: Config defaults.
- Setup: Load empty SPEC-005 config fixture.
- Oracle: Defaults match § 13.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-METRICS fixture detail

- Claim: Metrics through endpoints.
- Setup: Compare § 14 metrics to endpoint fixture output.
- Oracle: Every metric is available through § 11 endpoints.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-DOCS-HONESTY fixture detail

- Claim: Provider docs honest.
- Setup: Render provider docs snippet.
- Oracle: Snippet says v1 accrues credits and payout requires SPEC-007/operator decision.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

## Appendix F. Non-normative implementation estimate

- Day 1: additive SQLite migrations and schema tests.
- Day 2: hot-path credit calculation and same-transaction writes.
- Day 3: rate-card config parsing and immutable row snapshots.
- Day 4: weekly settlement goroutine and idempotency tests.
- Day 5: operator/provider JSON endpoints and auth tests.
- Day 6: startup/nightly recovery scanner and quarantine tests.
- Day 7: H-005 full fixture matrix and AC_STATUS-equivalent implementation report.

## Appendix G. Out-of-scope guard verification strings

- Guard: AntFeed USDC payment rail.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: On-chain settlement of any kind.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Stripe, checkout, credit cards, fiat invoices, refunds, or buyer revenue.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Billing logic in the Phase 5 gateway.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: SPEC-001 wire-format changes.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Per-provider negotiated splits.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Reputation-weighted reward formulas.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Dynamic market-rate pegging.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Tier 2 attested-provider reward multipliers.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: KYC, 1099, tax, or regulatory paperwork.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Refund or clawback workflows.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Multi-currency ledger entries written by SPEC-005.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Web charts and dashboards.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Slack, email, webhook, or digest notification surfaces.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Multi-coordinator or multi-region ledger replication.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
- Guard: Buyer-visible donation buttons, tip jars, or payment-adjacent SPEC-006 UI.
  - Verification: grep implementation prompts and specs for new normative work in this area.
  - Expected: any such work is rejected or moved to SPEC-007/SPEC-008/later.
