# BUILD: SPEC-038 Increment 4 — production measured observation + durable replay (#1500)

You are starting a **new** MacProvider implementation session. You have no
memory of prior chats. Read this file end-to-end before writing code. Then
execute it. Do not re-triage, do not park, do not ask whether to implement.

**Tracker:** https://github.com/Augustas11/macprovider/issues/1500  
**Predecessors (already merged, do not redo):**
- Increment 1 #1474 / #1475 (`c6a091d9`) — observed-identity attach + shared `[B,1]`
- Increment 2 #887 / #1476 (`44df935c`) — FR-PKV10 contiguous `KVCache` extraction
- Increment 3 #1477 / #1489 (`84ef22e7`) — sticky/AC-19 consumer (injected capability)
**Closed stale drafts (do not revive):** #889, #894

---

## 0. Mission (one sentence)

Construct a **live `.runtimeMeasurement` identity and hardware-sizing proof** at
production model load, install the already-landed scheduler backend only on a
complete match, and replace the always-claim replay stub with durable
request-identity claims — still **default-off**, still **keyless-first**.

This is the missing production half of Increment 1. It is not canary enablement
and not keyed rollout.

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
git worktree add ../macprovider-1500-inc4-observation -b feat/1500-spec038-inc4-observation origin/main
cd ../macprovider-1500-inc4-observation
```

Confirm `origin/main` contains Increment 3 (`84ef22e7` or later
"Let retained paged KV prove sticky billing parity"). If it does not, STOP
and rebase onto current `origin/main`.

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

This is **money-path**. A self-asserted identity that opens attach, or an
always-claim replay authority that re-executes settled work, is a billing
defect.

---

## 2. Why this exists (read once)

On current `origin/main` after #1489:

- Increments 1–3 are real under **injected** identity. Production
  `ModelRuntime` init still sets (`~line 1144`):
  `pagedKVObservedRuntimeIdentity = nil`,
  `pagedKVHardwareSizingProof = nil`,
  `pagedKVSchedulerBackendInstalled = false`,
  `continuousBatchScheduler = nil`,
  `continuousBatchingDurableReplayAuthorityAvailable = false`.
- `pagedKVRuntimeBridgeGates` returns `.runtimeClosed` unless a complete
  `.runtimeMeasurement` identity **and** a hardware-sizing proof are present
  (`ModelRuntime.swift` ~916).
- `ContinuousBatchRuntimeReplayAuthority.claim` always returns `.claimed`
  (`ModelRuntime.swift` ~354). The enable runbook already says that stub is
  **not** activation evidence.
- Policy still sets `conversationKeyRolloutUnavailable` for any conversation
  key (`ContinuousBatching.swift` ~206). Leave that gate in place.
- `continuous_batching` remains default-off. Do not flip canary/`on`.

#889/#894 failed by manufacturing identity from the advertised descriptor.
**Do not repeat that.** Restart from current `origin/main`. Do not cherry-pick
those drafts.

---

## 3. In scope

Consume Increments 1–3. Do not redefine storage layout, block size, kernel
semantics, allocator internals, descriptor schema, FR-PKV10, or AC-19 serving.

1. **Live observation at model load.** After the model artifact is loaded and
   its SHA is known, measure:
   - hardware class (the real host class used by Entry 110 / capacity, not a
     test placeholder and not a string copied from a descriptor)
   - SHA-256 of the packaged `default.metallib` that
     `PagedKVMetallibGate` actually finds
   - kernel identifier of the gather kernel that is **registered**, not only
     the `PagedKVGatherKernel.registeredKernelName` constant
   - parity label only if parity is established for that metallib/kernel
   - live pool epoch
   - `moeDispatchProven` (remain `false` unless AC-23 evidence already exists
     on this host; do not invent true)
   Pack these into `PagedKVObservedRuntimeIdentity` with
   `source: .runtimeMeasurement`. If any required field is empty, metallib
   missing (typical worktree/`swift build` without packaged metallib), or
   measurement fails: leave observation **nil** and stay closed.

2. **Hardware-sizing proof from the same measurement.** Construct
   `PagedKVHardwareSizingProof` from the measured tuple plus the live
   `PagedKVConfig` sizing. `covers()` must fail if observation and proof
   diverge. Do **not** satisfy `covers()` by writing the advertised
   descriptor into both structs.

3. **Install backend only on attach.** Set
   `pagedKVSchedulerBackendInstalled` and construct
   `continuousBatchScheduler` only when `PagedKVAttachDecision.attached`
   holds for that measured identity. Otherwise keep both false/nil exactly
   as today.

4. **Durable replay authority.** Replace
   `ContinuousBatchRuntimeReplayAuthority`'s always-`.claimed` stub with an
   implementation that:
   - keys claims on `ContinuousBatchSchedulerReplayKey` (request id +
     fingerprint SHA-256)
   - maps **stable relay/HTTP request identity** into that key (not a
     per-retry random id)
   - returns `.claimed` once, `.duplicateSameRequest` on the same
     fingerprint, `.duplicateMismatchedRequest` on a colliding id with a
     different fingerprint
   - remembers claims for at least the settlement replay horizon; the
     scheduler's bounded terminal-result cache is **not** this authority
   - sets `continuousBatchingDurableReplayAuthorityAvailable = true` only
     when that implementation is wired in production
   Process-local durable memory is acceptable if it outlives the scheduler
   result cache and is lost only on process exit. Do not change coordinator
   or gateway schemas. Do not treat the current always-claim stub as
   "available."

5. **Keep fail-closed paths:** missing metallib, incomplete identity,
   advertised-as-observed, `selfAsserted`, tuple mismatch, MoE without
   AC-23, keyed requests (`conversationKeyRolloutUnavailable`),
   `continuous_batching: off`.

## 4. Out of scope (hard)

- Enabling `continuous_batching: canary` or `on` for buyer traffic.
- Packaged `>32GB` enable-gate runs. This merge makes the runbook *able to
  run later*; it is not the run. First enableable scope stays **keyless**.
- Lifting `conversationKeyRolloutUnavailable`.
- SPEC-024 cold-tier production persist.
- Redo Increments 1–3 (attach protocol, FR-PKV10, AC-19 tests).
- Setting `moeDispatchProven = true` without AC-23 / live MSB-04.
- Salvaging #889 / #894.
- Buyer API, receipt tuple, pricing, routing, coordinator/gateway schema
  changes.
- Inspecting `d-inference`.

Green CI is not enablement (Entry-199 / SPEC-037 lesson).

---

## 5. Controlling contracts and live seams

Read before coding:

| Surface | Path |
|---|---|
| SPEC-038 FR-CB8 / FR-CB10 / FR-CB13 / FR-CB15 | `specs/SPEC-038-continuous-batching.md` (FR-CB15 is the later operator run, not this PR) |
| SPEC-039 attach / identity | `specs/SPEC-039-paged-kv-attention-engine.md` (FR-PKV6/7/9/11/12) |
| Identity + sizing proof + attach | `phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift` (`PagedKVObservedRuntimeIdentity`, `PagedKVHardwareSizingProof`, `PagedKVAttachGate`, `PagedKVMetallibGate`) |
| Production nil observation | `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (init ~1144, `pagedKVRuntimeBridgeGates` ~916, `ContinuousBatchRuntimeReplayAuthority` ~354) |
| Gather kernel | `phase3-binary/Sources/macprovider-cli/PagedKVCache.swift` (`PagedKVGatherKernel`) |
| Policy / keyed rollout | `phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift` (`conversationKeyRolloutUnavailable`) |
| Replay protocol | `phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift` (`ContinuousBatchSchedulerReplayAuthority`, claim at ~1203) |
| Enable runbook (update status only) | `docs/runbooks/continuous-batching-enable-gate.md` |
| Existing tests | `ServingKnobsConfigTests.swift`, `PagedKVRuntimeBridgeTests.swift`, `PagedKVEngineTests.swift`, `ContinuousBatchSchedulerTests.swift` |

Honest governance:

- specs: `SPEC-038`, `SPEC-039`
- requirements: `SPEC-038-R010` (primary, local capability activation) and
  `SPEC-039-R006` / `SPEC-039-R011` if this diff actually constructs
  observed identity and descriptor membership. Cite `SPEC-038-R013` only if
  you change replay/idempotency. Do not dump Increment 2/3 IDs unless those
  paths change.
- authority domain: `continuous-batching-serving` (and `paged-kv-attention`
  only if you change SPEC-039-owned attach/identity code)
- `behavior_change: "yes"`
- `contract_change: "none"` unless you edit `specs/SPEC-*.md`,
  `specs/AUTHORITY.json`, or `specs/CONFORMANCE.json`
- If you map R010 implementation/tests in `CONFORMANCE.json`, that is a
  contract_change. Pending until evidence exists is fine; do not claim
  production journeys. You may retarget `gap.issue` on the rows you
  actually fill from #614 to #1500. Do not mass-edit every SPEC-038 row.
- `arbitration`: `CODE_BUG` unless a SPEC text change forces otherwise

Validate the PR declaration locally before `gh pr create`
(`python3 scripts/check_spec_pr_declaration.py`).

If this PR updates the enable runbook, keep the **first enableable scope
keyless**. Record Increment 4 as landed-but-not-enablement. The in-process
always-claim stub must no longer be described as the production authority
once you replace it.

---

## 6. Load-bearing correctness (money-path)

- Incomplete measurement, missing `default.metallib`, or empty hardware
  class → observation stays nil → attach closed → no scheduler backend.
- `source != .runtimeMeasurement` cannot attach.
- Copying advertised `metallibSHA256` / kernel / parity / hardware class
  into observed fields must fail attach tests.
- Proof and observation must be independently populated from measurement;
  a single copied tuple into both is the #889 defect.
- Always-claim replay must not remain the production authority.
- Same request id + same fingerprint → `.duplicateSameRequest` (no second
  settlement-eligible execution).
- Same request id + different fingerprint → `.duplicateMismatchedRequest`.
- `continuous_batching: off` still serves serial. Flag default stays off.
- Conversation-keyed requests still get `conversationKeyRolloutUnavailable`.
- MoE tuples still fail closed without AC-23.

Do **not** claim FR-CB15 hardware proof, canary enablement, or keyed
rollout in the PR body.

---

## 7. Tests (minimum)

Deterministic and offline-runnable where possible.

- Production-shaped runtime (no injected identity) with missing metallib
  stays closed.
- Injected complete `.runtimeMeasurement` still attaches (Increment 1
  regression).
- Advertised-descriptor / `selfAsserted` identity does not attach.
- Partial identity (empty metallib SHA, poolEpoch 0, empty hardware class)
  does not attach.
- Measurement + proof mismatch fails `covers()` / attach.
- Replay: first claim succeeds; same key duplicates; mismatched
  fingerprint duplicates; authority unavailable is fail-closed.
- Keyed request still `conversationKeyRolloutUnavailable` on the
  production policy path.
- `continuous_batching: off` unchanged.
- Increment 1/2/3 filters still pass:
  `PagedKVEngineTests`, `PagedKVRuntimeBridgeTests`,
  `ContinuousBatchSchedulerTests`, `ServingKnobsConfigTests`,
  `ConversationCacheTests`, `KVConversationColdTierTests`.

Suggested filters:

```bash
cd phase3-binary
swift test --filter ServingKnobsConfigTests
swift test --filter PagedKVRuntimeBridgeTests
swift test --filter PagedKVEngineTests
swift test --filter ContinuousBatchSchedulerTests
```

Add a dedicated filter for the new observation/replay tests and name it in
the PR body. Local hosts may skip MLX-metallib-backed cases; CI
`phase3-binary (swift test)` is the metallib-capable gate — do not treat
local skips as a pass of those cases. A local skip because metallib is
absent is **correct production-closed behavior**, not a pass of the
measurement-success path.

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

- Did production copy the advertised descriptor into observed identity?
- Can attach succeed with `source` other than `.runtimeMeasurement`?
- Can attach succeed without a real `default.metallib` SHA?
- Is `hardwareSizingProof` a twin of the descriptor rather than a
  measurement?
- Does production still always-claim replay?
- Did this PR enable `canary`/`on` or lift keyed rollout?
- Did a worktree without metallib start serving batched?

Iterate until 0 C / 0 H / 0 M. Re-audit the fix delta each round. Carry
LOW/INFO in the PR body with rationale.

Do not edit the worktree while an `omc ask codex` lane is running (it can
silently revert).

---

## 9. PR and merge

Ship when tests pass and audits are at bar. Do not wait for "OK to PR?"

- Branch already created in §1.
- PR title: `SPEC-038 Increment 4: production measured observation + durable replay (#1500)`
- Body: exactly one `SPEC-GOVERNANCE-DECLARATION` block; `Closes #1500`;
  state default-off; state canary enable, keyed rollout, and SPEC-024
  cold-tier persist are out of scope; record audit artifact paths.
- Merge gate: green **`ci-required`** and green **`spec-index / check`**, plus
  antfleet-ops approval, then squash-merge as Augustas11
  (`gh pr merge <n> --squash --delete-branch`). No `--admin`.
- After merge: sync canonical `main` to `origin/main`. Do **not** start
  canary enable, keyed rollout, or a packaged `>32GB` enable run in the
  same session unless the operator names it.

Provider safety if you touch the live Mac: no broad `pkill`; narrow `pgrep`;
bootout `live.malibu.provider-watchdog` then the provider via graceful
`launchctl bootout`, off-peak; restore and verify serving. Never print the
buyer token.

---

## 10. Done when

- Production load can construct a complete `.runtimeMeasurement` identity
  when metallib/kernel/parity/hardware/epoch are actually present.
- Missing measurement stays nil → attach closed → no backend.
- Advertised-as-observed cannot attach.
- Durable replay rejects duplicate/mismatched claims; always-claim stub is
  gone from the production path.
- `continuous_batching` default remains off. Keyed rollout remains blocked.
- Offline tests green; CI swift tests green; three-lane audit 0 C/H/M.
- PR merged. #1500 closable.

Enable proof on a packaged `>32GB` install is **not** this session.
Widening keyed buyer traffic is **not** this session.
