# AUDIT — Fix iss-190 (concurrency rate-limit headers + N=3) — R1 SECURITY lane

## Scope

Same as the CODE prompt — the four files in
`/Users/augstar/macprovider-fix-190`. Read
`git diff origin/main..HEAD`.

## Context

Same as the CODE prompt.

## You are the SECURITY auditor

Score CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **0 C/H/M**.

The gateway is money-path: any header that leaks per-account state
to other tenants is a real concern. Specifically check:

1. **Tenant-state leakage in headers.**
   `X-RateLimit-Remaining-Requests` reveals the current per-account
   in-flight count. Is this safe on responses cached by upstream
   CDNs or proxies (CORS, Vary headers)? Could a buyer observe
   another buyer's state via a shared cache?
2. **Bumping default N from 2 to 3.** Does the higher cap meaningfully
   change DoS risk against the provider pool? Reference: phase-A
   M1-8 / PERF-6 documented that 3+ concurrent demo requests
   saturated the MLX-serialized provider pool for up to
   CoordinatorTimeout. With DemoConcurrency now also = 3,
   is that regression risk acceptable?
3. **Retry-After=1 second.** SDKs that honor Retry-After will
   retry every 1s indefinitely. Is the rate-limiter's per-account
   bookkeeping resilient to a tight retry loop? Could a malicious
   client convert 429-with-Retry-After=1 into a sustained
   per-account log-spam DoS?
4. **No new headers on the error body.** Confirm the new headers
   are HTTP response headers only — no JSON body change introduces
   information disclosure (Active count in error body, for
   example).
5. **Default-value changes vs deployed config.** Operators on
   `account_concurrency: 2` in their YAML keep N=2; the default
   change only affects fresh installs. Is this consistent with
   the project's "no silent behavior change for existing
   deployments" posture?
6. **Header ordering / overwrite.** `setConcurrencyRateLimitHeaders`
   on admit, then later code may call `setRateLimitHeaders`
   (token-quota headers). Could one overwrite the other? Could
   upstream-proxy response headers clobber the gateway's
   rate-limit headers? Confirm by reading the
   `copyCleanHeaders` / `copyReceiptEligibleHeaders` paths.
7. **No auth bypass / token leakage.** Confirm the changes do NOT
   touch authentication, token bearer headers, or receipt
   eligibility.

Out of scope: anything outside the four files.

## Output format

Same as CODE prompt — per-finding SEVERITY / Location / What / Why
it matters / Suggested fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
