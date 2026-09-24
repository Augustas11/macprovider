Read `audits/2026-09-24/AUDIT_1690_M8_COMMON.md` first.

**Lane: architecture, compatibility, and governance.** Check:
- mixed-version safety for the new runtime class and feed tuple (old coordinator, old CLI, old gateway)
- the feed rollout rule
- whether the SPEC text matches the implementation
- CONFORMANCE honesty and fragment-anchored evidence drift (the separate offer path exists to avoid editing evidenced functions: verify it does not duplicate security logic inconsistently)
- whether deferring LM Studio and oMLX is recorded correctly
