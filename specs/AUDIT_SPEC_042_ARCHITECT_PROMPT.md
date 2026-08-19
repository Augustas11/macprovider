# AUDIT SPEC-042 — Architecture Lane

You are reviewing the architecture of a specification. Subject:
`specs/SPEC-042-pool-control-plane.md` (Layer 2 "Trusted Pool / subnet"
control-plane manifest), status `draft-skeleton`.

Read first:
- `specs/SPEC-042-pool-control-plane.md` (subject)
- `specs/SPEC-002-*.md` (coordinator admission/routing — SPEC-042 extends its authority)
- `specs/SPEC-041-relay-blind-request-encryption.md` and
  `specs/SPEC-040-wallet-native-buyer-sessions.md` (adjacent Layer 3 / session SPECs)
- The Layer 1 substrate audit context: this SPEC exists because the network has
  a strong Layer 1 but no pool object; `pool_id` appears nowhere in the
  coordinator/gateway internals today.

## Your lane: is this the right decomposition?

Report findings on:

1. **Primitive choice.** Is "pool_id as a mandatory authority field threaded
   through every path" (R002) the correct core abstraction? Alternatives (pool
   as a routing overlay, per-pool coordinator instances, namespace prefixing).
   Is threading pool_id through ALL of {routing, admission, snapshots, logs,
   receipts, settlement, payout, disclosure} the right cut, or over/under-scoped?
2. **Authority-boundary fit.** Does SPEC-042 respect SPEC-002 routing ownership
   and SPEC-003 identity ownership, or does it duplicate/fork them? Is a new
   `pool-control-plane` authority domain justified, or should this live under an
   existing domain?
3. **Layer 2 / Layer 3 separation.** Are the forward-declared Layer 3 compat
   fields (R009: privacy_mode, relay_blind_capable, receipt_contract,
   metadata_visible, downgrade_policy, sticky_routing_allowed) the right set to
   avoid re-architecting when SPEC-041 Layer 3 lands? Anything that WILL force a
   re-architecture later that should be designed in now?
4. **Manifest model.** Immutable-core vs. mutable-fields split — is it coherent?
   Is pool_id-as-digest-of-core the right call vs. random opaque id? Manifest
   versioning/history sufficiency for reconstructing in-force policy at settle
   time.
5. **Sequencing / build order.** Is the R010 rollout (pool_id ingestion before
   routing; fail-closed until all components present; conformance tests first)
   the right build order? What is the true critical path to a shippable Layer 2
   MVP? Is tenant isolation correctly identified as the hardest risk?
6. **Open decisions.** Are the `(Open)` and `DECISION_REQUIRED` items the RIGHT
   open questions, and is anything marked settled that should actually be open
   (or vice versa)?
7. **Missing architectural requirements.** Anything structurally absent:
   pool lifecycle (create/pause/retire), capacity/supply bootstrapping for a new
   pool, migration of existing global providers into pools, coordinator failover
   with pool state, multi-coordinator/pool-state consistency.

## Output format

Per finding: severity (CRITICAL / HIGH / MEDIUM / LOW / INFO), title, location,
rationale, and a concrete recommendation. End with
`VERDICT: <PASS|PARTIAL|FAIL> — C:<n> H:<n> M:<n> L:<n> I:<n>`.
Bar is 0 Critical/High/Medium. This is a skeleton; `(Open)`-marked items are
acceptable and should be LOW/INFO unless the SPEC commits to a wrong structural
decision or omits a load-bearing one. Prioritize decomposition correctness over
prose polish.
