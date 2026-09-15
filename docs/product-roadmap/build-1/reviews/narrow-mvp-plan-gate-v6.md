# Build 1 narrow MVP plan gate record v6

Branch: `codex/build1-mvp-narrow`
Base/dependency: dependent on unmerged PR #1510 at `6a90f39bfd4b8917ae10169b3c760e03cd2dfd91`, based on `origin/main` `50b647960cda1cfc794f870f5685c2615b838f5c`. PR #1481 is merged.

Approved plan revision: `docs/product-roadmap/build-1/narrow-mvp-plan-v6.md`
Approved test specification: `docs/product-roadmap/build-1/narrow-mvp-test-spec-v6.md`

Approved digests:

```text
80f401fb62b78b49afca84932d63483e6997646d6873795f4be6a536b168939d  docs/product-roadmap/build-1/narrow-mvp-plan-v6.md
073c31b623d981e9d9051f8f14d41d5576df2ed2b3eb9daa225407e06d67f44b  docs/product-roadmap/build-1/narrow-mvp-test-spec-v6.md
```

## Review history summary

- v1/v2 rejected: staging observe wording could not satisfy current BYOM settlement-capable routing, unknown-size artifact authority contradicted validators, and physical MLX proof was too weak.
- v3 rejected: served-count-only proof was too weak and runtime digest authority was ambiguous.
- v4 passed with zero Critical/High/Medium findings; one Low required naming the exact local status endpoint.
- v5 passed with zero Critical/High/Medium findings after replacing `/status` shorthand with `GET /v1/status`.
- Lead self-review reopened the gate because v5 incorrectly implied `weights_manifest_sha256` must equal the snapshot-manifest artifact hash.
- v6 passed with zero Critical/High/Medium findings after separating `model_hash` / `model_hash_algorithm` as the snapshot-manifest identity from `weights_manifest_sha256` / `weights_manifest_algorithm` as separate safetensors weights-manifest evidence.

## Final independent verifier

Verifier: `/root/b1_narrow_mvp_plan_sol_r5`, model `gpt-5.6-sol`, high reasoning.

Result: OKAY. ZERO CRITICAL/HIGH/MEDIUM FINDINGS.

Verifier justification: v6 correctly fixes the digest-contract error, keeps settlement authority on the snapshot/catalog/admission/route/receipt path, and treats weights-manifest evidence as an additional runtime stability check matching current code.

## Approved implementation constraints

- One MVP model/runtime/profile only: `meta-llama/llama-3.2-3b-instruct` / `mlx-community/Llama-3.2-3B-Instruct-4bit` / MLX `mlx_cache` primary artifact.
- Artifact-derived preparation requires a signed artifact-bound release with measured positive `size_bytes`; current `size_bytes: null` source material is not preparation authority.
- BYOM settlement acceptance uses isolated non-production staging `verified_model_settlement_mode=enforce`; production enforcement, rewards, payout jobs, payouts and economic activation remain out of scope.
- Physical acceptance requires actual MLX on a physical Mac, request-id-bearing provider receipt/audit correlation, local provider `GET /v1/status` `model_hash` matching the prepared snapshot-manifest identity, separate stable `weights_manifest_sha256` evidence, and verified settlement evidence for the same request/provider/model.
- Fixture, fake provider, historical, skipped, timed-out, zero-selected, or served-count-only evidence cannot satisfy physical acceptance.
