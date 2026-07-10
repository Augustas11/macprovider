**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/0/1/0/0

## Closure verified

- r2 H-1: CLOSED. SPEC-019 §4 now has exactly one normative composite render
  order: construct schema-adjusted `ChatMessage` values, pass those adjusted
  messages through `ToolPromptRenderer.renderMessages(...)`, then construct
  `UserInput(chat: rendered, tools: request.tools)` with the original tools
  unchanged (`specs/SPEC-019-structured-output.md:497-511`). The surrounding
  prose matches the numbered sequence and explicitly forbids alternative
  ordering (`specs/SPEC-019-structured-output.md:513-516`). The empty and
  non-empty tool-history fixtures also exercise both renderer branches without
  changing that order (`specs/SPEC-019-structured-output.md:288-301`).

## Fresh findings

### Finding 1: Gzip preservation assigns schema/JCS work to the gateway while forbidding gateway schema parsing
- Severity: MEDIUM
- Location: SPEC §7 (`specs/SPEC-019-structured-output.md:709`, `specs/SPEC-019-structured-output.md:717`)
- Issue: The new content-encoding block correctly requires the gateway to
  forward compressed inbound request body bytes without gateway-side
  decompression, and AC-28a makes the coordinator-side decompressed schema bytes
  match the provider parser's decompressed schema bytes. But the same §7
  paragraph says the `json_schema.schema` byte cap and SPEC-015 JCS
  canonicalization are computed over the same byte sequence "at gateway,
  coordinator, and provider parser" (`specs/SPEC-019-structured-output.md:719-724`).
  That over-assigns schema-aware work to the gateway even though §7 says the
  gateway parses only minimal `chatRequest` fields and adds no schema parser
  (`specs/SPEC-019-structured-output.md:709-715`). It also blurs the byte domain:
  the gateway preserves compressed HTTP body bytes, while the coordinator and
  provider compare decompressed schema JSON bytes. SPEC-015 places canonical
  prompt construction at the provider, not the gateway
  (`specs/SPEC-015-receipts.md:1181-1191`). SPEC-006 does not appear to require
  gateway decompression; its gateway body rules cover request-body size limits
  and generic 413 handling (`specs/SPEC-006-buyer-api.md:1650-1657`,
  `specs/SPEC-006-buyer-api.md:2509-2516`).
- Recommendation: Split the invariant into two explicit domains. Gateway:
  preserve the exact inbound encoded body bytes and do not compute schema caps,
  schema JCS, or prompt hashes. Coordinator/provider parser: after any
  reader-side decompression, compute `json_schema.schema` byte caps over the
  decompressed schema JSON value and ensure provider prompt-hash input matches
  that same decompressed request content. Remove "at gateway" from the schema
  byte-cap/JCS computation sentence, or replace it with "across the coordinator
  and provider parser after decompression."

## Verdict justification

The architect r2 blocker is closed: §4 now has one order, the prose matches the
numbered hook sequence, and the renderer short-circuit is not an implicit
alternate branch. When `tools` are absent entirely, the generic §4 structured
schema instruction still applies; the composite block is scoped only to requests
where both `tools` and `response_format: json_schema` are present.

The validator panic / fatal-error catch-all does not contradict SPEC-001's
request-handler error mode. SPEC-001 says escaped HTTP 500s are unexpected bugs
and internal inference errors should become structured errors
(`specs/SPEC-001-phase3-binary.md:1043-1046`); SPEC-019 narrows the
post-inference structured-output path to terminal 502 envelopes
(`specs/SPEC-019-structured-output.md:557-568`).

The double-settlement prevention block does not conflict with SPEC-018 §10d.7.
SPEC-018 gates provider-positive settlement at final-close and routes cap or
final-close failures through coordinator-side `FaultBreakerQualifying` zero-credit
paths (`specs/SPEC-018-agentic-tool-calling.md:513`,
`specs/SPEC-018-agentic-tool-calling.md:961-978`). SPEC-018 is silent on a
gateway re-settlement step; SPEC-019's §7 rule is therefore a clarifying
gateway-side guard against double attribution (`specs/SPEC-019-structured-output.md:727-733`).

Because the gzip-preservation wording introduces a new normative ambiguity about
which component computes schema-aware byte/JCS invariants, the architect lane is
not ready to lock.
