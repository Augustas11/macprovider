# s2 attribution control: 10-06 binary vs step-overhead binary (exploratory)

**Exploratory, not a gate.** Exploratory policy schema; the R015 analyzer
gives it no verdict. It answers one question: is the gated s2 decode
regression in the 2026-10-06 R015 (`s2-p1536-o512` decode LB -8.6%) load or
code?

Design: one lab lock (07:43:19-08:15:48Z), four back-to-back runs in the order
old, new, new, old. "Old" is the 10-06 binary (`b96c5ebc…`, provider
`280f0e95d`, fork `b1811029`); "new" is the step-overhead binary (`3d5a1ed5…`,
provider `006a34ba8`, fork `ca8c384c`). Each run is the gated cell
`s2-p1536-o512` (staggered 250 ms, bound 1) plus `s1-p1536-o512`, 10 blocks
each, 1 warmup, seed `20261008`. The live provider was not paused (rule for
diagnostics), so all four runs share the same live load; GPU utilization in
`gpu.log` stayed at 94-98%. Policies are `s2-old-policy.json` and
`s2-new-policy.json`; raw JSONL, the run script, and `gpu.log` stay on the lab
host (hashes in `raw-sha256.txt`). `summarize.py` prints the table below from
the raw files. Exit 0 for all four runs; 0 parity mismatches, errors, or
fallbacks.

| s2-p1536-o512, 20 blocks per binary | 10-06 binary | step-overhead binary |
| --- | ---: | ---: |
| ordinary decode tok/s (median) | 112.1 | 112.4 |
| native decode tok/s (median) | 111.9 | 111.7 |
| native/ordinary decode, paired median | 0.9986 | 0.9936 |
| paired block ratios, range | 0.900-1.211 | 0.921-1.078 |
| p95 TPOT ms, ordinary / native | 17.54 / 17.58 | 17.51 / 17.61 |

## Finding

- **Load, not a code regression between binaries.** Both arms are the same on
  both binaries, and the paired native/ordinary median is 0.994-0.999 on
  both. The per-block ratios swing from 0.90 to 1.21 under live load, which
  is what widened the formal s2 interval to -8.6%. The step-overhead change
  only touches native verify rounds, and a gated s2 row never runs one: the
  second request arrives during the first one's prefill, so the gate holds
  the native row from its first decode round.
- **A small native-only cost that is code, present in both binaries.** Every
  native-arm request shows exactly 7 inter-chunk gaps of 22-26 ms (ordinary:
  0 to 0.5), at token 69, 133, 193, 256, 320, 384, 447, on both rows of the
  round. These are the MTP-6 periodic drafter catch-ups: a held row advanced
  its drafter every 64 buffered columns inside the shared ordinary round,
  about +8-10 ms each, roughly 1% of the request's decode time. The held row
  never restores in this cell, so the work was wasted.
- **Fix (this PR).** A held row now advances its drafter only before its next
  native proposal (SPEC-048 0.1.25, MTP-6), so a row held to completion adds
  no drafter forward to the shared rounds. The native admission rule was
  already the preferred one: native only when no other row is in flight
  (`otherActiveRows >= max_native_active_rows` selects ordinary).

One-slot (s1-p1536-o512) in the same window, for reference: the native/ordinary
paired median is 1.144 on the 10-06 binary and 1.291 on the step-overhead
binary, the same as in the 10-06 control.
