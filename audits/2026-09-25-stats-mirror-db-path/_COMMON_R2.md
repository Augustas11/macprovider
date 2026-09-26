# Codex audit: stats billing mirror reads the coordinator DB (#1748)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-mirror-dbpath`. Branch:
`fix/stats-mirror-coordinator-db`. Review `git diff 1148185e..ee061fc3` (c6c32692 plus the R1 fix ee061fc3), now on main.

## The change
- **What was wrong.** The full Pearl deploy (`phase4-coordinator/dist/deploy-pearl-vps.sh`)
  and `dist/stats-billing-mirror.service` pointed the stats billing mirror at
  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
  (`ledger_request_credits`) lives in `coordinator.db`, the configured
  `db_path` on Pearl.
- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
  deploy's initial mirror run failed with `no such table` and rolled back a
  catalog deploy.
- **The fix.** Replace the path with `/var/lib/macprovider/coordinator.db` in:
  - the unit (`ConditionPathExists`, `ExecStart`, the `ReadOnlyPaths` for the
    DB, WAL and SHM);
  - the deploy's ACL snapshot, ACL grant and start guard;
  - `billingmirror.DefaultSQLitePath`;
  - the flag help;
  - the wiring tests.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.

## Round 2
R1, all three lanes: one HIGH. `InaccessiblePaths=-/var/lib/macprovider/coordinator.db` hid the new source DB. `ee061fc3` removes that entry and adds a wiring assertion that the `--sqlite` source is never inaccessible. On Pearl, systemd-run with the fixed property set mirrors 6000 rows, and the old set fails with `unable to open database file`. Verify the fix and re-check the lane.
