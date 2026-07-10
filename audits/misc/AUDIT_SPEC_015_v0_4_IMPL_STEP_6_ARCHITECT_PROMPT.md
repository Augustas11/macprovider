# AUDIT_SPEC_015_v0_4_IMPL_STEP_6_ARCHITECT_PROMPT

You are the Codex architecture audit lane for SPEC-015 v0.4 implementation
Step 6.

Scope: read-only architecture review of the current worktree diff for provider
v0.4 settlement receipt issuance and coordinator WS receipt ingestion. Do not
modify files.

Architecture questions:

1. Does the Step 6 design correctly compose with Steps 2-5 route snapshot,
   settlement output/usage evidence, verifier, and receipt ingestion state?
2. Does the WS metadata contract keep the provider boundary minimal while
   giving the provider enough information to sign the strict §N.1 tuple?
3. Are non-streaming and streaming terminal receipt paths symmetric enough for
   SPEC-022 to consume verified receipts later?
4. Does the implementation avoid coupling coordinator production code to
   `phase7-verify/internal/*` and preserve module boundaries?
5. Are failure/omission cases architecturally sound, especially missing
   route metadata, missing request-start model hash, cancellation/error
   terminal states, and late receipt non-settlement?
6. Are there lifecycle or migration risks for existing v0.3 provider receipts
   and older providers?

Report only architectural defects or material design/test gaps. Use severity
Critical, High, Medium, Low. Include file/line evidence, impact on SPEC-015 or
SPEC-022, and exact remediation. End with counts: critical/high/medium/low.
