# SPEC-005 v0.2 audit report — Round 2 (Claude)

Audit target: `specs/SPEC-005-billing.md` v0.2 (2026-05-31, R1 fix pass).
Audit methodology: focus on the M2.1 implicit/unstated-assumption class
across SPEC-005 v0.2 and its cross-spec boundary with SPEC-001 v1.2.4,
SPEC-002 v1.3.3, SPEC-003 v0.7, SPEC-004 v0.3.1, SPEC-006 v0.8.1, and
SPEC-008 v0.3.

R1 audit (Codex, on v0.1) at `specs/SPEC-005-r1-audit.md` was read only
AFTER the independent R2 audit; cross-round comparison is the second
half of this document.

---

## Round 1 (Codex) summary

Recap of `specs/SPEC-005-r1-audit.md` on v0.1, recorded here for the
cross-round comparison below.

- 0 CRITICAL
- 7 MAJOR (M-1 D1-D12 reference completeness; M-2 stable provider_id
  derivation; M-3 historical rate-card snapshots; M-4 attempt_n
  fallback determinism; M-5 endpoint JSON examples + rate limits;
  M-6 D1-D12 behavior ACs; M-7 H-005 reconciliation tolerance;
  M-8 unreachable usage_source rows — note M-8 is enumerated in the
  v0.2 change log even though the R1 doc lists 7 by number).
- 4 MINOR (N-1 AC-NO-ONCHAIN grep ambiguity; N-2
  usage_source='provider_not_reached' contradiction; N-3 Appendix E
  duplication; N-4 admin JSON error envelope).
- 3 QUESTIONS (Q-1 ledger_config_snapshots; Q-2 identity snapshots;
  Q-3 wait for SPEC-002 attempt_n).

R1 verdict: READY WITH FIX PASS — architectural intent sound;
v0.2 needed precision fixes only. v0.2's change-log claims all R1
MAJORs (M-1 through M-8) and several MINOR/QUESTION items closed.

---

## Round 2 (Claude) findings on v0.2

Independent audit conducted without prior reading of the R1 audit.
Focus areas per the audit prompt:

1. Null `completion_tokens` edge in the reward formula.
2. Coordinator ledger-read TOCTOU under concurrent requests.
3. SPEC-006 D3 matrix state coverage in the reward formula section.
4. SPEC-002 `request_log` JOIN index strategy at 10K-provider scale.
5. D9 crash-recovery testability across the cross-process boundary.
6. SPEC-007 boundary machine-readable interface definition.
7. Implicit gateway-state dependencies.

### Summary

- 0 CRITICAL
- 10 MAJOR (R2-M1 through R2-M10)
- 5 MINOR (R2-n1 through R2-n5)
- 3 QUESTIONS (R2-Q1 through R2-Q3)

R2 verdict: READY WITH SECOND FIX PASS. v0.2 is structurally sound and
closes every R1 finding. The remaining work is M2.1-class precision:
implicit assumptions about upstream-spec contracts (SPEC-002 indexes,
SPEC-002 multi-row-per-request_id, SPEC-001 error-code surfacing) and
two downstream contracts (SPEC-006 § 17.7 null-usage row, SPEC-007
payout consumer interface). None of the R2 findings reopens the
locked § 2 D1-D12 decisions.

### CRITICAL findings

None.

### MAJOR findings

#### R2-M1. Null `prompt_tokens` edge in § 5.3 is undefined behavior.

- **Severity:** MAJOR
- **Section reference:** § 4.3, § 5.3, § 6.9
- **Description:** § 4.3 explicitly permits `prompt_tokens` to be NULL
  (`CHECK(prompt_tokens IS NULL OR prompt_tokens >= 0)`). SPEC-002
  v1.3.3 FR-B9 says both `prompt_tokens` and `completion_tokens` are
  NULL "if failed". § 5.3 `base_numerator = prompt_tokens *
  prompt_rate_per_mtok + effective_completion_tokens *
  completion_rate_per_mtok` is undefined when `prompt_tokens` is NULL.
  § 6.9 only addresses `completion_tokens` NULL via
  `usage_source = 'null_error'` setting effective completion to 0; it
  never addresses NULL `prompt_tokens`. This is the focus-1 implicit
  assumption: the spec assumes prompt is always known, but SPEC-001
  error-path semantics allow both to be NULL.
- **Proposed fix:** § 5.3 add: "When `usage_source = 'null_error'`,
  both `prompt_tokens` and `completion_tokens` MAY be NULL; the row
  MUST set `gross_credits = 0`, `provider_credits = 0`, and
  `operator_credits = 0` before the formula evaluates, and the
  formula MUST NOT be evaluated on NULL operands." § 6.9 add the
  symmetric statement. § 4.3 add the cross-check: "When
  `usage_source = 'null_error'`, `gross_credits` MUST be 0 (CHECK)."

#### R2-M2. `request_log.error` is a free-text message but § 6.9 keys on SPEC-001 error codes.

- **Severity:** MAJOR
- **Section reference:** § 6.9, SPEC-002 v1.3.3 FR-B9 schema, SPEC-001 v1.2.4 § 6.4
- **Description:** § 6.9 says the null-usage error path is detected
  when SPEC-001 returned `error_model_not_loaded`,
  `error_context_exceeded`, `error_queue_full`, or `error_internal`.
  SPEC-001 v1.2.4 indeed emits these as `status` values on the
  `inference_response_end` envelope (SPEC-001 lines 585-588, 1386).
  But SPEC-002 v1.3.3 `request_log.error` (line 1110) is a free-text
  error message column, not a SPEC-001 status enum. § 5.3, § 6.9, and
  § 10.4 recovery cannot deterministically classify a row as
  null_usage_error from `request_log.error` alone without a
  string-matching contract that SPEC-002 does not provide. AC-D9
  determinism (byte-identical output) fails on this surface.
- **Proposed fix:** Cross-spec patch to SPEC-002 v1.3.4 FR-B9: add a
  normative `error_code TEXT NULL` column whose values are exactly
  the SPEC-001 v1.2.4 status enum
  (`error_model_not_loaded`, `error_context_exceeded`,
  `error_queue_full`, `error_internal`, plus null/other). SPEC-005
  § 6.9 then keys deterministically on this column. SPEC-005
  § 4.2 read-only contract gains `error_code` to the read list.

#### R2-M3. SPEC-002 `request_log` lacks a `ts_utc` index; SPEC-005 reconciliation scans 7-day windows.

- **Severity:** MAJOR
- **Section reference:** § 10.2, § 10.3, § 10.4, § 11.3, SPEC-002 v1.3.3 FR-B9
- **Description:** Focus 4. SPEC-005 startup_scan (§ 10.2, prior 24h)
  and nightly_reconcile (§ 10.3, prior 7d) and the
  `GET /admin/ledger/reconcile?from=…&to=…` admin endpoint (§ 11.3)
  all scan `request_log` by time window. SPEC-002 v1.3.3 FR-B9
  declares only `request_id` MUST be indexed. At the 10K-provider
  scale referenced in the audit prompt, a full-table scan per
  reconcile cycle is a correctness/availability risk (lock contention
  with hot-path writers, scan timeouts, missed cycles).
- **Proposed fix:** Cross-spec patch to SPEC-002 v1.3.4 FR-B9: add
  `CREATE INDEX idx_request_log_ts_utc ON request_log(ts_utc)` and
  `CREATE INDEX idx_request_log_request_id_id ON request_log(request_id, id)`
  (the composite index also accelerates the § 8.2 attempt-ordinal
  fallback). SPEC-005 § 10.4 algorithm signature explicitly names
  these indexes as preconditions; lacking them, the algorithm is
  permitted to fall back to a chunked scan with explicit
  bounds-passing.

#### R2-M4. Multi-row-per-`request_id` semantics assumed but not normatively stated upstream.

- **Severity:** MAJOR
- **Section reference:** § 4.2, § 8.2, SPEC-002 FR-B9, SPEC-004 v0.3.1 § 7 line 454, AC-SR-8 (line 781)
- **Description:** § 8.2 fallback ordering says "sort same-`request_id`
  rows by `request_log.id ASC`" — implying multiple rows per
  `request_id`. SPEC-004 v0.3.1 AC-SR-8 confirms by stating retries
  "log both attempts with correct provider attribution". But SPEC-002
  v1.3.3 FR-B9 prose is "every buyer request is logged" — singular
  and could be interpreted as one row per `request_id`. The
  implementer choice (overwrite, append, separate table) is not
  pinned. SPEC-005's correctness depends on the append-per-attempt
  reading, but SPEC-002 doesn't normatively guarantee it.
- **Proposed fix:** Cross-spec patch to SPEC-002 v1.3.4 FR-B9: add
  normative "Each provider attempt for a given `request_id` MUST
  produce its own `request_log` row; (id) is the only uniqueness
  constraint; `request_id` MAY recur across rows" plus an AC. SPEC-005
  § 4.2 reaffirms this dependency explicitly.

#### R2-M5. TOCTOU window between hot-path COMMIT and recovery/reconciliation scan; WAL mode and as-of cutoff are implicit.

- **Severity:** MAJOR
- **Section reference:** § 10.1, § 10.2, § 10.4
- **Description:** Focus 2. § 10.1 says hot-path uses `BEGIN IMMEDIATE;
  ...; COMMIT` — SQLite serializes writers via the global lock, so
  per-row atomicity is safe. But the recovery scan (§ 10.2/§ 10.3) is
  a *separate* transaction and may run concurrently with hot-path
  writers. If the scan reads `request_log` while a hot-path
  transaction is mid-flight (request_log row written but ledger row
  not yet committed in the same txn — impossible inside a single
  txn but possible *between* the gateway-side debit and the
  coordinator-side BEGIN IMMEDIATE), it can classify the row as
  "missing ledger row" and try to insert a recovery row that then
  conflicts with the hot-path COMMIT on
  `UNIQUE(request_id, attempt_n, provider_id)`. SPEC-005 does not
  require WAL mode (only SPEC-002 v1.3.3 sketches WAL); SPEC-005
  does not define an "as-of" cutoff to bound in-flight races.
- **Proposed fix:** § 10.1 add: "The coordinator SQLite database MUST
  be operated in WAL mode (`PRAGMA journal_mode = WAL`). Recovery
  scans MUST execute under `BEGIN DEFERRED` to obtain a consistent
  snapshot." § 10.4 add: "The deterministic algorithm signature
  takes a `scanWindow` whose `to_utc` MUST be no closer to wall-clock
  now than a configurable `settlement.recovery_grace_seconds`
  (default 30s); rows newer than this cutoff are excluded from the
  scan to prevent races with in-flight hot-path transactions."

#### R2-M6. `overshoot_flag` column is a phantom field — no protocol writes it.

- **Severity:** MAJOR
- **Section reference:** § 4.3, § 12, D7
- **Description:** Focus 7. § 4.3 stores
  `overshoot_flag INTEGER NOT NULL DEFAULT 0`. § 12 D7 says
  overshoot_flag is "advisory only" and SPEC-006 owns quota. But
  SPEC-005 is coordinator-side; SPEC-006 is gateway-side. The
  coordinator has no automatic visibility into gateway quota state.
  No section in SPEC-005 defines how/when overshoot_flag is set: no
  inbound header is named, no coordinator query against the gateway
  is named, and the gateway is not asked to forward overshoot
  intent. The column is therefore always 0 in v1 — dead.
- **Proposed fix:** Pick one. **Option A (recommended for v0.3):**
  Drop `overshoot_flag` from § 4.3 and § 12 entirely. D7's "advisory
  only" already permits SPEC-005 to ignore overshoot; removing the
  column removes a phantom field and the AC-D7 fixture simplifies.
  **Option B:** Add a normative cross-spec patch: SPEC-006 gateway
  MUST emit a header (e.g., `X-MacProvider-Overshoot: 1` plus
  budget signed-int delta) when forwarding a request that exceeds
  quota. SPEC-005 hot path reads the header and sets
  `overshoot_flag = 1`. Requires SPEC-006 § 5.4 and § 7.2 edits.

#### R2-M7. SPEC-007 boundary at § 4.5 lacks a machine-readable consumer interface.

- **Severity:** MAJOR
- **Section reference:** § 4.5, § 1.4 SPEC-007 boundary, § 7.5
- **Description:** Focus 6. § 4.5 reserves columns for SPEC-007
  (`payout_currency`, `payout_external_id`, `status` mutable from
  'ready'). § 1.4 says SPEC-007 "consumes payout-ready rows". But no
  section defines: (a) what JSON projection or SQL view SPEC-007
  reads; (b) what status transitions are valid (presumably
  ready→consumed and ready→voided, with voided terminal — but it is
  not stated); (c) how SPEC-007 claims a row safely under contention
  (no `SELECT ... FOR UPDATE` pattern is specified, no
  ready→claimed→consumed three-state graph); (d) what happens if
  SPEC-007 errors mid-claim (no audit-trail requirement for status
  mutations).
- **Proposed fix:** Add § 4.5.1 "SPEC-007 consumer contract":
  (a) normative status transition graph diagram with terminal
  `consumed` and `voided`, no reverse transitions; (b) JSON
  projection schema `{id, provider_id, window_start_utc,
  window_end_utc, provider_credits, idempotency_key, status,
  payout_currency, payout_external_id}`; (c) a normative
  claim/finalize pattern (e.g., `UPDATE ledger_payout_ready SET
  status='consumed', payout_external_id=?, payout_currency=?
  WHERE id=? AND status='ready'` returning affected-row-count; if
  0 rows, the claim raced and SPEC-007 MUST not pay); (d) audit
  requirement: status mutations append to a new
  `ledger_payout_status_history` table or emit
  `ledger_reconciliation_runs` rows with `run_type='spec_007_claim'`
  (this is a Q-trade-off — see R2-Q1).

#### R2-M8. Byte-estimate formula duplicated across SPEC-005 and SPEC-006 with no normative link.

- **Severity:** MAJOR
- **Section reference:** § 6.8, § 15.1, AC-DISCONNECT-ESTIMATE; SPEC-006 § 17.7 client-disconnect pre-v1.2.4
- **Description:** § 6.8 says "Use the same estimate as buyer debit"
  for pre-v1.2.4 cancel. SPEC-006 v0.8.1 § 17.7 specifies
  `prompt + ceil(bytes_emitted_so_far / 4)`. AC-DISCONNECT-ESTIMATE
  asserts bytes_emitted=120 → 30 completion (matches ceil(120/4)).
  But SPEC-005 never reproduces the formula normatively; if SPEC-006
  ever changes the formula (e.g., to `bytes/3.5` for a different
  tokenizer), SPEC-005 silently diverges and H-005 fails.
- **Proposed fix:** § 6.8 add normative: "The byte-estimate
  completion-token formula is exactly
  `ceil(bytes_emitted_so_far / 4)` per SPEC-006 v0.8.1 § 17.7.
  SPEC-005 v0.3 mirrors this formula here normatively; any future
  SPEC-006 byte-estimate change MUST trigger a coordinated SPEC-005
  bump." § 15.1 cross-references the same anchor. AC-DISCONNECT-
  ESTIMATE references the SPEC-006 anchor explicitly.

#### R2-M9. D9 "crash-after-debit-before-forward" is not addressable from SPEC-005 alone.

- **Severity:** MAJOR
- **Section reference:** § 10.1, § 10.4, AC-CRASH, D7, D9
- **Description:** Focus 5. D9 says hot-path is one SQLite
  transaction. AC-CRASH tests local-transaction abort. But the
  cross-process crash window — gateway debits the buyer quota
  (SPEC-006 § 7.2 reservation), then crashes before forwarding to
  the coordinator → no `request_log` row exists → SPEC-005 nightly
  reconcile cannot detect or repair this state — is not addressable
  by SPEC-005's deterministic algorithm. The H-005 invariant
  (`delta_gross_credits = 0`) silently fails because the SPEC-005
  side sees nothing. The spec does not acknowledge this limit or
  define a cross-process reconciliation contract.
- **Proposed fix:** Pick one. **Option A:** § 10 add an
  "Out-of-scope crash boundaries" subsection explicitly listing the
  gateway-crash-after-debit-before-forward state as out of SPEC-005
  scope; refer to SPEC-006 reservation reaper (§ 7.2) as the owning
  surface; AC-H005 explicitly excludes this state. **Option B:**
  Cross-spec patch to SPEC-006 v0.9: gateway MUST emit and persist a
  reservation row keyed by `(request_id, reservation_id)`; on
  reservation-reaper sweep, expired-unsettled reservations write a
  zero-tokens entry to `request_log` so SPEC-005 reconcile observes
  a row to zero-credit. Operator decides — see R2-Q2.

#### R2-M10. § 11.3 `buyer_debit_credits` derivation is ambiguous; AC-H005 invariant under-defined.

- **Severity:** MAJOR
- **Section reference:** § 4.6, § 10.3, § 11.3, AC-H005
- **Description:** § 4.6 stores `buyer_debit_credits INTEGER NOT NULL`.
  § 10.3 says "For a clean range, `delta_gross_credits` MUST equal 0
  when provider gross credits are recomputed from the same § 5.3
  formula and historical config snapshot." But SPEC-005 owns only the
  provider-credit ledger; the *buyer* debit lives in SPEC-006. § 10.3
  / § 11.3 do not state whether `buyer_debit_credits` is (a) derived
  from `request_log` via the same § 5.3 formula (a SPEC-005-internal
  symmetry check) or (b) read from the SPEC-006 usage table (a
  cross-process consistency check). The two answers differ
  materially: SPEC-006 § 17.7 reserves max_tokens then settles to
  actual; the *reserved* amount and the *actual* amount diverge
  whenever requests under-use their reservation. AC-H005
  (`delta_gross_credits = 0`) cannot be satisfied without picking
  one interpretation.
- **Proposed fix:** § 10.3 and § 11.3 normatively clarify:
  "`buyer_debit_credits` is the SPEC-005-internal buyer-equivalent
  computed from `request_log` via the § 6 D8 matrix (using the
  same § 5.3 formula, not the SPEC-006 usage table). SPEC-005 does
  NOT read SPEC-006 usage tables. AC-H005 verifies symmetry of the
  SPEC-005 model only; cross-process consistency between SPEC-005
  and SPEC-006 is a separate H-005-EXT verification owned by the
  operator." Rename `buyer_debit_credits` →
  `buyer_equivalent_credits` (and `delta_gross_credits` left
  unchanged) to make the column name match the source semantics.

### MINOR findings

#### R2-n1. § 13 config does not pin WAL mode at the SPEC-005 level.

- **Severity:** MINOR
- **Section reference:** § 13, § 10.1 (cross-references R2-M5)
- **Description:** SPEC-002 may run SQLite in non-WAL mode in some
  test fixtures. SPEC-005 ACID assumptions depend on WAL for
  reader-during-writer correctness.
- **Proposed fix:** § 13 add: "SPEC-005 MUST run on a SQLite database
  with `journal_mode = WAL` (set at coordinator startup per § 10.1)."
  Add to AC-CRASH or a new AC-WAL deterministic check.

#### R2-n2. § 11.4 `/providers/{id}/earnings` gates on FR-P12 tokens but `require_provider_tokens: false` mode is not addressed.

- **Severity:** MINOR
- **Section reference:** § 11.4, § 11.5, SPEC-002 FR-P12 lines 646-696
- **Description:** SPEC-002 v1.3.3 FR-P12 defines
  `auth.require_provider_tokens` (default false). In default mode,
  providers may have no token. § 11.5 says SPEC-005's earnings
  endpoint REQUIRES bearer auth. So in the default SPEC-002
  configuration, no provider can read its own earnings.
- **Proposed fix:** § 11.5 add: "When SPEC-002
  `auth.require_provider_tokens` is `false`, the operator MUST
  separately provision per-provider bearer tokens for the earnings
  endpoint, or SPEC-005 v0.3 disables `/providers/{id}/earnings` and
  exposes the data via the operator-keyed `/admin/ledger/providers`
  only." Reference the production launch gate.

#### R2-n3. Appendix B traceability matrix omits § 4.3 / § 4.4 from the D5 anchor list.

- **Severity:** MINOR
- **Section reference:** Appendix B
- **Description:** D5 is anchored in § 5.3, § 7.3, § 13 per Appendix
  B, but the load-bearing immutability claim lives in § 4.3
  (`provider_share_bps` snapshotted on every row) and § 4.4
  (operator share snapshotted symmetrically). The traceability matrix
  is incomplete.
- **Proposed fix:** Appendix B D5 row: add `§ 4.3, § 4.4` to the
  normative anchors column.

#### R2-n4. Appendix G out-of-scope grep guards are still keyword-based; R1's N-1 finding is not fully closed.

- **Severity:** MINOR
- **Section reference:** Appendix G, § 18 AC-NO-ONCHAIN
- **Description:** R1's N-1 noted that AC-NO-ONCHAIN's grep test
  would false-fail because the spec itself lists "AntFeed",
  "on-chain", "USDC" in the out-of-scope guards. v0.2 still uses
  keyword grep in Appendix G ("grep implementation prompts and specs
  for new normative work in this area"). The guard is operator-text,
  not machine-checkable.
- **Proposed fix:** Appendix G add a structured "Prohibited
  patterns" list (e.g., import paths, function names, config keys)
  separate from prose mentions, so an automated check can grep the
  prohibited patterns without false-flagging out-of-scope explainer
  text.

#### R2-n5. Appendix A self-verification checklist omits WAL mode, recovery determinism, and SPEC-007 contract.

- **Severity:** MINOR
- **Section reference:** Appendix A
- **Description:** The checklist asserts deterministic ACs and
  storage completeness but does not cross-check the WAL-mode
  requirement (R2-n1), recovery determinism guarantees (R2-M5), or
  the SPEC-007 consumer contract (R2-M7).
- **Proposed fix:** Append three checkboxes: WAL mode required;
  recovery has explicit grace-window cutoff; SPEC-007 consumer
  interface defined.

### QUESTIONS for the operator

#### R2-Q1. `overshoot_flag` — drop or wire?

- **Severity:** QUESTION (gate for R2-M6 fix)
- **Description:** D7 makes overshoot "advisory only", and SPEC-005
  has no protocol to receive overshoot intent from the gateway. v0.3
  can either drop the column entirely or add a cross-spec patch to
  SPEC-006. Operator decides.

#### R2-Q2. Cross-process crash recovery — own or disclaim?

- **Severity:** QUESTION (gate for R2-M9 fix)
- **Description:** The gateway-crash-after-debit-before-forward
  state is invisible to SPEC-005. v0.3 can either explicitly
  disclaim ownership and let operator reconciliation handle (Option
  A) or push a normative SPEC-006 patch requiring reservation-
  reaper rows in `request_log` (Option B). Operator decides.

#### R2-Q3. v0.3 lock vs SPEC-002 v1.3.4 dependency ordering.

- **Severity:** QUESTION
- **Description:** Three findings (R2-M2 error_code column, R2-M3
  ts_utc index, R2-M4 multi-row-per-request_id semantics) require
  SPEC-002 v1.3.4 patches. v0.3 can either lock contingent on
  SPEC-002 v1.3.4 landing, or carry the patches as parallel work and
  lock SPEC-005 alone. The R1 Q-3 precedent was the operator
  accepting a quarantining fallback for R1-M4; the same pattern
  could apply.

---

## Cross-round comparison

Mapping R1 (Codex, v0.1) findings to R2 (Claude, v0.2) state.

### R1 findings confirmed resolved in v0.2

| R1 | v0.2 closing surface | R2 confirms |
|---|---|---|
| M-1 D1-D12 references | § 1, § 5, § 7, § 12, § 13, § 16 inline (D#) | confirmed |
| M-2 stable provider_id | § 4.8 `ledger_provider_identity_snapshots` | confirmed |
| M-3 historical config | § 4.7 `ledger_config_snapshots` | confirmed |
| M-4 attempt_n determinism | § 4.2, § 8.2 request_log.id ASC + quarantine | confirmed |
| M-5 endpoint JSON | § 11.1-§ 11.5 full JSON + rate limits | confirmed |
| M-6 behavior ACs | § 18 AC-D1-AC-D12 behavior-level | confirmed |
| M-7 H-005 tolerance | § 10.3, § 11.3 zero tolerance on gross | confirmed |
| M-8 unreachable usage_source | § 4.3 enum removed; § 6.2 no row | confirmed |
| N-2 provider_not_reached usage_source | resolved in § 6.2 | confirmed |
| N-4 admin JSON envelope | § 11 standard envelope | confirmed |
| Q-1 config snapshots | added | resolved |
| Q-2 identity snapshots | added | resolved |
| Q-3 wait for SPEC-002 | quarantining fallback chosen | resolved |

### R1 findings only partially closed

| R1 | v0.2 state | R2 layered finding |
|---|---|---|
| N-1 AC-NO-ONCHAIN grep | still keyword-based | R2-n4 carries forward |
| N-3 Appendix E duplication | Appendix E still extensive | deferred; not blocking |

### R2-only findings (net new in this round)

All ten MAJORs (R2-M1 through R2-M10) and four of the five MINORs
(R2-n1, R2-n2, R2-n3, R2-n5) are R2-only. R1 focused on R1-internal
architectural surface (config snapshots, identity snapshots,
endpoint JSON, AC behavior). R2 focused on the M2.1 implicit-
assumption boundary with upstream/downstream specs. The two rounds
are complementary, not redundant.

### Disagreements

None of substance. R1's findings are all valid and v0.2 closes them.
R2 layers in cross-spec precision that R1 did not probe. R2-Q3
re-litigates R1-Q3 in a slightly different form (now bundled with
three SPEC-002 v1.3.4 dependencies, not one).

---

## Cross-spec coherence findings

Audit 2 of the prompt: where SPEC-005 v0.2 claims conflict with,
are unanswered by, or require changes to existing specs.

### X-1. SPEC-005 D8 matrix vs SPEC-006 § 17.7 — null-usage row missing in SPEC-006.

- **Specs in conflict:** SPEC-005 v0.2 § 6.9 vs SPEC-006 v0.8.1 § 17.7.
- **Conflict:** SPEC-006 § 17.7 has exactly 8 rows (200; 503; 502 with
  0 completion; 502 partial; 504 with 0 completion; 504 partial;
  client disconnect v1.2.4+; client disconnect pre-v1.2.4). It does
  NOT have a row for SPEC-001 null-usage error states
  (`error_model_not_loaded`, `error_context_exceeded`,
  `error_queue_full`, `error_internal`). The gateway in practice maps
  these to HTTP 502 with 0 completion → SPEC-006 § 17.7 row "502 with
  0 completion" → debit prompt tokens. But SPEC-005 § 6.9 zero-
  credits the provider on these states. Asymmetry: buyer debited
  prompt tokens > 0; provider credited 0. AC-H005's invariant
  `delta_gross_credits = 0` fails by design on null-usage paths.
- **Minimal patch:** Edit SPEC-006 v0.8.2 (or v0.9) § 17.7: add a
  9th row "SPEC-001 null-usage error (`error_model_not_loaded`,
  `error_context_exceeded`, `error_queue_full`, `error_internal`)
  → completion 0 → quota debited: none → rationale: no provider
  work completed". Mirror in SPEC-005 v0.3 § 6.9 with cross-
  reference. This restores H-005 zero-delta on all paths.

### X-2. SPEC-005 storage contract vs SPEC-002 schema — SPEC-002 v1.3.4 patch needed.

- **Specs in conflict:** SPEC-005 v0.2 § 4.2, § 6.9, § 8.2, § 10
  vs SPEC-002 v1.3.3 FR-B9.
- **Conflict (bundled):**
  - SPEC-005 § 10 scans `request_log` by time window; SPEC-002 FR-B9
    only indexes `request_id`. No `ts_utc` index.
  - SPEC-005 § 6.9 keys on SPEC-001 error code enum; SPEC-002 FR-B9
    only carries free-text `error`. No `error_code` column.
  - SPEC-005 § 8.2 assumes multiple `request_log` rows per
    `request_id`; SPEC-002 FR-B9 prose is singular and ambiguous.
- **Minimal patch:** SPEC-002 v1.3.4 FR-B9: (a) add normative
  `CREATE INDEX idx_request_log_ts_utc ON request_log(ts_utc)` and
  `CREATE INDEX idx_request_log_request_id_id ON request_log(request_id, id)`;
  (b) add `error_code TEXT NULL` column with SPEC-001 v1.2.4 status
  enum (`error_model_not_loaded`, `error_context_exceeded`,
  `error_queue_full`, `error_internal`, plus null/other); (c) add
  normative "Each provider attempt MUST produce its own row;
  `request_id` MAY recur across rows; the only uniqueness constraint
  is `(id)`." Edit: SPEC-002 § 4 FR-B9 block (line 1093ff).

### X-3. SPEC-005 provider-earnings endpoint vs SPEC-002 `/poolz` — no conflict.

- **Specs:** SPEC-005 v0.2 § 11.2 / § 11.4 vs SPEC-002 v1.3.3 § 7
  `/poolz`.
- **Verdict:** Disjoint domains. `/poolz` exposes provider pool
  status (state, model, capacity, tier). SPEC-005 endpoints expose
  provider economics (credits, payouts, faults). No new field is
  needed in `/poolz`; SPEC-005 owns its own endpoints. Out of scope
  for SPEC-002 v1.3.4.
- **Minimal patch:** None.

### X-4. SPEC-005 attribution vs SPEC-004 FR-P11a — consistent; multi-row dependency carried in X-2.

- **Specs:** SPEC-005 v0.2 § 8 vs SPEC-004 v0.3.1 § 6 (line 454),
  AC-SR-8 (line 781).
- **Verdict:** SPEC-004 v0.3.1 mandates `request_log.retried` is a
  count of additional explicit retries, and AC-SR-8 confirms
  per-attempt request_log rows. SPEC-005 § 8.2 reads `retried` and
  derives `attempt_n` accordingly. Consistent except for the
  multi-row-per-`request_id` normative gap, which is owned by X-2.
- **Minimal patch:** None additional beyond X-2.

### X-5. SPEC-005 circuit-broken zero-credit vs SPEC-002 FR-P11a — consistent.

- **Specs:** SPEC-005 v0.2 § 9 vs SPEC-002 v1.3.3 FR-P11a (lines
  564, 605-627; line 508-510 fault table).
- **Verdict:** SPEC-002 FR-P11a defines exactly three breaker-
  qualifying fault categories: `dead-WS-mid-inference`,
  `relay-timeout-mid-inference`, qualified
  `zero-token-completion`. SPEC-005 § 9.1 mirrors all three exactly.
  § 9.2 zero-credits; § 9.4 normal credits resume after recovery
  preflight returns ready. SPEC-002 buyer-cancellation exclusion is
  mirrored at SPEC-005 § 9.1 and § 6.10. Consistent.
- **Minimal patch:** None.

### X-6. SPEC-005 identity-snapshot `response_header` source vs SPEC-006 header strip — consistent.

- **Specs:** SPEC-005 v0.2 § 4.8 (`resolved_from='response_header'`)
  vs SPEC-006 v0.8.1 provider-pinning header strip.
- **Verdict:** SPEC-006 strips INBOUND `X-MacProvider-*` headers
  from buyer requests; it does NOT strip OUTBOUND response headers.
  SPEC-002 line 1008 confirms `X-MacProvider-Provider` is emitted on
  responses. SPEC-005's use of the response header to resolve
  identity is consistent. Consistent.
- **Minimal patch:** None.

### X-7. SPEC-005 attestation_class storage vs SPEC-008 attestation — consistent.

- **Specs:** SPEC-005 v0.2 § 1.4, § 4.3 vs SPEC-008 v0.3.
- **Verdict:** SPEC-008 defines a provider attestation predicate
  (`attested` boolean per provider) but does NOT define reward
  multipliers. SPEC-005 § 1.4 explicitly forbids "v1 reward
  multiplier may use attestation_class"; § 4.3 stores
  `attestation_class TEXT NULL` for future use only. Consistent.
- **Minimal patch:** None.

---

## Consolidated verdict

**Verdict: READY WITH SECOND FIX PASS.**

SPEC-005 v0.2 is architecturally sound and closes every R1 (Codex)
finding via additive structural fixes — `ledger_config_snapshots`,
`ledger_provider_identity_snapshots`, deterministic `attempt_n`
fallback, complete § 11 endpoint JSON contracts, behavior-level ACs
for D1-D12, and zero-tolerance H-005 gross reconciliation. The
locked § 2 D1-D12 decisions remain untouched.

v0.2 is **not yet ready to lock**. The R2 pass surfaces 10 MAJOR
M2.1-class precision findings: 5 internal (R2-M1 null prompt_tokens,
R2-M5 WAL/grace window, R2-M6 phantom overshoot_flag, R2-M7
SPEC-007 boundary, R2-M10 H-005 derivation ambiguity), 3 requiring
SPEC-002 v1.3.4 patches (R2-M2 error_code, R2-M3 ts_utc index, R2-M4
multi-row), 1 requiring a SPEC-006 § 17.7 row (R2-M8 byte-estimate
formula), and 1 cross-process boundary that requires an operator
decision (R2-M9 crash-after-debit). None is CRITICAL; none reopens
§ 2.

Required v0.3 fix pass:

- 10 MAJOR (R2-M1 through R2-M10)
- 5 MINOR (R2-n1 through R2-n5)
- 3 QUESTIONS (R2-Q1 through R2-Q3) — operator pre-locks
- 3 cross-spec patches:
  - **SPEC-002 v1.3.4** (X-2 bundled: ts_utc + composite index,
    error_code column, multi-row-per-request_id normative)
  - **SPEC-006 v0.8.2** (X-1: § 17.7 9th row for SPEC-001 null-
    usage states)
  - SPEC-007 boundary contract (R2-M7, SPEC-005-internal addition
    — not a cross-spec edit because SPEC-007 doesn't exist yet)

After v0.3 lands and SPEC-002 v1.3.4 + SPEC-006 v0.8.2 patches are
merged, SPEC-005 should be lock-ready for
`BUILD_PHASE5_SPEC_005_PROMPT.md`. The operator decides whether v0.3
locks contingent on the SPEC-002/SPEC-006 patches or in parallel
(R2-Q3).
