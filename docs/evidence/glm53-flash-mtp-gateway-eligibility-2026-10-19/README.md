# GLM-5.3-Flash native MTP on gateway-shaped requests: release-build Studio e2e (2026-10-19)

## Defect

The coordinator gives a gateway chat request the gateway's auto-prefix key,
marks it cache-only, and adds a fleet-cache grant for that key. The provider
relay builds the request with `withConversationKey(key, cacheOnly: true)` and
then `withFleetCacheGrant(grant)`. `withFleetCacheGrant` rebuilt the request
with `conversationCacheOnly: false`. The runtime then saw a sticky key, and the
SPEC-048-R004 selector chose ordinary decode with reason `conversation_key`.
`/v1/status` reported this as `native_mtp.last_reason = request_ineligible`
with `mtp_forwards` 0. The R015 replay and the journey ran without fleet
grants, so neither of them covered this path.

The fix keeps the marker when the grant names the key already installed. With
the marker, R009 decides the row from its lease: a miss on GLM-5.3-Flash, a
hybrid model whose keyed rows commit in serial format, stays native, and a hit
stays ordinary.

## Setup

- Host: Mac Studio M3 Ultra 256 GB, model `zai-org/glm-5.3-flash`
  (artifact sha256 `7299b6a7...48f9`). The live provider was paused for the
  window.
- Binary: `swift build -c release` of source commit `f05882e38`
  (`macprovider-cli` sha256 `001ea5e0...af9a`), with the signed release
  `mlx.metallib` copied from the install (sha256 `3d9b4a74...261b`).
- The runtime files are byte-identical to `v1.8.257`: `NativeMTP.swift`,
  `ModelRuntime.swift`, `InferenceRelay.swift`, `HTTPServer.swift` and
  `ContinuousBatchScheduler.swift` show an empty diff. The fix touches only
  request construction and the admission-set projection reader.
- Lab serve: `serve --no-join --no-idle-prewarm` on loopback port 18098, using
  a copy of the live config. Coordinator, receipt and relay keys were removed.
  The config sets `donor_mode: true` so that a non-joining serve still runs
  the catalog preflight and resolves the signed native-MTP admission set from
  the static feed, and it uses the current catalog release
  `published-2026-10-19-glm53-flash-native-mtp-v257-v2`. `MACPROVIDER_CB_TRACE=1`.
- Native MTP admitted: the self-check passed at 1.26x, `native_mtp.mode`
  was `eligible`, the family was `glm5_next_mtp_v1`, and the signed bound was
  `max_native_active_rows = 1`.
- Probe: `mtp_probe.py` sends temperature 0 and top_p 1 non-streaming
  requests, each with a stable `X-Request-ID`, so that every request takes the
  continuous-batching path.
  It records content SHA-256 only, never content. A loopback request cannot
  carry the coordinator's cache-only marker. The probe sends the request
  state that the marker loss produced (a key with `cache_only=false`) through
  `X-MacProvider-Provider-Conversation`.

## Results

| Step | Shape | Path (trace) | mtp_forwards | Tokens | Output |
|---|---|---|---|---|---|
| native_p1 | plain text, no key | `native_mtp reason=eligible` | +140 (115/139 accepted) | 256 | sha `41141807...` |
| ordinary_p1 | same body plus an unadmitted top-level key | `ordinary reason=unknown_request_field` | +0 | 256 | sha `41141807...` (match) |
| native_p2 | plain text, no key | `native_mtp reason=eligible` | +133 (122/132 accepted) | 256 | sha `d765c945...` |
| ordinary_p2 | same body plus an unadmitted top-level key | `ordinary reason=unknown_request_field` | +0 | 256 | sha `d765c945...` (match) |
| tools | one function tool | `ordinary reason=tools` | +0 | 39 | `stop` |
| post_grant_key_plain | plain text, key with `cache_only=false` (pre-fix gateway state) | `ordinary reason=conversation_key` (lease `cached=0`) | +0 | 256 | sha `41141807...` |
| cb4_long | 4 concurrent rows, max_tokens 1400 | 1 `native_mtp`, 3 `capacity_above_native_bound` | +0 | 4 x 1400 `length` | all HTTP 200 |

- Native output is token-identical to ordinary output at temperature 0 for
  both prompts: same content SHA-256 and same token count.
- With 4 active rows, the native row degraded to depth 0 under the R007 load
  gate (`native_mtp_load_gate action=depth_zero active_rows=4 bound=1`) and was
  restored at 3 active rows. All four rows completed 1400 tokens in 82 s wall
  (68.3 tok/s aggregate) with 0 `continuous_batch_no_progress` lines and 0
  pre-output or post-output native failures.
- The serve resolved the live `v1` projection manifest through the new reader
  (`NativeMTPStoreProjection.members(manifest:modelKey:)`). A two-model `v2`
  manifest is covered by `NativeMTPAdmissionFeedTests`.

## Files

- `timeline.txt`: both windows (pause, lab legs, restore). Window 1 found
  that a plain `--no-join` serve skips the catalog preflight and so has no
  admission set (`sidecar_missing`). Window 2 used `donor_mode`. In window 2
  the leg on the installed 1.8.257 binary sent no `X-Request-ID`, so it ran
  on the serial path and is not used.
- `probe-fixed.jsonl`: per-request results and native counter deltas.
- `serve-native-trace.log`: `rt_cb_lease`, `rt_native`, self-check and
  load-gate lines.
- `identity.sha256`: hashes of the binary and metallib as run.
- `mtp_probe.py`: the probe.
