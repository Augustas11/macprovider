# ISS-188 R1 — code-lane audit prompt

Audit target: the diff on branch `fix/iss-188-xrequestid-propagation`
(PR https://github.com/Augustas11/macprovider/pull/195) against
`origin/main`. The change adds an `external_request_id` column to
`request_log`, plumbs the inbound `X-Request-ID` through the
coordinator's billing recorder, and changes the gateway to forward
the buyer-visible request id to the coordinator verbatim. It also
adds 2 new tests on the coordinator side and flips 1 test assertion
on the gateway side.

## Scope of this lane

You are the **code lane**. Focus on:

- Correctness of the SQL / migration / scan changes.
- Go-idiom hygiene (nil safety, error handling, struct field
  placement, exported vs unexported, naming consistency).
- Test coverage — are the two new tests sufficient? Any obvious
  failure modes uncovered? Do they assert the right thing?
- Backwards compatibility — does the additive `ALTER TABLE` work on
  a live SQLite WAL DB without disturbing live writers? Does a
  pre-fix row (no external_request_id column) survive query through
  the new helper that scans it?
- Concurrency — is `externalRequestID` propagated correctly through
  the per-request `billingRecorder` actor-ish boundary? Is the field
  set once at construction and never mutated?
- Dead code / unused symbols / commented-out lines.

Out of scope for this lane (other lanes own):

- **Security lane:** header trust, replay/spoofing, log-injection,
  PII via X-Request-ID, TOCTOU on sanitization.
- **Architect lane:** spec consistency vs SPEC-002 §11, contract
  shape, cross-service ownership, naming alignment with SPEC-006,
  observability, downstream impact on phase-C harness.

Do NOT duplicate their work — flag if a finding overlaps and let
the other lane own it.

## Files in the diff

```
phase4-coordinator/internal/buyer/billing_recorder.go
phase4-coordinator/internal/buyer/server.go
phase4-coordinator/internal/buyer/server_test.go
phase4-coordinator/internal/requestlog/store.go
phase5-gateway/internal/router/chat_proxy.go
phase5-gateway/internal/router/server_test.go
```

Useful command to view the diff locally:
```
git diff origin/main -- phase4-coordinator/ phase5-gateway/
```

The PR body is at
https://github.com/Augustas11/macprovider/pull/195 — read it for the
approach + rationale.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **File:line(s):** exact reference
- **Issue:** one-sentence statement
- **Evidence:** quote the offending code
- **Recommendation:** specific change. Propose new code when relevant.

Severity definitions:

- **CRITICAL:** the change will mislead implementors or cause a
  real bug. Must fix before this lands.
- **MAJOR:** materially weakens correctness or introduces ambiguity
  that WILL be exploited / misread. Should fix.
- **MINOR:** style / structure improvement; correct as-is but
  cleaner wording exists.
- **NOTE:** observation that may inform a future revision; no
  change required.

End with a single summary line:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Be honest about what you DON'T have evidence to judge. Better to
flag "uncertain — need [X]" than to invent confidence.

## Files to read

- The diff above.
- `phase4-coordinator/internal/requestlog/store.go` in full for
  migration ordering / column index correctness.
- `phase4-coordinator/internal/buyer/server_test.go` lines 1045-1200
  for the existing test pattern the new tests sit alongside.
- `phase5-gateway/internal/router/chat_proxy.go` lines 180-230 for
  the gateway forward path context (header copying, sticky
  conditional Authorization header, error refund path).
- Optionally, `phase4-coordinator/internal/buyer/billing_recorder.go`
  in full to see all sites that read `b.externalRequestID`.

Keep total response under 800 words. Quality over quantity.
