# B7 — Catalog gate re-derivation tooling

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

**Status (2026-08-02)**: the readiness preflight is implemented; numeric
re-derivation remains deferred by fleet/hardware preconditions. The preflight
does not mutate catalog bytes or invent threshold arithmetic.

**Gated on**: ≥3 verified providers existing / #584 hardware. Deferred by physics, not choice.

## Problem / shape
Stage-4 promotion arithmetic (roadmap §7 rule 4, #687): recompute each gate from
≥N verified providers' post-#745 measurements on ≥M hardware classes (N≥3, M≥2),
cross-checked against observed serving data; drop the oMLX seed at promotion.
**Unbuildable at current fleet size**, and the >32 GB rows remain unmeasurable
pending #584. Only after a gate reaches `trusted_provider_matrix` may it gain
enforcement power, and then under a new field name (`hard_min_sustained_tps`) so
the advisory wire field never silently changes meaning.

## Readiness preflight

`scripts/audit-autotune-gate-matrix.py` audits an operator export before any
catalog refresh. The export wraps one `hardware_evidence.autotune.v2` document
per provider with `verification.status = "verified"` and
`verification.decision_reason = "hardware-verifier.v2:verified_trusted_hardware"`.
The command requires:

- the authenticated current release candidate catalog and its SHA on the matrix
  and every benchmark;
- post-#745 timestamps at or after the canonical #745 merge cutoff
  (`2026-07-25T18:05:00Z`), supplied by `--min-generated-at`, plus an explicit
  reproducible `--as-of` upper bound;
- model ID, artifact SHA, row identity, binary version, and hardware identity
  bindings for every benchmark;
- the absolute normalized `model_artifact_path` actually loaded by every
  post-#745 benchmark;
- a bandwidth tier that exactly matches the provider-binary chip-derived tier;
- clean evidence with no swap or thermal-throttle signal; and
- at least three distinct verified providers and two distinct hardware classes
  for every active catalog row, after applying the catalog row's RAM floor plus
  the 4 GB safety margin and its bandwidth-tier floor.

It emits a machine-readable report and exits `2` when the matrix is incomplete.
Equivalent chip labels are normalized before hardware-class quorum, and matrix
size/provider/benchmark bounds are enforced. The report includes the matrix
SHA, generated time, explicit `--as-of`, and records that the wrapper's matrix
authentication is not performed by this command. Hardware-ineligible samples
are excluded from quorum and reported as warnings; they do not poison an
otherwise complete eligible matrix.
The wrapper's verification fields are an export contract, not a new trust
authority: the matrix must be obtained through an authenticated verifier/DB
path before an operator relies on the report.
The report's `ready_for_matrix_review` is only a completeness result:
`rederivation_authorized` is always `false` because this preflight does not
perform the B7 observed-serving cross-check, authenticate benchmark content, or
define threshold arithmetic. `numeric_gates_changed` is always `false`; a
future promotion tool must consume the matrix plus serving observations and
undergo its own SPEC/audit review before changing `bench_gate` values.

The current candidate catalog has no policy-bearing rows. If a row gains
`draft_candidates` or `workload_profiles`, this Python preflight fails closed
until it can share the coordinator's canonical row-identity implementation.

Example:

```bash
python3 scripts/audit-autotune-gate-matrix.py \
  --matrix /path/to/verified-gate-matrix.json \
  --min-generated-at 2026-07-25T18:05:00Z \
  --as-of 2026-07-30T12:00:00Z \
  --pretty
```
