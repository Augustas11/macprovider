# SPEC-019 v0.1.5 IMPL round-1 audit — narrative

Round-1 audit of SPEC-019 v0.1.5 IMPL at HEAD `1a6e00f` on branch
`impl/spec-019-v0-1`.

## Aggregate tally

| Lane | C | H | M | m | Q | Verdict |
|---|---|---|---|---|---|---|
| codex architect | 1 | 0 | 0 | 0 | 0 | FIX REQUIRED |
| codex code | 0 | 1 | 1 | 2 | 0 | REQUEST CHANGES |
| codex security | 0 | 2 | 0 | 0 | 0 | NOT READY |
| codex product-design | 0 | 1 | 1 | 0 | 0 | NOT READY |
| claude critic | 1 | 2 | 3 | 1 | 2 | FIX REQUIRED |
| claude narrative | 0 | 1 | 3 | 1 | 1 | FIX REQUIRED |
| **r1 IMPL TOTAL** | **2** | **7** | **8** | **4** | **3** | **FIX REQUIRED** |

## The 2 CRITICALs (one root cause, two layers)

| Convergent | Layer | Finding |
|---|---|---|
| **architect C-1 + security H-2 + critic C-1 (HTTP path)** | coordinator HTTP `spec001EndStatus` allow-list at `server.go:4915-4922` | Only 4 legacy codes (`error_model_not_loaded`, etc.). New SPEC-019 codes collapse → generic `provider_error` + `FaultNone` (not `FaultBreakerQualifying`). **Money-path leak.** |
| **critic C-1 (WS path)** | provider WS `errorEndFrame` at `InferenceRelay.swift:529-548` | Same legacy-only allow-list one hop earlier. New SPEC-019 codes never make it across the provider→coordinator WS frame. |

These are the same architectural pattern: legacy error-code allow-lists that didn't get extended when SPEC-019 introduced 2 new buyer-visible codes (`malformed_json_response`, `json_schema_validation_failed`). Gateway exclusion was added correctly; coordinator + WS-hop were not.

## Convergent HIGHs (multi-lane hits)

- **StrictJSONParser unbounded recursion** (security H-1 + code H-1 + critic H-1 = 3 lanes):
  - `StrictJSONParser.parseValue/parseObject/parseArray` recurse with no depth parameter
  - Deeply nested model output overflows stack BEFORE depth check fires
  - Swift `do/catch` can't recover from stack overflow / `fatalError`
  - **SPEC §5 catch-all gap** — money-path posture not held
- **Whitespace-only `Content-Encoding` accepted** (critic + code M-1 = 2 lanes):
  - All 3 layers accept `Content-Encoding: "   "` (empty after trim)
  - SPEC AC-28a says reject empty-after-trim
  - Gateway test `:5-16` explicitly locks the wrong behavior
- **PD-H1: streaming-reject envelope at gateway** — gateway may remap coordinator's AC-20 envelope (need to verify)
- **Narrative H-1: StrictJSONParser missing rationale** — 241-line new parser, no module-level "why does this exist"

## Single-lane substantive

- Critic H-2: `Content-Encoding` whitespace-strip parity drift (Swift strips Unicode whitespace incl. NBSP; Go strips only ASCII)
- Code M-1: enumerated coverage gap (Swift tests 7 of 14 rejected keywords; Go tests 1)
- Code L1/L2: rejected-keyword + name-regex coverage asymmetry between Swift/Go test suites
- Narrative M-1: Vercel fixture README missing `supportsStructuredOutputs:true` requirement
- Narrative M-2: provider commit `7b2a272` missing AC anchors
- Narrative M-3: StructuredOutputRenderer.swift missing module comment
- PD M-1: `json_object` breaking-change error copy doesn't tell prose buyers to use omitted `response_format` / `{"type":"text"}`
- Critic M-3: Swift `1.0` for integer schema vs Go reject — drift on `const`/`enum` integer type
- Critic M-4: whitespace-only completion edge case (SPEC silent)

## What's passing (cite for confidence)

Security lane found 6 explicit PASS items worth noting:
- Prompt-injection rendering (escaped JSON encoding)
- NFC/NFD byte comparison (uses raw UTF-8)
- Name validation no-ReDoS (direct byte loop, not regex)
- Coordinator/provider name parity (byte-identical at impl level)
- Content-Encoding parity (all 3 layers normalized identically)
- Schema-validator DoS bounded at parse time

Code lane found 6 explicit PASS items:
- Schema-subset reject list (allow-list pattern catches everything)
- Schema-depth algorithm (Swift + Go byte-identical)
- Byte-cap algorithm (raw bytes, not post-parse serialization)
- Name regex parity (byte loop, not regex)
- Error envelope coverage (11-code spot check)
- Empty-content `retryable:false` override correct

## Recommendation

Absorb r1 into a single commit. Two CRITICALs + 7 HIGHs to close before
re-fire. Tight absorption prompt to follow with explicit decisions
for: (a) InferenceRelay scope, (b) depth-bound vs iterative parser.

After absorption, fire r2 — same 6 lanes, defensive lens.
