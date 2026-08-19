SECURITY-REVIEW LANE — SPEC-042 slice 3 (authority log). Read AUDIT_SLICE3_COMMON_CONTEXT.md first.

This is the trust root that produces the signer sets gating pool policy. Attack it:
- Authorization forgery: can an entry be accepted without valid root-or-M-of-N authorization?
  Genesis without a valid root sig? An entry authorized by a set that is revoked, expired
  (window excludes not_before), self, future, or nonexistent? Root-sig path: can >1 sig, a
  foreign key id, or a malleable/short sig satisfy it?
- Rollback / equivocation: can a lower or equal signer_set_version be re-accepted? Can two
  entries share a version? Can a broken/re-pointed prev-hash chain (fork) be accepted?
- Revocation bypass: after revoking version N, can material under N still verify (via the
  materialized SignerSet.Revoked)? Can a revoked set still authorize a new entry? Is the
  rotate-and-revoke ordering exploitable (authorize with a set you simultaneously revoke to
  weaken future checks)?
- Signature domain separation: is the authority-log-entry-sig tag distinct enough that a
  policy-core signature (slice 2) can never be replayed as an authority-log signature or
  vice versa? Cross-structure hash confusion between entry hash and core digests?
- Encoding injectivity: can two distinct entries produce the same authority_log_entry_hash
  (length-prefix confusion, key-order ambiguity, duplicate keys, empty lists)? Second-preimage
  on the chain?
- Threshold independence: does M-of-N here require M DISTINCT authorized keys (reusing the
  slice-2 dedupe)? Duplicate public keys in a set (should be rejected)?
- Panics / DoS on adversarial input (nil slices, wrong-length hashes/keys/sigs, huge lists,
  unsorted input). Any allocation blowups before validation?
- Root-issuer binding: BindsRootIssuer — any way to pass a root key whose id doesn't match
  the identity core, or a malformed key?

Report Critical/High/Medium/Low with a concrete exploit, file:line, and a fix. Bar: 0 C/H/M.
