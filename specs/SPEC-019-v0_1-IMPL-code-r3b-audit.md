# SPEC-019 v0.1.5 IMPL r3b code-lane audit

Audited HEAD: `cb370b2` on `impl/spec-019-v0-1`.

**Verdict:** READY TO MERGE
**Tally:** C/H/M/m/Q = 0/0/0/0/0

## Closure verified

- r3 M-1 (WS envelope type drift): CLOSED. The r3 finding required `malformed_json_response` and `json_schema_validation_failed` WS terminal envelopes to use SPEC-019's upstream-provider envelope type instead of the legacy 502 fallback. The r3 polish routes both codes through `writeProviderStructuredOutputError` and now classifies both as `upstream_provider_error` in `spec018ErrorType` (`phase4-coordinator/internal/buyer/server.go:5078`, `:5100`, `:5155`). The WS regression assertion now matches the HTTP fixture and SPEC-019 §5 terminal envelope text (`phase4-coordinator/internal/buyer/structured_output_provider_error_test.go:23`, `:184`; `specs/SPEC-019-structured-output.md:624`, `:630`, `:665`).

## Fresh findings

None.

## Verdict justification

The rewrite is scoped to the previously failing envelope classification: it adds only the two SPEC-019 provider-detail codes to `spec018ErrorType`'s existing upstream-provider bucket, leaving legacy fallback behavior intact for unclassified codes (`phase4-coordinator/internal/buyer/server.go:5145`). The WS path still derives HTTP 502 from `wsEndHTTPStatus` and still preserves the provider end-frame retryability, `inference_ran:true`, and `settlement_ran:true` fields through `writeProviderStructuredOutputError` (`phase4-coordinator/internal/buyer/server.go:5087`, `:5091`, `:5103`, `:5105`).

Regression check found no new C/H/M issues. The HTTP test still requires byte-identical pass-through of the upstream provider body with `type:"upstream_provider_error"`, and the WS test now asserts the same buyer-visible type while preserving the no-fallback, request-log `error_code`, 502 status, zero provider credits, and `FaultBreakerQualifying` checks (`phase4-coordinator/internal/buyer/structured_output_provider_error_test.go:20`, `:82`, `:106`, `:184`, `:191`, `:198`, `:201`, `:204`).

Verification run:

- `go test ./internal/buyer -run 'TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetry'` in `phase4-coordinator`: pass.
- `go test ./internal/buyer` in `phase4-coordinator`: pass.
