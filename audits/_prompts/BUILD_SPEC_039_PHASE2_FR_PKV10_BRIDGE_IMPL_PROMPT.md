# BUILD: SPEC-039 Phase-2 — runtime bridge + FR-PKV10 contiguous-KVCache extraction (issue #887)

Author: operator (a11) + Claude session 2026-08-04
Status: IMPLEMENTATION HANDOFF. Tracked in **issue #887**. SPEC-039 engine (#814)
and SPEC-038 scheduler (#888) are both MERGED on `origin/main` and **hard-wired
inert**. This build implements the deferred runtime bridge that is *allowed* to
make them serve. It lands **default-off and inert**; the real activation is a
separate hardware enable proof (§7), NOT this merge.

## 0. Why this is the critical path (read first)

Two throughput features are on main but cannot do anything today:
- **SPEC-039 paged engine** (`phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift`)
  — real descriptor, block-table handle, allocator, and dense-parity gather, but
  `PagedKVDescriptor.engineBridgeAvailable` defaults **false** and
  `PagedKVAttachDecision` fails closed at runtime preflight
  (`guard gates.engineBridgeAvailable else { return fail(.kernel) }`). FR-PKV10
  ships only a neutral byte-materialization stub; the injectable contiguous
  `KVCache` is an **unimplemented protocol** (`PagedKVContiguousCacheBridge`).
- **SPEC-038 scheduler** (`ContinuousBatchScheduler.swift`,
  `ContinuousBatching.swift`) — full bounded actor scheduler, but
  `ModelRuntime.continuousBatchingCapability` hard-wires
  `requestedTuple: nil` and `schedulerBackendAvailable: false`, with a comment
  refusing to "manufacture a self-fulfilling tuple". So no request can ever reach
  a batch.

This build is the piece that is *allowed* to flip those to true — on a real
observed identity match, never speculatively. Nothing serves batched, reuses KV
cross-turn, or does SPEC-024 cold-tier residency until it exists.

## 1. Mission

Implement, over the merged SPEC-039 engine and against its existing frozen seams,
the **provider-local runtime bridge** that (a) attaches a live serving request to
the paged engine and drives a real shared-forward decode, and (b) materializes a
sequence's paged block-table into a standalone, injectable contiguous `KVCache`
(FR-PKV10). Do **not** redefine the engine's storage layout, block size, kernel
semantics, allocator internals, descriptor, or handle — consume them.

## 2. Scope — TWO increments, in this order. Do not bundle if increment 1 balloons.

### Increment 1 — request-level runtime attach + shared-forward drive (do FIRST)
This is the higher-leverage half: it unblocks SPEC-038 **fresh-conversation**
batching (the actual throughput win), which needs NO contiguous extraction.
- Build the real request-level attach path so `PagedKVAttachDecision.attached`
  can be produced from an **observed** runtime tuple (observed metallib SHA,
  kernel identifier, parity label, MoE-dispatch proof, pool epoch) that matches
  the committed/trusted descriptor — never a tuple manufactured from the
  advertised descriptor itself.
- Set `engineBridgeAvailable` / `schedulerBackendAvailable` true **only** when
  that observed identity match holds at runtime preflight; otherwise keep failing
  closed exactly as today.
- Provide the scheduler backend the shared `[B,1]` forward over active decode
  rows (the SPEC-038 scheduler already owns admission, block-table lifecycle, and
  per-request isolation — you provide the backend it calls).
- Wire `ModelRuntime.continuousBatchingCapability` to compute the **real**
  `requestedTuple` and pass `schedulerBackendAvailable: true` when (and only when)
  the bridge is genuinely attached for the request's hardware/model/cache/KV
  tuple. Preserve every existing fail-closed / serial-route path
  (`requestStateUnrepresented`, sticky-cache, draft mutual-exclusion, MoE
  promotion-evidence, tuple-not-advertised).

### Increment 2 — FR-PKV10 contiguous-KVCache extraction/injection (follow-on)
Enables cross-turn cache reuse under batching + SPEC-024 cold-tier residency.
- Implement `PagedKVContiguousCacheBridge.materializeContiguousByteCache` and its
  successor so a sequence's paged block-table becomes a **live, injectable
  contiguous `KVCache`**, and support retain-and-reattach of a sequence's own
  blocks across turns.
- This unblocks the deferred SPEC-038 follow-up (FR-CB4 cross-turn reuse under
  batching + AC-19 batched sticky-hit billing parity) and SPEC-024 cold-tier.
  Those consumers are OUT of scope here — just make the primitive real and prove
  the round-trip.

## 3. What you inherit (frozen — consume, never redefine)

On `origin/main`:
- `PagedKVDescriptor`, `PagedKVAttachDecision` (`.disabled/.attached/.fallback/.rejected`),
  `PagedKVBlockTableHandle`, `PagedKVBlockAllocator`, the gather kernel — all real.
- `PagedKVContiguousCacheBridge` (protocol, unimplemented) and
  `PagedKVMaterializedByteCache` (neutral byte stub) — your Increment 2 targets.
- `ContinuousBatchScheduler` + `ContinuousBatchingPolicy.capability(...)` — the
  scheduler + admission ladder; the bridge is the backend it drives, not a rewrite.
- `ModelRuntime.continuousBatchingCapability` (the hard-wired-false site) and
  `ModelRuntime.requestStateRepresentable` (the row-local-state gate) — extend the
  first, leave the second's contract intact.

## 4. Two load-bearing correctness gates (money-path)

1. **FR-CB6 exact greedy parity.** Batched output under the shared forward MUST be
   byte/token-identical to the serial path (as a lone row and as one row in a full
   batch); per-request `prompt_tokens` / `output_tokens` / `cached_prompt_tokens`
   / stop / terminal status computed exactly as serial; zero cross-request
   sampler/stop/logit/cache/block-table leakage. A single mis-attributed token is
   a billing and provider-earnings defect.
2. **SPEC-024 token-granular LCP/trim (Increment 2).** Contiguous extraction /
   retain-reattach MUST preserve exact SPEC-024 longest-common-prefix and trim
   semantics **including a mid-block boundary**.

## 5. Tests

- Unit/fixture coverage against the real engine interface (descriptor + handle),
  or a SPEC-039-compatible fake — never a redefinition of engine internals.
- Increment 1: attach succeeds only on identity match and fails closed otherwise;
  shared-forward batched greedy output == serial for lone-row and full-batch;
  `schedulerBackendAvailable` flips true only when genuinely attached.
- Increment 2: paged block-table -> contiguous `KVCache` -> re-inject round-trip
  preserving exact SPEC-024 LCP/trim incl. a mid-block boundary.
- Deterministic and offline-runnable where possible.

## 6. Audit loop (before PR is "done") — this is money-path, run a REAL independent audit

Recent lesson (SPEC-038 #888): a self-reported "3-lane 0/0/0, N/N passed" did
**not** survive an independent audit — it hid a real `ci-required` blocker plus
2 HIGH + 2 MEDIUM findings, and the first round of fixes was itself incomplete.
So:
1. Reconstruct the **full IMPL diff as it will land** (base = commit before this
   build's first commit -> working tree). Audit the whole change, never a slice.
2. Three Codex lanes (code / security / architect) via `omc ask codex`, prompts in
   `audits/<date>/`, backtick-safe (write prompt to file). Bar **0 CRITICAL / 0
   HIGH / 0 MEDIUM**; iterate until clean; re-audit the fix delta each round (a fix
   can introduce a fresh finding). Carry LOW/INFO with PR-body rationale.
3. Do not trust "already audited". Be adversarial about: can the bridge activate
   speculatively (without a real identity match)? Any batched-vs-serial divergence?
   Any cross-request state leak? Any FR-PKV10 round-trip that breaks mid-block LCP?

## 7. Enable gate — the true finish line, NOT CI (§ mirrors SPEC-038/037)

Merge lands the bridge **default-off and inert**. Green CI/unit proves the
interface; it does **NOT** prove activation (Entry-199 lesson: SPEC-037 shipped a
silent no-op on green CI). Before the flag serves real traffic on a given
hardware/model/quantization/KV/runtime tuple, run a **packaged release-candidate
install on a >32 GB Mac** proving, at minimum: real shared-forward batched serving,
per-request accounting correctness under the shared forward on real hardware,
no cross-request leak, no Metal command-buffer regression, peak RSS within bound,
and (Increment 2) a real cross-turn contiguous round-trip. `serve` self-re-execs
into the INSTALLED binary and a worktree `swift build` has no `mlx.metallib`, so
this proof cannot run from a dev-build worktree. **Do NOT flip
`schedulerBackendAvailable` / `engineBridgeAvailable` to serve production on green
CI.**

**Provider safety on the dev Mac:** it runs the LIVE production provider — never
broad `pkill`; use narrow `pgrep`; bootout the watchdog
(`live.streamvc.macprovider-watchdog`) then the provider via graceful
`launchctl bootout`, off-peak, and restore + verify serving after. Never print the
buyer token.

## 8. PR / merge protocol

- Fresh worktree off `origin/main`; never edit the canonical checkout; never edit
  the worktree while an `omc ask codex` audit lane is running (it silently reverts).
- Author as **Augustas11**; fill the governance declaration honestly (authority
  domain `paged-kv-attention`; cite SPEC-039 + FR-PKV10; `behavior_change: "yes"`;
  `contract_change: "yes"` only if you touch a canonical SPEC / AUTHORITY.json /
  CONFORMANCE.json — an impl-only change is `"none"`).
- Merge gate is green **`ci-required`** + 1 approval; `spec-index/check` is
  advisory. antfleet-ops approves -> `GH_TOKEN=$(gh auth token -u Augustas11) gh pr
  merge --squash --admin <n>`. After squash-merge: `git reset --hard origin/main`,
  delete the PR branch + worktree.
- Watch for the known scheduler timing flake
  (`ContinuousBatchSchedulerTests.testHangingTokenSinkHardTimeoutKeepsLiveTaskCapacityBounded`
  and the ReceiptPerf/XFF flakes): rerun the failed job rather than treating a
  one-off red as a regression, after confirming it passes locally.

## 9. Clean-room (still in force)

No `d-inference` / `Layr-Labs/*` source consultation in any session. Build only
from `ml-explore` upstream (MIT/Apache), the public `mlx-swift-lm` `KVCache` seam,
public `mlx-lm`, vLLM (Apache), and the PagedAttention paper. The wall is
knowledge-flow, not session boundaries.

## 10. Done when

Increment 1 lands: real request-level attach producing an observed-identity-matched
tuple, `schedulerBackendAvailable`/`engineBridgeAvailable` flip true only on match,
shared-forward batched greedy output == serial, all existing fail-closed/serial
paths intact, offline tests green — feature still default-off/inert, enable proof
deferred to a >32 GB Mac. Increment 2 (may be a second PR): FR-PKV10 contiguous
extraction/injection real with an exact SPEC-024 LCP/trim round-trip, handing a
clean primitive to the deferred SPEC-038 cross-turn-reuse follow-up and SPEC-024
cold-tier.
