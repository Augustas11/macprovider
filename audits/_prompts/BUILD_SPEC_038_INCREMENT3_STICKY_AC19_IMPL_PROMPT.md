# BUILD: SPEC-038 Increment 3 — FR-CB4 sticky/cross-turn batching + AC-19 billing parity (#1477)

> **2026-09-11 — Increment 3 landed** in #1489 (`84ef22e7`). Do not re-execute
> this prompt. The production observation / durable-replay slice is
> [#1500](https://github.com/Augustas11/macprovider/issues/1500) /
> `audits/_prompts/BUILD_SPEC_038_INCREMENT4_PRODUCTION_OBSERVATION_IMPL_PROMPT.md`.

You are starting a **new** MacProvider implementation session. You have no
memory of prior chats. Read this file end-to-end before writing code. Then
execute it. Do not re-triage, do not park, do not ask whether to implement.

**Tracker:** https://github.com/Augustas11/macprovider/issues/1477  
**Predecessors (already merged, do not redo):**
- Increment 1 #1474 / #1475 (`c6a091d9`) — observed-identity attach + shared `[B,1]`
- Increment 2 #887 / #1476 (`44df935c`) — FR-PKV10 contiguous `KVCache` extraction
**Follow-on (do not implement here):** #1500 production observation  
**Closed stale drafts (do not revive):** #889, #894

---

## 0. Mission (one sentence)

Wire the already-landed FR-PKV10 primitive into SPEC-038 so conversation-keyed
and sticky-cache requests can enter the existing scheduler with **serial-identical
`cached_prompt_tokens` (AC-19)**, and land that consumer **default-off /
runtime-inert**.

This is the SPEC-038 *consumer* of Increment 2. It is not enablement.

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
git worktree add ../macprovider-1477-inc3-sticky-ac19 -b feat/1477-spec038-inc3-sticky-ac19 origin/main
cd ../macprovider-1477-inc3-sticky-ac19
```

Confirm `origin/main` contains Increment 2 (`44df935c` or later
"Land FR-PKV10 extraction primitive without serving enablement"). If it does
not, STOP and rebase onto current `origin/main`.

3. Confirm `git log origin/main..HEAD` stays empty until your first commit,
   then contains only this task.
4. `gh auth switch -u Augustas11` before push / `gh pr create`. Approve from
   `antfleet-ops`. Never self-approve as Augustas11. Never
   `gh pr merge --admin` unless the operator writes that permission **in the
   same turn**.
5. Treat red `spec-index / check` as a merge gate. Do not merge past it.
6. Clean-room: do **not** inspect `d-inference` / `Layr-Labs/*` source.

Audits: three lanes via `omc ask codex` (code-reviewer, security-reviewer,
architect). Do **not** use Cursor `Task` subagents and do **not** call
`codex` / `codex exec` directly. Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

This is **money-path**. One mis-attributed `cached_prompt_tokens` is a billing
defect, not a serving glitch.

---

## 2. Why this exists (read once)

On current `origin/main` after #1476:

- Increment 1 is real: measured-identity attach, `PagedKVSharedForwardBackend`.
  Production `ModelRuntime` still sets `pagedKVObservedRuntimeIdentity = nil`,
  hardware proof nil, `pagedKVSchedulerBackendInstalled = false` (see
  `ModelRuntime.swift` init ~line 1142). Buyer traffic stays fail-closed.
- Increment 2 is real: `PagedKVRuntimeBridge.materializeContiguousKVCache`,
  allocator `retain` / `reattach` / `trim` including mid-block
  `tailValidTokenCount`. Tests inject identity + a paged sequence.
- Conversation-keyed / sticky requests still **cannot** enter a batch:

  Policy (`ContinuousBatching.swift` `makeCapability`): any
  `stickyCacheEligible` (`conversationKey != nil`) sets
  `stickyCacheBridgeUnavailable` **before** local-capability checks.

  Scheduler (`ContinuousBatchScheduler.submit` ~716): any non-empty
  `conversationKey` **or** `cachedPromptTokens > 0` throws
  `keyed_or_sticky_cache_reuse_deferred_until_paged_kv_cache_bridge` and records
  `.stickyCacheUnsupported`.

  Tests that encode that deferral (must be **replaced**, not deleted without a
  successor):
  - `ServingKnobsConfigTests.testStickyCacheEligibleRequestSerialRoutesUntilBridgeExists`
  - `ServingKnobsConfigTests.testStrictOnRejectsStickyRequestWithoutCacheBridge`
  - `ContinuousBatchSchedulerTests.testHeadUpdateStickyCacheRequestNeverEntersBatch`
  - `ContinuousBatchSchedulerTests.testConversationKeyNeverEntersBatchBeforePagedKVCacheBridge`
  - `PagedKVRuntimeBridgeTests.testStickyRequestsRemainRejectedBeforeFRPKV10CacheBridge`

#889/#894 bundled attach + extraction + implied serving and failed audit.
Increments 1 and 2 already landed the honest split. **Do not cherry-pick those
drafts.** Restart from current `origin/main`.

---

## 3. In scope

Consume Increment 1+2 and the frozen engine. Do not redefine storage layout,
block size, kernel semantics, allocator internals, descriptor schema, or the
measured-identity attach gate.

1. **Lift the blanket keyed/sticky reject** once FR-PKV10 is the handoff the
   scheduler actually uses for that request.
   - A keyed request with **no** reusable cache may enter the batch as fresh
     (`cachedPromptTokens = 0`). It must not keep
     `stickyCacheBridgeUnavailable` solely because a conversation key is
     present.
   - A keyed request **with** reusable same-conversation state must retain /
     reattach (preferred) or extract via FR-PKV10, apply SPEC-024 token-granular
     LCP/trim including a **mid-block** boundary, and continue decode in the
     shared `[B,1]` forward.
   - Cross-conversation reattach MUST still fail (`conversationMismatch` or
     equivalent). No sharing of one key's blocks with another.
2. **Serial `ConversationCache` lease/LCP for billing.** The batched path must
   obtain the same LCP / `cachedPromptTokens` the serial path would for that
   key+prompt (`ConversationCache.begin` / lease). That is serving accounting,
   not SPEC-024 cold-tier disk persist.
3. **AC-19 provider-report parity.** Batched usage fields for a given request
   must match the serial path:
   - positive sticky-hit: `cached_prompt_tokens` equals serial LCP (clamped to
     prompt length), and any local settlement inputs the binary already emits
     for serial sticky hits match.
   - miss / no reusable state: `cached_prompt_tokens = 0`.
   - mid-block trim: cached count is the token-granular LCP, not a whole-block
     round.
   - two concurrent distinct keys in one shared batch: each row's
     `cached_prompt_tokens` matches its own serial control; zero cross-key
     reuse or block-table exposure (FR-CB6).
   - invalid range: never emit `cached_prompt_tokens < 0` or
     `cached_prompt_tokens > prompt_tokens` (existing clamp in `ModelRuntime`
     must still hold on the batched path).
   - retry of an accepted request: no duplicate cached-token credit vs the
     serial retry of the same request (no second terminal usage for the same
     accepted work).
4. **Rewrite the deferral tests** so they prove the new contract. A test that
   still asserts `keyed_or_sticky_cache_reuse_deferred_until_paged_kv_cache_bridge`
   for a well-formed keyed request with the bridge available is a product bug
   in this PR. Keep a fail-closed test for keyed/sticky when the FR-PKV10
   handoff is **not** available (identity nil, backend missing, retain
   rejected).

## 4. Out of scope (hard)

- Enabling `continuous_batching: canary` or `on` for buyer traffic.
- Packaged `>32GB` enable-gate runs
  (`docs/runbooks/continuous-batching-enable-gate.md`). First enableable
  scope stays **keyless** until a later operator gate, even after this merge.
- Wiring SPEC-024 cold-tier to persist/promote paged blocks in production
  (`KVDiskTier` / `KVConversationColdTierAdapter` write path). Do **not**
  change cold-tier disk format. Existing `KVConversationColdTierTests` must
  still pass.
- Redo Increment 1 attach / Increment 2 extraction primitive.
- Porting coordinator `ambiguous_cache` / `invalid_cached_prompt_tokens`
  quarantine into Swift. Those are SPEC-024/SPEC-005 **coordinator**
  eligibility decisions on the provider's report. This PR's job is to make
  the **report** match serial. Do not edit `phase4-coordinator/` or
  `phase5-gateway/` unless a test fixture there is the only honest way to
  prove settlement arithmetic — prefer proving provider-reported fields in
  Swift. If you must touch coordinator tests, do not change hot-path
  quarantine rules.
- Salvaging #889 / #894.
- Buyer API, receipt tuple, pricing, routing, or schema changes.
- Inspecting `d-inference`.

**Production observation:** this merge MUST NOT construct a real runtime
observation in the production serve path. Nil observation still fails closed.
Tests may inject identity + FR-PKV10 state. Green CI is not enablement.

---

## 5. Controlling contracts and live seams

Read before coding:

| Surface | Path |
|---|---|
| SPEC-038 FR-CB4 / FR-CB6 / AC-19 | `specs/SPEC-038-continuous-batching.md` |
| SPEC-024 LCP/trim + report vs eligibility | `specs/SPEC-024-prefix-cache-billing.md` (provider reports actual reuse; coordinator owns `ambiguous_cache`) |
| FR-PKV10 primitive (consume, do not reimplement) | `phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift` (`materializeContiguousKVCache`, retain/reattach) |
| Allocator retain/trim | `phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift` |
| Sticky policy gate | `phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift` |
| Scheduler keyed reject | `phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift` (`submit` ~716) |
| Serial lease/LCP | `phase3-binary/Sources/macprovider-cli/ConversationCache.swift` |
| Production nil observation | `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (init still assigns identity/proof/backend-installed false) |
| Deferral tests to replace | `ServingKnobsConfigTests.swift`, `ContinuousBatchSchedulerTests.swift`, `PagedKVRuntimeBridgeTests.swift` |
| Increment 2 tests (must still pass) | `PagedKVEngineTests.swift`, `PagedKVRuntimeBridgeTests.swift` |
| Cold-tier tests (do not break) | `KVConversationColdTierTests.swift` |

Honest governance:

- specs: `SPEC-038` (cite `SPEC-039` / `SPEC-024` only if you change their
  text; consuming FR-PKV10 and LCP/trim does not require those edits)
- requirements: `SPEC-038-R004` (primary, FR-CB4 extract/retain under the
  scheduler) and `SPEC-038-R006` (FR-CB6 / AC-19 isolation + usage fields).
  Do **not** list Increment 1/2 requirement IDs unless this diff actually
  changes those paths.
- authority domain: `continuous-batching-serving`
- `behavior_change: "yes"`
- `contract_change: "none"` unless you edit `specs/SPEC-*.md`,
  `specs/AUTHORITY.json`, or `specs/CONFORMANCE.json`
- If you map R004/R006 implementation/tests in `CONFORMANCE.json`, that is a
  contract_change. Pending until evidence exists is fine; do not claim
  production journeys. You may retarget `gap.issue` on those two rows from
  #614 to #1477. Do not mass-edit every SPEC-038 row.
- `arbitration`: `CODE_BUG` unless a SPEC text change forces otherwise

Validate the PR declaration locally before `gh pr create`
(`python3 scripts/check_spec_pr_declaration.py`).

If this PR updates the enable runbook, keep the **first enableable scope
keyless**. Point sticky/cross-turn serving at #1477 as landed-but-inert
code, not as permission to canary keyed traffic.

---

## 6. Load-bearing correctness (money-path)

**AC-19 / FR-CB6 / FR-CB4.**

- Batched sticky-hit `cached_prompt_tokens` == serial sticky-hit for the same
  key, prompt, model, and KV bits.
- Two keys in one batch: no cross-key `cached_prompt_tokens`, tokens, stop
  state, sampler state, or block-table exposure.
- Mid-block LCP does not round to a whole block; a shortfall is a miss.
- Cross-conversation reattach is rejected.
- Production nil observation still cannot attach or batch.
- When FR-PKV10 handoff is unavailable, keyed/sticky still serial-routes
  (canary) or fails closed (strict `on`) with a reason-coded telemetry
  string. Do not silently ignore the key.

Do **not** claim canary enablement, FR-CB15 hardware proof, or SPEC-024
cold-tier production persist in the PR body.

Do **not** weaken Increment 1: advertised-as-observed identity still fails;
production nil observation still inert.

---

## 7. Tests (minimum)

Deterministic and offline-runnable where possible. Against the real engine
interface or a SPEC-039-compatible fake — never a redefinition of engine
internals.

- Keyed request with no reusable state enters the batch; `cachedPromptTokens`
  is 0; decode proceeds.
- Positive sticky-hit: batched `cachedPromptTokens` equals serial LCP.
- Mid-block LCP/trim on the batched retain/reattach path.
- Two distinct keys in one shared decode batch: per-row usage matches each
  serial control; zero cross-key reuse.
- Cross-conversation reattach fails; no blocks from A appear on B.
- Invalid cached range cannot be emitted (`cached > prompt` / negative).
- Retry of accepted work does not emit a second cached-token credit.
- FR-PKV10 unavailable → keyed/sticky still rejected or serial-routed
  (keep a successor to today's deferral tests).
- Increment 1 attach tests still pass. Increment 2 extract/retain tests
  still pass. Production-shaped nil observation still does not attach.
- `KVConversationColdTierTests` still pass.

Suggested filters:

```bash
cd phase3-binary
swift test --filter ContinuousBatchSchedulerTests
swift test --filter ServingKnobsConfigTests
swift test --filter PagedKVRuntimeBridgeTests
swift test --filter PagedKVEngineTests
swift test --filter ConversationCacheTests
swift test --filter KVConversationColdTierTests
```

Add a dedicated filter for the new AC-19 / sticky-consumer tests and name it
in the PR body. Local hosts may skip MLX-metallib-backed cases; CI
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

- Can a conversation-keyed request enter a batch without FR-PKV10 actually
  being used for that request's cache state?
- Can key A receive key B's `cached_prompt_tokens` or blocks in one shared
  forward?
- Does mid-block trim round to a whole block on the batched path?
- Does production serve still fail closed with nil observation?
- Did this PR enable `canary`/`on` or construct a production observation?
- Did this PR persist paged blocks through SPEC-024 cold-tier?
- Do leftover tests still assert the old `keyed_or_sticky_cache_reuse_deferred_*`
  reject against a now-supported request?

Iterate until 0 C / 0 H / 0 M. Re-audit the fix delta each round. Carry
LOW/INFO in the PR body with rationale.

Do not edit the worktree while an `omc ask codex` lane is running (it can
silently revert).

---

## 9. PR and merge

Ship when tests pass and audits are at bar. Do not wait for "OK to PR?"

- Branch already created in §1.
- PR title: `SPEC-038 Increment 3: FR-CB4 sticky/cross-turn batching + AC-19 (#1477)`
- Body: exactly one `SPEC-GOVERNANCE-DECLARATION` block; `Closes #1477`;
  state inert/default-off; state canary enable and SPEC-024 cold-tier
  production persist are out of scope; record audit artifact paths.
- Merge gate: green **`ci-required`** and green **`spec-index / check`**, plus
  antfleet-ops approval, then squash-merge as Augustas11
  (`gh pr merge <n> --squash --delete-branch`). No `--admin`.
- After merge: sync canonical `main` to `origin/main`. Production
  observation / durable replay is now
  [#1500](https://github.com/Augustas11/macprovider/issues/1500), not a
  continuation of this prompt. Do **not** start canary enable from this
  session.

Provider safety if you touch the live Mac: no broad `pkill`; narrow `pgrep`;
bootout `live.malibu.provider-watchdog` then the provider via graceful
`launchctl bootout`, off-peak; restore and verify serving. Never print the
buyer token.

---

## 10. Done when

- Keyed/sticky requests can enter the scheduler when FR-PKV10 + injected
  identity are present.
- AC-19 provider-report parity tests pass (sticky-hit, miss, mid-block,
  two-key isolation, invalid range, retry).
- Blanket `stickyCacheBridgeUnavailable` / deferred-until-bridge reject is
  gone for supported keyed requests; fail-closed remains when the handoff is
  missing.
- Production observation stays nil → inert. No canary/`on`.
- Cold-tier disk persist unchanged.
- Offline tests green; CI swift tests green; three-lane audit 0 C/H/M.
- PR merged. #1477 closable.

Enable proof on a packaged `>32GB` install is **not** this session.
SPEC-024 production cold-tier consumption is **not** this session.
