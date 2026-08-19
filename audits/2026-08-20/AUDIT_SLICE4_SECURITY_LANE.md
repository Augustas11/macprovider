SECURITY-REVIEW LANE — SPEC-042 slice 4 (active-policy selection). Read AUDIT_SLICE4_COMMON_CONTEXT.md first.

Attack the policy-history acceptance + selection:
- Rollback / downgrade: can an attacker get an older/weaker policy core accepted or selected as active?
  Can two versions be active at once (overlap slipping through)? Can a gap be masked so a stale policy routes?
- Chain forgery: can prev_manifest_core_hash be re-pointed to accept a forked history? Genesis spoofing?
- Signature/authority binding: is each core verified against the CORRECT signer set (its signer_set_version)?
  Can a core name a revoked or wrong-version signer set and still be accepted? Unknown signer set handling.
- pool_id confusion: can a policy core for pool A be accepted into pool B's history?
- Window abuse: negative/zero/inverted windows; integer overflow at window boundaries (uint64 arithmetic);
  a future-dated core wrongly active; an expired core wrongly active.
- Immutability: can accepted policy material be mutated post-acceptance through inputs or returned values
  (affecting a later admission decision)?
- Panics / DoS on adversarial input (nil slices, wrong-length prev hash, huge core lists, O(n^2) overlap scan).
- fail-closed correctness: does the stale path truly return an error (never a default/empty policy that a
  caller might treat as permissive)?

Report Critical/High/Medium/Low with exploit scenario, file:line, fix. Bar: 0 C/H/M.
