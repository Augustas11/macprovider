# SPEC-017 IMPL prompt — ARCH lane audit, Round 6 (Codex, 2026-06-26T04:55:47Z)

## Summary
- 2 CRITICAL findings
- 2 HIGH findings
- 2 MEDIUM findings
- 0 LOW findings
- 2 INFO

This v0.1.7 re-anchor is substantially aligned with the locked SPEC deltas, but it is not ready to lock. Two Step 4.B instructions would let a fresh IMPL author violate locked public-API behavior: the edge-cache test tells nginx to serve the same cached public response to `Authorization: Bearer garbage` as to anonymous traffic, contradicting AC-3, and the rate-limit section still permits an operator-recorded divergence from either §5.6 or AC-8 without a locked SPEC change. I also found one step-boundary regression around AC-15 redaction ownership and one launch-sequencing/prerequisite ambiguity around SPEC-014 v0.9.

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | FAIL. The main four-step split is coherent, but Step 3's AC-15 test bullet re-claims nginx and metrics redaction surfaces owned by Step 4.B/4.C. |
| B. Prerequisite coverage | FAIL. SPEC-014 v0.9 is simultaneously described as not a production blocker and as required actual sign-off evidence before Step 4.C convergence. |
| C. Cross-step structural integrity | MIXED. Step 2/3 rollup-to-handler seams are mostly explicit, and Step 3 can test keyed auth with seeded rows before the CLI. The AC-15 ownership text still bleeds Step 4 observability surfaces into Step 3. |
| D. PR strategy | PASS. One PR per step, ordered branch creation, reset/rebase discipline, and "Step N+1 MUST NOT open" are explicit. |
| E. Audit-loop discipline | PASS. The prompt requires ARCH/CODE/SECURITY per step and `0 CRITICAL + 0 HIGH + 0 MEDIUM` convergence before PR. |
| F. SPEC-prompt fidelity | FAIL. Step 4.B's cache test violates AC-3, and Path R2 permits knowingly shipping behavior that violates either §5.6 or AC-8. |
| G. Honesty about scope | MIXED. Audit cost and final gates are explicit, but the rate-limit contradiction is treated as optionally shippable divergence and the launch-sequencing sign-off is not scoped to cutover vs PR convergence. |

## CRITICAL findings

C1. Step 4.B tells the edge cache to turn invalid `Authorization` into cached public 200
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:527-532` (with related bypass rule at `:520-522`)
   **Finding:** The edge-cache test says: send a public request with `Authorization: Bearer garbage`, then an anonymous request, and the edge cache "SHOULD serve the same cached response to both." That directly contradicts SPEC-017 AC-3 (`Authorization: Bearer mpk_invalid` returns 401 `unauthorized`) and §5.2's invalid/revoked Authorization rule. It also contradicts the prompt's own `proxy_cache_bypass $http_authorization` rule one paragraph earlier.
   **Why it matters:** A fresh IMPL author following this test could configure nginx to satisfy authorized-looking requests from the anonymous public cache. That would skip the handler's required hash+SELECT path and ship a public API contract violation: invalid partner credentials receive a 200 public body instead of a 401.
   **Suggested fix:** Rewrite the Step 4.B cache test to require that any request carrying `Authorization` bypasses shared nginx cache and reaches the handler. The `Bearer garbage` case MUST return 401 `unauthorized` and MUST NOT be served from a cached anonymous response. Keep the public-projection `Vary: Accept-Encoding, Origin` assertion on true anonymous 200 responses only; do not use malformed Authorization as a public-cache equivalence case.

C2. Step 4.B Path R2 permits deliberate divergence from the locked SPEC
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:508-517` and final done criterion at `:707`
   **Finding:** The prompt correctly identifies that locked §5.6's "60 req/min, 120 burst" and locked AC-8's "61st request within 60s returns 429" are mechanically inconsistent under ordinary nginx semantics. But Path R2 then lets the operator record a decision to ship either burst=0 (violating §5.6) or burst=120 (violating AC-8), and treats that operator decision as authoritative "until v0.1.8 closes."
   **Why it matters:** SPEC-017 v0.1.7 is the single controlling contract. An IMPL prompt cannot authorize a local operator decision to override a locked public rate-limit invariant. This would let Step 4 ship knowingly non-conforming behavior without re-opening and re-locking the SPEC, which violates the locked-SPEC boundary and the AC sweep.
   **Suggested fix:** Delete Path R2. The prompt may keep a test-only harness for deterministic AC-8 mechanics, but production Step 4.B MUST stop before shipped nginx rate-limit config until a locked controlling contract exists. If the prompt remains anchored to v0.1.7, its Step 4.B stop condition should be "do not open/merge the production nginx/rate-limit PR subsection while §5.6 and AC-8 remain unreconciled," not "operator may pick a divergence."

## HIGH findings

H1. Step 3 re-claims Step 4 redaction surfaces, weakening the step seam
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:406-427`, especially `:423`; matrix at `:610`
   **Finding:** The heading says "Step 3 OWNS these ACs (writes the test)" and includes AC-15 as a sweep across journalctl, nginx logs, structured logs, traces, and metric labels. The ownership matrix correctly splits AC-15 across Step 3, Step 4.A, Step 4.B, and Step 4.C.
   **Why it matters:** This reintroduces the earlier step-boundary problem: Step 3 cannot write meaningful nginx access-log or Prometheus metric-label tests before Step 4.B/4.C land. A fresh session could either bloat Step 3 with Step 4 work or fake the AC-15 sweep early, losing the per-step audit-lens benefit.
   **Suggested fix:** Rewrite the Step 3 AC-15 bullet to say Step 3 owns only handler structured logs, recover panic logs, and trace spans. Leave CLI journalctl to 4.A, nginx access logs to 4.B, and metric-label hygiene to 4.C, matching the matrix at lines 610-611.

H2. SPEC-014 v0.9 launch sequencing is ambiguous between "not a blocker" and "actual sign-off before convergence"
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:69-72`, `:566-581`, `:697-711`
   **Finding:** The pre-flight section says "SPEC-014 v0.9 portal toggle UI" is out of scope and, if it has not landed at SPEC-017 cutover, "no production blocker exists." Later, Step 4.C requires the cutover-runbook gate and says the Step 4.C convergence file MUST include the verbatim sign-off text naming the SPEC-014 v0.9 commit/date. The final done list also requires the launch-sequencing gate to be discharged before first production partner-key issuance.
   **Why it matters:** The locked SPEC separates concerns: the portal toggle UI is a follow-up; the §6.6.2 disclosure UI/sign-off is a hard gate only for production partner-key issuance, while staging keys and public bucketed cutover can proceed. The prompt currently lets two conforming IMPL authors disagree: one may treat SPEC-014 v0.9 as no production blocker at all, another may block Step 4.C PR convergence until the live portal disclosure already shipped.
   **Suggested fix:** Split the wording into three states: (1) SPEC-014 v0.9 visibility-toggle UI is not a SPEC-017 code-write or public-cutover prereq; (2) SPEC-014 v0.9 §6.6.2 disclosure UI plus runbook sign-off is a hard gate before production partner-key issuance only; (3) Step 4.C PR must add the runbook checkbox/template and tracking issue, but actual live sign-off may remain pending in the convergence file unless the operator is doing production key issuance in that PR.

## MEDIUM findings

M1. The v0.1.7 round-8 audit is omitted from the "files to read" list
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:629-634`
   **Finding:** The controlling-contract section cites `SPEC-017-r1-audit.md` through `r8-audit.md`, but the later required-read list still says `r1-audit.md` through `r7-audit.md`. Round 8 is the audit that locked the v0.1.7 deltas this prompt exists to absorb.
   **Why it matters:** A fresh IMPL author relying on the "Files you should read before writing" checklist could miss the rationale behind the new ACAO, Vary, totals stripping, partial-history, timing, timeseries split, retention, atomicity, bucket, and launch-sequencing fixes.

M2. The malformed-Origin test leaves the expected branch ambiguous
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:435`
   **Finding:** The RFC 6454 normalization test says trailing slash/query Origin values are treated as absent and then "fall to row 3/4/7" with the expected branch left for the IMPL author to pin. In the described fixture (`allowed_origins = ARRAY['https://acme.example']`), malformed Origin is an absent Origin with a non-empty allowlist, so the locked §5.4.3 table requires the absent-Origin rejection branch: 401 `unauthorized`.
   **Why it matters:** Leaving this branch to the implementer invites divergent tests around one of the v0.1.7 timing/CORS hardenings. The prompt should provide the exact expected status/header outcome.

## LOW findings

None.

## INFO

I1. The four locked advisor picks remain preserved: separate rollup pipeline, public overview plus optional partner-key leaderboard, bucketed-default earnings with exact opt-in, and coordinator-binary hosting are all explicit.

I2. The v0.1.7 schema and handler deltas are mostly carried forward: `blocked_from_partner_projection` stub, 7-component health split, removed per-axis buckets, `meta.rewards_populated`, stripped public `totals.earnings_*`, `Vary` split, ACAO-never-`*` on partner projection, RFC 6454 normalization, Max-Age 60, and 3-way AC-18 timing are all present.

## Operator questions

q1. None for the IMPL prompt author. The prompt itself needs a fix pass; the operator should not be asked to choose local divergence from a locked SPEC.

## Verdict
- READY WITH FIX PASS

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Read BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md fully and compared process/step/audit structure.
- [x] Read SPEC-017-advisor-round-2026-06-25.md.
- [x] Skimmed SPEC-017-r1-audit.md through SPEC-017-r8-audit.md for why locked MUSTs exist.
- [x] Reviewed SPEC-017-IMPL-PROMPT-arch-r1-audit.md through r5 for closure continuity.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above.
- [x] Location line range included on every finding.
- [x] Suggested fix for every CRITICAL and HIGH finding.
- [x] Verdict included.
