# Uncensored GLM-5.3-Flash native-MTP variant inputs (#2382)

Lab record, 2026-11-16, Apple M3 Ultra 256 GB, isolated (no coordinator join).
It supplies the variant declaration that catalog release
`published-2026-11-16-glm53-flash-uncensored-native-mtp-v289` signs: the
uncensored build as a SPEC-048 MTP-13 variant of `zai-org/glm-5.3-flash`.

- Variant: `zai-org/glm-5.3-flash-uncensored`, artifact
  `mlx-oq4e-uncensored-dflash2`, `Solstice-AI/GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2`
  @ `bff40d24efb689d33e094083ce4a5d6835601730`, snapshot-manifest
  `242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919` (52 files).
- Donor: `zai-org/glm-5.3-flash`, `Jundot/GLM-5.3-Flash-oQ4e-mtp` @
  `36defc5042d92a992a7948e83d6f110b8df69329`, snapshot-manifest
  `7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9` (46 files).
- Lab binary: `release` build of source `4307559f7` (CLI 1.8.289), binary sha256
  `58deaf5c…`, metallib `41863424…`, decode-path digest `0164af50…`. Not a
  release candidate.

## Results

| Check | Result |
| --- | --- |
| Identity | PASS: `tokenizer_sha256` `19e77364…`, `mtp_manifest_sha256` `c0222a09…` |
| R012 served weights | PASS: variant `.safetensors` 185,700,864,629 bytes <= donor 185,926,672,287 (`size.txt`) |
| Quantization observer | PASS: `mlx_affine`, group 64, 543 per-layer exceptions, 0 unquantized, representation manifest `8e4a4d80…` |
| MTP-16 self-check | PASS: prompt equals the donor's; counters accepted 31, bonus 31, committed 63, rejected 0; terminal `length` (`self-check-record.json`) |

The catalog's `size_bytes` (189,249,390,230 for the variant, 185,947,410,196 for
the donor) counts snapshot files that are not loaded (the mmproj and DFlash2
GGUF files). R012 now compares served weight bytes, read from the committed
manifests in `phase3-binary/catalog/autotune/snapshot-manifests/`.

## Files

- `variant-entry.json`: the entry committed verbatim in
  `phase3-binary/catalog/autotune/native-mtp-variants.json`, together with
  `self_check_record` from `self-check-record.json`.
- `self-check-record.json`: the variant's MTP-16 output. The signed self-test
  bank carries it (`expected_token_id_sha256` `aee8ff5a…`).
- `size.txt`: served-weight and snapshot byte counts.
- `native-mtp-artifact-manifest.json`: the lab projection over the loaded
  snapshot (relative paths).
- `bank-journey.json`: the provider-local self-test half of journey step 12.
  The coordinator-issued SPEC-031-R033 canary is not covered here. The
  post-activation live probe covers it.

Not tested here: R015 cells. Under MTP-13 the variant needs none; it inherits
the donor's bounds, thresholds and evidence digests.
