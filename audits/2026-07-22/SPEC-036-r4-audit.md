# SPEC-036 — Round-4 SPEC audit (5 lanes) + consolidation

**Date:** 2026-07-22
**Reviewed revision:** `249baf3f` (post round-3)
**Method:** five independent lanes (3 codex + adversarial-verificator + product-design).

## Round-4 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code | 0 | 4 | 4 | 0 |
| codex security | 0 | 3 | 2 | 0 |
| codex architect | 0 | 3 | 3 | 0 |
| claude adversarial | 0 | 1 | 1 | 0 |
| claude product-design | 0 | 0 | 4 | 4 |

**Product lane reached 0 HIGH** (all seven round-3 product HIGHs resolved). The
remaining HIGHs were concentrated and — notably — several were NEW surface
introduced by the round-3 fixes themselves (the `degrade_to_spec022` machinery, the
`pending` post-start promotion, the multi-reference generalization framing, and
partial `hardware_runtime_class` threading). Per the repo's audit discipline
(anchored loops past ~3–4 rounds → simplify/rethink rather than keep patching), the
round-4 consolidation **removes/simplifies** that risky surface instead of patching
it further.

## Consolidation (all C/H/M addressed)

- **degrade_to_spec022 fail-open (adv-H1, security-H, arch-H3, codex code-H1):**
  REMOVED the per-row degrade-to-payable path. Every non-payable request-start
  condition now fails closed unconditionally at the row level. Availability during a
  reference outage is handled by `reference_unavailable_auto_downgrade`, a
  pre-admission **mode** flip (enforce→warn_only) that affects only new admissions
  and never reclassifies a captured row; honest-provider compensation is an
  operator-funded non-buyer path (FR-17), outside settlement.
- **pending post-start promotion (codex code-H2, security-H, arch-H2):** REMOVED. A
  captured `pending` is immutable and non-payable → `compute_integrity_pending_deadline`.
- **FR-10 over-collapse of unknown/expired (codex code-H3):** replaced with an
  ordered recomputation (block/quarantine → expiry+cause → unknown → verified → warn
  → pending) that preserves `unknown`/`expired` as distinct states.
- **hardware_runtime_class binding (codex code-H4, arch-H1, product-M4):** bound via
  a policy invariant (one class per covered key) + FR-4 `hardware_runtime_class_digest`
  capture + FR-12 `hardware_class_changed` expiry + FR-3 expiry cause + AC-1 8-tuple
  and class-restriction AC; rationale added that a policy-pinned constant need not be
  a separate key discriminator.
- **Multi-reference "identical 2-arm" contradiction (codex code-M5, arch-M, product-M1):**
  reframed as a SPEC-036-owned generalization of SPEC-030's rule to `(N+1)` arms
  (≤(N+1)K); fixed the backwards tail sentence (larger union → smaller per-arm tail).
- **Reference independence (security-H, reconciling R3 arch-M2/product-H6):** all
  three of operator/hardware/runtime-build independence now REQUIRED; golden fixture
  is additive only, never a substitute (safer money-path posture; consistent with
  §6.1 enforce-not-reachable-at-beta).
- **Composite snapshot fields (codex code-M6, security-M):** FR-4 capture now binds
  SPEC-022 version/mode/coverage-digest/effective-enforce/route-snapshot-digest +
  SPEC-036 policy digest; missing → unreadable.
- **Coordinator final-inconclusive enum (codex code-M7):** added
  `inconclusive:coordinator_timeout` + closed provider-reason→counter mapping.
- **AC-8 warn-based transition (codex code-M8, security-M):** aligned AC-8 and FR-12
  (escalate on provider-originated artifact change with active risk; benign warn /
  continuity-proven reconnect exempt).
- **Sybil precondition relies on a primitive SPEC-026 lacks (arch-M, product-L1):**
  enforce is now categorically unavailable until a named stable-device/operator
  identity authority exists; §6.1 lists this as a hard prerequisite, not a supply gap.
- **corpus/threshold rotation amnesty (arch-M, product-L4):** adverse-state lineage
  tombstone blocks short-onboarding re-qualification of a prior-quarantined identity.
- **TTL vs cadence (product-L3):** enforce refuses TTL < 2× cadence.

Round-5 convergence check recorded separately.
