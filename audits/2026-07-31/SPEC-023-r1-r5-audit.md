# SPEC-023 oMLX provisional-gates — independent audit record (r1–r5)

Target: `specs/SPEC-023-installer-autotune-recommend.md` + cross-spec `specs/SPEC-032-proof-of-weights-hello-gate.md`, `specs/SPEC-010-model-catalog.md`.
Issue: #687 Stage 1 ("make oMLX provisional gates normative"). Originated as contributor PR #828 (erikHtoo, authorship preserved in branch history); the maintainer independent audit + revision was carried on `spec/687-omlx-revision` after the contributor was tool-blocked on the codex loop.
Method each round: 3 codex lanes (code / security / architect) via `omc ask codex` + a Claude adversarial trust-invariant pass. Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM at Stage-1 scope.

## Final verdict (r5, tip d7d517ac)
**Trust invariant #687 INTACT. 0 C / 0 H / 0 M at Stage-1 scope.** Cleared to ship (behind the release freeze). `check_spec_governance.py`, `gen_spec_index.py --check`, `git diff --check` all pass. SPEC-023 v0.9.3, SPEC-032 v0.2.5.

## The invariant (issue #687)
Unattested oMLX data MAY only seed the STARTING advisory `bench_gate.min_sustained_tps` of a non-default provisional row. It MUST NEVER set/hold a recommendable gate, raise a verified gate, hard-block a provider, or be sole/partial promotion evidence. Verified provider autotune is the ONLY admission/promotion authority.

## Journey (why it took 5 rounds — this is the value of the independent loop)
The contributor's self-attested audit was a hand-written "0/0/0, findings: none" stub and did not survive the real loop. The prose stated every prohibition correctly; the failures were all at the enforcement layer, and each round drove deeper:

- **r1 (1 CRIT + 3 HIGH):** oMLX used as the promotion pass/fail predicate (CRIT); SPEC-032 hello-gate hard-vetoing on the advisory `bench_gate` (cross-spec HIGH); provenance laundering; K mapped to the wrong quantity (distinct cells vs observations-per-cell).
- **r2 (3 HIGH):** SPEC-032 fix was incomplete (veto still in the `evidence_invalid` taxonomy + FR-HG4 table); the r2 fix *introduced* a regression (semantic seed failures fail-closed at "coordinator admission" → oMLX hard-blocking a provider); promotion path unverifiable.
- **r3 (3 HIGH — the pivot):** findings shifted from wording to **implementation-coupling** — the deployed Go coordinator `RowIdentity` includes advisory TPS/TTFT, `runtime_status` unenforced, and (decisive) deployed strict-key validators reject the new schema → the **#813 forward-incompat fleet-break**. Conclusion: a docs-only Stage-1 change *cannot* reach 0 C/H/M because enforcement is Stage-2 code. **Re-scoped** around an activation gate (operator decision).
- **r4 (1 CRIT + HIGH):** the activation gate worked (impl items correctly gated as Stage-2 prereqs) but had real holes — provenance-erasure laundering (ban the schema but not oMLX-*derived* values under other labels), SPEC-032 admission-digest self-contradiction, quarantine phase contradiction.
- **r5 (converged):** closed the gate holes — broadened No-oMLX-derivation gate (§12.2 + AC-OMLX-16), `admission_policy_sha256` advisory-excluding subset digest (§3.6 + SPEC-032 FR-HG3), phase-qualified quarantine (§3.5/§12.3), immutable-lineage as Stage-2 prereq (v). Finalized AC-OMLX-11 to require all of (i)-(v). Final adversarial pass: invariant intact, 0 C/H/M.

## The resolution: activation gate (SPEC-023 §12.2)
Stage-1 is a safe forward-declaration. The oMLX schema (`omlx_seeded`, `gate_seed`, `verified_provider_matrix`) AND any oMLX-derived value under any provenance label MUST NOT reach a signed/served catalog until (a) all consumers (coordinator Go validators + CLI Swift decoders) forward-compat-accept the schema AND (b) Stage-2 enforcement (i)-(v) ships. This averts the #813 fleet-break and makes the invariant hold trivially in Stage 1 (no oMLX data is live).

## Stage-2 prerequisites carried (declared normative, not implemented here)
1. Coordinator admission identity uses the advisory-excluding `admission_policy_sha256` subset digest — never the full catalog SHA (§3.6, SPEC-032 FR-HG3).
2. Coordinator enforces `runtime_status == "recommendable"` for network-connected providers; provisional rows local-only.
3. Invalid oMLX rows are row-scoped quarantined — never whole-catalog / join / SPEC-032-admission blocking.
4. `verified_provider_matrix` promotion is evidence-bound (signed immutable per-measurement references + deterministic aggregation).
5. Immutable provenance lineage so a laundered oMLX-derived value is detectable post-activation.

## Carried INFO (non-blocking)
- Pre-activation, the anti-laundering control (AC-OMLX-16) is signer-attestation-rooted until the Stage-2 lineage detector (v) ships — consistent with the existing operator-signed-catalog trust root.
- The `AC-OMLX-*` are body ACs not yet registered as `SPEC-023-RNNN` in `CONFORMANCE.json` (spec's pending-migration state; no trust impact) — register with the eventual PR governance declaration.

Raw lane transcripts: `.omc/artifacts/ask/` and `audits/2026-07-31/RESULT-*.log` (untracked).
