# SPEC-019 v0.1.3 — r3 absorption (TIGHT)

Edit `specs/SPEC-019-structured-output.md` to absorb r3 findings.
Target version: **v0.1.3**. Append a v0.1.3 change-log entry citing
`specs/SPEC-019-v0_1-r3-audit.md` (write narrative file too — see §I).

**No commits, no docs/runbook updates, no IMPL code. SPEC body edits only.
Low reasoning effort.**

Aggregate r3: 0 CRITICAL + 2 HIGH + 7 MEDIUM + 4 minor + 1 Q. The code
lane already returned READY TO LOCK at r3.

## A. Gzip posture — reject `Content-Encoding` in v0.1.0 (critic H-1 + architect M-1 + security M-1)

**Decision: reject any `Content-Encoding` request header in v0.1.0
with HTTP 415.** Defer transparent decompression to v0.2.

This replaces the §7 gzip-preservation block (around `:717-725`) and
AC-28a (around `:354-359`). Decision rationale: current gateway
`parseChatRequest` does not auto-decompress (Go stdlib does not call
`gzip.NewReader` on `r.Body`), so the existing block is unimplementable.
Most SDK clients do not compress request bodies (response is what they
decompress). Narrow v0.1.0 scope.

Rewrite the §7 gzip block to this exact text:

```
**Inbound `Content-Encoding` posture (v0.1.0)**: the gateway and
coordinator MUST reject any request with a `Content-Encoding` header
(`gzip`, `deflate`, `br`, or any non-empty value) with HTTP 415
`request_content_encoding_unsupported` and an actionable message
("v0.1.0 does not accept compressed request bodies; resend with no
`Content-Encoding` header. Compressed-request support is deferred to
v0.2 per §10."). This sidesteps three problems with transparent
decompression in v0.1.0: (a) current gateway `parseChatRequest` reads
`r.Body` directly without `gzip.NewReader` (cite
`phase5-gateway/internal/router/chat_proxy.go:102-117`); (b)
decompressed-byte caps would need a second tier of limits; (c)
gateway, coordinator, and provider would need identical decompression
semantics to preserve the `json_schema.schema` byte cap and JCS
canonicalization invariants. v0.1.0 keeps a single byte-domain
(uncompressed request body) for all three components. No SPEC-006 or
SPEC-001 amendment is required: SPEC-006 §1650-1657 already covers
request-body size limits and 413; this adds 415 for a separate header
gate.
```

Replace AC-28a with this exact text:

```
AC-28a. `Content-Encoding` reject fixture: any request with a
`Content-Encoding` header returns HTTP 415
`request_content_encoding_unsupported`, `param:"Content-Encoding"`,
`retryable:false`, `inference_ran:false`, `settlement_ran:false`,
identical at gateway and coordinator (parity). Both gzip-compressed
JSON bodies and a header-only fixture (no actual compression) MUST
reject; the SPEC does not require the gateway/coordinator to validate
the body's compression. `Content-Encoding: identity` is the only
accepted value (or omitted header).
```

Add the new error code to the §5 error-codes table:

```
| `request_content_encoding_unsupported` | 415 | gateway + coordinator pre-validation | false | v0.1.0 rejects compressed request bodies. |
```

Add to §10 (Deferred):

```
- Transparent gateway-side decompression of `Content-Encoding: gzip`
  / `deflate` / `br` request bodies with a decompressed-byte cap is
  deferred to v0.2. v0.1.0 keeps the single uncompressed byte-domain
  invariant for caps and JCS.
```

## B. AC-31 Zod fixture — drop `.int()` + strip `$schema` (PD H-1)

Locate AC-31 (around `:382-390`).

Replace the Zod schema with this exact text:

```
AC-31. Vercel AI SDK paired fixture: `test/integration/spec_019/
vercel_ai_sdk_strict_json_schema/` uses the SAME logical `Person`
contract as AC-30 translated to a v0.1.0-compatible Zod shape:
`z.object({ name: z.string(), age: z.number() })`. (`z.number().int()`
emits `minimum`/`maximum` keywords which §3 rejects; v0.1.0 fixtures
use unconstrained `z.number()` until v0.2 widens the §3 subset to
include numeric bounds.) The fixture captures the outbound HTTP body
(`fixture_request_body.json`). A normalization step strips the
`$schema` top-level key from the captured Vercel body before
canonical-schema comparison; v0.1.0 §3 rejects `$schema` (per AC-3
rejected-keyword list). With `createOpenAICompatible({
supportsStructuredOutputs: true, ... })` and `@ai-sdk/openai-compatible
@2.0.38`, the AC asserts `response_format.type == "json_schema"`,
`json_schema.strict == true`. The JCS-canonicalized
`response_format.json_schema.schema` MUST match the AC-30 Pydantic
schema modulo `title` / `description` AND `$schema`. v0.1.0 documents
the `$schema` strip + `.int()` substitution as v0.1.0 fixture
constraints; v0.2 considers widening §3 to accept these keywords.
```

Document in §10 (Deferred):

```
- §3 numeric-bound keywords (`minimum`, `maximum`, `multipleOf`) and
  `$schema` top-level acceptance are deferred to v0.2 to enable
  direct round-trip with Vercel AI SDK's full Zod expressivity
  without an SDK-side normalization step.
```

## C. Panic catch-all — partial state discard (security M-2)

Locate the §5 panic catch-all (around `:557-568`).

Append to that block:

```
**Partial-validator-state rule**: when the validator does not
complete normally — thrown error, panic / fatal assertion, recursion /
stack overflow, resource-limit abort, or any other internal
failure — partial validation state MUST be discarded before emitting
the fallback envelope. The fallback envelope MUST use `error.param:""`
(RFC 6901 root) and a generic message (e.g. "Schema validation aborted
before completion"); the envelope MUST NOT report a JSON pointer
derived from partially-completed validation, since that pointer could
mislead the buyer about which field actually failed.
```

## D. Empty-content actionable message — fix the remediation list (critic M-2)

Locate the §5 empty-content override (around `:577-584`).

The current message says "modify the prompt, increase `max_tokens`, or
relax the schema". `max_tokens` is the wrong recommendation: empty
output happens at temperature=0 with deterministic models, not from
small `max_tokens`. Replace the actionable-message guidance with:

```
**Empty-content subcase override**: ... `error.message` MUST
recommend a buyer-side fix (e.g. "Model emitted zero tokens for the
requested schema; adjust `temperature` / `seed` (for stochastic
models), or modify the prompt or schema before retrying — automatic
same-request retry will not succeed.").
```

## E. §6 dual-axis signpost AC reference fix (narrative M-1)

Locate the §6 dual-axis signpost (around `:659`). It currently cites
"AC-27" for the output-instance side. The output-instance depth cap
is asserted by **AC-13** (verify by re-reading the AC-13 + AC-27 text in
the current SPEC and cite the correct AC).

Fix the citation to point to the AC that actually asserts the
output-instance depth cap (most likely AC-13). The earlier signpost text
at three lines above already cites AC-13 correctly — the line at `:659`
is the regression.

## F. §6 depth-counting algorithm — mixed items/properties example (critic M-3)

Locate the §6 depth-counting algorithm worked example (around `:663-672`).

Append a second worked example:

```
Mixed-keyword example: `{"type":"array","items":{"type":"array",
"items":{"type":"object","properties":{"id":{"type":"string"}}}}}` is
depth 4 — root array (depth 1) → items array (depth 2) → items object
(depth 3) → properties.id string (depth 4). Both `items` subtree and
`properties[*]` subtree increment the counter by 1, regardless of which
keyword is used at each level. Provider and coordinator MUST compute
the same value.
```

## G. Empty-content retryable nuance (PD M-2)

Locate the §5 empty-content override (after the §D message rewrite).

Append:

```
**Retry semantics**: `retryable:false` means the buyer's SDK SHOULD NOT
blindly replay the identical request (including same `seed` /
`temperature` / `prompt` / `schema`). Buyers MAY issue a deliberately
modified retry — different `seed`, different `temperature`, a relaxed
schema, or a clarifying prompt — after their own retry policy
decision. The `retryable:false` value prevents the SDK auto-retry
loop, not buyer-initiated recovery.
```

## H. Minor: nested-Pydantic v0.1.0 limitation note (critic F-4 minor)

Add to §10 (Deferred) or as a footnote on AC-30:

```
- AC-30 uses a flat Pydantic model. Nested Pydantic models emit
  `$defs` / `$ref` which §3 rejects (per v0.1.0 reject-list); fixtures
  with nested classes are deferred to v0.2 when `$ref` / `$defs`
  schema reuse is in scope.
```

## I. Theme citations + change-log entry

Add v0.1.3 entry to §12 change log:

```
- **v0.1.3 (2026-06-28, round-3 defensive absorption):** Absorbed 2
  HIGH + 7 MEDIUM + 4 minor + 1 Q across 6 audit lanes. Gzip posture
  switched from gateway-decompression to HTTP 415 reject in v0.1.0
  (critic + architect + security convergent on r2's gzip block being
  unimplementable against current gateway code) — transparent
  decompression deferred to v0.2. AC-31 Vercel fixture changed to
  v0.1.0-compatible Zod shape (`z.number()` instead of
  `z.number().int()`) + `$schema` strip step documented (PD).
  §5 panic catch-all partial-validator-state discard rule added
  (security). §5 empty-content actionable message replaced
  `max_tokens` with `temperature` / `seed` (critic). §6 dual-axis
  signpost AC citation corrected to AC-13 (narrative). §6 depth-
  counting algorithm gains mixed `items`/`properties` worked example
  (critic). Empty-content `retryable:false` semantics clarified as
  "no SDK auto-retry, buyer-initiated modified retry permitted" (PD).
  Nested-Pydantic v0.1.0 limitation documented in §10 (critic minor).
  Round narrative: `specs/SPEC-019-v0_1-r3-audit.md`; per-lane
  findings: `specs/SPEC-019-v0_1-{architect,code,security,
  product-design,critic,narrative}-r3-audit.md`. Codex code lane was
  the first lane to return READY TO LOCK at any round.
```

Update §12 metadata:

```
**Version:** 0.1.3 (2026-06-28, round-3 defensive absorption)
**Status:** DRAFT — r4 defensive audit pending.
```

## J. r3 narrative file

Write `specs/SPEC-019-v0_1-r3-audit.md` (mirror of r2 narrative):

```
# SPEC-019 v0.1.2 round-3 defensive audit — narrative

[tally table mirroring r2 format]
[The 2 HIGHs section]
[Convergent themes (3 lanes touched gzip)]
[Recommendation: absorb to v0.1.3 + fire r4 defensive]
[Note: codex code lane = first READY TO LOCK]
```

Use the same shape as `specs/SPEC-019-v0_1-r2-audit.md`. Keep tight
(~80 lines).

## Stop condition

Verify after editing:

1. `grep "request_content_encoding_unsupported" specs/SPEC-019-structured-output.md`
   appears in §7, §5 error-codes table, AND AC-28a — all three.
2. `grep "Content-Encoding" specs/SPEC-019-structured-output.md` — old
   "forward without decompression" wording is gone.
3. `grep "z.number().int()" specs/SPEC-019-structured-output.md` —
   `.int()` is now documented as v0.1.0-incompatible (the bare
   `z.number()` is used in the fixture).
4. `grep "\\$schema" specs/SPEC-019-structured-output.md` — strip
   step documented in AC-31.
5. §5 catch-all has partial-validator-state discard rule.
6. §5 empty-content message says `temperature` / `seed`, not
   `max_tokens`.
7. §6 dual-axis signpost cites the correct AC (likely AC-13, not
   AC-27 — verify against current SPEC).
8. §6 has mixed `items`/`properties` worked example.
9. §10 has both deferreds (gzip transparent decompression, numeric
   bounds + `$schema`).
10. §12 v0.1.3 change-log entry references §1-§12 anchors only.

Report:
- Resulting line count.
- AC count after edits.
- Any §A-§J fix you could not place — explain why.

Done. No commit. No re-audit. r4 fires next.
