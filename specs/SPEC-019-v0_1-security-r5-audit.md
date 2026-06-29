**Verdict:** READY TO LOCK
**Tally:** C/H/M/m/Q = 0/0/0/1/0

## Closure verified

- r4 Finding 1 (`Content-Encoding: identity` exception conflicts with the
  v0.1.0 header gate): CLOSED for the blocking contradiction. AC-28a still
  names HTTP 415 `request_content_encoding_unsupported` for unsupported
  `Content-Encoding` values and now explicitly keeps
  `Content-Encoding: identity` as the only accepted header value, or omitted
  header (`specs/SPEC-019-structured-output.md:354-361`). §7 now matches that
  release posture: gateway and coordinator reject any request whose normalized
  `Content-Encoding` field value is not exactly `identity`, accept omitted
  `Content-Encoding`, and defer compressed-body support to v0.2
  (`specs/SPEC-019-structured-output.md:755-763`). §10 preserves the v0.2
  decompression deferral and states that v0.1.0 returns HTTP 415
  `request_content_encoding_unsupported` for compressed bodies
  (`specs/SPEC-019-structured-output.md:866-870`).

## Fresh findings

### m-1: `Content-Encoding` normalization needs exact case-fold/list fixtures

- Severity: minor
- Location: AC-28a (`specs/SPEC-019-structured-output.md:354-361`), §7
  (`specs/SPEC-019-structured-output.md:755-763`)
- Issue: §7's "normalized field value is not exactly `identity`" is strong
  enough to reject `Content-Encoding: identity, gzip` when implemented as
  whole-field normalization, because the normalized value is not exactly the
  single token `identity`. RFC 9110 also makes content-coding tokens
  case-insensitive, so `Content-Encoding: Identity` should normalize to the
  same no-op token as lowercase `identity`. The remaining risk is
  implementation drift: one layer could use case-sensitive string equality and
  reject a valid no-op `Identity`, while another could split a comma-list and
  incorrectly accept if any token is `identity`, letting `identity, gzip`
  bypass the v0.1.0 compressed-body gate.
- Recommendation: Add an AC-28a parser sentence or fixtures: combine all
  `Content-Encoding` field instances into the HTTP field value, trim leading /
  trailing whitespace, parse the `#content-coding` list, case-fold each token,
  and accept only exactly one token equal to `identity`; reject empty,
  duplicate, parameterized, or multi-token values such as `identity, gzip` with
  the same HTTP 415 envelope at both gateway and coordinator. Include explicit
  parity fixtures for `Content-Encoding: Identity` accepted and
  `Content-Encoding: identity, gzip` rejected.

## Verdict justification

The r4 security blocker is closed: v0.1.0 now has one defensible byte-domain
posture for compressed request bodies, and the accepted `identity` carve-out is
aligned across AC-28a, §7, and §10. The case-folding and multi-value probes do
not expose a CRITICAL / HIGH / MEDIUM bypass in the spec as written:
`Identity` is the same no-op content-coding after RFC case-folding, while
`identity, gzip` is not exactly `identity` and therefore remains rejected under
§7. The only residual is a minor hardening request to lock the exact parser and
fixtures so gateway and coordinator cannot choose divergent normalization
strategies during implementation.
