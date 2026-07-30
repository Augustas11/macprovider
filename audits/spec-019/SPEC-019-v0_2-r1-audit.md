# SPEC-019 v0.2.0 — Round 1 audit narrative

**Anchor:** `spec/019-v0-2-streaming` @ `832ca07`
**Audited SPEC:** `specs/SPEC-019-structured-output.md` v0.2.0 (DRAFT)
**Round:** r1
**Lanes:** 4 codex (architect, code, security, product-design) + 2 Claude blind-spot (critic, narrative)

## Per-lane verdicts

| Lane | Verdict | C | H | M | Notes |
|---|---|---|---|---|---|
| A architect (codex) | NEEDS REVISION | 0 | 1 | 2 | WS bridge, render-order fixture, numeric-bound type gate |
| B code (codex) | NEEDS REVISION | 0 | 3 | 2 | Content buffer cap, timeout owner, coord SSE writer settlement |
| C security (codex) | NEEDS REVISION | 1 | 2 | 0 | Gateway SSE state machine re-normalization, timeout, multipleOf |
| D product-design (codex) | NEEDS REVISION | 0 | 1 | 2 | Cline live fixture byte-capture, partial content UX, z.number().int() body |
| E critic (Claude) | NEEDS REVISION | 0 | 2 | 3 | multipleOf:0/inverted bounds, type-conditional gate, byte-domain mismatch, $schema cap+hash, timeout source |
| F narrative (Claude) | READY TO LOCK | 0 | 0 | 0 | 4 non-blocking Notes |

**Totals: 1 CRITICAL, 9 HIGH, 9 MEDIUM** across 5 lanes; F clean.

## Convergent themes (3+ lanes)

### T-1: Streaming validation failure money-path 3-layer bridge (1C + 2H)

Lanes: A-H-1, B-H-3, C-C-1.

v0.2 amendment requires `FaultBreakerQualifying` on streaming validation
failure but does not normatively pin the three layers the v0.1 IMPL needed:

1. **Provider→coordinator WS end-frame status** must close with
   `inference_response_end.status ∈ {malformed_json_response,
   json_schema_validation_failed}`, retryable preserved, receipt omitted.
   IMPL anchor: `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:529`.

2. **Coordinator SSE writer** must populate `request_id` and `settlement_ran:true`
   on terminal v0.2 error frames. IMPL anchor: `phase4-coordinator/internal/buyer/server.go:5150-5170`.

3. **Gateway SSE state machine** must recognize the two terminal error codes
   as final structured-output failures and forward verbatim through `[DONE]`,
   skipping gateway-side positive/ok settlement (current code at
   `phase5-gateway/internal/router/chat_proxy.go:493/531/625` would emit
   `stream_malformed` and/or double-settle).

**Severity escalation rationale:** convergent across 3 lanes including
security-lane CRITICAL. v0.1 IMPL audit required 3 layers of explicit
billing-classification fixes (C-1 from lane C names the gateway hop
explicitly). Treat as one CRITICAL absorption item with three sub-edits.

### T-2: Streaming validation timeout authority (3H + 1M)

Lanes: A-H-1 (overlap), B-H-2, C-H-1, E-M-3.

AC-V2-9 names the failure ("fail closed", `FaultBreakerQualifying`) but
does not bind:

- Timeout source (provider generation inactivity, coord WS deadline, gateway
  upstream-read timeout).
- Wire error code on the terminal SSE frame.
- Whether the timeout is wall-clock, idle, or generation-token-rate based.

**Resolution choice for absorption:** pin to provider-side idle timeout
(no buyer-visible content delta for N seconds → close upstream generation,
run end-of-stream validation on whatever buffer exists, emit terminal SSE
error frame from §5 catch-all with a new specific code
`streaming_validation_timeout` or reuse existing `inference_timeout`).
Defer N value to v0.2.x with a placeholder default citing existing
SPEC-006 idle semantics.

### T-3: Numeric-bound value validity (2H + 1M)

Lanes: C-H-2, E-H-1, B-M-2.

§3 v0.2 amendment lifts `minimum`/`maximum`/`multipleOf` from the reject
list but does not constrain operand values:

- `multipleOf: 0` (division by zero in naive validators)
- `multipleOf` negative
- Non-number operand (e.g., `multipleOf: "x"`, `multipleOf: null`)
- Inverted bounds (`minimum > maximum`)

**Money-path DoS surface (E-H-1):** with §5 panic catch-all = terminal
502 + `FaultBreakerQualifying`, a buyer with a `multipleOf:0` schema
repeatedly burns provider compute and forces FaultBreakerQualifying every
request. v0.1.5 LOCKED body did not have this surface; v0.2 introduces it.

**Resolution:** add §3 v0.2 pre-inference rules:
- `multipleOf` MUST be a JSON number `> 0`.
- `minimum`/`maximum` MUST be JSON numbers.
- When both present, `minimum <= maximum`.
- All reject pre-inference with `json_schema_unsupported_keyword` (or new
  `json_schema_invalid_numeric_bound`).
- Add AC asserting all rejects fire at provider AND coordinator
  pre-inference.

### T-4: Numeric-bound type-conditional gate (1M + 1H)

Lanes: A-M-2, E-H-2.

§3 v0.2 narrative says "only on `number`/`integer` nodes" but AC-V2-10
asserts only the removal-from-reject-list. An IMPL that adds three names
to a global allow-list passes AC-V2-10 while silently accepting
`{"type":"string","minimum":1}` — a coordinator/provider parity hole.

**Resolution:** add AC-V2-10a — negative fixture: any of
{`minimum`,`maximum`,`multipleOf`} on a node whose `type ∉
{number,integer}` MUST reject pre-inference at provider AND coordinator
with `json_schema_unsupported_keyword` and the JSON pointer of the
offending node.

## Singular findings (1 lane)

### S-1: Streaming content buffer cap (B-H-1)

§6 cites SPEC-018's `2_097_152` cap, but that cap is for final
`tool_calls[].function.arguments`, not assistant `content` deltas. No
content-buffer cap actually exists in SPEC-018 for SPEC-019 to reuse.

**Resolution:** introduce a SPEC-019 v0.2 concatenated-`content` byte cap.
Numeric value `2_097_152` is fine (parity), but cite as SPEC-019-defined
in §6, not SPEC-018. State the byte domain explicitly (post-stop-token-
filter buyer-visible delta concatenation) to also close E-M-1. Specify
terminal SSE code on cap exceeded (`streaming_content_byte_cap_exceeded`
or reuse existing).

### S-2: Deleted v0.1 reject codes still in unversioned error table (B-M-1)

§5/§7 error-code table at line 884 still lists
`streaming_json_schema_unsupported` + `streaming_json_object_unsupported`,
contradicting the v0.2 deletion claim.

**Resolution:** split the table into an "active v0.2 codes" table and a
"v0.1.x historical / migration" subsection; or annotate the two rows as
"v0.1.x-only — deleted in v0.2".

### S-3: AC-V2-5 Cline live fixture under-specified (D-H-1)

AC-V2-5 pins `@ai-sdk/openai-compatible@2.0.38` but doesn't pin the Cline
commit / `ai` package version / call path (`streamObject` vs `streamText`
+ output). Could pass with a non-Cline helper.

**Resolution:** AC-V2-5 must:
- Pin the exact Cline commit + the `ai` SDK package version Cline pins.
- Invoke the same streaming primitive Cline uses on its active call path.
- Capture the outbound POST body bytes.
- Assert `stream:true` + exact `response_format.json_schema` fields
  before asserting parsed output.

### S-4: Partial-content UX during pre-validation streaming (D-M-1)

Buyers observe partial assistant content deltas before learning the
result is invalid. No AC states partial content is provisional / must
be discarded.

**Resolution:** add AC-V2-13 (negative streaming fixture) — Cline + Vercel
emit partial content, then terminal `malformed_json_response` /
`json_schema_validation_failed`; final object parsing must fail with
guidance that partial deltas are non-final.

### S-5: AC-V2-12 needs captured-body bytes (D-M-2)

`z.number().int()` acceptance claim lacks captured-body fixture proving
the emitted schema shape (integer + safe-integer min/max + top-level
`$schema`).

**Resolution:** AC-V2-12 fixture MUST commit the captured request body
containing `age: {"type":"integer","minimum":-9007199254740991,
"maximum":9007199254740991}` plus top-level `$schema`, with no SDK-side
rewrite.

### S-6: `$schema` byte-cap + receipt prompt-hash binding silence (E-M-2)

`$schema` "accepted with any JSON value and ignored" is misleading —
ignored only for meta-schema selection, but bytes count toward the 16
KiB cap and JCS-bind into receipt `prompt_hash`.

**Resolution:** add a clarifying sentence at §3 or §9 v0.2 invariant block:
"Top-level `$schema` bytes count toward `json_schema_max_bytes = 16_384`
and are JCS-canonicalized into receipt `prompt_hash` per §9; 'ignored'
refers only to validation-time meta-schema selection."

### S-7: AC-V2-1/22 composite render fixture (A-M-1)

§4 says streaming uses the same schema-adjusted `ChatMessage` →
`ToolPromptRenderer.renderMessages` → `UserInput` order, but no AC
asserts `stream:true + tools + json_schema` byte-equivalent composition.

**Resolution:** amend AC-22a/b to run both `stream:false` AND
`stream:true`, OR add AC-V2-14 fixture proving byte-equivalent system-
position composition for the streaming path.

## Citation drift

None detected (Lane E spot-checked 6 IMPL citations + the
`47dc2724` lock anchor — all accurate against worktree HEAD).

## Lane F (READY TO LOCK) summary

4 non-blocking Notes:
- §12 doesn't pin v0.1.5 LOCKED commit anchor (implicit via change log)
- New streaming terms not in dedicated glossary (self-defining in §1)
- AC-V2 namespace clean, collision-free
- Breaking-change posture preserved on both axes

## Round-1 absorption plan

**r1 absorption target version:** v0.2.1

**Convergent absorption (4 themes):**
- T-1: 3-layer money-path streaming validation bridge — add to §7/§8 + AC-V2-3 subcase + AC-V2-3a (gateway pass-through)
- T-2: Streaming timeout authority — bind AC-V2-9 to provider idle timeout + define terminal SSE code
- T-3: Numeric-bound value validity — §3 v0.2 pre-inference rules + AC
- T-4: Numeric-bound type-conditional gate — AC-V2-10a

**Singular absorption (7 items):**
- S-1: Content buffer cap (§6 v0.2 paragraph + close E-M-1 byte-domain)
- S-2: Split error-code table (active v0.2 vs v0.1.x historical)
- S-3: AC-V2-5 byte-capture + Cline commit pin
- S-4: AC-V2-13 partial-content negative fixture
- S-5: AC-V2-12 captured-body bytes
- S-6: `$schema` cap + prompt-hash clarifying sentence
- S-7: AC-22a/b stream:true extension OR AC-V2-14 composite-render

**Lock convention:** 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes.

**Per-lane round files (this directory):**
- `specs/SPEC-019-v0_2-architect-r1-audit.md` (codex artifact 07:27:13)
- `specs/SPEC-019-v0_2-code-r1-audit.md` (codex artifact 07:27:41)
- `specs/SPEC-019-v0_2-security-r1-audit.md` (codex artifact 07:26:44)
- `specs/SPEC-019-v0_2-product-design-r1-audit.md` (codex artifact 07:29:50)
- `specs/SPEC-019-v0_2-critic-r1-audit.md` (Claude critic agent)
- `specs/SPEC-019-v0_2-narrative-r1-audit.md` (Claude narrative agent)
