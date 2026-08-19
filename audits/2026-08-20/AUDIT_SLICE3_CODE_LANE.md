CODE-REVIEW LANE — SPEC-042 slice 3 (authority log). Read AUDIT_SLICE3_COMMON_CONTEXT.md first.

Focus on correctness of the chain-replay logic:
- Are all per-entry checks present, correctly ordered, and non-bypassable? (Validate,
  prev-hash length, monotonic version, chain, revokes well-formedness, authorization.)
- Genesis handling: first entry must have prev=zeros; root-authorized path requires
  EXACTLY one root signature from the root key id. Any way to slip extra/foreign sigs?
- Monotonicity: strictly increasing signer_set_version; is the "haveVersion" seed logic
  correct for the first entry? Any off-by-one or duplicate-version acceptance?
- Chain: bytes.Equal on 32-byte prev hash; genesis zero-hash check. Correct?
- revokes_versions: ascending/distinct, each < entry version and already present.
  Any way to revoke self/future/nonexistent, or to double-apply?
- Authorization-before-revocation ordering (rotate-and-revoke): is the "authorized by a
  revoked set" check reading the revocation state as of PRIOR entries only? Any way an
  entry authorizes itself off its own revocation, or a revoked set still authorizes?
- Canonical encoding: is CanonicalContentBytes injective and deterministic (key set-order,
  revokes order, u32 count prefixes, u64s)? Does it match the golden vectors? Does the
  signatures-not-hashed boundary hold (content excludes Signatures)?
- The signature.go refactor: is VerifyPolicyCore behavior byte-identical after extracting
  verifyThresholdMessage? Any semantic change?
- HeadHash returns a copy (no aliasing of internal state)? Map mutation safety?
- Error sentinels distinct; errors.Is works. Test coverage: do golden vectors freeze the
  encoding and do reject tests assert the SPECIFIC sentinel per failure mode?

Report Critical/High/Medium/Low with file:line and a concrete fix. Bar: 0 C/H/M.
