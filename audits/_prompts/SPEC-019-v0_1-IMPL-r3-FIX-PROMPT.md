# SPEC-019 IMPL r3 polish (TIGHT — single MEDIUM)

Edit SPEC-019 IMPL on branch `impl/spec-019-v0-1` to absorb the lone
r3 MEDIUM. **Low reasoning effort. No commits. 1 source file + 1 test
file.**

5-of-6 r3 lanes already READY TO MERGE. Code lane found 1 MEDIUM:
WS-path envelope `type` drift. HTTP path passes through provider body
with `type:"upstream_provider_error"` (SPEC-019 §5 compliant). WS path
falls through to legacy `"upstream_error"` because `spec018ErrorType`
doesn't classify the new codes.

## A. Classify SPEC-019 codes in `spec018ErrorType`

File: `phase4-coordinator/internal/buyer/server.go` around `:5145`
(the `spec018ErrorType` function — grep for `func spec018ErrorType` to
locate exactly).

Add a case for the 2 SPEC-019 codes that returns
`"upstream_provider_error"`:

```go
case "malformed_json_response", "json_schema_validation_failed":
    return "upstream_provider_error"
```

Place this case ABOVE the default fallback so it short-circuits before
the legacy `"upstream_error"` default.

SPEC-019 §5 error table (lines 624, 630, 665) defines both codes as
HTTP 502 with `type:"upstream_provider_error"`. This makes WS-path
buyer envelopes byte-equivalent to HTTP-path buyer envelopes for the
same two codes.

## B. Update WS test assertion

File: `phase4-coordinator/internal/buyer/structured_output_provider_error_test.go:183-184`

Current test asserts `envelope.Error.Type != "upstream_error"` as
failure (meaning expected value is `upstream_error` — the drift).

Change to assert `envelope.Error.Type == "upstream_provider_error"`
(per SPEC §5). Match the HTTP-path test's assertion shape.

## Stop conditions

After editing:

1. `cd phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer 2>&1 | tail -3`
   - Expect: clean + pass.
2. `cd phase3-binary && swift test 2>&1 | tail -3`
   - Expect: 618 tests, 0 failures (unchanged).
3. `cd phase5-gateway && go vet ./... && go test -count=1 ./internal/router 2>&1 | tail -3`
   - Expect: clean + pass (unchanged).

Report:
- Files modified.
- Confirmation §A + §B done.
- Note if `spec018ErrorType` is the actual function name or whether it
  differs at HEAD (verify by grep first).

Done. No commit. r3b re-fire of code lane only (proven SPEC-018 v0.1.4
pattern) follows.
