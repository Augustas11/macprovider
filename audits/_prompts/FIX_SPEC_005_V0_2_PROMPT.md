# Fix prompt — SPEC-005 v0.1 → v0.2 R1 audit closing

This is a FIX prompt draft. Do NOT execute it until the operator has
reviewed `specs/SPEC-005-r1-audit.md` and approved this prompt.

Codex R1 self-audit at `specs/SPEC-005-r1-audit.md` produced:

  0 CRITICAL
  7 MAJOR
  4 MINOR
  3 QUESTIONS

GATE 2 review (operator) added:

  - Pre-locked Q-1, Q-2, Q-3 (see "Operator pre-locks" section below)
  - Promoted N-2 to MAJOR as M-8 (orphaned usage_source enum value
    is a schema CHECK-constraint artifact, not a docs nit)
  - Softened M-5 numeric rate-limit ceiling to a configurable key

Verdict: READY WITH FIX PASS — the v0.1 architecture is sound, but
v0.2 must close identity attribution, deterministic recovery, endpoint
contract, AC precision, and the orphaned usage_source enum before
SPEC-005 can be locked.

Version bump:
  SPEC-005 v0.1 → v0.2

Estimated line count of changes: 220–320 lines.

Run in **Claude Code** or **Codex CLI**. Expected duration: ~90-120
minutes. Surgical edits only; do not redesign billing, settlement, or
the locked operator decisions.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are applying the Codex R1 self-audit findings to SPEC-005 v0.1 and
producing SPEC-005 v0.2.

You will edit one file in place:
  /Users/augstar/macprovider-poc/specs/SPEC-005-billing.md  v0.1 → v0.2

You are NOT implementing coordinator code. This is a spec fix pass.

## Critical constraints

**1. Locked design choices remain locked.**

Do NOT change any D1–D12 pre-commitment in § 2

You may add cross-references from later sections back to D1–D12, but
you MUST NOT alter the operator-decision text, semantics, or selected
options in § 2.

**2. SPEC-002 `request_log` remains read-only.** Do not add a SPEC-005
`ALTER request_log` requirement. Any additional storage needed for
identity or config history must be a SPEC-005 side table or a
cross-spec patch candidate explicitly gated by the operator.

**3. SPEC-006 § 17.7 remains the buyer-debit source of truth.** Mirror
the D3 matrix; do not edit or reinterpret SPEC-006.

**4. No implementation work.** Do not edit Go, YAML examples, tests, or
deployment artifacts in this pass.

**5. Keep scope surgical.** Fix only the CRITICAL and MAJOR findings
listed below. MINOR findings and QUESTIONS may be mentioned in § 20 if
needed, but do not expand the pass into a redesign.

## Required reading

1. `/Users/augstar/macprovider-poc/specs/SPEC-005-r1-audit.md`
   — read fully. Use the Proposed fix line under each MAJOR finding as
   the starting point.

2. `/Users/augstar/macprovider-poc/specs/SPEC-005-billing.md`
   — the v0.1 spec under revision.

3. `/Users/augstar/macprovider-poc/specs/SPEC-005-operator-decisions.md`
   — verify § 2 remains locked.

4. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   — focus on FR-B9 request_log, FR-P11a, FR-P12, FR-R3, FR-R4, and
   the current lack of `attempt_n` / stable `provider_id` in
   `request_log`.

5. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   — focus on § 17.7 only.

## Operator pre-locks (from GATE 2 review of R1 audit Q-1/Q-2/Q-3)

The R1 audit raised three QUESTIONS for the operator. The operator
reviewed them at GATE 2 and locked the following answers. The MAJOR
findings below are written to be consistent with these locks; do NOT
re-litigate them.

- **Q-1 (lock):** Add `ledger_config_snapshots` side table in SPEC-005
  v0.2. Recovery prices historical rows from the snapshot whose
  `effective_at_utc <= request_log.ts_utc`. (M-3 proceeds as written.)
- **Q-2 (lock):** Add `ledger_provider_identity_snapshots` side table
  in SPEC-005 v0.2. SPEC-002 is not patched as part of this pass.
  (M-2 proceeds as written.)
- **Q-3 (lock):** Permit the quarantining fallback for v0.2.
  Implementation does NOT wait for a SPEC-002 `attempt_n` cross-spec
  patch. SPEC-002 v1.3.4 monotonic `attempt_n` remains a candidate
  (filed in § 20 as OQ-1), not a SPEC-005 launch blocker. (M-4
  proceeds as written.)

## Findings to fix — ordered by section number

### CRITICAL

None.

### MAJOR

**M-1. D1-D12 normative references are incomplete outside § 2.**

**Audit location:** § 1, § 5-§ 13, § 16, Appendix B.

**Fix:** Add inline `(D#)` citations and one normative "This section
implements D#" sentence in each section that enforces a locked
decision.

Apply this without changing § 2. Examples:

- § 1.3 out-of-scope guard implements D1, D6, and the SPEC-007
  boundary.
- § 5 implements D3, D5, D6, and D8.
- § 7 implements D2, D4, and D5.
- § 8 implements D10.
- § 9 implements D12.
- § 10 implements D9.
- § 11 implements D11.
- § 12 implements D7.
- § 13 implements D2-D6 and D9 config commitments.

**M-2. Stable `provider_id` derivation is underspecified.**

**Audit location:** § 4.2, § 4.3, § 8.

**Fix:** Add a normative provider-identity snapshot contract, either
as a new SPEC-005 side table or as required hot-path fields, that maps
`request_id`, `attempt_n`, and `provider_assigned_id` to stable
`provider_id`.

Preferred v0.2 shape:

- Add `ledger_provider_identity_snapshots` table in § 4.
- Columns: `id`, `request_id`, `attempt_n`, `provider_assigned_id`,
  `provider_id`, `resolved_from`, `pool_session_started_at_utc`,
  `created_at_utc`.
- Unique key: `(request_id, attempt_n, provider_assigned_id)`.
- The hot path MUST write this snapshot in the same SQLite transaction
  as `request_log` and ledger rows.
- Recovery MUST use this snapshot when `request_log` lacks stable
  provider identity.

**M-4. `attempt_n` fallback ordering is not deterministic enough.**

**Audit location:** § 4.2, § 8.2, § 20 OQ-1.

**Fix:** Define fallback ordering as `request_log.id ASC` within each
`request_id` and quarantine any state that cannot produce a unique
ordinal.

Add:

- If SPEC-002 has no `attempt_n`, SPEC-005 derives attempt ordinal by
  sorting same-`request_id` rows by `request_log.id ASC`.
- Row 1 becomes `attempt_n=0`.
- Row 2 becomes `attempt_n=1` only when `request_log.retried` indicates
  an explicit retry.
- Row 3+ is quarantined until SPEC-002 gains monotonic `attempt_n`.
- If two rows cannot be ordered uniquely, all ambiguous rows are
  quarantined.

**M-3. Recovery cannot reconstruct historical rate-card snapshots after config changes.**

**Audit location:** § 5.3, § 10.2-§ 10.4, § 13.2.

**Fix:** Add a `ledger_config_snapshots` side table or equivalent
effective-at config snapshot requirement that recovery uses to price
historical rows deterministically.

Preferred v0.2 shape:

- Add `ledger_config_snapshots` table in § 4.
- Columns: `id`, `effective_at_utc`, `config_hash`, `provider_share_bps`,
  `global_multiplier_ppm`, `rate_card_json`, `created_at_utc`.
- Unique key: `config_hash`.
- Index: `(effective_at_utc)`.
- The coordinator MUST insert a snapshot on startup and whenever a
  valid SPEC-005 config reload is acknowledged.
- Recovery MUST select the latest snapshot whose `effective_at_utc <=
  request_log.ts_utc`.
- If no snapshot exists for a recoverable row, quarantine instead of
  pricing with current config.

**M-7. H-005 reconciliation tolerance is not specified precisely.**

**Audit location:** § 10.3, § 11.3, § 18 AC-H005.

**Fix:** Define H-005 reconciliation as zero tolerance on gross credits
computed from the same § 5.3 formula, with provider/operator split
rounding reconciled separately.

Add:

- `delta_gross_credits` MUST equal 0 for a clean range.
- Provider/operator split deltas MUST be checked separately against
  `provider_credits + operator_credits == gross_credits` per row.
- A non-zero gross delta MUST be reported by `/admin/ledger/reconcile`
  and MUST fail AC-H005.
- No live network may be required for the reconciliation fixture.

**M-5. § 11 endpoints do not include complete JSON examples or rate-limit posture.**

**Audit location:** § 11.1-§ 11.5, § 17.

**Fix:** Add one request/response contract, JSON example, auth failure
shape, and rate-limit statement for each of the four endpoints.

For each endpoint include:

- Method and path.
- Auth requirement.
- Query parameters if any.
- Rate-limit posture: operator endpoints share existing `/admin/*`
  protection; provider endpoint MUST be bounded by a per-provider read
  limit configurable via the new coordinator.yaml key
  `endpoints.provider_earnings.rate_limit_per_minute` (default 60).
  Add this key to § 13 alongside the other SPEC-005 config knobs; do
  not hard-code the numeric ceiling in spec text.
- HTTP 200 JSON example.
- 401/403/404 JSON error example where relevant.
- Explicit "no HTML/charts" statement remains.

Use admin/provider error envelope:

```json
{"error":{"code":"forbidden","message":"operator key required"}}
```

**M-8. Orphaned `usage_source='provider_not_reached'` enum value (promoted from N-2 at GATE 2).**

**Audit location:** § 4.3 (CHECK constraint on `ledger_request_credits.usage_source`), § 6.2.

**Rationale for promotion:** N-2 was classified MINOR in R1 because the
audit treated it as a docs contradiction. It is in fact a real SQLite
CHECK-constraint artifact: § 4.3 enumerates
`usage_source IN ('provider_reported','byte_estimated','null_error','provider_not_reached')`
while § 6.2 explicitly states no `ledger_request_credits` row is written
when the provider was not reached. The enum value is unreachable code.
The fix is one line and belongs with the other v0.2 schema corrections.

**Fix:**

- Remove `'provider_not_reached'` from the `usage_source` CHECK
  constraint in § 4.3.
- Reduce the enum to
  `usage_source IN ('provider_reported','byte_estimated','null_error')`.
- Add one sentence to § 6.2 reaffirming that the 503 path writes
  zero ledger rows of any kind (no `ledger_request_credits`, no
  `ledger_operator_credits`, no `ledger_provider_identity_snapshots`).
- If a reconciliation summary needs to count provider-not-reached
  requests, it does so via the `request_log` JOIN (where
  `provider_assigned_id IS NULL`), not via a `usage_source` value.

**M-6. Acceptance criteria for D1-D12 are too self-referential.**

**Audit location:** § 18 AC-D1 through AC-D12.

**Fix:** Keep text-presence checks as traceability ACs, but add
behavior-level deterministic fixtures for each D decision.

Examples:

- AC-D1-BEHAVIOR: fixture proves no buyer revenue or donation/tip jar
  table is created by SPEC-005 migrations.
- AC-D2-BEHAVIOR: fixture proves completed request accrues immediately
  and weekly job emits payout-ready only at window boundary.
- AC-D5-BEHAVIOR: fixture proves provider/operator split sums exactly
  to gross and historical row is immutable after share change.
- AC-D9-BEHAVIOR: fixture proves startup recovery output is
  deterministic for the same state pair.
- AC-D11-BEHAVIOR: fixture invokes all four handlers and verifies JSON
  shape plus auth.

## Budget

Estimated line count of changes: 230–340 lines (raised from 220–320
to absorb M-8 promotion and the explicit Q-1/Q-2/Q-3 lock paragraph).

## Self-verification before stopping

- [ ] SPEC-005 version bumped from v0.1 to v0.2 in the header.
- [ ] Change log v0.2 added and references R1 audit findings.
- [ ] § 2 D1-D12 operator decision text unchanged.
- [ ] Every MAJOR finding above (M-1 through M-8) has an explicit fix.
- [ ] M-8 removes `'provider_not_reached'` from the `usage_source`
      CHECK constraint and reaffirms the 503 path in § 6.2.
- [ ] Operator pre-locks Q-1/Q-2/Q-3 are encoded in v0.2 spec text
      (side tables for config + identity snapshots; quarantining
      fallback permitted) without re-opening them.
- [ ] New side tables, if added, include type, constraint, index, and
      migration ordering.
- [ ] `request_log` remains read-only; no `ALTER request_log`.
- [ ] H-005 reconciliation tolerance is explicit.
- [ ] All four endpoints include JSON examples and rate-limit posture.
- [ ] AC-D1 through AC-D12 include behavior-level deterministic
      verification, not only text search.
- [ ] Line-count change stays inside the budget unless the operator
      explicitly approves expansion.

When done, print a short handback summary with:

- Major findings closed.
- Files edited.
- Verification commands run.
- Remaining MINOR findings or operator QUESTIONS not addressed.

Then stop. Do NOT implement coordinator code.

=== END PROMPT ===
```
