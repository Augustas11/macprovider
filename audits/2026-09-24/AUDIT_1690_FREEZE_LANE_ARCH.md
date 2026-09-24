Read `audits/2026-09-24/AUDIT_1690_FREEZE_COMMON.md` first.

**Lane: architecture and compatibility.** Check:
- mixed-version safety: old CLI/new coordinator and the reverse, and an old coordinator reading the new DB columns
- governance: SPEC-042 0.0.31 text vs code, CONFORMANCE evidence anchors and fragment drift
- rename impact (`OllamaLoopbackRuntime` to `OpenAICompatibleLoopbackRuntime`) on configs, env vars, docs and tests
- whether the `ollama:` behavior is preserved
- whether the M1 code is correct and complete for SPEC-042-R006 without the M3 SPEC bundle (which is parked, not merged)
- whether anything in this diff depends on parked M3 text
