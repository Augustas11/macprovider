# Build prompt — SPEC-005 v0.1

Operator-paste prompt that drafts the normative SPEC-005 (Mac Provider's
billing, settlement, and provider-rewards spec) against the locked
design choices captured below. The design exploration was completed in
a previous run; its output is at `specs/SPEC-005-design.md`. The
operator's pre-commitments are at
`specs/SPEC-005-operator-decisions.md`. This prompt does NOT relitigate
the design — it locks the operator's 12 decisions and asks a fresh
session to produce the spec.

This prompt is the BUILD half of the two-stage SCOPE → BUILD pattern
established for SPEC-006 (Entry 22 lesson 4: "the SCOPE session
explores, the BUILD session implements; the operator locks the
decisions in between"). The executing session has zero design space:
every D1–D12 decision in `SPEC-005-operator-decisions.md` is normative
input.

Run in **Codex** (`/goal` form per `specs/SPEC-005-EXECUTION-PLAN.md`
Step 3) or **Claude Code**. Expected duration: ~3–4 hours for a
thorough first draft. Output is `specs/SPEC-005-billing.md` v0.1 plus,
optionally, appended notes in `phase4-coordinator/implementation-notes.html`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are drafting SPEC-005 v0.1, the normative specification for Mac
Provider's billing, settlement, and provider-rewards layer. The design
exploration is complete at `specs/SPEC-005-design.md` and the operator
has locked specific decisions at `specs/SPEC-005-operator-decisions.md`.
Your job is to convert those locked decisions into a normative spec
with the same rigor as SPEC-002 v1.3.3 and SPEC-006 v0.8.1.

Output location:
  /Users/augstar/macprovider-poc/specs/SPEC-005-billing.md

Target length: 1,800–2,800 lines. Same structural rigor as SPEC-006
v0.1 (which landed at 2,373 lines). Numbered sections, MUST/SHOULD/MAY
normative language per RFC 2119, explicit acceptance criteria with
deterministic verification steps (each AC MUST be testable without a
live network), change log header, § 2 locked-decisions section
(read-only; all 12 D1–D12 decisions encoded as normative
pre-commitments and NOT revisited).

You are NOT writing code in this run. You are writing the spec. A
separate BUILD_PHASE6_PROMPT.md (or whatever the next phase is named)
will drive the coordinator implementation AFTER the spec is audited
and locked.

## Locked design choices (operator pre-commitments)

These are normative inputs. Do NOT relitigate them. Do NOT propose
alternatives. They are the answers to the twelve questions in
`specs/SPEC-005-design.md` § 3, decided by the operator and committed
to `specs/SPEC-005-operator-decisions.md`. Read that file in full
before you begin; the summaries below are convenience copies of the
operator's locked rows but the canonical source is the file.

### D1 — Billing model

**Donation-only; no tip jar in v1.** SPEC-005 records a
provider-credit ledger, NOT buyer revenue. No Stripe, no checkout, no
credit card collection, no per-provider tip jar surface. A single
"support the network" donation link MAY be linked from front-door docs
(SPEC-006 surface) but is operator income, not earmarked provider
revenue, and lives entirely outside the SPEC-005 ledger.

### D2 — Settlement cadence

**Real-time accrue + weekly settlement-ready batch at UTC Monday
00:00.** `coordinator.yaml` carries `settlement.cadence_days: 7`. The
settlement job runs as an in-process coordinator goroutine (no new ops
surface, no cron row). Every completed request writes to
`ledger_request_credits` immediately; the weekly job reads the prior
7 days per provider and emits at most one `ledger_payout_ready` row
per provider per week.

### D3 — Provider reward formula

**Per-model rate card with a single global multiplier.** Per-model
rates live in `coordinator.yaml` (NOT the database), so changes are
git-auditable and require no schema migration. Unknown models fall
back to a `default` row. Per-request credit is integer arithmetic:

```
credits = round(
    global_multiplier × (
        prompt_tokens × prompt_credits_per_mtok / 1_000_000
      + completion_tokens × completion_credits_per_mtok / 1_000_000
    )
)
```

Initial rate-card values (placeholder, explicitly marked as such until
live traffic data justifies a tune):

| Model class | prompt credits/Mtok | completion credits/Mtok |
|---|---:|---:|
| 7B (e.g. `mlx-community/Qwen2.5-7B-Instruct-4bit`) | 1,000,000 | 2,000,000 |
| 3B (e.g. `mlx-community/Llama-3.2-3B-Instruct-4bit`) | 500,000 | 1,000,000 |
| default (any model not enumerated) | 500,000 | 1,000,000 |

`rewards.global_multiplier: 1.0` is the operator's master volume knob
and the only field operators tune day-to-day. The rate card is NOT
exposed via a public endpoint in v1.

### D4 — Minimum payout threshold

**$0.50 nominal, configurable.**
`settlement.min_payout_credits: 500000` (using the 1 credit =
1 micro-dollar convention from D6). Sub-threshold accrued credits
roll forward to the next weekly cycle (rows remain `settled=0` in
`ledger_request_credits`). At or above threshold, the weekly job emits
a `ledger_payout_ready` row for the cumulative amount and marks the
source rows `settled=1`.

The threshold MUST be configurable so SPEC-007 can re-tune for real
gas economics without re-cutting SPEC-005.

### D5 — Revenue split

**90/10 provider/operator global; recorded per credit row.**
`rewards.provider_share: 0.90` in `coordinator.yaml`. Every
`ledger_request_credits` row stores `provider_share_bps` as an
INTEGER (9000 at issuance) so historical splits are immutable even if
the operator changes the rate later. The 10% operator share is
recorded on a parallel `ledger_operator_credits` row for the same
request (sum of the two equals the gross credit value per request).
The split is NOT exposed publicly in v1 but IS visible to the
provider on their own earnings endpoint.

### D6 — Currency / unit

**Internal "credits" denominated as USD micro-dollars (1e-6 USD),
stored as INTEGER.** 1 credit = 1 micro-dollar = $0.000001. All
credit columns are INTEGER. NEVER FLOAT. All credit arithmetic is
integer arithmetic. SPEC-007 converts credits to USDC at payout time
using its own rate. `ledger_payout_ready` has a nullable
`payout_currency` column reserved for SPEC-007 to populate at payout
time; SPEC-005 always writes NULL there.

### D7 — Buyer balance enforcement

**Hard limit at the account-day boundary per SPEC-006 §17.7. SPEC-005
does NOT re-implement quota.** The gateway is the authoritative
enforcement point. SPEC-005 credits the provider for actual reported
usage regardless of buyer quota state — if the gateway forwarded the
request and the provider reported usage, the provider gets credit
even if the buyer was over-quota. The provider is never zero-credited
for legitimate completed work.

An advisory `overshoot_flag` column on `ledger_request_credits` MAY
record whether the actual debit exceeded the buyer's expected
reservation, for operator visibility only. Pure observation; no
automatic action.

### D8 — Failed-request accounting (the H-005 closure)

**Direct 1:1 credit-to-debit mapping with SPEC-006 §17.7 D3 matrix.**
For every buyer-side debit state in SPEC-006 §17.7, SPEC-005 defines
the symmetric provider credit:

| SPEC-006 §17.7 buyer state | Buyer debit | SPEC-005 provider credit |
|---|---|---|
| 200, usage as reported | prompt + completion | rate_card(prompt) + rate_card(completion) |
| 503, no provider reached | none | none (no `request_log` row with a `provider_assigned_id`) |
| 502, `completion_tokens=0` | prompt only | rate_card(prompt) only |
| 502, partial stream | prompt + actual completion | rate_card(prompt) + rate_card(actual completion) |
| 504, `completion_tokens=0` | prompt only | rate_card(prompt) only |
| 504, partial stream | prompt + actual completion | rate_card(prompt) + rate_card(actual completion) |
| Client disconnect, v1.2.4+ provider | provider-reported actual | rate_card(provider-reported actual) |
| Client disconnect, pre-v1.2.4, usage absent | byte-estimated | rate_card(byte-estimated, same value as buyer side) |

Additional normative rules:

- **Null usage on error path.** If `completion_tokens IS NULL` in
  `request_log` because the provider returned SPEC-001
  `error_model_not_loaded`, `error_context_exceeded`,
  `error_queue_full`, or `error_internal`, provider credit is 0
  regardless of prompt_tokens. The provider failed to perform work;
  no credit owed. (This is the M2.1 R2-audit edge case from the
  design exploration.)
- **Buyer-cancel exclusion.** Per FR-P11a, buyer-initiated cancels
  are NOT faults. The provider gets full credit per reported usage,
  identical to the 200 row.
- **Provider-not-reached.** If `request_log.provider_assigned_id IS
  NULL` (503 path), no provider can be credited and no
  `ledger_request_credits` row is written. (Distinct from the
  "credit = 0" rows above, which DO write a ledger row.)

This mapping closes H-005 by construction: for every buyer-side
SPEC-006 §17.7 debit, the SPEC-005 ledger has a matching, derivable
provider credit on the same `request_log` row.

### D9 — Crash recovery policy

**Same-SQLite-transaction write of `request_log` + ledger rows +
startup scan (24h) + nightly reconcile (7d).** ACID is the primary
mechanism. The coordinator's request-completion handler MUST write
`request_log`, `ledger_request_credits`, and `ledger_operator_credits`
in a single SQLite transaction (`BEGIN IMMEDIATE; …; COMMIT`). If the
crash happens before COMMIT, all rows are lost together (and the
provider response is also lost, so the buyer sees 502 on retry). If
the crash happens after COMMIT, all rows exist together.

A coordinator startup hook MUST scan the prior 24 hours for any
`request_log` row that is "creditable" (per the D8 mapping) but has
no matching `ledger_request_credits` row, and write a recovery row
with `recovery_source='startup_scan'`. A nightly goroutine MUST run
the same scan across the prior 7 days. Any `ledger_request_credits`
row whose `request_id` does not resolve to a `request_log` row MUST
be marked `quarantined=1` for operator review (no auto-correction).

The recovery algorithm MUST be deterministic and unit-testable: given
any (request_log, ledger) state pair, the recovery output is uniquely
defined. No 2PC. No eventual-only reconciliation.

### D10 — Multi-provider attribution (multi-hop)

**Per-attempt provider credit.** SPEC-004 FR-SR-18 logs each attempt
in `request_log` with its own `provider_assigned_id`. SPEC-005's
`ledger_request_credits` MUST be keyed by `(request_id, attempt_n,
provider_id)`. Each attempt runs through the D8 mapping
independently; the credits ledger sums across attempts to mirror the
buyer's aggregated per-request debit. Winner-takes-all is explicitly
rejected.

Cross-spec note: SPEC-002 `request_log` currently exposes `retried`
(0/1). SPEC-005 needs a monotonic `attempt_n` (0, 1, 2, …) to key
its ledger. The Codex R1 self-audit MUST surface this gap (a
SPEC-002 cross-spec patch candidate). For v0.1 drafting, write the
spec as if `attempt_n` exists on `request_log`, and call out the
SPEC-002 cross-spec patch requirement explicitly in § 4 (Storage)
and § 20 (Open questions to operator). Do NOT silently assume the
patch is free.

### D11 — Operator dashboard scope

**Four JSON endpoints, all coordinator-side, no charts.**

| Endpoint | Auth | Purpose |
|---|---|---|
| `GET /admin/ledger/summary` | operator key (existing `/admin/*` auth) | totals, this week, last 4 weeks, pending payouts, quarantined rows |
| `GET /admin/ledger/providers` | operator key | per-provider breakdown: total earned, pending payout, last activity, nullable `attestation_class` (future-proofing for SPEC-008) |
| `GET /admin/ledger/reconcile?from=YYYY-MM-DD&to=YYYY-MM-DD` | operator key | the H-005 reconciliation report (sum of buyer debits per SPEC-006 §17.7 ↔ sum of provider credits per SPEC-005, with delta and tolerance) |
| `GET /providers/{provider_id}/earnings` | provider bearer token (FR-P12) | provider's own credits: total accrued, current settlement-window credits, last `ledger_payout_ready` row, share percentage, rate-card excerpt for models served |

All endpoints return JSON; no HTML, no chart, no Slack/email digest.
The provider-facing endpoint MUST use the existing FR-P12 bearer-token
path (no new auth surface). No web dashboard in v1.

### D12 — Fraud floor for degraded providers

**Zero credit for FR-P11a fault-classified requests; full
eligibility restored after recovery preflight passes.**

- `ledger_request_credits` MUST write a row for every request that
  reaches a provider (even fault-classified), so the audit trail is
  complete.
- For requests classified by FR-P11a as qualifying faults
  (`relay-timeout-mid-inference`, `dead-WS-mid-inference`, qualified
  `zero-token-completion`), the row MUST have `provider_credits = 0`
  and `fault_flag = 'breaker_qualifying'`. The corresponding
  `ledger_operator_credits` row MUST also be 0 (the operator share
  of zero is zero).
- Provider in `degraded` or `unavailable` state earns nothing because
  no traffic is routed there (FR-R4). No special handling required.
- On FR-P11a recovery → `ready`, the provider rejoins normal credit
  accrual immediately. No carry-over penalty. No extended re-warmup
  period beyond the existing FR-P11a recovery preflight. No
  reduced-credit tier in v1.

The provider's earnings endpoint MUST expose the count of
`fault_flag='breaker_qualifying'` rows so providers can diagnose
their own bad behavior.

## Explicit out-of-scope for v1

Do NOT specify (defer to SPEC-006, SPEC-007, SPEC-008, or later):

- AntFeed USDC payment rail (SPEC-007 scope).
- On-chain settlement of any kind, any version.
- Stripe checkout, credit card collection, fiat invoicing, refund
  workflows, or any buyer-revenue path. (D1 lock; SPEC-006 §1.8
  boundary.)
- Adding any billing logic to the Phase 5 gateway. All SPEC-005
  state lives in coordinator SQLite. (SPEC-006 §1.8 explicit
  exclusion.)
- New fields, new message types, or wire-format changes for the
  Phase 3 binary. SPEC-001 v1.2.4 is frozen.
- Per-provider negotiated revenue splits.
- Reputation-weighted reward formula (uptime × quality × supply).
- Dynamic market-rate pegging (DeepInfra / Together / Groq tracking).
- Tier 2 attested-provider reward multipliers (the schema MUST leave
  a nullable `attestation_class` column for SPEC-008-v2, but SPEC-005
  MUST NOT compute any multiplier based on it).
- KYC, 1099 tax reporting, regulatory paperwork.
- Refund / clawback workflows (the H-005 invariant is one-shot
  symmetry, not bidirectional reversibility).
- Multi-currency ledger entries (the `payout_currency` column exists
  for SPEC-007 to populate, but SPEC-005 always writes NULL).
- Web dashboard with charts, Slack / email digests, webhook
  notifications.
- Multi-coordinator / multi-region replication. SPEC-005 v1 assumes
  SPEC-002 single-instance SQLite.
- Buyer-visible donation buttons, "tip jar" UI, or any payment-
  adjacent surface inside SPEC-006.

Naming this out-of-scope set explicitly is REQUIRED. Place the list
in § 1.3 (Out of scope for v1).

## Critical constraints

**1. SPEC-001 v1.2.4 is locked and unchanged.** SPEC-005 cannot ask
the Phase 3 binary to emit new fields. Reward computation MUST use
only the data already in `usage` (`prompt_tokens`, `completion_tokens`,
`total_tokens`). Cite SPEC-001 v1.2.4 in the "Depends on" header.

**2. SPEC-002 v1.3.3 `request_log` is read-only to SPEC-005.**
SPEC-005 MUST NOT `ALTER` the `request_log` table. New columns
required by SPEC-005 belong in side tables keyed by `request_id`.
SPEC-005 reads `request_log` via JOIN only.

The one exception is the D10 cross-spec patch: SPEC-005 needs an
`attempt_n` column on `request_log` to key per-attempt credit. This
MUST be flagged as a SPEC-002 v1.3.4 cross-spec patch candidate (not
applied by SPEC-005 itself; the operator gates the patch in the
audit cycle). Until the patch lands, SPEC-005's per-attempt ledger
keys MUST tolerate the current `retried` (0/1) schema as a fallback
(attempt_n derived as `retried`; first attempt = 0, second = 1, no
support for 2+ attempts in v0.1). State this fallback explicitly in
§ 4.

**3. SPEC-006 §17.7 D3 matrix is the source of truth for buyer-side
debits.** SPEC-005's D8 credit mapping MUST mirror it exactly, one
credit rule per debit row. Cite SPEC-006 §17.7 by section number on
every D8-related normative paragraph.

**4. Gateway has no billing state.** SPEC-006 §1.8 explicitly
excludes "rewards, payouts, provider contribution economics,
payment-adjacent flows" from gateway scope. SPEC-005's coordinator
endpoints MUST NOT require the gateway to read, write, or forward
ledger state. The provider-earnings endpoint at
`/providers/{provider_id}/earnings` lives on the coordinator, not
the gateway.

**5. No on-chain state, no AntFeed calls.** SPEC-005 MUST NOT call
any AntFeed API, MUST NOT require on-chain settlement, MUST NOT make
any USDC-specific assumption in column types or formulas. The
SPEC-007 boundary is a single machine-readable artifact:
`ledger_payout_ready` rows. SPEC-007 reads them; SPEC-005 writes
them; nothing else crosses the boundary.

**6. ACID is the consistency model.** All credit writes MUST share a
SQLite transaction with the `request_log` write. No 2PC. No
eventually-consistent reconciliation as the primary mechanism (the
reconciliation scan is a safety net, not the consistency model).

**7. Integer-only credit math.** All credit columns are INTEGER. All
credit formulas use integer arithmetic with explicit rounding rules
(round half to even is recommended; the spec MUST pick one and state
it). No FLOAT or REAL columns for credits, splits, or payout amounts.

**8. Append-only with one exception.** `ledger_request_credits` is
append-only in the hot path. The weekly settlement job MAY update
the `settled` column on existing rows (0 → 1) when it emits a
`ledger_payout_ready` row. This is the ONLY UPDATE permitted; all
other state changes are new rows.

**9. Stranger-readable.** SPEC-005's docs surface (the part visible
to providers via `get.malibu.tech/install.sh` link and provider
docs) MUST be honest about v1 limits: "v1 records provider credits
as an accrual ledger. Real payout requires SPEC-007 (AntFeed rail).
v1 may or may not pay out depending on operator decision." No
implied promises about when or whether credits convert to cash.

**10. H-005 closure is an acceptance criterion.** The SPEC-006 audit
left H-005 (billing settlement fairness) "largely covered by
D-CROSS-1 + SPEC-001 v1.2.3; verification deferred." SPEC-005 MUST
close it by providing an AC that demonstrates per-D3-row symmetry
between buyer debits (SPEC-006 §17.7) and provider credits (SPEC-005
§ on the D8 mapping). The AC MUST be deterministic and testable
without a live network.

## Required reading

In order:

1. `/Users/augstar/macprovider-poc/specs/SPEC-005-design.md`
   — the design exploration. Treat its § 3 (twelve open questions
   with recommendations) as resolved by the "Locked design choices"
   header above and by `specs/SPEC-005-operator-decisions.md`.
   § 4 (cross-question coherence), § 5 (build scope), § 6
   (deferred), and § 7 (falsification) are useful priors but not
   normative.

2. `/Users/augstar/macprovider-poc/specs/SPEC-005-operator-decisions.md`
   — the operator's locked D1–D12 pre-commitments. This is the
   canonical source. If anything in the "Locked design choices"
   header above differs from this file, the file wins.

3. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   — focus on § 4 storage contracts and FR-B9 (`request_log` schema
   with column-by-column types), FR-P11a (circuit-breaker state and
   fault categories), FR-P12 (provider bearer tokens; SPEC-005
   provider endpoint reuses this path), FR-R3 (stable `provider_id`
   vs session `assigned_id` — SPEC-005 keys credits on the stable
   `provider_id`), FR-R4 (pool filtering), FR-SR-18 (per-attempt
   logging). Note SPEC-002 is v1.3.3 — pin that version in the
   "Depends on" line.

4. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   — focus on §1.8 (boundary: no billing in gateway), §17.7 (D3
   quota refund + settlement matrix — the source of truth for D8
   symmetry), §1.6 (Tier 1 disclosure language SPEC-005 docs MUST
   stay consistent with), §3.7 (Quota definition). Pin SPEC-006
   v0.8.1 in "Depends on".

5. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   — focus on § 6 message shapes for `inference_response_end`
   (`usage` object: `prompt_tokens`, `completion_tokens`,
   `total_tokens`), § 6.6 cancel-usage normative (provider MUST
   include actual usage on cancel from v1.2.3), and the error-status
   list (`error_model_not_loaded`, `error_context_exceeded`,
   `error_queue_full`, `error_internal`) where `usage` MAY be null.
   Pin SPEC-001 v1.2.4 in "Depends on".

6. `/Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md`
   — focus on the "Rewards / billing — deferred to SPEC-005"
   subsection. SPEC-005's docs surface MUST be consistent with what
   SPEC-003 promises providers at install time. Pin SPEC-003 v0.7.

7. `/Users/augstar/macprovider-poc/specs/SPEC-004-smart-router.md`
   — focus on FR-SR-18 (per-attempt logging primitive SPEC-005's D10
   builds on) and the "Rewards, billing, settlement, contributor
   distribution" deferral to SPEC-005. Pin SPEC-004 v0.3.1.

8. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md`
   — focus on the attestation-class concept. SPEC-005's data model
   leaves a nullable `attestation_class` field for SPEC-008-v2
   multipliers but does NOT compute any v1 multiplier from it. Pin
   SPEC-008 v0.3 (informational, not a "Depends on" entry — SPEC-005
   does not consume SPEC-008 in v1).

9. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   — read Entry 22 (audit-pattern lessons, especially the
   five-tier audit cycle and dependency-line drift discipline).
   SPEC-005 inherits the same audit posture.

10. `/Users/augstar/macprovider-poc/specs/AUDIT_SPEC_006_PROMPT.md`
    — read for the audit structure SPEC-005's downstream R1/R2 cycles
    will use. Not normative for drafting, but informs how every AC
    should be expressed (deterministic verification, no live-network
    dependency).

## Output structure

```
# SPEC-005 — Billing, Settlement, and Provider Rewards

**Version:** 0.1 (2026-05-31, initial draft from locked operator decisions)
**Depends on:** SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-003 v0.7,
                SPEC-004 v0.3.1, SPEC-006 v0.8.1

**Change log v0.1:**
- Initial draft following design exploration in
  specs/SPEC-005-design.md and operator pre-commitments in
  specs/SPEC-005-operator-decisions.md.
- Locked design choices captured from D1–D12 (see § 2 Locked
  decisions). § 2 is read-only.
- Closes H-005 (billing settlement fairness) from SPEC-006 v0.6
  external audit by D8 1:1 credit-to-debit symmetry with SPEC-006
  §17.7 D3 matrix (see § 6 D8 mapping and AC-H005).

[main body sections — see structure below]
```

Section structure (numbers are normative; do NOT renumber):

1. **Scope** — what SPEC-005 covers (provider-credit ledger, weekly
   settlement-ready batch, operator + provider dashboards), what it
   doesn't (SPEC-007 payment rail, on-chain, gateway billing,
   SPEC-001 wire changes), relationship to SPEC-001 / 002 / 003 /
   004 / 006 / 007 / 008.

2. **Locked decisions** — restate D1–D12 verbatim from
   `specs/SPEC-005-operator-decisions.md`. This section is read-only
   documentation; do NOT propose changes, do NOT add commentary, do
   NOT re-evaluate. If a finding in a later audit needs to change a
   D1–D12 row, the operator must re-open the SCOPE stage; § 2 of
   SPEC-005 only documents what is locked.

3. **Terms and definitions** — credit, micro-dollar, rate card,
   settlement window, settlement-ready row, payout, provider_id (vs
   assigned_id), attempt_n, fault flag, attestation_class
   (nullable), recovery_source, quarantined row, reconciliation
   delta.

4. **Storage layer** — every new SQLite table with column-by-column
   type, constraint, index, and migration ordering. At minimum:
   `ledger_request_credits`, `ledger_operator_credits`,
   `ledger_payout_ready`, and any side tables for fault flags or
   audit. Each table MUST list its indexes (the `(provider_id,
   ts_utc)` index is required for the weekly rollup). Include the
   SPEC-002 cross-spec patch note for `attempt_n` and the v0.1
   fallback behavior using `retried`. State explicitly that
   `request_log` is read-only to SPEC-005 (JOIN only, never ALTER).

5. **Units and arithmetic** — D6 lock: 1 credit = 1 micro-dollar;
   all columns INTEGER; rounding rule (specify; round half to even
   recommended); per-request credit formula; integer division
   discipline. Worked examples for: 200 with 1,000 prompt / 2,000
   completion tokens on 7B rates; 502 with prompt-only credit; null
   usage on error path.

6. **Credit calculation (the D8 mapping)** — the core normative
   section. One subsection per SPEC-006 §17.7 D3 matrix row. Each
   subsection MUST cite the SPEC-006 §17.7 row by name and state the
   symmetric SPEC-005 provider credit derivation. Subsections for:
   200 success, 503 no-provider-reached, 502/0, 502/partial, 504/0,
   504/partial, client-disconnect-v1.2.4+, client-disconnect-pre-
   v1.2.4. Plus the three additional rules: null-usage error path,
   buyer-cancel exclusion, FR-P11a fault flag.

7. **Settlement** — D2 weekly cadence (UTC Monday 00:00),
   `settlement.cadence_days` config, in-process goroutine
   implementation contract (no cron), D4 threshold behavior (roll
   forward below, emit `ledger_payout_ready` above), D5 split
   recording (`provider_share_bps` immutable at row creation),
   idempotency requirement (re-running a missed window MUST be safe).

8. **Multi-attempt attribution (D10)** — per-attempt ledger keys
   `(request_id, attempt_n, provider_id)`, derivation from
   `request_log`, fallback using `retried` until SPEC-002 cross-spec
   patch lands, sum-of-credits-equals-sum-of-attempts invariant.

9. **Fraud floor and FR-P11a integration (D12)** — fault flag
   semantics, zero-credit rule for breaker-qualifying requests,
   `degraded` / `unavailable` state means no traffic and no rows,
   recovery preflight restores full eligibility, no carry-over
   penalty.

10. **Crash recovery and reconciliation (D9)** — same-SQLite-
    transaction write contract (`BEGIN IMMEDIATE; …; COMMIT`),
    startup scan (24h, `recovery_source='startup_scan'`), nightly
    reconcile job (7d, in-process goroutine), quarantine policy
    (ledger row referencing absent `request_log` row →
    `quarantined=1`, no auto-correction), deterministic recovery
    function signature.

11. **Operator and provider endpoints (D11)** — four endpoints with
    request schema, response schema, auth, rate-limit posture, and
    JSON example. `GET /admin/ledger/summary`,
    `GET /admin/ledger/providers`,
    `GET /admin/ledger/reconcile`,
    `GET /providers/{provider_id}/earnings`. Provider endpoint
    reuses FR-P12 bearer-token auth — no new auth surface. No HTML
    or charts in v1.

12. **Buyer-balance interaction (D7)** — explicit statement that
    SPEC-005 does NOT enforce quota (the gateway does, per SPEC-006
    §17.7) and does NOT zero-credit providers for over-quota
    buyer requests. Optional `overshoot_flag` semantics.

13. **Configuration** — every `coordinator.yaml` key SPEC-005 adds,
    with default value, type, and operator-tunability notes:
    `rewards.rate_card` (per-model + default + global_multiplier),
    `rewards.provider_share`, `settlement.cadence_days`,
    `settlement.min_payout_credits`, optional
    `settlement.reconcile_window_hours` (startup), optional
    `settlement.nightly_reconcile_window_days` (7). Hot-reload
    behavior: rate-card changes apply to NEW requests; existing
    ledger rows are immutable.

14. **Instrumentation and metrics** — per-provider total credits,
    per-provider current-window credits, count of pending
    `ledger_payout_ready` rows, count of `quarantined=1` rows, count
    of `fault_flag='breaker_qualifying'` rows, reconciliation delta
    (per-day buyer-debit total ↔ per-day provider-credit total). All
    metrics MUST be readable from the four endpoints in § 11 (no
    new metrics surface).

15. **Backward compatibility** — pre-v1.2.4 provider handling
    (byte-estimation fallback per D8); SPEC-002 `request_log`
    fallback for `attempt_n` derived from `retried` until the
    cross-spec patch lands; rate-card unknown-model fallback to
    `default`; idempotent re-run of a missed weekly settlement
    window.

16. **Security and privacy** — operator-only auth on `/admin/*`
    endpoints, provider bearer-token auth on
    `/providers/{provider_id}/earnings`, no buyer-visible secrets
    (no leaking of `provider_id` or earnings totals to buyers via
    any SPEC-005 path), append-only audit trail, the rate card NOT
    publicly exposed in v1.

17. **Failure modes** — endpoint failure modes (operator key
    invalid → 403; provider token invalid → 401; unknown
    `provider_id` on earnings endpoint → 404; settlement job crash
    mid-run → next start picks up via idempotent re-run). Crash
    recovery failure mode → quarantine + operator review.

18. **Acceptance criteria** — AC-1 through AC-N. Each AC MUST have
    deterministic verification steps that do NOT require a live
    network. At minimum:
    - AC-H005: H-005 closure — per-D3-row symmetry between buyer
      debits and provider credits.
    - AC-D1..AC-D12: one AC per locked decision, demonstrating the
      spec encodes it.
    - AC-NULL: null-usage error path → zero provider credit.
    - AC-MULTIHOP: two-attempt request produces two
      `ledger_request_credits` rows with distinct (attempt_n,
      provider_id) keys; sum matches buyer debit.
    - AC-FAULT: FR-P11a-qualifying fault writes a row with
      `provider_credits=0` and `fault_flag='breaker_qualifying'`.
    - AC-CRASH: simulated crash between request_log write and
      ledger write → no inconsistent state (both rows present after
      COMMIT or both absent).
    - AC-STARTUP-SCAN: synthetic missing-ledger row from prior 24h
      → startup scan writes a `recovery_source='startup_scan'` row.
    - AC-QUARANTINE: synthetic ledger row referencing absent
      `request_log` row → `quarantined=1` after nightly reconcile.
    - AC-THRESHOLD: accrued credits below `min_payout_credits` roll
      forward; accrued credits ≥ threshold emit
      `ledger_payout_ready` row and mark sources `settled=1`.
    - AC-SPLIT: every `ledger_request_credits` row has
      `provider_share_bps=9000` at issuance; row remains immutable
      after operator changes `rewards.provider_share`.
    - AC-RATE-CARD: unknown model falls back to `default` rate;
      operator changes `rate_card`, new requests use new rates,
      old rows unchanged.
    - AC-ENDPOINTS: all four endpoints return well-formed JSON with
      documented fields; provider endpoint authenticated via FR-P12
      token; operator endpoints rejected without operator key.
    - AC-INTEGER-ARITHMETIC: no FLOAT columns; computed
      `total_credits` matches integer formula exactly.
    - AC-NO-WIRE-CHANGE: drafted spec contains no requirement on
      SPEC-001 Phase 3 binary. (Grep test.)
    - AC-NO-GATEWAY-CHANGE: drafted spec contains no requirement on
      Phase 5 gateway code. (Grep test.)
    - AC-NO-ONCHAIN: drafted spec contains no AntFeed call, no
      on-chain state, no USDC-specific column type. (Grep test.)

19. **Audit categories** — inherit SPEC-002 / SPEC-006 audit
    categories; add SPEC-005-specific ones. At minimum: credit
    arithmetic correctness (off-by-one in integer rounding),
    same-transaction violation (any code path that writes ledger
    outside the request_log transaction), recovery determinism
    (any state pair producing non-unique recovery output), endpoint
    auth correctness, rate-card hot-reload safety (no rows written
    with wrong rate during a config swap).

20. **Open questions to operator** — any genuinely unresolved
    decisions surfaced during drafting. Should be small (operator
    pre-locked twelve decisions); if you find yourself wanting to
    add many, re-read § 2. Candidate items: SPEC-002 cross-spec
    `attempt_n` patch (must surface here so the operator decides
    whether to bundle it with SPEC-005 lock); integer rounding rule
    choice (round half to even vs floor); reconciliation window
    sizes (24h startup, 7d nightly — defaults proposed but
    operator-tunable).

## Self-verification checklist

Before declaring the spec complete, verify:

- [ ] Header reflects v0.1 + correct "Depends on" line with all five
      upstream specs version-pinned (SPEC-001 v1.2.4, SPEC-002
      v1.3.3, SPEC-003 v0.7, SPEC-004 v0.3.1, SPEC-006 v0.8.1).
- [ ] § 2 (Locked decisions) restates D1–D12 verbatim and contains
      NO original recommendations or alternatives.
- [ ] § 4 (Storage) lists every new table column-by-column with type,
      constraint, and indexes. `request_log` is documented as
      read-only (JOIN only).
- [ ] § 4 (Storage) explicitly flags the SPEC-002 cross-spec
      `attempt_n` patch and documents the v0.1 fallback using
      `retried`.
- [ ] § 5 (Units) commits to INTEGER columns and an explicit
      rounding rule.
- [ ] § 6 (Credit calculation) has one subsection per SPEC-006 §17.7
      D3 matrix row, cites each row by name, and the three
      additional rules (null usage, buyer cancel, fault flag) are
      explicit.
- [ ] § 7 (Settlement) makes the weekly job in-process goroutine
      normative and the threshold roll-forward behavior explicit.
- [ ] § 8 (Multi-attempt) keys ledger on `(request_id, attempt_n,
      provider_id)` and states the sum-equals-buyer-debit invariant.
- [ ] § 9 (Fraud floor) ties zero-credit rule to FR-P11a fault
      categories by name (`relay-timeout-mid-inference`,
      `dead-WS-mid-inference`, qualified `zero-token-completion`).
- [ ] § 10 (Crash recovery) names `BEGIN IMMEDIATE; …; COMMIT` and
      the deterministic recovery function contract.
- [ ] § 11 (Endpoints) lists all four endpoints with auth, request,
      and response shape. Provider endpoint uses FR-P12.
- [ ] § 13 (Configuration) lists every new `coordinator.yaml` key
      with default value and type.
- [ ] § 18 (Acceptance criteria) has ≥ 15 ACs, each with a
      deterministic verification step that does NOT require a live
      network. AC-H005 explicitly verifies SPEC-006 §17.7 ↔ SPEC-005
      D8 symmetry.
- [ ] Out-of-scope (§ 1.3) explicitly names: AntFeed payment rail,
      on-chain settlement, Stripe / fiat / refunds, gateway billing
      logic, SPEC-001 wire-format changes, per-provider negotiated
      splits, reputation weighting, dynamic market rates, Tier 2
      multipliers, KYC / 1099, multi-currency, web dashboard /
      charts / Slack, multi-coordinator replication, buyer-visible
      donation buttons.
- [ ] No proposed changes to SPEC-001. (Spec contains no MUST or
      SHOULD aimed at Phase 3 binary code.)
- [ ] No proposed changes to SPEC-006 §17.7 D3 matrix. (SPEC-005
      mirrors, never edits.)
- [ ] The single SPEC-002 cross-spec patch (`attempt_n`) is flagged
      in § 4 and § 20 — not silently applied.
- [ ] No buyer-visible secrets: no leaking `provider_id`, earnings
      totals, or rate card to buyers via any SPEC-005 path.
- [ ] Implementation language assumed: Go (consistent with
      phase4-coordinator).
- [ ] Implementation deployment target: same coordinator instance
      that owns `request_log` (Pearl VPS in v1).
- [ ] Sync all "Depends on" version pins at the top of the file to
      the current corpus state before declaring complete. (Entry 22
      lesson 6: dependency-line drift sweep is mandatory.)

If you find yourself wanting to recommend an alternative to a locked
decision, STOP — the decision is locked. File the alternative as a
v0.2 candidate in § 20 (Open questions to operator) if relevant; do
not edit § 2.

When done, print a 250-word handback summary covering:
- What the spec defines (one paragraph)
- What it explicitly defers (one paragraph)
- Estimated implementation scope in days (rough)
- Any genuine open questions surfaced during drafting (bulleted list,
  small if § 2 was respected)

Then stop. Do NOT begin implementation. The operator will audit the
spec (Codex R1 self-audit per Step 3 of
`specs/SPEC-005-EXECUTION-PLAN.md`) before any code work begins.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~45 min):

1. Read `specs/SPEC-005-billing.md` start to finish.
2. Verify § 2 (Locked decisions) matches `specs/SPEC-005-operator-decisions.md`
   verbatim — no "improvements," no edits, no commentary.
3. Verify out-of-scope (§ 1.3) names every deferred item from the
   "Explicit out-of-scope" header above.
4. Verify § 6 (Credit calculation) has one subsection per SPEC-006
   §17.7 D3 matrix row and cites each by name.
5. Verify § 4 (Storage) flags the SPEC-002 `attempt_n` cross-spec patch
   as a candidate (not silently applied).
6. Verify "Depends on" line pins all five upstream specs at the
   current corpus state (SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-003
   v0.7, SPEC-004 v0.3.1, SPEC-006 v0.8.1).
7. AC section has ≥ 15 deterministic ACs; AC-H005 explicitly closes
   H-005.

If clean: proceed to Step 3 of `specs/SPEC-005-EXECUTION-PLAN.md`
(Codex R1 self-audit + FIX_SPEC_005_V0_2_PROMPT.md draft).

If issues: edit `specs/SPEC-005-billing.md` directly or file a
narrow FIX prompt before Step 3 runs.

## Why this prompt is structured this way

The "Locked design choices" header is the most important part. It
exists to prevent the executing session from re-doing the design work
the operator already did in `specs/SPEC-005-operator-decisions.md`.
The previous design-exploration session correctly avoided being
prescriptive about implementation; this BUILD session needs the
opposite — every decision pre-made, room only to draft.

The "Critical constraints" header carries the locked spec boundaries
(SPEC-001 frozen, SPEC-002 `request_log` read-only, SPEC-006 §17.7 as
the H-005 source of truth, no gateway billing, no on-chain) that the
SCOPE session also respected but the BUILD session might drift on if
not reminded.

The verification checklist forbids the executing session from
proposing alternatives to locked decisions. This is the difference
between BUILD prompts that produce drift ("we changed D5 because we
thought 95/5 was better") and BUILD prompts that produce specs.

The dependency-line discipline (Entry 22 lesson 6) is encoded into
the final checklist item: every BUILD prompt MUST end with a "sync
all 'Depends on' version pins to the corpus state" sweep, regardless
of whether the spec's content touched dependencies. The mechanical
sweep takes ~30 seconds; the drift class is annoying but trivial to
prevent.
