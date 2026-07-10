# AUDIT 278 ARCHITECT PROMPT — Gateway upward-correction symmetric clamp

You are auditing the current branch for issue #278. This is an architecture and contract-preservation audit.

Target result: verify the patch preserves the streaming settlement contract while making the upward branch symmetric with the landed #262 downward branch.

Files in scope:
- `phase5-gateway/internal/router/chat_proxy.go`
- `phase5-gateway/internal/router/server_test.go`
- `specs/BUILD_GATEWAY_UPWARD_CLAMP_PROMPT.md`
- `specs/SPEC-006-buyer-api.md` only if needed to validate SPEC-006 section 17.7 settlement semantics

Checks:
- Does `settleReported` now have symmetric branch shape for reported-vs-observed disagreements?
- Does SPEC-006 section 17.7's settlement matrix remain true without requiring a normative spec edit?
- Does `token_source` still distinguish `provider_reported` as provider tokenizer usage and `gateway_estimated` as byte-derived usage?
- Are exact-match, below-floor, in-window, at-ceiling, above-ceiling, and large-mismatch cases architecturally coherent in both directions?
- Are fallback paths for malformed stream, client disconnect, provider timeout, and no usage chunk unchanged?
- Are comments and logs clear enough for future maintainers to avoid changing the byte estimator or unrelated fallback call sites as part of this fix?
- Does the test suite encode the contract at the correct level, or is it overfit to implementation details?

Output format:
- Start with `AUDIT_278_ARCHITECT: PASS` if there are 0 CRITICAL/HIGH/MEDIUM findings, otherwise `AUDIT_278_ARCHITECT: FAIL`.
- Then list counts as `CRITICAL: n`, `HIGH: n`, `MEDIUM: n`, `LOW: n`.
- For every finding, include severity, file:line, evidence, contract impact, and concrete fix.
- Explicitly state whether a SPEC change is required; if yes, explain why.
