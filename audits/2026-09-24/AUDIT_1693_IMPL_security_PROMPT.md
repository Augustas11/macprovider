# #1693 implementation audit — security lane (MONEY PATH)

Method constraint: first-party software-correctness / proof review. Do NOT author or construct malformed payloads
or exploit inputs. Evaluate by reading source and, if useful, running EXISTING tests. Describe gaps abstractly
(component + condition + consequence) in prose. Do NOT modify any file in the worktree.

Scope: the FULL diff `git diff origin/main...HEAD` in the current directory (branch feat/1693-pricing-content-lane,
7 commits, 86 files: specs, coordinator Go, gateway test, catalog-release.py + tests, content lane + activate lib +
harnesses, recovery helper + systemd units, deploy script, writer guard across updater/watchdog/tier2 scripts,
payout runbook). Issue #1693: reviewed pricing corrections (signed rate-card rows) activate through the catalog-content
lane without a new runtime binary, keeping SPEC-005 MoneyTable-A parity before, during, after and on rollback.

SECURITY lane: money-path integrity (any path to billing at an unreviewed or non-parity table, or re-pricing history), privilege/ownership of files installed or written on the host (modes, symlink/TOCTOU, O_NOFOLLOW, root vs service user), journal/lock tampering, injection via buyer-controlled model names (request_log) into shell/JSON/terminal, remote command construction over ssh, secrets exposure (live yaml bytes must never leave the host), fail-open vs fail-closed on every guard.

Severity: CRITICAL/HIGH only for a concrete path to mis-billing, unreviewed pricing, security compromise, or
unrecoverable/unsafe state; MEDIUM for concrete evidenced correctness gaps; LOW for precision/wording. Attribute each
finding NEW (introduced by this diff) vs PRE-EXISTING (a PRE-EXISTING finding is at most MEDIUM unless this diff makes
it materially worse). Cite file:line for every finding with a concrete sequence and a required change.

Output: one block per finding `[SEVERITY] <id> <title>` + evidence + required change; final line exactly
`VERDICT: <APPROVE|APPROVE-WITH-CHANGES|REJECT> C=<n> H=<n> M=<n> L=<n>`
