**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/0/1/0/0

## Closure verified

- r4 M-1: PARTIAL. v0.1.4 closes the §7 side of the contradiction:
  §7 now rejects only a `Content-Encoding` header whose normalized field
  value is not exactly `identity`, and explicitly accepts
  `Content-Encoding: identity` plus omitted `Content-Encoding`
  (`specs/SPEC-019-structured-output.md:755-763`). §10 also preserves the
  v0.1.0 uncompressed-byte-domain invariant and defers compressed-request
  decompression to v0.2 (`specs/SPEC-019-structured-output.md:866-870`).
  However, AC-28a still begins with "any request with a `Content-Encoding`
  header returns HTTP 415" before ending with "`Content-Encoding: identity`
  is the only accepted value (or omitted header)"
  (`specs/SPEC-019-structured-output.md:354-361`). The acceptance fixture is
  therefore still ambiguous for the exact header value the r4 fix intended to
  exempt.

## Fresh findings

### Finding 1: AC-28a still defines both reject-all and identity-accepted behavior
- Severity: MEDIUM
- Location: SPEC §2 AC-28a + §7
  (`specs/SPEC-019-structured-output.md:354-361`,
  `specs/SPEC-019-structured-output.md:755-763`)
- Issue: §7 now has a coherent architecture rule: omitted
  `Content-Encoding` and normalized `identity` stay in the single
  uncompressed byte-domain; compressed/non-identity codings fail with HTTP 415.
  AC-28a did not receive the same rewrite. Its first sentence still says any
  request with the header returns 415, while its final sentence says
  `Content-Encoding: identity` is accepted. A fixture implementer can still
  write either an `identity` rejection test or an `identity` acceptance test
  and cite AC-28a. That keeps the r4 MEDIUM open at fixture level even though
  the §7 narrative was repaired.
- Recommendation: Rewrite AC-28a to match §7, for example: "A request whose
  `Content-Encoding` header has a normalized field value other than exactly
  `identity` returns HTTP 415 ...; omitted `Content-Encoding` and
  `Content-Encoding: identity` are accepted." Add explicit fixture rows for
  `gzip`, a header-only non-identity value, an empty-after-trim value, and
  whitespace-surrounded `identity` after normalization.

## Verdict justification

The r4 architecture concern is not fully closed because the acceptance criteria
remain internally inconsistent for `Content-Encoding: identity`. The §7 fix is
otherwise directionally sound: it keeps gateway/coordinator/provider behavior
in one byte-domain, avoids transparent decompression before v0.2, and remains a
separate 415 content-coding gate from SPEC-006's request-body 413 gate
(`specs/SPEC-006-buyer-api.md:1650-1657`,
`specs/SPEC-006-buyer-api.md:2509-2524`).

The RFC-9110 carve-out does not introduce a new cross-spec architecture issue
by itself. RFC 9110 treats `Content-Encoding` as representation content
codings and allows 415 for unsupported request content codings; accepting
`identity` as a no-op remains compatible with SPEC-019's "no decompression in
v0.1.0" invariant. The main risk is still local: AC-28a's reject-all fixture
language contradicts the §7 carve-out.

For the edge cases named in the r5 prompt, §7's "normalized field value is not
exactly `identity`" implies an empty-after-trim header is rejected because it is
present and not `identity`. Whitespace-surrounded `identity` should be accepted
after header-value normalization, but that behavior should be locked in AC-28a
fixtures so gateway/coordinator parity tests cannot diverge.
