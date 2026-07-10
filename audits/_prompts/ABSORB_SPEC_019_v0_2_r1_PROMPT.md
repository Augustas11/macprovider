# SPEC-019 v0.2.1 — r1 absorption prompt

You are absorbing **r1 audit findings** into `specs/SPEC-019-structured-output.md`,
bumping version `0.2.0 → 0.2.1`. r1 narrative is at
`specs/SPEC-019-v0_2-r1-audit.md`. r1 totals: **1C + 9H + 9M** across 5 lanes;
lane F (Claude narrative) returned READY TO LOCK.

**Constraints — DO NOT VIOLATE:**

- v0.1.5 LOCKED body is **immutable**. All edits land in v0.2 amendment surface
  (§2 AC-V2 subsection, §3 v0.2 amendment, §5 v0.2 streaming validation
  subsection, §6 v0.2 paragraph, §7 v0.2 coordinator amendment, §8 v0.2
  streaming money-path amendment, §9 v0.2 invariants, §10 v0.2 amendment,
  §12 change-log v0.2.1 entry, AC-V2-* ACs).
- No SPEC-015 schema change.
- No SPEC-018 edits.
- No new HTTP endpoint.
- Bump version header AND change-log entry. Both MUST cite v0.2.1 (2026-06-29).

## Resolved design calls (baked in — DO NOT re-litigate)

**T-2 streaming timeout authority: (A) provider idle timeout, N deferred to v0.2.x.**
Bind AC-V2-9 to provider-side idle inactivity (no buyer-visible content delta
emitted for N seconds → upstream generation closed). Reuse existing
`inference_timeout` terminal SSE code. The concrete N value is deferred to a
future v0.2.x (cite SPEC-006 idle semantics as the placeholder source).

**T-3 numeric-bound error code: (α) reuse `json_schema_unsupported_keyword`** with
subreason details in `error.param` (e.g., `response_format.json_schema.schema.properties.X.multipleOf`).
Do NOT add a new code; do not add a new row to the error-code table.

## Absorption items

### Convergent (4 themes — must close all 4)

**T-1: 3-layer money-path streaming validation bridge (1C + 2H)**

Add to §7 v0.2 amendment AND §8 v0.2 streaming money-path subsection:

1. Provider→coordinator WS path: terminal streaming validation failure MUST
   close the WS stream with `inference_response_end.status ∈
   {malformed_json_response, json_schema_validation_failed}`, retryable
   preserved, receipt omitted. Cite
   `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:529` as the
   existing WS allow-list precedent that this requirement leverages.

2. Coordinator SSE writer: terminal v0.2 SSE error frames MUST populate
   `request_id` and `settlement_ran:true`. Cite
   `phase4-coordinator/internal/buyer/server.go:5150-5170` as the writer
   site requiring SPEC-019-specific handling.

3. Gateway SSE state machine: gateway MUST recognize terminal SSE error
   frames carrying `error.code ∈ {malformed_json_response,
   json_schema_validation_failed}` as final structured-output failures and
   forward them verbatim through `[DONE]`, skipping gateway-side positive
   / ok settlement. The gateway MUST NOT remap these frames to
   `stream_malformed` or any other code. Cite
   `phase5-gateway/internal/router/chat_proxy.go:493-531` as the affected
   normalization site.

Add **AC-V2-3a** asserting the 3-layer pass-through: provider WS end-frame
status set, coordinator settlement_ran=true, gateway passes the frame
verbatim. Each layer enforced separately by fixture or unit test.

**T-2: Streaming validation timeout authority (3H + 1M)**

Rewrite AC-V2-9 to:
- Bind the timeout source to provider-side idle inactivity (no buyer-visible
  `content` delta emitted for N seconds; N deferred to v0.2.x per SPEC-006
  idle semantics).
- On idle timeout: provider closes upstream generation, runs end-of-stream
  validation on the buffer-as-of-close, and emits a terminal SSE error
  frame using existing `inference_timeout` code with retryable per
  SPEC-006 semantics.
- Settlement remains `FaultBreakerQualifying` per §8.
- Add fixture / test reference for a stream that hits idle timeout.

**T-3: Numeric-bound value validity (2H + 1M)**

Add to §3 v0.2 amendment, pre-inference rules block:
- `multipleOf` value MUST be a JSON number `> 0` (reject `0`, negative,
  non-number).
- `minimum` / `maximum` values MUST be JSON numbers (reject string, null,
  bool, array, object).
- When both `minimum` and `maximum` are present on the same node,
  `minimum <= maximum` (reject inverted bounds pre-inference).
- All rejects use existing `json_schema_unsupported_keyword` with
  `error.param` pointing at the offending node path (T-3 (α) decision).

Add **AC-V2-10b** asserting these rejects fire at provider AND coordinator
pre-inference for each invalid case.

**T-4: Numeric-bound type-conditional gate (1H + 1M)**

Add **AC-V2-10a** — negative fixture: any of {`minimum`, `maximum`,
`multipleOf`} on a schema node whose `type` is not `number` or `integer`
MUST reject pre-inference at provider AND coordinator with
`json_schema_unsupported_keyword` and `error.param` carrying the JSON
pointer of the offending node. Test fixtures: `string`, `boolean`, `null`,
`array`, `object` nodes carrying a numeric-bound keyword.

### Singular items (7 — must close all)

**S-1: SPEC-019-owned streaming content buffer cap (B-H-1)**

Rewrite §6 v0.2 paragraph:
- Introduce SPEC-019 v0.2 concatenated-`content` byte cap = `2_097_152`
  (matches SPEC-018 cap value but cited as **SPEC-019-defined**, not as
  SPEC-018 reuse).
- Byte domain: post-stop-token-filter buyer-visible content delta
  concatenation (closes E-M-1 byte-domain mismatch in one edit).
- On cap exceeded: provider closes upstream generation, emits terminal SSE
  error frame using existing `inference_response_too_large` code (or
  whatever SPEC-018 catch-all uses — verify against
  `specs/SPEC-018-agentic-tool-calling.md` and reuse that existing code,
  do NOT invent a new one).
- Add AC-V2-9b (or fold into AC-V2-9) asserting cap-exceeded path.

**S-2: Split deleted v0.1 reject codes from active error-code table (B-M-1)**

In the §5 / §7 error-code table at SPEC line ~884:
- Either split into "active v0.2 codes" + "v0.1.x historical / migration"
  subsections,
- OR annotate the two rows (`streaming_json_schema_unsupported`,
  `streaming_json_object_unsupported`) as "v0.1.x-only — deleted in v0.2"
  with strikethrough or explicit text.

Pick whichever is structurally smaller. Bias toward the in-line annotation.

**S-3: AC-V2-5 byte-capture + Cline commit pin (D-H-1)**

Rewrite AC-V2-5:
- Pin the exact Cline upstream commit (or version) AND the `ai` SDK
  package version Cline pins on that commit (not just
  `@ai-sdk/openai-compatible@2.0.38`).
- Invoke the same streaming primitive Cline uses on its active call path
  (verify: `streamObject` vs `streamText` + output via inspection of the
  Cline source).
- Fixture MUST capture the outbound POST body bytes.
- Fixture MUST assert `stream:true` + exact `response_format.json_schema`
  fields in the captured body BEFORE asserting parsed output.

If pinning the exact Cline commit is impractical inside the SPEC text,
defer the commit pin to the fixture README but require the SPEC to name
the version pin as a release acceptance criterion.

**S-4: AC-V2-13 partial-content negative streaming fixture (D-M-1)**

Add **AC-V2-13**: A streaming structured-output request whose final
concatenated buffer fails validation MUST be observable as
{partial content deltas → terminal SSE error frame}. The fixture (Cline
or Vercel preferred) MUST:
- Receive partial content deltas (visible to the buyer's parser),
- Receive a terminal SSE error frame with `error.code ∈
  {malformed_json_response, json_schema_validation_failed}`,
- Assert that final object parsing fails (no partial-success path),
- Document the contract that partial deltas pre-validation are
  provisional, not final.

**S-5: AC-V2-12 captured-body bytes for z.number().int() (D-M-2)**

Amend AC-V2-12 to require the AC-V2-12 fixture to commit the captured
request body containing the actual Vercel/Zod emission for
`z.number().int()`. Expected shape (verify against actual capture):
`{"type":"integer","minimum":-9007199254740991,"maximum":9007199254740991}`
with top-level `$schema` present. No SDK-side rewrite step is permitted in
the fixture pipeline. If the actual capture differs from the expected
shape (which lane D speculated), reflect the actual capture in the SPEC.

**S-6: $schema byte-cap + receipt prompt-hash binding clarification (E-M-2)**

Add to §3 v0.2 amendment AND §9 v0.2 invariant block, one clarifying
sentence (place in both for cold-reader resilience):

> "Top-level `$schema` bytes count toward `json_schema_max_bytes = 16_384`
> and are JCS-canonicalized into the receipt `prompt_hash` per §9.
> '`$schema` is ignored' refers only to validation-time meta-schema
> selection — `$schema` bytes are NOT excluded from cap accounting or
> receipt prompt-hash binding."

**S-7: AC-22a/b composite-render stream:true extension OR AC-V2-14 (A-M-1)**

Amend AC-22a AND AC-22b to run BOTH `stream:false` and `stream:true`
fixtures asserting byte-equivalent system-position composition (schema-
adjusted ChatMessage → ToolPromptRenderer.renderMessages → UserInput).
Single-line amendment; no new AC needed if both can be expanded in place.

If amending AC-22a/b would require touching v0.1.5 LOCKED body text,
instead add **AC-V2-14** as a new v0.2-scoped AC asserting the same
composite-render invariant explicitly for `stream:true + tools +
json_schema`.

### Lane F notes (non-blocking — absorb only if trivial)

- N-1: §12 v0.1.5 lock anchor — OPTIONAL — add a one-line cite of v0.1.5
  PR (`#218` / commit `608ab22`) if it fits cleanly in §12 successor block.
- N-2: glossary subsection — SKIP — self-defining usage is sufficient.
- N-3: AC-V2 namespace clean — no action.
- N-4: breaking-change posture preserved — no action.

## Output requirements

- Edit `specs/SPEC-019-structured-output.md` in-place.
- Bump version header (line 3) and §12 metadata (line 1296) to
  **0.2.1 (2026-06-29, r1-absorption draft for audit)**.
- Add v0.2.1 change-log entry to §12. Summarize convergent themes T-1..T-4
  + singular S-1..S-7 in one paragraph. Cite the audit file
  `specs/SPEC-019-v0_2-r1-audit.md` for traceability.
- Status remains `DRAFT — audit loop pending` (do NOT mark LOCKED).
- DO NOT commit. The audit loop will fire r2 against this draft; absorber
  leaves the working tree dirty.
- Reasoning effort: **low** (mechanical text edits with exact file:line
  targets per item above).
