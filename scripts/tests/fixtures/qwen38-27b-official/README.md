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

## One-window plan (slice 8; not executed)

Coding-only restrictions remain in effect. Hardware starts only in the
assigned guarded Studio window, after host identity and exclusive ownership
are verified using existing lab controls. No live provider or coordinator
mutation; lab binary is isolated with `--no-join`. Build source plus lab
harness there only. Do not reuse historical scripts that hardcode another
model, identity or host as Qwen3.8 acceptance.

Before running, inventory existing qualification: the catalog has only a
runtime-validated advisory decode observation for the old community artifact;
Qwen3.6 has its own artifact-specific CB/MTP evidence. Neither qualifies this
new source conversion. Reuse all still-applicable evidence and bind changes:
`ChatCompletionRequest.templateReasoningEffort` and `ModelRuntime.userInput`
are the changed prompt-preparation lines; decoder/fork math is unchanged.
New target/drafter identity and official template distinguish this acceptance
from the incumbent's records. Do not repeat unrelated accepted cells.

1. **Preparation.** After the prerequisite merge/rebase, freeze provider and
   dependency commits, decode digest, lab binary hash, conversion environment,
   target/drafter manifests and exact official tokenizer/template hashes.
   Convert using the pinned command above; verify all 15 MTP tensors were
   extracted and the text drafter has no nonempty vision config. Set capped
   GPU limits for each tier; record peak/free RAM and swap before/after load,
   prefill, decode, CB self-check and MTP. Apply the stricter of runtime caps
   and catalog allowances: 28 GiB for 32 GB, 44 GiB for 48 GB, retaining the
   existing 4 GiB reserve. Successful capped allocation on a larger Studio
   establishes a budget check, not real 32/48 GB throughput. Use actual-tier
   FR-CB10 before selecting rows on each machine. Report a tier exclusion on
   the issue once if measured peak fails that tier. Fill `min_ram_gb` from
   the measured full serving peak; weights alone never establish fit.
2. **Goal first.** First serving result in the window: paired native target
   vs incumbent `qwen/qwen3.6-35b-a3b`, prompt512/output128, rows1, serial and
   actual scheduler CB. Report completed-answer output tok/s, TTFT, error
   count and token count before any engine optimization or profiling. Use
   identical prompts, thinking controls, temperature0 and output cap; retain
   tokenizer-derived prompt lengths for each model. Native MTP starts with
   same-row ordinary/native goal tok/s, acceptance, TTFT and exact parity.
3. **Official-reference parity.** Greedy fixed text at exact 1024,8192,32768
   token contexts, output256, official mlx-vlm0.7.10 on the same converted
   target vs native. Record reference config, token IDs, first divergence,
   and all256-token exact match; compare tokens, not decoded strings. Where
   prompt tokenization differs, first prove native/vendor prompt-token parity.
4. **Serial/CB matrix for both models.** Cartesian product: prompt1024/8192/
   32768 × output128/512 × rows1/2/4 × serial/scheduler. Counterbalance model
   and engine order with at least three paired repeats; retain cold/warm
   status. Require exact same-model serial/CB greedy token parity, row
   isolation, cancellation/drain and ragged-prefill checks using existing
   `msb-throughput --engine scheduler` scenarios. Compare cross-model quality
   and timing, never require cross-model token equality. Record per-request
   and aggregate output tok/s, p50/p95 TTFT, completion latency, delivered
   answer/finish reason, errors and each phase's peak/swap. At prompt4096/
   output128/rows1 also evaluate the existing4k advisory TTFT target. Use
   actual scheduler admission metrics; a serial fallback is not a CB pass.
5. **FR-CB10/tool loop.** Run CB self-check at each capped tier, record selected
   row count and reason, then assistant→function-XML→tool→assistant with
   typed nested arguments, required/named selection, retained reasoning,
   streaming/nonstreaming, all accepted effort values and bounded output.
   Check argument fidelity, termination, completed buyer answer and usage.
6. **Paired quality.** Vendor card publishes coding/agentic tasks including
   Terminal Bench2.1 and SWE-bench Pro. The repository's closest fixed subset
   is the nine-case `scripts/revenue_benchmark/coding_agent_workload_v1.json`
   (debug/tests/implement/refactor/review/agent-loop). Freeze its existing
   digest, identical cases/order, sampling, three repeats, reasoning budget
   and correctness rubric before inference for both models. Evaluate task
   correctness/test success and completed tool-loop outcomes, retain all
   failures, and record scores alongside same-cell throughput. Use the
   workload planner, not the revenue calculator, for isolated requests; no
   paid revenue or full vendor-benchmark reproduction is claimed by this
   proxy. If the subset cannot distinguish quality, record inconclusive and
   retain the incumbent. Post the measured paired table as the default
   decision before changing preference. The model card alone cannot pick it.
7. **MTP.** Existing SPEC-048 R005 acceptance corpus plus current R015 policy
   matrix, counterbalanced ordinary/native at the same rows (1,2,4 as allowed
   by the signed tuple); do not grant unsupported rows by benchmark success.
   Use the existing `NativeMTPQualificationTests` and
   `native-mtp-hardware-e2e`, `native-mtp-bench --phase matrix`, then
   `--phase sustained` (at least1800s at the current policy's sustained cell),
   and the existing analyzer. Freeze the current R015 matrix from main:
   admitted slots × prompt1536 and min(4096,signed cap), outputs128/512,
   plus gated overflow cells and sustained s<qualified_slots>-p1536-o512.
   Record token parity, output tok/s, acceptance, TTFT, fallback and peak.
   Preserve multi-entry sidecars. A failure stays a failure; do not replace
   the required gates or seed ordinary throughput with accelerated results.
8. **Campaign completion.** Fill actual artifacts/memory/intake/policy and the
   measured default decision in this PR; audit the final combined diff once
   at freeze (code/security/architecture, 0 critical/high/medium), pass hosted
   CI, and qualify on the lab build before cut. Shared signed CLI cut →
   `scripts/ops/catalog-activate.sh` listing → first-promotion conformance
   (#2107) → promotion. Use `scripts/ops/cli-release.sh status`/`next` and the
   documented `next --run`; catalog uses its corresponding `status`/`next`
   sequence. Identity-only cut rebinding does not regenerate qualification.
