You are performing an independent proof-review (ARCHITECT / design-coherence lane)
of a finished normative specification in the macprovider repository. This is a
review of an existing document for design defects. Report defects only.

## Target
- Primary: `specs/SPEC-036-compute-integrity-receipt.md`.
- Composed primitive: `specs/SPEC-030-losslessness-probe.md`.
- Neighbors: `specs/SPEC-022-verified-model-settlement.md` (settlement it gates),
  `specs/SPEC-015-receipts.md` (receipt shape it preserves),
  `specs/SPEC-026-browserless-provider-onboarding.md` (onboarding it gates).
- Decision context: `beta/DECISION_CRITERIA.md` (Entry 181 will record the
  compose-vs-duplicate reconciliation and the renumber).

## Context
The spec was renumbered `SPEC-030 → SPEC-036` to resolve a collision with the
landed `SPEC-030-losslessness-probe.md`, and its shared-machinery dependency was
rewired from the pre-renumber `SPEC-029` to canonical `SPEC-030`. The chosen design
is **compose** on the losslessness probe's snapshot/support-selection/TV/transport
machinery (by normative reference), adding only three genuinely new arms:
(a) provider-vs-trusted-reference comparison, (b) trusted-reference admission /
quorum / independence, (c) the SPEC-022 settlement-gating consumer +
`quarantined_compute_drift` state.

## Review dimensions (ARCHITECT / coherence)
1. Compose soundness: is the boundary between "inherited from SPEC-030" and
   "new in SPEC-036" drawn coherently? Is anything claimed as inherited that the
   losslessness probe does not actually provide, or duplicated that should have
   been referenced? Is keeping a distinct `compute_integrity_probe_v1` wire
   constant (vs reusing `losslessness_probe_v1`) justified and consistent?
2. Dependency-rewire correctness: does depending on SPEC-030 (Losslessness Probe)
   for the snapshot/TV/transport primitive actually hold, given SPEC-030's stated
   scope is provider plain-vs-spec self-consistency? Are the cited §FR-3/§FR-4/
   §FR-7/§FR-9 the right anchors? Any circular or contradictory dependency?
3. Scope-boundary integrity vs neighbors: does SPEC-036 stay additive to SPEC-022
   (no outcome-enum change, AND-gate semantics) and SPEC-015 (no receipt/usage
   fields)? Does the SPEC-026 onboarding gate compose without blocking identity
   registration? Any overreach into another spec's authority domain?
4. Threat-model honesty and layering: is SPEC-036 correctly positioned as the
   "stronger-claim" cross-node probe the losslessness spec named as future work,
   while still honestly disclaiming hardware/binary/honest-computation proof and
   overt-probe evasion? Are the enforcement claims proportionate to what an overt
   distribution-drift detector can actually establish?
5. Migration / operability coherence: is the observe → warn_only → enforce path
   with per-key calibration gates, reference-refresh throughput SLOs, and
   circuit-breaker/manual-review controls internally coherent and operable at the
   stated beta scale (single/few reference nodes)? Do the §8 resolved decisions
   (trusted-reference-only enforce, threshold floors, onboarding gate, calibration
   timeline, consensus-funding deferral) each follow from the design without
   contradicting an FR?
6. Consumer/authority modeling: is a new `compute-integrity-settlement` authority
   domain the right home for settlement-gating (vs folding into SPEC-022 or
   SPEC-030)? Is the compose-not-fold decision defensible and free of a hidden
   duplicate-authority conflict with SPEC-030 or SPEC-022?

## Output format
For each finding: SEVERITY (CRITICAL / HIGH / MEDIUM / LOW / INFO), short title,
file + section, the design defect and why it matters, and the recommended
resolution. Rank most-severe first. If a dimension is coherent, say so briefly.
Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM.
