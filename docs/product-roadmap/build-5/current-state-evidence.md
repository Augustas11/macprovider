# Product Build 5 current-state evidence

Date: 2026-09-11

Repository base: `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`)

Roadmap baseline: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`

Scope: assessment and planning only

## Evidence rules

This record describes merged code at the repository base above and fresh tests
run from that exact revision. Historical plans, specifications, and pull
request checks are context, not current acceptance evidence. An environment-
skipped test is recorded as skipped. The current work does not enable a
runtime feature, change scheduling, or make a production-capacity claim.

The roadmap source was available at
`/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md` and was
used as historical scope evidence. Durable conclusions are recorded here so
they do not depend on that temporary path.

## Classification of the requested surface

| Surface | Status | Code-grounded evidence | Consequence |
|---|---|---|---|
| Paged KV allocator and gather foundation | Landed, inert | `phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift`, `phase3-binary/Sources/macprovider-cli/PagedKVCache.swift`; foundation commit `69c32bbb` is an ancestor of the assessed base. | Allocator and real gather parity can be tested independently. This does not put paged KV in production generation. |
| Continuous scheduler core | Landed, inert | `phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift`; scheduler commit `edca3faf` is an ancestor. | Actor, queue, row, allocator, cancellation, and accounting logic are unit-testable without claiming a shared production forward. |
| Production `ModelRuntime` integration | Missing on merged main | `ModelRuntime.continuousBatchingCapability` constructs `requestedTuple = nil` and passes `schedulerBackendAvailable: false` at `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1870-1879`. Production generation still uses an `AsyncSemaphore` and independent `TokenIterator` instances, including at lines 2376-2400 and 2502-2594. | The backend cannot be enabled for real traffic from merged code. No scheduler throughput claim is available. |
| Paged cache injection and lifecycle owner | Missing on merged main | `ModelRuntime.enforcePagedKVPreflight` rejects an attached decision because no runtime owner injects `PagedKVCache` and manages its handle (`ModelRuntime.swift:995-1004`). `PagedKVCache.swift:56` records the same inert bridge boundary. | Real paged residency is not part of the production request path. |
| Unsupported-feature routing | Partial | `ModelRuntime.requestStateRepresentable` excludes structured output, tools, logit bias/logprobs/top-logprobs; `ContinuousBatching.swift` reason-codes unavailable tuples, KV quantization, speculative decoding, sticky reuse, and MoE evidence. Canary serial-routes while strict mode fails closed. | The policy surface exists, but end-to-end routing through a live batch backend is unproved until that backend is integrated. |
| Serial fallback | Landed for the inert/capability gate; production failover unproved | The current runtime remains serial, and `ContinuousBatchingCapability.shouldUseSerialPath` supplies reason-coded canary fallback. | Flag-off behavior is protected. Scheduler failure after a real backend starts accepting traffic still needs integrated proof. |
| Capability/conformance publication | Missing | `specs/CONFORMANCE.json` leaves `SPEC-038-R001` through `SPEC-038-R017` pending with no implementation, test, or evidence links. | Do not advertise SPEC-038 conformance or production support. |
| Runtime-bridge follow-up | Active, unmerged, unusable as baseline evidence | Draft PR #894 (`fix/889-spec039p2`) is open, conflicting, and has a failed `spec-index / check`. Candidate commits `5db988f0` and `b8150a4c` are not ancestors of the assessed base. The PR itself keeps production observation/injection inert and defers real large-host parity. | A future implementation may rebase and independently audit useful work, but this assessment never assumes it landed. |
| Benchmarks and enable gate | Partial plan, no qualifying result | `docs/runbooks/continuous-batching-enable-gate.md`, `docs/runbooks/PLAN_THROUGHPUT_ENGINEERING_RUNBOOK.md`, SPEC-038 FR-CB14/15, and SPEC-039 FR-PKV13 define pieces of the gate. | The benchmark contract must be fixed before optimizing or publishing results. No current 64 GB+ representative result exists. |

## Fresh repository tests

### Allocator, scheduler, and parity-suite selection

Command:

```text
cd phase3-binary
swift test --filter 'PagedKVEngineTests|ContinuousBatchSchedulerTests|PagedKVParityTests'
```

Result: exit 0. Seventy-three executable tests passed: 43 scheduler tests and
30 engine tests. Three `PagedKVParityTests` were selected and explicitly
skipped because their opt-in environment variables were absent. The skipped
tests are not passing acceptance evidence.

This proves deterministic scheduler/allocator behavior covered by those unit
tests. It does not execute a production shared forward or real model parity.

### Real small-model MLX parity

An initial opt-in attempt failed before the test ran with `Failed to load the
default metallib`. That is expected evidence that an ordinary SwiftPM build in
a worktree is not a packaged-runtime or release proof.

The pinned metallib was then built into the ignored SwiftPM test bundle and the
test rerun without rebuilding:

```text
cd phase3-binary
./scripts/build-mlx-metallib.sh \
  .build/arm64-apple-macosx/debug/phase3-binaryPackageTests.xctest/Contents/MacOS
MACPROVIDER_RUN_PAGED_PARITY=1 swift test --skip-build \
  --filter PagedKVParityTests/testAC1_DenseLlama_3_2_3B_ParityWithRealGather
```

Result: exit 0; 1 of 1 test passed in 5.682 seconds. The test loaded 28 model
layers and compared 40 of 40 greedy tokens. It recorded 2,240 gather-kernel
calls, a maximum of four logical blocks, and a non-identity physical
permutation.

The result proves real MLX dense 3B gather-feeds-SDPA parity for this test,
artifact, host, and pinned dependency tuple. It does not prove runtime
scheduler integration, concurrent throughput, memory reduction, release
packaging, MoE support, or representative large-model capacity.

## Sanitized host and artifact inventory

No serial number, hardware UUID, local account data, signing material, buyer
content, provider credentials, or operator secret was retained.

| Item | Observed value | Qualification use |
|---|---|---|
| Host | MacBook Air, Apple M5, 10 CPU cores, 32 GB unified memory | Small-model functional and parity work; not representative large-model capacity. |
| OS | macOS 26.5 (25F71), Darwin 25.5.0 | Record as part of every result tuple. |
| Toolchain | Xcode 26.6 (17F113), Swift 6.3.3, Metal compiler available | Local builds and MLX tests. |
| Repository dependencies | `mlx-swift` 0.31.4, `mlx-swift-lm` 3.31.4 from `phase3-binary/Package.resolved` | Pin every result to exact revisions and packaged metallib identity. |
| Free storage at inspection | Approximately 65 GiB on the root volume | Enough for bounded local testing; record again before a benchmark. |
| Host state | A provider CLI process was already running; memory pressure was normal when sampled | This is not a clean benchmark host. Do not stop the process or run sustained load without an operator maintenance window. |
| Usable local MLX artifact | Llama-3.2-3B-Instruct-4bit, about 1.7 GiB of weights | Real small-model parity and functional tests. |
| Usable local MLX artifact | Qwen3-8B-4bit, `model.safetensors` 4,607,835,174 bytes | Candidate 32 GB functional/performance cell after a clean maintenance window. |
| Non-usable cache entries | Several 1B/7B/27B model directories lacked a complete local snapshot | They are not evidence that those models are available. |
| Required large tuple | No 64 GB+ host and no local Qwen3-Coder-30B-A3B artifact | Representative-scale benchmark and capacity claims remain blocked. |

The local cache's apparent disk size can double-count content-addressed blobs
and snapshot links. Artifact availability should be recorded from verified
snapshot files and hashes, not the cache directory's aggregate accounting.

## Current claim boundary

At this revision, it is accurate to say that MacProvider has an inert scheduler
and paged-KV foundation, deterministic unit coverage, and one fresh small-model
real MLX parity result. It is inaccurate to say that production generation uses
paged KV or continuous batching, that paged residency reduces peak attention
memory, that concurrent inference is faster, or that any large-model capacity
has been qualified.
