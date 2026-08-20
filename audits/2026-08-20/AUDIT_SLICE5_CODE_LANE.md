CODE-REVIEW LANE — SPEC-042 slice 5. Read AUDIT_SLICE5_COMMON_CONTEXT.md first.

Focus:
- The decoder: are ALL reads bounds-checked? Can any path panic on truncated/adversarial
  input (u32/u64/bool/lenPrefixed/take/count/expectTag)? Does the err-latch make post-error
  reads no-ops? Does done() reject trailing bytes AND surface the first error?
- Round-trip fidelity: is encode/decode symmetric for EVERY field of AuthorityLogEntry,
  PolicyCore (all 22 fields), Signature, SignerKey, AcceptedPolicyRecord? nil vs empty slice
  handling (does a nil field round-trip to nil, not empty)? Field ORDER preserved (no sorting)?
- The count() over-allocation guard: is it correct (n > remaining bytes -> fail)? Any make([]T, n)
  with attacker-controlled n before the guard?
- boolean() rejects bytes other than 0x00/0x01?
- lenPrefixed returns a COPY (no aliasing of the input buffer into decoded structs)?
- The shared buildPolicyHistory refactor: is online BuildPolicyHistory behavior byte-identical
  (still passes VerifyPolicyCore)? Is the verify-fn indirection correct?
- verifyPolicyCoreSignature: does it correctly omit ONLY the revoked/window gate while keeping
  Validate + version-match + digest + threshold? Any check wrongly dropped or kept?
- ReconstructPool: error wrapping (errors.Is still works through fmt.Errorf %w)? Correct order
  (authlog before policy history)?
- Test coverage: round-trip, determinism, strict-parse, grandfathering, corruption. Sentinels asserted?

Report Critical/High/Medium/Low with file:line + fix. Bar: 0 C/H/M.
