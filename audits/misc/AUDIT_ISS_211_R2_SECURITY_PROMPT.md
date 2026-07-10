# AUDIT — ISS-211 R2 — SECURITY lens

## Task

R2 security re-audit. R1 found 1 HIGH (unconditional account
header would be rejected by coordinator without paired bearer)
and R2 fixed it by hoisting the upstream `Authorization` bearer
out of the sticky conditional. Re-check the security implications
of that R2 change — there is meaningful blast radius from sending
the gateway-service-token bearer on every chat forward.

Branch: `spec/iss-211-coordinator-account-scope`.

## R2 security deltas

- Every chat forward from the gateway to the coordinator now
  carries `Authorization: Bearer <UpstreamCoordinatorBearer>`
  AND `X-MacProvider-Account`. Previously the bearer was only
  set on the sticky path.
- The coordinator's `internalBearerAuthorized` audit log line
  now fires on every chat forward, including demo traffic.
- Demo subjects forward `demo:<X-Real-IP>` to coordinator via
  the new header path.

## Focus areas

1. **Buyer-supplied Authorization passthrough.** The gateway
   handler reads buyer's `Authorization: Bearer <mp_...>` to
   authenticate, then sets its own `Authorization: Bearer
   <UpstreamCoordinatorBearer>` for the upstream call. Verify:
   - The upstream `Set` overwrites any value `copyForwardHeaders`
     may have propagated from the buyer (would be a
     credential leak otherwise).
   - The integration test
     `TestStrangerKeyOpenAIChatUsageFlow` actually exercises a
     buyer with a real `mp_` key and asserts the buyer's key
     does NOT reach the coordinator (it now asserts on
     `Bearer operator-key`).
   - What if `copyForwardHeaders` happens to be allowlist-based
     and explicitly DOES copy `Authorization`? Is the
     subsequent `Set` order-correct?

2. **Increased blast radius of compromised UpstreamCoordinatorBearer.**
   Pre-v0.9.1 the bearer was only sent on sticky forwards.
   Post-v0.9.1 it's sent on every chat forward. Does this
   meaningfully change the attacker model:
   - An attacker who sniffs gateway → coordinator traffic
     pre-v0.9.1 could only steal the bearer on sticky requests.
     Post-v0.9.1 the bearer is on every TLS frame to the
     coordinator. (Both should be over TLS; net new exposure
     should be near-zero — verify.)
   - The bearer audit-log line in the coordinator now fires
     orders-of-magnitude more often. Is there a per-line cost
     (disk, alerting, downstream pipeline) the SPEC should
     warn operators about?

3. **Demo IP exposure (sustained).** R1 considered net new
   exposure low because the IP is already visible via
   X-Forwarded-For. R2 didn't change this but expanded the
   scope of where `demo:<ip>` lands (now also `request_log.account_id`,
   audited via the new internal-bearer log line, etc.). Re-verify
   the conclusion: is there a downstream consumer (admin
   dashboard, payout pipeline, public surface) that now sees the
   demo IP where it previously didn't?

4. **Header trust boundary persists.** With the bearer paired,
   the coordinator's `selectProviderExcluding` accepts the
   account header. But the value of `X-MacProvider-Account` is
   gateway-claimed: a compromised gateway can claim any
   `account_id` it wants. Confirm this is acknowledged in the
   threat model and is intentional (i.e., the coordinator
   trusts the gateway as an authority for account_id, as it
   already did on the sticky path).

5. **Downgrade attack via header suppression.** If an attacker
   can persuade the gateway to send empty `X-MacProvider-Account`
   (e.g., subverting `subject.AccountID = ""` somehow), the
   coordinator falls back to the unscoped COUNT query in
   hotpath.go. Is the failure mode safe — would the unscoped
   query expose data the scoped one wouldn't, or just count
   cross-account rows? The result is `ambiguous_attempt_n`
   zero-credit (audit-only, money-safe) — confirm.

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal SPEC or code edit>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

## Out of scope

- The R1 findings already addressed.
- Coordinator-vs-buyer network segmentation (assumed
  TLS-mutual or VPC-internal per existing threat model).
- Demo abuse rate-limiting (separate work).
