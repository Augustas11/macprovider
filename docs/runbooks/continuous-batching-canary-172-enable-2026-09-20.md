# Operator canary CB on v1.8.172 — 2026-09-20

Studio-only enable attempt. Fleet stayed on 1.8.123. Slots stayed 4.
No secrets, tokens, or raw completions are recorded here.

## Header

- **Date:** 2026-09-20
- **Operator:** augstar
- **Provider id:** `mp-5aad6b654611666e16edf83dc0f326eb`
- **Installed RC:** signed `v1.8.172` @ `c512d342b1df6c495afeabbe49eaca74a98107c4`
  ([run 35512582454](https://github.com/Augustas11/macprovider/actions/runs/35512582454)
  attempt 1)
- **Binary path:** `/Users/a1/macprovider/macprovider-cli` (launchd
  `gui/501/live.malibu.provider`); CLI SHA-256
  `7bd43fe8582206043b70e95b8bc232eb0826511832fc43ff0ffe91555c92ac60`
- **Metallib:** co-located `/Users/a1/macprovider/mlx.metallib` present
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1
  (25E253), thermal `nominal`, not throttled, AC power
- **Model tuple:** served `qwen3-coder-30b-a3b-instruct` /
  `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` revision
  `6e302ea604ad9ab206367e2c501d1571023e7b6d`, model SHA-256
  `10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0`
- **Entry 110 slots_total:** 4 (`max_concurrency_override: 4`, unchanged)
- **Config:** `continuous_batching: canary` plus `paged_kv.enabled: true`
  (production defaults `blockSizeTokens=16`, `maxPhysicalBlocks=1024`). Queue
  limit unset. Launchd argv is `serve --config` only.

## Load-time attach

After kickstart, pid 36016 (runs=3) reached `ready` / `buyer_serving` with
Pearl still accepting 172. Load-time probes:

- parity `established=true` nLayers=48 nNew=32 gatherKernelCalls=3072
  maxLogicalBlocks=18 nonIdentityPermutation=true
- batched-isolation `requiresMoE=true proven=true rowsDecoded=2 rowFailures=0
  crossRowDivergences=0 challengeDistinguishing=true`
- `[paged-kv] measure OK: runtime measurement complete, paged-KV attach eligible`

Startup also emitted the configuration-only canary line
`event=batching_unsupported action=serial_routed reason=local_batching_capability_unavailable`
before the model/engine attached. That is expected preflight, not the request path.

## Keyless serve-path probe

One local loopback POST `/v1/chat/completions` with `X-Request-ID`, no
conversation key, `max_tokens=8`, temperature 0:

- HTTP **503**
- `code=continuous_batching_prefill_failed`
- `inference_ran=false`, `settlement_ran=false`, `retryable=false`
- no `event=batching_unsupported` on that request (the scheduler admitted it)
- durable replay store wrote one claim file (`version=1`, request-id and
  fingerprint SHA-256 only)

Admitted canary traffic fail-closes on prefill. It does **not** serial-route
after admission. Buyer relay requests also carry a stable request id, so this
would 503 live traffic.

## Rollback

Restored `/Users/a1/.config/macprovider/config.yaml` from
`config.yaml.bak-cb-canary-20260920T230131Z` (no `continuous_batching`, no
`paged_kv`). Kickstart `gui/501/live.malibu.provider`.

Post-rollback:

- 172 identity unchanged, Pearl `buyer_serving`, slots 4, thermal nominal
- keyless serial loopback HTTP **200**, `finish_reason=stop`,
  `prompt_tokens=15`, `completion_tokens=1`, `cached_prompt_tokens=0`,
  observed model hash `10adb5da…`

Replay claim file from the failed canary request was left in place.

## Evidence template

- SPEC-039 descriptor: load-time attach eligible on this exact served tuple
- #887 / #1476 FR-PKV10: landed; not an enable signal
- #1477 / #1489 sticky: landed; first scope stayed keyless
- Durable replay: store-backed `ContinuousBatchRuntimeReplayAuthority` claimed
  the keyless request; this is not enough while prefill 503s
- MSB-01..05 / leftovers / MoE flag: prior packaged 171/172 evidence, unchanged
- Secrets redaction: no tokens, bearer headers, or raw completions captured

## Decision

**Rollback.** Keep `continuous_batching` off on Studio 172. Do not set `on`.
Do not raise slots. Do not fleet-promote. Do not canary other Macs.

Stop condition: the attached serve-path scheduler returned
`continuous_batching_prefill_failed` for a keyless request after descriptor
admission. That is not a serial canary.

## Follow-up

Fix serve-path prefill on packaged 172 (`PagedKVSharedForwardBackend.prefill`
/ scheduler `continuous_batching_prefill_failed`) so a keyless loopback with
`X-Request-ID` returns 200 from the scheduler, then re-run this gate. Until
that proof exists, canary stays off.
