# Product Build 5 current-state evidence

Date: 2026-09-11

Evidence revision: `build5-evidence-r5`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

Roadmap baseline: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`

Scope: assessment and planning only

## Evidence rules

This record describes merged source at the repository base above and fresh
tests of that source. Historical plans, specifications, pull requests, and
spike reports remain supporting context. A skipped, zero-selected, failed,
fixture-only, or historical run is never a fresh acceptance pass. Nothing in
this Build 5 branch changes runtime code, scheduling, configuration,
conformance state, releases, or production enablement.

The roadmap source was available at
`/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md`.
Durable conclusions are recorded here and do not depend on that temporary
path.

## Classification of the requested surface

| Surface | Status | Code-grounded evidence | Consequence |
|---|---|---|---|
| Paged KV allocator and gather foundation | Landed, inert, conformance pending | `phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift` and `phase3-binary/Sources/macprovider-cli/PagedKVCache.swift` exist. | Allocator and gather behavior can be tested. This does not prove a production bridge or accepted SPEC-039 conformance. |
| Continuous scheduler core | Landed, inert, conformance pending | `phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift` contains the actor, queue, row, allocator, cancellation, and accounting scaffold. | Deterministic scheduler behavior is testable without proving a shared MLX forward. |
| Production `ModelRuntime` bridge | Missing on merged source base | `ModelRuntime.continuousBatchingCapability` supplies no requested tuple and sets `schedulerBackendAvailable: false`. `completeWithServedSnapshot` and `streamWithServedSnapshot` continue to create independent `TokenIterator` instances behind the serial `AsyncSemaphore`. | Real traffic cannot use continuous batching from this source base. |
| Paged-cache injection and lifecycle owner | Missing | `ModelRuntime.enforcePagedKVPreflight` rejects an attached decision because no runtime owner injects `PagedKVCache` and owns its handle lifecycle. | Production generation does not use paged KV. |
| Batch/serial execution arbitration | Missing | SPEC-038 FR-CB7 forbids unsupported serial iterators and supported batched work from concurrently using one resident model without proof. No runtime arbiter presently spans the existing semaphore and future scheduler. | A future bridge requires one explicit execution owner before mixed fallback can be safe. |
| Unsupported-feature routing | Partial | `ModelRuntime.requestStateRepresentable` and `ContinuousBatchingCapability` reason-code tools, structured output, logprobs/logit bias, speculative decoding, sticky reuse, quantized KV, and unadvertised tuples. | Policy exists; live backend routing and mutual exclusion remain unproved. |
| SPEC-038 conformance | Pending | `specs/CONFORMANCE.json` leaves the SPEC-038 implementation requirements pending. | No continuous-batching conformance or production support may be advertised. |
| SPEC-039 conformance | Pending reconciliation | SPEC-039 is draft with `implementation_status: pending-reconciliation`, `production_status: not-deployed`, and `SPEC-039-R001` through `SPEC-039-R014` all `pending` with empty implementation/test/evidence arrays. | Foundation code is not accepted SPEC-039 implementation evidence. Reconciliation is a prerequisite to a runtime bridge. |
| Draft runtime-bridge work | Active historical context only | Draft PR #894 was open, conflicting, and had a failed `spec-index / check` when inspected. Its candidate commits were not ancestors of the source base. | Rebase and review useful work as a complete new diff; never assume it landed. |
| Benchmarks and enable gate | Partial documents; no qualifying result | SPEC-038 FR-CB14/15, SPEC-039 FR-PKV13, and the enable runbook define portions of the gate. | No 64 GB+ representative result, large-model capacity claim, or production enable authority exists. |

## Fresh deterministic test evidence

Command:

```text
cd phase3-binary
swift test --filter 'PagedKVEngineTests|ContinuousBatchSchedulerTests|PagedKVParityTests'
```

Result: exit 0. Seventy-three executable tests passed: 43 scheduler tests and
30 engine tests. Three selected `PagedKVParityTests` were explicitly skipped
because their opt-in environment variables were absent. The skipped tests are
not passing evidence. This run proves only the exercised deterministic
allocator/scheduler behavior.

## Fresh 3B MLX result: exact bytes, exploratory classification

The ordinary SwiftPM opt-in attempt first failed because the test bundle did
not contain the required metallib. After `build-mlx-metallib.sh` placed the
pinned metallib next to the ignored test executable, the opt-in test was rerun.
The first successful run completed 40/40 greedy-token parity. A second fresh
R3 run completed 1/1 selected test in 5.944 seconds with 40/40 parity, 2,240
gather calls, four maximum logical blocks, and a non-identity permutation.
Its sanitized committed log is
`docs/product-roadmap/build-5/evidence/real-mlx-3b-exploratory-r3.log` with
SHA-256 `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95`.

The R3 run is bound to these exact observed bytes:

| Item | Exact value |
|---|---|
| Model repository | `mlx-community/Llama-3.2-3B-Instruct-4bit` |
| Snapshot revision | `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` |
| Canonical six-file manifest SHA-256 | `13dd40495712f75a36855801a5211da59c6416d29a58aafea434978980f2c8e3` |
| `config.json` | 1,122 bytes; `c546925585e48f43890d9dc5150df4fec73dd3780d92961c5ace451934cc4cd6` |
| `model.safetensors` | 1,807,496,278 bytes; `d75e1ee0ea653cc5b76191ec934c7c0d568e94d4e47846619f1f4bc715b7b265` |
| `model.safetensors.index.json` | 45,720 bytes; `2ef31fa0b9dcda01f87835851d5e1d5a39ab6258ae618af6ea864c3747e556e4` |
| `special_tokens_map.json` | 296 bytes; `6f38c73729248f6c127296386e3cdde96e254636cc58b4169d3fd32328d9a8ec` |
| `tokenizer.json` | 17,209,920 bytes; `6b9e4e7fb171f92fd137b777cc2714bf87d11576700a1dcd7a399e7bbe39537b` |
| `tokenizer_config.json` | 54,558 bytes; `022d5ae3df4737998ab97d8f31ac2bcb4c06dd8ebe5a8aba2b4aceef1e5ea7d3` |
| Prompt UTF-8 SHA-256 | `e474dfc49534a577a789472b5627e4d07acc1b445181c070c0fab29a960ab291` |
| Harness source SHA-256 | `95808cb4ce2e0c004c776998fc4f48eb5cdf6cfe4f666c75ac61bf18c10c8095` |
| SwiftPM test executable | 144,076,712 bytes; `affdca8488e80e71a21340660602e926e2830ef282cec074f0758016664e12fe` |
| Adjacent `mlx.metallib` | 130,926,469 bytes; `90c9a8af18123b2f84c17e5e85d31e356e24df69dea5639c9e4aa439a4985274` |
| Committed `Package.resolved` SHA-256 | `e844140818c6b134b4efabca73dfc1024fffb8a12fb5ea8131e0d85c59b20356` |
| SwiftPM workspace-state SHA-256 | `ad2fcab636508025c3e7242ea9e1849d2f017e44403469690183eb57c52e5f9a` |
| MLX checkouts used by the built test executable | `mlx-swift` 0.31.4 at `dc43e62d7055353c7f99fa071a4e71d29dfddc44`; `mlx-swift-lm` 3.31.4 at `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` |
| Host/toolchain | Apple M5 MacBook Air, 32 GiB; macOS 26.5 (25F71); Xcode 26.6 (17F113); Swift 6.3.3 |

The canonical model manifest digest above is computed over lexicographically
sorted records `relative_path NUL byte_count NUL content_sha256 LF`. The test
snapshot contained exactly one directory with a `config.json` when inspected,
but the harness did not require its revision. `findSnapshotDir` iterates the
filesystem and selects the first acceptable directory, and
`makePagedCacheFactory` supplies all-zero model and metallib hashes to the
descriptor. Therefore this is exploratory real-MLX evidence, not a
descriptor-authoritative tuple qualification. The independent manifest proves
which bytes were present and used in this observed run; it does not repair the
harness's authority boundary.

Swift 6.3 planning rewrote `Package.resolved` during the R3 invocation. That
uncommitted change was restored immediately. The executable's own hash and the
SwiftPM workspace-state/checkouts above bind what actually ran; this is another
reason the run cannot substitute for the protected locked-resolution release
path.

A qualifying future harness must accept a declared snapshot revision, adopt it
into a dedicated read-only APFS image, and recursively manifest every regular
model file rather than a caller-selected subset. The closed loader identity
includes every weight shard/index reference, config, tokenizer/template,
repository code file, metallib/resource, executable, dependency lock and
checkout, runtime selector, and non-platform dynamic library. It rejects
symlinks, normalized-path collisions, missing or unreferenced shards,
custom/remote code, undeclared selectors, and network fallback. It verifies
the complete manifest before load and recaptures image, mount, file identity,
and content after unload; mutation or replacement is a failed cell. Only those
verified bytes may form the model/metallib SPEC-039 descriptor. No first-
directory selection or caller assertion may grant tuple authority.

## Assessment review state

The independent R4 GPT-5.6 Sol review reported 0 Critical, 2 High, 3 Medium,
and 0 Low findings. It did not dispute the merged-source classification or the
exploratory 3B result. It rejected R4 as a promotion plan because first-run
memory admission depended on the calibration result it sought to measure;
accepted backlog and logical fencing did not prove the mode-wait bound; the
runtime/campaign/dynamic loader closure and backing-object custody were
incomplete; cancellation and slow-consumer triggers were nondeterministic; and
request-level resampling ignored start/batch correlation. R5 corrects those
planning contracts only. No additional inference or implementation test was
run because this revision changes documentation and does not alter the
historical source or raw exploratory evidence. R5 remains unapproved until a
fresh independent GPT-5.6 Sol review reports zero Critical, High, and Medium
findings against the exact committed digests.

## Sanitized host and artifact inventory

No serial number, hardware UUID, local account data, signing material, buyer
content, provider credentials, or operator secret is retained.

| Item | Observed value | Qualification use |
|---|---|---|
| Host | MacBook Air, Apple M5, 10 CPU cores, 32 GiB unified memory | Small-model functional work only. Entry 110 recommends one row. |
| OS | macOS 26.5 (25F71), Darwin 25.5.0 | Tuple field for local evidence. |
| Development toolchain | Xcode 26.6 (17F113), Swift 6.3.3 | Development evidence only; it is not the protected release toolchain. |
| Protected release toolchain required later | Xcode 16.4 (16F6), Swift 6.1.2, macOS SDK 15.5 | Mandatory for release-candidate proof. |
| Local artifacts | Complete 3B snapshot above; Qwen3-8B-4bit with a 4,607,835,174-byte weight file | Candidate small-model cells only after deterministic selection and a maintenance window. |
| Host state | Provider/Malibu processes were present; memory pressure was normal when sampled | Not a clean sustained-load benchmark host. |
| Large target | No 64 GiB+ host and no verified local 30B MoE artifact | Representative capacity and MSB qualification remain blocked. |

## Current claim boundary

MacProvider has inert scheduler and paged-KV foundations, fresh deterministic
unit evidence, and one exactly inventoried but exploratory 3B real-MLX gather
result. Production generation does not use paged KV or continuous batching.
No throughput uplift, memory-servability improvement, MoE shared-forward
correctness, representative capacity, release qualification, or production
enablement is proved.
