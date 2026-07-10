# SPEC-017 IMPL prompt — ARCH lane audit, Round 4 (Codex, 2026-06-26T03:57:47Z)

## Summary
- 1 CRITICAL finding
- 0 HIGH findings
- 0 MEDIUM findings
- 1 LOW finding
- 3 INFO

Round 4 confirms the stated r3 ARCH fixes are absorbed: `partner_keys_writer`
is default-off with no prompt-authored `SELECT(id)` widening, Step 2 owns only
rollup/table-state health setup while Step 3 owns `/health` JSON status, and
AC-15 is now split across Step 3 plus Step 4.A/4.B/4.C with an nginx access-log
scan. The remaining blocker is a prompt-authored Step 4 nginx resolution that
chooses AC-8 over the locked §5.6 public burst contract. That is an IMPL-prompt
problem, not a SPEC fix request.

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | PASS. The 4-step split is coherent; Step 4 is large but explicitly subdivided into 4.A/4.B/4.C under one ops PR. |
| B. Prerequisite coverage | PASS. Hostname, backfill, SPEC-016 re-check, provider identity trust, SPEC-014 v0.9 non-prereq, DSNs, DNS, Cloudflare, and nginx cutover gates are explicit. |
| C. Cross-step structural integrity | PASS except C1's Step 4 nginx contract issue. Step 3's partner-key auth can be tested with seeded `partner_keys` rows before the Step 4 CLI exists. |
| D. PR strategy | PASS. One PR per step, in-order squash-merge, rebase/reset discipline, and no Step N+1 opening before Step N merge are explicit. |
| E. Audit-loop discipline | LOW finding L1. Three lanes per step and `0 CRITICAL + 0 HIGH + 0 MEDIUM` convergence are otherwise preserved. |
| F. SPEC-prompt fidelity | CRITICAL finding C1. All ACs are mapped, and §11 Q1-Q13 are explicitly deferred. |
| G. Honesty about scope | PASS. The prompt names 4 PRs, 12-36 codex audits, per-step convergence files, final AC sweep, OPS.md, changelog, and cutover runbook deliverables. |

## CRITICAL findings

C1. Step 4 resolves locked public rate-limit semantics by silently dropping the §5.6 burst
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md` lines 401-407, 419, 486, 588; controlling SPEC §5.6 lines 881-889 and AC-8 lines 1785-1787.

   **Finding:** The locked SPEC says the public anonymous tier is `60 req/min per IP per endpoint` with `Burst 120`, enforced primarily by nginx. The locked AC-8 also requires the 61st request from the same IP in a 60s window to return 429. The IMPL prompt correctly observes that plain nginx `rate=60r/m burst=120 nodelay` will not reject the 61st request, but then instructs v0.1 IMPL to configure the public AC-8 surface without `burst=` and treats the SPEC's `120 burst` as something to recover only through a future SPEC candidate.

   **Why it matters:** SPEC-017 v0.1.6 is locked and §5.6 is part of the public API's abuse-control contract. A fresh IMPL author following the prompt would ship a production nginx config that intentionally omits a locked burst invariant. This is not a harmless test-shape choice: it changes public throttling behavior and uses the IMPL prompt to choose between two locked SPEC pins. Under the audit severity model, silently flipping a locked public contract from the IMPL prompt is CRITICAL even though the underlying contradiction is in the locked contract.

   **Suggested fix:** Rewrite the Step 4.B burst paragraph so the IMPL prompt does not pick a no-burst v0.1 production config. The prompt should state that Step 4 nginx rate-limit implementation is blocked until the controlling contract has one mechanical instruction for both §5.6 and AC-8; the IMPL author must not resolve the conflict by treating the locked `120 burst` as optional or v0.2-only. If a temporary local/nginx test harness omits burst solely to demonstrate AC-8 mechanics, label it non-production and forbid using it as the shipped §5.6 config.

## HIGH findings

None.

## MEDIUM findings

None.

## LOW findings

L1. Step 4 SECURITY-audit wording pressures auditors to manufacture findings
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md` lines 352-360.

   **Finding:** The prompt says the Step 4 SECURITY lane "MUST produce findings in each of 4.A, 4.B, 4.C" and that a lane finding zero issues in one subsection is suspicious. The intended architectural point is good: Step 4 has three distinct security-relevant surfaces. But the literal wording asks an auditor to produce findings even if a subsection is clean.

   **Why it matters:** This does not weaken the required three-lane convergence gate, so it is not MEDIUM. It can, however, create noisy low-value audit churn or make a final 0/0/0 security result look non-compliant with the prompt.

   **Suggested fix:** Reword to require explicit SECURITY coverage of each subsection, not mandatory findings: "The SECURITY audit lane MUST include a 4.A, 4.B, and 4.C sweep; a no-finding subsection must still record the evidence checked."

## INFO

I1. The r3 ARCH C1 fix is closed. `partner_keys_writer` is now optional/default-off, the role is skipped in v0.1, `last_used_at` remains NULL, and the prompt no longer instructs a `SELECT(id)` grant widening outside locked §7.2.4.

I2. The r3 ARCH H1 fix is closed. Step 2 keeps `stats_components_health` to bootstrap/table-state assertions, while `/v1/stats/health` JSON status derivation is assigned to Step 3.

I3. The r3 ARCH H2 fix is closed. AC-15 ownership now spans Step 3, Step 4.A, Step 4.B, and Step 4.C, including a keyed nginx request followed by access-log scanning.

## Operator questions

q1. None for the IMPL prompt author to answer inside code. The prompt must not encode a unilateral no-burst production resolution while §5.6 and AC-8 remain simultaneously locked.

## Verdict
- READY WITH FIX PASS

The prompt is not ready to lock while Step 4.B tells a fresh IMPL author to ship no-burst public nginx rate limiting as the v0.1 resolution. The fix pass can stay in `BUILD_SPEC_017_IMPL_PROMPT.md`: remove the prompt-authored production resolution and replace it with a hard implementation-blocking instruction for that subsection unless the controlling contract presents one mechanical public-rate-limit behavior.

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Read BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md fully and compared process/step/audit structure.
- [x] Read SPEC-017-advisor-round-2026-06-25.md.
- [x] Skimmed SPEC-017-r4-audit.md through SPEC-017-r7-audit.md for why locked MUSTs exist.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above.
- [x] Location line range included on every finding.
- [x] Suggested fix included for every CRITICAL and HIGH finding.
- [x] Verdict included.
