# SPEC-039 R1 security audit prompt

Audit the complete SPEC-039 authoring diff in `/Users/augstar/macprovider-spec039`:

```bash
git diff origin/main -- specs/SPEC-039-paged-kv-attention-engine.md specs/AUTHORITY.json specs/CONFORMANCE.json specs/README.md audits/2026-07-29/SPEC-039-r1-code-prompt.md audits/2026-07-29/SPEC-039-r1-security-prompt.md audits/2026-07-29/SPEC-039-r1-architect-prompt.md
```

Lane: security / settlement correctness.

Read at least:

- `audits/_prompts/BUILD_SPEC_039_PAGED_ENGINE_PROMPT.md`
- `specs/SPEC-039-paged-kv-attention-engine.md`
- `specs/SPEC-037-kv-survival-restart.md`
- `specs/SPEC-038-continuous-batching.md`
- `specs/SPEC-015-receipts.md` if present, otherwise use repo search for SPEC-015
- `specs/SPEC-024-prefix-cache-billing.md`
- `docs/research/SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md`
- `docs/research/SPIKE_PAGED_ATTN_PHASE3_MOE_RESULT_2026-07-29.md`

Focus on fail-safe behavior, exact-parity gates, fp16 vs quantized KV boundary,
no receipt/usage/billing drift, cache identity, block-table validation, fallback
observability, and SPEC-037 persistence composition. Do not consult
`Layr-Labs/*` or `d-inference` source.

Return findings ordered by severity with file/line references. If there are no
CRITICAL/HIGH/MEDIUM findings, say so explicitly and list only LOW/INFO notes.
