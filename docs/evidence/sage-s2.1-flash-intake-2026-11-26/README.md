# Sage S2.1 Flash catalog intake (2026-11-26)

Related: #2466

Catalog key `hygaard/sage-s2.1-flash-oq4e-mtp`. Artifact
`Hygaard/Sage-S2.1-Flash-oQ4e-mtp` at revision
`a972e256db2553562bd718e677d100089aca5fce`, snapshot-manifest.v1 hash
`d59ecd8525692c53ea9dd36d5e690d4c3218713f0b0a81fec77637e1f588c261` (71 files,
186,593,494,737 bytes). The hash was recomputed from the Hugging Face API with
`scripts/catalog-hash-sweep.py`'s algorithm. It equals the `target_sha256` of the
Studio intake runs, whose fetch step (`scripts/lab/2466/fetch-sage.sh`) verified
every file. The manifest is committed as
`phase3-binary/catalog/autotune/snapshot-manifests/d59ecd85….manifest`.

Sage S2.1 Flash is a GLM-5.3-Flash fine-tune by Shanghai AI Laboratory /
InternLM (`internlm/Sage-S2.1-Flash`), MIT licensed. It has the same `glm5_next`
architecture and the same `tokenizer.json` as `zai-org/glm-5.3-flash`. The row
is staged in `staged-rows.json` at the GLM-5.3-Flash placement and price, under
its own labelled rate row. `scripts/tests/test_sage_s21_flash_staged_rows.py`
merges each fragment into the committed input and runs the generator's
validators.

## Measurements

GLM-5.3-Flash and Sage ran back to back on one Mac Studio M3 Ultra (256 GB) on
the #2466 lab build. Sage reuses the GLM-5.3-Flash code path; the only engine
change is its entry on the SPEC-039 FR-PKV12 hybrid allowlist.

| Check | Sage | GLM-5.3-Flash | Source |
|---|---|---|---|
| 4-row batched vs serial parity | PASS | PASS | `verdict-20261124T104526Z.json` |
| Reference top-1 vs mlx-vlm, 1K / 8K / 32K | 16/16 each | 16/16 each | same |
| Greedy tokens vs mlx-vlm, 1K / 8K / 32K | 256/256 each | 256/256 each | same |
| One-row decode tok/s, 1K / 8K / 32K | 41.16 / 39.20 / 37.96 | 41.99 / 39.71 / 38.49 | same |
| 4-row aggregate tok/s, 1K (vs serial) | 75.88 (1.83x) | 73.64 (1.74x) | same |
| Coding-agent quality rubric (serve) | 9/9 | 9/9 | `verdict-20261125T222921Z.json` |
| Native-MTP throughput vs ordinary, s1 cells | 1.16-1.20x, 10/10 blocks each | 1.13-1.15x | run 20261125T081146Z, `mtp-sage-*-20261125T081146Z.json` |

## What the listing does not carry yet

- **Continuous batching.** A CB policy entry binds a signed CLI's attach proof
  (`paged_kv_decision=attached`, `local_proof_result=passed`): its package
  manifest, CDHash and version. Sage is on the FR-PKV12 allowlist only from
  this branch, so no signed CLI can attach it until the cut that carries it
  (1.8.301). After that cut, the canary serves Sage and the entry is drafted
  from that serve, with `cached_turns_donor` `zai-org/glm-5.3-flash`, as the
  uncensored GLM row did in #2276.
- **Native MTP.** Sage's 35 model shards are 475,791,676 bytes larger than
  GLM-5.3-Flash's, so an MTP-13 variant must bind its own R012 fit evidence
  (SPEC-048 0.1.126). The policy and analysis committed here are exploratory
  (`macprovider.native-mtp-exploratory-policy.v1`, one slot, prompts up to
  4,096 tokens, no sustained run). `generate` needs an R015 run on Sage at the
  donor's `qualified_slots` 4 and `max_prompt_tokens` 32,768, plus the
  sustained run.
- **Tools and reasoning before 1.8.301.** The coordinator gives Sage the GLM
  tool grammar and reasoning only on providers at 1.8.301 or later. Older
  CLIs serve it as plain chat.
