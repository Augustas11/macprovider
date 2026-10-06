# Column-cap fix (`7b5fbd675`): lab control, outside the R015-measured regime

**Exploratory, not a gate.** The policies use the exploratory schema, so the
R015 analyzer gives them no verdict. This change was made after the formal
R015 in `../README.md`, which ran on `e1103712d`. That R015 does not measure it.

## What changed

Since `e1103712d`, a load-held native row buffers its committed
(token, hidden) columns until its next native proposal, with no cap. Each
hidden state was a slice of the shared `[B, 1, 2048]` bf16 batch output. A
slice shares its parent's buffer, so each column kept `B x 4 KiB` alive
outside the paged-KV accounting. At the 1,048,576-token completion budget that
is up to 4 GiB per held row at `B = 1` and 32 GiB at `B = 8`. `7b5fbd675`
gathers each column into its own `[1, 1, 2048]` buffer. It also caps a held
row's buffer at 1024 columns: a row whose next ordinary window would pass the
cap catches its drafter up first (SPEC-048 0.1.25 MTP-6).

**Outside the R015-measured regime.** Every R015 cell generates at most 512
tokens, so the cap never fires in a measured cell. The only change on the
measured path is one small gather per held-row decode step in place of a
slice. The timing control below shows no measurable difference.

## Lab window

Mac Studio `Mac15,14`, 26A434. Lab lock windows were 11:40:26–12:16:35Z and
12:16:42–12:29:48Z. An earlier lock window (11:34–11:39Z) built without
`-DMACPROVIDER_LAB_HARNESS`, ran nothing, and was discarded. All runs were
in-process (`native-mtp-hardware-e2e`, `native-mtp-bench`), with no listening
port and no coordinator join. The live provider was not paused (rule for
diagnostics), so every run shares its load.

- New: `7b5fbd675`, release build with `-DMACPROVIDER_LAB_HARNESS`, binary
  `fb26642b…`.
- Old: `e1103712d`, the formal R015's lab binary `ca12a90c…`.
- `mlx.metallib`: `84e48718…` for both. The fork is `ca8c384c` for both.

Status logs: `status-window1.txt`, `status-window2.txt`. Scripts:
`run-lab.sh`, `run-lab2.sh`. Raw JSONL, the e2e log, and `gpu.log` stay on the
lab host under `~/mtp-colcap-7b5fbd675/` (hashes in `raw-sha256.txt`).

## Hardware e2e (new binary)

`native-mtp-hardware-e2e` with the serve path, `--max-batch 2`: exit 0,
`status: pass`, `serve_path_verified: true`, 3 admissions, max batch depth 2.
The runner `require`s every native response to match its ordinary response
exactly, so a pass means 0 ordinary/native mismatches.

## Timing control: old/new/new/old, 5 blocks each, s1-p1536-o512 and s2-p1536-o512

Generate the table with
`python3 summarize.py old1.jsonl new1.jsonl new2.jsonl old2.jsonl`.

| 10 paired blocks per binary | `e1103712d` | `7b5fbd675` |
| --- | ---: | ---: |
| s1 native/ordinary decode, paired median | 1.2895 | 1.2885 |
| s1 TPOT p95 ratio, median | 0.7755 | 0.7761 |
| s2 native decode tok/s (median) | 111.9 | 112.1 |
| s2 ordinary decode tok/s (median) | 112.0 | 112.4 |
| s2 native/ordinary decode, paired median | 1.0007 | 0.9593 |
| s2 native/ordinary median inter-chunk gap, per-block range | 0.997–1.008 | 0.995–1.243 |

The s2 aggregate ratio is lower on the new binary because of foreign load, not
code:

- The isolated native-arm gaps above 30 ms (single slow chunks) follow the
  prompt, not the binary. Across all 10 block/request pairs, no index has such
  a gap in both new runs and in neither old run, and no index has the
  reverse.
- The only differences are runs of 15–65 consecutive slow chunks. They hit the
  native arm in new1 block 0, new2 blocks 0, 3, and 4, and old2 block 3. They
  hit the ordinary arm in new1 block 2, old1 blocks 1 and 3, and old2 blocks 1
  and 2.
- A code cost would show in every block. Nine of ten new blocks have a
  native/ordinary median-gap ratio within 0.995–1.004. The tenth, new1 block 3
  at 1.243, is a whole-run slowdown with no burst.
- The s1 cells, where the change does not run, match to 0.1%.

## Long generation: s1 and gated s2 at o2048 and o4096

Generate the tables with `python3 longgen.py new.jsonl old.jsonl` (prints
per-request inter-chunk gaps above 30 ms).

The synthetic corpus stops on EOS before the budget. No request reached 2048
tokens: individual requests ran 768 to 1608 tokens, and per-run committed
tokens in the s2 cells reached 2079 to 2699. The bench has no ignore-EOS
switch, so this check could not show two cap triggers in one request.

- **Parity.** Across 24 + 32 records, 0 parity mismatches, 0 errors, and
  0 fallbacks on both binaries.
- **The cap fires.** In the gated s2 cell the native row is held from its
  first decode round. On the new binary, held requests that pass about 1000
  chunks show one isolated native-only gap of 39–41 ms near chunk 1000. That
  is the catch-up at 1024 buffered columns. It appears in o2048 blocks -1, 0,
  and 1 (989–1001; held requests of 1004–1249 chunks) and o4096 blocks -1 and
  1 (991 and 998; 1254 and 1608 chunks). In the same requests the old binary
  has no gap within about 150 chunks of that point. Its one isolated
  native-only gap (1146 or 1159, block 1 of each budget) is in the prompt
  that also gives the new binary a late gap at 1099/1106. Held requests of
  768 and 937 chunks never reach the cap, and neither binary shows a gap
  there. No request shows a second catch-up, because none reached 2048
  columns.
- **Memory.** The per-run `peak_phys_footprint_bytes` matches between
  binaries within 0.3 GB: s2-o4096 new 33.58/33.58/34.20/34.20 GB against old
  33.30/33.30/34.20/34.20 GB. This window cannot show the leak's growth. At
  `B = 2` and about 1600 held tokens, the old views pin about 13 MiB, below
  footprint resolution when the MLX buffer cache is several GB. The memory
  property is shown by the Metal unit test
  `testDetachedHiddenColumnDoesNotPinTheBatchOutput`: 16 slice columns retain
  all 16 batch outputs, while 16 gathered columns retain less than one. The
  cap is shown by `testHeldNativeRowCatchesUpItsDrafterAtTheColumnCap`:
  at cap 8, a held row never buffers more than 8 columns, and its tokens match
  both the uncapped run and the ordinary path. Every proposal after restore is
  the drafter's definitional seed.
