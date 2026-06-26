# SPEC-017 IMPL prompt — ARCH lane audit, Round 5 (Codex, 2026-06-26T04:06:01Z)

## Summary
- 0 CRITICAL findings
- 0 HIGH findings
- 0 MEDIUM findings
- 0 LOW findings
- 4 INFO

Round 5 confirms the r4 ARCH blockers are absorbed. Step 4.B no longer silently picks a no-burst production nginx configuration over locked §5.6; it now blocks production rate-limit implementation until the operator either reconciles the SPEC in v0.1.7 or records an explicit divergence, while allowing a clearly labeled non-production AC-8 harness only for CI. The Step 4 SECURITY wording now requires subsection sweep + evidence instead of manufactured findings. I found no remaining prompt-level architecture issue that would cause a fresh IMPL author to violate SPEC-017 v0.1.6, weaken step boundaries, or skip the per-step/per-lane audit gates.

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | PASS. The four-step split remains coherent: Step 1 owns schema/roles/grants/visibility storage, Step 2 owns rollup/table state, Step 3 owns request-path handlers/auth/CORS/redaction, and Step 4 is one ops PR with explicit 4.A/4.B/4.C sub-seams. |
| B. Prerequisite coverage | PASS. Hostname and backfill are framed as locked/default implementation shapes plus cutover choices; SPEC-016 re-check, provider identity trust, Postgres role/DSN provisioning, DNS, Cloudflare, nginx, and SPEC-014 v0.9 non-prereq status are explicit. |
| C. Cross-step structural integrity | PASS. Step 2 no longer requires handler JSON assertions; Step 3 can test partner-key auth with seeded `partner_keys` rows before CLI exists; Step 4.B nginx production work is explicitly blocked rather than smuggled into earlier steps. |
| D. PR strategy | PASS. One PR per step is mandatory; step branches are created from squash-merged prior tips; rebase/reset discipline and no Step N+1 PR before Step N merge are explicit. |
| E. Audit-loop discipline | PASS. Every step requires ARCH, CODE, and SECURITY lanes, fresh per-lane files, and `0 CRITICAL + 0 HIGH + 0 MEDIUM` convergence before PR. Step 4 SECURITY coverage now requires evidence per subsection, not artificial findings. |
| F. SPEC-prompt fidelity | PASS. The four locked design picks are preserved; §9.1 schemas, §7.2 grants, §5.4.1 partner keys, §6.1/§6.5 visibility tables, all 21 ACs, and §11 Q1-Q13 deferrals are carried forward. |
| G. Honesty about scope | PASS. The prompt names 4 PRs, 12-36 expected codex audits, final AC sweep, OPS.md, changelog, cutover runbook, and the Step 4.B rate-limit reconciliation stop condition. |

## CRITICAL findings

None.

## HIGH findings

None.

## MEDIUM findings

None.

## LOW findings

None.

## INFO

I1. The r4 ARCH C1 fix is closed. `BUILD_SPEC_017_IMPL_PROMPT.md` lines 411-420 now state that production nginx rate-limit config is blocked on SPEC reconciliation or recorded operator divergence, and the no-burst AC-8 harness is test-only and must not be shipped.

I2. The r4 ARCH L1 fix is closed. `BUILD_SPEC_017_IMPL_PROMPT.md` lines 358-366 now require Step 4 SECURITY to sweep 4.A/4.B/4.C and record evidence for clean subsections, without requiring findings where none exist.

I3. The prior ARCH closures remain intact: `partner_keys_writer` stays default-off with no prompt-authored grant widening; Step 2 owns health table state while Step 3 owns `/health` JSON derivation; AC-15 remains distributed across Step 3 and Step 4.A/4.B/4.C.

I4. The SPEC-016 analog's conceptual seams are covered in the SPEC-017 shape despite the simpler surface: pre-flight gates, step/PR workflow, audit-loop mechanics, repo layout/package boundaries, explicit deferrals, budget/cadence, final deliverables, and "not done when code compiles" criteria all have homes.

## Operator questions

q1. None for the IMPL prompt author. The only operator branch is already explicit in Step 4.B: reconcile §5.6/AC-8 in a SPEC v0.1.7 candidate, or record a deliberate production divergence before that subsection kicks off.

## Verdict
- READY TO LOCK

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Read BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md fully and compared process/step/audit structure.
- [x] Read SPEC-017-advisor-round-2026-06-25.md.
- [x] Skimmed SPEC-017-r5-audit.md through SPEC-017-r7-audit.md for why locked MUSTs exist.
- [x] Reviewed SPEC-017-IMPL-PROMPT-arch-r1-audit.md through r4 for closure continuity.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above. No findings required severity assignment.
- [x] Location line range included on every finding. Not applicable; no findings.
- [x] Suggested fix for every CRITICAL and HIGH finding. Not applicable; no CRITICAL or HIGH findings.
- [x] Verdict included.
