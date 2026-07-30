# SPEC-016 Step 2 IMPL — continuation prompt for a fresh session

**Handoff context.** Step 1 of SPEC-016 IMPL is committed (`1df0235` on
branch `impl/spec-016`). Between Step 1 and Step 2 kickoff, a Claude-side
adversarial cross-check (round 20, 2 parallel subagents) ran against
v0.1.19, surfaced 3 criticals + 5 majors that 19 codex rounds missed, and
was absorbed into v0.1.20 → v0.1.21 (after one codex fix-pass round).
**Codex round-22 declared CONVERGED 0/0/0/0 and GO for Step 2 IMPL start.**

You are picking up here. Do NOT re-litigate v0.1.21 deltas — codex already
verified them. Your job is to land Step 2 of the IMPL per
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md §2`, against the v0.1.21 SPEC.

## Before writing code — read in this order

1. **`specs/SPEC-016-r20-audit.md`** — what the Claude cross-check found
   and why. Critical for understanding the cross-section attack classes
   the deltas close (C1 funding-key binding, C2 hot-wallet self-funding,
   C3 amount/credits invariant, M1 reorg poll cadence, M2 finality model,
   M4 chain-nonce load-bearing, M5 conservation invariant query).
2. **`specs/SPEC-016-r21-audit.md`** — codex's fix-pass round on v0.1.20
   that produced v0.1.21. Three findings closed: MAJOR-1 confirmation_blocks
   bound contradiction (§4.3 step 7 line 1295 was stale), MEDIUM-1 IMPL
   test (4) impossible assertion (§4.8b stall test), LOW-1 two-RPC budget
   undercount (§4.7).
3. **`specs/SPEC-016-payout-pipeline.md` at v0.1.21** — the locked SPEC.
   Specifically re-read these sections that v0.1.20/v0.1.21 changed:
   - §3.2 deny-list (line ~438, hot wallet denied as source AND destination)
   - §4.3 step 5 (C3 pre-INSERT invariant inside BEGIN IMMEDIATE)
   - §4.3 step 7 (confirmation_blocks bounds — line 1295)
   - §4.7 (M1 reorg-poll cadence + budget accounting + `payout_reorg_poll_rpc_error` event)
   - §4.8b "Chain-nonce uniqueness is load-bearing" + IMPL test (4)
   - §4.9 record-funding (C1 Idempotency-Key tx_hash binding, C2 400 on
     `from_address == hot_wallet`)
   - §payout.tuning bounds (M2 confirmation_blocks `[5, 200]`, M1
     `reorg_poll_window` `[1h, 168h]`)
   - §7.1 `payout_reorg_revert.observed_via` + `payout_reorg_poll_rpc_error`
     + `payout_invariant_violation.where='amount_credit_mismatch'`
   - §7.4 query (E) hot-wallet self-funding detector + query (F)
     money-conservation aggregate invariant
4. **`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`** — the IMPL master prompt.
   Step 2 scope is §4.3 runner + §4.6 nonce/abandon endpoint. (The §4.9
   handler is Step 3, §6.5+§7.4 is Step 4.) Note: this file was also
   updated by v0.1.21 (`confirmation_blocks ∈ [5, 200]` at lines 82 + 885).
5. **`specs/SPEC-016-IMPL-PROMPT-audit.md`** + the existing IMPL audit
   prompts under `specs/AUDIT_SPEC_016_IMPL_PHASE_*` — the audit-loop
   discipline. Step 2 follows the same pattern: code → codex audit
   prompt → fix loop until 0/0/0/0 → only THEN push branch.

## Step 2 scope (from BUILD_SPEC_016 §2)

Build the §4.3 runner (cadence cycle, row selection, attempt persistence,
broadcast, receipt verification, confirmation, `ClaimPayoutReady` handoff)
and the §4.6 nonce + `/admin/payout/abandon-attempt` endpoint. The runner
MUST honor every v0.1.21 delta — specifically:

- **C3 (§4.3 step 5):** the pre-INSERT invariant `amount_base_units ==
  lpr.provider_credits` MUST be asserted INSIDE the `BEGIN IMMEDIATE`
  transaction with `lpr.provider_credits` re-read inside the same txn —
  NOT trusted from the §4.3 step 1 SELECT. Mismatch → ROLLBACK + emit
  `payout_invariant_violation where='amount_credit_mismatch'` (PAGE)
  + HALT. Add an IMPL test that injects a mismatched
  `amount_base_units` and asserts the runner halts.
- **M1 (§4.7):** the reorg poll cadence is part of the §4.3 runner
  cycle. Each cadence cycle the runner re-polls every `confirmed_at_utc
  >= now - reorg_poll_window` row via the §4.4 two-RPC discipline.
  Budget accounting: at default values, 200 row re-polls = 400 RPC
  calls per cycle. IMPL the `payout.tuning.reorg_poll_window` config
  key with bounds `[1h, 168h]`, default `24h`.
- **M2 (§4.3 step 7 / §payout.tuning):** `confirmation_blocks` bounds
  are `[5, 200]` (NOT the v0.1.19 `[2, 50]`). The config-parse code
  in Step 1 may have used the old bounds — verify and update. Default
  remains 5.
- **M4 (§4.8b):** Step 1 built the lease schema. Step 2 builds the
  broadcast path. The post-CAS broadcast race is unguarded by software
  between the post-COMMIT lease re-read and `eth_sendRawTransaction` —
  chain nonce-uniqueness is the load-bearing guard. IMPL the test (4)
  per the §4.8b spec: inject 30s sleep AFTER post-COMMIT lease re-read,
  before broadcast; assert one process gets `nonce too low` /
  `already known` and the runner does NOT emit
  `payout_invariant_violation` on that response.
- **M5 (§7.4):** the conservation invariant query (F) and the hot-wallet
  self-funding detector (E) land in Step 4's `reconcile.sql`, NOT Step 2.
  But Step 2's runner MUST NOT BREAK the invariant — i.e. the C3 check
  is the load-bearing guard.

## Audit-loop discipline (mandatory)

Per [[feedback-build-audit-loop]] + [[feedback-codex-only-audits]]: after
each Step 2 code stretch, author a narrow IMPL audit prompt
(`specs/AUDIT_SPEC_016_IMPL_PHASE_2_PROMPT.md`), fire at codex via
`omc ask codex`, absorb findings, loop until CONVERGED 0/0/0/0. Only
THEN push the branch and open the bundled PR per
[[feedback-bundle-spec-impl-one-pr]] (one PR = SPEC v0.1.21 deltas +
Step 1 + Step 2 + later steps).

Per [[feedback-pause-before-audit]]: after codex completes a code stretch,
run a smoke check (`go test ./internal/payout/...` + a manual read of the
diff for cross-step inconsistency) BEFORE firing the audit. Pause if
anything surfaces.

Per [[feedback-codex-only-audits]]: SPEC + IMPL audit loops use codex
via `omc ask codex` or `/ccg`, NOT Claude internal subagents
(code-reviewer, security-reviewer, architect). Claude wrote the round-20
cross-check INTENTIONALLY as a layered different-lens pass; that pattern
does NOT generalize to per-step IMPL audits.

## Branch + commit state

Branch `impl/spec-016` HEAD carries Step 1 IMPL + SPEC v0.1.21 deltas as
of round-22 CONVERGED. Do NOT push the branch until Step 2 IMPL audit
converges. Do NOT open the PR — that's after all 4 steps land per the
single-PR plan in commit `92c8672`.

## Step 2 deliverables checklist

- [ ] §4.3 runner cycle: row selection (§4.3 step 1), cap re-check
  (§4.3 step 4), cancel-handling pre-check (§4.3 step 5 prologue),
  pre-INSERT C3 invariant assertion (§4.3 step 5), attempt INSERT,
  build+sign+verify+persist+broadcast (§4.3 step 6 with pre-broadcast
  Signer-output verification per §4.3 step 6 NORMATIVE block).
- [ ] §4.3 step 7 receipt polling + cancel-specific verification +
  reorg-poll cadence (M1) within the same cycle loop.
- [ ] §4.3 step 8 `ClaimPayoutReady` handoff with SPEC-005 §11.4
  Idempotency-Key equality.
- [ ] §4.6 nonce allocation + `/admin/payout/abandon-attempt` endpoint
  (operator-action endpoint; PAGE on every invocation per §7.1).
- [ ] §4.7 reorg detection path (record-only; orphan recording in Step 3).
- [ ] §4.8b lease self-fencing on every §4.3 step; IMPL test (4) per
  v0.1.21 §4.8b spec.
- [ ] `payout.tuning.reorg_poll_window` config key wired with bounds
  `[1h, 168h]`, default `24h`. SIGHUP-only hot-reload path.
- [ ] All Step 2 events from §7.1 emit at the right severity (PAGE for
  invariant violations + reorg events + lease losses; WARN for
  reorg-poll RPC errors + flag audit reaped; INFO for cancel confirmed).
- [ ] IMPL tests cover the C3 invariant, M2 bounds enforcement, M4
  test (4) stall scenario, and M1 reorg-poll cadence.
- [ ] Step 2 IMPL audit prompt at
  `specs/AUDIT_SPEC_016_IMPL_PHASE_2_PROMPT.md` authored.
- [ ] Codex audit loop runs until CONVERGED 0/0/0/0.

## What you ARE NOT doing in Step 2

- Step 3 territory: §4.9 `/admin/payout/record-funding` handler (C1 + C2
  belong here), §6.4.1 portal `/providers/{id}/payouts` endpoint, the
  §4.7 orphan-recording endpoint.
- Step 4 territory: §6.5 hot-reload bound re-enforcement + §7.4
  reconcile.sql file (where queries E and F live).
- M3 (EIP-712 verifyingContract UX): explicitly deferred per
  `specs/SPEC-016-r20-audit.md`. Will be reopened against SPEC-014 v0.9.

## Cross-references

- Locked SPEC: `specs/SPEC-016-payout-pipeline.md` v0.1.21 at branch
  `impl/spec-016` HEAD (post round-22 CONVERGED)
- Step 1 commit: `1df0235`
- IMPL master prompt: `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`
- Round 20 (Claude cross-check) narrative: `specs/SPEC-016-r20-audit.md`
- Round 21 (codex fix-pass) narrative: `specs/SPEC-016-r21-audit.md`
- Round 22 codex artifact (CONVERGED):
  `.omc/artifacts/ask/codex-spec-016-round-22-audit-re-run-the-audit-at-specs-audit-spec-2026-06-25T14-35-44-145Z.md`

## Stranger-phase context (informs UX edges, not Step 2 code)

The user is preparing for stranger-phase rollout. SPEC-014 v0.8 (provider
portal) is shipped at `portal.streamvc.live`. SPEC-014 v0.9 (payout-address
registration screen + earnings-with-payout-ETA banner) is NOT YET written
— it consumes the endpoints Step 2 builds. The Step 2 endpoint shapes
matter because v0.9 will be authored against them. If Step 2 IMPL surfaces
a deltas-vs-SPEC drift in endpoint shape, FLAG IT before pushing — v0.9
spec writing may start in parallel and a moving endpoint shape forces v0.9
to chase.
