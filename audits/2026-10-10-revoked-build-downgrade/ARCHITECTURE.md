Lane: ARCHITECTURE REVIEW. Is this the right shape for the one rollback lever?
Check spec/code consistency (SPEC-020-R007, R-2.1, AC-V0.1-2/AC-V0.1-R007,
T-4; SPEC-002-R004 v1.6.13; CONFORMANCE.json mappings), wire compatibility
with older providers and older coordinators in both directions, interaction
with SPEC-020-R005 accepted-session recovery and R006 mirror, the pending
marker format staying readable by the older target release, the release
train/ops entry-point rules (scripts/ops only, live-ops lock, downtime
banner), the operator runbook's accuracy (preconditions, timing, discovery
head caveat), and any coupling or single-use abstraction that should not
exist. Note anything that would stop this lever working in production the
first time it is used.
