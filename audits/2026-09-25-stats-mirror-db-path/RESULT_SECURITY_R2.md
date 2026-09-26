# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-09-25T08:46:15.544Z

## Original task

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
## Lane: SECURITY / MONEY PATH

Check:
- `coordinator.db` holds money-path state. Granting the `macprovider-stats` user a read ACL on it: is that least privilege acceptable, is the database read-only in the sandbox, and does the rollback restore the ACLs exactly?
- Is there any write path to `coordinator.db` from the mirror?
- `InaccessiblePaths` still hides secrets.

## Final prompt

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
## Lane: SECURITY / MONEY PATH

Check:
- `coordinator.db` holds money-path state. Granting the `macprovider-stats` user a read ACL on it: is that least privilege acceptable, is the database read-only in the sandbox, and does the rollback restore the ACLs exactly?
- Is there any write path to `coordinator.db` from the mirror?
- `InaccessiblePaths` still hides secrets.

## Raw output

```text
Security/money-path lane: no findings.

- ACL is least-privilege at the SQLite boundary: `macprovider-stats` receives only `r--` on `coordinator.db` and `--x` on its directory ([deploy-pearl-vps.sh:3629-3637](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/deploy-pearl-vps.sh:3629)).
- The mirror cannot write the coordinator DB: systemd marks DB/WAL/SHM read-only ([service:23-25](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/stats-billing-mirror.service:23)), and Go opens SQLite with `mode=ro` and `query_only(true)` ([dsn.go:56-76](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/internal/sqliteutil/dsn.go:56)).
- Rollback snapshots and restores DB, WAL, SHM, and directory ACLs exactly via `getfacl`/`setfacl --restore` ([deploy-pearl-vps.sh:3139-3143](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/deploy-pearl-vps.sh:3139), [coordinator-deploy-recover.sh:135-144](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/coordinator-deploy-recover.sh:135)).
- Secrets remain inaccessible via `/etc/macprovider` and the coordinator config path; the source DB is no longer hidden ([service:26-27](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/stats-billing-mirror.service:26)).

Existing checks passed:

- `go test ./internal/stats/billingmirror`
- `check_stats_billing_mirror_deploy_test.sh`
- `check_deploy_static_feed_access.test.sh`
- `coordinator_deploy_recovery.test.sh`

VERDICT: PASS


OpenAI Codex v0.156.1
--------
workdir: /Users/augstar/macprovider-mirror-dbpath
model: gpt-5.6-luna
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 01a0d7bb-c4e3-7e11-b3ba-1aed20b0c1e6
--------
user
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
## Lane: SECURITY / MONEY PATH

Check:
- `coordinator.db` holds money-path state. Granting the `macprovider-stats` user a read ACL on it: is that least privilege acceptable, is the database read-only in the sandbox, and does the rollback restore the ACLs exactly?
- Is there any write path to `coordinator.db` from the mirror?
- `InaccessiblePaths` still hides secrets.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: failed to parse hooks config /Users/augstar/.codex/hooks.json: unknown field `state`, expected `description` or `hooks` at line 2 column 9
codex
I’ll verify the Round 2 security/money-path lane against the specified diff, the service/deploy wiring, and existing tests only. I’ll trace ACL/sandbox behavior and mirror write access, then run the narrowest existing checks and report only evidence-backed C/H/M findings.
exec
/bin/bash -lc "git status --short --branch && git diff --stat 1148185e..ee061fc3 && git diff -- 1148185e..ee061fc3 -- phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/internal/billingmirror phase4-coordinator 2>/dev/null | sed -n '1,260p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 52ms:
 phase4-coordinator/cmd/stats-billing-mirror/main.go  |  2 +-
 phase4-coordinator/dist/deploy-pearl-vps.sh          | 16 ++++++++--------
 phase4-coordinator/dist/stats-billing-mirror.service | 11 +++++------
 .../test/check_deploy_static_feed_access.test.sh     |  2 +-
 .../test/check_stats_billing_mirror_deploy_test.sh   | 20 ++++++++++++++------
 .../internal/stats/billingmirror/mirror.go           |  2 +-
 6 files changed, 30 insertions(+), 23 deletions(-)

exec
/bin/bash -lc 'git diff 1148185e..ee061fc3 -- phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/internal/stats/billingmirror/mirror.go phase4-coordinator/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
diff --git a/phase4-coordinator/cmd/stats-billing-mirror/main.go b/phase4-coordinator/cmd/stats-billing-mirror/main.go
index 210cdaa4e..47f95fabf 100644
--- a/phase4-coordinator/cmd/stats-billing-mirror/main.go
+++ b/phase4-coordinator/cmd/stats-billing-mirror/main.go
@@ -11,7 +11,7 @@ import (
 
 func main() {
 	var opts billingmirror.Options
-	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/request-log.sqlite")
+	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/coordinator.db")
 	flag.StringVar(&opts.PostgresDSN, "dsn", "", "Postgres DSN; defaults to STATS_BILLING_MIRROR_DSN")
 	flag.IntVar(&opts.BatchSize, "batch-size", billingmirror.DefaultBatchSize, "maximum request-credit rows to fetch per batch")
 	flag.Int64Var(&opts.OverlapRows, "overlap-rows", billingmirror.DefaultOverlapRows, "number of recent SQLite row IDs to re-read every run")
diff --git a/phase4-coordinator/dist/deploy-pearl-vps.sh b/phase4-coordinator/dist/deploy-pearl-vps.sh
index 3f00b577b..8bc28cb76 100755
--- a/phase4-coordinator/dist/deploy-pearl-vps.sh
+++ b/phase4-coordinator/dist/deploy-pearl-vps.sh
@@ -3138,9 +3138,9 @@ $SSH "set -e
 
   if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
     snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite request-log-db.acl had-request-log-db-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-wal request-log-wal.acl had-request-log-wal-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-shm request-log-shm.acl had-request-log-shm-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
   fi
   if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
     cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
@@ -3632,10 +3632,10 @@ $SSH "set -e
     # to a newly appeared, unsnapshotted file would make exact rollback
     # impossible.
     [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
-    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite
-    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-wal
-    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-shm
-  elif [ -f /var/lib/macprovider/request-log.sqlite ]; then
+    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
+    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
+    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
+  elif [ -f /var/lib/macprovider/coordinator.db ]; then
     echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
   fi
   # Stage the complete immutable catalog release. Activation happens only
@@ -4870,7 +4870,7 @@ $SSH 'set -e
   elif [ "$_parity_required" = absent ]; then
     echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
   fi
-  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ] && su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats; then
+  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
     systemctl enable --now stats-billing-mirror.timer
     if ! systemctl start stats-billing-mirror.service; then
       systemctl disable --now stats-billing-mirror.timer
diff --git a/phase4-coordinator/dist/stats-billing-mirror.service b/phase4-coordinator/dist/stats-billing-mirror.service
index 056cf4f47..9be817313 100644
--- a/phase4-coordinator/dist/stats-billing-mirror.service
+++ b/phase4-coordinator/dist/stats-billing-mirror.service
@@ -4,14 +4,14 @@ Documentation=https://github.com/augstar/macprovider-poc
 Wants=network-online.target
 After=network-online.target
 ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env
-ConditionPathExists=/var/lib/macprovider/request-log.sqlite
+ConditionPathExists=/var/lib/macprovider/coordinator.db
 
 [Service]
 Type=oneshot
 User=macprovider-stats
 Group=macprovider-stats
 EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env
-ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/request-log.sqlite --ensure-schema=false
+ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
 Nice=10
 IOSchedulingClass=best-effort
 IOSchedulingPriority=7
@@ -20,9 +20,8 @@ PrivateDevices=true
 PrivateTmp=true
 ProtectHome=true
 ProtectSystem=strict
-ReadOnlyPaths=/var/lib/macprovider/request-log.sqlite
-ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-wal
-ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-shm
+ReadOnlyPaths=/var/lib/macprovider/coordinator.db
+ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
+ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
 InaccessiblePaths=/etc/macprovider
 InaccessiblePaths=-/opt/macprovider/coordinator.yaml
-InaccessiblePaths=-/var/lib/macprovider/coordinator.db
diff --git a/phase4-coordinator/internal/stats/billingmirror/mirror.go b/phase4-coordinator/internal/stats/billingmirror/mirror.go
index 5cc0c9506..1caffe167 100644
--- a/phase4-coordinator/internal/stats/billingmirror/mirror.go
+++ b/phase4-coordinator/internal/stats/billingmirror/mirror.go
@@ -19,7 +19,7 @@ import (
 )
 
 const (
-	DefaultSQLitePath  = "/var/lib/macprovider/request-log.sqlite"
+	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
 	DefaultBatchSize   = 5000
 	DefaultOverlapRows = 1000
 	DefaultRunTimeout  = 25 * time.Second

exec
/bin/bash -lc "git diff --name-status 1148185e..ee061fc3 && git diff 1148185e..ee061fc3 -- phase4-coordinator/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/test/check_deploy_static_feed_access.test.sh test 2>/dev/null | sed -n '1,320p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
M	phase4-coordinator/cmd/stats-billing-mirror/main.go
M	phase4-coordinator/dist/deploy-pearl-vps.sh
M	phase4-coordinator/dist/stats-billing-mirror.service
M	phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
M	phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
M	phase4-coordinator/internal/stats/billingmirror/mirror.go

exec
/bin/bash -lc 'git diff 1148185e..ee061fc3 -- phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
diff --git a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
index 292e99c4..4ac03a77 100755
--- a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
+++ b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
@@ -148,7 +148,7 @@ for marker in had-nginx-stats-shared had-nginx-stats-security-headers \
     fail "nginx rollback coverage missing for $marker"
 done
 
-grep -q 'snapshot_acl /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" &&
+grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
   grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
   fail "request-log ACL changes must be captured and restored"
 
diff --git a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
index 9a2075ab..9ae1b63e 100755
--- a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
+++ b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
@@ -41,17 +41,17 @@ grep -qF '$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/
   fail "deploy script missing billing mirror timer upload"
 grep -qF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror binary install"
-grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" ||
+grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
   fail "deploy script must grant narrow SQLite file ACL"
 grep -qF "echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'" "$DEPLOY_SH" ||
   fail "deploy script must keep setfacl warning single-quoted inside SSH install block"
-grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats' "$DEPLOY_SH" ||
+grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
   fail "deploy script must only enable mirror when stats user can read sqlite source"
 grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror service install"
 grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer' "$DEPLOY_SH" ||
   fail "deploy script missing billing mirror timer install"
-grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ]' "$DEPLOY_SH" ||
+grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
   fail "deploy script must only enable timer when env and SQLite source exist"
 grep -qF 'systemctl disable --now stats-billing-mirror.timer' "$DEPLOY_SH" ||
   fail "deploy script must disable the billing mirror timer after a failed initial run"
@@ -64,14 +64,22 @@ grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
   fail "billing mirror must run with dedicated stats group"
 grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
   fail "billing mirror service must be opt-in on env file"
-grep -qxF 'ConditionPathExists=/var/lib/macprovider/request-log.sqlite' "$SERVICE" ||
+grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
   fail "billing mirror service must require the SQLite source"
 grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
   fail "billing mirror service must read isolated env file"
-grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/request-log.sqlite --ensure-schema=false' "$SERVICE" ||
+grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
   fail "billing mirror service must execute from deploy path"
-grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/request-log.sqlite' "$SERVICE" ||
+grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
   fail "billing mirror service must read only the SQLite source"
+# The mirror's source DB must never also be inaccessible: systemd applies
+# InaccessiblePaths over ReadOnlyPaths, which hid the ledger and failed the
+# deploy's initial mirror run.
+source_db=$(sed -n 's/^ExecStart=.* --sqlite \([^ ]*\) .*/\1/p' "$SERVICE")
+[ -n "$source_db" ] || fail "stats billing mirror ExecStart must name its --sqlite source"
+if grep -qE "^InaccessiblePaths=-?${source_db}(-wal|-shm)?$" "$SERVICE"; then
+  fail "stats billing mirror source DB $source_db must not be listed in InaccessiblePaths"
+fi
 grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||
   fail "billing mirror service must not access coordinator secrets"
 grep -qxF 'OnUnitActiveSec=60s' "$TIMER" ||

codex
The R1 diff removes the conflicting `InaccessiblePaths` entry and adds a test that derives the `--sqlite` source from `ExecStart` and rejects any matching inaccessible rule. I’m now checking whether the mirror implementation can mutate the coordinator DB, and whether deploy rollback snapshots/restores the exact ACL state for the DB plus WAL/SHM lifecycle.
exec
/bin/bash -lc "rg -n \"func (snapshot_acl|restore_acl)|snapshot_acl|restore_acl|had-request-log|macprovider-stats|coordinator\\.db(-wal|-shm)?\" phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '1,240p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
1950:  getent group macprovider-stats >/dev/null 2>&1 || groupadd --system macprovider-stats
1951:  id macprovider-stats >/dev/null 2>&1 || useradd --system --gid macprovider-stats --home /nonexistent --shell /usr/sbin/nologin macprovider-stats
1960:  install -d -o root -g macprovider-stats -m 0750 /opt/macprovider-stats
1965:  install -d -o root -g macprovider-stats -m 0750 /etc/macprovider-stats
1980:  if [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ]; then
1981:    chown root:macprovider-stats /etc/macprovider-stats/stats-hardware-inventory.yaml
1982:    chmod 0640 /etc/macprovider-stats/stats-hardware-inventory.yaml
1983:    echo "  enforced stats hardware inventory perms: root:macprovider-stats 0640"
1985:    echo "  /etc/macprovider-stats/stats-hardware-inventory.yaml not yet present; stats inventory timer remains opt-in"
1987:  if [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
1988:    chown root:root /etc/macprovider-stats/stats-inventory-sync.env
1989:    chmod 0600 /etc/macprovider-stats/stats-inventory-sync.env
1992:    echo "  /etc/macprovider-stats/stats-inventory-sync.env not yet present; stats inventory timer remains opt-in"
1994:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ]; then
1995:    chown root:root /etc/macprovider-stats/stats-billing-mirror.env
1996:    chmod 0600 /etc/macprovider-stats/stats-billing-mirror.env
1999:    echo "  /etc/macprovider-stats/stats-billing-mirror.env not yet present; stats billing mirror timer remains opt-in"
2001:  if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
2002:    chown root:root /etc/macprovider-stats/stats-hardware-verifier.env
2003:    chmod 0600 /etc/macprovider-stats/stats-hardware-verifier.env
2006:    echo "  /etc/macprovider-stats/stats-hardware-verifier.env not yet present; stats hardware verifier timer remains opt-in"
2474:    verifier_env=/etc/macprovider-stats/stats-hardware-verifier.env
2487:      echo "  Provision /etc/macprovider-stats/stats-hardware-verifier.env before deploying." >&2
2612:    inventory_yaml=/etc/macprovider-stats/stats-hardware-inventory.yaml
2613:    inventory_env=/etc/macprovider-stats/stats-inventory-sync.env
3071:  snapshot_acl() {
3093:  snapshot_node /opt/macprovider-stats/stats-inventory-sync stats-inventory-sync had-stats-inventory-binary
3094:  snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
3095:  snapshot_node /opt/macprovider-stats/stats-hardware-verifier stats-hardware-verifier had-stats-hardware-binary
3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
3559:  # to this binary; its Postgres writer DSN lives under /etc/macprovider-stats.
3568:    if [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
3569:       ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
3576:  elif [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
3577:       ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
3581:  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync
3583:  # dedicated macprovider-stats identity and gets read access only to the
3585:  if [ ! -x /opt/macprovider-stats/stats-billing-mirror ] ||
3586:     ! cmp -s $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror; then
3590:  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
3593:  if [ ! -x /opt/macprovider-stats/stats-hardware-verifier ] ||
3594:     ! cmp -s $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier; then
3598:  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier
3629:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
3634:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
4768:  STATS_HEADERS="$(mktemp -t macprovider-stats-headers.XXXXXX)"
4855:  if [ "$_parity_required" = absent ] && [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ] && [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
4871:    echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
4886:    echo "stats billing mirror timer not enabled: missing env/sqlite source or macprovider-stats read ACL"
4888:  if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
4915:    echo "stats hardware verifier timer not enabled: missing /etc/macprovider-stats/stats-hardware-verifier.env"

exec
/bin/bash -lc "sed -n '1,280p' phase4-coordinator/internal/stats/billingmirror/mirror.go && rg -n \"(sqlite|coordinator\\.db|request-log|setfacl|snapshot_acl|restore_acl|InaccessiblePaths|ReadOnlyPaths|stats-billing-mirror)\" phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/internal/stats/billingmirror phase4-coordinator/cmd/stats-billing-mirror" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
package billingmirror

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "github.com/lib/pq"
	_ "modernc.org/sqlite"
)

const (
	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
	DefaultBatchSize   = 5000
	DefaultOverlapRows = 1000
	DefaultRunTimeout  = 25 * time.Second

	StateSource = "sqlite-ledger-request-credits"
)

type Options struct {
	SQLitePath   string
	PostgresDSN  string
	BatchSize    int
	OverlapRows  int64
	SweepRows    int
	MaxBatches   int
	EnsureSchema bool
	DryRun       bool
	Stdout       io.Writer
}

type Result struct {
	RequestRowsRead     int
	RequestRowsUpserted int
	ProviderRowsRead    int
	ProviderRowsEnsured int
	LastRequestID       int64
	SweepAfterID        int64
	SourceMaxID         int64
	PendingRequestRows  int64
	DryRun              bool
}

type RequestCredit struct {
	SQLiteID                     int64
	RequestID                    string
	AttemptN                     int
	ProviderID                   string
	TSUTC                        time.Time
	CreatedAtUTC                 time.Time
	UpdatedAtUTC                 sql.NullTime
	PromptTokens                 sql.NullInt64
	CompletionTokens             sql.NullInt64
	EstimatedCompletionTokens    sql.NullInt64
	UsageSource                  string
	ProviderCredits              int64
	FaultFlag                    string
	Quarantined                  bool
	SettlementPolicyMode         string
	Spec022Verified              bool
	RequestedPrivacyMode         string
	EffectivePrivacyOutcome      string
	PositiveVerificationExcluded bool
	RewardsExcluded              bool
}

type ProviderIdentity struct {
	ProviderID   string
	ProviderName string
	CreatedAt    time.Time
	LastUsedAt   sql.NullTime
}

type State struct {
	LastRequestID int64
	SweepAfterID  int64
}

func Run(parent context.Context, opts Options) (Result, error) {
	opts = normalizeOptions(opts)
	out := opts.Stdout
	if out == nil {
		out = io.Discard
	}
	if opts.SQLitePath == "" {
		return Result{}, errors.New("sqlite path is required")
	}
	if opts.PostgresDSN == "" && !opts.DryRun {
		return Result{}, errors.New("postgres dsn is required")
	}

	ctx, cancel := context.WithTimeout(parent, DefaultRunTimeout)
	defer cancel()

	source, err := OpenSQLite(opts.SQLitePath)
	if err != nil {
		return Result{}, err
	}
	defer source.Close()

	var pg *sql.DB
	var state State
	if !opts.DryRun {
		pg, err = OpenPostgres(opts.PostgresDSN)
		if err != nil {
			return Result{}, err
		}
		defer pg.Close()
		if opts.EnsureSchema {
			if err := EnsureSchema(ctx, pg); err != nil {
				return Result{}, err
			}
		}
		state, err = LoadState(ctx, pg)
		if err != nil {
			return Result{}, err
		}
	}

	maxSourceID, err := FetchMaxRequestCreditID(ctx, source)
	if err != nil {
		return Result{}, err
	}
	newRows := make([]RequestCredit, 0, opts.BatchSize)
	newCursor := state.LastRequestID
	for batch := 0; batch < opts.MaxBatches; batch++ {
		batchRows, err := FetchRequestCredits(ctx, source, newCursor, opts.BatchSize)
		if err != nil {
			return Result{}, err
		}
		if len(batchRows) == 0 {
			break
		}
		newRows = append(newRows, batchRows...)
		newCursor = maxSQLiteID(batchRows, newCursor)
		if len(batchRows) < opts.BatchSize {
			break
		}
	}
	nextLastRequestID := maxSQLiteID(newRows, state.LastRequestID)
	rows := newRows
	if state.LastRequestID > 0 && opts.OverlapRows > 0 {
		startID := state.LastRequestID - opts.OverlapRows
		if startID < 0 {
			startID = 0
		}
		overlapRows, err := FetchRequestCreditsThrough(ctx, source, startID, state.LastRequestID, minInt(opts.BatchSize, int(opts.OverlapRows)))
		if err != nil {
			return Result{}, err
		}
		rows = mergeRequestCredits(overlapRows, rows)
	}
	nextSweepAfterID := state.SweepAfterID
	if opts.SweepRows > 0 && maxSourceID > 0 {
		sweepStart := state.SweepAfterID
		if sweepStart >= maxSourceID {
			sweepStart = 0
		}
		sweepRows, err := FetchRequestCreditsThrough(ctx, source, sweepStart, maxSourceID, opts.SweepRows)
		if err != nil {
			return Result{}, err
		}
		rows = mergeRequestCredits(rows, sweepRows)
		nextSweepAfterID = maxSQLiteID(sweepRows, sweepStart)
		if nextSweepAfterID >= maxSourceID {
			nextSweepAfterID = 0
		}
	}
	providers, err := FetchProviderIdentities(ctx, source)
	if err != nil {
		return Result{}, err
	}
	result := Result{
		RequestRowsRead:  len(rows),
		ProviderRowsRead: len(providers),
		DryRun:           opts.DryRun,
		LastRequestID:    nextLastRequestID,
		SweepAfterID:     nextSweepAfterID,
		SourceMaxID:      maxSourceID,
	}
	if maxSourceID > result.LastRequestID {
		result.PendingRequestRows = maxSourceID - result.LastRequestID
	}
	if opts.DryRun {
		fmt.Fprintf(out, "would upsert %d request credit rows and ensure %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsRead, result.ProviderRowsRead, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
		return result, nil
	}

	if err := Apply(ctx, pg, rows, providers, State{LastRequestID: result.LastRequestID, SweepAfterID: result.SweepAfterID}); err != nil {
		return Result{}, err
	}
	result.RequestRowsUpserted = len(rows)
	result.ProviderRowsEnsured = len(providers)
	fmt.Fprintf(out, "upserted %d request credit rows and ensured %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsUpserted, result.ProviderRowsEnsured, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
	return result, nil
}

func normalizeOptions(opts Options) Options {
	opts.SQLitePath = strings.TrimSpace(opts.SQLitePath)
	if opts.SQLitePath == "" {
		opts.SQLitePath = strings.TrimSpace(os.Getenv("STATS_BILLING_MIRROR_SQLITE"))
	}
	if opts.SQLitePath == "" {
		opts.SQLitePath = DefaultSQLitePath
	}
	opts.PostgresDSN = strings.TrimSpace(opts.PostgresDSN)
	if opts.PostgresDSN == "" {
		opts.PostgresDSN = strings.TrimSpace(os.Getenv("STATS_BILLING_MIRROR_DSN"))
	}
	if opts.BatchSize <= 0 {
		opts.BatchSize = DefaultBatchSize
	}
	if opts.BatchSize > 50000 {
		opts.BatchSize = 50000
	}
	if opts.MaxBatches <= 0 {
		opts.MaxBatches = 5
	}
	if opts.MaxBatches > 20 {
		opts.MaxBatches = 20
	}
	if opts.OverlapRows < 0 {
		opts.OverlapRows = 0
	}
	if opts.OverlapRows == 0 {
		opts.OverlapRows = DefaultOverlapRows
	}
	if opts.OverlapRows > int64(opts.BatchSize) {
		opts.OverlapRows = int64(opts.BatchSize)
	}
	if opts.SweepRows < 0 {
		opts.SweepRows = 0
	}
	if opts.SweepRows == 0 {
		opts.SweepRows = opts.BatchSize
	}
	if opts.SweepRows > opts.BatchSize {
		opts.SweepRows = opts.BatchSize
	}
	return opts
}

func OpenSQLite(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	return db, nil
}

func OpenPostgres(dsn string) (*sql.DB, error) {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(time.Minute)
	return db, nil
}

func FetchRequestCredits(ctx context.Context, db *sql.DB, startID int64, limit int) ([]RequestCredit, error) {
	caps, err := detectRequestCreditSourceCapabilities(ctx, db)
	if err != nil {
		return nil, err
	}
	return scanRequestCredits(ctx, db, requestCreditsQuery(caps, false), startID, limit)
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:10:SERVICE="$DIST_DIR/stats-billing-mirror.service"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:11:TIMER="$DIST_DIR/stats-billing-mirror.timer"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:12:ENV_EXAMPLE="$DIST_DIR/stats-billing-mirror.env.example"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:13:BOOTSTRAP_SQL="$DIST_DIR/stats-billing-mirror-bootstrap.sql"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:26:grep -qF 'STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:28:grep -qF 'STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:30:grep -qF 'STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:32:grep -qF '$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:38:grep -qF '$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:40:grep -qF '$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:42:grep -qF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:44:grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:46:grep -qF "echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'" "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:47:  fail "deploy script must keep setfacl warning single-quoted inside SSH install block"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:48:grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:49:  fail "deploy script must only enable mirror when stats user can read sqlite source"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:50:grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:52:grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:54:grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:56:grep -qF 'systemctl disable --now stats-billing-mirror.timer' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:58:grep -qF 'aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:65:grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:67:grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:69:grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:71:grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:76:# InaccessiblePaths over ReadOnlyPaths, which hid the ledger and failed the
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:78:source_db=$(sed -n 's/^ExecStart=.* --sqlite \([^ ]*\) .*/\1/p' "$SERVICE")
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:79:[ -n "$source_db" ] || fail "stats billing mirror ExecStart must name its --sqlite source"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:80:if grep -qE "^InaccessiblePaths=-?${source_db}(-wal|-shm)?$" "$SERVICE"; then
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:81:  fail "stats billing mirror source DB $source_db must not be listed in InaccessiblePaths"
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:83:grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:143:    "p_sqlite_lrc_id", "p_request_id", "p_attempt_n", "p_provider_id",
phase4-coordinator/dist/stats-billing-mirror.service:6:ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/dist/stats-billing-mirror.service:7:ConditionPathExists=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:13:EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/dist/stats-billing-mirror.service:14:ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
phase4-coordinator/dist/stats-billing-mirror.service:23:ReadOnlyPaths=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:24:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/stats-billing-mirror.service:25:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/stats-billing-mirror.service:26:InaccessiblePaths=/etc/macprovider
phase4-coordinator/dist/stats-billing-mirror.service:27:InaccessiblePaths=-/opt/macprovider/coordinator.yaml
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:151:grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:152:  grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:153:  fail "request-log ACL changes must be captured and restored"
phase4-coordinator/dist/deploy-pearl-vps.sh:629:STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh:640:STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"
phase4-coordinator/dist/deploy-pearl-vps.sh:641:STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh:1994:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:1995:    chown root:root /etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/dist/deploy-pearl-vps.sh:1996:    chmod 0600 /etc/macprovider-stats/stats-billing-mirror.env
phase4-coordinator/dist/deploy-pearl-vps.sh:1999:    echo "  /etc/macprovider-stats/stats-billing-mirror.env not yet present; stats billing mirror timer remains opt-in"
phase4-coordinator/dist/deploy-pearl-vps.sh:3036:# nginx files, request-log ACLs, config, and catalog pointers.
phase4-coordinator/dist/deploy-pearl-vps.sh:3071:  snapshot_acl() {
phase4-coordinator/dist/deploy-pearl-vps.sh:3094:  snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
phase4-coordinator/dist/deploy-pearl-vps.sh:3114:  snapshot_node /etc/systemd/system/stats-billing-mirror.service stats-billing-mirror.service had-stats-billing-service
phase4-coordinator/dist/deploy-pearl-vps.sh:3115:  snapshot_node /etc/systemd/system/stats-billing-mirror.timer stats-billing-mirror.timer had-stats-billing-timer
phase4-coordinator/dist/deploy-pearl-vps.sh:3119:  snapshot_node /etc/systemd/system/timers.target.wants/stats-billing-mirror.timer stats-billing-mirror.wants had-stats-billing-wants
phase4-coordinator/dist/deploy-pearl-vps.sh:3123:  snapshot_active stats-billing-mirror.timer stats-billing-timer-was-active
phase4-coordinator/dist/deploy-pearl-vps.sh:3124:  snapshot_active stats-billing-mirror.service stats-billing-service-was-active
phase4-coordinator/dist/deploy-pearl-vps.sh:3139:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3197:  for unit in stats-billing-mirror.timer stats-billing-mirror.service stats-hardware-verifier.timer stats-hardware-verifier.service; do
phase4-coordinator/dist/deploy-pearl-vps.sh:3241:_append_deploy_input_digest "$STATS_BILLING_MIRROR_BINARY" "stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh:3259:  "$STATS_BILLING_MIRROR_SERVICE=stats-billing-mirror.service" \
phase4-coordinator/dist/deploy-pearl-vps.sh:3260:  "$STATS_BILLING_MIRROR_TIMER=stats-billing-mirror.timer" \
phase4-coordinator/dist/deploy-pearl-vps.sh:3299:$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"
phase4-coordinator/dist/deploy-pearl-vps.sh:3318:$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"
phase4-coordinator/dist/deploy-pearl-vps.sh:3319:$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"
phase4-coordinator/dist/deploy-pearl-vps.sh:3582:  # stats-billing-mirror is an out-of-band stats sidecar. It runs as the
phase4-coordinator/dist/deploy-pearl-vps.sh:3585:  if [ ! -x /opt/macprovider-stats/stats-billing-mirror ] ||
phase4-coordinator/dist/deploy-pearl-vps.sh:3586:     ! cmp -s $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3587:    echo "refusing stats-billing-mirror replacement from direct deploy: install the signed matching stats sidecar release first" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:3590:  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
phase4-coordinator/dist/deploy-pearl-vps.sh:3625:  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
phase4-coordinator/dist/deploy-pearl-vps.sh:3626:  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:3629:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3634:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3639:    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
phase4-coordinator/dist/deploy-pearl-vps.sh:4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4874:    systemctl enable --now stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:4875:    if ! systemctl start stats-billing-mirror.service; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4876:      systemctl disable --now stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:4877:      echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh:4878:      journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
phase4-coordinator/dist/deploy-pearl-vps.sh:4881:    systemctl is-active stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:4883:    systemctl start stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:4884:    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
phase4-coordinator/dist/deploy-pearl-vps.sh:4886:    echo "stats billing mirror timer not enabled: missing env/sqlite source or macprovider-stats read ACL"
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:12:	_ "modernc.org/sqlite"
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:196:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:197:	db, err := sql.Open("sqlite", path)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:199:		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:202:		t.Fatalf("seed sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:205:		t.Fatalf("close sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:246:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:247:	db, err := sql.Open("sqlite", path)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:249:		t.Fatalf("open sqlite seed db: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:297:		t.Fatalf("seed sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:300:		t.Fatalf("close sqlite seed db: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:303:		t.Fatalf("stat seed sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:310:	path := filepath.Join(t.TempDir(), "legacy-request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:311:	db, err := sql.Open("sqlite", path)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:313:		t.Fatalf("open legacy sqlite seed db: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:342:		t.Fatalf("seed legacy sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:345:		t.Fatalf("close legacy sqlite seed db: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:348:		t.Fatalf("stat legacy seed sqlite: %v", err)
phase4-coordinator/cmd/stats-billing-mirror/main.go:14:	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/coordinator.db")
phase4-coordinator/cmd/stats-billing-mirror/main.go:26:		fmt.Fprintf(os.Stderr, "stats-billing-mirror: %v\n", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:16:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/stats/billingmirror/mirror.go:18:	_ "modernc.org/sqlite"
phase4-coordinator/internal/stats/billingmirror/mirror.go:22:	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
phase4-coordinator/internal/stats/billingmirror/mirror.go:27:	StateSource = "sqlite-ledger-request-credits"
phase4-coordinator/internal/stats/billingmirror/mirror.go:96:		return Result{}, errors.New("sqlite path is required")
phase4-coordinator/internal/stats/billingmirror/mirror.go:254:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
phase4-coordinator/internal/stats/billingmirror/mirror.go:256:		return nil, fmt.Errorf("open sqlite: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:312:	hasPolicy, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "settlement_policy_mode")
phase4-coordinator/internal/stats/billingmirror/mirror.go:316:	hasPayable, err := sqliteObjectExists(ctx, db, "spec022_payable_request_credits")
phase4-coordinator/internal/stats/billingmirror/mirror.go:320:	hasRequestedPrivacyMode, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "requested_privacy_mode")
phase4-coordinator/internal/stats/billingmirror/mirror.go:324:	hasEffectivePrivacyOutcome, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "effective_privacy_outcome")
phase4-coordinator/internal/stats/billingmirror/mirror.go:328:	hasPositiveVerificationExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "positive_verification_excluded")
phase4-coordinator/internal/stats/billingmirror/mirror.go:332:	hasRewardsExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "rewards_excluded")
phase4-coordinator/internal/stats/billingmirror/mirror.go:393:func sqliteColumnExists(ctx context.Context, db *sql.DB, table, column string) (bool, error) {
phase4-coordinator/internal/stats/billingmirror/mirror.go:396:		return false, fmt.Errorf("inspect sqlite table %s: %w", table, err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:415:func sqliteObjectExists(ctx context.Context, db *sql.DB, name string) (bool, error) {
phase4-coordinator/internal/stats/billingmirror/mirror.go:419:            SELECT 1 FROM sqlite_master
phase4-coordinator/internal/stats/billingmirror/mirror.go:647:	sum := sha256.Sum256([]byte("stats-billing-mirror\x00" + providerID))
phase4-coordinator/internal/stats/billingmirror/mirror.go:700:    sqlite_lrc_id BIGINT,
phase4-coordinator/internal/stats/billingmirror/mirror.go:721:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS sqlite_lrc_id BIGINT`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:786:    sqlite_lrc_id BIGINT,
phase4-coordinator/internal/stats/billingmirror/mirror.go:869:    p_sqlite_lrc_id BIGINT,
phase4-coordinator/internal/stats/billingmirror/mirror.go:919:        sqlite_lrc_id, request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
phase4-coordinator/internal/stats/billingmirror/mirror.go:924:        p_sqlite_lrc_id, p_request_id, p_attempt_n, p_provider_id, p_ts_utc, p_created_at_utc, p_updated_at_utc,
phase4-coordinator/internal/stats/billingmirror/mirror.go:931:        sqlite_lrc_id = EXCLUDED.sqlite_lrc_id,
phase4-coordinator/internal/stats/billingmirror/mirror.go:951:            request_id, attempt_n, provider_id, sqlite_lrc_id,
phase4-coordinator/internal/stats/billingmirror/mirror.go:954:            p_request_id, p_attempt_n, p_provider_id, p_sqlite_lrc_id,

exec
/bin/bash -lc "git show 1148185e:phase4-coordinator/dist/deploy-pearl-vps.sh | rg -n \"snapshot_acl|restore_acl|request-log\\.sqlite|coordinator\\.db|macprovider-stats\" | sed -n '1,260p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
1950:  getent group macprovider-stats >/dev/null 2>&1 || groupadd --system macprovider-stats
1951:  id macprovider-stats >/dev/null 2>&1 || useradd --system --gid macprovider-stats --home /nonexistent --shell /usr/sbin/nologin macprovider-stats
1960:  install -d -o root -g macprovider-stats -m 0750 /opt/macprovider-stats
1965:  install -d -o root -g macprovider-stats -m 0750 /etc/macprovider-stats
1980:  if [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ]; then
1981:    chown root:macprovider-stats /etc/macprovider-stats/stats-hardware-inventory.yaml
1982:    chmod 0640 /etc/macprovider-stats/stats-hardware-inventory.yaml
1983:    echo "  enforced stats hardware inventory perms: root:macprovider-stats 0640"
1985:    echo "  /etc/macprovider-stats/stats-hardware-inventory.yaml not yet present; stats inventory timer remains opt-in"
1987:  if [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
1988:    chown root:root /etc/macprovider-stats/stats-inventory-sync.env
1989:    chmod 0600 /etc/macprovider-stats/stats-inventory-sync.env
1992:    echo "  /etc/macprovider-stats/stats-inventory-sync.env not yet present; stats inventory timer remains opt-in"
1994:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ]; then
1995:    chown root:root /etc/macprovider-stats/stats-billing-mirror.env
1996:    chmod 0600 /etc/macprovider-stats/stats-billing-mirror.env
1999:    echo "  /etc/macprovider-stats/stats-billing-mirror.env not yet present; stats billing mirror timer remains opt-in"
2001:  if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
2002:    chown root:root /etc/macprovider-stats/stats-hardware-verifier.env
2003:    chmod 0600 /etc/macprovider-stats/stats-hardware-verifier.env
2006:    echo "  /etc/macprovider-stats/stats-hardware-verifier.env not yet present; stats hardware verifier timer remains opt-in"
2474:    verifier_env=/etc/macprovider-stats/stats-hardware-verifier.env
2487:      echo "  Provision /etc/macprovider-stats/stats-hardware-verifier.env before deploying." >&2
2612:    inventory_yaml=/etc/macprovider-stats/stats-hardware-inventory.yaml
2613:    inventory_env=/etc/macprovider-stats/stats-inventory-sync.env
3071:  snapshot_acl() {
3093:  snapshot_node /opt/macprovider-stats/stats-inventory-sync stats-inventory-sync had-stats-inventory-binary
3094:  snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
3095:  snapshot_node /opt/macprovider-stats/stats-hardware-verifier stats-hardware-verifier had-stats-hardware-binary
3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
3141:    snapshot_acl /var/lib/macprovider/request-log.sqlite request-log-db.acl had-request-log-db-acl
3142:    snapshot_acl /var/lib/macprovider/request-log.sqlite-wal request-log-wal.acl had-request-log-wal-acl
3143:    snapshot_acl /var/lib/macprovider/request-log.sqlite-shm request-log-shm.acl had-request-log-shm-acl
3559:  # to this binary; its Postgres writer DSN lives under /etc/macprovider-stats.
3568:    if [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
3569:       ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
3576:  elif [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
3577:       ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
3581:  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync
3583:  # dedicated macprovider-stats identity and gets read access only to the
3585:  if [ ! -x /opt/macprovider-stats/stats-billing-mirror ] ||
3586:     ! cmp -s $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror; then
3590:  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
3593:  if [ ! -x /opt/macprovider-stats/stats-hardware-verifier ] ||
3594:     ! cmp -s $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier; then
3598:  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier
3634:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite
3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-wal
3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-shm
3638:  elif [ -f /var/lib/macprovider/request-log.sqlite ]; then
4768:  STATS_HEADERS="$(mktemp -t macprovider-stats-headers.XXXXXX)"
4855:  if [ "$_parity_required" = absent ] && [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ] && [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
4871:    echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ] && su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats; then
4886:    echo "stats billing mirror timer not enabled: missing env/sqlite source or macprovider-stats read ACL"
4888:  if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
4915:    echo "stats hardware verifier timer not enabled: missing /etc/macprovider-stats/stats-hardware-verifier.env"

exec
/bin/bash -lc "sed -n '3040,3170p' phase4-coordinator/dist/deploy-pearl-vps.sh; sed -n '3520,3665p' phase4-coordinator/dist/deploy-pearl-vps.sh; rg -n \"function|restore_acl|\\.acl|coordinator-deploy-rollback|rollback\" phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '1,280p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
  _rollback=/opt/macprovider/.coordinator-deploy-rollback
  _rollback_stage=\$_rollback.stage.\$\$
  umask 077
  if [ -e \"\$_rollback\" ] || [ -L \"\$_rollback\" ]; then
    echo 'coordinator deploy transaction already exists; refusing to overwrite it' >&2
    exit 1
  fi
  $(_tier2_migration_gate_remote_script)
  rm -rf \"\$_rollback_stage\"
  mkdir \"\$_rollback_stage\"
  trap 'rm -rf \"\$_rollback_stage\"' EXIT HUP INT TERM
  chown root:root \"\$_rollback_stage\"
  chmod 0700 \"\$_rollback_stage\"
  snapshot_node() {
    _source=\"\$1\"
    _snapshot=\"\$2\"
    _marker=\"\$3\"
    if [ -e \"\$_source\" ] || [ -L \"\$_source\" ]; then
      if [ ! -f \"\$_source\" ] && [ ! -L \"\$_source\" ]; then
        echo \"unsafe rollback source: \$_source\" >&2
        exit 1
      fi
      cp -a \"\$_source\" \"\$_rollback_stage/\$_snapshot\"
      touch \"\$_rollback_stage/\$_marker\"
    fi
  }
  snapshot_active() {
    if systemctl is-active --quiet \"\$1\"; then
      touch \"\$_rollback_stage/\$2\"
    fi
  }
  snapshot_acl() {
    _source=\"\$1\"
    _snapshot=\"\$2\"
    _marker=\"\$3\"
    if [ -e \"\$_source\" ]; then
      getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
      touch \"\$_rollback_stage/\$_marker\"
    fi
  }
  snapshot_node /opt/macprovider/coordinator.prev coordinator.prev had-coordinator-prev
  if [ -x /opt/macprovider/coordinator ]; then
    cp -p /opt/macprovider/coordinator \"\$_rollback_stage/coordinator\"
    touch \"\$_rollback_stage/had-coordinator\"
  fi
  snapshot_node /opt/macprovider/coordinator-cli coordinator-cli had-coordinator-cli
  snapshot_node /opt/macprovider/coordinator.yaml.prev coordinator.yaml.prev had-config-prev
  printf '%s' 'coordinator.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/config-backup-name\"
  snapshot_node /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS coordinator-dated-backup had-config-dated-backup
  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay
  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.prev coordinator.pearl-overlays.yaml.prev had-overlay-prev
  printf '%s' 'coordinator.pearl-overlays.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/overlay-config-backup-name\"
  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS coordinator-overlay-dated-backup had-overlay-dated-backup
  snapshot_node /opt/macprovider-stats/stats-inventory-sync stats-inventory-sync had-stats-inventory-binary
  snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
  snapshot_node /opt/macprovider-stats/stats-hardware-verifier stats-hardware-verifier had-stats-hardware-binary
  if [ -f /opt/macprovider/coordinator.yaml ]; then
    cp -p /opt/macprovider/coordinator.yaml \"\$_rollback_stage/coordinator.yaml\"
    touch \"\$_rollback_stage/had-config\"
  fi
  if [ -L /opt/macprovider/tier2-catalog.json ] || { [ -e /opt/macprovider/tier2-catalog.json ] && [ ! -f /opt/macprovider/tier2-catalog.json ]; }; then
    echo 'unsafe existing Tier-2 catalog path' >&2
    exit 1
  fi
  if [ -f /opt/macprovider/tier2-catalog.json ]; then
    cp -p /opt/macprovider/tier2-catalog.json \"\$_rollback_stage/tier2-catalog.json\"
    touch \"\$_rollback_stage/had-tier2-catalog\"
  fi
  if [ -e /etc/systemd/system/macprovider-coordinator.service ] || [ -L /etc/systemd/system/macprovider-coordinator.service ]; then
    cp -a /etc/systemd/system/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.service\"
    touch \"\$_rollback_stage/had-service-unit\"
  fi
  snapshot_node /etc/systemd/system/stats-inventory-sync.service stats-inventory-sync.service had-stats-inventory-service
  snapshot_node /etc/systemd/system/stats-inventory-sync.timer stats-inventory-sync.timer had-stats-inventory-timer
  snapshot_node /etc/systemd/system/stats-billing-mirror.service stats-billing-mirror.service had-stats-billing-service
  snapshot_node /etc/systemd/system/stats-billing-mirror.timer stats-billing-mirror.timer had-stats-billing-timer
  snapshot_node /etc/systemd/system/stats-hardware-verifier.service stats-hardware-verifier.service had-stats-hardware-service
  snapshot_node /etc/systemd/system/stats-hardware-verifier.timer stats-hardware-verifier.timer had-stats-hardware-timer
  snapshot_node /etc/systemd/system/timers.target.wants/stats-inventory-sync.timer stats-inventory-sync.wants had-stats-inventory-wants
  snapshot_node /etc/systemd/system/timers.target.wants/stats-billing-mirror.timer stats-billing-mirror.wants had-stats-billing-wants
  snapshot_node /etc/systemd/system/timers.target.wants/stats-hardware-verifier.timer stats-hardware-verifier.wants had-stats-hardware-wants
  snapshot_active stats-inventory-sync.timer stats-inventory-timer-was-active
  snapshot_active stats-inventory-sync.service stats-inventory-service-was-active
  snapshot_active stats-billing-mirror.timer stats-billing-timer-was-active
  snapshot_active stats-billing-mirror.service stats-billing-service-was-active
  snapshot_active stats-hardware-verifier.timer stats-hardware-timer-was-active
  snapshot_active stats-hardware-verifier.service stats-hardware-service-was-active

  snapshot_node /etc/nginx/conf.d/stats-shared.conf stats-shared.conf had-nginx-stats-shared
  snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
  snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
  snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
  snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
  snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
  snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
  snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
  snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
  snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full

  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
  fi
  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
    touch \"\$_rollback_stage/had-wants-link\"
  fi
  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
    touch \"\$_rollback_stage/had-recovery-helper\"
  fi
  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ]; then
    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
    touch \"\$_rollback_stage/had-recovery-unit\"
  fi
  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ]; then
    cp -a /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service \"\$_rollback_stage/macprovider-coordinator-deploy-watchdog.service\"
    touch \"\$_rollback_stage/had-watchdog-unit\"
  fi
  if [ -e /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ] || [ -L /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ]; then
    cp -a /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf \"\$_rollback_stage/10-deploy-transaction-guard.conf\"
    touch \"\$_rollback_stage/had-guard-dropin\"
  fi
  _catalog_target=\$(readlink /opt/macprovider/autotune/current 2>/dev/null || true)
  case \"\$_catalog_target\" in
    ''|releases/*) ;;
    *) echo \"invalid existing autotune current target: \$_catalog_target\" >&2; exit 1 ;;
  esac
  printf '%s' \"\$_catalog_target\" > \"\$_rollback_stage/catalog-current-target\"
        if [ '${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ] || [ '${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
          install -d -o root -g macprovider -m 0750 /etc/macprovider
          if [ -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
            install -o root -g macprovider -m 0640 /etc/macprovider/coordinator.pearl-overlays.yaml /etc/macprovider/coordinator.pearl-overlays.yaml.prev
            install -o root -g macprovider -m 0640 /etc/macprovider/coordinator.pearl-overlays.yaml /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS
            echo '  remote-overlay backup saved at /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS'
          fi
        fi"
else
  log "  CONFIG_MODE=preserve-live — skipping coordinator.yaml backup because no config overwrite will occur"
fi

$SSH "set -e
  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  flock -s 8
  # R5 SEC MED — deploy artifacts owned root:macprovider with group-read
  # rather than macprovider:macprovider. This prevents a compromised
  # macprovider UID from persistently rewriting its own executable /
  # config / cli. The daemon runs as macprovider; group=macprovider +
  # mode 0750 (binary/cli) and 0640 (config) give it the needed
  # read/execute access.
  # The signed Pearl updater is the sole authority for the coordinator/gateway
  # runtime pair. This catalog/config deployment may restart that installed
  # pair, but must not create a mixed release by replacing only coordinator.
  if [ ! -x /opt/macprovider/coordinator ] || ! cmp -s $DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator; then
    echo 'refusing coordinator-only replacement: install the signed coordinator/gateway pair with macprovider-pearl-update first' >&2
    echo '  preflight the selected Pearl runtime release with scripts/verify-pearl-runtime-release.sh before retrying direct deploy' >&2
    exit 1
  fi
  # coordinator-cli is operator-facing, but remains part of the same release
  # and therefore has an exact durable snapshot like the daemon binary.
  if [ ! -x /opt/macprovider/coordinator-cli ] || ! cmp -s $DEPLOY_TMP/coordinator-cli-linux-amd64 /opt/macprovider/coordinator-cli; then
    echo 'refusing coordinator-cli replacement from direct deploy: install the signed matching Pearl runtime release first' >&2
    echo '  macprovider-pearl-update --apply --tag $COORDINATOR_RELEASE_VERSION installs the signed coordinator-cli and stats sidecars' >&2
    exit 1
  fi
  install -o root -g macprovider -m 0750 $DEPLOY_TMP/coordinator-cli-linux-amd64 /opt/macprovider/coordinator-cli
  # stats-inventory-sync is an operator sidecar, not a coordinator child.
  # It runs under its own Unix identity and only receives execute access
  # to this binary; its Postgres writer DSN lives under /etc/macprovider-stats.
  # A pre-existing parity hold belongs to an earlier coordinator release. A
  # catalog-only deploy may carry the live binary through byte-for-byte, but it
  # must not silently promote a different sidecar before the signed matching
  # coordinator/sidecar release does so.
  if [ ! -r /opt/macprovider/.coordinator-deploy-sidecar-prior-state ]; then
    echo "refusing stats-inventory sidecar install: missing pre-quiesce parity state" >&2
    exit 1
  elif grep -qx "parity_required=present" /opt/macprovider/.coordinator-deploy-sidecar-prior-state; then
    if [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
       ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
      echo "refusing parity-held stats-inventory sidecar replacement: install the signed matching coordinator/sidecar release first" >&2
      exit 1
    fi
  elif ! grep -qx "parity_required=absent" /opt/macprovider/.coordinator-deploy-sidecar-prior-state; then
    echo "refusing stats-inventory sidecar install: invalid pre-quiesce parity state" >&2
    exit 1
  elif [ ! -x /opt/macprovider-stats/stats-inventory-sync ] ||
       ! cmp -s $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync; then
    echo "refusing stats-inventory sidecar replacement from direct deploy: install the signed matching stats sidecar release first" >&2
    exit 1
  fi
  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync
  # stats-billing-mirror is an out-of-band stats sidecar. It runs as the
  # dedicated macprovider-stats identity and gets read access only to the
  # SQLite ledger files via file ACLs below.
  if [ ! -x /opt/macprovider-stats/stats-billing-mirror ] ||
     ! cmp -s $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror; then
    echo "refusing stats-billing-mirror replacement from direct deploy: install the signed matching stats sidecar release first" >&2
    exit 1
  fi
  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
  # stats-hardware-verifier is an out-of-band stats sidecar. It promotes
  # queued autotune evidence after conservative verification.
  if [ ! -x /opt/macprovider-stats/stats-hardware-verifier ] ||
     ! cmp -s $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier; then
    echo "refusing stats-hardware-verifier replacement from direct deploy: install the signed matching stats sidecar release first" >&2
    exit 1
  fi
  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier
  if [ '$CONFIG_MODE' = 'apply-tracked' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.yaml /opt/macprovider/coordinator.yaml
  elif [ '${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}' = '1' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.rate-card-migration.yaml /opt/macprovider/coordinator.yaml
  elif [ '$C2_TIMER_CONFIG_MIGRATION' = '1' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.c2-timer-migration.yaml /opt/macprovider/coordinator.yaml
  else
    echo '  preserving live /opt/macprovider/coordinator.yaml'
  fi
  if [ '${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  elif [ '${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.c2-timer-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  fi
  install -d -o root -g macprovider -m 0750 /etc/macprovider
  if [ -e /etc/macprovider/coordinator.pearl-overlays.yaml ] && [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
    echo 'refusing unsafe coordinator overlay path: /etc/macprovider/coordinator.pearl-overlays.yaml' >&2
    exit 1
  fi
  if [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
    printf '{}\n' > $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  fi
  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.service /etc/systemd/system/stats-hardware-verifier.service
  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.timer /etc/systemd/system/stats-hardware-verifier.timer
  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
    # Mutate only objects captured at the transaction boundary. WAL/SHM files
    # can appear while the old coordinator is still running; granting an ACL
    # to a newly appeared, unsnapshotted file would make exact rollback
    # impossible.
    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
  elif [ -f /var/lib/macprovider/coordinator.db ]; then
    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
  fi
  # Stage the complete immutable catalog release. Activation happens only
  # after the late connected-provider safeguard immediately before restart.
  _autotune_root=/opt/macprovider/autotune
  _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
  _autotune_lock=\$_autotune_release.lock
  _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
  if ! mkdir \$_autotune_lock; then
    echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
    exit 1
  fi
  trap 'rm -rf \"\$_autotune_stage\"; rmdir \"\$_autotune_lock\" 2>/dev/null || true' EXIT
  rm -rf \$_autotune_stage
  install -d -o root -g macprovider -m 0750 \$_autotune_stage
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json \$_autotune_stage/demand-rank.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json.sig \$_autotune_stage/demand-rank.json.sig
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json \$_autotune_stage/autotune-candidates.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json.sig \$_autotune_stage/autotune-candidates.json.sig
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json \$_autotune_stage/rate-card.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json.sig \$_autotune_stage/rate-card.json.sig$AUTOTUNE_ARTIFACT_INSTALL_LINES
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/release.json \$_autotune_stage/release.json
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/trusted-keys.json \$_autotune_stage/trusted-keys.json
  python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_stage --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
  sync
312:    echo "           M0-5 instrumentation (PR #18) and the rollback gate is bypassed." >&2
320:    echo "       (deployed binary does not match the exact local release tag — rollback before commit)" >&2
973:    function indent_of(s) {
977:    function mask_scalar(s) {
981:    function suppress_secret_continuation(s) {
985:    function mask_secret_scalar(s) {
1088:#   own rollback deliberately leaves the sidecar stopped — the sidecar is LEFT
1098:  # rollback owns sidecar restoration and DELIBERATELY leaves it stopped pending
1101:    echo "coordinator deploy: stats-inventory-sync deliberately left stopped (schema/binary parity required — the armed rollback leaves the old 2-column sidecar stopped against the migrated 3-column schema; see coordinator-deploy-recover runbook)" >&2
1196:        test ! -d /opt/macprovider/.coordinator-deploy-rollback
1199:        echo "coordinator deploy rollback completed" >&2
1202:        echo "CRITICAL: coordinator deploy rollback failed; snapshot preserved at /opt/macprovider/.coordinator-deploy-rollback" >&2
1217:# race rollback against a still-running mutation SSH session.
1322:# config drift checks or a new rollback baseline.
1323:if $SSH 'test -d /opt/macprovider/.coordinator-deploy-rollback'; then
1326:    echo "aborting deploy: rollback snapshot exists but recovery helper is missing" >&2
1327:    echo "  Preserve /opt/macprovider/.coordinator-deploy-rollback and recover it manually." >&2
1867:    echo "  Use the reviewed enforcement or rollback transaction for that state transition." >&2
2027:        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
2077:# rollback transaction is armed, so its inactive state is what the step-4
2078:# snapshot records: a rollback restores the pre-019 binary but deliberately
2371:    AND has_function_privilege(current_user, 'request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
2372:    AND NOT has_function_privilege(current_user, 'approve_provider_auth_policy_exemption(uuid,text)'::regprocedure, 'EXECUTE')
2373:    AND NOT has_function_privilege(current_user, 'seed_provider_auth_policy_cutover(timestamp with time zone,text[])'::regprocedure, 'EXECUTE')
2394:    AND has_function_privilege(current_user, 'approve_provider_auth_policy_exemption(uuid,text)'::regprocedure, 'EXECUTE')
2395:    AND NOT has_function_privilege(current_user, 'request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
2396:    AND NOT has_function_privilege(current_user, 'seed_provider_auth_policy_cutover(timestamp with time zone,text[])'::regprocedure, 'EXECUTE')
2417:    AND has_function_privilege(current_user, 'seed_provider_auth_policy_cutover(timestamp with time zone,text[])'::regprocedure, 'EXECUTE')
2418:    AND NOT has_function_privilege(current_user, 'request_provider_auth_policy_exemption(uuid,text,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
2419:    AND NOT has_function_privilege(current_user, 'approve_provider_auth_policy_exemption(uuid,text)'::regprocedure, 'EXECUTE')
2441:    AND has_function_privilege(current_user, 'request_hardware_trust_approval(uuid,bigint,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
2442:    AND NOT has_function_privilege(current_user, 'approve_hardware_trust_approval(uuid,text)'::regprocedure, 'EXECUTE')
2443:    AND NOT has_function_privilege(current_user, 'revoke_hardware_trust_approval(uuid,text,text,text,text)'::regprocedure, 'EXECUTE')
2464:    AND has_function_privilege(current_user, 'approve_hardware_trust_approval(uuid,text)'::regprocedure, 'EXECUTE')
2465:    AND has_function_privilege(current_user, 'revoke_hardware_trust_approval(uuid,text,text,text,text)'::regprocedure, 'EXECUTE')
2466:    AND NOT has_function_privilege(current_user, 'request_hardware_trust_approval(uuid,bigint,text,timestamp with time zone,text,text)'::regprocedure, 'EXECUTE')
3031:log "step 4/9: upload binary + config + nginx site (with rollback snapshot)"
3040:  _rollback=/opt/macprovider/.coordinator-deploy-rollback
3041:  _rollback_stage=\$_rollback.stage.\$\$
3043:  if [ -e \"\$_rollback\" ] || [ -L \"\$_rollback\" ]; then
3048:  rm -rf \"\$_rollback_stage\"
3049:  mkdir \"\$_rollback_stage\"
3050:  trap 'rm -rf \"\$_rollback_stage\"' EXIT HUP INT TERM
3051:  chown root:root \"\$_rollback_stage\"
3052:  chmod 0700 \"\$_rollback_stage\"
3059:        echo \"unsafe rollback source: \$_source\" >&2
3062:      cp -a \"\$_source\" \"\$_rollback_stage/\$_snapshot\"
3063:      touch \"\$_rollback_stage/\$_marker\"
3068:      touch \"\$_rollback_stage/\$2\"
3076:      getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
3077:      touch \"\$_rollback_stage/\$_marker\"
3082:    cp -p /opt/macprovider/coordinator \"\$_rollback_stage/coordinator\"
3083:    touch \"\$_rollback_stage/had-coordinator\"
3087:  printf '%s' 'coordinator.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/config-backup-name\"
3091:  printf '%s' 'coordinator.pearl-overlays.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/overlay-config-backup-name\"
3097:    cp -p /opt/macprovider/coordinator.yaml \"\$_rollback_stage/coordinator.yaml\"
3098:    touch \"\$_rollback_stage/had-config\"
3105:    cp -p /opt/macprovider/tier2-catalog.json \"\$_rollback_stage/tier2-catalog.json\"
3106:    touch \"\$_rollback_stage/had-tier2-catalog\"
3109:    cp -a /etc/systemd/system/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.service\"
3110:    touch \"\$_rollback_stage/had-service-unit\"
3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
3146:    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
3147:    touch \"\$_rollback_stage/had-wants-link\"
3150:    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
3151:    touch \"\$_rollback_stage/had-recovery-helper\"
3154:    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
3155:    touch \"\$_rollback_stage/had-recovery-unit\"
3158:    cp -a /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service \"\$_rollback_stage/macprovider-coordinator-deploy-watchdog.service\"
3159:    touch \"\$_rollback_stage/had-watchdog-unit\"
3162:    cp -a /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf \"\$_rollback_stage/10-deploy-transaction-guard.conf\"
3163:    touch \"\$_rollback_stage/had-guard-dropin\"
3170:  printf '%s' \"\$_catalog_target\" > \"\$_rollback_stage/catalog-current-target\"
3172:    cp -p /opt/macprovider/autotune/.previous-target \"\$_rollback_stage/catalog-previous-target\"
3173:    touch \"\$_rollback_stage/had-previous-target\"
3176:    touch \"\$_rollback_stage/release-was-absent\"
3178:  printf '%s' '$AUTOTUNE_RELEASE_DIR_NAME' > \"\$_rollback_stage/release-id\"
3180:    touch \"\$_rollback_stage/service-was-active\"
3182:  touch \"\$_rollback_stage/complete\"
3183:  mv \"\$_rollback_stage\" \"\$_rollback\"
3189:# create non-rollbackable database effects before the catalog canary passes.
3629:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
3632:    # to a newly appeared, unsnapshotted file would make exact rollback
3634:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
3639:    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
4103:  # apply; the immutable release staged above stays for forensics/rollback.
4184:  touch /opt/macprovider/.coordinator-deploy-rollback/restart-attempted
4224:# mismatched versions are fatal while rollback is still armed; otherwise a clean
4226:# See audits/2026-06-10/ROLLBACK_PROCEDURE.md for the rollback path.
4867:  elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
4869:    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
4882:  elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-timer-was-active ]; then
4884:    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
4911:  elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-timer-was-active ]; then
4913:    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-service-was-active ] || systemctl start stats-hardware-verifier.service
4918:  touch /opt/macprovider/.coordinator-deploy-rollback/committed

exec
/bin/bash -lc "sed -n '1030,1235p' phase4-coordinator/dist/deploy-pearl-vps.sh" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
      if ($0 ~ /^[[:space:]]*[a-zA-Z0-9_]*(_key|_secret|_token|_dsn|dsn):[[:space:]]*env:[A-Za-z_][A-Za-z0-9_]*([[:space:]]*(#.*)?)?$/) {
        suppress_secret_continuation($0)
        print
      } else {
        print mask_secret_scalar($0)
      }
      next
    }
    { print }
	  ' | redact_dsn
}
reject_redacted_install_candidate() {
  local path="$1" label="$2"
  if grep -Eq '(<MASKED>|postgres(ql)?://[^[:space:]]+:\*\*\*@)' "$path"; then
    echo "aborting deploy: refusing to install redacted validation data as $label" >&2
    echo "  C2 timer migration install candidates must come from raw 0600 live config copies, never sanitized validation copies." >&2
    exit 5
  fi
}
normalize_yaml() {
  # Mask any field whose name ends in _key / _secret / _token, then strip
  # pure-comment lines and blanks so the drift check focuses on semantic
  # differences (values + structure) rather than comment-placement noise.
  sanitize_live_config_for_local_validation \
    | sed -E 's/^([[:space:]]*[a-zA-Z0-9_]*(_key|_secret|_token)):[[:space:]]*.*$/\1: <MASKED>/' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | grep -vE '^[[:space:]]*(#|$)'
}
print_config_drift_diff() {
  redact_dsn | sed 's/^/    /' >&2
}

# R5 ARCH M1 — early coherence check: if the operator set
# STATS_REQUIRED=1 but coordinator.yaml has stats.enabled=false (or
# unset), the deploy would restart the binary then exit 9 in step 8.
# Catch it BEFORE any SSH mutation.
assert_stats_required_matches_effective_config() {
  [ "${STATS_REQUIRED:-0}" = "1" ] || return 0
  _stats_enabled_pre="$(yaml_block_value stats enabled)"
  if [ "$_stats_enabled_pre" != "true" ]; then
    echo "aborting deploy: STATS_REQUIRED=1 but stats.enabled is not true in $DEPLOY_CONFIG ('$_stats_enabled_pre')." >&2
    echo "  Either set stats.enabled: true in coordinator.yaml, or drop STATS_REQUIRED=1." >&2
    exit 5
  fi
}

# Issue #582 (MEDIUM #6) — stats-inventory-sync restore-on-failure state.
# The old 2-column sidecar is quiesced (stop+disable) BEFORE migration 019
# widens hardware_verification_trust's PRIMARY KEY, so an abort that happens
# BEFORE the schema/binary actually become incompatible (before 019 is applied
# and before the new 3-column sidecar binary is installed) must RESTORE the
# sidecar to its pre-quiesce state rather than strand it stopped. These are
# ARMED before the quiesce (search "MEDIUM #6" at the quiesce step) and consumed
# by the EXIT trap through _sidecar_restore_on_abort.
#   SIDECAR_QUIESCE_ATTEMPTED — set to 1 immediately before the quiesce SSH.
#   Parity marker (/opt/macprovider/.coordinator-deploy-sidecar-parity-required,
#   touched just before the migration apply) records that the schema may now be
#   3-column; once set — or once the release transaction is ARMED at step 4, whose
#   own rollback deliberately leaves the sidecar stopped — the sidecar is LEFT
#   stopped (the old 2-column binary must never run against the migrated 3-column
#   schema). Restore reads the pre-quiesce enable/active state captured in
#   /opt/macprovider/.coordinator-deploy-sidecar-prior-state.
SIDECAR_QUIESCE_ATTEMPTED=0
_sidecar_restore_on_abort() {
  # $1 = deploy exit code. Best-effort + idempotent; never changes _final_rc.
  [ "${1:-0}" -ne 0 ] || return 0
  [ "${SIDECAR_QUIESCE_ATTEMPTED:-0}" = "1" ] || return 0
  # Once the release transaction is armed (step 4), the coordinator deploy
  # rollback owns sidecar restoration and DELIBERATELY leaves it stopped pending
  # schema/binary parity (see coordinator-deploy-recover.sh). Do not fight it.
  if [ "${COORDINATOR_DEPLOY_ARMED:-0}" = "1" ]; then
    echo "coordinator deploy: stats-inventory-sync deliberately left stopped (schema/binary parity required — the armed rollback leaves the old 2-column sidecar stopped against the migrated 3-column schema; see coordinator-deploy-recover runbook)" >&2
    return 0
  fi
  # Not armed: the new 3-column sidecar binary was never installed. If migration
  # 019 was (or may have been) applied inside the quiesced window the schema is
  # already 3-column, so the old 2-column sidecar MUST stay stopped.
  if $SSH 'test -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required' 2>/dev/null; then
    echo "coordinator deploy: stats-inventory-sync deliberately left stopped (schema/binary parity required — migration 019 applied but the new 3-column sidecar binary was not installed; see coordinator-deploy-recover runbook)" >&2
    return 0
  fi
  # Safe early abort: schema/binary parity never crossed. Restore the sidecar to
  # the enable/active state captured before the quiesce.
  if $SSH '
    set -u
    exec 8>/opt/macprovider/.coordinator-deploy-operation.lock 2>/dev/null || exit 0
    flock -s 8 2>/dev/null || true
    _prior=/opt/macprovider/.coordinator-deploy-sidecar-prior-state
    [ -f "$_prior" ] || exit 0
    timer_enabled=; timer_active=; service_enabled=; parity_required=
    . "$_prior"
    case "$parity_required" in
      present)
        touch /opt/macprovider/.coordinator-deploy-sidecar-parity-required
        systemctl disable --now stats-inventory-sync.timer >/dev/null 2>&1 || exit 1
        systemctl stop stats-inventory-sync.service >/dev/null 2>&1 || exit 1
        rm -f "$_prior"
        exit 0
        ;;
      absent) ;;
      *) exit 1 ;;
    esac
    [ "$service_enabled" = enabled ] && systemctl enable stats-inventory-sync.service >/dev/null 2>&1 || true
    [ "$timer_enabled" = enabled ] && systemctl enable stats-inventory-sync.timer >/dev/null 2>&1 || true
    [ "$timer_active" = active ] && systemctl start stats-inventory-sync.timer >/dev/null 2>&1 || true
    rm -f "$_prior"
  '; then
    echo "coordinator deploy: stats-inventory-sync restored to its pre-deploy state (safe early abort — schema/binary parity never crossed)" >&2
  else
    echo "coordinator deploy: WARNING could not restore stats-inventory-sync after early abort; verify its enabled/active state manually" >&2
  fi
}

# Issue #244 R6 (CODE+SEC+ARCH convergent MED) — register the EXIT
# cleanup trap UNCONDITIONALLY, before any temp resource is created.
# Earlier the trap was inside the `if [ -n "$CATALOG_REMOTE_PATH" ]`
# branch, so a deploy with catalog disabled that failed mid-flight
# could leave the remote $DEPLOY_TMP and local TMP_CATALOG_PUBKEY
# behind. Both variables are guarded with `:-` so the trap is a
# no-op when they are unset.
trap '
  _deploy_rc=$?
  _final_rc=$_deploy_rc
  rm -f "${TMP_CATALOG_PUBKEY:-}"
  rm -f "${TMP_CATALOG_PINNED:-}"
  rm -f "${CATALOG_SMOKE_TMP:-}"
  rm -f "${LIVE_COORDINATOR_CONFIG_RAW_TMP:-}"
  rm -f "${LIVE_COORDINATOR_CONFIG_TMP:-}"
  rm -f "${COORDINATOR_OVERLAY_CONFIG_RAW_TMP:-}"
  rm -f "${COORDINATOR_OVERLAY_CONFIG_TMP:-}"
  rm -f "${DEPLOY_EFFECTIVE_CONFIG_TMP:-}"
  rm -f "${C2_TIMER_MIGRATED_CONFIG_TMP:-}"
  rm -f "${C2_TIMER_MIGRATED_CONFIG_VALIDATION_TMP:-}"
  rm -f "${C2_TIMER_MIGRATED_OVERLAY_TMP:-}"
  rm -f "${C2_TIMER_MIGRATED_OVERLAY_VALIDATION_TMP:-}"
  rm -f "${RATE_CARD_MIGRATED_CONFIG_TMP:-}"
  rm -f "${RATE_CARD_MIGRATED_CONFIG_VALIDATION_TMP:-}"
  rm -f "${RATE_CARD_MIGRATED_OVERLAY_TMP:-}"
  rm -f "${RATE_CARD_MIGRATED_OVERLAY_VALIDATION_TMP:-}"
  rm -f "${GATEWAY_REMOTE_CONFIG_TMP:-}"
  rm -f "${DEPLOY_INPUT_MANIFEST_TMP:-}"
  rm -f "${RECOVERY_INPUT_MANIFEST_TMP:-}"
  rm -f "${TCP_INPUT_MANIFEST_TMP:-}"
  rm -rf "${PINNED_DEPLOY_INPUT_DIR:-}"
  rm -rf "${STATIC_SMOKE_DIR:-}"
  if [ -n "${DEPLOY_TMP:-}" ]; then
    $SSH "rm -rf $DEPLOY_TMP" 2>/dev/null || true
  fi
  if [ -n "${RECOVERY_DEPLOY_TMP:-}" ]; then
    $SSH "rm -rf $RECOVERY_DEPLOY_TMP" 2>/dev/null || true
  fi
  if [ "${DEPLOY_LOCK_HELD:-0}" = "1" ]; then
    touch "${DEPLOY_LOCK_RELEASE_SENTINEL:-}"
    exec 9>&-
    _lock_rc=0
    wait "${DEPLOY_LOCK_PID:-}" || _lock_rc=$?
    if [ "$_deploy_rc" -ne 0 ] && [ "${COORDINATOR_DEPLOY_ARMED:-0}" = "1" ]; then
      _recovery_rc=0
      $SSH '\''
        _wait=0
        while [ "$(systemctl show -p ActiveState --value macprovider-coordinator-deploy-watchdog.service 2>/dev/null || true)" = activating ]; do
          _wait=$((_wait + 1))
          [ "$_wait" -lt 600 ] || exit 1
          sleep 0.25
        done
        ! systemctl is-failed --quiet macprovider-coordinator-deploy-watchdog.service
        test ! -d /opt/macprovider/.coordinator-deploy-rollback
      '\'' || _recovery_rc=$?
      if [ "$_lock_rc" -eq 0 ] && [ "$_recovery_rc" -eq 0 ]; then
        echo "coordinator deploy rollback completed" >&2
      else
        cat "${DEPLOY_LOCK_STATUS:-/dev/null}" >&2 2>/dev/null || true
        echo "CRITICAL: coordinator deploy rollback failed; snapshot preserved at /opt/macprovider/.coordinator-deploy-rollback" >&2
        _final_rc=70
      fi
    fi
  fi
  _sidecar_restore_on_abort "$_deploy_rc"
  rm -rf "${DEPLOY_LOCK_DIR:-}"
  exit "$_final_rc"
' EXIT
trap 'exit 71' HUP INT TERM

if [ "$DRY_RUN_LOCAL" != "1" ]; then
# Acquire the Pearl lease before any live config read. The remote holder owns
# flock until the controller closes its FIFO. A remote systemd watchdog waits
# behind this lease and a per-command operation lock, so controller loss cannot
# race rollback against a still-running mutation SSH session.
DEPLOY_LOCK_DIR=$(umask 077 && mktemp -d -t macprovider-deploy-lock.XXXXXXXX)
DEPLOY_LOCK_FIFO="$DEPLOY_LOCK_DIR/stdin"
DEPLOY_LOCK_STATUS="$DEPLOY_LOCK_DIR/status"
DEPLOY_LOCK_WATCHDOG_ARMED="$DEPLOY_LOCK_DIR/watchdog-armed"
DEPLOY_LOCK_RELEASE_SENTINEL="$DEPLOY_LOCK_DIR/release-requested"
DEPLOY_CONTROLLER_PID=$$
mkfifo -m 600 "$DEPLOY_LOCK_FIFO"
touch "$DEPLOY_LOCK_WATCHDOG_ARMED"
(
  set +e
  $SSH "command -v flock >/dev/null 2>&1 || { echo 'Pearl is missing flock' >&2; exit 127; }
python3 -c '
import os, stat

nofollow = getattr(os, \"O_NOFOLLOW\", 0)
directory_flags = os.O_RDONLY | os.O_DIRECTORY | nofollow
opt_fd = os.open(\"/opt\", directory_flags)
root_fd = None

exec
/bin/bash -lc "rg -n \"restore_acl|request-log-db\\.acl|request-log-wal\\.acl|request-log-shm\\.acl|had-request-log-(db|wal|shm)-acl|setfacl --restore|getfacl\" phase4-coordinator scripts docs specs | sed -n '1,320p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/dist/coordinator-deploy-recover.sh:135:restore_acl() {
phase4-coordinator/dist/coordinator-deploy-recover.sh:229:restore_acl had-request-log-dir-acl request-log-dir.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh:230:restore_acl had-request-log-db-acl request-log-db.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh:231:restore_acl had-request-log-wal-acl request-log-wal.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh:232:restore_acl had-request-log-shm-acl request-log-shm.acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3076:      getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
phase4-coordinator/dist/deploy-pearl-vps.sh:3139:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3629:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3639:    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:46:grep -qF "echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'" "$DEPLOY_SH" ||
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:174:  printf '# acl fixture\n' >"$ROLLBACK/request-log-db.acl"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:175:  touch "$ROLLBACK/had-request-log-db-acl"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:243:grep -qx -- "--restore=$ROLLBACK/request-log-db.acl" "$SETFACL_LOG" || fail "request-log ACL was not restored"
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:152:  grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||

exec
/bin/bash -lc "sed -n '100,155p' phase4-coordinator/dist/coordinator-deploy-recover.sh; sed -n '205,245p' phase4-coordinator/dist/coordinator-deploy-recover.sh; sed -n '130,265p' phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
if [ -f "$ROLLBACK/committed" ]; then
  rm -rf "$ROLLBACK"
  exit 0
fi

restore_regular() {
  marker=$1
  snapshot=$2
  destination=$3
  if [ -f "$ROLLBACK/$marker" ]; then
    [ -f "$ROLLBACK/$snapshot" ] || {
      echo "rollback snapshot missing $snapshot" >&2
      exit 1
    }
    rm -f "$destination"
    cp -p "$ROLLBACK/$snapshot" "$destination"
  else
    rm -f "$destination"
  fi
}

restore_link_or_file() {
  marker=$1
  snapshot=$2
  destination=$3
  rm -f "$destination"
  if [ -f "$ROLLBACK/$marker" ]; then
    [ -e "$ROLLBACK/$snapshot" ] || [ -L "$ROLLBACK/$snapshot" ] || {
      echo "rollback snapshot missing $snapshot" >&2
      exit 1
    }
    cp -a "$ROLLBACK/$snapshot" "$destination"
  fi
}

restore_acl() {
  marker=$1
  snapshot=$2
  if [ -f "$ROLLBACK/$marker" ]; then
    [ -f "$ROLLBACK/$snapshot" ] || {
      echo "rollback snapshot missing $snapshot" >&2
      exit 1
    }
    "$SETFACL" --restore="$ROLLBACK/$snapshot"
  fi
}

restore_active_state() {
  unit_name=$1
  active_marker=$2
  if [ -f "$ROLLBACK/$active_marker" ]; then
    "$SYSTEMCTL" start "$unit_name"
  else
    "$SYSTEMCTL" stop "$unit_name" 2>/dev/null || true
    if "$SYSTEMCTL" is-active --quiet "$unit_name"; then
      echo "$unit_name remained active after rollback stop" >&2
restore_link_or_file had-service-unit macprovider-coordinator.service "$UNIT"
restore_link_or_file had-wants-link macprovider-coordinator.wants "$WANTS_LINK"

restore_link_or_file had-stats-inventory-service stats-inventory-sync.service "$SYSTEMD_ROOT/stats-inventory-sync.service"
restore_link_or_file had-stats-inventory-timer stats-inventory-sync.timer "$SYSTEMD_ROOT/stats-inventory-sync.timer"
restore_link_or_file had-stats-billing-service stats-billing-mirror.service "$SYSTEMD_ROOT/stats-billing-mirror.service"
restore_link_or_file had-stats-billing-timer stats-billing-mirror.timer "$SYSTEMD_ROOT/stats-billing-mirror.timer"
restore_link_or_file had-stats-hardware-service stats-hardware-verifier.service "$SYSTEMD_ROOT/stats-hardware-verifier.service"
restore_link_or_file had-stats-hardware-timer stats-hardware-verifier.timer "$SYSTEMD_ROOT/stats-hardware-verifier.timer"
restore_link_or_file had-stats-inventory-wants stats-inventory-sync.wants "$TIMERS_WANTS/stats-inventory-sync.timer"
restore_link_or_file had-stats-billing-wants stats-billing-mirror.wants "$TIMERS_WANTS/stats-billing-mirror.timer"
restore_link_or_file had-stats-hardware-wants stats-hardware-verifier.wants "$TIMERS_WANTS/stats-hardware-verifier.timer"

restore_link_or_file had-nginx-stats-shared stats-shared.conf "$NGINX_ROOT/conf.d/stats-shared.conf"
restore_link_or_file had-nginx-stats-security-headers stats-security-headers.conf "$NGINX_ROOT/conf.d/stats-security-headers.conf"
restore_link_or_file had-nginx-stats-cors-429 cors-429.conf "$NGINX_ROOT/conf.d/cors-429.conf"
restore_link_or_file had-nginx-stats-proxy-public stats-proxy-public.conf "$NGINX_ROOT/conf.d/stats-proxy-public.conf"
restore_link_or_file had-nginx-stats-proxy-partner stats-proxy-partner.conf "$NGINX_ROOT/conf.d/stats-proxy-partner.conf"
restore_link_or_file had-nginx-coordinator-site nginx-coordinator.site "$NGINX_ROOT/sites-available/coordinator.malibu.tech"
restore_link_or_file had-nginx-stats-site nginx-stats.site "$NGINX_ROOT/sites-available/stats.malibu.tech"
restore_link_or_file had-nginx-coordinator-enabled nginx-coordinator.enabled "$NGINX_ROOT/sites-enabled/coordinator.malibu.tech"
restore_link_or_file had-nginx-stats-enabled nginx-stats.enabled "$NGINX_ROOT/sites-enabled/stats.malibu.tech"
restore_link_or_file had-nginx-coordinator-full nginx-coordinator.full "$NGINX_ROOT/sites-available/coordinator.malibu.tech.full"

restore_acl had-request-log-dir-acl request-log-dir.acl
restore_acl had-request-log-db-acl request-log-db.acl
restore_acl had-request-log-wal-acl request-log-wal.acl
restore_acl had-request-log-shm-acl request-log-shm.acl

previous=$(cat "$ROLLBACK/catalog-current-target" 2>/dev/null || true)
case "$previous" in
  releases/*)
    mkdir -p "$CATALOG_ROOT"
    if [ -e "$CATALOG_ROOT/current" ] && [ ! -L "$CATALOG_ROOT/current" ]; then
      echo "unsafe non-symlink catalog current path" >&2
      exit 1
    fi
    ln -sfn "$previous" "$CATALOG_ROOT/current"
    ;;
  '') rm -f "$CATALOG_ROOT/current" ;;
  *) echo "invalid rollback catalog target: $previous" >&2; exit 1 ;;
  touch "$ROLLBACK/had-coordinator" "$ROLLBACK/had-config" "$ROLLBACK/had-tier2-catalog"
  printf old-cli >"$ROLLBACK/coordinator-cli"
  touch "$ROLLBACK/had-coordinator-cli"
  printf old-coordinator-prev >"$ROLLBACK/coordinator.prev"
	  printf old-config-prev >"$ROLLBACK/coordinator.yaml.prev"
	  printf old-dated-backup >"$ROLLBACK/coordinator-dated-backup"
	  printf coordinator.yaml.bak-20260711T120000Z >"$ROLLBACK/config-backup-name"
	  touch "$ROLLBACK/had-coordinator-prev" "$ROLLBACK/had-config-prev" "$ROLLBACK/had-config-dated-backup"
	  printf old-overlay >"$ROLLBACK/coordinator.pearl-overlays.yaml"
	  printf old-overlay-prev >"$ROLLBACK/coordinator.pearl-overlays.yaml.prev"
	  printf old-overlay-dated-backup >"$ROLLBACK/coordinator-overlay-dated-backup"
	  printf coordinator.pearl-overlays.yaml.bak-20260711T120000Z >"$ROLLBACK/overlay-config-backup-name"
	  touch "$ROLLBACK/had-overlay" "$ROLLBACK/had-overlay-prev" "$ROLLBACK/had-overlay-dated-backup"
  for artifact in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
    printf 'old-%s' "$artifact" >"$ROLLBACK/$artifact"
  done
  touch "$ROLLBACK/had-stats-inventory-binary" "$ROLLBACK/had-stats-billing-binary" "$ROLLBACK/had-stats-hardware-binary"
  ln -s /dev/null "$ROLLBACK/macprovider-coordinator.service"
  touch "$ROLLBACK/had-service-unit"
  ln -s ../macprovider-coordinator.service "$ROLLBACK/macprovider-coordinator.wants"
  touch "$ROLLBACK/had-wants-link"
  printf old-watchdog-unit >"$ROLLBACK/macprovider-coordinator-deploy-watchdog.service"
  touch "$ROLLBACK/had-watchdog-unit"
  for unit in stats-inventory-sync.service stats-inventory-sync.timer \
    stats-billing-mirror.service stats-billing-mirror.timer \
    stats-hardware-verifier.service stats-hardware-verifier.timer; do
    printf 'old-%s' "$unit" >"$ROLLBACK/$unit"
  done
  touch "$ROLLBACK/had-stats-inventory-service" "$ROLLBACK/had-stats-inventory-timer" \
    "$ROLLBACK/had-stats-billing-service" "$ROLLBACK/had-stats-billing-timer" \
    "$ROLLBACK/had-stats-hardware-service" "$ROLLBACK/had-stats-hardware-timer"
  ln -s ../stats-inventory-sync.timer "$ROLLBACK/stats-inventory-sync.wants"
  touch "$ROLLBACK/had-stats-inventory-wants"
  touch "$ROLLBACK/stats-inventory-timer-was-active" "$ROLLBACK/stats-billing-service-was-active"
  for nginx_file in stats-shared.conf stats-security-headers.conf cors-429.conf stats-proxy-public.conf stats-proxy-partner.conf; do
    printf 'old-%s' "$nginx_file" >"$ROLLBACK/$nginx_file"
  done
  printf old-coordinator-site >"$ROLLBACK/nginx-coordinator.site"
  printf old-stats-site >"$ROLLBACK/nginx-stats.site"
  ln -s ../sites-available/coordinator.malibu.tech "$ROLLBACK/nginx-coordinator.enabled"
  touch "$ROLLBACK/had-nginx-stats-shared" "$ROLLBACK/had-nginx-stats-security-headers" \
    "$ROLLBACK/had-nginx-stats-cors-429" "$ROLLBACK/had-nginx-stats-proxy-public" \
    "$ROLLBACK/had-nginx-stats-proxy-partner" "$ROLLBACK/had-nginx-coordinator-site" \
    "$ROLLBACK/had-nginx-stats-site" "$ROLLBACK/had-nginx-coordinator-enabled"
  printf '# acl fixture\n' >"$ROLLBACK/request-log-db.acl"
  touch "$ROLLBACK/had-request-log-db-acl"
  printf releases/old >"$ROLLBACK/catalog-current-target"
  # #1688: autotune_window.py writes a multi-line window; recovery must restore it byte-exact.
  printf 'releases/older\nreleases/oldest\n' >"$ROLLBACK/catalog-previous-target"
  touch "$ROLLBACK/had-previous-target" "$ROLLBACK/release-was-absent"
  printf new >"$ROLLBACK/release-id"
  touch "$ROLLBACK/restart-attempted" "$ROLLBACK/service-was-active"
  touch "$ROLLBACK/complete"

  printf new-binary >"$ROOT/coordinator"
  printf new-cli >"$ROOT/coordinator-cli"
  printf new-coordinator-prev >"$ROOT/coordinator.prev"
	  printf new-config-prev >"$ROOT/coordinator.yaml.prev"
	  printf new-dated-backup >"$ROOT/coordinator.yaml.bak-20260711T120000Z"
	  printf new-config >"$ROOT/coordinator.yaml"
	  printf new-overlay >"$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml"
	  printf new-overlay-prev >"$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.prev"
	  printf new-overlay-dated-backup >"$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.bak-20260711T120000Z"
	  printf new-tier2-catalog >"$ROOT/tier2-catalog.json"
  printf new-unit >"$SYSTEMD/macprovider-coordinator.service"
  printf new-watchdog-unit >"$SYSTEMD/macprovider-coordinator-deploy-watchdog.service"
  for artifact in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
    printf 'new-%s' "$artifact" >"$STATS_ROOT/$artifact"
  done
  for unit in stats-inventory-sync.service stats-inventory-sync.timer \
    stats-billing-mirror.service stats-billing-mirror.timer \
    stats-hardware-verifier.service stats-hardware-verifier.timer; do
    printf 'new-%s' "$unit" >"$SYSTEMD/$unit"
  done
  ln -s ../stats-inventory-sync.timer "$SYSTEMD/timers.target.wants/stats-inventory-sync.timer"
  ln -s ../stats-billing-mirror.timer "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer"
  for nginx_file in stats-shared.conf stats-security-headers.conf cors-429.conf stats-proxy-public.conf stats-proxy-partner.conf; do
    printf 'new-%s' "$nginx_file" >"$NGINX_ROOT/conf.d/$nginx_file"
  done
  printf new-coordinator-site >"$NGINX_ROOT/sites-available/coordinator.malibu.tech"
  printf new-stats-site >"$NGINX_ROOT/sites-available/stats.malibu.tech"
  ln -s ../sites-available/stats.malibu.tech "$NGINX_ROOT/sites-enabled/stats.malibu.tech"
  ln -s ../wrong.service "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service"
  ln -sfn releases/new "$ROOT/autotune/current"
  printf releases/new >"$ROOT/autotune/.previous-target"
  : >"$SYSTEMCTL_LOG"
  : >"$SETFACL_LOG"
}

seed_transaction
run_recover
[ "$(cat "$ROOT/coordinator")" = old-binary ] || fail "binary was not restored"
[ "$(cat "$ROOT/coordinator.yaml")" = old-config ] || fail "config was not restored"
[ "$(cat "$ROOT/tier2-catalog.json")" = old-tier2-catalog ] || fail "Tier-2 catalog was not restored"
[ "$(cat "$ROOT/coordinator-cli")" = old-cli ] || fail "coordinator CLI was not restored"
[ "$(cat "$ROOT/coordinator.prev")" = old-coordinator-prev ] || fail "coordinator convenience backup was not restored"
[ "$(cat "$ROOT/coordinator.yaml.prev")" = old-config-prev ] || fail "config convenience backup was not restored"
[ "$(cat "$ROOT/coordinator.yaml.bak-20260711T120000Z")" = old-dated-backup ] || fail "dated config backup collision was not restored"
[ "$(cat "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml")" = old-overlay ] || fail "overlay was not restored"
[ "$(cat "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.prev")" = old-overlay-prev ] || fail "overlay convenience backup was not restored"
[ "$(cat "$ETC_MACPROVIDER_ROOT/coordinator.pearl-overlays.yaml.bak-20260711T120000Z")" = old-overlay-dated-backup ] || fail "dated overlay backup collision was not restored"
[ "$(cat "$STATS_ROOT/stats-inventory-sync")" = old-stats-inventory-sync ] || fail "stats inventory binary was not restored"
[ "$(cat "$STATS_ROOT/stats-billing-mirror")" = old-stats-billing-mirror ] || fail "stats billing binary was not restored"
[ "$(cat "$STATS_ROOT/stats-hardware-verifier")" = old-stats-hardware-verifier ] || fail "stats hardware binary was not restored"
[ "$(readlink "$SYSTEMD/macprovider-coordinator.service")" = /dev/null ] || fail "masked unit was not restored"
[ "$(readlink "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service")" = ../macprovider-coordinator.service ] || fail "enablement link was not restored"
[ "$(cat "$SYSTEMD/macprovider-coordinator-deploy-watchdog.service")" = old-watchdog-unit ] || fail "deploy watchdog unit was not restored"
[ "$(cat "$SYSTEMD/stats-inventory-sync.timer")" = old-stats-inventory-sync.timer ] || fail "stats timer unit was not restored"
[ -L "$SYSTEMD/timers.target.wants/stats-inventory-sync.timer" ] || fail "prior stats timer enablement was not restored"
[ ! -e "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer" ] || fail "new stats timer enablement was not removed"
[ "$(cat "$NGINX_ROOT/conf.d/stats-shared.conf")" = old-stats-shared.conf ] || fail "nginx snippet was not restored"
[ "$(cat "$NGINX_ROOT/sites-available/coordinator.malibu.tech")" = old-coordinator-site ] || fail "coordinator nginx site was not restored"
[ ! -e "$NGINX_ROOT/sites-enabled/stats.malibu.tech" ] || fail "new stats nginx enablement was not removed"
grep -qx -- "--restore=$ROLLBACK/request-log-db.acl" "$SETFACL_LOG" || fail "request-log ACL was not restored"
[ "$(readlink "$ROOT/autotune/current")" = releases/old ] || fail "catalog current was not restored"
[ "$(cat "$ROOT/tier2-catalog.json")" = old-tier2-catalog ] &&
  [ "$(readlink "$ROOT/autotune/current")" = releases/old ] ||
  fail "legacy Tier-2 bridge and current pointer were not restored together"
[ "$(cat "$ROOT/autotune/.previous-target")" = "$(printf 'releases/older\nreleases/oldest')" ] || fail "catalog previous target was not restored"
[ ! -d "$ROOT/autotune/releases/new" ] || fail "new release was not removed"
[ ! -e "$ROLLBACK" ] || fail "successful recovery did not remove its snapshot"
grep -qx 'daemon-reload' "$SYSTEMCTL_LOG" || fail "recovery did not reload systemd"
grep -qx 'restart macprovider-coordinator' "$SYSTEMCTL_LOG" || fail "recovery did not restore active service state"
grep -qx 'start stats-inventory-sync.timer' "$SYSTEMCTL_LOG" || fail "active stats timer state was not restored"
grep -qx 'start stats-billing-mirror.service' "$SYSTEMCTL_LOG" || fail "active stats service state was not restored"
grep -qx 'try-reload-or-restart nginx' "$SYSTEMCTL_LOG" || fail "restored nginx graph was not reloaded"

seed_transaction
rm -f "$ROLLBACK/macprovider-coordinator.wants" "$ROLLBACK/had-wants-link"
run_recover
[ ! -e "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service" ] &&
  [ ! -L "$SYSTEMD/multi-user.target.wants/macprovider-coordinator.service" ] ||
  fail "disabled service state was not restored"

seed_transaction
rm -f "$ROLLBACK/tier2-catalog.json" "$ROLLBACK/had-tier2-catalog"

exec
/bin/bash -lc 'rg -n "func ReadOnlyDSN|ReadOnlyDSN|PRAGMA|ExecContext|QueryContext|QueryRowContext|BeginTx|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|VACUUM|ATTACH" phase4-coordinator/internal/stats/billingmirror phase4-coordinator/internal/sqliteutil' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/internal/sqliteutil/transact.go:35://	conn.ExecContext(ctx, "BEGIN IMMEDIATE")
phase4-coordinator/internal/sqliteutil/transact.go:37://	defer func() { if !committed { _, _ = conn.ExecContext(context.Background(), "ROLLBACK") } }()
phase4-coordinator/internal/sqliteutil/transact.go:39://	conn.ExecContext(ctx, "COMMIT"); committed = true
phase4-coordinator/internal/sqliteutil/transact.go:70:	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
phase4-coordinator/internal/sqliteutil/transact.go:76:			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
phase4-coordinator/internal/sqliteutil/transact.go:84:	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
phase4-coordinator/internal/sqliteutil/dsn.go:24:// throughput cost on every billing/requestlog INSERT, and is
phase4-coordinator/internal/sqliteutil/dsn.go:56:// ReadOnlyDSN builds a strictly read-only modernc.org/sqlite DSN.
phase4-coordinator/internal/sqliteutil/dsn.go:57:// Opens with mode=ro and applies PRAGMA query_only=ON at connection
phase4-coordinator/internal/sqliteutil/dsn.go:61:// introspection never persists journal-mode metadata or runs ALTER
phase4-coordinator/internal/sqliteutil/dsn.go:63:func ReadOnlyDSN(path string) string {
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:201:	if _, err := db.Exec(`CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY)`); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:253:CREATE TABLE ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:270:CREATE VIEW spec022_payable_request_credits AS
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:275:CREATE TABLE provider_tokens (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:285:INSERT INTO ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:294:INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:317:CREATE TABLE ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:333:INSERT INTO ledger_request_credits (
phase4-coordinator/internal/sqliteutil/wal.go:24:// PRAGMA wal_checkpoint.
phase4-coordinator/internal/sqliteutil/wal.go:40:		return `PRAGMA wal_checkpoint(PASSIVE)`, nil
phase4-coordinator/internal/sqliteutil/wal.go:42:		return `PRAGMA wal_checkpoint(TRUNCATE)`, nil
phase4-coordinator/internal/sqliteutil/wal.go:59:	err = db.QueryRowContext(ctx, query).Scan(&result.Busy, &result.LogPages, &result.CheckpointedPages)
phase4-coordinator/internal/sqliteutil/wal.go:87:// SetBusyTimeout sets PRAGMA busy_timeout on db to timeout, clamped to
phase4-coordinator/internal/sqliteutil/wal.go:101:	_, err := db.ExecContext(ctx, "PRAGMA busy_timeout = "+strconv.FormatInt(ms, 10))
phase4-coordinator/internal/sqliteutil/transact_test.go:48:	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go:66:		if _, err := conn.ExecContext(ctx, `INSERT INTO t (v) VALUES ('a'), ('b')`); err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go:83:		if _, err := conn.ExecContext(ctx, `INSERT INTO t (v) VALUES ('a')`); err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go:105:		if _, err := conn.ExecContext(innerCtx, `INSERT INTO t (v) VALUES ('a')`); err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go:123:		_, err := conn.ExecContext(c, `INSERT INTO t (v) VALUES ('b')`)
phase4-coordinator/internal/sqliteutil/transact_test.go:150:		_, err := conn.ExecContext(ctx, `INSERT INTO t (v) VALUES ('a')`)
phase4-coordinator/internal/sqliteutil/transact_test.go:177:	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
phase4-coordinator/internal/sqliteutil/transact_test.go:180:	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a')`); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go:23:	if _, err := db.Exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)`); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go:26:	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('a'), ('b'), ('c')`); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go:72:		"TRUNCATE); DROP TABLE t; --",
phase4-coordinator/internal/sqliteutil/wal_test.go:89:	if _, err := db.Exec(`INSERT INTO t (v) VALUES ('still-there')`); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go:106:	if err := db.QueryRow(`PRAGMA busy_timeout`).Scan(&ms); err != nil {
phase4-coordinator/internal/sqliteutil/wal_test.go:107:		t.Fatalf("PRAGMA busy_timeout: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:254:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
phase4-coordinator/internal/stats/billingmirror/mirror.go:285:	if err := db.QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go:394:	rows, err := db.QueryContext(ctx, `PRAGMA table_info(`+table+`)`)
phase4-coordinator/internal/stats/billingmirror/mirror.go:417:	err := db.QueryRowContext(ctx, `
phase4-coordinator/internal/stats/billingmirror/mirror.go:428:	cur, err := db.QueryContext(ctx, q, args...)
phase4-coordinator/internal/stats/billingmirror/mirror.go:483:	cur, err := db.QueryContext(ctx, q)
phase4-coordinator/internal/stats/billingmirror/mirror.go:514:	tx, err := db.BeginTx(ctx, nil)
phase4-coordinator/internal/stats/billingmirror/mirror.go:525:	if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(47017, 1711)`).Scan(&locked); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go:553:		if _, err := db.ExecContext(ctx, stmt); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go:562:	if err := db.QueryRowContext(ctx, `SELECT last_request_credit_id, sweep_after_request_credit_id FROM stats_billing_mirror_load_state($1)`, StateSource).Scan(&state.LastRequestID, &state.SweepAfterID); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go:569:	if _, err := tx.ExecContext(ctx, `SELECT stats_billing_mirror_save_state($1, $2, $3)`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:578:	if _, err := tx.ExecContext(ctx, `SELECT stats_billing_mirror_ensure_provider($1, $2, $3, $4, $5)`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:586:	if _, err := tx.ExecContext(ctx, `SELECT stats_billing_mirror_upsert_request_credit(
phase4-coordinator/internal/stats/billingmirror/mirror.go:698:	`CREATE TABLE IF NOT EXISTS ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror.go:721:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS sqlite_lrc_id BIGINT`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:722:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS request_id TEXT`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:723:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS attempt_n INTEGER`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:724:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_id TEXT`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:725:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS ts_utc TIMESTAMPTZ`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:726:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS created_at_utc TIMESTAMPTZ DEFAULT now()`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:727:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS updated_at_utc TIMESTAMPTZ`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:728:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS prompt_tokens BIGINT`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:729:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS completion_tokens BIGINT`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:730:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS estimated_completion_tokens BIGINT`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:731:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS usage_source TEXT DEFAULT 'provider_reported'`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:732:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_credits BIGINT DEFAULT 0`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:733:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS fault_flag TEXT DEFAULT 'none'`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:734:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS quarantined BOOLEAN DEFAULT FALSE`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:735:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS settlement_policy_mode TEXT DEFAULT 'legacy'`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:736:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS spec022_verified BOOLEAN DEFAULT FALSE`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:737:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS requested_privacy_mode TEXT DEFAULT 'none'`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:738:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS effective_privacy_outcome TEXT DEFAULT 'plaintext'`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:739:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS positive_verification_excluded BOOLEAN DEFAULT FALSE`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:740:	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS rewards_excluded BOOLEAN DEFAULT FALSE`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:741:	`UPDATE ledger_request_credits SET settlement_policy_mode = 'legacy' WHERE settlement_policy_mode IS NULL`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:742:	`UPDATE ledger_request_credits SET spec022_verified = FALSE WHERE spec022_verified IS NULL`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:743:	`UPDATE ledger_request_credits SET requested_privacy_mode = 'none' WHERE requested_privacy_mode IS NULL`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:744:	`UPDATE ledger_request_credits SET effective_privacy_outcome = 'plaintext' WHERE effective_privacy_outcome IS NULL`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:745:	`UPDATE ledger_request_credits SET positive_verification_excluded = FALSE WHERE positive_verification_excluded IS NULL`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:746:	`UPDATE ledger_request_credits SET rewards_excluded = FALSE WHERE rewards_excluded IS NULL`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:750:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_attempt_nonnegative CHECK (attempt_n >= 0);
phase4-coordinator/internal/stats/billingmirror/mirror.go:753:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_prompt_tokens_nonnegative CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0);
phase4-coordinator/internal/stats/billingmirror/mirror.go:756:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_completion_tokens_nonnegative CHECK (completion_tokens IS NULL OR completion_tokens >= 0);
phase4-coordinator/internal/stats/billingmirror/mirror.go:759:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_estimated_completion_tokens_nonnegative CHECK (estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0);
phase4-coordinator/internal/stats/billingmirror/mirror.go:762:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_usage_source_enum CHECK (usage_source IN ('provider_reported','byte_estimated','null_error'));
phase4-coordinator/internal/stats/billingmirror/mirror.go:765:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_provider_credits_nonnegative CHECK (provider_credits >= 0);
phase4-coordinator/internal/stats/billingmirror/mirror.go:768:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_fault_flag_enum CHECK (fault_flag IN ('none','breaker_qualifying','null_usage_error'));
phase4-coordinator/internal/stats/billingmirror/mirror.go:771:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_settlement_policy_mode_enum CHECK (settlement_policy_mode IN ('legacy','observe','enforce'));
phase4-coordinator/internal/stats/billingmirror/mirror.go:774:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_not_null CHECK (spec022_verified IS NOT NULL);
phase4-coordinator/internal/stats/billingmirror/mirror.go:777:        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_enforce_check CHECK (spec022_verified = FALSE OR settlement_policy_mode = 'enforce');
phase4-coordinator/internal/stats/billingmirror/mirror.go:780:	`CREATE UNIQUE INDEX IF NOT EXISTS idx_lrc_mirror_unique_attempt ON ledger_request_credits(request_id, attempt_n, provider_id)`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:781:	`CREATE INDEX IF NOT EXISTS idx_lrc_mirror_provider_ts ON ledger_request_credits(provider_id, ts_utc)`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:782:	`CREATE TABLE IF NOT EXISTS ledger_request_credit_spec022_verified_audit (
phase4-coordinator/internal/stats/billingmirror/mirror.go:793:	`CREATE TABLE IF NOT EXISTS provider_tokens (
phase4-coordinator/internal/stats/billingmirror/mirror.go:803:	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS token_prefix TEXT DEFAULT ''`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:804:	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS provider_id TEXT DEFAULT ''`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:805:	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS provider_name TEXT DEFAULT ''`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:806:	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now()`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:807:	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:808:	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:809:	`CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_tokens_one_active_per_provider
phase4-coordinator/internal/stats/billingmirror/mirror.go:812:	`CREATE TABLE IF NOT EXISTS stats_billing_mirror_state (
phase4-coordinator/internal/stats/billingmirror/mirror.go:818:	`ALTER TABLE stats_billing_mirror_state ADD COLUMN IF NOT EXISTS sweep_after_request_credit_id BIGINT NOT NULL DEFAULT 0`,
phase4-coordinator/internal/stats/billingmirror/mirror.go:819:	`CREATE OR REPLACE FUNCTION stats_billing_mirror_load_state(p_source TEXT)
phase4-coordinator/internal/stats/billingmirror/mirror.go:825:    INSERT INTO stats_billing_mirror_state (source, last_request_credit_id, sweep_after_request_credit_id)
phase4-coordinator/internal/stats/billingmirror/mirror.go:833:	`CREATE OR REPLACE FUNCTION stats_billing_mirror_save_state(p_source TEXT, p_last_request_credit_id BIGINT, p_sweep_after_request_credit_id BIGINT)
phase4-coordinator/internal/stats/billingmirror/mirror.go:839:    INSERT INTO stats_billing_mirror_state (source, last_request_credit_id, sweep_after_request_credit_id, updated_at)
phase4-coordinator/internal/stats/billingmirror/mirror.go:841:    ON CONFLICT (source) DO UPDATE SET
phase4-coordinator/internal/stats/billingmirror/mirror.go:846:	`CREATE OR REPLACE FUNCTION stats_billing_mirror_ensure_provider(
phase4-coordinator/internal/stats/billingmirror/mirror.go:858:    INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
phase4-coordinator/internal/stats/billingmirror/mirror.go:863:    ON CONFLICT (token_hash) DO UPDATE SET
phase4-coordinator/internal/stats/billingmirror/mirror.go:868:	`CREATE OR REPLACE FUNCTION stats_billing_mirror_upsert_request_credit(
phase4-coordinator/internal/stats/billingmirror/mirror.go:916:     FOR UPDATE;
phase4-coordinator/internal/stats/billingmirror/mirror.go:918:    INSERT INTO ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror.go:930:    ON CONFLICT (request_id, attempt_n, provider_id) DO UPDATE SET
phase4-coordinator/internal/stats/billingmirror/mirror.go:950:        INSERT INTO ledger_request_credit_spec022_verified_audit (

exec
/bin/bash -lc "sed -n '1,180p' phase4-coordinator/internal/sqliteutil/*.go; sed -n '280,460p' phase4-coordinator/internal/stats/billingmirror/mirror.go; sed -n '840,1010p' phase4-coordinator/internal/stats/billingmirror/mirror.go" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
package sqliteutil

import (
	"net/url"
	"strings"
)

// WithPragmas builds a modernc.org/sqlite DSN with the project's standard
// pragma set (busy_timeout, foreign_keys, WAL, synchronous=FULL).
//
// ARCH-5: this helper deliberately mirrors the gateway SQLite DSN shape while
// remaining coordinator-owned. The duplication is intentional — coordinator
// and gateway are deployed as independent Go modules, and introducing a shared
// library would re-couple them on every DSN tweak. See audits/2026-06-10/
// REPO_AUDIT.md (ARCH-5) for the conscious-debt reasoning.
//
// SPEC-016 §3.1 requires synchronous=FULL on every connection
// touching provider_payout_addresses or payout_attempts. Because
// the coordinator shares one *sql.DB handle across requestlog,
// billing, audit, and payout (SPEC-016 §4.8a / §4.8b same-DB
// pins make the shared handle structurally necessary), the DSN
// is the only place to set the per-connection pragma. The prior
// value was NORMAL; the change carries a non-trivial write-
// throughput cost on every billing/requestlog INSERT, and is
// called out explicitly in SPEC-016 IMPL Step 1 audit prompt.
func WithPragmas(path string) string {
	values := url.Values{}
	for _, pragma := range []string{
		"busy_timeout=5000",
		"foreign_keys=1",
		"journal_mode(WAL)",
		"synchronous(FULL)",
	} {
		values.Add("_pragma", pragma)
	}
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	return path + separator + values.Encode()
}

// WithManualWALCheckpointPragmas disables SQLite's autocheckpoint for a DB
// handle whose owner starts an explicit off-hot-path checkpoint loop.
func WithManualWALCheckpointPragmas(path string) string {
	base := WithPragmas(path)
	values := url.Values{}
	values.Add("_pragma", "wal_autocheckpoint(0)")
	separator := "?"
	if strings.Contains(base, "?") {
		separator = "&"
	}
	return base + separator + values.Encode()
}

// ReadOnlyDSN builds a strictly read-only modernc.org/sqlite DSN.
// Opens with mode=ro and applies PRAGMA query_only=ON at connection
// init via a pragma — no journal_mode toggle, no synchronous toggle,
// no writable connection. SPEC-002 v1.5.1 R-2 / issue #197 R3 code:
// used by `coordinator migrate-indexes --check` so the read-only
// introspection never persists journal-mode metadata or runs ALTER
// TABLE on a legacy DB.
func ReadOnlyDSN(path string) string {
	values := url.Values{}
	values.Set("mode", "ro")
	for _, pragma := range []string{
		"busy_timeout=5000",
		"query_only(true)",
	} {
		values.Add("_pragma", pragma)
	}
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	return path + separator + values.Encode()
}
package sqliteutil

import (
	"context"
	"database/sql"
	"time"
)

// Observer receives closed-set SQLite timing observations from money-path
// stores. Implementations must keep labels bounded; component values are
// call-site constants, and outcome is "success" or "error".
type Observer interface {
	ObserveSQLiteConnectionWait(component, outcome string, duration time.Duration)
	ObserveSQLiteTransactionDuration(component, outcome string, duration time.Duration)
}

// Transact reserves a single *sql.Conn from db, issues BEGIN IMMEDIATE to
// take the SQLite write lock deterministically, invokes fn with the
// reserved connection, and then COMMITs on nil error or ROLLBACKs on
// non-nil error (or panic).
//
// The ROLLBACK is issued with context.Background(), never the caller's
// ctx, so cancellation of the request context after a partial write does
// not leave the transaction dangling.
//
// The callback receives the reserved *sql.Conn and MUST issue all
// subsequent statements against it — SQLite transactions are bound to a
// single connection, and running a statement on a different conn from the
// pool while a BEGIN IMMEDIATE is in flight would deadlock against the
// write lock this call is holding.
//
// This helper replaces the hand-rolled
//
//	conn, _ := s.db.Conn(ctx); defer conn.Close()
//	conn.ExecContext(ctx, "BEGIN IMMEDIATE")
//	committed := false
//	defer func() { if !committed { _, _ = conn.ExecContext(context.Background(), "ROLLBACK") } }()
//	... work ...
//	conn.ExecContext(ctx, "COMMIT"); committed = true
//
// pattern used across money-path stores (billing, auth token issuance,
// requestlog, receipts). Semantics are byte-equivalent to that pattern;
// see phase4-coordinator/internal/sqliteutil/transact_test.go for the
// invariant coverage.
func Transact(ctx context.Context, db *sql.DB, fn func(context.Context, *sql.Conn) error) (err error) {
	return TransactObserved(ctx, db, "", nil, fn)
}

// TransactObserved is Transact with optional timing observation for the
// sql.DB connection wait and full BEGIN IMMEDIATE..COMMIT/ROLLBACK duration.
func TransactObserved(ctx context.Context, db *sql.DB, component string, observer Observer, fn func(context.Context, *sql.Conn) error) (err error) {
	connWaitStarted := time.Now()
	conn, cerr := db.Conn(ctx)
	observeConnectionWait(observer, component, cerr, time.Since(connWaitStarted))
	if cerr != nil {
		return cerr
	}
	defer conn.Close()

	txStarted := time.Now()
	txErr := true
	defer func() {
		if err == nil && !txErr {
			observeTransactionDuration(observer, component, nil, time.Since(txStarted))
			return
		}
		observeTransactionDuration(observer, component, err, time.Since(txStarted))
	}()

	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	if err := fn(ctx, conn); err != nil {
		return err
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return err
	}
	committed = true
	txErr = false
	return nil
}

func observeConnectionWait(observer Observer, component string, err error, duration time.Duration) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteConnectionWait(component, sqliteOutcome(err), duration)
}

func observeTransactionDuration(observer Observer, component string, err error, duration time.Duration) {
	if observer == nil || component == "" {
		return
	}
	observer.ObserveSQLiteTransactionDuration(component, sqliteOutcome(err), duration)
	return scanRequestCredits(ctx, db, requestCreditsQuery(caps, false), startID, limit)
}

func FetchMaxRequestCreditID(ctx context.Context, db *sql.DB) (int64, error) {
	var maxID sql.NullInt64
	if err := db.QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
		return 0, fmt.Errorf("select max ledger_request_credits id: %w", err)
	}
	if !maxID.Valid {
		return 0, nil
	}
	return maxID.Int64, nil
}

func FetchRequestCreditsThrough(ctx context.Context, db *sql.DB, startID, endID int64, limit int) ([]RequestCredit, error) {
	caps, err := detectRequestCreditSourceCapabilities(ctx, db)
	if err != nil {
		return nil, err
	}
	return scanRequestCredits(ctx, db, requestCreditsQuery(caps, true), startID, endID, limit)
}

type requestCreditSourceCapabilities struct {
	HasSettlementPolicyMode         bool
	HasSpec022PayableView           bool
	HasRequestedPrivacyMode         bool
	HasEffectivePrivacyOutcome      bool
	HasPositiveVerificationExcluded bool
	HasRewardsExcluded              bool
}

func detectRequestCreditSourceCapabilities(ctx context.Context, db *sql.DB) (requestCreditSourceCapabilities, error) {
	hasPolicy, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "settlement_policy_mode")
	if err != nil {
		return requestCreditSourceCapabilities{}, err
	}
	hasPayable, err := sqliteObjectExists(ctx, db, "spec022_payable_request_credits")
	if err != nil {
		return requestCreditSourceCapabilities{}, err
	}
	hasRequestedPrivacyMode, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "requested_privacy_mode")
	if err != nil {
		return requestCreditSourceCapabilities{}, err
	}
	hasEffectivePrivacyOutcome, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "effective_privacy_outcome")
	if err != nil {
		return requestCreditSourceCapabilities{}, err
	}
	hasPositiveVerificationExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "positive_verification_excluded")
	if err != nil {
		return requestCreditSourceCapabilities{}, err
	}
	hasRewardsExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "rewards_excluded")
	if err != nil {
		return requestCreditSourceCapabilities{}, err
	}
	return requestCreditSourceCapabilities{
		HasSettlementPolicyMode:         hasPolicy,
		HasSpec022PayableView:           hasPayable,
		HasRequestedPrivacyMode:         hasRequestedPrivacyMode,
		HasEffectivePrivacyOutcome:      hasEffectivePrivacyOutcome,
		HasPositiveVerificationExcluded: hasPositiveVerificationExcluded,
		HasRewardsExcluded:              hasRewardsExcluded,
	}, nil
}

func requestCreditsQuery(caps requestCreditSourceCapabilities, bounded bool) string {
	policyExpr := "'legacy'"
	if caps.HasSettlementPolicyMode {
		policyExpr = "COALESCE(lrc.settlement_policy_mode, 'legacy')"
	}
	verifiedExpr := "0"
	if caps.HasSpec022PayableView {
		verifiedExpr = fmt.Sprintf(`CASE
           WHEN %s = 'enforce'
            AND EXISTS (SELECT 1 FROM spec022_payable_request_credits payable WHERE payable.id = lrc.id)
           THEN 1 ELSE 0
       END`, policyExpr)
	}
	requestedPrivacyExpr := "'none'"
	if caps.HasRequestedPrivacyMode {
		requestedPrivacyExpr = "COALESCE(lrc.requested_privacy_mode, 'none')"
	}
	effectivePrivacyExpr := "'plaintext'"
	if caps.HasEffectivePrivacyOutcome {
		effectivePrivacyExpr = "COALESCE(lrc.effective_privacy_outcome, 'plaintext')"
	}
	positiveExcludedExpr := "0"
	if caps.HasPositiveVerificationExcluded {
		positiveExcludedExpr = "COALESCE(lrc.positive_verification_excluded, 0)"
	}
	rewardsExcludedExpr := "0"
	if caps.HasRewardsExcluded {
		rewardsExcludedExpr = "COALESCE(lrc.rewards_excluded, 0)"
	}
	where := "WHERE lrc.id > ?"
	if bounded {
		where += "\n   AND lrc.id <= ?"
	}
	return fmt.Sprintf(`
SELECT lrc.id, lrc.request_id, lrc.attempt_n, lrc.provider_id, lrc.ts_utc, lrc.created_at_utc, lrc.updated_at_utc,
       lrc.prompt_tokens, lrc.completion_tokens, lrc.estimated_completion_tokens, lrc.usage_source,
       lrc.provider_credits, lrc.fault_flag, lrc.quarantined,
       %s AS settlement_policy_mode,
       %s AS spec022_verified,
       %s AS requested_privacy_mode, %s AS effective_privacy_outcome,
       %s AS positive_verification_excluded, %s AS rewards_excluded
  FROM ledger_request_credits lrc
 %s
 ORDER BY lrc.id
 LIMIT ?`, policyExpr, verifiedExpr, requestedPrivacyExpr, effectivePrivacyExpr, positiveExcludedExpr, rewardsExcludedExpr, where)
}

func sqliteColumnExists(ctx context.Context, db *sql.DB, table, column string) (bool, error) {
	rows, err := db.QueryContext(ctx, `PRAGMA table_info(`+table+`)`)
	if err != nil {
		return false, fmt.Errorf("inspect sqlite table %s: %w", table, err)
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

func sqliteObjectExists(ctx context.Context, db *sql.DB, name string) (bool, error) {
	var exists bool
	err := db.QueryRowContext(ctx, `
        SELECT EXISTS (
            SELECT 1 FROM sqlite_master
             WHERE name = ?
               AND type IN ('table', 'view')
        )
    `, name).Scan(&exists)
	return exists, err
}

func scanRequestCredits(ctx context.Context, db *sql.DB, q string, args ...any) ([]RequestCredit, error) {
	cur, err := db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("select ledger_request_credits: %w", err)
	}
	defer cur.Close()
	var out []RequestCredit
	for cur.Next() {
		var row RequestCredit
		var ts, created sql.NullString
		var updated sql.NullString
		var quarantined, spec022Verified, positiveExcluded, rewardsExcluded int
		if err := cur.Scan(
			&row.SQLiteID, &row.RequestID, &row.AttemptN, &row.ProviderID,
			&ts, &created, &updated,
			&row.PromptTokens, &row.CompletionTokens, &row.EstimatedCompletionTokens,
			&row.UsageSource, &row.ProviderCredits, &row.FaultFlag, &quarantined,
			&row.SettlementPolicyMode, &spec022Verified,
			&row.RequestedPrivacyMode, &row.EffectivePrivacyOutcome, &positiveExcluded, &rewardsExcluded,
		); err != nil {
			return nil, fmt.Errorf("scan ledger_request_credits: %w", err)
		}
		row.TSUTC, err = parseRequiredTime(ts, "ts_utc")
		if err != nil {
			return nil, err
		}
		row.CreatedAtUTC, err = parseRequiredTime(created, "created_at_utc")
		if err != nil {
			return nil, err
		}
		row.UpdatedAtUTC, err = parseOptionalTime(updated)
		if err != nil {
			return nil, fmt.Errorf("updated_at_utc: %w", err)
		}
    VALUES (p_source, p_last_request_credit_id, p_sweep_after_request_credit_id, now())
    ON CONFLICT (source) DO UPDATE SET
        last_request_credit_id = GREATEST(stats_billing_mirror_state.last_request_credit_id, EXCLUDED.last_request_credit_id),
        sweep_after_request_credit_id = EXCLUDED.sweep_after_request_credit_id,
        updated_at = EXCLUDED.updated_at;
$$`,
	`CREATE OR REPLACE FUNCTION stats_billing_mirror_ensure_provider(
    p_token_hash TEXT,
    p_provider_id TEXT,
    p_provider_name TEXT,
    p_created_at TIMESTAMPTZ,
    p_last_used_at TIMESTAMPTZ
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
    SELECT p_token_hash, 'stats-mirror', p_provider_id, p_provider_name, p_created_at, p_last_used_at
    WHERE NOT EXISTS (
        SELECT 1 FROM provider_tokens WHERE provider_id = p_provider_id AND provider_id <> ''
    )
    ON CONFLICT (token_hash) DO UPDATE SET
        provider_id = EXCLUDED.provider_id,
        provider_name = EXCLUDED.provider_name,
        last_used_at = EXCLUDED.last_used_at;
$$`,
	`CREATE OR REPLACE FUNCTION stats_billing_mirror_upsert_request_credit(
    p_sqlite_lrc_id BIGINT,
    p_request_id TEXT,
    p_attempt_n INTEGER,
    p_provider_id TEXT,
    p_ts_utc TIMESTAMPTZ,
    p_created_at_utc TIMESTAMPTZ,
    p_updated_at_utc TIMESTAMPTZ,
    p_prompt_tokens BIGINT,
    p_completion_tokens BIGINT,
    p_estimated_completion_tokens BIGINT,
    p_usage_source TEXT,
    p_provider_credits BIGINT,
    p_fault_flag TEXT,
    p_quarantined BOOLEAN,
    p_settlement_policy_mode TEXT,
    p_spec022_verified BOOLEAN,
    p_requested_privacy_mode TEXT,
    p_effective_privacy_outcome TEXT,
    p_positive_verification_excluded BOOLEAN,
    p_rewards_excluded BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_settlement_policy_mode TEXT := COALESCE(NULLIF(p_settlement_policy_mode, ''), 'legacy');
    v_spec022_verified BOOLEAN;
    v_was_spec022_verified BOOLEAN;
BEGIN
    IF v_settlement_policy_mode NOT IN ('legacy','observe','enforce') THEN
        RAISE EXCEPTION 'invalid settlement_policy_mode: %', v_settlement_policy_mode;
    END IF;

    v_spec022_verified :=
        v_settlement_policy_mode = 'enforce'
        AND COALESCE(p_spec022_verified, FALSE)
        AND COALESCE(p_provider_credits, 0) > 0
        AND NOT COALESCE(p_quarantined, FALSE);

    SELECT spec022_verified
      INTO v_was_spec022_verified
      FROM ledger_request_credits
     WHERE request_id = p_request_id
       AND attempt_n = p_attempt_n
       AND provider_id = p_provider_id
     FOR UPDATE;

    INSERT INTO ledger_request_credits (
        sqlite_lrc_id, request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
        prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
        provider_credits, fault_flag, quarantined, settlement_policy_mode, spec022_verified,
        requested_privacy_mode, effective_privacy_outcome, positive_verification_excluded, rewards_excluded
    ) VALUES (
        p_sqlite_lrc_id, p_request_id, p_attempt_n, p_provider_id, p_ts_utc, p_created_at_utc, p_updated_at_utc,
        p_prompt_tokens, p_completion_tokens, p_estimated_completion_tokens, p_usage_source,
        p_provider_credits, p_fault_flag, COALESCE(p_quarantined, FALSE), v_settlement_policy_mode, v_spec022_verified,
        COALESCE(NULLIF(p_requested_privacy_mode, ''), 'none'), COALESCE(NULLIF(p_effective_privacy_outcome, ''), 'plaintext'),
        COALESCE(p_positive_verification_excluded, FALSE), COALESCE(p_rewards_excluded, FALSE)
    )
    ON CONFLICT (request_id, attempt_n, provider_id) DO UPDATE SET
        sqlite_lrc_id = EXCLUDED.sqlite_lrc_id,
        ts_utc = EXCLUDED.ts_utc,
        created_at_utc = EXCLUDED.created_at_utc,
        updated_at_utc = EXCLUDED.updated_at_utc,
        prompt_tokens = EXCLUDED.prompt_tokens,
        completion_tokens = EXCLUDED.completion_tokens,
        estimated_completion_tokens = EXCLUDED.estimated_completion_tokens,
        usage_source = EXCLUDED.usage_source,
        provider_credits = EXCLUDED.provider_credits,
        fault_flag = EXCLUDED.fault_flag,
        quarantined = EXCLUDED.quarantined,
        settlement_policy_mode = EXCLUDED.settlement_policy_mode,
        spec022_verified = EXCLUDED.spec022_verified,
        requested_privacy_mode = EXCLUDED.requested_privacy_mode,
        effective_privacy_outcome = EXCLUDED.effective_privacy_outcome,
        positive_verification_excluded = EXCLUDED.positive_verification_excluded,
        rewards_excluded = EXCLUDED.rewards_excluded;

    IF v_spec022_verified AND NOT COALESCE(v_was_spec022_verified, FALSE) THEN
        INSERT INTO ledger_request_credit_spec022_verified_audit (
            request_id, attempt_n, provider_id, sqlite_lrc_id,
            provider_credits, settlement_policy_mode
        ) VALUES (
            p_request_id, p_attempt_n, p_provider_id, p_sqlite_lrc_id,
            p_provider_credits, v_settlement_policy_mode
        )
        ON CONFLICT (request_id, attempt_n, provider_id) DO NOTHING;
    END IF;
END;
$$`,
	`DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_rollup') THEN
        GRANT SELECT ON ledger_request_credits TO stats_rollup;
        GRANT SELECT ON provider_tokens TO stats_rollup;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rewards_writer') THEN
        GRANT SELECT ON ledger_request_credits TO rewards_writer;
    END IF;
    REVOKE ALL ON FUNCTION stats_billing_mirror_load_state(TEXT) FROM PUBLIC;
    REVOKE ALL ON FUNCTION stats_billing_mirror_save_state(TEXT, BIGINT, BIGINT) FROM PUBLIC;
    REVOKE ALL ON FUNCTION stats_billing_mirror_ensure_provider(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
    IF EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname = 'stats_billing_mirror_upsert_request_credit'
           AND p.pronargs = 14
    ) THEN
        REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN) FROM PUBLIC;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
            REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN) FROM stats_billing_mirror_writer;
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname = 'stats_billing_mirror_upsert_request_credit'
           AND p.pronargs = 16
    ) THEN
        REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) FROM PUBLIC;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
            REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) FROM stats_billing_mirror_writer;
        END IF;
    END IF;
    REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN, BOOLEAN) FROM PUBLIC;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
        REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
        REVOKE ALL ON provider_tokens FROM stats_billing_mirror_writer;
        REVOKE ALL ON stats_billing_mirror_state FROM stats_billing_mirror_writer;
        REVOKE ALL ON ledger_request_credit_spec022_verified_audit FROM stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_load_state(TEXT) TO stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_save_state(TEXT, BIGINT, BIGINT) TO stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_ensure_provider(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN, BOOLEAN) TO stats_billing_mirror_writer;
    END IF;
END $$`,

exec
/bin/bash -lc "sed -n '1,115p' phase4-coordinator/dist/stats-billing-mirror.service; sed -n '1,130p' phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
[Unit]
Description=MacProvider stats billing mirror
Documentation=https://github.com/augstar/macprovider-poc
Wants=network-online.target
After=network-online.target
ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env
ConditionPathExists=/var/lib/macprovider/coordinator.db

[Service]
Type=oneshot
User=macprovider-stats
Group=macprovider-stats
EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env
ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/var/lib/macprovider/coordinator.db
ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
InaccessiblePaths=/etc/macprovider
InaccessiblePaths=-/opt/macprovider/coordinator.yaml
#!/usr/bin/env bash
# check_stats_billing_mirror_deploy_test.sh — offline validation for the
# stats billing mirror sidecar deploy wiring.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_SH="$DIST_DIR/deploy-pearl-vps.sh"
SERVICE="$DIST_DIR/stats-billing-mirror.service"
TIMER="$DIST_DIR/stats-billing-mirror.timer"
ENV_EXAMPLE="$DIST_DIR/stats-billing-mirror.env.example"
BOOTSTRAP_SQL="$DIST_DIR/stats-billing-mirror-bootstrap.sql"
MIGRATION_SQL="$DIST_DIR/../internal/stats/migrations/029_stats_billing_mirror_privacy_columns.up.sql"
MIRROR_GO="$DIST_DIR/../internal/stats/billingmirror/mirror.go"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in "$DEPLOY_SH" "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$BOOTSTRAP_SQL" "$MIGRATION_SQL" "$MIRROR_GO"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

grep -qF 'STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror binary variable"
grep -qF 'STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror service variable"
grep -qF 'STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror timer variable"
grep -qF '$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror binary upload"
grep -qF 'for f in "$BINARY" "$CLI_BINARY" "$STATS_INVENTORY_BINARY" "$STATS_BILLING_MIRROR_BINARY"' "$DEPLOY_SH" ||
  fail "deploy preflight must require billing mirror binary"
grep -qF '"$STATS_BILLING_MIRROR_SERVICE" "$STATS_BILLING_MIRROR_TIMER"' "$DEPLOY_SH" ||
  fail "deploy preflight must require billing mirror unit files"
grep -qF '$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror service upload"
grep -qF '$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror timer upload"
grep -qF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror binary install"
grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
  fail "deploy script must grant narrow SQLite file ACL"
grep -qF "echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'" "$DEPLOY_SH" ||
  fail "deploy script must keep setfacl warning single-quoted inside SSH install block"
grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
  fail "deploy script must only enable mirror when stats user can read sqlite source"
grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror service install"
grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror timer install"
grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
  fail "deploy script must only enable timer when env and SQLite source exist"
grep -qF 'systemctl disable --now stats-billing-mirror.timer' "$DEPLOY_SH" ||
  fail "deploy script must disable the billing mirror timer after a failed initial run"
grep -qF 'aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run' "$DEPLOY_SH" ||
  fail "deploy script must fail closed when the configured billing mirror cannot run"

grep -qxF 'User=macprovider-stats' "$SERVICE" ||
  fail "billing mirror must run as dedicated stats user"
grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
  fail "billing mirror must run with dedicated stats group"
grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
  fail "billing mirror service must be opt-in on env file"
grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
  fail "billing mirror service must require the SQLite source"
grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
  fail "billing mirror service must read isolated env file"
grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
  fail "billing mirror service must execute from deploy path"
grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
  fail "billing mirror service must read only the SQLite source"
# The mirror's source DB must never also be inaccessible: systemd applies
# InaccessiblePaths over ReadOnlyPaths, which hid the ledger and failed the
# deploy's initial mirror run.
source_db=$(sed -n 's/^ExecStart=.* --sqlite \([^ ]*\) .*/\1/p' "$SERVICE")
[ -n "$source_db" ] || fail "stats billing mirror ExecStart must name its --sqlite source"
if grep -qE "^InaccessiblePaths=-?${source_db}(-wal|-shm)?$" "$SERVICE"; then
  fail "stats billing mirror source DB $source_db must not be listed in InaccessiblePaths"
fi
grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||
  fail "billing mirror service must not access coordinator secrets"
grep -qxF 'OnUnitActiveSec=60s' "$TIMER" ||
  fail "billing mirror timer must run frequently enough for public stats"
grep -qF 'stats_billing_mirror_writer' "$ENV_EXAMPLE" ||
  fail "env example must document dedicated writer role"
grep -qF 'STATS_BILLING_MIRROR_DSN=' "$ENV_EXAMPLE" ||
  fail "env example must define the expected DSN variable"
grep -qF 'runs with --ensure-schema=false' "$ENV_EXAMPLE" ||
  fail "env example must document bootstrap-before-service contract"
grep -qF 'CREATE TABLE IF NOT EXISTS ledger_request_credits' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must create ledger_request_credits"
grep -qF 'settlement_policy_mode TEXT' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must carry settlement policy mode column"
grep -qF 'spec022_verified BOOLEAN' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must carry SPEC-022 verified column"
grep -qF 'lrc_mirror_spec022_verified_enforce_check' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must constrain SPEC-022 verified rows to enforce mode"
grep -qF 'CREATE TABLE IF NOT EXISTS ledger_request_credit_spec022_verified_audit' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must create SPEC-022 verified audit table"
if grep -qF "PASSWORD 'REPLACE_ME'" "$BOOTSTRAP_SQL"; then
  fail "bootstrap SQL must not create a known default password"
fi
grep -qF 'RAISE EXCEPTION' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must fail if writer role is missing"
grep -qF 'CREATE TABLE IF NOT EXISTS provider_tokens' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must create provider_tokens"
grep -qF 'GRANT SELECT ON ledger_request_credits TO stats_rollup' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must grant rollup read access"
grep -qF 'GRANT SELECT ON ledger_request_credits TO rewards_writer' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must grant rewards writer read access"
grep -qF 'REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must revoke direct writer table DML"
grep -qF 'REVOKE ALL ON ledger_request_credit_spec022_verified_audit FROM stats_billing_mirror_writer' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must revoke direct writer audit table DML"
grep -qF 'REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must revoke public function execute"
MIRROR_UPSERT_SIGNATURE='stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN, BOOLEAN)'
for sql in "$BOOTSTRAP_SQL" "$MIGRATION_SQL"; do
  grep -qF "GRANT EXECUTE ON FUNCTION $MIRROR_UPSERT_SIGNATURE TO stats_billing_mirror_writer" "$sql" ||
    fail "$sql must grant only the 20-argument mirror upsert function"
  for column in requested_privacy_mode effective_privacy_outcome positive_verification_excluded rewards_excluded; do
    grep -qF "$column" "$sql" || fail "$sql missing mirror column $column"
  done
done
if grep -qF 'GRANT EXECUTE ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) TO stats_billing_mirror_writer' "$BOOTSTRAP_SQL" "$MIGRATION_SQL"; then
  fail "bootstrap/migration must not grant the legacy 16-argument mirror upsert"
fi

codex
The source trace shows the mirror opens SQLite through `sqliteutil.ReadOnlyDSN` (`mode=ro` plus `query_only(true)`), and all write operations are on the separate Postgres handle. The unit now combines read-only path protection with no source-DB `InaccessiblePaths`; secrets remain hidden under `/etc/macprovider` and the coordinator config path. I’m validating these conclusions with the existing package and deployment/recovery tests.
exec
/bin/bash -lc 'go test ./internal/stats/billingmirror' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-mirror-dbpath
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh' in /Users/augstar/macprovider-mirror-dbpath
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 812ms:
ok: stats billing mirror deploy wiring

 succeeded in 865ms:
ok  	github.com/augstar/macprovider-coordinator/internal/stats/billingmirror	(cached)

 succeeded in 5643ms:
/var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/tmp.MmNBTjbcSy: line 1: 16184 Alarm clock: 14         python3 -c '
import os
import signal
import sys

timeout_s = int(sys.argv[1])
if timeout_s < 1:
    raise SystemExit("deadline must be at least one second")
signal.alarm(timeout_s)
os.execvp(sys.argv[2], sys.argv[2:])
' "$timeout_s" "$@"
PASS: deploy autotune feed access guards present

 succeeded in 18754ms:
PASS: coordinator deploy recovery is durable and state-exact

exec
/bin/bash -lc "rg -n \"ReadOnlyDSN|query_only|mode=ro|DefaultSQLitePath|STATS_BILLING_MIRROR_SQLITE|OpenSQLite\" phase4-coordinator --glob '*_test.go' --glob '*.sh' | sed -n '1,260p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:45:	db, err := OpenSQLite(dbPath)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:47:		t.Fatalf("OpenSQLite() error = %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:97:	db, err := OpenSQLite(dbPath)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:99:		t.Fatalf("OpenSQLite() error = %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:120:	db, err := OpenSQLite(dbPath)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:122:		t.Fatalf("OpenSQLite() error = %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:137:	db, err := OpenSQLite(dbPath)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:139:		t.Fatalf("OpenSQLite() error = %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:171:	db, err := OpenSQLite(dbPath)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:173:		t.Fatalf("OpenSQLite() error = %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:207:	source, err := OpenSQLite(path)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:209:		t.Fatalf("OpenSQLite() error = %v", err)

exec
/bin/bash -lc "sed -n '1,225p' phase4-coordinator/internal/stats/billingmirror/mirror_test.go; sed -n '225,380p' phase4-coordinator/internal/stats/billingmirror/mirror_test.go" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 19ms:
package billingmirror

import (
	"bytes"
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

func TestRunDryRunReadsSQLiteWithoutPostgresDSN(t *testing.T) {
	dbPath := seedSQLite(t)
	var out bytes.Buffer
	res, err := Run(context.Background(), Options{
		SQLitePath:  dbPath,
		DryRun:      true,
		BatchSize:   10,
		OverlapRows: 1,
		SweepRows:   1,
		Stdout:      &out,
	})
	if err != nil {
		t.Fatalf("Run(dry-run) error = %v", err)
	}
	if res.RequestRowsRead != 2 {
		t.Fatalf("RequestRowsRead = %d, want 2", res.RequestRowsRead)
	}
	if res.ProviderRowsRead != 1 {
		t.Fatalf("ProviderRowsRead = %d, want 1", res.ProviderRowsRead)
	}
	if res.LastRequestID != 2 {
		t.Fatalf("LastRequestID = %d, want 2", res.LastRequestID)
	}
	if got := out.String(); !strings.Contains(got, "would upsert 2 request credit rows and ensure 1 provider identities") {
		t.Fatalf("dry-run output = %q", got)
	}
}

func TestFetchRequestCreditsParsesEffectiveStatsColumns(t *testing.T) {
	dbPath := seedSQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	rows, err := FetchRequestCredits(context.Background(), db, 0, 10)
	if err != nil {
		t.Fatalf("FetchRequestCredits() error = %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("len(rows) = %d, want 2", len(rows))
	}
	first := rows[0]
	if first.RequestID != "req-1" || first.AttemptN != 0 || first.ProviderID != "provider-a" {
		t.Fatalf("first identity = %#v", first)
	}
	if !first.PromptTokens.Valid || first.PromptTokens.Int64 != 100 {
		t.Fatalf("prompt tokens = %#v, want 100", first.PromptTokens)
	}
	if !first.CompletionTokens.Valid || first.CompletionTokens.Int64 != 200 {
		t.Fatalf("completion tokens = %#v, want 200", first.CompletionTokens)
	}
	if first.Quarantined {
		t.Fatal("first.Quarantined = true, want false")
	}
	if first.SettlementPolicyMode != "enforce" {
		t.Fatalf("first settlement policy = %q, want enforce", first.SettlementPolicyMode)
	}
	if !first.Spec022Verified {
		t.Fatal("first.Spec022Verified = false, want true")
	}
	second := rows[1]
	if second.UsageSource != "byte_estimated" {
		t.Fatalf("second usage source = %q, want byte_estimated", second.UsageSource)
	}
	if second.CompletionTokens.Valid {
		t.Fatalf("second completion tokens = %#v, want NULL", second.CompletionTokens)
	}
	if !second.EstimatedCompletionTokens.Valid || second.EstimatedCompletionTokens.Int64 != 44 {
		t.Fatalf("second estimated completion = %#v, want 44", second.EstimatedCompletionTokens)
	}
	if !second.Quarantined {
		t.Fatal("second.Quarantined = false, want true")
	}
	if second.Spec022Verified {
		t.Fatal("second.Spec022Verified = true, want false")
	}
}

func TestFetchRequestCreditsSupportsLegacySourceSchema(t *testing.T) {
	dbPath := seedLegacySQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	rows, err := FetchRequestCredits(context.Background(), db, 0, 10)
	if err != nil {
		t.Fatalf("FetchRequestCredits() error = %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("len(rows) = %d, want 1", len(rows))
	}
	if got := rows[0].SettlementPolicyMode; got != "legacy" {
		t.Fatalf("SettlementPolicyMode = %q, want legacy", got)
	}
	if rows[0].Spec022Verified {
		t.Fatal("Spec022Verified = true, want false for legacy source schema")
	}
}

func TestFetchMaxRequestCreditID(t *testing.T) {
	dbPath := seedSQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	maxID, err := FetchMaxRequestCreditID(context.Background(), db)
	if err != nil {
		t.Fatalf("FetchMaxRequestCreditID() error = %v", err)
	}
	if maxID != 2 {
		t.Fatalf("maxID = %d, want 2", maxID)
	}
}

func TestFetchRequestCreditsThroughReplaysOnlyBoundedOverlap(t *testing.T) {
	dbPath := seedSQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	rows, err := FetchRequestCreditsThrough(context.Background(), db, 0, 1, 10)
	if err != nil {
		t.Fatalf("FetchRequestCreditsThrough() error = %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("len(rows) = %d, want 1", len(rows))
	}
	if rows[0].SQLiteID != 1 {
		t.Fatalf("SQLiteID = %d, want 1", rows[0].SQLiteID)
	}
}

func TestMaxSQLiteIDOnlyUsesSequentialNewRows(t *testing.T) {
	newRows := []RequestCredit{{SQLiteID: 11}, {SQLiteID: 12}}
	recentReplay := []RequestCredit{{SQLiteID: 99}}
	next := maxSQLiteID(newRows, 10)
	if next != 12 {
		t.Fatalf("next = %d, want 12", next)
	}
	if got := maxSQLiteID(recentReplay, next); got != 99 {
		t.Fatalf("sanity max = %d, want 99", got)
	}
	// Run intentionally calls maxSQLiteID before merging recentReplay so a
	// recently updated high-ID row cannot skip unfetched IDs 13..98.
}

func TestFetchProviderIdentitiesDoesNotRequireTokenHashes(t *testing.T) {
	dbPath := seedSQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	providers, err := FetchProviderIdentities(context.Background(), db)
	if err != nil {
		t.Fatalf("FetchProviderIdentities() error = %v", err)
	}
	if len(providers) != 1 {
		t.Fatalf("len(providers) = %d, want 1", len(providers))
	}
	if providers[0].ProviderID != "provider-a" {
		t.Fatalf("provider id = %q, want provider-a", providers[0].ProviderID)
	}
	if providers[0].ProviderName != "Provider A" {
		t.Fatalf("provider name = %q, want Provider A", providers[0].ProviderName)
	}
	if !providers[0].LastUsedAt.Valid {
		t.Fatal("LastUsedAt.Valid = false, want true")
	}
}

func TestFetchProviderIdentitiesFailsWhenTrustSourceMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "request-log.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY)`); err != nil {
		t.Fatalf("seed sqlite: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close sqlite: %v", err)
	}
	source, err := OpenSQLite(path)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer source.Close()
	_, err = FetchProviderIdentities(context.Background(), source)
	if err == nil || !strings.Contains(err.Error(), "provider_tokens") {
		t.Fatalf("FetchProviderIdentities() error = %v, want provider_tokens failure", err)
	}
}

func TestMergeRequestCreditsDeduplicatesNaturalKey(t *testing.T) {
	old := RequestCredit{SQLiteID: 10, RequestID: "req", AttemptN: 0, ProviderID: "p", ProviderCredits: 1}
	updated := old
	updated.ProviderCredits = 2
	rows := mergeRequestCredits([]RequestCredit{old}, []RequestCredit{updated})
	if len(rows) != 1 {
		t.Fatalf("len(rows) = %d, want 1", len(rows))
	}
	}
	if rows[0].ProviderCredits != 2 {
		t.Fatalf("ProviderCredits = %d, want updated value 2", rows[0].ProviderCredits)
	}
}

func TestSyntheticTokenHashDoesNotExposeProviderID(t *testing.T) {
	got := syntheticTokenHash("provider-secret")
	if !strings.HasPrefix(got, "stats-mirror-sha256:") {
		t.Fatalf("hash = %q, want stats mirror prefix", got)
	}
	if strings.Contains(got, "provider-secret") {
		t.Fatalf("hash exposes provider id: %q", got)
	}
	if got != syntheticTokenHash("provider-secret") {
		t.Fatal("syntheticTokenHash is not deterministic")
	}
}

func seedSQLite(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "request-log.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open sqlite seed db: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`
CREATE TABLE ledger_request_credits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    ts_utc TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NULL,
    prompt_tokens INTEGER NULL,
    completion_tokens INTEGER NULL,
    estimated_completion_tokens INTEGER NULL,
    usage_source TEXT NOT NULL,
    provider_credits INTEGER NOT NULL,
    fault_flag TEXT NOT NULL,
    quarantined INTEGER NOT NULL,
    settlement_policy_mode TEXT NOT NULL DEFAULT 'legacy'
);
CREATE VIEW spec022_payable_request_credits AS
SELECT *
  FROM ledger_request_credits
 WHERE quarantined = 0
   AND settlement_policy_mode = 'enforce';
CREATE TABLE provider_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    provider_id TEXT NOT NULL DEFAULT '',
    provider_name TEXT NOT NULL,
    created_at TEXT NOT NULL,
    revoked_at TEXT DEFAULT NULL,
    last_used_at TEXT DEFAULT NULL
);
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
    prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
    provider_credits, fault_flag, quarantined, settlement_policy_mode
) VALUES
    ('req-1', 0, 'provider-a', '2026-07-05T08:59:00Z', '2026-07-05T08:59:01Z', NULL,
     100, 200, NULL, 'provider_reported', 300, 'none', 0, 'enforce'),
    ('req-2', 0, 'provider-a', '2026-07-05T09:01:00Z', '2026-07-05T09:01:01Z', '2026-07-05T09:02:00Z',
     33, NULL, 44, 'byte_estimated', 0, 'none', 1, 'enforce');
INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
VALUES ('hash-a', 'hash-a', 'provider-a', 'Provider A', '2026-07-05T08:00:00Z', '2026-07-05T09:00:00Z');
`); err != nil {
		t.Fatalf("seed sqlite: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close sqlite seed db: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("stat seed sqlite: %v", err)
	}
	return path
}

func seedLegacySQLite(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "legacy-request-log.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open legacy sqlite seed db: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`
CREATE TABLE ledger_request_credits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    ts_utc TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NULL,
    prompt_tokens INTEGER NULL,
    completion_tokens INTEGER NULL,
    estimated_completion_tokens INTEGER NULL,
    usage_source TEXT NOT NULL,
    provider_credits INTEGER NOT NULL,
    fault_flag TEXT NOT NULL,
    quarantined INTEGER NOT NULL
);
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
    prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
    provider_credits, fault_flag, quarantined
) VALUES (
    'legacy-req', 0, 'provider-legacy', '2026-07-05T08:59:00Z', '2026-07-05T08:59:01Z', NULL,
    10, 20, NULL, 'provider_reported', 30, 'none', 0
);
`); err != nil {
		t.Fatalf("seed legacy sqlite: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close legacy sqlite seed db: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("stat legacy seed sqlite: %v", err)
	}
	return path
}

exec
/bin/bash -lc "rg -n \"CREATE TABLE|provider_payout|payout|private|secret|token|auth|ledger_request_credits|request_log\" phase4-coordinator/internal phase4-coordinator/migrations phase4-coordinator --glob '*.sql' --glob '*.go' | sed -n '1,360p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
rg: phase4-coordinator/migrations: No such file or directory (os error 2)
phase4-coordinator/tools/mockprovider/main_test.go:102:	tokenPath := filepath.Join(dir, "provider.token")
phase4-coordinator/tools/mockprovider/main_test.go:103:	if err := os.WriteFile(tokenPath, []byte("canary-token\n"), 0o600); err != nil {
phase4-coordinator/tools/mockprovider/main_test.go:104:		t.Fatalf("write token: %v", err)
phase4-coordinator/tools/mockprovider/main_test.go:107:	token, ok, err := readProviderToken(tokenPath)
phase4-coordinator/tools/mockprovider/main_test.go:112:		t.Fatal("readProviderToken did not report a token")
phase4-coordinator/tools/mockprovider/main_test.go:114:	if token != "canary-token" {
phase4-coordinator/tools/mockprovider/main_test.go:115:		t.Fatalf("token = %q, want trimmed token", token)
phase4-coordinator/tools/mockprovider/main_test.go:121:	tokenPath := filepath.Join(dir, "provider.token")
phase4-coordinator/tools/mockprovider/main_test.go:122:	if err := os.WriteFile(tokenPath, []byte(" \n"), 0o600); err != nil {
phase4-coordinator/tools/mockprovider/main_test.go:123:		t.Fatalf("write token: %v", err)
phase4-coordinator/tools/mockprovider/main_test.go:126:	if _, _, err := readProviderToken(tokenPath); err == nil {
phase4-coordinator/tools/mockprovider/main_test.go:127:		t.Fatal("readProviderToken accepted an empty token file")
phase4-coordinator/tools/mockprovider/main_test.go:141:	tokenPath := filepath.Join(dir, "provider.token")
phase4-coordinator/tools/mockprovider/main_test.go:143:	if err := os.WriteFile(tokenPath, large, 0o600); err != nil {
phase4-coordinator/tools/mockprovider/main_test.go:144:		t.Fatalf("write token: %v", err)
phase4-coordinator/tools/mockprovider/main_test.go:147:	if _, _, err := readProviderToken(tokenPath); err == nil {
phase4-coordinator/tools/mockprovider/main_test.go:154:	tokenPath := filepath.Join(dir, "provider.token")
phase4-coordinator/tools/mockprovider/main_test.go:155:	if err := os.WriteFile(tokenPath, []byte("canary-token\n"), 0o600); err != nil {
phase4-coordinator/tools/mockprovider/main_test.go:156:		t.Fatalf("write token: %v", err)
phase4-coordinator/tools/mockprovider/main_test.go:158:	if err := os.Chmod(tokenPath, 0o640); err != nil {
phase4-coordinator/tools/mockprovider/main_test.go:159:		t.Fatalf("chmod token: %v", err)
phase4-coordinator/tools/mockprovider/main_test.go:162:	if _, _, err := readProviderToken(tokenPath); err == nil {
phase4-coordinator/tools/mockprovider/main_test.go:169:	targetPath := filepath.Join(dir, "target.token")
phase4-coordinator/tools/mockprovider/main_test.go:170:	linkPath := filepath.Join(dir, "provider.token")
phase4-coordinator/tools/mockprovider/main_test.go:171:	if err := os.WriteFile(targetPath, []byte("canary-token\n"), 0o600); err != nil {
phase4-coordinator/tools/mockprovider/main_test.go:172:		t.Fatalf("write token: %v", err)
phase4-coordinator/tools/mockprovider/main_test.go:175:		t.Fatalf("symlink token: %v", err)
phase4-coordinator/tools/mockprovider/main_test.go:190:	if _, err := parseProviderToken([]byte("canary token\n")); err == nil {
phase4-coordinator/tools/mockprovider/main_test.go:191:		t.Fatal("parseProviderToken accepted whitespace inside token")
phase4-coordinator/tools/mockprovider/main_test.go:201:		providerTokenFile: filepath.Join(dir, "missing.token"),
phase4-coordinator/tools/mockprovider/main_test.go:205:		t.Fatal("run returned 0 for an invalid provider token file")
phase4-coordinator/tools/mockprovider/main_test.go:214:	tokenPath := filepath.Join(dir, "provider.token")
phase4-coordinator/tools/mockprovider/main_test.go:215:	if err := os.WriteFile(tokenPath, []byte("canary-token\n"), 0o600); err != nil {
phase4-coordinator/tools/mockprovider/main_test.go:216:		t.Fatalf("write token: %v", err)
phase4-coordinator/tools/mockprovider/main_test.go:223:		providerTokenFile: tokenPath,
phase4-coordinator/tools/mockprovider/main_test.go:227:		t.Fatal("run returned 0 for unsafe provider token transport")
phase4-coordinator/tools/mockprovider/main_test.go:346:	header := providerAuthHeader(" canary-token ")
phase4-coordinator/tools/mockprovider/main_test.go:348:		t.Fatal("providerAuthHeader returned nil for a token")
phase4-coordinator/tools/mockprovider/main_test.go:355:	if got := buf.String(); !strings.Contains(got, "Authorization: Bearer canary-token\r\n") {
phase4-coordinator/tools/mockprovider/main_test.go:362:		t.Fatal("providerAuthHeader returned a header for a blank token")
phase4-coordinator/tools/mockprovider/main_test.go:386:		t.Fatal("validateTokenTransport accepted token-bearing non-loopback ws")
phase4-coordinator/internal/github/client.go:15:	DefaultAuthorizeURL = "https://github.com/login/oauth/authorize"
phase4-coordinator/internal/github/client.go:16:	DefaultTokenURL     = "https://github.com/login/oauth/access_token"
phase4-coordinator/internal/github/client.go:38:		"client_secret": clientSecret,
phase4-coordinator/internal/github/client.go:55:		return "", fmt.Errorf("github token exchange status %d", resp.StatusCode)
phase4-coordinator/internal/github/client.go:58:		AccessToken string `json:"access_token"`
phase4-coordinator/internal/github/client.go:66:			out.Error = "missing_access_token"
phase4-coordinator/internal/github/client.go:68:		return "", fmt.Errorf("github token exchange failed: %s", out.Error)
phase4-coordinator/cmd/coordinator-cli/trust_pool_oncall_sign_test.go:73:		t.Fatalf("signed output missing authority fields: %+v", signed)
phase4-coordinator/tools/spec032canary/main.go:27:	"github.com/augstar/macprovider-coordinator/internal/auth"
phase4-coordinator/tools/spec032canary/main.go:196:	flag.StringVar(&opts.runRoot, "run-root", "", "local run root; defaults under the operator secret store")
phase4-coordinator/tools/spec032canary/main.go:214:	base := filepath.Join(home, ".config", "macprovider", "operator-secrets", "spec032-runs")
phase4-coordinator/tools/spec032canary/main.go:550:		"active_tokens_before":    beforeTokens,
phase4-coordinator/tools/spec032canary/main.go:551:		"active_tokens_after":     afterTokens,
phase4-coordinator/tools/spec032canary/main.go:555:		return fmt.Errorf("R003 fail-closed reload not observed: last_reload=%+v before_tokens=%d after_tokens=%d", proof.LastReload, beforeTokens, afterTokens)
phase4-coordinator/tools/spec032canary/main.go:617:	for _, role := range []string{"provider_onboarding", "provider_auth_policy_requester", "provider_auth_policy_approver", "provider_auth_policy_cutover", "hardware_trust_requester", "hardware_trust_approver"} {
phase4-coordinator/tools/spec032canary/main.go:659:	store, err := auth.OpenStore(r.sqliteDB)
phase4-coordinator/tools/spec032canary/main.go:664:	if _, token, err := store.IssueToken(ctx, r.subject.ProviderID, r.subject.Name); err != nil {
phase4-coordinator/tools/spec032canary/main.go:667:		r.subject.Token = token
phase4-coordinator/tools/spec032canary/main.go:669:	if _, token, err := store.IssueToken(ctx, r.control.ProviderID, r.control.Name); err != nil {
phase4-coordinator/tools/spec032canary/main.go:672:		r.control.Token = token
phase4-coordinator/tools/spec032canary/main.go:705:	cfg.Onboarding.AuthPolicyRequestDSN = r.roleDSN("provider_auth_policy_requester")
phase4-coordinator/tools/spec032canary/main.go:706:	cfg.Onboarding.AuthPolicyApproveDSN = r.roleDSN("provider_auth_policy_approver")
phase4-coordinator/tools/spec032canary/main.go:707:	cfg.Onboarding.AuthPolicyCutoverDSN = r.roleDSN("provider_auth_policy_cutover")
phase4-coordinator/tools/spec032canary/main.go:794:	tokenPath := filepath.Join(r.runRoot, p.Role+".provider-token")
phase4-coordinator/tools/spec032canary/main.go:795:	if err := os.WriteFile(tokenPath, []byte(p.Token+"\n"), 0o600); err != nil {
phase4-coordinator/tools/spec032canary/main.go:798:	if err := r.scp(ctx, tokenPath, p.Host+":"+p.RemoteDir+"/provider-token"); err != nil {
phase4-coordinator/tools/spec032canary/main.go:807:	if err := r.ssh(ctx, p.Host, "chmod", "600", p.RemoteDir+"/provider-token"); err != nil {
phase4-coordinator/tools/spec032canary/main.go:822:	cmd := fmt.Sprintf("cd %s && (nohup ./mockprovider -coord-url %s -provider-id %s -model %s -ram-gb 8 -max-concurrency 1 -slots 1 -omit-endpoint-url -hb 1 -provider-token-file provider-token -heartbeat-override-file heartbeat-model.json -catalog-release-id %s -catalog-policy-version %s -catalog-candidate-sha256 %s -catalog-signer-key-id %s -catalog-row-identity %s > mockprovider.log 2>&1 & echo $! > provider.pid)",
phase4-coordinator/tools/spec032canary/main.go:1231:			"secrets_redacted":               true,
phase4-coordinator/tools/spec032canary/main.go:1276:	if err := db.QueryRow(`SELECT COUNT(1) FROM provider_tokens WHERE provider_id = ? AND revoked_at IS NULL`, providerID).Scan(&n); err != nil {
phase4-coordinator/cmd/coordinator-cli/main_test.go:16:	"github.com/augstar/macprovider-coordinator/internal/auth"
phase4-coordinator/cmd/coordinator-cli/main_test.go:27:			t.Fatalf("authorization = %q", got)
phase4-coordinator/cmd/coordinator-cli/main_test.go:42:		"--token-prefix", prefix,
phase4-coordinator/cmd/coordinator-cli/main_test.go:58:		"--token-prefix", prefix,
phase4-coordinator/cmd/coordinator-cli/main_test.go:63:	if err == nil || !strings.Contains(err.Error(), "token belongs to provider_id p1") {
phase4-coordinator/cmd/coordinator-cli/main_test.go:70:	store, err := auth.OpenStore(dbPath)
phase4-coordinator/cmd/coordinator-cli/main_test.go:76:	mint, err := store.MintBootstrapToken(context.Background(), auth.BootstrapMintRequest{
phase4-coordinator/cmd/coordinator-cli/main_test.go:117:	store, err = auth.OpenStore(dbPath)
phase4-coordinator/cmd/coordinator-cli/main_test.go:133:	store, err := auth.OpenStore(dbPath)
phase4-coordinator/cmd/coordinator-cli/main_test.go:156:	store, err := auth.OpenStore(dbPath)
phase4-coordinator/cmd/coordinator-cli/main_test.go:163:		t.Fatalf("issue token: %v", err)
phase4-coordinator/internal/tier2/pillar_c.go:30:	mockAttestationToken        = "mock-devicecheck-token"
phase4-coordinator/internal/tier2/pillar_c.go:59:	Token            string                 `json:"token"`
phase4-coordinator/internal/tier2/pillar_c.go:108:func VerifyAttestationTokenExt(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, authAttemptID, providerID, providerECDHPublicKey string, sePublicKey []byte, now time.Time, logger zerolog.Logger) AttestationVerifyResult {
phase4-coordinator/internal/tier2/pillar_c.go:109:	status, seResult, mdaHardware := verifyAttestationTokenInternal(raw, cfg, challenge, authAttemptID, providerID, providerECDHPublicKey, sePublicKey, now, logger, attestationModelHashCheck{})
phase4-coordinator/internal/tier2/pillar_c.go:119:func VerifyAttestationTokenExtWithCatalog(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, authAttemptID, providerID, providerECDHPublicKey, modelID string, catalog *Catalog, sePublicKey []byte, now time.Time, logger zerolog.Logger) AttestationVerifyResult {
phase4-coordinator/internal/tier2/pillar_c.go:120:	status, seResult, mdaHardware := verifyAttestationTokenInternal(raw, cfg, challenge, authAttemptID, providerID, providerECDHPublicKey, sePublicKey, now, logger, attestationModelHashCheck{
phase4-coordinator/internal/tier2/pillar_c.go:127:// VerifyAttestationToken verifies an attestation token and returns the status.
phase4-coordinator/internal/tier2/pillar_c.go:129:func VerifyAttestationToken(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, authAttemptID, providerID, providerECDHPublicKey string, now time.Time, logger zerolog.Logger) pool.AttestationStatus {
phase4-coordinator/internal/tier2/pillar_c.go:130:	status, _, _ := verifyAttestationTokenInternal(raw, cfg, challenge, authAttemptID, providerID, providerECDHPublicKey, nil, now, logger, attestationModelHashCheck{})
phase4-coordinator/internal/tier2/pillar_c.go:134:func verifyAttestationTokenInternal(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, authAttemptID, providerID, providerECDHPublicKey string, sePublicKey []byte, now time.Time, logger zerolog.Logger, modelHashCheck attestationModelHashCheck) (pool.AttestationStatus, *SEAttestationResult, bool) {
phase4-coordinator/internal/tier2/pillar_c.go:140:			logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "missing_token", "tier2.require_attestation")
phase4-coordinator/internal/tier2/pillar_c.go:143:		// A missing token is a capability absence, not an unsupported token
phase4-coordinator/internal/tier2/pillar_c.go:150:		logAttestationEvent(logger, "attestation_token_too_large", "WARN", providerID, "reject", "token_too_large", "tier2.attestation_max_age_s")
phase4-coordinator/internal/tier2/pillar_c.go:153:	var token AttestationToken
phase4-coordinator/internal/tier2/pillar_c.go:154:	if err := json.Unmarshal(raw, &token); err != nil {
phase4-coordinator/internal/tier2/pillar_c.go:158:	if !attestationFormatAllowed(token.Format, cfg.AttestationFormats) {
phase4-coordinator/internal/tier2/pillar_c.go:162:	if len(token.Token) > MaxAttestationTokenBytes {
phase4-coordinator/internal/tier2/pillar_c.go:163:		logAttestationEvent(logger, "attestation_token_too_large", "WARN", providerID, "reject", "token_too_large", "tier2.attestation_max_age_s")
phase4-coordinator/internal/tier2/pillar_c.go:166:	if !validAttestationTokenEncoding(token.Token) {
phase4-coordinator/internal/tier2/pillar_c.go:167:		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_token_encoding", "tier2.require_attestation")
phase4-coordinator/internal/tier2/pillar_c.go:170:	if token.ProviderID != providerID {
phase4-coordinator/internal/tier2/pillar_c.go:175:	if token.Challenge != wantChallenge {
phase4-coordinator/internal/tier2/pillar_c.go:179:	if strings.TrimSpace(providerECDHPublicKey) != "" && token.KeyBinding.ProviderECDHPublicKey != providerECDHPublicKey {
phase4-coordinator/internal/tier2/pillar_c.go:183:	if !attestationHardwareFamilyAllowed(token) {
phase4-coordinator/internal/tier2/pillar_c.go:190:	if token.IssuedAt.IsZero() || token.ExpiresAt.IsZero() || now.Before(token.IssuedAt.Add(-1*time.Minute)) || !now.Before(token.ExpiresAt) {
phase4-coordinator/internal/tier2/pillar_c.go:194:	if cfg.AttestationMaxAgeS > 0 && now.Sub(token.IssuedAt) > time.Duration(cfg.AttestationMaxAgeS)*time.Second {
phase4-coordinator/internal/tier2/pillar_c.go:202:	if token.Format == seAttestationFormat {
phase4-coordinator/internal/tier2/pillar_c.go:203:		status, seResult := verifySEAttestationToken(token, challenge, authAttemptID)
phase4-coordinator/internal/tier2/pillar_c.go:205:			observeSignedModelHashAgainstCatalog(token, modelHashCheck, providerID, logger)
phase4-coordinator/internal/tier2/pillar_c.go:220:		if validMockAttestationToken(token.Token) {
phase4-coordinator/internal/tier2/pillar_c.go:230:	if status, ok, mdaHardware := verifyProductionMDAChainShape(token, cfg, sePublicKey, now, authAttemptID, providerID, logger, modelHashCheck); ok {
phase4-coordinator/internal/tier2/pillar_c.go:245:// for a production token. sePublicKey is optional (may be nil or len!=64); when
phase4-coordinator/internal/tier2/pillar_c.go:248:func verifyProductionMDAChainShape(token AttestationToken, cfg config.Tier2Config, sePublicKey []byte, now time.Time, authAttemptID, providerID string, logger zerolog.Logger, modelHashCheck attestationModelHashCheck) (pool.AttestationStatus, bool, bool) {
phase4-coordinator/internal/tier2/pillar_c.go:249:	certs, ok, err := extractAttestationCertificateChain(token)
phase4-coordinator/internal/tier2/pillar_c.go:277:	reason, seKeyUsed := verifyMDAFreshness(certs[0], token.Token, sePublicKey)
phase4-coordinator/internal/tier2/pillar_c.go:286:	csrStatus, csrReason := verifyMDACSRKeyBinding(certs[0], token)
phase4-coordinator/internal/tier2/pillar_c.go:302:	if reason := verifyAttestationBindingSignature(certs[0], token, authAttemptID); reason != "" {
phase4-coordinator/internal/tier2/pillar_c.go:306:	observeSignedModelHashAgainstCatalog(token, modelHashCheck, providerID, logger)
phase4-coordinator/internal/tier2/pillar_c.go:345:	// Use an empty token string for the legacy freshness digest so that it
phase4-coordinator/internal/tier2/pillar_c.go:422:func attestationHardwareFamilyAllowed(token AttestationToken) bool {
phase4-coordinator/internal/tier2/pillar_c.go:423:	hardwareFamily, ok := token.Claimed["hardware_family"].(string)
phase4-coordinator/internal/tier2/pillar_c.go:427:func observeSignedModelHashAgainstCatalog(token AttestationToken, check attestationModelHashCheck, providerID string, logger zerolog.Logger) {
phase4-coordinator/internal/tier2/pillar_c.go:433:		modelID = tokenClaimedModelID(token)
phase4-coordinator/internal/tier2/pillar_c.go:438:	claimedValue, present := token.Claimed["model_hash"]
phase4-coordinator/internal/tier2/pillar_c.go:460:func tokenClaimedModelID(token AttestationToken) string {
phase4-coordinator/internal/tier2/pillar_c.go:461:	modelID, _ := token.Claimed["model_id"].(string)
phase4-coordinator/internal/tier2/pillar_c.go:509:func verifyMDACSRKeyBinding(leaf *x509.Certificate, token AttestationToken) (pool.AttestationStatus, string) {
phase4-coordinator/internal/tier2/pillar_c.go:510:	csr, ok, err := extractAttestationCSR(token)
phase4-coordinator/internal/tier2/pillar_c.go:526:func verifyAttestationBindingSignature(leaf *x509.Certificate, token AttestationToken, authAttemptID string) string {
phase4-coordinator/internal/tier2/pillar_c.go:527:	sig, ok := parseAttestationBindingSignature(token.Signature)
phase4-coordinator/internal/tier2/pillar_c.go:531:	payload, err := attestationBindingPayload(token, authAttemptID)
phase4-coordinator/internal/tier2/pillar_c.go:576:func BuildAttestationBindingSignature(token AttestationToken, authAttemptID string, signer crypto.Signer) (map[string]interface{}, error) {
phase4-coordinator/internal/tier2/pillar_c.go:580:	payload, err := attestationBindingPayload(token, authAttemptID)
phase4-coordinator/internal/tier2/pillar_c.go:606:func attestationBindingPayload(token AttestationToken, authAttemptID string) ([]byte, error) {
phase4-coordinator/internal/tier2/pillar_c.go:607:	claimed, err := json.Marshal(token.Claimed)
phase4-coordinator/internal/tier2/pillar_c.go:612:	tokenHash := sha256.Sum256([]byte(token.Token))
phase4-coordinator/internal/tier2/pillar_c.go:618:		AuthAttemptID         string `json:"auth_attempt_id"`
phase4-coordinator/internal/tier2/pillar_c.go:622:		TokenSHA256           string `json:"token_sha256"`
phase4-coordinator/internal/tier2/pillar_c.go:626:		ProviderID:            token.ProviderID,
phase4-coordinator/internal/tier2/pillar_c.go:627:		BinaryVersion:         token.BinaryVersion,
phase4-coordinator/internal/tier2/pillar_c.go:628:		Challenge:             token.Challenge,
phase4-coordinator/internal/tier2/pillar_c.go:629:		AuthAttemptID:         authAttemptID,
phase4-coordinator/internal/tier2/pillar_c.go:630:		ProviderECDHPublicKey: token.KeyBinding.ProviderECDHPublicKey,
phase4-coordinator/internal/tier2/pillar_c.go:631:		IssuedAt:              token.IssuedAt.UTC().Format(time.RFC3339),
phase4-coordinator/internal/tier2/pillar_c.go:632:		ExpiresAt:             token.ExpiresAt.UTC().Format(time.RFC3339),
phase4-coordinator/internal/tier2/pillar_c.go:633:		TokenSHA256:           base64.RawURLEncoding.EncodeToString(tokenHash[:]),
phase4-coordinator/internal/tier2/pillar_c.go:638:func extractAttestationCSR(token AttestationToken) (*x509.CertificateRequest, bool, error) {
phase4-coordinator/internal/tier2/pillar_c.go:639:	value := strings.TrimSpace(token.CertificateCSR)
phase4-coordinator/internal/tier2/pillar_c.go:641:		value = strings.TrimSpace(token.CSR)
phase4-coordinator/internal/tier2/pillar_c.go:714:func validAttestationTokenEncoding(token string) bool {
phase4-coordinator/internal/tier2/pillar_c.go:715:	token = strings.TrimSpace(token)
phase4-coordinator/internal/tier2/pillar_c.go:716:	if token == "" {
phase4-coordinator/internal/tier2/pillar_c.go:719:	if strings.Contains(token, ".") {
phase4-coordinator/internal/tier2/pillar_c.go:720:		parts := strings.Split(token, ".")
phase4-coordinator/internal/tier2/pillar_c.go:734:	decoded, err := base64.RawURLEncoding.DecodeString(token)
phase4-coordinator/internal/tier2/pillar_c.go:747:func validMockAttestationToken(token string) bool {
phase4-coordinator/internal/tier2/pillar_c.go:748:	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(token))
phase4-coordinator/internal/tier2/pillar_c.go:752:func extractAttestationCertificateChain(token AttestationToken) ([]*x509.Certificate, bool, error) {
phase4-coordinator/internal/tier2/pillar_c.go:753:	values := append([]string{}, token.CertificateChain...)
phase4-coordinator/internal/tier2/pillar_c.go:754:	values = append(values, token.X5C...)
phase4-coordinator/internal/tier2/pillar_c.go:755:	if len(values) == 0 && strings.Contains(token.Token, ".") {
phase4-coordinator/internal/tier2/pillar_c.go:756:		headerX5C, err := compactJWSHeaderX5C(token.Token)
phase4-coordinator/internal/tier2/pillar_c.go:763:		decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(token.Token))
phase4-coordinator/internal/tier2/pillar_c.go:784:func compactJWSHeaderX5C(token string) ([]string, error) {
phase4-coordinator/internal/tier2/pillar_c.go:785:	parts := strings.Split(strings.TrimSpace(token), ".")
phase4-coordinator/internal/tier2/pillar_c.go:954:		panic(fmt.Sprintf("mock attestation token marshal failed: %v", err))
phase4-coordinator/internal/referralapi/xapi_test.go:53:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:95:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:100:		if request.URL.String() != "https://api.x.com/2/tweets/123?tweet.fields=entities,author_id" {
phase4-coordinator/internal/referralapi/xapi_test.go:103:		if request.Header.Get("Authorization") != "Bearer secret" {
phase4-coordinator/internal/referralapi/xapi_test.go:104:			t.Fatalf("authorization=%q", request.Header.Get("Authorization"))
phase4-coordinator/internal/referralapi/xapi_test.go:106:		body := `{"data":{"id":"123","author_id":"456","entities":{"urls":[{"expanded_url":"` + wantShare + `"}]}}}`
phase4-coordinator/internal/referralapi/xapi_test.go:109:	authorID, err := client.VerifyPost(context.Background(), "123", wantShare)
phase4-coordinator/internal/referralapi/xapi_test.go:110:	if err != nil || authorID != "456" {
phase4-coordinator/internal/referralapi/xapi_test.go:111:		t.Fatalf("author=%q err=%v", authorID, err)
phase4-coordinator/internal/referralapi/xapi_test.go:115:		body := `{"data":{"id":"123","author_id":"","entities":{"urls":[{"expanded_url":"` + wantShare + `"}]}}}`
phase4-coordinator/internal/referralapi/xapi_test.go:119:		t.Fatalf("missing author error=%v", err)
phase4-coordinator/internal/referralapi/xapi_test.go:150:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:152:		`{"data":{"id":"999","author_id":"456","entities":{"urls":[{"expanded_url":"` + wantShare + `"}]}}}`,
phase4-coordinator/internal/referralapi/xapi_test.go:153:		`{"data":{"id":"123","author_id":"not-numeric","entities":{"urls":[{"expanded_url":"` + wantShare + `"}]}}}`,
phase4-coordinator/internal/referralapi/xapi_test.go:154:		`{"data":{"id":"123","author_id":"1234567890123456789012345","entities":{"urls":[{"expanded_url":"` + wantShare + `"}]}}}`,
phase4-coordinator/internal/referralapi/xapi_test.go:170:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:178:		{status: http.StatusForbidden, body: `{"type":"https://api.x.com/2/problems/not-authorized-for-resource","detail":"This post is unavailable"}`, want: ErrXPostTerminal},
phase4-coordinator/internal/referralapi/xapi_test.go:180:		{status: http.StatusForbidden, body: `{"detail":"client cannot access private metrics"}`, want: ErrXPostTransient},
phase4-coordinator/internal/referralapi/xapi_test.go:201:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:204:		body := `{"data":{"id":"123","author_id":"456","entities":{"urls":[{"expanded_url":"` + postURL + `"}]}}}`
phase4-coordinator/internal/referralapi/xapi_test.go:207:	if author, err := client.RecheckPost(context.Background(), "123", digest); err != nil || author != "456" {
phase4-coordinator/internal/referralapi/xapi_test.go:208:		t.Fatalf("unchanged author=%q err=%v", author, err)
phase4-coordinator/internal/referralapi/xapi_test.go:223:		"https://user:secret@malibu.tech/j",
phase4-coordinator/internal/referralapi/xapi_test.go:233:		if _, err := NewXAPIClient("secret", raw); err == nil {
phase4-coordinator/cmd/coordinator-cli/trust_pool_admin.go:47:	case "authorize-buyer":
phase4-coordinator/cmd/coordinator-cli/trust_pool_admin.go:48:		return trustPoolAdminEvent(args[1:], "authorize-buyer", trustpool.EventBuyerAuthorized, getenv, stdout)
phase4-coordinator/cmd/coordinator-cli/trust_pool_admin.go:49:	case "remove-buyer-authorization":
phase4-coordinator/cmd/coordinator-cli/trust_pool_admin.go:50:		return trustPoolAdminEvent(args[1:], "remove-buyer-authorization", trustpool.EventBuyerAuthorizationRm, getenv, stdout)
phase4-coordinator/cmd/coordinator-cli/trust_pool_admin.go:74:		return fmt.Errorf("rotate-signer-set is not implemented in the SPEC-043 candidate surface; submit a signed SPEC-042 authority-log event through append-event after signer-set support lands")
phase4-coordinator/cmd/coordinator-cli/trust_pool_admin.go:92:		keyEnv:   fs.String("operator-key-env", "MACPROVIDER_OPERATOR_KEY", "environment variable containing operator bearer token"),
phase4-coordinator/cmd/coordinator-cli/trust_pool_admin.go:120:		return "", "", fmt.Errorf("--operator-key-env must name an environment variable containing the operator bearer token")
phase4-coordinator/internal/referralapi/validate.go:17:	"github.com/augstar/macprovider-coordinator/internal/auth"
phase4-coordinator/internal/referralapi/validate.go:21:	ValidateReferral(context.Context, auth.ReferralPolicy, string, time.Time) (auth.ReferralValidation, error)
phase4-coordinator/internal/referralapi/validate.go:32:// authority that consumes a referral.
phase4-coordinator/internal/referralapi/validate.go:35:	Policy        auth.ReferralPolicy
phase4-coordinator/internal/referralapi/validate.go:113:	// Decode and bound the request before consulting policy or authority so a
phase4-coordinator/internal/referralapi/validate.go:130:		writeError(w, http.StatusServiceUnavailable, "unavailable", "referral authority unavailable")
phase4-coordinator/internal/referralapi/validate.go:136:		if reason == "invalid" && !errors.Is(err, auth.ErrReferralInvalid) {
phase4-coordinator/internal/referralapi/validate.go:138:			writeError(w, http.StatusServiceUnavailable, "unavailable", "referral authority unavailable")
phase4-coordinator/internal/referralapi/validate.go:188:	case errors.Is(err, auth.ErrReferralRequired):
phase4-coordinator/internal/referralapi/validate.go:190:	case errors.Is(err, auth.ErrReferralExpired):
phase4-coordinator/internal/referralapi/validate.go:192:	case errors.Is(err, auth.ErrReferralRevoked):
phase4-coordinator/internal/referralapi/validate.go:194:	case errors.Is(err, auth.ErrReferralExhausted):
phase4-coordinator/internal/referralapi/validate.go:196:	case errors.Is(err, auth.ErrReferralConflict):
phase4-coordinator/internal/referralapi/advocacy.go:11:	"github.com/augstar/macprovider-coordinator/internal/auth"
phase4-coordinator/internal/referralapi/advocacy.go:15:	ProviderReferralStatus(context.Context, auth.ReferralPolicy, string) (auth.ProviderReferral, error)
phase4-coordinator/internal/referralapi/advocacy.go:16:	CreateSocialChallenge(context.Context, auth.ReferralPolicy, string, time.Time) (auth.SocialChallenge, error)
phase4-coordinator/internal/referralapi/advocacy.go:17:	PreflightSocialVerification(context.Context, auth.ReferralPolicy, string, string, string, time.Time) (auth.ProviderReferral, bool, error)
phase4-coordinator/internal/referralapi/advocacy.go:18:	CompleteSocialVerification(context.Context, auth.ReferralPolicy, string, string, string, string, string, string, time.Time) (auth.ProviderReferral, error)
phase4-coordinator/internal/referralapi/advocacy.go:19:	FailSocialVerification(context.Context, auth.ReferralPolicy, string, string, string, string, string, string, time.Time) (auth.ProviderReferral, error)
phase4-coordinator/internal/referralapi/advocacy.go:20:	ConsumeSocialRateLimit(context.Context, auth.ReferralPolicy, string, string, time.Time, time.Duration, int) (bool, error)
phase4-coordinator/internal/referralapi/advocacy.go:21:	RecordSocialAudit(context.Context, auth.ReferralPolicy, string, string, string, string, string, string, string, time.Time) error
phase4-coordinator/internal/referralapi/advocacy.go:32:// AdvocacyHandler owns the provider-authenticated referral endpoints. It never
phase4-coordinator/internal/referralapi/advocacy.go:38:	Policy           auth.ReferralPolicy
phase4-coordinator/internal/referralapi/advocacy.go:56:	providerID, ok := h.authenticate(w, r)
phase4-coordinator/internal/referralapi/advocacy.go:61:	if errors.Is(err, auth.ErrReferralLocked) {
phase4-coordinator/internal/referralapi/advocacy.go:83:	providerID, ok := h.authenticate(w, r)
phase4-coordinator/internal/referralapi/advocacy.go:112:		if errors.Is(err, auth.ErrReferralLocked) {
phase4-coordinator/internal/referralapi/advocacy.go:117:		if errors.Is(err, auth.ErrSocialChallenge) {
phase4-coordinator/internal/referralapi/advocacy.go:142:	providerID, ok := h.authenticate(w, r)
phase4-coordinator/internal/referralapi/advocacy.go:187:		if errors.Is(err, auth.ErrSocialChallenge) {
phase4-coordinator/internal/referralapi/advocacy.go:224:	authorID, err := h.PostVerifier.VerifyPost(r.Context(), postID, expectedURL)
phase4-coordinator/internal/referralapi/advocacy.go:239:	if err != nil || strings.TrimSpace(authorID) == "" {
phase4-coordinator/internal/referralapi/advocacy.go:242:			reason = "author_missing"
phase4-coordinator/internal/referralapi/advocacy.go:245:			r.Context(), h.Policy, providerID, request.Challenge, postID, authorID, shareURLHash, reason, submittedAt,
phase4-coordinator/internal/referralapi/advocacy.go:260:		r.Context(), h.Policy, providerID, request.Challenge, postID, authorID, shareURLHash, "x_api", submittedAt,
phase4-coordinator/internal/referralapi/advocacy.go:263:		if errors.Is(err, auth.ErrSocialChallenge) {
phase4-coordinator/internal/referralapi/advocacy.go:276:func (h *AdvocacyHandler) authenticate(w http.ResponseWriter, r *http.Request) (string, bool) {
phase4-coordinator/internal/referralapi/advocacy.go:292:			writeError(w, http.StatusServiceUnavailable, "auth_busy", "provider authentication is temporarily busy")
phase4-coordinator/internal/referralapi/advocacy.go:297:	token, ok := strings.CutPrefix(raw, "Bearer ")
phase4-coordinator/internal/referralapi/advocacy.go:298:	if !ok || strings.TrimSpace(token) == "" || h.Tokens == nil || h.Store == nil {
phase4-coordinator/internal/referralapi/advocacy.go:299:		writeError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token required")
phase4-coordinator/internal/referralapi/advocacy.go:302:	providerID, valid, err := h.Tokens.ValidateTokenReadOnly(r.Context(), strings.TrimSpace(token))
phase4-coordinator/internal/referralapi/advocacy.go:304:		writeError(w, http.StatusServiceUnavailable, "auth_unavailable", "provider authentication unavailable")
phase4-coordinator/internal/referralapi/advocacy.go:308:		writeError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token invalid")
phase4-coordinator/internal/referralapi/advocacy.go:314:func (h *AdvocacyHandler) writeStatus(w http.ResponseWriter, status auth.ProviderReferral) {
phase4-coordinator/internal/ws/admission.go:44:	TotalTokensServed   int        `json:"total_tokens_served"`
phase4-coordinator/internal/ws/admission.go:98:// admission history. A failed referral/token transaction therefore leaves no
phase4-coordinator/internal/ws/admission.go:445:// loop in cmd/coordinator/main.go alongside the request_log + audit_log
phase4-coordinator/cmd/coordinator-cli/main.go:16:	"github.com/augstar/macprovider-coordinator/internal/auth"
phase4-coordinator/cmd/coordinator-cli/main.go:26:	case "issue-token":
phase4-coordinator/cmd/coordinator-cli/main.go:28:	case "revoke-token":
phase4-coordinator/cmd/coordinator-cli/main.go:36:	case "list-tokens":
phase4-coordinator/cmd/coordinator-cli/main.go:40:	case "prune-tokens":
phase4-coordinator/cmd/coordinator-cli/main.go:71:	fs := flag.NewFlagSet("issue-token", flag.ExitOnError)
phase4-coordinator/cmd/coordinator-cli/main.go:73:	providerID := fs.String("provider-id", "", "stable provider_id this token may authenticate")
phase4-coordinator/cmd/coordinator-cli/main.go:78:	store, err := auth.OpenStore(*dbPath)
phase4-coordinator/cmd/coordinator-cli/main.go:83:	record, token, err := store.IssueToken(context.Background(), *providerID, *providerName)
phase4-coordinator/cmd/coordinator-cli/main.go:87:	fmt.Printf("token=%s\n", token)
phase4-coordinator/cmd/coordinator-cli/main.go:88:	fmt.Printf("token_prefix=%s\n", record.TokenPrefix)
phase4-coordinator/cmd/coordinator-cli/main.go:95:	fs := flag.NewFlagSet("revoke-token", flag.ExitOnError)
phase4-coordinator/cmd/coordinator-cli/main.go:97:	prefix := fs.String("token-prefix", "", "token prefix printed at issuance")
phase4-coordinator/cmd/coordinator-cli/main.go:101:	store, err := auth.OpenStore(*dbPath)
phase4-coordinator/cmd/coordinator-cli/main.go:110:	fmt.Printf("revoked token_prefix=%s provider_name=%s\n", record.TokenPrefix, record.ProviderName)
phase4-coordinator/cmd/coordinator-cli/main.go:121:	store, err := auth.OpenStore(*dbPath)
phase4-coordinator/cmd/coordinator-cli/main.go:137:	identityRetention := fs.Duration("identity-retention", 7*24*time.Hour, "post-token recovery retention used to show collection horizon; must match coordinator config")
phase4-coordinator/cmd/coordinator-cli/main.go:151:	store, err := auth.OpenStore(*dbPath)
phase4-coordinator/cmd/coordinator-cli/main.go:208:func collectInSeconds(record auth.BootstrapIdentityRecord, now time.Time, retention time.Duration) string {
phase4-coordinator/cmd/coordinator-cli/main.go:219:func bootstrapIdentityState(record auth.BootstrapIdentityRecord, now time.Time) string {
phase4-coordinator/cmd/coordinator-cli/main.go:242:	fs := flag.NewFlagSet("list-tokens", flag.ExitOnError)
phase4-coordinator/cmd/coordinator-cli/main.go:247:	store, err := auth.OpenStore(*dbPath)
phase4-coordinator/cmd/coordinator-cli/main.go:273:	prefix := fs.String("token-prefix", "", "token prefix printed at issuance")
phase4-coordinator/cmd/coordinator-cli/main.go:275:	operatorKey := fs.String("operator-key", "", "operator bearer token")
phase4-coordinator/cmd/coordinator-cli/main.go:276:	providerID := fs.String("provider-id", "", "optional stable provider ID override for legacy tokens without provider_id")
phase4-coordinator/cmd/coordinator-cli/main.go:277:	reason := fs.String("reason", "provider token revoked", "blacklist reason")
phase4-coordinator/cmd/coordinator-cli/main.go:284:	store, err := auth.OpenStore(*dbPath)
phase4-coordinator/cmd/coordinator-cli/main.go:296:			return fmt.Errorf("token belongs to provider_id %s, refusing to kick %s", targetProviderID, *providerID)
phase4-coordinator/cmd/coordinator-cli/main.go:301:		return fmt.Errorf("revoked token has no provider_id; pass --provider-id for legacy token")
phase4-coordinator/cmd/coordinator-cli/main.go:306:	fmt.Printf("revoked token_prefix=%s provider_id=%s provider_name=%s kicked provider_id=%s\n", record.TokenPrefix, record.ProviderID, record.ProviderName, targetProviderID)
phase4-coordinator/cmd/coordinator-cli/main.go:347:	fs := flag.NewFlagSet("prune-tokens", flag.ExitOnError)
phase4-coordinator/cmd/coordinator-cli/main.go:349:	olderThan := fs.String("older-than", "168h", "retire unused tokens older than this duration (e.g. 168h) or RFC3339 timestamp")
phase4-coordinator/cmd/coordinator-cli/main.go:351:	force := fs.Bool("force", false, "allow cutoffs younger than 24h (DANGEROUS: may invalidate tokens of providers in their first settling window before they have reconnected with Bearer)")
phase4-coordinator/cmd/coordinator-cli/main.go:360:	// re-audit on PR #44 (MINOR-2) flagged that a self-minted token is
phase4-coordinator/cmd/coordinator-cli/main.go:365:	// the active first-session provider's only token, bricking it under
phase4-coordinator/cmd/coordinator-cli/main.go:372:			"refusing to prune with cutoff %s (younger than 24h ago at %s); a self-minted token does not become last_used_at-non-NULL until the binary reconnects with Bearer, which can take several seconds. Pass --force to override at the risk of bricking providers mid-onboarding",
phase4-coordinator/cmd/coordinator-cli/main.go:377:	store, err := auth.OpenStore(*dbPath)
phase4-coordinator/cmd/coordinator-cli/main.go:392:		// surfacing token_prefix + provider_id + age helps the operator
phase4-coordinator/cmd/coordinator-cli/main.go:398:				fmt.Printf("  candidate token_prefix=%s provider_id=%s created_at=%s last_used_at=NULL\n", r.TokenPrefix, r.ProviderID, r.CreatedAt)
phase4-coordinator/cmd/coordinator-cli/main.go:403:		fmt.Println("NOTE: last_used_at=NULL means the binary has never authenticated with this token via Bearer. Verify each candidate is genuinely stale (not a provider currently in its self-mint -> persist -> reconnect window) before --apply.")
phase4-coordinator/cmd/coordinator-cli/main.go:422:	store, err := auth.OpenStore(*dbPath)
phase4-coordinator/cmd/coordinator-cli/main.go:457:// every active provider_tokens row has a `last_used_at` no older than
phase4-coordinator/cmd/coordinator-cli/main.go:459:// stale — it means no provider has ever authenticated with Bearer using that
phase4-coordinator/cmd/coordinator-cli/main.go:460:// token, so flipping the flag would brick that provider.
phase4-coordinator/cmd/coordinator-cli/main.go:497:	// auth.OpenStore would otherwise create an empty SQLite file and the
phase4-coordinator/cmd/coordinator-cli/main.go:506:	store, err := auth.OpenStore(*dbPath)
phase4-coordinator/cmd/coordinator-cli/main.go:516:	// auth/tokens.go nowString() writes. Failing closed on a parse
phase4-coordinator/cmd/coordinator-cli/main.go:526:		TokenPrefix  string  `json:"token_prefix"`
phase4-coordinator/cmd/coordinator-cli/main.go:547:				Reason:       "last_used_at IS NULL (provider never authenticated with Bearer)",
phase4-coordinator/cmd/coordinator-cli/main.go:601:			ActiveTokens int        `json:"active_tokens"`
phase4-coordinator/cmd/coordinator-cli/main.go:612:		fmt.Fprintf(stdout, "pre-flip-audit cutoff=%s max_age=%s active_tokens=%d stale=%d\n", cutoffStr, maxAge.String(), activeCount, len(offenders))
phase4-coordinator/cmd/coordinator-cli/main.go:618:			fmt.Fprintf(stdout, "  STALE token_prefix=%s provider_id=%s provider_name=%q created_at=%s last_used_at=%s reason=%q\n",
phase4-coordinator/cmd/coordinator-cli/main.go:632:	fmt.Fprintln(os.Stderr, "usage: coordinator-cli <issue-token|revoke-token|revoke-bootstrap-identity|list-bootstrap-identities|list-onboarding|list-tokens|revoke-and-kick|prune-tokens|list-pair-ot-mints|pre-flip-audit|create-seed-referral|adjust-seed-referral|replace-seed-referral|revoke-referral|trust-pool-admin|trust-pool-oncall|trust-pool-artifact-lifecycle> [flags]")
phase4-coordinator/internal/referralapi/serving_test.go:13:	"github.com/augstar/macprovider-coordinator/internal/auth"
phase4-coordinator/internal/referralapi/serving_test.go:26:CREATE TABLE settlement_receipt_verdicts (
phase4-coordinator/internal/referralapi/serving_test.go:69:func (s *servingQualificationRecorder) QualifyProviderReferral(_ context.Context, _ auth.ReferralPolicy, providerID, evidenceID string, servedAt, _ time.Time) (auth.ProviderReferral, bool, error) {
phase4-coordinator/internal/referralapi/serving_test.go:77:		return auth.ProviderReferral{}, false, nil
phase4-coordinator/internal/referralapi/serving_test.go:81:	return auth.ProviderReferral{}, true, nil
phase4-coordinator/internal/referralapi/serving_test.go:87:	insertServingVerdict(t, path, "provider-authoritative", now.Add(-time.Minute), true, "verified", "valid")
phase4-coordinator/internal/referralapi/serving_test.go:91:	locked, err := store.ProviderReferralStatus(context.Background(), policy, "provider-authoritative")
phase4-coordinator/internal/referralapi/serving_test.go:92:	if !errors.Is(err, auth.ErrReferralLocked) || locked.Code != "" || locked.FirstServingSeen {
phase4-coordinator/internal/referralapi/serving_test.go:113:	status, err := store.ProviderReferralStatus(context.Background(), policy, "provider-authoritative")
phase4-coordinator/internal/referralapi/serving_test.go:114:	if err != nil || !status.FirstServingSeen || status.SocialState != auth.SocialStateEligible || status.Code == "" || status.BaseCapacity != 1 {
phase4-coordinator/internal/referralapi/serving_test.go:121:	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_serving_qualifications WHERE provider_id = ?`, "provider-authoritative").Scan(&qualificationRows); err != nil {
phase4-coordinator/internal/referralapi/serving_test.go:124:	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_issuers WHERE provider_id = ?`, "provider-authoritative").Scan(&issuerRows); err != nil {
phase4-coordinator/internal/referralapi/serving_test.go:127:	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_social_audit WHERE provider_id = ? AND event_kind = 'serving_qualified'`, "provider-authoritative").Scan(&auditRows); err != nil {
phase4-coordinator/internal/referralapi/validate_test.go:12:	"github.com/augstar/macprovider-coordinator/internal/auth"
phase4-coordinator/internal/referralapi/validate_test.go:15:type validationStoreFunc func(string) (auth.ReferralValidation, error)
phase4-coordinator/internal/referralapi/validate_test.go:34:func (f validationStoreFunc) ValidateReferral(_ context.Context, _ auth.ReferralPolicy, code string, _ time.Time) (auth.ReferralValidation, error) {
phase4-coordinator/internal/referralapi/validate_test.go:38:func validationPolicy() auth.ReferralPolicy {
phase4-coordinator/internal/referralapi/validate_test.go:39:	return auth.ReferralPolicy{
phase4-coordinator/internal/referralapi/validate_test.go:60:		Store: validationStoreFunc(func(code string) (auth.ReferralValidation, error) {
phase4-coordinator/internal/referralapi/validate_test.go:62:				return auth.ReferralValidation{}, auth.ErrReferralExpired
phase4-coordinator/internal/referralapi/validate_test.go:64:			return auth.ReferralValidation{Valid: true, Reason: "valid"}, nil
phase4-coordinator/internal/referralapi/validate_test.go:99:			Policy:           auth.ReferralPolicy{RequireForRegistration: false},
phase4-coordinator/internal/referralapi/validate_test.go:114:			Store: validationStoreFunc(func(string) (auth.ReferralValidation, error) {
phase4-coordinator/internal/referralapi/validate_test.go:115:				return auth.ReferralValidation{}, auth.ErrReferralInvalid
phase4-coordinator/internal/referralapi/validate_test.go:133:		Policy:        auth.ReferralPolicy{RequireForRegistration: false},
phase4-coordinator/internal/referralapi/validate_test.go:164:		Store: validationStoreFunc(func(string) (auth.ReferralValidation, error) {
phase4-coordinator/internal/referralapi/validate_test.go:165:			return auth.ReferralValidation{}, errors.New("database busy")
phase4-coordinator/internal/referralapi/validate_test.go:183:		Store: validationStoreFunc(func(string) (auth.ReferralValidation, error) {
phase4-coordinator/internal/referralapi/validate_test.go:184:			return auth.ReferralValidation{Valid: true, Reason: "valid"}, nil
phase4-coordinator/internal/referralapi/validate_test.go:230:		Store: validationStoreFunc(func(string) (auth.ReferralValidation, error) {
phase4-coordinator/internal/referralapi/validate_test.go:231:			return auth.ReferralValidation{Valid: true, Reason: "valid"}, nil
phase4-coordinator/internal/referralapi/validate_test.go:256:		auth.ErrReferralRequired:  "missing",
phase4-coordinator/internal/referralapi/validate_test.go:257:		auth.ErrReferralInvalid:   "invalid",
phase4-coordinator/internal/referralapi/validate_test.go:258:		auth.ErrReferralExpired:   "expired",
phase4-coordinator/internal/referralapi/validate_test.go:259:		auth.ErrReferralRevoked:   "revoked",
phase4-coordinator/internal/referralapi/validate_test.go:260:		auth.ErrReferralExhausted: "exhausted",
phase4-coordinator/internal/ws/identity_migration_test.go:15:	"github.com/augstar/macprovider-coordinator/internal/auth"
phase4-coordinator/internal/ws/identity_migration_test.go:26:	store, err := auth.OpenStore(dbPath)
phase4-coordinator/internal/ws/identity_migration_test.go:35:	pubkey, privateKey, err := ed25519.GenerateKey(nil)
phase4-coordinator/internal/ws/identity_migration_test.go:68:		signedIdentityProofFields(t, privateKey, providerID, challenge.AuthAttemptID, initial))
phase4-coordinator/internal/ws/identity_migration_test.go:75:	// Runbook item 23: the v2 auth_response propagates the admission verdict.
phase4-coordinator/internal/ws/identity_migration_test.go:76:	// This connect carries a valid Bearer, so auth_state is bearer_validated.
phase4-coordinator/internal/ws/identity_migration_test.go:78:		t.Fatalf("v2 auth_response auth_state = %q, want %q (bearer-validated admission)", response.AuthState, pool.AuthBearerValidated)
phase4-coordinator/internal/ws/identity_migration_test.go:88:	// A fresh coordinator and empty live registry authenticate from SQLite
phase4-coordinator/internal/ws/identity_migration_test.go:111:		signedIdentityProofFields(t, privateKey, providerID, challenge.AuthAttemptID, initial))
phase4-coordinator/internal/ws/identity_migration_test.go:123:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/identity_migration_test.go:145:	// The accepted response names generation 2 and the coordinator-authoritative
phase4-coordinator/internal/ws/identity_migration_test.go:151:	challenge, response, conn := authenticateAdmissionIdentity(t, first, bearer, providerID, initial, currentPrivateKey)
phase4-coordinator/internal/ws/identity_migration_test.go:174:	authoritativePreviousDeadline := response.AdmissionIdentityPreviousValidUntil
phase4-coordinator/internal/ws/identity_migration_test.go:183:	challenge, response, conn = authenticateAdmissionIdentity(t, responseLoss, bearer, providerID, initial, nextPrivateKey)
phase4-coordinator/internal/ws/identity_migration_test.go:191:		response.AdmissionIdentityPreviousValidUntil != authoritativePreviousDeadline {
phase4-coordinator/internal/ws/identity_migration_test.go:197:	// A rolled-back binary may authenticate with the bounded previous key, but
phase4-coordinator/internal/ws/identity_migration_test.go:199:	// authoritative.
phase4-coordinator/internal/ws/identity_migration_test.go:203:	challenge, response, conn = authenticateAdmissionIdentity(t, rollback, bearer, providerID, initial, currentPrivateKey)
phase4-coordinator/internal/ws/identity_migration_test.go:211:		response.AdmissionIdentityPreviousValidUntil != authoritativePreviousDeadline {
phase4-coordinator/internal/ws/identity_migration_test.go:221:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/identity_migration_test.go:247:	_, response, conn := authenticateAdmissionIdentity(t, withoutPolicy, bearer, providerID, initial, recoveryPrivateKey)
phase4-coordinator/internal/ws/identity_migration_test.go:249:		t.Fatalf("unauthorized recovery response=%+v", response)
phase4-coordinator/internal/ws/identity_migration_test.go:255:		t.Fatalf("unauthorized recovery mutated durable state=%+v ok=%v err=%v", state, ok, err)
phase4-coordinator/internal/ws/identity_migration_test.go:261:	_, response, conn = authenticateAdmissionIdentity(t, wrongProof, bearer, providerID, initial, currentPrivateKey)

codex
All four existing checks completed successfully: the billing-mirror Go package, the updated deployment wiring test, the static-feed access test, and the coordinator recovery test. The recovery test specifically observes `setfacl --restore` for the captured DB ACL and passes state-exact restoration. I’m doing the final line-numbered review now, including the Round 2 service assertion and secret-path restrictions.
exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/stats-billing-mirror.service | sed -n '1,45p'; nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '3068,3082p;3135,3147p;3625,3643p;4868,4888p'; nl -ba phase4-coordinator/internal/sqliteutil/dsn.go | sed -n '50,82p'; nl -ba phase4-coordinator/internal/stats/billingmirror/mirror.go | sed -n '80,120p;245,265p;500,605p'; nl -ba phase4-coordinator/dist/coordinator-deploy-recover.sh | sed -n '130,148p;225,236p'; nl -ba phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh | sed -n '68,88p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
     1	[Unit]
     2	Description=MacProvider stats billing mirror
     3	Documentation=https://github.com/augstar/macprovider-poc
     4	Wants=network-online.target
     5	After=network-online.target
     6	ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env
     7	ConditionPathExists=/var/lib/macprovider/coordinator.db
     8	
     9	[Service]
    10	Type=oneshot
    11	User=macprovider-stats
    12	Group=macprovider-stats
    13	EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env
    14	ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
    15	Nice=10
    16	IOSchedulingClass=best-effort
    17	IOSchedulingPriority=7
    18	NoNewPrivileges=true
    19	PrivateDevices=true
    20	PrivateTmp=true
    21	ProtectHome=true
    22	ProtectSystem=strict
    23	ReadOnlyPaths=/var/lib/macprovider/coordinator.db
    24	ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
    25	ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
    26	InaccessiblePaths=/etc/macprovider
    27	InaccessiblePaths=-/opt/macprovider/coordinator.yaml
  3068	      touch \"\$_rollback_stage/\$2\"
  3069	    fi
  3070	  }
  3071	  snapshot_acl() {
  3072	    _source=\"\$1\"
  3073	    _snapshot=\"\$2\"
  3074	    _marker=\"\$3\"
  3075	    if [ -e \"\$_source\" ]; then
  3076	      getfacl -p \"\$_source\" > \"\$_rollback_stage/\$_snapshot\"
  3077	      touch \"\$_rollback_stage/\$_marker\"
  3078	    fi
  3079	  }
  3080	  snapshot_node /opt/macprovider/coordinator.prev coordinator.prev had-coordinator-prev
  3081	  if [ -x /opt/macprovider/coordinator ]; then
  3082	    cp -p /opt/macprovider/coordinator \"\$_rollback_stage/coordinator\"
  3135	  snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
  3136	  snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
  3137	  snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full
  3138	
  3139	  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
  3140	    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
  3141	    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
  3142	    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
  3143	    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
  3144	  fi
  3145	  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
  3146	    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
  3147	    touch \"\$_rollback_stage/had-wants-link\"
  3625	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
  3626	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
  3627	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.service /etc/systemd/system/stats-hardware-verifier.service
  3628	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.timer /etc/systemd/system/stats-hardware-verifier.timer
  3629	  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
  3630	    # Mutate only objects captured at the transaction boundary. WAL/SHM files
  3631	    # can appear while the old coordinator is still running; granting an ACL
  3632	    # to a newly appeared, unsnapshotted file would make exact rollback
  3633	    # impossible.
  3634	    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
  3635	    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
  3636	    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
  3637	    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
  3638	  elif [ -f /var/lib/macprovider/coordinator.db ]; then
  3639	    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
  3640	  fi
  3641	  # Stage the complete immutable catalog release. Activation happens only
  3642	  # after the late connected-provider safeguard immediately before restart.
  3643	  _autotune_root=/opt/macprovider/autotune
  4868	    systemctl start stats-inventory-sync.timer
  4869	    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
  4870	  elif [ "$_parity_required" = absent ]; then
  4871	    echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
  4872	  fi
  4873	  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
  4874	    systemctl enable --now stats-billing-mirror.timer
  4875	    if ! systemctl start stats-billing-mirror.service; then
  4876	      systemctl disable --now stats-billing-mirror.timer
  4877	      echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
  4878	      journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
  4879	      exit 13
  4880	    fi
  4881	    systemctl is-active stats-billing-mirror.timer
  4882	  elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-timer-was-active ]; then
  4883	    systemctl start stats-billing-mirror.timer
  4884	    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
  4885	  else
  4886	    echo "stats billing mirror timer not enabled: missing env/sqlite source or macprovider-stats read ACL"
  4887	  fi
  4888	  if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
    50		if strings.Contains(base, "?") {
    51			separator = "&"
    52		}
    53		return base + separator + values.Encode()
    54	}
    55	
    56	// ReadOnlyDSN builds a strictly read-only modernc.org/sqlite DSN.
    57	// Opens with mode=ro and applies PRAGMA query_only=ON at connection
    58	// init via a pragma — no journal_mode toggle, no synchronous toggle,
    59	// no writable connection. SPEC-002 v1.5.1 R-2 / issue #197 R3 code:
    60	// used by `coordinator migrate-indexes --check` so the read-only
    61	// introspection never persists journal-mode metadata or runs ALTER
    62	// TABLE on a legacy DB.
    63	func ReadOnlyDSN(path string) string {
    64		values := url.Values{}
    65		values.Set("mode", "ro")
    66		for _, pragma := range []string{
    67			"busy_timeout=5000",
    68			"query_only(true)",
    69		} {
    70			values.Add("_pragma", pragma)
    71		}
    72		separator := "?"
    73		if strings.Contains(path, "?") {
    74			separator = "&"
    75		}
    76		return path + separator + values.Encode()
    77	}
    80		CreatedAt    time.Time
    81		LastUsedAt   sql.NullTime
    82	}
    83	
    84	type State struct {
    85		LastRequestID int64
    86		SweepAfterID  int64
    87	}
    88	
    89	func Run(parent context.Context, opts Options) (Result, error) {
    90		opts = normalizeOptions(opts)
    91		out := opts.Stdout
    92		if out == nil {
    93			out = io.Discard
    94		}
    95		if opts.SQLitePath == "" {
    96			return Result{}, errors.New("sqlite path is required")
    97		}
    98		if opts.PostgresDSN == "" && !opts.DryRun {
    99			return Result{}, errors.New("postgres dsn is required")
   100		}
   101	
   102		ctx, cancel := context.WithTimeout(parent, DefaultRunTimeout)
   103		defer cancel()
   104	
   105		source, err := OpenSQLite(opts.SQLitePath)
   106		if err != nil {
   107			return Result{}, err
   108		}
   109		defer source.Close()
   110	
   111		var pg *sql.DB
   112		var state State
   113		if !opts.DryRun {
   114			pg, err = OpenPostgres(opts.PostgresDSN)
   115			if err != nil {
   116				return Result{}, err
   117			}
   118			defer pg.Close()
   119			if opts.EnsureSchema {
   120				if err := EnsureSchema(ctx, pg); err != nil {
   245			opts.SweepRows = opts.BatchSize
   246		}
   247		if opts.SweepRows > opts.BatchSize {
   248			opts.SweepRows = opts.BatchSize
   249		}
   250		return opts
   251	}
   252	
   253	func OpenSQLite(path string) (*sql.DB, error) {
   254		db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
   255		if err != nil {
   256			return nil, fmt.Errorf("open sqlite: %w", err)
   257		}
   258		db.SetMaxOpenConns(1)
   259		db.SetMaxIdleConns(1)
   260		return db, nil
   261	}
   262	
   263	func OpenPostgres(dsn string) (*sql.DB, error) {
   264		db, err := sql.Open("postgres", dsn)
   265		if err != nil {
   500			p.CreatedAt = createdAt
   501			p.LastUsedAt, err = parseOptionalTime(lastUsed)
   502			if err != nil {
   503				return nil, fmt.Errorf("provider_tokens.last_used_at: %w", err)
   504			}
   505			out = append(out, p)
   506		}
   507		if err := cur.Err(); err != nil {
   508			return nil, fmt.Errorf("iterate provider_tokens: %w", err)
   509		}
   510		return out, nil
   511	}
   512	
   513	func Apply(ctx context.Context, db *sql.DB, rows []RequestCredit, providers []ProviderIdentity, state State) error {
   514		tx, err := db.BeginTx(ctx, nil)
   515		if err != nil {
   516			return fmt.Errorf("begin mirror transaction: %w", err)
   517		}
   518		committed := false
   519		defer func() {
   520			if !committed {
   521				_ = tx.Rollback()
   522			}
   523		}()
   524		var locked bool
   525		if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(47017, 1711)`).Scan(&locked); err != nil {
   526			return fmt.Errorf("acquire mirror advisory lock: %w", err)
   527		}
   528		if !locked {
   529			return errors.New("another stats billing mirror run is active")
   530		}
   531		for _, p := range providers {
   532			if err := ensureProvider(ctx, tx, p); err != nil {
   533				return err
   534			}
   535		}
   536		for _, row := range rows {
   537			if err := upsertRequestCredit(ctx, tx, row); err != nil {
   538				return err
   539			}
   540		}
   541		if err := SaveState(ctx, tx, state); err != nil {
   542			return err
   543		}
   544		if err := tx.Commit(); err != nil {
   545			return fmt.Errorf("commit mirror transaction: %w", err)
   546		}
   547		committed = true
   548		return nil
   549	}
   550	
   551	func EnsureSchema(ctx context.Context, db *sql.DB) error {
   552		for _, stmt := range schemaStatements {
   553			if _, err := db.ExecContext(ctx, stmt); err != nil {
   554				return fmt.Errorf("ensure stats billing mirror schema: %w", err)
   555			}
   556		}
   557		return nil
   558	}
   559	
   560	func LoadState(ctx context.Context, db *sql.DB) (State, error) {
   561		var state State
   562		if err := db.QueryRowContext(ctx, `SELECT last_request_credit_id, sweep_after_request_credit_id FROM stats_billing_mirror_load_state($1)`, StateSource).Scan(&state.LastRequestID, &state.SweepAfterID); err != nil {
   563			return State{}, fmt.Errorf("load mirror state: %w", err)
   564		}
   565		return state, nil
   566	}
   567	
   568	func SaveState(ctx context.Context, tx *sql.Tx, state State) error {
   569		if _, err := tx.ExecContext(ctx, `SELECT stats_billing_mirror_save_state($1, $2, $3)`,
   570			StateSource, state.LastRequestID, state.SweepAfterID); err != nil {
   571			return fmt.Errorf("save mirror state: %w", err)
   572		}
   573		return nil
   574	}
   575	
   576	func ensureProvider(ctx context.Context, tx *sql.Tx, p ProviderIdentity) error {
   577		tokenHash := syntheticTokenHash(p.ProviderID)
   578		if _, err := tx.ExecContext(ctx, `SELECT stats_billing_mirror_ensure_provider($1, $2, $3, $4, $5)`,
   579			tokenHash, p.ProviderID, p.ProviderName, p.CreatedAt, nullTimeArg(p.LastUsedAt)); err != nil {
   580			return fmt.Errorf("ensure provider %q: %w", p.ProviderID, err)
   581		}
   582		return nil
   583	}
   584	
   585	func upsertRequestCredit(ctx context.Context, tx *sql.Tx, row RequestCredit) error {
   586		if _, err := tx.ExecContext(ctx, `SELECT stats_billing_mirror_upsert_request_credit(
   587	    $1, $2, $3, $4, $5, $6, $7,
   588	    $8, $9, $10, $11,
   589	    $12, $13, $14, $15, $16,
   590	    $17, $18, $19, $20
   591	)`,
   592			row.SQLiteID, row.RequestID, row.AttemptN, row.ProviderID, row.TSUTC, row.CreatedAtUTC, nullTimeArg(row.UpdatedAtUTC),
   593			nullInt64Arg(row.PromptTokens), nullInt64Arg(row.CompletionTokens), nullInt64Arg(row.EstimatedCompletionTokens),
   594			row.UsageSource, row.ProviderCredits, row.FaultFlag, row.Quarantined, row.SettlementPolicyMode, row.Spec022Verified,
   595			row.RequestedPrivacyMode, row.EffectivePrivacyOutcome, row.PositiveVerificationExcluded, row.RewardsExcluded); err != nil {
   596			return fmt.Errorf("upsert request credit %q/%d/%q: %w", row.RequestID, row.AttemptN, row.ProviderID, err)
   597		}
   598		return nil
   599	}
   600	
   601	func mergeRequestCredits(a, b []RequestCredit) []RequestCredit {
   602		if len(b) == 0 {
   603			return a
   604		}
   605		byKey := make(map[string]RequestCredit, len(a)+len(b))
   130	    }
   131	    cp -a "$ROLLBACK/$snapshot" "$destination"
   132	  fi
   133	}
   134	
   135	restore_acl() {
   136	  marker=$1
   137	  snapshot=$2
   138	  if [ -f "$ROLLBACK/$marker" ]; then
   139	    [ -f "$ROLLBACK/$snapshot" ] || {
   140	      echo "rollback snapshot missing $snapshot" >&2
   141	      exit 1
   142	    }
   143	    "$SETFACL" --restore="$ROLLBACK/$snapshot"
   144	  fi
   145	}
   146	
   147	restore_active_state() {
   148	  unit_name=$1
   225	restore_link_or_file had-nginx-coordinator-enabled nginx-coordinator.enabled "$NGINX_ROOT/sites-enabled/coordinator.malibu.tech"
   226	restore_link_or_file had-nginx-stats-enabled nginx-stats.enabled "$NGINX_ROOT/sites-enabled/stats.malibu.tech"
   227	restore_link_or_file had-nginx-coordinator-full nginx-coordinator.full "$NGINX_ROOT/sites-available/coordinator.malibu.tech.full"
   228	
   229	restore_acl had-request-log-dir-acl request-log-dir.acl
   230	restore_acl had-request-log-db-acl request-log-db.acl
   231	restore_acl had-request-log-wal-acl request-log-wal.acl
   232	restore_acl had-request-log-shm-acl request-log-shm.acl
   233	
   234	previous=$(cat "$ROLLBACK/catalog-current-target" 2>/dev/null || true)
   235	case "$previous" in
   236	  releases/*)
    68	  fail "billing mirror service must require the SQLite source"
    69	grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
    70	  fail "billing mirror service must read isolated env file"
    71	grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
    72	  fail "billing mirror service must execute from deploy path"
    73	grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
    74	  fail "billing mirror service must read only the SQLite source"
    75	# The mirror's source DB must never also be inaccessible: systemd applies
    76	# InaccessiblePaths over ReadOnlyPaths, which hid the ledger and failed the
    77	# deploy's initial mirror run.
    78	source_db=$(sed -n 's/^ExecStart=.* --sqlite \([^ ]*\) .*/\1/p' "$SERVICE")
    79	[ -n "$source_db" ] || fail "stats billing mirror ExecStart must name its --sqlite source"
    80	if grep -qE "^InaccessiblePaths=-?${source_db}(-wal|-shm)?$" "$SERVICE"; then
    81	  fail "stats billing mirror source DB $source_db must not be listed in InaccessiblePaths"
    82	fi
    83	grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||
    84	  fail "billing mirror service must not access coordinator secrets"
    85	grep -qxF 'OnUnitActiveSec=60s' "$TIMER" ||
    86	  fail "billing mirror timer must run frequently enough for public stats"
    87	grep -qF 'stats_billing_mirror_writer' "$ENV_EXAMPLE" ||
    88	  fail "env example must document dedicated writer role"

codex
Security/money-path lane: no findings.

- ACL is least-privilege at the SQLite boundary: `macprovider-stats` receives only `r--` on `coordinator.db` and `--x` on its directory ([deploy-pearl-vps.sh:3629-3637](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/deploy-pearl-vps.sh:3629)).
- The mirror cannot write the coordinator DB: systemd marks DB/WAL/SHM read-only ([service:23-25](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/stats-billing-mirror.service:23)), and Go opens SQLite with `mode=ro` and `query_only(true)` ([dsn.go:56-76](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/internal/sqliteutil/dsn.go:56)).
- Rollback snapshots and restores DB, WAL, SHM, and directory ACLs exactly via `getfacl`/`setfacl --restore` ([deploy-pearl-vps.sh:3139-3143](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/deploy-pearl-vps.sh:3139), [coordinator-deploy-recover.sh:135-144](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/coordinator-deploy-recover.sh:135)).
- Secrets remain inaccessible via `/etc/macprovider` and the coordinator config path; the source DB is no longer hidden ([service:26-27](/Users/augstar/macprovider-mirror-dbpath/phase4-coordinator/dist/stats-billing-mirror.service:26)).

Existing checks passed:

- `go test ./internal/stats/billingmirror`
- `check_stats_billing_mirror_deploy_test.sh`
- `check_deploy_static_feed_access.test.sh`
- `coordinator_deploy_recovery.test.sh`

VERDICT: PASS
tokens used
98 022

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
