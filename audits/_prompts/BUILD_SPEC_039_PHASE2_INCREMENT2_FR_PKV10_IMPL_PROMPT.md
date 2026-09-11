# BUILD: SPEC-039 Phase-2 Increment 2 — FR-PKV10 contiguous KVCache extraction (#887)

> **2026-09-11 — Increment 2 landed** in #1476 (`44df935c`). Do not re-execute
> this prompt. The SPEC-038 sticky/AC-19 consumer is
> [#1477](https://github.com/Augustas11/macprovider/issues/1477) /
> `audits/_prompts/BUILD_SPEC_038_INCREMENT3_STICKY_AC19_IMPL_PROMPT.md`.

You are starting a **new** MacProvider implementation session. You have no
memory of prior chats. Read this file end-to-end before writing code. Then
execute it. Do not re-triage, do not park, do not ask whether to implement.

**Tracker:** https://github.com/Augustas11/macprovider/issues/887  
**Predecessor (already merged, do not redo):** #1474 / #1475 (`c6a091d9`)  
**Follow-on (do not implement here):** #1477  
**Closed stale drafts (do not revive):** #889, #894

---

## 0. Mission (one sentence)

Implement FR-PKV10: a sequence's paged block table becomes a **live, injectable
contiguous `KVCache`**, plus same-conversation retain/reattach, with exact
SPEC-024 token-granular LCP/trim including a **mid-block** boundary — and land
that primitive **default-off / runtime-inert**.

This makes the public API SPEC-038 FR-CB4 / AC-19 and SPEC-024 cold-tier can
later consume. Those consumers are **not** this PR.

---

## 1. Workspace, identity, rules

Before any edit:

1. Read `CLAUDE.md` and `AGENTS.md`. Follow them.
2. Do **not** edit canonical `/Users/augstar/macprovider-poc` unless the
   operator explicitly names that checkout. Fresh sibling worktree:

```bash
git status -sb
git worktree list
git fetch origin
git worktree add ../macprovider-887-inc2-fr-pkv10 -b feat/887-spec039-inc2-fr-pkv10 origin/main
cd ../macprovider-887-inc2-fr-pkv10
```

Confirm `origin/main` contains Increment 1 (`c6a091d9` or later
"Enable measured SPEC-039 attach without sticky reattach"). If it does not,
STOP and rebase onto current `origin/main`.

3. Confirm `git log origin/main..HEAD` stays empty until your first commit,
   then contains only this task.
4. `gh auth switch -u Augustas11` before push / `gh pr create`. Approve from
   `antfleet-ops`. Never self-approve as Augustas11. Never
   `gh pr merge --admin` unless the operator writes that permission **in the
   same turn**.
5. Treat red `spec-index / check` as a merge gate. Do not merge past it.
6. Clean-room: do **not** inspect `d-inference` / `Layr-Labs/*` source. Build
   from `ml-explore` MLX, public `mlx-swift-lm` `KVCache`, public `mlx-lm`,
   vLLM (Apache), and the PagedAttention paper.

Audits: three lanes via `omc ask codex` (code-reviewer, security-reviewer,
architect). Do **not** use Cursor `Task` subagents and do **not** call
`codex` / `codex exec` directly. Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

---

## 2. Why this exists (read once)

On current `origin/main` after #1475:

- Increment 1 is real: measured-identity attach, `PagedKVSharedForwardBackend`,
  scheduler wiring. Production `ModelRuntime` still sets
  `pagedKVObservedRuntimeIdentity = nil`, hardware proof nil,
  `pagedKVSchedulerBackendInstalled = false`. Buyer traffic stays fail-closed.
- Fresh greedy requests can attach **only** when tests inject a complete
  observed identity. Sticky / conversation-keyed requests still serial-route
  (`stickyCacheBridgeUnavailable`).
- `PagedKVContiguousCacheBridge` still yields
  `PagedKVMaterializedByteCache` (neutral **bytes**). That is **not** the
  standalone contiguous `KVCache` FR-PKV10 / SPEC-024 / SPEC-038 require.
- Allocator already has handle-level `retain` / `reattach` /
  `discardRetained` and `trim`. Those are not a live `KVCache` handoff and
  are not an AC-15 proof by themselves.

#889/#894 bundled Increment 1+2 and failed audit (self-asserted provenance,
unproven parity, lifecycle bugs). Increment 1 is done. **Do not cherry-pick
those drafts.** Restart from current `origin/main`.

---

## 3. In scope

Consume Increment 1 and the frozen engine. Do not redefine storage layout,
block size, kernel semantics, allocator internals, descriptor schema, handle,
or the measured-identity attach gate.

1. **Live contiguous extraction.** Implement
   `PagedKVContiguousCacheBridge` **or a successor protocol** so a sequence's
   paged block table materializes a **live, injectable contiguous `KVCache`**
   in exact logical token order (fp16 byte-exact vs stock contiguous for the
   same tokens). Neutral byte materialization may remain as an internal step;
   it is not the public FR-PKV10 contract.
2. **Same-conversation retain-and-reattach.** A sequence's own physical
   blocks may be retained past decode end and reattached to a later decode of
   the **same** conversation without a contiguous copy. Cross-conversation
   reattach MUST fail (`conversationMismatch` or equivalent).
3. **SPEC-024 token-granular LCP/trim, including mid-block.** Extracted and
   reattached caches MUST trim exactly the requested token count on every KV
   layer (a shortfall is a miss). A mid-block boundary adjusts the tail
   block's `tailValidTokenCount`; no whole-block rounding.
4. **Public API.** Scheduler / cold-tier code must be able to call this
   without redefining engine internals. You may add a thin test-only or
   internal helper on `ModelRuntime` / the bridge. Do **not** turn on
   production observation or canary.

## 4. Out of scope (hard)

- Redo Increment 1 attach / shared-forward / identity provenance.
- SPEC-038 FR-CB4 batched cross-turn reuse serving buyer traffic.
- AC-19 batched sticky-hit billing parity as a serving feature.
- Lifting `stickyCacheBridgeUnavailable` so conversation-keyed requests enter
  a production batch. Leave that admission ladder in place; this PR ships the
  primitive those paths will consume later.
- Wiring SPEC-024 cold-tier to persist/promote paged state in production.
- Enabling `continuous_batching: canary` or `on` for buyer traffic.
- Packaged `>32GB` enable-gate runs
  (`docs/runbooks/continuous-batching-enable-gate.md`).
- Salvaging #889 / #894.
- Buyer API, receipt tuple, pricing, routing, coordinator/gateway money-path
  changes.
- Inspecting `d-inference`.

**Production observation:** this merge MUST NOT construct a real runtime
observation in the production serve path. Nil observation still fails closed.
Tests may inject identity + a paged sequence to prove extraction. Green CI is
not enablement.

---

## 5. Controlling contracts and live seams

Read before coding:

| Surface | Path |
|---|---|
| SPEC-039 FR-PKV10 / AC-15 | `specs/SPEC-039-paged-kv-attention-engine.md` |
| SPEC-024 LCP/trim (FR-CI2/FR-CI3) | `specs/SPEC-024-*.md` (token-granular trim; mid-block is the load-bearing case) |
| SPEC-038 consumer notes only | `specs/SPEC-038-continuous-batching.md` FR-CB4, AC-19 — do not implement serving |
| Engine, byte stub, allocator retain | `phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift` (`PagedKVContiguousCacheBridge`, `retain`/`reattach`/`trim`) |
| Paged `KVCache` seam | `phase3-binary/Sources/macprovider-cli/PagedKVCache.swift` |
| Increment 1 backend | `phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift` |
| Sticky still serial | `phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift` |
| Production nil observation | `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (init still assigns identity/proof/backend-installed false) |
| Existing engine tests | `phase3-binary/Tests/MacProviderCoreTests/PagedKVEngineTests.swift` |
| Increment 1 bridge tests | `phase3-binary/Tests/macprovider-cliTests/PagedKVRuntimeBridgeTests.swift` |
| Cold-tier tests (do not break) | `phase3-binary/Tests/macprovider-cliTests/KVConversationColdTierTests.swift` |

Honest governance (this **is** SPEC-039-R010):

- specs: `SPEC-039` (cite `SPEC-024` only if you change its text; consuming
  LCP/trim semantics does not require a SPEC-024 edit)
- requirements: `SPEC-039-R010` (primary). You may also list `SPEC-039-R002`
  / `SPEC-039-R009` if the diff actually exercises allocator retain and
  SPEC-038 composition seams. Do not dump Increment 1's R006/R011/R012 list
  unless you change those paths.
- authority domain: `paged-kv-attention`
- `behavior_change: "yes"`
- `contract_change: "none"` unless you edit `specs/SPEC-*.md`,
  `specs/AUTHORITY.json`, or `specs/CONFORMANCE.json`
- If you map R010 implementation/tests in `CONFORMANCE.json`, that is a
  contract_change and must be honest (pending until evidence exists is fine;
  do not claim production journeys)
- `arbitration`: `CODE_BUG` unless a SPEC text change forces otherwise

Validate the PR declaration locally before `gh pr create`
(`python3 scripts/check_spec_pr_declaration.py`).

---

## 6. Load-bearing correctness (money-path)

**AC-15 / FR-PKV10.**

- Materialize paged block-table → standalone contiguous `KVCache` is fp16
  byte-exact against stock contiguous for the same tokens.
- Re-inject that cache and continue decode without token/accounting drift
  vs a stock contiguous control.
- Retain-and-reattach continues the **same** conversation without a
  contiguous round-trip.
- Mid-block trim: tail `tailValidTokenCount` shrinks; no whole-block
  rounding; a shortfall is a miss on every layer.
- Cross-conversation reattach is rejected.
- No sharing of one conversation's blocks with another.

Do **not** claim FR-CB6 batched sticky parity or AC-19 in the PR body. Those
are later consumers.

Do **not** weaken Increment 1: advertised-as-observed identity still fails;
production nil observation still inert.

---

## 7. Tests (minimum)

Deterministic and offline-runnable where possible. Against the real engine
interface or a SPEC-039-compatible fake — never a redefinition of engine
internals.

- Byte-exact extract vs stock contiguous (multi-block, non-identity physical
  order if the engine already has that fixture).
- Round-trip: paged → contiguous `KVCache` → re-inject.
- Mid-block LCP/trim on extract and on retain/reattach.
- Cross-conversation reattach fails.
- Increment 1 attach tests still pass (identity match / fail-closed / sticky
  still serial in the admission ladder).
- Production-shaped nil observation still does not attach.

Suggested filters:

```bash
cd phase3-binary
swift test --filter PagedKVEngineTests
swift test --filter PagedKVRuntimeBridgeTests
swift test --filter KVConversationColdTierTests
```

Add a dedicated filter for the new extraction/retain tests and name it in
the PR body. Local hosts may skip MLX-metallib-backed cases; CI
`phase3-binary (swift test)` is the metallib-capable gate — do not treat
local skips as a pass of those cases.

Known flake: `ContinuousBatchSchedulerTests.testHangingTokenSinkHardTimeoutKeepsLiveTaskCapacityBounded`.
Rerun after a local pass; do not treat a one-off CI flake as a product
regression.

---

## 8. Audit loop

Not done until the **full landing diff** is audited (commit before first
fix → working tree, scoped to the fix files).

```bash
omc ask codex --agent-prompt code-reviewer --prompt "<lane prompt>"
omc ask codex --agent-prompt security-reviewer --prompt "<lane prompt>"
omc ask codex --agent-prompt architect --prompt "<lane prompt>"
```

Write lane prompts under `audits/<date>/` (backtick-safe: prompt in a file).
Adversarial questions:

- Is the public handoff a live contiguous `KVCache`, or still only bytes?
- Can mid-block trim round to a whole block or miss a layer?
- Can conversation A reattach B's blocks?
- Does production serve still fail closed with nil observation?
- Did this PR silently lift sticky requests into a batch without AC-19 proof?
- Any leakage of paged block tables across requests?

Iterate until 0 C / 0 H / 0 M. Re-audit the fix delta each round. Carry
LOW/INFO in the PR body with rationale.

Do not edit the worktree while an `omc ask codex` lane is running (it can
silently revert).

---

## 9. PR and merge

Ship when tests pass and audits are at bar. Do not wait for "OK to PR?"

- Branch already created in §1.
- PR title: `SPEC-039 Phase-2 Increment 2: FR-PKV10 contiguous KVCache extraction (#887)`
- Body: exactly one `SPEC-GOVERNANCE-DECLARATION` block; `Closes #887`;
  state inert/default-off; state SPEC-038 sticky serving / AC-19 / cold-tier
  consumption are out of scope; record audit artifact paths.
- Merge gate: green **`ci-required`** and green **`spec-index / check`**, plus
  antfleet-ops approval, then squash-merge as Augustas11
  (`gh pr merge <n> --squash --delete-branch`). No `--admin`.
- After merge: sync canonical `main` to `origin/main`. Sticky serving /
  AC-19 is now [#1477](https://github.com/Augustas11/macprovider/issues/1477),
  not a continuation of this prompt. Do **not** start canary enable from
  this session.

Provider safety if you touch the live Mac: no broad `pkill`; narrow `pgrep`;
bootout `live.malibu.provider-watchdog` then the provider via graceful
`launchctl bootout`, off-peak; restore and verify serving. Never print the
buyer token.

---

## 10. Done when

- Live contiguous `KVCache` extraction exists (not bytes-only).
- Retain/reattach is same-conversation only; cross-conversation fails.
- Mid-block LCP/trim round-trip tests pass.
- Sticky admission ladder still serial-routes conversation-keyed production
  requests.
- Production observation stays nil → inert.
- Offline tests green; CI swift tests green; three-lane audit 0 C/H/M.
- PR merged. #887 closable.

Enable proof on a packaged `>32GB` install is **not** this session.
SPEC-038 batched sticky serving and SPEC-024 production cold-tier consumption
are **not** this session.
