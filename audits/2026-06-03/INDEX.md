# macprovider-poc — Full Codebase Audit (2026-06-03)

Three-lens audit (code quality, security, architecture) of the P2P AI-inference
marketplace settling real USDC across three trust tiers: the Swift provider
binary (untrusted contributor Macs), the Go coordinator (trusted money
authority), and the Go gateway (internet edge).

## Method

28 audit cells — 12 components × {code-reviewer, security-reviewer} + 4
`architect` system views — each read real source for its component, then **every
raw finding was handed to an adversarial verifier** that re-read the cited
`file:line`, refuted false positives, and assigned an evidence-backed
`adjustedSeverity`. 59 agents, ~1.87M tokens. 137 raw findings → **135 verified**
(2 false positives dropped).

## Reports

| Report | Findings | Critical | High | Medium | Low | Info |
|--------|---------:|---------:|-----:|-------:|----:|-----:|
| [Code Quality](CODE_AUDIT.md) | 62 | 0 | 4 | 6 | 35 | 17 |
| [Security](SECURITY_AUDIT.md) | 49 | 0 | 4 | 7 | 29 | 9 |
| [Architecture](ARCHITECTURE_AUDIT.md) | 24 | 1 | 4 | 7 | 11 | 1 |
| **Total** | **135** | **1** | **12** | **20** | **75** | **27** |

Raw verified findings (machine-readable): [findings-raw.json](findings-raw.json)

## The one theme that matters most

**The untrusted provider controls the billing input.** The coordinator pays
providers in USDC on **self-reported `completion_tokens`** read verbatim from the
provider's `inference_response_end.usage` frame, with no server-side metering and
no cross-check on reconcile. Every other defense (the Pillar-D output-byte cap,
attestation, settlement idempotency) is moot while the party being paid also
declares the amount. This single trust-boundary violation is the Architecture
CRITICAL, the #1 Security HIGH, and the root of two Code HIGHs.

## Master remediation order (cross-lens)

1. **Stop trusting provider-declared token counts** (ARCH-CRIT, SEC-HIGH payout,
   ARCH-HIGH Pillar-D cap). Count completion tokens server-side from the bytes
   the coordinator already proxies; bill `min(provider_reported, server_observed)`
   and clamp on reconcile. Wire the existing-but-unused `OutputBytesPerTokenCeiling`.
2. **Take the billing `request_id` away from the client** (SEC-HIGH X-Request-ID).
   Generate it server-side; make `(request_id, attempt_n)` a real idempotency key
   that re-bills or 409s instead of silently zero-crediting. Today any normal
   authenticated buyer gets free inference by pinning one UUIDv4.
3. **Fix streaming settlement correctness** (CODE-HIGH ×2): gateway checks
   `scanner.Err()` so truncated/failed SSE isn't billed as `ok`
   (`phase5-gateway/internal/router/server.go:1475-1531`); coordinator raw-HTTP
   path checks `r.Context().Err()` before blaming the provider for a buyer
   cancel (`phase4-coordinator/internal/buyer/server.go:1664-1692`).
4. **Make the signing key non-overridable** (SEC-HIGH supply-chain). Remove the
   `MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM` env override (or DEBUG-gate it); prefer
   CryptoKit P256 over shelling to `openssl`.
5. **Bound the internet-facing/hijacked sockets** (SEC-HIGH WS DoS, CODE-HIGH
   rate-limiter): WS read/idle deadlines + max-frame cap before auth; replace the
   spoofable, never-evicting `X-Forwarded-For` limiter on `/v1/pool/check`.
6. **Address the availability SPOFs** (ARCH-HIGH ×3): the coordinator holds all
   pool/session/relay state in memory and the advertised multi-coordinator
   failover does not exist in code — either implement it or stop advertising it;
   add WS ping/pong + TCP keepalive + no-sleep assertion on the provider leg.
7. **Sweep the recurring low-stakes pattern**: non-constant-time operator/admin
   bearer-token comparison recurs across ~5 sites in both Go services while
   `crypto/subtle` / `hmac.Equal` already exist in-tree. One shared helper.
8. **Operator-data integrity**: gateway LEFT JOIN fan-out inflates per-buyer
   usage totals (CODE-HIGH); `request_log` has no retention/pruning (PII +
   unbounded growth).

See each report's own "Prioritized remediation roadmap" for the full ordered
batches including medium/low items.
