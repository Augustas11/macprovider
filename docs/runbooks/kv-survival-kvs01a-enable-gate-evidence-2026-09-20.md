# KV Survival KVS-01a Enable-Gate Evidence — 2026-09-20

Sanitized: no prompts, completions, raw conversation keys, bearer headers, or
operator secrets. This was the SPEC-037 KVS-01a attempt for the Mac Studio lab
tuple. It reached a real GUI-launched local serve and smoke attempt, then
stopped because the encrypted KV disk tier stayed activation-dormant with
`keychain_unavailable`.

## Header

- **Date:** 2026-09-20
- **Operator:** augstar
- **Hardware tuple:** Mac Studio, Apple M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power
- **Candidate binary:** `/Users/a1/candidate-v1.8.170/install/macprovider-cli`
- **CLI SHA-256:** `37a680f3781e1c0796aeaa8ce549e02f0cef996898d53b0a5c9715d7de51a957`
- **Compatibility set:** `Augustas11/macprovider:v1.8.170@b8faebae0cb144301de77b2f0b43b5864bfeb2fe`
- **Release commit:** `b8faebae0cb144301de77b2f0b43b5864bfeb2fe`
- **Model tuple intended for gate:** `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`, snapshot `6e302ea604ad9ab206367e2c501d1571023e7b6d`, model/artifact SHA-256 `10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0`
- **Lab serve tuple intended:** `127.0.0.1:18080`, provider id `kvs01a-studio-lab`, `continuous_batching=off`, `kv_disk_cache.enabled=true`, `allow_buyer_keys=false`, no coordinator join

## Freeze Check

- GitHub PR #1623 (`perf/spec038-msb-throughput-harness`) was already merged.
- `127.0.0.1:8080` was initially occupied by the live launchd provider:
  `/Users/a1/macprovider/macprovider-cli serve --config /Users/a1/.config/macprovider/config.yaml`.
- `127.0.0.1:18080` was free.
- No `msb-throughput`, `swift-package`, or competing MLX measurement process was running.
- The live provider was later paused only for the local 30B smoke attempt, then
  relaunched from the same LaunchAgent. Final check: 8080 listening,
  `/v1/status` ready, model loaded, coordinator connected; 18080 clear.

## E2E Attempt Evidence

The lab config was staged under `/Users/a1/.local/state/kvs-01a/` with a
dedicated `0700` KV cache directory and the packaged candidate tree containing
both `macprovider-cli` and `mlx.metallib`.

The local buyer token was found on this Mac, copied to a private `0600` Studio
lab file, and never printed. A direct sanitized probe against the GUI-launched
local provider returned HTTP 200 with usage and `correctness=ok`, proving the
direct HTTP buyer path and model load were usable:

```text
status=200 ttft_ms=4877 total_latency_ms=4964 prompt_tokens=7248 completion_tokens=8 cached_prompt_tokens=0 correctness=ok
```

The KVS-01a smoke harness was then launched from the Studio GUI session against
the isolated local provider. It exited `5` before any restore arm because the
persist turn returned no usable persisted state:

```text
kvs-01a[c1]: persist turn key_hash=<redacted>
kvs-01a[c1]: persist turn returned no usage; aborting cycle
kvs-01a: smoke mode -- percentile thresholds skipped (correctness only)
kvs-01a: 1/1 cycle(s) FAILED the restored correctness contract
exit=5
```

The provider-side reason was not an HTTP/model failure; it was SPEC-037 tier
activation dormancy. With `provider_id` intact and `serve --no-join` active, the
provider emitted:

```text
event=kv_disk_cache action=enabled directory=/Users/a1/.local/state/kvs-01a/kv-cache ...
event=kv_disk_cache code=disk_miss_io detail=keychain_unavailable phase=activation_dormant
event=kv_disk_cache action=dormant reason=keychain_unavailable retry=backoff
```

The same GUI Terminal session also checked the purge/status surface against the
lab config:

```text
event=kv_disk_cache code=disk_miss_io detail=keychain_unavailable phase=activation_dormant
{"detail":"namespace lock unavailable or quarantined","status":"unavailable"}
```

The GUI Terminal keychain check itself reported the login keychain and returned
`Keychain "<NULL>" no-timeout`, so this was not the earlier SSH-only keychain
context. The candidate is validly signed on disk but exposes no keychain
entitlements in `codesign -d --entitlements :-`.

SPEC-037 FR-KVP8 requires Data Protection Keychain DEKs and says an unavailable
entitlement/access-group path keeps the tier dormant instead of falling back to
the legacy login Keychain. The observed result is therefore a fail-closed
activation stop, not a KVS-01a correctness result.

## Gate Result

- **KVS-01a smoke:** run from GUI session; exited `5`
- **KVS-01a 30-cycle gate:** not run
- **Harness exit code:** `5` for smoke
- **Restored `disk_hit` count:** 0, because no restore arm was started
- **Cached-token equality:** not evaluated
- **TTFT / restore / commit latency percentiles:** not available
- **Purge primitive:** not exercised; `kv-cache status` could not activate the namespace
- **Enable consequence:** none. Do not leave `kv_disk_cache.enabled=true` on this Studio lab serve, do not flip fleet defaults, do not allow buyer keys, and do not mark `SPEC-037-R013` conformant.

## Decision

KVS-01a remains blocked on the packaged CLI's ability to activate the SPEC-037
Data Protection Keychain namespace on the Studio. Running the 30-cycle harness
after this smoke would only grind a dormant/no-op tier and repeat the Entry-199
class of mistake.

Before retrying KVS-01a, cut or stage a reviewed candidate whose KV disk-tier
Keychain mode can create and read its DEK namespace on the target host, or amend
SPEC-037 with a reviewed alternative revocation anchor. Then rerun the same
packaged-binary smoke before any 30-cycle gate.
