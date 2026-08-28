# Handoff — Cluster F (cross-Mac model sharding) desk research (2026-07-22)

## Why this exists

A chat session investigated whether macprovider should adopt
[Mesh-LLM](https://github.com/Mesh-LLM/mesh-llm) (an external Rust project that
pools machines into one OpenAI-compatible endpoint, splitting oversized models
across peers) as a way to serve models too large for one provider Mac. This is
**desk research** (repo reads + external repo/PR inspection), not a benchmarked
campaign — it has not earned a `RESEARCH_2NN_..._MEMO.md` yet. This doc hands
the findings to whichever session maintains `RESEARCH_ROADMAP.md` and turns
research into SPECs, so it can decide whether/how to fold this in.

**Repository baseline:** `origin/main` at `013ef86b` (2026-07-22).

## TL;DR

- This is exactly the thing your own specs already call **"Cluster F sharding"**
  and have marked **deferred** — see [Where this already lives in the repo](#where-this-already-lives-in-the-repo).
  Mesh-LLM is a working reference implementation of that deferred idea, built on
  a different stack than macprovider uses.
- **Don't port Mesh-LLM.** It's GGUF/llama.cpp-native (Rust); macprovider is
  MLX-native (Swift). Adopting it means running a second inference stack, not
  extending the existing one.
- **The "recreate it on MLX" runtime question has a concrete, trackable answer**
  now instead of being open: the collective primitives exist in MLX's C layer,
  a Swift wrapper is mid-flight upstream in an **unmerged, 4-month-stale PR**,
  and it has real caveats (CPU-only ops, no backend selection). Details below.
- **The runtime is not the biggest blocker anyway.** Ranked by severity, the
  real gates are (1) receipts/billing assume one provider per response, (2) the
  provider-anonymity-set model gets weaker, (3) availability multiplies across
  N independently-owned Macs, (4) no established buyer demand for models that
  don't fit one high-end Mac today. The MLX/Swift runtime question is the most
  *tractable* item on the list, not the most important one.
- **Recommendation:** do not start a build. Register the upstream PR as a watch
  item; only commission a full `RESEARCH_237` memo if a demand signal for
  oversized models shows up (see [Suggested next steps](#suggested-next-steps)).

---

## Where this already lives in the repo

This isn't a new idea — it's a named, deferred backlog item that already has no
spec:

- [`specs/SPEC-015-receipts.md:910`](../../specs/SPEC-015-receipts.md) and
  `:4658` (Q3 "Cross-provider routing") — *"Once Cluster F sharding lands a
  single response may have multiple provider segments... v0.1 assumes one
  provider per response."* Status: **deferred**, confirmed in
  [`docs/OPEN_QUESTIONS.md:202`](../OPEN_QUESTIONS.md) (`SPEC-015/Q3 | deferred
  | ... | Cluster F sharding | ... v0.4+ candidate`).
- [`specs/SPEC-025-native-mac-app.md:676`](../../specs/SPEC-025-native-mac-app.md)
  lists "multi-node fleet management" under §13 out-of-scope/backlog.
- `audits/_prompts/BUILD_SPEC_015_RECEIPTS_v0_1_PROMPT.md:83,121` and
  `_v0_2_VERIFY_PROMPT.md:125` repeat the same deferral for receipt chain
  verification.
- **"Cluster F" has no dedicated spec file anywhere** — it exists only as a
  named-but-unspecified future bucket. If this ever gets built, it needs a new
  `SPEC-0NN-cluster-f-sharding.md`, not a patch to an existing spec.

## Current macprovider state (verified in code, not assumed)

- **Single model, single Mac, always.** `phase4-coordinator`'s `Provider`
  struct has one `ModelID` field (`internal/pool/provider.go:101`); heartbeats
  update that single field. No layer-range/tensor-parallel/pipeline-parallel
  code exists anywhere in the tree.
- **Backend is MLX, not GGUF/llama.cpp.**
  [`phase3-binary/Package.swift:19-39`](../../phase3-binary/Package.swift)
  depends on `mlx-swift-lm` (`MLXLLM`/`MLXLMCommon`) + `swift-transformers`.
  `phase3-binary/Sources/malibu-cli/ModelRuntime.swift` manages exactly
  one loaded model at a time (`currentModelID`/`currentModelHash`, ~lines
  322-410), including warm-swap to a *different single* model.
- **`phase4-coordinator` is a pure marketplace/routing/billing hub** — one
  buyer request maps to exactly one provider (`internal/pool`,
  `internal/routing`, `internal/buyer`).
- **Model catalog is one-hot-model-per-provider.** `SPEC-010-model-catalog.md`
  (v1.5, **LOCKED**) lets a provider *advertise* additional `supported_models[]`
  it could cold-start into (`:243`), but only one model is warm at a time —
  not concurrent multi-model serving, and not sharding.
- **Current dependency pins** (`beta/throughput-engineering/UPSTREAM_WATCH.json`,
  checked 2026-07-22): `mlx_swift_lm = 3.31.4`, `mlx_swift = 0.31.6`. Neither
  includes any distributed-communication code (see below).

## Mesh-LLM: what it is, for context

[Mesh-LLM](https://github.com/Mesh-LLM/mesh-llm) — Rust, Apache-2.0, 2.5k★,
actively maintained (pushed 2026-07-15 at time of check). Splits oversized
models via **Skippy stage splits**: a model is exported as a layer package
(`model-package.json` manifest + GGUF fragments per contiguous layer range); a
coordinator plans stage assignment across peers; stages load
downstream-first; stage-0 only becomes routable once every stage reports
ready. This is **pipeline-parallel** (activations handed rank-to-rank, no
per-layer all-reduce) — deliberately avoiding the low-latency interconnect that
tensor-parallel approaches need. Transport is QUIC/iroh with gossip peer-state
and Nostr discovery. Their own
[Exo comparison doc](https://github.com/Mesh-LLM/mesh-llm/blob/main/docs/EXO_COMPARISON.md)
contrasts this with [Exo](https://github.com/exo-explore/exo) (MLX + tensor
*and* pipeline parallelism + Thunderbolt-5 RDMA, Apple-first) — Exo is
architecturally closer to what an MLX-native macprovider build would look
like than Mesh-LLM is.

**Why not just run Mesh-LLM as a sidecar for oversized models only** (a
third option beyond "port it" / "don't"): possible, but it still requires the
same billing/receipts multi-provider-settlement work below, on top of running
and operating two separate inference stacks. Noting it for completeness; not
recommending it as the first move.

## The MLX/Swift runtime question — now answered, not open

Original open question: does `mlx-swift` expose the same distributed
primitives Python MLX has? Verified directly against the `mlx-swift` repo:

- **The C-level primitives already exist**, vendored in `mlx-swift`'s `Cmlx`
  bridge:
  [`Source/Cmlx/include/mlx/c/distributed.h`](https://github.com/ml-explore/mlx-swift/blob/main/Source/Cmlx/include/mlx/c/distributed.h)
  declares `mlx_distributed_all_sum`, `all_gather`, `all_max`, `all_min`,
  `sum_scatter`, `send`, `recv`, `recv_like`, plus group init/rank/size/split
  — the same auto-generated layer Python MLX sits on.
- **No Swift wrapper ships them.** Every other MLX capability gets an
  ergonomic Swift file (`Random.swift`, `FFT.swift`, `Linalg.swift`); there is
  no `Distributed.swift` in any tagged release.
- **A wrapper exists but is unmerged**:
  [`ml-explore/mlx-swift#371`](https://github.com/ml-explore/mlx-swift/pull/371)
  ("Add distributed communication framework for multi-device tensor
  parallelism"), opened 2026-03-15 by community contributor `ronaldmannak`,
  **still OPEN as of 2026-07-22** (37 files, +7199/-95, mergeable, no reviews
  merged in ~4 months). It adds `Source/MLX/Distributed.swift`
  (`DistributedGroup` + 8 collectives including `send`/`recv` — the ones
  pipeline-parallel/Skippy-style splitting actually needs) and
  `Source/MLXNN/Distributed.swift` (sharded linear layers for tensor
  parallelism). Ring/TCP backend is the relevant one for macprovider
  (internet-distributed provider Macs, not a Thunderbolt-linked cluster);
  JACCL (Thunderbolt-5 RDMA) is not applicable to your topology.
- **PR's own caveats:** all distributed ops are **CPU-only** right now
  (requires forcing `Device.withDefaultDevice(.cpu)`) — unknown whether
  CPU-bound send/recv becomes a bottleneck vs. GPU-side generation, needs a
  benchmark before trusting it; backend selection (ring vs JACCL) isn't
  programmatic; `group.split()` (subgroups) doesn't work outside MPI
  (unavailable on macOS); `sumScatter` isn't implemented in the ring backend,
  only tested for graceful failure.
- **Context signal:** Apple's own `mlx.launch` (Python) already does working
  pipeline-parallel sharding today — a 27B Qwen model across four M3 Ultras at
  ~3x single-machine throughput — and there's a WWDC 2026 session,
  ["Explore distributed inference and training with MLX"](https://developer.apple.com/videos/play/wwdc2026/233/),
  suggesting first-party investment. Swift parity is lagging behind Python,
  gated on this one community PR landing.

**Net effect:** this moves the runtime question from "research spike needed"
to "known upstream dependency to track." It does not change the overall
recommendation — see ranked blockers below.

## Ranked blockers (why this still isn't a build, even with the runtime answered)

1. **Billing/receipts.** SPEC-015's entire ledger model assumes one provider
   per response — that's the literal thing "Cluster F" is deferred against.
   N-provider settlement per request is a real redesign of
   `phase4-coordinator`'s billing path, independent of the inference engine.
   This is money-path code — full three-lane audit loop applies once it's
   scoped.
2. **Anonymity/privacy.** SPEC-017 already treats macprovider's provider pool
   as a deliberately small, single-provider anonymity set (that's *why*
   per-request decode-speed telemetry was ruled not-feasible). Pipeline
   splitting means a buyer's request flows through N provider machines'
   intermediate activations instead of one — a new privacy surface (timing/
   volume side-channels across providers) needing explicit analysis before
   any build, not after.
3. **Availability.** A response depending on N independently-owned,
   independently-flaky Mac providers being simultaneously up is strictly more
   fragile than routing to whichever single Mac is healthy — and this repo has
   already eaten real incidents from single-provider transient degrade
   (`prod-503-noprovider-transient-degrade`, per session memory).
4. **Demand is unestablished.** Nothing currently in the spec corpus targets
   models too large for one high-end Mac (M3 Ultra/512GB territory). If the
   target catalog fits a single machine, this solves a problem with no
   confirmed buyers yet.
5. **Runtime (MLX/Swift distributed primitives).** Tractable and now
   concretely scoped (see above) — genuinely the easiest item on this list,
   which is exactly why it shouldn't be mistaken for the blocking one.

## Suggested next steps

For whoever picks this up:

1. **Register the upstream watch**, don't build yet. Add an entry to
   `beta/throughput-engineering/UPSTREAM_WATCH.json` under `blockers`
   (pattern matches the existing `mlx_swift_lm_406_...` / `mlx_swift_lm_364_...`
   entries), e.g. `mlx_swift_371_distributed_communication` pointing at
   [PR #371](https://github.com/ml-explore/mlx-swift/pull/371), so it surfaces
   automatically on the next upstream-watch refresh instead of being
   rediscovered from scratch.
2. **Don't add a numbered research thread yet.** This hasn't earned a
   `RESEARCH_237_..._MEMO.md` — there's no measurement campaign behind it, only
   desk research. If/when a demand signal appears (see item 4 above), the next
   free number is **237** (last used: 233; 234-236 are e2e-harness threads
   tracked directly in `RESEARCH_ROADMAP.md`, not memo files).
3. **If commissioning `RESEARCH_237`,** scope it around the demand question
   first ("do we have evidence buyers want models bigger than one Mac can
   serve?"), not the runtime question (already answered above) and not a
   Mesh-LLM feature-parity exercise (already covered in this handoff).
4. **If/when PR #371 merges,** the follow-up is a benchmark spike: pull the
   branch, run two provider-class Macs over a realistic WAN link, and measure
   `send`/`recv` overhead against real generation throughput before trusting
   CPU-only collectives for anything latency-sensitive.
5. **Billing/receipts scoping is the actual pacing work**, independent of all
   of the above — if this ever gets prioritized, start there, not with the
   inference engine.

## Sources

- Mesh-LLM: [repo](https://github.com/Mesh-LLM/mesh-llm) ·
  [README](https://github.com/Mesh-LLM/mesh-llm/blob/main/README.md) ·
  [SKIPPY_SPLITS.md](https://github.com/Mesh-LLM/mesh-llm/blob/main/docs/SKIPPY_SPLITS.md) ·
  [EXO_COMPARISON.md](https://github.com/Mesh-LLM/mesh-llm/blob/main/docs/EXO_COMPARISON.md) ·
  [LAYER_PACKAGE_REPOS.md](https://github.com/Mesh-LLM/mesh-llm/blob/main/docs/LAYER_PACKAGE_REPOS.md) ·
  [MESHES.md](https://github.com/Mesh-LLM/mesh-llm/blob/main/docs/MESHES.md)
- Exo (comparison reference): [repo](https://github.com/exo-explore/exo)
- mlx-swift: [repo](https://github.com/ml-explore/mlx-swift) ·
  [distributed.h](https://github.com/ml-explore/mlx-swift/blob/main/Source/Cmlx/include/mlx/c/distributed.h) ·
  [PR #371](https://github.com/ml-explore/mlx-swift/pull/371)
- MLX core: [Distributed Communication docs](https://ml-explore.github.io/mlx/build/html/usage/distributed.html)
- Apple: [WWDC26 — Explore distributed inference and training with MLX](https://developer.apple.com/videos/play/wwdc2026/233/)
- LocalAI: [MLX Distributed Inference feature page](https://localai.io/features/mlx-distributed/)
- In-repo: `specs/SPEC-015-receipts.md` (Q3), `specs/SPEC-025-native-mac-app.md`
  (§13), `specs/SPEC-010-model-catalog.md` (v1.5, LOCKED), `specs/SPEC-017-*`
  (anonymity-set rationale), `docs/OPEN_QUESTIONS.md`,
  `beta/throughput-engineering/UPSTREAM_WATCH.json`,
  `audits/2026-06-30/mlx-swift-examples-upstream-issue.md` (precedent for
  writing up an upstream-dependency constraint)
