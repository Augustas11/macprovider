Read `audits/2026-09-24/AUDIT_1690_M3_SPEC_COMMON.md` first.

**Lane: specification correctness and cross-SPEC consistency (code-review lane).**
- Are the amended requirements internally consistent?
- Grep EVERY restatement of each changed rule, across all `specs/`, runbooks, README and index text. Is any restatement left contradicting the new text? Known risk areas: SPEC-015 §N.2/§N.6 "exactly these fields" and "provider-only usage never sufficient"; SPEC-022 R-3.4.1; SPEC-047 R003; SPEC-023 AC-CAT-7/16; SPEC-043-R006 delegated providers.
- Do the version bumps, changelogs, CONFORMANCE registrations (pending, no fake evidence) and AUTHORITY consumer edges agree?
- Is every normative statement testable, and is each new requirement ID mapped?
- Are the code anchors cited in the text correct at this commit?
