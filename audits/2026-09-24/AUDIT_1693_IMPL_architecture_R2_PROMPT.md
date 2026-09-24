# #1693 implementation audit — architecture lane (MONEY PATH)

Method constraint: first-party software-correctness / proof review. Do NOT author or construct malformed payloads
or exploit inputs. Evaluate by reading source and, if useful, running EXISTING tests. Describe gaps abstractly
(component + condition + consequence) in prose. Do NOT modify any file in the worktree.

Scope: the FULL diff `git diff origin/main...HEAD` in the current directory (branch feat/1693-pricing-content-lane,
7 commits, 86 files: specs, coordinator Go, gateway test, catalog-release.py + tests, content lane + activate lib +
harnesses, recovery helper + systemd units, deploy script, writer guard across updater/watchdog/tier2 scripts,
payout runbook). Issue #1693: reviewed pricing corrections (signed rate-card rows) activate through the catalog-content
lane without a new runtime binary, keeping SPEC-005 MoneyTable-A parity before, during, after and on rollback.

ARCHITECTURE lane: does the implementation match the approved plan v20 (posted at https://github.com/Augustas11/macprovider/issues/1693#issuecomment-5800624020; normative summary in this diff's SPEC-005 R013 and SPEC-023 R018) and the amended specs; single source of truth; lock order and ownership across coordinator, lane, deploy, updater, watchdog, renewal; crash-recovery completeness (journal phases, pre-start, closer, deploy-recover interplay); deploy/rollout ordering (enabling runtime cut, units installed, old tags); CONFORMANCE/spec consistency; unnecessary complexity.

Severity: CRITICAL/HIGH only for a concrete path to mis-billing, unreviewed pricing, security compromise, or
unrecoverable/unsafe state; MEDIUM for concrete evidenced correctness gaps; LOW for precision/wording. Attribute each
finding NEW (introduced by this diff) vs PRE-EXISTING (a PRE-EXISTING finding is at most MEDIUM unless this diff makes
it materially worse). Cite file:line for every finding with a concrete sequence and a required change.

Output: one block per finding `[SEVERITY] <id> <title>` + evidence + required change; final line exactly
`VERDICT: <APPROVE|APPROVE-WITH-CHANGES|REJECT> C=<n> H=<n> M=<n> L=<n>`

Round 2 (HEAD a4889920, 9 #1693 commits incl. runbook docs). Round-1 findings and dispositions: HIGH wholesale conflicting identities (fixed: independent resolution, fail closed); SEC-M1 ack digest vs Go-resolved names (fixed); SEC-M2 recovery lock validation (fixed); CODE-2 verified/finalize split + monotonic terminal phases (fixed); ARCH-002 missing runbook section §Pricing txn (added in docs/runbooks/catalog-release-decision-tree.md); ARCH-003 enabling rollout (runbook §Enabling rollout; release-train doc on main updated); ARCH-004 CONFORMANCE (updated). CARRIED, out of scope: SEC-M3 PRE-EXISTING deploy-pearl-vps.sh copying raw live yaml off-host for local validation (lines this diff does not change; tracked as a follow-up) — do not re-raise it unless this diff makes it worse. Independently verify each closure and hunt for NEW defects, including in the docs (esp. the hand procedure in §Deploy-and-pricing conflict). Do not anchor on round 1.
