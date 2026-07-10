# AUDIT_SPEC_016_IMPL_PROMPT — Audit the SPEC-016 IMPL kickoff prompt

You are auditing the BUILD prompt
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` on branch
`spec/016-payout-impl-prompt` (PR
[#162](https://github.com/Augustas11/macprovider/pull/162)).

The prompt is the kickoff artifact for a fresh codex session
that will implement the payout pipeline in
`phase4-coordinator/internal/payout/`. It is NOT itself a
normative spec — every "MUST / MUST NOT" lives in
`specs/SPEC-016-payout-pipeline.md` v0.1.19 (LOCKED at
commit `5c034a0` on `main`). Your job is to check the prompt
faithfully encodes the SPEC and won't waste the IMPL author's
time on wrong step boundaries, missed requirements, or
contradictions.

## Scope

The only intended modified file is:

- `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` (new, 1196 lines)

The diff is +1196 / -0. No code, no SPEC normative edits, no
schema, no test changes are in scope. Anything else in the
diff is itself a CRITICAL finding.

## Context the prompt depends on (read these first)

1. `specs/SPEC-016-payout-pipeline.md` at commit `5c034a0` on
   `main` — the controlling contract. Every §-reference in
   the audited prompt MUST resolve against this file.
2. `specs/SPEC-016-r9-audit.md` through
   `specs/SPEC-016-r19-audit.md` — the codex round history
   that produced the v0.1.19 locked text. The 11-round
   trajectory explains *why* particular SPEC paragraphs
   exist (e.g. round-14 MAJOR-1 confused-deputy filter,
   round-15 MAJOR-2 cancel-reorg carve-out, round-10
   MAJOR-1 pre-broadcast signed-tx verify, round-11 MAJOR-2
   CAS predicate). The audited prompt should surface every
   one of these defect classes to the IMPL author.
3. `beta/DECISION_CRITERIA.md` Entry 88 — the rail decision
   (USDC on Base) and the anticipatory-schema pattern. The
   audited prompt MUST direct the IMPL author NOT to
   re-litigate either.
4. `specs/BUILD_SPEC_015_IMPL_PROMPT.md` — the prior
   stepped-IMPL prompt that this one mirrors structurally.
   House-style reference only; SPEC-016 is a different
   contract.

## Audit tasks

Walk the audited prompt section-by-section and report
findings by severity. Focus on these failure modes:

### A. SPEC §-reference resolution (most important)

For every § citation in the prompt (e.g. "§3.2 step 5",
"§4.3 step 6", "§4.8b acquire algorithm", "§9.5b.1"),
verify the section exists in SPEC-016 v0.1.19 at commit
`5c034a0` AND that the prompt's paraphrase of it matches the
SPEC text. A wrong § number, a step renumbering miss, or a
paraphrase that drops a normative requirement is the
highest-cost defect class — it directs the IMPL author at a
SPEC clause that doesn't say what the prompt claims.

Particular hot spots:

- §4.3 step numbering. The SPEC underwent a renumbering in
  v0.1.8 (singleton-runner lease became new step 3,
  bumping sign/build/broadcast from step 5 to step 6). The
  audited prompt MUST reflect the v0.1.19 numbering. The
  v0.1.18 codex round-11 LOW-4 closure call-out is a hint
  for what to check.
- §4.8a / §4.8b / §4.8c — these section letters were added
  in different rounds; v0.1.18 swapped the section order.
  Verify the prompt's cites match.
- §9 prerequisites — the prompt lists eight items
  (1, 2, 3, 4, 5+5a+5b, 6, 7, 8) and claims "without
  items 1, 2, 3, 4, 5a, 5b, 6, 7, 8 (item 5 itself is the
  only soft prerequisite), IMPL is blocked." Verify this
  matches §9 closing text in the SPEC.
- §9.5b.1 — verify the prompt encodes the SPEC-005 vX.Y+1
  contract surface correctly: the strict-equality fix
  (`gross_credits == provider_credits`), the snapshot
  binding to `payout_reorg_orphans.observed_*` (NOT
  mutable `ledger_payout_ready.*`), the regex
  `^reorg_compensation:\d+:\d+$`, the `trg_lpr_terminal_status_guard`
  exact-name preservation.
- §6.5 namespace split — verify the prompt's tuning bounds
  matrix (`address_cooling_off_period >= 1h`,
  `confirmation_blocks ∈ [2, 50]`, `run_interval ∈
  [5m, 24h]`, etc.) matches the SPEC's normative bounds.

### B. Missed normative requirements

For each major SPEC section the prompt claims to encode,
check whether the prompt surfaces every "MUST / MUST NOT" in
that section. Use this checklist:

- §3.2 EIP-712: domain fields (name, version, chainId,
  verifyingContract), struct fields (providerId, address,
  chain, nonce, tsUtc), field-by-field equality between
  typed-data and request body (NOT just ecrecover-pass),
  ±5min skew, 10-minute prune retention, EIP-55 enforcement
  with checksum-skipped acceptance, deny-list contents,
  canonical-form NOT echoed in 400 response.
- §3.3 endpoint: chi/gorilla over http.ServeMux, single
  path-table check, pre-auth pause check, TOCTOU re-check
  in BEGIN IMMEDIATE, server-side stamp of
  `registered_against_hot_wallet`, DisallowUnknownFields
  FORBIDDEN, co-residency assertion, `submitted_fingerprint`
  is 6-prefix-4-suffix (not raw bytes).
- §4.3 per-run algorithm: all 9 steps; specifically the
  three compound guards at step 3 (lease + BEGIN IMMEDIATE
  + idx_pa_one_live_non_cancel_per_payout), the
  cancel-handling pre-check at step 5 with the three
  state branches (unbroadcast / broadcast-unconfirmed /
  confirmed) and the §4.3-step-7 cancel-specific
  verification carve-out, the pre-broadcast Signer-output
  verification + CAS persist at step 6 with side-channel
  discipline, the two-RPC + chain-side value verification
  at step 7 (input calldata exact-68-byte assertion +
  ecrecover sender check + exactly-one matching Transfer
  log), the `payoutCurrency = "USDC-BASE"` literal at
  step 8 + intra-txn trigger-presence check.
- §4.6 abandon: runner-active gate via lease heartbeat,
  cancel-row INSERT with `broadcast_at_utc=NULL`,
  post-COMMIT cancel-broadcast preflight, CAS-stamp
  `broadcast_at_utc` post-broadcast, 404/409/422/429 error
  codes, all four RUNTIME-IMMUTABLE caps.
- §4.7 reorg: provider-payout carve-out (§9.5b.1
  compensation path) vs cancel-self-transfer carve-out
  (NO `ledger_payout_ready` revert), the §4.8c outbox
  table + reaper.
- §4.8a runtime_flags: three-table empty-check bootstrap
  gating, sentinel-asymmetry HALT, outbox audit pattern,
  CAS-claim with RETURNING id on both sync emitter and
  reaper paths, dedupe-by-event_id contract, same-DB pin.
- §4.8b lease: acquire / takeover (3 × run_interval stale
  window) / heartbeat / self-fence on every §4.3 step 4-8
  / clean-shutdown release.
- §4.9 funding: `source='manual'` only during bootstrap
  window, one-way flip via trigger pair, BOTH-RPC receipt
  verification for `source='rpc-confirmed'`, UNIQUE(tx_hash)
  idempotency.
- §5.3 day cap: reservation-aware query (A) + (B), the
  stale-reservation halt-check from v0.1.10 round-11
  MAJOR-1.
- §6.3 process hardening: setrlimit, prctl, mlockall with
  fail-loud, systemd-coredump bypass check, Linux-only
  enforcement, `VmLck` assertion test.
- §6.3.1 Signer interface: `FromAddress` + `SignTx`, NO
  `SignMessage` (footgun carve-out), unsignedTxBytes
  format (EIP-2718 type-prefixed RLP, KMS hashes
  themselves, caller does NOT pre-hash), error semantics.
- §6.4 / §6.4.1 key rotation: pause/resume endpoints with
  outbox + 60s rate-limit, persistent `registration_paused`
  across restart, post-rotation `registered_against_hot_wallet`
  filter.
- §6.5 dual-namespace loader: three buckets (security
  immutable / tuning SIGHUP-only / runtime CLOSED), fsnotify
  FORBIDDEN, reload-endpoint FORBIDDEN, bound re-enforcement,
  in-flight `pending_until_utc` NOT recomputed, `payout.enabled`
  grandfathered.
- §7.1 events: every PAGE / WARN event named in §9 prereq
  item 6 should be emitted somewhere in the IMPL — the
  prompt should make this assignment unambiguous.
- §7.4 reconciliation: queries (A)/(B)/(C)/(D) +
  chain-balance recon + 1h cadence + signed drift
  positive/negative semantics.

### C. Wrong step boundaries

The prompt splits IMPL into 4 steps. A step boundary is
"wrong" if a requirement is split across steps in a way
that creates dependency hazards (Step N needs something
landed in Step N+1) or that creates a known-broken
intermediate state on `main`. Check:

- Step 1 lands schema + §3.3 + §3.2. Does Step 1's code
  depend on anything that lands in Step 2-4 to compile or
  run?
- Step 2 lands §4.3 runner + §4.6 + §4.8b lease. The
  cancel-handling pre-check at §4.3 step 5 calls into
  cancel-broadcast logic (§4.6). If §4.6 endpoint lands
  here, does the §4.3 cycle have the dependencies?
- Step 3 lands §4.9 + §6.4.1 + §4.7. The §4.7 cancel-reorg
  reactivation marker (`cancel_reconfirm_stale_paged_at_utc`)
  schema lives in Step 1, but the §4.7 reactivation logic
  lives here. Is the column documented as "added in Step 1,
  used in Step 3"?
- Step 4 lands §6.5 loader split + §7.4 + ops. The §7.1
  event emitters are scattered across earlier steps but
  the matrix lands here. Is that explicit?

### D. Contradictions

A contradiction is a place where the prompt asserts X in
one section and ¬X in another. Pay attention to:

- "What you must NOT do" (§10) vs the body. E.g. §10 says
  "do NOT use http.ServeMux" — §3.3 body should also say
  this; §10 says "do NOT add a SignMessage primitive" —
  §6.3 / §6.3.1 body should also say this.
- Step boundaries vs the package-layout file list in §5.
  Does `lease.go` live in Step 2 (correct — it's used by
  §4.3) but get scaffolded in Step 1?
- The audit-loop sentence "loop until 0 CRITICAL / 0 MAJOR /
  0 MEDIUM" vs the prompt's tolerance for LOW deferrals
  (which it explicitly allows). Internally consistent?

### E. Missing memory rule references

The user pinned five feedback memories to the prompt
contract. Verify each is wired into the prompt's text:

- `feedback-spec-audit-loop-before-pr` — used to justify the
  no-PR-before-audit-loop discipline.
- `feedback-codex-only-audits` — used to ban Claude
  internal subagents from the audit loop.
- `feedback-spec-audit-file-convention` — used to dictate
  the `SPEC-016-IMPL-STEP_N-audit.md` file convention.
- `feedback-build-audit-loop` — used to mandate audit before
  every IMPL push.
- `feedback-bundle-spec-impl-one-pr` — used to justify
  shipping the IMPL prompt as a SEPARATE PR.
- `macprovider-required-review-merge-pattern` /
  `gh-pr-merge-augustas11-token-prefix` — used in §8 PR
  workflow.

### F. Style / scrutability

LOW findings only. Is the prompt readable in one sitting?
Are §-anchored links to SPEC-016 working? Are file paths
relative to repo root and accurate?

## Verdict + counts

- Verdict: READY or NEEDS FIX PASS.
- Counts: CRITICAL / MAJOR / MEDIUM / LOW.
- Findings with prompt-line references and SPEC-§
  cross-references.
- Severity calibration: CRITICAL = the IMPL author will
  produce wrong code if they follow the prompt as written
  (wrong § citation, missed money-path requirement,
  contradictory step boundary). MAJOR = the IMPL author
  will waste a meaningful chunk of time (e.g. a missing
  primitive citation, a wrong file path, a missed
  cross-step dependency). MEDIUM = the IMPL author will
  ask a clarifying question (e.g. ambiguous wording,
  missing example, unclear which test goes where). LOW =
  cosmetic / stylistic.

The merge gate for this PR is **0 CRITICAL + 0 MAJOR**.
MEDIUM is the operator's judgment call — likely-fix on
review; deferrable with a tracking note if scoped.

## Important — what NOT to do

- Do NOT audit SPEC-016 v0.1.19 itself; it was already
  audited to 0/0/0 over rounds 9-19. If you find a
  defect in the SPEC text, file it as a SPEC v0.2
  candidate and continue auditing the prompt.
- Do NOT propose a different IMPL decomposition (e.g.
  3 steps instead of 4); the 4-step split is an operator
  decision. Audit the boundaries the prompt chose, not
  whether a different split would be better.
- Do NOT propose adding normative requirements to the
  prompt — its job is to surface SPEC requirements, not
  create new ones.
