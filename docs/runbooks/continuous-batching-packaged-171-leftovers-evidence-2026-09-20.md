# Packaged v1.8.171 leftovers — Studio evidence, 2026-09-20

Signed acceptance candidate `v1.8.171` @
`12de7aea9e3ecf07df229682fc6defd225e4085f`
([run 35505282884](https://github.com/Augustas11/macprovider/actions/runs/35505282884)
attempt 2). Compat
`Augustas11/macprovider:v1.8.171@12de7aea9e3ecf07df229682fc6defd225e4085f`.
Staged at `/Users/a1/candidate-v1.8.171/`. Harness ran from the **packaged**
tarball CLI + co-located `mlx.metallib`, not a worktree build.

Buyer `continuous_batching` stayed **off**. Live `v1.8.170` `live.malibu.provider`
(pid 32516) stayed up. Do not promote. Do not canary 170. Do not raise slots.

## Header

- **Date:** 2026-09-20
- **Operator:** augstar
- **Binary:** packaged `macprovider-cli` SHA-256 `3b803245aad3c73338c7fed27071dbe044981e9b5448f96dbeb841a9a3cc3f81`
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power
- **Model:** `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`
- **Command:** `msb-throughput --engine scheduler --compile --scenario leftovers|msb05|msb03`

## Results

| Leftover | Result | Notes |
| --- | --- | --- |
| Failure isolation | **pass** | Cancel after first token; cancelled `cancelled`, healthy `length`. |
| Durable replay | **pass** | First `eligible_owner`, second `non_settling_replay`, tokens match. |
| Warm-swap / drain | **pass (scheduler drain)** | Active rows `length`/`length`; queued rejected; permit valid; post-drain reject. Live 170 weights were not swapped. |
| Temp-0 exact token match | **fail at index 9** | Same FR-CB6 compiled-graph divergence as the worktree harness. |
| MSB-05 Q1 native parallel | **0.73×** | Two concurrent `generate()` streams. Q2 oMLX sidecar unavailable. Native parallel still does not scale. |
| MSB-03 ragged | **pass 1.72×** | 512/1024/1536/2048 prompts, 256 decode. Short-row TTFT 1.07× (gate ≤2×). Usage four distinct IDs, `eligible_owner`, 256 completion. Peak RSS 33.0 GB. |

On-box JSON: `/Users/a1/candidate-v1.8.171/evidence/` (snapshot paths, not checked in).

Worktree predecessor:
[`continuous-batching-frcb15-leftovers-evidence-2026-09-20.md`](continuous-batching-frcb15-leftovers-evidence-2026-09-20.md).
