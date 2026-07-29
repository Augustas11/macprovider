# SPEC-038 — Round 1 audit (three-lane codex)

Date: 2026-07-29. Lanes: code / security(money-path weighted) / architect,
each an independent `omc ask codex` invocation. Prompts:
`audits/2026-07-29/AUDIT_SPEC_038_{CODE,SECURITY,ARCHITECT}.md`.

## Round-1 result

| Lane | CRITICAL | HIGH | MEDIUM | LOW/INFO |
|---|---:|---:|---:|---|
| code | 0 | 0 | 4 | 1 LOW |
| security | 0 | 2 | 2 | 1 LOW + 1 INFO |
| architect | 0 | 0 | 2 | 1 LOW |

Total unique: 0 C / 2 H / 8 M (one MEDIUM — AUTHORITY.json consumer
registration — was raised by all three lanes) / LOWs. Below-bar; all fixed in
commit following this file.

## Findings and resolutions

**HIGH**

- **H1 (security) — queued-work snapshot-binding gap.** §10 left "does queued
  work count as accepted before snapshot binding" open while FR-CB13 referenced
  it, leaving a path where queued work is neither pre-admission nor
  snapshot-bound (breaks SPEC-015 model-hash binding under warm swap). *Fix:*
  FR-CB13 now defines two normative states — **pre-admission queued** (no
  snapshot, no settlement attempt) and **accepted** (snapshot captured at the
  instant of acceptance) — with no state in between; the §10 open question is
  removed as resolved. AC-21 exercises both.
- **H2 (security) — mid-request scheduler-failure fallback boundary.** "Safe
  mode after scheduler failure" (FR-CB9) did not forbid mid-attempt fallback
  after buyer-visible output/receipt/cache state, risking stitched
  batched+serial output and mixed-output receipts. *Fix:* FR-CB9 now mirrors
  the SPEC-028 fallback boundary — fallback applies only to subsequent requests
  or to an in-flight request before any visible/receipt/request-log side
  effect; post-output failure fails closed with no settlement receipt for
  stitched output. AC-21 exercises it.

**MEDIUM**

- **M1 (all three) — AUTHORITY.json consumer registration.** SPEC-038's
  CONFORMANCE `depends_on` was not reflected as consumer edges in AUTHORITY.
  *Fix:* SPEC-038 added to the `consumers` of billing-settlement-formula,
  model-catalog-identity, inference-receipts, installer-autotune-policy,
  prefix-cache-billing-isolation, speculative-decoding, and kv-cache-persistence.
  Stray `autotune-recommendation` mention dropped from §2.
- **M2 (code) — Gate A5 economics unbound.** *Fix:* FR-CB15 now requires the
  Gate A5 conditions (`sku-econ` green, sustained provider upside, acceptable
  tail latency/rejection, OPoI FP <5%) before a production-default promotion.
- **M3 (code) — MSB-01..05 coverage.** AC-14 only covered MSB-02/03/04. *Fix:*
  AC-13 now requires the harness to run all five scenarios with their memo
  thresholds and fields, including MSB-01 baseline stability and the MSB-05
  paired native-vs-oracle comparison (CI width ≤0.20, promotion thresholds).
- **M4 (code) — requirements without ACs.** R001/R002/R004/R007 had no AC and
  R010 was not marked static. *Fix:* added AC-15 (FCFS/backpressure/shared
  admission), AC-16 (decode-first/bounded prefill), AC-17 (dense cache row
  ops), AC-18 (actor isolation), and AC-22 (R010 static-review obligation).
- **M5 (code) — FR-CB10 correctness-gate fallback.** Only calendar miss
  triggered Approach B. *Fix:* FR-CB10 now makes a Gate A1/A3 correctness or
  lifecycle failure an equally binding Approach-B / no-go trigger.
- **M6 (security) — cache-billing parity AC.** AC-1 could pass with all
  cold-cache `cached_prompt_tokens = 0`. *Fix:* added AC-19 (batched
  cache-billing parity: sticky hit, ambiguous, retry, invalid-range quarantine,
  two-key non-interference).
- **M7 (architect) — relay-reconnect idempotence unbound.** Gate A3's
  "no relay-reconnect duplication" had no FR/AC. *Fix:* FR-CB13 now requires
  reconnect/retry idempotence at every lifecycle state; AC-20 exercises it.

**LOW (carried into fixes, none deferred)**

- L1 (security) — FR-CB8 now requires observable reason-coded telemetry for
  **both** the permissive serial-route branch and the preflight-rejection
  branch.
- L2 (architect) — `SPEC-023 v…` placeholder replaced with `v0.8.1`.

**INFO** — security lane confirmed "no batch ID in the receipt identity tuple"
(FR-CB6) is clean against SPEC-015's strict tuple. No action.

---

# Round 2 (re-audit after r1 fixes)

| Lane | CRITICAL | HIGH | MEDIUM | LOW/INFO |
|---|---:|---:|---:|---|
| security | 0 | 0 | 0 | 2 LOW + 1 INFO |
| architect | 0 | 0 | 0 | 1 LOW |
| code | 0 | 0 | 2 | 1 LOW |

Security and architect reached the 0 C/H/M bar and are not re-fired. Code
raised 2 MEDIUM, both fixed here:

- **R2-M1 — glossary drift.** §3 `Waiting queue` term still read "Accepted
  work," contradicting the FR-CB13 two-state model (security flagged the same
  as LOW). *Fix:* glossary now says "Received work not yet admitted… entries
  are either pre-admission queued or accepted queued per FR-CB13."
- **R2-M2 — audit file location.** `specs/SPEC-038-r1-audit.md` is a
  non-canonical file in `specs/` root; `gen_spec_index.py --lint` (which uses
  `git ls-files`) and `check_spec_governance.py` reject it once tracked.
  *Fix:* relocated to `audits/2026-07-29/SPEC-038-r1-audit.md`; SPEC header
  reference updated. (Supersedes the stale "specs/SPEC-NNN-rN-audit.md"
  convention — the current lint requires audit records under `audits/`.)

LOW/INFO also folded in: §1 quantized-KV out-of-scope bullet aligned to FR-CB8
(reject-or-permissive-serial-route); AC-6 greedy output stated as
token-identical with tolerance only for explicit logit comparison; AC-5
extended to cover the permissive-serial and post-failure safe-mode entries of
FR-CB9.

# Round 3 (code lane re-audit only)

Code lane re-fired against the R2 fixes; security/architect skipped (passed at
R2). Result recorded below on convergence.

Result: code lane **0 C / 0 H / 0 M**. All three lanes now at 0/0/0 (security
r2, architect r2, code r3). Converged.

Two LOWs folded in (no re-fire; LOW-only):
- AC-4 now tags FR-CB3 and asserts the shared-forward invocation-count
  invariant (B rows → one forward per decode step).
- AC-10 wording aligned to the FR-CB13 two-state model (accepted queued work
  drains/cancels/fails; pre-admission queued work may be rejected at drain
  start).

No LOW/INFO carried unresolved.

## Convergence summary

| Round | code | security | architect |
|---|---|---|---|
| R1 | 0/0/4M | 0/2H/2M | 0/0/2M |
| R2 | 0/0/2M | **0/0/0** | **0/0/0** |
| R3 | **0/0/0** | (skipped, passed) | (skipped, passed) |
