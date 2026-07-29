# G0 — Measure buyer demand per (provider, model, bucket)

**Type**: gate (produces no change; produces the decision) · **Size**: XS (~2-4 operator hours)

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

**Status (2026-07-29)**: complete on `main` at `c9749d00`; live Pearl DB
findings are recorded below.

## Why it is the gate
The coordinator-observed thesis (that observed buyer-path performance should
replace provider self-report as the authority for privileges) assumes enough
buyer requests exist to fill per-(provider, model, workload-bucket) aggregates.
At 1-2 providers and prebeta demand, splitting traffic across
(provider × model × workload class × concurrency) plausibly yields single-digit
or zero samples per bucket. Every deferred brief that consumes observed
aggregates (B3, B4, B8) depends on this number.

## Change
One read-only SQL pass over the existing `request_log`: requests/day per
`(provider_assigned_id, model)`, and the same split by prompt-token range and a
concurrency proxy. Report median and p10 days per candidate bucket.

## Files
None (operator query); optionally a `scripts/` helper.

## Necessary, not sufficient
G0 counts *requests* — an **upper bound** on usable observed-performance samples.
Substituted work, buffered-then-flushed streams, and errored requests each yield
a request row but not a clean TTFT/decode sample. A positive G0 gates B3/B4 *in*;
it does not prove them executable. That confirmation comes from B1's real
`ttft_ms`/`decode_ms` data — the argument for drafting B1's SPEC-002 amendment
early so columns fill in parallel with G0.

## The G0-negative posture (decide this in advance)
If G0 shows buckets cannot fill at current demand: **shelve B3/B4/B8**, keep
operator-approved identity + the ship-now A-piece hardening as the trust basis,
hold model upgrades to the operator-grant path rather than observed promotion,
and revisit at materially higher demand. The observed-performance thesis is then
*deferred*, not *wrong* — and the cost of learning that was an afternoon.

## Output
A number, recorded in the deferred-briefs tracking issue, **before any
G0-consuming brief (B3/B4/B8) is scheduled**.

## Findings - live Pearl coordinator DB (2026-07-29)

Source: read-only SQLite query over Pearl
`/var/lib/macprovider/coordinator.db` using `scripts/trust-g0-demand.sql`.
The earlier local run against
`/Users/augstar/macprovider-poc/phase4-coordinator/coordinator.db` produced
zeros only because that local developer DB had an empty `request_log`; it was
not live-network evidence.

Summary:

- Raw `request_log` rows: **23,738**.
- G0-eligible routed rows (`provider_assigned_id` and `model` both present):
  **13,021**.
- Eligible time span: **2026-06-05T07:02:40.340253921Z** through
  **2026-07-29T05:07:31.272893587Z**.
- Observed days: **54.92**.
- Distinct providers: **389**.
- Distinct provider/model pairs: **390**.
- Candidate workload buckets
  `(provider_assigned_id, model, prompt_bucket, concurrency_proxy_bucket)`:
  **987**.
- Buckets with at least 30 current samples: **140 / 987**.
- Buckets at or above 1 request/day: **47 / 987**.
- Buckets estimated to reach 30 samples within 30 days: **47 / 987**.
- Buckets estimated to reach 30 samples within 90 days: **200 / 987**.

Decision numbers from `trust-g0-demand.sql`:

- `p10_requests_per_day`: **0.018**.
- `median_requests_per_day`: **0.055**.
- `p10_days_to_30_samples`: **43.4**.
- `median_days_to_30_samples`: **549.2**.

Highest-fill current buckets:

| provider_assigned_id | model | prompt_bucket | concurrency_proxy_bucket | request_count | requests_per_day | days_to_30_samples |
| --- | --- | --- | --- | ---: | ---: | ---: |
| `c08186bf-b152-4795-a37e-7e5b6588078a` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `0_512` | `c4_plus` | 360 | 6.555 | 4.6 |
| `7c893218-308d-4b58-9260-0678d00deb9c` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `0_512` | `c2_3` | 278 | 5.062 | 5.9 |
| `8387823f-2b8f-42f4-8244-56a629f05c15` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `0_512` | `c2_3` | 224 | 4.079 | 7.4 |
| `69d9337e-5154-44e1-929a-3e1e09d07492` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `0_512` | `c2_3` | 192 | 3.496 | 8.6 |
| `7c893218-308d-4b58-9260-0678d00deb9c` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `0_512` | `c1` | 181 | 3.296 | 9.1 |

Interpretation:

G0 is **positive for aggregate live-network demand** and rejects the local-zero
result. It is **negative for broad per-bucket observed-performance authority at
current demand**: most provider/model/workload/concurrency buckets would take
months or longer to collect 30 samples. B3/B4/B8 should therefore stay
deferred for broad routing or promotion authority until B1 records clean
TTFT/decode fields and demand materially increases. Narrow high-fill buckets can
support observe-mode analysis first, but they should not become general
promotion/enforcement authority from this G0 result alone.
