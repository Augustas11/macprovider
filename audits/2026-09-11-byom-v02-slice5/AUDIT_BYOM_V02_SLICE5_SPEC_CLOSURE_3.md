# BYOM v0.2 slice 5 SPEC closure — pass 3 (2026-09-11)

Reviewed: `git diff origin/main -- specs/` at `ade182e5`. Three codex lanes over `AUDIT_BYOM_V02_SLICE5_SPEC_CLOSURE_3_PROMPT.md`.

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 0 | 2 | 3 | 0 |
| security-reviewer | 0 | 0 | 0 | 0 | 0 |
| architect | 0 | 0 | 0 | 1 | 0 |

Security and architect at bar (not re-fired). Fixed in the R4 fix commit:

- **SPEC-017 DRAFT lifecycle vs the CONFORMANCE-keyed §16.7 gate** (code M): SPEC-017 v0.2.1 is LOCKED in this revision (header and status updated); CONFORMANCE's `0.2.1` is the version of record the gate keys on.
- **SPEC-047 change-log reversed the never-trusted rule** (code M): "a never-trusted provider is excluded while hardware trust is operated".
- LOW: SPEC-023 sanction citation → R009 (aggregate) + R007 (offer path); loss detection names `*_source_sha256`; AC-INTAKE-5 future-dated wording; §5.2b "like §5.2a" cache cross-reference removed.
