# RESEARCH_744 — Buyer TTFT ceiling: observe-only calibration

Date pulled: 2026-08-17T02:12:31Z  
Host: Pearl `coordinator.db` (read-only sqlite3)  
Window: `ts_utc >= 2026-07-29T00:00:00Z` (B1 `ttft_ms`/`decode_ms` columns exist)  
Catalog baseline: `published-2026-07-29-inband-provenance-v1`  
Scope: decide whether `--buyer-ttft-ceiling-ms` can leave its shipped default of `0`  
Non-goals: no catalog write, no CLI default change, no hello-gate flip, no ranking formula change

## Executive summary

1. **#744 ranking/provenance/drift already shipped** (SPEC-023 v0.8, PR #772, A4 in-band provenance). The remaining original item is a production buyer-TTFT default.
2. **Keep the default at `0` (disabled).** Live `request_log` does not contain a per-RAM-class Stage-1 warm 4k TTFT distribution, which is the quantity the installer ceiling actually compares.
3. **Streaming buyer TTFT is fast where we have it, and too thin to set a fleet default.** 298 HTTP-200 streaming rows with non-null `ttft_ms`; **0** exceeded 1800 ms. Llama-3.2-3B stream p95 = 308 ms (n=168). Qwen3-8B stream p95 = 431 ms (n=110). Qwen3-Coder-30B stream p95 = 597 ms (n=20, last sample 2026-08-02).
4. **Non-streaming `ttft_ms` is the 2026-07-09 trap.** 18,502 of 18,800 timed HTTP-200 rows are `stream=0`. Qwen3-8B non-stream p50 = 19.2 s; Coder-30B non-stream p95 = 113 s. Those numbers are buffered whole-response latency, not first-token UX, and must not become an installer veto.
5. **Hardware class is missing.** `request_log` has no RAM/chip. 8 GB vs 32 GB onboarding risk cannot be measured from this table. Joining session IDs to Postgres hardware evidence is a later observe pass, not this memo.
6. **Autotune Stage-1 still uses a padded ~4k prompt** (`Stage1Iterator` prewarm + probe). Short-prompt streaming chat (Llama avg 41 prompt / 2.1 completion tokens) is not that probe. A ceiling calibrated here would not be the ceiling the installer evaluates.

**Decision:** do not set `--buyer-ttft-ceiling-ms` in `install.sh` or the CLI default. Revisit only after a signed export of post-#901 Stage-1 warm TTFT exists across 8/16/24/32 GB classes with n≥30 per cell.

## What the ceiling actually gates

`--buyer-ttft-ceiling-ms` (SPEC-023 v0.8 / #744) is a **paid-recommendation** hard veto on the local autotune probe's `ttftMS`. `install.sh` runs `autotune --recommend --apply` without the flag, so every fresh install and every incumbent refresh currently uses `0` = disabled.

It is not:

- catalog `bench_gate.max_4k_ttft_ms` (advisory drift only; SPEC-023 §5 / SPEC-032 #687)
- canary `max_ttft_ms` (SPEC-031; observe in production)
- coordinator routing exclusion

A default greater than 0 therefore changes **who can onboard as paid**, including existing providers who re-run recommend.

## Live coverage

| Slice | Rows |
|---|---:|
| `request_log` all-time | 59,400 |
| Post-B1 (`>= 2026-07-29`) | 35,772 |
| Non-null `ttft_ms` (equals non-null `decode_ms`) | 18,805 |
| HTTP 200 + routed + timed | 18,800 |
| of which `stream=1` | 298 |
| of which `stream=0` | 18,502 |
| Distinct timed providers (session IDs) | 161 |
| Distinct streaming providers | 38 |

Timed columns only appear after B1. Pre-2026-07-29 rows cannot be used.

Post-B1 model mix is dominated by `mlx-community/Llama-3.2-3B-Instruct-4bit` (30,482 rows). Qwen3-8B is second (4,587). Coder-30B, gpt-oss-20b, and catalog-key aliases are sparse. No timed rows for Llama-3.1-8B, Qwen3-32B, Qwen2.5-Coder-32B, Gemma-4-26B, or Nemotron.

## Streaming HTTP 200 (buyer-first-byte analogue)

| Model | n | providers | p50 ms | p95 ms | max ms | >1800 | > catalog `max_4k_ttft_ms` | avg prompt / completion |
|---|---:|---:|---:|---:|---:|---:|---|---|
| Llama-3.2-3B-Instruct-4bit | 168 | 12 | 209 | 308 | 715 | 0 | 0 / 2500 | 41.0 / 2.1 |
| Qwen3-8B-4bit | 110 | 18 | 217 | 431 | 1225 | 0 | 0 / 4500 | 14.6 / 8.8 |
| Qwen3-Coder-30B-A3B-Instruct-4bit | 20 | 8 | 181 | 597 | 868 | 0 | 0 / 3500 | 3077.6 / 3.5 |

Coder-30B is the only streaming cell with a 4k-shaped prompt. n=20 is below the cold/warm harness floor of 30 (`test/e2e/coldwarm-ttft/CALIBRATION.md`). Last sample is 2026-08-02, so it is also stale.

Llama/Qwen streaming samples are short chat, not Stage-1 probes. They show that **current buyer-visible first-byte latency is far below every signed catalog TTFT number**. They do not show what a 8 GB Mac would record on the installer's padded probe.

## Non-streaming HTTP 200 (do not calibrate from this)

| Model | n | p50 ms | p95 ms | max ms | avg completion | `decode_ms` = 0 |
|---|---:|---:|---:|---:|---:|---:|
| Llama-3.2-3B-Instruct-4bit | 16,358 | 779 | 5,104 | 35,494 | 66.2 | 4,473 |
| Qwen3-8B-4bit | 2,039 | 19,227 | 32,578 | 192,305 | 410.7 | 982 |
| Qwen3-Coder-30B-A3B-Instruct-4bit | 79 | 4,326 | 113,233 | 147,095 | 65.9 | 40 |
| gpt-oss-20b-MXFP4-Q8 | 22 | 23,368 | 133,431 | 224,787 | 165.5 | 7 |

Non-stream `ttft_ms` is provider-dispatch-to-first-byte on a buffered response. Thousands of rows have `decode_ms = 0`, which means first byte ≈ completion. Using these p95s as `--buyer-ttft-ceiling-ms` would replay SPEC-031's 2026-07-09 failure: a structurally different metric, applied as a hard gate, emptying paid eligibility.

## Why this still cannot pick a number

Entry 196 already rejected making catalog `max_4k_ttft_ms` the buyer UX gate, and rejected restoring the 60 s `--gate-ttft-ms` default. The remaining option is a new installer default.

That default needs, at minimum:

1. Warm Stage-1 TTFT (post-#901 prewarm), not cold load, not non-stream `request_log`.
2. The same padded prompt the installer probe uses.
3. Separate 8 / 16 / 24 / 32 GB cells with n≥30 each, because the 8 GB onboarding cliff is the actual harm mode (#742 Pageouts false-block, #786 rate-card default).
4. Donor-mode fallback still names a local row when the paid ceiling vetoes every candidate, so a guessed default cannot strand a fresh install with `noEligibleModel` and no donor path.

None of those four are in this snapshot. Postgres hardware-verifier evidence is a different database and was not joined.

## What would change if we guessed anyway

`install.sh` and incumbent `autotune --recommend --apply` would start vetoing paid rows whose **local Stage-1 warm 4k TTFT** exceeded the default. Short-prompt streaming evidence says current serving is fine. It says nothing about M-Base 8 GB / 16 GB probe TTFT on a 3200-token prefill. The last time this path grew a “cleaner” eligibility rule (PR #772 dropping rate-card `default`), fresh installs fell to donor-only until #786.

## Revisit gate

A later memo may propose a default only if all hold:

- Post-#901 Stage-1 warm `ttftMS` export, bound to catalog row + artifact SHA + binary version + chip-derived tier + RAM.
- n≥30 per RAM class for every `recommendable` row the installer can pick on that class.
- Streaming `request_log` p95 on the same models remains below the proposed default (sanity check, not the calibration source).
- New decision-log entry; CLI/install default change ships as a reviewed PR, not a docs push.

Until then #744 remaining work is this observe record plus B7 matrix completeness (`scripts/audit-autotune-gate-matrix.py`). It is not a ranking rewrite.

## Appendix — read-only query

Run on Pearl as `macprovider`. Do not SELECT `buyer_ip`, `request_id`, `account_id`, or raw provider IDs into artifacts.

```sql
-- coverage
SELECT COUNT(*) AS rows_total,
       SUM(CASE WHEN ttft_ms IS NOT NULL THEN 1 ELSE 0 END) AS ttft_nonnull,
       SUM(CASE WHEN status = 200 AND stream = 1 AND ttft_ms IS NOT NULL
                 AND provider_assigned_id IS NOT NULL THEN 1 ELSE 0 END) AS stream_200_ttft,
       SUM(CASE WHEN status = 200 AND stream = 0 AND ttft_ms IS NOT NULL
                 AND provider_assigned_id IS NOT NULL THEN 1 ELSE 0 END) AS nonstream_200_ttft
FROM request_log
WHERE ts_utc >= '2026-07-29T00:00:00Z';

-- percentiles (streaming and non-streaming)
WITH timed AS (
  SELECT model, stream, ttft_ms, decode_ms
  FROM request_log
  WHERE ts_utc >= '2026-07-29T00:00:00Z'
    AND status = 200
    AND provider_assigned_id IS NOT NULL
    AND ttft_ms IS NOT NULL
    AND ttft_ms > 0
), ranked AS (
  SELECT model, stream, ttft_ms, decode_ms,
         ROW_NUMBER() OVER (PARTITION BY model, stream ORDER BY ttft_ms) AS ttft_rn,
         COUNT(*) OVER (PARTITION BY model, stream) AS n
  FROM timed
)
SELECT model, stream, n,
       ROUND(MAX(CASE WHEN ttft_rn = MAX(1, CAST((n + 1) * 0.50 AS INT)) THEN ttft_ms END), 1) AS ttft_p50,
       ROUND(MAX(CASE WHEN ttft_rn = MAX(1, CAST((n + 1) * 0.95 AS INT)) THEN ttft_ms END), 1) AS ttft_p95,
       ROUND(MAX(CASE WHEN ttft_rn = n THEN ttft_ms END), 1) AS ttft_p100
FROM ranked
GROUP BY model, stream, n
ORDER BY n DESC;
```
