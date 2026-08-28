# T3-01 — Token/Chunk Batching (`streamInterval`)

**Task ID:** T3-01  
**Date:** 2026-07-07  
**Branch:** `perf/t3-01-stream-interval`  
**Gate:** TG3  
**Status:** WAIVE (structural only; T0-03 GREEN ⇒ <5% egress overhead)

---

## Summary

Implements `streamInterval` — a configurable token-batching parameter that accumulates N content-token deltas before emitting one SSE/WS frame. Default **1** preserves current behavior (one frame per token). Setting **4** matches the upstream production value.

**VERDICT: WAIVE** — T0-03 found egress overhead <5% of token period at p95, so TG3 criteria for promotion are not triggered. The implementation ships clean with default=1 and is ready for a production experiment at `stream_interval: 4` on operator opt-in.

---

## Implementation

### Files changed

| File | Change |
|------|--------|
| `phase3-binary/Sources/MacProviderCore/Config.swift` | Add `streamInterval: Int` to `AppConfig` (default 1) and `CLIOverrides`; wire YAML key `stream_interval`, env `MACPROVIDER_STREAM_INTERVAL`, CLI `--stream-interval` |
| `phase3-binary/Sources/malibu-cli/MalibuCLI.swift` | `@Option --stream-interval` flag; validation in `runServingKnobsPreflight` (must be ≥1); config dump line |
| `phase3-binary/Sources/malibu-cli/CoordinatorClient.swift` | Store `streamInterval` from config; pass to `InferenceRelay` init |
| `phase3-binary/Sources/malibu-cli/InferenceRelay.swift` | `streamInterval` stored property (nonisolated); batching logic in `processStreaming`; pending content flushed on tool-call delta and at stream end |
| `phase3-binary/Tests/malibu-cliTests/StreamIntervalBatchingTests.swift` | 9 tests covering config resolution, relay storage, 1-per-token baseline, 4-token batching, remainder flush, large-interval flush, content fidelity |

### Batching logic (InferenceRelay.processStreaming)

```
var pendingContent = ""
var pendingCount = 0

stream callback:
  .content(text):
    pendingContent += text
    pendingCount += 1
    if pendingCount >= streamInterval:
      enqueue(sseEvent(combined chunk))
      pendingContent = ""; pendingCount = 0
  .toolCallDelta:
    if pendingContent not empty: flush now
    enqueue(tool-call chunk)

after stream:
  if pendingContent not empty: flush remainder
```

Tool-call deltas are never batched and immediately flush any pending content, preserving tool-call sequencing.

---

## Measurement / Estimate

T0-03 concluded **egress overhead <5% of token period at p95** (structural analysis, no live model needed for this path). Based on that:

| Metric | interval=1 | interval=4 | Change |
|--------|-----------|-----------|--------|
| WS send calls per token | 1.0 | 0.25 | **−75%** |
| First-chunk latency | 1× token period | ≤4× token period | acceptable |
| CPU saving (egress path) | baseline | <3% of total (egress <5% → 75% of that) | ~1–2% net |

At 25–30 TPS (dense model), interval=4 reduces sendChunk calls from ~28/sec to ~7/sec. At this TPS the WS send is already sub-millisecond per T0-03, so the absolute CPU saving is <2%.

**Unit test evidence:**
- `testInterval1EmitsOneFramePerToken`: 8 tokens → 8 content frames (baseline confirmed)
- `testInterval4BatchesFourTokensPerFrame`: 8 tokens → 2 content frames (**75% reduction**)
- `testInterval4FlushesRemainder`: 10 tokens → 3 frames (2 full + 1 remainder)
- All 1007 `swift test` cases pass, 0 failures

---

## Gate Assessment

| Criterion | Result |
|-----------|--------|
| ≥10% reduction in send calls (interval=4) | ✅ 75% (structural + unit test) |
| No TTFT regression | ✅ Default=1 unchanged; interval=4 TTFT ≤4 token periods |
| T0-03 verdict | GREEN (<5% egress) → WAIVE path |
| swift test | ✅ 1007 passed, 0 failures |

**VERDICT: WAIVE** per TG3 definition — T0-03 GREEN and no measurable CPU win above 3% threshold. Code ships ready, gate not promoted.

---

## Default recommendation

**Keep default `stream_interval: 1`** (current behavior, no regression risk).

**Production experiment at `stream_interval: 4`:**
- Safe for any Tier-2 provider; confirmed content fidelity in unit tests
- First-chunk latency ≤4 token periods (~130ms at 30 TPS) — imperceptible to users
- Enables ~75% reduction in WS send calls if egress ever becomes the bottleneck
- Suggested config path: add `stream_interval: 4` to operator YAML when running sustained high-TPS sessions or multi-request concurrency experiments

---

## Config surface

```yaml
# config.yaml
stream_interval: 4   # default: 1
```

```bash
# CLI
malibu-cli serve --stream-interval 4

# env
MACPROVIDER_STREAM_INTERVAL=4
```

Priority: CLI > env > YAML > default (1). Validated at serve preflight: must be ≥1.
