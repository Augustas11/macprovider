# BUILD SPEC-019 v0.2 — streaming structured output (narrow Cline drop-in)

Draft `specs/SPEC-019-structured-output.md` v0.2.0 as a v0.2 amendment
on top of locked v0.1.5. Same shape and discipline as SPEC-018 v0.2.4
(narrow Cline-drop-in build).

This is the BUILD-direction prompt — write the **v0.2 amendments to
the SPEC body**. A 4-round 6-lane codex+Claude audit loop will follow.

## Context (background, not normative)

SPEC-019 v0.1.5 LOCKED (PR #218 commit `608ab22`) + IMPL shipped
(PR #225 commit `47dc2724`) today. v0.1 unlocked non-streaming
structured output via post-hoc parse + validate.

Cline source as of v0.1.5 SPEC commit `92806c60` does not send
`response_format` on its **streaming** code path. v0.1 was explicit
in §10: "v0.1.0 is NOT a Cline drop-in structured-output release;
Cline structured-output enablement is a v0.2 streaming-validation
deliverable." v0.2 closes that gap.

Already-known facts about the v0.1 IMPL (verified pre-prompt):

- Provider parses `response_format` and rejects `stream:true` + `json_schema`
  with HTTP 400 `streaming_json_schema_unsupported`. Same for
  `json_object`. The 2 reject codes live in
  `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` + the
  coordinator at `phase4-coordinator/internal/buyer/server.go`.
- Provider post-hoc validates at end of non-streaming inference via
  `StrictJSONParser` + `JSONSchemaValidator` (panic-safe depth-bound).
- Family-keyed schema instruction rendering via `StructuredOutputRenderer`
  (Qwen3 + Llama-3.3); composes BEFORE `ToolPromptRenderer.renderMessages`
  per SPEC §4.
- Money-path: post-inference failures land at
  `phase4-coordinator/internal/buyer/billing_recorder.go:181` +
  `phase4-coordinator/internal/billing/formula.go:112` with
  `FaultBreakerQualifying`.
- Receipts: `PromptCanonicalizer.swift:5-16` already JCS-canonicalizes
  `response_format` into prompt hash (no SPEC-015 schema change).
- §3 numeric-bound keywords (`minimum`/`maximum`/`multipleOf`) and
  `$schema` top-level are rejected per v0.1.5 (AC-5
  `json_schema_unsupported_keyword`).
- v0.2 streaming preconditions met by SPEC-018 v0.2: token-incremental
  streaming wire contract stable.

## Resolved design decisions (DO NOT re-litigate)

These are upstream calls. Write the SPEC consistent with them; don't
argue.

1. **Streaming validation = end-of-stream validate, NOT incremental
   partial-JSON-prefix.** v0.2 accepts `stream:true` + `json_schema`
   / `json_object` and emits normal SSE deltas; the validator runs
   AFTER the stream terminates (concatenated content buffer). On
   validation failure, terminal SSE error frame replaces the implicit
   `[DONE]`. Same FaultBreakerQualifying posture as v0.1 non-streaming.
   Partial-JSON-prefix tolerant validation is deferred to a future
   version (acknowledge in §10).

2. **Cline drop-in scope.** v0.2 anchors on Cline's existing
   `streamText` + `response_format: json_schema` shape via
   `@ai-sdk/openai-compatible@2.0.38` with
   `supportsStructuredOutputs:true`. Cline = anchor framework (same
   posture as SPEC-018 v0.2 anchored on Cline).

3. **Subset widening = numeric bounds + `$schema`.** §3 accepts:
   - `minimum`, `maximum`, `multipleOf` on number / integer types
     (no validation behavior change — pre-inference subset check
     only acknowledges them as valid keywords; the validator still
     enforces them as constraints on the model output).
   - `$schema` top-level key (any value accepted; ignored at
     validation time — the IMPL does not select a meta-schema
     based on `$schema`).
   Other keywords (`oneOf`/`anyOf`/`allOf`/`not`/`$ref`/`$defs`/
   `pattern`/`format`/array-length keywords) STILL rejected in v0.2.

4. **Streaming reject codes from v0.1 are deleted.** v0.2 removes
   `streaming_json_schema_unsupported` and `streaming_json_object_unsupported`
   from the buyer-visible error table. v0.1.x → v0.2 buyer migration:
   buyers MAY now send `stream:true` with `response_format`.
   Backward-compat hazard: documented in §1 as a v0.1.5 → v0.2
   BEHAVIOR CHANGE (buyers who relied on the 400 to detect "streaming
   not supported" must now expect 200 streaming responses).

5. **Out-of-scope for v0.2** (per SPEC §10):
   - Transparent gateway `Content-Encoding` decompression (deferred to a
     later v0.2.x or v0.3).
   - Schema warm-cache between requests.
   - Wider schema subset beyond numeric bounds + `$schema`.
   - Partial-JSON-prefix tolerant validation.
   - `oneOf`/`anyOf`/`$ref`/`$defs` (still deferred to v0.3).
   - `strict:false` mode (still deferred to v0.3).

6. **Money-path = `FaultBreakerQualifying` on streaming validation
   failure.** Same posture as v0.1 non-streaming. Buyer-visible:
   terminal SSE error frame; settlement records zero provider-positive
   credits.

7. **Receipts = no SPEC-015 schema change.** Same as v0.1 —
   `PromptCanonicalizer.swift` already canonicalizes `response_format`.

8. **Streaming error envelope = mirror SPEC-018 v0.2 terminal-failure
   shape.** Per SPEC-018 v0.2.4 §10d.4. Streaming structured-output
   validation failure emits the same terminal SSE error frame format
   as a tool-call validation failure.

## SPEC v0.2 required structure (amendments only — not a rewrite)

v0.2 is an AMENDMENT to v0.1.5, NOT a rewrite. Add to the existing
SPEC body without deleting the v0.1.5 LOCKED content. Use the
established change-log pattern + targeted section amendments.

Required edits:

### Document metadata (top of file)

- Bump version: `**Version:** 0.2.0 (2026-06-29, draft for audit)`
- Status: `DRAFT — audit loop pending`

### Change log (§12)

Add v0.2.0 entry above the existing v0.1.5 entry following the
established pattern. Cite resolved decisions. Cite the 4 narrow
deliverables.

### §1 (Buyer-visible contract)

- Add a "**v0.2 streaming**" subsection (or extend existing §1) that
  states:
  - `stream:true` + `response_format: json_schema` is NOW accepted.
  - `stream:true` + `response_format: json_object` is NOW accepted.
  - End-of-stream validation; SSE error frame on fail.
  - v0.1.5 → v0.2 behavior change announcement (buyers who depended
    on the 400 reject must update detection logic).

### §2 (Acceptance criteria)

Add v0.2 ACs under a new category "v0.2 streaming" (or extend the
existing "Streaming reject" category and rename it "Streaming"):

- AC-V2-1: `stream:true` + `json_schema` returns 200 + SSE stream
  with end-of-stream validation.
- AC-V2-2: `stream:true` + `json_object` returns 200 + SSE stream
  with end-of-stream object-or-array validation.
- AC-V2-3: streaming output that fails post-stream validation emits
  terminal SSE error frame matching SPEC-018 v0.2 §10d.4 shape;
  settlement = `FaultBreakerQualifying`.
- AC-V2-4: streaming output where the model emits valid JSON
  matching the schema → buyer sees normal `[DONE]` terminal; no
  error frame.
- AC-V2-5: Cline live-fixture: `@ai-sdk/openai-compatible@2.0.38`
  with `supportsStructuredOutputs:true` against macprovider streaming
  endpoint parses to expected object.
- AC-V2-6: openai-python streaming fixture mirrors AC-15 v0.1 contract
  but with `stream=True`.
- AC-V2-7: streaming token-incremental `content` deltas must equal
  the same content as non-streaming (byte-equivalent concatenation,
  modulo stream chunking).
- AC-V2-8: empty-content streaming (model emits zero tokens) ends as
  terminal SSE error frame with `malformed_json_response`,
  `retryable:false`, actionable buyer message. Same posture as v0.1
  AC-18.
- AC-V2-9: streaming validation timeout — if the buffer never
  completes (e.g., long connection but no `[DONE]`), the stream is
  treated as failed; settlement = `FaultBreakerQualifying`.
- AC-V2-10: numeric bounds (`minimum`/`maximum`/`multipleOf`) MUST be
  accepted in schema; pre-inference reject removed.
- AC-V2-11: `$schema` top-level key MUST be accepted (any value;
  ignored at validation).
- AC-V2-12: Vercel Zod paired fixture with `z.number().int()` (which
  emits `minimum`/`maximum`) is now ACCEPTED end-to-end without
  SDK-side normalization. Was deferred in v0.1 AC-31; v0.2 closes.

### §3 (Schema-subset grammar)

Amend the subset:
- Accept `minimum`, `maximum`, `multipleOf` on number / integer types.
  Pre-inference parse no longer rejects.
- Accept `$schema` top-level key (any value).
- Other keywords (`oneOf`/`anyOf`/etc.) STILL rejected.

### §4 (Family rendering)

No changes for v0.2 — same family-renderer pattern. Streaming uses
the same composite-render rule.

### §5 (Validator behavior)

Add a "**v0.2 streaming validation**" subsection:
- Validator runs at end of stream (when SSE generation produces
  `[DONE]` or terminal). Same code path as v0.1 non-streaming;
  the IMPL just relaxes the `stream:true` reject gate.
- Empty-content + whitespace-only override: same as v0.1, but now
  emits SSE error frame instead of HTTP 502.
- Validator panic catch-all: same as v0.1; panic during end-of-stream
  validation → terminal SSE error frame + FaultBreakerQualifying.

### §6 (Caps)

No changes for v0.2 — same caps. Streaming response cap reuses
SPEC-018 v0.2.4 §9 2 MiB.

### §7 (Coordinator / gateway behavior)

- Streaming pass-through allow-list (SPEC-006 amendment): the gateway
  must pass through SSE error frames for `malformed_json_response`
  and `json_schema_validation_failed` without remapping to
  `api_error/upstream_provider_error`. v0.1 already added the HTTP
  502 codes to the allow-list; v0.2 adds the streaming SSE-error
  frame variant.
- Coordinator: `stream:true` + `response_format` no longer rejects;
  end-of-stream validation runs identically to non-streaming path.
- Streaming auto-downgrade reuses SPEC-018 v0.2.4 §10d.4 per-(buyer,
  provider) attribution.

### §8 (Money path)

Streaming validation failure = `FaultBreakerQualifying`, zero
provider-positive credits. Same code paths.

### §9 (Forward-compat invariants)

Add v0.2 invariants:
- Streaming MAY use end-of-stream validation; future versions MAY
  promote to incremental partial-JSON-prefix tolerant validation
  but MUST NOT regress from end-of-stream validation.
- Numeric bounds + `$schema` keyword acceptance is monotonic — v0.2.x
  MAY widen the accepted-keyword set but MUST NOT remove `minimum`,
  `maximum`, `multipleOf`, or `$schema`.

### §10 (Deferred)

Move "Cline structured-output enablement" + "streaming structured
output" entries OUT of deferred (they're shipping in v0.2). Move
"numeric bounds + `$schema`" out. Keep:
- Transparent gateway `Content-Encoding` decompression → still
  deferred (to v0.2.x or v0.3).
- Schema warm-cache → still deferred.
- Wider schema subset → still deferred.
- `oneOf`/`anyOf`/`$ref`/`$defs` → v0.3.
- `strict:false` → v0.3.
- Auto-retry → v0.3.

### §11 (Open questions / audit hooks)

Audit lanes for v0.2 should probe:
- Whether end-of-stream validation creates a denial-of-service for
  buyers who send `stream:true` + a model that emits 2 MiB of
  unvalidated tokens then fails — the buyer pays for the tokens but
  gets nothing useful. Counter-argument: same posture as v0.1
  non-streaming (buyer pays for the inference, gets an error). Is
  this acceptable for streaming?
- Whether SSE error-frame shape matches SPEC-018 v0.2.4 §10d.4
  exactly, or whether the SPEC-019 streaming error frame needs its
  own dedicated shape.
- Whether `Content-Type` and chunked-transfer-encoding on the SSE
  stream are preserved at the gateway with the new path.
- Whether `[DONE]` is the right terminal marker for both success and
  failure paths.

## Citations to wire in

Every claim about file:line in the SPEC body MUST cite the actual
current file:line on `origin/main` at commit `47dc272` or later.
Grep-verify before citing.

Key paths to cite:

- v0.1 streaming reject sites:
  - `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` (current
    `streaming_json_schema_unsupported` + `streaming_json_object_unsupported`
    reject paths)
  - `phase4-coordinator/internal/buyer/server.go` (current coordinator
    reject path)
- Post-hoc validator entry: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- Streaming response framing: SPEC-018 v0.2.4 §10d.4 (terminal-failure
  envelope shape)
- Existing SDK fixture pattern: `test/integration/spec_019/openai_python_strict_json_schema/`
  and `vercel_ai_sdk_strict_json_schema/`

## Out-of-scope for the drafter

- DO NOT modify any file other than `specs/SPEC-019-structured-output.md`.
- DO NOT write IMPL code. This is the SPEC v0.2 draft only; IMPL is a
  separate PR after lock.
- DO NOT change v0.1.5 LOCKED content; ONLY ADD v0.2 amendments per
  the change-log convention.
- DO NOT change SPEC-018. SPEC-019 cites SPEC-018 streaming patterns;
  it does not amend them.

## Style requirements

- Match SPEC-018 v0.2.4's amendment shape: change-log entry at top
  describes deltas; targeted section additions; no v0.1.5 deletion.
- All caps acronyms: HTTP, JSON, SSE, SDK, UTF-8, JCS.
- No emoji.
- No "we" / "you" — use "the provider", "the coordinator", "the buyer".
- ACs numbered AC-V2-N (or extend the existing AC numbering past 34;
  drafter chooses — pick one and be consistent).
- Cite resolved-decision-list ambiguities and document the call in
  the SPEC body.

## Stop condition

Write the v0.2 amendments to `specs/SPEC-019-structured-output.md`.
Verify every cited file:line by reading the actual file. Report:

1. Resulting line count.
2. New AC count + numbering convention used.
3. List of citations actually verified.
4. Any resolved-decision ambiguities you noticed and resolved in-SPEC.

After your draft lands, the audit loop fires: 4 codex lanes
(architect, code, security, product-design) + Claude critic + Claude
narrative. Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes
before SPEC v0.2.0 LOCKS.
