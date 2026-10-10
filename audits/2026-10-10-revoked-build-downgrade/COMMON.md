# Revoked-build downgrade audit (round R{ROUND})

Repository: the current working directory (branch `cli/revoked-build-downgrade`).
Audit the complete diff `git diff origin/main...HEAD` (read every changed file in
full where needed, and the surrounding code the diff relies on). Do not edit
files. Do not run network commands.

## Change under audit

Goal: one rollback lever for the provider CLI auto-updater. The operator
recommends the previous good release P and exactly revokes the bad release V
in one Pearl edit. Macs running exactly-revoked V then auto-update DOWN to P
and serve again. No other downgrade is possible.

Required rules (fail closed). A downgrade is allowed only when ALL hold:
(a) the coordinator told this session that its own running build's
compatibility id is exactly revoked (new optional wire field
`compatibility_set_revoked` on `hello_ack` / accepted `auth_response`, omitted
otherwise, so older clients/coordinators see no change);
(b) the target equals the coordinator's recommended version for this session
and the recommended compatibility set;
(c) the target is a validly signed release from the expected repository that
passes every existing artifact verification with exactly the strength of an
upgrade;
(d) the target itself is not revoked.
The GitHub signed discovery rail and manual update never downgrade. The
pending-marker/rollback machinery keeps working; events are attributed with
`update_direction: downgrade_from_revoked`. Coordinator config keeps
`revoked_ids must not contain target_id` and does not enforce a monotonic
recommendation. Ops: `scripts/ops/cli-release.sh` gains a `rollback` step
(env `CLI_ROLLBACK_TO_ID`, `CLI_ROLLBACK_REVOKE_ID`) and
`scripts/ops/lib/pearl-cli-config.py` now allows `--recommend P --revoke
<current target>` in one edit. SPEC-020 v0.1.22 (new SPEC-020-R007) and
SPEC-002 v1.6.13 (R004) are amended; the runbook is
`docs/runbooks/provider-cli-release-verification.md` "Revoked-build rollback".

Key files: `phase3-binary/Sources/macprovider-cli/AutoUpdater.swift`
(`revokedBuildDowngradeDecision`, `handleCoordinatorRecommendation`,
`signedDiscoveryAllowsTarget`), `CoordinatorClient.swift`
(`validateCompatibilitySetAcceptance`, `acceptCoordinatorSession`,
`coordinatorRevocationNotice`), `CompatibilitySetManifest.swift`
(`compatibilitySetIDParts`), `phase4-coordinator/internal/ws/{messages,server}.go`,
the tests, the ops scripts and the specs.

## Output

List findings as `SEVERITY (CRITICAL/HIGH/MEDIUM/LOW/INFO) — file:line —
problem — concrete fix`. Mark whether each finding is NEW in this diff or
PRE-EXISTING. End with exactly one line:
`VERDICT: C=<n> H=<n> M=<n> L=<n>`.
