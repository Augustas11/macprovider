# SPEC-019 v0.1.5 IMPL -- round-3 critic (final defensive) audit

**Verdict:** READY TO MERGE
**Tally:** C/H/M/m/Q = 0/0/0/0/0

Scope: closure verification of r2 critic findings + 3 fresh blind-spot
probes specified by the r3 audit prompt. Bar: any unclosed or
regressed C/H/M from r2 OR any fresh C/H/M from the regression probe
blocks merge.

## Closure verified

### r2 minor 1 (`JSONValue.parse` `1.0 -> .int(1)` schema-side collapse) -- DEFERRED, as committed

- The r2 critic recorded this as MINOR, deferred to v0.2 polish in the
  absorption directive (`SPEC-019-v0_1-IMPL-r2-FIX-PROMPT.md` §D). The
  r2 absorption commit footer at `70b5c44` confirms the deferral. No
  regression; production parity preserved by the Go coordinator
  rejecting `1.0` schema literals at `server.go:3838-3844` before
  forwarding to the provider. Not a r3 blocker.

### r2 absorption surface A (WS-tunneled FaultBreakerQualifying) -- CLOSED

- Cite: `phase4-coordinator/internal/buyer/server.go:2125-2135`.
  `forwardWSNonStreaming` end-handling for `end.Status != "complete"`
  now constructs `attempt := requestLogAttempt{...}` and then
  conditionally promotes `FaultFlag` to `billing.FaultBreakerQualifying`
  via `isSpec019ProviderDetailCode(attempt.ErrorCode)` (line 2132-2134)
  before returning. The pre-existing `error_queue_full` shortcut
  (line 2127-2129) still returns early -- this is fine because
  `error_queue_full` cannot match the new predicate (the helper
  whitelists only the two SPEC-019 codes).
- The flag flows through unmodified into `recordRow` via the
  `attempt.FaultFlag` field, which `billing_recorder.go:181-183` reads
  directly (no overwrite path -- the recorder only defaults `""` to
  `FaultNone`).

### r2 absorption surface B (WS regression test) -- CLOSED

- Cite: `phase4-coordinator/internal/buyer/structured_output_provider_error_test.go:106-210`
  (`TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetryWS`).
  Pins both codes, asserts buyer-visible 502 + SPEC-019 envelope
  shape (message/type/code/retryable/inference_ran/settlement_ran),
  request-log `error_code` matches the SPEC-019 code, billing
  `provider_credits == 0`, billing `fault == FaultBreakerQualifying`,
  zero failover. Mirrors the HTTP-path test's contract closely.
- Test passes locally:
  `go test -count=1 -run "TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetryWS|TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetry$" ./internal/buyer`
  -> `ok 0.290s`.

### r2 absorption surface C (json_object scalar-root migration hint) -- CLOSED

- Cite: `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:46-54`.
  `validateJSONObjectOrArray` error message now reads:
  `"response_format json_object requires a top-level object or array. If you intended free-form prose, send response_format: {\"type\":\"text\"} or omit the field. Per SPEC-019 v0.1.0, json_object now enforces top-level JSON; this is a breaking change from earlier versions where json_object was a silent no-op."`
- Identical migration tail used by the empty-content
  (`ModelRuntime.swift:949`) and parse-fail
  (`ModelRuntime.swift:966`) messages. Buyer-facing parity preserved.
  No unexpanded placeholders, no quote-escaping defects (Swift
  `#"..."#` extended literal wraps the embedded double quotes around
  `"text"` cleanly).

## Fresh blind-spot probes

### Probe 1: `retryable` propagation across the WS hop into buyer envelope -- CLEAN

- The new WS path at `server.go:2130` calls `writeWSEndError(w, end)`,
  which at `server.go:5078-5079` branches on the SPEC-019 codes to
  `writeProviderStructuredOutputError(w, status, code, message, end.Retryable)`.
- `writeProviderStructuredOutputError` at `server.go:5087-5108` reads
  the `retryable *bool` parameter:
  - If non-nil, uses `*retryable` verbatim (line 5092-5094) -- the
    end-frame value wins.
  - If nil, falls back to `spec018Retryable(code)` (line 5091) which
    returns the SPEC-018 default for the code (false for both
    SPEC-019 detail codes per `ChatCompletionRequest.swift:289-290`).
- NOT hardcoded; correctly propagates `retryable` from provider end
  frame to buyer envelope. The new WS regression test pins
  `retryable: true` at `structured_output_provider_error_test.go:127`
  (provider end frame) and verifies it surfaces as `Retryable: true`
  on the buyer envelope at line 175 + 185-189. End-to-end propagation
  proven by test, not just inspection.

### Probe 2: HTTP vs WS path helper-sharing (`isSpec019ProviderDetailCode`) -- CLEAN

- Single definition at `server.go:4946-4948`:
  ```go
  func isSpec019ProviderDetailCode(code string) bool {
      return code == "malformed_json_response" || code == "json_schema_validation_failed"
  }
  ```
- Both call sites consume this helper:
  - HTTP path: `server.go:1866` -- `isSpec019ProviderDetailCode(attempt.ErrorCode)`.
  - WS path: `server.go:2132` -- `isSpec019ProviderDetailCode(attempt.ErrorCode)`.
- `grep -n "isSpec019ProviderDetailCode" phase4-coordinator/internal/buyer/server.go`
  returns exactly 3 hits (1 definition + 2 call sites). No duplicated
  inline check, no drift risk. If the SPEC-019 code allow-list ever
  needs extension, a single edit at line 4947 updates both paths.

### Probe 3: predicate over-broadness -- CLEAN

- `isSpec019ProviderDetailCode` literally compares against the two
  exact string constants `"malformed_json_response"` and
  `"json_schema_validation_failed"`. No prefix match, no regex, no
  case-insensitive comparison. Cannot accidentally trigger on any
  other end status.
- The WS branch at `server.go:2131-2134` runs the predicate on
  `attempt.ErrorCode`, which is the output of `spec001EndStatus(end.Status)`
  at line 2131. `spec001EndStatus` (`server.go:4937-4944`) whitelists
  six end statuses (the four legacy SPEC-001 codes plus the two new
  SPEC-019 codes); any unrecognized status maps to `""`, and
  `isSpec019ProviderDetailCode("")` is false. So a hypothetical
  rogue/legacy provider that emitted, e.g., `"error_model_not_loaded"`
  on a WS hop:
  - `spec001EndStatus("error_model_not_loaded") -> "error_model_not_loaded"`.
  - `isSpec019ProviderDetailCode("error_model_not_loaded") -> false`.
  - WS-path FaultFlag remains the zero value (becomes FaultNone at
    recordRow) -- the SAME billing treatment legacy SPEC-001 codes
    received before this absorption. No regression for the four
    legacy codes.
- The two new SPEC-019 codes are the ONLY codes the predicate accepts,
  and they are the ONLY codes for which the absorption changes
  billing semantics. Tight scoping.

## Additional defensive checks

### Streaming WS path is intentionally out-of-scope -- CLEAN

- `forwardWSStreaming` at `server.go:2315` returns a
  `requestLogAttempt` for the not-committed not-complete end branch
  WITHOUT setting `FaultFlag`. This was flagged as a candidate concern
  in r2 probe 3 (third-path risk for SPEC-019 codes), but is
  unreachable for the SPEC-019 codes because:
  - Coordinator rejects `stream:true` + `response_format: json_object`
    at `server.go:3674-3678` with code `streaming_json_object_unsupported`
    (HTTP 400) BEFORE provider dispatch.
  - Coordinator rejects `stream:true` + `response_format: json_schema`
    at `server.go:3679-3680` with code `streaming_json_schema_unsupported`
    (HTTP 400).
- A buyer cannot reach `forwardWSStreaming` with structured output
  active. Defense-in-depth (also setting `FaultBreakerQualifying` for
  SPEC-019 codes on the streaming branch at line 2315) would be
  cosmetic; not a finding.

### Buffered streaming WS path -- CLEAN

- `forwardWSStreamingBuffered` at `server.go:2440-2446` ALREADY sets
  `FaultFlag: billing.FaultBreakerQualifying` unconditionally for any
  non-complete end status. SPEC-019 codes (also rejected upstream by
  the `streaming_*_unsupported` gates) would be classified
  FaultBreakerQualifying anyway. No gap.

### Smoke baseline verified at HEAD `70b5c44`

- `go vet ./internal/buyer/...` -> clean.
- `go test -count=1 -run "TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetry$|TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetryWS" ./internal/buyer`
  -> `ok 0.290s`.

## Fresh findings

None.

## Open Questions

None at r3.

## Verdict justification

All r2 critic findings closed at the level the absorption committed
to. The lone r2 MINOR (Finding 4 -- `JSONValue.parse` schema-side
1.0 collapse) was explicitly deferred to v0.2 polish in the
absorption directive; the deferral is documented in the absorption
commit footer at `70b5c44` and remains a parity-invariant gap rather
than a money-path bug.

The three r2 surfaces (A: WS-path FaultBreakerQualifying classification;
B: WS-path regression test; C: json_object scalar-root migration
hint) are landed and exercised by the suite.

The three fresh r3 blind-spot probes targeted exactly the failure
modes that wouldn't naturally surface through architect/security/PD
lenses on a money-path classification fix:

1. `retryable` propagation: not hardcoded, threads from provider end
   frame through `writeProviderStructuredOutputError` to buyer
   envelope, end-to-end-proven by the new WS regression test.
2. Helper-sharing: HTTP and WS call sites consume the same
   `isSpec019ProviderDetailCode` definition; no inline duplication
   means no drift risk on future SPEC-019 code-list extensions.
3. Predicate over-broadness: strict-equal against two literals, no
   pattern/regex/prefix; cannot accidentally promote legacy codes to
   FaultBreakerQualifying. Confirmed by tracing every status through
   `spec001EndStatus` filter -- the four legacy codes flow through
   unchanged.

The two adjacent WS paths (`forwardWSStreaming` and
`forwardWSStreamingBuffered`) were probed as defensive third-path
candidates and dismissed: SPEC-019 codes cannot reach them because
the coordinator rejects `stream:true` + `response_format:
json_object|json_schema` at request validation with
`streaming_json_object_unsupported` / `streaming_json_schema_unsupported`
400s BEFORE provider dispatch.

Smoke baseline holds at HEAD: `go vet` clean, both HTTP and WS
SPEC-019 regression tests pass.

Realist Check: no CRITICAL/HIGH/MEDIUM findings survived to
pressure-test. The single MINOR from r2 was already mitigated and
deferred with explicit rationale.

I operated in THOROUGH mode throughout. No escalation to ADVERSARIAL
warranted -- the closure pass returned clean and all three fresh
blind-spot probes returned negative with cited evidence.

READY TO MERGE.
