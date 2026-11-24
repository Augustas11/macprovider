# Inkling-2-Mini catalog intake (#2467)

Status: **base row listed** in catalog release
`published-2026-11-24-inkling-2-mini-listed-v289` (static feeds signed with
`streamvc-autotune-static-v4`, Tier-2 pin signed with `catalog-key-2026q2`).
The uncensored row stays in `staged-rows.json` until its artifact is
published. `scripts/tests/test_inkling2_staged_rows.py` reads the base row
back from the signed inputs and runs the staged row through the same
validators `catalog-release.py generate` uses.

Rule 15 passed on 2026-11-24 on the pinned engine (Studio run
`20261124T073707Z`, fork `10584fc0`, `3.33.0-macprovider.89`, JOB_PASS):
greedy parity 64/64 on both layouts at 1K and 8K; oQ4e decode 45.3/43.9/40.2
tok/s at 1K/8K/32K with the levers on (26.1/25.2/22.4 off), 156-163% of
mlx-vlm; prefill 99-107%. The earlier 3.32.3-base run `20261124T062416Z`
(`ea6f545c`) measured 46.4/45.6/41.0 decode.

At the cut the artifact entry became `verified` (2026-11-24) and the intake
decision is `admit_listed` on the cold-start slot with tier target `<= 36 GB`
(min_ram_gb 32 plus the 4 GB intake safety margin).

## Served artifact

| | |
|---|---|
| Catalog key | `thinkingmachines/inkling-2-mini` |
| Served id | `mlx-community/Inkling-2-Mini-oQ4e-mtp` @ `3eea042751cd296b7266628a8342c1749242e1fe` |
| Snapshot manifest | `75509c7fcd864d109d542676ed14763a2c5c570c731f3c1d1180d0207b6b9b34` (committed under `phase3-binary/catalog/autotune/snapshot-manifests/`) |
| Size | 16,873,811,514 bytes, 15 files: 4 weight shards and `mtp.safetensors` (DSpark draft, 635,801,416 bytes) |
| Format | `inkling2_loop`, oMLX v0.8.1 oQ4e: NVFP4 g16 experts for layers 0-19, affine 4-bit g64 for layers 20-23, affine 8-bit attention, embeddings and head, BF16 vision and draft |
| Placement | `min_ram_gb` 32, tier C, `class-30b-moe` |
| Price | one rate row at the `google-gemma-4-26b-a4b-it` rates (closest geometry: 26B total, about 4B active): $0.06 prompt, $0.015 cache hit, $0.24 completion per 1M tokens |

The file sizes and LFS SHA-256 values come from the Hugging Face tree API at
the pinned revision. Plain git files were hashed from their resolved bytes and
cross-checked against the git blob SHA-1, the same way
`scripts/catalog-hash-sweep.py` does it. No weights were downloaded.

The 24 GB tier is not staged. 16.87 GB of weights is above 70% of 24 GB
(16.8 GB). A 24 GB row needs the real-Mac check from the issue plan.

## Licence

- `thinkingmachines/Inkling-2-Mini`: Apache-2.0 (README `**License:** Apache 2.0`; no LICENSE file in the repo). The README links the Thinking Machines Model Acceptable Use Policy. The policy says that accessing or using the Model Materials means agreeing to it. It covers modified versions. It also makes an operator that lets others use the model responsible for their compliance. It has no non-commercial or model-as-a-service clause.
- `mlx-community/Inkling-2-Mini-oQ4e-mtp`: Apache-2.0, "following the source model" (README; no LICENSE file).
- `OpenUncensored/Inkling-2-Mini-Uncensored` @ `4e5f06d7`: Apache-2.0 (README front matter and disclosure section; no LICENSE file). Its base licence is the one above, so the base model's acceptable use policy applies to it.

**Uncensored row: operator decision 2026-11-24 to list.** The policy
prohibits attempts to circumvent, disable or remove measures implemented in
the Model Materials, and a refusal-removed derivative runs straight into that
clause; the operator decided to list the row anyway. Its notes carry the
Apache-2.0 licence, the policy link and that decision.

`staged-rows.json` stages `openuncensored/inkling-2-mini-uncensored` beside the
base row: the same tier, RAM, rate class and price, under its own labelled
rate row, as the abliterated rows carry their bases' prices. The served
artifact `aug11/Inkling-2-Mini-oQ4e-mtp-uncensored` is the oQ4e base with
the source's changed attention output projections re-quantized in the
base's own format. `scripts/lab/2467/job-inkling2-uncensored.sh` builds and
checks it in a Studio window and publishes it only with `PUBLISH=1`. Until
then the row's revision, manifest hash and size are the placeholders its
`placeholders` block names. Source identity: snapshot manifest
`050f1cec…69e2` (`openuncensored-source-050f1cec.manifest`), 20,191,617,908
bytes. The source ships `edit.pt`, a PyTorch pickle. The job never downloads
or unpickles it and reads tensors only through safetensors.

## Measured so far (not reproduced here)

Issue #2467 slice 3 (Studio, mlx-vlm @ `f1618d6d`, greedy, 64 decode steps,
source checkpoint): 64/64 matching tokens at 1K and 8K, mean KL 0.0018 and
0.0021. Swift decode was 17.1 and 17.8 tok/s against mlx-vlm's 29.0 and 27.9.
The campaign reports the fork head `5c0ccd883` at 64/64 parity, prefill at
97-108% of mlx-vlm and decode at 85-86%. Those raw files are not in this repo.

## Placeholders a Studio window fills

1. `bench_gate`: `min_sustained_tps` and `max_4k_ttft_ms` are the advisory defaults, with provenance `never_benched`. Replace them with the rule-15 window's single-row decode and 4K TTFT on the pinned provider build, and set `runtime_validated_only`.
2. Rule-15 numbers at 32K. The thread has only 1K and 8K figures.
3. Quality probe on the served oQ4e build. None is in the thread.
4. Native MTP with the bundled DSpark draft: not staged. That needs the Swift drafter and its own SPEC-048 tuple and evidence.

## Steps to land

1. Rule-15 decode A/B passes on the Studio.
2. Tag the fork (`macprovider/2467-inkling2`), then bump the `mlx-swift-lm` pin in `phase3-binary/Package.resolved` to the tag.
3. Provider: route `inkling2_loop` to the port, and add the Inkling reasoning and `inkling2` tool-call grammar. Neither is in this branch.
4. Apply `staged-rows.json` to the catalog inputs: the candidate, demand-rank, artifact-source (`verified` on the cut date), rate-card-source, acknowledged-pricing-moves, tier2-catalog, tier2-identity-binding and intake-decision files, plus the coordinator.yaml rewards row. Then sign the release (`catalog-key-2026q2`, `streamvc-autotune-static-v4`).
5. Merge, then `scripts/ops/catalog-activate.sh status` and `next --run`. Live probe: a 32 GB or larger provider serves a strict-pinned paid buyer request through the Malibu gateway.
