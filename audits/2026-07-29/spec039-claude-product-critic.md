Critique the SPEC-039 paged KV implementation diff in this repository for product correctness and release framing.

You get only the feature intent and current diff. Do not rely on fix history.

Feature intent:
- Land default-off provider-local paged KV engine contract surfaces.
- Keep buyer contracts unchanged.
- Keep serve inert until packaged metallib/kernel/parity/hardware proof.
- Provide stable surfaces for SPEC-038: descriptor, block-table handle, materialization/retention primitive.

Review task:
- Inspect `git diff` including intent-to-add files.
- Identify product/release risks, misleading claims, missing stop conditions, and any user-visible behavior drift.

Required output:
- Findings first, ordered by CRITICAL/HIGH/MEDIUM/LOW/INFO.
- Include file/line, impact, and fix.
- Explicitly state whether there are any CRITICAL/HIGH/MEDIUM findings.
