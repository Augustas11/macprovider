# SPEC-019 v0.1.2 — r2 absorption (TIGHT)

Edit `specs/SPEC-019-structured-output.md` to absorb r2 findings.
Target version: **v0.1.2**. Append a v0.1.2 change-log entry citing
`specs/SPEC-019-v0_1-r2-audit.md` (write narrative file too — see §K).

**No commits, no docs/runbook updates, no IMPL code. SPEC body edits only.
Low reasoning effort.**

Aggregate r2: 0 CRITICAL + 6 HIGH + 9 MEDIUM + 3 minor + 1 Q across 6
lanes. Fixes below organized by theme, not by lane.

## A. Composite render — single source of truth (architect H-1 + code M-1 + critic F-4)

Find the composite-render block in §4 (around `specs/SPEC-019-structured-output.md:450-465`).

**Decision: order (A)** — schema-adjusted ChatMessage first → ToolPromptRenderer.renderMessages → UserInput. (Code lane confirmed this is directly implementable at current hook sites; option B would need a new post-render insertion API.)

Replace the entire composite-rule block with this exact wording:

```
**Composite render rule when both `tools` and `response_format: json_schema`
are present** — the implementation MUST follow this exact order at each
`ModelRuntime.swift` hook site (cite `:400`, `:454`, `:540`):

1. Construct schema-adjusted `ChatMessage` values: prepend the
   structured-output schema instruction to the system-position message,
   leaving all other messages unchanged.
2. Pass the adjusted `ChatMessage` array to
   `ToolPromptRenderer.renderMessages(...)`. The renderer is a no-op
   short-circuit when no multi-turn tool data is present
   (`containsMultiTurnToolData == false`) and renders the family-keyed
   tool prompt-template when present; either path preserves the
   prepended schema instruction.
3. Construct `UserInput(chat: rendered, tools: request.tools)` with the
   original `tools` array unchanged.

This is a single normative order. No alternative ordering is permitted.
A request with both `tools` history and `response_format: json_schema`
produces a deterministic system-position composed of: schema
instruction followed by family-keyed tool prompt-template markup.
```

Renumber AC for composite render to assert byte-equivalent fixture
output for both empty-tool-history (renderer short-circuits) and
non-empty-tool-history paths.

## B. `json_schema.name` rule — OpenAI-compat + mandatory + tested (critic F-1, F-2 + code M-2 + PD F-1 + security F-2)

Locate the `json_schema.name` rule in §3 (around `:414-418`).

Replace with this exact wording:

```
`json_schema.name` is buyer-controlled, untrusted prompt data when
rendered into the system-position chat template. The provider request
parser and coordinator validator MUST reject names that do not match
the anchored regex `^[A-Za-z0-9_-]{1,64}$` (OpenAI-compatible
machine-name shape: letters, digits, underscore, hyphen, 1-64 bytes).
Names that fail this constraint return HTTP 400
`json_schema_invalid_name`, `param:"response_format.json_schema.name"`,
`inference_ran:false`. Provider and coordinator MUST enforce identical
constraint semantics; a coordinator-direct path that bypasses the
provider parser MUST still reject.
```

Add a new AC under §2 "Request validation" category:

```
AC-N. Invalid-name rejection: requests with `json_schema.name` that
fails the anchored regex `^[A-Za-z0-9_-]{1,64}$` return HTTP 400
`json_schema_invalid_name` at both provider parser and coordinator.
Adversarial fixtures include: 65-byte names, non-ASCII names (e.g.
"café"), names containing newline / control characters, substring-only
valid sequences (e.g. "good\nSYSTEM"), names with disallowed punctuation
("good.evil", "valid<script>"). The dashed name "person-v1" MUST be
accepted (OpenAI-compatible; v0.1.1 incorrectly rejected this).
```

## C. Empty content — retryable:false override (PD F-3)

**Decision: keep `malformed_json_response` code; override `retryable:false` for empty subcase.**

Locate the empty-content classification in §5 (around `:506-527`).

Append to that block:

```
**Empty-content subcase override**: when the offending output is the
empty string `""` after stop-token filtering, the response envelope
MUST set `retryable:false` and the `error.message` MUST recommend a
buyer-side fix (e.g. "Model emitted zero tokens for the requested
schema; modify the prompt, increase `max_tokens`, or relax the
schema before retrying — automatic same-request retry will not
succeed."). This prevents deterministic empty output from burning the
buyer's retry budget. Non-empty malformed JSON output keeps
`retryable:true` per the standard envelope.
```

Update AC-18 (empty-content fixture) to assert `retryable:false` and
the actionable message on the empty-content path. Add the error-codes
table footnote noting the retryable override.

## D. Validator panic catch-all (security F-1)

Add to §5 as a new normative block (after the receipt-ordering block):

```
**Validator panic / fatal-error catch-all**: after inference starts,
every structured-output postprocess failure path MUST be caught and
converted to a terminal HTTP 502 SPEC-019 envelope with
`inference_ran:true`, `settlement_ran:true`, `FaultBreakerQualifying`,
no success receipt emitted, no sticky-success route written, and zero
provider-positive credits. Failure modes covered: thrown errors,
runtime panics or fatal assertions, recursion / stack-overflow,
resource-limit aborts (timeout / memory), and any unexpected validator
internal error. Fallback code mapping: JSON parse internals →
`malformed_json_response`; validator internals →
`json_schema_validation_failed`. An empty / default HTTP 500 from the
request handler MUST NOT escape this boundary on the structured-output
postprocess path.
```

## E. SDK parity fixture — paired Person schema (PD F-2)

Locate AC-30 / AC-31 (around `:336-354`).

Rewrite as a paired-fixture acceptance:

```
AC-30. openai-python paired fixture: `test/integration/spec_019/
openai_python_strict_json_schema/` contains:
- request body with `response_format.json_schema` for `Person`
  (Pydantic model: `class Person(BaseModel): name: str; age: int`),
- `openai==2.44.0`,
- captured outbound HTTP body (`fixture_request_body.json`),
- expected returned parsed `Person` model,
- golden OpenAI `gpt-4o-2024-08-06` response committed for
  side-by-side comparison.
The macprovider response parses into the same `Person` model and the
JCS-canonicalized `response_format.json_schema.schema` matches the
golden fixture modulo an explicit allow-list (`title`, `description`).

AC-31. Vercel AI SDK paired fixture: `test/integration/spec_019/
vercel_ai_sdk_strict_json_schema/` contains the SAME logical `Person`
contract translated to Zod (`z.object({ name: z.string(), age:
z.number().int() })`) with `createOpenAICompatible({
supportsStructuredOutputs: true, ... })`, `@ai-sdk/openai-compatible
@2.0.38`, captured outbound HTTP body (`fixture_request_body.json`),
and assertion that `response_format.type == "json_schema"` and
`json_schema.strict == true`. The JCS-canonicalized
`response_format.json_schema.schema` MUST match the AC-30 Pydantic
schema modulo `title` / `description` differences. False-green between
the two SDK paths is the failure case this fixture prevents.

AC-32. Vercel default-path fixture (separate file): without
`supportsStructuredOutputs:true`, Vercel emits `json_object` not
`json_schema`. Asserts default path remains v0.1.1 `json_object`
enforcement (AC-7).
```

## F. Schema depth counting (critic F-5)

Locate §6 `json_schema_max_depth` block (around `:576-580`).

Append to that block:

```
**Depth counting algorithm**: the count is the maximum nesting of the
schema JSON tree itself, NOT instance-implied depth. Algorithm: at the
root schema object, depth = 1; each nested `properties[*]` subtree,
`items` subtree, `additionalProperties` subtree, or schema-typed value
inside `oneOf`/`anyOf` (note: those keywords are rejected per §3, but
the counter rule still applies if support is added later) increments
the count by 1. Sibling schemas at the same level do not increase
depth. Provider and coordinator MUST use this identical algorithm.
Example: `{"type":"object","properties":{"a":{"type":"object",
"properties":{"b":{"type":"string"}}}}}` is depth 3 (root → properties.a
→ properties.a.properties.b).
```

## G. NFC/NFD — adversarial security fixture (security F-3)

Locate AC-9 (around `:184-187` — NFC/NFD parity fixture).

Append to AC-9:

```
Adversarial extension: schema with NFC property name "café" plus
attacker-supplied output with visually-equivalent NFD property name
"café" → validator rejects byte-distinct keys as
`json_schema_validation_failed` AND log / error envelope preserves
the offending byte sequence (escaped per JSON string rules; codepoints
unchanged). No Unicode normalization at log time. Future
implementations MUST NOT weaken byte-distinct comparison to
NFC-normalized comparison; doing so breaks this AC.
```

## H. gzip body-byte preservation (critic F-3 / carried-from-r1 M-5)

Add to §7 (Coordinator / gateway behavior):

```
**Inbound content-encoding preservation**: the gateway MUST forward the
inbound request body bytes to the coordinator without decompressing
any `Content-Encoding` (`gzip`, `deflate`, `br`). The
`json_schema.schema` byte cap (§6) and JCS canonicalization (SPEC-015
§1191-1204) are computed over the same byte sequence at gateway,
coordinator, and provider parser; mid-path decompression would split
the byte-equivalence invariant. If a buyer sends a compressed body,
the coordinator's reader-side handles decompression with identical
byte semantics. Provider parser sees the canonical decompressed bytes.
```

Add an AC under §2 "Coordinator / gateway parity":

```
AC-N. Body-byte preservation: a buyer-sent compressed request body
(`Content-Encoding: gzip` with a 14 KiB `json_schema.schema`) is
forwarded to the coordinator without gateway-side decompression. The
coordinator-side decompressed schema bytes equal the provider parser's
decompressed schema bytes (byte-equivalent). Receipt prompt-hash
matches a buyer-sent identical-content uncompressed request.
```

## I. Gateway settleBeforeResponse for new codes (critic F-6 minor)

Add to §7 (after §H block):

```
**Settlement double-attribution prevention**: for the gateway-passed-
through detail codes `malformed_json_response` and
`json_schema_validation_failed`, the gateway MUST NOT invoke
`settleBeforeResponse` (`phase5-gateway/internal/router/chat_proxy.go`
— grep for current line) on these specific codes. These are
downstream `FaultBreakerQualifying` outcomes already settled by the
coordinator; a second gateway-side settle would double-debit the
buyer.
```

## J. Code citations correction (code F-3 minor)

Locate the §7 "current normalization evidence" gateway citations
(around `:617-634`).

Fix two specific citations:

1. Replace `phase5-gateway/internal/router/chat_proxy.go:997-1008`
   (which is `parseChatRequest`) — remove this citation OR replace
   with the correct body-preservation evidence line (grep current state
   for `bytes.NewReader(body)` in `chat_proxy.go` and cite that line).

2. Relabel `phase5-gateway/internal/router/chat_proxy.go:601-607` as
   the `isNullUsageProviderError` predicate (or whatever the current
   helper at that line is — grep first); cite `:593-599` as the
   provider-error allow-list helper if that's where it lives at HEAD.

## K. Theme-code anchor fix + narrative wording (narrative F-1 + minors)

§12 change-log entry currently cites `§A.1`, `§B.1`, etc., which do
not anchor in the SPEC body's §1-§12 structure. Replace each theme
citation with the SPEC body §N anchor it actually lands in. Map:
- §A.1 → §1 (cross-spec amendment)
- §A.2 → §7 (gateway pass-through)
- §B.1 → §3 (strict-required-parity rule)
- §B.2 → §3 (const/enum type-conformance)
- §B.3 → §3 (NFC/NFD byte-comparison)
- §C.1 → §5 + §2 AC-26 (receipt ordering + money-path)
- §C.2 → §5 (empty-content classification)
- §C.3 → §9 (defaulted-strict receipt scope)
- §D.1 → §6 (schema-depth cap)
- §D.2 → §6 (response cap pre-parse)
- §D.3 → §3 + §2 AC-33 (json_schema.name rule)
- §E.1 → §4 (composite render)
- §E.2 → §4 (stateless renderer)
- §F → §2 AC-30/AC-31 (SDK fixtures)
- §G.1 → §1 + §2 AC-11/AC-22 (versioned suffix drop)
- §I.1/§I.2 → §0 / §2 (orientation + AC categories)

Add new v0.1.2 entry below the v0.1.1 entry:

```
- **v0.1.2 (2026-06-28, round-2 defensive absorption):** Absorbed 6
  HIGH + 9 MEDIUM + 3 minor findings across 6 audit lanes. Composite
  render order unified to single normative sequence in §4 (architect/
  code/critic convergent). `json_schema.name` rule made
  OpenAI-compatible (`^[A-Za-z0-9_-]{1,64}$`), mandatory, and AC-
  asserted at provider + coordinator (critic/code/PD/security
  convergent). Empty-content `retryable:false` override added in §5
  (PD). Validator panic / fatal-error catch-all normative block added
  in §5 (security). AC-30/AC-31 SDK parity rewritten as paired
  fixture (PD). Schema-depth counting algorithm specified in §6
  (critic). NFC/NFD adversarial fixture added to AC-9 (security).
  gzip body-byte preservation added to §7 (critic / carried-from-r1).
  Gateway double-settlement prevention added to §7 (critic). Stale
  gateway citations fixed in §7 (code). Round narrative:
  `specs/SPEC-019-v0_1-r2-audit.md`; per-lane findings:
  `specs/SPEC-019-v0_1-{architect,code,security,product-design,
  critic,narrative}-r2-audit.md`.
```

Also fix:
- §2 category "Schema-shape parity" → rename to "Schema-shape & key-
  comparison" (narrative minor 1 — AC-9 is byte-comparison, not parity)
- §6 dual depth-cap (schema=32, instance=32): add one signposting
  sentence: "Both `json_schema_max_depth` (schema-side, §6) and AC-27
  (output-instance side) use the same constant 32 by design — a schema
  at depth 32 can match an instance at depth 32."

## L. r2 narrative file

Write `specs/SPEC-019-v0_1-r2-audit.md` (mirror of r1 narrative):

```
# SPEC-019 v0.1.1 round-2 defensive audit — narrative

[tally table mirroring r1 format]
[Top HIGHs section]
[Convergent themes section]
[Recommendation: absorb to v0.1.2 + fire r3 defensive — same 6 lanes,
mirror of r3 from SPEC-018 v0.2]
```

Use the same shape as `specs/SPEC-019-v0_1-r1-audit.md`. Keep it tight
(~80-100 lines).

## Stop condition

Verify after editing:

1. `grep "json_schema_invalid_name" specs/SPEC-019-structured-output.md`
   shows the code in §3, §5 table, AND at least one AC asserting it.
2. `grep "person-v1" specs/SPEC-019-structured-output.md` shows the
   accepted-name test case in the AC.
3. §4 composite-render block contains exactly ONE normative order, no
   contradictory wording.
4. §5 has empty-content `retryable:false` override paragraph.
5. §5 has validator panic catch-all normative block.
6. §6 has schema-depth counting algorithm.
7. §7 has gzip body-byte preservation block + gateway double-settlement
   prevention block.
8. §12 v0.1.2 change-log entry references §1-§12 anchors, NOT
   §A.1/§B.1/etc theme codes.
9. v0.1.1 change-log theme codes replaced per §K mapping.
10. `wc -l specs/SPEC-019-structured-output.md` — report.

Report:
- Resulting line count.
- AC count after additions.
- Any §A-§K fix you could not place — explain why.

Done. No commit. No re-audit. r3 fires next.
