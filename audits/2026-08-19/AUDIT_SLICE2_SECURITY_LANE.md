SECURITY-REVIEW LANE — SPEC-042 manifest slice 2 (policy-core signature verification).

Read audits/2026-08-19/AUDIT_SLICE2_COMMON_CONTEXT.md first for scope and the bar.

This is trust infrastructure that will gate pool routing + pool-labeled settlement.
Attack it:
- Signature forgery / confusion: is the signing preimage domain-separated well
  enough that a policy-core signature cannot be replayed as an identity-core,
  authority-log-entry, or mutable-field signature (future slices)? Is signing the
  digest (vs the full preimage) safe under SHA-256 CR? Any cross-protocol reuse?
- Threshold bypass: can an attacker reach M with fewer than M distinct authorized
  keys? Duplicate-key handling, unknown-key handling, malleable Ed25519 signatures
  (does the standard library verify admit malleated S, and if so can it inflate the
  count given the by-KeyID dedupe)? Zero-key / all-zero pubkey edge cases.
- Signer-set validity bypass: can a revoked or out-of-window signer set be made to
  verify? Is acceptance validity correctly anchored to not_before_unix (not
  manifest_version) per R012 — could a wall-clock or ordinal confusion flip a
  reject to accept? Boundary conditions at NotBefore and Expires.
- signer_set_version confusion: can a policy core be verified against a
  different-version signer set whose keys happen to overlap?
- pool_id binding: any way to pass VerifyPoolIDBinding with a mismatched identity
  core (length-extension, encoding ambiguity, truncation collision within scope)?
- Panics / DoS on adversarial input (nil slices, oversized inputs, non-32-byte
  digests, wrong-length keys/sigs).
- Any secret-dependent branch that leaks via timing that MATTERS here (note pool_id
  is public).

Report Critical/High/Medium/Low with a concrete exploit scenario, file:line, and a
fix. Bar: 0 C/H/M.
