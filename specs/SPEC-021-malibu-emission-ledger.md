# SPEC-021 — MALIBU bootstrap rewards emission ledger

**Version:** 0.1.1 (2026-08-17, reward eligibility reason read model)
**Status:** DRAFT — implementation target for Session C (`ops/runbooks/malibu-bootstrap-emission.md`)  
**Depends on:** SPEC-026 v0.13 §5.1–§5.2, §5.5, §10 step 8; SPEC-017 v0.1.8 (`provider_rewards_ledger`); SPEC-016 v0.1.19 (`provider_payout_addresses` projection); SPEC-022 (verified-receipt-only USDC earnings)

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

USDC payout semantics remain in SPEC-016; this spec owns MALIBU accrual only.

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

Constraint: at least one of `amount_usd`, `amount_malibu` MUST be non-NULL.

**Hold reason vocabulary (closed set):**

| Value | Meaning |
|-------|---------|
| `trust_tier_provisional` | Provider is Provisional; accrues but cannot withdraw MALIBU |
| `per_wallet_daily_cap` | Wallet aggregate cap reached; accrual continues for visibility but is held |
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

### 2.5 `rewards_writer` Postgres role

Dedicated runtime role for emission writes:

- `INSERT` on `provider_rewards_ledger`, `wallet_daily_malibu_emission`, `provider_emission_state`
- `UPDATE` on `wallet_daily_malibu_emission`, `provider_emission_state`
- `SELECT` on projection + ledger + state tables
- **No** `DELETE`, `TRUNCATE`, or DDL
- Emission transactions run at **`SERIALIZABLE`** isolation with **retry-on-40001** (max 5 attempts, exponential backoff 10–160ms)

`stats_rollup` retains `SELECT` on `provider_rewards_ledger` only; it MUST NOT write MALIBU rows.

---

## 3. Emission rules (provisional tier)

| Rule | Default (config-backed) |
|------|-------------------------|
| Per-provider daily accrual cap | **25 MALIBU / provider_id / UTC day** |
| Per-wallet daily aggregate cap | **100 MALIBU / bound wallet / UTC day** |
| Withdrawable | **No** until `trust_tier = trusted` |
| Hold reason (provisional accrual) | `trust_tier_provisional` |
| Hold reason (wallet cap exceeded) | `per_wallet_daily_cap` (accrue but non-withdrawable) |

Trusted providers accrue with `withdrawal_hold_reason IS NULL` unless wallet cap applies (`per_wallet_daily_cap`).

**Retroactive unlock rule:** Tier transition to Trusted clears holds on **new** accrual rows only. Existing ledger rows retain their original `withdrawal_hold_reason`; operators MAY run a one-shot reconciliation job to clear holds on pre-unlock rows (out of v0.1 scope).

---

## 4. Workers

### 4.1 Emission tick (periodic)

- Default interval: **15 minutes** (`malibu_emission.tick_interval`)
- Gated by `malibu_emission.enabled` (default `false`)
- Per tick, per eligible `provider_id`:
  1. Resolve `bound_wallet` from `provider_payout_addresses_proj` (NULL if unbound — per-provider cap still applies; wallet cap skipped)
  2. Compute tick accrual: `provider_daily_cap / ticks_per_day`
  3. Under SERIALIZABLE txn + wallet/provider day counters:
     - If `provider_day_malibu + tick > provider_daily_cap`, accrue remainder only
     - If bound wallet set and `wallet sum + accrual > wallet_daily_cap`, accrue remainder with `per_wallet_daily_cap` hold on overflow portion
     - Insert `provider_rewards_ledger` row
     - Upsert aggregates

Eligibility: provider MUST exist in `provider_emission_state` (seeded at App-track register and lazily on first tick for legacy CLI providers).

Optional gate (hook only, v0.1): when `opoi_liveness_ok = false` for a canary cohort, skip accrual for that provider (Session A integration point).

### 4.2 Wallet-bind mirror

Periodic poll of SQLite `provider_payout_addresses` (same DB as `ledger_payout_ready` per SPEC-016 §3.1) into `provider_payout_addresses_proj`.

On first bind for a `provider_id`:

1. Set `provider_emission_state.bound_wallet`
2. Set `cap_replay_pending = TRUE`

### 4.3 Cap replay at wallet bind

When `cap_replay_pending = TRUE`, under the same SERIALIZABLE lock as live emissions:

1. Select held accrual rows for all `provider_id`s sharing the wallet, oldest `unix_ts` first
2. Re-evaluate against wallet cap; clear `per_wallet_daily_cap` hold where cap now permits withdrawal (Trusted tier only)
3. Clear `cap_replay_pending`

### 4.4 Trusted unlock evaluator (Phase C2)

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

### 4.5 Withdrawal runner filter

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

### 5.1 `malibu_reward_eligibility.v1`

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
MALIBU hold reasons.

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
| `compute_integrity_pending` | SPEC-036 proof/trust input | Compute-integrity state is pending and cannot authorize stronger earning claims. |
| `compute_integrity_blocked` | SPEC-036 proof/trust input | Compute-integrity owner reports `quarantined_compute_drift` or `blocked:<reason>`. |
| `provider_token_untrusted` | provider-token auth | Provider-token authentication failed or is not trusted for this read model. Successful `/v1/provider/malibu-accrual` responses normally omit this because auth failures return 401. |
| `local_on_battery` | runtime-health observation reported to reward owner | Runtime health reports battery power blocking earning opportunity. |
| `local_thermal_pressure` | runtime-health observation reported to reward owner | Runtime health reports thermal pressure blocking earning opportunity. |
| `model_not_ready` | runtime-health observation reported to reward owner | Runtime health reports the model is not loaded/ready for earning work. |
| `telemetry_unavailable` | runtime-health observation | The runtime-health source is missing or stale. This MUST NOT override ledger-held or withdrawable facts for `withdrawal_state`. |

Precedence:

1. `compute_integrity_blocked` outranks `compute_integrity_pending`.
2. `held_wallet_daily_cap` outranks `held_provisional_trust_tier` when both are
   present, so clients can render cap-specific copy.
3. Ledger-held and ledger-withdrawable facts outrank `telemetry_unavailable` for
   `withdrawal_state`.
4. Runtime-health reasons, when reported into v1 by the reward owner, affect
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
  tick_interval: 15m
  provider_daily_cap_malibu: 25
  wallet_daily_cap_malibu: 100
  sqlite_payout_db_path: ""         # defaults to storage.db_path; SPEC-016 payout table source
  wallet_mirror_interval: 5m
  unlock_eval_interval: 1h
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

## 8. Acceptance criteria (Phase C1)

- [ ] Provisional provider accrues MALIBU with `withdrawal_hold_reason = trust_tier_provisional`
- [ ] Second `provider_id` on same wallet cannot exceed 100 MALIBU/day wallet aggregate
- [ ] Withdrawal helper returns zero rows for held accrual
- [ ] `rewards_writer` cannot SELECT from `partner_keys` or write `stats_*` rollup tables
- [ ] Migration is idempotent; existing `amount_usd` leaderboard rollup continues to work

---

## 9. Open questions

1. Cohort telemetry may adjust 100 MALIBU/day wallet cap (SPEC-026 §13).
2. Event-driven accrual (per verified receipt) vs periodic tick — v0.1 uses tick; receipt-gated accrual is v0.2 candidate.
3. On-chain MALIBU withdrawal rail — out of scope; this spec is ledger-only.

---

*End of SPEC-MALIBU-EMISSION-LEDGER v0.1.1.*
