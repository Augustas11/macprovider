# SPEC-021 — MALIBU rewards emission ledger

**Version:** 0.3.0 (2026-08-17, reward audit trail)
**Status:** DRAFT — implementation target for Session C (`ops/runbooks/malibu-bootstrap-emission.md`)  
**Depends on:** SPEC-026 v0.13 §5.1–§5.2, §5.5, §10 step 8; SPEC-017 v0.1.8 (`provider_rewards_ledger`); SPEC-016 v0.1.19 (`provider_payout_addresses` projection); SPEC-022 (verified-receipt-only USDC earnings)

**Change log v0.3.0 (2026-08-17, reward audit trail):**
- Adds append-only `malibu_reward_audit_events` rows for MALIBU accrual,
  hold application/clearance, wallet projection, trust-tier transitions, and
  reserved withdrawal/eligibility events.
- Defines provider-token-authenticated `GET /v1/provider/malibu-reward-audit`
  with stable event IDs, bounded cursor pagination, provider isolation, and a
  provider-safe field allowlist.
- Defines operator-authenticated `GET /admin/malibu-reward-audit` for
  correlation to ledger IDs, source reasons, trust transitions, and external
  idempotency references without exposing those fields in provider responses.
- Pins retention and sensitive-field exclusions: raw prompts, raw outputs,
  bearer tokens, request payloads, operator secrets, and arbitrary metadata
  MUST NOT be serialized into provider-visible audit events.

**Change log v0.2.0 (2026-08-17, verified useful-work accrual):**
- Adds `malibu_verified_useful_work_v0_2` ledger rows derived only from
  mirrored SPEC-022 enforce-mode request credits with verified settlement
  evidence.
- Defines the v0.2 accrual formula as normalized provider credits converted to
  MALIBU by `useful_work_malibu_per_1000_provider_credits`; provider credits
  are the billing-owned model/rate-card/token weighted unit, so MALIBU does not
  re-price models independently.
- Pins idempotency to `external_ref = spec022:<request_id>:<attempt_n>:<provider_id>`
  with a unique MALIBU external-ref index. Duplicate settlement replay MUST NOT
  mint another row or advance daily cap aggregates.
- Keeps v0.1 `malibu_bootstrap_tick` rows readable as historical/bootstrap
  accrual. No row is silently reclassified; any future backfill MUST use an
  explicit migration rule.

**Change log v0.1.1 (2026-08-17, reward eligibility reason read model):**
- Defines `malibu_reward_eligibility.v1`, the provider-token-authenticated read
  model for MALIBU earning opportunity, held/withdrawable state, and stable
  client reason codes.
- Separates reward-ledger facts, runtime-health observations, proof/trust
  observations, and unavailable-source reasons so clients do not re-derive policy
  from raw fields.
- Keeps USDC payout readiness separate from MALIBU reward eligibility while
  allowing clients to render both projections together.

**Note on numbering:** This is canonical **SPEC-021** (assigned 2026-07-10 in a corpus-hygiene pass; promoted from `docs/notes/SPEC-MALIBU-EMISSION-LEDGER.md` into `specs/`). Earlier SPEC-026 prose called the emission ledger "SPEC-028"; that was a mislabel — `SPEC-028-mlx-speculative-decoding.md` is unrelated MLX work — and those references now point to SPEC-021. The human-readable name `SPEC-MALIBU-EMISSION-LEDGER` remains a valid alias used by code comments, migrations (`012_malibu_emission_ledger.up.sql`), and runbooks.

---

## 1. Purpose

Accrue **$MALIBU** for early Malibu providers to bootstrap network growth, with **enforceable** sybil defenses:

- Provisional tier accrual is **non-withdrawable** until Trusted.
- Per-wallet daily cap applies across all `provider_id`s sharing a bound payout address.
- Withdrawal runners MUST filter on `withdrawal_hold_reason IS NULL`.

USDC payout semantics remain in SPEC-016/SPEC-022; this spec owns MALIBU
accrual only. v0.2 useful-work rewards consume settlement evidence as an input
but do not alter buyer debit, USDC payout readiness, or the billing ledger.

---

## 2. Schema (Postgres stats / rewards DB)

All objects live on the same Postgres database as SPEC-017 stats tables (`provider_rewards_ledger`).

### 2.1 `provider_rewards_ledger` extension

Migration extends the existing table:

| Column | Type | Semantics |
|--------|------|-----------|
| `amount_usd` | `NUMERIC(18,2) NULL` | Legacy operator USD rewards; nullable after migration |
| `amount_malibu` | `NUMERIC(24,8) NULL` | MALIBU accrual for this row; NULL for USD-only rows |
| `withdrawal_hold_reason` | `TEXT NULL` | When non-NULL, row is accrual-visible but **not** withdrawable |
| `reason` | `TEXT NULL` | Reward source, including `malibu_bootstrap_tick` and `malibu_verified_useful_work_v0_2` |
| `external_ref` | `TEXT NULL` | Idempotency reference for external sources. v0.2 useful-work rows use `spec022:<request_id>:<attempt_n>:<provider_id>` |

Constraint: at least one of `amount_usd`, `amount_malibu` MUST be non-NULL.
MALIBU rows with non-NULL `external_ref` are unique by `external_ref`.

**Hold reason vocabulary (closed set):**

| Value | Meaning |
|-------|---------|
| `trust_tier_provisional` | Provider is Provisional; accrues but cannot withdraw MALIBU |
| `per_wallet_daily_cap` | Wallet aggregate cap reached on a partial boundary accrual; the accepted remainder is visible but not withdrawable |
| `demotion_cooldown` | Provider demoted from Trusted; 72h requalification window (SPEC-026 §5.5) |

Withdrawal selection: `WHERE withdrawal_hold_reason IS NULL AND amount_malibu IS NOT NULL AND amount_malibu > 0`.

### 2.2 `wallet_daily_malibu_emission`

Aggregate cap enforcement table:

```sql
CREATE TABLE wallet_daily_malibu_emission (
    bound_wallet  TEXT NOT NULL,          -- EIP-55 lowercase hex, 0x-prefixed
    emission_day  DATE NOT NULL,          -- UTC calendar day
    sum_malibu    NUMERIC(24,8) NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (bound_wallet, emission_day)
);
```

Cap value is **config-backed** (default **100 MALIBU / bound wallet / UTC day**).

### 2.3 `provider_emission_state`

Per-provider cross-track state:

```sql
CREATE TABLE provider_emission_state (
    provider_id           TEXT PRIMARY KEY,
    trust_tier            TEXT NOT NULL DEFAULT 'provisional'
                          CHECK (trust_tier IN ('provisional', 'trusted')),
    bound_wallet          TEXT NULL,      -- canonical payout address projection
    cap_replay_pending    BOOLEAN NOT NULL DEFAULT FALSE,
    provider_day_malibu   NUMERIC(24,8) NOT NULL DEFAULT 0,  -- today's accrual for per-provider cap
    emission_day          DATE NULL,      -- UTC day provider_day_malibu applies to
    demotion_cooldown_until TIMESTAMPTZ NULL,
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`cap_replay_pending` is set TRUE on first wallet bind; cleared after oldest-first replay through the wallet cap under the aggregate lock (§4.3).

### 2.4 `provider_payout_addresses_proj`

Postgres projection of SPEC-016 SQLite `provider_payout_addresses`:

```sql
CREATE TABLE provider_payout_addresses_proj (
    provider_id      TEXT NOT NULL,
    chain            TEXT NOT NULL CHECK (chain = 'base-mainnet'),
    address          TEXT NOT NULL,       -- EIP-55 normalized lowercase
    payout_allowed   INTEGER NOT NULL DEFAULT 1,
    registered_at_utc TIMESTAMPTZ NOT NULL,
    source_updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (provider_id, chain)
);
```

Maintained by the wallet-mirror worker (§4.2). Staleness is monitored via mirror heartbeat, not row age alone.

### 2.5 `malibu_reward_audit_events`

Append-only audit trail for MALIBU reward state:

| Column | Type | Semantics |
|--------|------|-----------|
| `id` | `BIGSERIAL PRIMARY KEY` | Stable event identity. Provider/operator APIs render this as `mra_<id>`. |
| `provider_id` | `TEXT NOT NULL` | Provider subject. Provider reads MUST derive this from bearer auth, never from query/body input. |
| `occurred_at` | `TIMESTAMPTZ NOT NULL` | Event creation/transition time in UTC. |
| `event_type` | `TEXT NOT NULL` | Closed vocabulary below. |
| `ledger_id` | `BIGINT NULL` | Optional `provider_rewards_ledger.id` correlation for money-path rows. |
| `amount_malibu` | `NUMERIC(24,8) NULL` | Reward amount when event concerns a ledger amount. |
| `withdrawal_hold_reason` | `TEXT NULL` | Closed hold reason when event applies/clears a hold. |
| `trust_tier` | `TEXT NULL` | Trust tier when event concerns trust state. |
| `source_reason` | `TEXT NULL` | Ledger source reason such as `malibu_bootstrap_tick` or `malibu_verified_useful_work_v0_2`. |
| `safe_summary` | `TEXT NOT NULL` | Provider-safe sentence; no secrets or raw prompt/output data. |
| `operator_correlation` | `JSONB NOT NULL` | Operator-only correlation keys, e.g. ledger ID, source reason, and idempotency external-ref. |

Closed `event_type` vocabulary:

| Value | Meaning |
|-------|---------|
| `malibu_accrual_inserted` | A MALIBU ledger row was inserted. |
| `malibu_hold_applied` | A withdrawal hold was applied to a reward row. |
| `malibu_hold_cleared` | A withdrawal hold was cleared, e.g. cap replay. |
| `wallet_daily_cap_applied` | A wallet daily cap hold was applied. |
| `wallet_bind_projected` | A payout wallet projection changed and cap replay is pending. |
| `trust_tier_promoted` | Provider trust tier transitioned to `trusted`. |
| `trust_tier_demoted` | Provider trust tier transitioned to `provisional`. |
| `withdrawal_candidate_selected` | Reserved for the withdrawal runner selecting a candidate row. |
| `withdrawal_candidate_skipped` | Reserved for the withdrawal runner skipping a candidate row. |
| `eligibility_reason_changed` | Reserved for future reward-eligibility reason transitions. |

Provider-visible audit responses MUST NOT include `operator_correlation`,
`external_ref`, raw request payloads, raw prompts, raw outputs, bearer tokens,
operator secrets, full arbitrary metadata maps, or internal notes. Operator
responses MAY include `operator_correlation`, but the column itself remains an
allowlisted JSON object owned by this spec; it MUST NOT become a dump of
unreviewed request/provider metadata.

Retention: audit rows are append-only and retained for at least **180 days**.
Any compaction/archive after that window MUST preserve `id`, `provider_id`,
`occurred_at`, `event_type`, `ledger_id`, `withdrawal_hold_reason`, and
`safe_summary` for dispute/support correlation.

### 2.6 `rewards_writer` Postgres role

Dedicated runtime role for emission writes:

- `INSERT` on `provider_rewards_ledger`, `wallet_daily_malibu_emission`, `provider_emission_state`
- `UPDATE` on `wallet_daily_malibu_emission`, `provider_emission_state`
- `SELECT` on projection + ledger + state + audit tables
- `INSERT` on `malibu_reward_audit_events`
- **No** `DELETE`, `TRUNCATE`, or DDL
- Emission transactions run at **`SERIALIZABLE`** isolation with **retry-on-40001** (max 5 attempts, exponential backoff 10–160ms)

`stats_rollup` retains `SELECT` on `provider_rewards_ledger` only; it MUST NOT write MALIBU rows.

---

## 3. Emission rules (provisional tier)

| Rule | Default (config-backed) |
|------|-------------------------|
| Per-provider daily accrual cap | **25 MALIBU / provider_id / UTC day** |
| Per-wallet daily aggregate cap | **100 MALIBU / bound wallet / UTC day** |
| v0.2 useful-work rate | **1 MALIBU / 1000 verified provider credits** |
| Withdrawable | **No** until `trust_tier = trusted` |
| Hold reason (provisional accrual) | `trust_tier_provisional` |
| Hold reason (wallet cap boundary reached) | `per_wallet_daily_cap` (accepted remainder is accrual-visible but non-withdrawable) |

Trusted providers accrue with `withdrawal_hold_reason IS NULL` unless wallet cap applies (`per_wallet_daily_cap`).
Provider and wallet daily caps are shared across v0.1 bootstrap tick rows and
v0.2 useful-work rows.

**Retroactive unlock rule:** Tier transition to Trusted clears holds on **new** accrual rows only. Existing ledger rows retain their original `withdrawal_hold_reason`; operators MAY run a one-shot reconciliation job to clear holds on pre-unlock rows (out of v0.1 scope).

---

## 4. Workers

### 4.1 Bootstrap emission tick (periodic)

- Default interval: **15 minutes** (`malibu_emission.tick_interval_seconds`)
- Gated by `malibu_emission.enabled` (default `false`)
- Per tick, per eligible `provider_id`:
  1. Resolve `bound_wallet` from `provider_payout_addresses_proj` (NULL if unbound — per-provider cap still applies; wallet cap skipped)
  2. Compute tick accrual: `provider_daily_cap / ticks_per_day`
  3. Under SERIALIZABLE txn + wallet/provider day counters:
     - If `provider_day_malibu + tick > provider_daily_cap`, accrue remainder only
     - If bound wallet set and `wallet sum + accrual > wallet_daily_cap`, accrue only the remainder that fits under `wallet_daily_cap`, mark that accepted boundary amount with `per_wallet_daily_cap`, and skip any fully over-cap amount so the wallet aggregate never advances beyond the cap
     - Insert `provider_rewards_ledger` row
     - Upsert aggregates

Eligibility: provider MUST exist in `provider_emission_state` (seeded at App-track register and lazily on first tick for legacy CLI providers).

Bootstrap tick rows use `reason = malibu_bootstrap_tick`. They remain enabled
only by `malibu_emission.enabled`; v0.2 does not reclassify them.

### 4.2 Verified useful-work accrual (v0.2)

- Default interval: **15 minutes** (`malibu_emission.useful_work_interval_seconds`)
- Gated by both `malibu_emission.enabled` and
  `malibu_emission.useful_work_enabled` (default `false`)
- Source table: Postgres-mirrored `ledger_request_credits`
- Eligibility gate:
  - `spec022_verified = TRUE`
  - `provider_credits > 0`
  - no existing MALIBU ledger row for
    `external_ref = spec022:<request_id>:<attempt_n>:<provider_id>`
- If the provider or wallet daily cap is already exhausted before a useful-work
  row can accept any MALIBU, the coordinator writes a terminal ledger marker
  with `amount_malibu = 0` and the useful-work `external_ref`. This marks the
  source row processed without advancing provider or wallet daily aggregates.
  Wallet-cap terminal markers use
  `withdrawal_hold_reason = per_wallet_daily_cap` and a paired
  `wallet_daily_cap_applied` audit event so the provider read model remains
  capped for the UTC day unless a later `malibu_hold_cleared` audit event
  clears the same ledger row.
- Formula:

```text
malibu = provider_credits / 1000 * useful_work_malibu_per_1000_provider_credits
```

`provider_credits` is billing-owned normalized useful-work weight. It already
captures verified request count (one eligible row per verified request),
verified billable tokens, served model/rate-card price, and provider share.
MALIBU MUST NOT independently re-price models from raw model IDs or client copy.
Uptime/liveness and proof multipliers are reserved for a later explicit
multiplier version; v0.2 may use proof state for eligibility/copy but not as a
hidden amount multiplier.

The worker inserts `provider_rewards_ledger` rows with
`reason = malibu_verified_useful_work_v0_2` and the external-ref idempotency key
above. Duplicate settlement replay or mirror overlap MUST be a no-op: no second
row and no daily cap counter advance.

The same provider cap, wallet cap, provisional hold, demotion hold, and trusted
withdrawable rules from §3 apply. Non-verified, missing-receipt, quarantined, or
legacy/observe-only rows are excluded from v0.2 MALIBU useful-work accrual.

### 4.3 Wallet-bind mirror

Periodic poll of SQLite `provider_payout_addresses` (same DB as `ledger_payout_ready` per SPEC-016 §3.1) into `provider_payout_addresses_proj`.

On first bind for a `provider_id`:

1. Set `provider_emission_state.bound_wallet`
2. Set `cap_replay_pending = TRUE`

### 4.4 Cap replay at wallet bind

When `cap_replay_pending = TRUE`, under the same SERIALIZABLE lock as live emissions:

1. Select held accrual rows for all `provider_id`s sharing the wallet, oldest `unix_ts` first
2. Re-evaluate against wallet cap; clear `per_wallet_daily_cap` hold where cap now permits withdrawal (Trusted tier only)
3. Clear `cap_replay_pending`

### 4.5 Trusted unlock evaluator (Phase C2)

Coordinator job evaluates SPEC-026 §5.2 criteria on `unlock_eval_interval`:

- At least **one economic** (E1/E2/E3) **and one distinct additional** criterion
- E1: ≥100 verified receipts from `settlement_receipt_verdicts` (SQLite billing DB)
- E2/A3: wallet bound + ≥100 USDC for 72h when `base_usdc_balance_rpc_urls` + checker configured
- E3: dual-control operator promotion via `/admin/trust-promotion/request` + `.../approve`.
  Two-person control is enforced by **distinct operator credentials**: both endpoints
  authenticate against `auth.operator_keys` (per-actor map) with a constant-time
  compare, and the acting operator identity is bound to the **matched key** — the
  `X-Operator-Actor` header is never trusted. The route **fails closed**
  (`503 dual_control_unavailable`) unless `auth.operator_keys` holds ≥2 entries with
  distinct, non-empty secrets, so one credential cannot both request and approve.
- A1: 72h uptime with heartbeat gap &lt;5m (live pool snapshot)
- A4: `provider_identities.attested = true`
- On unlock: `trust_tier → trusted`; new accruals omit `trust_tier_provisional` hold
- On demotion (§5.5): `trust_tier → provisional`, set `demotion_cooldown_until = now() + 72h`, new rows get `demotion_cooldown` hold until cooldown elapses
- Post-demotion requalification: pairing must co-hold continuously for 72h before reinstatement

### 4.6 Withdrawal runner filter

Any MALIBU withdrawal query (future SPEC-016 extension or dedicated runner) MUST include:

```sql
WHERE withdrawal_hold_reason IS NULL
```

USDC `ledger_payout_ready` runner is unchanged.

---

## 5. Provider read API

`GET /v1/provider/malibu-accrual` (provider-token auth):

```json
{
  "accrued_malibu": "12.50000000",
  "withdrawable_malibu": "0",
  "held_malibu": "12.50000000",
  "trust_tier": "provisional",
  "daily_cap_malibu": "25",
  "provider_daily_capped": false,
  "wallet_daily_cap_malibu": "100",
  "withdrawal_hold_reasons": ["trust_tier_provisional"],
  "reward_eligibility": {
    "schema_version": "malibu_reward_eligibility.v1",
    "earning_state": "held",
    "withdrawal_state": "held",
    "primary_reason": "held_provisional_trust_tier",
    "reasons": [
      "held_provisional_trust_tier",
      "missing_wallet_binding",
      "insufficient_verified_receipts"
    ]
  }
}
```

`withdrawable_malibu` sums ledger rows where `withdrawal_hold_reason IS NULL`.

### 5.1 Reward audit API

`GET /v1/provider/malibu-reward-audit?limit=25&before_id=mra_123`
(provider-token auth) returns recent provider-scoped audit events:

```json
{
  "events": [
    {
      "id": "mra_42",
      "occurred_at": "2026-08-17T12:00:00Z",
      "event_type": "malibu_hold_applied",
      "ledger_id": 917,
      "amount_malibu": "0.26041667",
      "withdrawal_hold_reason": "trust_tier_provisional",
      "trust_tier": "provisional",
      "source_reason": "malibu_bootstrap_tick",
      "summary": "Reward hold applied because the provider is provisional."
    }
  ],
  "next_before_id": "mra_41"
}
```

Rules:

- Provider identity MUST come from the bearer token. A provider request MUST
  NOT accept `provider_id` as a query/body override.
- `limit` defaults to 25 and MUST be bounded to 1..100.
- Pagination is keyset pagination using `before_id`; cursors are stable
  `mra_<id>` event IDs.
- Provider events are ordered newest first.
- Provider responses MUST use the field allowlist above and exclude
  `operator_correlation` and `external_ref`.
- Unknown event types under a known schema version MUST be rendered as
  "reward status updated" copy and logged for client upgrade.

`GET /admin/malibu-reward-audit?provider_id=<id>&limit=25&before_id=mra_123`
(operator bearer auth) returns the same events plus `provider_id` and
`operator_correlation`, allowing support and operators to correlate a provider
visible event with the authoritative ledger row, trust transition, source
reason, and useful-work idempotency key.

### 5.2 `malibu_reward_eligibility.v1`

`reward_eligibility` is the coordinator-owned provider read model for whether
MALIBU is currently earnable, held, capped, withdrawable, ineligible, or
unavailable to classify from facts reported to the reward owner. Clients MUST
prefer this object over independently inferring MALIBU ledger, trust, hardware,
or compute eligibility from `trust_tier`, raw hold reasons, trust counters, or
future compute-integrity fields when the object is present and
`schema_version == "malibu_reward_eligibility.v1"`. Until local runtime-health
observations are reported into this object by the reward owner, clients MAY
display them only as separate operational readiness copy; they MUST NOT mutate
`reward_eligibility`, override its `withdrawal_state`, or add client-inferred
MALIBU hold reasons. A successful `/v1/provider/malibu-accrual` response that
omits `reward_eligibility` is schema drift for v0.1.1 readers: clients MUST
render the MALIBU reward state as unavailable and MUST NOT fall back to raw
`withdrawable_malibu`, `wallet_bound`, `trust_tier`, or hold-reason fields to
authorize withdrawable copy.

Fields:

| Field | Type | Semantics |
|-------|------|-----------|
| `schema_version` | string | Exactly `malibu_reward_eligibility.v1` for this contract. Unknown versions MUST be treated as unavailable rather than guessed. |
| `earning_state` | enum | One of `earning`, `eligible_idle`, `held`, `capped`, `ineligible`, `unavailable`. This is an earning-opportunity/readiness state; it does not assert live paid work unless `earning_verified_work` is present. |
| `withdrawal_state` | enum | One of `withdrawable`, `held`, `capped`, `ineligible`, `unavailable`. This describes MALIBU withdrawal eligibility only, not USDC payout readiness. |
| `primary_reason` | enum | The single highest-priority reason clients should render first. |
| `reasons` | array | Closed ordered set of reason codes. Unknown codes under a known schema version MUST be rendered as generic unavailable/review-needed copy and logged for client upgrade. |

Reason vocabulary:

| Reason | Owner | Meaning |
|--------|-------|---------|
| `earning_verified_work` | coordinator reward/read model | Recent verified work was observed by the reward owner and can be presented as active earning. |
| `eligible_idle_no_work` | coordinator reward/read model | No blocking reward reason is known, but no current earning work is observed. |
| `held_provisional_trust_tier` | MALIBU ledger/trust | Accrual is visible but held because the provider is not Trusted. Maps from `withdrawal_hold_reason = trust_tier_provisional`. |
| `held_provider_daily_cap` | provider emission state | The provider has reached its UTC-day MALIBU cap. Maps from `provider_emission_state.provider_day_malibu >= daily_cap_malibu` for the current UTC day. |
| `held_wallet_daily_cap` | MALIBU ledger | Accrual is held or capped by the bound-wallet daily MALIBU cap. Maps from `withdrawal_hold_reason = per_wallet_daily_cap`. |
| `held_demotion_cooldown` | MALIBU ledger/trust | Accrual is held during post-demotion requalification. Maps from `withdrawal_hold_reason = demotion_cooldown`. |
| `withdrawable_balance_available` | MALIBU ledger | At least one MALIBU ledger row is withdrawable. |
| `withdrawable_no_balance` | MALIBU ledger | No MALIBU is currently withdrawable and no held MALIBU exists. |
| `missing_wallet_binding` | payout-address projection | The provider does not have a payout wallet binding in the MALIBU projection. This may affect trust/unlock or cap replay; it is not a USDC payout-ready assertion. |
| `insufficient_verified_receipts` | SPEC-022/SPEC-026 trust input | Verified receipt count is below the trust criterion threshold used by the unlock evaluator. |
| `app_attestation_missing` | SPEC-026 trust input | App attestation is not currently satisfied for the trust-read snapshot. |
| `hardware_evidence_unavailable` | SPEC-032/SPEC-033 proof/trust input | Hardware-evidence classification source is not wired or cannot answer. |
| `hardware_evidence_missing_or_expired` | SPEC-032/SPEC-033 proof/trust input | The hardware-evidence owner reports no verified in-window evidence. This MUST NOT be rendered as a claim that hardware is false or weak. |
| `compute_integrity_unavailable` | SPEC-036 proof/trust input | Compute-integrity classification source is not wired, unknown, or expired. |
| `compute_integrity_pending` | SPEC-036 proof/trust input | Compute-integrity state is pending or warn-only for this read model and cannot authorize stronger earning claims. |
| `compute_integrity_blocked` | SPEC-036 proof/trust input | Compute-integrity owner reports `quarantined_compute_drift` or `blocked:<reason>`. |
| `provider_token_untrusted` | provider-token auth | Provider-token authentication failed or is not trusted for this read model. Successful `/v1/provider/malibu-accrual` responses normally omit this because auth failures return 401. |
| `local_on_battery` | runtime-health observation reported to reward owner | Runtime health reports battery power blocking earning opportunity. |
| `local_thermal_pressure` | runtime-health observation reported to reward owner | Runtime health reports thermal pressure blocking earning opportunity. |
| `model_not_ready` | runtime-health observation reported to reward owner | Runtime health reports the model is not loaded/ready for earning work. |
| `telemetry_unavailable` | runtime-health observation | The runtime-health source is missing or stale. This MUST NOT override ledger-held or withdrawable facts for `withdrawal_state`. |

Precedence:

1. `compute_integrity_blocked` outranks `compute_integrity_pending`; only a
   recognized positive compute state may omit both reasons.
2. `held_wallet_daily_cap` and `held_provider_daily_cap` outrank
   `held_provisional_trust_tier` when both are present, so clients can render
   cap-specific copy. `held_wallet_daily_cap` MAY be derived from same-UTC-day
   un-cleared `wallet_daily_cap_applied` audit events when a provisional ledger
   row can store only `trust_tier_provisional` as its primary hold.
3. `missing_wallet_binding` blocks MALIBU withdrawal readiness and outranks raw
   withdrawable ledger balance and generic proof-source unavailable reasons for
   `primary_reason`.
4. Ledger-held and ledger-withdrawable facts outrank `telemetry_unavailable` for
   `withdrawal_state`.
5. Runtime-health reasons, when reported into v1 by the reward owner, affect
   earning opportunity only. They MUST NOT make already-accrued MALIBU
   withdrawable or non-withdrawable by themselves.

USDC payout readiness remains owned by SPEC-016/SPEC-022 projections. A client MAY
display USDC and MALIBU readiness in the same UI, but MUST NOT collapse
`wallet_bound`, USDC payout readiness, and MALIBU `withdrawal_state` into one
boolean.

---

## 6. Config (`coordinator.yaml`)

```yaml
malibu_emission:
  enabled: false
  writer_dsn: ""                    # rewards_writer role; env override MALIBU_EMISSION_WRITER_DSN
  tick_interval_seconds: 900
  useful_work_enabled: false
  useful_work_interval_seconds: 900
  provider_daily_cap_malibu: 25
  wallet_daily_cap_malibu: 100
  useful_work_malibu_per_1000_provider_credits: 1
  sqlite_payout_db_path: ""         # defaults to storage.db_path; SPEC-016 payout table source
  wallet_mirror_interval_seconds: 300
  unlock_eval_interval_seconds: 3600
  max_serializable_retries: 5
```

Rollback: set `malibu_emission.enabled: false`; accrual rows freeze, tier transitions stop.

---

## 7. Malibu app integration (Phase C3 — contract only)

| Surface | Field / copy |
|---------|----------------|
| Control socket | `metricsResponse.malibuAccrued` |
| Success card | "Provisional — earn up to 25 MALIBU/day (non-withdrawable until Trusted)" |
| Lock icon | All MALIBU displays when `trust_tier != trusted` |

Coordinator → CLI metrics wiring is C3; this spec defines the read API in §5.

---

## 8. Normative requirements

| Requirement | Status | Text |
|-------------|--------|------|
| `SPEC-021-R001` | Draft | MALIBU reward mutations MUST persist append-only audit events for accrual insertion, hold application/clearance, wallet projection, and trust-tier promotion/demotion. |
| `SPEC-021-R002` | Draft | Provider reward-audit reads MUST authenticate with provider bearer tokens, derive provider identity from the token, enforce provider isolation, and use bounded stable cursor pagination. |
| `SPEC-021-R003` | Draft | Provider-visible reward-audit events MUST use a fixed safe field allowlist and MUST NOT expose operator correlation, external refs, raw prompts, raw outputs, bearer tokens, operator secrets, arbitrary metadata, or internal notes. |
| `SPEC-021-R004` | Draft | Operator reward-audit reads MUST require operator auth and return enough correlation to map provider-visible events to ledger IDs, source reasons, trust transitions, and idempotency references. |

---

## 9. Acceptance criteria

- [ ] Provisional provider accrues MALIBU with `withdrawal_hold_reason = trust_tier_provisional`
- [ ] Second `provider_id` on same wallet cannot exceed 100 MALIBU/day wallet aggregate
- [ ] Withdrawal helper returns zero rows for held accrual
- [ ] Verified useful-work rows accrue only when `spec022_verified = TRUE`
- [ ] Non-verified, missing-receipt, quarantined, or legacy/observe-only rows do not accrue v0.2 useful-work MALIBU
- [ ] Duplicate settlement/mirror replay with the same `spec022:<request_id>:<attempt_n>:<provider_id>` external ref does not mint a second row or advance cap counters
- [ ] Existing v0.1 `malibu_bootstrap_tick` balances remain readable and are not reclassified
- [ ] Provider reward audit API returns recent events with stable IDs, bounded pagination, and no cross-provider leakage
- [ ] Provider reward audit API excludes operator correlation, external refs, raw prompts/outputs, bearer tokens, and arbitrary metadata
- [ ] Operator reward audit query returns provider/ledger/trust correlation for support and dispute investigation
- [ ] Cap replay and trust demotion/promotion produce corresponding audit events
- [ ] `rewards_writer` cannot SELECT from `partner_keys` or write `stats_*` rollup tables
- [ ] Migration is idempotent; existing `amount_usd` leaderboard rollup continues to work

---

## 10. Open questions

1. Cohort telemetry may adjust 100 MALIBU/day wallet cap (SPEC-026 §13).
2. Whether bootstrap tick remains permanently as an early-network floor or is disabled after demand reaches a stable threshold remains an operator policy choice.
3. On-chain MALIBU withdrawal rail — out of scope; this spec is ledger-only.

---

*End of SPEC-MALIBU-EMISSION-LEDGER v0.3.0.*
