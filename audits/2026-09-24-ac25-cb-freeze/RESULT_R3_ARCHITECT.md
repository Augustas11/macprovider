## Raw output

```text
I'll run the architecture freeze audit on the post-`6f75c3a1` hybrid-cache work: specs, attach contracts, and how the new code sits on the earlier CB path. Reading the prior audit, governance notes, and the branch diff first.Prior freeze results and the R3 architect prompt are on disk. Next I’ll pin the git range and read SPEC-039 / SPEC-038 against the hybrid-cache code.The freeze prompts are in the tree; I’ll now compare SPEC-039/038 to the hybrid attach path, status snapshot, and probe/MSB contracts.SPEC-039 now names a first-turn Qwen3.6 mixed-layout exception. Next I’ll match that text to attach, AC-26, and the status/probe surfaces.I’ll read the attach, handoff, status, probe, and tuple-declaration sites next so the spec claims can be checked against the live contracts.Existing tests and governance checks are next; those results will decide whether the admit-path stderr write is a real operability finding.Architecture freeze audit of `campaign/ac25-m2-api-lifecycle` @ `87ba9771`, focused on `6f75c3a1..HEAD` (`46df88d9`, `e38840a5`, merge `422a83a7`, `87ba9771`) against the full `origin/main...HEAD` contract surface.

No CRITICAL, HIGH, or MEDIUM findings.

## LOW (carried)

`ContinuousBatchScheduler.swift:2304` writes `event=batching_admitted` with `FileHandle.standardError.write(Data)`. `PagedKVRuntimeDiagnostics.swift:21-25` documents that this deprecated `write(_:)` raises an uncatchable exception on a closed stderr and terminates the process. This campaign already moved `CBTrace` to `try? write(contentsOf:)`. The new line is the success counterpart of existing `event=batching_unsupported` telemetry (`ContinuousBatching.swift:393`), which uses the same API. Closed stderr on a successful scheduler admit can abort serving. Use `try? write(contentsOf:)`.

## INFO

- SPEC-039 §5 outcome table (`SPEC-039-paged-kv-attention-engine.md:641`) still lists `CacheList`/hybrid as fail-safe. The measured Qwen3.6 path is mixed `MambaCache`+`KVCacheSimple`, not `CacheList`. FR-PKV12 and the no-go list carry the exception. AC-13 still requires `CacheList` fail-safe.
- `MSBThroughputCommand` still defaults `--compile` on. Serve constructs `compiledDecode: false` for every layout (`ModelRuntime.swift:3183`). Hybrid cannot enter compiled lockstep even when the flag is true (`PagedKVRuntimeBridge.swift:799-801`: `canCompile` requires every layer `.pagedAttention`).
- `GET /v1/status` grows a `continuous_batching` object with no new `localStatusCapabilities` token. Malibu `decodeStatus` uses `JSONSerialization` and ignores unknown keys. Coordinator and gateway do not parse the object.

## Contracts that hold

**SPEC-039 v0.1.4 mixed exception.** Attach requires serving identity `qwen/qwen3.6-27b`, `Qwen3_5ForConditionalGeneration` in `config.json` architectures, runtime class `mixed`, and a measured topology of `MambaCache` on recurrent layers plus `KVCacheSimple` on full-attention layers (`ModelRuntime.swift:1847-1858`, `PagedKVAttachGate.supportsCacheClass`, `pagedKVCacheKinds`). Unverified mixed, `CacheList`, `RotatingKVCache`, and `QuantizedKVCache` still fail `paged_fallback_cache_class`.

**First-turn only.** Hybrid serve installs no contiguous-cache bridge (`ModelRuntime.swift:3161-3164`). `retainTerminalCache` returns nil without that bridge (`ContinuousBatchScheduler.swift:2816`). Admit of a retained sequence also requires the bridge (`:2248-2252`). `installRetainedPagedKVCache` throws `continuous_batching_retained_hybrid_cache_unavailable` for any recurrent layer (`PagedKVRuntimeBridge.swift:631-632`).

**SPEC-038 AC-26.** `canaryShouldSerialRouteCachedHitMissingRetainedHandoff` serial-routes every `cachedPromptTokens > 0` in canary and `.on`, including when a retained handoff exists (`ModelRuntime.swift:3809-3818`). Scheduler submit still rejects cached tokens without a retained sequence (`:1176-1178`).

**FR-CB6 / FR-PKV isolation evidence.** Ordered prompt pairs stop at the first `challengeDistinguishing` result (`ModelRuntime.swift:1636-1718`). A distinguishing pair that diverges fails attach. A non-distinguishing pair cannot hide a leak, so the next pair is tried. Hybrid runs a two-step lockstep window then leave/rejoin (`PagedKVRuntimeParityProbe.swift:225-357`). `measurePagedKVRuntime` requires `proven`, `challengeDistinguishing`, two decoded rows, zero failures, and zero divergences (`ModelRuntime.swift:1520-1525`).

**FR-PKV11 / FR-CB10 mixed tuple.** The attached descriptor advertises `allowedCacheClasses: [runtimeCacheClass]` (`PagedKVEngine.swift:431`), so a Qwen3.6 attach publishes `mixed`. Acceptance coverage matches `cache_class` exactly (`ContinuousBatching.swift:141-150`). Config accepts any non-empty `cache_class` string, so `mixed` is a valid operator declaration. No fleet YAML declares it; undeclared is `tuple_acceptance_coverage_unavailable`.

**Mamba row state.** Recurrent state is fixed-size conv/delta slots packed along the batch axis. Joining rows with empty slots get zeros. Qwen3.6 linear attention uses `cache[0]`/`cache[1]` and `advance(S)`; it does not drive `offset` for SSM. Ragged KV lengths still set `batchedOffset` only when every paged row shares one length. Hybrid cancellation looks up paged handles through `pagedAttentionCaches`.

## Checks

- `python3 scripts/check_spec_governance.py` — exit 0
- `python3 scripts/gen_spec_index.py --check` — exit 0
- `python3 -m unittest scripts.tests.test_byom_contract_lock` — 16 tests, OK
- `swift test --filter 'PagedKVRuntimeMixedCacheTests|testQwen36|testStatusResponsePublishes|testCanarySerialRoutesCachedHit|testMixedCacheClassRequiresVerified|testPagedKV'` — 26 executed, 2 skipped (metallib absent on this host), 0 failures

Writeup: `audits/2026-09-24-ac25-cb-freeze/RESULT_ARCHITECT_R3.md`

**VERDICT: PASS**

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
