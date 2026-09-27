# Investigation handoff — CB paged-KV parity for the remaining Qwen3.x hybrids

Goal: make continuous-batching (SPEC-039 paged-KV shared-forward) produce
**bit-exact** batched output for the Qwen3.x hybrid decoders that currently fail
parity, so they can join the FR-PKV12 mixed-layout allowlist. Broader operator
goal: CB working for **every** catalog model.

This is a distinct kernel/numerics debugging track, not a config change. It does
not block or reopen [PR #1771](https://github.com/Augustas11/macprovider/pull/1771),
which shipped only the parity-proven `qwen3.6` pair.

## What is already established (do not re-derive)

Measured 2026-09-27 on the Mac Studio (M3 Ultra 256GB) with the packaged
v1.8.201 runtime, via `macprovider-cli msb-throughput --engine scheduler
--no-compile` (the production paged shared-forward serve path,
`compiledDecode:false`). All five resident Qwen3.x hybrids were run for
throughput (`--scenario throughput`, rows 8) and correctness (`--scenario
leftovers` = parity + isolation + row leave/join, rows 4, 48 greedy parity
tokens).

| Model | arch | agg vs serial | isolation | **parity** |
|---|---|---|---|---|
| `qwen/qwen3.6-35b-a3b` | `Qwen3_5MoeForConditionalGeneration` | 2.86× | pass | **PASS (bit-exact)** |
| `qwen/qwen3.6-27b` | `Qwen3_5ForConditionalGeneration` | 1.88× | pass | **PASS (bit-exact)** |
| `qwen/qwen3.5-35b-a3b` | `Qwen3_5MoeForConditionalGeneration` | 2.78× | pass | **FAIL** |
| `qwen/qwen3.5-27b` | `Qwen3_5ForConditionalGeneration` | 1.88× | pass | **FAIL** |
| `qwen/qwen3.8-27b` | `Qwen3_5ForConditionalGeneration` | 1.89× | pass | **FAIL** |

Parity = greedy temp-0 serial vs batched token SHA-256 over 48 tokens. The three
failures diverge (`oneRowMatch=false`); the throughput and cross-row isolation
gates pass, so this is purely a **decode-correctness/numerics** problem on the
batched path, not perf and not isolation.

Divergent token hashes (serial ≠ batched):
- `qwen3.5-35b-a3b`: serial `41f507569d1ed1be157e95c84385810c168900c2fe443bab6813311946e1be4b` / batched `65ad0703496f4498b7269ddd06b96fd9a85f54090bc92691964572baa52bebcd`
- `qwen3.5-27b`: serial `1ce83ee4497839320b6afc28ffc044da04591679c967b2355ea4904ceefe4899` / batched `26ca4a42071b6f7a19f16d7eb6d3f3ef67c01fc098ce447ef12c45786a21a51c`
- `qwen3.8-27b`: serial `2168d14061f153ad0c6cdbd33cd898df168c32e77409c8352dee334e4bc386ea` / batched `77364ea5a8005b41a6f3e5c94ea36638dd2fecf6c70ece8e97bf3c254a74acaa`

The passing `qwen3.6` pair is the exact model family the paged path was built and
validated against (#1646 / #1716). The others were never validated on it.

## Config-diff evidence (the starting point)

Two apparently distinct failure classes:

**MoE class — `qwen3.5-35b-a3b` (FAIL) vs `qwen3.6-35b-a3b` (PASS).** Real
`config.json` differences that plausibly change decode numerics:
- `text_config.partial_rotary_factor`: **0.25 on 3.6 (partial RoPE), absent/full on 3.5** — the paged gather/attention path may only be correct for the partial-rotary layout it was validated on.
- MoE `mlp.gate` / `mlp.shared_expert_gate` are **quantized 8-bit on 3.6, unquantized on 3.5** — different router numerics.
- Minor: `bos_token_id`, `mlp_only_layers`, `output_router_logits`, `tie_word_embeddings`, `transformers_version`.

**Dense class — `qwen3.8-27b` (FAIL) vs `qwen3.6-27b` (PASS).** The `text_config`
scalars and quantization layout are **nearly identical** (no scalar diffs, no
gate quant). So the dense failure is most likely a **weight-level numerical
sensitivity** in the paged shared-forward decode (precision differences that flip
greedy argmax for 3.8's weights but not 3.6's), not a structural config gap.

## How to reproduce and inspect

Build the current CLI on the Studio and run the harness per model (loopback only,
never touch live :8080):

```bash
ssh macstudio 'CLI=/path/to/release/macprovider-cli
ART="/Users/a1/Library/Application Support/macprovider/models/<repo-dir>/<rev>/<sha>"
"$CLI" msb-throughput --model "$ART" --engine scheduler --no-compile \
  --scenario leftovers --rows 4 --prompt-tokens 512 --parity-tokens 48 --runs 1 --stdout-only'
```

Resident artifact dirs: `mlx-community--Qwen3.5-27B-4bit`,
`mlx-community--Qwen3.5-35B-A3B-4bit`, `mlx-community--Qwen3.8-27B-4bit`
(plus the passing `Qwen3.6-*` for A/B).

To localize the divergence, compare serial vs batched **per-layer activations**
for one failing model on a short greedy prompt: find the first layer/op whose
output differs, then whether it is the RoPE application (partial vs full rotary),
the gather-fed SDPA, the Mamba recurrent-state handling, or the MoE gate.

## Code anchors

- `phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift` —
  `PagedKVSharedForwardBackend`, `runDecodeStep()` / `decodeLockstepWindow` (the
  batched decode path that diverges).
- Gather kernel identity `macprovider_paged_kv_gather_v1`; RoPE application in the
  paged attention path (check partial-rotary handling).
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` — the runtime parity
  probe (`computePagedKVRuntimeProbes`, `pagedKVRuntimeProber.parity`) that
  reports `[paged-kv] parity … established=…`; note it currently reports
  `established=true` for these models at load (the load-time probe is weaker /
  shorter than the 48-token harness parity that catches the divergence — worth
  reconciling so the load probe also rejects them).
- `phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift` — the parity
  scenario (`--scenario parity/leftovers`), the authoritative gate.
- FR-PKV12 allowlist: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
  `pagedKVModelCapabilities` `hybridArchitectureAllowlist`, and
  `specs/SPEC-039-paged-kv-attention-engine.md` FR-PKV12.

## Deliverable

Root-cause each failure class (MoE partial-rotary/gate-quant vs dense
weight-numerics), fix the paged shared-forward decode so batched == serial
bit-exact, re-run `--scenario leftovers` to PASS, then add each newly-proven
identity to the FR-PKV12 allowlist (code + SPEC) with its measured evidence — the
same per-identity, evidence-gated pattern PR #1771 established. Also reconcile the
load-time parity probe so it rejects any hybrid that fails the 48-token parity,
closing the gap between `established=true` at load and the harness FAIL.

## Constraints

- Build/bench on the Studio (`swift build -c release`), isolated loopback serve
  (`--no-join --credential-store protected_file`, non-8080 port); never touch
  `live.malibu.provider` / :8080.
- SPEC-039/code changes go through PR review (3-lane audit 0 C/H/M), authored as
  Augustas11. This is a phase3-binary correctness change → PR, not docs-only.
- Do not add any model to the allowlist until it individually passes measured
  parity + isolation. A same-architecture match is never sufficient (that is the
  whole reason these three are excluded).
