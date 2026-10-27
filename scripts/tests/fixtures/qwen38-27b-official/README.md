# Official Qwen3.8-27B intake fixtures

Related: #2154, item 4. Official source: `Qwen/Qwen3.8-27B`, revision
`1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`.

Gate 3: PASS. The model card identifies Apache-2.0 and the retained LICENSE
is the Apache License 2.0 with Alibaba Cloud attribution. Paid commercial
serving and mirror redistribution (including a quantized derivative) are
permitted under its conditions. Distribute the license, retain applicable
copyright/patent/attribution notices and any upstream NOTICE, and mark changed
files for a conversion. The license grants no trademark rights; its patent
termination and warranty/liability terms continue to apply. No revenue or
user-count threshold is stated.

LICENSE SHA-256: `bbedc3fda3305820b977265f01b8619d87570a6739de3a5582c3464840f1e57a`. Exact source:
https://huggingface.co/Qwen/Qwen3.8-27B/blob/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0/LICENSE

The model card was reviewed at the same revision:
https://huggingface.co/Qwen/Qwen3.8-27B/blob/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0/README.md

License review does not establish runtime parity, memory fit, quality,
paid eligibility, promotion or a tier-default winner.

## Artifact choice and conversion

No official Qwen-owned MLX build of this checkpoint was found in the official
model listing. Use the pinned official BF16 source; do not substitute the
existing community quantization. `source-manifest.json` records all 32 files,
55,586,114,863 total source bytes, 55,563,006,776 shard bytes and
55,562,855,904 tensor bytes. The source weights alone exceed both tier
allowances, so source BF16 is not the serving artifact. Four-bit converted
size and RAM fit remain unmeasured, not inferred from another quantization.

Use existing mlx-vlm 0.7.10 (Blaizzy/mlx-vlm commit
`8c061ef516e7f8b584c0d5b64f26b50d5806303b`) with mlx 0.32.4, already pinned
for repository reference work. Its `mlx_vlm/convert.py` supports `--mtp`,
`--mtp-output`, four-bit affine quantization and a pinned source revision:

```sh
python -m mlx_vlm.convert --hf-path Qwen/Qwen3.8-27B \
  --revision 1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0 \
  --mlx-path "$TARGET_OUTPUT" -q --q-bits 4 --q-group-size 64 --q-mode affine \
  --mtp --mtp-output "$DRAFTER_OUTPUT"
```

This is a future hardware-window command, not a command run during coding.
Set output directories in private lab storage. Keep the exact original
config/template/tokenizer and source inventory; distribute license and notices,
and mark the conversion. Retain all 15 source `mtp.*` tensors in the separate
dense `qwen3_5_mtp` drafter produced by the bundled
`mlx_vlm/speculative/drafters/qwen3_5_mtp/split.py`. Verify target plus drafter
inventories after conversion. The converter catches extraction failures and
can still exit successfully: a missing/partial drafter fails readiness even
when the base conversion succeeds. Target sanitization intentionally removes
`mtp.*`; target-only output never satisfies the MTP requirement. Do not add a
nonempty vision config to the text-only drafter.

Compute both converted identities with the existing canonical snapshot-manifest
hashing rules, record exact files and bytes, and bind target/drafter separately.
Null output hash/size/`min_ram_gb` in this fixture are marked preparation
placeholders, never publishable artifact-feed entries.

## Native mapping (slice 3)

The official root is `qwen3_5` / `Qwen3_5ForConditionalGeneration`, with a dense
`qwen3_5_text` decoder. `ModelRuntime` already maps the exact catalog key to
that architecture. Fork `Augustas11/mlx-swift-lm` at
`9b2766ee4f4271669e58429e6eb1251e22e5ecaa` registers it in LLM/VLM factories;
`Libraries/MLXLLM/Models/Qwen35.swift` and the matching MLXVLM implementation
already accept this geometry:

| Official property | Existing implementation / difference from incumbent |
|---|---|
| 64 layers, full every fourth | 48 Gated DeltaNet + 16 full attention; `layer_types` matches the computed schedule |
| Hidden 5120, intermediate 17408 | Configured dense MLP; no experts or routing, unlike Qwen3.6-35B-A3B |
| Q24/KV4, head256, gated attention | Existing configurable full-attention path |
| Linear K16/V48, dimensions128, kernel4 | Existing Gated DeltaNet cache path |
| RoPE theta10000000, partial .25, mrope sections11/11/10 | Existing rope/config decoding; oracle remains required |
| Vocab248320, untied embedding/head | Existing configured embedding/output projection |
| Vision depth27, hidden1152, patch16, merge2 | Existing Qwen3.5 VLM wrapper; this intake does not newly qualify vision/video |
| Dense MTP, one full-attention layer, shared embedding | Existing `Qwen35MTP.swift` dense branch and `Qwen35TextMTPRegistration`; separate artifact |
| Function-XML tools | Existing Qwen grammar; official-template regression added in slice 6 |
| Reasoning low/medium/xhigh; history reasoning | Prompt preparation must adapt high/max and preserve supplied assistant reasoning for this exact model |

The config's extra `attn_output_gate`, `output_gate_type`, `hidden_act` and
`mamba_ssm_dtype` fields do not justify a decoder rewrite. Gate/activation math
must be judged against the official reference, not inferred from unused config
labels. `Qwen35MoE.swift`/`Qwen35FusedMoE.swift` and `Qwen3MoE.swift` routing
are not this dense model's execution path. No new architecture registration,
MoE dispatch, decoder or dependency pin is warranted before measurement.

## CB and native MTP (slices 4–5)

`ModelRuntime.pagedKVHybridModelIsAllowlisted` already accepts this exact key
and architecture; its topology validator checks hybrid layer geometry and the
dense branch needs no expert dispatch. `PagedKVRuntimeBridgeTests` already
includes this key. Retain those gates and FR-CB10 row selection unchanged.
Architecture recognition is not signed CB authorization: the current signed CB
policy has no Qwen3.8 entry. The window must prove actual scheduler rows and
bind the converted target identity before adding its measured policy entry in
this same campaign. Preserve current Qwen3.6 and GLM entries.

The source ships MTP; it is not optional for this intake. Existing dense draft
support and `qwen3_5_mtp_v1` separate-artifact selection can be reused. Keep
slice 5 pending until the multi-family campaign PR #2152 merges, then rebase
and bind the newly converted target and drafter without replacing other
entries. No new SPEC-048 acceptance gates are introduced. Qualify on the lab
build; a signed CLI cut only rebinds identity.

## Catalog preparation and intake disposition (slice 7)

Reuse the existing key, `class-32b`, explicit prompt/cache-hit/completion price
row `192000 / 48000 / 2000000` credits/Mtok, matching `rewards.rate_card` row,
and demand-rank row (rank30, weight0.4, target5). Those are existing published
values, not fresh market measurements. Native source restriction remains
`mlx_cache`. The current recommendable row and its community artifact are
unchanged; they are not qualification of the new official-derived conversion.

SPEC-023 §16.8 preparation decision: **pending, no add/promote/default change**.
This is not a release-bound `macprovider.intake-decision` manifest. Do not
invent source-frame digests, demand/provider/buyer counts, rank, artifact
identity, memory peak or admission status to populate one. When output identity
and measurements exist, update the artifact/candidate/CB/MTP bindings together
in this campaign and use the generator's actual release transition rules. A
required §16.8 decision must retain authentic source frames and thresholds and
be bound to the shared release. Preserve pricing/billing parity and incumbent
fallback. Existing admission is not silently demoted to stage an unknown hash.

The supervisor's default decision is pending the paired quality/throughput
comparison. Do not add an unconditional Qwen3.8 preference now. After the
comparison, implement only the measured winner for 32–48 GB after existing
paid-eligibility checks, using the Bonsai eligibility-first fallback pattern.
Record both models' quality scores, serial/CB buyer tok/s, TTFT and memory in
the PR's default-decision table. A model that cannot serve completed buyer
answers within the existing advisory target (10 output tok/s and 3s 4k TTFT)
is flagged as unusable for this default decision; do not lower those targets to
manufacture a winner. These are comparison criteria, not new admission gates.
If quality is tied/inconclusive, retain the incumbent. If the quality winner
misses usability, report that tradeoff and retain the incumbent pending the
operator's decision; no automatic tradeoff or CB/MTP withdrawal.

