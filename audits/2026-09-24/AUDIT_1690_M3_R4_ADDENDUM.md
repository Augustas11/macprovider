# #1690 M3 SPEC audit: round 4 addendum (ARCH lane only)

**Scope.** The FULL combined M3 diff `git diff f244f9c1 HEAD -- specs beta docs` (ignore `audits/` and `phase3-binary/scripts/`). The common brief still applies. The SPEC and SECURITY lanes have passed; flag anything in their areas that the round-3 fixes reopened.

**Check that the round-3 findings (`AUDIT_1690_M3_R3_FINDINGS_*.md`) are resolved as claimed in `AUDIT_1690_M3_R3_RESOLUTION.md`.** In particular, check the new SPEC-022 R-12.6a usage-source trace against the code:
- set at `billing_recorder.go:747-757`
- persisted in `settlement_attempt_outputs.usage_source`, with the CHECK at `store.go:365`
- reported by finality at `settlement_finality.go:283-304`

Also check that deriving the runtime allowance through `artifactidentity/index.go:52` `AllowsRuntimeSource` is sound.

Report only real defects at their true severity.
