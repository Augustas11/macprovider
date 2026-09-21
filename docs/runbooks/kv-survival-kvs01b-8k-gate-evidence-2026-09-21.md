# KVS-01b 8k enable-gate evidence — 2026-09-21

SPEC-037 restart-survival **performance** gate (persist → SIGKILL →
relaunch → `disk_hit`) at an 8k prefix on the Mac Studio isolated lab.
Sanitized: token counts, reason codes, TTFT, RSS, binary identity. No
prompts, no conversation keys, no bearer headers.

## Header

- **Date:** 2026-09-21
- **Operator:** augstar
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power
- **Topology:** isolated local HTTP `127.0.0.1:18080`, `--no-join`,
  `credential_store: protected_file`, `continuous_batching: off`,
  `kv_disk_cache.enabled: true`, `allow_buyer_keys: false`. Synthetic keys
  only (`conv:kvs-synth:`). Live Pearl-connected `127.0.0.1:8080` was not
  killed.
- **Operator knobs:** `staging_max_bytes=1073741824` and
  `write_staging_max_bytes=1073741824` (both at the v0.1.3 1 GiB hard cap;
  fleet default remains 256 MiB).
- **Model tuple:** `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`,
  snapshot `6e302ea604ad9ab206367e2c501d1571023e7b6d`,
  `model_sha256=10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0`,
  unquantized `KVCacheSimple` (`kv_bits=null`), codec `kvsurv-codec-v1`
- **Prompt class:** 8000 requested tokens (KVS-01b). Measured persist
  `cached_prompt_tokens=8016` on every restored sample (`prompt_tokens`
  typically 8032 + 8 completion). Persist payload
  `serialized_bytes=788041108` (~752 MiB, ~96 KiB/token).
- **Harness:** `test/e2e/coldwarm-ttft/kvs-01a.sh --cycles 30 --perf-gate`

## Binaries

| Role | Path | SHA-256 | Identity |
| --- | --- | --- | --- |
| 8k smoke + 30-cycle lab CLI | `/Users/a1/.local/state/kvs-01a/run-v013/macprovider-cli` | `9be5e2f18f0c7db0a11253480f511b5ab2641f0df3ef6d872c2175a47c74d5f0` | worktree build of `origin/main` `@711f46bf` (#1655 1 GiB ceiling); `--version` still `1.8.123` |
| Packaged Studio canary | `/Users/a1/macprovider/macprovider-cli` | `7bd43fe8582206043b70e95b8bc232eb0826511832fc43ff0ffe91555c92ac60` | `Augustas11/macprovider:v1.8.172@c512d342b1df6c495afeabbe49eaca74a98107c4` (256 MiB promotion hard cap; not used for 8k) |

`--version` prints `1.8.123` on the lab CLI: candidate tags do not bump
`binaryVersion`. Packaged 172 cannot hold an 8k FP16 snapshot under the
v0.1.2 256 MiB hard ceiling even after Keychain Allow.

A new unsigned CDHash required a GUI SecurityAgent **Allow** (SSH cannot
grant login-keychain ACL). After Allow, SIGKILL + harness relaunch did
not need another dialog. Live 8080 PID 36375 stayed on 172 for the whole
run (`coordinator_connected=true`).

## Smoke (correctness only)

- **Window:** 2026-09-20T23:30:56Z → 2026-09-20T23:35:33Z
- **Exit:** 0
- **Restored:** `disk_hit` `cached=8016` `ttft=1158ms`
  `restore_bytes=788041108` `restore_ms=666`
  `staging_peak_bytes=854265104` (~815 MiB) `commit_latency_ms=477`

Driver transcript: [`data/kvs01b-2026-09-21/smoke.out`](data/kvs01b-2026-09-21/smoke.out).

## 30-cycle gate (correctness + `--perf-gate`)

- **Window:** 2026-09-20T23:38:29Z → 2026-09-21T00:36:51Z
- **Exit:** 0
- **Cycles:** 30/30 restored `disk_hit`, `correctness=ok`,
  `cached_prompt_tokens == persist.prompt_tokens + persist.completion_tokens`
  (8016)

Nearest-rank TTFT (ms):

| Arm | n | p50 | p95 | min | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| restored | 30 | 1111 | 1127 | 988 | 1131 |
| warm | 30 | 482 | 501 | 440 | 501 |
| miss (buyer-visible) | 30 | 5557 | 5568 | 5535 | 5572 |
| disabled | 30 | 5232 | 5293 | 5223 | 5358 |

Restored restore_ms p50/p95 = 669 / 675. Staging peak 854,265,104 bytes
(~815 MiB) under the 1 GiB promotion ceiling. Persist
`serialized_bytes=788041108` on every cycle. Commit-latency p50/p95 =
495 / 531 ms.

**Harness `--perf-gate` (normative for KVS-01b):** PASS. Restored p95
1127 ≤ warm p95 501 × 3.0 (1503); restored p95 < miss p50 5557; restored
p95 < disabled p50 5232.

**SPEC-037 §6 warm-relative hypotheses:** PASS on this tuple.

- restored p50 1111 ≤ max(1.25 × warm p50, warm p50 + 1 s) = 1482
- restored p95 1127 ≤ max(1.5 × warm p95, warm p95 + 2 s) = 2501
- p95 TTFT reduction vs miss / disabled ≈ 80% / 79% (gate is ≥ 30%)

**SPEC-037 §6 write-path overhead p95 ≤ 250 ms:** NOT met at 8k
(commit-latency p95 = 531 ms). 01a at ~1.6k was 128 ms. This is encrypt
+ atomic write of a 752 MiB `KVCacheSimple` blob, not a restored-TTFT
regression. Approach A does **not** pause: the stop condition is failing
the warm-relative gate without replacing the per-conversation layout;
that gate held.

Miss-arm `disk_reason=disk_hit` in the NDJSON is scrape leftover from the
restored line on the same log; buyer-visible `cached_prompt_tokens=0` on
all 30 miss samples.

Redacted cycle records:
[`data/kvs01b-2026-09-21/gate-samples.redacted.json`](data/kvs01b-2026-09-21/gate-samples.redacted.json).
Driver transcript (hashes only):
[`data/kvs01b-2026-09-21/gate.out`](data/kvs01b-2026-09-21/gate.out).

## Enable consequence

Operator **may** leave `kv_disk_cache.enabled=true` with both staging
knobs at 1 GiB on **this Studio isolated lab serve** for `conv:kvs-synth:`
direct-HTTP traffic at the 8k class.

- Fleet default stays **off** (256 MiB promotion ceiling).
- Live Pearl-connected Studio/32 GB providers are unchanged.
- `allow_buyer_keys` stays **false**.
- Do **not** mark `SPEC-037-R013` conformant. FR-KVP13 graduation past
  synthetic-key experiments still needs KVS-02/03 (invalidation gates).

## Next

KVS-02 / KVS-03: warm-swap same family → deterministic miss; exact-hash
change → zero old-generation hits. No harness exists yet; do not invent
one inside this evidence PR.

32k–64k remains KVS-04-class: it exceeds the 1 GiB hard cap (~3–6 GiB
decoded at ~96 KiB/token) and needs a spec-revision ceiling or a new
codec, not a configuration change.
