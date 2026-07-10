**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/0/1/0/0

## Closure verified

- r3 M-1: CLOSED. The r3 finding was that the gzip-preservation block assigned
  schema byte-cap / JCS work to the gateway while §7 also said the gateway adds
  no schema parser. v0.1.3 removes that architecture: AC-28a now requires a
  pre-validation HTTP 415 `request_content_encoding_unsupported` response for
  compressed request bodies before inference or settlement
  (`specs/SPEC-019-structured-output.md:354-361`); the §5 error-code table
  carries the same 415 code at gateway + coordinator pre-validation
  (`specs/SPEC-019-structured-output.md:630-644`); and §7 says the gateway
  still parses only minimal `chatRequest` fields, adds no schema parser, and
  rejects unsupported `Content-Encoding` before any decompression/JCS problem is
  introduced (`specs/SPEC-019-structured-output.md:742-764`). The old
  "gateway computes schema/JCS over decompressed bytes" ambiguity is gone.

## Fresh findings

### Finding 1: `Content-Encoding: identity` is both accepted and rejected
- Severity: MEDIUM
- Location: SPEC §7 + AC-28a
  (`specs/SPEC-019-structured-output.md:354-361`,
  `specs/SPEC-019-structured-output.md:750-764`)
- Issue: AC-28a says "`Content-Encoding: identity` is the only accepted value
  (or omitted header)" (`specs/SPEC-019-structured-output.md:361`). But the
  normative §7 posture says the gateway and coordinator MUST reject any request
  with a `Content-Encoding` header, including "any non-empty value", with HTTP
  415 (`specs/SPEC-019-structured-output.md:750-753`). `identity` is a
  non-empty `Content-Encoding` value, so a conforming implementation cannot know
  whether to accept or reject it. This also weakens the claimed gateway /
  coordinator parity fixture because the fixture has two incompatible expected
  outcomes for the same header.
- Recommendation: Pick one rule and make §7, AC-28a, and the error-message
  guidance match. If `identity` is accepted, change §7 to reject
  `Content-Encoding` only when the normalized field value is not exactly
  `identity`, and keep the "single uncompressed byte-domain" invariant for
  identity/omitted. If v0.1.0 intends the simpler gate, remove the identity
  carve-out from AC-28a and require no `Content-Encoding` header at all.

## Verdict justification

The r3 architect blocker is closed because v0.1.3 no longer asks the gateway to
understand schema bytes, decompressed schema JSON, or SPEC-015 JCS
canonicalization; gateway/coordinator behavior is now a pre-validation header
gate plus ordinary uncompressed request-body forwarding.

The new 415 posture does not conflict with SPEC-006 §7.4's request-body posture.
SPEC-006 §7.4 orders the gateway's quota checks and names the request body size
limit as a distinct check (`specs/SPEC-006-buyer-api.md:1650-1657`), while
SPEC-006 §17.1 maps body-too-large to 413
(`specs/SPEC-006-buyer-api.md:2509-2524`). SPEC-019's 415 is a separate
request representation / content-coding gate, not a replacement for the 413
body-size gate. HTTP 415 is also the right family for unsupported
`Content-Encoding`: RFC 9110 §15.5.16 explicitly allows 415 when the request
format problem is due to `Content-Encoding`, while 400 would be less precise.

The §10 deferral is directionally correct: v0.2 transparent decompression is
explicitly paired with a decompressed-byte cap
(`specs/SPEC-019-structured-output.md:854-857`), so v0.1.3 does not silently
inherit SPEC-006's encoded-byte request limit as the only future decompression
limit. However, the identity accept/reject contradiction leaves v0.1.3 with a
MEDIUM implementation ambiguity, so the architect lane is not ready to lock.
