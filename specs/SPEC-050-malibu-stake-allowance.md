# SPEC-050 - MALIBU Stake Allowance

**Version:** 0.1.0
Status: draft
Owner: @Augustas11
Issue: https://github.com/Augustas11/macprovider/issues/1062

```json
{
  "spec_id": "SPEC-050",
  "title": "MALIBU Stake Allowance",
  "version": "0.1.0",
  "path": "specs/SPEC-050-malibu-stake-allowance.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["malibu-stake-allowance"],
  "supersedes": [],
  "depends_on": ["SPEC-005", "SPEC-006", "SPEC-016", "SPEC-021", "SPEC-022", "SPEC-034", "SPEC-041", "SPEC-049"],
  "implementation_status": "pending-reconciliation",
  "production_status": "not-deployed",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "DECISION_REQUIRED",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/1062",
    "rationale": "SPEC-050 v0.1.0 defines the MALIBU stake allowance: a ledger-MALIBU stake, a budgeted daily non-withdrawable inference allowance, allowance-first spend ordering, and the self-dealing reward exclusion. It ships on; the operator's daily budget sets its size. Every requirement stays pending until one account stakes, receives an allowance, and spends it through the gateway live."
  }
}
```

## 1. Purpose and scope

Providers accrue MALIBU in the SPEC-021 rewards ledger. SPEC-050 gives that
MALIBU a use on the network: an account locks (stakes) MALIBU and receives a
daily inference allowance, sized by the stake and bounded by an operator
network budget. Allowance requests settle to providers exactly like any other
request, so provider pay does not change.

In scope for v0.1:

- staking ledger MALIBU held by providers the account owns;
- an append-only stake ledger with lock, unlock, and an unlock cooldown;
- a daily allowance refresh, idempotent per account and UTC day, scaled to the
  network budget;
- allowance-first spend ordering at gateway admission, a per-account overage
  setting, and a per-request allowance/paid split;
- excluding self-dealt allowance traffic from MALIBU rewards;
- the account API and the account page fields.

Out of scope for v0.1:

- an on-chain MALIBU token or staking contract. The stake source is an
  interface (SPEC-050-R001), so a chain source can be added later without
  changing the allowance or billing contract;
- wallet-session (SPEC-040) and demo traffic. Both keep the paid quota path;
- any yield, interest, or return on staked MALIBU. Staking buys inference
  allowance only.

## 2. Dependencies and authority

SPEC-050 owns the authority domain `malibu-stake-allowance`: the stake ledger,
the stake source interface, effective stake, the daily allowance, the
allowance balance, spend ordering, the overage setting, the per-request split,
the self-dealing relation, the account surface, and the disclosure text.

Consumed contracts, owned elsewhere:

- **SPEC-021** owns MALIBU accrual and the canonical withdrawability predicate.
  SPEC-050 reads withdrawable MALIBU through that predicate and nets its own
  locks out of it (SPEC-050-R003). SPEC-050 never writes a
  `provider_rewards_ledger` row.
- **SPEC-005** owns credit units (1 credit = 1 micro-USD), the rate card,
  gross credits, provider credits, and D1a wholesale statements. Allowance
  amounts are credits. Allowance spend is measured from SPEC-005 ledger rows.
- **SPEC-006** owns the gateway quota ledger and buyer error envelope. The paid
  balance of an account is its SPEC-006 daily token quota (and, for D1a
  partners, its postpaid statement).
- **SPEC-022** owns USDC earnings. Allowance funding never changes a
  SPEC-022/SPEC-005 settlement row (SPEC-050-R009).
- **SPEC-016** owns provider payout addresses; **SPEC-034** owns referral
  issuance and redemption. SPEC-050 reads both to find self-dealing.
- **SPEC-041/SPEC-049** own relay-blind and privacy-class requests. Those
  requests use the same allowance admission as plaintext requests.

## 3. Terms

| Term | Meaning |
|---|---|
| Account | A gateway account (SPEC-006 §3.4). Staking requires a linked GitHub identity. |
| Owned provider | A provider whose `provider_ownership.github_user_id` equals the account's GitHub user id. |
| Stake source | The interface that answers how much MALIBU an account may lock and how much it has locked (SPEC-050-R001). |
| Lock | An append-only stake event moving MALIBU of one owned provider into the stake. |
| Unlock | An append-only stake event that stops a locked amount earning at once and releases it after the cooldown. |
| Earning stake | Matured locked MALIBU that counts for the allowance on a given UTC day (SPEC-050-R004). |
| Allowance | Credits granted to an account for one UTC day. Non-withdrawable, non-transferable, no rollover. |
| Paid quota | The account's existing SPEC-006 daily token quota or D1a statement. |
| Overage | The account setting that lets a request use the paid quota when the allowance cannot cover it. |
| Credit bound | Gross credits of a request priced at its input token upper bound and maximum output tokens, uncached, at the current rate card. |

## 4. Configuration

Coordinator `coordinator.yaml`, section `stake_allowance`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `daily_budget_credits` | int ≥ 0 | `0` | Network-wide allowance credits per UTC day. `0` grants nothing; the feature stays on. |
| `credits_per_malibu` | int ≥ 0 | `0` | Credits granted per whole earning MALIBU per day. |
| `per_account_daily_cap_credits` | int ≥ 0 | `0` | Upper bound on one account's daily allowance. |
| `min_stake_age_hours` | int 1..720 | `24` | A lock earns only from the first refresh at least this long after it. |
| `unlock_cooldown_hours` | int 24..2160 | `168` | Time between an unlock and the release of its MALIBU. |
| `refresh_check_interval_seconds` | int 10..3600 | `60` | How often the refresh job checks whether today's run is done and closes holds left by an earlier coordinator process. |

When `daily_budget_credits > 0`, `credits_per_malibu` and
`per_account_daily_cap_credits` MUST both be positive or the configuration
fails to load. The shipped `coordinator.yaml.example` carries a conservative
example (5,000,000 credits = USD 5 per day network-wide, 1,000 credits per
MALIBU per day, 250,000 credits per account per day). The operator sets the
production values; they are deployment state like the rate card. Changes apply
at the next coordinator start.

## 5. Normative requirements

### SPEC-050-R001 - Stake source interface and ledger MALIBU source

Allowance computation MUST read stake only through a stake source interface
that returns, for a UTC day, each account's earning stake. The v0.1 source is
ledger MALIBU: an account may lock only MALIBU that SPEC-021's canonical
withdrawability predicate counts as withdrawable for its owned providers, and
only when the account has a linked GitHub identity. Held, provisional, capped,
disposition-blocked, or another owner's MALIBU MUST NOT be stakeable. A later
chain source MUST implement the same interface and MUST NOT change
SPEC-050-R004 through SPEC-050-R011.

### SPEC-050-R002 - Append-only, idempotent stake ledger

Stake events MUST be append-only rows keyed by account, provider, and an
`Idempotency-Key` supplied by the caller. A retry with the same key and the
same request MUST return the original result without a new event; the same key
with a different request MUST be refused with `409 idempotency_key_reused`. A
lock MUST be split deterministically across owned providers in ascending
`provider_id` order and MUST NOT exceed, per provider, withdrawable MALIBU
minus MALIBU already locked on that provider by its current owner's identity.
Under a per-provider lock the coordinator MUST re-read the provider's owner,
skip a provider the account's identity no longer owns, compute the remainder,
and insert the event, so concurrent locks cannot lock the same MALIBU twice. A
lock is effective only while the provider is owned by the identity that placed
it: a former owner's lock neither earns (SPEC-050-R004) nor keeps the current
owner from staking. An account stakes under one GitHub identity for good; a
lock under a different identity is refused with `409 stake_identity_changed`.
An account's total stake MUST NOT exceed 10,000,000,000 MALIBU (`400
stake_bound_exceeded`). An unlock MUST NOT exceed the account's current
earning-or-maturing stake, is taken in descending `provider_id` order, and
needs no current GitHub link. Amounts are decimal MALIBU strings with at most
8 fractional digits, positive, at most 10,000,000,000 per call. One account
MAY append at most 200 stake events in a rolling 24 hours, counting every
event a change would append; further changes are refused with `429
stake_rate_limited`, and a replay of an applied key is still answered.

### SPEC-050-R003 - Locked MALIBU cannot be withdrawn

MALIBU locked on a provider, including MALIBU inside an unlock cooldown, MUST be
netted out of that provider's withdrawable MALIBU on every SPEC-021 read
surface and by any withdrawal runner. Locked MALIBU becomes withdrawable again
only when its unlock's release time has passed and the SPEC-021 predicate still
holds. The provider accrual read reports the locked amount as `locked_malibu`.
Every lock still in force counts here, a former owner's included. A
withdrawal selector MUST hold the same per-provider lock as staking for the
whole transaction that claims the rows, and takes withdrawable rows oldest
first only while their running total stays within withdrawable minus locked
MALIBU, so no lock can commit between selection and claim.

### SPEC-050-R004 - Earning stake and the unlock cooldown

For UTC day `D` starting at `T`, an account's earning stake on a provider is
the sum of its locks created at or before `T - min_stake_age_hours`, minus the
sum of its unlocks created before `T`, floored at zero. It counts only while the
provider is still owned by the GitHub identity recorded on the lock at refresh
time, and is capped at the provider's withdrawable MALIBU before netting locks.
An unlock MUST stop earning from the next refresh and MUST keep its MALIBU
locked until `unlock time + unlock_cooldown_hours`. Because each provider's
MALIBU can be locked once (SPEC-050-R002) and only the current owner's locks
earn, no MALIBU counts toward two allowances on the same day, across unstake,
relink, or account churn.

### SPEC-050-R005 - Daily allowance refresh

At the first check after 00:00 UTC, the coordinator MUST compute every account's
allowance for the day: `raw = min(floor(earning_stake * credits_per_malibu),
per_account_daily_cap_credits)`. When the sum of `raw` exceeds
`daily_budget_credits`, each grant MUST be `floor(raw * budget / sum_raw)`;
otherwise the grant is `raw`. The refresh MUST be idempotent per (account, UTC
day): a second run for the same day MUST NOT add, change, or remove a grant.
Unused allowance MUST NOT roll over. If the stake source is unavailable, the
run MUST NOT be recorded and MUST be retried at the next check. Every account
with a positive earning stake gets a grant record, a zero one included.

### SPEC-050-R006 - Refresh audit

Each refresh MUST append one run record with the day, budget, rate, cap, stake
source name, total earning stake, total raw credits, total granted credits,
scale in parts per million, account count, and run time, and one grant record
per account with its earning stake, raw credits, and granted credits, in the
same transaction. Run and grant records MUST NOT be updated or deleted by the
allowance code.

### SPEC-050-R007 - Allowance-first spend ordering and the overage setting

For an API-key plaintext or relay-blind request, the gateway MUST send the
request's model, input token upper bound, and maximum output tokens to the
coordinator on the chat hop in gateway-only internal headers. Before any
provider is dispatched, the coordinator MUST reserve the request's credit
bound from the account's remaining allowance (grant minus closed spend minus
active holds) in one transaction when it fits, and fund the request from the
allowance. When it does not fit, the request is funded from the paid quota if
the account's overage setting is on, and refused with `429
rate_limit_exceeded / allowance_exhausted` and `X-RateLimit-Reset` at the next
00:00 UTC if it is off. Overage defaults to on. The coordinator MUST tell the
gateway the funding and whether the account has an allowance today; the
gateway MUST then keep an allowance-funded request off the paid daily quota,
both its hold and its usage. When the paid quota cannot take a request, the
gateway MAY forward it only for an account the coordinator reported an
allowance for that UTC day, marked so that only the allowance may fund it; the
coordinator MUST refuse it with `429 quota_exhausted` when the allowance
cannot cover it. A refusal happens before dispatch and the gateway refunds its
reservation. A request is funded by one source; allowance and paid quota are
not combined inside one request. A gateway retry of an admitted request keeps
its first funding, and a closed allowance hold is held again with a fresh
bound while the retry runs. The overage setting is recorded only when it
changes, at most 50 times per account in a rolling 24 hours (`429
overage_rate_limited`).

### SPEC-050-R008 - Per-request split and allowance balance

The allowance spend of a request MUST equal the sum of `gross_credits` of the
SPEC-005 ledger rows of all its attempts, measured at ledger insert. The
coordinator MUST record one split row per ledger row of every request that
went through allowance admission, carrying `allowance_credits` and
`paid_credits` (one of them zero) and whether the row was rewards-excluded.
For an account with no allowance that day no split row is written, and its
requests are funded from the paid quota. Allowance-funded
requests MUST be excluded from SPEC-005 D1a wholesale statements. The
allowance balance MUST NOT be withdrawable, transferable between accounts, or
convertible to MALIBU or USDC. A closed request may spend more than its hold
when the provider's real usage exceeds the bound; the overshoot is recorded
and the remainder floors at zero. A hold is closed by its own chat handler
when the handler ends; holds created before the current coordinator process
started belong to handlers that died with it and are closed by the refresh
job from the ledger. Closing is re-entrant, so a later close adds any attempt
recorded after an earlier one. The gateway settlement writes the confirmed
funding onto its reservation in the same transaction, so a failed earlier
update never leaves allowance usage on the paid quota.

### SPEC-050-R009 - Providers are paid unchanged

Allowance funding MUST NOT change any SPEC-005 or SPEC-022 ledger row, rate,
provider credit, receipt, or settlement decision. A provider serving an
allowance request earns USDC exactly as for a paid request. The operator funds
the allowance from the configured daily budget.

### SPEC-050-R010 - Self-dealt allowance traffic earns no MALIBU

When an allowance-funded attempt is served by a provider that is self-dealing
for the account, its ledger row MUST be written with `rewards_excluded = 1`, so
SPEC-021 accrues no MALIBU for it. A provider is self-dealing for an account
when any of these hold: it is owned by the account's GitHub identity; its
SPEC-016 payout address equals the payout address of any provider the account
owns; or it is in the same referral cluster as any provider the account owns.
A referral cluster is the connected set of providers linked by
provider-issued (`P`) referral redemptions, walked in both directions to depth
8 and at most 256 providers; operator seed codes do not link providers. The
account's identity is the one recorded on the grant of the day the request
was admitted. When the walk limit is reached, any lookup fails, or the request
has no allowance hold, the attempt MUST be treated as self-dealt. Answers MAY
be cached for at most five minutes. USDC earnings are unaffected
(SPEC-050-R009).

### SPEC-050-R011 - Account surface

The gateway MUST expose `GET /v1/stake` and `POST /v1/stake/lock`,
`/v1/stake/unlock`, `/v1/stake/overage` to API-key-authenticated accounts only,
refusing wallet-session bearers and demo tokens with `403 permission_error`.
It MUST forward a new request to the coordinator that carries only the gateway
service token, the authenticated account id, the account's GitHub user id when
linked, `Idempotency-Key`, and `X-Request-ID`; no client header is copied. The
account view MUST return the staked and unlocking MALIBU, the next unlock
release time, MALIBU available to stake, today's allowance, spent, held and
remaining credits, the next refresh time, the overage setting, the payout
addresses of the account's owned providers (`linked_wallets`), and the
disclosure text of SPEC-050-R012. The gateway account page MUST show these
fields.

### SPEC-050-R012 - Disclosure without yield language

Every surface that shows stake or allowance MUST carry this text unchanged:
"Staked MALIBU stays locked while staked and during the unlock cooldown. The
daily allowance is inference credit on this network only. It cannot be
withdrawn, transferred, or sold, and unused allowance expires at 00:00 UTC. Its
size depends on the operator's daily network budget and can change." No stake
or allowance surface, field name, error message, or log line MAY use the words
APY, APR, yield, interest, dividend, or return(s) on stake.

### SPEC-050-R013 - Write authority

Stake events MUST be written only by the coordinator through the
`rewards_writer` Postgres role, which holds `SELECT` and `INSERT` and no
`UPDATE`, `DELETE`, or `TRUNCATE` on the stake table. `stats_reader` and
`stats_rollup` MUST NOT read or write it. The gateway MUST NOT hold a Postgres
credential or write any rewards, stake, or allowance table; it reaches them only
through the coordinator's service-token internal API. Allowance grants,
reservations, splits, and overage events live in the coordinator SQLite
billing database.

### SPEC-050-R014 - Version skew and coordinator failure

A coordinator that does not know the allowance headers ignores them, and the
request is paid as before; a gateway that does not send them gets no
allowance admission. A gateway MUST NOT forward a paid-quota-exhausted request
as allowance-only unless the coordinator reported an allowance for the account
that UTC day; it keeps that answer across restarts. If the coordinator cannot
run admission for an allowance-only request (missing or invalid headers, no
account context, no billing store, a store error), it MUST refuse it with
`503 allowance_unavailable` before dispatch, and otherwise serve the request
from the paid quota. If an allowance-only request comes back without an
allowance funding answer (a coordinator without SPEC-050, or one rolled back),
the gateway MUST charge it to the paid quota, even past its limit, and MUST
stop forwarding allowance-only requests for that account that day. The gateway
SQLite schema is version 19, which an older gateway refuses. The gateway MUST
strip the internal allowance headers from buyer requests and from responses
to buyers.

## 6. Implementation, tests, and journeys

The machine-readable mapping is in `CONFORMANCE.json`.

- Stake ledger and source: `phase4-coordinator/internal/rewards/stake.go`,
  Postgres migration `032_malibu_stake_ledger`.
- Allowance store, refresh, admission, splits, self-dealing:
  `phase4-coordinator/internal/billing/allowance*.go`.
- Coordinator internal API: `phase4-coordinator/internal/stakeallowance/`.
- Coordinator chat-hop admission and close:
  `phase4-coordinator/internal/buyer/allowance_hook.go`.
- Gateway allowance headers, quota exclusion, and `/v1/stake` proxy:
  `phase5-gateway/internal/router/stake_allowance.go` and the SQLite store.
- Integration journey: `test/integration/stake_allowance_integration_test.go`.

The physical journey (one account stakes, receives an allowance, and spends it
through the Malibu gateway) is the live slice of issue #1062.

## 7. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-050-R001`..`R014` | `DECISION_REQUIRED` | `@Augustas11` | `#1062` | Live stake, refresh, and allowance spend through the gateway |

## 8. Current contract notes

- Allowance spend is measured at the hot-path ledger price. A later SPEC-005
  §7.5b receipt re-price changes provider credit, not the recorded spend.
- A request with several attempts spends the gross credits of every attempt,
  because the operator funds each provider leg.
- The credit bound for a pool-model request uses the global rate card; the
  spend uses the ledger row actually written. The bound rounds up and applies
  no usage validation, so it is never below the gross of the same tokens.
- Split rows are written for every request of an account that has an
  allowance that day; a request with no split row was paid from the quota.

## 9. Changelog

- 0.1.0 - #1062 initial contract: ledger-MALIBU stake, budgeted daily
  allowance, allowance-first spend, overage, split, self-dealing exclusion,
  account surface, disclosure, write authority.
