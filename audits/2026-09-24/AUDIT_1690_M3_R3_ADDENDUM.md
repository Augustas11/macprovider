# #1690 M3 SPEC audit: round 3 addendum

**Scope for round 3.** Audit the FULL combined M3 diff `git diff f244f9c1 HEAD -- specs beta docs` (ignore `audits/` and `phase3-binary/scripts/`). The common brief still applies. The SECURITY lane passed in round 2 and does not re-run; flag anything in its areas that the round-2 fixes reopened.

**Also check:**
- that each round-2 finding (`audits/2026-09-24/AUDIT_1690_M3_R2_FINDINGS_*.md`) is resolved as claimed in `AUDIT_1690_M3_R2_RESOLUTION.md`;
- the new "pool route-time member derivation" in SPEC-047-R003(iv): implementable against `ws/model_admission.go:1788`, `ws/model_admission_binding.go:404` and `buyer/model_admission.go:307`; consistent with SPEC-022 R-3.3/R-12 and SPEC-042-R005/R013; with global routes unchanged.

Report only real defects at their true severity; do not re-report resolved items.
