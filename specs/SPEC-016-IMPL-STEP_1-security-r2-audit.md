# SPEC-016 IMPL Step 1 — codex SECURITY REVIEW lane, round 2

**Scope:** `fc3bf56` fix-pass, focused on `phase4-coordinator/internal/payout/{addresses.go,topology.go,eip712.go,deny.go,migrations.go}`, `cmd/coordinator/main.go`, config/security startup wiring, and payout tests.  
**Risk Level:** LOW  
**Verdict:** CLEAN

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| 0 | 0 | 0 | 0 |

## r1 closures verified from security lens

| r1 ID | Lane | Closure verdict | Notes |
|-------|------|-----------------|-------|
| code:1.1 | code | CLOSED | Rotation reads `payout_allowed` inside `BEGIN IMMEDIATE` and returns 409 before update when disabled: `addresses.go:356`, `addresses.go:410`, `addresses.go:433`. Disabled row remains untouched. |
| code:1.2 | code | CLOSED | Anti-replay key is derived from decoded nonce bytes with `hex.EncodeToString`, not request string casing: `addresses.go:308`, `addresses.go:347`. |
| arch:1.3 | arch | CLOSED for Step 1 | Empty/malformed hot-wallet pin fails before handler mount via `LoadSecurityConfig` and topology assertion: `main.go:605`, `main.go:615`, `topology.go:77`, `topology.go:80`. Step 2 still must tighten runner co-residency. |

## Regression probe matrix

| Probe | Verdict | Evidence |
|-------|---------|----------|
| Adversary A: stolen token against `payout_allowed=0` | PASS | Targeted test returns 409 `payout_not_allowed`; address and flag unchanged. |
| Compliance-gate race posture | PASS | Existing row read and update share same `BEGIN IMMEDIATE`; no Step 1 alternate code path flips `payout_allowed` outside this lock. |
| Nonce rollback side-channel | PASS / documented | Temp probe repeated same valid nonce after 409; both attempts returned 409, nonce table stayed empty. This favors legitimate retry liveness; attacker can retry same nonce against disabled state until future §3.3 rate-limit exists. SPEC does not mandate burn-vs-rollback for this 409 branch. |
| `0x` / `0X` nonce replay | PASS | `TestServePayoutAddress_NonceCanonicalisation_0XReplayDefeated` passed; table holds one canonical nonce row. |
| `hex.EncodeToString` lowercase canonical form | PASS | Go stdlib emits lowercase hex; no environment-dependent casing path. |
| Empty hot-wallet pin startup | PASS | `TestAssertPayoutRuntimeTopology_EmptyHotWalletPinRejected` passed; `setupPayout` fails before service/mux construction. |
| Malformed hot-wallet pin startup | PASS | `TestAssertPayoutRuntimeTopology_InvalidHotWalletPinRejected` passed; EIP-55 validation rejects. |
| Independent ethers.js EIP-712 vector | PASS | Temp ethers v6 vector accepted by Go verifier; digest matched `0xcc905f9e...733f8b4e`. |
| 8-connection `PRAGMA synchronous=FULL` | PASS | Temp probe opened 8 SQLite conns; all reported `synchronous=2`. |
| TOCTOU pause re-check | PASS | `TestServePayoutAddress_TOCTOUPauseFlipDuringTxn_NoRowWritten` passed with 503. |
| Hot-wallet self-payment denial | PASS | `TestServePayoutAddress_DenyList` passed with 400 `denylist`; deny-list includes hot wallet at `deny.go:46`. |
| `v=0/1` signature rejection | PASS | `TestVerifyEIP712_BadVRejected` passed; `eip712.go:177` enforces `{27,28}` only. |

## New findings

None.

## Tests run

- `go test -count=1 -race ./internal/payout/...` — PASS
- `go test -count=1 ./...` from `phase4-coordinator` — PASS
- Focused payout regression test run — PASS
- `govulncheck ./...` — PASS, 0 reachable vulnerabilities
- Secrets scan over Step 1 payout/config/main paths and git-history slice — no production secrets found; only test fixtures / symbolic config names surfaced
- Temp-copy probes: ethers.js EIP-712 vector, 409 nonce rollback behavior, 8-connection PRAGMA check — PASS

## Cross-cutting security observations

- The 409 rollback behavior is security-defensible but rate-limit-sensitive: repeated same-nonce probes are possible against a disabled row. This is not a money-out bypass because `payout_allowed=0` remains enforced, but Step 3 / rate-limit work should not lose the §3.3 429 requirement.
- `RunnerCoResident=false` still passes by design in Step 1 (`topology.go:92`). That is acceptable only while no runner exists; Step 2 must make split-process handler+runner startup impossible.

## Security Checklist

- [x] No hardcoded production secrets found
- [x] All reviewed request inputs validated/bounded
- [x] Injection prevention verified: SQL uses placeholders
- [x] Authentication/authorization verified for provider-token path
- [x] EIP-712 proof-of-possession verified against independent ethers.js vector
- [x] Dependencies audited with `govulncheck`
- [x] OWASP Top 10 categories considered for the reviewed Step 1 surface
tokens used

---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-1-security-review-lane-round-2026-06-25T15-22-25-683Z.md; agent-role tools (Write/Edit) were disallowed so codex returned the report in its artifact body. Claude transcribed verbatim — no edits._
