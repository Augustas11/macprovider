Review the full working-tree diff for SPEC-039 paged KV implementation in this repository.

Scope:
- Use `git diff` from the current worktree, including intent-to-add files.
- Focus on code correctness, Swift API boundaries, allocator/block-table invariants, fallback semantics, config precedence, and tests.
- Treat this as money-path-adjacent serving correctness.

Required output:
- Findings first, ordered by severity.
- For each finding, include severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file and line, impact, and concrete fix.
- Explicitly state whether there are any CRITICAL/HIGH/MEDIUM findings.
- Do not review unrelated existing warnings unless this diff worsens them.
