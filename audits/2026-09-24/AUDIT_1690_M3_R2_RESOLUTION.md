# #1690 M3 SPEC audit round 2: resolution

Base `9ea213a4`. SPEC versions are unchanged, because M3 is still unmerged. SECURITY passed in round 2; the fixes below do not touch its areas (derived runtime class, authorization binding, disputed labels, allowlist encoding).

## ARCH lane (0C/1H/1M/1L)
- H1 GGUF snapshot cannot be bound: fixed with one design, the **pool route-time member derivation** in the SPEC-047-R003(iv) pool clause.
  - The route helper selects the recorded `catalog_members` entry that the session's pin names, using the `sessionBoundMember` rule. The entry must be `artifact_feed`, `gguf-file.v1`, and allow the recorded `runtime_source`.
  - The expected identity plus the six artifact values come from that member and the session's provenance. Every other field is compared as in `ModelAdmissionSettlementBindingForRouteSnapshot`, and state `catalog_priced` is accepted on pool routes only.
  - Code sites M4 changes: a new pool sibling of `ws/model_admission.go:1788`, an exported wrapper over `ws/model_admission_binding.go:404`, and a pool branch in `buyer/model_admission.go:307`. `buyer/model_admission.go:363` is unchanged and stays global-only.
  - An acceptance test is named in SPEC-047 and required by SPEC-042-R013. SPEC-042-R005 site (3) and SPEC-022 R-12.1 (`expected_catalog_model_hash` is the derived member) point to the derivation.
- M2 earnings disclosure contradiction: fixed. SPEC-047-R004 adds a pool-qualified eligibility claim. It is shown only while all pool route-time predicates hold, names the pool, and never implies global eligibility or `settlement_capable`. The R003 pool-clause exception now names it.
- L1 "verifier unchanged": fixed. The SPEC-015 v0.4.10 changelog and the SPEC-015-R006 CONFORMANCE rationale now say the tuple and wire are unchanged but the coordinator verifier and ingestion source handling change (SPEC-022 R-12.4).

## SPEC lane (0C/0H/3M/2L)
- M1 AC-022-54 conflict: fixed. It carries the R-12 exception, pointing to R-5.6 and AC-022-65.
- M2 AC-CAT-7(iii) conflict: fixed. (iii) is split into a global-admission case (non-loopback only) and a pool-route case (allowlisted loopback GGUF member binds through the pool member derivation; the candidate stays `catalog_priced`).
- M3 verifier-change summaries: fixed. This is the same change as ARCH L1.
- L4 stale dependency versions: fixed. The SPEC-015 depends line now names SPEC-010 v1.7 R007(d) / v1.10 R007(f) and SPEC-022 v0.2.0 R-12 for §N.12.
- L5 "three sites" summaries: fixed. The SPEC-042 0.0.32 changelog, the SPEC-047 gap-table row, and the SPEC-047 v0.2.0 changelog now name the five R005 sites.

## SECURITY lane (0C/0H/0M/1L)
- L1 "verifier unchanged" summaries: fixed. This is the same change as ARCH L1 and SPEC M3.
