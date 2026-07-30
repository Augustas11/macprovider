# SPEC-039 R2 code audit prompt

Audit the complete corrected SPEC-039 authoring diff in
`/Users/augstar/macprovider-spec039`:

```bash
git diff origin/main -- specs/SPEC-039-paged-kv-attention-engine.md specs/AUTHORITY.json specs/CONFORMANCE.json specs/README.md audits/2026-07-29/SPEC-039-r1-code-prompt.md audits/2026-07-29/SPEC-039-r1-security-prompt.md audits/2026-07-29/SPEC-039-r1-architect-prompt.md audits/2026-07-29/SPEC-039-r2-code-prompt.md audits/2026-07-29/SPEC-039-r2-security-prompt.md audits/2026-07-29/SPEC-039-r2-architect-prompt.md
```

R1 context:

- Code lane: 0 C/H/M; LOW about untracked files. New files are now
  intent-staged for diff visibility.
- Architect lane: MEDIUM fixed by removing `SPEC-037` from
  `paged-kv-attention.consumers`.
- Security lane: MEDIUM fixed by adding hard paged-pool capacity,
  pre-admission/pre-dispatch reservation, and a pool-exhaustion AC.

Lane: code / spec-governance correctness. Check structural consistency,
requirement coverage, manifest/index consistency, and whether the fixes
introduced any new CRITICAL/HIGH/MEDIUM issue.

Return findings ordered by severity with file/line references. Explicitly
state whether there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
