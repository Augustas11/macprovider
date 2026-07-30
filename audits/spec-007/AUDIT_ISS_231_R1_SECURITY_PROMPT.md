# Audit: ISS-231 R1 security lens

Issue #231 closes the R2 architect lane deferrals from PR #221:
- A1 cap on `matched_account_ids` in the 409 ambiguity response
- A2 path-segment typing (deprecation-window mode)

Tree: `spec/iss-231-spec-007-v04`.

## Threat model

The 409 ambiguity response is operator-facing. The path-segment is
buyer-influenced (X-Request-ID echo). The two changes together
adjust how an attacker can manipulate the explorer surface.

Specifically watch for:

1. **Collision-flood DoS**: an attacker who can write to N
   accounts under the SAME request_id (or who controls a shared
   external_request_id) could try to inflate the 409 body. Does
   the cap=10 actually bound the response size, or can the
   forensic unbounded SELECT still saturate memory?
2. **Audit-log poisoning**: the truncation audit row embeds
   account_ids that might be attacker-influenced. `quotedCSV`
   escapes `"`, `\`, `\n`, `\r`, `\t`. Are there other JSON
   special characters or unicode line-separators (U+2028, U+2029)
   that could break the JSON shape or inject log content?
3. **Path-segment typing bypass**: untyped path-segments are
   still accepted in v0.4. Can an attacker bypass the
   deprecation telemetry (e.g. via URL encoding)? Conversely, is
   there an attack where an attacker-supplied typed prefix
   confuses downstream consumers?
4. **Information leak**: the deprecation WARN audit/log embeds
   the request_id verbatim. request_id is buyer-influenced (it
   echoes X-Request-ID). Can a buyer-controlled value inject
   control characters into the log line?
5. **Cap-bypass via second call**: an attacker could re-issue
   the 409 request many times in a loop; does cap=10 actually
   prevent enumeration of all ambiguous account_ids?

Severity + Convergence line.
