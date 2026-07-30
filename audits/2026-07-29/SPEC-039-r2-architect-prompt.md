# SPEC-039 R2 architect audit prompt

Audit the complete corrected SPEC-039 authoring diff in
`/Users/augstar/macprovider-spec039`:

```bash
git diff origin/main -- specs/SPEC-039-paged-kv-attention-engine.md specs/AUTHORITY.json specs/CONFORMANCE.json specs/README.md audits/2026-07-29/SPEC-039-r1-code-prompt.md audits/2026-07-29/SPEC-039-r1-security-prompt.md audits/2026-07-29/SPEC-039-r1-architect-prompt.md audits/2026-07-29/SPEC-039-r2-code-prompt.md audits/2026-07-29/SPEC-039-r2-security-prompt.md audits/2026-07-29/SPEC-039-r2-architect-prompt.md
```

R1 context:

- Architect lane MEDIUM fixed by removing `SPEC-037` from
  `paged-kv-attention.consumers`; `SPEC-038` remains the unconditional
  consumer. SPEC-039 still states SPEC-037 persistence consumes paged layout
  only if a later persistence revision stores paged resident state.
- Security lane MEDIUM fixed by making pool capacity a normative hard bound
  with pre-admission/pre-dispatch reservation and an exhaustion fixture.

Lane: architecture / boundary correctness. Check whether SPEC-039 remains
standalone at batch=1, additive on pinned MLX/MLXLM, architecture-general,
default-off provider-local, and composed with SPEC-037/SPEC-038 without
authority inversion or implementation misdirection.

Return findings ordered by severity with file/line references. Explicitly
state whether there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
