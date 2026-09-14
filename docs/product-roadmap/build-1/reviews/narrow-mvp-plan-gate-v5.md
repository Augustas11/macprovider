<!-- SUPERSEDED/REOPENED REVIEW: retained only as review history. narrow-mvp-plan-gate-v6.md is the authoritative Build 1 narrow MVP plan gate record. -->
# Build 1 narrow MVP plan gate record

Branch: `codex/build1-mvp-narrow`
Base/dependency: dependent on unmerged PR #1510 at `6a90f39bfd4b8917ae10169b3c760e03cd2dfd91`, based on `origin/main` `50b647960cda1cfc794f870f5685c2615b838f5c` as recorded in the plan. PR #1481 is merged.

Approved plan revision: `docs/product-roadmap/build-1/narrow-mvp-plan-v5.md`
Approved test specification: `docs/product-roadmap/build-1/narrow-mvp-test-spec-v5.md`

Approved digests:

```text
5f3b6d8f14c5558fb54bfd2339af2b6b783af3cbd060cb0fbc0cb2f0a5d01dc9  docs/product-roadmap/build-1/narrow-mvp-plan-v5.md
4a80780198077077f2175911fb439d58cc62d8955aaa57ca8c5a1da94fe8850e  docs/product-roadmap/build-1/narrow-mvp-test-spec-v5.md
```

## Review rounds

### Round 1 / v1

Verifier: `/root/b1_narrow_mvp_plan_sol_r1`, model `gpt-5.6-sol`, high reasoning.

Result: rejected.

Findings:

- High: plan required verified BYOM settlement while declaring staging observe/non-production settlement. Code requires BYOM route snapshots to be settlement-capable only when `settlementEnforceMode()` is true.
- Medium: test spec allowed unknown-size artifact feed authority, but Swift/coordinator validators require measured positive `size_bytes`.
- Medium: physical acceptance did not require enough provider-side evidence to prove actual MLX execution rather than fake provider fixture settlement.

Resolution:

- v2 made measured positive `size_bytes` a hard staging/preparation prerequisite.
- v3 switched acceptance to isolated non-production staging `verified_model_settlement_mode=enforce` with production activation/rewards/payout jobs disabled, and added provider-side correlation.

### Round 2 / v2

Verifier: `/root/b1_narrow_mvp_plan_sol_r1` follow-up, model `gpt-5.6-sol`, high reasoning.

Result: rejected.

Findings:

- High: v2 still retained observe-mode wording incompatible with BYOM settlement routing.
- Medium: provider-side physical proof remained too weak.
- Low: revision titles/cross-references stale.

Resolution:

- v3 removed observe-mode acceptance and required isolated staging enforce mode.
- v3 required provider binary/process identity, provider-side request correlation, and fake-provider exclusion.

### Round 3 / v3

Verifier: `/root/b1_narrow_mvp_plan_sol_r2`, model `gpt-5.6-sol`, high reasoning.

Result: rejected.

Findings:

- High: served-count-only provider evidence could be advanced by unrelated local traffic and did not uniquely prove the staging gateway request ran through the physical MLX CLI.
- Medium: plan named control-socket runtime status but artifact digest is exposed by local HTTP status, leaving digest authority ambiguous.
- Low: titles still said v1.

Resolution:

- v4 required request-id-bearing `receipt_issued`/receipt-audit or equivalent provider log evidence as mandatory physical correlation. Served-count became supporting evidence only.
- v4 selected local provider status JSON as the runtime digest authority and tied `model_hash` / `weights_manifest_sha256` to the prepared artifact.
- v4 fixed revision headings.

### Round 4 / v4

Verifier: `/root/b1_narrow_mvp_plan_sol_r3`, model `gpt-5.6-sol`, high reasoning.

Result: passed with ZERO Critical/High/Medium findings.

Low finding:

- The plan used shorthand `/status`; the code implements `GET /v1/status`.

Resolution:

- v5 replaced the shorthand with exact `GET /v1/status` wording.

### Round 5 / v5

Verifier: `/root/b1_narrow_mvp_plan_sol_r4`, model `gpt-5.6-sol`, high reasoning.

Result: OKAY. ZERO Critical/High/Medium findings.

Verifier summary: v5 is actionable, names the exact local provider endpoint, keeps provider receipt/audit correlation mandatory, preserves narrow MVP scope, and does not claim production readiness or economic activation.

## Approved implementation constraints

- One MVP model/runtime/profile only: `meta-llama/llama-3.2-3b-instruct` / `mlx-community/Llama-3.2-3B-Instruct-4bit` / MLX `mlx_cache` primary artifact.
- Artifact-derived preparation requires a signed artifact-bound release with measured positive `size_bytes`; current `size_bytes: null` source material is not preparation authority.
- BYOM settlement acceptance uses isolated non-production staging `verified_model_settlement_mode=enforce`; production enforcement, rewards, payout jobs, payouts and economic activation remain out of scope.
- Physical acceptance requires actual MLX on a physical Mac, request-id-bearing provider receipt/audit correlation, local provider `GET /v1/status` digest binding, and verified settlement evidence for the same request/provider/model.
- Fixture, fake provider, historical, skipped, timed-out, zero-selected, or served-count-only evidence cannot satisfy physical acceptance.
