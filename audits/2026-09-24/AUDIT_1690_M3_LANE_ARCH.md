Read `audits/2026-09-24/AUDIT_1690_M3_SPEC_COMMON.md` first.

**Lane: architecture and implementability.**
- Can M4 (coordinator) and M5 (CLI per-request receipt eligibility) implement these SPECs against the actual code structure without contradicting existing requirements or mapped CONFORMANCE evidence (fragment-anchored evidence)?
- Are the authority-domain ownership and the sequencing sound? Check that SPEC-042 owns the pool policy, SPEC-022 settlement, SPEC-005 arithmetic, and SPEC-015 receipts.
- Does the rollout rule for the SPEC-023 feed tuple leave any mixed-version state unsafe (old coordinator/new CLI, and the reverse)?
- Is anything over-specified, or missing, that would block M6: a Mac Studio pool member serving llama-server with enforce-mode receipt → ledger credit?
