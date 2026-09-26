# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-09-25T08:35:46.588Z

## Original task

# Codex audit: stats billing mirror reads the coordinator DB (#1748)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-mirror-dbpath`. Branch:
`fix/stats-mirror-coordinator-db`. Review `git diff origin/main...HEAD`.

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
## Lane: ARCHITECTURE

Check:
- Consistency with the coordinator `db_path` config and the `requestlog` store.
- Whether another environment relies on `request-log.sqlite`.
- The fleet and Pearl rollout: the next runtime tag, then the full deploy.

## Final prompt

# Codex audit: stats billing mirror reads the coordinator DB (#1748)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-mirror-dbpath`. Branch:
`fix/stats-mirror-coordinator-db`. Review `git diff origin/main...HEAD`.

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
## Lane: ARCHITECTURE

Check:
- Consistency with the coordinator `db_path` config and the `requestlog` store.
- Whether another environment relies on `request-log.sqlite`.
- The fleet and Pearl rollout: the next runtime tag, then the full deploy.

## Raw output

```text
Found one HIGH architecture issue.

- **HIGH — `phase4-coordinator/dist/stats-billing-mirror.service:23-28`**  
  The coordinator DB is declared both `ReadOnlyPaths` and `InaccessiblePaths`. `InaccessiblePaths=-...` makes `/var/lib/macprovider/coordinator.db` unavailable to the mirror despite the corrected `ExecStart`. The deploy’s readability guard passes, but systemd startup fails; `deploy-pearl-vps.sh:4873-4877` then disables the timer and aborts the full deploy.  
  **Fix:** remove `/var/lib/macprovider/coordinator.db` from `InaccessiblePaths`; add a regression assertion preventing this overlap.

Coordinator config, requestlog wiring, production path references, signed runtime-tag flow, and Pearl release tests otherwise align. Existing relevant tests passed, including billingmirror/requestlog Go tests and deployment/release wiring tests.

VERDICT: FAIL (0/1/0)


OpenAI Codex v0.156.1
--------
workdir: /Users/augstar/macprovider-mirror-dbpath
model: gpt-5.6-luna
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 01a0d7af-fd94-7693-9f53-59ae3572226f
--------
user
# Codex audit: stats billing mirror reads the coordinator DB (#1748)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-mirror-dbpath`. Branch:
`fix/stats-mirror-coordinator-db`. Review `git diff origin/main...HEAD`.

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
## Lane: ARCHITECTURE

Check:
- Consistency with the coordinator `db_path` config and the `requestlog` store.
- Whether another environment relies on `request-log.sqlite`.
- The fleet and Pearl rollout: the next runtime tag, then the full deploy.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.
  user (/Users/augstar/.codex/config.toml): `features.child_agents_md` is ignored.
warning: failed to parse hooks config /Users/augstar/.codex/hooks.json: unknown field `state`, expected `description` or `hooks` at line 2 column 9
codex
Architecture audit target: verify the mirror’s database path, environment assumptions, and Pearl rollout wiring against `origin/main...HEAD`, then run only existing relevant tests and report evidence with a pass/fail verdict. I’ll inspect the diff and surrounding configuration first.
exec
/bin/bash -lc "git status -sb && git diff --stat origin/main...HEAD && git diff -- origin/main...HEAD -- phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/internal/billingmirror phase4-coordinator | sed -n '1,260p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 67ms:
## fix/stats-mirror-coordinator-db...origin/fix/stats-mirror-coordinator-db
?? audits/2026-09-25-stats-mirror-db-path/
 phase4-coordinator/cmd/stats-billing-mirror/main.go      |  2 +-
 phase4-coordinator/dist/deploy-pearl-vps.sh              | 16 ++++++++--------
 phase4-coordinator/dist/stats-billing-mirror.service     | 10 +++++-----
 .../dist/test/check_deploy_static_feed_access.test.sh    |  2 +-
 .../dist/test/check_stats_billing_mirror_deploy_test.sh  | 12 ++++++------
 .../internal/stats/billingmirror/mirror.go               |  2 +-
 6 files changed, 22 insertions(+), 22 deletions(-)

exec
/bin/bash -lc 'git diff origin/main...HEAD -- phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/internal/stats/billingmirror/mirror.go' in /Users/augstar/macprovider-mirror-dbpath
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
index 056cf4f47..0fbb75a51 100644
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
@@ -20,9 +20,9 @@ PrivateDevices=true
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
 InaccessiblePaths=-/var/lib/macprovider/coordinator.db
diff --git a/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh b/phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
index 292e99c4c..4ac03a779 100755
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
index 9a2075ab5..8d8816853 100755
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
@@ -64,13 +64,13 @@ grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
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
 grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||
   fail "billing mirror service must not access coordinator secrets"
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

codex
The diff is narrowly scoped, but the unit still contains an `InaccessiblePaths` entry for `/var/lib/macprovider/coordinator.db` while the change adds that same path to `ReadOnlyPaths`. I’m checking whether this is an effective sandbox contradiction, and I’m tracing every remaining `request-log.sqlite` reference plus the configured coordinator `db_path` before classifying it.
exec
/bin/bash -lc "printf '%s\\n' '--- remaining path references ---'; rg -n --hidden --glob '"'!d-inference/**'"' --glob '"'!.git/**'"' 'request-log\\.sqlite|coordinator\\.db|db_path|stats-billing-mirror' phase4-coordinator phase5-gateway specs docs ops scripts test | sed -n '1,360p'; printf '%s\\n' '--- service with line numbers ---'; nl -ba phase4-coordinator/dist/stats-billing-mirror.service; printf '%s\\n' '--- coordinator DB config references ---'; rg -n --hidden --glob '"'!d-inference/**'"' --glob '"'!.git/**'"' 'db_path|DBPath|coordinator\\.db' phase4-coordinator | sed -n '1,280p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 11ms:
phase4-coordinator/scripts/test-ac2-harness.sh:55:db_path: "${RUNS_DB}"
phase4-coordinator/scripts/test-ac3-adversarial.sh:49:db_path: "${RUNS_DB}"
phase4-coordinator/scripts/run-local-pool.sh:75:  db_path: "${COORD_DB}"
phase4-coordinator/coordinator.yaml.example:223:  db_path: "coordinator.db"
phase4-coordinator/cmd/coordinator-cli/main_test.go:69:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/main_test.go:132:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/main_test.go:155:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/dist/payout-runbook.md:273:   sqlite3 /var/lib/macprovider/coordinator.db \
phase4-coordinator/dist/payout-runbook.md:420:sqlite3 /var/lib/macprovider/coordinator.db \
phase4-coordinator/cmd/coordinator-cli/main.go:72:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:96:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:116:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:135:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:243:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:272:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:348:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:417:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/main.go:487:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:46:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:62:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:80:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:100:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:120:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:140:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:151:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:190:func TestPreFlipAudit_MissingDBPath_FailsClosed(t *testing.T) {
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:226:			dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:244:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go:274:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/referrals_test.go:15:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/referrals_test.go:99:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/dist/coordinator-sqlite-relief.sh:9:  echo "usage: coordinator-sqlite-relief.sh [coordinator.db]" >&2
phase4-coordinator/cmd/coordinator/main_test.go:254:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:284:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:313:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:350:			DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:508:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main_test.go:1100:	cfg.Storage.DBPath = "/tmp/provider.sqlite"
phase4-coordinator/cmd/coordinator/main_test.go:1108:	cfg.MalibuEmission.SQLitePayoutDBPath = ""
phase4-coordinator/cmd/coordinator/main_test.go:1119:	if got.SQLitePayoutDBPath != "/tmp/provider.sqlite" {
phase4-coordinator/cmd/coordinator/main_test.go:1120:		t.Fatalf("SQLitePayoutDBPath=%q, want storage fallback", got.SQLitePayoutDBPath)
phase4-coordinator/cmd/coordinator/main_test.go:1156:	cfg.Storage.DBPath = defaultPath
phase4-coordinator/cmd/coordinator/main_test.go:1166:	cfg.MalibuEmission.SQLitePayoutDBPath = alternatePath
phase4-coordinator/cmd/coordinator/main_test.go:1194:	cfg.Storage.DBPath = path
phase4-coordinator/cmd/coordinator/main_test.go:1477:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/cmd/coordinator-cli/onboarding_test.go:16:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/cmd/coordinator-cli/onboarding_test.go:59:	eventsPath := providerevents.DefaultDBPath(dbPath)
phase4-coordinator/dist/coordinator.yaml:243:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/cmd/coordinator/main.go:230:	tokenStore, err := auth.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:236:	reqLogStore, err := requestlog.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:242:	moneyCheckpointDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:250:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:258:	routeSnapshotJournalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(routeSnapshotJournalDBPath(cfg.Storage.DBPath)))
phase4-coordinator/cmd/coordinator/main.go:287:	auditStore, err := audit.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:293:	settlementReceiptAuditStore, err := audit.OpenSettlementReceiptStore(audit.DefaultDBPath(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:323:	connectionEventStore, err := providerevents.Open(providerevents.DefaultDBPath(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:436:	startMoneySQLiteWALCheckpointer(shutdownCtx, moneyCheckpointDB, metricsHandle, logger, moneySQLiteActivity, cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:566:		sqlitePath := strings.TrimSpace(cfg.MalibuEmission.SQLitePayoutDBPath)
phase4-coordinator/cmd/coordinator/main.go:568:			sqlitePath = cfg.Storage.DBPath
phase4-coordinator/cmd/coordinator/main.go:581:			SQLitePayoutDBPath:           sqlitePath,
phase4-coordinator/cmd/coordinator/main.go:976:		if mdaStore, err := mdm.OpenMDAStoreWithManualWALCheckpoint(cfg.Storage.DBPath); err != nil {
phase4-coordinator/cmd/coordinator/main.go:980:			logger.Info().Str("db_path", cfg.Storage.DBPath).Msg("Phase 3 live MDA durable proof store wired")
phase4-coordinator/cmd/coordinator/main.go:1436:			Source: referralapi.SQLiteServingEvidence{Path: cfg.Storage.DBPath},
phase4-coordinator/cmd/coordinator/main.go:1843:func routeSnapshotJournalDBPath(dbPath string) string {
phase4-coordinator/cmd/coordinator/main.go:1857:	DBPath         string
phase4-coordinator/cmd/coordinator/main.go:1868:		DBPath:         dbPath,
phase4-coordinator/cmd/coordinator/main.go:2062:	walBytes := sqliteutil.WALFileSize(cfg.DBPath)
phase4-coordinator/cmd/coordinator/main.go:3531:		SQLitePayoutDBPath:           cfg.MalibuEmission.SQLitePayoutDBPath,
phase4-coordinator/cmd/coordinator/main.go:3538:	if rewardsCfg.SQLitePayoutDBPath == "" {
phase4-coordinator/cmd/coordinator/main.go:3539:		rewardsCfg.SQLitePayoutDBPath = cfg.Storage.DBPath
phase4-coordinator/cmd/coordinator/main.go:3549:	payoutPath := strings.TrimSpace(rewardsCfg.SQLitePayoutDBPath)
phase4-coordinator/cmd/coordinator/main.go:3550:	if payoutPath == "" || sameFilePath(payoutPath, cfg.Storage.DBPath) {
phase4-coordinator/cmd/coordinator/main.go:3564:	readStore, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator-cli/onboarding.go:17:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/onboarding.go:18:	eventsDBPath := fs.String("events-db", "", "path to provider_connection_events.db; defaults to the sibling of --db; omitted when the file is absent")
phase4-coordinator/cmd/coordinator-cli/onboarding.go:38:	eventsStore, err := openOnboardingEventsStore(*dbPath, *eventsDBPath)
phase4-coordinator/cmd/coordinator-cli/onboarding.go:87:func openOnboardingEventsStore(authDBPath, eventsDBPath string) (*providerevents.SQLiteStore, error) {
phase4-coordinator/cmd/coordinator-cli/onboarding.go:88:	path := strings.TrimSpace(eventsDBPath)
phase4-coordinator/cmd/coordinator-cli/onboarding.go:90:		path = providerevents.DefaultDBPath(authDBPath)
phase4-coordinator/dist/stats-hardware-verifier.service:25:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/cmd/coordinator-cli/referrals.go:18:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/referrals.go:29:	setReferralUsage(fs, "create-seed-referral", "coordinator-cli create-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 100 --apply --operation-id 11111111-1111-4111-8111-111111111111 --actor ops@malibu --reason 'open cohort'")
phase4-coordinator/cmd/coordinator-cli/referrals.go:81:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/referrals.go:92:	setReferralUsage(fs, "adjust-seed-referral", "coordinator-cli adjust-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --seed-id launch --max-uses 250 --apply --operation-id 22222222-2222-4222-8222-222222222222 --expect-state <dry-run-digest> --actor ops@malibu --reason 'expand cohort'")
phase4-coordinator/cmd/coordinator-cli/referrals.go:135:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/referrals.go:143:	setReferralUsage(fs, "revoke-referral", "coordinator-cli revoke-referral --db coordinator.db --campaign prebeta --issuer-id launch --apply --operation-id 33333333-3333-4333-8333-333333333333 --expect-state <dry-run-digest> --actor ops@malibu --reason 'abuse report'")
phase4-coordinator/cmd/coordinator-cli/referrals.go:180:	dbPath := fs.String("db", "coordinator.db", "path to coordinator SQLite database")
phase4-coordinator/cmd/coordinator-cli/referrals.go:193:	setReferralUsage(fs, "replace-seed-referral", "coordinator-cli replace-seed-referral --db coordinator.db --campaign prebeta --key-id k1 --secret-env MAL_REFERRAL_SECRET --old-seed-id launch --new-seed-id launch2 --max-uses 100 --apply --operation-id 44444444-4444-4444-8444-444444444444 --expect-state <dry-run-digest> --actor ops@malibu --reason 'rotate invite'")
phase4-coordinator/dist/coordinator-archive-rotate.sh:2:# coordinator-archive-rotate.sh — coordinator.db archive-rotate scaffold (#1226).
phase4-coordinator/dist/coordinator-archive-rotate.sh:15:#   COORDINATOR_DB_PATH                  default: /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/coordinator-archive-rotate.sh:34:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
phase4-coordinator/dist/coordinator-archive-rotate.sh:128:  local db_path="$1"
phase4-coordinator/dist/coordinator-archive-rotate.sh:131:  if ! out=$(sqlite3 -batch -noheader "$db_path" "$sql" 2>&1); then
phase4-coordinator/dist/coordinator-archive-rotate.sh:132:    log "ERROR: sqlite query failed for $db_path: $out"
phase4-coordinator/dist/coordinator-archive-rotate.sh:152:  local db_path="$1"
phase4-coordinator/dist/coordinator-archive-rotate.sh:155:  n=$(sqlite_scalar_db "$db_path" "SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='$table';")
phase4-coordinator/dist/coordinator-archive-rotate.sh:274:  log "DRY_RUN=1 coordinator.db size=${size}B"
phase4-coordinator/dist/coordinator-archive-rotate.sh:314:  local db_path="$1"
phase4-coordinator/dist/coordinator-archive-rotate.sh:325:  integrity=$(sqlite3 "$db_path" "PRAGMA integrity_check;" || echo "fail")
phase4-coordinator/dist/coordinator-archive-rotate.sh:327:  fk=$(sqlite3 "$db_path" "PRAGMA foreign_key_check;" || echo "fail")
phase4-coordinator/dist/coordinator-archive-rotate.sh:331:  sqlite3 "$db_path" "VACUUM INTO '$esc_snapshot';" || fail "$stem VACUUM INTO failed"
phase4-coordinator/cmd/stats-billing-mirror/main.go:14:	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/coordinator.db")
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go:80:		store, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go:106:	store, err := requestlog.OpenStore(cfg.Storage.DBPath)
phase4-coordinator/dist/coordinator.yaml.example:151:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/dist/coordinator.yaml.example:379:  # Defaults to storage.db_path when unset (SPEC-016 payout address mirror source).
phase4-coordinator/dist/coordinator.yaml.example:380:  # sqlite_payout_db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/internal/ws/identity_migration_test.go:25:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/ws/identity_migration_test.go:123:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/identity_migration_test.go:221:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/tools/spec032canary/main.go:297:	r.sqliteDB = filepath.Join(r.runRoot, "state", "coordinator.db")
phase4-coordinator/tools/spec032canary/main.go:690:	cfg.Storage.DBPath = r.sqliteDB
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:27:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:48:	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:123:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:138:	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:176:	baseDBPath := filepath.Join(dir, "base.db")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:177:	overlayDBPath := filepath.Join(dir, "overlay.db")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:181:	db, err := sql.Open("sqlite", overlayDBPath)
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:195:	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+baseDBPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:198:	if err := os.WriteFile(overlayPath, []byte("storage:\n  db_path: "+overlayDBPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:217:	if _, err := os.Stat(baseDBPath); !os.IsNotExist(err) {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:218:		t.Fatalf("base db was touched despite overlay storage.db_path: stat err=%v", err)
phase4-coordinator/internal/ws/server_test.go:1781:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1840:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1895:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1932:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:2316:	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:2588:	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/cmd/coordinator/migrate_indexes.go:69:		store, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/migrate_indexes.go:98:	store, err := requestlog.OpenStore(cfg.Storage.DBPath)
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh:16:DB="$TMP/coordinator.db"
phase4-coordinator/internal/ws/model_admission_test.go:186:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:399:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:433:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:617:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:842:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:912:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:954:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1030:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1069:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1109:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/ws/model_admission_test.go:1227:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1313:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1372:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1491:		db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1537:		db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1551:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_test.go:1665:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:44:grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:48:grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:54:grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:67:grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:71:grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/stats-billing-mirror.service:7:ConditionPathExists=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:14:ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
phase4-coordinator/dist/stats-billing-mirror.service:23:ReadOnlyPaths=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:24:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/stats-billing-mirror.service:25:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/stats-billing-mirror.service:28:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/coordinator-archive-restore.sh:10:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
phase4-coordinator/dist/coordinator-archive-restore.sh:46:default_audit_db_path_for() {
phase4-coordinator/dist/coordinator-archive-restore.sh:105:LIVE_AUDIT_DB_PATH="${COORDINATOR_AUDIT_DB_PATH:-$(default_audit_db_path_for "$COORDINATOR_DB_PATH")}"
phase4-coordinator/dist/coordinator-archive-restore.sh:107:  COORDINATOR_AUDIT_DB_PATH=$(default_audit_db_path_for "$TARGET_PATH")
phase4-coordinator/dist/coordinator-archive-restore.sh:182:PRIMARY_TMP="$TMP_DIR/coordinator.db"
phase4-coordinator/dist/monitor/macprovider-monitor.service:20:# macprovider-owned so the daemon can write coordinator.db; the
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:151:grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
phase4-coordinator/internal/ws/model_admission_decision_store_test.go:25:			db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:20:DB="$TMP/coordinator.db"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:148:grep -q "DRY_RUN=1 coordinator.db size=" "$TMP/dry.err" || fail "dry-run size report missing"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:424:printf 'live-parent-marker\n' >"$LIVE_DIR/coordinator.db"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:426:COORDINATOR_DB_PATH="$LIVE_DIR/coordinator.db" \
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:433:[ "$(cat "$LIVE_DIR/coordinator.db")" = "live-parent-marker" ] || fail "directory restore mutated live coordinator.db"
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
phase4-coordinator/internal/ws/referral_core_test.go:31:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/canary_store_test.go:14:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_probe_test.go:531:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_disablement_test.go:23:			authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_disablement_test.go:120:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:373:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:407:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:436:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:482:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:547:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:634:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:679:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:717:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:922:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/admission_test.go:968:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_intake_test.go:279:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:42:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:113:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:163:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:188:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:251:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:324:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:365:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:418:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:479:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:541:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:620:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:712:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:763:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:813:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/provider_token_self_serve_test.go:876:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_old_client_compat_test.go:141:	authStore, err := auth.OpenStore(filepath.Join(dir, "coordinator.db"))
phase4-coordinator/internal/ws/admin_onboarding_test.go:56:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/auth_github_test.go:678:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/trustpool/spec043_creator_mvp_journey_test.go:810:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/referralapi/advocacy_test.go:72:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/explorer/handlers_test.go:984:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:38:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:64:	store, err := auth.OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:80:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:96:	path := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:181:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:217:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:252:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:307:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:345:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:394:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:457:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:499:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:518:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:537:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:563:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:584:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:627:				store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:664:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:711:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:754:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:774:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:792:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:832:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:858:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:944:		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:964:		dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:997:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1034:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1071:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1105:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1249:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1285:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1347:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1390:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1406:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1458:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/tokens_test.go:1526:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/tokens_test.go:1589:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/mdm/device_binding_test.go:41:	store, err := OpenMDAStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/mdm/device_binding_test.go:57:	store, err := OpenMDAStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/mdm/device_binding_test.go:374:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:517:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:584:	dbPath := filepath.Join(dir, "coordinator.db")
phase4-coordinator/internal/mdm/device_binding_test.go:942:	store, err := OpenMDAStore(filepath.Join(dir, "coordinator.db"))
phase4-coordinator/internal/buyer/server_test.go:101:	store, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/buyer/server_test.go:7291:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/auth/iss274_provider_id_validator_test.go:17:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/iss274_provider_id_validator_test.go:52:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:353:	tokenStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:504:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:537:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:613:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:659:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:714:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:802:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:891:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:954:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:1214:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/autotune_hello_gate_test.go:1334:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:19:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/auth/portal_sessions_test.go:32:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))

exec
/bin/bash -lc "rg -n --hidden --glob '"'!d-inference/**'"' --glob '"'!.git/**'"' 'request-log\\.sqlite' ." in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 98ms:
./audits/2026-09-25-stats-mirror-db-path/_COMMON.md:13:  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
./audits/2026-09-25-stats-mirror-db-path/_COMMON.md:16:- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
./audits/2026-09-25-stats-mirror-db-path/CODE.md:4:- Every former `request-log.sqlite` path is covered, including rollback restore of the ACLs.
./audits/2026-09-25-stats-mirror-db-path/AUDIT_ARCHITECT_PROMPT.md:13:  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
./audits/2026-09-25-stats-mirror-db-path/AUDIT_ARCHITECT_PROMPT.md:16:- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
./audits/2026-09-25-stats-mirror-db-path/AUDIT_ARCHITECT_PROMPT.md:35:- Whether another environment relies on `request-log.sqlite`.
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:13:  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:16:- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
./audits/2026-09-25-stats-mirror-db-path/AUDIT_CODE_PROMPT.md:34:- Every former `request-log.sqlite` path is covered, including rollback restore of the ACLs.
./audits/2026-09-25-stats-mirror-db-path/AUDIT_SECURITY_PROMPT.md:13:  `/var/lib/macprovider/request-log.sqlite`. The coordinator billing ledger
./audits/2026-09-25-stats-mirror-db-path/AUDIT_SECURITY_PROMPT.md:16:- **What that caused.** On Pearl, `request-log.sqlite` is an empty file. The
./audits/2026-09-25-stats-mirror-db-path/ARCHITECT.md:5:- Whether another environment relies on `request-log.sqlite`.

exec
/bin/bash -lc "rg -n --hidden --glob '"'!d-inference/**'"' --glob '"'!.git/**'"' 'storage:|db_path:' phase4-coordinator/dist phase4-coordinator/config* phase4-coordinator/*.yaml phase4-coordinator/*.yml 2>/dev/null | sed -n '1,220p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/dist/coordinator.yaml:242:storage:
phase4-coordinator/dist/coordinator.yaml:243:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/dist/coordinator-archive-rotate.sh:132:    log "ERROR: sqlite query failed for $db_path: $out"
phase4-coordinator/dist/coordinator.yaml.example:150:storage:
phase4-coordinator/dist/coordinator.yaml.example:151:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/dist/coordinator.yaml.example:380:  # sqlite_payout_db_path: "/var/lib/macprovider/coordinator.db"

exec
/bin/bash -lc "rg -n 'ledger_request_credits|OpenStore|db_path|sqlite' phase4-coordinator/internal/stats/billingmirror phase4-coordinator/internal/requestlog phase4-coordinator/internal/config phase4-coordinator/cmd/coordinator phase4-coordinator/dist/coordinator.yaml phase4-coordinator/dist/coordinator.yaml.example 2>/dev/null | sed -n '1,300p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/dist/coordinator.yaml.example:151:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/dist/coordinator.yaml.example:379:  # Defaults to storage.db_path when unset (SPEC-016 payout address mirror source).
phase4-coordinator/dist/coordinator.yaml.example:380:  # sqlite_payout_db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/dist/coordinator.yaml:111:  sqlite_path: ""
phase4-coordinator/dist/coordinator.yaml:243:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/internal/requestlog/store.go:13:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/requestlog/store.go:14:	_ "modernc.org/sqlite"
phase4-coordinator/internal/requestlog/store.go:118:// OpenStoreReadOnly opens the request-log DB without running ALTER
phase4-coordinator/internal/requestlog/store.go:126:func OpenStoreReadOnly(dbPath string) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go:130:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(dbPath))
phase4-coordinator/internal/requestlog/store.go:139:func OpenStore(dbPath string) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go:143:func OpenStoreWithManualWALCheckpoint(dbPath string) (*Store, error) {
phase4-coordinator/internal/requestlog/store.go:156:	dsn := sqliteutil.WithPragmas(dbPath)
phase4-coordinator/internal/requestlog/store.go:158:		dsn = sqliteutil.WithManualWALCheckpointPragmas(dbPath)
phase4-coordinator/internal/requestlog/store.go:160:	db, err := sql.Open("sqlite", dsn)
phase4-coordinator/internal/requestlog/store.go:167:	// auth.OpenStore and audit.OpenStore already cap at 1; requestlog
phase4-coordinator/internal/requestlog/store.go:544:		sqliteTimeText(row.TSUtc),
phase4-coordinator/internal/requestlog/store.go:585:func sqliteTimeText(t time.Time) string {
phase4-coordinator/internal/requestlog/store.go:817:// sqlite_master and returns the migration state per composite key plus
phase4-coordinator/internal/requestlog/store.go:843:		switch err := s.db.QueryRowContext(ctx, `SELECT name FROM sqlite_master WHERE type='index' AND name=?`, def.IndexName).Scan(&existing); err {
phase4-coordinator/internal/requestlog/store.go:931:	// at OpenStore time so this should always be true; the explicit
phase4-coordinator/internal/requestlog/store.go:1020:// Intentionally NOT called from OpenStore, nor from a goroutine in
phase4-coordinator/internal/requestlog/store.go:1024:// connection (see SetMaxOpenConns(1) in OpenStore), so any in-daemon
phase4-coordinator/internal/requestlog/store.go:1030:// calls are cheap: a sqlite_master point lookup decides whether the
phase4-coordinator/internal/requestlog/store.go:1038:		switch err := s.db.QueryRowContext(ctx, `SELECT name FROM sqlite_master WHERE type='index' AND name=?`, def.IndexName).Scan(&existing); err {
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:12:	_ "modernc.org/sqlite"
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:196:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:197:	db, err := sql.Open("sqlite", path)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:199:		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:201:	if _, err := db.Exec(`CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY)`); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:202:		t.Fatalf("seed sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:205:		t.Fatalf("close sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:246:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:247:	db, err := sql.Open("sqlite", path)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:249:		t.Fatalf("open sqlite seed db: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:253:CREATE TABLE ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:272:  FROM ledger_request_credits
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:285:INSERT INTO ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:297:		t.Fatalf("seed sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:300:		t.Fatalf("close sqlite seed db: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:303:		t.Fatalf("stat seed sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:310:	path := filepath.Join(t.TempDir(), "legacy-request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:311:	db, err := sql.Open("sqlite", path)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:313:		t.Fatalf("open legacy sqlite seed db: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:317:CREATE TABLE ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:333:INSERT INTO ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:342:		t.Fatalf("seed legacy sqlite: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:345:		t.Fatalf("close legacy sqlite seed db: %v", err)
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:348:		t.Fatalf("stat legacy seed sqlite: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go:30:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/cmd/coordinator/main_test.go:64:	reqLogStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "request-log.sqlite"))
phase4-coordinator/cmd/coordinator/main_test.go:66:		t.Fatalf("OpenStore: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go:232:	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go:234:		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go:262:	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go:264:		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go:292:	db, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go:294:		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/cmd/coordinator/main_test.go:303:	if size := sqliteutil.WALFileSize(dbPath); size == 0 {
phase4-coordinator/cmd/coordinator/main_test.go:315:	if size := sqliteutil.WALFileSize(dbPath); size == 0 {
phase4-coordinator/cmd/coordinator/main_test.go:322:	checkpointDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go:334:	writerDB, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go:366:	if size := sqliteutil.WALFileSize(dbPath); size == 0 {
phase4-coordinator/cmd/coordinator/main_test.go:393:	if mode != sqliteutil.WALCheckpointTruncate {
phase4-coordinator/cmd/coordinator/main_test.go:400:	if mode != sqliteutil.WALCheckpointPassive {
phase4-coordinator/cmd/coordinator/main_test.go:469:	checkpointDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go:482:	readerDB, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go:514:	writerDB, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
phase4-coordinator/cmd/coordinator/main_test.go:1100:	cfg.Storage.DBPath = "/tmp/provider.sqlite"
phase4-coordinator/cmd/coordinator/main_test.go:1119:	if got.SQLitePayoutDBPath != "/tmp/provider.sqlite" {
phase4-coordinator/cmd/coordinator/main_test.go:1147:	defaultPath := filepath.Join(tmp, "default.sqlite")
phase4-coordinator/cmd/coordinator/main_test.go:1148:	alternatePath := filepath.Join(tmp, "payout.sqlite")
phase4-coordinator/cmd/coordinator/main_test.go:1149:	defaultStore, err := requestlog.OpenStore(defaultPath)
phase4-coordinator/cmd/coordinator/main_test.go:1182:	path := filepath.Join(tmp, "coordinator.sqlite")
phase4-coordinator/cmd/coordinator/main_test.go:1183:	defaultStore, err := requestlog.OpenStore(path)
phase4-coordinator/cmd/coordinator/main_test.go:1200:	sqliteReader, ok := reader.(*providerws.SQLiteModelAdmissionStore)
phase4-coordinator/cmd/coordinator/main_test.go:1204:	if sqliteReader == writer {
phase4-coordinator/cmd/coordinator/main_test.go:1210:	before, err := sqliteReader.ModelAdmissionProviderRouteGeneration(context.Background(), providerID)
phase4-coordinator/cmd/coordinator/main_test.go:1233:	after, err := sqliteReader.ModelAdmissionProviderRouteGeneration(context.Background(), providerID)
phase4-coordinator/cmd/coordinator/main_test.go:1477:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go:380:	db, err := sql.Open("sqlite", dbPath)
phase4-coordinator/internal/requestlog/store_test.go:382:		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/internal/requestlog/store_test.go:431:	store, err := OpenStore(dbPath)
phase4-coordinator/internal/requestlog/store_test.go:433:		t.Fatalf("OpenStore: %v", err)
phase4-coordinator/internal/requestlog/store_test.go:448:func TestOpenStoreKeepsSQLiteAutocheckpointOwnerDefault(t *testing.T) {
phase4-coordinator/internal/requestlog/store_test.go:461:func TestOpenStoreWithManualWALCheckpointAppliesSQLitePragmasViaDSN(t *testing.T) {
phase4-coordinator/internal/requestlog/store_test.go:462:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go:541:	db, err := sql.Open("sqlite", dbPath)
phase4-coordinator/internal/requestlog/store_test.go:543:		t.Fatalf("open sqlite: %v", err)
phase4-coordinator/internal/requestlog/store_test.go:570:	// assertion below verifies. Insert via store.Insert (after OpenStore)
phase4-coordinator/internal/requestlog/store_test.go:590:	store, err := OpenStore(dbPath)
phase4-coordinator/internal/requestlog/store_test.go:591:	// SPEC-002 v1.4.2 R-2 / ISS-188 R4 audit: OpenStore is column-only;
phase4-coordinator/internal/requestlog/store_test.go:623:		if err := store.db.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?`, name).Scan(&got); err != nil {
phase4-coordinator/internal/requestlog/store_test.go:849:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go:867:	// Fresh OpenStore: both columns present (ensureColumns ran), no
phase4-coordinator/internal/requestlog/store_test.go:923:		t.Skipf("DROP COLUMN unsupported on this sqlite build (need 3.35+): %v", err)
phase4-coordinator/internal/requestlog/store_test.go:1263:// TestOpenStoreCapsPoolAtOneConn pins the SetMaxOpenConns(1) +
phase4-coordinator/internal/requestlog/store_test.go:1271:func TestOpenStoreCapsPoolAtOneConn(t *testing.T) {
phase4-coordinator/internal/stats/billingmirror/mirror.go:16:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/stats/billingmirror/mirror.go:18:	_ "modernc.org/sqlite"
phase4-coordinator/internal/stats/billingmirror/mirror.go:27:	StateSource = "sqlite-ledger-request-credits"
phase4-coordinator/internal/stats/billingmirror/mirror.go:96:		return Result{}, errors.New("sqlite path is required")
phase4-coordinator/internal/stats/billingmirror/mirror.go:254:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
phase4-coordinator/internal/stats/billingmirror/mirror.go:256:		return nil, fmt.Errorf("open sqlite: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:285:	if err := db.QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go:286:		return 0, fmt.Errorf("select max ledger_request_credits id: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:312:	hasPolicy, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "settlement_policy_mode")
phase4-coordinator/internal/stats/billingmirror/mirror.go:316:	hasPayable, err := sqliteObjectExists(ctx, db, "spec022_payable_request_credits")
phase4-coordinator/internal/stats/billingmirror/mirror.go:320:	hasRequestedPrivacyMode, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "requested_privacy_mode")
phase4-coordinator/internal/stats/billingmirror/mirror.go:324:	hasEffectivePrivacyOutcome, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "effective_privacy_outcome")
phase4-coordinator/internal/stats/billingmirror/mirror.go:328:	hasPositiveVerificationExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "positive_verification_excluded")
phase4-coordinator/internal/stats/billingmirror/mirror.go:332:	hasRewardsExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "rewards_excluded")
phase4-coordinator/internal/stats/billingmirror/mirror.go:387:  FROM ledger_request_credits lrc
phase4-coordinator/internal/stats/billingmirror/mirror.go:393:func sqliteColumnExists(ctx context.Context, db *sql.DB, table, column string) (bool, error) {
phase4-coordinator/internal/stats/billingmirror/mirror.go:396:		return false, fmt.Errorf("inspect sqlite table %s: %w", table, err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:415:func sqliteObjectExists(ctx context.Context, db *sql.DB, name string) (bool, error) {
phase4-coordinator/internal/stats/billingmirror/mirror.go:419:            SELECT 1 FROM sqlite_master
phase4-coordinator/internal/stats/billingmirror/mirror.go:430:		return nil, fmt.Errorf("select ledger_request_credits: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:447:			return nil, fmt.Errorf("scan ledger_request_credits: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:468:		return nil, fmt.Errorf("iterate ledger_request_credits: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:698:	`CREATE TABLE IF NOT EXISTS ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror.go:700:    sqlite_lrc_id BIGINT,
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
phase4-coordinator/internal/stats/billingmirror/mirror.go:786:    sqlite_lrc_id BIGINT,
phase4-coordinator/internal/stats/billingmirror/mirror.go:869:    p_sqlite_lrc_id BIGINT,
phase4-coordinator/internal/stats/billingmirror/mirror.go:912:      FROM ledger_request_credits
phase4-coordinator/internal/stats/billingmirror/mirror.go:918:    INSERT INTO ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror.go:919:        sqlite_lrc_id, request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
phase4-coordinator/internal/stats/billingmirror/mirror.go:924:        p_sqlite_lrc_id, p_request_id, p_attempt_n, p_provider_id, p_ts_utc, p_created_at_utc, p_updated_at_utc,
phase4-coordinator/internal/stats/billingmirror/mirror.go:931:        sqlite_lrc_id = EXCLUDED.sqlite_lrc_id,
phase4-coordinator/internal/stats/billingmirror/mirror.go:951:            request_id, attempt_n, provider_id, sqlite_lrc_id,
phase4-coordinator/internal/stats/billingmirror/mirror.go:954:            p_request_id, p_attempt_n, p_provider_id, p_sqlite_lrc_id,
phase4-coordinator/internal/stats/billingmirror/mirror.go:964:        GRANT SELECT ON ledger_request_credits TO stats_rollup;
phase4-coordinator/internal/stats/billingmirror/mirror.go:968:        GRANT SELECT ON ledger_request_credits TO rewards_writer;
phase4-coordinator/internal/stats/billingmirror/mirror.go:1001:        REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go:80:		store, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/backfill_attempt_n.go:106:	store, err := requestlog.OpenStore(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:45:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/cmd/coordinator/main.go:230:	tokenStore, err := auth.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:236:	reqLogStore, err := requestlog.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:242:	moneyCheckpointDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:244:		fmt.Fprintf(os.Stderr, "money sqlite checkpoint: %v\n", err)
phase4-coordinator/cmd/coordinator/main.go:250:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(cfg.Storage.DBPath))
phase4-coordinator/cmd/coordinator/main.go:252:		fmt.Fprintf(os.Stderr, "route snapshot sqlite: %v\n", err)
phase4-coordinator/cmd/coordinator/main.go:258:	routeSnapshotJournalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(routeSnapshotJournalDBPath(cfg.Storage.DBPath)))
phase4-coordinator/cmd/coordinator/main.go:260:		fmt.Fprintf(os.Stderr, "route snapshot journal sqlite: %v\n", err)
phase4-coordinator/cmd/coordinator/main.go:273:	// is added by OpenStore as an additive column. The matching partial-
phase4-coordinator/cmd/coordinator/main.go:276:	// requestlog.OpenStore SetMaxOpenConns(1)), so running CREATE INDEX
phase4-coordinator/cmd/coordinator/main.go:287:	auditStore, err := audit.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/main.go:566:		sqlitePath := strings.TrimSpace(cfg.MalibuEmission.SQLitePayoutDBPath)
phase4-coordinator/cmd/coordinator/main.go:567:		if sqlitePath == "" {
phase4-coordinator/cmd/coordinator/main.go:568:			sqlitePath = cfg.Storage.DBPath
phase4-coordinator/cmd/coordinator/main.go:581:			SQLitePayoutDBPath:           sqlitePath,
phase4-coordinator/cmd/coordinator/main.go:980:			logger.Info().Str("db_path", cfg.Storage.DBPath).Msg("Phase 3 live MDA durable proof store wired")
phase4-coordinator/cmd/coordinator/main.go:990:		relayBlindStore, err = relayblind.OpenStore(cfg.RelayBlind.SQLitePath)
phase4-coordinator/cmd/coordinator/main.go:1997:func startMoneySQLiteWALCheckpointer(ctx context.Context, db *sql.DB, observer sqliteutil.WALObserver, logger zerolog.Logger, idle moneySQLiteIdleTracker, dbPath string) {
phase4-coordinator/cmd/coordinator/main.go:2001:func startMoneySQLiteWALCheckpointerWithConfig(ctx context.Context, db *sql.DB, observer sqliteutil.WALObserver, logger zerolog.Logger, idle moneySQLiteIdleTracker, cfg moneySQLiteWALCheckpointerConfig) {
phase4-coordinator/cmd/coordinator/main.go:2049:func moneySQLiteCheckpointDecision(idle, idleInterval time.Duration, walBytes int64, cfg moneySQLiteWALCheckpointerConfig) (sqliteutil.WALCheckpointMode, time.Duration) {
phase4-coordinator/cmd/coordinator/main.go:2050:	mode := sqliteutil.WALCheckpointPassive
phase4-coordinator/cmd/coordinator/main.go:2052:		mode = sqliteutil.WALCheckpointTruncate
phase4-coordinator/cmd/coordinator/main.go:2057:func runMoneySQLiteWALCheckpoint(ctx context.Context, db *sql.DB, observer sqliteutil.WALObserver, logger zerolog.Logger, idle moneySQLiteIdleTracker, cfg moneySQLiteWALCheckpointerConfig) {
phase4-coordinator/cmd/coordinator/main.go:2062:	walBytes := sqliteutil.WALFileSize(cfg.DBPath)
phase4-coordinator/cmd/coordinator/main.go:2067:	if err := sqliteutil.SetBusyTimeout(ctx, db, cfg.BusyTimeout); err != nil {
phase4-coordinator/cmd/coordinator/main.go:2068:		logger.Warn().Err(err).Int64("wal_bytes", walBytes).Msg("money sqlite WAL busy_timeout failed")
phase4-coordinator/cmd/coordinator/main.go:2074:	result, err := sqliteutil.RunWALCheckpointMode(checkpointCtx, db, "wal_checkpoint", observer, sqliteutil.WALCheckpointPassive)
phase4-coordinator/cmd/coordinator/main.go:2076:		logger.Warn().Err(err).Str("mode", string(sqliteutil.WALCheckpointPassive)).Int64("wal_bytes", walBytes).Msg("money sqlite WAL checkpoint failed")
phase4-coordinator/cmd/coordinator/main.go:2083:	if mode != sqliteutil.WALCheckpointTruncate || result.Busy != 0 || result.LogPages != result.CheckpointedPages {
phase4-coordinator/cmd/coordinator/main.go:2095:	if _, err := sqliteutil.RunWALCheckpointMode(truncateCtx, db, "wal_checkpoint", observer, sqliteutil.WALCheckpointTruncate); err != nil {
phase4-coordinator/cmd/coordinator/main.go:2096:		logger.Warn().Err(err).Str("mode", string(sqliteutil.WALCheckpointTruncate)).Int64("wal_bytes", walBytes).Msg("money sqlite WAL checkpoint failed")
phase4-coordinator/cmd/coordinator/main.go:3553:	payoutStore, err := requestlog.OpenStoreReadOnly(payoutPath)
phase4-coordinator/cmd/coordinator/main.go:3564:	readStore, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/internal/config/config.go:371:	SQLitePayoutDBPath           string   `yaml:"sqlite_payout_db_path"`
phase4-coordinator/internal/config/config.go:717:	// SPEC-005 v0.3 stores `ledger_request_credits.provider_credits`
phase4-coordinator/internal/config/config.go:989:	SQLitePath                string            `yaml:"sqlite_path"`
phase4-coordinator/internal/config/config.go:1223:	DBPath                   string `yaml:"db_path"`
phase4-coordinator/internal/config/config.go:2531:			return fmt.Errorf("relay_blind.sqlite_path must be set when enabled")
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:18:	_ "modernc.org/sqlite"
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:34:	db, err := sql.Open("sqlite", dbPath)
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:48:	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:90:	db, err = sql.Open("sqlite", dbPath)
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:119:// `--format` validation happens before OpenStore, so an invalid
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:125:	db, err := sql.Open("sqlite", dbPath)
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:138:	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\nstorage:\n  db_path: "+dbPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:149:	db, err = sql.Open("sqlite", dbPath)
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:181:	db, err := sql.Open("sqlite", overlayDBPath)
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:195:	if err := os.WriteFile(configPath, []byte("auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: "+baseDBPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:198:	if err := os.WriteFile(overlayPath, []byte("storage:\n  db_path: "+overlayDBPath+"\n"), 0o644); err != nil {
phase4-coordinator/cmd/coordinator/migrate_indexes_test.go:218:		t.Fatalf("base db was touched despite overlay storage.db_path: stat err=%v", err)
phase4-coordinator/cmd/coordinator/migrate_indexes.go:69:		store, err := requestlog.OpenStoreReadOnly(cfg.Storage.DBPath)
phase4-coordinator/cmd/coordinator/migrate_indexes.go:98:	store, err := requestlog.OpenStore(cfg.Storage.DBPath)

exec
/bin/bash -lc "git show origin/main:phase4-coordinator/dist/stats-billing-mirror.service | nl -ba; git log --oneline --all -- phase4-coordinator/dist/stats-billing-mirror.service | sed -n '1,30p'; rg -n 'InaccessiblePaths=.*coordinator\\.db|InaccessiblePaths' phase4-coordinator/dist ops | sed -n '1,220p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 125ms:
c6c326927 Point the stats billing mirror at the coordinator DB that holds the ledger
51746ca05 Record Pearl cut ownership and the pending operator CLI candidate.
6de3e6175 Keep stats billing rows mirrored out of band (#371)
phase4-coordinator/dist/stats-billing-mirror.service:26:InaccessiblePaths=/etc/macprovider
phase4-coordinator/dist/stats-billing-mirror.service:27:InaccessiblePaths=-/opt/macprovider/coordinator.yaml
phase4-coordinator/dist/stats-billing-mirror.service:28:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-hardware-verifier.service:23:InaccessiblePaths=/etc/macprovider
phase4-coordinator/dist/stats-hardware-verifier.service:24:InaccessiblePaths=-/opt/macprovider/coordinator.yaml
phase4-coordinator/dist/stats-hardware-verifier.service:25:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:75:grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||

exec
/bin/bash -lc 'git rev-parse origin/main HEAD; git merge-base origin/main HEAD; git log --oneline --decorate --graph --max-count=12 origin/main HEAD; git diff --name-status origin/main...HEAD' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
c6c3269276f3494cd7ee52ba2b5eae35daa24d6e
c6c3269276f3494cd7ee52ba2b5eae35daa24d6e
c6c3269276f3494cd7ee52ba2b5eae35daa24d6e
* c6c326927 (HEAD -> fix/stats-mirror-coordinator-db, tag: v1.8.197, origin/main, origin/fix/stats-mirror-coordinator-db, origin/HEAD, main) Point the stats billing mirror at the coordinator DB that holds the ledger
* 1148185e7 (tag: v1.8.196) Expect the signed rate card in the deploy catalog canary (#1746)
* 696dfc729 Record fleet impact of the v1.8.194 catalog rollback in the coordinator train
* d9da31b8d Record the partial v1.8.194 apply and canary rollback in the coordinator train
* 52f86ad3d Reserve CLI candidate v1.8.195 for #1742 on the Studio
* 03627cda7 (origin/release/candidate-1.8.195) Continuous batching on the Studio: batched sampling, cached turns, Qwen3.6 throughput (#1646) (#1742)
* 1a8639094 Record the v1.8.194 cut for #1744 in the coordinator release train
* 98ff77ca3 (tag: v1.8.194) Correct eight signed catalog artifact hashes so providers can verify them (#1735) (#1744)
* 27a1bb14e Fix broken internal links in three docs
* d967bc6d4 Resolve the 20.5 vs 36.4 tok/s gap: launchd background priority
* 6b4f35a69 Compare Qwen3.6 serving runtimes on the M3 Ultra against our CB engine
* ea98a0165 Add a catalog hash sweep that recomputes signed rows from Hugging Face (#1735 step 5) (#1739)

exec
/bin/bash -lc "man systemd.exec 2>/dev/null | col -b | rg -n -C 8 'InaccessiblePaths=|ReadOnlyPaths=' | sed -n '1,180p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 87ms:
exec
/bin/bash -lc 'command -v systemd-analyze || true; git show --format=fuller --stat HEAD; git diff HEAD''^ HEAD --check; git diff HEAD''^ HEAD --name-status' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
commit c6c3269276f3494cd7ee52ba2b5eae35daa24d6e
Author:     Augustas11 <augstar@gmail.com>
AuthorDate: Fri Sep 25 16:29:47 2026 +0800
Commit:     Augustas11 <augstar@gmail.com>
CommitDate: Fri Sep 25 16:29:47 2026 +0800

    Point the stats billing mirror at the coordinator DB that holds the ledger
    
    The unit and deploy-pearl-vps.sh read /var/lib/macprovider/request-log.sqlite,
    but the coordinator's billing ledger (ledger_request_credits) lives in its
    configured db_path, /var/lib/macprovider/coordinator.db. On Pearl the
    request-log path is an empty file, so the deploy's initial mirror run failed
    with 'no such table: ledger_request_credits' and rolled back the v1.8.196
    catalog deploy. The unit, the deploy's ACL snapshot/grant and start guard,
    the mirror default and the wiring tests now use coordinator.db, which is
    what Pearl's hand-maintained unit already reads.
    
    Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>

 phase4-coordinator/cmd/stats-billing-mirror/main.go      |  2 +-
 phase4-coordinator/dist/deploy-pearl-vps.sh              | 16 ++++++++--------
 phase4-coordinator/dist/stats-billing-mirror.service     | 10 +++++-----
 .../dist/test/check_deploy_static_feed_access.test.sh    |  2 +-
 .../dist/test/check_stats_billing_mirror_deploy_test.sh  | 12 ++++++------
 .../internal/stats/billingmirror/mirror.go               |  2 +-
 6 files changed, 22 insertions(+), 22 deletions(-)
M	phase4-coordinator/cmd/stats-billing-mirror/main.go
M	phase4-coordinator/dist/deploy-pearl-vps.sh
M	phase4-coordinator/dist/stats-billing-mirror.service
M	phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
M	phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
M	phase4-coordinator/internal/stats/billingmirror/mirror.go

exec
/bin/bash -lc 'git show HEAD''^:phase4-coordinator/dist/stats-billing-mirror.service | nl -ba; git show HEAD''^:phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '"'3128,3150p;3625,3642p;4864,4878p'; sed -n '2250,2290p' ops/pearl-updater/macprovider-pearl-update.py 2>/dev/null || true" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
     1	[Unit]
     2	Description=MacProvider stats billing mirror
     3	Documentation=https://github.com/augstar/macprovider-poc
     4	Wants=network-online.target
     5	After=network-online.target
     6	ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env
     7	ConditionPathExists=/var/lib/macprovider/request-log.sqlite
     8	
     9	[Service]
    10	Type=oneshot
    11	User=macprovider-stats
    12	Group=macprovider-stats
    13	EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env
    14	ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/request-log.sqlite --ensure-schema=false
    15	Nice=10
    16	IOSchedulingClass=best-effort
    17	IOSchedulingPriority=7
    18	NoNewPrivileges=true
    19	PrivateDevices=true
    20	PrivateTmp=true
    21	ProtectHome=true
    22	ProtectSystem=strict
    23	ReadOnlyPaths=/var/lib/macprovider/request-log.sqlite
    24	ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-wal
    25	ReadOnlyPaths=-/var/lib/macprovider/request-log.sqlite-shm
    26	InaccessiblePaths=/etc/macprovider
    27	InaccessiblePaths=-/opt/macprovider/coordinator.yaml
    28	InaccessiblePaths=-/var/lib/macprovider/coordinator.db
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
    snapshot_acl /var/lib/macprovider/request-log.sqlite request-log-db.acl had-request-log-db-acl
    snapshot_acl /var/lib/macprovider/request-log.sqlite-wal request-log-wal.acl had-request-log-wal-acl
    snapshot_acl /var/lib/macprovider/request-log.sqlite-shm request-log-shm.acl had-request-log-shm-acl
  fi
  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
    touch \"\$_rollback_stage/had-wants-link\"
  fi
  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
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
    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite
    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-wal
    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite-shm
  elif [ -f /var/lib/macprovider/request-log.sqlite ]; then
    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
  fi
  # Stage the complete immutable catalog release. Activation happens only
  # after the late connected-provider safeguard immediately before restart.
      rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
      systemctl is-active stats-inventory-sync.timer
    fi
  elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
    systemctl start stats-inventory-sync.timer
    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
  elif [ "$_parity_required" = absent ]; then
    echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
  fi
  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ] && su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats; then
    systemctl enable --now stats-billing-mirror.timer
    if ! systemctl start stats-billing-mirror.service; then
      systemctl disable --now stats-billing-mirror.timer
      echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
      journalctl -u stats-billing-mirror.service -n 30 --no-pager || true

exec
/bin/bash -lc "sed -n '1,130p' phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh; sed -n '130,165p' phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh; sed -n '1,120p' phase4-coordinator/internal/stats/billingmirror/mirror.go; sed -n '240,460p' phase4-coordinator/internal/stats/billingmirror/mirror.go" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
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
LEGACY_16_WRITER_REVOKE='REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) FROM stats_billing_mirror_writer'
for source in "$BOOTSTRAP_SQL" "$MIGRATION_SQL" "$MIRROR_GO"; do
  grep -qF "$LEGACY_16_WRITER_REVOKE" "$source" ||
    fail "$source must revoke the legacy 16-argument SECURITY DEFINER function from the mirror writer"
done

if ! BOOTSTRAP_SQL="$BOOTSTRAP_SQL" MIGRATION_SQL="$MIGRATION_SQL" MIRROR_GO="$MIRROR_GO" python3 <<'PY'
import os
  fail "coordinator rollback must preserve the exact Tier-2 signed catalog"

grep -q 'had-coordinator-cli' "$DEPLOY_SH" && grep -q 'restore_regular had-coordinator-cli' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve the matching operator CLI"

for marker in had-stats-inventory-binary had-stats-billing-binary had-stats-hardware-binary \
  had-stats-inventory-service had-stats-inventory-timer \
  had-stats-billing-service had-stats-billing-timer \
  had-stats-hardware-service had-stats-hardware-timer; do
  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
    fail "coordinator rollback coverage missing for $marker"
done

for marker in had-nginx-stats-shared had-nginx-stats-security-headers \
  had-nginx-stats-cors-429 had-nginx-stats-proxy-public \
  had-nginx-stats-proxy-partner had-nginx-coordinator-site \
  had-nginx-stats-site had-nginx-coordinator-enabled had-nginx-stats-enabled; do
  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
    fail "nginx rollback coverage missing for $marker"
done

grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
  grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
  fail "request-log ACL changes must be captured and restored"

grep -q 'try-reload-or-restart nginx' "$RECOVER_SH" ||
  fail "rollback must validate and activate the restored nginx graph"

freeze_line=$(grep -nF '# Freeze sidecar execution for the release window.' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
binary_install_line=$(grep -nF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
sidecar_activate_line=$(grep -nF '# Sidecars remain frozen until every coordinator/catalog/canary check has' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
commit_line=$(grep -nF 'touch /opt/macprovider/.coordinator-deploy-rollback/committed' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$freeze_line" ] && [ -n "$binary_install_line" ] && [ "$freeze_line" -lt "$binary_install_line" ] ||
  fail "stats sidecars must freeze before transaction binaries are replaced"
[ -n "$sidecar_activate_line" ] && [ -n "$commit_line" ] && [ "$sidecar_activate_line" -lt "$commit_line" ] ||
  fail "stats sidecars must reactivate only as the final pre-commit mutation"
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

codex
The repository refs now resolve `origin/main` and `HEAD` to the same commit, so the literal requested range is empty; the six-file change is the current `HEAD` commit (`c6c326927`) and I’m auditing it against `HEAD^`. The production search finds no remaining `/var/lib/macprovider/request-log.sqlite` reference outside test fixtures and audit notes. The sandbox overlap remains the main architecture risk; I’m now validating it against the existing test coverage and rollout scripts.
exec
/bin/bash -lc "rg -n 'test-dist|check_stats_billing_mirror|test-pearl-runtime|stats-billing-mirror' Makefile scripts phase4-coordinator/Makefile phase4-coordinator/dist/test 2>/dev/null | sed -n '1,240p'; sed -n '1,260p' scripts/test-pearl-runtime-release.sh | sed -n '1,180p'; rg -n 'RUNTIME_TAG|runtime tag|PINNED_RUNTIME|deploy-pearl-vps|release' phase4-coordinator/dist/deploy-pearl-vps.sh scripts/verify-pearl-runtime-release.sh scripts/test-pearl-runtime-release.sh | sed -n '1,300p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
Makefile:8:.PHONY: test test-coordinator test-coordinator-integration test-gateway test-integration test-dist \
Makefile:14:test: test-coordinator test-gateway test-integration test-dist
Makefile:76:test-dist:
Makefile:89:	bash scripts/test-pearl-runtime-release.sh
Makefile:193:	bash phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
phase4-coordinator/dist/test/check_nginx_receipt_header_live_test.sh:6:  # echo URL was configured, which made `make test-dist` and the AC-15
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:114:    "$STATS_ROOT/stats-inventory-sync" "$STATS_ROOT/stats-billing-mirror" "$STATS_ROOT/stats-hardware-verifier" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:116:    "$SYSTEMD/stats-billing-mirror.service" "$SYSTEMD/stats-billing-mirror.timer" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:119:    "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer" \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:143:  for artifact in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:154:    stats-billing-mirror.service stats-billing-mirror.timer \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:196:  for artifact in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:200:    stats-billing-mirror.service stats-billing-mirror.timer \
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:205:  ln -s ../stats-billing-mirror.timer "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:232:[ "$(cat "$STATS_ROOT/stats-billing-mirror")" = old-stats-billing-mirror ] || fail "stats billing binary was not restored"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:239:[ ! -e "$SYSTEMD/timers.target.wants/stats-billing-mirror.timer" ] || fail "new stats timer enablement was not removed"
phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh:254:grep -qx 'start stats-billing-mirror.service' "$SYSTEMCTL_LOG" || fail "active stats service state was not restored"
phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh:66:grep -qF 'refusing stats-billing-mirror replacement from direct deploy' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh:67:  fail "deploy must not replace stats-billing-mirror from ignored local artifacts"
phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh:94:  'STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"' \
phase4-coordinator/dist/test/check_stats_inventory_deploy_test.sh:753:  in_block && /^  if \[ -f \/etc\/macprovider-stats\/stats-billing-mirror\.env / { exit }
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:2:# check_stats_billing_mirror_deploy_test.sh — offline validation for the
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
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:50:grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:52:grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:54:grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:56:grep -qF 'systemctl disable --now stats-billing-mirror.timer' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:58:grep -qF 'aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:65:grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:69:grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:71:grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
scripts/test-swift-package-lock.sh:36:    raise SystemExit("Makefile test-dist must run scripts/test-swift-package-lock.sh")
scripts/test-release-security-posture.sh:537:# `make test-dist` (the only CI consumer of the sealed catalog verifier) runs
scripts/test-release-security-posture.sh:540:if ci_workflow.count("run: make test-dist") != 1:
scripts/test-release-security-posture.sh:541:    raise SystemExit("make test-dist must run in exactly one CI job (dist-tooling)")
scripts/test-release-security-posture.sh:545:test_dist_index = ci_workflow.find("run: make test-dist")
scripts/test-release-security-posture.sh:547:    raise SystemExit("the Linux CI verifier seal must precede the make test-dist step it protects")
scripts/enforce-tier2-hash.sh:475:    for unit in macprovider-coordinator.service macprovider-gateway.service canary-buyer.service macprovider-archive-rotate.service stats-billing-mirror.service; do
scripts/verify-pearl-runtime-release.sh:107:  stats-billing-mirror-linux-amd64
scripts/verify-pearl-runtime-release.sh:214:    "stats_billing_mirror": "stats-billing-mirror-linux-amd64",
scripts/verify-pearl-runtime-release.sh:230:            "cut a Pearl runtime release that signs stats-inventory-sync, stats-billing-mirror, "
scripts/verify-pearl-go-binaries.py:21:    "stats-billing-mirror-linux-amd64": "github.com/augstar/macprovider-coordinator/cmd/stats-billing-mirror",
scripts/verify-pearl-go-binaries.py:36:        "stats-billing-mirror-linux-amd64",
scripts/verify-pearl-go-binaries.py:174:        valid.replace("/cmd/coordinator\n", "/cmd/stats-billing-mirror\n", 1),
scripts/verify-pearl-go-binaries.py:200:            " optionally followed by stats-inventory-sync, stats-billing-mirror, and stats-hardware-verifier",
scripts/test-pearl-runtime-release.sh:111:for sidecar in ("stats-inventory-sync", "stats-billing-mirror", "stats-hardware-verifier"):
scripts/test-pearl-runtime-release.sh:113:    if "for sidecar in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do" not in build:
scripts/test-pearl-runtime-release.sh:159:    printf '%s\n' stats-billing-mirror > "$directory/stats-billing-mirror-linux-amd64"
scripts/test-pearl-runtime-release.sh:539:deploy_assets=(coordinator-linux-amd64 coordinator-cli-linux-amd64 stats-inventory-sync-linux-amd64 stats-billing-mirror-linux-amd64 stats-hardware-verifier-linux-amd64)
scripts/test-pearl-runtime-release.sh:579:printf '%s\n' stray > "$work/release-sidecars-stray/stats-billing-mirror-linux-amd64"
scripts/test-pearl-runtime-release.sh:586:grep -q 'release carries stats sidecar asset(s) pearl-release.json does not bind: stats-billing-mirror-linux-amd64' \
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/verify-pearl-runtime-release.sh"
runtime_workflow="$repo_root/.github/workflows/pearl-runtime-release.yml"
work="$(mktemp -d "${TMPDIR:-/tmp}/pearl-runtime-release-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$guard"
# Operator deploys run this guard under macOS /bin/bash 3.2. A process
# substitution is parsed before its quoted heredoc, so a Python set
# comprehension inside <() dies before any asset is staged.
if grep -n 'done < <(' "$guard"; then
  fail "verify-pearl-runtime-release.sh uses process substitution; operator Mac bash 3.2 rejects a heredoc inside <()"
fi
python3 - "$runtime_workflow" <<'PY'
import pathlib
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
if workflow.count("scripts/verify-github-release-posture.sh") < 3:
    raise SystemExit("runtime workflow must verify protected posture before signing, draft, and publish")
before_sign = workflow.split("- name: Sign Pearl runtime metadata and checksums", 1)[0]
if "Verify protected GitHub release posture before runtime signing" not in before_sign:
    raise SystemExit("runtime workflow must verify protected posture before importing signing key")
create = workflow.split("- name: Create verified draft GitHub release", 1)[1].split(
    "- name: Publish only the revalidated numeric draft", 1
)[0]
if "RELEASE_POSTURE_TOKEN" not in create or "verify-github-release-posture.sh" not in create:
    raise SystemExit("runtime workflow must recheck protected posture before draft creation")
publish = workflow.split("- name: Publish only the revalidated numeric draft", 1)[1]
if "RELEASE_POSTURE_TOKEN" not in publish or "verify-github-release-posture.sh" not in publish:
    raise SystemExit("runtime workflow must recheck protected posture immediately before publication")
if "make_latest=true" in publish or "true|false) make_latest=false" not in publish:
    raise SystemExit("runtime workflow must never make a runtime-only release latest")
if 'RELEASE_PRERELEASE_INPUT: "true"' not in workflow:
    raise SystemExit("runtime workflow must force GitHub prerelease publication")
if 'EXPECTED_REVISION="${{ steps.release_source.outputs.commit }}"' not in workflow:
    raise SystemExit("runtime workflow must bind Pearl Go binary verification to the reviewed commit")
before_build = workflow.split("- name: Build Pearl linux-amd64 runtime pair", 1)[0]
if "id: release_toolchain" not in before_build:
    raise SystemExit("runtime workflow must expose the reviewed toolchain path as a step output")
if 'toolchain_json="$RUNNER_TEMP/release-toolchain.json"' not in before_build:
    raise SystemExit("runtime workflow must keep release-toolchain.json outside the git worktree before Go builds")
if "scripts/verify-release-toolchain.sh release-toolchain.json" in before_build:
    raise SystemExit("runtime workflow must not write release-toolchain.json into the git worktree before Go builds")
build = workflow.split("- name: Build Pearl linux-amd64 runtime pair", 1)[1].split(
    "- name: Sign Pearl runtime metadata and checksums", 1
)[0]
if 'artifact_dir="$RUNNER_TEMP/pearl-runtime-build"' not in build:
    raise SystemExit("runtime workflow must build Pearl Go binaries outside the git worktree")
if "git status --porcelain --untracked-files=all" not in build:
    raise SystemExit("runtime workflow must fail closed when the checkout is dirty before Go builds")
if '-o "$GITHUB_WORKSPACE/' in build:
    raise SystemExit("runtime workflow must not write Go build outputs into the git worktree")
if 'python3 scripts/verify-pearl-go-binaries.py \\\n            "$artifact_dir/coordinator-linux-amd64" \\\n            "$artifact_dir/coordinator-cli-linux-amd64" \\\n            "$artifact_dir/gateway-linux-amd64"' not in build:
    raise SystemExit("runtime workflow must verify the out-of-worktree Pearl Go binaries")
verify_position = build.find("python3 scripts/verify-pearl-go-binaries.py")
install_position = build.find('install -m 0755 "$artifact_dir/coordinator-linux-amd64" coordinator-linux-amd64')
if verify_position < 0 or install_position < 0 or install_position < verify_position:
    raise SystemExit("runtime workflow must copy release assets into the workspace only after binary verification")
sign = workflow.split("- name: Sign Pearl runtime metadata and checksums", 1)[1].split(
    "- name: Prepare runtime release notes", 1
)[0]
toolchain_copy = 'install -m 0644 "${{ steps.release_toolchain.outputs.json }}" release-toolchain.json'
if toolchain_copy not in sign:
    raise SystemExit("runtime workflow must copy release-toolchain.json into release assets only after binary verification")
if sign.find(toolchain_copy) > sign.find("scripts/build-release-provenance.py"):
    raise SystemExit("runtime workflow must copy release-toolchain.json before building provenance")
patch_position = publish.find("gh api --method PATCH")
if patch_position < 0:
    raise SystemExit("runtime workflow must publish by numeric-ID PATCH")
positive_latest_position = publish.find("stable latest endpoint before publication did not return a positive release id")
if positive_latest_position < 0 or positive_latest_position > patch_position:
    raise SystemExit("runtime workflow must validate stable latest before publishing anything")
if "-F prerelease=false" in publish:
    raise SystemExit("runtime workflow must never promote runtime-only releases to GitHub stable releases")
for required in (
    "capture-release-publication.py --draft --runtime-only",
    "--expected-title \"Pearl runtime $tag\"",
    "final-draft-api.json release-provenance.json final-draft-manifest.json",
):
    if publish.find(required) < 0 or publish.find(required) > patch_position:
        raise SystemExit(f"runtime workflow draft asset capture is incomplete: {required}")
for required in (
    "-F prerelease=true",
    "published-release-api.json",
    "immutable-release-by-id.json release-provenance.json publication-manifest-by-id.json",
    "immutable-release-by-tag.json release-provenance.json publication-manifest-by-tag.json",
    "cmp final-draft-manifest.json publication-manifest-by-id.json",
    "cmp final-draft-manifest.json publication-manifest-by-tag.json",
):
    if publish.find(required, patch_position) < 0:
        raise SystemExit(f"runtime workflow immutable asset capture is incomplete: {required}")
for required in (
    "stable-latest-before.json",
    "stable-latest-after.json",
    "stable latest endpoint before publication did not return a positive release id",
    "stable latest endpoint after publication did not return a positive release id",
    "runtime-only release unexpectedly resolves through the stable latest endpoint",
    "runtime-only release changed the stable latest endpoint",
):
    if required not in publish:
        raise SystemExit(f"runtime workflow latest-preservation check is incomplete: {required}")
for sidecar in ("stats-inventory-sync", "stats-billing-mirror", "stats-hardware-verifier"):
    asset = f"{sidecar}-linux-amd64"
    if "for sidecar in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do" not in build:
        raise SystemExit("runtime workflow must build every stats sidecar the full deploy compares byte-for-byte")
    if f'"$artifact_dir/{asset}"' not in build.split("python3 scripts/verify-pearl-go-binaries.py", 1)[1]:
        raise SystemExit(f"runtime workflow must verify {asset} with the Pearl Go binary verifier")
    if f'install -m 0755 "$artifact_dir/{asset}" {asset}' not in build:
        raise SystemExit(f"runtime workflow must stage {asset} as a release asset")
    key = sidecar.replace("-", "_")
    if f'"{key}": {{\n                      "asset": "{asset}",' not in sign:
        raise SystemExit(f"runtime workflow must bind {asset} in signed pearl-release.json operator_artifacts")
    assets_block = sign.split("release_assets=(", 1)[1].split(")", 1)[0]
    if asset not in assets_block.split():
        raise SystemExit(f"runtime workflow must publish {asset} in the signed release asset list")
latest_window = publish[publish.find("stable-latest-before.json"):publish.find("python3 scripts/capture-release-publication.py --runtime-only")]
if "printf '%s\\n' '{}'" in latest_window:
    raise SystemExit("runtime workflow must fail closed when stable latest cannot be fetched")
PY

git init --bare -q "$work/remote.git"
git init -q "$work/source"
git -C "$work/source" config user.name pearl-runtime-release-test
git -C "$work/source" config user.email pearl-runtime-release-test@example.invalid
printf '%s\n' one > "$work/source/value"
git -C "$work/source" add value
git -C "$work/source" commit -qm one
first="$(git -C "$work/source" rev-parse HEAD)"
printf '%s\n' two > "$work/source/value"
git -C "$work/source" commit -qam two
second="$(git -C "$work/source" rev-parse HEAD)"
git -C "$work/source" remote add origin "$work/remote.git"
git -C "$work/source" push -q origin HEAD:refs/heads/main
git -C "$work/source" tag v1.8.66 "$second"
git -C "$work/source" push -q origin refs/tags/v1.8.66

make_release_dir() {
  local directory="$1"
  local tag="$2"
  local commit="$3"
  local lane="${4:-pearl_runtime_catalog}"
  local sidecars="${5:-}"
  rm -rf "$directory"
  mkdir -p "$directory"
  printf '%s\n' coordinator > "$directory/coordinator-linux-amd64"
  printf '%s\n' coordinator-cli > "$directory/coordinator-cli-linux-amd64"
  printf '%s\n' gateway > "$directory/gateway-linux-amd64"
  if [[ "$sidecars" == sidecars ]]; then
    printf '%s\n' stats-inventory-sync > "$directory/stats-inventory-sync-linux-amd64"
    printf '%s\n' stats-billing-mirror > "$directory/stats-billing-mirror-linux-amd64"
    printf '%s\n' stats-hardware-verifier > "$directory/stats-hardware-verifier-linux-amd64"
  fi
  printf '%s\n' signed-metadata > "$directory/pearl-release.json.sig"
  printf '%s\n' signed-checksums > "$directory/checksums.txt.sig"
  printf '%s\n' catalog-release > "$directory/release.json"
  printf '%s\n' trusted-keys > "$directory/trusted-keys.json"
  printf '%s\n' tier2-catalog > "$directory/tier2-catalog.json"
  printf '%s\n' autotune-candidates > "$directory/autotune-candidates.json"
  printf '%s\n' autotune-candidates-sig > "$directory/autotune-candidates.json.sig"
  printf '%s\n' demand-rank > "$directory/demand-rank.json"
  printf '%s\n' demand-rank-sig > "$directory/demand-rank.json.sig"
  printf '%s\n' rate-card > "$directory/rate-card.json"
  printf '%s\n' rate-card-sig > "$directory/rate-card.json.sig"
  if [[ "$lane" == pearl_runtime_catalog_artifacts ]]; then
    printf '%s\n' autotune-artifacts > "$directory/autotune-artifacts.json"
    printf '%s\n' autotune-artifacts-sig > "$directory/autotune-artifacts.json.sig"
  fi
  python3 - "$directory" "$tag" "$commit" "$lane" <<'PY'
import hashlib
import json
import pathlib
scripts/verify-pearl-runtime-release.sh:6:usage: scripts/verify-pearl-runtime-release.sh --tag vX.Y.Z --expected-commit SHA [options]
scripts/verify-pearl-runtime-release.sh:8:Verifies that a release tag is suitable for Pearl runtime rollout before
scripts/verify-pearl-runtime-release.sh:9:running macprovider-pearl-update or deploy-pearl-vps.sh.
scripts/verify-pearl-runtime-release.sh:12:  --tag TAG                 release tag, vX.Y.Z
scripts/verify-pearl-runtime-release.sh:13:  --expected-commit SHA      exact reviewed source commit expected for the release
scripts/verify-pearl-runtime-release.sh:16:  --release-dir DIR          verify a local release asset directory instead of GitHub
scripts/verify-pearl-runtime-release.sh:19:                            binaries into DIR for deploy-pearl-vps.sh
scripts/verify-pearl-runtime-release.sh:28:  printf '[verify-pearl-runtime-release] ERROR: %s\n' "$*" >&2
scripts/verify-pearl-runtime-release.sh:36:release_dir=""
scripts/verify-pearl-runtime-release.sh:57:    --release-dir)
scripts/verify-pearl-runtime-release.sh:58:      release_dir="${2:-}"
scripts/verify-pearl-runtime-release.sh:91:bash "$root/scripts/verify-release-tag-target.sh" \
scripts/verify-pearl-runtime-release.sh:95:  pearl-release.json
scripts/verify-pearl-runtime-release.sh:96:  pearl-release.json.sig
scripts/verify-pearl-runtime-release.sh:104:# never installs them itself; the signed updater installs them from the release.
scripts/verify-pearl-runtime-release.sh:116:validate_release_dir() {
scripts/verify-pearl-runtime-release.sh:118:  [[ -d "$directory" ]] || die "release directory does not exist: $directory"
scripts/verify-pearl-runtime-release.sh:125:    die "missing Pearl runtime release asset(s): ${missing[*]}"
scripts/verify-pearl-runtime-release.sh:143:    print(f"[verify-pearl-runtime-release] ERROR: {message}", file=sys.stderr)
scripts/verify-pearl-runtime-release.sh:154:    metadata = json.loads((directory / "pearl-release.json").read_text(encoding="utf-8"))
scripts/verify-pearl-runtime-release.sh:156:    fail(f"pearl-release.json is not valid JSON: {exc}")
scripts/verify-pearl-runtime-release.sh:159:    fail("pearl-release.json has unsupported schema")
scripts/verify-pearl-runtime-release.sh:160:lane = metadata.get("release_lane", "pearl_runtime_catalog")
scripts/verify-pearl-runtime-release.sh:162:    fail("pearl-release.json release_lane is invalid")
scripts/verify-pearl-runtime-release.sh:164:    fail(f"pearl-release.json repository is {metadata.get('repository')!r}, expected {repository!r}")
scripts/verify-pearl-runtime-release.sh:166:    fail(f"pearl-release.json tag is {metadata.get('tag')!r}, expected {tag!r}")
scripts/verify-pearl-runtime-release.sh:168:    fail(f"pearl-release.json commit is {metadata.get('commit')!r}, expected {expected_commit!r}")
scripts/verify-pearl-runtime-release.sh:170:    fail("pearl-release.json architecture must be linux-amd64")
scripts/verify-pearl-runtime-release.sh:172:if metadata.get("release_version") != version:
scripts/verify-pearl-runtime-release.sh:173:    fail("pearl-release.json release_version does not match the tag")
scripts/verify-pearl-runtime-release.sh:176:        fail("pearl-release.json runtime-only lane must not carry provider advertised version")
scripts/verify-pearl-runtime-release.sh:179:        fail("pearl-release.json provider_advertised_version does not match the tag")
scripts/verify-pearl-runtime-release.sh:183:    fail("pearl-release.json components are missing")
scripts/verify-pearl-runtime-release.sh:193:        fail(f"pearl-release.json {name} component does not bind {asset}")
scripts/verify-pearl-runtime-release.sh:196:        fail(f"pearl-release.json {name} sha256 is invalid")
scripts/verify-pearl-runtime-release.sh:199:        fail(f"{asset} sha256 does not match pearl-release.json")
scripts/verify-pearl-runtime-release.sh:204:    fail("pearl-release.json coordinator CLI artifact does not bind coordinator-cli-linux-amd64")
scripts/verify-pearl-runtime-release.sh:207:    fail("pearl-release.json coordinator CLI sha256 is invalid")
scripts/verify-pearl-runtime-release.sh:210:    fail("coordinator-cli-linux-amd64 sha256 does not match pearl-release.json")
scripts/verify-pearl-runtime-release.sh:219:    fail("pearl-release.json binds unknown operator artifacts: " + " ".join(unknown_operator_artifacts))
scripts/verify-pearl-runtime-release.sh:222:    fail("pearl-release.json binds an incomplete stats sidecar set")
scripts/verify-pearl-runtime-release.sh:226:        fail("release carries stats sidecar asset(s) pearl-release.json does not bind: " + " ".join(stray_sidecars))
scripts/verify-pearl-runtime-release.sh:229:            "pearl-release.json does not bind the stats sidecars the full deploy requires; "
scripts/verify-pearl-runtime-release.sh:230:            "cut a Pearl runtime release that signs stats-inventory-sync, stats-billing-mirror, "
scripts/verify-pearl-runtime-release.sh:236:        fail(f"pearl-release.json {key} artifact does not bind {asset}")
scripts/verify-pearl-runtime-release.sh:239:        fail(f"pearl-release.json {key} sha256 is invalid")
scripts/verify-pearl-runtime-release.sh:241:        fail(f"missing Pearl runtime release asset(s): {asset}")
scripts/verify-pearl-runtime-release.sh:243:        fail(f"{asset} sha256 does not match pearl-release.json")
scripts/verify-pearl-runtime-release.sh:268:    "release.json",
scripts/verify-pearl-runtime-release.sh:280:        fail("pearl-release.json runtime-only lane must not bind catalog/feed assets")
scripts/verify-pearl-runtime-release.sh:283:        fail("pearl-release.json catalog metadata is missing")
scripts/verify-pearl-runtime-release.sh:286:    # SPEC-023 §3.7.8 Stage A: the catalog release.json is the binding
scripts/verify-pearl-runtime-release.sh:288:    # sidecar are two more catalog assets that pearl-release.json MUST bind and
scripts/verify-pearl-runtime-release.sh:289:    # the release MUST carry; otherwise neither may appear. Both sets are exact.
scripts/verify-pearl-runtime-release.sh:294:        release_feeds = json.loads((directory / "release.json").read_text(encoding="utf-8")).get("feeds")
scripts/verify-pearl-runtime-release.sh:295:        artifact_bound = isinstance(release_feeds, dict) and "autotune-artifacts.json" in release_feeds
scripts/verify-pearl-runtime-release.sh:296:        artifact_record = release_feeds.get("autotune-artifacts.json") if artifact_bound else None
scripts/verify-pearl-runtime-release.sh:302:            fail("release.json artifact feed record is invalid")
scripts/verify-pearl-runtime-release.sh:307:                fail("autotune-artifacts.json does not match its release.json binding")
scripts/verify-pearl-runtime-release.sh:310:            fail("pearl-release.json catalog file set disagrees with release.json feeds on the artifact feed")
scripts/verify-pearl-runtime-release.sh:311:        fail("pearl-release.json catalog file set is invalid")
scripts/verify-pearl-runtime-release.sh:315:            fail("release carries artifact-feed asset(s) release.json does not bind: " + " ".join(stray))
scripts/verify-pearl-runtime-release.sh:318:        fail("missing catalog/feed asset(s) for catalog-bound Pearl runtime release: " + " ".join(missing_catalog))
scripts/verify-pearl-runtime-release.sh:322:            fail(f"pearl-release.json catalog sha256 is invalid for {asset}")
scripts/verify-pearl-runtime-release.sh:325:            fail(f"{asset} sha256 does not match pearl-release.json catalog metadata")
scripts/verify-pearl-runtime-release.sh:332:print(f"[verify-pearl-runtime-release] ok: {tag} has Pearl runtime assets for {expected_commit}")
scripts/verify-pearl-runtime-release.sh:345:if [[ -n "$release_dir" ]]; then
scripts/verify-pearl-runtime-release.sh:346:  validate_release_dir "$release_dir"
scripts/verify-pearl-runtime-release.sh:347:  copy_deploy_artifacts "$release_dir"
scripts/verify-pearl-runtime-release.sh:351:command -v gh >/dev/null 2>&1 || die "gh CLI is required unless --release-dir is provided"
scripts/verify-pearl-runtime-release.sh:352:work="$(mktemp -d "${TMPDIR:-/tmp}/pearl-runtime-release.XXXXXX")"
scripts/verify-pearl-runtime-release.sh:355:if ! gh release view "$tag" --repo "$repository" --json tagName,isDraft,isPrerelease,assets > "$work/release.json" 2>"$work/release.err"; then
scripts/verify-pearl-runtime-release.sh:356:  die "Pearl runtime release assets are missing for $tag: GitHub release not found"
scripts/verify-pearl-runtime-release.sh:359:PEARL_RELEASE_VIEW="$work/release.json" \
scripts/verify-pearl-runtime-release.sh:369:    print(f"[verify-pearl-runtime-release] ERROR: {message}", file=sys.stderr)
scripts/verify-pearl-runtime-release.sh:376:    fail("GitHub release tag does not match requested tag")
scripts/verify-pearl-runtime-release.sh:378:    fail("GitHub release is still draft; Pearl rollout requires published immutable assets")
scripts/verify-pearl-runtime-release.sh:384:    fail("missing Pearl runtime release asset(s): " + " ".join(missing))
scripts/verify-pearl-runtime-release.sh:387:gh release download "$tag" --repo "$repository" --dir "$work/assets" \
scripts/verify-pearl-runtime-release.sh:388:  --pattern pearl-release.json --pattern pearl-release.json.sig \
scripts/verify-pearl-runtime-release.sh:393:# The stats sidecars are bound all-or-none by pearl-release.json; fetch any the
scripts/verify-pearl-runtime-release.sh:394:# release publishes so the local validator can check the binding both ways.
scripts/verify-pearl-runtime-release.sh:398:  PEARL_RELEASE_VIEW="$work/release.json" \
scripts/verify-pearl-runtime-release.sh:418:  gh release download "$tag" --repo "$repository" --dir "$work/assets" \
scripts/verify-pearl-runtime-release.sh:423:  PEARL_RELEASE_METADATA="$work/assets/pearl-release.json" python3 - <<'PY'
scripts/verify-pearl-runtime-release.sh:431:    print(f"[verify-pearl-runtime-release] ERROR: pearl-release.json is not valid JSON: {exc}", file=sys.stderr)
scripts/verify-pearl-runtime-release.sh:433:lane = metadata.get("release_lane", "pearl_runtime_catalog") if isinstance(metadata, dict) else None
scripts/verify-pearl-runtime-release.sh:435:    print("[verify-pearl-runtime-release] ERROR: pearl-release.json release_lane is invalid", file=sys.stderr)
scripts/verify-pearl-runtime-release.sh:443:    release.json
scripts/verify-pearl-runtime-release.sh:453:  PEARL_RELEASE_VIEW="$work/release.json" \
scripts/verify-pearl-runtime-release.sh:467:        "[verify-pearl-runtime-release] ERROR: missing catalog/feed asset(s) for catalog-bound Pearl runtime release: "
scripts/verify-pearl-runtime-release.sh:473:  gh release download "$tag" --repo "$repository" --dir "$work/assets" \
scripts/verify-pearl-runtime-release.sh:474:    --pattern release.json --pattern trusted-keys.json \
scripts/verify-pearl-runtime-release.sh:479:  # SPEC-023 §3.7.8 Stage A: the downloaded release.json decides whether the
scripts/verify-pearl-runtime-release.sh:480:  # artifact feed and its sidecar are release assets too; fetch them so the
scripts/verify-pearl-runtime-release.sh:482:  artifact_feed_state="$(python3 - "$work/assets/release.json" <<'PY'
scripts/verify-pearl-runtime-release.sh:492:    # A rate-card-bound release must not publish the pair at all.
scripts/verify-pearl-runtime-release.sh:493:    PEARL_RELEASE_VIEW="$work/release.json" python3 - <<'PY'
scripts/verify-pearl-runtime-release.sh:503:        "[verify-pearl-runtime-release] ERROR: release publishes artifact-feed asset(s) release.json does not bind: "
scripts/verify-pearl-runtime-release.sh:511:    PEARL_RELEASE_VIEW="$work/release.json" \
scripts/verify-pearl-runtime-release.sh:525:        "[verify-pearl-runtime-release] ERROR: missing catalog/feed asset(s) for catalog-bound Pearl runtime release: "
scripts/verify-pearl-runtime-release.sh:531:    gh release download "$tag" --repo "$repository" --dir "$work/assets" \
scripts/verify-pearl-runtime-release.sh:535:  PEARL_RELEASE_VIEW="$work/release.json" python3 - <<'PY'
scripts/verify-pearl-runtime-release.sh:541:if payload.get("isPrerelease") is not True:
scripts/verify-pearl-runtime-release.sh:543:        "[verify-pearl-runtime-release] ERROR: runtime-only Pearl releases must be GitHub prereleases",
scripts/verify-pearl-runtime-release.sh:550:validate_release_dir "$work/assets"
scripts/test-pearl-runtime-release.sh:5:guard="$repo_root/scripts/verify-pearl-runtime-release.sh"
scripts/test-pearl-runtime-release.sh:6:runtime_workflow="$repo_root/.github/workflows/pearl-runtime-release.yml"
scripts/test-pearl-runtime-release.sh:7:work="$(mktemp -d "${TMPDIR:-/tmp}/pearl-runtime-release-test.XXXXXX")"
scripts/test-pearl-runtime-release.sh:20:  fail "verify-pearl-runtime-release.sh uses process substitution; operator Mac bash 3.2 rejects a heredoc inside <()"
scripts/test-pearl-runtime-release.sh:27:if workflow.count("scripts/verify-github-release-posture.sh") < 3:
scripts/test-pearl-runtime-release.sh:30:if "Verify protected GitHub release posture before runtime signing" not in before_sign:
scripts/test-pearl-runtime-release.sh:32:create = workflow.split("- name: Create verified draft GitHub release", 1)[1].split(
scripts/test-pearl-runtime-release.sh:35:if "RELEASE_POSTURE_TOKEN" not in create or "verify-github-release-posture.sh" not in create:
scripts/test-pearl-runtime-release.sh:38:if "RELEASE_POSTURE_TOKEN" not in publish or "verify-github-release-posture.sh" not in publish:
scripts/test-pearl-runtime-release.sh:41:    raise SystemExit("runtime workflow must never make a runtime-only release latest")
scripts/test-pearl-runtime-release.sh:43:    raise SystemExit("runtime workflow must force GitHub prerelease publication")
scripts/test-pearl-runtime-release.sh:44:if 'EXPECTED_REVISION="${{ steps.release_source.outputs.commit }}"' not in workflow:
scripts/test-pearl-runtime-release.sh:47:if "id: release_toolchain" not in before_build:
scripts/test-pearl-runtime-release.sh:49:if 'toolchain_json="$RUNNER_TEMP/release-toolchain.json"' not in before_build:
scripts/test-pearl-runtime-release.sh:50:    raise SystemExit("runtime workflow must keep release-toolchain.json outside the git worktree before Go builds")
scripts/test-pearl-runtime-release.sh:51:if "scripts/verify-release-toolchain.sh release-toolchain.json" in before_build:
scripts/test-pearl-runtime-release.sh:52:    raise SystemExit("runtime workflow must not write release-toolchain.json into the git worktree before Go builds")
scripts/test-pearl-runtime-release.sh:67:    raise SystemExit("runtime workflow must copy release assets into the workspace only after binary verification")
scripts/test-pearl-runtime-release.sh:69:    "- name: Prepare runtime release notes", 1
scripts/test-pearl-runtime-release.sh:71:toolchain_copy = 'install -m 0644 "${{ steps.release_toolchain.outputs.json }}" release-toolchain.json'
scripts/test-pearl-runtime-release.sh:73:    raise SystemExit("runtime workflow must copy release-toolchain.json into release assets only after binary verification")
scripts/test-pearl-runtime-release.sh:74:if sign.find(toolchain_copy) > sign.find("scripts/build-release-provenance.py"):
scripts/test-pearl-runtime-release.sh:75:    raise SystemExit("runtime workflow must copy release-toolchain.json before building provenance")
scripts/test-pearl-runtime-release.sh:79:positive_latest_position = publish.find("stable latest endpoint before publication did not return a positive release id")
scripts/test-pearl-runtime-release.sh:82:if "-F prerelease=false" in publish:
scripts/test-pearl-runtime-release.sh:83:    raise SystemExit("runtime workflow must never promote runtime-only releases to GitHub stable releases")
scripts/test-pearl-runtime-release.sh:85:    "capture-release-publication.py --draft --runtime-only",
scripts/test-pearl-runtime-release.sh:87:    "final-draft-api.json release-provenance.json final-draft-manifest.json",
scripts/test-pearl-runtime-release.sh:92:    "-F prerelease=true",
scripts/test-pearl-runtime-release.sh:93:    "published-release-api.json",
scripts/test-pearl-runtime-release.sh:94:    "immutable-release-by-id.json release-provenance.json publication-manifest-by-id.json",
scripts/test-pearl-runtime-release.sh:95:    "immutable-release-by-tag.json release-provenance.json publication-manifest-by-tag.json",
scripts/test-pearl-runtime-release.sh:104:    "stable latest endpoint before publication did not return a positive release id",
scripts/test-pearl-runtime-release.sh:105:    "stable latest endpoint after publication did not return a positive release id",
scripts/test-pearl-runtime-release.sh:106:    "runtime-only release unexpectedly resolves through the stable latest endpoint",
scripts/test-pearl-runtime-release.sh:107:    "runtime-only release changed the stable latest endpoint",
scripts/test-pearl-runtime-release.sh:118:        raise SystemExit(f"runtime workflow must stage {asset} as a release asset")
scripts/test-pearl-runtime-release.sh:121:        raise SystemExit(f"runtime workflow must bind {asset} in signed pearl-release.json operator_artifacts")
scripts/test-pearl-runtime-release.sh:122:    assets_block = sign.split("release_assets=(", 1)[1].split(")", 1)[0]
scripts/test-pearl-runtime-release.sh:124:        raise SystemExit(f"runtime workflow must publish {asset} in the signed release asset list")
scripts/test-pearl-runtime-release.sh:125:latest_window = publish[publish.find("stable-latest-before.json"):publish.find("python3 scripts/capture-release-publication.py --runtime-only")]
scripts/test-pearl-runtime-release.sh:132:git -C "$work/source" config user.name pearl-runtime-release-test
scripts/test-pearl-runtime-release.sh:133:git -C "$work/source" config user.email pearl-runtime-release-test@example.invalid
scripts/test-pearl-runtime-release.sh:146:make_release_dir() {
scripts/test-pearl-runtime-release.sh:162:  printf '%s\n' signed-metadata > "$directory/pearl-release.json.sig"
scripts/test-pearl-runtime-release.sh:164:  printf '%s\n' catalog-release > "$directory/release.json"
scripts/test-pearl-runtime-release.sh:194:# release (SPEC-023 §3.7.8 Stage A): the same lane on the wire, two more
scripts/test-pearl-runtime-release.sh:202:    (directory / "release.json").write_text(json.dumps({"feeds": feeds}) + "\n", encoding="utf-8")
scripts/test-pearl-runtime-release.sh:205:        "release_id": "test-release",
scripts/test-pearl-runtime-release.sh:208:            "release.json": digest("release.json"),
scripts/test-pearl-runtime-release.sh:227:    "release_lane": lane,
scripts/test-pearl-runtime-release.sh:230:    "release_version": version,
scripts/test-pearl-runtime-release.sh:259:(directory / "pearl-release.json").write_text(
scripts/test-pearl-runtime-release.sh:278:if [[ "${1:-}" != "release" ]]; then
scripts/test-pearl-runtime-release.sh:295:metadata = json.loads((directory / "pearl-release.json").read_text(encoding="utf-8"))
scripts/test-pearl-runtime-release.sh:296:prerelease = metadata.get("release_lane") == "pearl_runtime"
scripts/test-pearl-runtime-release.sh:298:    prerelease = False
scripts/test-pearl-runtime-release.sh:302:    "isPrerelease": prerelease,
scripts/test-pearl-runtime-release.sh:329:          echo "unsupported fake gh release download argument: $1" >&2
scripts/test-pearl-runtime-release.sh:340:    echo "unsupported fake gh release subcommand: ${1:-}" >&2
scripts/test-pearl-runtime-release.sh:347:make_release_dir "$work/release-ok" v1.8.66 "$second"
scripts/test-pearl-runtime-release.sh:349:  --remote "$work/remote.git" --release-dir "$work/release-ok" |
scripts/test-pearl-runtime-release.sh:352:make_release_dir "$work/release-runtime-only" v1.8.66 "$second" pearl_runtime
scripts/test-pearl-runtime-release.sh:353:rm "$work/release-runtime-only"/release.json \
scripts/test-pearl-runtime-release.sh:354:  "$work/release-runtime-only"/trusted-keys.json \
scripts/test-pearl-runtime-release.sh:355:  "$work/release-runtime-only"/tier2-catalog.json \
scripts/test-pearl-runtime-release.sh:356:  "$work/release-runtime-only"/autotune-candidates.json \
scripts/test-pearl-runtime-release.sh:357:  "$work/release-runtime-only"/autotune-candidates.json.sig \
scripts/test-pearl-runtime-release.sh:358:  "$work/release-runtime-only"/demand-rank.json \
scripts/test-pearl-runtime-release.sh:359:  "$work/release-runtime-only"/demand-rank.json.sig
scripts/test-pearl-runtime-release.sh:361:  --remote "$work/remote.git" --release-dir "$work/release-runtime-only" |
scripts/test-pearl-runtime-release.sh:364:make_release_dir "$work/release-catalog-bound-missing-feed" v1.8.66 "$second"
scripts/test-pearl-runtime-release.sh:365:rm "$work/release-catalog-bound-missing-feed/demand-rank.json"
scripts/test-pearl-runtime-release.sh:367:  --remote "$work/remote.git" --release-dir "$work/release-catalog-bound-missing-feed" \
scripts/test-pearl-runtime-release.sh:369:  fail "accepted a catalog-bound Pearl runtime release missing a feed asset"
scripts/test-pearl-runtime-release.sh:371:grep -q 'missing catalog/feed asset(s) for catalog-bound Pearl runtime release: demand-rank.json' \
scripts/test-pearl-runtime-release.sh:374:make_release_dir "$work/release-catalog-bound-tampered-feed" v1.8.66 "$second"
scripts/test-pearl-runtime-release.sh:375:printf '\n' >> "$work/release-catalog-bound-tampered-feed/autotune-candidates.json"
scripts/test-pearl-runtime-release.sh:377:  --remote "$work/remote.git" --release-dir "$work/release-catalog-bound-tampered-feed" \
scripts/test-pearl-runtime-release.sh:379:  fail "accepted a catalog-bound Pearl runtime release with tampered feed bytes"
scripts/test-pearl-runtime-release.sh:381:grep -q 'autotune-candidates.json sha256 does not match pearl-release.json catalog metadata' \
scripts/test-pearl-runtime-release.sh:384:# SPEC-023 §3.7.8 Stage A (BYOM v0.2 slice 2b-ii): an artifact-bound release
scripts/test-pearl-runtime-release.sh:387:make_release_dir "$work/release-artifact-bound" v1.8.66 "$second" pearl_runtime_catalog_artifacts
scripts/test-pearl-runtime-release.sh:389:  --remote "$work/remote.git" --release-dir "$work/release-artifact-bound" |
scripts/test-pearl-runtime-release.sh:392:make_release_dir "$work/release-artifact-bound-missing-sig" v1.8.66 "$second" pearl_runtime_catalog_artifacts
scripts/test-pearl-runtime-release.sh:393:rm "$work/release-artifact-bound-missing-sig/autotune-artifacts.json.sig"
scripts/test-pearl-runtime-release.sh:395:  --remote "$work/remote.git" --release-dir "$work/release-artifact-bound-missing-sig" \
scripts/test-pearl-runtime-release.sh:397:  fail "accepted an artifact-bound Pearl runtime release missing the artifact sidecar"
scripts/test-pearl-runtime-release.sh:399:grep -q 'missing catalog/feed asset(s) for catalog-bound Pearl runtime release: autotune-artifacts.json.sig' \
scripts/test-pearl-runtime-release.sh:402:make_release_dir "$work/release-artifact-stray" v1.8.66 "$second"
scripts/test-pearl-runtime-release.sh:403:printf '%s\n' stray > "$work/release-artifact-stray/autotune-artifacts.json"
scripts/test-pearl-runtime-release.sh:405:  --remote "$work/remote.git" --release-dir "$work/release-artifact-stray" \
scripts/test-pearl-runtime-release.sh:407:  fail "accepted an artifact-feed asset the release does not bind"
scripts/test-pearl-runtime-release.sh:409:grep -q 'release carries artifact-feed asset(s) release.json does not bind: autotune-artifacts.json' \
scripts/test-pearl-runtime-release.sh:412:# release.json is the binding authority; pearl-release.json must AGREE with it
scripts/test-pearl-runtime-release.sh:414:make_release_dir "$work/release-artifact-pearl-unbound" v1.8.66 "$second" pearl_runtime_catalog_artifacts
scripts/test-pearl-runtime-release.sh:415:python3 - "$work/release-artifact-pearl-unbound" <<'PY'
scripts/test-pearl-runtime-release.sh:418:metadata_path = directory / "pearl-release.json"
scripts/test-pearl-runtime-release.sh:423:# checksums.txt covers pearl-release.json; re-derive it so only the binding rule fails
scripts/test-pearl-runtime-release.sh:429:  --remote "$work/remote.git" --release-dir "$work/release-artifact-pearl-unbound" \
scripts/test-pearl-runtime-release.sh:431:  fail "accepted Pearl metadata that omits the artifact feed release.json binds"
scripts/test-pearl-runtime-release.sh:433:grep -q 'pearl-release.json catalog file set disagrees with release.json feeds on the artifact feed' \
scripts/test-pearl-runtime-release.sh:436:make_release_dir "$work/release-artifact-pearl-overbound" v1.8.66 "$second" pearl_runtime_catalog_artifacts
scripts/test-pearl-runtime-release.sh:437:printf '%s\n' catalog-release > "$work/release-artifact-pearl-overbound/release.json"
scripts/test-pearl-runtime-release.sh:438:python3 - "$work/release-artifact-pearl-overbound" <<'PY'
scripts/test-pearl-runtime-release.sh:445:  --remote "$work/remote.git" --release-dir "$work/release-artifact-pearl-overbound" \
scripts/test-pearl-runtime-release.sh:447:  fail "accepted Pearl metadata that binds an artifact feed release.json does not"
scripts/test-pearl-runtime-release.sh:449:grep -q 'pearl-release.json catalog file set disagrees with release.json feeds on the artifact feed' \
scripts/test-pearl-runtime-release.sh:452:make_release_dir "$work/release-artifact-tampered" v1.8.66 "$second" pearl_runtime_catalog_artifacts
scripts/test-pearl-runtime-release.sh:453:printf '\n' >> "$work/release-artifact-tampered/autotune-artifacts.json"
scripts/test-pearl-runtime-release.sh:454:python3 - "$work/release-artifact-tampered" <<'PY'
scripts/test-pearl-runtime-release.sh:457:metadata_path = directory / "pearl-release.json"
scripts/test-pearl-runtime-release.sh:465:  --remote "$work/remote.git" --release-dir "$work/release-artifact-tampered" \
scripts/test-pearl-runtime-release.sh:467:  fail "accepted artifact feed bytes that differ from the release.json binding"
scripts/test-pearl-runtime-release.sh:469:grep -q 'autotune-artifacts.json does not match its release.json binding' "$work/artifact-tampered.out"
scripts/test-pearl-runtime-release.sh:471:# GitHub mode: the pair is downloaded (and required) exactly when release.json binds it.
scripts/test-pearl-runtime-release.sh:472:make_release_dir "$work/release-github-artifact-bound" v1.8.66 "$second" pearl_runtime_catalog_artifacts
scripts/test-pearl-runtime-release.sh:473:FAKE_GH_RELEASE_DIR="$work/release-github-artifact-bound" PATH="$fake_gh_dir:$PATH" \
scripts/test-pearl-runtime-release.sh:478:make_release_dir "$work/release-github-artifact-bound-missing" v1.8.66 "$second" pearl_runtime_catalog_artifacts
scripts/test-pearl-runtime-release.sh:479:rm "$work/release-github-artifact-bound-missing/autotune-artifacts.json.sig"
scripts/test-pearl-runtime-release.sh:480:if FAKE_GH_RELEASE_DIR="$work/release-github-artifact-bound-missing" PATH="$fake_gh_dir:$PATH" \
scripts/test-pearl-runtime-release.sh:483:  fail "accepted a GitHub artifact-bound Pearl runtime release missing the artifact sidecar"
scripts/test-pearl-runtime-release.sh:485:grep -q 'missing catalog/feed asset(s) for catalog-bound Pearl runtime release: autotune-artifacts.json.sig' \
scripts/test-pearl-runtime-release.sh:488:make_release_dir "$work/release-github-artifact-stray" v1.8.66 "$second"
scripts/test-pearl-runtime-release.sh:489:printf '%s\n' stray > "$work/release-github-artifact-stray/autotune-artifacts.json"
scripts/test-pearl-runtime-release.sh:490:if FAKE_GH_RELEASE_DIR="$work/release-github-artifact-stray" PATH="$fake_gh_dir:$PATH" \
scripts/test-pearl-runtime-release.sh:493:  fail "accepted a GitHub release publishing an artifact-feed asset release.json does not bind"
scripts/test-pearl-runtime-release.sh:495:grep -q 'release publishes artifact-feed asset(s) release.json does not bind: autotune-artifacts.json' \
scripts/test-pearl-runtime-release.sh:498:make_release_dir "$work/release-github-runtime-only" v1.8.66 "$second" pearl_runtime
scripts/test-pearl-runtime-release.sh:499:rm "$work/release-github-runtime-only"/release.json \
scripts/test-pearl-runtime-release.sh:500:  "$work/release-github-runtime-only"/trusted-keys.json \
scripts/test-pearl-runtime-release.sh:501:  "$work/release-github-runtime-only"/tier2-catalog.json \
scripts/test-pearl-runtime-release.sh:502:  "$work/release-github-runtime-only"/autotune-candidates.json \
scripts/test-pearl-runtime-release.sh:503:  "$work/release-github-runtime-only"/autotune-candidates.json.sig \
scripts/test-pearl-runtime-release.sh:504:  "$work/release-github-runtime-only"/demand-rank.json \
scripts/test-pearl-runtime-release.sh:505:  "$work/release-github-runtime-only"/demand-rank.json.sig
scripts/test-pearl-runtime-release.sh:506:FAKE_GH_RELEASE_DIR="$work/release-github-runtime-only" PATH="$fake_gh_dir:$PATH" \
scripts/test-pearl-runtime-release.sh:511:if FAKE_GH_RELEASE_DIR="$work/release-github-runtime-only" FAKE_GH_PRERELEASE=false PATH="$fake_gh_dir:$PATH" \
scripts/test-pearl-runtime-release.sh:514:  fail "accepted a GitHub runtime-only Pearl release that was not a prerelease"
scripts/test-pearl-runtime-release.sh:516:grep -q 'runtime-only Pearl releases must be GitHub prereleases' \
scripts/test-pearl-runtime-release.sh:519:make_release_dir "$work/release-github-catalog-bound-missing-feed" v1.8.66 "$second"
scripts/test-pearl-runtime-release.sh:520:rm "$work/release-github-catalog-bound-missing-feed/demand-rank.json"
scripts/test-pearl-runtime-release.sh:521:if FAKE_GH_RELEASE_DIR="$work/release-github-catalog-bound-missing-feed" PATH="$fake_gh_dir:$PATH" \
scripts/test-pearl-runtime-release.sh:524:  fail "accepted a GitHub catalog-bound Pearl runtime release missing a feed asset"
scripts/test-pearl-runtime-release.sh:526:grep -q 'missing catalog/feed asset(s) for catalog-bound Pearl runtime release: demand-rank.json' \
scripts/test-pearl-runtime-release.sh:530:# stats sidecar bytes only from a verified release that signs all of them.
scripts/test-pearl-runtime-release.sh:540:make_release_dir "$work/release-sidecars" v1.8.66 "$second" pearl_runtime_catalog sidecars
scripts/test-pearl-runtime-release.sh:543:  --remote "$work/remote.git" --release-dir "$work/release-sidecars" \
scripts/test-pearl-runtime-release.sh:547:  cmp -s "$work/release-sidecars/$asset" "$work/deploy-sidecars/$asset" ||
scripts/test-pearl-runtime-release.sh:548:    fail "deploy artifact dir does not hold the verified release bytes for $asset"
scripts/test-pearl-runtime-release.sh:555:  --remote "$work/remote.git" --release-dir "$work/release-ok" \
scripts/test-pearl-runtime-release.sh:557:  fail "full deploy accepted a release that does not sign the stats sidecars"
scripts/test-pearl-runtime-release.sh:560:[ -z "$(ls -A "$work/deploy-no-sidecars")" ] || fail "rejected release still staged deploy artifacts"
scripts/test-pearl-runtime-release.sh:562:make_release_dir "$work/release-sidecars-partial" v1.8.66 "$second" pearl_runtime_catalog sidecars
scripts/test-pearl-runtime-release.sh:563:python3 - "$work/release-sidecars-partial" <<'PY'
scripts/test-pearl-runtime-release.sh:565:path = pathlib.Path(sys.argv[1]) / "pearl-release.json"
scripts/test-pearl-runtime-release.sh:570:resign_checksums "$work/release-sidecars-partial"
scripts/test-pearl-runtime-release.sh:572:  --remote "$work/remote.git" --release-dir "$work/release-sidecars-partial" \
scripts/test-pearl-runtime-release.sh:574:  fail "accepted a release binding an incomplete stats sidecar set"
scripts/test-pearl-runtime-release.sh:578:make_release_dir "$work/release-sidecars-stray" v1.8.66 "$second"
scripts/test-pearl-runtime-release.sh:579:printf '%s\n' stray > "$work/release-sidecars-stray/stats-billing-mirror-linux-amd64"
scripts/test-pearl-runtime-release.sh:580:resign_checksums "$work/release-sidecars-stray"
scripts/test-pearl-runtime-release.sh:582:  --remote "$work/remote.git" --release-dir "$work/release-sidecars-stray" \
scripts/test-pearl-runtime-release.sh:586:grep -q 'release carries stats sidecar asset(s) pearl-release.json does not bind: stats-billing-mirror-linux-amd64' \
scripts/test-pearl-runtime-release.sh:589:make_release_dir "$work/release-sidecars-tampered" v1.8.66 "$second" pearl_runtime_catalog sidecars
scripts/test-pearl-runtime-release.sh:590:printf '%s\n' tampered > "$work/release-sidecars-tampered/stats-hardware-verifier-linux-amd64"
scripts/test-pearl-runtime-release.sh:592:  --remote "$work/remote.git" --release-dir "$work/release-sidecars-tampered" \
scripts/test-pearl-runtime-release.sh:596:grep -q 'stats-hardware-verifier-linux-amd64 sha256 does not match pearl-release.json' "$work/sidecars-tampered.out"
scripts/test-pearl-runtime-release.sh:598:make_release_dir "$work/release-github-sidecars" v1.8.66 "$second" pearl_runtime sidecars
scripts/test-pearl-runtime-release.sh:599:rm "$work/release-github-sidecars"/release.json \
scripts/test-pearl-runtime-release.sh:600:  "$work/release-github-sidecars"/trusted-keys.json \
scripts/test-pearl-runtime-release.sh:601:  "$work/release-github-sidecars"/tier2-catalog.json \
scripts/test-pearl-runtime-release.sh:602:  "$work/release-github-sidecars"/autotune-candidates.json \
scripts/test-pearl-runtime-release.sh:603:  "$work/release-github-sidecars"/autotune-candidates.json.sig \
scripts/test-pearl-runtime-release.sh:604:  "$work/release-github-sidecars"/demand-rank.json \
scripts/test-pearl-runtime-release.sh:605:  "$work/release-github-sidecars"/demand-rank.json.sig \
scripts/test-pearl-runtime-release.sh:606:  "$work/release-github-sidecars"/rate-card.json \
scripts/test-pearl-runtime-release.sh:607:  "$work/release-github-sidecars"/rate-card.json.sig
scripts/test-pearl-runtime-release.sh:608:resign_checksums "$work/release-github-sidecars"
scripts/test-pearl-runtime-release.sh:610:FAKE_GH_RELEASE_DIR="$work/release-github-sidecars" PATH="$fake_gh_dir:$PATH" \
scripts/test-pearl-runtime-release.sh:615:  cmp -s "$work/release-github-sidecars/$asset" "$work/deploy-github-sidecars/$asset" ||
scripts/test-pearl-runtime-release.sh:616:    fail "GitHub deploy artifact dir does not hold the verified release bytes for $asset"
scripts/test-pearl-runtime-release.sh:620:  --remote "$work/remote.git" --release-dir "$work/release-ok" \
scripts/test-pearl-runtime-release.sh:622:  fail "accepted a release whose required tag is absent"
scripts/test-pearl-runtime-release.sh:624:grep -q 'release tag v1.8.65 is absent' "$work/absent-tag.out"
scripts/test-pearl-runtime-release.sh:628:make_release_dir "$work/release-wrong-tag-target" v1.8.67 "$second"
scripts/test-pearl-runtime-release.sh:630:  --remote "$work/remote.git" --release-dir "$work/release-wrong-tag-target" \
scripts/test-pearl-runtime-release.sh:632:  fail "accepted a release whose tag targets a different commit"
scripts/test-pearl-runtime-release.sh:636:make_release_dir "$work/release-missing-asset" v1.8.66 "$second"
scripts/test-pearl-runtime-release.sh:637:rm "$work/release-missing-asset/gateway-linux-amd64"
scripts/test-pearl-runtime-release.sh:639:  --remote "$work/remote.git" --release-dir "$work/release-missing-asset" \
scripts/test-pearl-runtime-release.sh:641:  fail "accepted a release missing a Pearl runtime asset"
scripts/test-pearl-runtime-release.sh:643:grep -q 'missing Pearl runtime release asset(s): gateway-linux-amd64' "$work/missing-asset.out"
scripts/test-pearl-runtime-release.sh:645:make_release_dir "$work/release-wrong-metadata-commit" v1.8.66 "$first"

exec
/bin/bash -lc "sed -n '68,102p' Makefile; sed -n '176,204p' Makefile; rg -n -C 6 'STATS_BILLING_MIRROR_BINARY|PINNED_RUNTIME_ARTIFACT_DIR|runtime tag|RELEASE_TAG|PEARL' phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '1,280p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
# the M3-2 internalBearerAuthorized dual-credential gate.
test-integration:
	cd test/integration && go test -race -count=1 -timeout 5m ./...

# Deploy-tooling tests (bash + python3, no Go build). Guards the fail-closed
# pre-deploy gate in phase4-coordinator/dist/check-deploy-config.sh — notably
# that an env:NAME-indirected secret is deferred to runtime rather than
# false-failing the gate (the 2026-06-17 regression that forced SKIP_C2_CHECK=1).
test-dist:
	bash scripts/test-openai-wire-compat.sh
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_upstream_watch
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_byom_contract_lock
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_byom_journey_evidence
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_discovery_journey_driver
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_admission_journey_runner
	node --test phase3-binary/app/Tests/MalibuTests/payout-signer-chain.test.mjs
	bash scripts/test-production-exceptions.sh
	bash scripts/test-coordinator-advertised-version-test.sh
	bash scripts/test-cli-se-entitlements.sh
	bash scripts/test-malibu-independent-release.sh
	bash scripts/test-release-tag-target.sh
	bash scripts/test-pearl-runtime-release.sh
	bash scripts/test-live-coordinator-release-gate.sh
	bash scripts/test-release-security-posture.sh
	bash scripts/test-h1-undercredit-probe.sh
	bash scripts/test-malibu-bootstrap-bridge.sh
	bash scripts/test-recover-malibu-publication.sh
	bash scripts/test-acceptance-candidate-security.sh
	bash scripts/test-swift-package-lock.sh
	bash scripts/test-signed-payout-journey-workflow.sh
	bash scripts/test-signed-provider-prebeta-journey-workflow.sh
	bash scripts/test-signed-byom-discovery-journey-workflow.sh
	bash scripts/test-signed-network-model-admission-journey-workflow.sh
	bash scripts/test-signed-buyer-paid-path-journey-workflow.sh
	bash scripts/test-signed-buyer-crash-recovery-journey-workflow.sh
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_catalog_artifact_feed
	bash scripts/test-autotune-gate-matrix.sh
	bash -n phase4-coordinator/dist/deploy-pearl-vps.sh
	bash -n phase4-coordinator/dist/deploy-malibu-emission-pearl.sh
	bash -n phase4-coordinator/dist/deploy-opoi-v0-pearl.sh
	bash -n phase5-gateway/dist/deploy-pearl-vps.sh
	bash phase4-coordinator/dist/test/check_deploy_config_test.sh
	bash phase4-coordinator/dist/test/c2_timer_config_migration_test.sh
	bash phase4-coordinator/dist/test/autotune_rate_card_config_migration_test.sh
	bash phase4-coordinator/dist/test/coord_deploy_c2_precheck.test.sh
	bash phase4-coordinator/dist/test/check_nginx_receipt_buffers_test.sh
	bash phase4-coordinator/dist/test/check_nginx_api_perf_tuning_test.sh
	bash phase4-coordinator/dist/test/check_nginx_catalog_routes_test.sh
	bash phase4-coordinator/dist/test/check_nginx_stats_test.sh
	bash phase4-coordinator/dist/test/check_nginx_mdm_enroll_routes_test.sh
	bash phase4-coordinator/dist/test/check_nginx_referral_routes_test.sh
	bash phase4-coordinator/dist/test/check_stats_inventory_deploy_test.sh
	bash phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
	bash phase4-coordinator/dist/test/coord_deploy_config_mode_test.sh
	bash phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh
	bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh
	bash phase4-coordinator/dist/test/deploy_catalog_verifier_closure.test.sh
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_autotune_window
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_catalog_compare_live
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_catalog_content_gate
	bash phase4-coordinator/dist/test/deploy_catalog_compare_live.test.sh
	bash phase4-coordinator/dist/test/deploy_catalog_window_coverage.test.sh
	bash phase4-coordinator/dist/test/coord_deploy_restart_readiness.test.sh
	bash phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh
136-      /*) ;;             # absolute — use as-is
137-      *) src="$dir/$src" ;;
138-    esac
139-  done
140-  cd "$(dirname "$src")" && pwd -P
141-}
142:_PEARL_TLS_SCRIPT_DIR="$(_pearl_resolve_symlink "${BASH_SOURCE[0]}")"
143-# shellcheck source=lib/pearl_tls.sh
144:. "$_PEARL_TLS_SCRIPT_DIR/lib/pearl_tls.sh"
145-
146-SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
147-VPS_HOST="${VPS_HOST:-159.223.165.194}"
148-VPS_USER="${VPS_USER:-root}"
149-DOMAIN="${DOMAIN:-coordinator.malibu.tech}"
150-STATS_DOMAIN="${STATS_DOMAIN:-stats.malibu.tech}"
--
197-_validate_dns_name "$DOMAIN"        DOMAIN
198-_validate_dns_name "${STATS_DOMAIN:-stats.malibu.tech}" STATS_DOMAIN
199-
200-# #1688: the canary bearer loader and operator-key proof live in the shared
201-# lib so the catalog-content lane reads the token exactly as deploy does.
202-# shellcheck source=../../scripts/lib/catalog-canary-token.sh
203:. "$_PEARL_TLS_SCRIPT_DIR/../../scripts/lib/catalog-canary-token.sh"
204-# #1688: the catalog override/coverage append primitive also lives in a
205-# shared lib so deploy and the catalog-content lane write the same audit log
206-# through the same byte-for-byte contract.
207-# shellcheck source=../../scripts/lib/catalog-window-override.sh
208:. "$_PEARL_TLS_SCRIPT_DIR/../../scripts/lib/catalog-window-override.sh"
209-
210-_run_with_deadline_alarm() {
211-  local timeout_s="$1"
212-  shift
213-  python3 -c '
214-import os
--
476-# R3 SEC MED — reuse the already-resolved physical dir from the
477-# symlink walker rather than recomputing from `$0` (which is the
478-# symlink path) + logical `pwd`. All later artifact reads,
479-# check-deploy-config, config uploads, and vhost templates hang
480-# off DIST_DIR, so any parent-symlink retargeting attack that
481-# survives helper sourcing would still land here.
482:DIST_DIR="$_PEARL_TLS_SCRIPT_DIR"
483-MODULE_DIR="$(cd "$DIST_DIR/.." && pwd -P)"
484-REPO_ROOT="$(git -C "$MODULE_DIR" rev-parse --show-toplevel)"
485-
486-COORDINATOR_RELEASE_VERSION=""
487-COORDINATOR_RELEASE_COMMIT=""
488-if [ "$DRY_RUN_LOCAL" != "1" ]; then
--
522-  esac
523-}
524-
525-PINNED_DEPLOY_INPUT_DIR=""
526-PINNED_REPOSITORY_DIR=""
527-PINNED_DIST_DIR="$DIST_DIR"
528:PINNED_RUNTIME_ARTIFACT_DIR="$DIST_DIR"
529-PINNED_STATIC_FEEDS_DIR="$DIST_DIR/../../phase3-binary/dist/static"
530-PINNED_AUTOTUNE_DIR="$DIST_DIR/../../phase3-binary/catalog/autotune"
531-PINNED_SCRIPTS_DIR="$DIST_DIR/../../scripts"
532-if [ "$DRY_RUN_LOCAL" != "1" ]; then
533-  PINNED_DEPLOY_INPUT_DIR="$(umask 077 && mktemp -d -t macprovider-deploy-inputs.XXXXXXXX)" || {
534-    echo "aborting deploy: mktemp failed for pinned deploy inputs" >&2
--
554-    | tar -xf - -C "$PINNED_REPOSITORY_DIR"
555-  PINNED_DIST_DIR="$PINNED_DEPLOY_INPUT_DIR/phase4-coordinator/dist"
556-  # Issue #1721: the exact-copy gates below compare Pearl's live coordinator,
557-  # coordinator-cli, and stats sidecars with these bytes and never install
558-  # different ones. Take them from the verified signed Pearl runtime release
559-  # that macprovider-pearl-update installs, never from a local dist/ build.
560:  PINNED_RUNTIME_ARTIFACT_DIR="$PINNED_DEPLOY_INPUT_DIR/pearl-runtime-release"
561:  install -d -m 0700 "$PINNED_RUNTIME_ARTIFACT_DIR"
562-  GH_HOST=github.com bash "$REPO_ROOT/scripts/verify-pearl-runtime-release.sh" \
563-    --tag "$COORDINATOR_RELEASE_VERSION" \
564-    --expected-commit "$COORDINATOR_RELEASE_COMMIT" \
565-    --repository "Augustas11/macprovider" \
566-    --remote "origin" \
567:    --deploy-artifacts-dir "$PINNED_RUNTIME_ARTIFACT_DIR"
568-  PINNED_STATIC_FEEDS_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/dist/static"
569-  PINNED_AUTOTUNE_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/catalog/autotune"
570-  PINNED_SCRIPTS_DIR="$PINNED_DEPLOY_INPUT_DIR/scripts"
571-else
572-  PINNED_REPOSITORY_DIR="$REPO_ROOT"
573-  CATALOG_VERIFIER_BUNDLE="$(_parse_catalog_verifier_bundle < "$PINNED_SCRIPTS_DIR/catalog-verifier-bundle.txt")" || exit 2
--
620-fi
621-if [ "${STATS_DOMAIN:-stats.malibu.tech}" != "stats.malibu.tech" ]; then
622-  echo "aborting deploy: STATS_DOMAIN override (${STATS_DOMAIN}) does not match the baked-in vhost template" >&2
623-  exit 1
624-fi
625-
626:BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/coordinator-linux-amd64"
627:CLI_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/coordinator-cli-linux-amd64"
628:STATS_INVENTORY_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-inventory-sync-linux-amd64"
629:STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"
630:STATS_HARDWARE_VERIFIER_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-hardware-verifier-linux-amd64"
631-CONFIG="$PINNED_DIST_DIR/coordinator.yaml"
632-DEPLOY_CONFIG="$CONFIG"
633-SERVICE="$PINNED_DIST_DIR/macprovider-coordinator.service"
634-DEPLOY_RECOVER="$PINNED_DIST_DIR/coordinator-deploy-recover.sh"
635-DEPLOY_GUARD="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-guard.conf"
636-DEPLOY_RECOVERY_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-recovery.service"
--
859-# FR-C9.4 strict-reject path still requires `coordinator-cli
860-# revoke-token` for the used-token-persist-failure case; routine
861-# prune-tokens / list-tokens also belong on Pearl). Production deploys
862-# stage it and the stats sidecars from the verified signed release above;
863-# DRY_RUN_LOCAL reads dist/. Fail closed — do NOT silently deploy with a
864-# stale CLI.
865:for f in "$BINARY" "$CLI_BINARY" "$STATS_INVENTORY_BINARY" "$STATS_BILLING_MIRROR_BINARY" "$STATS_HARDWARE_VERIFIER_BINARY" \
866-         "$CONFIG" "$SERVICE" "$DEPLOY_RECOVER" "$DEPLOY_GUARD" "$DEPLOY_RECOVERY_SERVICE" "$DEPLOY_WATCHDOG_SERVICE" "$STATS_INVENTORY_SERVICE" "$STATS_INVENTORY_TIMER" \
867-         "$STATS_BILLING_MIRROR_SERVICE" "$STATS_BILLING_MIRROR_TIMER" \
868-         "$STATS_HARDWARE_VERIFIER_SERVICE" "$STATS_HARDWARE_VERIFIER_TIMER" "$NGINX_SITE" \
869-         "$NGINX_STATS_SHARED" "$NGINX_STATS_SECHEADERS" "$NGINX_STATS_SITE" \
870-         "$STATIC_DEMAND_JSON" "$STATIC_DEMAND_SIG" \
871-         "$STATIC_AUTOTUNE_JSON" "$STATIC_AUTOTUNE_SIG" \
--
3235-  local source_path="$1" remote_name="$2"
3236-  shasum -a 256 "$source_path" | awk -v name="$remote_name" '{ print $1 "  " name }' >> "$DEPLOY_INPUT_MANIFEST_TMP"
3237-}
3238-_append_deploy_input_digest "$BINARY" "coordinator-linux-amd64"
3239-_append_deploy_input_digest "$CLI_BINARY" "coordinator-cli-linux-amd64"
3240-_append_deploy_input_digest "$STATS_INVENTORY_BINARY" "stats-inventory-sync-linux-amd64"
3241:_append_deploy_input_digest "$STATS_BILLING_MIRROR_BINARY" "stats-billing-mirror-linux-amd64"
3242-_append_deploy_input_digest "$STATS_HARDWARE_VERIFIER_BINARY" "stats-hardware-verifier-linux-amd64"
3243-if [ "$CONFIG_MODE" = "apply-tracked" ]; then
3244-  _append_deploy_input_digest "$CONFIG" "coordinator.yaml"
3245-elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
3246-  _append_deploy_input_digest "$RATE_CARD_MIGRATED_CONFIG_TMP" "coordinator.rate-card-migration.yaml"
3247-elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
--
3293-  _append_deploy_input_digest "$AUTOTUNE_TIER2_JSON" "tier2-catalog.json"
3294-fi
3295-
3296-$SCP "$BINARY"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
3297-$SCP "$CLI_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-cli-linux-amd64"
3298-$SCP "$STATS_INVENTORY_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync-linux-amd64"
3299:$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"
3300-$SCP "$STATS_HARDWARE_VERIFIER_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier-linux-amd64"
3301-if [ "$CONFIG_MODE" = "apply-tracked" ]; then
3302-  $SCP "$CONFIG" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.yaml"
3303-elif [ "${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}" = "1" ]; then
3304-  $SCP "$RATE_CARD_MIGRATED_CONFIG_TMP" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.rate-card-migration.yaml"
3305-elif [ "$C2_TIMER_CONFIG_MIGRATION" = "1" ]; then
--
3906-# R1 SEC MED-3 / ARCH MED-2 — opt-in strict mode for non-primary
3907-# domains. Default WARN-only matches the issue intent (stats. NXDOMAIN
3908-# must not break primary deploy); STATS_REQUIRED=1 promotes any non-
3909-# primary failure to a fail-closed exit so operators with strict
3910-# uptime SLOs can enforce it.
3911-pearl_tls_check_issuance_failures "$DOMAIN"
3912:if [ "$PEARL_TLS_PRIMARY_FAILED" -eq 1 ]; then
3913-  # State-aware abort (lib/pearl_tls.sh — issue #291).
3914-  pearl_tls_primary_abort_msg "$DOMAIN" >&2
3915-  exit 9
3916-fi
3917:if [ "$PEARL_TLS_NONPRIMARY_FAILED" -eq 1 ] && [ "${STATS_REQUIRED:-0}" = "1" ]; then
3918-  echo "" >&2
3919-  echo "  ABORT-EXIT: STATS_REQUIRED=1 set and a non-primary domain failed cert" >&2
3920-  echo "             issuance ([${DOMAINS_ISSUED_FAIL[*]}]). Refusing to restart." >&2
3921-  exit 9
3922-fi
3923-

codex
The release path is correctly wired to the signed runtime tag: production deploy resolves the tag/commit, verifies the signed runtime release, and takes the billing-mirror binary from that artifact directory before the full deploy. I’m running the existing mirror wiring, rollback/access, release-tag, and billing-mirror package tests now; these tests may pass while still missing the unit sandbox overlap.
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 exited 127 in 0ms:
bash: phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh: No such file or directory

exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 exited 127 in 0ms:
bash: phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh: No such file or directory

exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 exited 127 in 0ms:
bash: phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh: No such file or directory

exec
/bin/bash -lc 'go test ./internal/stats/billingmirror' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 succeeded in 218ms:
ok  	github.com/augstar/macprovider-coordinator/internal/stats/billingmirror	(cached)

exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh' in /Users/augstar/macprovider-mirror-dbpath
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-mirror-dbpath
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/coordinator_release_tag_guard.test.sh' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 226ms:
ok: stats billing mirror deploy wiring

 succeeded in 2983ms:
/var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/tmp.TVe9E0r57e: line 1: 91942 Alarm clock: 14         python3 -c '
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

 succeeded in 5897ms:
PASS: coordinator release tag guards reject git-describe deploy footguns

exec
/bin/bash -lc 'bash -n phase4-coordinator/dist/deploy-pearl-vps.sh' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
exec
/bin/bash -lc 'bash scripts/test-pearl-runtime-release.sh' in /Users/augstar/macprovider-mirror-dbpath
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/coordinator_deploy_recovery.test.sh' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 9896ms:
PASS: Pearl runtime release preflight fails closed on missing assets and source drift

 succeeded in 10054ms:
PASS: coordinator deploy recovery is durable and state-exact

exec
/bin/bash -lc "find /usr/share/man /usr/local/share/man -iname 'systemd.exec*' -o -iname 'systemd.service*' 2>/dev/null | head -20; rg -n 'InaccessiblePaths=.*ReadOnlyPaths|InaccessiblePaths=|ReadOnlyPaths=' /usr/share/doc /usr/share/man 2>/dev/null | head -80" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 195ms:
exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/stats-billing-mirror.service | sed -n '18,32p'; nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '3136,3146p;3629,3641p;4868,4878p'; nl -ba phase4-coordinator/internal/stats/billingmirror/mirror.go | sed -n '20,31p'; nl -ba phase4-coordinator/dist/coordinator.yaml | sed -n '238,247p'; nl -ba phase4-coordinator/cmd/coordinator/main.go | sed -n '226,246p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
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
    28	InaccessiblePaths=-/var/lib/macprovider/coordinator.db
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
    20	
    21	const (
    22		DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
    23		DefaultBatchSize   = 5000
    24		DefaultOverlapRows = 1000
    25		DefaultRunTimeout  = 25 * time.Second
    26	
    27		StateSource = "sqlite-ledger-request-credits"
    28	)
    29	
    30	type Options struct {
    31		SQLitePath   string
   238	  asn_prefixes:
   239	    "0.0.0.0/0": "AS0"
   240	    "::/0": "AS0"
   241	
   242	storage:
   243	  db_path: "/var/lib/macprovider/coordinator.db"
   244	  snapshot_interval_s: 300
   245	  request_log_retention_days: 90
   246	  # Defaults are true for backward compatibility. Set false to defer DELETE
   247	  # retention work to the scheduled pruner tick during buyer traffic relief.
   226		metricsRegistry := prom.NewRegistry()
   227		metricsHandle := statsmetrics.New(metricsRegistry)
   228		registry := pool.NewRegistry(cfg.Providers)
   229		startedAt := time.Now().UTC()
   230		tokenStore, err := auth.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
   231		if err != nil {
   232			fmt.Fprintf(os.Stderr, "storage: %v\n", err)
   233			os.Exit(1)
   234		}
   235		defer tokenStore.Close()
   236		reqLogStore, err := requestlog.OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)
   237		if err != nil {
   238			fmt.Fprintf(os.Stderr, "requestlog: %v\n", err)
   239			os.Exit(1)
   240		}
   241		defer reqLogStore.Close()
   242		moneyCheckpointDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(cfg.Storage.DBPath))
   243		if err != nil {
   244			fmt.Fprintf(os.Stderr, "money sqlite checkpoint: %v\n", err)
   245			os.Exit(1)
   246		}

exec
/bin/bash -lc 'go test -count=1 ./internal/stats/billingmirror ./internal/requestlog ./cmd/stats-billing-mirror' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'go test -count=1 ./internal/stats/billingmirror ./internal/requestlog ./cmd/stats-billing-mirror' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 succeeded in 40646ms:
ok  	github.com/augstar/macprovider-coordinator/internal/stats/billingmirror	0.429s
ok  	github.com/augstar/macprovider-coordinator/internal/requestlog	39.275s
?   	github.com/augstar/macprovider-coordinator/cmd/stats-billing-mirror	[no test files]

 succeeded in 49051ms:
ok  	github.com/augstar/macprovider-coordinator/internal/stats/billingmirror	0.475s
ok  	github.com/augstar/macprovider-coordinator/internal/requestlog	46.710s
?   	github.com/augstar/macprovider-coordinator/cmd/stats-billing-mirror	[no test files]

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '486,570p;626,638p;3288,3302p'; nl -ba scripts/verify-pearl-runtime-release.sh | sed -n '90,125p;200,238p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
   486	COORDINATOR_RELEASE_VERSION=""
   487	COORDINATOR_RELEASE_COMMIT=""
   488	if [ "$DRY_RUN_LOCAL" != "1" ]; then
   489	  COORDINATOR_RELEASE_IDENTITY="$(_coordinator_release_tag_version "$MODULE_DIR")" || exit 2
   490	  COORDINATOR_RELEASE_VERSION="${COORDINATOR_RELEASE_IDENTITY%% *}"
   491	  COORDINATOR_RELEASE_COMMIT="${COORDINATOR_RELEASE_IDENTITY#* }"
   492	  echo "  release tag OK: $COORDINATOR_RELEASE_VERSION @ $COORDINATOR_RELEASE_COMMIT"
   493	fi
   494	
   495	# #1688: scripts/catalog-verifier-bundle.txt is the one list of files every
   496	# shipped copy of catalog-release.py needs beside it. Entries become archive
   497	# paths and remote file names, so reject anything but plain scripts/<name>.
   498	_parse_catalog_verifier_bundle() {
   499	  _bundle_seen=" "
   500	  while IFS= read -r _bundle_line || [ -n "$_bundle_line" ]; do
   501	    case "$_bundle_line" in '#'*) continue ;; esac
   502	    if ! printf '%s\n' "$_bundle_line" | grep -Eq '^scripts/[A-Za-z0-9._-]+$' ||
   503	      [ "$_bundle_line" = "scripts/." ] || [ "$_bundle_line" = "scripts/.." ]; then
   504	      echo "aborting deploy: invalid catalog verifier bundle entry: '$_bundle_line'" >&2
   505	      return 1
   506	    fi
   507	    case "$_bundle_seen" in
   508	      *" $_bundle_line "*)
   509	        echo "aborting deploy: duplicate catalog verifier bundle entry: $_bundle_line" >&2
   510	        return 1
   511	        ;;
   512	    esac
   513	    _bundle_seen="$_bundle_seen$_bundle_line "
   514	    printf '%s\n' "$_bundle_line"
   515	  done
   516	  case "$_bundle_seen" in
   517	    *" scripts/catalog-release.py "*) ;;
   518	    *)
   519	      echo "aborting deploy: catalog verifier bundle must list scripts/catalog-release.py" >&2
   520	      return 1
   521	      ;;
   522	  esac
   523	}
   524	
   525	PINNED_DEPLOY_INPUT_DIR=""
   526	PINNED_REPOSITORY_DIR=""
   527	PINNED_DIST_DIR="$DIST_DIR"
   528	PINNED_RUNTIME_ARTIFACT_DIR="$DIST_DIR"
   529	PINNED_STATIC_FEEDS_DIR="$DIST_DIR/../../phase3-binary/dist/static"
   530	PINNED_AUTOTUNE_DIR="$DIST_DIR/../../phase3-binary/catalog/autotune"
   531	PINNED_SCRIPTS_DIR="$DIST_DIR/../../scripts"
   532	if [ "$DRY_RUN_LOCAL" != "1" ]; then
   533	  PINNED_DEPLOY_INPUT_DIR="$(umask 077 && mktemp -d -t macprovider-deploy-inputs.XXXXXXXX)" || {
   534	    echo "aborting deploy: mktemp failed for pinned deploy inputs" >&2
   535	    exit 2
   536	  }
   537	  trap 'rm -rf "${PINNED_DEPLOY_INPUT_DIR:-}"' EXIT HUP INT TERM
   538	  CATALOG_VERIFIER_BUNDLE_TEXT="$(git -C "$REPO_ROOT" show "$COORDINATOR_RELEASE_COMMIT:scripts/catalog-verifier-bundle.txt")" || {
   539	    echo "aborting deploy: $COORDINATOR_RELEASE_COMMIT lacks scripts/catalog-verifier-bundle.txt" >&2
   540	    exit 2
   541	  }
   542	  CATALOG_VERIFIER_BUNDLE="$(printf '%s\n' "$CATALOG_VERIFIER_BUNDLE_TEXT" | _parse_catalog_verifier_bundle)" || exit 2
   543	  # shellcheck disable=SC2086 # validated scripts/<name> entries, no IFS/glob chars
   544	  GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO_ROOT" archive --format=tar "$COORDINATOR_RELEASE_COMMIT" -- \
   545	    phase4-coordinator/dist \
   546	    phase3-binary/dist/static \
   547	    phase3-binary/catalog/autotune \
   548	    scripts/catalog-verifier-bundle.txt \
   549	    $CATALOG_VERIFIER_BUNDLE \
   550	    | tar -xf - -C "$PINNED_DEPLOY_INPUT_DIR"
   551	  PINNED_REPOSITORY_DIR="$PINNED_DEPLOY_INPUT_DIR/repository"
   552	  install -d -m 0700 "$PINNED_REPOSITORY_DIR"
   553	  GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO_ROOT" archive --format=tar "$COORDINATOR_RELEASE_COMMIT" \
   554	    | tar -xf - -C "$PINNED_REPOSITORY_DIR"
   555	  PINNED_DIST_DIR="$PINNED_DEPLOY_INPUT_DIR/phase4-coordinator/dist"
   556	  # Issue #1721: the exact-copy gates below compare Pearl's live coordinator,
   557	  # coordinator-cli, and stats sidecars with these bytes and never install
   558	  # different ones. Take them from the verified signed Pearl runtime release
   559	  # that macprovider-pearl-update installs, never from a local dist/ build.
   560	  PINNED_RUNTIME_ARTIFACT_DIR="$PINNED_DEPLOY_INPUT_DIR/pearl-runtime-release"
   561	  install -d -m 0700 "$PINNED_RUNTIME_ARTIFACT_DIR"
   562	  GH_HOST=github.com bash "$REPO_ROOT/scripts/verify-pearl-runtime-release.sh" \
   563	    --tag "$COORDINATOR_RELEASE_VERSION" \
   564	    --expected-commit "$COORDINATOR_RELEASE_COMMIT" \
   565	    --repository "Augustas11/macprovider" \
   566	    --remote "origin" \
   567	    --deploy-artifacts-dir "$PINNED_RUNTIME_ARTIFACT_DIR"
   568	  PINNED_STATIC_FEEDS_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/dist/static"
   569	  PINNED_AUTOTUNE_DIR="$PINNED_DEPLOY_INPUT_DIR/phase3-binary/catalog/autotune"
   570	  PINNED_SCRIPTS_DIR="$PINNED_DEPLOY_INPUT_DIR/scripts"
   626	BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/coordinator-linux-amd64"
   627	CLI_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/coordinator-cli-linux-amd64"
   628	STATS_INVENTORY_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-inventory-sync-linux-amd64"
   629	STATS_BILLING_MIRROR_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-billing-mirror-linux-amd64"
   630	STATS_HARDWARE_VERIFIER_BINARY="$PINNED_RUNTIME_ARTIFACT_DIR/stats-hardware-verifier-linux-amd64"
   631	CONFIG="$PINNED_DIST_DIR/coordinator.yaml"
   632	DEPLOY_CONFIG="$CONFIG"
   633	SERVICE="$PINNED_DIST_DIR/macprovider-coordinator.service"
   634	DEPLOY_RECOVER="$PINNED_DIST_DIR/coordinator-deploy-recover.sh"
   635	DEPLOY_GUARD="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-guard.conf"
   636	DEPLOY_RECOVERY_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-recovery.service"
   637	DEPLOY_WATCHDOG_SERVICE="$PINNED_DIST_DIR/systemd/macprovider-coordinator-deploy-watchdog.service"
   638	STATS_INVENTORY_SERVICE="$PINNED_DIST_DIR/stats-inventory-sync.service"
  3288	fi
  3289	if [ -n "$CATALOG_REMOTE_PATH" ]; then
  3290	  _append_deploy_input_digest "$TMP_CATALOG_PINNED" "tier2-catalog.json"
  3291	  _append_deploy_input_digest "$TMP_CATALOG_PUBKEY" "tier2-catalog.pub"
  3292	else
  3293	  _append_deploy_input_digest "$AUTOTUNE_TIER2_JSON" "tier2-catalog.json"
  3294	fi
  3295	
  3296	$SCP "$BINARY"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
  3297	$SCP "$CLI_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-cli-linux-amd64"
  3298	$SCP "$STATS_INVENTORY_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync-linux-amd64"
  3299	$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"
  3300	$SCP "$STATS_HARDWARE_VERIFIER_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-hardware-verifier-linux-amd64"
  3301	if [ "$CONFIG_MODE" = "apply-tracked" ]; then
  3302	  $SCP "$CONFIG" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.yaml"
    90	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    91	bash "$root/scripts/verify-release-tag-target.sh" \
    92	  "$tag" "$expected_commit" "$remote" --require-existing >/dev/null
    93	
    94	required_assets=(
    95	  pearl-release.json
    96	  pearl-release.json.sig
    97	  checksums.txt
    98	  checksums.txt.sig
    99	  coordinator-linux-amd64
   100	  coordinator-cli-linux-amd64
   101	  gateway-linux-amd64
   102	)
   103	# Issue #1721: the full deploy compares these byte-for-byte with Pearl and
   104	# never installs them itself; the signed updater installs them from the release.
   105	stats_sidecar_assets=(
   106	  stats-inventory-sync-linux-amd64
   107	  stats-billing-mirror-linux-amd64
   108	  stats-hardware-verifier-linux-amd64
   109	)
   110	deploy_exact_copy_assets=(
   111	  coordinator-linux-amd64
   112	  coordinator-cli-linux-amd64
   113	  "${stats_sidecar_assets[@]}"
   114	)
   115	
   116	validate_release_dir() {
   117	  local directory="$1"
   118	  [[ -d "$directory" ]] || die "release directory does not exist: $directory"
   119	  local missing=()
   120	  local asset
   121	  for asset in "${required_assets[@]}"; do
   122	    [[ -f "$directory/$asset" ]] || missing+=("$asset")
   123	  done
   124	  if [[ "${#missing[@]}" -gt 0 ]]; then
   125	    die "missing Pearl runtime release asset(s): ${missing[*]}"
   200	
   201	operator_artifacts = metadata.get("operator_artifacts")
   202	coordinator_cli = operator_artifacts.get("coordinator_cli") if isinstance(operator_artifacts, dict) else None
   203	if not isinstance(coordinator_cli, dict) or coordinator_cli.get("asset") != "coordinator-cli-linux-amd64":
   204	    fail("pearl-release.json coordinator CLI artifact does not bind coordinator-cli-linux-amd64")
   205	coordinator_cli_digest = coordinator_cli.get("sha256")
   206	if not isinstance(coordinator_cli_digest, str) or not sha_re.fullmatch(coordinator_cli_digest):
   207	    fail("pearl-release.json coordinator CLI sha256 is invalid")
   208	actual = hashlib.sha256((directory / "coordinator-cli-linux-amd64").read_bytes()).hexdigest()
   209	if actual != coordinator_cli_digest:
   210	    fail("coordinator-cli-linux-amd64 sha256 does not match pearl-release.json")
   211	
   212	stats_sidecars = {
   213	    "stats_inventory_sync": "stats-inventory-sync-linux-amd64",
   214	    "stats_billing_mirror": "stats-billing-mirror-linux-amd64",
   215	    "stats_hardware_verifier": "stats-hardware-verifier-linux-amd64",
   216	}
   217	unknown_operator_artifacts = sorted(set(operator_artifacts) - {"coordinator_cli", *stats_sidecars})
   218	if unknown_operator_artifacts:
   219	    fail("pearl-release.json binds unknown operator artifacts: " + " ".join(unknown_operator_artifacts))
   220	bound_sidecars = [key for key in stats_sidecars if key in operator_artifacts]
   221	if bound_sidecars and len(bound_sidecars) != len(stats_sidecars):
   222	    fail("pearl-release.json binds an incomplete stats sidecar set")
   223	if not bound_sidecars:
   224	    stray_sidecars = sorted(asset for asset in stats_sidecars.values() if (directory / asset).is_file())
   225	    if stray_sidecars:
   226	        fail("release carries stats sidecar asset(s) pearl-release.json does not bind: " + " ".join(stray_sidecars))
   227	    if os.environ.get("PEARL_RELEASE_REQUIRE_STATS_SIDECARS") == "1":
   228	        fail(
   229	            "pearl-release.json does not bind the stats sidecars the full deploy requires; "
   230	            "cut a Pearl runtime release that signs stats-inventory-sync, stats-billing-mirror, "
   231	            "and stats-hardware-verifier"
   232	        )
   233	for key, asset in stats_sidecars.items() if bound_sidecars else ():
   234	    row = operator_artifacts[key]
   235	    if not isinstance(row, dict) or row.get("asset") != asset:
   236	        fail(f"pearl-release.json {key} artifact does not bind {asset}")
   237	    sidecar_digest = row.get("sha256")
   238	    if not isinstance(sidecar_digest, str) or not sha_re.fullmatch(sidecar_digest):

codex
Existing tests pass for the changed wiring, ACL/rollback checks, release-tag guard, runtime-release gate, shell syntax, and the billing-mirror/requestlog Go packages. They do not exercise systemd’s namespace, and the unit’s contradictory path directives are therefore not caught. I’m doing the final diff/status check and then I’ll report the single concrete finding.
exec
/bin/bash -lc "git diff --quiet origin/main...HEAD; printf 'requested-range-exit=%s\\n' \""'$?"; git status --short; git diff HEAD''^ HEAD --check' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 192ms:
?? audits/2026-09-25-stats-mirror-db-path/

codex
Found one HIGH architecture issue.

- **HIGH — `phase4-coordinator/dist/stats-billing-mirror.service:23-28`**  
  The coordinator DB is declared both `ReadOnlyPaths` and `InaccessiblePaths`. `InaccessiblePaths=-...` makes `/var/lib/macprovider/coordinator.db` unavailable to the mirror despite the corrected `ExecStart`. The deploy’s readability guard passes, but systemd startup fails; `deploy-pearl-vps.sh:4873-4877` then disables the timer and aborts the full deploy.  
  **Fix:** remove `/var/lib/macprovider/coordinator.db` from `InaccessiblePaths`; add a regression assertion preventing this overlap.

Coordinator config, requestlog wiring, production path references, signed runtime-tag flow, and Pearl release tests otherwise align. Existing relevant tests passed, including billingmirror/requestlog Go tests and deployment/release wiring tests.

VERDICT: FAIL (0/1/0)
tokens used
101 293

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
