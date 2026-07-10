# ISS-188 R1 — security-lane audit prompt

Audit target: the diff on branch `fix/iss-188-xrequestid-propagation`
(PR https://github.com/Augustas11/macprovider/pull/195) against
`origin/main`. The change persists the buyer-supplied `X-Request-ID`
header into the coordinator's `request_log.external_request_id`
column and makes the gateway forward the buyer-visible request id to
the coordinator verbatim instead of minting a fresh UUID.

## Scope of this lane

You are the **security lane**. Focus on:

- **Header trust boundary.** The buyer-controlled `X-Request-ID` now
  reaches a column in the coordinator's persistent SQLite DB. Are
  there sanitization gaps? Length bounds? Format validation?
- **Log injection / SQL injection.** The value is bound via parameter
  in the INSERT (`nullString(row.ExternalRequestID)`) but is it ever
  string-interpolated into a query elsewhere? Is it written to
  structured logs that might suffer JSON-escape issues?
- **Replay / collision attacks.** A buyer can submit an arbitrary
  `X-Request-ID` and have it persisted alongside another buyer's
  legitimate id. Does this break any uniqueness or audit-integrity
  invariant? The schema doesn't put a unique constraint on
  external_request_id; is that the right call?
- **Buyer-visible information leak.** Does the gateway ever echo back
  the coordinator's per-attempt internal `request_id` to the buyer
  via response headers or body, leaking internal state? The flipped
  test asserts the buyer-supplied id is forwarded — does any earlier
  middleware redact it on the response side?
- **PII / regulatory.** OpenAI SDK clients sometimes include
  user-correlated identifiers in `X-Request-ID`. Persisting that
  string in a coordinator log — is it PII per the project's existing
  policy? Search the repo for "redact" / "PII" / "GDPR" hits to see
  what posture the project takes.
- **Sticky-routing path.** chat_proxy.go between lines 195-220 has a
  conditional Authorization header for sticky routing. Does that
  conditional interact with the X-Request-ID change in any
  unexpected way (e.g., is the bearer or conversation key
  X-Request-ID-derived)?
- **Database write authority.** Is there any path where the
  coordinator's billing recorder runs at a privilege the
  external_request_id wouldn't be cleared through (e.g., shared
  store with relaxed RLS)?
- **Idempotency.** A separate idempotency-key code path exists
  (`request_idempotency_keys` table per store.go). Does the new
  column interact with idempotency replay — could a malicious buyer
  resubmit with a colliding external_request_id and confuse the
  idempotency cache?

Out of scope for this lane (other lanes own):

- **Code lane:** Go idiom, SQL correctness, test coverage,
  backwards compat at the schema level.
- **Architect lane:** spec consistency vs SPEC-002 §11, naming,
  cross-service ownership, observability shape.

Do NOT duplicate their work.

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention: this audit gates
this PR on findings INTRODUCED by the diff against origin/main.
Pre-existing vulnerabilities visible to your audit but NOT modified
by this PR are out of scope for blocking convergence — they may be
worth filing as separate issues but they do NOT block PR #195 from
landing.

Example of in-scope: the new `sanitizeExternalRequestID` accepts
128-byte non-UUIDv4 values when stricter validation would be safer.
This is introduced by the PR.

Example of out-of-scope: gateway `usage_events.request_id` was
already the primary key before this PR. If you find a vulnerability
in that PK shape, file it as a separate issue (see existing
[#196](https://github.com/Augustas11/macprovider/issues/196) which
already tracks this) — do NOT report it as a CRITICAL against this
PR.

If you re-find a CRITICAL/MAJOR that was already filed as a separate
issue, drop it from your findings list and add a one-line NOTE
referencing the issue number.

## Files in the diff

```
phase4-coordinator/internal/buyer/billing_recorder.go
phase4-coordinator/internal/buyer/server.go
phase4-coordinator/internal/buyer/server_test.go
phase4-coordinator/internal/requestlog/store.go
phase5-gateway/internal/router/chat_proxy.go
phase5-gateway/internal/router/server_test.go
```

Useful command:
```
git diff origin/main -- phase4-coordinator/ phase5-gateway/
```

PR body at https://github.com/Augustas11/macprovider/pull/195.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **File:line(s):** exact reference
- **Threat model / attack surface:** one-sentence statement
- **Evidence:** quote relevant code
- **Recommendation:** specific change (validation, sanitization,
  bounds, schema constraint, etc.).

Severity definitions:

- **CRITICAL:** exploitable now or under realistic adversary
  assumptions. Must fix before this lands.
- **MAJOR:** weakens defense in depth; likely to be problematic at
  scale or in beta.
- **MINOR:** hardening opportunity.
- **NOTE:** future-proofing observation.

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Be honest about what you DON'T have evidence to judge.

## Reference reading

Search for prior security audits:
- `specs/125_TRUSTED_PROXIES_SECURITY_audit.md`
- `specs/127_ENUM_AST_SECURITY_audit.md`
- `phase5-gateway/internal/auth/`
- `phase4-coordinator/internal/audit/` (if it exists)

Keep response under 800 words.
