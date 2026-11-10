# Uncensored GLM-5.3-Flash CB attach on signed CLI 1.8.283 (#2189)

The Studio canary served `zai-org/glm-5.3-flash-uncensored` on the signed, promoted CLI 1.8.283
on 2026-11-10. Continuous batching stayed off only because the signed CB policy has no entry for
this model: `/v1/status` reported `decision_reason=tuple_identity_mismatch`. This record binds the
CB policy entry to that serve. `attach-proof.json` holds the public-safe status fields.

- Artifact: `Solstice-AI/GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2` @
  `bff40d24efb689d33e094083ce4a5d6835601730`, snapshot-manifest `242f8fcf…`, catalog key
  `zai-org/glm-5.3-flash-uncensored`.
- Binary: the signed provider CLI 1.8.283 (source `ec252246fbf91fbef8d218213e7bb465c0100771`,
  binary sha256 `bebe9834…`, CDHash `06e8b09c…`, decode-path digest `940e2541…`). Read from the
  `macprovider-cli` inside the `v1.8.283` release tarball, whose sha256 matches the release's
  signed `checksums.txt`. The embedded decode-path marker equals the tree digest at `ec252246f`.
- Metallib: the release `mlx.metallib` is `3d9b4a74…`, unchanged since 1.8.281. The existing CB
  entries keep their metallib.

## Attach proof

| Check | Result |
| --- | --- |
| `paged_kv_decision` | `attached`, cache class `mixed` |
| `policy.local_proof_result` | `passed` |
| `policy.authorized` / `decision_reason` | `false` / `tuple_identity_mismatch` (no signed entry) |
| Measured tuple | `apple-silicon:Apple M3 Ultra:ram-256gb`, metallib `3d9b4a74…`, kernel `macprovider_paged_kv_gather_v1` |

On this binary, `attached` with `local_proof_result=passed` means the load-time paged parity
probe and the batched shared-forward isolation probe both passed and the SPEC-039 descriptor
admits the tuple. In `ModelRuntime`, attach measurement returns nil unless the gather parity
shape holds and the batched-isolation gate passes (shared-forward parity, two distinguishing rows,
no row failure, no cross-row divergence), and `localProofResult` is `passed` only for `.attached`
with the descriptor admitting the tuple. For a `glm5_next` model the isolation probe includes
cross-row MoE expert-dispatch isolation.

## Earlier lab evidence (#2244)

- Token parity against an mlx-vlm `glm5_next` reference: 256/256 at 1K and at 8K, 16/16 top-1.
- 1 row 41.9 tok/s (1K), 39.6 tok/s (8K); 4 rows at 1K 72.0 tok/s aggregate (base GLM-5.3-Flash
  72.2).
- On the lab build, the FR-CB10 self-check granted, 1.60x aggregate at 4 rows.

## Policy entry

The entry copies the `zai-org/glm-5.3-flash` entry's tuple shape (`mixed`, `fp16`, MoE, M3 Ultra
256 GB, kernel, metallib, `max_served_slots` 4, `canary`), with these differences:

- `model_sha256` is the snapshot-manifest `242f8fcf…` from the candidate row.
- `chat_template_sha256` is `4fcb509e…`: the runtime hashes `chat_template.jinja\0` followed by
  the file bytes (`ModelRuntime.tokenizerIdentityHashes`). The bytes are
  `scripts/tests/fixtures/glm53-uncensored-chat-template/chat_template.jinja`, whose git blob id
  equals the pinned snapshot's `chat_template.jinja` (`d6f626a3…`, 22,133 bytes). The same formula
  gives the committed `6138d780…` and `5448db3c…` from the other two GLM fixtures.
- `tokenizer_sha256` is the runtime's hash over `tokenizer_config.json\0` + bytes and
  `tokenizer.json\0` + bytes. `tokenizer.json` is byte-identical to the base GLM-5.3-Flash
  snapshot (git blob `aba40197…`, LFS sha256 `19e77364…`). `tokenizer_config.json` is not (23,357
  bytes, blob `a15283bf…`; base 761 bytes), so the value differs from the base entry's
  `1e9d4f69…`.
- `cached_turns_accepted` is `false`: no AC-26 proof exists for this model.
- `provenance`: `provider_cli_version` `1.8.283`, `live_executable_cdhash` the 1.8.283 CDHash,
  `package_manifest_sha256` the 1.8.283 binary, `studio_campaign_sha256` the SHA-256 of
  `attach-proof.json`.

The entry goes live only with a signed catalog release. On load the provider still runs the
FR-CB10 self-check, which grants slots only on a measured aggregate gain with exact parity.

## Not recorded

- The `leftovers` scheduler harness (isolation, replay, drain, 48-token parity) has not run on
  this model. SPEC-039 v0.1.31 names it for this identity.
- `msb-throughput` rows 2 and the serve-log probe lines (gather-call counts) are not recorded.
