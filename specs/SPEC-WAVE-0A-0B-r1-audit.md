# SPEC-WAVE-0A-0B r1 audit

Date: 2026-06-30

Artifacts:
- Code: `.omc/artifacts/ask/codex-audit-spec-wave-0a-0b-code-lane-you-are-auditing-the-current-2026-06-30T17-02-18-354Z.md`
- Security: `.omc/artifacts/ask/codex-audit-spec-wave-0a-0b-security-lane-you-are-auditing-the-cur-2026-06-30T17-03-00-935Z.md`
- Architect: `.omc/artifacts/ask/codex-audit-spec-wave-0a-0b-architect-lane-you-are-auditing-the-cu-2026-06-30T17-01-22-575Z.md`

Verdict:
- Code: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW.
- Architect: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 2 LOW.
- Security: 0 CRITICAL / 0 HIGH / 2 MEDIUM / 0 LOW.

Security findings:
- MEDIUM: valid streaming usage could severely under-report emitted output and settle `provider_reported`.
- MEDIUM: coordinator normalization stripped any namespace before `/`, allowing unknown namespaces such as `other/qwen3-32b-4bit` to match known model keys before `default`.

Fixes applied after r1:
- Added a narrow gateway fallback for implausible provider under-reports.
- Restricted coordinator namespace stripping to the requested known namespaces.
- Added unknown-namespace rate-card regression coverage.

Accepted LOWs:
- Architect LOW: new `rate_card_normalized` hot-path log shape is intentional audit visibility.
- Architect LOW: gateway hard-byte-ceiling warning message changed from the old soft-cap warning.
