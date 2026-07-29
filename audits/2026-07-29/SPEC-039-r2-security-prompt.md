# SPEC-039 R2 security audit prompt

Audit the complete corrected SPEC-039 authoring diff in
`/Users/augstar/macprovider-spec039`:

```bash
git diff origin/main -- specs/SPEC-039-paged-kv-attention-engine.md specs/AUTHORITY.json specs/CONFORMANCE.json specs/README.md audits/2026-07-29/SPEC-039-r1-code-prompt.md audits/2026-07-29/SPEC-039-r1-security-prompt.md audits/2026-07-29/SPEC-039-r1-architect-prompt.md audits/2026-07-29/SPEC-039-r2-code-prompt.md audits/2026-07-29/SPEC-039-r2-security-prompt.md audits/2026-07-29/SPEC-039-r2-architect-prompt.md
```

R1 context:

- Security lane MEDIUM: allocator had no normative hard memory/pool budget.
  The spec now requires hard pool capacity, reservation before request
  admission/GPU dispatch, no OOM-as-control, and an AC for capacity exhaustion
  without partial output, accounting, receipts, or leaked blocks.
- Architect lane MEDIUM: SPEC-037 was incorrectly declared as an unconditional
  `paged-kv-attention` consumer. It has been removed; SPEC-037 remains a
  conditional/persistence-composition boundary in the prose.

Lane: security / settlement correctness. Focus on fail-safe behavior,
pool-exhaustion behavior, exact-parity gates, fp16 vs quantized KV boundary,
no receipt/usage/billing drift, block-table validation, fallback observability,
and SPEC-037 persistence composition. Do not consult `Layr-Labs/*` or
`d-inference` source.

Return findings ordered by severity with file/line references. Explicitly
state whether there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
