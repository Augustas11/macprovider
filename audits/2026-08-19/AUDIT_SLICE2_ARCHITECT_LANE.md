ARCHITECT LANE — SPEC-042 manifest slice 2 (policy-core signature verification).

Read audits/2026-08-19/AUDIT_SLICE2_COMMON_CONTEXT.md first for scope and the bar.

Evaluate the design and its fit to SPEC-042 R001/R012 and the surrounding codebase:
- Slice boundary: is "verify against a handed SignerSet, authority log produces it
  later" a clean, correct layering? Does anything in this slice bake in an
  assumption that the slice-3 authority log will be unable to satisfy (e.g. the
  Revoked flag, the validity-window semantics, signer_set_version lookup contract)?
- SPEC conformance: does VerifyPolicyCore faithfully implement R012's "verify
  against exactly that signer_set_version" + "validity window containing not_before"
  + "reject not-yet-active/expired/revoked/version-mismatched"? Is the not_before
  anchoring (vs manifest_version) correct and future-proof for the slice-5 durable
  verdict replay?
- Reusability: is the threshold primitive shaped so slice 3 (authority-log entries)
  and mutable-field signing can reuse it without a breaking change? Is the signing
  tag scheme extensible (distinct tags per structure)?
- Wire-format stability: are the golden vectors the right freeze points? Will a
  later slice be forced into a breaking re-encode of anything frozen here?
- Consistency with existing crypto conventions in the coordinator (Ed25519,
  base64url keys/sigs, {Alg,KeyID,Sig} shape in internal/tier2).
- SPEC/CONFORMANCE/README governance updates coherent and honest.

Report Critical/High/Medium/Low with rationale and file:line. Bar: 0 C/H/M.
