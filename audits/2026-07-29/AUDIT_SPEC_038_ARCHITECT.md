# SPEC-038 audit — ARCHITECT lane

You are auditing a **normative SPEC document** (design text), not an
implementation. Proof-review only; produce findings, not code.

## Scope (read these files)

- `specs/SPEC-038-continuous-batching.md`
- `specs/AUTHORITY.json`, `specs/CONFORMANCE.json`
- Ground truth: `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md`
  (esp. Part 2 technical deep dive, Part 4 approach evaluation, Part 5
  integration map, Part 6 milestones).
- Adjacent authority the SPEC integrates with: `specs/SPEC-023-installer-autotune-recommend.md`
  (Entry 110 capacity), `specs/SPEC-028-mlx-speculative-decoding.md`,
  `specs/SPEC-037-kv-survival-restart.md`.

## What to check (ARCHITECT lane = boundaries, authority, sequencing)

1. **Authority-domain fit.** Is `continuous-batching-serving` the right new
   domain, correctly scoped, and does it avoid re-owning authority held by
   SPEC-023 (autotune capacity), SPEC-015 (receipts), SPEC-024 (prefix-cache
   billing), SPEC-028 (spec decode), or SPEC-037 (kv-cache-persistence)? Are
   the consumer/owner relationships in AUTHORITY.json / CONFORMANCE.json
   correct (SPEC-038 consumes those domains, owns only its own)?
2. **Approach A/B/C/D framing.** Does the SPEC correctly encode Approach A as
   primary, Approach B as the calendar/correctness fallback, and C/D as
   production no-go — with the version-pin and the Gate A4 fallback trigger
   (FR-CB10) faithful to the memo? Any drift from the decision?
3. **Independence vs SPEC-037.** Is the FR-CB16 independence claim (no shared
   paged allocator; v1 round-trip preserved or flag-isolated) architecturally
   sound and consistent with the memo's reciprocal INDEPENDENT verdict and
   with SPEC-037 §8 sequencing? Does it correctly describe the LAYOUT-BOUND
   pivot condition without invoking it?
4. **Integration-surface coherence.** Does the SPEC stay at normative-contract
   altitude (Entry 110 mapping, actor isolation, drain, admission) without
   prescribing IMPL detail that belongs in the BUILD_SPEC? Conversely, are any
   load-bearing architectural constraints missing (e.g. one admission policy
   shared by relay + HTTP, separate prefill/decode phases, decode-first)?
5. **Gate/milestone soundness.** Are §8 go/no-go gates and the FR-CB14 /
   FR-CB15 gates internally consistent and non-circular? Is the enable gate
   genuinely stronger than a green-CI pass (Entry-199 lesson)?
6. **Deferral hygiene.** Are quantized-KV batching, mixed-phase batching,
   combined speculative batching, and priority economics cleanly deferred
   (recorded, not silently dropped), matching the memo's out-of-scope set?

## Output

Per finding: SEVERITY (CRITICAL / HIGH / MEDIUM / LOW / INFO), exact location,
the architectural problem, and a concrete fix. Bar is 0 C / 0 H / 0 M. State
explicitly if the SPEC meets the bar; list LOW/INFO separately.
