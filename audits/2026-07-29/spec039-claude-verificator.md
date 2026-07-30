Adversarially verify the SPEC-039 paged KV implementation diff in this repository.

You get only the feature intent and current diff. Do not assume the author narrative is correct.

Feature intent:
- Provider-local default-off paged KV engine surfaces.
- No buyer-visible receipt/usage/billing/model identity changes.
- Fail-safe fallback before first token; strict mode rejects before inference.
- Runtime enablement remains blocked until packaged metallib/kernel/parity/hardware proof.

Review task:
- Inspect `git diff` including intent-to-add files.
- Try to falsify allocator, fallback, config precedence, and runtime-inert claims.
- Call out overclaims against the full SPEC-039 prompt.

Required output:
- Findings first, ordered by CRITICAL/HIGH/MEDIUM/LOW/INFO.
- Include file/line, impact, and fix.
- Explicitly state whether there are any CRITICAL/HIGH/MEDIUM findings.
