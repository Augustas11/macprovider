Read `audits/2026-09-24/AUDIT_1690_FINAL_COMMON.md` first.

**Lane: architecture, compatibility, and governance.** Check:
- Mixed-version fleet safety: old CLI with new coordinator, new CLI with old coordinator, an old coordinator reading new DB rows or columns, and old gateways.
- The rollout order: coordinator first, then CLI.
- Whether the SPEC text matches the implementation for SPEC-042 0.0.32, SPEC-022 v0.2.0 R012, SPEC-015 0.4.10 R006, SPEC-047 0.2.0, and SPEC-010 v1.11.
- CONFORMANCE honesty (pending vs conformant) and fragment-anchored evidence drift.
- The rename impact of the loopback runtime.
- Whether M6 (a Studio pool member serving llama-server with enforce-mode receipt to ledger credit) is reachable from this code without further code.
