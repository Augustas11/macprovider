# PR #1945 Codex audit round 2

Head 823b42ea8. The MEDIUM (overlapping offer handlers clearing each other's probe guard) and code LOW 2 (memory-store newest by evaluation time) are fixed in the following commit; the disclosure-text LOW is carried.

=================== architecture
```text
Architecture gate: **FAIL — 1 MEDIUM, 1 carried LOW** across `origin/main...HEAD` at `823b42ea8`.

1. **MEDIUM — Concurrent offer retry can clear another handler’s probe guard.** [model_admission.go:2180](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission.go:2180)
   Each handler stores the same provider/candidate marker and unconditionally deletes it on return. While the original offer’s probe runs, an identical replay can return and delete that marker; a repeated offer using new replay keys can also delete it explicitly at line 2190 and immediately evaluate binding. The candidate can consequently bind with null or older evidence. When the original probe finishes, the unchanged manifest generation prevents rebind, leaving the wrong digest linked. This remains an incomplete fix for round 1’s offer/sweep race, introduced by this PR.
   **Fix:** make the guard owned by the handler that appended the new offer, coordinated under the provider section; replay/conflict handlers must not clear it. Add an overlapping-handler regression covering both retry paths.

2. **LOW — Disclosure text remains independently defined (carried).** [policy.go:85](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/trustpool/policy.go:85)
   A vocabulary change can make policy/status disagree with buyer disclosure or gateway validation. Buyer/gateway duplication is **pre-existing**; this PR adds another definition.
   **Fix:** share coordinator constants and verify gateway agreement through a common contract fixture.

Round 1 architecture findings 1–4 are addressed: buffered output is drained, only verified labels count, expired builds are rejected before publication, and refresh reads current-policy evidence. The shared-database helpers retain billing/trustpool ownership of their queries; existing coordinator wiring supplies the sources and refresh lifetime. SPEC-047-R003’s global loopback exclusion and SPEC-023’s separate promotion requirements remain structurally enforced.

Validation passed: targeted ws, billing, trustpool, and buyer tests; all 22 `IntakeDecisionManifestTest` tests. Existing tests do not cover overlapping offer handlers or deadline expiry during final aggregation. Diff whitespace checking reports trailing spaces in `R1_FINDINGS.md` only.

No files edited, live hosts contacted, or new payloads constructed.

C/H/M/L = 0/0/1/1
```

=================== code
```text
Gate fails at `823b42ea8`: **1 MEDIUM, 2 LOW** across the complete `origin/main...HEAD` diff.

1. **MEDIUM — Concurrent offer retries can clear another handler’s probe guard.** [model_admission.go:2180](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission.go:2180)
   While the first offer handler probes, a concurrent submission for the same candidate overwrites the shared marker. An idempotent replay clears it on return; an equivalent offer with fresh replay identifiers explicitly clears it at line 2190 and evaluates binding immediately. The candidate can therefore bind with null or older evidence before the first probe records. Its later evaluation cannot update the same-generation binding. **R1’s ordering finding remains incompletely fixed.**
   **Fix:** give the probe lifecycle exclusive ownership under candidate/provider synchronization; replay and rejected handlers must neither replace nor clear that ownership. Add an actual concurrent-handler regression—the existing test manually toggles the marker.

2. **LOW — Memory-store “latest” means append order, not evaluation time.** [model_admission_probe_evidence.go:252](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission_probe_evidence.go:252)
   Concurrent offer and refresh probes can append out of evaluation order. If an earlier evaluation appends last, this lookup returns it instead of the newest record, linking older evidence and using the wrong refresh age/result. SQLite correctly orders by evaluation time. Introduced here.
   **Fix:** select the greatest `evaluated_at`, with append order breaking ties; cover out-of-order appends in the existing store-parity test.

3. **LOW — Duplicated disclosure vocabulary, carried R1 finding.** [policy.go:85](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/trustpool/policy.go:85)
   Another independent definition can drift from buyer disclosure and gateway validation. Buyer/gateway duplication is **pre-existing**; this additional definition is new.
   **Fix:** share coordinator constants and verify gateway agreement through a common contract fixture.

The remaining R1 fixes are present: exact probe-policy validation, policy-filtered currency, response draining, verified-label counting, cached owner snapshots and entry indexes, publication deadline rejection, source chronology, and type-exact re-derivation. Global loopback exclusion and separate recommendable-promotion gates remain intact.

Validation passed: **15 focused existing Go tests** across WS, billing, trustpool and buyer; **22 `IntakeDecisionManifestTest` tests**. Coverage still lacks actual refresh-pass integration and deadline expiry during final processing. `git diff --check origin/main...HEAD` reported trailing whitespace only in `R1_FINDINGS.md`.

No files edited, live hosts contacted, or malformed payloads constructed.

C/H/M/L = 0/0/1/2
```

=================== security
```text
Security gate: **FAIL — 1 MEDIUM, 1 carried LOW** at `823b42ea8`.

- **MEDIUM — Concurrent submissions can clear another request’s probe guard.** [model_admission.go:2180](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission.go:2180), explicit deletion at line 2190. While the first offer’s probe runs, another authenticated submission for the same candidate overwrites the shared marker. Its replay, conflict, or error path then deletes that marker; an identical-offer conflict also immediately reevaluates bindings. The candidate can bind with null or older evidence before the first probe records. Later reevaluation does not repair the link at the same manifest version. The round 1 ordering finding remains partially unresolved. **Fix:** use per-candidate ownership or reference counting so overlapping requests cannot release another request’s guard; add an HTTP-handler concurrency regression. The existing test manually toggles one marker and misses this condition.

- **LOW — Carried disclosure-text duplication.** [policy.go:85](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/trustpool/policy.go:85). Independent copies can drift, making creator policy/status disagree with buyer or gateway disclosure. Buyer/gateway duplication is **pre-existing**; this PR adds another copy. **Fix:** share coordinator constants and verify gateway agreement with a contract fixture.

Other round 1 fixes are supported by source review and existing tests. No additional owner-count inflation, probe forgery, endpoint dereference, operator-access bypass, or global loopback settlement bypass found.

Validation: **17 targeted Go tests and 22 intake-manifest tests passed**. No files edited, live hosts contacted, or malformed payloads constructed.

C/H/M/L = 0/0/1/1
```
