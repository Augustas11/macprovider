# Gemma 4 12B native-MTP qualification records (#2328)

These are the R005 and R015 records of the `gemma4_mtp_v1` adapter (PR 2348).
The lab run was on 2026-11-16, on an M3 Ultra with 256 GB, isolated from live
serving (`evidence_class` `lab_isolated_no_join`). It used a release build of
campaign commit `1d0340145` with the lab harness flag. No admission tuple binds
these records yet; see "Not in these records".

## Setup

| Field | Value |
| --- | --- |
| Model | `google/gemma-4-12b-it`, 8-bit MLX affine target with the bf16 assistant embedded as `model-mtp.safetensors` |
| Hardware class | `apple-m3-ultra` (`Mac15,14`), 256 GB, macOS build `26A434`, Xcode `17F113` |
| Native MTP | proposal depth 1, one native row (`max_native_active_rows` 1), four qualified slots, 4096-token prompt cap |
| `target_sha256` | `8ce4036fbec241711a62cb44e305b629663e7eea73ff9a8693a5c16555623860` (snapshot manifest of the target directory) |
| `mtp_sha256` | the same digest: the assistant ships inside the target directory |
| `tokenizer_sha256` | `cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f` |
| Provider commit | `1d0340145f260c720d63b2d6fa6e7ee00c78879a` |
| Engine | mlx-swift-lm `3.32.3-macprovider.81` (`2639874f835134c94c069d1825afe44604110a58`) |
| Release `mlx.metallib` | `9ba197c57f042131f40f4e730a33169dbfb6fc3afcb961d1f44a1e197ea851d6` |
| Binary (lab harness build) | `cf51c8c4f89dec9e60f98f7c18e9b2c8984497435caadbc84bf816d7a8d1cd06` |
| Decode-path digest at `1d0340145` | `fbf61cc416a813bfae925e39eb5f4a054864b6e4afa42f6ace143ccd477995aa` |

## Files

| File | SHA-256 | What it is |
| --- | --- | --- |
| `gemma4/acceptance.json.gz` | `94371e263a600512c480f71b5992f31bc7cf9fe5330997afddde4b2fa961291e` | R005 result, gzip of the lab `acceptance.json` (uncompressed SHA-256 `63835c7c1bab1c404922a7f8deba0589a19319141db74bf939ec2ff322d2bf13`) |
| `gemma4/r015-analysis.json` | `f886818e0223203c767efb17b7d38203133c9f0dff49f0ac186b9339377c8c18` | R015 analyzer output, `overall_status` PASS |
| `gemma4/r015-analysis.md` | `bda2233442b57e6d6391f1b10eb97ab5f7255d4b7c9d038adf0037844240302c` | the analyzer's table |
| `gemma4/step1-analysis.json` | `90eaf27196c592ff149c687549d1b74feff8de7d71e2e61110e4aa20c52917c1` | exploratory step 1 (four one-row cells, no verdict by design) |
| `gemma4/identity.sha256` | | build and policy digests, redacted (see below) |
| `failed-runs/3309503a6-acceptance.json.gz` | `252bca82182da519ff516b0decea9553ae671794d4d79993dd08ad13802f4a33` | failed R005 on `3309503a6` (uncompressed `ff2b2852357aa8223a79bf5523714c7783db47eef358b5bfd97777bc6064bdf7`) |
| `failed-runs/f6d62fe7e-r015-analysis.json` | `71b5c1522df436fd14a3811363db539ded4e0318da1fbd4f9e2db82fb218c798` | failed R015 on `f6d62fe7e`, `overall_status` FAIL |
| `failed-runs/f6d62fe7e-r015-analysis.md` | `c50e28f6d195518f4b394e07a7f7ab2c0f01ee2a8552c33a83a7f30da3292fc8` | its table |

The JSON and Markdown files are byte-identical to the lab outputs; the two
`.gz` files decompress to the lab bytes. `identity.sha256` is the lab file with
the absolute lab directory replaced by `<lab>/` and its duplicate lines
dropped; the digests are unchanged. The raw R015 JSONL stays off-repo (10.7 MB),
as for earlier tuples. Its digest is the commitment:

| Record | SHA-256 |
| --- | --- |
| R015 JSONL, `1d0340145` (197 lines: header, 12 warmup runs, 120 cell runs, 64 sustained runs) | `58e23b970cc3445bdbb6f23a30af87faab43d356ebacb8453c70874955dcd868` |
| R015 policy | `572bb187b0c89582c1ceb11798a4c12bb89e1417f526a81ce31544c30a354219` |
| R005 acceptance policy | `15031b7eb64a346ad2b41c7a16a74c5f9fc6df04e7d090f4544410a15b20f730` |
| R005 acceptance corpus | `fb2480dc6d321ba82a7ba017a5de87dba5eee6e2a2005a79877c03aa6f697dc4` |
| R015 JSONL, failed run `f6d62fe7e` | `0c2ef7a2f5f48b9052ee551d8090f66ddac0c88c7f852b987d88c963cea53951` |

## R005

Status `pass`, 200 of 200 cases passed (short 120, 1.5k 20, 4k 20, 8k 20,
near-boundary 20), no failed checks. Accepted 6600, rejected 7024, 20489
compared native positions, 481 near-tied positions.

## R015

Gate set `tpot_chunk_gap_positive_lb_v3`, `overall_status` PASS, every cell 10
of 10 paired blocks. Tok/s is the median per-run `aggregate_decode_tps` of the
JSONL; acceptance is accepted over proposed drafts summed over the native runs;
parity counts runs whose tokens differ from the paired ordinary run.

| Cell | Class | Ordinary tok/s | Native tok/s | Ratio | Acceptance | Parity mismatch | Analyzer |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| s1-p1536-o128 | native_eligible | 38.21 | 45.73 | 1.197 | 543/723 (75.1%) | 0/20 | PASS |
| s1-p1536-o512 | native_eligible | 37.95 | 45.16 | 1.190 | 2121/2712 (78.2%) | 0/20 | PASS |
| s1-p4096-o128 | native_eligible | 36.96 | 40.14 | 1.086 | 537/727 (73.9%) | 0/20 | PASS |
| s1-p4096-o512 | native_eligible | 37.00 | 41.53 | 1.122 | 2204/2781 (79.3%) | 0/20 | PASS |
| s2-p1536-o512 | gated | 51.43 | 51.40 | 0.999 | 5/8 | 0/20 | PASS |
| s4-p1536-o512 | gated | 71.86 | 71.84 | 1.000 | none proposed | 0/20 | PASS |
| s4-p1536-o512, sustained 1857.7 s | gated | 76.63 | 76.62 | 1.000 | none proposed | 0/64 | PASS |

With more than one active row the load gate holds the native row at depth 0,
so the gated cells measure that native MTP costs nothing there; the analyzer's
gated bounds are throughput lower bound at least -0.05 and TPOT p95 upper bound
at most 0.05 (s2: -0.0021 and 0.0021; s4: -0.0017 and 0.0078).

## Two earlier runs the same day

- **`3309503a6`, R005 failed** (accepted 702, rejected 727, 2176 positions,
  failed checks `all_cases_passed`, `eos_terminal`, `native_positions`).
  Case `acceptance-short-19` answered one token and then EOS with exact
  parity, but its only native round proposed nothing because the drafter was
  never seeded from the prefill, so admission failed and the fail-fast runner
  stopped after 20 of 200 cases. Commit `9f11268ae` seeds the first proposal
  from the prefill, as the reference iterator does.
- **`f6d62fe7e`, R015 failed on the gated cells** (s2 0.949, s4 0.958,
  sustained 0.959; the four one-row cells passed). A native row held at
  depth 0 still buffered drafter columns, so the shared forward emitted
  drafter state and read it on the host every step, which removed the
  window's pipelining (about 2.3 ms more per decode step). Commit `1d0340145`
  makes a held Gemma 4 row buffer no columns, so it rides the ordinary
  forward unchanged.

## Not in these records

- **Admission tuple.** No signed native-MTP admission entry for Gemma 4 12B
  exists yet, and the catalog has no Gemma 4 12B row. The entry also needs
  the journey record (state rollback and batch evidence), the security
  negatives, the derived window bound and the observed quantization block, as
  `docs/evidence/qwen27b-native-mtp-2026-11-16/` recorded for the Qwen 27B
  entries.
- **Self-test bank entry** for the MTP-16 self-check and canary.

Related: #2328, #2154
