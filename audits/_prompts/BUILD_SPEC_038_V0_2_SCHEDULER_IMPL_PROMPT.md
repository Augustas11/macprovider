# BUILD: SPEC-038 v0.2 continuous-batching scheduler — IMPL (absorbs PR #804 scaffold)

Author: operator (a11) + Claude session 2026-07-29
Status: IMPLEMENTATION HANDOFF — SPEC-038 v0.2 is LOCKED on `origin/main`
(landed with SPEC-039 at `61369ec6`). This is the **second** of two IMPL builds.
It **depends on the SPEC-039 paged-engine IMPL**, which **MERGED 2026-08-03 at
`69c32bbb` (PR #814)**. Of the three consumed surfaces, **two are real**
(capability descriptor FR-PKV11, block-table handle FR-PKV2) and **one is
deferred** (FR-PKV10 standalone contiguous-`KVCache` extraction — only a neutral
byte-materialization stub exists; see §0). Build now against the two real
surfaces; the FR-PKV10-dependent cache-reuse path is **scoped out of this first
cut** per §0.

## 0. HEAD-UPDATE 2026-08-03 — READ BEFORE §2 (FR-PKV10 gap + scope)

The SPEC-039 engine PR (#814, `69c32bbb`) landed as a **foundation + proven
dense-parity core**, default-off/inert. Two of the three surfaces this scheduler
consumes are real and stable public API:
- **FR-PKV11 capability descriptor** (`PagedKVDescriptor`) — real; drive the
  activation predicate against it as §3.1 describes.
- **FR-PKV2 block-table handle** (`PagedKVBlockTableHandle` + allocate/bind/
  extend/release, backed by `PagedKVBlockAllocator`) — real.

But **FR-PKV10 is NOT complete.** The merged engine ships only a *neutral
byte-materialization* primitive (`PagedKVMaterializedByteCache`); the standalone,
live, injectable contiguous-`KVCache` handoff that this scheduler's cross-turn
reuse consumes is an **unimplemented protocol** (`PagedKVContiguousCacheBridge`),
explicitly deferred to the SPEC-039 runtime bridge. Tracked in **issue #887**.

**Consequence — scope this first IMPL cut down, do not fake the missing surface:**
- **Batch fresh-conversation decode only** (the real throughput win). Implement
  FR-CB1..CB3, CB5..CB9, CB11..CB14, CB16 (minus cross-turn reuse), CB17 as written.
- **Serial-route any sticky-cache-eligible / cross-turn request** (the existing
  `AsyncSemaphore` path) with a reason-coded `batching_unsupported` telemetry
  string until #887 lands — the same fail-honest pattern §4.8 uses for unsupported
  tuples. No batched cross-turn cache reuse until FR-PKV10 is real.
- **Defer FR-CB4 cross-turn-reuse-under-batching and AC-19 batched sticky-hit
  billing parity** to a SPEC-038 follow-up gated on #887. Keep AC-19's
  *fresh-conversation / non-sticky* cases (no discount, ambiguous, retry,
  invalid-range quarantine) — those don't need FR-PKV10.
- Tests for the real surfaces MAY use the SPEC-039-compatible fake (§3, §4.4)
  exactly as this prompt already allows.

Everything below is unchanged EXCEPT where §3 surface #3 and §7 are annotated for
this gap. The feature still lands **default-off and inert**; the real enable gate
(§7) is unchanged and still requires the SPEC-039 runtime bridge + a >32 GB-Mac
serve proof.

## 1. Mission

Implement the provider's **continuous-batching scheduler and serving layer**
defined by `specs/SPEC-038-continuous-batching.md` (requirements
`SPEC-038-R001..R017`, acceptance `AC-1..AC-24`). Move the shared-model decode
step from today's **parallel single-stream decode** (each admitted request runs
an independent `TokenIterator` under an `AsyncSemaphore` permit) to **continuous
batching**: active decode rows share one model forward and join/leave the batch
dynamically between decode steps, over the SPEC-039 paged engine.

This is a **money-path** change. Under one shared forward, per-request token
usage, stop conditions, cancellation, and each request's receipt are no longer
isolated by separate iterators. **Per-request accounting correctness (FR-CB6) is
the load-bearing invariant.** A single mis-attributed token is a billing and
provider-earnings defect, not a serving glitch.

Frame it exactly as SPEC §1: throughput is the **secondary axis, built ahead of
the multi-slot (Ultra) demand it serves** on the SPEC-039 servability flywheel —
not behind current demand. Today's mostly-1-slot fleet is **not** an argument
against building it (that is the addendum's rejected melting-ice-cream
circularity). The feature is **disabled by default** and enables nothing on
merge.

## 2. Starting point — absorb, don't rebuild: PR #804's scaffold

PR #804 (closed, superseded) left a working scaffold on branch
**`feature/232-continuous-batching` (`9733e54d`)**. Its **surviving half is your
base**: the three-state flag (`off`/`canary`/`on`), the serial-fallback-identical
path, the guards, the telemetry field scaffolding, the MSB "no unmeasured
throughput number" helper, and the per-request usage/receipt isolation skeleton.

Its **dead half must be rewired**: the v0.1 **FR-CB10 upstream-pin activation
gate** — "a reviewed `mlx-swift-lm` batch revision exists" — is falsified and
removed from the SPEC. Replace it with the **locally-owned activation capability**
(§4.2): the activation predicate is `requested tuple ∈ the SPEC-039 engine's
capability descriptor` (FR-PKV11). No code path or error text may cite a missing
upstream pin as the path to success (AC-22).

Start the IMPL by branching a fresh worktree from **`feature/232-continuous-batching`**
(not `main`), rebased onto current `origin/main` so it carries the landed
SPEC-039 engine:
```bash
git fetch origin
git worktree add ../macprovider-spec038-impl -b impl/232-continuous-batching-v0_2 origin/feature/232-continuous-batching
cd ../macprovider-spec038-impl
git rebase origin/main   # pick up the merged SPEC-039 engine
```

## 3. What you inherit from SPEC-039 (frozen public API — consume, never redefine)

The engine owns paged KV storage, physical-block allocation, and paged-attention
execution. **The scheduler MUST NOT redefine storage layout, block size, kernel
semantics, or allocator internals** (FR-CB16). You consume exactly three surfaces:

1. **Capability descriptor** (SPEC-039 FR-PKV11) — block size, supported model
   families, allowed cache classes, KV dtype, MoE-dispatch support. Your
   activation predicate is `requested tuple ∈ descriptor`. **No separately
   self-declared support matrix** that could drift (FR-CB8, FR-CB10).
2. **Engine-issued block-table handle** (SPEC-039 FR-PKV2) — the verb "allocate"
   is the engine's; you drive **request-allocation / bind / extend /
   release-completed / detach / release** through the handle at scheduler
   lifecycle boundaries (FR-CB4).
3. **Cache-extraction / same-conversation retention primitive** (SPEC-039
   FR-PKV10) — materialize a sequence's block table into a standalone contiguous
   `KVCache`, or retain-and-reattach its own blocks across turns, preserving
   **exact SPEC-024 token-granular LCP/trim including a mid-block boundary**
   (FR-CB4). This is how you keep cross-turn cache reuse eligible under batching.
   **⚠ NOT YET REAL (2026-08-03, §0): deferred in merged #814 — only neutral
   byte-materialization exists; the injectable contiguous-`KVCache` bridge is
   unimplemented (`PagedKVContiguousCacheBridge`), tracked in #887.** Do NOT
   consume or fake this surface in the first cut — serial-route cross-turn/sticky
   requests per §0 and defer FR-CB4/AC-19 until #887 lands.

## 4. Concrete task list

### 4.1 Scheduler core — actor-isolated, decode-first (FR-CB1..CB3, CB7 → AC-4,15,16,18)
- [ ] Single-owner Swift actor (or equivalent single-owner domain) owns ALL
      mutable batch state: waiting queue, prompt-processing set, active decode
      batch, per-row lifecycle, request block tables, cache handles, admission
      reservations, terminal bookkeeping (FR-CB7). Supported batched rows and
      unsupported serial iterators MUST NOT run against the same resident model
      concurrently without a thread-safety proof.
- [ ] **FCFS admission**, bounded waiting queue (benchmark default `2 x
      slots_total`), explicit client-visible backpressure at the bound before
      unbounded prompt/relay-state accumulation. Relay and local-HTTP share ONE
      admission policy and ONE capacity accounting — not two independent queues.
- [ ] **Admission gated by paged-block-pool availability, not slot count alone**
      (FR-CB1/FR-CB17): admit only if the engine can reserve the row's **initial
      footprint = prompt + configured decode headroom** (NOT the full generation
      ceiling — reserving the ceiling per row collapses concurrency toward depth 1).
- [ ] **Separate prompt (prefill) and decode phases; decode-first** (FR-CB2). No
      heterogeneous prefill+decode in one model call. Prefill bounded/chunked so a
      long prompt can't block decode rows unboundedly. A request joins decode only
      after prefill completes and its block table is initialized over engine blocks.
- [ ] **One shared `[B,1]` forward** for all active decode rows per step (FR-CB3),
      not `B` independent calls. Merely running concurrent iterators is the serial
      path and MUST NOT be reported as batching in telemetry.

### 4.2 Locally-owned activation capability (FR-CB10 → AC-22) — replaces #804's dead gate
- [ ] Remove the upstream-pin/revision/calendar-fallback gate entirely.
- [ ] `on`/`canary` activates only when a locally-owned batching capability exists
      for the requested hardware/model/cache/KV/runtime tuple = this scheduler +
      the SPEC-039 engine, where support = **membership of the tuple in the
      engine-advertised descriptor** (FR-PKV11) plus acceptance coverage.
- [ ] Strict `on` **fails closed** with an observable reason naming the missing
      **local** capability until it exists; permissive/canary MAY serial-route only
      with explicit operator policy + reason-coded telemetry. No path or error text
      cites a missing upstream pin (static-review obligation, AC-22).

### 4.3 Per-request isolation under the shared forward (FR-CB6 → AC-1,2,6,19) — the load-bearing part
- [ ] Per request under one shared forward, guarantee: exactly one terminal
      result; no token attributed to the wrong request; no cross-request sampler /
      stop-sequence / logit-processor state; no cross-request cache/block-table
      exposure; per-request `prompt_tokens` / `output_tokens` /
      `cached_prompt_tokens` / terminal status computed **exactly** as serial.
- [ ] Receipt per request preserves the **LOCKED SPEC-015** per-request field set
      and computation, **no batch identifier** in receipt identity. Batch metadata
      (row index, depth, fill, cohort) lives only in non-receipt diagnostics.
- [ ] Temperature-0 output under batching MUST match serial-path output (byte/
      token-identical under greedy) both as a lone row and as one row in a full
      batch.
- [ ] **Batched cache-billing parity** (SPEC-024/005, AC-19): sticky-hit reuse
      (positive `cached_prompt_tokens`, correct discount, matching settlement),
      non-sticky/ambiguous (`ambiguous_cache`, no discount), retry (null/full-rate,
      no duplicate discount/receipt), invalid-range quarantine, and two concurrent
      distinct conversation keys with zero cross-key reuse in one batch.

### 4.4 Per-request block-table lifecycle over engine handle (FR-CB4 → AC-17)
- [ ] Own request-allocation / bind / extend / release-completed / detach /
      release ONLY at scheduler boundaries: admission, prefill completion,
      decode-step completion, cancellation, terminal stop, request-local failure,
      batch-level failure, cache commit, warm-swap drain.
- [ ] Never expose one request's block table / cache handle / logical positions to
      another request. Per-request extract-to-standalone uses the FR-PKV10
      primitive and preserves exact SPEC-024 LCP/trim (incl. mid-block).
- [ ] Tests use a SPEC-039-compatible fake OR the real engine interface (its
      descriptor + handle) — never redefine engine internals in scheduler tests.

### 4.5 Dynamic insert/remove + failure isolation (FR-CB5 → AC-3,4,11)
- [ ] Insert a newly-prefilled row / remove a terminal/cancelled row between
      decode steps without disturbing any other row's stream, sampler, stop state,
      or block table. A row leaves on stop sequence, output-token limit,
      cancellation, or request-local error.
- [ ] **Request-local failure isolates**: a mid-decode block-extension failure
      (shared pool exhausted) fails **that row only** deterministically, releases
      its blocks, leaves healthy rows intact (FR-CB17). A whole-batch model-forward
      failure MAY fail every participating request, with deterministic cleanup (no
      leaked rows/tables/caches/busy-keys).
- [ ] Cancellation observed at a bounded scheduler boundary; no duplicate terminal
      output for a cancelled row.

### 4.6 Paged-pool pressure = back-pressure, not preemption (FR-CB17/CB16 → AC-24)
- [ ] **No true preemption in v0.2** (no evict-and-recompute of a healthy row's KV
      at Entry-110 depths `<= 4`). Pool pressure handled by admission back-pressure
      (§4.1) + deterministic request-local mid-decode failure (§4.5).
- [ ] Both the admission-time and mid-decode paths are observable + reason-coded,
      and emit no settlement receipt for output stitched across a failed+retried
      path.

### 4.7 Serial fallback identical to today (FR-CB9 → AC-5,21)
- [ ] Flag off ⇒ byte-identical to serial in every observable respect: response/
      receipt schemas, per-request accounting, `slots_total`/`slots_free`,
      telemetry field set, and (greedy, no cache-residency diff) byte-identical
      bodies. Retain the `AsyncSemaphore` serial path as (a) flag-off default,
      (b) preflight-guarded fallback for unsupported models, (c) safe mode after
      scheduler failure.
- [ ] Scheduler-failure fallback **never stitches** batched+serial output for one
      request. Applies to subsequent requests, or to an in-flight request only
      before any buyer-visible token/frame/receipt/request-log terminal state
      (then reuse the served snapshot, carry no partial batched cache). After a
      visible side effect: fail closed through the SPEC-001 terminal path, emit no
      stitched settlement receipt (mirrors SPEC-028 boundary).

### 4.8 Unsupported-mode honesty (FR-CB8 → AC-7)
- [ ] Support = `requested tuple ∈ descriptor`. Outside it (unsupported cache
      class, engine capability, MoE-dispatch surface, or `kv_bits`): serial-route
      (permissive, emit `batching_unsupported(serial_routed, <reason>)`) OR fail
      preflight with a named reason. **Never** silently disable KV quantization,
      reinterpret a quantized cache as ordinary KV, downgrade, or run serial
      without explicit permissive policy.

### 4.9 Entry 110 capacity mapping (FR-CB11 → AC-8)
- [ ] Max active decode rows = persisted `max_concurrency_override` for the
      detected hardware class; synthesize no tiers, advertise no capacity above it.
- [ ] Keep three quantities distinct: `slots_total` = validated Entry 110
      concurrency; active accepted/runnable `<= slots_total`; queued work never
      inflates `slots_total`. `slots_free` = validated active capacity − active
      work. Internal prompt/decode/microbatch/pool/queue limits MAY differ but
      MUST NOT change `slots_total`.

### 4.10 SPEC-028 mutual exclusion (FR-CB12 → AC-9)
- [ ] Draft-enabled provider keeps `effective_max_batch = 1` and the existing
      `draft_model_capacity_shortfall` preflight for `max_concurrency_override > 1`;
      batching never engaged for draft-enabled requests; combined spec+batching
      never silently enabled, never in any advertised multiplier.

### 4.11 Warm-swap drain + snapshot binding + idempotence (FR-CB13 → AC-10,20)
- [ ] Two waiting-queue states only: **pre-admission queued** (no snapshot, no
      receipt/settlement attempt, rejectable at drain start) and **accepted**
      (captures served snapshot = model artifact + hash + weights generation at the
      instant of acceptance, subject to drain guarantees). Snapshot capture is the
      single transition point; never run an accepted request against later
      warm-swapped weights under the old hash; never assign a snapshot retroactively.
- [ ] Warm-swap drain covers active prompt rows, decode rows, accepted queued work,
      block-table cleanup, cache commits, terminal receipts; new admission rejected
      once draining; every old-snapshot request finishes or is cancelled before
      weights swap, under a bounded drain timeout; no decode row survives across
      generations; receipt model hash always matches the serving weights.
- [ ] **Operator disable-while-serving** (flag off on a live provider) drains
      in-flight batched work through this same machinery before reverting to serial
      — never drops rows abruptly.
- [ ] Relay/HTTP reconnect + retry idempotent at every lifecycle state (queued /
      prefill / decode / draining): no duplicate accepted work, terminal result, or
      settlement receipt; reattach or reject deterministically.

### 4.12 MoE scheduler obligations (FR-CB16 → AC-23)
- [ ] The scheduler does **NOT** select or route experts — expert selection is
      model-internal (the router runs inside the shared forward). The obligation is
      to feed **each row's correct current token** into the shared `[B,1]` forward
      and keep per-row expert-affected outputs, load-balancing telemetry, and
      terminal/cancel accounting **request-isolated**.
- [ ] AC-23 is a **required correctness fixture, not a placeholder**, for a MoE
      model representative of `Qwen3-Coder-30B-A3B`. The MoE tuple stays
      **unsupported** for batching until this fixture passes, MSB-04 is measured on
      the live MoE (§4.13), and the tuple is admitted by the descriptor.

### 4.13 Throughput-replication gate MSB-01..05 (FR-CB14 → AC-13)
- [ ] Aggregate TG = total decoded tokens over common wall-clock; **never** a sum
      of per-request elapsed durations. Report per-stream and aggregate as distinct
      values; exclude warm-up; record all RESEARCH_232 §3.1 fields.
- [ ] Ship **no** throughput number not measured on real catalog models. Gate A2
      thresholds (MSB-02 > 1.5x MSB-01, MSB-03 > 1.2x MSB-01, ≥1 Entry-110
      multi-slot tier > 1.3x aggregate TG, within memory bound) are promotion
      thresholds — failing triggers profiling/pivot, not a shipped number.
- [ ] **MoE throughput risk (expectation-setter):** a 2–4 row batch on the
      128-expert/8-active MoE routes to largely **disjoint** experts, so per-step
      weight-load amortization is weak; aggregate-TG may trail dense uplift and fall
      **below the MSB-04 floor**. **MSB-04 MUST be measured on the live MoE**, never
      extrapolated from dense MSB-02/03; a MoE tuple failing MSB-04 ships no number
      and stays unsupported.

### 4.14 SPEC-037 composition (FR-CB16 → AC-12)
- [ ] With batching on, an eligible conversation entry round-trips identically
      through the SPEC-037 v1 opaque-record path, OR all batched scheduler/engine
      state is proven **flag-isolated from persistence** (SPEC-037 serial path
      unaffected). No scheduler-owned block table persisted through the serial
      opaque-record path unless SPEC-039 declares that representation + its ABI
      compatibility (codec-ID + ABI-epoch bump, never a silent format change).

## 5. Acceptance criteria → fixtures (all 24; every R0xx exercised)

Map each fixture to its AC in the PR body. AC-1/2/6/19 per-request usage/stop/
determinism/cache-billing; AC-3 cancellation; AC-4 join-leave + shared-forward
invocation-count assert; AC-5/21 serial-fallback parity + scheduler-failure
boundary; AC-7 unsupported rejection; AC-8 Entry-110 mapping; AC-9 SPEC-028
exclusion; AC-10/20 warm-swap drain + reconnect idempotence; AC-11 batch-failure
cleanup; AC-12 SPEC-037 round-trip; AC-13 MSB harness + full MSB-01..05; AC-14
real-hardware enable gate (hardware run, not CI); AC-15 FCFS + backpressure +
shared admission; AC-16 decode-first + bounded prefill; AC-17 block-table
lifecycle; AC-18 single-owner actor isolation (static + concurrency); AC-22 local
capability activation gate (static-review + fixture); AC-23 MoE per-row isolation
+ MSB-04; AC-24 pool-pressure back-pressure + request-local failure, no preemption.

## 6. Audit loop (before PR is "done")

Same discipline as the SPEC-039 build, and **heavier because this is money-path**:
1. Reconstruct the **full IMPL diff as it will land** (base = commit before this
   build's first commit — i.e. the #804 scaffold base — diff to working tree).
   Never audit an incremental slice on top of the scaffold.
2. Three Codex lanes (code / security / architect) via `omc ask codex`, prompts in
   `audits/<date>/` (not `specs/`), backtick-safe (prompt-to-file). Bar **0
   C/H/M**; iterate until clean; carry LOW/INFO with PR-body rationale.
3. Two independent Claude passes (adversarial verificator + correctness/product
   critic), feature + diff only. **Re-verify the fix delta** — the SPEC-037 IMPL
   proved a fix can introduce a fresh HIGH; check per-request attribution and the
   warm-swap/idempotence paths especially hard.
4. Do not re-fire a lane that already passed 0/0/0.

## 7. Real-hardware enable gate (FR-CB15 → AC-14) — the true finish line, NOT CI

Merge lands the feature **default-off and inert**. Before the flag serves real
traffic on a given hardware/model/quantization/KV/runtime tuple, complete a
real-Mac exercise on that tuple proving, at minimum:
- aggregate-TG meeting FR-CB14 / Gate A2 for that Entry-110 tier;
- **per-request usage correctness under the shared forward on real hardware**
  (FR-CB6: per-request token counts + receipt fields correct, zero cross-request
  attribution), not only in unit fixtures;
- no cross-request state leak, no Metal command-buffer regression, peak RSS within
  bound, warm-swap/receipt/model-hash parity, and SPEC-039 engine support for the
  tuple.

Author the operator runbook `docs/runbooks/continuous-batching-enable-gate.md`
with this PR (analogous to the SPEC-037 KVS graduation runbook). Promotion to a
**production default** additionally needs Gate A5 (`sku-econ` green, material
sustained upside, acceptable tail latency + rejection rate, OPoI false-positive
< 5%); a tier failing any A5 condition stays opt-in.

**The same-hardware serve traps apply** (from the SPEC-037 incident and the
SPEC-039 handoff): `serve` self-re-execs into the INSTALLED binary, and a worktree
`swift build` has no `mlx.metallib` — so this real-serve proof runs only from a
**packaged release-candidate install** on a test provider, ideally a `>32 GB` Mac
(the recurring >32 GB-Mac enable-proof dependency; also requires the SPEC-039
runtime bridge, #887, before any batched cache-reuse path can serve).
**Provider safety on the dev Mac:** it runs the
LIVE production provider — never broad `pkill`; use narrow `pgrep`; bootout the
watchdog (`live.streamvc.macprovider-watchdog`) then the provider via graceful
`launchctl bootout`, off-peak, and restore + verify serving after. Never print the
buyer token.

## 8. PR / merge protocol

- Author the PR as **Augustas11**; fill the governance declaration honestly
  (`behavior_change: "yes"`, `contract_change: "none"` — preserves LOCKED
  SPEC-015/024/005, adds no new canonical contract field; cite `SPEC-038` + a
  requirement + `authority_domains: ["continuous-batching-serving"]` + tests).
- Green `ci-required` + 1 approval is the merge gate; `spec-index/check` advisory.
- Merge: antfleet-ops approves → `GH_TOKEN=$(gh auth token -u Augustas11) gh pr
  merge --squash --admin <n>`.
- After squash-merge: reset local `main` to `origin/main`, delete the PR branch
  (and the now-absorbed `feature/232-continuous-batching`), remove the worktree.
- Append a DECISION_CRITERIA.md entry capturing the scheduler landing, the
  #804-scaffold absorption, the upstream-pin→local-capability reframe, and the
  merged-inert / enable-gate distinction (decision-log entries merge last).

## 9. Clean-room (still in force)

No `d-inference` / `Layr-Labs/*` source consultation in any session. Build only
from `ml-explore` upstream (MIT/Apache), public `mlx-lm` `BatchGenerator` (MIT),
vLLM (Apache), and the PagedAttention paper. The wall is knowledge-flow, not
session boundaries.
