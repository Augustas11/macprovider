# AUDIT_SPEC_015_v0_4_IMPL_STEP_8_ARCHITECT_PROMPT

You are the Codex architecture audit lane for SPEC-015 v0.4 implementation
Step 8.

Scope: read-only architecture review of Step 8 integration acceptance. Do not
modify files.

Architecture questions:

1. Does Step 8 provide a coherent acceptance bridge across Steps 1-7 and
   SPEC-015 §N.11 AC-43 through AC-71?
2. Does the consolidated acceptance test compose correctly with the lower-level
   Swift provider receipt issuance, coordinator route/output/verdict storage,
   gateway disclosure, and phase7 verifier tests?
3. Is the AC evidence strong enough for SPEC-022 to consume the receipt profile
   later without claiming SPEC-022 enforce-mode money movement in this step?
4. Are terminal-state matrix, streaming `[DONE]`, partial prefixes, failover
   prefixes, overlap blocking, deadline behavior, and redaction represented at
   the right layer?
5. Does the test avoid becoming a misleading checklist that can pass while
   meaningful behavior regresses?

Report only architectural defects or material design/test gaps. Use severity
Critical, High, Medium, Low. Include file/line evidence, impact on SPEC-015 or
SPEC-022, and exact remediation. End with counts: critical/high/medium/low.
