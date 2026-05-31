# FIX prompt — SPEC-005 v0.3 (Claude R2 + cross-spec pass)

This prompt was produced by the Claude R2 audit at
`specs/SPEC-005-r2-audit.md`. **Do NOT execute until the operator
reviews this prompt and the underlying audit.** Operator review
should confirm the three QUESTIONS (R2-Q1, R2-Q2, R2-Q3) are
pre-locked before the executing session starts, and confirm that
SPEC-002 v1.3.4 and SPEC-006 v0.8.2 cross-spec patches are either
landed or accepted as parallel work.

Operator-paste prompt to apply the R2 audit findings to SPEC-005
v0.2 and produce v0.3, plus the two cross-spec patch files
(SPEC-002 v1.3.4 and SPEC-006 v0.8.2).

R2 audit produced:

- 0 CRITICAL
- 10 MAJOR (R2-M1 through R2-M10)
- 5 MINOR (R2-n1 through R2-n5)
- 3 QUESTIONS (R2-Q1 through R2-Q3 — operator pre-locks below)
- 3 cross-spec patches (SPEC-002 v1.3.4, SPEC-006 v0.8.2, SPEC-007
  consumer contract added inside SPEC-005)

R2 verdict: READY WITH SECOND FIX PASS — architecturally sound;
v0.3 closes M2.1-class implicit assumptions and the two cross-spec
patch surfaces.

Version bump:
  SPEC-005 v0.2 → v0.3
  SPEC-002 v1.3.3 → v1.3.4 (cross-spec patch, bundled with this fix)
  SPEC-006 v0.8.1 → v0.8.2 (cross-spec patch, bundled with this fix)

Run in **Claude Code** or **Codex CLI**. Expected duration: ~2-3
hours (narrow-but-numerous fixes, no architectural changes).
Surgical edits only; the locked § 2 D1-D12 decisions remain locked.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are applying the Claude R2 audit findings to SPEC-005 v0.2 and
producing v0.3, plus the bundled cross-spec patches to SPEC-002
(v1.3.3 → v1.3.4) and SPEC-006 (v0.8.1 → v0.8.2). The audit report
is at `specs/SPEC-005-r2-audit.md`. This is targeted closing-fix
work, NOT a redesign.

You will edit three files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-005-billing.md   v0.2 → v0.3
  /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md v1.3.3 → v1.3.4
  /Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md  v0.8.1 → v0.8.2

## Critical constraints

**1. Locked design choices remain locked.** § 2 of SPEC-005 (the
operator pre-commitments D1-D12) is read-only for content. Do NOT
change any D1-D12 decision text, reopen the donation-only billing
model, the weekly UTC settlement cadence, the per-model rate card
with global multiplier, the $0.50 / 500,000-credit threshold, the
90/10 split, the micro-dollar credit unit, the FR-P11a zero-credit
rule, or the SPEC-007 boundary scope. Any fix that touches § 2
substance is REJECTED.

**2. SPEC-001 v1.2.4 stays unchanged.** No wire-protocol edits.

**3. SPEC-003 v0.7 stays unchanged.** No onboarding-doc edits in
this fix pass.

**4. SPEC-004 v0.3.1 stays unchanged.** SPEC-004 already says what
SPEC-005 needs (per-attempt request_log rows, retried counter).

**5. SPEC-008 v0.3 stays unchanged.** attestation_class remains
nullable storage only; no v1 reward multiplier.

**6. d-inference clean-room.** Do not inspect d-inference source.

**7. Surgical scope.** This fix pass addresses 10 MAJOR + 5 MINOR
findings plus 3 cross-spec patch surfaces. Each has a specific
location and a suggested fix in the audit report. Apply the
suggested fixes (or operator-equivalent alternatives where
indicated below). Do NOT add new normative content beyond what
closes findings.

**8. Three operator questions are pre-resolved.** See "Operator
decisions for v0.3" below.

## Required reading

1. `/Users/augstar/macprovider-poc/specs/SPEC-005-r2-audit.md`
   — read fully. The "Proposed fix" line under each finding is your
   starting text for that finding's resolution.

2. `/Users/augstar/macprovider-poc/specs/SPEC-005-billing.md` v0.2
   — the primary spec under revision. Read all 20 sections plus
   Appendices A-G.

3. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.3 § 7 FR-B9 (request_log schema, line 1093ff) — confirm
   exactly which columns and indexes exist before applying the
   X-2 patch.

4. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   v0.8.1 § 17.7 (line 2561ff, the quota refund and settlement
   matrix) — confirm the current 8-row matrix shape before applying
   the X-1 patch.

5. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 § 6.4 (line 1386ff, inference_response_end status enum)
   — confirm the exact SPEC-001 null-usage error code names
   (`error_model_not_loaded`, `error_context_exceeded`,
   `error_queue_full`, `error_internal`) before referencing them
   in the SPEC-002 v1.3.4 error_code column normative enum.

## Operator decisions for v0.3 (pre-locked, do not relitigate)

The R2 audit surfaced three operator questions. The operator has
pre-decided each. The executing session MUST encode the locked
choice without reopening it.

### Decision R2-D1 (R2-Q1): drop `overshoot_flag` entirely.

**Lock:** Remove the `overshoot_flag` column from § 4.3 and all
references in § 12 D7 and § 17 failure-modes table. D7's "advisory
only" stance is preserved as prose; the column is dropped because
no protocol writes it and SPEC-006 quota enforcement is
authoritative. AC-D7 fixture detail is simplified accordingly. No
SPEC-006 patch is needed for this finding.

### Decision R2-D2 (R2-Q2): disclaim cross-process crash boundary.

**Lock:** SPEC-005 v0.3 explicitly disclaims ownership of the
gateway-crash-after-debit-before-forward state. § 10 adds an
"Out-of-scope crash boundaries" subsection that names this state
and points to SPEC-006 reservation reaper (§ 7.2) as the owning
surface. AC-H005 explicitly excludes this state. NO normative edit
to SPEC-006 is required by R2-M9 (the SPEC-006 § 7.2 reservation
reaper already exists per SPEC-006 v0.8.1 D3 lock).

### Decision R2-D3 (R2-Q3): bundle SPEC-002 v1.3.4 + SPEC-006 v0.8.2 with v0.3.

**Lock:** This fix pass produces three coordinated spec bumps in
one commit:
  SPEC-005 v0.2 → v0.3
  SPEC-002 v1.3.3 → v1.3.4
  SPEC-006 v0.8.1 → v0.8.2

SPEC-005 v0.3 references the v1.3.4 / v0.8.2 dependencies in its
header `Depends on:` line and in § 1.4 cross-spec boundaries.

## Findings to fix — by cluster

### Cluster A — SPEC-005 internal precision (5 MAJOR + 4 MINOR)

#### F-R2-M1: Null `prompt_tokens` edge in § 5.3.

**Location:** § 4.3 (CHECK clause), § 5.3 (formula), § 6.9.

**Fix:** Edit § 5.3 to add explicitly:

> When `usage_source = 'null_error'`, both `prompt_tokens` and
> `completion_tokens` MAY be NULL. The row MUST set
> `gross_credits = 0`, `provider_credits = 0`, and
> `operator_credits = 0` before the formula evaluates; the formula
> MUST NOT be evaluated on NULL operands.

Edit § 6.9 to add the symmetric paragraph. Edit § 4.3 to add a
table-level CHECK note: "When `usage_source = 'null_error'`,
`gross_credits` MUST be 0 (enforced by the hot path and
recovery)."

Add **AC-NULL-PROMPT** (deterministic fixture): prompt_tokens=NULL,
completion_tokens=NULL, error_code='error_internal' → row written
with gross=0, provider=0, operator=0, usage_source='null_error'.

#### F-R2-M5: WAL mode and recovery grace window.

**Location:** § 10.1, § 10.4, § 13.

**Fix:** Edit § 10.1 to add:

> The coordinator SQLite database MUST be operated in WAL mode
> (`PRAGMA journal_mode = WAL`). Recovery scans MUST execute under
> `BEGIN DEFERRED` to obtain a consistent reader snapshot.

Edit § 10.4 to add:

> The deterministic algorithm signature accepts a `scanWindow`
> whose `to_utc` MUST be no closer to wall-clock now than
> `settlement.recovery_grace_seconds` (default 30s). Rows with
> `request_log.ts_utc` newer than this cutoff are excluded from
> the scan to prevent races with in-flight hot-path transactions.

Edit § 13 config table: add row
`settlement.recovery_grace_seconds | integer | 30 | recovery scan grace cutoff`.

Add **AC-WAL** (schema-level): coordinator startup asserts
`journal_mode = WAL` and fails fast otherwise.

#### F-R2-M6 (per R2-D1 lock): drop `overshoot_flag` column.

**Location:** § 4.3, § 12, § 17 failure modes, AC-D7, Appendix C.

**Fix:** Remove the `overshoot_flag` row from § 4.3 table. Remove
"overshoot_flag remains advisory" from § 12. Update D7 prose to
read:

> SPEC-005 does not enforce buyer quota. SPEC-006 gateway quota
> is authoritative. If the gateway forwarded and the provider
> performed work, provider credit follows § 6. Over-quota
> overshoot does not zero provider credit. Operator recourse is
> quota tuning, not provider clawback.

Remove "overshoot_flag" Appendix C entry. AC-D7 fixture simplifies
to assert provider credit > 0 for an over-quota request that
reached a provider.

#### F-R2-M7: SPEC-007 consumer contract — add § 4.5.1.

**Location:** § 4.5 (after the column table); § 1.4 SPEC-007
boundary block.

**Fix:** Add a new subsection § 4.5.1:

> **§ 4.5.1 SPEC-007 consumer contract.**
>
> **Status transition graph:** `ready` → `consumed` (terminal);
> `ready` → `voided` (terminal); no reverse transitions; no
> transitions out of `consumed` or `voided`. SPEC-005 writes only
> `ready`; SPEC-007 may write `consumed` or `voided`.
>
> **JSON projection schema** (consumed by SPEC-007 readers):
>
> ```json
> {
>   "id": int,
>   "provider_id": string,
>   "window_start_utc": ISO8601,
>   "window_end_utc": ISO8601,
>   "provider_credits": int,
>   "min_payout_credits": int,
>   "idempotency_key": string,
>   "status": "ready"|"consumed"|"voided",
>   "payout_currency": string|null,
>   "payout_external_id": string|null
> }
> ```
>
> **Claim pattern** (normative, race-safe):
>
> ```sql
> UPDATE ledger_payout_ready
>    SET status = 'consumed',
>        payout_external_id = ?,
>        payout_currency = ?
>  WHERE id = ? AND status = 'ready';
> ```
>
> SPEC-007 MUST check the affected-row-count: if 0, the claim
> raced or the row is no longer `ready`; SPEC-007 MUST NOT pay.
>
> **Audit trail:** every status mutation MUST also insert one row
> into `ledger_reconciliation_runs` with
> `run_type = 'spec_007_claim'`, populating `from_utc/to_utc` from
> the payout window and `status = 'complete'` or `'failed'`. The
> existing CHECK constraint on `ledger_reconciliation_runs.run_type`
> MUST be extended in MIG-005-008 to include `'spec_007_claim'`.

Add migration MIG-005-008 (in § 4.9) extending the run_type enum.

Add **AC-SPEC-007-CONTRACT** (deterministic fixture):
ready → consumed via the claim pattern; second claim returns 0
rows; voided is terminal; an audit row is appended.

#### F-R2-M8: byte-estimate formula mirrored in SPEC-005 normatively.

**Location:** § 6.8, § 15.1, AC-DISCONNECT-ESTIMATE.

**Fix:** Edit § 6.8 to add:

> The byte-estimate completion-token formula is exactly
> `ceil(bytes_emitted_so_far / 4)` per SPEC-006 v0.8.2 § 17.7.
> SPEC-005 v0.3 mirrors this formula here normatively; any future
> SPEC-006 byte-estimate change MUST trigger a coordinated
> SPEC-005 bump.

§ 15.1 cross-references the same anchor. AC-DISCONNECT-ESTIMATE
adds the explicit reference to SPEC-006 v0.8.2 § 17.7.

#### F-R2-M9 (per R2-D2 lock): disclaim cross-process crash boundary.

**Location:** § 10 (new subsection § 10.6); AC-H005; Appendix A.

**Fix:** Add § 10.6 "Out-of-scope crash boundaries":

> SPEC-005 owns only coordinator-side crash recovery. The
> following cross-process states are explicitly OUT OF SCOPE for
> SPEC-005 v0.3 and remain the responsibility of SPEC-006:
>
> 1. Gateway crashes after the buyer-quota debit (SPEC-006 § 7.2
>    reservation) but before forwarding the request to the
>    coordinator. SPEC-005 sees no `request_log` row; the
>    reservation reaper (SPEC-006 § 7.2 D3 lock) reclaims the
>    reservation within 24h.
> 2. Gateway-coordinator network partition during an in-flight
>    SSE stream; SPEC-005 credits based on whatever
>    `request_log` row eventually commits.
>
> AC-H005 explicitly excludes these states; `delta_gross_credits`
> is computed over the SPEC-005-owned request_log + ledger
> dataset only.

Edit AC-H005 to explicitly exclude these states. Appendix A adds
a checkbox: "cross-process crash boundaries disclaimed in § 10.6".

#### F-R2-M10: clarify `buyer_debit_credits` derivation; rename column.

**Location:** § 4.6, § 10.3, § 11.3, AC-H005.

**Fix:** Rename `buyer_debit_credits` →
`buyer_equivalent_credits` in:

- § 4.6 column table
- Appendix C `ledger_reconciliation_runs.buyer_debit_credits`
  entry
- § 11.3 JSON example
- § 10.3 prose

Add to § 10.3:

> `buyer_equivalent_credits` is the SPEC-005-internal
> buyer-equivalent total computed from `request_log` via the
> § 6 D8 matrix and the same § 5.3 formula. SPEC-005 does NOT
> read SPEC-006 usage tables. AC-H005 verifies symmetry of the
> SPEC-005 model only; cross-process consistency between
> SPEC-005 and SPEC-006 is a separate H-005-EXT verification
> owned by the operator outside SPEC-005 v0.3.

Update AC-H005 to reflect the rename and the SPEC-005-internal
scope.

Add migration MIG-005-009 (column rename via additive ALTER):
since SQLite doesn't support column rename pre-3.25, use
`ALTER TABLE ledger_reconciliation_runs ADD COLUMN
buyer_equivalent_credits INTEGER` plus a backfill from
`buyer_debit_credits`, with `buyer_debit_credits` deprecated as
write-NULL for new rows (kept for backward compatibility).

#### F-R2-n1: pin WAL mode at SPEC-005 config layer.

**Location:** § 13.

**Fix:** Add normative config requirement: "The coordinator SQLite
database MUST run in WAL mode (`journal_mode = WAL`). SPEC-005
behavior is undefined under journal_mode = DELETE." Already
referenced in F-R2-M5; this MINOR is a config-layer mirror.

#### F-R2-n2: `/providers/{id}/earnings` and `require_provider_tokens: false` mode.

**Location:** § 11.5.

**Fix:** Add normative:

> When SPEC-002 v1.3.4 `auth.require_provider_tokens` is `false`,
> the operator MUST separately provision per-provider bearer
> tokens for `/providers/{provider_id}/earnings`, or the endpoint
> MUST be disabled at the route layer. In the disabled-route
> configuration, SPEC-005 provider economics are available only
> via the operator-keyed `/admin/ledger/providers` endpoint.
> SPEC-005 v0.3 production launch gate adds this as item 9
> alongside SPEC-006 production launch gate.

#### F-R2-n3: Appendix B D5 anchor list.

**Location:** Appendix B.

**Fix:** Edit the D5 row of the traceability matrix to read:
`Normative anchors: § 4.3, § 4.4, § 5.3, § 7.3, § 13`.

#### F-R2-n4: Appendix G structured prohibited-pattern list.

**Location:** Appendix G, AC-NO-ONCHAIN.

**Fix:** Reorganize Appendix G into two columns: "Prose-level
guard" (keyword-style, for human review) and "Machine-checkable
prohibited pattern" (specific symbol names, config keys, import
paths). For each existing guard, add at least one machine-
checkable pattern. AC-NO-ONCHAIN updates to grep the
machine-checkable list, not the prose list.

#### F-R2-n5: self-verification checklist.

**Location:** Appendix A.

**Fix:** Append three checkboxes:

- [ ] WAL mode required (§ 10.1, § 13)
- [ ] recovery has explicit grace-window cutoff (§ 10.4)
- [ ] SPEC-007 consumer interface defined (§ 4.5.1)
- [ ] cross-process crash boundaries disclaimed (§ 10.6)

### Cluster B — SPEC-002 v1.3.4 cross-spec patch (X-2 bundle)

Edit `specs/SPEC-002-coordinator.md` header to bump version to
v1.3.4. Add change-log entry summarizing the X-2 bundle.

#### F-X2-A: ts_utc and composite index on request_log.

**Location:** SPEC-002 § 7 FR-B9 (request_log schema, line 1093ff).

**Fix:** Append two normative CREATE INDEX statements after the
table block:

```sql
CREATE INDEX idx_request_log_ts_utc ON request_log(ts_utc);
CREATE INDEX idx_request_log_request_id_id ON request_log(request_id, id);
```

Add prose:

> The `idx_request_log_ts_utc` index supports SPEC-005 v0.3
> reconciliation scans (24h startup, 7d nightly, ad-hoc admin
> ranges) at 10K-provider scale. The composite
> `(request_id, id)` index supports the SPEC-005 § 8.2
> attempt-ordinal fallback and SPEC-004 multi-attempt log
> queries.

#### F-X2-B: error_code column on request_log.

**Location:** SPEC-002 § 7 FR-B9.

**Fix:** Add a new normative column to the request_log table:

| Column | Type | Description |
|---|---|---|
| `error_code` | TEXT | SPEC-001 v1.2.4 status enum on failed responses (`error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, `error_internal`); NULL on success or non-SPEC-001 error paths |

Migration: additive `ALTER TABLE request_log ADD COLUMN
error_code TEXT NULL`.

Add AC: deterministic test that a null-usage error path populates
`error_code` with the exact SPEC-001 string.

#### F-X2-C: multi-row-per-request_id normative.

**Location:** SPEC-002 § 7 FR-B9 (prose around line 1115ff).

**Fix:** Add normative prose:

> Each provider attempt for a given `request_id` MUST produce its
> own `request_log` row. The only uniqueness constraint is on
> (`id`). `request_id` MAY recur across rows when SPEC-004 retry
> logic produces multiple attempts. The `retried` column counts
> additional explicit-retry attempts beyond the first per
> SPEC-004 v0.3.1; the row order within a `request_id` is
> determined by `id ASC`. This contract is load-bearing for
> SPEC-005 v0.3 multi-attempt attribution.

Add AC-FR-B9-MULTI: deterministic fixture with one request_id and
two attempts; assert two `request_log` rows with the same
`request_id` and distinct `id`.

### Cluster C — SPEC-006 v0.8.2 cross-spec patch (X-1)

Edit `specs/SPEC-006-buyer-api.md` header to bump version to
v0.8.2. Add change-log entry.

#### F-X1: § 17.7 ninth row for SPEC-001 null-usage error states.

**Location:** SPEC-006 v0.8.1 § 17.7 (line 2561ff).

**Fix:** Add one new row to the quota refund and settlement
matrix:

| Status | Completion tokens | Quota debited | Rationale |
|---|---:|---|---|
| SPEC-001 null-usage error (`error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, `error_internal`) | 0 (NULL) | **none** | Provider was reached but performed no countable work; no buyer debit |

Add prose:

> SPEC-001 null-usage errors are distinguished from 502/504 with
> 0 completion (which DO debit prompt only) because the
> null-usage error states indicate the provider returned a
> structured "did not even start work" signal. SPEC-005 v0.3
> § 6.9 mirrors this row with zero provider credit. H-005
> reconciliation requires both sides to agree: buyer 0, provider
> 0.

Add AC-NULL-USAGE-REFUND: deterministic fixture that a 502 with
SPEC-001 `error_model_not_loaded` produces a quota refund of the
full reservation; only the 502 with non-null-error rationale
debits prompt only.

## Output requirements

### SPEC-005 v0.3 deliverables

1. Header version bumped to v0.3 with change log entry.
2. § 1.4 `Depends on:` line updated to SPEC-002 v1.3.4 and
   SPEC-006 v0.8.2.
3. § 4.3 `overshoot_flag` removed; § 5.3 null-operand guard
   added; § 4.5.1 SPEC-007 consumer contract added.
4. § 4.6 column rename to `buyer_equivalent_credits` (additive
   migration); § 4.9 adds MIG-005-008 and MIG-005-009.
5. § 6.8 byte-estimate formula mirrored normatively.
6. § 6.9 null prompt_tokens edge handled.
7. § 10.1 WAL mode + DEFERRED snapshot; § 10.4 grace cutoff;
   § 10.6 out-of-scope crash boundaries.
8. § 11.5 require_provider_tokens fallback documented.
9. § 12 D7 prose updated for overshoot_flag removal.
10. § 13 `settlement.recovery_grace_seconds` added; WAL mode
    requirement.
11. § 17 failure-modes table updated.
12. § 18 new ACs: AC-NULL-PROMPT, AC-WAL, AC-SPEC-007-CONTRACT.
13. Appendix A four new checkboxes.
14. Appendix B D5 anchor row updated.
15. Appendix C `overshoot_flag` entry removed;
    `buyer_equivalent_credits` entry added; `buyer_debit_credits`
    marked deprecated.
16. Appendix G structured into prose vs machine-checkable
    columns.

### SPEC-002 v1.3.4 deliverables

1. Header version bumped to v1.3.4 with change log entry
   summarizing the X-2 bundle.
2. § 7 FR-B9 schema: `error_code TEXT NULL` column added;
   `idx_request_log_ts_utc` and `idx_request_log_request_id_id`
   indexes added; multi-row-per-request_id prose added.
3. New AC: AC-FR-B9-MULTI; new AC for `error_code` population.

### SPEC-006 v0.8.2 deliverables

1. Header version bumped to v0.8.2 with change log entry
   summarizing the X-1 patch.
2. § 17.7 ninth row added (SPEC-001 null-usage error → 0 debit).
3. New AC: AC-NULL-USAGE-REFUND.

## Self-verification checklist

- [ ] SPEC-005 version 0.2 → 0.3 in header.
- [ ] SPEC-005 change log entry references the audit at
      `specs/SPEC-005-r2-audit.md` and counts (0C + 10M + 5m + 3 OQ).
- [ ] § 2 D1-D12 content unchanged from v0.2.
- [ ] All 10 R2-M findings (R2-M1 through R2-M10) have visible
      resolution text in SPEC-005.
- [ ] All 5 R2-n MINOR findings applied.
- [ ] R2-D1, R2-D2, R2-D3 visibly encoded.
- [ ] 3 new SPEC-005 ACs (AC-NULL-PROMPT, AC-WAL,
      AC-SPEC-007-CONTRACT) present in § 18.
- [ ] No new normative content in SPEC-005 beyond what closes
      findings or encodes R2-D1/D2/D3.
- [ ] SPEC-002 version 1.3.3 → 1.3.4 with FR-B9 patch (X-2
      bundle: ts_utc + composite index, error_code column,
      multi-row prose).
- [ ] SPEC-002 v1.3.4 has 2 new ACs (multi-row, error_code).
- [ ] SPEC-006 version 0.8.1 → 0.8.2 with § 17.7 ninth row (X-1).
- [ ] SPEC-006 v0.8.2 has 1 new AC (AC-NULL-USAGE-REFUND).
- [ ] No SPEC-001, SPEC-003, SPEC-004, SPEC-007, SPEC-008 edits.
- [ ] Locked D1-D12 substance unchanged.
- [ ] Cross-spec patches numbered consistently (X-1 for SPEC-006,
      X-2 for SPEC-002).

**Budget:** estimated 550-700 added lines across the three files
(SPEC-005 ~450; SPEC-002 ~80; SPEC-006 ~60). If your edits exceed
~800 added lines or you find yourself adding "improvements" beyond
the R2 audit findings, STOP — those are scope creep. Defer to v0.4.

When done, print a 200-word handback summary:
- Findings closed by cluster (Cluster A: 9 [5 MAJOR + 4 MINOR];
  Cluster B: 3 [X-2 bundle]; Cluster C: 1 [X-1]).
- Any finding you could not close in v0.3 (with rationale).
- New AC count and where they live across the three specs.
- Whether SPEC-005 v0.3 is now READY TO LOCK or needs another
  audit round.

Then stop. Do NOT begin implementation. The operator decides
whether to run a regression-check audit on v0.3 (recommended for
the first cross-spec-bundled fix pass) or proceed to
`BUILD_PHASE5_SPEC_005_PROMPT.md`.

=== END PROMPT ===
```

---

## Cross-spec patches identified

The executing session edits THREE spec files in this fix pass.
Operator review should treat the three together as one atomic
spec bump:

| File | Version | Sections to edit |
|---|---|---|
| `specs/SPEC-005-billing.md` | v0.2 → v0.3 | § 1.4, § 4.3, § 4.5 (+ new § 4.5.1), § 4.6, § 4.9, § 5.3, § 6.8, § 6.9, § 10.1, § 10.3, § 10.4, § 10.6 (new), § 11.3, § 11.5, § 12, § 13, § 17, § 18, Appendices A/B/C/G |
| `specs/SPEC-002-coordinator.md` | v1.3.3 → v1.3.4 | § 7 FR-B9 (request_log schema + indexes + multi-row prose + new ACs) |
| `specs/SPEC-006-buyer-api.md` | v0.8.1 → v0.8.2 | § 17.7 (ninth row) + new AC |

SPEC-007 does not exist yet; the R2-M7 SPEC-007 consumer contract
lives inside SPEC-005 § 4.5.1 as the canonical reference for the
future SPEC-007 author. SPEC-001, SPEC-003, SPEC-004, SPEC-008
are untouched.

## After running this prompt

Operator's review checklist (~45 min — slightly longer than
SPEC-006 v0.2 because three files):

1. `git diff specs/SPEC-005-billing.md` — confirm version bumped,
   change log entry present, § 2 D1-D12 content unchanged.
2. `git diff specs/SPEC-002-coordinator.md` — confirm v1.3.4
   bump, FR-B9 schema patches.
3. `git diff specs/SPEC-006-buyer-api.md` — confirm v0.8.2 bump,
   § 17.7 ninth row only (no other edits).
4. Verify all 10 R2-M findings have visible resolution in
   SPEC-005. Search the diff for each R2-M label.
5. Verify R2-D1, R2-D2, R2-D3 visibly encoded (overshoot_flag
   absent; § 10.6 out-of-scope subsection present; three header
   lines reference each other's v0.3/v1.3.4/v0.8.2).
6. AC count: SPEC-005 § 18 should now have 3 new ACs; SPEC-002 +2;
   SPEC-006 +1. Total +6 across the three specs.
7. No SPEC-001/003/004/007/008 edits. No § 2 substance changes.
   No premium positioning. No reward-multiplier creep into v1.

Then commit. Suggested message:

```
SPEC-005 v0.3 + SPEC-002 v1.3.4 + SPEC-006 v0.8.2: R2 audit closing fixes

Closes 0 CRITICAL + 10 MAJOR + 5 MINOR Claude R2 audit findings from
specs/SPEC-005-r2-audit.md. Three operator decisions locked:
R2-D1 drop overshoot_flag column; R2-D2 disclaim cross-process crash
boundary; R2-D3 bundle three coordinated spec bumps.

SPEC-005 v0.3 internal precision: null prompt_tokens guard, WAL mode +
recovery grace window, SPEC-007 consumer contract (§ 4.5.1),
byte-estimate formula mirrored normatively, buyer_equivalent_credits
rename, cross-process boundaries disclaimed (§ 10.6).

SPEC-002 v1.3.4 cross-spec X-2 bundle: error_code TEXT column on
request_log, ts_utc + (request_id, id) indexes, multi-row-per-
request_id normative.

SPEC-006 v0.8.2 cross-spec X-1 patch: § 17.7 ninth row for SPEC-001
null-usage error states (0 buyer debit; mirrors SPEC-005 § 6.9 zero
provider credit; restores H-005 zero-delta).

6 new acceptance criteria (3 in SPEC-005, 2 in SPEC-002, 1 in
SPEC-006). No upstream wire-protocol edits. Locked § 2 D1-D12
unchanged. SPEC-001/003/004/007/008 untouched.

15/15 R2 findings closed.
```

After commit, decide:

- **Regression audit** (recommended for cross-spec-bundled bumps):
  write `AUDIT_SPEC_005_V0_3_PROMPT.md` narrowly scoped to verify
  the v0.3 + v1.3.4 + v0.8.2 changes don't introduce regressions
  (especially in SPEC-002 schema migration and SPEC-006 § 17.7).
  Codex audits in ~45 min. Likely closes with READY TO BUILD
  verdict.

- **Skip regression, proceed to build**: defensible since v0.2 had
  no architectural CRITICALs and v0.3 is narrow text additions
  plus two narrow cross-spec patches. Risk slightly higher than
  SPEC-006 v0.2's situation because three files change at once.

Either way, SPEC-005 v0.3 lock is the gate for
`BUILD_PHASE5_SPEC_005_PROMPT.md`.
