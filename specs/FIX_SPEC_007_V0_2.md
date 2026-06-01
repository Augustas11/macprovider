# FIX_SPEC_007_V0_2 — Resolve SPEC-007 v0.1 audit blockers and high-impact majors

## Mission

You are revising the SPEC-007 explorer corpus from v0.1 to v0.2. A read-only audit surfaced 3 blockers and 12 majors. Your job is to land the 3 blockers and 2 highest-impact majors with concrete normative edits to the spec files (and one cross-spec edit to SPEC-005). After your pass, SPEC-007 v0.2 MUST be implementable without further open questions in the touched areas.

This task is **spec editing only**. Do NOT modify code under `phase4-coordinator/`, `phase5-gateway/`, or anywhere else. Code follow-up tickets are recorded in the spec, not executed.

## Repo orientation

- Repo root: `/Users/augstar/macprovider-poc`
- Spec corpus lives in `specs/`. House style: `SPEC-NNN-*.md` normative docs; `BUILD_SPEC_*` and `FIX_SPEC_*_VX_Y` for prompts.
- Decision log: `beta/DECISION_CRITERIA.md` (append, do not rewrite existing entries).
- Files you will edit:
  - `specs/SPEC-007-explorer.md` — primary, ~2,485 lines, v0.1 → v0.2.
  - `specs/SPEC-007-operator-decisions.md` — add D15 (gateway bearer model).
  - `specs/SPEC-005-billing.md` — rename "SPEC-007 consumer contract" surface.
- Files you will read for grounding (do NOT edit):
  - `phase4-coordinator/internal/config/config.go` (lines 141–205) — confirms coordinator has no `env:` resolver.
  - `phase5-gateway/internal/config/config.go` (lines 193–205) — gateway `resolveEnvValue`.
  - `phase5-gateway/internal/router/server.go` (lines 128–131, 1898–1904) — existing gateway `/admin/*` auth model.
  - `phase5-gateway/internal/storage/sqlite/migrate.go` (line 75) — `token_source` CHECK enum.
  - `phase4-coordinator/internal/auth/tokens.go` (lines 73–83) — `provider_tokens` schema.

## House style for spec edits

- Normative verbs follow RFC 2119: MUST, MUST NOT, SHOULD, MAY. Keep existing capitalization.
- ASCII-only. No emoji, no smart quotes.
- Section numbering already exists; preserve it. Add subsections (e.g., §7.7, §8.10) without renumbering existing sections.
- Cross-references format: "§5.4", "AC-19", "OQ-2", "D11".
- Update the change-log section (§1.2) with a v0.2 entry naming each fix landed.
- Keep the file readable in 100-column terminals; wrap prose paragraphs.

## Decisions you are authorized to make

Three blockers require a normative decision. Make the call below, write it in, and record it in the change-log and (where applicable) the operator decisions doc. Do not leave OQs open in the touched areas.

### Decision 1 — `explorer.bearer_env` and coordinator env resolution (resolves B-1, OQ-2)

**Decision**: Drop `explorer.bearer_env` from v1 entirely. Pin the explorer bearer to whatever string is in `auth.operator_key` verbatim. Defer coordinator `env:` resolution to a separate follow-up ticket (record it in §17 out-of-scope and in §1.2 change-log as a forward link, NOT as a SPEC-007 v0.2 dependency).

Rationale to write into the spec: D3 already specified bearer reuse; an env-resolver knob inside SPEC-007 would either require new coordinator config-loader plumbing (out of v1 scope) or silently equal `auth.operator_key`, which makes the knob non-functional.

Edits required:
- `specs/SPEC-007-explorer.md` §13.1 config block: remove `bearer_env` field.
- `specs/SPEC-007-explorer.md` §13.4: replace the entire `explorer.bearer_env` subsection with a one-paragraph "Bearer source" subsection stating the explorer reuses `auth.operator_key` verbatim; if the operator wants env-only secret management, a separate (future) coordinator config-resolver work item will land it.
- `specs/SPEC-007-explorer.md` §17 out-of-scope: add a bullet "Coordinator `env:` value resolution for `auth.operator_key`. SPEC-007 v0.2 does not require it; a future infra ticket will add it to `phase4-coordinator/internal/config/config.go` mirroring the existing gateway pattern."
- `specs/SPEC-007-explorer.md` §18 open questions: remove OQ-2.

### Decision 2 — SPEC-005 "SPEC-007 consumer contract" rename (resolves B-2, OQ-1)

**Decision**: Rename the SPEC-005 surface from "SPEC-007 consumer contract" to "payout-rail consumer contract" (placeholder for a future spec). Keep the literal `spec_007_claim` token in the schema CHECK constraint and MIG-005-008 to avoid a migration, but add a footnote in SPEC-005 explaining the literal is reserved for a future payout-rail spec, NOT for SPEC-007 v0.2 read-only.

Rationale to write: SPEC-007 v0.2 is internal/read-only per D11; mutating payout claim is a separate future spec. The SPEC-005 column comments and acceptance criterion currently mislead readers into expecting SPEC-007 v0.2 to mutate `ledger_payout_ready`.

Edits required (in `specs/SPEC-005-billing.md`):
- §1.2 change-log: add a new entry dated 2026-06-01 noting the rename driven by SPEC-007 v0.2 read-only re-scope. Do not delete existing entries.
- §4.5.1: rename "SPEC-007 consumer contract" → "Payout-rail consumer contract" everywhere it appears in the section heading and body. Replace every standalone "SPEC-007 may write" / "SPEC-007 consumer" with "the future payout-rail spec may write" / "the payout-rail consumer".
- §4.5 column comments for `payout_currency`, `payout_external_id`, and the `status` transitions ready→consumed/voided: change "SPEC-007 only" / "SPEC-007 writes" → "future payout-rail spec only" / "future payout-rail spec writes".
- §4.6 `ledger_reconciliation_runs.run_type` CHECK and MIG-005-008 description: leave `spec_007_claim` literal in place; add a footnote (under the table or next to the CHECK definition) "The literal token `spec_007_claim` predates the SPEC-007 v0.2 internal-read-only scope decision. It remains as a reserved enum value for a future payout-rail spec. SPEC-007 v0.2 MUST NOT emit rows with this `run_type`."
- AC-SPEC-007-CONTRACT (around line 1338): rename to `AC-PAYOUT-CLAIM-CONTRACT` and update the body to refer to the future payout-rail spec.
- §1516 acceptance checklist row "SPEC-007 consumer interface defined": rename to "Payout-rail consumer interface defined".

Edits required (in `specs/SPEC-007-explorer.md`):
- §3.9 read-only invariant: add an explicit sentence "SPEC-005 §4.5.1 references a payout-rail consumer that writes `ledger_payout_ready.status` ∈ {consumed, voided}. That consumer is a future spec, NOT SPEC-007 v0.2. SPEC-007 v0.2 MUST NOT execute the payout-rail consumer contract."
- §5.12 settlements: add a normative note "`payout_currency` and `payout_external_id` MUST be returned as `null` in v0.2 because no payout-rail spec is active yet."
- §18 open questions: remove OQ-1.

### Decision 3 — Gateway explorer bearer model (resolves B-3)

**Decision**: Drop the distinct-secret invariant. `GATEWAY_EXPLORER_BEARER` defaults to and SHOULD equal `coordinator.operator_key`. The gateway explorer routes reuse the existing `operatorAuthorized` path in `phase5-gateway/internal/router/server.go:1899`. AC-3 is rewritten to verify the explorer routes accept the coordinator operator bearer (consistent with the rest of `/admin/*`).

Rationale to write: §10.5 already excludes "Compromised coordinator host" from the threat model. The split-secret design only matters under that excluded threat. The existing gateway `/admin/*` surface uses the shared key; introducing a divergence for explorer-only routes is undermotivated and would require AC-3 to refuse configurations that work today.

Edits required (in `specs/SPEC-007-explorer.md`):
- §10.2: rewrite to state "The gateway `/admin/explorer/*` routes MUST authenticate the caller with the same bearer model used by the rest of `phase5-gateway/internal/router/server.go` `/admin/*` routes: `Authorization: Bearer <coordinator.operator_key>`. No distinct gateway-only secret is introduced in v0.2."
- Remove every reference to `GATEWAY_EXPLORER_BEARER` as a distinct env var. If any §13 config knob mentions it, delete it.
- AC-3 (around the auth-startup block in §15): rewrite to "Verify gateway `/admin/explorer/*` routes return 401 when called with a bogus bearer and 200 when called with `coordinator.operator_key`. Verify startup does NOT fail when `coordinator.operator_key` is the only configured admin secret."
- §17 out-of-scope: add a bullet "Migrating gateway `/admin/*` routes to a gateway-side bearer distinct from the coordinator operator key. A future spec MAY introduce that separation across all gateway admin endpoints; SPEC-007 v0.2 reuses the existing shared-key model."

Edits required (in `specs/SPEC-007-operator-decisions.md`):
- Append a new row D15 with the decision text: "Gateway explorer routes reuse `coordinator.operator_key` for v0.2; no distinct `GATEWAY_EXPLORER_BEARER`. Rationale: §10.5 excludes compromised-coordinator threat; existing gateway `/admin/*` surface shares the key; splitting explorer-only secret is undermotivated and would require AC-3 to reject configs that work today. Reconsider when a future spec migrates all gateway admin endpoints to a gateway-side bearer."

### Decision 4 — Buyer email filter semantics (resolves M-1, OQ-3)

**Decision**: Two parameters. `email` is an exact match (case-folded with NFKC + ASCII-lowercase). `email_prefix` is a prefix match (same case-fold). Only one of the two may appear per request; both present MUST return 400.

Edits required (in `specs/SPEC-007-explorer.md`):
- §5.9: rewrite the email filter spec to "`email`: optional, exact match. The server case-folds the parameter and stored row with NFKC + ASCII-lowercase before comparison. The stored row is not modified. `email_prefix`: optional, prefix match with the same case-fold rule. If both `email` and `email_prefix` are present, the endpoint MUST return 400 with `error.code='bad_request'` and `error.detail` identifying the conflict."
- §6.2: mirror the same wording for the gateway buyers list (if that endpoint also accepts email filtering — check whether it does).
- §15 ACs: add AC-29 verifying the semantics. Suggested body:
  > **AC-29 (email filter semantics)**. Seed three accounts with emails `a@x`, `ab@x`, `aB@x`. Request `GET /admin/explorer/buyers?email=ab@x` MUST return exactly one row (the second). Request `email_prefix=a` MUST return all three. Request `email_prefix=aB` MUST return the third only after case-fold. Request with both `email` and `email_prefix` set MUST return 400.
- §18 open questions: remove OQ-3.

### Decision 5 — Window-knob structure (resolves M-2)

**Decision**: Replace the single `max_window_days` global knob with explicit per-endpoint knobs. Document each with its own default and bounds.

Edits required (in `specs/SPEC-007-explorer.md`):
- §13.1 config block: replace `max_window_days` with the following entries (keep alphabetical order with siblings):
  - `activity_max_window_days` — default 7, bounds 1–31.
  - `buyers_max_window_days` — default 31, bounds 1–31.
  - `ledger_max_window_days` — default 31, bounds 1–31.
  - `sessions_max_window_days` — default 7, bounds 1–31.
  - `settlements_max_window_days` — already exists per §13.10; leave at default 180, bounds 31–365.
- §13.10: rewrite the paragraph that bounded `max_window_days` 1–31 to describe each new per-endpoint knob with its bounds, and remove the contradiction with `default_window_hours`.
- Each affected endpoint section (§5.5 sessions, §5.10 buyer detail, §5.11 ledger, §5.14 activity, §6.2/§6.3 gateway counterparts): update the "Maximum window is N days" sentence to reference the corresponding knob by name. Where two sections mention different maxima for related views, reconcile per the per-endpoint table above.
- §13.10 `default_window_hours`: bound it by `min(per-endpoint-max) * 24` or simply drop the global default and add per-endpoint `default_window_hours` knobs paralleling the max knobs. Recommend the latter — symmetric and easier to validate.

## Edits NOT in scope for this pass

Land only the 5 decisions above plus the three change-log entries (one per spec file edited) and the new D15 operator decision. Do NOT touch:
- M-3 through M-12 from the audit (defer to a separate v0.3 reconciliation pass).
- All minors and nits.
- Any code under `phase4-coordinator/`, `phase5-gateway/`, or other directories.
- AC renumbering past AC-29 (the new email-filter AC); preserve existing AC numbers for all other ACs.

If you encounter a finding outside this scope while editing, leave it. Capture it as a comment in the v0.2 change-log entry: "Deferred to v0.3: M-3, M-4, ..."

## Verification checklist (run before declaring done)

1. `grep -n "OQ-1\|OQ-2\|OQ-3" specs/SPEC-007-explorer.md` returns nothing. (OQ-4 stays.)
2. `grep -n "bearer_env\|GATEWAY_EXPLORER_BEARER" specs/SPEC-007-explorer.md` returns nothing.
3. `grep -n "SPEC-007 consumer\|SPEC-007 may write\|SPEC-007 only" specs/SPEC-005-billing.md` returns nothing. (`spec_007_claim` literal stays.)
4. `grep -n "max_window_days" specs/SPEC-007-explorer.md` returns only the per-endpoint variants (no bare `max_window_days`).
5. `grep -n "^## D15\|^D15:" specs/SPEC-007-operator-decisions.md` returns the new row.
6. Each of the three edited spec files has a new v0.2 change-log entry dated 2026-06-01 naming the fixes landed.
7. `wc -l specs/SPEC-007-explorer.md` — note new line count in your summary.
8. ASCII-only check: `LC_ALL=C grep -nP '[^\x00-\x7F]' specs/SPEC-007-explorer.md specs/SPEC-007-operator-decisions.md specs/SPEC-005-billing.md` returns nothing.

## Report back

After edits, output a concise summary covering:
- New line count of each edited file.
- Verification checklist results (pass/fail per item).
- Any decision points you hit that the prompt didn't anticipate, with the call you made and why.
- A one-line readiness statement: "SPEC-007 v0.2 unblocked for BUILD" or, if not, what is still open.

Do not summarize the audit findings themselves — assume the reader has them. Focus the report on what changed and what is verified.
