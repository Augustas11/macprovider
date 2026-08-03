Review the full working-tree diff for SPEC-039 paged KV implementation in this repository as an architecture review.

Scope:
- Use `git diff` from the current worktree, including intent-to-add files.
- Focus on whether the public surfaces are coherent for SPEC-038 to consume: descriptor, engine-issued block-table handle, allocator lifecycle, materialization/retention primitives, attach gate, and default-off runtime integration.
- Identify any architectural mismatch with the prompt/spec, especially where the diff may overclaim real MLX/Metal enablement.

Required output:
- Findings first, ordered by severity.
- For each finding, include severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file and line, impact, and concrete fix.
- Explicitly state whether there are any CRITICAL/HIGH/MEDIUM findings.
- Do not review unrelated existing warnings unless this diff worsens them.
