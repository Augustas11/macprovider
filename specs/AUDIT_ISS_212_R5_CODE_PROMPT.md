# AUDIT — ISS-212 R5 — CODE lens

## Task

R5 code re-audit. R4 surfaced 2 MEDIUMs (URL construction bug
embedding `?account_id=...` into URL.Path; §5.6 path-parameter
description still claimed internal-OR-external). Both fixed in R5.

Branch: `spec/iss-212-explorer-composite-pk`.

## R5 deltas (relative to R4)

- `phase4-coordinator/internal/explorer/handlers.go`
  `handleSessionDetail`:
  - Switched to `fetchGatewayJSONStatusRawQuery` with separately-
    encoded `gwPath` (path only) and `gwQuery` (built via
    `url.Values{}.Encode()`).
  - Tightened to "both-or-nothing": gateway proxy fires ONLY when
    the resolved row supplies BOTH non-empty external_request_id
    AND non-empty account_id. Otherwise the response carries
    `gateway: {"error": {"code": "gateway_identity_unavailable"}}`.
- `phase4-coordinator/internal/explorer/handlers_test.go`
  `TestSessionDetailGatewayProxyUsesExternalRequestIDAndAccountID`
  rewritten to capture `r.URL.EscapedPath()` + `r.URL.RawQuery`
  separately, catching the false-positive URL-encoding class.
- New test `TestSessionDetailGatewayProxySkippedOnIncompleteIdentity`
  verifies that NULL-account rows do NOT trigger the gateway proxy.
- `phase4-coordinator/internal/explorer/handlers_test.go`
  `newTestExplorer` default fixture now carries
  `ExternalRequestID="buyer_seed_X"` + `AccountID="acct_seed"`
  so existing AC-07 test still exercises the gateway-proxy path.
- `specs/SPEC-007-explorer.md` §5.6:
  - Path parameter description fixed to "v0.3: coordinator-internal
    billing id only" with v0.4 deferral pointer.
  - Identity-model paragraph reworded as "both-or-nothing":
    proxy fires only when both fields are present; otherwise
    returns `gateway_identity_unavailable`.
- `specs/SPEC-007-explorer.md` AC-7 reworded: sub-cases now match
  the v0.3 coordinator-internal-id-only contract, with explicit
  "Deferred to v0.4" subsection covering the path-segment-overload
  + 409-on-external cases.

## What to audit

1. Does the URL construction now correctly send `account_id` as
   a real wire query parameter? Verify via the test that asserts
   on `r.URL.EscapedPath()` + `r.URL.RawQuery` separately.
2. Is the "both-or-nothing" contract correctly implemented? In
   particular: when `external_request_id` is empty OR `account_id`
   is empty, the gateway proxy MUST NOT fire at all (not even
   with internal-id fallback).
3. Does the SPEC §5.6 wording match the IMPL exactly? Look for
   any residual "fallback to internal id" or "forward unscoped
   external_request_id" claim.
4. Are AC-7's v0.3-only assertions consistent with the SPEC
   §5.6 contract?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
