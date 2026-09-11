# BUILD: SPEC-039 Phase-2 Increment 1 — observed-identity attach + shared-forward backend (#1474)

You are starting a **new** MacProvider implementation session. You have no
memory of prior chats. Read this file end-to-end before writing code. Then
execute it. Do not re-triage, do not park, do not ask whether to implement.

**Tracker:** https://github.com/Augustas11/macprovider/issues/1474  
**Follow-on Increment 2 (landed):** https://github.com/Augustas11/macprovider/issues/887  
**Follow-on Increment 3 (do not implement here):** https://github.com/Augustas11/macprovider/issues/1477  
**Closed stale drafts (do not revive):** #889, #894 (`fix/889-spec039p2` was deleted)

---

## 0. Mission (one sentence)

Implement the provider-local runtime bridge that may attach a live serve
request to the already-merged SPEC-039 paged engine and drive SPEC-038's
existing scheduler through a real shared `[B,1]` forward — **only** on an
observed-identity match against a trusted descriptor — and land that bridge
**default-off / runtime-inert**.

This unblocks SPEC-038 **fresh-conversation** batching. It does **not**
implement FR-PKV10.

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
git worktree add ../macprovider-1474-inc1-attach -b feat/1474-spec039-inc1-attach origin/main
cd ../macprovider-1474-inc1-attach
```

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

On current `origin/main`:

- SPEC-039 engine (#814) is real: descriptor, block-table handle, allocator,
  dense-parity gather. `PagedKVDescriptor.engineBridgeAvailable` defaults
  **false**. `PagedKVAttachDecision` fails closed at
  `guard gates.engineBridgeAvailable else { return fail(.kernel) }`.
- SPEC-038 scheduler (#888) is real: `ContinuousBatchScheduler` +
  `ContinuousBatchSchedulerBackend` (prefill / decode / cancelInFlight).
  `ModelRuntime.continuousBatchingCapability` still hard-wires
  `requestedTuple: nil` and `schedulerBackendAvailable: false` with a comment
  refusing to manufacture a self-fulfilling tuple. No request can enter a batch.
- `PagedKVCache` is a compile-time `KVCache` seam. `ModelRuntime` never
  injects it today.
- `PagedKVContiguousCacheBridge` is still an unimplemented protocol. That is
  **#887 / Increment 2**. Leave it unimplemented.

#889 failed an independent audit: self-asserted provenance, unproven FR-CB6
parity overclaim, attach-path lifecycle bugs (1 CRITICAL + several HIGH/MEDIUM).
#894 was a WIP revision of that cut, then went stale against ~400 commits of
`ModelRuntime` / `InferenceRelay` drift (opaque relay #1467, liveness token,
MLX cache gates, in-app model switching). **Restart from `origin/main`. Do
not cherry-pick #894.**

---

## 3. In scope

Consume the frozen engine. Do not redefine storage layout, block size, kernel
semantics, allocator internals, descriptor schema, or handle.

1. **Observed-identity attach.** Produce `PagedKVAttachDecision.attached`
   only when an **observed** runtime tuple matches a **trusted** descriptor:
   hardware class, metallib SHA, kernel identifier, parity label, MoE-dispatch
   proof, pool epoch. `admits()` must reject empty/partial identity on those
   fields. Never copy the advertised descriptor into the observed fields.
2. **Gate flips.** Set `engineBridgeAvailable` / `schedulerBackendAvailable`
   true **only** when that match holds at preflight. Otherwise fail closed
   exactly as today.
3. **Shared-forward backend.** Implement `ContinuousBatchSchedulerBackend`
   so the existing scheduler can drive one shared `[B,1]` forward over active
   decode rows. The scheduler already owns admission, block-table lifecycle,
   and per-request isolation — do not rewrite it.
4. **Wire capability.** `ModelRuntime.continuousBatchingCapability` must
   compute the real `requestedTuple` and pass `schedulerBackendAvailable: true`
   only when the bridge is genuinely attached for that request's
   hardware/model/cache/KV tuple.
5. **Keep every fail-closed / serial-route path:**
   `requestStateUnrepresented`, sticky-cache (`stickyCacheBridgeUnavailable`),
   draft mutual-exclusion, MoE promotion-evidence, tuple-not-advertised.
   Sticky / cross-turn requests stay serial until #887.

## 4. Out of scope (hard)

- FR-PKV10 / `PagedKVContiguousCacheBridge` / retain-reattach / mid-block LCP
  (#887).
- SPEC-024 cold-tier consuming extraction.
- SPEC-038 FR-CB4 cross-turn reuse and AC-19 batched sticky-hit billing.
- Enabling `continuous_batching: canary` or `on` for buyer traffic.
- Packaged `>32GB` enable-gate runs
  (`docs/runbooks/continuous-batching-enable-gate.md`). Merge stays inert;
  that runbook is a later operator step, not this PR.
- Salvaging #889 / #894.
- Buyer API, receipt tuple, pricing, routing, coordinator/gateway money-path
  changes.
- Inspecting `d-inference`.

**Production observation:** this merge MUST NOT construct a real runtime
observation in the production serve path. If observation is nil, attach fails
closed and both availability flags stay false. Tests may inject a fake
observed tuple. Green CI is not enablement (Entry-199 / SPEC-037 lesson).

---

## 5. Controlling contracts and live seams

Read before coding:

| Surface | Path |
|---|---|
| SPEC-039 | `specs/SPEC-039-paged-kv-attention-engine.md` (FR-PKV6/7/9/11/12; **not** FR-PKV10) |
| SPEC-038 | `specs/SPEC-038-continuous-batching.md` (FR-CB3 shared forward, FR-CB6 isolation, FR-CB8/10 activation, FR-CB16 boundary) |
| Enable gate (do not run as merge proof) | `docs/runbooks/continuous-batching-enable-gate.md` |
| Engine + gates + attach enum | `phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift` |
| Compile-time cache seam | `phase3-binary/Sources/macprovider-cli/PagedKVCache.swift` |
| Hard-wired-false capability | `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (`continuousBatchingCapability`, `pagedKVRuntimeCapabilityDecision` uses `.runtimeClosed`) |
| Admission ladder | `phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift` |
| Scheduler + backend protocol | `phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift` |
| Opaque relay (do not regress #1467) | `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift` |

Honest governance for an impl-only PR (do not cite SPEC-039-R010 — that is
Increment 2 / FR-PKV10):

- specs: `SPEC-039`, `SPEC-038`
- requirements actually exercised: `SPEC-039-R006`, `SPEC-039-R007`,
  `SPEC-039-R009`, `SPEC-039-R011`, `SPEC-039-R012`, `SPEC-038-R003`,
  `SPEC-038-R006`, `SPEC-038-R010`
- authority domain: `paged-kv-attention`
- `behavior_change: "yes"`
- `contract_change: "none"` unless you edit `specs/SPEC-*.md`,
  `specs/AUTHORITY.json`, or `specs/CONFORMANCE.json`
- `arbitration`: `CODE_BUG` unless a SPEC text change forces otherwise

Validate the PR declaration locally before `gh pr create`
(`python3 scripts/check_spec_pr_declaration.py`).

---

## 6. Load-bearing correctness (money-path)

**FR-CB6 exact greedy parity.** Under the shared forward, batched output MUST
be byte/token-identical to serial for a lone row and for one row in a full
batch. Per-request `prompt_tokens` / `output_tokens` / `cached_prompt_tokens`
/ stop / terminal status MUST match serial. Zero cross-request
sampler / stop / logit / cache / block-table leakage. One mis-attributed
token is a billing and provider-earnings defect.

Do **not** claim this in the PR body without tests that actually exercise it.

Other attach invariants:

- Observed identity is measured, never copied from the advertised descriptor.
- Allocator / block-table failure at preflight reason-codes and rolls back;
  no mid-stream paged→stock stitch (FR-PKV7).
- Fallback is pre-first-token only.
- `ModelRuntime.requestStateRepresentable` contract stays intact.

---

## 7. Tests (minimum)

Deterministic and offline-runnable where possible. Against the real engine
interface (descriptor + handle) or a SPEC-039-compatible fake — never a
redefinition of engine internals.

- Attach succeeds only on full observed-identity match; empty/partial
  identity fails closed.
- Self-asserted / advertised-as-observed tuples are rejected.
- `schedulerBackendAvailable` / `engineBridgeAvailable` are true only when
  genuinely attached; production-shaped nil observation stays inert.
- Shared-forward greedy output == serial (lone row and full batch), including
  usage and stop.
- Sticky-cache-eligible requests still serial-route
  (`stickyCacheBridgeUnavailable` or equivalent).
- Existing ServingKnobs / ContinuousBatching / PagedKVEngine tests stay green.

Suggested filters while iterating:

```bash
cd phase3-binary
swift test --filter PagedKVRuntimeBridgeTests
swift test --filter PagedKVEngineTests
swift test --filter ServingKnobsConfigTests
swift test --filter ContinuousBatchSchedulerTests
```

Known flake: `ContinuousBatchSchedulerTests.testHangingTokenSinkHardTimeoutKeepsLiveTaskCapacityBounded`.
Rerun that job after a local pass; do not treat a one-off CI flake as a
product regression.

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
Adversarial questions the auditors must be able to answer from the diff:

- Can the bridge activate without a real identity match?
- Can advertised descriptor fields masquerade as observed?
- Any batched-vs-serial token, stop, or usage divergence?
- Any cross-request state leak under the shared forward?
- Does production serve still fail closed with nil observation?

Iterate until 0 C / 0 H / 0 M. Re-audit the fix delta each round. Carry
LOW/INFO in the PR body with rationale.

Do not edit the worktree while an `omc ask codex` lane is running (it can
silently revert).

---

## 9. PR and merge

Ship when tests pass and audits are at bar. Do not wait for "OK to PR?"

- Branch already created in §1.
- PR title: `SPEC-039 Phase-2 Increment 1: observed-identity attach + shared-forward (#1474)`
- Body: exactly one `SPEC-GOVERNANCE-DECLARATION` block; link #1474; state
  inert/default-off; state Increment 2 / #887 is out of scope; record audit
  artifact paths.
- Merge gate: green **`ci-required`** and green **`spec-index / check`**, plus
  antfleet-ops approval, then squash-merge as Augustas11
  (`gh pr merge <n> --squash --delete-branch`). No `--admin`.
- After merge: sync canonical `main` to `origin/main`. Do **not** start #887
  in the same session unless the operator names it.

Provider safety if you touch the live Mac: no broad `pkill`; narrow `pgrep`;
bootout `live.malibu.provider-watchdog` then the provider via graceful
`launchctl bootout`, off-peak; restore and verify serving. Never print the
buyer token.

---

## 10. Done when

- Observed-identity attach exists and cannot self-assert.
- `schedulerBackendAvailable` / `engineBridgeAvailable` flip true only on
  match.
- Shared-forward greedy == serial (lone row + full batch) with matching
  usage/stop.
- Sticky/cross-turn still serial-routed.
- Production observation stays nil → inert.
- Offline tests green; three-lane audit 0 C/H/M.
- PR merged. #1474 closable. #887 still open.

Enable proof on a packaged `>32GB` install is **not** this session.
