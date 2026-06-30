# SPEC-WAVE-0A-0B r2 audit

Date: 2026-06-30

Artifacts:
- Security: `.omc/artifacts/ask/codex-audit-spec-wave-0a-0b-security-lane-you-are-auditing-the-cur-2026-06-30T17-08-54-821Z.md`

Skipped lanes:
- Code accepted in r1.
- Architect accepted in r1 with LOWs documented.

Verdict:
- Security: 0 CRITICAL / 2 HIGH / 1 MEDIUM / 1 LOW.

Security findings:
- HIGH: streaming `usage.completion_tokens > max_tokens` could settle above buyer max because streaming bypassed the parser's independent completion cap and storage only enforced the broader prompt-headroom total cap.
- HIGH: implausible-underreport fallback allowed large underreports where `reported` stayed above the 25% ratio floor.
- MEDIUM: canonical `meta-llama/Llama-...-4bit` normalized to `llama-...`, missing `meta-llama/llama-...` rate-card keys.
- LOW: gateway hard-cap warning message changed.

Fixes applied after r2:
- Required emitted output to substantiate provider-reported over-`max_tokens` usage before settling above max.
- Tightened severe-underreport fallback to catch large gaps above a 1.5x observed/reported ratio while preserving the Llama 93-vs-69 production case.
- Preserved canonical `meta-llama/` namespace during normalization and added coverage.
