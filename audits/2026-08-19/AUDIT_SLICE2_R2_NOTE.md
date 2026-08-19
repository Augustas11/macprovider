ROUND 2 RE-AUDIT — SPEC-042 manifest slice 2.

Round 1 found ONE HIGH (converged across the code and security lanes): duplicate
Ed25519 public keys under distinct key ids could collapse M-of-N (one private key
satisfies a 2-of-N threshold by signing the same digest presented under two ids,
because threshold counting dedupes by key id).

The fix, now in the diff (git diff d8f6b31b..HEAD, patch at
audits/2026-08-19/slice2-manifest-sig-fulldiff.patch):
- SignerSet.Validate() now rejects duplicate public-key bytes with a new sentinel
  errSignerKeyDup (in addition to distinct key ids), at the trust-primitive
  boundary. See signature.go func (ss SignerSet) Validate.
- New regression tests: signature_test.go
  TestDuplicatePublicKeyCannotCollapseThreshold (proves one key cannot satisfy
  2-of-N via a twin id, rejected before threshold counting), plus a
  "duplicate public key under distinct ids" case in TestSignerSetValidate.
- Round-1 LOW also fixed: PolicyCoreSigningMessage now returns a distinct
  errDigestLen (was reusing errPrevHashLen); asserted in
  TestPolicyCoreSigningMessageGolden.
- SPEC 0.0.9 structural-validity clause + design doc §3 updated to require distinct
  public keys and explain why.
- Round-1 security LOW (no input-size caps) is DEFERRED to the slice-3 wire/parse
  layer with a SPEC-backed max, documented in the design doc; nothing untrusted
  reaches this package yet.

Re-verify ONLY that the HIGH is fully closed and no new C/H/M was introduced by the
fix. Confirm the fix cannot be bypassed (e.g. duplicate keys detected regardless of
ordering; VerifyPolicyCore rejects before counting). Bar: 0 Critical / 0 High / 0
Medium.
