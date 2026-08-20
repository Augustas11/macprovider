SECURITY-REVIEW LANE — SPEC-042 slice 5. Read AUDIT_SLICE5_COMMON_CONTEXT.md first.

This deserializes durable state and reconstructs trust decisions. Attack it:
- Deserialization safety: can crafted snapshot bytes cause a panic, OOM, or huge allocation
  (length fields, element counts) BEFORE validation? Is the count() guard sufficient against
  a claimed-huge count with a tiny buffer? Integer overflow in length/offset math (int vs uint32,
  pos+n)? Slice aliasing of attacker bytes into long-lived structs?
- The grandfathering split — is it SOUND? Reconstruction skips the revoked/window gate but MUST
  still re-verify the M-of-N signature. Can an attacker who can write the durable store inject a
  policy that was NEVER validly accepted (e.g. signed by a non-member, below threshold, or under a
  signer set that never authorized it)? Confirm verifyPolicyCoreSignature still enforces
  signer-set membership + threshold + exact signer_set_version, so a forged verdict cannot pass.
- Can reconstruction accept a policy whose signer_set_version is NOT in the authority log, or whose
  signer set the log marks revoked but whose signature was forged? Can a revoked signer set's keys
  be used to sign a NEW (never-accepted) policy and have it grandfathered?
- Chain/rollback on reconstruction: are monotonic manifest_version + prev-hash chain + non-overlap
  still enforced (so a tampered snapshot can't inject an out-of-order or overlapping policy)?
- Authority-log reconstruction: fully re-verified? Can a tampered authority log entry slip through?
- Domain separation: snapshot tag distinct; no confusion between snapshot bytes and signed preimages.
- Does ReconstructPool ever FAIL OPEN (return a usable pool) when it should error?

Report Critical/High/Medium/Low with exploit scenario, file:line, fix. Bar: 0 C/H/M.
