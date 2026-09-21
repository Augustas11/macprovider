# Operator canary CB on v1.8.175 — 2026-09-21

Studio-only enable. Fleet stayed on 1.8.123. Slots stayed 4. Mode is
`canary`, not `on`. No secrets, tokens, or raw completions are recorded here.

## Header

- **Date:** 2026-09-21
- **Operator:** augstar
- **Provider id:** `mp-5aad6b654611666e16edf83dc0f326eb`
- **Installed RC:** signed `v1.8.175` @ `d02798dbe0482b4454cc25bf497959da59242faa`
  ([run 35569340744](https://github.com/Augustas11/macprovider/actions/runs/35569340744)
  attempt 1)
- **Binary path:** `/Users/a1/macprovider/macprovider-cli` (launchd
  `gui/501/live.malibu.provider`); CLI SHA-256
  `27a8ceac8fc35ca1b5447743048e7e6b0008734e0967a9569cd695c78d597ec8`
- **Metallib:** co-located `/Users/a1/macprovider/mlx.metallib` present
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1
  (25E253), thermal `nominal`
- **Model tuple:** served `qwen3-coder-30b-a3b-instruct` /
  `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`, observed model hash
  `10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0`
- **Entry 110 slots_total:** 4 (`max_concurrency_override: 4`, unchanged)
- **Config:** `continuous_batching: canary` plus `paged_kv.enabled: true`
  (production defaults). Queue limit unset. Launchd argv is `serve --config`
  only. Backup:
  `/Users/a1/.config/macprovider/config.yaml.bak-cb-canary-20260921T074014Z`

## Load-time attach

After kickstart, live 8080 reached `ready` / `serving_buyers` with Pearl still
accepting 175. Load-time probes:

- parity `established=true` nLayers=48 nNew=32 gatherKernelCalls=3072
  maxLogicalBlocks=18 nonIdentityPermutation=true
- batched-isolation `requiresMoE=true proven=true rowsDecoded=2 rowFailures=0
  crossRowDivergences=0 challengeDistinguishing=true`
- `[paged-kv] measure OK: runtime measurement complete, paged-KV attach eligible`

Startup also emitted the configuration-only canary line
`event=batching_unsupported action=serial_routed reason=local_batching_capability_unavailable`
before the model/engine attached. That is expected preflight, not the request
path.

## Keyless serve-path probe

One local loopback POST `/v1/chat/completions` against the **live 8080**
provider with `X-Request-ID`, no conversation key, `max_tokens=8`,
temperature 0:

- HTTP **200**
- `finish_reason=length`
- `prompt_tokens=15`, `completion_tokens=8`, `cached_prompt_tokens=0`
- no `event=batching_unsupported` and no `event=batching_prefill_failed` on
  that request
- durable replay store wrote a matching claim file (`version=1`, request-id
  and fingerprint SHA-256 only)

This is the same request shape that 503'd `continuous_batching_prefill_failed`
on 172.

## Evidence template

- SPEC-039 descriptor: load-time attach eligible on this exact served tuple
- #887 / #1476 FR-PKV10: landed; not an enable signal
- #1477 / #1489 sticky: landed; first scope stayed keyless
- Durable replay: store-backed `ContinuousBatchRuntimeReplayAuthority` claimed
  the keyless request
- MSB-01..05 / leftovers / MoE flag: prior packaged 171/172 evidence, unchanged
- Secrets redaction: no tokens, bearer headers, or raw completions captured

## Decision

**Keep canary.** Studio 175 only. Do not set `on`. Do not raise slots. Do not
fleet-promote. Do not canary other Macs.

Rollback remains config-first: restore the 20260921T074014Z backup (or set
`continuous_batching: off` and drop `paged_kv`) and kickstart
`gui/501/live.malibu.provider`.
