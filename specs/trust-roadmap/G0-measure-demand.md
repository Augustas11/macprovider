# G0 — Measure buyer demand per (provider, model, bucket)

**Type**: gate (produces no change; produces the decision) · **Size**: XS (~2-4 operator hours)

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
