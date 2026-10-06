# Audit R1: SPEC-049 v0.2.0 automatic enrollment (SECURITY lane)

Read `audits/2026-10-06-privacy-auto-enrollment/AUDIT_AUTO_ENROLLMENT_CONTEXT.md` first; its METHOD constraint applies.

Check for this lane:

- Enrollment trust rule: can any path enroll, re-enroll, or replace keys without a fully verified posture on the live authenticated session (claim alone, heartbeat, auth proof, replaced session, reconnect race, store error, kill switch, quarantine, unapproved or denied identity)? Is the enrollment committed before the posture counts as verified, and can a race between two sessions of one provider enroll two different key pairs?
- Key change: can a different identity or SE key ever be used for a provider that already has an active enrollment without quarantine, including partial configuration pins, a claim omitted, a posture signed by new keys, or `ErrEnrollmentKeyChanged` from the store? Does `reenroll` revoke keys, reject held predispatch reservations, and clear quarantine atomically?
- Record and posture consistency: can records verified under one identity sit beside a posture or enrollment for another, and be served to a buyer?
- Release-derived approval: signature verification over exact bytes, key parsing, symlink and size handling, TOCTOU between Lstat and read, duplicate and malformed `provider_code_identity`, fail-closed on directory errors, precedence with `denied_code_cdhashes` and config entries (expired entries withdraw). Does the Pearl updater stage only verified pairs, and can staging be abused to approve an unsigned identity?
- The change from quarantine to ineligible-without-quarantine for unapproved identities: does it weaken any protection SPEC-049 still claims?
- Directory: signature domain separation, verification over exact payload bytes, closed parsing, `key_id` binding, freshness and future-skew, revocation semantics, size bounds, cache window, failure modes (never partial), and the buyer client's use of the entry (fingerprint match, revoked, model scope). Can a gateway or relay substitute an identity, replay an old directory past expiry, or make the client pin a key it did not sign?
- Directory signing key custody: file mode and owner checks, no symlink following, never logged or printed (keygen output, errors, status), exclusive create.
- Provider default-on: does the read-only eligibility check stay read-only? Can an ineligible or failed-hardening host advertise privacy keys or a claim? Is the R007 ordering (hardening before credential resolution) preserved for automatic and forced modes? Does default-on change ordinary serving (plaintext, relay-blind) for ineligible hosts?
- Information exposure: does the directory or `status` reveal provider IDs, private keys, or anything beyond SPEC-049 §4.11?
- Threat model honesty: do §2.2, §2.5, §2.6, R020, and the runbook state what enrollment does and does not protect, including the first-attested-session and coordinator-host residuals?

Lane: SECURITY.
