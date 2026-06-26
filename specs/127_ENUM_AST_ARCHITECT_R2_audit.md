CRITICAL (0):
  None.

HIGH (0):
  None.

MEDIUM (0):
  None.

LOW (0):
  None.

QUESTIONS (0):
  None.

Architect notes:
- The new "Reserved-reason convention" subsection is in the right place: it follows the existing `bundle_pubkey_provider_mismatch` reserved reason explanation inside the "Reasons" material and appears before the separate "Warning Merge Strategy" section. Evidence: phase7-verify/internal/verify/implementation-notes.md:43, phase7-verify/internal/verify/implementation-notes.md:49, phase7-verify/internal/verify/implementation-notes.md:59
- The doc does not overpromise scope. It names `TestReasonEnumBijection`, `reasonXxx` string constants, future SPEC reason reservations, and `reasonBundlePubkeyProviderMismatch`; it does not extend the marker convention to warnings or result constants. Evidence: phase7-verify/internal/verify/implementation-notes.md:51, phase7-verify/internal/verify/implementation-notes.md:52, phase7-verify/internal/verify/implementation-notes.md:54
- The test boundary remains unchanged from r1: the AST walker is still scoped to `reasonXxx` constants and schema reason values, with SPEC §10.4.2 described as the spec-side authority rather than a parsed/generated source. Evidence: phase7-verify/internal/verify/enum_drift_test.go:24, phase7-verify/internal/verify/enum_drift_test.go:28, phase7-verify/internal/verify/enum_drift_test.go:29
- The marker semantics are documented consistently with the r2 code: the note lists the exact `FORWARD-COMPAT` / `RESERVED` tokens and states standalone-token matching, while the regex and synthetic negated-prose case enforce that "NOT RESERVED" does not silence the unused-constant check. Evidence: phase7-verify/internal/verify/implementation-notes.md:55, phase7-verify/internal/verify/implementation-notes.md:56, phase7-verify/internal/verify/enum_drift_test.go:19, phase7-verify/internal/verify/enum_drift_test.go:345
- Calling out #127 as the final v1.0.1-followup-labeled issue remains useful PR-body/release-management context, but it does not require a SPEC or architecture change. Evidence: specs/127_ENUM_AST_ARCHITECT_audit.md:24

VERDICT: architect lane r2 READY TO MERGE
