# AUDIT — Issue #245 — ARCHITECT lane

## Goal
ARCHITECT / SPEC-alignment audit on commit `2743679` (branch `fix/iss245-spec007-v05-untyped-400`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope

- `specs/SPEC-007-explorer.md` — change-log v0.5 entry, §5.6, §6.4
- Handler code in both phases
- dashboard.js link emission

## Background

v0.4 (#231) shipped path-segment typing with a deprecation window. The v0.4 SPEC committed to a v0.5 break per three explicit trigger conditions:
1. 14d telemetry-quiet on `payout_explorer_path_segment_untyped`
2. Operator UI cutover
3. Forced 90-day cutoff at ~2026-09-27

The user invoked this flip on 2026-06-30 — only ~1d after v0.4 merged. The dashboard.js update in this PR IS the operator-UI cutover step (trigger #2 retroactively).

## Lens — ARCHITECT

- **Migration risk**: pre-v0.5 callers (operator scripts, runbooks, external bookmarks) that still emit bare-id URLs will receive 400. Was a sweep done for non-dashboard call sites — runbooks under `ops/`, README snippets, integration test fixtures that bypass dashboard.js?
- **SPEC version semantics**: SPEC-007 jumped v0.4 → v0.5 for a breaking change. The spec corpus convention is v0.X for non-1.0 specs; is the break appropriate at this version level, or should it have waited for v1.0?
- **§5.6 / §6.4 prose drift**: re-read both sections end-to-end. Are there other paragraphs that still reference the v0.4 deprecation window (mentions of "v0.4 deprecation WARN", "v0.5 will reject", "in v0.4 untyped is accepted")? Stale forward-looking prose is a real ARCH finding.
- **Cross-spec references**: do any sibling specs (SPEC-005 billing, SPEC-002 coordinator, SPEC-006 buyer API) reference the explorer's `/admin/explorer/sessions/{id}` path shape? If so, do they say "bare id" or "typed prefix"? Drift here is a MEDIUM.
- **Audit-events schema**: the v0.4 `payout_explorer_path_segment_untyped` event_type is no longer emitted. Does it warrant a SPEC-level "deprecated event_type" registry entry, OR can it be silently dropped because v0.4 was the only place that emitted it?
- **Dashboard contract**: dashboard.js linkFor now hard-codes the `int_` prefix. This couples the static JS asset to the SPEC-007 v0.5 typing rule. Is the coupling explicit (comment pointing at SPEC §5.6) or implicit?
- **Audit-prompt convention**: per [[feedback-audit-prompts-file-not-chat]] the audit prompt files MUST stay versioned in `specs/`. Verify this PR includes `specs/AUDIT_ISS245_*_PROMPT.md` so future v0.X bumps can copy-tweak.

## Specific must-check

1. The v0.4 change-log entry contained a paragraph: "**v0.5 (tracked at #245) will reject untyped with `400 session_id_untyped`.**" Does the v0.5 change-log explicitly close that commitment (says "closes the v0.4 deprecation window per the v0.4 §5.6 + §6.4 commitments")?
2. SPEC-007-explorer-design.md — does it have any path-segment-overload prose that needs to update in lock-step?
3. The issue #245 body listed 3 trigger conditions. None of telemetry-quiet (14d) or 90-day cutoff are met. The dashboard.js change IS the operator-UI cutover. Should the PR body note this explicitly so future archaeologists understand the override?

## Out of scope

- Style nits (CODE lane)
- Specific bypass / injection (SECURITY lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk / Concern: <why, at architectural layer>
Recommendation: <concrete fix or "defer to follow-up">
```

End summary: `C/H/M/L/INFO = a/b/c/d/e`. If 0 C/H/M: `ACCEPT — 0 C/H/M`.
