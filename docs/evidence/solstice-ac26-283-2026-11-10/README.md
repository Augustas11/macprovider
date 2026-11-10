# Uncensored GLM-5.3-Flash AC-26 cached-turns proof on signed CLI 1.8.283 (#2189)

Result: **AC-26 pass** for the `zai-org/glm-5.3-flash-uncensored` CB policy entry. It grants
`cached_turns_accepted: true` on that entry. The entry's attach proof, scheduler leftovers and
msb-throughput are in [`../solstice-cb-283-2026-11-10/`](../solstice-cb-283-2026-11-10/).

`ac26-proof.json` holds the public-safe identity, status and routing fields and the SHA-256 of
each leg file. Its own SHA-256 is the entry's `provenance.studio_campaign_sha256`.

## Identity

| Item | Value |
| --- | --- |
| Binary | signed provider CLI 1.8.283, sha256 `bebe9834…`, CDHash `06e8b09c…`, checked before the run |
| Decode-path digest | `940e2541…` (embedded marker, `/v1/status` build identity) |
| Metallib | `3d9b4a74…` (the release `mlx.metallib`) |
| Measured runtime identity | `zai-org/glm-5.3-flash-uncensored`, model `242f8fcf…`, `apple-silicon:Apple M3 Ultra:ram-256gb`, kernel `macprovider_paged_kv_gather_v1` |
| Signed CB policy at load | `live_verified`, release `published-2026-11-10-glm53-flash-uncensored-cb-v283`, `authorized=true`, `decision_reason=authorized`, tuple `b74a344f…`, `local_proof_result=passed`, `paged_kv_decision=attached`, `cached_turns_authorized=false` (expected before the grant) |
| Tokenizer / chat template | `4baf3a70…` / `4fcb509e…`. The serve authorized against the signed entry that carries them; a mismatch reads `tuple_identity_mismatch`. |

## Procedure

The tool and procedure are the ones used for the base GLM-5.3-Flash (#2143, CLI 1.8.274) and
abliterated (#2191, CLI 1.8.280) grants. Only identity, tuple and catalog fields changed.

- Isolated `--no-join` serve on loopback with the live catalog fields, so the signed CB policy
  loads. Settings: `continuous_batching: canary`, `continuous_batching_cached_turns: true`,
  `native_mtp_mode: off`, and a manual accepted tuple equal to the signed entry plus
  `cached_turns_accepted: true`. Serve start printed
  `event=batching_cached_turns action=enabled mode=canary`.
- A `--no-join` serve runs no FR-CB10 self-check, so the window's wait for
  `event=served_slots action=applied` never ends. After `/v1/status` showed CB active with
  `scheduler.slots_total=4`, a labelled `[lab-marker …]` line released the wait. It precedes the
  routing baseline and is not counted.

## AC-26 checks (SPEC-038 v0.3.31)

| Check | Result |
| --- | --- |
| (a) Later turns report `cached_prompt_tokens` equal to the previous snapshot length | **Pass.** Every warm turn t≥1 at rows 1 and 4 reports the previous warm turn's `prompt_tokens` − 2 (the generation prompt). Rows 1: 1169, 1194, 1219. Same boundary as base GLM and abliterated. |
| (a) Later turns enter a CB row, no `serial_routed` | **Pass.** After readiness: `snapshot_hits=18 batching_admitted=48 serial_routed=0 forward_failures=0 off_boundary=0 drafter_miss=0`. |
| (a) Tokens equal the same turns sent cold under a new key | **Pass.** `warm_equals_cold` on every row and turn (rows 1: 4/4, rows 4: 16/16, ordinary leg 4/4); `cold_reused_nothing` everywhere. `parity-rows1.json` 11/11 checks, `parity-rows4.json` 44/44. |
| (c) Usage fields | **Pass.** Every response carries `prompt_tokens`, `cached_prompt_tokens`, `completion_tokens` (with details), `total_tokens`, `macprovider_generated_completion_tokens`, `macprovider_generation_ms` and `macprovider_model_hash_observed`. Cold turns report cached 0. |
| (b) Native-MTP rows resumed from a snapshot | **Not run on this tuple.** No native-MTP admission exists for it, so the signed serve cannot run native. Covered by the base GLM-5.3-Flash proof under the SPEC-038 v0.3.40 same-architecture variant clause: same `glm5_next` family, every CB tuple field equal except model, tokenizer and template, and this entry's own attach proof and leftovers passed on the binary it binds. |

Ordinary cached-turn leg (`mtp-ordinary.json`, 1 row, 256 max tokens):

| Turn | Warm TTFT | Decode tok/s | Cached |
| --- | --- | --- | --- |
| 0 | 3.089 s | 26.73 | 0 |
| 1 | 0.298 s | 37.84 | 1169 |
| 2 | 0.295 s | 37.85 | 1194 |
| 3 | 0.942 s | 34.63 | 1219 |

## Files

- `ac26-proof.json`: the bound record.
- `parity-rows1.json`, `parity-rows4.json`: the keyed multi-turn legs (`glm53_cb_prefix_cache.py`).
- `mtp-ordinary.json`: the ordinary cached-turn leg (`mtp_leg.py`).
- `window-summary.txt`: the window's own log. `identity.txt`: binary and model identity.

Local paths are written as `<models>` and `<bin>`.
