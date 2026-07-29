# SPEC-039 R1 architect audit prompt

Audit the complete SPEC-039 authoring diff in `/Users/augstar/macprovider-spec039`:

```bash
git diff origin/main -- specs/SPEC-039-paged-kv-attention-engine.md specs/AUTHORITY.json specs/CONFORMANCE.json specs/README.md audits/2026-07-29/SPEC-039-r1-code-prompt.md audits/2026-07-29/SPEC-039-r1-security-prompt.md audits/2026-07-29/SPEC-039-r1-architect-prompt.md
```

Lane: architecture / boundary correctness.

Read at least:

- `audits/_prompts/BUILD_SPEC_039_PAGED_ENGINE_PROMPT.md`
- `specs/SPEC-039-paged-kv-attention-engine.md`
- `specs/SPEC-037-kv-survival-restart.md`
- `specs/SPEC-038-continuous-batching.md`
- `docs/research/SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md`
- `docs/research/SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md`
- `docs/research/SPIKE_PAGED_ATTN_PHASE3_MOE_RESULT_2026-07-29.md`
- `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md`

Check whether SPEC-039 is correctly standalone at batch=1, additive on pinned
MLX/MLXLM, architecture-general, default-off provider-local, and composed with
SPEC-037 and SPEC-038 without authority inversion. Prioritize CRITICAL/HIGH/
MEDIUM boundary defects that would misdirect implementation.

Return findings ordered by severity with file/line references. If there are no
CRITICAL/HIGH/MEDIUM findings, say so explicitly and list only LOW/INFO notes.
