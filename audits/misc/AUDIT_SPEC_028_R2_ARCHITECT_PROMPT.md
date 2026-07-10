# AUDIT_SPEC_028_R2_ARCHITECT_PROMPT

You are auditing `specs/SPEC-028-mlx-speculative-decoding.md` from the ARCHITECT lane.

Audit target: SPEC-028 v0.2-draft only. Treat the current branch as a
research/spec branch: do not propose executable code, and do not audit unrelated
repository changes.

Controlling context:

- `specs/SPEC-028-mlx-speculative-decoding.md`
- `docs/research/spec-decode-integration-2026-07.md`
- `specs/SPEC-001-phase3-binary.md`
- `specs/SPEC-010-model-catalog.md`
- `specs/SPEC-011-operator-pushed-warm-swap.md`
- `specs/SPEC-013-cli-autotune.md`
- `specs/SPEC-015-receipts.md`
- `phase3-binary/dist/static/autotune-candidates.json`
- `beta/workloads.py`
- `beta/config-m1.yaml`
- `beta/config-m4.yaml`
- `beta/DECISION_CRITERIA.md`

Lock bar: 0 critical, 0 high, 0 medium.

Focus:

- Is SPEC-028 scoped to the correct layer: provider-side throughput, no buyer
  API change, no settlement schema change, no coordinator routing behavior
  change?
- Are SPEC-001, SPEC-010, SPEC-011, SPEC-013, and SPEC-015 interactions assigned
  to the right owners?
- Does v0.2 close the major research risks from v0.1 without over-scoping the
  first implementation round?
- Is the gpt-oss waiver architecturally acceptable for v0.1, or does it
  undermine the compatibility matrix and lock bar?
- Does the PR-A/PR-B/PR-C implementation sequencing keep state-machine,
  telemetry, and runtime-loading risks isolated?
- Does the autotune extension stay a future SPEC-013 amendment rather than
  accidentally becoming a dependency of SPEC-028?
- Are AC-10 and AC-11 good acceptance gates for a provider fleet made of mixed
  8 GB, 16 GB, and 48 GB+ Apple Silicon machines?

Output format:

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity:

- `ARCH-C-1`, `ARCH-H-1`, `ARCH-M-1`, `ARCH-L-1`, etc.
- Each finding must cite the SPEC section and concrete repo/spec evidence.
- Do not include Critical/High/Medium findings unless they should block LOCK.
- Low findings may be left for later; the stop bar is 0 C/H/M.
