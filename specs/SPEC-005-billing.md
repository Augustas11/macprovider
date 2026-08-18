# SPEC-005 - Billing, Settlement, and Provider Rewards

**Version:** 0.6.3 (2026-08-18, remaining SPEC-005 conformance unit IDs)
**Depends on:** SPEC-001 v1.2.4, SPEC-002 v1.5.6, SPEC-003 v0.7, SPEC-004 v0.3.2, SPEC-006 v0.9.8, SPEC-024 v0.2.1 (prefix-cache cache-isolation; its billing sections are superseded by this spec)

**Change log v0.6.3 (2026-08-18, issue #1023 — remaining conformance unit IDs):**
- Registers `SPEC-005-R004`..`SPEC-005-R009` in `specs/CONFORMANCE.json` as
  pending anchors for D8 failed-request accounting, settlement/payout-ready,
  multi-attempt attribution, operator endpoints, account-scope identity, and
  quarantine resolutions. No formula, ledger, or payout behavior change.
  `requirement_id_migration` remains `pending`. Do not promote.

**Change log v0.6.2 (2026-08-17, issue #614 — preliminary paid-path conformance unit IDs):**
- Registers `SPEC-005-R001`..`SPEC-005-R003` in `specs/CONFORMANCE.json` as
  pending preliminary conformance anchors for the paid buyer-path #614 slice.
  These IDs group existing normative obligation areas without changing them:
  closed-form credit arithmetic (`R001`), hot-path ledger write (`R002`), and
  crash recovery (`R003`). Remaining SPEC-005 clause migration is issue #1023.
  No formula, ledger, or payout behavior change.

## Preliminary conformance unit IDs

SPEC-005 v0.6.3 registers `SPEC-005-R001`..`SPEC-005-R009` in
`specs/CONFORMANCE.json`. R001–R003 remain the paid-path formula, hot-path,
and crash-recovery units. R004–R009 group additional existing obligation
areas without changing them:

- `SPEC-005-R001` — closed-form credit formula, units, rounding, and rate-card
  resolution (§5).
- `SPEC-005-R002` — hot-path ledger persistence of buyer debit / provider
  credit (§4, §7).
- `SPEC-005-R003` — crash recovery, WAL, and reconcile of in-flight ledger
  rows (§10).
- `SPEC-005-R004` — D8 failed-request accounting (§6).
- `SPEC-005-R005` — settlement cadence, threshold, and payout-ready
  idempotency (§7, §4.5).
- `SPEC-005-R006` — multi-attempt attribution (§8).
- `SPEC-005-R007` — operator and provider ledger endpoints (§11).
- `SPEC-005-R008` — settlement account-scope hashing / identity snapshots
  (§4.8).
- `SPEC-005-R009` — operator quarantine resolutions (§4.10, §10.5).

`requirement_id_migration` remains `pending` until issue #1023 closes.
These IDs are not promoted from this registration.

**Change log v0.6.1 (2026-07-29, B1 — request-log TTFT/decode consumer boundary):**
- Dependency bump: SPEC-002 v1.5.2 → v1.5.6 to acknowledge
  `request_log.ttft_ms` and `request_log.decode_ms`. They are
  coordinator-observed, nullable, read-only observability fields.
  SPEC-005 MAY expose or join them for operational reconciliation, but
  MUST NOT use them in credit arithmetic, payout eligibility, quarantine
  classification, or request-log migrations.

**Change log v0.6 (2026-07-12, money-path reconciliation — runbook item 11; spec-only, reconciled to shipped code):**

v0.6 reconciles SPEC-005 to the shipped billing implementation
(`phase4-coordinator/internal/billing/formula.go`, `store.go`,
`internal/config/config.go`) — the code is the money-path source of truth and any
disagreement is a spec bug. No behavior change. Six reconciliations:

- **§4.3 — six ledger columns added** that ship but were unspecced:
  `charged_prompt_tokens`, `provider_reported_prompt_tokens`, `cached_prompt_tokens`
  (SPEC-024), `settlement_account_scope_hash`, `settlement_policy_mode`,
  `settlement_policy_version`; plus the table-level
  `CHECK(usage_source != 'null_error' OR gross_credits = 0)`.
- **§5.3 — completion clamp (runbook item 2 / audit H1).** The billable completion is
  `min(provider_reported, byte_estimate)`, and when the byte estimate is the smaller value
  on a `provider_reported` row the clamp **downgrades `usage_source` to `byte_estimated`**.
  The byte estimate is `ceil(wire_bytes/16)` (computed upstream in the buyer path). The G1
  ledger probe (2026-07-11, re-confirmed 2026-07-12) measured this clamp as negligible
  (~3–5% of reported rows, ~1-token median, ~$0.001 provider / 35 d), so v0.6 **documents**
  the shipped `/16` clamp rather than reverting the divisor.
- **§5.3 — SPEC-024 prefix-cache split folded in.** Prompt billing splits into
  `uncached = prompt_tokens − cached_prompt_tokens` priced at the prompt rate plus
  `cached_prompt_tokens` priced at the prompt-cache-hit rate. **Default:** an unconfigured
  `prompt_cache_hit_credits_per_mtok` bills cached tokens at the **full prompt rate**
  (no discount) — conservative, never over-discounts (`EffectivePromptCacheHitCreditsPerMtok`).
  A `cached_prompt_tokens > prompt_tokens` (or negative) row is caught by the §5.3.1 hot-path gate as
  an `invalid_cached_prompt_tokens` **quarantine** (zero credit); the §5.3 formula bound and the DB
  CHECK are defense-in-depth backstops. Either way the row pays zero.
- **§5.3 — 10,000,000-token per-field cap.** Any of `prompt_tokens`, `cached_prompt_tokens`,
  or the billable completion exceeding `maxBillableTokens = 10_000_000`, or any
  multiply/add overflow in the numerator, yields `null_usage_error` + zero credits.
- **§5.5 (new) — model-key normalization + rate-card resolution order.** Rate lookup is
  exact key → `NormalizeModelKey` (lowercase/trim, strip a known namespace prefix, strip
  `-mxfp4-q8`/`-4bit`/`-8bit` quant suffixes, canonical `meta-llama`/`nvidia-nemotron`/
  `gpt-oss` remaps) → `default` → empty, emitting `rate_card_normalized`.
- **§13 — rate-card config key** `prompt_cache_hit_credits_per_mtok` added.

SPEC-024's billing **arithmetic** sections — §4 (ledger), §5 (rate card), §6 (formula) — are hereby
**absorbed** into SPEC-005 v0.6 as the canonical home for prefix-cache billing. SPEC-024 **retains**
the provider **wire field** `cached_prompt_tokens` (§3, SPEC-002 addendum) and the **buyer-visible**
mirror (§8, SPEC-006 addendum) — which this spec consumes/prices but does not define — plus the fraud
model (§7) and the cache-**isolation** invariant (§11–§16).

- **R1-audit additions (3-lane codex).** The byte-estimate divisor is the configurable `tier2.output_bytes_per_token_ceiling` (default 16), swept across §6.7/§6.8/§15/AC-DISCONNECT/appendix (the stale `/4` superseded; SPEC-006 §17.7 `/4` flagged as a carried cross-spec drift). Added **§5.3.1** (cache-eligibility gates + NULL⇒COALESCE(0) + the `0<=cache_hit_rate<=prompt_rate` ceiling — SPEC-024 §14 folded in). Added **§7.5a** (settlement-policy `enforce` payout gate) and **§7.5b** (the verified-receipt re-pricing exception that the prior blanket no-update rule contradicted). Reconciled the byte_estimated+nil branch, the bare-`llama-` non-remap, the `rate_card_normalized` log shape, the cache-rate snapshot provenance (rate_card_json, not a §4.3 column), the exact settlement-hash CHECK SQL, and Appendix C's six columns. Amended **SPEC-024 → v0.2.1** to hand billing ownership to this spec (bundled).
- **R2-audit additions (3-lane codex).** Completed the **§7.5b** verified-receipt exception: it also
  re-prices `ledger_operator_credits` (gross/operator/fault) and is scoped to matched, `enforce`-mode,
  verified, unsettled, non-quarantined rows with the receipt-count downward clamp and cache-snapshot
  quarantines; carved the `insert only` rule in §4.1/§4.3/§4.4/Appendix C to name that one exception.
  Added **§5.3.2** (charged-vs-provider-reported **prompt**-token bound — the money-affecting
  `min(provider_reported, coordinator_estimate)` cap analogous to the completion clamp). Specified the
  non-null-error **NULL `prompt_tokens` ⇒ COALESCE(0)** completion-only path (§5.3). Added the two
  shipped `ledger_provider_identity_snapshots` columns (`config_snapshot_id`,
  `provider_reported_prompt_tokens`, §4.8). Reconciled the `cached > prompt` classification to the
  §5.3.1 `invalid_cached_prompt_tokens` quarantine in the changelog + §4.3. Bumped the stale boundary
  labels (SPEC-004 v0.3.1→v0.3.2, SPEC-006 v0.9.1→v0.9.8) and finished the SPEC-024 §1 billing-handoff
  banner. Security lane confirmed 0 C/H/M.
- **R3-audit additions (3-lane codex).** Corrected R2 over-claims against code. **§5.3.2**:
  `provider_reported_prompt_tokens` holds the provider value **or** the coordinator
  `estimateTokens(req.raw)` substitution (not strictly "raw"); the bound is a loose `len(req.raw)/4`
  heuristic (caps gross over-reporting, leaves slack; NULL-bound legacy rows unbounded) — the absolute
  "cannot over-charge" claim removed. **§5.3.1**: disclosed that cache **under**-reporting is
  undetectable (full-rate billing, provider-favorable) and stated the fallback quarantine-preservation
  invariant with the shipped fallback code gap flagged as a carried money-path follow-up. **§7.5b**:
  cached count is read from the existing ledger row (receipt has no cached field), added the
  clamp-below-cached `invalid_cached_prompt_tokens` quarantine branch, and the `settled = 0` **AND**
  `settlement_id IS NULL` guard; carved a one-time additive-migration backfill exception. **D7**:
  clarified quarantine is a reviewable hold, not a final zero-credit. **AC-D3**: cache-hit rate lives
  in the config snapshot, not the credit row. Added **AC-PROMPT-BOUND**. Reconciled the SPEC-024
  handoff to §4–§6 only (wire §3 + buyer-mirror §8 retained by SPEC-024); swept stale SPEC-006 v0.9.1
  pins to v0.9.8; reconciled `ledger_config_snapshots` immutability to by-convention (no shipped
  `UNIQUE(config_hash)`). §5.3 breaker-before-null precedence made explicit.
- **R4-audit corrections (3-lane codex).** All three lanes converged on the **D7 clarification**: R3's
  claim that operator force-credit "restores the legitimate prompt/completion credit" is **false** —
  cache quarantine permanently zeroes credits, force-credit re-admits the row **as-is** (no recompute;
  only §7.5b re-prices), so a force-credited cache-quarantine row pays zero. Retracted the claim;
  reframed the D7 reconciliation on the *unverifiable-report* basis (ambiguous_cache fires only on a
  provider report inconsistent with the coordinator route view) and carried the "zero the cache
  discount vs the whole row" question as an open money-path decision. Fixed the **§4.8**
  identity-snapshot `provider_reported_prompt_tokens` meaning (still said "raw"; now reported-or-
  substituted, matching §4.3) and extended **AC-PROMPT-BOUND** to assert the identity-snapshot mirror.
  Code lane confirmed §5.3.2 provenance/bound, §5.3.1 disclosures, §7.5b, breaker precedence, and
  schema fidelity all PASS.
- **R5-audit corrections (3-lane codex).** Tightened the R4 D7 rewrite, which was still imprecise on
  quarantine mechanics. Corrected two over-broad claims against code: (1) "both ledger tables" — the
  **hot-path** quarantine writes only `ledger_request_credits` and creates **no** operator-credit row
  (only the receipt-time path zeroes both); (2) the universal "cache-quarantine pays zero" — the
  **recovery** path (`recovery.go` flag-only UPDATE) leaves stored credits **intact**, so a pre-credited
  row cache-quarantined by recovery **retains its non-zero credits**. §2.7 now documents all **three**
  quarantine paths with their distinct credit effects, states §7.5b re-pricing skips `quarantined=1`
  rows (cannot restore), and reframes the D7 reconciliation on SPEC-024's **legitimate-but-non-creditable
  reuse** basis (not "dishonest/inconsistent report"). Reconciled SPEC-024's stale "simply withholds the
  discount" / "priced as if cached=0" language (§2/§7/§14) to the shipped whole-row quarantine. Added
  **AC-CACHE-QUARANTINE-CREDIT-EFFECT** and a force-credit-no-recompute assertion to **AC-Q055**.
- **R6-audit corrections (3-lane codex).** All three lanes converged on the completeness of the §2.7
  quarantine taxonomy: the **recovery** path has **two** subpaths, not one — flag-only (row exists,
  credits retained) **and** `insertQuarantineTx` (no row exists → inserts a NEW zero-credit,
  no-operator-row shape like the hot path). §2.7 + AC-CACHE-QUARANTINE-CREDIT-EFFECT now cover all
  **four** write shapes. Architect additionally flagged that SPEC-024 §3 (canonical, non-superseded)
  states an absolute "quarantine MUST zero payable credits" invariant that the recovery **flag-only**
  path does not enforce — reconciled by keeping §3 as the intended invariant and documenting the
  recovery flag-only retention as a **shipped deviation** (carried code follow-up: recovery flag-only
  should zero stored credits), with a cross-referenced caveat in SPEC-024 §3 and the fixed AC-CI-5
  wording. Non-§2.7 checks (clamps, caps, cache ceiling, rate resolution, snapshot immutability) PASS.
- **R7-audit corrections (3-lane codex).** All lanes confirmed the four-shape taxonomy **complete and
  accurate** ("no fifth cache-quarantine credit mutation"); residual fixes were text-consistency and one
  adjacent path: (1) the SPEC-024 §3 deviation caveat now applies to **both** quarantine bullets
  (`ambiguous_cache` + `invalid_cached_prompt_tokens`) as a shared paragraph (recovery flag-only touches
  both); (2) **AC-CI-5** de-conflicted — the **retry** case is NOT quarantined (nulled + full prompt
  rate), distinct from the non-hit/range quarantine cases; (3) **§5.3** now notes the out-of-range
  `null_usage_error` classification is the **formula/hot-path** behavior, while **recovery** reconciles
  the same out-of-range prompt/completion as an **`invalid_usage_tokens`** quarantine sharing the §2.7
  two-subpath structure (flag-only retains / insert zeroes); §2.7 cross-references it. **Carried code
  follow-up (LOW):** the shipped `internal/billing` tests assert the four AC shapes only partially (hot
  path/recovery-insert check gross but not all rates/provider credits; no test asserts recovery flag-only
  credit retention; AC-Q055 doesn't snapshot unchanged credits) — a test-hardening task, not a spec gap.
- **R8-audit corrections (3-lane codex).** Core (four shapes, §3 caveat, AC-CI-5) confirmed PASS by all
  lanes. Refined the R7 `invalid_usage_tokens` note against code: (1) **completion carve-out** (code +
  security + architect) — an out-of-range **completion** is `invalid_usage_tokens` only when there is **no
  valid in-range estimate**; with a clampable in-range estimate the completion is priced at the estimate
  (mirrors the §5.3 clamp), NOT quarantined (`invalidRecoveryCompletion`); prompt/estimate out-of-range
  and completion `<0` still always quarantine. (2) **recovery cache-snapshot strictness** (code) — a
  positive first-attempt cache row requires the identity snapshot's **exact `config_snapshot_id`** and
  quarantines **`missing_cache_config_snapshot`** if absent (does not fall back to the §10.2 timestamp
  lookup); documented in §10.2. (3) **force-credit is not reason-gated** (security) — shipped §11.6.1
  accepts any `quarantined=1` row regardless of reason, so §2.4's "integrity reasons MUST stay
  quarantined" is operator policy, not code-enforced; reconciled at §2.4 + §11.6.1, carried a
  reason-allowlist policy follow-up. **Carried LOW (security):** the recovery orphan pass can display an
  earlier `missing_request_log` reason instead of `invalid_usage_tokens` (COALESCE preserves the first
  reason) — money stays quarantined, only the operator-visible reason can mislead; a diagnostic follow-up.
- **R9-audit corrections (3-lane codex).** All three lanes flagged that two R8 fixes had landed **only in
  the changelog**, not the normative text — a concurrent audit lane running in the worktree had reverted
  those two working-tree edits before the R8 commit. Both are now applied to the normative sections (and
  the extra locations that repeat the same claims): (1) the **completion carve-out** — a >10M completion
  with a valid in-range estimate is clamped, not quarantined — now in the **§5.3** recovery note, **§2.7**
  intro, and the **§5.4** 10M example; (2) the **recovery cache-snapshot strictness** (exact
  `config_snapshot_id`, `missing_cache_config_snapshot`, no timestamp fallback for positive first-attempt
  cache rows) now in **§10.2** and **§10.4**. Also fixed a stale **§11.6.1** cross-reference ("§2.4" →
  the v0.3.3 "Quarantine rule narrowing" changelog) and softened the overstated "monotonic-quarantine
  **schema** invariant" to application-enforced (the schema CHECK only constrains `quarantined IN (0,1)`,
  not the transition). Process fix: never edit this worktree while an audit lane is running in it.
- **R10-audit corrections (3-lane codex).** Architect lane **PASSED 0 C/H/M**; the completion carve-out
  confirmed normative by all lanes. Corrected the **snapshot-selection precedence** (code + security): my
  R9 wording said non-cache recovery rows use timestamp-qualified selection, but code uses the **exact
  identity-linked `config_snapshot_id` for EVERY row when present** — the timestamp-qualified latest
  snapshot is only the **fallback when that id is absent**, and a positive first-attempt cache row
  quarantines `missing_cache_config_snapshot` instead of falling back. Fixed in **§4.7**, **§10.2**, and
  **§10.4**. LOW fixes: **§4.1** now lists `updated_at_utc` among recovery-updatable columns (matches
  §2.7/§4.3); the remaining "monotonic-quarantine **schema** invariant" in normative **§4.10** softened to
  application-enforced.
- **R11-audit corrections (3-lane codex).** The R10 identity-first fix added correct new paragraphs but
  left **two stale timestamp-primary sentences** that now self-contradicted them (architect HIGH; code +
  security MED): §4.7's immutability rationale ("Recovery selects a snapshot by `effective_at_utc`
  ordering") and §10.2's original "Recovery rows use the latest ... `effective_at_utc`" line — both
  removed/corrected to the identity-first precedence. LOW: softened §4.7's absolute "never UPDATEs"
  snapshot-immutability wording to allow the startup `effective_at_utc` **format normalization**
  (semantic-preserving, never a priced-value change); annotated the two non-normative stale copies
  (`GOAL_SPEC_005_IMPL.md`, `BUILD_SPEC_005_IMPL_PROMPT.md`) with a v0.6 supersession pointer rather than
  rewriting the historical stubs.

**Change log v0.5 (2026-07-08, issue #253 — force-credit + pre-payout hold + corrective resolution):**

v0.5 lands the force-credit arm that v0.4 deliberately deferred.
The new surface is intentionally coupled to a pre-payout hold so an
operator mistake can be corrected before SPEC-016 consumes a
`ledger_payout_ready` row for real-money payout.

- **New force-credit endpoint (§11.6.1).**
  `POST /admin/ledger/quarantine/{request_credit_id}/force-credit`
  uses the same operator-key, JSON validation, rate-limit bucket,
  same-transaction audit, and route-layer invisibility posture as
  force-void. It emits `ledger_quarantine_force_credit`.
- **Pre-payout hold.** A successful force-credit writes
  `force_credit_matures_at_utc = created_at_utc +
  billing.force_credit_settlement_hold_seconds`. The default is
  86400 seconds (24h). Until that timestamp has elapsed, the
  quarantined row remains excluded from `spec022_payable_request_credits`
  and therefore cannot enter §7 settlement or SPEC-016 payout.
- **Persisted correction deadline.** Every resolution row also writes
  `correction_deadline_at_utc`. Corrective eligibility is evaluated
  against that persisted deadline, not against a later hot-reloaded
  hold value.
- **UNIQUE relaxation and latest-row projection (§4.10).**
  `UNIQUE(request_credit_id)` is removed. Resolution rows are
  append-only history. Readers that need the current state MUST use
  the latest row by `(created_at_utc DESC, id DESC)`.
- **Corrective-resolution rule.** The handler permits at most one
  opposite-kind corrective resolution during the hold window
  (`force_credit -> force_void` before `force_credit_matures_at_utc`,
  or `force_void -> force_credit` before the prior row's persisted
  `correction_deadline_at_utc`).
  Same-kind repeats and third resolutions return HTTP 409
  `already_resolved`; corrections after the window return HTTP 409
  `resolution_locked`.
- **Settlement snapshot ordering (§7).** The settlement sweep MUST
  acquire a SQLite `BEGIN IMMEDIATE` transaction before computing the
  payable-row snapshot, and MUST materialize one fixed eligible source
  set before inserting or updating `ledger_payout_ready`. Force-credit
  maturity and corrective mutations cannot interleave with
  payout-ready materialization or mutate the already-computed source
  set.
- **Existing payout-ready interaction.** If a force-credit matures
  after a prior settlement window has already produced a
  `ledger_payout_ready` row, the row MUST NOT mutate that old payout.
  It rolls forward as an unsettled payable row and can be captured by
  the next settlement sweep whose `window_end_utc` is after the row's
  original `ts_utc`.
- **First-class open-quarantine list.**
  `GET /admin/ledger/quarantine?status=open` returns unresolved
  quarantined rows. A row with any resolution history is no longer
  "open"; held force-credit rows are resolved-but-not-yet-payable.
- **SPEC-007 explorer projection.** Explorer-style reads MUST separate
  current state from history after UNIQUE relaxation: the current
  resolution is the latest row; full history is an ordered collection.
- **Acceptance.** AC-Q040 and AC-Q043 are updated for history-capable
  resolution rows; AC-Q055 now verifies held force-credit exclusion
  and post-maturity payable inclusion.

**Change log v0.4 (2026-06-29, issue #169 — manual quarantine VOID admin surface, partial §OQ-5 close; force-credit + pre-payout hold deferred to v0.5):**

**Scope cut after R1+R2+R3 codex audit.** The three rounds of
audit converged on a fundamental issue: `force-credit` is unsafe
in v0.4 without a pre-payout hold primitive, because SPEC-016 USDC
payout is a real-money path that consumes `ledger_payout_ready`
rows; any mistaken `force_credit` flows to chain payout within one
settlement window. v0.4 therefore ships ONLY the `force-void`
endpoint — voiding a quarantined row never produces money-out.
Force-credit and the pre-payout hold ship together in v0.5 as a
coordinated design (issue to be filed); v0.5 also lifts the
UNIQUE constraint to allow a corrective resolution within the hold
window. §OQ-5 is PARTIALLY closed by v0.4 (the operational
need to clear false-positive quarantines from the open count is
satisfied); the full close moves to v0.5.

- **New table `ledger_quarantine_resolutions` (§4.10).** Records the
  operator-issued force-void decision for a quarantined
  `ledger_request_credits` row. The base row's `quarantined=1` marker
  remains immutable (preserves the v0.3.3 monotonic-quarantine
  invariant; operators MUST NOT execute direct `UPDATE` on the base
  row). One resolution per quarantined row, terminal, via
  `UNIQUE(request_credit_id)`. The `resolution_kind` enum reserves
  `force_credit` as a value but v0.4 IMPL MUST reject INSERTs with
  that value (CHECK constraint) — v0.5 will lift the constraint.
- **One new admin endpoint (§11.6).** `POST /admin/ledger/quarantine/{request_credit_id}/force-void`.
  Gated behind the operator key (same posture as the existing
  `/admin/ledger/*` GETs per §11). Body carries the operator-supplied
  reason string (1..500 chars; v0.4 §11.6.4 validation rules).
  Idempotent at the row level: any second POST returns HTTP 409 with
  the existing resolution row in the response body. v0.4 does NOT
  support resolution flips or amendments. Schema immutability of the
  resolution makes the audit trail unambiguous.
- **Aggregation queries narrowed (§11.1 / §11.2 / §11.3).** v0.4's
  force-void does NOT add a row to the payable set — the
  pre-v0.4 `quarantined=0` filter remains correct for
  `total_provider_credits` / `total_operator_credits` /
  `provider_gross_credits`. What v0.4 narrows is the
  `quarantined_count` reader (§11.1 / §11.2 / §11.3): it MUST now
  use the `OPEN_PREDICATE` (§11.6.5) which excludes force-voided
  rows. Force-voided rows are a third state — present in the base
  table with `quarantined=1`, present in
  `ledger_quarantine_resolutions` with `resolution_kind='force_void'`,
  but counted as neither payable nor open.
- **Two new audit-log event types (§16.5 + §11.6.4).**
  `ledger_quarantine_force_void` is written to the existing
  `audit_log` table on every successful 200 from §11.6.1, severity
  WARN. `billing_config_flag_changed` is written on every
  hot-reload-acknowledged change to
  `billing.quarantine_resolution_force_void_enabled`, severity
  WARN. Both go through the billing store's `*sql.Tx` (not
  `audit.Store.Insert`) to share atomicity with the operational
  write. v0.4 reserves the `ledger_quarantine_force_credit`
  event-type name for v0.5; v0.4 IMPL MUST NOT emit it.
- **SPEC-007 explorer surface (§11.6.5).** The quarantined-row
  detail view (SPEC-007 explorer) is amended to LEFT JOIN
  `ledger_quarantine_resolutions` and surface the resolution kind
  / operator / reason / timestamp when present. v0.4 does NOT
  mandate a "Resolve" UI button; UI scope is owned by the operator
  portal repo. The single POST endpoint is the normative interface;
  any UI surface composes on top of it.
- **§OQ-5 partially resolved.** v0.4 closes the void-arm of §OQ-5
  ("Manual quarantine resolution"); the credit-arm moves to v0.5
  along with the pre-payout hold primitive. Pointer:
  `docs/OPEN_QUESTIONS.md` row `SPEC-005/OQ-5` — flip to PARTIAL
  with issue #169 (void-arm landed) / v0.5 tracking issue
  (credit-arm pending).
- **Acceptance.** AC block (§18 AC-Q040, Q042–Q045, Q047–Q051,
  Q053, Q055) covers: schema (table shape, UNIQUE, CHECK
  including the v0.4 `resolution_kind IN ('force_void')` carve-
  out), force-void happy path (Q042), idempotent UNIQUE conflict
  (Q043), exhaustive validation matrix including Unicode bidi /
  zero-width / default-ignorable (Q044), reader-side narrowing
  (Q045 — `OPEN_PREDICATE` excludes voided rows), same-transaction
  audit atomicity (Q047), method enforcement (Q048), 64-thread
  concurrent UNIQUE-conflict mapping (Q049), SPEC-007 explorer
  alias visibility (Q050), reconcile `rows_force_resolved_in_range`
  field (Q051 — `delta_gross_credits` unchanged because force-void
  doesn't shift the payable sum), route-layer config-flag gate
  with config-flip audit event (Q053), v0.4 force-credit schema-
  level rejection (Q055).
- **Audit-round summary.** R1 / R2 / R3 three-lane codex audit
  (see `specs/SPEC-005-v0-4-r1-audit.md` for the R1→R2 narrative)
  converged on the structural finding that force-credit is unsafe
  in v0.4 without the v0.5 pre-payout hold primitive. v0.4 cuts
  force-credit to ship a smaller, safer surface: force-void only,
  route-layer-gated, with the immutable-resolution UNIQUE
  constraint preserved. v0.5 will land force-credit + pre-payout
  hold + UNIQUE-relaxation for corrective resolutions together as
  one coordinated design (separate tracking issue to be filed).
- **Deferred to v0.5:** force-credit endpoint, pre-payout hold
  (~24h default delay between resolution commit and §7 sweep
  eligibility), corrective-resolution rule (lifting UNIQUE during
  hold), SPEC-016 USDC payout interaction text, settlement-sweep
  snapshot ordering, existing-payout-ready interaction, mistaken-
  resolution operator runbook, first-class
  `GET /admin/ledger/quarantine?status=open` list endpoint,
  **SPEC-007 explorer current-vs-history projection** (the v0.4
  LEFT JOIN in §11.6.5 projects exactly one resolution row per
  base row because of the v0.4 UNIQUE constraint; v0.5's UNIQUE
  relaxation turns the join into one-to-many, so v0.5 MUST define
  whether the explorer surfaces the latest resolution, the entire
  history, or both via separate columns). All become coherent
  once the v0.5 hold primitive exists.

**Change log v0.3.3 (2026-06-29, issue #168 — SPEC-002 v1.5.2 monotonic `attempt_n` adoption, closes §OQ-1):**
- Dependency bump: SPEC-002 v1.5.1 → v1.5.2 to absorb the new
  `request_log.attempt_n` column (zero-based monotonic ordinal
  populated at INSERT time by the writer, scoped to
  `(account_id, request_id)` under SQLite `IS`).
- **Row-mapping rule promotion.** §8.2 / §10.4 / §15.2 attempt-
  ordinal derivation MUST prefer `request_log.attempt_n` exact match
  when non-NULL. When NULL (legacy pre-SPEC-002-v1.5.2 row OR
  rollback window), the derivation falls back to the v0.3.1 id-ASC
  arithmetic within the same `(account_id, request_id)` group under
  SQLite `IS` clustering. Both paths produce byte-identical ordinals
  because the writer's INSERT-time COUNT and the fallback's read-time
  COUNT compute the same value over the same row set; v0.3.3 just
  persists it.
- **Quarantine rule narrowing.** v0.3.1's "row 3+ MUST be quarantined
  until SPEC-002 gains monotonic `attempt_n`" rule is satisfied as of
  SPEC-002 v1.5.2 — both via the persisted `attempt_n` column AND via
  the byte-identical id-ASC fallback derivation. Row 3+ in BOTH the
  v1.5.2 write path and the legacy NULL-`attempt_n` fallback path
  receives a stable `attempt_n=2, 3, ...` ordinal and is credited
  normally on a fresh reconciliation pass.

  The only remaining steady-state quarantine class is `attempt_n=1`
  with `retried=0` — legitimate retry without an explicit `retried`
  marker. Cannot be safely distinguished from a buggy duplicate
  insert; quarantined for operator review per §OQ-5 (issue #169).
- **Pre-existing quarantine rows are immutable.** Quarantine rows
  written under the v0.3.1 row-3+ rule BEFORE the SPEC-005 v0.3.3
  IMPL deploy remain in their existing quarantined=1 state. The
  ledger schema constrains `quarantined` to a `0 → 1` monotonic
  transition; SPEC-005 v0.3.3 does NOT introduce an unquarantine
  flow. **Operator action is required to resolve these legacy
  quarantines** — the SPEC-005 §OQ-5 force-credit / force-void admin
  surface (issue #169) is the natural counterpart. v0.3.3 closes the
  quarantine **CREATION** class for row 3+; resolution of pre-existing
  quarantines is out of scope and tracked in #169. **Operators MUST
  NOT execute direct `UPDATE ledger_request_credits SET quarantined=0`
  SQL** — that violates the monotonic-quarantine invariant
  (application-enforced: the schema CHECK only constrains `quarantined
  IN (0,1)`, not the 0→1-only transition, so a direct `SET quarantined=0`
  is not DB-blocked and would immediately re-enter the payable
  projection), bypasses the §OQ-5 audit-log requirement, and risks crediting a row
  that was legitimately quarantined for a non-row-3+ reason. The
  current quarantine reason strings (per `internal/billing/recovery.go`
  and `internal/billing/settlement.go`) include: `ambiguous_attempt_n`
  (the row-3+ class — only attempts before v0.3.3 IMPL are now
  affected), `missing_request_log`, `missing_provider_identity`,
  `missing_config_snapshot`, `invalid_usage_tokens`,
  `reconciliation_mismatch`, `operator_split_mismatch`, and
  `conflicting_settlement_id` — only the first should ever be
  candidates for an unquarantine flow; the others reflect real
  invariant violations and (as an operator-policy stance) should stay
  quarantined. **Shipped reality (v0.6):** #169 landed the §11.6.1
  force-credit resolution flow, which is **NOT reason-gated** — it can
  re-admit any quarantined row regardless of reason (see §11.6.1 "Not
  reason-gated"). So this "should stay quarantined" is operator policy,
  **not** a code-enforced restriction; a reason allowlist is a carried
  follow-up. The prohibition on direct `UPDATE ... SET quarantined=0`
  SQL still stands (that bypasses the §OQ-5 audit log entirely).
- **Acceptance.** On a backfilled deployment (`attempt_n` populated
  everywhere) the quarantine count from the row-3+ class drops to
  zero on a fresh nightly reconciliation pass. The v0.3.1 fallback
  path and the v0.3.3 `attempt_n` path remain valid in IMPL code
  during the migration window (no big-bang).
- **Cross-spec.** Closes the SPEC-005 §OQ-1 long-tail item. The
  §OQ-5 admin surface (force-credit / force-void) remains a
  separate open item for the legitimate-retry-without-marker
  ambiguity class (issue #169).
- No new SPEC-002 indexes; `attempt_n` is a per-row ordinal, not a
  join key. The SPEC-002 v1.5.1 per-key migration-state machine is
  unchanged. SPEC-002 v1.5.2 adds a parallel **per-column** migration
  state (`legacy | populating | populated`) for `attempt_n`,
  observable via the new `coordinator backfill-attempt-n --check
  --format json` subcommand.

**Change log v0.3.2 (2026-06-29, issue #197 — SPEC-002 v1.5.1 dependency bump + per-key migration-state contract):**
- Dependency bump: SPEC-002 v1.5.0 → v1.5.1 to absorb the per-key
  `legacy | unindexed | indexed` migration-state machine. The §10.4
  "production startup MUST fail the schema check" sentence below is
  reworded to read the per-key state instead of the prior binary
  legacy/migrated model. Schema-check failure conditions are now:
  - any depended-on composite reconciliation key in state `legacy`
    (column absent) → production reconciliation MUST fail closed;
  - any depended-on composite reconciliation key in state `unindexed`
    (column present, partial-NULL composite index absent) →
    production reconciliation MUST fail closed unless an explicit
    bounded `--allow-unindexed-scan` override is provided (operator
    response: run `coordinator migrate-indexes`).
  Scope is by **data-surface contract, not process placement**: this
  binding governs any reconciliation surface that performs **closing-
  the-books joins** between coordinator `request_log` and gateway
  `usage_events` / `audit_events` (the SPEC-005 v0.3+ contract) —
  out-of-process harnesses AND any future coordinator-hosted endpoint
  that exposes the same join. The coordinator's own in-process
  `RecoverLedger`, admin reconcile, and hot-path AttemptN paths
  derive ordinals via single-table SQLite `IS` clustering and are
  correct (just unindexed-slow) under state `unindexed`; they do NOT
  fail closed during the daemon-startup rollout window. No code
  change in this version.

**Change log v0.3.1 (2026-06-29, issue #211):**
- Dependency bump: SPEC-002 v1.3.4 → v1.5.0 and SPEC-006 v0.8.2 → v0.9.1
  to absorb the coordinator-side account-scoped reconciliation key
  introduced in #211 (follow-up to #196). No new normative billing
  rate / formula change; §4.2 and §8.2 fallback-attempt-ordinal
  derivation text updated in-place to group rows by
  `(account_id, request_id)` under SQLite `IS` semantics. Under `IS`
  a NULL-`account_id` row clusters with NULL-`account_id` rows
  only — it does NOT mix with non-NULL `account_id` rows that
  happen to share the same `request_id`. This preserves the
  pre-v0.3.1 intra-NULL grouping for legacy rows while keeping
  all three IMPL sites (`hotpath.go`, `recovery.go`, and
  `endpoints.go` admin reconcile) consistent on the same
  derivation contract. Per ISS-211 R1/R2/R3/R4 audit convergence.

**Triage note 2026-06-26 (no version bump, no normative change):**
- §OQ-2 (round-half-to-even) and §OQ-3 (24h/7d recovery windows) marked RESOLVED inline as implicitly confirmed by sustained production traffic. Pointer: `docs/OPEN_QUESTIONS.md` 2026-06-26 triage row for SPEC-005. OQ-1 / OQ-4 / OQ-5 remain open and are routed to follow-up issues per the ledger.

**Change log v0.3:**
- 2026-06-01 SPEC-007 v0.2 cross-spec fix: renames the misleading settlement
  consumer surface to the payout-rail consumer contract. The `spec_007_claim`
  enum literal remains reserved for a future payout-rail spec; SPEC-007 v0.2 is
  internal-read-only and MUST NOT emit it.
- Fixed the Claude R2 audit at `specs/SPEC-005-r2-audit.md` (0 CRITICAL, 10 MAJOR, 5 MINOR, 3 operator questions) with a narrow v0.3 pass.
- Encodes R2-D1 by dropping the phantom quota-overshoot column and preserving D7 as a no-clawback rule.
- Encodes R2-D2 by explicitly disclaiming cross-process gateway crash boundaries in section  10.6.
- Encodes R2-D3 by bundling SPEC-002 v1.3.4 and SPEC-006 v0.8.2 cross-spec patches.
- Encodes R2-D4 by disabling `/providers/{provider_id}/earnings` at the route layer when `auth.require_provider_tokens = false`.
- Adds null-prompt/null-completion guards, WAL-mode and recovery-grace requirements, payout consumer contract, byte-estimate formula mirroring, and `buyer_equivalent_credits` reconciliation naming.

**Change log v0.2:**
- Fixed R1 M-1 by adding D1-D12 normative references outside section  2.
- Fixed R1 M-2 and GATE 2 Q-2 with `ledger_provider_identity_snapshots`.
- Fixed R1 M-3 and GATE 2 Q-1 with `ledger_config_snapshots`.
- Fixed R1 M-4 and GATE 2 Q-3 with deterministic `request_log.id ASC` fallback quarantine.
- Fixed R1 M-5 by completing section  11 JSON endpoint contracts and rate-limit posture.
- Fixed R1 M-6 by adding behavior-level deterministic AC-D1 through AC-D12 fixtures.
- Fixed R1 M-7 by specifying zero-tolerance H-005 gross reconciliation.
- Fixed R1 M-8 by removing unreachable provider-not-reached usage_source rows.

**Change log v0.1:**
- Initial draft following `specs/design/spec-005/SPEC-005-design.md` and `specs/design/spec-005/SPEC-005-operator-decisions.md`.
- Encodes D1-D12 as read-only locked decisions in section  2.
- Defines the coordinator-side provider-credit ledger, weekly settlement-ready batch, recovery algorithm, and four JSON endpoints.
- Closes H-005 by mirroring SPEC-006 v0.8.1 section  17.7 with deterministic provider-credit formulas.

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
It emits `ledger_payout_ready` rows that a future payout-rail spec may later consume.
### 1.2 In scope

- Provider-credit ledger rows written by the coordinator.
- Operator-credit rows that preserve the D5 split.
- Weekly settlement-ready rows for future payout-rail consumption.
- Coordinator-local recovery and reconciliation scans.
- Four JSON visibility endpoints from D11.
- No-live-network acceptance criteria and deterministic fixtures.
- Rate-card configuration in coordinator.yaml.
- H-005 closure against SPEC-006 section  17.7.

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

This section implements the locked billing and unit decisions (D1)(D6) and the SPEC-007 boundary by keeping SPEC-005 to internal coordinator credits and payout-ready handoff only.

### 1.4 Cross-spec boundaries

**SPEC-001 v1.2.4:**
- frozen Phase 3 binary wire format.
- usage object has prompt_tokens, completion_tokens, total_tokens.
- cancel usage is authoritative for v1.2.4+ providers.
- SPEC-005 MUST NOT require new provider fields.
**SPEC-002 v1.5.6:**
- coordinator owns request_log and provider auth.
- request_log is read-only to SPEC-005.
- request_log carries deterministic `error_code` for SPEC-001 null-usage errors.
- request_log has `ts_utc`, `(request_id, id)`, `external_request_id` (partial-NULL), and `(account_id, external_request_id)` (partial-NULL composite) indexes for reconciliation scans and attempt fallback. (Composite index added in v1.5.0 / issue #211.)
- per-key migration state `legacy | unindexed | indexed` is exposed by `coordinator migrate-indexes --check --format json`. SPEC-005 reconciliation tooling that performs **closing-the-books joins** between coordinator `request_log` and gateway `usage_events` / `audit_events` MUST consume this state and fail closed on any depended-on key in state `legacy` or `unindexed` (v0.3.2 / issue #197).
- each provider attempt for a repeated request_id has its own request_log row.
- request_log carries `account_id` (v1.5.0 / issue #211). The composite `(account_id, request_id)` is the grouping key for attempt-ordinal derivation; SQLite `IS` semantics preserve the pre-v1.5.0 grouping for legacy NULL-`account_id` rows.
- request_log carries `attempt_n` (v1.5.2 / issue #168). Zero-based monotonic ordinal populated at INSERT time by the writer within the same `(account_id, request_id)` group. SPEC-005 v0.3.3 reads this directly when non-NULL; falls back to id-ASC derivation when NULL (legacy / rollout window). Both paths produce byte-identical ordinals.
- request_log carries nullable `ttft_ms` and `decode_ms` (v1.5.6 / B1). SPEC-005 treats them as read-only observability fields, never billing formula inputs.
- FR-P11a supplies fault categories.
- FR-P12 supplies provider bearer-token auth.
- FR-R3 distinguishes stable provider_id from assigned_id.
- FR-R4 excludes non-ready providers from routing.
**SPEC-003 v0.7:**
- provider onboarding is stranger-readable.
- provider docs must be honest that rewards/billing were deferred to SPEC-005.
- SPEC-005 docs must avoid cash-payout promises.
**SPEC-004 v0.3.2:**
- smart-router attempts must preserve accounting.
- retried is a fallback but not a full attempt ordinal.
- FR-SR-18 composes routing with FR-P11a and eligibility checks.
- (v0.3.2) FR-SR-2 provider-visibility carve-out permits the coordinator to hand the derived,
  account-scoped `conv:` key to the provider for prefix caching — a SPEC-024 isolation concern with
  no billing-boundary impact here.
**SPEC-006 v0.9.8:**
- gateway has no billing state.
- section  17.7 is the buyer-debit source of truth.
- section  17.7 includes the SPEC-001 null-usage error row with zero buyer debit.
- SPEC-005 mirrors the matrix. (Cross-spec drift carried: SPEC-006 §17.7 still divides by `/4` where
  SPEC-005 §6.8 uses the configurable default `/16`; reconciliation is a tracked follow-up, §6.8.)
- gateway MUST forward `X-MacProvider-Account` + upstream `Authorization` bearer on every chat forward (issue #211); the coordinator persists the account into `request_log.account_id` for SPEC-005's attempt-ordinal grouping rule.
**SPEC-007 future:**
- owns AntFeed and USDC conversion.
- consumes payout-ready rows.
- may populate payout_currency later.
**SPEC-008 v0.3 informational:**
- attestation_class is nullable storage only.
- no v1 reward multiplier may use attestation_class.

## 2. Locked decisions

This section reproduces the operator pre-commitments from `specs/design/spec-005/SPEC-005-operator-decisions.md`.
It is read-only. It records decisions; it does not reopen them.
Any change to D1-D12 requires operator review and a reopened SCOPE stage.

### 2.1 D1 - Billing model

**Operator decision:** **D** - donation-only; no tip jar in v1; SPEC-005 ledger tracks provider credits only, not buyer revenue; no Stripe, no checkout, no credit card collection.
**Normative effect:** Implementations MUST satisfy D1 exactly as written.
**Reference discipline:** Later sections may cite D1; they MUST NOT weaken it.

### 2.2 D2 - Settlement cadence

**Operator decision:** **A** - real-time accrue + weekly settlement-ready batch UTC Monday 00:00; `settlement.cadence_days: 7` in coordinator.yaml; in-process goroutine (no new ops surface).
**Normative effect:** Implementations MUST satisfy D2 exactly as written.
**Reference discipline:** Later sections may cite D2; they MUST NOT weaken it.

### 2.3 D3 - Provider reward formula

**Operator decision:** **B** - per-model rate card with global multiplier; initial rates (placeholder, tuned once live traffic data available): 7B models = 1,000,000 prompt / 2,000,000 completion credits per Mtok; 3B models = 500,000 prompt / 1,000,000 completion credits per Mtok; default fallback = 3B rates; `global_multiplier: 1.0`; rate card stored in coordinator.yaml (git-auditable), NOT in database; unknown models fall back to default.
**Normative effect:** Implementations MUST satisfy D3 exactly as written.
**Reference discipline:** Later sections may cite D3; they MUST NOT weaken it.

### 2.4 D4 - Minimum payout threshold

**Operator decision:** **B** - $0.50 nominal = 500,000 credits (using 1 credit = $0.000001); `settlement.min_payout_credits: 500000` in coordinator.yaml; sub-threshold credits roll forward to next weekly cycle (`settled=0`); configurable for SPEC-007 gas calibration.
**Normative effect:** Implementations MUST satisfy D4 exactly as written.
**Reference discipline:** Later sections may cite D4; they MUST NOT weaken it.

### 2.5 D5 - Revenue split

**Operator decision:** **B** - 90/10 global; `rewards.provider_share: 0.90`; stored as `provider_share_bps=9000` INTEGER on every `ledger_request_credits` row at creation time (historical splits immutable); operator share recorded as `ledger_operator_credits`; not publicly exposed in v1 but visible in per-provider earnings endpoint.
**Normative effect:** Implementations MUST satisfy D5 exactly as written.
**Reference discipline:** Later sections may cite D5; they MUST NOT weaken it.

### 2.6 D6 - Currency / unit

**Operator decision:** **B** - internal credits; 1 credit = 1 micro-dollar = $0.000001; all columns INTEGER, never FLOAT; all credit arithmetic is integer arithmetic; a future payout-rail spec converts credits to USDC at payout time; `payout_currency` column on `ledger_payout_ready` is nullable for that future spec to populate.
**Normative effect:** Implementations MUST satisfy D6 exactly as written.
**Reference discipline:** Later sections may cite D6; they MUST NOT weaken it.

### 2.7 D7 - Buyer balance enforcement

**Operator decision:** **A** - hard limit at account-day boundary per SPEC-006 section 17.7 (not re-implemented in SPEC-005); provider is credited for actual reported usage regardless of buyer quota state; provider is never zero-credited for legitimate completed work.
**Normative effect:** Implementations MUST satisfy D7 exactly as written.
**Reference discipline:** Later sections may cite D7; they MUST NOT weaken it.

**Clarification — cache quarantine vs D7, honest shipped behavior (v0.6).** A cache quarantine
(`ambiguous_cache`, `invalid_cached_prompt_tokens`) always sets `quarantined = 1`, but its effect on
**stored credits depends on which code path applies** — there is **no** universal "cache-quarantined
rows pay zero" guarantee. (The recovery subpaths below carry the same structure for the
`invalid_usage_tokens` out-of-range reason — subject to the §5.3 completion carve-out, where a >10M
completion with a valid in-range estimate is clamped, not quarantined — see §5.3's recovery-path note.)
Four effects across three paths:
- **Hot-path** quarantine (`hotpath.go`, first-write): the formula result is **zeroed**, the row is
  inserted with zero credits, and the path **returns before inserting any `ledger_operator_credits`
  row** — so a hot-path cache-quarantine row stores zero and has **no** operator-credit row.
- **Receipt-time** quarantine (§7.5b, on a row that was `quarantined = 0`): **zeroes both**
  `ledger_request_credits` and the existing linked `ledger_operator_credits` row (`settlement_receipts.go`).
- **Recovery** quarantine (`recovery.go`) has **two** subpaths, chosen by whether a ledger row already
  exists for the `(request_id, attempt_n)`:
  - **Existing row** (`quarantineExistingLedgerForRequestAttemptTx`): a **flag-only** UPDATE of
    `quarantined` / `quarantine_reason` / `updated_at_utc` — it does **NOT** modify stored credits. A row
    already credited **non-zero** therefore **retains its non-zero credits**.
  - **No existing row** (`insertQuarantineTx`): recovery **inserts a NEW** quarantined
    `ledger_request_credits` row with **all rates and credits zero**, `quarantined = 1`, and **no**
    `ledger_operator_credits` row — i.e. the same zero-credit/no-operator-row shape as the hot path.

**Force-credit never recomputes.** Force-credit (§11.6.1) inserts a resolution and re-admits the row to
the payable projection **as-is** (`quarantine.go` / `store.go` payable view); force-void voids it;
settlement sums the **stored** amounts (`settlement.go`). So a force-credited cache-quarantine row pays
exactly what is stored: **zero** for the hot-path / receipt-time / recovery-insert cases, but the
**original non-zero** for a recovery **flag-only** row (pre-existing non-zero credits). §7.5b re-pricing —
the only runtime re-price — **selects only
`quarantined = 0` rows** (`settlement_receipts.go`), so it operates *before* quarantine and **cannot**
restore an already-quarantined row. An earlier draft's claim that force-credit "restores the legitimate
prompt/completion credit" is **false** and is retracted; so is the over-broad "permanently pays zero"
claim (the recovery flag-only path is the counterexample).

**Note — the recovery flag-only path deviates from the intended invariant.** SPEC-024 §3 (the canonical,
non-superseded cache wire contract) states the *intended* rule: an `ambiguous_cache` /
`invalid_cached_prompt_tokens` quarantine MUST set payable credit fields to 0 and never produce
provider-creditable credits. The recovery **flag-only** subpath does **not** honor that invariant — it
leaves a pre-existing row's stored non-zero credits in place, so a subsequent force-credit can pay them.
This is a **shipped deviation** from the SPEC-024 §3 zero-payable rule, not intended behavior; it is
tracked with the "unify the quarantine credit effect" follow-up below (the fix is for recovery flag-only
to also zero the stored credits). v0.6 documents the deviation honestly rather than restating an
invariant the code does not uniformly enforce.

Reconciliation with D7 (which forbids zero-crediting *legitimate completed work*): a positive
`cached_prompt_tokens` on a non-sticky-hit route is **not** necessarily a dishonest report — per
SPEC-024 §2/§7/§14 the provider reports its **actual** reuse without seeing `sticky_result`, so the
value can be **legitimate reuse that merely lacks sticky billing provenance** (`ambiguous_cache` is a
billing-eligibility decision, not a wire violation). The tension with D7 is real: the shipped **hot-path
and receipt-time** quarantines zero the **whole row** (not just the un-creditable cache discount), which
*can* zero legitimate uncached-prompt + completion work. **Carried design follow-up:** whether an
ambiguous/invalid cache signal should zero only the **cache discount** (re-price `cached = 0`, still
paying the legitimate uncached-prompt + completion credit) rather than the entire row — and whether the
four quarantine write shapes (hot-path, receipt-time, recovery flag-only, recovery insert) should be
**unified** to one credit effect (in particular, recovery flag-only zeroing stored credits to honor the
SPEC-024 §3 invariant) — is an open money-path decision (a code change gated by the G-series probe + a
`beta/DECISION_CRITERIA.md` entry). v0.6 **documents** the shipped path-dependent behavior; it does not
ratify it as optimal.

### 2.8 D8 - Failed-request accounting

**Operator decision:** **Recommended** - 1:1 mapping to SPEC-006 section 17.7 D3 matrix for every request state: null-usage error paths (`error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, `error_internal`) -> 0 provider credit; buyer cancel with reported usage -> full credit per actual tokens; provider-not-reached -> 0 credit. Closes H-005 by construction.
**Normative effect:** Implementations MUST satisfy D8 exactly as written.
**Reference discipline:** Later sections may cite D8; they MUST NOT weaken it.

### 2.9 D9 - Crash recovery policy

**Operator decision:** **B** - request_log JOIN + ledger rows written in the same SQLite transaction (ACID); coordinator startup scans last 24h for uncommitted ledger rows; nightly goroutine reconciles 7-day window; no 2PC; recovery algorithm must be deterministic and testable without live network.
**Normative effect:** Implementations MUST satisfy D9 exactly as written.
**Reference discipline:** Later sections may cite D9; they MUST NOT weaken it.

### 2.10 D10 - Multi-provider attribution

**Operator decision:** **B** - per-attempt credit; each attempt row in `request_log` has its own `provider_id` and `attempt_n`; `ledger_request_credits` keyed by `(request_id, attempt_n, provider_id)`; mirrors SPEC-006 per-attempt debit exactly; winner-takes-all explicitly rejected.
**Normative effect:** Implementations MUST satisfy D10 exactly as written.
**Reference discipline:** Later sections may cite D10; they MUST NOT weaken it.

### 2.11 D11 - Operator dashboard scope

**Operator decision:** **B** - all four JSON endpoints in v1: `GET /admin/ledger/summary`, `GET /admin/ledger/providers`, `GET /admin/ledger/reconcile`, `GET /providers/{id}/earnings`; no charts; no Slack/email; provider endpoint authenticated via existing FR-P12 bearer tokens; no new auth surface required.
**Normative effect:** Implementations MUST satisfy D11 exactly as written.
**Reference discipline:** Later sections may cite D11; they MUST NOT weaken it.

### 2.12 D12 - Fraud floor for degraded providers

**Operator decision:** **C** - zero credit for requests fault-classified under FR-P11a; full earnings restored after recovery preflight passes; `degraded` and `unavailable` states receive no traffic so earning rate is moot; no reduced-credit tier in v1; no extended re-warmup penalty beyond recovery preflight.
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
- Settlement may update settled and settlement_id only — **except** verified-receipt finalization
  (§7.5b, v0.6), the one sanctioned re-price of token/credit/usage/fault columns on `enforce`-mode
  verified rows.
- Recovery may update quarantined, quarantine_reason, and the accompanying updated_at_utc only.
- Migrations are additive and idempotent.

### 4.2 request_log read-only contract

SPEC-005 reads request_id, ts_utc, model, provider_assigned_id, prompt_tokens, completion_tokens, total_tokens, status, stream, error, error_code, provider_header, retried, and (v0.3.1) account_id.
SPEC-005 never changes these columns.
**SPEC-005 v0.3.3 / SPEC-002 v1.5.2 (issue #168):** the D10 `attempt_n` need is satisfied by `request_log.attempt_n` (monotonic, populated at INSERT time within each `(account_id, request_id)` group under SQLite `IS`). SPEC-005 reads `attempt_n` directly when non-NULL; falls back to the legacy id-ASC derivation when NULL (rollout window). Both paths produce byte-identical ordinals.
**SPEC-005 v0.6.1 / SPEC-002 v1.5.6 (B1):** `request_log.ttft_ms` and `request_log.decode_ms` are nullable coordinator-observed provider timing fields. SPEC-005 MAY read them for operator diagnostics, but MUST NOT use them to compute credits, provider rewards, settlement readiness, or quarantine reasons.

Legacy fallback (NULL `attempt_n` only — pre-v1.5.2 rows OR rollback window): group rows that share the same `(account_id, request_id)` under SQLite `IS`, then order each group by `request_log.id ASC`. Under `IS` a NULL-`account_id` row clusters with NULL-`account_id` rows only — it does NOT cluster with non-NULL rows that happen to share `request_id`. Row 1 becomes `attempt_n=0`. Row 2 becomes `attempt_n=1` only when `request_log.retried` indicates an explicit retry. **Row 3+ in the fallback path is also assigned a stable monotonic ordinal (`attempt_n=2, 3, ...`) and is credited normally** — the prior v0.3.1 "row 3+ MUST be quarantined" rule is satisfied by the deterministic id-ASC derivation. Quarantining is reserved for the legitimate-retry-without-explicit-marker class (`attempt_n=1` with `retried=0`).

If rows cannot be ordered uniquely within their `(account_id, request_id)` group (a SQLite invariant violation; should never occur because `id INTEGER PRIMARY KEY AUTOINCREMENT` is strictly monotonic), all ambiguous rows MUST be quarantined.
SPEC-005 resolves stable provider_id through `ledger_provider_identity_snapshots`; it MUST NOT require ALTER request_log.

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
| `prompt_tokens` | INTEGER | NULL CHECK(prompt_tokens IS NULL OR prompt_tokens >= 0) | prompt tokens (the value priced by §5.3) | insert only |
| `charged_prompt_tokens` | INTEGER | NULL CHECK(charged_prompt_tokens IS NULL OR charged_prompt_tokens >= 0) | prompt tokens actually billed — the §5.3.2 bounded value `min(attributed, PromptTokenUpperBound)`, equal to `prompt_tokens` (diagnostic) | insert only |
| `provider_reported_prompt_tokens` | INTEGER | NULL CHECK(provider_reported_prompt_tokens IS NULL OR provider_reported_prompt_tokens >= 0) | prompt count attributed to the provider before the §5.3.2 bound: the provider's reported value, or the coordinator's `estimateTokens(req.raw)` substitution when the provider omitted it (diagnostic) | insert only |
| `cached_prompt_tokens` | INTEGER | NULL CHECK(cached_prompt_tokens IS NULL OR (cached_prompt_tokens >= 0 AND cached_prompt_tokens <= prompt_tokens)) | prefix-cache-reused prompt tokens (SPEC-024), priced at the cache-hit rate in §5.3 | insert only |
| `completion_tokens` | INTEGER | NULL CHECK(completion_tokens IS NULL OR completion_tokens >= 0) | reported completion tokens | insert only |
| `estimated_completion_tokens` | INTEGER | NULL CHECK(estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0) | byte-estimated completion tokens | insert only |
| `usage_source` | TEXT | NOT NULL CHECK(usage_source IN ('provider_reported','byte_estimated','null_error')) | usage source | insert only |
| `prompt_rate_per_mtok` | INTEGER | NOT NULL CHECK(prompt_rate_per_mtok >= 0) | rate snapshot | insert only |
| `completion_rate_per_mtok` | INTEGER | NOT NULL CHECK(completion_rate_per_mtok >= 0) | rate snapshot | insert only |
| `global_multiplier_ppm` | INTEGER | NOT NULL CHECK(global_multiplier_ppm >= 0) | multiplier snapshot | insert only |
| `gross_credits` | INTEGER | NOT NULL CHECK(gross_credits >= 0) | pre-split credits | insert only |
| `provider_share_bps` | INTEGER | NOT NULL CHECK(provider_share_bps BETWEEN 0 AND 10000) | share snapshot | insert only |
| `provider_credits` | INTEGER | NOT NULL CHECK(provider_credits >= 0) | provider net credits | insert only |
| `fault_flag` | TEXT | NOT NULL DEFAULT 'none' CHECK(fault_flag IN ('none','breaker_qualifying','null_usage_error')) | fault diagnostic | insert only |
| `attestation_class` | TEXT | NULL | SPEC-008 future-proofing | insert only |
| `settled` | INTEGER | NOT NULL DEFAULT 0 CHECK(settled IN (0,1)) | settlement marker | 0 to 1 only |
| `settlement_id` | INTEGER | NULL | ledger_payout_ready id | set once |
| `quarantined` | INTEGER | NOT NULL DEFAULT 0 CHECK(quarantined IN (0,1)) | operator-review marker | 0 to 1 only |
| `quarantine_reason` | TEXT | NULL | quarantine explanation | set by recovery |
| `settlement_account_scope_hash` | TEXT | NULL CHECK(settlement_account_scope_hash IS NULL OR (length(settlement_account_scope_hash) = 64 AND settlement_account_scope_hash NOT GLOB '*[^0-9a-f]*')) | 64-lowercase-hex account-scope hash for settlement partitioning | insert only |
| `settlement_policy_mode` | TEXT | NOT NULL DEFAULT 'legacy' CHECK(settlement_policy_mode IN ('legacy','observe','enforce')) | settlement-policy rollout mode at insert time | insert only |
| `settlement_policy_version` | TEXT | NULL | settlement-policy version tag | insert only |
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

Table-level CHECK: `CHECK(usage_source != 'null_error' OR gross_credits = 0)` — when `usage_source = 'null_error'`, `gross_credits` MUST be 0 (DB-enforced). The hot path and recovery MUST enforce this before the formula in section  5.3 would otherwise evaluate nullable operands.

**Cache column CHECK.** `cached_prompt_tokens` additionally CHECKs `cached_prompt_tokens <= prompt_tokens` at the DB layer. A `cached > prompt_tokens` (or negative) value is caught **first** on the hot path by the §5.3.1 eligibility gate as an **`invalid_cached_prompt_tokens` quarantine** (zero credit, cache field cleared, usage source otherwise preserved) — not as `null_usage_error`; the §5.3 formula's cached-bound rejection and this DB CHECK are defense-in-depth backstops for a path that reaches the formula/insert without the §5.3.1 gate. Either way the row is zero-credit. (See §5.3.1 for the authoritative precedence.)

**Insert-only exception (v0.6).** The `insert only` update rule on `prompt_tokens`,
`charged_prompt_tokens`, `completion_tokens`, `estimated_completion_tokens`, `usage_source`,
`gross_credits`, `provider_credits`, and `fault_flag` is subject to the single verified-receipt
re-price of §7.5b (`enforce`-mode verified rows only); `updated_at_utc` is the "bounded update"
column that records it. Separately, a **one-time additive migration backfill** (§4.9) MAY populate a
newly-added nullable column (e.g. `charged_prompt_tokens`, `provider_reported_prompt_tokens`) on
pre-existing rows without touching any credit amount. No other post-insert mutation is permitted.

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

**Insert-only exception (v0.6).** As with `ledger_request_credits`, the `insert only` rule on
`gross_credits`, `operator_credits`, and `fault_flag` is subject to the §7.5b verified-receipt
re-price, which UPDATEs the linked operator-credit row (`WHERE request_credit_id = ?`) so the
operator split tracks the re-priced gross. No other post-insert mutation is permitted.

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
| `payout_currency` | TEXT | NULL | future payout-rail spec reserved; SPEC-005 writes NULL | future payout-rail spec only |
| `payout_external_id` | TEXT | NULL | future payout-rail spec reserved; SPEC-005 writes NULL | future payout-rail spec only |
| `status` | TEXT | NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','consumed','voided')) | payout row status | future payout-rail spec writes after ready |
| `idempotency_key` | TEXT | NOT NULL | rerun-safe key | insert only |
| `created_at_utc` | TEXT | NOT NULL | creation time | insert only |

Indexes and uniqueness constraints:
- `UNIQUE(provider_id, window_start_utc, window_end_utc)`
- `UNIQUE(idempotency_key)`
- `INDEX idx_lpr_provider_status(provider_id, status, window_end_utc)`
- `INDEX idx_lpr_status(status, window_end_utc)`

#### 4.5.1 Payout-rail consumer contract

**Status transition graph:** `ready` -> `consumed` (terminal); `ready` -> `voided` (terminal); no reverse transitions; no transitions out of `consumed` or `voided`. SPEC-005 writes only `ready`; the future payout-rail spec may write `consumed` or `voided`.

**JSON projection schema** consumed by payout-rail readers:

```text
{
  "id": int,
  "provider_id": string,
  "window_start_utc": ISO8601,
  "window_end_utc": ISO8601,
  "provider_credits": int,
  "min_payout_credits": int,
  "idempotency_key": string,
  "status": "ready"|"consumed"|"voided",
  "payout_currency": string|null,
  "payout_external_id": string|null
}
```

**Claim pattern** (normative, race-safe):

```sql
UPDATE ledger_payout_ready
   SET status = 'consumed',
       payout_external_id = ?,
       payout_currency = ?
 WHERE id = ? AND status = 'ready';
```

The payout-rail consumer MUST check the affected-row-count: if 0, the claim raced or the row is no longer `ready`; the payout-rail consumer MUST NOT pay.

**Audit trail:** every status mutation MUST also insert one row into `ledger_reconciliation_runs` with `run_type = 'spec_007_claim'`, populating `from_utc/to_utc` from the payout window and `status = 'complete'` or `'failed'`. The existing CHECK constraint on `ledger_reconciliation_runs.run_type` MUST be extended in MIG-005-008 to include `'spec_007_claim'`.

### 4.6 Table `ledger_reconciliation_runs`

| Column | Type | Constraint | Meaning | Update rule |
|---|---|---|---|---|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | local row id | insert only |
| `run_type` | TEXT | NOT NULL CHECK(run_type IN ('startup_scan','nightly_reconcile','admin_reconcile','spec_007_claim')) | caller type | insert only |
| `from_utc` | TEXT | NOT NULL | inclusive scan start | insert only |
| `to_utc` | TEXT | NOT NULL | exclusive scan end | insert only |
| `request_log_rows_scanned` | INTEGER | NOT NULL CHECK(request_log_rows_scanned >= 0) | source row count | insert only |
| `missing_credit_rows_created` | INTEGER | NOT NULL CHECK(missing_credit_rows_created >= 0) | recovery count | insert only |
| `orphan_credit_rows_quarantined` | INTEGER | NOT NULL CHECK(orphan_credit_rows_quarantined >= 0) | quarantine count | insert only |
| `buyer_equivalent_credits` | INTEGER | NOT NULL CHECK(buyer_equivalent_credits >= 0) | SPEC-005-internal buyer-equivalent total | insert only |
| `provider_gross_credits` | INTEGER | NOT NULL CHECK(provider_gross_credits >= 0) | ledger gross total | insert only |
| `reconciliation_delta_credits` | INTEGER | NOT NULL | provider minus buyer gross | insert only |
| `started_at_utc` | TEXT | NOT NULL | run start | insert only |
| `finished_at_utc` | TEXT | NULL | run finish | set once |
| `status` | TEXT | NOT NULL CHECK(status IN ('running','complete','failed')) | run status | running to final |
| `error` | TEXT | NULL | failure text | set on failure |
| `created_at_utc` | TEXT | NOT NULL | creation time | insert only |

Footnote: The literal token `spec_007_claim` predates the SPEC-007 v0.2
internal-read-only scope decision. It remains as a reserved enum value for a future
payout-rail spec. SPEC-007 v0.2 MUST NOT emit rows with this `run_type`.

Indexes and uniqueness constraints:
- `INDEX idx_lrr_type_started(run_type, started_at_utc)`
- `INDEX idx_lrr_range(from_utc, to_utc)`

Legacy `buyer_debit_credits` from v0.2 is deprecated after MIG-005-009. New rows MUST write NULL to the deprecated column when it exists and MUST write `buyer_equivalent_credits`.

### 4.7 Table `ledger_config_snapshots`

| Column | Type | Constraint | Meaning | Update rule |
|---|---|---|---|---|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | local row id | insert only |
| `effective_at_utc` | TEXT | NOT NULL | first timestamp covered by this config | insert only |
| `config_hash` | TEXT | NOT NULL | canonical hash of applied SPEC-005 config | insert only |
| `provider_share_bps` | INTEGER | NOT NULL CHECK(provider_share_bps BETWEEN 0 AND 10000) | provider share snapshot | insert only |
| `global_multiplier_ppm` | INTEGER | NOT NULL CHECK(global_multiplier_ppm >= 0) | multiplier snapshot | insert only |
| `rate_card_json` | TEXT | NOT NULL | canonical rate-card JSON | insert only |
| `created_at_utc` | TEXT | NOT NULL | creation time | insert only |

Indexes and uniqueness constraints:
- `INDEX idx_lcs_effective_at(effective_at_utc)`

**Snapshot immutability is by-convention, not DB-enforced (v0.6 reconciliation).** Earlier drafts
specified `UNIQUE(config_hash)`; the **shipped** schema deliberately has **no** uniqueness or
immutability constraint on `ledger_config_snapshots`, and a migration removes the legacy unique index
(`store.go`) so that an unchanged config re-inserts an identical-hash snapshot on each startup (this is
required by the append-on-restart behavior). Insert-only immutability of the **priced values**
(`rate_card_json`, `provider_share_bps`, `global_multiplier_ppm`) is therefore a **convention** the
coordinator upholds; it is not a database guarantee. The one exception is a startup **normalization**
that may `UPDATE ledger_config_snapshots.effective_at_utc` to a canonical timestamp format (`store.go`)
— this preserves the same semantic instant and never changes a priced value. No remote or API path
mutates a snapshot, so the absence of a DB constraint is defense-in-depth drift rather than a
demonstrated risk. Recovery snapshot **selection** follows the identity-first precedence below (and
§10.2/§10.4), not a bare `effective_at_utc` ordering.

The coordinator MUST insert a config snapshot on startup and whenever a valid SPEC-005 config reload is acknowledged.
Recovery prices historical rows from the **exact `ledger_provider_identity_snapshots.config_snapshot_id`** the row was priced under at insert **when that id is present** (all rows, cache and non-cache); the timestamp-qualified "latest snapshot whose effective_at_utc ≤ request_log.ts_utc" rule is the **fallback used only when that id is absent** (§10.2/§10.4). A positive first-attempt cache row is the exception that does **not** fall back — it quarantines `missing_cache_config_snapshot` when the exact id is absent.
If no snapshot can be selected for a recoverable row, recovery MUST quarantine instead of pricing with current config.

### 4.8 Table `ledger_provider_identity_snapshots`

| Column | Type | Constraint | Meaning | Update rule |
|---|---|---|---|---|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | local row id | insert only |
| `request_id` | TEXT | NOT NULL | joins request_log.request_id | insert only |
| `attempt_n` | INTEGER | NOT NULL CHECK(attempt_n >= 0) | zero-based attempt ordinal | insert only |
| `provider_assigned_id` | TEXT | NOT NULL | session-scoped serving provider id | insert only |
| `provider_id` | TEXT | NOT NULL | stable SPEC-002 FR-R3 provider id | insert only |
| `resolved_from` | TEXT | NOT NULL CHECK(resolved_from IN ('pool_entry','response_header','admin_recovery')) | identity source | insert only |
| `pool_session_started_at_utc` | TEXT | NULL | active session start if known | insert only |
| `config_snapshot_id` | INTEGER | NULL CHECK(config_snapshot_id IS NULL OR config_snapshot_id > 0) | `ledger_config_snapshots.id` the row was priced under; §5.5/§7.5b use it to reconstruct the historical cache-hit rate during verified-receipt re-pricing | insert only |
| `provider_reported_prompt_tokens` | INTEGER | NULL CHECK(provider_reported_prompt_tokens IS NULL OR provider_reported_prompt_tokens >= 0) | prompt count attributed to the provider before the §5.3.2 bound — the provider's reported value, or the coordinator's `estimateTokens(req.raw)` substitution when omitted (diagnostic; mirrors the `ledger_request_credits` column, §4.3) | insert only |
| `created_at_utc` | TEXT | NOT NULL | creation time | insert only |

Indexes and uniqueness constraints:
- `UNIQUE(request_id, attempt_n, provider_assigned_id)`
- `INDEX idx_lpis_request(request_id, attempt_n)`
- `INDEX idx_lpis_provider(provider_id, created_at_utc)`

The hot path MUST write this snapshot in the same SQLite transaction as request_log, ledger_request_credits, and ledger_operator_credits.
Provider-not-reached rows with provider_assigned_id NULL MUST NOT write an identity snapshot.
Recovery MUST use this snapshot when request_log lacks stable provider identity.

### 4.9 Migration ordering

- MIG-005-001 creates ledger_request_credits.
- MIG-005-002 creates ledger_operator_credits.
- MIG-005-003 creates ledger_payout_ready.
- MIG-005-004 creates ledger_reconciliation_runs.
- MIG-005-005 creates ledger_config_snapshots.
- MIG-005-006 creates ledger_provider_identity_snapshots.
- MIG-005-007 validates request_log columns by read-only introspection.
- MIG-005-008 extends `ledger_reconciliation_runs.run_type` to include
  `spec_007_claim` as a reserved enum value for a future payout-rail spec.
- MIG-005-009 adds `ledger_reconciliation_runs.buyer_equivalent_credits INTEGER`, backfills it from `buyer_debit_credits`, and deprecates `buyer_debit_credits` as write-NULL for new rows.
- MIG-005-010 creates `ledger_quarantine_resolutions` per §4.10
  (SPEC-005 v0.4, issue #169). The migration MUST be `CREATE TABLE IF
  NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` only — no backfill, no
  touch on existing ledger_request_credits rows. Idempotent under
  re-run (production restart). On a fresh coordinator install the
  table is created empty; on an upgrade install no pre-v0.4
  quarantine row carries a resolution row, which is the intended
  v0.4 semantic (operator MUST issue the resolution explicitly per
  §11.6).
- MIG-005-011 widens `ledger_quarantine_resolutions` for v0.5
  (issue #253): `resolution_kind` permits `force_void` and
  `force_credit`; `UNIQUE(request_credit_id)` is removed;
  `force_credit_matures_at_utc` and `correction_deadline_at_utc` are
  present; `idx_lqr_request_latest` exists. This migration MUST run
  transactionally. On SQLite versions where altering CHECK/UNIQUE
  constraints requires a rebuild, the implementation MUST rebuild via
  create-copy-count-check-rename inside one transaction and recover
  safely from an interrupted prior attempt before making further
  schema changes.
- No SPEC-005 migration alters request_log.

### 4.10 Table `ledger_quarantine_resolutions`

Added by SPEC-005 v0.4 (issue #169) and widened by v0.5
(issue #253) to record operator-issued resolutions for a
quarantined `ledger_request_credits` row. The base row's
`quarantined=1` marker remains immutable — this table records the
OUTCOME of operator review without violating the v0.3.3
monotonic-quarantine invariant (application-enforced; the schema
CHECK only constrains `quarantined IN (0,1)`, not the 0→1-only
transition). v0.5 supports `force_void`
and `force_credit`; force-credit rows are held from settlement until
`force_credit_matures_at_utc`.

| Column | Type | Constraint | Meaning | Update rule |
|---|---|---|---|---|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | local row id | insert only |
| `request_credit_id` | INTEGER | NOT NULL REFERENCES ledger_request_credits(id) | quarantined row being resolved | insert only |
| `resolution_kind` | TEXT | NOT NULL CHECK(resolution_kind IN ('force_void','force_credit')) | operator's resolution | insert only |
| `operator_id` | TEXT | NOT NULL CHECK(length(operator_id) BETWEEN 1 AND 64) | self-asserted operator identity; the SCHEMA enforces only length; endpoint-layer validation (§11.6.1, §11.6.4) is authoritative for charset, trim, and UTF-8 | insert only |
| `resolution_reason` | TEXT | NOT NULL CHECK(length(resolution_reason) BETWEEN 1 AND 500) | operator-supplied justification; SCHEMA enforces only length; endpoint-layer validation (§11.6.4) is authoritative for sanitization | insert only |
| `created_at_utc` | TEXT | NOT NULL | resolution time (RFC3339Nano) | insert only |
| `force_credit_matures_at_utc` | TEXT NULL | populated for `force_credit`; NULL for `force_void` | earliest time the force-credited row may enter `spec022_payable_request_credits` / settlement | insert only |
| `correction_deadline_at_utc` | TEXT | NOT NULL | final time an opposite-kind correction may be appended for this resolution | insert only |

Indexes and uniqueness constraints:
- v0.5 removes `UNIQUE(request_credit_id)`. The table is append-only
  history. The handler enforces the current lifecycle rule: zero or
  one initial resolution, plus at most one opposite-kind correction
  within the hold window. Readers that need current state MUST use
  the latest row ordered by `(created_at_utc DESC, id DESC)`.
- `INDEX idx_lqr_kind_created(resolution_kind, created_at_utc)` —
  covers operator-facing audit-of-resolutions browsing.
- `INDEX idx_lqr_request_latest(request_credit_id, created_at_utc DESC, id DESC)` —
  covers latest-resolution projection and current-state joins.

**Schema choice rationale (v0.4).** The separate
`ledger_quarantine_resolutions` table — instead of adding a
`resolution_kind` column to `ledger_request_credits` — exists to
preserve the v0.3.3 monotonic-quarantine invariant on the base
row. A column on `ledger_request_credits` would either need to
break the insert-only/0→1-only update rule, or would force a
schema-version bump on the base table for every future
resolution-related field. The separate table also keeps the
audit-of-resolutions browse path (`idx_lqr_kind_created`) on a
narrow table with no money-path index contention. v0.5+ may
reconsider if v0.5's expanded resolution surface (force-credit +
hold + corrective-resolution) and any future operator-lifecycle
extensions (defer, split, amend) require schema changes; until
then the simpler two-table shape stays.

**Schema invariants (v0.5).**
- v0.5 does NOT introduce an update path. The columns are insert-only.
  Mistakes are
  corrected by appending one opposite-kind corrective row inside the
  hold window, NOT by mutating prior history.
- `correction_deadline_at_utc` is set at resolution INSERT time using
  the then-effective hold duration. Later config reloads MUST NOT
  shorten or extend an already-inserted row's correction window.
- `resolution_kind` enum is constrained to
  `{'force_credit', 'force_void'}`. Additional kinds (e.g. `defer`,
  `split`) are not planned.
- The base `ledger_request_credits` row referenced by
  `request_credit_id` MUST have `quarantined=1` at resolution time.
  The hot path MUST enforce this at the endpoint layer (§11.6.2)
  BEFORE the INSERT, because a foreign-key check alone would not
  catch a non-quarantined target.
- The resolution does NOT modify the base row. Force-void remains
  non-payable. Force-credit becomes payable only when it is the
  latest resolution and its `force_credit_matures_at_utc` has elapsed.

## 5. Units and arithmetic

This section implements the locked formula, split, unit, and failed-request accounting decisions (D3)(D5)(D6)(D8) by defining integer-only request pricing, immutable split arithmetic, and the shared formula used by hot-path, recovery, and reconciliation rows.

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

The shipped formula is `ComputeCreditsWithCache` (`internal/billing/formula.go`). It applies, in
order: (1) fault/null short-circuits, (2) the completion clamp, (3) the token-validity gates,
(4) the cache-split prompt numerator, (5) the multiplier + split.

```text
# (1) short-circuits (no arithmetic on NULL operands) — EVALUATED IN THIS ORDER:
#   (1a) fault_flag = 'breaker_qualifying'  => return immediately, fault_flag stays 'breaker_qualifying'
#   (1b) usage_source = 'null_error'        => fault_flag := 'null_usage_error', return
# breaker is checked FIRST (formula.go), so a row that is both breaker-qualifying and null_error keeps
# fault_flag = 'breaker_qualifying'. Either way: gross = provider = operator = 0 (rate columns still
# snapshotted).

# (2) completion clamp — billable completion is the SMALLER of reported and byte-estimate.
#     byte_estimate = ceil(wire_bytes / tier2.output_bytes_per_token_ceiling) (default 16, §6.8).
#     The selection is BRANCHED ON usage_source (billableCompletion, formula.go):
#
#   usage_source == 'byte_estimated':
#       estimate == NULL                      => 0        (even if a reported value exists)
#       reported != NULL and reported < est   => reported (stays 'byte_estimated')
#       otherwise                             => estimate
#   usage_source == 'provider_reported':
#       reported == NULL, estimate == NULL    => 0
#       reported == NULL, estimate present    => estimate  (CLAMP: downgrade usage_source -> 'byte_estimated')
#       estimate == NULL                      => reported
#       estimate < reported                   => estimate  (CLAMP: downgrade usage_source -> 'byte_estimated')
#       otherwise                             => reported
#
# i.e. a provider_reported row whose byte-estimate is the smaller value is CLAMPED and its
# usage_source is DOWNGRADED to 'byte_estimated'; a negative reported/estimate is a null_usage_error
# (exception: on a byte_estimated row with a NULL estimate the selection short-circuits to 0 before a
# negative reported value is inspected — an edge `usageFor` construction makes effectively unreachable).

# (3) validity gates — any failure => usage_source='null_error', gross=provider=operator=0
#   - prompt_tokens, cached_prompt_tokens, effective_completion_tokens each in [0, 10_000_000]
#     (maxBillableTokens); a value <0 or >10_000_000 is a null_usage_error
#   - cached_prompt_tokens <= prompt_tokens
#   - any multiply/add below overflowing int64 is a null_usage_error (checked arithmetic)
#
# Precedence note (v0.6): for cached_prompt_tokens specifically, the §5.3.1 hot-path gate runs
# FIRST — a negative cached count or cached>prompt is classified there as
# 'invalid_cached_prompt_tokens' QUARANTINE (not null_error). The cached bounds in this gate (3)
# are therefore a defensive backstop that only fires for a code path reaching the formula without
# the §5.3.1 gate; the prompt/completion bounds and overflow checks are the primary null_error
# classifiers. Either way credits are zeroed.
#
# RECOVERY-path note (v0.6): the null_usage_error classification above is the FORMULA / hot-path
# behavior. During RECOVERY (recovery.go), an out-of-range token is intercepted BEFORE the formula and
# classified as an 'invalid_usage_tokens' QUARANTINE (not null_usage_error), but the interception is
# NARROWER than the formula gate (recovery.go invalidRecoveryToken/Estimate/Completion):
#   - prompt <0 or >10_000_000            => invalid_usage_tokens (always)
#   - estimate <0 or >10_000_000          => invalid_usage_tokens (always)
#   - completion <0                       => invalid_usage_tokens (always)
#   - completion >10_000_000              => invalid_usage_tokens ONLY IF there is no valid in-range
#       estimate; WITH a valid in-range estimate the completion is CLAMPED to that estimate and priced
#       normally (mirrors the §5.3 billableCompletion clamp) — e.g. completion=10_000_001, estimate=2
#       prices at 2, it is NOT quarantined.
# An invalid_usage_tokens quarantine shares the same two recovery subpaths as the cache quarantines
# (§2.7): flag-only on a pre-existing row (stored credits RETAINED — the §2.7 deviation) or
# insertQuarantineTx on a new row (zero credits, no operator row). So the "out-of-range => null_error"
# rule holds for the formula path; recovery reconciles the same condition as invalid_usage_tokens.

# (4) cache-split prompt numerator (SPEC-024, folded in)
uncached_prompt_tokens = prompt_tokens - cached_prompt_tokens
prompt_numerator = uncached_prompt_tokens * prompt_rate_per_mtok
                 + cached_prompt_tokens   * effective_prompt_cache_hit_rate_per_mtok
# effective_prompt_cache_hit_rate = prompt_cache_hit_credits_per_mtok if configured
#   (or explicitly 0, or if prompt rate is 0); OTHERWISE defaults to prompt_rate_per_mtok
#   (cached tokens billed at the FULL prompt rate — no discount unless configured, §5.5)

# (5) numerator, multiplier, split
base_numerator = prompt_numerator + effective_completion_tokens * completion_rate_per_mtok
rate_scaled_numerator = base_numerator * global_multiplier_ppm
gross_credits = round_half_even(rate_scaled_numerator, 1_000_000 * 1_000_000)
provider_credits = round_half_even(gross_credits * provider_share_bps, 10_000)
operator_credits = gross_credits - provider_credits
```

When `usage_source = 'null_error'`, any of `prompt_tokens`, `cached_prompt_tokens`, and
`completion_tokens` MAY be NULL. The row MUST set `gross_credits = 0`, `provider_credits = 0`, and
`operator_credits = 0` before the formula evaluates; the formula MUST NOT be evaluated on NULL
operands. Fault (`breaker_qualifying`) and null-error overrides set gross/provider/operator to 0
before split (the rate/multiplier/share columns are still snapshotted for audit).

**NULL `prompt_tokens` on a non-null-error row (v0.6).** The §5.3 formula treats a NULL
`prompt_tokens` as **`COALESCE(prompt_tokens, 0)` = 0** (`ComputeCreditsWithCache`, `formula.go`): the
prompt numerator contributes 0 and a present `completion_tokens` is still billed. **But on the paths
that would otherwise reach the formula with a nil prompt, the server substitutes an estimate first**
(§5.3.2): when the prompt count is absent and the row is a `byte_estimated` completion or a `502`/`504`
with no error code, `server.go` sets `prompt_tokens = estimateTokens(req.raw)` **before** billing — so
those rows charge the coordinator's prompt estimate, not zero, and the estimate is recorded in
`provider_reported_prompt_tokens`. The genuine `COALESCE(0)` completion-only path is therefore the
**residual** case: a provider-reported row whose prompt was omitted with no substitution trigger (no
estimate, not 502/504) — it bills completion alone and is not an error. It is distinct from
`null_error`, where the whole row zeroes.
Recovery rows MUST use the `ledger_config_snapshots` row selected by section  10.4; they MUST NOT
price historical rows from current coordinator.yaml when a historical snapshot is required.

**Clamp provenance (runbook item 2 / audit H1).** The `min(reported, byte_estimate)` clamp with a
`byte_estimated` usage-source downgrade means an honest provider-reported completion larger than
`ceil(wire_bytes/16)` is billed at the byte estimate. The 2026-07-11/07-12 production-ledger G1
probe measured this as negligible (~3–5% of reported rows bound, ~1-token median loss, ~$0.001
provider credit over 35 days), so v0.6 documents the shipped `/16` divisor and clamp rather than
reverting it; any future change to the divisor or the clamp direction is a money-path decision that
MUST re-run the G1 probe and append a `beta/DECISION_CRITERIA.md` entry.

### 5.3.1 Cache-eligibility gating and NULL semantics (SPEC-024 §14, folded in)

`cached_prompt_tokens` is a nullable optimization signal, and the cache **discount** is applied by
the formula only for a row that has passed a coordinator eligibility gate on the hot path
(`normalizeCachedPromptTokens`, `internal/billing/hotpath.go`) **before** §5.3 runs. The gate,
applied in order:

1. **NULL** `cached_prompt_tokens` — no cache term. The formula treats a NULL as **`COALESCE(cached,
   0)`**: `uncached = prompt_tokens`, no cached numerator, and the row bills **identically to
   pre-SPEC-024** (a legacy / non-cache row is unaffected — implementations MUST NOT null-propagate).
2. **Invalid** — `cached < 0`, or `prompt_tokens` NULL, or `cached > prompt_tokens` — the row is
   **quarantined** with `quarantine_reason = 'invalid_cached_prompt_tokens'`, `cached` is cleared,
   and credits are **zeroed** (`quarantined = 1`, no payable credit).
3. **Retry** (`attempt_n > 0`) — `cached` is cleared (set NULL); the row is priced **fully at the
   prompt rate** (cache reuse is trusted only on the first attempt). Not quarantined.
4. **Non-sticky-hit route** (`sticky_result != "hit"`): a **positive** `cached` is **quarantined**
   with `quarantine_reason = 'ambiguous_cache'` and credits **zeroed**; a zero `cached` is simply
   cleared (no discount, not quarantined). Cache reuse is trusted only on a sticky **hit**.
5. **Sticky hit, first attempt, valid** — `cached` is kept and the §5.3 cache split applies (the
   discount is earned).

So the cache discount is earned **only** on a `sticky_result = "hit"`, `attempt_n = 0`, valid-`cached`
row; every other case is either priced at the full prompt rate or **quarantined to zero payable
credit** — never a partial/ambiguous discount. This is the SPEC-024 §14 (FR-CI11/CI11a/CI12/CI13)
coordinator cross-check, now normative here. (A `cached_prompt_tokens > prompt_tokens` value is
additionally rejected by the DB CHECK, §4.3.)

**Cache-hit-rate ceiling (config-validated).** `prompt_cache_hit_credits_per_mtok` MUST satisfy
`0 <= prompt_cache_hit_credits_per_mtok <= prompt_credits_per_mtok` for every rate-card row,
enforced at config load (`internal/config/config.go`); a cache-hit rate above the prompt rate, or
negative, fails startup. So a cached token can never be billed **higher** than an uncached one — the
cache split can only reduce or hold cost, never increase it. Combined with the §5.5 default (unset ⇒
full prompt rate), cache accounting is bounded in `[0, prompt_rate]` per token.

**Directionality limit — under-reporting is not detectable (v0.6, honest disclosure).** The §5.3.1
gates and the §14 coordinator cross-check only constrain the **over**-reporting direction (a positive
`cached_prompt_tokens` on a route the coordinator cannot corroborate is quarantined). They do **not**
detect **under**-reporting: a provider that actually reused its KV cache but reports
`cached_prompt_tokens = 0` or omits the field is priced with **no discount** — every prompt token
bills at the full prompt rate (NULL ⇒ COALESCE(0), §5.3). This **over**-credits that provider (and
mirrors into buyer **over**-charge) by the configured prompt-rate/cache-rate delta, and verified
receipts cannot repair it because the receipt schema carries no cached-token count (§7.5b). This is an
accepted residual of provider-self-reported cache reuse, not a solved property; it bounds buyer harm
only by the size of the configured cache discount. (SPEC-024 §7 fraud model / §13 threat model own the
non-billing framing.)

**Fallback quarantine-preservation invariant (v0.6) + known code gap.** The eligibility gate MUST run
against the **same** prompt bound used for billing so that a cached count exceeding the *bounded*
prompt is caught as `invalid_cached_prompt_tokens`. **Known shipped gap (carried code follow-up):**
the request-log cache fields are currently computed against the *un*bounded prompt, and on a hot-path
**fallback** the prompt is lowered but a now-over-bound cached count is **cleared without recording
the quarantine reason** (`hotpath.go` fallback path), so recovery can create ordinary payable credits
for such a row (e.g. prompt 1000 → bound 500, cached 600 should zero-quarantine but can pay 500 +
completion). This is a **code** defect, not intended behavior; the invariant above is normative and
the fallback path MUST be fixed to preserve the quarantine. Tracked as a money-path code follow-up
(does not block this spec-reconciliation PR; pre-existing to this change).

### 5.3.2 Charged-vs-reported prompt-token bounding (v0.6)

The prompt count the formula prices is bounded above by a coordinator-side estimate, analogous to the
§5.3 completion clamp. The hot path (`boundProviderReportedPromptTokens`, `internal/billing/hotpath.go`)
applies, in order:

1. **Independent estimate.** The coordinator estimates the request's prompt tokens from the buyer
   request at routing time — `PromptTokenUpperBound = estimateTokens(req.raw)`
   (`internal/buyer/server.go`), where `estimateTokens ≈ len(req.raw)/4`. This is a **loose heuristic
   upper bound**, not a tokenizer-exact count: `req.raw` is the whole request JSON (whitespace,
   non-model fields, formatting), so `len/4` typically **over**-estimates the true prompt tokens.
2. **Provider-attributed prompt (`provider_reported_prompt_tokens`).** This column holds the prompt
   count **attributed to the provider**, which is the provider's own reported value **when present**.
   When the provider omits the prompt count on a path that still bills prompt — an estimated-completion
   (`byte_estimated`) row or a `502`/`504` with no usage — the coordinator **substitutes**
   `estimateTokens(req.raw)` as the prompt (`server.go` `logAttemptWithReceiptState`) **before** the
   hot path, and that substituted estimate is what is copied into `provider_reported_prompt_tokens`. So
   this column is "the prompt count the coordinator attributed to the provider (reported-or-substituted)",
   **not** strictly a raw provider wire value; it is never zeroed by this step.
3. **Billable cap.** If the attributed prompt exceeds the estimate the charged value is lowered to the
   bound — `charged_prompt = min(provider_reported_prompt_tokens, PromptTokenUpperBound)` — and the
   bounded value is stored as **both** `prompt_tokens` (the §5.3-priced value) and
   `charged_prompt_tokens`. A `warn` log records any row where the bound reduced the charge. When the
   coordinator has no estimate (`PromptTokenUpperBound == NULL`, e.g. legacy/recovery rows) or no
   attributed prompt, the value passes through **unbounded**.

This is a **money-affecting** normalization that caps *gross* prompt over-reporting: a provider claiming
far more prompt tokens than `len(req.raw)/4` is billed only for that heuristic bound. It is **not** a
tight anti-inflation guarantee — because the bound is `len/4` rather than a tokenizer count, a dishonest
provider retains **slack** to inflate the prompt report up to the heuristic, and NULL-bound
(legacy/recovery) rows are not capped at all. A conforming implementation MUST price the bounded
`prompt_tokens`, MUST NOT price a value above `PromptTokenUpperBound` when a bound exists, and MUST
record the raw-or-substituted attribution in `provider_reported_prompt_tokens`. (§7.5b applies the same
`min(receipt, existing)` discipline again at verified-receipt finalization.) Provider **under**-reporting
of prompt tokens is not corrected here (see the §5.3.1 cache-under-reporting disclosure for the
analogous provider-favorable direction).

### 5.4 Worked examples

- 200 with 1000 prompt and 2000 completion tokens on 7B rates: gross=5000, provider=4500, operator=500.
- 502 prompt-only with 1000 prompt tokens on 7B rates: gross=1000, provider=900, operator=100.
- Null usage error path: gross=0, provider=0, operator=0.
- Unknown model: default rates 500000 prompt and 1000000 completion are snapshotted.
- global_multiplier 0.5: parse to 500000 PPM before the formula.
- **Cache split (no configured cache-hit rate):** 1000 prompt of which 400 `cached_prompt_tokens`, 7B rates, no `prompt_cache_hit_credits_per_mtok`. Cached tokens default to the full prompt rate, so `prompt_numerator = 600*1_000_000 + 400*1_000_000 = 1000*1_000_000` — identical to no cache split. Cache accounting is a no-op on cost until a discount rate is configured.
- **Cache split (discount configured):** same row with `prompt_cache_hit_credits_per_mtok = 250000`. `prompt_numerator = 600*1_000_000 + 400*250_000 = 700_000_000` — the 400 cached tokens billed at ¼ the prompt rate.
- **Completion clamp:** provider reports 5000 completion tokens but `estimated_completion_tokens = ceil(wire_bytes/16) = 4200`. Billable completion clamps to 4200 and `usage_source` is recorded as `byte_estimated`.
- **10M cap:** a row with `prompt_tokens = 10_000_001` (or a cached/completion field over 10M) is `null_usage_error` with gross=provider=operator=0 **in the formula path**. Exception: a `completion_tokens` over 10M is first subject to the §5.3 completion clamp — with a valid in-range `estimated_completion_tokens` the completion is clamped to the estimate (and priced) before the 10M gate sees it, so it is not a `null_usage_error`. During recovery the same case is `invalid_usage_tokens` only when no in-range estimate exists (§5.3 recovery note).

## 5.5 Model-key normalization and rate-card resolution

Rate lookup (`RateFor`, `internal/billing/formula.go`) resolves a request `model` string against
the coordinator.yaml rate card in this order, stopping at the first hit:

1. **Exact** `model` key.
2. **Normalized** key via `NormalizeModelKey(model)` (below), if it differs from `model`.
3. **`default`** rate-card row.
4. **Empty** entry (all-zero rates) if there is no `default` — priced at zero. (§13.x requires a
   `default` row at config load; cold start without one fails.)

The `rate_card_normalized` structured log is emitted **only when normalization changed the input**
(`NormalizeModelKey(model) != model`) and a fallback tier was used; an exact hit on the original key
logs nothing. Its `matched` field carries the **actual matched key** — the normalized key string on
a normalized hit, `"default"` on the default fallback, or `""` when nothing matched — not a literal
tier name.

`NormalizeModelKey(model)`:

1. Lowercase and trim whitespace.
2. If the key has a `<namespace>/` prefix and `<namespace>` is a **known** namespace
   (`mlx-community`, `openai`, `google`, `meta-llama`, `nvidia`, `qwen`), strip the prefix
   (recording the stripped namespace).
3. Strip a trailing quantization suffix — one of `-mxfp4-q8`, `-4bit`, `-8bit`.
4. Apply canonical remaps (exact, from the shipped `switch`):
   - stripped namespace was exactly `meta-llama` **and** the remaining key starts with `llama-`
     → `meta-llama/<key>`;
   - else the key starts with `meta-llama-` → `meta-llama/` + (key with the `meta-` prefix removed);
   - else the key starts with `nvidia-nemotron-` → key with the leading `nvidia-` removed;
   - else the key starts with `gpt-oss-` → `openai/<key>`;
   - otherwise the stripped key unchanged.
   **A bare `llama-…` key (no `meta-llama` namespace and no `meta-llama-` prefix) is NOT remapped** —
   it falls through unchanged, so it resolves to its own rate-card row or `default`, not
   `meta-llama/…`.

Normalization affects **only rate-card lookup**; the original `model` string is stored verbatim in
`ledger_request_credits.model`. The resolved **prompt and completion** rates are snapshotted as the
`prompt_rate_per_mtok` / `completion_rate_per_mtok` columns (§4.3); the **cache-hit** rate has no
dedicated column — it is captured only inside the full rate-card JSON in
`ledger_config_snapshots.rate_card_json` (§4.7), which a request row is tied to through the
`config_snapshot_id` linkage (§4.8), so historical cache-rate reconstruction goes through the
config snapshot, not `ledger_request_credits`.

## 6. Credit calculation: D8 mapping

SPEC-006 **v0.9.8** section  17.7 is the source of truth for buyer debits. (v0.8.2 introduced this section; v0.9.1 added the X-MacProvider-Account forward contract; v0.9.8 narrowed the Tier-2 survivability invariant for the SPEC-024 provider-visibility carve-out. The 200 row now records the streaming symmetric token clamp — downward to gateway-observed, upward to provider-reported — which is buyer-debit accounting on the SPEC-006 side and does not change SPEC-005's provider-credit byte math.)
SPEC-005 mirrors every row with a provider-credit derivation.
This section implements the locked failed-request accounting decision (D8) by mirroring the SPEC-006 section  17.7 D3 matrix after the coordinated v0.8.2 null-usage row.

### 6.1 200 success

**SPEC-006 section  17.7 status:** 200.
**Completion-token state:** as reported.
**Buyer debit:** prompt + completion.
**SPEC-005 provider-credit rule:** Write ledger row; provider_reported; compute prompt plus completion.
**Closed form:** apply section  5.3 to this row after its token-source selection and overrides.

### 6.2 503 no provider reached

**SPEC-006 section  17.7 status:** 503.
**Completion-token state:** 0.
**Buyer debit:** none.
**SPEC-005 provider-credit rule:** Write no provider or operator ledger row.
**Closed form:** not applicable because no ledger row is written.
The 503 provider-not-reached path writes zero ledger rows of any kind: no `ledger_request_credits`, no `ledger_operator_credits`, and no `ledger_provider_identity_snapshots`.
If a reconciliation summary needs to count provider-not-reached requests, it does so via the `request_log` JOIN where provider_assigned_id IS NULL, not via a `usage_source` value.

### 6.3 502 zero completion

**SPEC-006 section  17.7 status:** 502.
**Completion-token state:** 0.
**Buyer debit:** prompt only.
**SPEC-005 provider-credit rule:** Write prompt-only ledger row unless FR-P11a override applies.
**Closed form:** apply section  5.3 to this row after its token-source selection and overrides.

### 6.4 502 partial stream

**SPEC-006 section  17.7 status:** 502.
**Completion-token state:** >0 partial.
**Buyer debit:** prompt + actual completion.
**SPEC-005 provider-credit rule:** Write prompt plus actual completion ledger row unless FR-P11a override applies.
**Closed form:** apply section  5.3 to this row after its token-source selection and overrides.

### 6.5 504 zero completion

**SPEC-006 section  17.7 status:** 504.
**Completion-token state:** 0.
**Buyer debit:** prompt only.
**SPEC-005 provider-credit rule:** Write prompt-only ledger row unless FR-P11a override applies.
**Closed form:** apply section  5.3 to this row after its token-source selection and overrides.

### 6.6 504 partial stream

**SPEC-006 section  17.7 status:** 504.
**Completion-token state:** >0 partial.
**Buyer debit:** prompt + actual completion.
**SPEC-005 provider-credit rule:** Write prompt plus actual completion ledger row unless FR-P11a override applies.
**Closed form:** apply section  5.3 to this row after its token-source selection and overrides.

### 6.7 Client disconnect v1.2.4+

**SPEC-006 section  17.7 status:** client_disconnect.
**Completion-token state:** provider reported actual.
**Buyer debit:** prompt + actual completion.
**SPEC-005 provider-credit rule:** Use the provider-reported completion, **subject to the §5.3 clamp** (`min(reported, byte_estimate)` — when a byte estimate is present and smaller, the row is clamped and its `usage_source` downgraded to `byte_estimated`).
**Closed form:** apply section  5.3 to this row after its token-source selection and overrides.

### 6.8 Client disconnect pre-v1.2.4

**SPEC-006 section  17.7 status:** client_disconnect.
**Completion-token state:** byte estimated.
**Buyer debit:** prompt + the §5.3 byte estimate.
**SPEC-005 provider-credit rule:** Use the same estimate as buyer debit.
**Closed form:** apply section  5.3 to this row after its token-source selection and overrides.
**Byte-estimate formula (reconciled to shipped code, v0.6).** The completion byte estimate is
`ceil(bytes_emitted_so_far / tier2.output_bytes_per_token_ceiling)`, floored at 1 token and
capped at the request-log usage cap (`estimatedCompletionTokensFromBytes`,
`internal/buyer/server.go`). The ceiling is a coordinator config knob with **default 16**; a
non-positive ceiling falls back to a `4` divisor defensively (never the normal path). **This
supersedes the prior `ceil(bytes/4)` text** (runbook item 2). The historical `ceil(bytes/4)` in
**SPEC-006 v0.9.8 §17.7** is a documented **cross-spec drift** — SPEC-005 billing is authoritative
on the coordinator estimate (default `/16`); reconciling the SPEC-006 §17.7 buyer-debit wording is
a separate carried follow-up. Any change to `tier2.output_bytes_per_token_ceiling` or the clamp
direction is a money-path decision (re-run the G1 probe + append a `beta/DECISION_CRITERIA.md` entry).

### 6.9 Null usage error path

If SPEC-002 v1.5.0 `request_log.error_code` is `error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, or `error_internal`, provider credit is 0.
When `usage_source = 'null_error'`, both `prompt_tokens` and `completion_tokens` MAY be NULL. The row MUST set `gross_credits = 0`, `provider_credits = 0`, and `operator_credits = 0` before the formula evaluates; the formula MUST NOT be evaluated on NULL operands.
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

This section implements the locked cadence, threshold, and split decisions (D2)(D4)(D5) by accruing immediately, emitting weekly UTC payout-ready rows, enforcing the configurable minimum threshold, and preserving the provider/operator split.

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

### 7.4.1 Settlement source-set snapshot

Each settlement run MUST acquire `BEGIN IMMEDIATE` before computing
eligible source rows. Within that transaction it MUST materialize a
fixed source set for the run before inserting or updating
`ledger_payout_ready`, and subsequent source-row settlement updates
MUST use only that materialized set. The eligibility timestamp for
force-credit maturity is one run-local snapshot timestamp, not a
fresh wall-clock evaluation per SQL statement.

If a force-credit row matures after a provider/window already has a
`ledger_payout_ready` row, rerunning that old window MUST NOT mutate
the old payout-ready row. The matured source row remains unsettled
and can roll forward into the next settlement run whose
`window_end_utc` is after the row's original `ts_utc`.

### 7.5 Update exception

The hot path never updates ledger_request_credits.
Settlement may update settled and settlement_id.
Recovery may update quarantine fields.
Tokens, rates, split snapshots, and credit amounts are otherwise immutable — **with one shipped
exception (v0.6): verified-receipt finalization (§7.5b).**

### 7.5a Settlement-policy mode (columns reconciled, v0.6)

Each row records `settlement_policy_mode` (`legacy` / `observe` / `enforce`, default `legacy`) and
`settlement_policy_version` at insert (§4.3). The payable-credits projection
(`spec022_payable_request_credits`) treats them as: `legacy` and `observe` rows are payable on the
usual `quarantined = 0` basis (observe is measure-only); an **`enforce`** row is payout-eligible
only when it additionally has a **matched route, a matched settlement receipt, a matching policy
version, a verified outcome, and no overlapping row** (`internal/billing/store.go` payable query).
`settlement_account_scope_hash` is the 64-hex account partition the enforce gate matches on. This is
the SPEC-022 settlement-policy enforcement surface; SPEC-022 is authoritative on the policy
lifecycle, SPEC-005 documents only how the columns gate the payable projection.

### 7.5b Verified-receipt finalization (re-pricing exception, v0.6)

When a **verified settlement receipt** arrives for a request (SPEC-015/016), the coordinator
**re-prices** the matched credit row from the receipt's authoritative token counts
(`internal/billing/settlement_receipts.go`), running it back through the §5.3 formula. The receipt
schema (`settlementUsageV04`) carries only `billable_input_tokens` / `billable_output_tokens` and
observed counts — it does **not** carry a `cached_prompt_tokens` value. The **cached** count used in
re-pricing is therefore read from the **existing ledger row** (`lrc.cached_prompt_tokens`), not from
the receipt; the receipt authoritatively sets only prompt (input) and completion (output). The
re-price touches **two** tables (both otherwise insert-only, §4.3/§4.4):

- `ledger_request_credits` — UPDATEs `prompt_tokens`, `charged_prompt_tokens`, `completion_tokens`,
  `estimated_completion_tokens` (→ NULL), `usage_source`, `gross_credits`, `provider_credits`,
  `fault_flag`, and `updated_at_utc`.
- `ledger_operator_credits` — UPDATEs `gross_credits`, `operator_credits`, and `fault_flag` on the
  linked row (`WHERE request_credit_id = ?`) so the operator split stays consistent with the
  re-priced gross.

**Scope of the exception (v0.6).** Re-pricing is **not** unconditional: it applies only to a row
that is matched by `id`, in **`enforce`** settlement mode, carrying a **verified** receipt,
**unsettled**, and **not already quarantined**. "Unsettled" is enforced as **both** `settled = 0`
**and** `settlement_id IS NULL` (`settlement_receipts.go`); a row inconsistent between those two
columns (no CHECK binds them) is not re-priced. Rows outside that set are untouched.

**Cache-quarantine branches during re-pricing (v0.6).** When the existing ledger row carries a
positive `cached_prompt_tokens`, re-pricing **quarantines** rather than guessing in three cases:
(1) the downward prompt clamp (next paragraph) lowers `prompt_tokens` **below** the existing cached
count → `invalid_cached_prompt_tokens`; (2) the historical cache-rate config snapshot is unavailable
→ `missing_cache_config_snapshot`; (3) the snapshot rate/multiplier/share disagree with the row →
`cache_config_snapshot_rate_mismatch`. Each zeroes the row's credits on both ledger tables
(`settlement_receipts.go`).

**Prompt count is bounded, never inflated (v0.6).** Re-pricing MUST NOT raise the prompt charge
above the count already on the row. The receipt's `billable_input_tokens` is applied under a
downward clamp against the existing ledger `prompt_tokens`:
`charged = min(receipt.billable_input_tokens, existing prompt_tokens)` when the row already carries a
prompt count, and both `prompt_tokens` and `charged_prompt_tokens` are set to that bounded value
(`settlement_receipts.go`). A verified receipt reporting **more** prompt tokens than the insert-time
count therefore does **not** over-credit the provider or over-charge the buyer — it can only confirm
or lower the charge (and, per the branch above, a clamp that drops below the cached count quarantines
rather than pays). The receipt's `billable_output_tokens` sets `completion_tokens` directly.

This is the single sanctioned **runtime** mutation of token/credit fields after insert; it is
idempotent and applies only to a row matched by `id` under a verified receipt (both the request-credit
and the linked operator-credit row). The only other permitted post-insert write is a **one-time
additive migration backfill**: when a migration (§4.9) adds a new nullable column, its idempotent
backfill MAY populate that column on pre-existing rows — e.g. the `charged_prompt_tokens` /
`provider_reported_prompt_tokens` backfill (`store.go`) — but it MUST NOT alter any credit amount
(`gross_credits`/`provider_credits`/`operator_credits`) or the priced `prompt_tokens`. Any OTHER
process updating tokens/rates/credits remains forbidden.

## 8. Multi-attempt attribution (D10)

This section implements the locked multi-provider attribution decision (D10) by crediting each routed attempt independently using request_id, attempt_n, and stable provider_id.

### 8.1 Key

Every credit row is keyed by request_id, attempt_n, and provider_id.
The unique index rejects duplicate attempt credits.
Stable provider_id is the economic identity.

### 8.2 Derivation

**SPEC-005 v0.3.3 (issue #168): prefer the persisted `request_log.attempt_n` exact match when non-NULL.** SPEC-002 v1.5.2 populates `attempt_n` monotonically at INSERT time within the same `(account_id, request_id)` group; the value is the canonical ordinal and MUST be copied directly into the ledger row.
For legacy NULL-`attempt_n` rows (pre-SPEC-002-v1.5.2 OR rollback window), the fallback derivation is unchanged from v0.3.1: group rows by `(account_id, request_id)` under SQLite `IS`, order each group by `request_log.id ASC`. NULL-`account_id` rows cluster with NULL-`account_id` rows only. The first ordered row uses `attempt_n=0`; the second uses `attempt_n=1` only when `request_log.retried` indicates an explicit retry. The fallback arithmetic is byte-identical to the writer's INSERT-time COUNT, so backfilled and derivation-time ordinals match exactly.
**Quarantine rules (v0.3.3):** the v0.3.1 "row 3+ MUST be quarantined" rule is satisfied in BOTH paths — the persisted monotonic `attempt_n` path AND the byte-identical id-ASC fallback path. Row 3+ in either path receives a stable `attempt_n=2, 3, ...` ordinal and is credited normally. The only remaining quarantine class is `attempt_n=1` with `retried=0` (legitimate retry without explicit marker) — operator resolution via SPEC-005 §OQ-5 force-credit / force-void (issue #169).
If request_log.id cannot produce a unique order within an `(account_id, request_id)` group, all ambiguous rows in that group MUST be quarantined.
Stable provider_id MUST be copied from `ledger_provider_identity_snapshots` when request_log only supplies provider_assigned_id.

### 8.3 Invariant

Every attempt independently runs through section  6.
Request-level gross is the sum of attempt gross credits.
Winner-takes-all is forbidden.
No attempt may borrow tokens from another attempt.

### 8.4 Cross-spec patch

SPEC-002 needs an attempt_n column or equivalent monotonic attempt ordinal. **Closed in SPEC-002 v1.5.2 / SPEC-005 v0.3.3 (issue #168) — see §15.2 below.**
SPEC-005 does not apply that patch.
The operator must gate that patch in audit or v0.2 work.

## 9. Fraud floor and FR-P11a integration (D12)

This section implements the locked fraud-floor decision (D12) by zero-crediting FR-P11a fault-classified requests and restoring normal earning eligibility only after the recovery preflight returns the provider to ready.

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

This section implements the locked crash-recovery decision (D9) by keeping hot-path writes in one SQLite transaction and making startup and nightly recovery deterministic without live network calls.

### 10.1 Transaction contract

Hot path MUST use BEGIN IMMEDIATE; ...; COMMIT.
request_log, ledger_request_credits, ledger_operator_credits, and any provider identity snapshot for the reached provider are written together.
Crash before COMMIT loses all rows together.
Crash after COMMIT preserves all rows together.
No 2PC is used.
The coordinator SQLite database MUST be operated in WAL mode (`PRAGMA journal_mode = WAL`). Recovery scans MUST execute under `BEGIN DEFERRED` to obtain a consistent reader snapshot.

**Pool cap (operational invariant).** The Go `*sql.DB` handle backing the coordinator SQLite store MUST set `MaxOpenConns(1)` and `MaxIdleConns(1)`. SQLite already serializes writers at one-at-a-time; the Go-pool cap converts that into an enforceable serialization point and eliminates the implicit-pool unbounded growth that surfaced as latent p99 latency and post-inference `request_log_failed` 500s on prior uncapped builds (issue #21 / ARCH-3 / 2026-06-10 audit QW-5). Callers that share the requestlog/billing/admission `*sql.DB` MUST NOT hold an outer `*sql.Rows` cursor open across an inner query against the SAME pool, and inside a transaction MUST NOT call helpers that issue against the un-pinned `*sql.DB` (they will deadlock waiting for a second connection that cannot be obtained while the tx pins the only one). The reference IMPL is `phase4-coordinator/internal/requestlog/store.go` `OpenStore`.

### 10.2 Startup scan

Startup scans prior 24 hours.
Creditable request_log rows missing ledger rows get recovery rows.
Recovery rows set recovery_source=startup_scan.
Recovery rows select the config snapshot by the identity-first precedence stated below (exact identity-linked `config_snapshot_id` when present; timestamp-qualified fallback only when absent). If no snapshot can be selected, the row is quarantined (`missing_config_snapshot`, or `missing_cache_config_snapshot` for a positive first-attempt cache row) instead of priced with current config.
Recovery rows use `ledger_provider_identity_snapshots` to resolve provider_assigned_id to stable provider_id.
The scan is idempotent.

**Snapshot selection precedence — identity snapshot first (v0.6).** Recovery does **not** use the
timestamp-qualified "latest snapshot ≤ `ts_utc`" rule as its primary. For **every** recovery row (cache
and non-cache), recovery first uses the **exact** `ledger_provider_identity_snapshots.config_snapshot_id`
the row was priced under at insert, **when that id is present** (`recovery.go` — `identityConfigSnapshotID`
is normally set for all provider-reached rows). The timestamp-qualified latest-snapshot rule is the
**fallback used only when that id is absent**. Behavior when the id is absent then diverges:
- a **positive `cached_prompt_tokens` on `attempt_n = 0`** (`cacheProvenanceRequired`) does **NOT** fall
  back — it **quarantines** `missing_cache_config_snapshot`, because a cache discount must be
  reconstructed from the exact historical rate, not an approximate by-timestamp one;
- every **other** row falls back to the timestamp-qualified latest snapshot and quarantines
  `missing_config_snapshot` only when no snapshot at or before `ts_utc` exists.

(This mirrors the §7.5b receipt-time `missing_cache_config_snapshot` strictness.) §10.4's snapshot-selection
step follows this same identity-first precedence.

### 10.3 Nightly reconcile

Nightly goroutine scans prior 7 days.
It uses the same deterministic classifier as startup.
It writes ledger_reconciliation_runs.
It quarantines orphan ledger rows.
It does not delete rows.
For a clean range, delta_gross_credits MUST equal 0 when provider gross credits are recomputed from the same section  5.3 formula and historical config snapshot.
Provider/operator split deltas MUST be checked separately by verifying provider_credits + operator_credits == gross_credits for each row.
A non-zero gross delta MUST be recorded in `/admin/ledger/reconcile` output and MUST fail AC-H005.
`buyer_equivalent_credits` is the SPEC-005-internal buyer-equivalent total computed from `request_log` via the section  6 D8 matrix and the same section  5.3 formula. SPEC-005 does NOT read SPEC-006 usage tables. AC-H005 verifies symmetry of the SPEC-005 model only; cross-process consistency between SPEC-005 and SPEC-006 is a separate H-005-EXT verification owned by the operator outside SPEC-005 v0.3.

### 10.4 Deterministic algorithm

Function signature: RecoverLedger(requestLogRows, ledgerRows, configSnapshots, providerIdentitySnapshots, scanWindow).
Outputs: recoveryRows, quarantineUpdates, reconciliationSummary.
Same inputs produce byte-identical outputs.
Time is explicit input.
No live network call may affect output.
`scanWindow.to_utc` MUST be no closer to wall-clock now than `settlement.recovery_grace_seconds` (default 30s). Rows with `request_log.ts_utc` newer than this cutoff are excluded from the scan to prevent races with in-flight hot-path transactions.
SPEC-002 v1.5.1 indexes `request_log.ts_utc`, `(request_id, id)`, `external_request_id` (partial-NULL), and `(account_id, external_request_id)` (partial-NULL composite) are preconditions for production-scale reconciliation scans. Any reconciliation surface that performs closing-the-books joins between coordinator `request_log` and gateway `usage_events` / `audit_events` by composite reconciliation key — whether run as an out-of-process harness OR as a future coordinator-hosted reconciliation endpoint — MUST read per-key migration state via `coordinator migrate-indexes --check --format json` (`requestlog.Store.MigrationState`) and fail closed when any depended-on composite key is in state `legacy` or `unindexed`, per the SPEC-002 v1.5.1 operational binding. Fixture / dev / one-shot recovery runs MAY pass an explicit bounded `--allow-unindexed-scan` override; the override MUST NOT be the default. Coordinator's own in-process AttemptN paths (`hotpath.go`, `recovery.go`, `endpoints.go` `/admin/ledger/reconcile`) use single-table SQLite `IS` clustering and are correct (just unindexed-slow) under state `unindexed`; they do NOT fail closed during the rollout window. (v0.3.2 / issue #197; v0.3.1 / issue #211 added the composite index dependency.)
For each recoverable request_log row, the algorithm uses the exact identity-linked `config_snapshot_id` when present (all rows); only when that id is absent does it fall back to the latest config snapshot whose effective_at_utc is less than or equal to request_log.ts_utc — **except** a positive first-attempt cache row, which does not fall back and quarantines `missing_cache_config_snapshot` (the §10.2 identity-first precedence).
If no config snapshot or provider identity snapshot can be selected for a provider-reached row, the row is quarantined.

### 10.5 Quarantine

Absent request_log join quarantines ledger rows.
Inconsistent immutable math quarantines ledger rows.
Ambiguous `attempt_n=1` with `retried=0` (legitimate retry without explicit marker) quarantines rows. (v0.3.3: row 3+ is no longer in this class — see §15.2.)
Quarantine is review, not deletion.
Quarantined rows are exposed in admin endpoints.

### 10.6 Out-of-scope crash boundaries

SPEC-005 owns only coordinator-side crash recovery. The following cross-process states are explicitly OUT OF SCOPE for SPEC-005 v0.3 and remain the responsibility of SPEC-006:

1. Gateway crashes after the buyer-quota debit (SPEC-006 section  7.2 reservation) but before forwarding the request to the coordinator. SPEC-005 sees no `request_log` row; the reservation reaper (SPEC-006 section  7.2 D3 lock) reclaims the reservation within 24h.
2. Gateway-coordinator network partition during an in-flight SSE stream; SPEC-005 credits based on whatever `request_log` row eventually commits.

AC-H005 explicitly excludes these states; `delta_gross_credits` is computed over the SPEC-005-owned request_log + ledger dataset only.

## 11. Operator and provider endpoints (D11)

This section implements the locked operator-dashboard decision (D11) by defining exactly four JSON visibility endpoints and no charts, HTML dashboards, Slack, email, or digest surface.
All endpoint errors use this envelope:

```json
{"error":{"code":"forbidden","message":"operator key required"}}
```

Admin endpoints share the existing `/admin/*` operator-key protection and rate-limit posture.

### 11.1 `GET /admin/ledger/summary`

**Method and path:** `GET /admin/ledger/summary`.
**Auth requirement:** operator key.
**Query parameters:** none.
**Rate-limit posture:** existing `/admin/*` protection.
**Purpose:** totals, this week, last 4 weeks, pending payouts, quarantined rows.
**HTTP 200 JSON example:**

```json
{
  "total_gross_credits": 8123456,
  "total_provider_credits": 7311110,
  "total_operator_credits": 812346,
  "current_window_provider_credits": 525000,
  "pending_payout_count": 2,
  "pending_payout_credits": 1010000,
  "quarantined_count": 0,
  "fault_count": 3,
  "last_reconciliation_delta_credits": 0
}
```

**403 JSON error example:**

```json
{"error":{"code":"forbidden","message":"operator key required"}}
```

No HTML, chart markup, Slack payload, or email body is returned.

### 11.2 `GET /admin/ledger/providers`

**Method and path:** `GET /admin/ledger/providers`.
**Auth requirement:** operator key.
**Query parameters:** optional `limit`, `cursor`, and `include_quarantined`.
**Rate-limit posture:** existing `/admin/*` protection.
**Purpose:** per-provider breakdown.
**HTTP 200 JSON example:**

```json
{
  "providers": [
    {
      "provider_id": "m4-anon",
      "total_provider_credits": 640000,
      "current_window_credits": 125000,
      "pending_payout_credits": 500000,
      "last_activity_utc": "2026-05-31T08:12:00Z",
      "fault_count": 1,
      "quarantined_count": 0,
      "attestation_class": null
    }
  ],
  "next_cursor": null
}
```

**403 JSON error example:**

```json
{"error":{"code":"forbidden","message":"operator key required"}}
```

No HTML, chart markup, Slack payload, or email body is returned.

### 11.3 `GET /admin/ledger/reconcile?from=YYYY-MM-DD&to=YYYY-MM-DD`

**Method and path:** `GET /admin/ledger/reconcile`.
**Auth requirement:** operator key.
**Query parameters:** required `from=YYYY-MM-DD`, required `to=YYYY-MM-DD`.
**Rate-limit posture:** existing `/admin/*` protection.
**Purpose:** H-005 reconciliation report.
**HTTP 200 JSON example:**

```json
{
  "from_utc": "2026-05-24T00:00:00Z",
  "to_utc": "2026-05-31T00:00:00Z",
  "buyer_equivalent_credits": 8123456,
  "provider_gross_credits": 8123456,
  "delta_gross_credits": 0,
  "split_delta_rows": 0,
  "rows_scanned": 128,
  "rows_recovered": 1,
  "rows_quarantined": 0,
  "rows_force_resolved_in_range": 0
}
```

`delta_gross_credits` MUST be 0 for a clean H-005 range. v0.5
computes included rows through `spec022_payable_request_credits`:
force-void rows stay excluded, while held force-credit rows enter
only after maturity. The `rows_force_resolved_in_range` field is
mandatory and counts `force_void` and `force_credit` resolutions
with `created_at_utc` inside the range; see §11.6.5.
`buyer_equivalent_credits` is computed by SPEC-005 from request_log and the section  6 D8 matrix; it is not read from SPEC-006 usage tables.
Provider/operator split validation is reported separately with `split_delta_rows`.
A non-zero `delta_gross_credits` MUST be returned in this JSON response and MUST fail AC-H005.
The reconciliation fixture MUST NOT require live network access.

**403 JSON error example:**

```json
{"error":{"code":"forbidden","message":"operator key required"}}
```

No HTML, chart markup, Slack payload, or email body is returned.

### 11.4 `GET /providers/{provider_id}/earnings`

**Method and path:** `GET /providers/{provider_id}/earnings`.
**Auth requirement:** FR-P12 provider bearer token with subject equal to path `provider_id`.
**Query parameters:** optional `from=YYYY-MM-DD` and `to=YYYY-MM-DD`.
**Rate-limit posture:** bounded by the per-provider read limit configured at `endpoints.provider_earnings.rate_limit_per_minute`.
**Purpose:** provider-owned earnings view.
**HTTP 200 JSON example:**

```json
{
  "provider_id": "m4-anon",
  "total_credits": 640000,
  "current_window_credits": 125000,
  "last_payout_ready": {
    "window_start_utc": "2026-05-18T00:00:00Z",
    "window_end_utc": "2026-05-25T00:00:00Z",
    "provider_credits": 515000,
    "status": "ready"
  },
  "provider_share_bps": 9000,
  "models_served": ["mlx-community/Qwen2.5-7B-Instruct-4bit"],
  "rate_card_excerpt": {
    "mlx-community/Qwen2.5-7B-Instruct-4bit": {
      "prompt_credits_per_mtok": 1000000,
      "completion_credits_per_mtok": 2000000
    }
  },
  "fault_count": 1
}
```

**401 JSON error example:**

```json
{"error":{"code":"unauthorized","message":"provider bearer token required"}}
```

**403 JSON error example:**

```json
{"error":{"code":"forbidden","message":"provider token subject mismatch"}}
```

**404 JSON error example:**

```json
{"error":{"code":"not_found","message":"provider not found"}}
```

No HTML, chart markup, Slack payload, or email body is returned.

### 11.5 Provider endpoint authorization

Provider endpoint MUST use FR-P12 bearer-token auth.
Token subject MUST equal path provider_id.
Wrong-subject token returns 403.
Missing token returns 401.
Unknown provider_id returns 404 without enumerating valid providers.
When SPEC-002 v1.5.0 `auth.require_provider_tokens` is `false`, the `/providers/{provider_id}/earnings` endpoint MUST be disabled at the route layer. SPEC-005 v0.3.1 does NOT specify a side-channel per-provider bearer-token provisioning scheme; provider economics in this deployment mode are available only via the operator-keyed `/admin/ledger/providers` endpoint. SPEC-005 v0.3.1 production launch gate adds this as item 9 alongside the SPEC-006 production launch gate.

**Production launch gate item 10 (v0.5, issue #253).** §11.6 is
gated at the route layer by independent config keys:
`billing.quarantine_resolution_force_void_enabled` and
`billing.quarantine_resolution_force_credit_enabled` (both default
`false`). When a flag is `false`, its endpoint MUST return HTTP
404 `not_found` — the endpoint is invisible to clients. The flags
are operator-toggleable via the existing config-reload primitive
(no coordinator restart required); §13 lists them. Force-credit
also reads `billing.force_credit_settlement_hold_seconds`, default
86400.

Before flipping the flag to `true` in production the operator
MUST: (a) document the operator-key holder set (who can hit
`/admin/ledger/quarantine/*`) and the per-human attribution
limitation per §11.6.4; (b) verify the §13 config-table entry is
present in the deployment's `coordinator.yaml`.

The route-layer default-disabled posture is a MUST, not a SHOULD.
v0.5 ships the SPEC text and IMPL with both flags FALSE; operator
flip is a deliberate, runbook-gated event. The SPEC-006 production
launch gate is NOT modified by SPEC-005 v0.5 — gate item 10 lives
in SPEC-005 alone.

### 11.6 Quarantine resolution admin surface (v0.5, issue #253)

Added by SPEC-005 v0.4 to PARTIALLY close the §OQ-5 "Manual
quarantine resolution" open question. The §OQ-1 closure in v0.3.3
narrowed the quarantine creation class to `attempt_n=1` with
`retried=0` (legitimate retry without explicit marker); v0.4 ships
the operator action to clear false-positive quarantines from the
open-quarantine count via a `force-void` resolution. v0.5 adds the
credit arm via `force-credit`, gated by a 24h default pre-payout
hold.

The endpoint is operator-only (same `/admin/ledger/*` posture as
§11.1 / §11.2 / §11.3 — operator_key bearer, no gateway service
token). POST only; other methods MUST return 405. The endpoint
writes to the `ledger_quarantine_resolutions` table (§4.10) and
emits an audit-log row (§11.6.4) on success, all inside the same
SQLite `BEGIN IMMEDIATE` transaction.

#### 11.6.1 `POST /admin/ledger/quarantine/{request_credit_id}/force-void` and `/force-credit`

**Purpose:** mark the quarantined row as a non-credit (duplicate,
over-count, fraud, or other reason the operator decided not to pay
it). After this resolution, the row remains excluded from §11.1 /
§11.2 / §11.4 / §7 aggregations exactly as a quarantined-and-
unresolved row was excluded under v0.3.3 — but the row is no
longer counted toward the open-quarantine surface (`quarantined_count`
in §11.1 / §11.2). Force-void produces NO money-out; this is the
v0.4 safety property.

**Force-credit purpose:** mark the quarantined row as payable after
operator review. The successful resolution remains out of
`spec022_payable_request_credits`, §7 settlement, and SPEC-016
payout until `force_credit_matures_at_utc`. The maturity timestamp
is `created_at_utc + billing.force_credit_settlement_hold_seconds`
and defaults to 24h.

**Not reason-gated (v0.6 honest disclosure).** Shipped force-credit
(`internal/billing/quarantine.go`) accepts **any** `quarantined = 1`
row **regardless of `quarantine_reason`** — there is no reason
allowlist. This is in tension with the v0.3.3 changelog's "Quarantine
rule narrowing" pre-#169 stance (§ Change log v0.3.3) that
integrity reasons (`invalid_usage_tokens`, `missing_config_snapshot`,
`missing_cache_config_snapshot`, `reconciliation_mismatch`,
`operator_split_mismatch`, `conflicting_settlement_id`, etc.) "MUST
stay quarantined": §11.6.1 (the #169 operator-resolution mechanism)
does **not** enforce that restriction in code — it relies on operator
discipline plus the maturity hold, audit log (§11.6.4), and correction
window (§11.6.2). Because a **recovery flag-only** quarantine can leave
non-zero credits stored (§2.7), force-crediting such an integrity-reason
row re-admits and pays those retained credits. **Carried policy
follow-up:** whether force-credit should enforce a `quarantine_reason`
allowlist (block integrity reasons, permit only reviewable classes) is
an open money-path decision; v0.6 documents the shipped un-gated
behavior, it does not ratify it.

**Path parameter:** `request_credit_id` MUST be the integer
primary key of a row in `ledger_request_credits`. Decimal digits
only; any other character returns HTTP 400 `bad_request`.

**Auth:** operator key (per §11). Missing OR wrong key returns
HTTP 403 `forbidden` with the §11 envelope. (This matches the
existing §11.1 / §11.2 / §11.3 admin contract — the prior R2
draft introduced a 401/403 split that conflicted with §16.1
"Invalid or missing key returns 403" and AC-ENDPOINTS-AUTH; v0.4
uses the existing global posture for consistency.)

**Request body:** JSON object with these fields:

| Field | Type | Required | Validation |
|---|---|---|---|
| `operator_id` | string | yes | 1..64 chars after trim; charset `[A-Za-z0-9_.-]` only; identifies the operator-key user; the audit trail proves operator-KEY use, not human identity (per §11.6.4 attribution note) |
| `reason` | string | yes | 1..500 chars after trim; per-character reject classes per §11.6.3 |

Body MUST be `Content-Type: application/json` (or HTTP 415).
Empty body → HTTP 400. Duplicate JSON keys, unknown JSON keys, or
a top-level non-object → HTTP 400 `bad_request`. Body exceeding 4
KiB → HTTP 413. Validation failures return HTTP 422
`unprocessable_entity` with one of the `code` values enumerated
in §11.6.1.1 (no echo of submitted values to avoid log-injection).

##### 11.6.1.1 Response code table (normative)

| HTTP | `code` | Trigger |
|---|---|---|
| 200 | (n/a — success body) | resolution row inserted; see §11.6.1 200 example |
| 400 | `bad_request` | path `{request_credit_id}` not a base-10 integer, OR overflows int64, OR body not valid JSON, OR top-level not an object, OR contains duplicate keys, OR contains unknown keys |
| 403 | `forbidden` | missing OR wrong operator key (per §11, §16.1 envelope) |
| 404 | `not_found` | (a) the endpoint's config flag is `false` — endpoint is route-layer disabled per §11.5 launch-gate item 10; OR (b) the flag is true but no `ledger_request_credits` row exists with that `id`; the response body is identical in both cases (no leak of which) |
| 405 | `method_not_allowed` | method is not POST |
| 409 | `already_resolved` | same-kind repeat, third resolution attempt, or other already-resolved state that is not an allowed hold-window correction (per §11.6.2) |
| 409 | `resolution_locked` | opposite-kind correction attempted after the hold window has elapsed |
| 413 | `request_too_large` | body > 4 KiB |
| 415 | `unsupported_media_type` | `Content-Type` not `application/json` |
| 422 | `not_quarantined` | row exists but `quarantined=0` |
| 422 | `empty_reason` | `reason` is whitespace-only after trim |
| 422 | `reason_too_long` | trimmed `reason` length > 500 |
| 422 | `unsanitized_reason` | `reason` contains a rejected codepoint per §11.6.3 |
| 422 | `invalid_utf8` | `reason` or `operator_id` not well-formed UTF-8 |
| 422 | `bad_operator_id` | `operator_id` empty after trim, length > 64, or contains characters outside `[A-Za-z0-9_.-]` |
| 422 | `missing_field` | `operator_id` or `reason` field absent from body |
| 500 | `internal_error` | any unreachable FK / CHECK violation surfaces after validation (NOT silent corruption) |

All error responses follow the §11 envelope shape.

**HTTP 200 JSON response on success:**

```json
{
  "request_credit_id": 12345,
  "resolution_kind": "force_void",
  "operator_id": "alice",
  "resolution_reason": "Duplicate row confirmed via gateway audit log",
  "created_at_utc": "2026-07-12T18:23:51.000000000Z",
  "force_credit_matures_at_utc": null,
  "correction_deadline_at_utc": "2026-07-13T18:23:51.000000000Z"
}
```

The 200 body is a top-level resolution object mirroring the
inserted row. The 409 body is the §11 error envelope with
`existing_resolution` nested inside (§11.6.2) — different shape.

#### 11.6.2 Idempotency and corrective resolution rule

v0.5 removes `UNIQUE(request_credit_id)` but keeps idempotency at
the handler layer. A second same-kind POST against the same
`request_credit_id` — even with a different `reason` — MUST return
HTTP 409 `conflict` with this body:

```json
{
  "error": {
    "code": "already_resolved",
    "message": "row already resolved",
    "existing_resolution": {
      "request_credit_id": 12345,
      "resolution_kind": "force_void",
      "operator_id": "alice",
      "resolution_reason": "Duplicate row confirmed via gateway audit log",
      "created_at_utc": "2026-07-12T18:23:51.000000000Z",
      "force_credit_matures_at_utc": null,
      "correction_deadline_at_utc": "2026-07-13T18:23:51.000000000Z"
    }
  }
}
```

Exactly one opposite-kind correction is allowed while the hold
window is open. A `force_credit` row can be corrected to
`force_void` before `force_credit_matures_at_utc`. A `force_void`
row can be corrected to `force_credit` before that row's persisted
`correction_deadline_at_utc`. The latest row wins for current-state
projection. A third resolution attempt returns 409
`already_resolved`; an opposite-kind correction after the hold
window returns 409 `resolution_locked`.

The endpoint MUST also enforce, INSIDE the same `BEGIN IMMEDIATE`
transaction that performs the resolution INSERT:

- HTTP 404 `not_found` when no `ledger_request_credits` row has
  the given `id`.
- HTTP 422 `not_quarantined` when the row exists but
  `quarantined=0`.

Both checks happen on `ledger_request_credits` (the base ledger
row); they are NOT a TOCTOU pre-check on
`ledger_quarantine_resolutions`. The current-state lookup,
correction-window decision, resolution INSERT, and audit INSERT
MUST happen inside one `BEGIN IMMEDIATE` transaction.

**Conflict and SQLite error-class mapping.** When the lifecycle
decision or INSERT into `ledger_quarantine_resolutions` fails:

- Same-kind repeat or third resolution → HTTP 409
  `already_resolved`; the handler MUST re-read the latest row to
  populate `existing_resolution`.
- Opposite-kind correction after the hold window → HTTP 409
  `resolution_locked`; the handler MUST re-read the latest row to
  populate `existing_resolution`.
- `SQLITE_CONSTRAINT_CHECK` on the `resolution_kind` CHECK → HTTP
  500 `internal_error`. The endpoint MUST never insert any
  resolution kind outside `force_void` / `force_credit`; if a 500
  surfaces here it indicates an IMPL bug, not silent corruption.
- `SQLITE_CONSTRAINT_FOREIGN_KEY` → unreachable after the 404
  precondition; HTTP 500 `internal_error` if it surfaces.
- `SQLITE_CONSTRAINT_CHECK` on length checks → unreachable after
  endpoint validation; HTTP 500 `internal_error`.

#### 11.6.3 Reason-string sanitization

The `reason` field is written verbatim into the audit log and the
ledger table. Per-codepoint reject classes:

1. **UTF-8 well-formedness:** invalid sequences → HTTP 422
   `invalid_utf8`. (Reject before length-measurement.)
2. **ASCII control reject:** bytes `0x00..0x1F` (excluding `\t`,
   `\n`, `\r`) and `0x7F` → HTTP 422 `unsanitized_reason`.
3. **C1 control reject:** code points `U+0080..U+009F` → HTTP 422.
4. **Unicode bidi / format reject:** U+200E, U+200F, U+202A..U+202E,
   U+2066..U+2069 → HTTP 422.
5. **Unicode zero-width / BOM reject:** U+200B..U+200D, U+FEFF → HTTP 422.
6. **Unicode variation selectors / tag chars / private-use:**
   U+FE00..U+FE0F, U+180B..U+180D, U+E0000..U+E007F, U+E0080..U+E00FF,
   U+E000..U+F8FF, U+F0000..U+FFFFD, U+100000..U+10FFFD → HTTP 422.
7. **Unicode `Default_Ignorable_Code_Point` (DICP) set:** every
   codepoint with `Default_Ignorable_Code_Point=Yes` in Unicode
   16.0 `DerivedCoreProperties.txt` MUST be rejected with HTTP 422
   `unsanitized_reason`. The reference list (Unicode 16.0):
   - U+00AD (SOFT HYPHEN)
   - U+034F (COMBINING GRAPHEME JOINER)
   - U+061C (ARABIC LETTER MARK)
   - U+115F, U+1160 (HANGUL CHOSEONG/JUNGSEONG FILLER)
   - U+17B4, U+17B5 (KHMER vowel-inherent markers)
   - U+180B..U+180D (Mongolian variation selectors — also in #6)
   - U+180E (MONGOLIAN VOWEL SEPARATOR)
   - U+180F (MONGOLIAN FREE VARIATION SELECTOR FOUR — Unicode 14+)
   - U+200B..U+200F (zero-width + LRM/RLM — also in #4/#5)
   - U+202A..U+202E (bidi controls — also in #4)
   - U+2060..U+2064 (WORD JOINER + invisible operators)
   - U+2065 (reserved)
   - U+2066..U+2069 (bidi isolates — also in #4)
   - U+206A..U+206F (deprecated format chars — DICP per Unicode 16.0)
   - U+3164 (HANGUL FILLER)
   - U+FE00..U+FE0F (variation selectors — also in #6)
   - U+FEFF (ZWNBSP / BOM — also in #5)
   - U+FFA0 (HALFWIDTH HANGUL FILLER)
   - U+FFF0..U+FFF8 (reserved)
   - U+1BCA0..U+1BCA3 (Duployan shorthand format)
   - U+1D173..U+1D17A (musical-notation format chars)
   - U+E0000 (reserved; tag identifier)
   - U+E0001 (LANGUAGE TAG)
   - U+E0002..U+E001F (reserved tag range between LANGUAGE TAG
     and TAG SPACE; DICP=Yes per Unicode 16.0)
   - U+E0020..U+E007F (tag chars — also in #6)
   - U+E0080..U+E00FF (reserved tag range — also in #6)
   - U+E0100..U+E01EF (variation selectors supplement)
   - U+E01F0..U+E0FFF (reserved supplementary tag plane)
   The implementation MUST source this list from the Unicode 16.0
   `DerivedCoreProperties.txt` file (or equivalent shipped data)
   rather than re-deriving from the SPEC's enumerated ranges,
   because Unicode property assignments can shift between
   versions and the DICP=Yes set is the load-bearing identity. A
   future Unicode-version bump in the coordinator MUST re-extract
   the list; the SPEC pins Unicode 16.0 as the v0.4 reference.

Length is measured AFTER trimming whitespace (`\t \n \r \v \f` +
ASCII space), NOT raw byte length, BEFORE the per-codepoint
checks. Empty after trim → HTTP 422 `empty_reason`. Trimmed
length > 500 → HTTP 422 `reason_too_long`.

The `operator_id` field is subject to the same UTF-8 well-formedness
rule (1) and the same length-after-trim rule (1..64 instead of
1..500), plus the explicit charset restriction `[A-Za-z0-9_.-]`.
Any character outside that set → HTTP 422 `bad_operator_id`.

Implementation MUST use `json.Marshal` for the audit-log payload
(never hand-rolled JSON concatenation). The sanitizer is
REJECT-based, not transform-based.

#### 11.6.4 Audit-log emit (mandatory on success)

Every successful 200 response from §11.6.1 MUST write exactly one
row into the existing `audit_log` table (defined at
`phase4-coordinator/internal/audit/store.go` line 87) WITHIN the
same SQLite `BEGIN IMMEDIATE` transaction as the
`ledger_quarantine_resolutions` INSERT. Atomic on success; absent
on failure (audit-log INSERT failure MUST roll back the resolution
INSERT).

**Insertion-path requirement.** The audit row MUST be INSERTed
via the SAME `*sql.Tx` that performs the resolution INSERT —
directly via raw SQL against the `audit_log` table — NOT via the
`audit.Store.Insert(...)` helper. The `audit.Store` opens its own
`*sql.DB` handle (per `cmd/coordinator/main.go` line 153) so calls
through the helper cannot participate in the billing transaction.
The endpoint handler MUST emit the audit row as part of the
billing transaction by executing the equivalent
`INSERT INTO audit_log (ts_utc, event_type, provider_id, payload_json) VALUES (?, ?, ?, ?)`
statement on the resolution-INSERT `*sql.Tx`. The `audit_log`
table is shared (single SQLite database file); only the insertion
code path differs.

Event type: `ledger_quarantine_force_void`. Severity: WARN.
`provider_id` column equals the `provider_id` from the resolved
`ledger_request_credits` row. `ts_utc` equals the resolution's
`created_at_utc`.

`payload_json` MUST be a JSON object (built with `json.Marshal`)
with EXACTLY these fields:

| Field | Type | Source |
|---|---|---|
| `severity` | string | constant `"WARN"` |
| `operator_attribution` | string | constant `"operator_key_self_asserted"` — makes the limitation forensically explicit |
| `operator_id` | string | request body, post-sanitization (§11.6.3) |
| `request_credit_id` | integer (int64) | path parameter |
| `request_id` | string | `request_id` column of base row |
| `attempt_n` | integer (int64, >=0) | `attempt_n` column of base row |
| `provider_id` | string | `provider_id` column of base row |
| `quarantine_reason` | string \| null | `quarantine_reason` column of base row |
| `resolution_reason` | string | request body, post-sanitization |
| `ts_utc` | string (RFC3339Nano) | identical byte value to `ledger_quarantine_resolutions.created_at_utc` |

Severity is WARN because this is money-path operator action (it
modifies what `quarantined_count` returns, which is operator-
visible). The retention sweep (`audit.Store.PruneBefore`) treats
these like any other audit row.

**Operator attribution caveat.** `operator_id` is free-form input
from the POST body and is NOT bound to any authenticated
principal in v0.4 — the §11 operator-key authentication proves
only that some holder of the operator key made the call. The
`operator_attribution: "operator_key_self_asserted"` constant in
the payload makes this limitation visible to a forensic reader
who sees only the audit row.

**Config-flag flip auditing.** Every hot-reload-acknowledged
CHANGE to `billing.quarantine_resolution_force_void_enabled` or
`billing.quarantine_resolution_force_credit_enabled` — i.e., the
post-reload value differs from the pre-reload value —
MUST emit a separate audit-log row with `event_type =
"billing_config_flag_changed"`, payload `{"flag":
"quarantine_resolution_force_void_enabled"|"quarantine_resolution_force_credit_enabled", "old_value": <bool>,
"new_value": <bool>, "reload_source": "sighup"|"http_reload",
"ts_utc": "<RFC3339Nano>"}`. The `reload_source` enum is
restricted to actual reload mechanisms; v0.5 does NOT emit at
startup, because "no prior acknowledged value" has no defined
`old_value` and the startup `ledger_config_snapshots` row already
captures the initial state. A reload that ACKNOWLEDGES the same
value (no change) MUST NOT emit. This is in addition to the
existing `ledger_config_snapshots` row §13.2 already requires;
it surfaces the flip as a discrete WARN event so an audit-log
scan can correlate quarantine resolutions to the flag state at
the time.

#### 11.6.5 Reader-side composition (SPEC-007 explorer and §11 aggregates)

v0.4's force-void resolution does NOT add a row to the payable
set. v0.5's force-credit resolution adds a row to the payable set
only after the hold matures and only while `force_credit` is the
latest resolution. Included aggregations and §7 settlement MUST use
the `spec022_payable_request_credits` projection rather than a raw
`quarantined=0` filter. The OPEN aggregation remains a count of
quarantined rows with no resolution history. SPEC-007 explorer
detail MUST expose both the latest/current resolution and ordered
history after v0.5 removes `UNIQUE(request_credit_id)`.

Define one reusable SQL fragment:

```sql
-- OPEN set: quarantined rows awaiting operator decision.
OPEN_PREDICATE :=
  (ledger_request_credits.quarantined = 1
   AND NOT EXISTS (SELECT 1
                     FROM ledger_quarantine_resolutions r
                    WHERE r.request_credit_id = ledger_request_credits.id))
```

Force-voided rows are a resolved-and-excluded third state: still
have `quarantined=1` in the base table, have a corresponding row
in `ledger_quarantine_resolutions` with `resolution_kind = 'force_void'`,
and match NEITHER the v0.3.3 `quarantined=0` payable filter NOR
the new `OPEN_PREDICATE`.

Concrete touch-list:

| Reader | v0.3.3 filter | v0.5 filter |
|---|---|---|
| §11.1 `total_gross_credits`, `total_provider_credits`, `total_operator_credits`, `current_window_provider_credits` | `WHERE quarantined=0` | use `spec022_payable_request_credits` |
| §11.1 `quarantined_count` | `WHERE quarantined=1` | `WHERE OPEN_PREDICATE` — narrows to exclude voided rows |
| §11.2 per-provider rollup credits | `WHERE quarantined=0` | use `spec022_payable_request_credits` |
| §11.2 per-provider `quarantined_count` | `WHERE quarantined=1` | `WHERE OPEN_PREDICATE` |
| §11.3 reconcile `provider_gross_credits`, `buyer_equivalent_credits` | `WHERE quarantined=0` | use `spec022_payable_request_credits` |
| §11.3 reconcile `rows_quarantined` | `WHERE quarantined=1` | `WHERE OPEN_PREDICATE` |
| §11.4 `/providers/{id}/earnings` `total_credits`, `current_window_credits` | `WHERE quarantined=0` | use `spec022_payable_request_credits` |
| §7 settlement sweep | `WHERE quarantined=0` | materialize one run-local eligible set equivalent to `spec022_payable_request_credits`, plus §7.4.1 old-window protection |
| SPEC-007 explorer quarantined-row detail view | `WHERE quarantined=1` (no resolution data) | current projection uses the latest row by `(created_at_utc DESC, id DESC)`; history projection returns all rows ordered by `(created_at_utc ASC, id ASC)` |

The §11.3 reconcile response also gains a new top-level field
`rows_force_resolved_in_range` (integer, COUNT of
`ledger_quarantine_resolutions` rows with `created_at_utc` in
[from_utc, to_utc]). v0.5 counts both `force_void` and
`force_credit` resolutions.

The §10.3 AC-H005 `delta_gross_credits` contract remains clean-range
zero. Force-void rows stay excluded from provider gross. Force-credit
rows shift into provider gross only after maturity, through the same
`spec022_payable_request_credits` projection used by §11 and §7.

#### 11.6.6 Rate limit, concurrency, and threat-model notes

The endpoint shares the existing `/admin/*` rate-limit posture
(per §11 preamble — operator key, /admin/* bucket). Authentication
runs before the operator-key bucket so unauthenticated traffic cannot
drain authenticated admin capacity. After successful operator-key
authentication, every response code path — 200, 4xx, 5xx — consumes
the SAME bucket; authenticated failure responses (404, 409, 422, etc.)
do NOT bypass.

Concurrent POSTs against the same `request_credit_id` race at the
UNIQUE constraint layer: SQLite's serialization yields exactly
one INSERT success (200) and one or more 409 conflicts. The
endpoint MUST NOT pre-check existence in
`ledger_quarantine_resolutions` and then INSERT — TOCTOU race.
Single `INSERT … ON CONFLICT(request_credit_id) DO NOTHING
RETURNING …` (or equivalent: catch SQLITE_CONSTRAINT_UNIQUE on
a bare INSERT) is the correct shape.

**Threat-model acceptances (v0.4).**

1. **Operator-key user enumeration of `request_credit_id`.**
   Distinct 404 / 422 `not_quarantined` / 409 status codes reveal
   whether an ID exists / is quarantined / already resolved. The
   endpoint is `/admin/*`-gated; the status distinction is
   operator UX (different remediation paths), accepted under the
   v0.4 threat model.
2. **Self-asserted `operator_id`.** Per §11.6.4: the audit trail
   proves operator-KEY use, not human identity. The
   `operator_attribution` constant in the payload makes the
   limitation forensically explicit.
3. **Money-out risk bounded by hold.** Force-credit can produce a
   payable row only after the hold elapses. A mistaken force-credit
   can be corrected to force-void during that window; settlement
   snapshots acquire `BEGIN IMMEDIATE` so a correction cannot
   interleave with payout-ready materialization.

## 12. Buyer-balance interaction (D7)

This section implements the locked buyer-balance decision (D7) by leaving buyer balance enforcement to SPEC-006 and crediting providers for legitimate completed work regardless of buyer quota state.

SPEC-005 does not enforce buyer quota.
SPEC-006 gateway quota is authoritative.
If the gateway forwarded and the provider performed work, provider credit follows section  6.
Over-quota overshoot does not zero provider credit.
Operator recourse is quota tuning, not provider clawback.

## 13. Configuration

This section implements D2-D6 and D9 config commitments (D2)(D3)(D4)(D5)(D6)(D9) by keeping the cadence, threshold, rate card, multiplier, split, and recovery windows in coordinator.yaml with immutable row snapshots.

All SPEC-005 configuration lives in coordinator.yaml.
Config changes affect only new request-credit rows.

| Key | Type | Default | Notes |
|---|---|---|---|
| `rewards.global_multiplier` | number | `1.0` | operator volume knob; parse to PPM |
| `rewards.provider_share` | number | `0.90` | parse to provider_share_bps=9000 |
| `rewards.rate_card.default.prompt_credits_per_mtok` | integer | `500000` | default prompt rate |
| `rewards.rate_card.default.completion_credits_per_mtok` | integer | `1000000` | default completion rate |
| `rewards.rate_card.default.prompt_cache_hit_credits_per_mtok` | integer | *unset* → prompt rate | default cache-hit rate for prefix-cache-reused prompt tokens (SPEC-024); **when unset, cached tokens bill at the full prompt rate — no discount** (§5.3, §5.5). Config load enforces `0 <= value <= prompt_credits_per_mtok` (§5.3.1); a value above the prompt rate or negative fails startup. |
| `rewards.rate_card.<model>.prompt_credits_per_mtok` | integer | `model-specific` | enumerated model prompt rate |
| `rewards.rate_card.<model>.completion_credits_per_mtok` | integer | `model-specific` | enumerated model completion rate |
| `rewards.rate_card.<model>.prompt_cache_hit_credits_per_mtok` | integer | *unset* → prompt rate | enumerated model cache-hit rate (SPEC-024); unset ⇒ full prompt rate |
| `settlement.cadence_days` | integer | `7` | weekly cadence |
| `settlement.min_payout_credits` | integer | `500000` | threshold |
| `settlement.startup_reconcile_window_hours` | integer | `24` | startup scan window |
| `settlement.nightly_reconcile_window_days` | integer | `7` | nightly scan window |
| `settlement.recovery_grace_seconds` | integer | `30` | recovery scan grace cutoff |
| `settlement.job_enabled` | boolean | `true` | test-disable switch for scheduler only |
| `billing.quarantine_resolution_force_void_enabled` | boolean | `false` | route-layer gate for force-void |
| `billing.quarantine_resolution_force_credit_enabled` | boolean | `false` | route-layer gate for force-credit |
| `billing.force_credit_settlement_hold_seconds` | integer | `86400` | pre-payout hold for force-credit maturity; zero/missing uses the default |
| `endpoints.provider_earnings.rate_limit_per_minute` | integer | `60` | per-provider read limit for earnings endpoint |

The coordinator SQLite database MUST run in WAL mode (`journal_mode = WAL`). SPEC-005 behavior is undefined under `journal_mode = DELETE`.

### 13.1 Initial placeholder rate card

| Model class | prompt credits/Mtok | completion credits/Mtok |
|---|---:|---:|
| 7B, e.g. `mlx-community/Qwen2.5-7B-Instruct-4bit` | 1000000 | 2000000 |
| 3B, e.g. `mlx-community/Llama-3.2-3B-Instruct-4bit` | 500000 | 1000000 |
| default | 500000 | 1000000 |

### 13.2 Hot reload

New values apply only after reload acknowledgement.
Rows snapshot the applied values.
The coordinator MUST insert a `ledger_config_snapshots` row on startup and after each valid reload acknowledgement.
Invalid reload keeps prior valid config.
Cold start without default rate-card row fails.
Recovery MUST use historical `ledger_config_snapshots`; it MUST NOT price old request_log rows from a newer acknowledged config.

**v0.5 route-layer flags and hold (issue #253).** The
`billing.quarantine_resolution_force_void_enabled` and
`billing.quarantine_resolution_force_credit_enabled` booleans are
route-layer hot-reload settings: a flip applies on the next inbound
HTTP request, NOT just to "new request-credit rows" as the
pre-v0.4 hot-reload prose implied. Each flip is recorded in
`ledger_config_snapshots` (existing §4.7 mechanism) AND emits an
explicit WARN audit-log row per §11.6.4 "Config-flag flip
auditing". The coordinator MUST treat the flags as
strictly-additive: the GET-summary path (§11.1
`quarantined_count`) reads the same database regardless of flag
values; only the POST §11.6.1 endpoints observe their flags.
`billing.force_credit_settlement_hold_seconds` is snapshotted with
the route flags and applies to subsequently inserted force-credit
resolution rows.

## 14. Instrumentation and metrics

- Metric: per-provider total credits. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: current-window credits. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: pending payout-ready rows. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: pending payout-ready credits. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: quarantined rows. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: breaker-qualifying faults. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: null-usage zero-credit rows. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: startup recovery rows. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: nightly recovery rows. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: reconciliation delta. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: rate-card default fallback count. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: unknown model count. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: settlement job duration. Source: section  11 endpoints. No new metrics surface in v1.
- Metric: idempotent settlement replay count. Source: section  11 endpoints. No new metrics surface in v1.

## 15. Backward compatibility

### 15.1 Pre-v1.2.4 cancel usage

Use byte-estimation fallback only when usage is absent.
Use the §5.3 byte estimate: `ceil(bytes_emitted_so_far / tier2.output_bytes_per_token_ceiling)` (default 16; the prior `/4` is superseded — runbook item 2 / § 6.8).
Set usage_source=byte_estimated.

### 15.2 attempt_n derivation

**SPEC-005 v0.3.3 / SPEC-002 v1.5.2 (issue #168) — current rule:** the canonical attempt ordinal is `request_log.attempt_n` (populated at INSERT time by the writer as `COUNT(*) FROM request_log WHERE account_id IS ? AND request_id = ?` within the same writer transaction). Read-side consumers (SPEC-005 §8.2, §10.4, §15.2 itself) MUST copy `request_log.attempt_n` directly when non-NULL.

**Legacy fallback (v0.3.1 / SPEC-002 v1.5.0 / issue #211) — retained for the v1.5.2 rollout window:** when `request_log.attempt_n IS NULL` (pre-v1.5.2 row OR rollback window), rows are grouped by `(account_id, request_id)` (using SQLite `IS` so legacy NULL-`account_id` rows cluster identically to pre-v0.3.1 behavior) and ordered within each group by `request_log.id ASC`. The first ordered row maps to `attempt_n=0`; the second to `attempt_n=1` only with explicit `retried` semantics; the third and later receive `attempt_n=2, 3, ...` from the same deterministic id-ASC arithmetic and are credited normally — byte-identical to what the writer would have persisted under v1.5.2.

**Migration acceptance:** on a backfilled deployment (operator has run `backfill-attempt-n` and `--check` reports `populated`), the legacy fallback path is unreachable in steady state but remains in IMPL code as a defense against future schema-rollback windows. Both paths produce byte-identical ordinals because the writer's INSERT-time COUNT and the fallback's read-time COUNT compute the same value over the same row set.

The only steady-state quarantine class under v0.3.3 is `attempt_n=1` with `retried=0` (legitimate retry without explicit marker), resolved via the SPEC-005 §OQ-5 admin surface (issue #169).

### 15.3 Unknown models

Use default rate-card row.
Snapshot default rates on row.
Expose fallback count to operator metrics.

### 15.4 Missed settlement

Rerun is safe.
Idempotency key prevents duplicate payout-ready rows.
All unsettled rows up to window end are included.

## 16. Security and privacy

This section implements the locked billing, unit, and visibility decisions (D1)(D6)(D11) by keeping SPEC-005 economics internal, authenticated, and credit-denominated.

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

**v0.4 (issue #169) audit-log event types.** Two new `audit_log.event_type`
values are introduced:
- `ledger_quarantine_force_void` — emitted per §11.6.4 on every
  successful 200 from `POST /admin/ledger/quarantine/{id}/force-void`.
- `billing_config_flag_changed` — emitted per §11.6.4 on every
  hot-reload-acknowledged change to
  `billing.quarantine_resolution_force_void_enabled` (and any
  future quarantine-resolution flag added by a later SPEC bump).
Both are severity WARN. Both are written through the billing
store's `*sql.Tx` (not via `audit.Store.Insert`) per §11.6.4
insertion-path requirement, so they share atomicity with the
operational write (resolution INSERT or config-snapshot row).

## 17. Failure modes

Endpoint failures MUST return the section  11 JSON error envelope and no ledger data.

| Failure | Surface | Result | Required behavior |
|---|---|---|---|
| Admin key invalid | /admin/ledger/* | 403 | JSON envelope; no ledger data |
| Admin key missing | /admin/ledger/* | 403 | JSON envelope; no ledger data |
| Provider token missing | /providers/{provider_id}/earnings | 401 | JSON envelope; no provider data |
| Provider token invalid | /providers/{provider_id}/earnings | 401 | JSON envelope; no provider data |
| Provider token wrong subject | /providers/{provider_id}/earnings | 403 | JSON envelope; no provider data |
| Provider tokens disabled in deployment | /providers/{provider_id}/earnings | route disabled | provider economics available only through `/admin/ledger/providers` |
| Unknown provider_id | /providers/{provider_id}/earnings | 404 | JSON envelope; no enumeration |
| Provider earnings read limit exceeded | /providers/{provider_id}/earnings | 429 | JSON envelope; no provider data |
| Settlement crash before payout row | settlement goroutine | retry | source rows remain unsettled |
| Settlement crash after payout row | settlement goroutine | repair | rerun marks matching source rows |
| Missing ledger row | startup/nightly | repair | write deterministic recovery row |
| WAL mode missing | coordinator startup | startup failure | fail fast before SPEC-005 ledger work |
| Orphan ledger row | startup/nightly | quarantine | quarantined=1 |
| Missing default rate | config load | startup failure | unknown models cannot be priced |
| Invalid multiplier | config reload | reload failure | keep prior valid config |
| audit_log INSERT fails during quarantine-resolution POST (v0.5) | /admin/ledger/quarantine/{id}/force-void or /force-credit | 500 `internal_error` | the same `BEGIN IMMEDIATE` transaction MUST roll back; no resolution row inserted; no audit row written; client retry safe |
| Same-kind already-resolved row hit by second POST (v0.5) | /admin/ledger/quarantine/{id}/force-void or /force-credit | 409 `already_resolved` | response includes latest `existing_resolution`; no second same-kind resolution row; no second audit row; rate-limit bucket charged |
| Correction after hold expires (v0.5) | /admin/ledger/quarantine/{id}/force-void or /force-credit | 409 `resolution_locked` | response includes latest `existing_resolution`; no corrective row; no audit row |
| Route flag disabled (v0.5) | /admin/ledger/quarantine/{id}/force-void or /force-credit | 404 `not_found` | same body as row-not-found 404; no flag-leak; no resolution INSERT; no audit row |

## 18. Acceptance criteria

Every AC is deterministic and requires no live network.
Fixtures may use in-memory SQLite, temporary SQLite, or pure functions.

### AC-D1: Billing model encoded

**Traceability verification:** Parse section  2 and locate D1; then locate at least one later normative reference.
**Behavior verification:** Run SPEC-005 migrations in an empty SQLite fixture and inspect tables.
**Expected:** D1 exists in section  2, is enforced outside section  2, and no buyer revenue, Stripe, checkout, donation, tip-jar, or payment-collection table is created by SPEC-005 migrations.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D2: Settlement cadence encoded

**Traceability verification:** Parse section  2 and locate D2; then locate at least one later normative reference.
**Behavior verification:** Seed a completed request and run the hot path, then run settlement before and at the UTC Monday boundary.
**Expected:** D2 exists in section  2, is enforced outside section  2, completed request credits accrue immediately, and payout-ready rows emit only at the weekly boundary.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D3: Provider reward formula encoded

**Traceability verification:** Parse section  2 and locate D3; then locate at least one later normative reference.
**Behavior verification:** Price one known-model row and one unknown-model row through the section  5.3 formula.
**Expected:** D3 exists in section  2, is enforced outside section  2, known-model rates are used, unknown model uses the default row, and the prompt/completion rates + multiplier + share are snapshotted on the credit row. **Exception (v0.6, §5.5):** the prompt-**cache-hit** rate has no `ledger_request_credits` column; it is snapshotted only in `ledger_config_snapshots.rate_card_json`, reachable from the credit row via `ledger_provider_identity_snapshots.config_snapshot_id`. A discounted-cache row therefore snapshots its cache-hit rate in the config snapshot, not the credit row.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D4: Minimum payout threshold encoded

**Traceability verification:** Parse section  2 and locate D4; then locate at least one later normative reference.
**Behavior verification:** Run settlement with provider totals one credit below and exactly at settlement.min_payout_credits.
**Expected:** D4 exists in section  2, is enforced outside section  2, below-threshold credits roll forward unsettled, and at-threshold credits emit one payout-ready row.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D5: Revenue split encoded

**Traceability verification:** Parse section  2 and locate D5; then locate at least one later normative reference.
**Behavior verification:** Create one row at provider_share_bps=9000, reload share to 9500, then create a second row.
**Expected:** D5 exists in section  2, is enforced outside section  2, each row satisfies provider_credits + operator_credits == gross_credits, and the historical row remains immutable after the share change.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D6: Currency / unit encoded

**Traceability verification:** Parse section  2 and locate D6; then locate at least one later normative reference.
**Behavior verification:** Inspect the SQLite schema and run formula fixtures with half, below-half, and above-half remainders.
**Expected:** D6 exists in section  2, is enforced outside section  2, economic columns are INTEGER, no REAL/FLOAT economic storage exists, and rounding is exact round half to even.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D7: Buyer balance enforcement encoded

**Traceability verification:** Parse section  2 and locate D7; then locate at least one later normative reference.
**Behavior verification:** Seed a SPEC-006 over-quota overshoot row that reached a provider with reported usage.
**Expected:** D7 exists in section  2, is enforced outside section  2, provider credit follows section  6, and provider credit is greater than 0 for legitimate completed work that reached a provider.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D8: Failed-request accounting encoded

**Traceability verification:** Parse section  2 and locate D8; then locate at least one later normative reference.
**Behavior verification:** Run the full SPEC-006 section  17.7 D3 matrix through the section  6 classifier.
**Expected:** D8 exists in section  2, is enforced outside section  2, every buyer-debit state maps to the matching provider-credit action, null-usage errors produce zero-credit audit rows, and provider-not-reached produces no ledger rows.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D9: Crash recovery policy encoded

**Traceability verification:** Parse section  2 and locate D9; then locate at least one later normative reference.
**Behavior verification:** Run the same startup recovery input twice, including request_log rows, ledger rows, config snapshots, identity snapshots, and scan window.
**Expected:** D9 exists in section  2, is enforced outside section  2, output is byte-identical for the same state pair, no live network is called, and missing config or identity snapshots quarantine instead of guessing.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D10: Multi-provider attribution encoded

**Traceability verification:** Parse section  2 and locate D10; then locate at least one later normative reference.
**Behavior verification:** Seed two rows that share the same `(account_id, request_id)` group, ordered by request_log.id ASC, plus matching provider identity snapshots. (Legacy fixtures may use NULL `account_id` on both rows; SQLite `IS` clusters NULLs.)
**Expected:** D10 exists in section  2, is enforced outside section  2, rows receive distinct `attempt_n`/`provider_id` keys (`attempt_n=0, 1, 2, ...` monotonically from `request_log.attempt_n` when populated, or from the byte-identical id-ASC fallback when NULL), row 2 is accepted only with explicit `retried` semantics (else quarantined), and row 3+ is credited normally under SPEC-005 v0.3.3 / SPEC-002 v1.5.2.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D11: Operator dashboard scope encoded

**Traceability verification:** Parse section  2 and locate D11; then locate at least one later normative reference.
**Behavior verification:** Invoke all four handlers with fixture stores and with missing or wrong credentials.
**Expected:** D11 exists in section  2, is enforced outside section  2, each handler returns the documented JSON shape, admin failures use the error envelope, provider subject mismatch returns 403, unknown provider returns 404, and no HTML/charts are emitted.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-D12: Fraud floor for degraded providers encoded

**Traceability verification:** Parse section  2 and locate D12; then locate at least one later normative reference.
**Behavior verification:** Seed an FR-P11a breaker-qualifying fault, a buyer cancel, and a provider that returns ready after recovery preflight.
**Expected:** D12 exists in section  2, is enforced outside section  2, breaker-qualified work is zero-credit, buyer cancel is not fault-zeroed, degraded/unavailable providers receive no new earning rows, and normal credits resume after recovery preflight.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-H005: H-005 symmetry

**Verification:** Construct all nine SPEC-006 v0.9.8 section  17.7 states and run the section  6 credit function.
**Expected:** Each buyer-debit state has the specified provider-credit state; provider-not-reached writes no row; null-usage errors write zero-credit rows; cross-process states disclaimed in section  10.6 are excluded; delta_gross_credits equals 0 for a clean SPEC-005-owned range; provider/operator splits satisfy provider_credits + operator_credits == gross_credits per row.
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
**Expected:** estimated_completion_tokens=8 by `ceil(bytes_emitted_so_far / tier2.output_bytes_per_token_ceiling)` = ceil(120/16) = 8 (default ceiling; the prior `/4`→30 is superseded, § 6.8) and gross includes 8 completion.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-NULL-PROMPT: Null prompt and completion zero credit

**Verification:** Fixture prompt_tokens=NULL, completion_tokens=NULL, and error_code=`error_internal`.
**Expected:** One ledger row is written with gross_credits=0, provider_credits=0, operator_credits=0, and usage_source=`null_error`; section  5.3 formula is not evaluated on NULL operands.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-PROMPT-BOUND: Charged prompt bounded to coordinator estimate (§5.3.2)

**Verification:** Price a row whose attributed prompt (`provider_reported_prompt_tokens`) **exceeds** the coordinator `PromptTokenUpperBound`, and a second row whose attributed prompt is at or below the bound. Cover both a provider-reported prompt and a coordinator-substituted prompt (prompt absent on a `byte_estimated`/502/504 path).
**Expected:** For the over-bound row, `prompt_tokens = charged_prompt_tokens = PromptTokenUpperBound` (the raw/attributed value preserved separately in `provider_reported_prompt_tokens`) and §5.3 prices the bounded value; for the at/below-bound row the value passes through unchanged; a NULL bound (legacy/recovery) passes through unbounded. Store order is `prompt_tokens = charged_prompt_tokens = min(attributed, bound)` with `provider_reported_prompt_tokens` = the raw/substituted attribution. The **`ledger_provider_identity_snapshots.provider_reported_prompt_tokens`** mirror MUST carry the same reported-or-substituted attribution as the credit-row column (§4.8), including for the substituted-prompt case.
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

**Verification:** Fixture two providers and one logical request sharing the same `(account_id, request_id)` group (single account; cross-account fixtures need their own account scope per v0.3.1).
**Expected:** Two rows with distinct attempt_n/provider_id keys from identity snapshots; sums match attempt totals.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-ATTEMPT-FALLBACK: retried fallback limit

**Verification:** Fixture three rows sharing the same `(account_id, request_id)` group under SQLite `IS` clustering (legacy NULL-`account_id` fixtures cluster identically among themselves). One fixture variant pre-populates `request_log.attempt_n` (post-v1.5.2 schema); a second variant leaves `attempt_n` NULL to exercise the id-ASC fallback derivation.
**Expected:** Both fixtures produce identical ordinals: row 1 → `attempt_n=0`; row 2 → `attempt_n=1` accepted only with explicit `retried` semantics (else quarantined as legitimate-retry-without-marker); row 3 → `attempt_n=2` credited normally (per SPEC-005 v0.3.3 / SPEC-002 v1.5.2). The persisted-attempt_n path and the id-ASC fallback path are byte-identical.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-CRASH: ACID crash boundary

**Verification:** Abort a transaction before COMMIT and commit a second transaction.
**Expected:** Abort leaves no partial rows; commit leaves request_log plus ledger rows.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-WAL: WAL mode required

**Verification:** Coordinator startup runs `PRAGMA journal_mode` against the SQLite fixture.
**Expected:** Startup asserts `journal_mode = WAL` and fails fast otherwise.
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-STARTUP-SCAN: Startup scan recovery

**Verification:** Seed a prior-24h creditable request_log row without ledger row.
**Expected:** Exactly one startup_scan recovery row using the historical config snapshot and provider identity snapshot.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-NIGHTLY: Nightly reconcile recovery

**Verification:** Seed a prior-7d row outside startup window without ledger row.
**Expected:** Exactly one nightly_reconcile recovery row using the historical config snapshot and provider identity snapshot.
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

### AC-PAYOUT-CLAIM-CONTRACT: payout-ready consumer contract

**Verification:** Seed a `ready` payout row, run the section  4.5.1 claim pattern once, then run it a second time and attempt a mutation from a terminal state.
**Expected:** First claim changes `ready` to `consumed` and appends a `ledger_reconciliation_runs` row with `run_type='spec_007_claim'`; second claim affects 0 rows; `voided` is terminal and cannot transition; the future payout-rail spec MUST NOT pay on a 0-row claim.
**Network:** Not required.
**State reset:** Fresh fixture database.

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

### AC-Q040: Quarantine resolution table shape (v0.5 §4.10)

**Verification:** Inspect SQLite schema after MIG-005-011.
**Expected:** Table `ledger_quarantine_resolutions` exists with columns `id`, `request_credit_id`, `resolution_kind`, `operator_id`, `resolution_reason`, `created_at_utc`, `force_credit_matures_at_utc`, `correction_deadline_at_utc`; no `UNIQUE(request_credit_id)`; CHECK constraints per §4.10 including `CHECK(resolution_kind IN ('force_void','force_credit'))`; `idx_lqr_kind_created` and `idx_lqr_request_latest` present.
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-Q042: Force-void happy path (v0.4 §11.6.1)

**Verification:** Seed a `ledger_request_credits` row with `quarantined=1`, `gross_credits=10000`, `provider_credits=9000`. With `billing.quarantine_resolution_force_void_enabled = true`, POST `/admin/ledger/quarantine/{id}/force-void` with valid operator_key + body `{"operator_id":"alice","reason":"Duplicate row confirmed"}`.
**Expected:** HTTP 200 with response mirroring the inserted resolution row. One row in `ledger_quarantine_resolutions` with `resolution_kind='force_void'`. One row in `audit_log` with `event_type='ledger_quarantine_force_void'` and the §11.6.4 payload shape (including `operator_attribution: "operator_key_self_asserted"`). Base row's `quarantined` column unchanged (=1). Provider earnings (§11.4) and §11.1 `total_provider_credits` are UNCHANGED (force-void doesn't add the row to the payable set; it just removes it from `quarantined_count`).
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-Q043: Idempotent conflict and corrective resolution (v0.5 §11.6.2)

**Verification:** With route flags enabled, issue two sequential same-kind POSTs against the same `request_credit_id`; also drive two concurrent same-kind POSTs from separate clients against the same id. Separately, issue `force-credit` followed by `force-void` before maturity, then attempt a third resolution. Separately, attempt `force-credit` followed by `force-void` after maturity.
**Expected:** Same-kind repeats produce exactly one current resolution and return HTTP 409 with `code: "already_resolved"` and the existing/latest resolution body. The hold-window opposite-kind correction appends exactly one second row; latest row wins for current projection. A third resolution returns 409 `already_resolved`. A correction after maturity returns 409 `resolution_locked`. No losing/conflict path writes an extra `audit_log` row.
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-Q044: Validation rejection (v0.4 §11.6.3, §11.6.1.1)

**Verification:** With the route flag enabled, POST each malformed body in turn: (a) missing `operator_id`, (b) `reason` containing ASCII ESC (0x1b), (c) `reason` containing C1 CSI (U+009B), (d) invalid UTF-8 sequence, (e) `reason` whitespace-only after trim, (f) `reason` 501 chars after trim, (g) Content-Type `text/plain`, (h) body 4 KiB + 1, (i) row not found (`/quarantine/999999/force-void`), (j) row exists with `quarantined=0`, (k) `reason` containing U+202E (RLO bidi), (l) `reason` containing U+200B (ZWSP), (m) `reason` containing U+034F (CGJ — default-ignorable), (n) `operator_id` containing space (outside allowed charset).
**Expected:** (a) HTTP 422 `missing_field`. (b,c) HTTP 422 `unsanitized_reason`. (d) HTTP 422 `invalid_utf8`. (e) HTTP 422 `empty_reason`. (f) HTTP 422 `reason_too_long`. (g) HTTP 415. (h) HTTP 413 `request_too_large`. (i) HTTP 404 `not_found`. (j) HTTP 422 `not_quarantined`. (k,l,m) HTTP 422 `unsanitized_reason`. (n) HTTP 422 `bad_operator_id`. No `ledger_quarantine_resolutions` row inserted in any case. No `audit_log` row in any case.
**Network:** Not required.
**State reset:** Fresh fixture database per scenario.

### AC-Q045: Reader-side narrowing (v0.4 §11.6.5)

**Verification:** Seed THREE rows in `ledger_request_credits`: (a) `quarantined=0`, (b) `quarantined=1` with no resolution, (c) `quarantined=1` with a `force_void` resolution row. Hit `/admin/ledger/summary` and `/providers/{id}/earnings`.
**Expected:** `total_provider_credits` covers (a) ONLY — UNCHANGED from v0.3.3 semantics. `quarantined_count` = 1 (row (b) only — `OPEN_PREDICATE`). Provider earnings `total_credits` covers (a) ONLY. Row (c) contributes to NEITHER total: not payable (force-void), not open (resolved).
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-Q047: Same-transaction audit atomicity (v0.4 §11.6.4)

**Verification:** Patch the resolution-INSERT handler to fault between the `ledger_quarantine_resolutions` INSERT and the `audit_log` INSERT (inject a transaction error after the first INSERT). Issue a force-void POST.
**Expected:** HTTP 500 `internal_error`. SELECT on `ledger_quarantine_resolutions` shows zero rows for that `request_credit_id`. SELECT on `audit_log` shows zero rows for that `request_credit_id` payload. A retry (without the fault injection) succeeds with HTTP 200 — no UNIQUE conflict because the first attempt rolled back fully.
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-Q048: Method enforcement (v0.4 §11.6.1)

**Verification:** With route flag enabled, issue GET, PUT, DELETE, PATCH against `/admin/ledger/quarantine/12345/force-void` with valid operator key.
**Expected:** Every non-POST returns HTTP 405 `method_not_allowed`. No resolution INSERT in any case. No audit row in any case.
**Network:** Not required.
**State reset:** Fresh fixture database (row 12345 quarantined).

### AC-Q049: Concurrent same-kind conflict mapping (v0.5 §11.6.2, §11.6.6)

**Verification:** With route flag enabled, seed a `quarantined=1` row. Fire 64 parallel POST `/force-void` requests against it from independent client goroutines, each with a distinct `reason` value.
**Expected:** Exactly one 200 response. Exactly 63 × 409 `already_resolved` responses, each with `existing_resolution` populated with the winner's identity. SELECT on `ledger_quarantine_resolutions` returns exactly one row. SELECT on `audit_log` returns exactly one row of `event_type='ledger_quarantine_force_void'`. The implementation MUST serialize the lifecycle decision and INSERT in one `BEGIN IMMEDIATE` transaction. All 64 authenticated responses count against the `/admin/*` rate-limit bucket.
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-Q050: SPEC-007 explorer current and history projection (v0.5 §11.6.5)

**Verification:** Seed three rows: (a) `quarantined=0`, (b) `quarantined=1` with no resolution, (c) `quarantined=1` with two resolution rows: first `force_credit`, then corrective `force_void`. Hit the SPEC-007 explorer detail view for each.
**Expected:** (a) view returns base columns; current resolution fields are absent or JSON null and history is empty. (b) same as (a). (c) current projection returns the latest row (`force_void`) using the `resolution_*` aliases; history projection returns both rows in chronological order with the original `force_credit` before the corrective `force_void`.
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-Q051: Reconcile `rows_force_resolved_in_range` (v0.4 §11.6.5)

**Verification:** Seed eight `quarantined=1` rows over a 7-day window. Force-void five within the window; leave three open. Hit `/admin/ledger/reconcile?from=…&to=…` over that window.
**Expected:** Response includes `rows_force_resolved_in_range: 5`. `provider_gross_credits` is UNCHANGED from the pre-force-void value (force-void doesn't shift the payable sum). `delta_gross_credits == 0`. `rows_quarantined: 3` (open ones only — voided rows excluded per `OPEN_PREDICATE`).
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-Q053: Route-layer config flag gates (v0.5 §11.5 / §13.2)

**Verification:** With both route flags false by default, POST `/force-void` and `/force-credit` against valid quarantined rows. Config-reload either flag to true and POST that endpoint again. Config-reload back to false and POST a third time against a DIFFERENT quarantined row.
**Expected:** Disabled endpoints return HTTP 404 `not_found` with the §11.6.1.1 envelope; no resolution INSERT; no audit row. Enabled endpoints return HTTP 200 with a fresh resolution row + audit row. Re-disabled endpoints return HTTP 404 again. The 404 body for the disabled-flag case is byte-identical to the row-not-found 404 body — no leak of which case fired. After each flag flip, a separate `audit_log` row exists with `event_type='billing_config_flag_changed'` carrying the flag name, old/new values, and reload-source per §11.6.4.
**Network:** Not required.
**State reset:** Fresh fixture database; config-reload primitive exercised between scenarios.

### AC-Q055: Force-credit hold and payable inclusion (v0.5 §11.6.1)

**Verification:** Seed a quarantined `ledger_request_credits` row, enable `billing.quarantine_resolution_force_credit_enabled`, POST `/admin/ledger/quarantine/{id}/force-credit`, and inspect `spec022_payable_request_credits` before and after `force_credit_matures_at_utc`.
**Expected:** The POST returns HTTP 200, writes `resolution_kind='force_credit'`, sets `force_credit_matures_at_utc = created_at_utc + billing.force_credit_settlement_hold_seconds`, sets `correction_deadline_at_utc` at INSERT time, and emits `ledger_quarantine_force_credit`. Before maturity the row is absent from `spec022_payable_request_credits`. After maturity, if force-credit remains the latest resolution, the row appears in `spec022_payable_request_credits` while the base `ledger_request_credits.quarantined` marker remains 1. **Force-credit MUST NOT recompute credits:** the re-admitted row's `gross_credits`/`provider_credits` equal the stored values unchanged (zero for a hot-path/receipt cache-quarantine row; the pre-existing non-zero value for a recovery-flagged row — §2.7).
**Network:** Not required.
**State reset:** Fresh fixture database.

### AC-CACHE-QUARANTINE-CREDIT-EFFECT: Path-dependent cache-quarantine credits (v0.6 §2.7)

**Verification:** Drive the four cache-quarantine write shapes: (a) hot-path `ambiguous_cache` first-write; (b) §7.5b receipt-time quarantine on a previously `quarantined=0` row; (c) recovery `quarantineExistingLedgerForRequestAttemptTx` on a pre-existing non-zero-credit row; (d) recovery `insertQuarantineTx` when **no** ledger row exists. Inspect `ledger_request_credits` and `ledger_operator_credits`.
**Expected:** (a) request-credit row stored with `gross_credits=provider_credits=0` and **no** `ledger_operator_credits` row exists; (b) both request- and operator-credit rows zeroed; (c) `quarantined=1`/`quarantine_reason` set with `gross_credits`/`provider_credits` **unchanged** (non-zero retained — the SPEC-024 §3 zero-payable invariant deviation, §2.7); (d) a NEW `quarantined=1` request-credit row with all rates and credits `0` and **no** operator-credit row. No path recomputes to a new non-zero value; §7.5b re-pricing skips any `quarantined=1` row.
**Network:** Not required.
**State reset:** Fresh fixture database.


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

**Verification:** Grep implementation prompts, migration files, and implementation code for the machine-checkable prohibited patterns in Appendix G.
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
**Expected:** Defaults match section  13.
**Network:** Not required.
**State reset:** Fresh fixture database or pure-function input.

### AC-METRICS: Metrics through endpoints

**Verification:** Compare section  14 metrics to endpoint fixture output.
**Expected:** Every metric is available through section  11 endpoints.
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
- **Category E: SPEC-006 symmetry.** each section  17.7 row maps to one credit rule.
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

**RESOLVED in SPEC-005 v0.3.3 / SPEC-002 v1.5.2 (issue #168, 2026-06-29).** `request_log.attempt_n` is now the canonical monotonic ordinal, populated at INSERT time within `(account_id, request_id)` groups under SQLite `IS`. SPEC-005 reads it directly when non-NULL; falls back to the byte-identical id-ASC derivation when NULL (rollout window). Row 3+ is credited normally; the only steady-state quarantine class is `attempt_n=1` with `retried=0`, deferred to §OQ-5 admin surface (issue #169).

### OQ-2: Rounding rule acceptance

_RESOLVED 2026-06-26 (`docs/OPEN_QUESTIONS.md` triage): closed as implicitly confirmed — round-half-to-even shipped 2026-05 and has run in production ~7 months with no operator pushback. The pre-production-gate confirmation condition is moot once the gate has been crossed._

This draft chooses round half to even. Operator should confirm before v0.2.

### OQ-3: Recovery windows

_RESOLVED 2026-06-26 (`docs/OPEN_QUESTIONS.md` triage): closed as implicitly confirmed — 24h startup + 7d nightly shipped 2026-05 and have not surfaced as wrong in ~7 months of production. Same reasoning as OQ-2._

Defaults are 24h startup and 7d nightly. Operator should confirm the operational fit.

### OQ-4: Provider docs wording

_RESOLVED 2026-06-26 (`docs/OPEN_QUESTIONS.md` triage): closed. `doc/provider-economics.md:137-140` explicitly names this OQ ("v1 payout boundary (SPEC-005 AC-DOCS-HONESTY / OQ-4). v1 accrues credits and emits payout-ready rows; the actual payout rail (USDC settlement) requires SPEC-007 and an operator decision.") `phase3-binary/README.md` links readers to that doc for the full reference. The wording will need a fresh refresh once SPEC-016 USDC pipeline lands and changes the answer to "automatically paid" — but that's a v0.4 docs update, not this OQ._

Provider-facing copy should say v1 accrues credits and payout requires SPEC-007/operator decision.

### OQ-5: Manual quarantine resolution

**PARTIALLY RESOLVED in SPEC-005 v0.4 (issue #169, 2026-06-29).**
v0.4 adds the `ledger_quarantine_resolutions` table (§4.10) and
the single `POST /admin/ledger/quarantine/{id}/force-void`
endpoint (§11.6.1) plus the audit-log emit contract (§11.6.4) and
the reader-side aggregation narrowing (§11.6.5
`quarantined_count` excludes voided rows). Force-void is terminal
and has no money-out risk, so it ships safely under v0.4.

**Force-credit (the credit-arm of §OQ-5) is DEFERRED to v0.5**
along with the pre-payout hold primitive and a corrective-
resolution rule (lifting the UNIQUE constraint for in-hold-window
amendments). Three rounds of R1/R2/R3 codex audit on v0.4
converged on the finding that force-credit without a hold
primitive is unsafe in the presence of SPEC-016 USDC payout
(real-money chain transfers). v0.5 is the right surface for the
full close. Tracking issue (separate from #169) to be filed with
the v0.4 PR; #169 itself stays open until v0.5 lands.

Pointer: `docs/OPEN_QUESTIONS.md` row `SPEC-005/OQ-5` flips to
PARTIAL — credit-arm pending v0.5.

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
- [x] SPEC-006 v0.9.8 dependency pinned (bumped v0.9.1->v0.9.8 in v0.6; originally pinned v0.3.1 / issue #211; was v0.8.2 in v0.3)
- [x] no gateway billing state
- [x] Go coordinator assumed
- [x] single SQLite deployment assumed
- [ ] WAL mode required (section  10.1, section  13)
- [ ] recovery has explicit grace-window cutoff (section  10.4)
- [ ] Payout-rail consumer interface defined (section  4.5.1)
- [ ] cross-process crash boundaries disclaimed (section  10.6)

## Appendix B. Decision traceability matrix

| Decision | section  2 anchor | Normative anchors | AC anchor |
|---|---|---|---|
| D1 | section  2.1 | section  1.3, section  12, section  16 | AC-D1 |
| D2 | section  2.2 | section  7, section  13 | AC-D2 |
| D3 | section  2.3 | section  5, section  13 | AC-D3 |
| D4 | section  2.4 | section  7.2, section  13 | AC-D4 |
| D5 | section  2.5 | section  4.3, section  4.4, section  5.3, section  7.3, section  13 | AC-D5 |
| D6 | section  2.6 | section  1.3, section  5, section  13, section  16 | AC-D6 |
| D7 | section  2.7 | section  12 | AC-D7 |
| D8 | section  2.8 | section  6 | AC-D8 |
| D9 | section  2.9 | section  4.7, section  10, section  13 | AC-D9 |
| D10 | section  2.10 | section  4.8, section  8 | AC-D10 |
| D11 | section  2.11 | section  11 | AC-D11 |
| D12 | section  2.12 | section  9 | AC-D12 |

## Appendix C. Column contract detail

> **v0.6 note on "insert only".** The per-column `Update rule` is a documentation contract, not a
> schema constraint (SQLite cannot enforce immutability). The token/credit/usage/fault columns marked
> `insert only` on `ledger_request_credits` and `ledger_operator_credits` are subject to the single
> verified-receipt re-price of §7.5b (`enforce`-mode verified rows), and `settled` / `settlement_id` /
> `quarantined` / `quarantine_reason` to their stated settlement/recovery transitions. No other
> post-insert mutation is permitted.

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
- Meaning: prompt tokens (the value priced by §5.3).
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.charged_prompt_tokens`

- Type: INTEGER.
- Constraint: NULL CHECK(charged_prompt_tokens IS NULL OR charged_prompt_tokens >= 0).
- Meaning: prompt tokens actually billed — the §5.3.2 bounded value `min(attributed, PromptTokenUpperBound)`, equal to `prompt_tokens` (diagnostic).
- Update rule: insert only (plus the §7.5b re-price / one-time additive-migration backfill; see §4.3 note).
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.provider_reported_prompt_tokens`

- Type: INTEGER.
- Constraint: NULL CHECK(provider_reported_prompt_tokens IS NULL OR provider_reported_prompt_tokens >= 0).
- Meaning: prompt count attributed to the provider before the §5.3.2 bound — the provider's reported value, or the coordinator's `estimateTokens(req.raw)` substitution when the provider omitted it (diagnostic).
- Update rule: insert only (plus one-time additive-migration backfill; see §4.3 note).
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.cached_prompt_tokens`

- Type: INTEGER.
- Constraint: NULL CHECK(cached_prompt_tokens IS NULL OR (cached_prompt_tokens >= 0 AND cached_prompt_tokens <= prompt_tokens)).
- Meaning: prefix-cache-reused prompt tokens (SPEC-024); priced at the cache-hit rate (§5.3) only on an eligible sticky-hit first-attempt row (§5.3.1).
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
- Constraint: NOT NULL CHECK(usage_source IN ('provider_reported','byte_estimated','null_error')).
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
- Meaning: quarantine explanation (includes `invalid_cached_prompt_tokens` and `ambiguous_cache`, §5.3.1).
- Update rule: set by recovery.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.settlement_account_scope_hash`

- Type: TEXT.
- Constraint: NULL CHECK(settlement_account_scope_hash IS NULL OR (length(settlement_account_scope_hash) = 64 AND settlement_account_scope_hash NOT GLOB '*[^0-9a-f]*')).
- Meaning: 64-lowercase-hex account-scope hash for settlement partitioning (SPEC-022 policy).
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.settlement_policy_mode`

- Type: TEXT.
- Constraint: NOT NULL DEFAULT 'legacy' CHECK(settlement_policy_mode IN ('legacy','observe','enforce')).
- Meaning: settlement-policy rollout mode recorded at insert (§7.5a); `enforce` rows are payout-gated on matched route/receipt/policy-version/verified-outcome/non-overlap.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_request_credits.settlement_policy_version`

- Type: TEXT.
- Constraint: NULL.
- Meaning: settlement-policy version tag at insert (§7.5a).
- Update rule: insert only.
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
- Meaning: future payout-rail spec reserved; SPEC-005 writes NULL.
- Update rule: future payout-rail spec only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.payout_external_id`

- Type: TEXT.
- Constraint: NULL.
- Meaning: future payout-rail spec reserved; SPEC-005 writes NULL.
- Update rule: future payout-rail spec only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_payout_ready.status`

- Type: TEXT.
- Constraint: NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','consumed','voided')).
- Meaning: payout row status.
- Update rule: future payout-rail spec writes after ready.
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
- Constraint: NOT NULL CHECK(run_type IN ('startup_scan','nightly_reconcile','admin_reconcile','spec_007_claim')).
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

#### `ledger_reconciliation_runs.buyer_equivalent_credits`

- Type: INTEGER.
- Constraint: NOT NULL CHECK(buyer_equivalent_credits >= 0).
- Meaning: SPEC-005-internal buyer-equivalent total computed from request_log through section  6 and section  5.3.
- Update rule: insert only.
- Verification: schema introspection MUST find this exact column contract or a stricter equivalent.

#### `ledger_reconciliation_runs.buyer_debit_credits` (deprecated)

- Type: INTEGER.
- Constraint: NULL for new rows after MIG-005-009; legacy v0.2 rows may contain NOT NULL values.
- Meaning: deprecated name for `buyer_equivalent_credits`.
- Update rule: write NULL for new rows when the legacy column exists.
- Verification: schema introspection MAY find this legacy column for backward compatibility, but new-row fixtures MUST assert it is NULL.

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
- Verification function: pass fixture through the section  5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: 503 no provider reached

- SPEC-006 status: 503.
- Completion-token state: 0.
- Buyer debit basis: none.
- Provider credit action: Write no provider, operator, or provider identity ledger row.
- Verification function: assert no ledger rows are written and count the state only via request_log JOIN where provider_assigned_id IS NULL.
- Expected network use: none.

### Fixture: 502 zero completion

- SPEC-006 status: 502.
- Completion-token state: 0.
- Buyer debit basis: prompt only.
- Provider credit action: Write prompt-only ledger row unless FR-P11a override applies.
- Verification function: pass fixture through the section  5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: 502 partial stream

- SPEC-006 status: 502.
- Completion-token state: >0 partial.
- Buyer debit basis: prompt + actual completion.
- Provider credit action: Write prompt plus actual completion ledger row unless FR-P11a override applies.
- Verification function: pass fixture through the section  5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: 504 zero completion

- SPEC-006 status: 504.
- Completion-token state: 0.
- Buyer debit basis: prompt only.
- Provider credit action: Write prompt-only ledger row unless FR-P11a override applies.
- Verification function: pass fixture through the section  5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: 504 partial stream

- SPEC-006 status: 504.
- Completion-token state: >0 partial.
- Buyer debit basis: prompt + actual completion.
- Provider credit action: Write prompt plus actual completion ledger row unless FR-P11a override applies.
- Verification function: pass fixture through the section  5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: Client disconnect v1.2.4+

- SPEC-006 status: client_disconnect.
- Completion-token state: provider reported actual.
- Buyer debit basis: prompt + actual completion.
- Provider credit action: Use provider-reported completion, subject to the § 5.3 clamp (min(reported, byte_estimate)).
- Verification function: pass fixture through the section  5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: Client disconnect pre-v1.2.4

- SPEC-006 status: client_disconnect.
- Completion-token state: byte estimated.
- Buyer debit basis: prompt + `ceil(bytes_emitted_so_far / tier2.output_bytes_per_token_ceiling)` (default 16; § 6.8).
- Provider credit action: Use the same estimate as buyer debit.
- Verification function: pass fixture through the section  5.3 arithmetic after row-specific token selection.
- Expected network use: none.

### Fixture: SPEC-001 null-usage error

- SPEC-006 status: SPEC-001 null-usage error.
- Completion-token state: 0 (NULL).
- Buyer debit basis: none.
- Provider credit action: Write a zero-credit audit row with `usage_source='null_error'` and `fault_flag='null_usage_error'` unless FR-P11a is more specific.
- Verification function: assert prompt_tokens=NULL and completion_tokens=NULL never enter the section  5.3 arithmetic.
- Expected network use: none.

## Appendix E. Acceptance criterion fixture details

### AC-D1 fixture detail

- Claim: Billing model encoded.
- Setup: Parse section  2 and later D1 references; run migrations in an empty SQLite fixture.
- Oracle: D1 exists in section  2, is enforced outside section  2, and no buyer revenue, Stripe, checkout, donation, tip-jar, or payment-collection table exists.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D2 fixture detail

- Claim: Settlement cadence encoded.
- Setup: Parse section  2 and later D2 references; seed completed usage and run settlement before and at UTC Monday 00:00.
- Oracle: D2 exists in section  2, is enforced outside section  2, credits accrue immediately, and payout-ready rows emit only at the weekly boundary.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D3 fixture detail

- Claim: Provider reward formula encoded.
- Setup: Parse section  2 and later D3 references; price known-model and unknown-model rows.
- Oracle: D3 exists in section  2, is enforced outside section  2, known-model rates are used, default fallback applies for unknown model, and rates are snapshotted.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D4 fixture detail

- Claim: Minimum payout threshold encoded.
- Setup: Parse section  2 and later D4 references; run settlement one credit below and exactly at the configured threshold.
- Oracle: D4 exists in section  2, is enforced outside section  2, below-threshold credits roll forward, and at-threshold credits emit one payout-ready row.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D5 fixture detail

- Claim: Revenue split encoded.
- Setup: Parse section  2 and later D5 references; create rows before and after a provider_share_bps reload.
- Oracle: D5 exists in section  2, is enforced outside section  2, split sums to gross per row, and the historical row is immutable after the share change.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D6 fixture detail

- Claim: Currency / unit encoded.
- Setup: Parse section  2 and later D6 references; inspect schema and run half/below-half/above-half rounding fixtures.
- Oracle: D6 exists in section  2, is enforced outside section  2, economic storage is INTEGER only, and round-half-even behavior is exact.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D7 fixture detail

- Claim: Buyer balance enforcement encoded.
- Setup: Parse section  2 and later D7 references; seed an over-quota overshoot row that reached a provider with reported usage.
- Oracle: D7 exists in section  2, is enforced outside section  2, provider credit follows section  6, and legitimate completed work that reached a provider has provider credit greater than 0.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D8 fixture detail

- Claim: Failed-request accounting encoded.
- Setup: Parse section  2 and later D8 references; run all SPEC-006 section  17.7 D3 rows through the section  6 classifier.
- Oracle: D8 exists in section  2, is enforced outside section  2, each buyer-debit state maps to matching provider-credit action, and provider-not-reached writes no ledger rows.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D9 fixture detail

- Claim: Crash recovery policy encoded.
- Setup: Parse section  2 and later D9 references; run the same recovery input twice with request_log rows, ledger rows, config snapshots, identity snapshots, and scan window.
- Oracle: D9 exists in section  2, is enforced outside section  2, outputs are byte-identical, no live network is called, and missing snapshots quarantine instead of guessing.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D10 fixture detail

- Claim: Multi-provider attribution encoded.
- Setup: Parse section  2 and later D10 references; seed rows sharing the same `(account_id, request_id)` group, ordered by request_log.id ASC, plus identity snapshots. (Legacy fixtures may use NULL account_id; SQLite `IS NULL` clusters NULLs identically to the v0.3 pre-account-scope behavior.)
- Oracle: D10 exists in section  2, is enforced outside section  2, rows receive distinct `attempt_n`/`provider_id` keys (monotonic 0, 1, 2, ... from `request_log.attempt_n` when populated, byte-identical id-ASC fallback when NULL), row 2 requires explicit `retried` semantics (else quarantined), and row 3+ is credited normally under SPEC-005 v0.3.3 / SPEC-002 v1.5.2 (issue #168).
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D11 fixture detail

- Claim: Operator dashboard scope encoded.
- Setup: Parse section  2 and later D11 references; invoke all four handlers with fixture stores and missing/wrong credentials.
- Oracle: D11 exists in section  2, is enforced outside section  2, documented JSON shapes and error envelopes are returned, provider auth scopes hold, and no HTML/charts are emitted.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-D12 fixture detail

- Claim: Fraud floor for degraded providers encoded.
- Setup: Parse section  2 and later D12 references; seed a breaker-qualified fault, buyer cancel, and provider recovery preflight.
- Oracle: D12 exists in section  2, is enforced outside section  2, breaker faults are zero-credit, buyer cancels are not fault-zeroed, and normal credits resume after recovery preflight.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-H005 fixture detail

- Claim: H-005 symmetry.
- Setup: Construct all nine SPEC-006 v0.9.8 section  17.7 states and run the section  6 credit function.
- Oracle: Each buyer-debit state has the specified provider-credit state; provider-not-reached writes no row; null-usage errors write zero-credit rows; section  10.6 cross-process states are excluded; delta_gross_credits is 0 for a clean SPEC-005-owned range; provider/operator split sums to gross per row.
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
- Oracle: estimated_completion_tokens=8 by `ceil(bytes_emitted_so_far / tier2.output_bytes_per_token_ceiling)` = ceil(120/16) = 8 (default ceiling; § 6.8) and gross includes 8 completion.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-NULL-PROMPT fixture detail

- Claim: Null prompt and completion zero credit.
- Setup: Fixture prompt_tokens=NULL, completion_tokens=NULL, error_code=error_internal.
- Oracle: One zero-credit row with gross_credits=0, provider_credits=0, operator_credits=0, usage_source=null_error, and no section  5.3 NULL-operand evaluation.
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
- Setup: Fixture two providers and one logical request sharing the same `(account_id, request_id)` group (single account; legacy NULL-`account_id` fixtures cluster identically among themselves under SQLite `IS`).
- Oracle: Two rows with distinct attempt_n/provider_id keys; sums match attempt totals.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-ATTEMPT-FALLBACK fixture detail

- Claim: retried fallback limit.
- Setup: Fixture three rows sharing the same `(account_id, request_id)` group under SQLite `IS` clustering. One variant uses persisted `request_log.attempt_n=0,1,2` (post-v1.5.2); a second variant leaves `attempt_n` NULL to exercise the id-ASC fallback. Set `retried=1` on row 2 to avoid the legitimate-retry-without-marker quarantine class.
- Oracle: Both variants produce identical credit rows for `attempt_n=0, 1, 2`. Row 3 (`attempt_n=2`) is credited normally under SPEC-005 v0.3.3 / SPEC-002 v1.5.2 — the v0.3.1 row-3+ quarantine is satisfied by both the persisted column and the byte-identical fallback derivation. The only quarantine class that remains is `attempt_n=1` with `retried=0`.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-CRASH fixture detail

- Claim: ACID crash boundary.
- Setup: Abort a transaction before COMMIT and commit a second transaction.
- Oracle: Abort leaves no partial rows; commit leaves request_log plus ledger rows.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-WAL fixture detail

- Claim: WAL mode required.
- Setup: Run coordinator startup against SQLite fixtures with `journal_mode=WAL` and `journal_mode=DELETE`.
- Oracle: WAL fixture passes; DELETE fixture fails fast before ledger work.
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

### AC-PAYOUT-CLAIM-CONTRACT fixture detail

- Claim: payout-ready consumer contract.
- Setup: Seed ready and voided payout rows, run the section  4.5.1 claim update twice, and inspect ledger_reconciliation_runs.
- Oracle: First ready claim consumes one row and appends run_type=spec_007_claim; second claim affects 0 rows; voided remains terminal; no pay action is allowed on a 0-row claim.
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
- Setup: Grep implementation prompts, migration files, and implementation code for the machine-checkable prohibited patterns in Appendix G.
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
- Oracle: Defaults match section  13.
- Live network: forbidden.
- Failure handling: failing this fixture blocks claiming SPEC-005 implementation complete.

### AC-METRICS fixture detail

- Claim: Metrics through endpoints.
- Setup: Compare section  14 metrics to endpoint fixture output.
- Oracle: Every metric is available through section  11 endpoints.
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

AC-NO-ONCHAIN and related scope checks MUST grep the machine-checkable prohibited pattern column, not the prose-level guard column.

| Prose-level guard | Machine-checkable prohibited pattern |
|---|---|
| AntFeed USDC payment rail | `antfeed.Client`, `ANTFEED_`, `antfeed_settlement` |
| On-chain settlement of any kind | `eth_sendRawTransaction`, `solana_client`, `chain_id`, `wallet_private_key` |
| Stripe, checkout, credit cards, fiat invoices, refunds, or buyer revenue | `stripe.`, `STRIPE_`, `checkout_session`, `invoice_id`, `refund_id`, `buyer_revenue_cents` |
| Billing logic in the Phase 5 gateway | `phase5-gateway/internal/billing`, `gateway_ledger_write`, `buyer_invoice` |
| SPEC-001 wire-format changes | `inference_response_billing`, `provider_payout`, `billing_credits` in SPEC-001 protocol messages |
| Per-provider negotiated splits | `provider_share_overrides`, `negotiated_share_bps`, `provider_contract_terms` |
| Reputation-weighted reward formulas | `reputation_multiplier`, `quality_weighted_credits`, `rating_adjusted_payout` |
| Dynamic market-rate pegging | `market_rate_oracle`, `spot_price_feed`, `dynamic_rate_card` |
| Tier 2 attested-provider reward multipliers | `attestation_multiplier`, `tier2_reward_bonus`, `attested_provider_bps` |
| KYC, 1099, tax, or regulatory paperwork | `kyc_status`, `tax_form_1099`, `tin_hash`, `w9_document` |
| Refund or clawback workflows | `clawback_credits`, `refund_workflow`, `reverse_provider_credit` |
| Multi-currency ledger entries written by SPEC-005 | `ledger_currency_amount`, `fx_rate_snapshot`, `multi_currency_ledger` |
| Web charts and dashboards | `ledger_chart`, `dashboard_widget`, `chart_series_provider_credits` |
| Slack, email, webhook, or digest notification surfaces | `slack_webhook_url`, `earnings_digest_email`, `provider_payout_webhook` |
| Multi-coordinator or multi-region ledger replication | `ledger_replica_region`, `coordinator_shard_id`, `multi_region_ledger_sync` |
| Buyer-visible donation buttons, tip jars, or payment-adjacent SPEC-006 UI | `donation_button`, `tip_jar`, `payment_cta`, `buyer_donate_url` |

Expected result: any implementation hit on a prohibited pattern is rejected or moved to SPEC-007/SPEC-008/later unless a future operator-approved spec explicitly changes this boundary.
