# SPEC-019 v0.2.0 — Round 1 audit prompt (per-lane)

You are auditing **SPEC-019 v0.2.0 (2026-06-29, DRAFT)** — a v0.2 amendment
on top of the LOCKED v0.1.5 body. The amendment covers four narrow
deliverables for a Cline drop-in structured-output streaming build:

1. **Streaming structured output** (`stream:true` + `json_schema` / `json_object`)
   with **end-of-stream validation** over concatenated `content` deltas
   (NOT partial-JSON-prefix per chunk).
2. **Terminal streaming validation failures** reuse SPEC-018 v0.2.4 §10d.4
   SSE error frames and settle **FaultBreakerQualifying**.
3. **§3 schema-subset widening**: `minimum`, `maximum`, `multipleOf` on
   `number` / `integer` nodes + top-level `$schema` acceptance (and
   `$schema` removed from reject list). `oneOf`/`anyOf`/`$ref`/`$defs`
   remain deferred.
4. **SDK fixtures expand to streaming**: Cline (`@ai-sdk/openai-compatible@2.0.38`
   with `supportsStructuredOutputs:true`), Vercel AI SDK with
   `z.number().int()` without normalization, openai-python streaming.

**The v0.1 streaming reject codes** (`streaming_json_schema_unsupported`,
`streaming_json_object_unsupported`) are **DELETED** from the active v0.2
buyer-visible error table.

**No SPEC-015 change. No SPEC-018 edits. No new HTTP endpoint.**

## Anchors (read these first)

- **SPEC under audit**: `specs/SPEC-019-structured-output.md` at HEAD of
  `spec/019-v0-2-streaming` (commit `832ca07`). Read §§1–12 + change log
  v0.2.0 entry.
- **Locked precondition v0.1.5**: same file, but treat the v0.1.5 body
  as IMMUTABLE — do not propose v0.1.5 changes. Only v0.2.0 amendment
  text is in scope.
- **SPEC-018 v0.2.4 LOCKED**: `specs/SPEC-018-agentic-tool-calling.md`
  — §10d.4 (SSE error frame minimum envelope) is the parent contract
  for AC-V2-3 reuse.
- **SPEC-015 LOCKED**: `specs/SPEC-015-receipts-and-billing.md` — the
  v0.2 amendment claims "no schema change". Verify.
- **IMPL anchors**:
  - `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift` (WS error frame allow-list)
  - `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift` (subset + reject-list)
  - `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift` (depth-bounded parser)
  - `phase4-coordinator/internal/buyer/server.go` (mirror validator + FaultBreakerQualifying)
  - `phase5-gateway/internal/router/chat_proxy.go` (Content-Encoding gate + pass-through)
  - `phase3-binary/Sources/MacProviderCore/PromptCanonicalizer.swift` (prompt-hash binding)

## Lane-specific focus

Pick ONE lane based on the agent firing this prompt. Each lane returns
**0/0/0 OR finds CRITICAL/HIGH/MEDIUM**.

### Lane A — Codex architect

- Cross-spec consistency: does the v0.2 amendment respect §3, §4, §5
  invariants from v0.1.5? Where does v0.2 surface new invariant violations?
- Composite render order under streaming: SPEC §4 says "schema-adjusted
  ChatMessage → ToolPromptRenderer.renderMessages → UserInput". Does v0.2
  preserve this for the streaming path? Does the AC-V2 set say so explicitly?
- FaultBreakerQualifying coverage on streaming validation failure: does
  v0.2 hit the 3-layer money-path (HTTP, WS frame, WS billing
  classification) the v0.1 IMPL needed?
- Versioning monotonicity: does §9 "schema-keyword monotonicity" cover the
  v0.2 widening claim cleanly, or does the v0.2 amendment break v0.1
  forward-compat contract?
- Numeric-bounds keyword scope: is the allow-list "only on type:number /
  type:integer nodes" structurally enforced by the reject-list AC set, or
  is there a gap where the keyword could appear on a non-numeric node?
- `$schema` semantics: "accepted with any JSON value and ignored for
  validation-time meta-schema selection". Does v0.2 specify what byte
  inclusion does to JCS / prompt-hash / receipts? Is it documented?

### Lane B — Codex code

- AC-V2-1..12 wire-level fidelity: are the SSE frame fields exactly
  reusable from SPEC-018 v0.2.4 §10d.4? Any drift?
- End-of-stream buffer ownership: who concatenates content deltas — the
  provider, the coordinator, or the gateway? Does the AC text pick a
  single layer, or leave it ambiguous?
- Streaming timeout (AC-V2-9): what is the timeout source — provider
  inactivity, coordinator ack timeout, gateway upstream timeout? Is the
  error code well-defined and aligned with existing SPEC-001/SPEC-006
  timeout semantics?
- Empty-stream / zero-token fixture (AC-V2-8): which existing error code
  does it reuse? `empty_content_response`? Does it preserve `retryable:false`
  from v0.1 §7?
- v0.1 streaming reject codes deletion: the deleted codes are no longer
  documented. What happens to the legacy clients sending v0.1.0 expectations?
  Is there a migration note in §10 / §1?
- `$schema` byte-inclusion vs validation-ignore: §5 / §6 byte cap covers
  the raw schema bytes. Does `$schema` count toward the 16 KiB cap? Spec
  silent → flag MEDIUM at minimum.
- Cite `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift`
  lines that would need to change to lift the `minimum`/`maximum`/
  `multipleOf`/`$schema` rejects — is the amendment surgical or does it
  imply a broader subset rewrite?

### Lane C — Codex security

- Streaming validation as a DoS vector: AC-V2-9 timeout. Can a buyer
  open many streams that never terminate, holding provider buffers for
  large schemas? Is there a streaming-content byte cap? Spec silent →
  flag.
- Schema-subset widening attack surface: `minimum`/`maximum`/`multipleOf`
  acceptance. Can crafted numeric bounds cause a validation panic in the
  IMPL StrictJSONParser? Are bounds bounded themselves (e.g.,
  `multipleOf: 0` rejection)?
- `$schema` URL fetching: top-level `$schema` accepted "and ignored for
  validation-time meta-schema selection". Is "ignored" load-bearing here?
  Any chance an IMPL fetches the `$schema` URL? Spec must forbid.
- Money-path posture parity: streaming validation failure must end at
  `FaultBreakerQualifying` + zero provider-positive credits, same as v0.1
  non-streaming path. Does AC-V2-3 + §8 explicitly say "FaultBreakerQualifying
  on streaming validation failure"?
- Double-settlement under streaming error frame: gateway sees terminal
  SSE error frame + then expects normal `[DONE]` — can the gateway
  double-settle? Is double-settlement prevention extended to streaming
  validation codes?

### Lane D — Codex product-design

- Cline drop-in semantics: with `supportsStructuredOutputs:true` in
  `@ai-sdk/openai-compatible@2.0.38`, what is the actual wire shape?
  Does AC-V2-5 fixture capture it byte-for-byte?
- openai-python streaming SDK behavior: does the SDK collect deltas
  into `chunk.choices[0].delta.content`? Does the fixture in AC-V2-6
  match the actual library behavior, or does it imagine a different
  shape?
- Buyer-error UX: validation failure mid-stream — does the buyer see
  partial valid SSE deltas + terminal error, or does the buyer see a
  clean error? AC-V2-3 says terminal SSE error frame, but does it pair
  with AC-15 / AC-16 to ensure no confusing partial assistant content?
- Migration UX for v0.1.0 callers of the deleted reject codes: any v0.1.0
  documentation that referenced the codes? Release-note migration step
  documented?
- Vercel Zod `z.number().int()` round-trip claim (AC-V2-12): the v0.1
  workaround was `$schema` strip + Zod normalization. v0.2 promises no
  normalization. Does AC-V2-12 cover the integer-as-number-with-multipleOf-1
  equivalence? Or the explicit `{"type":"integer"}` shape? What does
  `@ai-sdk/openai-compatible@2.0.38` actually emit for `z.number().int()`?

### Lane E — Claude critic (blind-spot adversarial)

- Hostile read of the v0.2 amendment: what assumption could be invalid?
  What hidden contradiction with v0.1.5 LOCKED? What citation drift
  (file:line) — pick 3 file:line citations in the v0.2 text and verify
  them against the IMPL source.
- What does the amendment *claim* without specifying *how*? Look for
  "MUST" / "SHALL" verbs whose subject is unclear, or where the verb
  binds the provider but the IMPL site is in the coordinator.
- Defer-list quality: are any items in the v0.2.0 deferred list things
  that could break v0.2.0's stated guarantees if the buyer used them
  anyway?
- Streaming validation buffer cap: should v0.2 cap the concatenated
  content byte size at validation time? If unbounded, what's the DoS
  posture?
- Numeric `multipleOf: 0` (a JSON Schema invalid value). Does the
  amendment specify what to do? Default JSON Schema says invalid; v0.2
  needs to pick a behavior.

### Lane F — Claude narrative (blind-spot continuity)

- Read v0.1.5 LOCKED → v0.2.0 DRAFT change log: does the narrative
  hand-off make sense? Could a reader cold-read the v0.2 amendment and
  understand it without knowing v0.1.5?
- Buyer-facing "what changed since v0.1" narrative: §1 + change log + §10
  amendment. Is the breaking-change posture clear? Is the v0.1
  `json_object` enforcement breaking-change still preserved?
- Internal terminology consistency: does v0.2 introduce any new term
  ("end-of-stream validation", "concatenated content", "buffer") that
  needs a definition section? Is the term used consistently across
  AC-V2-1..12 + §5 + §7 + §8?
- AC numbering hygiene: AC-V2-1..12 vs AC-1..34 from v0.1. Is the
  prefix `V2-` chosen carefully, or does it collide with the existing
  v0.1 AC namespace?
- Successor/precursor block (§12 doc metadata): does it cite SPEC-018
  v0.2.4 LOCKED accurately? Does §12 cite the v0.1.5 lock anchor for
  traceability?

## Output format (per-lane)

Return EXACTLY this format, no preamble:

```
# SPEC-019 v0.2.0 r1 audit — lane <X>

## Verdict

<one of: READY TO LOCK | NEEDS REVISION>

## CRITICAL (N)

- **[C-1]** <single-line title>
  - file:line citation
  - what's wrong
  - why CRITICAL (money path / security / lock blocker)
  - precise fix or path to fix

## HIGH (N)

- **[H-1]** <title>
  - ...

## MEDIUM (N)

- **[M-1]** <title>
  - ...

## Notes (N) [optional]

- minor / Qs / observations
```

**Bar to return READY TO LOCK**: 0 CRITICAL + 0 HIGH + 0 MEDIUM.
Notes are fine but not blocking.

**Do NOT** edit files. Do NOT propose net-new v0.3+ scope. Do NOT propose
v0.1.5 LOCKED body changes. Constrain to the v0.2.0 amendment surface.

**Read SPEC-019 v0.2.0 SPEC under audit at**:
`specs/SPEC-019-structured-output.md` (worktree HEAD `832ca07`).
