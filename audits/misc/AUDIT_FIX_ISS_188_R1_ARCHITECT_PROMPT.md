# ISS-188 R1 — architect-lane audit prompt

Audit target: the diff on branch `fix/iss-188-xrequestid-propagation`
(PR https://github.com/Augustas11/macprovider/pull/195) against
`origin/main`. The change adds a coordinator-side
`request_log.external_request_id` column to carry the inbound
`X-Request-ID`, and the gateway forwards the buyer's id verbatim
to the coordinator. The PR is paired with SPEC-002 v1.4.2 addendum
(PR #192, R-2).

## Scope of this lane

You are the **architect lane**. Focus on:

- **Spec consistency.** SPEC-002 v1.4.1 §11 line 1291 says
  `request_id TEXT UUID v4 from inbound X-Request-ID when present,
  otherwise UUID assigned by coordinator`. A literal reading says
  request_id IS the inbound id. This PR sidesteps that by ADDING a
  new column `external_request_id` instead of flipping request_id's
  semantics. Is the additive approach defensible? Does it leave a
  spec gap that v1.4.2 R-2 (PR #192) should explicitly address?
- **Naming alignment.** The column name `external_request_id`
  matches a local variable in coord code but is unprecedented in
  the spec corpus. Is this name aligned with how SPEC-005 / SPEC-006
  describe cross-service correlation? Should it be `correlation_id`
  or `client_request_id` or `inbound_request_id`?
- **Cross-service ownership.** The PR touches coordinator and
  gateway. Gateway-side: did the change correctly identify
  `requestID(r)` as the SPEC-002 §11-honored id? Or is there a
  layer-1 gateway-middleware issue where requestID(r) itself
  doesn't faithfully reflect the inbound header (case mismatch,
  trim issues)?
- **Schema migration discipline.** Adding nullable columns to a
  live SQLite DB is the canonical safe pattern. Are there
  conventions in the project (e.g., gated by a feature flag,
  documented in BUILD_SPEC, requiring a separate DROP-old fallback)
  the PR should follow but skips?
- **Reconciliation contract surface.** The PR's reconciliation
  promise is `gateway.usage_events.request_id ==
  coord.request_log.external_request_id`. Is that the ONLY join
  key needed, or do other tables need similar plumbing (audit
  events, billing snapshots, payout ledger)?
- **Phase-C harness implications.** The internal e2e harness's
  reconciler will need to switch from fuzzy matching to the new
  column. Is there enough versioning / migration runway in the
  PR for the harness to know whether to use the old or new path?
- **Test coverage shape vs spec.** Do the new tests verify the
  spec-derivable invariant ("external_request_id == inbound
  X-Request-ID across all attempts of a logical request"), or do
  they test implementation details that could drift?

Out of scope for this lane (other lanes own):

- **Code lane:** SQL correctness, Go idiom, test runnability.
- **Security lane:** header trust, log injection, PII.

Do NOT duplicate their work.

## Files in the diff

```
phase4-coordinator/internal/buyer/billing_recorder.go
phase4-coordinator/internal/buyer/server.go
phase4-coordinator/internal/buyer/server_test.go
phase4-coordinator/internal/requestlog/store.go
phase5-gateway/internal/router/chat_proxy.go
phase5-gateway/internal/router/server_test.go
```

Reference docs:

- `specs/SPEC-002-coordinator.md` v1.4.1 — especially §11 lines
  2239-2243 (the X-Request-ID contract) and line 1291 (the schema
  description for request_log.request_id).
- The companion `specs/SPEC-002-v1.4.2-routing-contract-addendum.md`
  (PR #192) — especially R-2 which this PR implements against.
- `specs/SPEC-006-buyer-api.md` for the gateway-side contract.
- `specs/SPEC-005-*.md` (whatever the billing settlement spec is)
  for the provider-credit mirror, since this affects reconciliation.

PR body at https://github.com/Augustas11/macprovider/pull/195
explains the trade-off the PR makes (additive vs flip-the-semantics)
— address whether that trade-off is the right call.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **Aspect:** spec / naming / cross-service / migration / contract / harness / test-shape
- **Issue:** one-sentence statement
- **Evidence:** quote from the diff or referenced spec
- **Recommendation:** specific change. If a clause needs new wording
  in the v1.4.2 addendum, propose it.

Severity definitions:

- **CRITICAL:** clause-or-implementation will mislead future authors
  or break the contract. Must fix before this lands.
- **MAJOR:** materially weakens the spec or introduces ambiguity.
- **MINOR:** clarity improvement.
- **NOTE:** future-revision consideration.

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Keep response under 800 words.
