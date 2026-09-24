# #1735 step 5: signed catalog row hash sweep

Date: 2026-09-24
Issue: [Augustas11/macprovider#1735](https://github.com/Augustas11/macprovider/issues/1735)
Tool: `scripts/catalog-hash-sweep.py` (tests: `scripts/tests/test_catalog_hash_sweep.py`)
Feed swept: `phase3-binary/dist/static/autotune-candidates.json`, release
`published-2026-09-23-tier2-buyer-closure-v1`, sha256
`5c24348a1d26a6308d1a3b1a24c848458ae43bcc4499d8de0a8bccb8ffe51729`, 17 rows.

## Summary

The live sweep ran on 2026-09-24 from an operator Mac with Hugging Face
egress. It exited `1`: every row was recomputed (no `ERROR`), and at least one
row mismatched.

- **8 of 17 signed rows MISMATCH.** For each of them, no correct download of
  the pinned revision can produce the signed `model_sha256`. The affected rows
  are `google-gemma-4-26b-a4b-it`, `openai/gpt-oss-120b`,
  `qwen/qwen3-30b-a3b-instruct-2507`, `qwen/qwen3.5-27b`,
  `qwen/qwen3.5-35b-a3b`, `qwen/qwen3.6-35b-a3b`, `qwen/qwen3.8-27b` and
  `z-ai/glm-4.5-air`. All 8 are `recommendable`.
- **9 rows MATCH.**
- **Cross-checks on the tool:**
  - GLM-4.5-Air recomputes to `7fbf8e50…11ed`. This equals the independent
    HF-only recompute in #1735 and the Studio E2E materialized-copy
    measurement (`audits/2026-09-24-1689-studio-e2e/EVIDENCE.md`, F8).
  - `qwen/qwen3.6-27b` MATCHes. That row was already corrected by #1686 from a
    measured snapshot.
- For every row, the unsigned artifact source (`autotune-artifacts-source.json`)
  equals the signed `model_sha256`. The 8 bad values are therefore in the
  source as well as in the signed feed.
- A corrected unsigned source value for GLM-4.5-Air is ready in
  `glm-4.5-air-artifact-source.patch` (not applied; see below). The other 7
  rows need the same correction in the #1735 catalog cut.

**Provenance:** every value comes from `sweep.json`, the machine output of
the run below, committed beside this report. The earlier revision of this
report copied the values from the operator's terminal. All 8 copied values
equal `sweep.json`.

**Where the bad values came from:** none of the 8 signed values equals the
hash of the same revision without `.gitattributes`. So dropping
`.gitattributes` does not explain them, just as #1735 found for GLM. Every row
reports no error and no notes: sibling and tree sets agreed, git blob SHA-1s
matched, and LFS sizes matched.

## Method

The algorithm matches `ModelArtifactVerifier.inspectCanonicalArtifact`
(`phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`). It is
SHA-256 over the joined `"<path>\n<size>\n<sha256>\n"` lines of every regular
file, sorted by relative path. The same relative-path policy applies.

The file set matches `HuggingFaceSnapshotDownloader.downloadSnapshot`, which
downloads every `siblings[].rfilename` of
`/api/models/<repo>/revision/<rev>?blobs=true`, **including `.gitattributes`**.
This answers #1735 fix step 1: the durable store holds the full snapshot, so the
correct row value is the with-`.gitattributes` hash.

Per-file values come from `/api/models/<repo>/tree/<rev>?recursive=true`
(paginated through the `Link` header):

- LFS/Xet files use `lfs.oid` as the SHA-256. The LFS size must equal the entry
  size.
- Plain git files are downloaded from `/resolve/<rev>/`. The script checks the
  length, checks the git blob SHA-1 against the tree `oid`, and then takes the
  SHA-256.
- The sibling set and the tree file set must be identical. Otherwise the row
  is `ERROR`.

The script also reports the hash without `.gitattributes`, to help classify
where a bad row value came from.

Exit codes: 0 means all rows match, 1 means at least one mismatch, 3 means at
least one row could not be recomputed (2 is argparse's usage error). 3 takes
precedence over 1, so read the per-row status for mismatches in a partial run. An error in
one row is recorded and the sweep continues. The optional `HF_TOKEN` is sent as
an unredirected header, so it never follows a redirect to the CDN, and tree
pagination may not leave `huggingface.co`.

## Per-row results

All values in this table come from `sweep.json`. The full hashes without
`.gitattributes` are in that file.

| Row | HF repo | Pinned revision | Files | Signed `model_sha256` | Recomputed (downloader file set) | Without `.gitattributes` | Status |
|---|---|---|---|---|---|---|---|
| `google-gemma-4-26b-a4b-it` | `mlx-community/gemma-4-26b-a4b-it-4bit` | `0d77464eeb233a2da68ebf9d7dc4edaac7db956d` | 12 | `436ce68d2ac5a27dde3b54569736fb7a69dc3b7a175d2f633147c7802b3bc88a` | `b245e39f1476907653e3fe1897bba36b0e2a90c471828a9e13b5fdf3e1b6db01` | `b971d6114ce1…` | **MISMATCH** |
| `meta-llama/llama-3.1-8b-instruct` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `241a666dad6cb93c8ff213d39a7f34a36bf26db4` | 8 | `67b26d6b1c50dc8836ab3705b06276a43c74c8f66247f9b112e232b58abbd99f` | same as signed | `d781bd0ba0c0…` | MATCH |
| `meta-llama/llama-3.2-3b-instruct` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` | 8 | `e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90` | same as signed | `3975387f2499…` | MATCH |
| `nvidia/nemotron-3-nano-30b-a3b` | `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | `832f602eba5d22436c258c1462bdedc5afddb42b` | 15 | `1bc78f214f9a042eaeb290b1fa4cb29915df1028f79d8479266349166c40a71f` | same as signed | `08ddc335fc10…` | MATCH |
| `openai/gpt-oss-120b` | `mlx-community/gpt-oss-120b-4bit` | `08e7899579b5dd5e0364e4bcd32578134072e22d` | 22 | `5003c9196bd6664b22227d687472ba2eb50c2c4daa224b36c230edbbe36b18fb` | `c8b99b694c6730ebcb86a8b2277f8c441c99c6275d4bedf9d3913b7e9d2b6156` | `00cdebaa98d3…` | **MISMATCH** |
| `openai/gpt-oss-20b` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | `773a7da77e569019bb0fd17a554b263738d669a3` | 12 | `f25592861e0b7f4eb8489d9103214f3f0dc4f798bb0e4e0cd817ff2f4191f1b1` | same as signed | `db95a7b40901…` | MATCH |
| `qwen/qwen3-30b-a3b-instruct-2507` | `mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit` | `e9675aa3ca5f900ccef55267914466d55ab325fa` | 16 | `6ed599e763ccfcf2731b2c383e81e6638375f62359ccb8bf730e1f17f583e3e7` | `a0ca3d59f301f08ae4c4c2010b07f80b890d35f4e8562c213b1d01aed8328e42` | `32e0f50c87b9…` | **MISMATCH** |
| `qwen/qwen3.5-27b` | `mlx-community/Qwen3.5-27B-4bit` | `45797d2985a12c55e6473686e9ea91b95e959553` | 15 | `01b20ff61b8f635d25515287bd6d2ac26877eab0de2fb2056b3d8b314ab4e2a3` | `7777cf15fbd096d66ccec5f0f76ec915eb4800f4f3e8dd899d1b4ae3041387ae` | `fa103ed93197…` | **MISMATCH** |
| `qwen/qwen3.5-35b-a3b` | `mlx-community/Qwen3.5-35B-A3B-4bit` | `1e20fd8d42056f870933bf98ca6211024744f7ec` | 16 | `58f00ca2bc7bb007b69145143d8a3fee90a3e5839a5a06e6443e8a7ef3906ad2` | `893c5fd5a4f6adf19a97faeff19d67f2b7a5d8c29e81cd857bd5949ce0b31e43` | `69fd11386cf1…` | **MISMATCH** |
| `qwen/qwen3.6-27b` | `mlx-community/Qwen3.6-27B-4bit` | `c000ac2c2057d94be3fa931000c31723aac53282` | 16 | `518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931` | same as signed | `ca6c5221f7c8…` | MATCH |
| `qwen/qwen3.6-35b-a3b` | `mlx-community/Qwen3.6-35B-A3B-4bit` | `38740b847e4cb78f352aba30aa41c76e08e6eb46` | 17 | `c4d82befa782da05bea1bdc4000ab9422a7173d9cd96bab739374d28d9ad4827` | `3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1` | `13f4421825f8…` | **MISMATCH** |
| `qwen/qwen3.8-27b` | `mlx-community/Qwen3.8-27B-4bit` | `10c35caafbb80f7dc6a7a432cdd11af10a6d4818` | 15 | `1a955b957b75d2e3264bd914600048cc8047b7cfc08117e82fa4c8272e7e8086` | `8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05` | `81305de7cd31…` | **MISMATCH** |
| `qwen2.5-coder-32b-instruct` | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `d1e3b690c8e225d7795bccddf971ca6be68b2012` | 14 | `b7749cc57f37f7e9239d0f9b091bcffe6d7629e48af75e8cb84c1cdca1780973` | same as signed | `849b61d5c4d2…` | MATCH |
| `qwen3-32b` | `mlx-community/Qwen3-32B-4bit` | `bcaaf7f538adf166c1080a2befdb4f6019f66639` | 14 | `69169cceb643f108755f96dba26d8647862e38a7f82cb1b5b25aff8f204967aa` | same as signed | `90ef8ac89658…` | MATCH |
| `qwen3-8b` | `mlx-community/Qwen3-8B-4bit` | `545dc4251c05440727734bcd94334791f6ab0192` | 11 | `1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877` | same as signed | `f6078249f1a0…` | MATCH |
| `qwen3-coder-30b-a3b-instruct` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `6e302ea604ad9ab206367e2c501d1571023e7b6d` | 17 | `10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0` | same as signed | `00694655b5ad…` | MATCH |
| `z-ai/glm-4.5-air` | `mlx-community/GLM-4.5-Air-4bit` | `60837794f3caafc4682dd1a9188a82c55a9100ef` | 21 | `350c018e8a3397a753bcb7c22c839a5c5a24041e6dee014bb42c2d766d6db57d` | `7fbf8e5005fbdadbf1d345a04b7d283ad20aec959ee001bc4b0dc902ea7f11ed` | `3a4230720c30…` | **MISMATCH** |

GLM-4.5-Air detail, from #1735: 21 files. With `.gitattributes` the hash is
`7fbf8e50…11ed`, which the downloader file set produces. Without
`.gitattributes` it is `3a4230720c30ba28c59339348fe333bd676c5af9d67de3109d0cf18039b3e58c`.
The signed `350c018e…` matches neither.

## Runs

1. **Build session (egress denied):** `python3 scripts/catalog-hash-sweep.py`
   exited `3`. All 17 rows were `ERROR` with `URLError: Tunnel connection
   failed: 403 Forbidden`.
2. **Operator Mac, 2026-09-24:** the command was run from a worktree of this
   branch at `0a27686`:

   ```bash
   python3 scripts/catalog-hash-sweep.py --markdown \
     --json-out audits/2026-09-24-1735-catalog-hash-sweep/sweep.json
   ```

   It exited `1`, with 8 `MISMATCH` rows, 9 `MATCH` rows and 0 `ERROR` rows.
   The operator committed its `--json-out` as `sweep.json` (commit `565917e`).

## Prepared GLM-4.5-Air source correction (unsigned, not applied)

`glm-4.5-air-artifact-source.patch` changes the `z-ai/glm-4.5-air` primary
artifact `hash` in `phase3-binary/catalog/autotune/autotune-artifacts-source.json`
from `350c018e…d57d` to `7fbf8e5005fbdadbf1d345a04b7d283ad20aec959ee001bc4b0dc902ea7f11ed`.

It is committed as a patch and not applied to the tree, for this reason:
`catalog-release.py` requires every source primary-artifact hash to equal the
signed candidate row's `model_sha256` ("primary artifact hash does not equal the
candidate model_sha256"). Applied alone, it fails 53 tests in
`scripts.tests.test_catalog_artifact_feed`. It has to land in the same catalog
cut that changes `model_sha256` in `catalog/autotune/autotune-candidates.json`.
That cut also regenerates the generated/static outputs, re-signs the static
feeds, appends the ledger row, and updates the Tier-2 binding. All of those are
signing-lane work (#1735 fix step 2) and are out of scope here. The same cut
should also refresh the row's provenance note, which still cites
`snapshot-manifest 350c018e8a33`.

`git apply --check` passes against this branch's base.

## Scope guard

This work does not sign anything, generate or modify signed feeds, or read or
write key material. `dist/static/*` and `catalog/autotune/autotune-candidates.json`
are unchanged.
