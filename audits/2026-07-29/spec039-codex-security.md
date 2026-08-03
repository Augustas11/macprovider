Review the full working-tree diff for SPEC-039 paged KV implementation in this repository from a security and safety perspective.

Scope:
- Use `git diff` from the current worktree, including intent-to-add files.
- Focus on fail-closed behavior, buyer-visible surface invariance, billing/receipt/identity non-interference, unsafe enablement paths, config/environment/CLI abuse, denial-of-service risk, and accidental secret/log exposure.
- Treat runtime enablement as blocked unless packaged metallib, parity, and hardware gates are proven.

Required output:
- Findings first, ordered by severity.
- For each finding, include severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file and line, impact, and concrete fix.
- Explicitly state whether there are any CRITICAL/HIGH/MEDIUM findings.
- Do not review unrelated existing warnings unless this diff worsens them.
