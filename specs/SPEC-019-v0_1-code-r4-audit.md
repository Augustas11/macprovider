**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/1/0/1/0

## Closure verified

- r3 code lane fresh findings: CLOSED / none to close. The r3 code audit had
  no fresh findings and was READY TO LOCK.
- r3 code re-verification of prior r2 F-1: CLOSED. §4 still has one
  normative composite render order and keeps original tools unchanged
  (`specs/SPEC-019-structured-output.md:497-516`). AC-22a / AC-22b still
  split empty-tool-history and non-empty tool-history paths
  (`specs/SPEC-019-structured-output.md:288-301`).
- r3 code re-verification of prior r2 F-2: CLOSED. §3 still requires the
  anchored OpenAI-compatible machine-name regex at provider and coordinator
  (`specs/SPEC-019-structured-output.md:464-472`), and §5 still lists
  `json_schema_invalid_name` in the error table
  (`specs/SPEC-019-structured-output.md:640`).
- r3 code re-verification of prior r2 F-3: CLOSED. The stale
  `chat_proxy.go:997-1008` citation is still absent from §7. The current
  body-preservation citations point at inbound body read and upstream request
  construction from the same body (`specs/SPEC-019-structured-output.md:742-748`).

## Fresh findings

### H-1. AC-31's `z.number()` fixture matches Vercel output but cannot satisfy the AC-30/AC-31 canonical-schema parity assertion

- Location: `specs/SPEC-019-structured-output.md:371-399`
- Issue: The r4 text correctly changed the Vercel fixture to the actual
  v0.1.0-compatible Zod shape, `z.object({ name: z.string(), age:
  z.number() })`. A local capture with `@ai-sdk/openai-compatible@2.0.38`,
  compatible `ai@6.0.144`, and `zod@4.1.13` confirms the outbound schema for
  `age` is exactly `{"type":"number"}` and the top-level schema contains
  `$schema`. A comparison capture confirms `z.number().int()` emits
  `{"type":"integer","minimum":-9007199254740991,"maximum":9007199254740991}`.
  However, AC-30 still defines the paired Pydantic model as
  `class Person(BaseModel): name: str; age: int`, and an `openai==2.44.0`
  / Pydantic strict-schema probe emits `age: {"type":"integer"}`. AC-31 then
  requires the JCS-canonicalized Vercel schema to match AC-30 modulo only
  `title` / `description` and `$schema`. That comparison still fails on
  `type:"number"` versus `type:"integer"`.
- Why it matters: The acceptance criterion remains mechanically false under
  the named SDK behavior. An implementation can make the Vercel request
  v0.1.0-valid, or it can make the schema match the Pydantic `int` fixture, but
  the current text requires both at once without allowing the remaining numeric
  type delta. This is the same class of lock-blocking false-red fixture problem
  that r3 was supposed to close.
- Fix shape: Either change AC-30's paired Python fixture to a numeric type that
  emits JSON Schema `number`, or explicitly allow and justify the
  `integer`/`number` delta in the AC-30/AC-31 canonical comparison. If strict
  byte-equivalence is still desired, the fixtures need a shared schema type
  before lock.

### m-1. §10 defers compressed request support but does not grep-cover the new error-code token

- Location: `specs/SPEC-019-structured-output.md:354-361`,
  `specs/SPEC-019-structured-output.md:643`,
  `specs/SPEC-019-structured-output.md:750-764`,
  `specs/SPEC-019-structured-output.md:854-857`
- Issue: `rg "request_content_encoding_unsupported"
  specs/SPEC-019-structured-output.md` returns exactly three hits: AC-28a
  (`:356`), the §5 error-code table (`:643`), and §7 normative inbound
  `Content-Encoding` posture (`:753`). §10 covers the related v0.2 deferral for
  transparent decompression and decompressed-byte caps (`:854-857`), but it does
  not repeat the literal `request_content_encoding_unsupported` code that the
  r4 code-lens prompt asked to grep-verify in §10.
- Why it matters: Non-blocking editorial traceability gap. The behavior is
  present in §10, but the code token itself is not.
- Fix shape: Add the literal v0.1.0 error code to the §10 deferred bullet, for
  example by saying v0.1.0 returns `request_content_encoding_unsupported` until
  v0.2 decompression semantics land.

## Verdict justification

The `request_content_encoding_unsupported` posture is otherwise coherent across
AC-28a, §5, and §7: AC-28a requires HTTP 415 with
`param:"Content-Encoding"`, `retryable:false`, `inference_ran:false`, and
`settlement_ran:false`; §5 gives the same code HTTP 415 at gateway +
coordinator pre-validation; §7 makes gateway and coordinator reject
non-identity `Content-Encoding` before decompression.

The partial-validator-state rule cites the right envelope field and the right
RFC 6901 root representation. §5 says fallback envelopes use
`error.param:""` and separately states root-level JSON pointers are the empty
string `""` per RFC 6901 §5 (`specs/SPEC-019-structured-output.md:579-586`,
`:617-623`). That does not bypass the §5 error-envelope discipline; it selects
the root pointer for an incomplete validator state where a field pointer would
be misleading.

The remaining blocker is AC-31's real SDK fixture. The Zod text now matches
actual Vercel output for `z.number()`, but that exposed a second, still
lock-blocking mismatch against AC-30's Pydantic `int` schema. With one HIGH
finding open, SPEC-019 v0.1.3 is not ready to lock from the code lane.
