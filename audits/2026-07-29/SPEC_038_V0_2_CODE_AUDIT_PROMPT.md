# SPEC-038 v0.2 code-lane audit prompt

Audit the full branch diff for `SPEC-038` v0.2:

```bash
git diff origin/main -- specs/SPEC-038-continuous-batching.md specs/CONFORMANCE.json specs/README.md
```

Scope:

- SPEC-only change; no implementation files should be modified or required.
- Check that the v0.2 text removes the dead upstream-pin activation spine and
  dense-contiguous KV scheduler contract.
- Check that surviving serving-safety invariants remain implementable:
  feature flag default-off, serial-fallback parity, per-request usage/stop/
  cancel/receipt isolation, actor isolation, FCFS admission, bounded queues,
  unsupported-mode rejection, SPEC-028 exclusion, warm-swap drain, Entry 110
  capacity mapping, telemetry, and real-hardware enable gates.
- Check that `CONFORMANCE.json` and generated `specs/README.md` are consistent
  with the spec header and validator constraints.

Money-path weighting:

- Treat any ambiguity in per-request usage, receipt identity, settlement,
  cache-billing parity, or cross-request attribution under a shared forward as
  at least MEDIUM.

Output:

- Findings ordered by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO.
- Include exact file/line references.
- End with counts and a verdict: PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
