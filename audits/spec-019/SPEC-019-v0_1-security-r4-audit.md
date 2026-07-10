**Verdict:** READY TO LOCK
**Tally:** C/H/M/m/Q = 0/0/0/2/0

## Closure verified

- r3 Finding 1, compressed request handling lacks a decompressed-byte cap:
  CLOSED for v0.1.0. SPEC-019 no longer attempts transparent request-body
  decompression; AC-28a requires HTTP 415
  `request_content_encoding_unsupported`, `param:"Content-Encoding"`,
  `inference_ran:false`, and `settlement_ran:false` for gzip-compressed and
  header-only fixtures at both gateway and coordinator
  (`specs/SPEC-019-structured-output.md:354-361`). §7 makes the same gate
  normative and explicitly defers gzip / deflate / br decompression because a
  second decompressed-byte cap would be required
  (`specs/SPEC-019-structured-output.md:750-764`). §10 carries the v0.2
  decompressed-byte-cap deferral (`specs/SPEC-019-structured-output.md:854-857`).
- r3 Finding 2, validator internal aborts can reuse stale partial validation
  state: CLOSED. §5 now requires partial validation state to be discarded for
  thrown errors, panics / fatal assertions, recursion / stack overflow,
  resource-limit aborts, and any other validator internal failure. The fallback
  envelope MUST use `error.param:""` and a generic message, and MUST NOT report
  a pointer derived from partially-completed validation
  (`specs/SPEC-019-structured-output.md:579-586`).
- r3 Finding 3, fixed-depth sibling sprawl lacks an explicit linear-walk
  requirement: PARTIAL, minor residual only. v0.1.3 did not add an explicit
  O(schema bytes + decoded output bytes) walker requirement. The remaining risk
  is bounded by the 16,384-byte schema cap, rejected high-complexity keywords,
  required `additionalProperties:false`, and exact provider/coordinator depth
  algorithm (`specs/SPEC-019-structured-output.md:424-445`,
  `specs/SPEC-019-structured-output.md:671-705`).

## Fresh findings

### Finding 1: `Content-Encoding: identity` exception conflicts with the v0.1.0 header gate

- Severity: minor
- Location: AC-28a (`specs/SPEC-019-structured-output.md:354-362`), §7
  (`specs/SPEC-019-structured-output.md:750-764`)
- Issue: AC-28a says any `Content-Encoding` header returns 415, then carves out
  `Content-Encoding: identity` as accepted. §7 says the gateway and coordinator
  MUST reject any `Content-Encoding` header, including "any non-empty value".
  The security impact is not a decompression-bomb bypass if the implementation
  accepts only the exact single no-op `identity` token: current gateway and
  coordinator read raw request bytes under their normal request-body caps and do
  not auto-decompress (`phase5-gateway/internal/router/chat_proxy.go:102-117`,
  `phase4-coordinator/internal/buyer/server.go:1316-1329`). However, the
  exception creates avoidable parser-differential space for duplicate /
  comma-combined values such as `identity, gzip`, case variants, or parameters,
  and it makes the header-only reject fixture ambiguous.
- Recommendation: Prefer the §7 rule: v0.1.0 should accept only an omitted
  `Content-Encoding` header and reject `identity` with the same HTTP 415
  envelope. If `identity` remains accepted for compatibility, AC-28a should
  define an exact parser: one case-insensitive token equal to `identity`, no
  parameters, no duplicates, no comma-list, and byte-identical behavior at
  gateway and coordinator.

## Verdict justification

The two r3 security MEDIUMs are closed at the SPEC level. Rejecting compressed
request codings in v0.1.0 removes the decompression-bomb class from this release
and leaves the required decompressed-byte cap correctly deferred to v0.2. The
partial-validator-state rule is now explicit, and `error.param:""` is the
correct RFC 6901 root pointer for a generic validation-aborted fallback; it does
not bypass the §5 error-envelope discipline because the error still uses the
SPEC-019 terminal envelope fields and settlement flags.

The remaining issues are minor. The `identity` exception should be tightened or
removed before implementation to avoid gateway/coordinator parser drift, and the
linear-walk concern remains a bounded implementation-quality note. Under the
r4 bar of 0 CRITICAL + 0 HIGH + 0 MEDIUM, the security lane is READY TO LOCK.
