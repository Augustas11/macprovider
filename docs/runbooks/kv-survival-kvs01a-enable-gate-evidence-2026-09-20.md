# KVS-01a enable-gate evidence — 2026-09-20

SPEC-037 restart-survival correctness gate (persist → SIGKILL → relaunch →
`disk_hit`) on the Mac Studio, plus the FR-KVP8 purge primitive on the same
lab namespace. Sanitized: token counts, reason codes, TTFT, RSS, binary
identity. No prompts, no conversation keys, no bearer headers.

## Header

- **Date:** 2026-09-20
- **Operator:** augstar
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power
- **Topology:** isolated local HTTP `127.0.0.1:18080`, `--no-join`,
  `credential_store: protected_file`, `continuous_batching: off`,
  `kv_disk_cache.enabled: true`, `allow_buyer_keys: false`. Synthetic keys
  only (`conv:kvs-synth:`). Live Pearl-connected `127.0.0.1:8080` was not
  killed.
- **Model tuple:** `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`,
  snapshot `6e302ea604ad9ab206367e2c501d1571023e7b6d`,
  `model_sha256=10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0`,
  unquantized `KVCacheSimple` (`kv_bits=null`), codec `kvsurv-codec-v1`
- **Prompt class:** 1600 requested tokens (v1 allowlist under the 256 MiB
  promotion ceiling; measured persist `prompt_tokens=1608`, restored
  `cached_prompt_tokens=1616`)
- **Harness:** `test/e2e/coldwarm-ttft/kvs-01a.sh --cycles 30` (no `--perf-gate`)

## Binaries

| Role | Path | SHA-256 | Identity |
| --- | --- | --- | --- |
| 30-cycle + purge lab CLI | `/Users/a1/.local/state/kvs-01a/run/macprovider-cli` | `dd28a66e3325c47272eafaadebfcf487dff3d6c0d2d1be829a32c9d7179d3e83` | worktree build of #1648 login-keychain KV DEKs; `--version` still `1.8.123` |
| Packaged Studio canary | `/Users/a1/macprovider/macprovider-cli` and `/Users/a1/candidate-v1.8.172/install/macprovider-cli` | `7bd43fe8582206043b70e95b8bc232eb0826511832fc43ff0ffe91555c92ac60` | `Augustas11/macprovider:v1.8.172@c512d342b1df6c495afeabbe49eaca74a98107c4` (includes #1648 and #1650) |

`--version` prints `1.8.123` on both: candidate tags do not bump `binaryVersion`.

An isolated 18080 serve of **packaged 172** hung in
`KVDiskCacheStore.ensureEpochMaster` → `SecItemCopyMatching` with
`SecurityAgent` running (new signed CDHash vs the already-ACL'd lab CLI).
SSH cannot click Allow. Live 8080 172 was left serving. Purge close-out
therefore used the ACL'd #1648 lab CLI against the lab namespace, not the
live provider.

## 30-cycle gate (correctness)

- **Window:** 2026-09-20T11:10:51Z → 2026-09-20T11:59:58Z
- **Exit:** 0
- **Cycles:** 30/30 restored `disk_hit`, `correctness=ok`,
  `cached_prompt_tokens == persist.prompt_tokens + persist.completion_tokens`
  (1616)

Nearest-rank TTFT (ms):

| Arm | n | p50 | p95 | min | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| restored | 30 | 485 | 534 | 328 | 548 |
| warm | 30 | 97 | 118 | 91 | 179 |
| miss (buyer-visible) | 30 | 883 | 1052 | 871 | 1270 |
| disabled | 30 | 875 | 899 | 861 | 920 |

Restored restore_ms p50/p95 = 155 / 182. Commit-latency p50/p95 = 113 / 128
(under the 250 ms advisory write-path cap). Staging peak 204,628,192 bytes
(~195 MiB) under the 256 MiB promotion ceiling.

**Advisory:** restored p95 534 > warm p95 118 × 3. Not a KVS-01a fail
(perf-gate was off). Miss-arm `disk_reason=disk_hit` in the NDJSON is
scrape leftover from the restored line on the same log; buyer-visible
`cached_prompt_tokens=0` on all 30 miss samples.

Redacted cycle records:
[`data/kvs01a-2026-09-20/gate-samples.redacted.json`](data/kvs01a-2026-09-20/gate-samples.redacted.json).
Driver transcript (hashes only):
[`data/kvs01a-2026-09-20/gate.out`](data/kvs01a-2026-09-20/gate.out).

## Purge primitive (same lab namespace)

After releasing the namespace flock (stop the isolated serve, not 8080):

| Step | Result |
| --- | --- |
| persist | `disk_write_committed` `serialized_bytes=158869548` `write_ms=113` |
| status before | `entry_count=2` `tombstone_count=0` `keychain_item_count=3` `namespace_id=kvs01a-studio-lab` |
| `kv-cache purge --key-stdin` | `purge_ok` `entries_removed=1` `bytes_freed=158876097` |
| status after | `entry_count=1` `tombstone_count=1` `purge_high_watermark_entries=1` `keychain_item_count=2` |
| relaunch + restored-shaped request | `cached_prompt_tokens=0`, `ttft_ms=1158`, **no** `disk_hit`; `conv_cache` `cold_start`. Then a new `disk_write_committed` (re-cache after purge is allowed). |

Live 8080 PID 76887 stayed up for the whole purge (`compatibility_set_id`
`v1.8.172@c512d342…`, `coordinator_connected=true`, RSS ~49.8 GB).

Geometry-seed was not run on the purge relaunch, so the log does not carry
an explicit `disk_miss_tombstoned` code; the buyer-visible miss is
`cached_prompt_tokens=0` and the absence of `disk_hit`. DEK destruction is
the `keychain_item_count` 3 → 2 drop plus `tombstone_count=1`.

## Enable consequence

Operator **may** leave `kv_disk_cache.enabled=true` on **this Studio
isolated lab serve** for `conv:kvs-synth:` direct-HTTP traffic.

- Fleet default stays **off**.
- Live Pearl-connected Studio/32 GB providers are unchanged.
- `allow_buyer_keys` stays **false**.
- Do **not** mark `SPEC-037-R013` conformant. FR-KVP13 graduation past
  synthetic-key experiments still needs KVS-01b (8k / Q6-Q7) and KVS-02/03.

## Next

KVS-01b is the same scenario at an 8k prefix.

**Q6 (this tuple, measured):** live production KV is unquantized
`KVCacheSimple` (`kv_bits=null`). The 30-cycle persist payload was
~159 MiB for 1616 tokens (~98 KiB/token), matching the FP16 GQA estimate
in RESEARCH_233 §3.4, not the hypothetical q4 ~30 KiB/token class.

**Q7:** not applicable on this tuple. q4 KV is not the active
representation, so quality/restore gates for quantized KV are not the
01b path.

Therefore 01b needs a **spec-revision FR-KVP9 ceiling raise** (8k ×
~96 KiB/token ≈ 768 MiB, plus framing), not a `QuantizedKVCache` codec
v2 allowlist. Configuration cannot raise the 256 MiB hard ceiling.
Do not mark `SPEC-037-R013` conformant until that revision plus the 8k
gate land.
