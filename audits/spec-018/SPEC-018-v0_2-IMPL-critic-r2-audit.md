# SPEC-018 v0.2.4 IMPL — Critic Blind-spot r2 Audit

**Date:** 2026-06-28
**Reviewer:** claude critic blind-spot
**Commit audited:** `42476b7` on `impl/spec-018-v0-2`
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

- CRITICAL: 1
- HIGH: 2
- MEDIUM: 2
- minor: 1
- Open questions: 1

## Closure status per r1 finding

### r1 CRITICAL

#### r1 C-1 — error envelope `retryable` hardcoded false → **CLOSED**

Verified mechanically:
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:245-262` defines `retryableByCode` map. All 16 SPEC §10d.0 codes present with correct booleans (cross-checked against `specs/SPEC-018-agentic-tool-calling.md:759-776`).
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:278-292` envelope emits `retryable`, `request_id`, `inference_ran`, `settlement_ran` for every code.
- `phase4-coordinator/internal/buyer/server.go:52-73` defines `spec018RetryableByCode` map with the same 16 codes and matching booleans.
- `phase4-coordinator/internal/buyer/server.go:4831-4852` `writeSSEError` emits the thicker envelope with `spec018Retryable(code)` lookup and `spec018ErrorType(code, "server_error")` lookup.
- Test coverage: `phase3-binary/Tests/macprovider-cliTests/MultiTurnTests.swift:41-59` asserts per-code retryable values match SPEC table for 6 sampled codes (true and false branches both exercised).

Sub-observation (not a blocker): `writeSSEError` hardcodes `"inference_ran": true` (server.go:4844) and Swift envelope hardcodes `inference_ran: false` (ChatCompletionRequest.swift:288). Both are envelope shape-correct but the SPEC text suggests these should reflect whether inference actually ran. For terminal SSE errors mid-stream (HTTPServer.swift:543 reuses `error.envelope` after `sseStarted=true`), the Swift envelope reports `inference_ran=false` when inference HAS actually run. Recorded as Open Question, not a finding — see Q-1.

### r1 HIGH

#### r1 H-1 — AC-44 dead instrumentation → **PARTIALLY CLOSED → see fresh H-1, H-2**

Headers are now emitted, so the metric will accumulate samples > 0:
- Provider sets `X-MacProvider-Provider-ToolCallOpen-Unix-Ms` + `X-MacProvider-Provider-Unix-Ms` at `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:460-463`.
- Coordinator sets `X-MacProvider-Coordinator-FirstForward-Unix-Ms` at `phase4-coordinator/internal/buyer/server.go:2627`.
- Gateway sets `X-MacProvider-Gateway-FirstByte-Unix-Ms` + `X-MacProvider-NTP-Skew-Ms` at `phase5-gateway/internal/router/chat_proxy.go:210-211, 360-361`.
- `observeFromHeaders` is invoked at `server.go:2630` on every committed forward.

But **the timestamps measure the wrong moments** and **the skew is fake** — see fresh H-1 and H-2 below. The r1 finding's surface symptom (samples_total 0) is fixed; the underlying SPEC AC-44 measurement-validity issue is not.

#### r1 H-2 — AC-25a omits `macprovider_model_hash_observed` → **CLOSED**

`test/integration/cline_session/run_fixture.py:75` mock emits `macprovider_model_hash_observed: KNOWN_HASH if turn % 2 == 0 else None`. Per-turn entries at `:165, :173` carry the field. Validation at `:228-229` asserts both `KNOWN_HASH` and `None` are present in the hashes set. Both branches structurally exercised.

(But the fixture is broken by a separate Python `TypeError` — see fresh C-1 below — so the validation never actually runs.)

#### r1 H-3 — AC-48b not actually using Vercel AI SDK → **CLOSED**

`test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts:107-138` now:
- Stands up a local HTTP server emitting the terminal-error SSE sequence (lines 68-103).
- Constructs `createOpenAICompatible({...})` and `provider.chatModel("fixture-model")` (lines 109-113).
- Calls `streamText({model: ..., prompt: ...})` and iterates `result.fullStream` (lines 119-130).
- Asserts `sawToolCallPart === false` and `sawSuccessfulText === false` (lines 135-137).

This is the real AC-48b shape. If the SDK ever yielded a `tool-call` part type from the malformed/terminated stream, the test would fail. Genuinely closed.

### r1 MEDIUM

#### r1 M-1 — Renderer fixtures not byte-equivalent to tokenizer config → **CLOSED**

- `tools/version-pins/qwen3-tokenizer-config-v0_2_4.txt` pins SHA-256 `d5d09f07b48c3086c508b30d1c9114bd1189145b74e982a265350c923acd8101` for Qwen3-32B tokenizer_config.json.
- **Mechanically verified against upstream:** I fetched `https://huggingface.co/Qwen/Qwen3-32B/raw/main/tokenizer_config.json`; `shasum -a 256` returned exactly the pinned value. The pin is honest and current.
- `tools/version-pins/llama3_3-tokenizer-config-v0_2_4.txt` is honestly labeled "Structural pin rather than byte-exact" with explicit explanation of why (Meta gating). It enumerates the structural delimiter set used in the renderer (`<|python_tag|>`, `<|eot_id|>`, `<|start_header_id|>ipython<|end_header_id|>` etc.), which matches what `MultiTurnTests.swift:21-29` asserts.
- The SPEC §3.8.1 carve-out for "structural plus pinned upstream artifact where they are not byte-stable" is satisfied.

#### r1 M-2 — AC-46 silent sanitization → **NOT CLOSED → see fresh M-1**

The audit-prompt summary claims "AC-46 self-test now treats non-hex from 'known' branch as mismatch". Mechanical inspection of `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:795-803` shows `validObservedModelHash` is **still a silent sanitizer**:

```swift
private static func validObservedModelHash(_ hash: String?) -> String? {
    guard let hash, hash.utf8.count == 64 else { return nil }
    guard hash.utf8.allSatisfy({ byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }) else {
        return nil
    }
    return hash
}
```

No warn log when a non-nil-but-malformed hash is rejected. No metric. No test in `phase3-binary/Tests/macprovider-cliTests/` exercises the "known but format-invalid" path. `grep -rn "modelHashMismatch\|model_hash_mismatch\|model_hash_self_test\|selfTestModelHash"` returns zero hits. The function is identical in semantics to what r1 flagged — a misconfigured `model_hash` subsystem reporting an uppercase or 63-char hash still silently emits `null`, indistinguishable from "no local hash known".

This is a phantom closure in IMPL-NOTES. The commit message claim "AC-46 self-test now treats non-hex from 'known' branch as mismatch" is unverified by the diff. Re-raised as fresh M-1.

#### r1 M-3 — AC-48a assertion gap → **CLOSED (semantically)**

`test/integration/streaming_terminal_error/ac48a_openai_python_terminal_error.py:99-110` now:
- Tracks `saw_successful_tool_finish` (line 101) — trips if SDK yields `finish_reason="tool_calls"` after the error frame.
- Tracks `saw_dispatchable_tool_call` (line 108) — `json.loads(accumulated)` succeeds AND `call.id` AND `call.function.name` all present.
- Final assertions at lines 116-119.

The r1 logical gap (`endswith("}")` could never trip given the fixture data) is replaced by semantically correct guards. The fixture data still doesn't form complete JSON, so `saw_dispatchable_tool_call` is still hard to trip with the current fixture; but the `saw_successful_tool_finish` assertion is independently meaningful and the guard logic now matches SPEC intent. Acceptable close.

### r1 minor

#### r1 m-1 — `recordClean` early-return → **PARTIALLY ADDRESSED**

`phase4-coordinator/internal/buyer/streaming_downgrade.go:65-76` `recordClean` still early-returns when `downgradeUntil.IsZero()`. However, `isDowngraded` (`:33-51`) was rewritten to prune stale malformed entries on every check, including deleting empty entries from the map. The latent bounded mem-leak is now actively pruned. Functional cleanup confirmed. minor remains open as a naming/readability issue, not severity-bearing.

#### r1 m-2 — Package.swift unhandled-resources warning → **CLOSED**

`phase3-binary/Package.swift:72-74` adds explicit `.copy(...)` declarations for `Fixtures/SPEC015_v03_jcs/null_hash.json`, `non_null_hash.json`, `README.md`. Warning eliminated.

### r1 Open Questions

#### Q-1 — process-restart isolation → **RESOLVED VIA DOCUMENTATION**

`docs/operations/spec-018-v0.2-deploy.md:193-196` explicitly documents: "Per-(buyer, provider) downgrade state lives in-memory in the coordinator process; it does not survive process restart and does not propagate across multi-coordinator deployments. Single-instance Pearl deployment is acceptable for v0.2; multi-instance is v0.3+." This is the right resolution given Pearl is single-instance.

#### Q-2 — Vercel AI SDK pinned to exact `2.0.38` → **UNCHANGED**

`test/integration/streaming_terminal_error/package.json:9` still declares `"@ai-sdk/openai-compatible": "2.0.38"` (exact pin, not `^2.0.38`). Cline upstream still uses `^2.0.38`. The test still exercises the compatibility floor only. Open question remains — see Q-1 below.

#### Q-3 — SPEC-018 self-read path → **PARTIALLY ADDRESSED**

`run_fixture.py:218-223` validate() now asserts at least one `read_file` call against `SPEC-018-agentic-tool-calling.md` succeeds. The synthetic fixture does include the read at `:125`. However, since the fixture itself crashes (see fresh C-1), this is unverifiable until the runtime bug is fixed.

## Fresh findings

### CRITICAL findings

#### C-1 — AC-25a release-gate fixture crashes at runtime with `TypeError` before any validation completes

**Evidence**:

I ran `python3 test/integration/cline_session/run_fixture.py` against `42476b7`:

```
Traceback (most recent call last):
  File ".../run_fixture.py", line 256, in <module>
    raise SystemExit(main())
  File ".../run_fixture.py", line 244, in main
    validate(transcript, config)
  File ".../run_fixture.py", line 224, in validate
    large_write = max(call for call in transcript["tool_calls"] if call["name"] == "write_to_file" and call.get("result", {}).get("bytes_written", 0) >= minimums["write_to_file_bytes"])
TypeError: '>' not supported between instances of 'dict' and 'dict'
```

Root cause: `max()` is called on a generator of dicts without `key=`. Python tries to compare dicts directly when more than one matches. `fixture_config.json` minimums require 30 tool_calls, and `drive_mock_stack` (line 130-131) pads with 65536-byte `write_to_file` calls until length >= 30 — so multiple matches are inevitable.

**Confidence**: HIGH (reproduced locally on commit `42476b7`).

**Why this matters**: AC-25a is the v0.2 Cline release-gate evidence harness. IMPL-NOTES line 19 lists it as the AC-25a IMPL-side closure. The codex Product-Design r2 audit (line 14 of `specs/SPEC-018-v0_2-IMPL-product-design-r2-audit.md`: "`./run-cline-session.sh` — FAIL: Python `TypeError` in AC-25a validation") confirms the same failure. The IMPL-NOTES claim that AC-25a now "drives macprovider stack as separate process (mock-provider mode)" is structurally false — the harness cannot even produce a transcript-validation pass. SPEC AC-25a fail condition: "transcript schema invalid" trivially applies because no transcript is ever validated. No release-gate evidence can be collected with this harness.

**Fix**:

```python
# run_fixture.py:224
large_write = max(
    (call for call in transcript["tool_calls"]
     if call["name"] == "write_to_file"
     and call.get("result", {}).get("bytes_written", 0) >= minimums["write_to_file_bytes"]),
    key=lambda c: c["result"]["bytes_written"],
)
```

And add a CI step that actually runs `run_fixture.py` (the fact this slipped through r1 absorption suggests the harness was never re-executed end-to-end before claiming closure).

### HIGH findings

#### H-1 — AC-44 `t_tool_call_open_detected` timestamp is set at SSE-start time, not at tool-call-open detection

**Evidence**:

- SPEC AC-44 (`specs/SPEC-018-agentic-tool-calling.md:631`): "Provider-side timestamp instrumentation is REQUIRED: `t_tool_call_open_detected` (**provider-internal native opening detected**)..."
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:460-463`:

  ```swift
  writer.startSSE(extraHeaders: [
      ("X-MacProvider-Provider-ToolCallOpen-Unix-Ms", "\(Int64(Date().timeIntervalSince1970 * 1000))"),
      ("X-MacProvider-Provider-Unix-Ms", "\(Int64(Date().timeIntervalSince1970 * 1000))"),
  ])
  sseStarted = true
  var streamedAnyToolCallDelta = false
  let completion = try await modelRuntime.stream(...) { chunk in
      switch chunk {
      case .content(let text): ...
      case .toolCallDelta(let toolDelta):
          streamedAnyToolCallDelta = true
          ...
      }
  }
  ```

  The `Provider-ToolCallOpen-Unix-Ms` header is captured **before** `modelRuntime.stream` is even invoked — before any token has been generated, let alone a tool call detected.

- Result: `t_first_gateway_byte - t_tool_call_open_detected` (SPEC AC-44's measured value) always includes the FULL model generation time before the first tool-call delta. For a 1.5s-per-second-tps generation that emits content first and a tool call last, this metric will report ~all of the model run time as "tool call latency", instead of the moment-of-detection-to-buyer-delivery latency the SPEC measures.

- The SPEC's `p95 ≤ 1500 ms on M4` / `≤ 3000 ms on M2/M3` targets assume the metric measures tool-call-detection latency, not whole-request latency. With the current implementation the metric will almost always be larger than the target on any non-trivial generation, even when the system is operating perfectly.

**Confidence**: HIGH

**Why this matters**: SPEC AC-44 fail condition is "p95 above target after skew correction". The implementation will systematically report values above target because it's measuring whole-generation latency, not the tool-call-open-to-buyer-byte interval. This is functionally equivalent to having no measurement: the operator can't tell from `/metrics/streaming` whether the system is failing the SPEC or whether the metric is mis-implemented. Either reading kills the release-gate utility of AC-44 instrumentation.

**Fix**: Move the `Provider-ToolCallOpen-Unix-Ms` capture out of the SSE-start `extraHeaders` and into the `case .toolCallDelta` branch at line 488. The header MUST be set when the first `.toolCallDelta` chunk arrives, not when the SSE response is opened. Note: SSE headers are committed once `writer.startSSE` is called, so this requires either (a) delaying SSE-start until the first chunk so the header reflects detection time, or (b) emitting the timestamp inline in the SSE event payload (e.g. an additive `usage.macprovider_tool_call_open_detected_ms`) and updating the coordinator to read it from event data rather than header.

#### H-2 — AC-44 NTP skew correction is fake: `X-MacProvider-NTP-Skew-Ms` is hardcoded `"0"` and `X-MacProvider-Gateway-Unix-Ms` is never emitted

**Evidence**:

- `phase5-gateway/internal/router/chat_proxy.go:211`: `upReq.Header.Set("X-MacProvider-NTP-Skew-Ms", "0")`.
- `phase5-gateway/internal/router/chat_proxy.go:361`: `w.Header().Set("X-MacProvider-NTP-Skew-Ms", "0")`.
- Grep across the whole repo for `Gateway-Unix-Ms` (the `streamingTimingGatewayNowHeader` value at `phase4-coordinator/internal/buyer/streaming_timing.go:20`) returns ONLY the constant definition. No phase3/phase4/phase5 production code emits it. The skew-fallback path at `streaming_timing.go:72-80` (`else if providerNowOK && gatewayNowOK`) is dead.
- `observeFromHeaders` (streaming_timing.go:64-71) reads `streamingTimingSkewHeader`, parses "0" → 0ms, falls through `absDuration(skew) > streamingTimingSkewBound` because 0 ≤ 100ms is always true, so no sample is ever discarded for skew.
- `SkewCorrectedForwardLag = firstForwarded.Sub(providerOpen.Add(skew))` with skew=0 means **the metric reports raw (unsoected) provider-gateway delta**, with no skew correction applied.

- SPEC AC-44 (`specs/SPEC-018-agentic-tool-calling.md:631`): "Timing measurements assume NTP-anchored clock skew `|t_provider - t_gateway| ≤ 100 ms` at request start, **verified via heartbeat**."
- Production reality: provider Macs and gateway VPS have unsynchronized clocks (NTP usually within 50-200ms but can drift more under network problems). The metric will silently report negative or inflated `SkewCorrectedForwardLag` values whenever real skew exceeds a few tens of milliseconds.

- `docs/operations/spec-018-v0.2-deploy.md:135-137`:
  ```
  # HELP macprovider_streaming_skew_skipped_total Samples discarded due to NTP skew > 100 ms.
  macprovider_streaming_skew_skipped_total 5
  ```
  In reality this counter will always be 0 (skew is always reported as 0).

**Confidence**: HIGH

**Why this matters**: SPEC AC-44 fail condition: "missing **heartbeat skew verification**, p95 above target after skew correction". No heartbeat skew measurement is implemented; the gateway lies that skew is always 0. Combined with H-1 (wrong timestamp moment), the AC-44 metric reports systematically wrong values with no operator-visible signal that anything is wrong. The deploy doc claim that ">100 ms skew → discarded" is impossible to trigger in production.

**Fix**: Either (a) wire a real NTP-skew measurement: gateway and coordinator each run `chronyd` / `timesyncd` (already in deploy doc) and the gateway emits its actual offset-from-stratum as `NTP-Skew-Ms` (chronyc tracking offset, in ms); OR (b) drop the skew correction and emit raw uncorrected `forward_lag_ms` with a deploy-doc note that the metric is best-effort because NTP-anchored measurement is v0.3. The current "skew=0" is dishonest — it reports a measurement quality that does not exist.

### MEDIUM findings

#### M-1 — AC-46 self-test still silently sanitizes; phantom closure in IMPL-NOTES

(Re-raise of r1 M-2; mechanically verified NOT CLOSED.)

**Evidence**: `validObservedModelHash` (ModelRuntime.swift:795-803) is unchanged in semantics from r1. No warn log on invalid non-nil input. No test in `phase3-binary/Tests/` exercises the "known-but-format-invalid" path (`grep -rn modelHashMismatch` is empty). The r1 absorption commit message claims this was addressed but the code is identical in observable behavior.

**Confidence**: HIGH

**Why this matters**: A provider whose local `model_hash` subsystem returns uppercase hex or a 63/65-char hash (real misconfigurations) silently emits `null` to buyers, which is indistinguishable from "no hash known". SPEC AC-46 specifically calls this out as a release-gate fail condition. The fix is small (5-10 lines: add `s.log.Warn()` and return nil) and the test is small (3-5 lines).

**Fix**: When `validObservedModelHash(nil-able-input)` rejects a non-nil input, emit `runtime.logger.warn` with the offending raw input (truncated) and `reason: "non_hex_or_wrong_length"`. Add a counter or a self-test that asserts the warning fires when fed `"ABCD...64-chars"`.

#### M-2 — Swift 5 Sendable warnings on `streamedAnyToolCallDelta` capture; will be Swift 6 errors

**Evidence**:

- `swift build -Xswiftc -warnings-as-errors` against `42476b7` errors at:
  - `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:489` — `mutation of captured var 'streamedAnyToolCallDelta' in concurrently-executing code`
  - `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:437` — same
  - `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1075` — `capture of 'context' with non-Sendable type 'ChannelHandlerContext' in a '@Sendable' closure`
- Default `swift build` (Swift 5 mode) passes without errors. Swift 6 mode (when enabled) will reject this.

**Confidence**: HIGH

**Why this matters**: Not a correctness bug under current execution model (the actor-method semantic happens to be safe: `modelRuntime.stream` awaits the callback inside the actor context, and the caller reads the flag after `await stream(...)` returns), but it is technical debt that blocks Swift 6 migration. The IMPL-NOTES does not call this out as known. The audit-prompt specifically asked whether the fix is robust vs papering over — answer: papering over (Swift 5 mode forgives, Swift 6 mode wouldn't). v0.3 will need to either wrap in an `Atomic<Bool>` or refactor to actor-isolated state.

**Fix**: Replace `var streamedAnyToolCallDelta = false` with a class-bound mutable reference:

```swift
final class StreamingFlag: @unchecked Sendable { var fired = false }
let toolCallSeen = StreamingFlag()
... { chunk in
    case .toolCallDelta(let toolDelta):
        toolCallSeen.fired = true
        ...
}
if !toolCallSeen.fired, ... { ... fallback ... }
```

Or refactor the callback to return whether it emitted, summing across chunks. Either approach works.

### minor findings

- **m-1** — `containsMacProviderHeader` whitelist (HTTPServerReceiptTests.swift:1087-1102) hardcodes the v0.2 normative header suffix list. If v0.3 adds a new normative header (e.g. `X-MacProvider-Malformed-Tool-Call-Reason`) the test will fail silently as a "receipt leak" until the whitelist is updated. Consider centralizing the normative-header list in a single Swift constant so the test and the production server code can share it. Receipt-leak guard intent itself is preserved by this whitelist — none of the listed suffixes (`streaming-mode`, `provider-toolcallopen-unix-ms`, `provider-unix-ms`, `coordinator-firstforward-unix-ms`, `gateway-firstbyte-unix-ms`, `ntp-skew-ms`) are receipt-bearing, and `x-macprovider-receipt` is still flagged.

### Open Questions

- **Q-1** — Swift `APIError.envelope` hardcodes `inference_ran: false` and `settlement_ran: false` (ChatCompletionRequest.swift:288-289). Used at HTTPServer.swift:543 when `sseStarted=true`, i.e. after inference partially ran. Should the envelope take these as parameters (defaulting to false but overridable for terminal SSE error paths to report `inference_ran: true`)? Go side already does this (server.go:4844 hardcodes `inference_ran: true` for SSE errors). Result: Swift HTTP terminal SSE errors and Go SSE errors report different `inference_ran` values for the same conceptual mid-stream failure. Likely cosmetic for Cline (it acts on `retryable`, not `inference_ran`), but a SPEC-§10d.0-faithful implementation should be consistent.

## Multi-perspective notes

- **Executor**: an operator following the deploy doc will configure NTP, set up the metrics endpoint, and expect to see `samples_total > 0` (now true) and a populated `forward_lag_p95_ms` reading. The reading will be **systematically wrong** (per H-1 + H-2) and the operator has no way to know — the metric name doesn't carry a "raw/uncorrected" or "best-effort" suffix and the deploy doc claims skew-correction is applied.
- **Stakeholder**: the v0.2 release gate is supposed to use AC-25a evidence to demonstrate Cline-on-macprovider works in CI. The harness crashes immediately and the IMPL-NOTES claim of "drives macprovider stack as separate process" is false. No release evidence will be produced from this harness as-is.
- **Skeptic**: the strongest counter to my H-1 / H-2 findings is "this is v0.2 best-effort and the deploy doc explicitly says AC-44 evidence is fragile". Rebuttal: the deploy doc says NTP is required and skew > 100 ms gets discarded — both statements are operationally false in the current implementation. The SPEC AC-44 normative text says fail condition is "missing heartbeat skew verification", and there is no heartbeat skew verification.

## Verdict justification

**FIX REQUIRED** — 1 CRITICAL + 2 HIGH + 2 MEDIUM exceeds the 0/0/0 merge bar.

**Mode**: Started in THOROUGH, escalated to ADVERSARIAL after r1 M-2 was found NOT-CLOSED-despite-claim (phantom closure trigger). Adversarial pass expanded into mechanical AC-44 timestamp-semantics inspection (found H-1 + H-2) and runtime execution of the AC-25a fixture (found C-1).

**Realist Check applied**:
- **C-1 retained at CRITICAL**: AC-25a is the v0.2 Cline release-gate evidence harness. A runtime crash before validation = no evidence can be collected. Realistic worst case: release blocked because no evidence transcript can be produced. Mitigation: trivial 1-line fix (add `key=` to `max()`). But cannot ship as-is.
- **H-1 retained at HIGH**: The SPEC AC-44 p95 target is a release gate. Measuring whole-generation latency instead of tool-call-detection latency will systematically fail the gate. Mitigated by: not a money-path bug; settlement does not depend on AC-44. Detection: immediate, on first `/metrics/streaming` scrape. Still HIGH because release-gate evidence is invalid.
- **H-2 retained at HIGH**: Skew correction is fake. The SPEC normatively requires skew verification. Mitigated by: same as H-1, not a money-path bug. Detection: requires comparing chrony output to reported skew, which an operator wouldn't naturally do. Still HIGH because the deploy doc claims a measurement quality that does not exist (operational dishonesty).
- **M-1 (AC-46) at MEDIUM**: SPEC fail condition not enforceable, but no buyer is currently relying on `model_hash_observed` (v0.2 is observation-only). Mitigated by: v0.2 buyer-visible semantics are presence + null-or-hex, both of which still hold. Real-world impact: a misconfigured provider looks healthy. Acceptable as MEDIUM for v0.2 ship; should not slip to v0.3.
- **M-2 (Sendable warnings) at MEDIUM**: Swift 5 mode forgives; Swift 6 mode would error. No correctness bug today. Acceptable as MEDIUM tech debt.

**Pre-commitment predictions vs actuals**:
- Predicted: r1 absorption may have left Sendable warnings on the new `streamedAnyToolCallDelta` flag (HIT — M-2).
- Predicted: Phantom closures where IMPL-NOTES claims a fix that the diff doesn't actually contain (HIT — M-1 / r1 M-2).
- Predicted: AC-44 timing headers emitted but capturing the wrong moment (HIT — H-1).
- Predicted: HuggingFace SHA-256 pin may not match upstream (MISS — Qwen3 pin verified byte-exact).
- Predicted: HTTPServerSwapTests / HTTPServerReceiptTests broken by StreamChunk refactor (MISS — both pass, receipt-leak guard preserved).

**Bonus uncovered**: AC-25a fixture runtime crash (C-1) — this was NOT in the pre-commitment set. It surfaced when actually running `python3 run_fixture.py` as the audit prompt explicitly suggested ("re-verify by `cd phase3-binary && swift test`" — extended to also exercise the Python fixture). The codex Product-Design lane independently caught the same failure, corroborating the finding.

**To upgrade to READY TO MERGE**:
1. Fix C-1: 1-line `max(..., key=lambda c: c["result"]["bytes_written"])` change to run_fixture.py:224. Add a CI hook that actually runs the fixture so this can't regress.
2. Fix H-1: move ToolCallOpen timestamp capture from SSE-start to first `.toolCallDelta` chunk arrival. Likely requires emitting timestamp in event body rather than header (SSE headers can't be set post-start).
3. Fix H-2: either implement real NTP-skew measurement (chronyc tracking) or rename the metric to make its uncorrected nature explicit and update the deploy doc to stop claiming skew correction is applied.
4. Fix M-1: add `s.log.Warn()` when `validObservedModelHash` rejects a non-nil malformed input. Add a unit test that asserts the warning fires.
5. Address M-2 either by switching to a class-bound flag or accept the warning suppression and document v0.3 cleanup.
