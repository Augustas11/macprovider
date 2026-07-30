# SPEC-038 audit — CODE lane

You are auditing a **normative SPEC document** (design text), not an
implementation. This is a proof-review of the specification's internal
consistency and completeness. Do not write code; produce findings only.

## Scope (read these files in this repo checkout)

- `specs/SPEC-038-continuous-batching.md` (the SPEC under audit)
- `specs/AUTHORITY.json`, `specs/CONFORMANCE.json`, `specs/README.md` (manifest
  entries added for SPEC-038)
- Ground truth for the decision being specified:
  `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md`

## What to check (CODE lane = spec-as-contract correctness)

1. **Requirement completeness vs the 10-point contract.** The memo's decision
   (§Decision, items 1–10) plus SPEC-028 mutual exclusion, the MSB throughput
   gate, and RESEARCH_233 independence must each map to a normative
   `SPEC-038-R0xx` requirement. Flag any contract point with no MUST/MUST NOT
   coverage, or any requirement that contradicts the memo.
2. **Internal consistency.** Cross-references between FR-CB labels,
   `SPEC-038-R0xx` IDs, the §5 mode matrix, §7 acceptance criteria, and §8/§9
   gates must be coherent and non-contradictory. Every AC must trace to a
   requirement; every requirement should be exercised by an AC or explicitly
   marked hardware-only.
3. **Testability.** Acceptance criteria must be concrete fixtures, not vague
   prose. Flag any AC that cannot be turned into a pass/fail test.
4. **Manifest correctness.** SPEC-038 entry in CONFORMANCE.json (spec_id,
   title, version matching the SPEC header exactly), the 16 requirement
   records, and the `continuous-batching-serving` authority domain in
   AUTHORITY.json must be well-formed and consistent with the SPEC text.
   Requirement count (R001..R016) must match the SPEC's requirement set.
5. **Scope discipline.** The SPEC must not silently expand into IMPL, into a
   paged allocator, into quantized-KV batching, or into combined
   speculative-batching. Confirm the out-of-scope list is honored by the
   requirements.

## Output

For each finding: SEVERITY (CRITICAL / HIGH / MEDIUM / LOW / INFO), the exact
location (file + section/requirement), the problem, and a concrete fix. The
acceptance bar is 0 CRITICAL / 0 HIGH / 0 MEDIUM. If you find nothing at those
levels, say so explicitly and list any LOW/INFO separately.
