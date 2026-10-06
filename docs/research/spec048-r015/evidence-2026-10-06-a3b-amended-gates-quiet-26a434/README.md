# SPEC-048 R015, amended gates, quiet window, step-overhead candidate, build 26A434

This directory holds the formal R015 run for the Qwen3.6 A3B native-MTP tuple
under the SPEC-048 0.1.25 gates. The run used provider `e1103712d` (PR #1862)
and fork `ca8c384c4fb6bc7d2fbb7c70a18c34b935701805`. The live provider was
paused for the window. `s2-control/` holds the exploratory s2 attribution
control that preceded the freeze.

**Status: PASS** (`overall_status: PASS`, every cell, every gate). This is lab
evidence on an unpackaged Studio build. It enables nothing: native MTP stays
default-off, and enabling it is a separate operator gate (SPEC-048 R014).

## Identity

| Field | Value |
| --- | --- |
| Policy | `policy.json`, SHA-256 `e24cb7bc4599cfb7281f3dc3985efd6c3b7c9a3b61e424bbc0435d8ea756d44a`, committed in `a5f07ab43` before any measured request, not modified after (see `PREREGISTRATION.md`) |
| Host | `Mac15,14`, Apple M3 Ultra, 256 GB, macOS build `26A434`, Swift 6.3.3 (Command Line Tools) |
| Provider | `e1103712d408a0b158ac17dd8834875245874a42`, built on the Studio with `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS` from `git archive` of that commit |
| Lab binary | SHA-256 `ca12a90c889437acf23ac67e0f74dc765edf29c323c65a5f6e31b2087c531b5f`; `mlx.metallib` `84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf` (mlx-swift 0.31.4) |
| Fixture | `q36-a3b-cat`: target `3fed776d…`, MTP `fa01beec…`, tokenizer `87a7830d…` |
| Isolation | Lab binary isolated, no coordinator join; lab lock held 08:35:30-09:46:02Z |
| Fork harness | Unchanged fork pin; the 2026-10-06 harness runs (fused 133/133, GDN 96/96) in `../evidence-2026-10-06-a3b-step-overhead-26a434/fork-harness/` apply |

Window, from `run-identity-and-status.txt`: `native-mtp-hardware-e2e` (serve
path, PASS, 0 ordinary/native mismatches) 08:36:06-08:37:11Z, then `--phase
matrix` (exit 0, 133 records, 08:37:11-09:00:47Z), then `--phase sustained`
(exit 0, 209 records, 09:00:47-09:31:49Z). Raw JSONL, logs, and the run
script stay on the lab host; their SHA-256 values are in `raw-sha256.txt`.
The final JSONL is `e1f3c42e…`. `analysis.json` and `analysis.md` are the
unmodified output of `scripts/native_mtp_r015_analyze.py` on that file and
`policy.json` (exit 0).

## Result

Corrected bounds are Holm-corrected over all 30 hypotheses (6 cells x 5
gates), as fractions of the ordinary arm (the gap gate is the native/ordinary
p99 ratio minus one).

| Cell | Decode LB (>= +15%; gated >= -5%) | TTFT p95 UB (<= +10%; gated <= +5%) | TPOT p95 UB (<= 0; gated <= +5%) | Gap p99 UB (<= +100%) | Rejection UB (<= 1 pp) | Status |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| s1-p1536-o128 | +25.8% | +4.6% | -20.5% | -23.2% | 0 | PASS |
| s1-p1536-o512 | +24.2% | +4.7% | -19.5% | -24.0% | 0 | PASS |
| s1-p4096-o128 | +21.0% | +5.6% | -17.4% | -19.2% | 0 | PASS |
| s1-p4096-o512 | +18.5% | +5.6% | -15.6% | -19.0% | 0 | PASS |
| s2-p1536-o512 (gated) | -0.3% | +2.6% | +0.3% | +0.3% | 0 | PASS |
| s8-p1536-o512 (gated) + sustained | -0.2% | +0.8% | +0.3% | +0.9% | 0 | PASS |

Hard gates: 208 run records (including warmups), 0 parity mismatches, 0
fallbacks or errors, and no invalid records. Memory: peak physical footprint
43.1 GB at s8 (with the 8 GiB margin, well within 256 GB). The minimum
available-memory fraction was 0.656 in the sustained window and at least 0.759
in every other cell. The sustained window ran 1811 s as one continuous run
(76 records, one window id). Thermal state was nominal at the start and end
of every run.

Medians (decode tok/s, p95 TPOT ms, inter-chunk p95 and p99 ms):

| Cell | Decode ord / native | TPOT p95 ord / native | Inter-chunk p95 ord / native (reported, not gated) | Gap p99 ord / native | Acceptance | Tokens per target forward |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| s1-p1536-o128 | 111.7 / 142.5 | 8.95 / 7.02 | 9.49 / 13.35 | 17.79 / 13.52 | 0.888 | 1.90 |
| s1-p1536-o512 | 110.3 / 138.5 | 9.07 / 7.22 | 9.61 / 13.47 | 18.08 / 13.65 | 0.855 | 1.86 |
| s1-p4096-o128 | 106.9 / 133.2 | 9.35 / 7.51 | 10.16 / 14.61 | 18.54 / 14.93 | 0.917 | 1.92 |
| s1-p4096-o512 | 107.3 / 127.9 | 9.32 / 7.82 | 10.13 / 14.53 | 18.55 / 14.94 | 0.843 | 1.85 |
| s2-p1536-o512 | 137.0 / 137.1 | 14.36 / 14.35 | 15.19 / 15.24 | 25.19 / 25.11 | n/a | n/a |
| s8-p1536-o512 | 197.3 / 197.4 | 35.93 / 35.95 | 39.38 / 39.45 | 64.78 / 61.63 | n/a | n/a |

Acceptance and tokens per target forward match both earlier 10-06 runs
exactly, as expected for bit-identical verification. The inter-chunk p95
column shows the structural mismatch the 0.1.25 amendment removed: native's
inter-chunk p95 stays about 40% above ordinary's while its per-token latency
is 16-22% lower.

Gate evidence in the native runs (counts include the warmup; every hold ended
with a clean finish, none unresolved, none restored because every held row
finished while the gate was engaged):

| Cell | Native admissions | Load-gate downgrades | Depth-zero rounds | Hold episodes | Held to clean finish |
| --- | ---: | ---: | ---: | ---: | ---: |
| s2-p1536-o512 | 11 | 11 | 374 | 11 | 11 |
| s8-p1536-o512 | 11 | 77 | 429 | 11 | 11 |
| s8 sustained (38 blocks) | 38 | 266 | 1548 | 38 | 38 |

## Against the contaminated 2026-10-06 run

Ordinary one-slot decode is 107-112 tok/s here, against 84-87 tok/s under live
load on 10-06, so the quiet window removed the load. The native/ordinary
decode ratio (1.19-1.28) is close to the 10-06 medians (1.24-1.31). The gated
cells are now at parity in both throughput and latency (s2 decode ratio
0.999, s8 1.001). This includes the MTP-6 change in `e1103712d`, which removed
the 64-column drafter catch-up stall that every gated native run showed in
`s2-control/`.

## Live provider pause (operator-authorized for this run only)

| Event | UTC |
| --- | --- |
| Pause start (graceful `pause_request` over the control socket, drain acknowledged) | 08:35:33 |
| `launchctl bootout gui/501/live.malibu.provider`, process gone | 08:35:45 |
| GPU preflight: 0% device utilization for 19 of 20 one-second samples (the first sample, 92%, is the drain tail) | 08:35:46-08:36:06 |
| Formal run complete | 09:31:49 |
| `launchctl bootstrap`; process up, status stays `Model is preparing` (pause restored) | 09:31:49 |
| Script fallback `kickstart -k` (provider not ready after 10 min) | 09:41:58 |
| `resume_request` over the control socket | 09:44:39 |
| Provider ready, coordinator connected, buyer serving | 09:45:57 |

Buyer-facing downtime was 70 min 24 s (08:35:33-09:45:57). About 14 minutes
of that came after the run. The provider persists an operator pause across
restarts (`reason operator_pause_restored_after_startup`), and the run
script restarted the job without first sending `resume_request`. The
kickstart restarted it once more. Sending the resume restored service
within 80 s. The next quiet window must resume before restarting.

Restore verification (09:45-09:47Z): the process (pid 67071) runs
`/Users/a1/macprovider/macprovider-cli serve` from the same live binary
(SHA-256 `a6ea51d7ad19359a21fac63995194523264035fbca2ab32dceeede9d9da739bb`,
v1.8.217). Status is `ready` / `buyer_serving`, it is connected to
`wss://coordinator.malibu.tech`, and the catalog release is
`published-2026-10-01-artifact-feed-activation-v1`. A buyer request for
`qwen/qwen3.6-35b-a3b` through `api.malibu.tech` returned HTTP 200 with
content, and the provider's served counter advanced. No config, Pearl, or
coordinator setting was changed.

## Known contamination intervals (recorded, no data discarded)

The frozen `exclusion_rules` is `none`; nothing was excluded or rerun.
`contamination.log` samples GPU utilization, the CPU of the Trusted Pool M1
member's listeners (:18120/:18130), and other inference processes every 10 s,
with the JSONL line count. The in-flight block below comes from that line
count (±1 record). All named intervals are sub-second requests on small
models (3B Q4, 0.5B) and fall in the sustained phase. Every one-slot and s2
matrix record is clean.

| Source | Times (UTC) | In-flight s8 sustained blocks |
| --- | --- | --- |
| Trusted Pool M1 member llama-server (3B Q4), 5 requests | 09:08:50, 09:09:19, 09:09:21, 09:18:26, 09:20:51 | 8, 9, 21, 23 |
| Trusted Pool M1 member swap, ollama (0.5B), 6 requests | 09:24:53, 09:25:56, 09:26:06, 09:27:30, 09:28:05, 09:28:07 | 29, 30, 32, 33 |
| Another session's #1816 GGUF provider llama-server (0.5B), 10 requests | 09:07:58, 09:09:43, 09:10:59-09:11:10, 09:15:17 | 7, 10, 11, 17 |
| Unidentified process at about one CPU core (not GPU; name not sampled) | 08:57:48-09:04:00 | matrix s8 blocks 6-9, sustained 0-2 |

The request times come from each llama-server's relative-time log, anchored
at the file's modification time (±1 s), and from ollama's wall-clock log.

What each overlap can reach. The analyzer builds its paired statistics
(decode throughput, TTFT, TPOT p95, chunk-gap p99, rejection) from matrix
blocks only and drops sustained records from the pairs. The sustained window
feeds only the hard gates: parity, admissions, errors, and minimum available
memory. Its 76 records show 0 parity mismatches and 0 errors, and minimum
available memory never fell below 0.656 (the floor is 0.10). Foreign load
can only lower available memory, so it biases that gate toward FAIL, never
toward PASS. The one overlap that reaches the statistics is the unidentified
CPU-only process during matrix s8 blocks 6-9. Each block runs both arms back
to back, so the process loaded both arms of the pair. Per-block native/ordinary
ratios for those blocks are TPOT -0.019, -0.005, +0.005, +0.001 and
chunk-gap p99 -0.050, -0.053, +0.009, -0.005. Without blocks 6-9 the median
TPOT ratio would be +0.0009 instead of +0.0004, against the 0.05 gated margin.
This attributes each overlap. It does not change the frozen
`exclusion_rules: none`, and no block was excluded or rerun.
