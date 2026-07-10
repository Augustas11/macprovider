# SPEC-019 IMPL r2 absorption (TIGHT — single targeted commit)

Edit SPEC-019 IMPL on branch `impl/spec-019-v0-1` (worktree
`/Users/augstar/macprovider-impl-spec-019-v0-1`) to absorb r2 findings.

**Low reasoning effort. No SPEC body edits. No commits — let me commit
once at the end. 3 targeted surfaces only.**

Aggregate r2: 1 CRITICAL + 1 HIGH + 1 MEDIUM + 1 minor (deferred to v0.2).
3 of 6 lanes already READY TO MERGE (code, critic, narrative).

The CRITICAL + HIGH are convergent (architect + security found same
issue): WS-tunneled non-streaming path doesn't set `FaultBreakerQualifying`
even though r1 closed the HTTP path. Third layer of the same money-path
classification gap.

## A. CRITICAL + HIGH — Set FaultBreakerQualifying on WS-tunneled SPEC-019 errors

**Convergent**: architect C-1 + security H-1.

File: `phase4-coordinator/internal/buyer/server.go:2125-2131`
(`forwardWSNonStreaming` end-handling, around the `requestLogAttempt`
return for non-`complete` end statuses).

Currently the WS path returns a `requestLogAttempt` with only `Status`,
`Error`, `ErrorCode` for any non-`complete` end status — `FaultFlag` is
left empty. `recordRow` at `billing_recorder.go:181-183` defaults
empty `FaultFlag` to `billing.FaultNone`, so the SPEC-019 codes get
wrong billing semantics (FaultNone, not FaultBreakerQualifying).

Fix: when `end.Status` is `malformed_json_response` or
`json_schema_validation_failed`, set `FaultFlag: billing.FaultBreakerQualifying`
on the returned `requestLogAttempt`. Use an `isSpec019ProviderDetailCode`
helper if it already exists from r1; otherwise inline the 2-code check.

Exact pattern (adjust to actual code structure):

```go
// In forwardWSNonStreaming, around server.go:2125-2131
attempt := requestLogAttempt{
    Status:    failureStatus,
    Error:     end.ErrorMessage,
    ErrorCode: spec001EndStatus(end.Status),
}
if isSpec019ProviderDetailCode(attempt.ErrorCode) {
    attempt.FaultFlag = billing.FaultBreakerQualifying
}
return attempt
```

If `isSpec019ProviderDetailCode` doesn't exist as a helper yet, define
it co-located with `spec001EndStatus` (~`server.go:4942`):

```go
func isSpec019ProviderDetailCode(code string) bool {
    switch code {
    case "malformed_json_response", "json_schema_validation_failed":
        return true
    default:
        return false
    }
}
```

## B. New WS-tunneled money-path regression test

File: `phase4-coordinator/internal/buyer/structured_output_provider_error_test.go`
(extend existing) OR new file
`phase4-coordinator/internal/buyer/structured_output_ws_provider_error_test.go`.

Mirror `TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetry`
(which covers HTTP path) for the WS-tunneled non-streaming path. Assert
for each of `malformed_json_response` and `json_schema_validation_failed`:

- Buyer-visible status preserved (502 with original envelope shape).
- Buyer-visible error code preserved (no collapse to `provider_error`).
- Request-log row's `error_code` is the SPEC-019 code.
- Request-log row's `fault_flag` is `FaultBreakerQualifying` (NOT
  `FaultNone`).
- Zero provider-positive credits (ComputeCredits returns 0 because of
  the fault flag).
- No retry/failover (the terminal handler ran once).

Match the test naming convention of the existing HTTP test (e.g.,
`TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetryWS` or
similar — match what's in the worktree).

## C. MEDIUM — extend `json_object` valid-scalar message with migration hint (PD-M1)

File: `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:46-54`
(`validateJSONObjectOrArray` function).

Current message:
```
response_format json_object requires a top-level object or array
```

Replace with:
```
response_format json_object requires a top-level object or array. If you intended free-form prose, send response_format: {"type":"text"} or omit the field. Per SPEC-019 v0.1.0, json_object now enforces top-level JSON; this is a breaking change from earlier versions where json_object was a silent no-op.
```

(Same migration hint as the empty-content and parse-fail messages
from r1.)

Update or add a test in
`phase3-binary/Tests/macprovider-cliTests/JSONSchemaValidatorTests.swift`
(or wherever `testJsonObjectRequiresObjectOrArray` lives) to assert
the message includes the migration string `response_format: {"type":"text"}`
OR `omit the field`.

## D. Defer to v0.2 polish (critic m-1, no action)

Schema-side `JSONValue.parse` collapses `1.0` → `.int(1)`. Coordinator
already rejects `1.0` in schemas before forwarding to provider, so
production parity is preserved. Document as a v0.2 polish item in the
absorption commit message footer; no SPEC edit needed.

## Stop conditions

After editing, run all 3 smoke tests:

1. `cd phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer 2>&1 | tail -5`
   - Expect: clean + pass. New WS test included.
2. `cd phase3-binary && swift test 2>&1 | tail -5`
   - Expect: 617 + 1 new test, 0 failures.
3. `cd phase5-gateway && go vet ./... && go test -count=1 ./internal/router 2>&1 | tail -5`
   - Expect: unchanged, clean + pass.

Report:

- Files modified (list).
- Confirmation §A/§B/§C are addressed.
- Test count growth.
- The `isSpec019ProviderDetailCode` helper: did it already exist from
  r1, or did you create it now? (If already exists, list its
  location.)

Done. No commit. No re-audit. r3 fires next (defensive) — should
converge to 0/0/0 with this absorption since all r2 issues are tightly
scoped.
