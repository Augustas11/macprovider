# SPEC-048 R015 formal evidence: first native-MTP tuple, 2026-10-02

This is the formal (non-exploratory) R015 run for the first native-MTP tuple
under SPEC-048 0.1.21. The policy uses the admission schema
`macprovider.native-mtp-r015-policy.v1`, was committed before any measurement,
and the analyzer returns `overall_status: PASS`. Native MTP stays default-off;
this evidence does not enable anything.

## Tuple

| Field | Value |
| --- | --- |
| Target | `qwen/qwen3.6-35b-a3b`, catalog artifact `mlx-4bit` (mlx-community/Qwen3.6-35B-A3B-4bit @ `38740b84`), snapshot hash `3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1` |
| Drafter | mlx-community/Qwen3.6-35B-A3B-MTP-4bit, snapshot hash `fa01beecb6c1e76845e9880623c3b5a009baa602c52e9e9b5d12edc489a23fd2`, manifest (`mtp/config.json`) `7b38a336fa246a285ee23cc990351989bf2ee6c040506a2b793ee24e463f35a7` |
| Tokenizer | `87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4` |
| Shape | qualified_slots 8, max_native_active_rows 1, max_prompt_tokens 4096, proposal depth 1, MLX affine 4-bit |
| Host | Mac15,14, Apple M3 Ultra, 256 GB, macOS build 25E253, Swift 6.3.3 (CommandLineTools; no Xcode) |
| Provider | `cb708b58c873beb2e728121b6a463697df1dbe47`, release build with `-DMACPROVIDER_LAB_HARNESS`, MLX fork `ef4ff8568c38c640bc90a8176dc3acfe943a288d` |
| Policy | `policy.json`, sha256 `30934c07e5b6ca6dfa569505bbfdb2fd118be719cba81ddf99193a4ebe72d581`, seed 20261012, 10 blocks, 1 warmup, greedy, staggered arrivals 250 ms |

The target snapshot hash is the catalog-verified artifact-feed member. The
earlier exploratory fixture omitted the repository `.gitattributes` and hashed
to `13f44218…`; the weights and tokenizer bytes are identical.

## Result

Decode ratio is native/ordinary median decode throughput. LB and UB are
Holm-corrected bounds (fractions). Gated cells use the -5% / +5% / +5%
non-inferiority margins; native-eligible cells need decode LB >= 0.15, TTFT
UB <= 0.10, ITL UB <= 0. Capacity-rejection UB is 0 in every cell, and parity,
fallback, and error counts are 0 everywhere.

| Cell | Class | Decode ratio | Decode LB | TTFT UB | ITL UB | Acceptance | Status |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| s1-p1536-o128 | native-eligible | 1.278 | 0.258 | 0.047 | -0.902 | 0.881 | PASS |
| s1-p1536-o512 | native-eligible | 1.264 | 0.241 | 0.048 | -0.902 | 0.865 | PASS |
| s1-p4096-o128 | native-eligible | 1.242 | 0.208 | 0.065 | -0.899 | 0.931 | PASS |
| s1-p4096-o512 | native-eligible | 1.216 | 0.204 | 0.065 | -0.900 | 0.856 | PASS |
| s2-p1536-o512 | gated | 0.997 | -0.005 | 0.030 | 0.003 | n/a | PASS |
| s8-p1536-o512 + 1800 s sustained | gated | 1.000 | -0.006 | 0.009 | 0.004 | n/a | PASS |

Gate evidence in the native runs:

| Cell | Native admissions | Load-gate downgrades | Depth-zero rounds | Hold episodes | Held to clean finish | Unresolved |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| s2-p1536-o512 | 10 | 10 | 340 | 10 | 10 | 0 |
| s8-p1536-o512 | 10 | 70 | 390 | 10 | 10 | 0 |
| s8 sustained (39 blocks) | 39 | 273 | 1587 | 39 | 39 | 0 |

Sustained window: 1839 s, thermal state nominal throughout, minimum available
memory fraction 0.621, peak physical footprint 43.3 GB (with the 8 GiB safety
margin, well inside 256 GB).

At full load the one admitted native row is held at depth zero for the whole
run and finishes held; the gated cells prove the gate costs nothing, not that
native MTP helps at eight slots. The tuple's measurable gain is at one active
row: decode +22% to +28%, corrected lower bound +20% to +26%.

## Bench time

| Phase | Wall time |
| --- | --- |
| Matrix, six cells (warmup + 10 blocks each) | 26 min (02:11–02:37Z) |
| Sustained window | 31.5 min (04:10–04:42Z) |
| Serve-path e2e | 1 min |

Total bench time is about 59 min. The old 48-cell mandatory matrix would have
taken about 2.5 days.

## Run history (all kept for review)

1. **Policy `525ac686…` (superseded, `superseded-policy-525ac686/`).** Its
   4096 prompt stratum was sized on raw text. The chat template pushed the
   served prompt past the signed 4096 cap, so every native row in the
   s1-p4096 cells was silently sent back to ordinary after admission had
   already been recorded as native. Those cells compared ordinary with
   ordinary and failed only on missing proposals. Fixed in `cb708b58c`:
   strata are now counted on the served prompt (corpus
   `deterministic_synthetic_unique_v2`), and the runtime records a
   token-bound reselection, which fails a native bench run closed. A new
   policy was frozen before any further measurement.
2. **Policy `30934c07…`, window G01 (02:10–02:38Z).** Serve-path e2e passed,
   and all six matrix cells completed.
3. **Window S01 (03:24–03:44Z) is VOID.** Another session ignored the lab
   lock and re-bootstrapped an unpaused live provider that loaded the model
   at 03:41Z during the sustained run, so the bench was killed. All 48
   sustained records were moved out of the run file. The G01 matrix records,
   all written before the intrusion, were kept: policy v2's sustained phase
   reuses them.
4. **Window S02 (04:10–04:42Z).** The sustained window was re-run under the
   lock, with the live provider paused and no foreign model process recorded
   by the contamination sampler.

## Not covered (R015 stays pending)

- The representative post-gateway eligibility replay (at least 10% eligible
  requests and completion tokens) is not implemented. Under the current
  gateway auto-prefix conversation keys, most paid traffic is ineligible
  (SPEC-048 MTP-4).
- No lower RAM tier is advertised or measured. This evidence covers only the
  256 GB Studio.
- The matrix ran greedy rows. Seeded sampled-row parity is covered by the
  journey hardware harness, not by an R015 throughput cell.

Files: `policy.json`, `analysis.json`, `analysis.md`,
`admission-tuple-input.json`, `admission-tuple-provenance.md`,
`superseded-policy-525ac686/`.

Raw JSONL and logs stay on the lab host by operator decision. Their digests
are bound here so the committed analysis can be checked against them:

| Lab-host file | Lines | SHA-256 |
| --- | ---: | --- |
| `mtp-r015-a3b-formal-v2/r015-a3b-formal.jsonl` (analyzer input for `analysis.json`) | 211 | `88c79a5757caf08d9efcee12756559d4f6dbd36341c6f43831301adb5b04e04d` |
| `mtp-r015-a3b-formal-v2/contaminated/S01-sustained-records.jsonl` (voided S01) | 48 | `62809643c1d78093bc6d7b4997833a522aab03a59c1a3c9550edc412dff6d184` |
| `mtp-r015-a3b-formal/r015-a3b-formal.jsonl` (superseded 525ac686 run) | 133 | `33a01f5a93a79401a267f31af28a3124ad1590bd8ab049859d00b2573e2db829` |
