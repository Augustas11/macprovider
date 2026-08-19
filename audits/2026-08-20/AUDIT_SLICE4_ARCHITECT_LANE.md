ARCHITECT LANE — SPEC-042 slice 4 (active-policy selection). Read AUDIT_SLICE4_COMMON_CONTEXT.md first.

Evaluate design + SPEC fit:
- Does BuildPolicyHistory + ActivePolicy faithfully implement the R001 active-policy paragraph
  (half-open windows, at most one active, adjacent boundary, future pre-accept, pool_policy_stale on gap,
  reject overlapping windows) and the rollback/chain sentence?
- Is composing slice-2 VerifyPolicyCore + slice-3 authLog.SignerSet the right seam? Is verifying each core
  against the HANDED authority-log state (with the revocation-grandfather case deferred to slice-5 durable
  verdicts) a clean, honest boundary, or does it bake in something slice 5 cannot reconcile?
- Is `now` as an explicit parameter (vs an ambient clock) the right purity seam for slice 5 persistence?
- Non-overlap checked against ALL accepted windows (not just previous) — correct given versions and windows
  need not share order? Any case where version order and window order diverge that breaks an assumption?
- API shape: PolicyHistory opaque, ActivePolicy/HighestVersion — does this cleanly feed slice 6 (routing/admission)?
  Is "current policy = active-at-now" vs "highest version" distinction correct and not misusable?
- Consistency with slices 1-3 (deep-copy immutability, sentinel errors, encoder reuse, no clock).
- SPEC/CONFORMANCE/README governance coherent and honest.

Report Critical/High/Medium/Low with rationale + file:line. Bar: 0 C/H/M.
