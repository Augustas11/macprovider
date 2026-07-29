# SPEC-038 v0.2 architect-lane audit prompt

Audit the full branch diff for `SPEC-038` v0.2:

```bash
git diff origin/main -- specs/SPEC-038-continuous-batching.md specs/CONFORMANCE.json specs/README.md
```

Scope:

- SPEC-only change; no implementation files should be modified or required.
- Check the architectural reframe from upstream batch API / dense KV to a
  locally owned scheduler consuming a forward-referenced `SPEC-039` paged
  engine.
- Check the boundary: `SPEC-038` owns admission, preemption, dynamic
  insert/remove, per-request block-table lifecycle, serving telemetry,
  accounting, fallback, and enable gates; `SPEC-039` owns paged KV storage and
  paged-attention execution.
- Check whether the `SPEC-039` forward reference is represented honestly
  without breaking structured governance while `SPEC-039` is absent on
  `origin/main`.
- Check that MoE expert dispatch is captured as a scheduler concern without
  overstating the Phase-3 attention-paging result.

Money-path weighting:

- Treat any unclear scheduler/engine ownership that can lead to duplicated
  authority, contradictory implementation gates, or unowned receipt/accounting
  behavior as at least MEDIUM.

Output:

- Findings ordered by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO.
- Include exact file/line references.
- End with counts and a verdict: PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
