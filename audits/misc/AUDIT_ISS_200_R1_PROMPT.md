# Audit prompt — ISS-200 R1

## What's under review

Branch `fix/iss-200-idempotency-replay-refund` against `origin/main`
(HEAD `3019238`). Closes [#200](https://github.com/Augustas11/macprovider/issues/200).

## Background — investigation completed

The issue body asked for empirical investigation of coordinator
behavior before picking Option A (gateway cache) vs B (refund-on-409)
vs C (composed). The investigation:

- Coordinator (`phase4-coordinator/internal/buyer/server.go:1337-1366`)
  enforces Idempotency-Key by storing `(key, body_hash, request_id)`
  in `request_idempotency_keys` table.
- On REPLAY (same key + same body): returns
  `409 idempotency_key_replayed` with no provider work.
- On KEY-BUT-BODY-DIFFERS: returns
  `409 idempotency_key_body_mismatch`.
- The coordinator does NOT serve cached responses (Option A
  scenario doesn't fire).

So Option B (refund-on-409 + passthrough) is the correct fix — no
gateway-side cache needed.

## What this PR does

1. New `coordinatorIdempotencyError(status, body) bool` in
   `phase5-gateway/internal/router/chat_proxy.go` — detects the two
   coord-issued 409 idempotency codes.
2. Adds a check for that condition at the top of the `!= 200`
   handling in both `forwardNonStreamingChat` and
   `forwardStreamingChat`, before the existing
   `settleBeforeResponse(... "upstream_error")` path.
3. On match: calls existing `passThroughNoProviderCoordinatorError`
   helper — refunds reservation + passes through coord status/body.
4. Regression test `TestCoordinatorIdempotencyReplayPassesThroughAndRefunds`
   asserts: 409 preserved (not remapped to 502), envelope intact,
   no quota burn, no reservation hold. Covers both codes × both
   transports (stream / non-stream) = 4 subtests.

## Severity bar (CRITICAL/HIGH only)

Three independent lanes (code / security / architect). Report ONLY
CRITICAL or HIGH. Optional MEDIUM advisory below.

## CODE lane

1. Is the check ordering correct in both forward functions? Could
   any later branch (Tier-2, null-usage, completion-from-header)
   ever fire for a 409 and conflict with the new refund path?
2. `coordinatorIdempotencyError` reads `openAIErrorCode(body)` —
   any pitfall when coord returns 409 with no body or a malformed
   body?
3. The streaming path reads body via `io.ReadAll(resp.Body)` —
   same as the existing Tier-2 detection. Compatible?
4. `passThroughNoProviderCoordinatorError` refunds + passes
   through. Is the refund truly idempotent when called twice (e.g.,
   if the check accidentally also matches a non-idempotency 409
   that someone adds in the future)?

## SECURITY lane

1. Could a malicious coordinator-side actor (or a bug in the coord
   binary) return a 409 with `code=idempotency_key_replayed` to
   AVOID being billed for a legitimate completion? (Risk model:
   coord is trusted but bugs happen.)
2. Could a buyer SDK abuse this path — e.g., send a request that
   coord processes successfully but then send a duplicate to
   trigger refund? (Note: original request still settled normally,
   so no double-refund scenario.)
3. Body-mismatch case: same key + different body. Should the
   gateway treat this differently from clean replay? Both currently
   refund + passthrough — is that the right outcome?

## ARCHITECT lane

1. SPEC alignment — does any spec text constrain how the gateway
   handles coord 409? SPEC-006 / SPEC-002 idempotency contract.
2. Consistency — the existing Tier-2 and 404 passthrough paths
   follow the same shape. New 409 path matches their pattern?
3. Forward-compat — if coord adds NEW 409 codes (e.g.
   `idempotency_key_expired`), should they automatically refund
   too, or is the explicit code-list approach safer?
4. Should the gateway track "saw idempotency replay" anywhere for
   ops visibility (audit_events row)?

## Output format

```
SEVERITY: <CRITICAL|HIGH>
TITLE: <short>
FILE: <path>:<line>
DETAIL: <what fires / why wrong>
SUGGESTED FIX: <action>
```

Plus optional advisory MEDIUMs.

If 0 CRITICAL/HIGH: output exactly `0 CRITICAL / 0 HIGH`.
