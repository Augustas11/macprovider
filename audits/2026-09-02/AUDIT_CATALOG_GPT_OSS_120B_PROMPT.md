# Audit — admit gpt-oss-120b to the SPEC-023 autotune model catalog (Tier-1)

Review the COMPLETE staged diff of this branch as it will land. Run `git diff --cached` (or `git diff origin/main...HEAD` if unstaged) and review every file. This is a MONEY-PATH change (rate card) on branch `catalog/gpt-oss-120b`.

## What the change does
Admits `mlx-community/gpt-oss-120b-4bit` as a recommendable Tier-1 catalog model so 96GB+/128GB-class providers can serve and earn on it. It adds one row to each signed autotune feed, adds the coordinator inline rate-card fallback row, and cuts a new signed release `published-2026-09-02-gpt-oss-120b-v1` (regenerating release.json, release-ledger.json, tier2-identity-binding.json, dist/static/* + .sig, and the baked AutotuneCatalog.generated.swift). It does NOT touch tier2-catalog.json (separate verified-settlement trust layer, different key) — consistent with the #466 precedent for a recommendable model. Test fixtures pinned to the prior release id / baked generated_at were updated.

## Values to verify (challenge them)
- `sha256 = 5003c9196bd6664b22227d687472ba2eb50c2c4daa224b36c230edbbe36b18fb` — the artifact_manifest hash. It was derived from HuggingFace LFS oids and independently confirmed by replicating `scripts/hash-model-weights.go`'s exact Go struct marshaling. The release-time re-hash from a real download is still the authority.
- `min_ram_gb = 90` — operator override. Weights are ~62 GiB; the tool's auto-floor caps at 64 which is unsafe for a 62 GB-weight model (~85 GB resident). 90 gates it to ram-4>=90 i.e. 96GB+ Macs. Is 90 correct/safe?
- `min_bandwidth_tier = C` — matches the gpt-oss-20b sibling (small-active MoE). Is C appropriate or should it be higher?
- `bench_gate` = min_sustained_tps 10, max_4k_ttft_ms 4500, provenance source `policy` — conservative, no local bench (no operator hardware is 96GB+; the external 128GB provider refines it via SPEC-023 §12 after admission). Precedent: qwen3-32b (`never_benched`) and nemotron (`runtime_validated_only`) ship recommendable without a throughput bench.
- rate-card: completion 136000, prompt 68000 (=0.5×), prompt_cache_hit 17000 (=0.25×prompt), provider_share_bps 9000 — $0.136/M completion, a 20% undercut of the $0.17/M OpenRouter market. Matches the repo's pricing pattern.
- demand-rank: rank 27 (OpenRouter demand rank), demand_weight 0.5, min_provider_target 5, recommendable true.

## Lanes to report (this pass is: {{LANE}})
Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO. The merge bar is 0 CRITICAL, 0 HIGH, 0 MEDIUM.

Focus areas across the three lanes:
- CODE: are the feed rows schema-valid and internally consistent across all four feeds + release manifest + baked Swift? Do the test-fixture date/release-id changes preserve the original test intent and coverage (not merely silence assertions)? Is the append-only ledger update correct?
- SECURITY: model identity binding (sha256/model_revision) integrity; no mispricing path (verify `mlx-community/gpt-oss-120b-4bit` normalizes to rate-card key `openai/gpt-oss-120b` via NormalizeModelKey on both Go and Swift, so it never silently falls back to the higher `default` rate); anti-rollback/release-freshness intact; no secrets, no signing-key material, no weakened trust gate.
- ARCHITECTURE: is admitting via Tier-1 feeds only (without a tier2-catalog entry) correct and consistent with the release/verify contract? Does the release-cut (new release_id, regenerated artifacts, re-sign) follow the catalog-release.py contract? Any drift between source feeds and dist/static or baked Swift?

Be specific: cite file:line. If a value is wrong or a gate is weakened, say so with the failure scenario. Do not invent issues to fill a lane.
