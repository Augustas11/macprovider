# SPEC-WAVE-0A-0B r3 audit

Date: 2026-06-30

Artifacts:
- Security: `.omc/artifacts/ask/codex-audit-spec-wave-0a-0b-security-lane-you-are-auditing-the-cur-2026-06-30T17-14-07-977Z.md`

Skipped lanes:
- Code accepted in r1.
- Architect accepted in r1 with LOWs documented.

Verdict:
- Security: 0 CRITICAL / 1 HIGH / 0 MEDIUM / 1 LOW.

Security finding:
- HIGH: over-`max_tokens` provider usage handling only ran when `outcome == "ok"`, leaving truncated/client-disconnect reported-usage paths able to settle over-max usage without the spoof guard.
- LOW: rate-card normalization log shape is not pinned by tests.

Fixes applied after r3:
- Made over-`max_tokens` handling outcome-independent inside `settleReported`.
- Added truncated and buyer-disconnect over-max spoof regression tests.

Accepted LOWs:
- Rate-card normalization log shape is present in code and documented; selection behavior is pinned by tests.
