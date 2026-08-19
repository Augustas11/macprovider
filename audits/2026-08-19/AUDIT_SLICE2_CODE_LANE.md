CODE-REVIEW LANE — SPEC-042 manifest slice 2 (policy-core signature verification).

Read audits/2026-08-19/AUDIT_SLICE2_COMMON_CONTEXT.md first for scope and the bar.

Focus on correctness and code quality of the signature-verification logic:
- Is M-of-N counting correct and non-bypassable? Confirm one key cannot satisfy the
  threshold by signing M times; confirm an unauthorized key's signature cannot pad
  the count; confirm empty/partial signature lists reject.
- Are the accept/reject predicates in VerifyPolicyCore complete and correctly
  ordered (signer-set Validate, version match, revoked, window vs not_before,
  digest recompute, threshold)? Any missing predicate, wrong operator, or off-by-one
  in the half-open window `[NotBefore, Expires)` containing not_before?
- SignerSet.Validate: 1<=M<=N, distinct non-empty key ids, ed25519 key length,
  non-empty window. Any gap?
- Determinism/totality claims: no I/O, no clock, no rand. Confirm.
- Error sentinels distinct and wrapping via errors.Is works for callers.
- Test coverage: do the golden vectors actually freeze the signing preimage, and do
  the reject tests assert the SPECIFIC sentinel for each failure mode?
- Go idioms, error handling, naming consistency with the slice-1 file.

Report Critical/High/Medium/Low with file:line and a concrete fix. Bar: 0 C/H/M.
