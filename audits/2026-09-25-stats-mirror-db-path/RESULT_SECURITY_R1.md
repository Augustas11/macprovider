# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-09-25T08:35:01.616Z

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
## Lane: SECURITY / MONEY PATH

Check:
- `coordinator.db` holds money-path state. Granting the `macprovider-stats` user a read ACL on it: is that least privilege acceptable, is the database read-only in the sandbox, and does the rollback restore the ACLs exactly?
- Is there any write path to `coordinator.db` from the mirror?
- `InaccessiblePaths` still hides secrets.

## Raw output

```text
Audit basis: `origin/main...HEAD` is empty because both refs point to `c6c326927`; I audited the target commit against its parent.

Finding:

- **HIGH** — `phase4-coordinator/dist/stats-billing-mirror.service:28` still declares `InaccessiblePaths=-/var/lib/macprovider/coordinator.db`, while lines 7, 14, and 23 configure that same file as the mirror’s source. Systemd will hide the coordinator DB inside the service sandbox, so the mirror cannot open the ledger. The deploy guard at `deploy-pearl-vps.sh:4873` checks readability outside that sandbox, allowing deployment to proceed until the initial service run fails and triggers rollback.  
  **Fix:** Remove only the coordinator DB entry from `InaccessiblePaths`; retain the `/etc/macprovider` and coordinator configuration protections. Add a wiring assertion that the source DB is not inaccessible.

Other checks:

- ACL scope is limited to `macprovider-stats:r--` on the DB and existing WAL/SHM files, with directory traverse-only access. SQLite file-level access necessarily covers the database file, but no write ACL is granted.
- Rollback snapshots and restores the coordinator DB, WAL, SHM, and directory ACLs via `getfacl`/`setfacl --restore`.
- The mirror uses SQLite `mode=ro` plus `query_only(true)` and has no coordinator-DB write path.
- `InaccessiblePaths` continues to hide `/etc/macprovider` and coordinator configuration secrets.
- Existing tests passed:
  - `check_stats_billing_mirror_deploy_test.sh`
  - `check_deploy_static_feed_access.test.sh`
  - `go test ./internal/stats/billingmirror`
  - `go test ./internal/sqliteutil`

VERDICT: FAIL (C=0, H=1, M=0)


OpenAI Codex v0.156.1
--------
workdir: /Users/augstar/macprovider-mirror-dbpath
model: gpt-5.6-luna
provider: openai
approval: never
sandbox: danger-full-access
reasoning effort: high
reasoning summaries: none
session id: 01a0d7af-fd9d-7773-9b23-27c979d048c7
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
I’ll audit the complete `origin/main...HEAD` diff for the security/money-path criteria, then run only the existing relevant tests. I’ll report only evidence-backed C/H/M findings with file:line, scenario, and fix, and finish with the required verdict.
exec
/bin/bash -lc "git status -sb && git diff --stat origin/main...HEAD && git diff --name-only origin/main...HEAD && git diff -- origin/main...HEAD -- phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/internal/billingmirror phase4-coordinator | sed -n '1,260p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 18ms:
exec
/bin/bash -lc 'git diff --no-ext-diff --unified=80 origin/main...HEAD -- phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/internal/stats/billingmirror/mirror.go' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
diff --git a/phase4-coordinator/cmd/stats-billing-mirror/main.go b/phase4-coordinator/cmd/stats-billing-mirror/main.go
index 210cdaa4e..47f95fabf 100644
--- a/phase4-coordinator/cmd/stats-billing-mirror/main.go
+++ b/phase4-coordinator/cmd/stats-billing-mirror/main.go
@@ -1,29 +1,29 @@
 package main
 
 import (
 	"context"
 	"flag"
 	"fmt"
 	"os"
 
 	"github.com/augstar/macprovider-coordinator/internal/stats/billingmirror"
 )
 
 func main() {
 	var opts billingmirror.Options
-	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/request-log.sqlite")
+	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/coordinator.db")
 	flag.StringVar(&opts.PostgresDSN, "dsn", "", "Postgres DSN; defaults to STATS_BILLING_MIRROR_DSN")
 	flag.IntVar(&opts.BatchSize, "batch-size", billingmirror.DefaultBatchSize, "maximum request-credit rows to fetch per batch")
 	flag.Int64Var(&opts.OverlapRows, "overlap-rows", billingmirror.DefaultOverlapRows, "number of recent SQLite row IDs to re-read every run")
 	flag.IntVar(&opts.SweepRows, "sweep-rows", 0, "historical primary-key sweep rows to refresh per run; defaults to batch-size")
 	flag.IntVar(&opts.MaxBatches, "max-batches", 5, "maximum new-row batches to process per run")
 	flag.BoolVar(&opts.EnsureSchema, "ensure-schema", true, "create/upgrade the narrow Postgres mirror schema before syncing")
 	flag.BoolVar(&opts.DryRun, "dry-run", false, "read SQLite and print counts without writing Postgres")
 	flag.Parse()
 	opts.Stdout = os.Stdout
 
 	if _, err := billingmirror.Run(context.Background(), opts); err != nil {
 		fmt.Fprintf(os.Stderr, "stats-billing-mirror: %v\n", err)
 		os.Exit(1)
 	}
 }
diff --git a/phase4-coordinator/dist/deploy-pearl-vps.sh b/phase4-coordinator/dist/deploy-pearl-vps.sh
index 3f00b577b..8bc28cb76 100755
--- a/phase4-coordinator/dist/deploy-pearl-vps.sh
+++ b/phase4-coordinator/dist/deploy-pearl-vps.sh
@@ -3061,163 +3061,163 @@ $SSH "set -e
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
-    snapshot_acl /var/lib/macprovider/request-log.sqlite request-log-db.acl had-request-log-db-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-wal request-log-wal.acl had-request-log-wal-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-shm request-log-shm.acl had-request-log-shm-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
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
   if [ -f /opt/macprovider/autotune/.previous-target ]; then
     cp -p /opt/macprovider/autotune/.previous-target \"\$_rollback_stage/catalog-previous-target\"
     touch \"\$_rollback_stage/had-previous-target\"
   fi
   if [ ! -d /opt/macprovider/autotune/releases/$AUTOTUNE_RELEASE_DIR_NAME ]; then
     touch \"\$_rollback_stage/release-was-absent\"
   fi
   printf '%s' '$AUTOTUNE_RELEASE_DIR_NAME' > \"\$_rollback_stage/release-id\"
   if systemctl is-active --quiet macprovider-coordinator; then
     touch \"\$_rollback_stage/service-was-active\"
   fi
   touch \"\$_rollback_stage/complete\"
   mv \"\$_rollback_stage\" \"\$_rollback\"
   trap - EXIT HUP INT TERM"
 COORDINATOR_DEPLOY_ARMED=1
 
 # Freeze sidecar execution for the release window. Their binaries and units are
 # transaction-owned, so allowing an old timer to fire after replacement could
 # create non-rollbackable database effects before the catalog canary passes.
 # NOTE: stats-inventory-sync is deliberately NOT in this loop — it is quiesced
 # earlier (before the onboarding migration preflight) because migration 019
 # makes the old inventory binary incompatible with the migrated schema, so it
 # must be down before the migration is exercised, not merely before install.
 $SSH 'set -eu
   exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
   flock -s 8
   for unit in stats-billing-mirror.timer stats-billing-mirror.service stats-hardware-verifier.timer stats-hardware-verifier.service; do
     load_state=$(systemctl show -p LoadState --value "$unit")
     [ "$load_state" = not-found ] && continue
     systemctl stop "$unit"
     active_state=$(systemctl show -p ActiveState --value "$unit")
     case "$active_state" in
       inactive|failed) ;;
       *) echo "sidecar unit did not stop: $unit state=$active_state" >&2; exit 1 ;;
     esac
   done
 '
 
 # Issue #244 R5 SEC CRITICAL — stage uploaded artifacts into a fresh
 # per-deploy root-owned 0700 directory instead of predictable /tmp/X
 # names. Otherwise any local user (including a compromised macprovider
 # UID) can race the SCP/install window and substitute their own
 # systemd unit, binary, or nginx config — which root then installs.
 # `mktemp -d` returns a fresh dir with mode 0700 owned by the SSH
 # user (root). The wider /tmp permissions (1777) don't matter because
 # the fresh subdir denies traversal.
 DEPLOY_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-deploy.XXXXXXXX') || {
   echo "failed to create remote staging directory" >&2; exit 1;
 }
 case "$DEPLOY_TMP" in
   /tmp/macprovider-deploy.*) ;;
   *)
     echo "aborting deploy: mktemp produced unexpected path: '$DEPLOY_TMP'" >&2
@@ -3555,164 +3555,164 @@ $SSH "set -e
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
   if [ -e \$_autotune_release ]; then
     if ! diff -qr \$_autotune_stage \$_autotune_release >/dev/null; then
       echo 'catalog release envelope $AUTOTUNE_RELEASE_DIR_NAME already exists with different bytes' >&2
       exit 1
     fi
     rm -rf \$_autotune_stage
   else
     mv \$_autotune_stage \$_autotune_release
   fi
   python3 $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_autotune_release --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub
   # First rollout: the new on-disk coordinator config already points at
   # autotune/current. Establish that path as soon as the immutable release is
   # staged so an abort before the late restart gate cannot leave the next
   # service restart without feeds. Existing rollouts remain untouched here.
   if [ ! -e \$_autotune_root/current ] && [ ! -L \$_autotune_root/current ]; then
     ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME \$_autotune_root/current.bootstrap
     mv -Tf \$_autotune_root/current.bootstrap \$_autotune_root/current
   fi
   rmdir \$_autotune_lock
   trap - EXIT
 "
 
 # nginx + Let's Encrypt strategy (issue #244 R1+R2+R3+R4 — TLS-safety hardening):
 #
 # Domain classification (step 4b) produces FOUR states:
 #   HAVE    fullchain.pem + privkey.pem present, openssl -checkend
 #           86400 valid → no stub, no certbot, full vhost reinstalled
 #           idempotently in step 6b.
 #   RENEW   files present, cert valid RIGHT NOW (openssl -checkend 0
 #           valid) but <24h to expiry → certbot needed, but the
 #           existing full TLS vhost is left in place. A certbot
 #           failure leaves the soon-expiring cert serving until next
 #           deploy (instead of being replaced with an HTTP-only stub).
 #   EXPIRED files present but cert is already invalid (openssl
 #           -checkend 0 fails) → treat like MISSING. Existing vhost
 #           would serve a broken cert; install stub + run certbot
 #           instead.
 #   MISSING fullchain.pem or privkey.pem absent → install stub + run
 #           certbot. (Always-stub: dropped the R2 vhost-flag gate
 #           after R3 audit showed a stale enabled vhost could lack
 #           /.well-known/acme-challenge/ and block first issuance.)
 #
 #   step 5   -> install the port-80 ACME-stub ONLY for DOMAINS_NEED_STUB
 #               (= EXPIRED ∪ MISSING). HAVE + RENEW production vhosts
 #               are untouched. This is the load-bearing change vs. the
 #               original bug: a downstream certbot failure cannot leave
 #               another domain's working TLS vhost broken because we
 #               never clobbered it in the first place.
 #   step 6   -> per-domain certbot certonly --webroot, FAIL-SOFT. A
 #               failure on ANY single domain (e.g. NXDOMAIN) is logged
 #               and recorded but does not abort the deploy. State-aware
 #               messaging tells the operator the per-domain fallback.
 #   step 6b  -> install the full TLS vhost ONLY for DOMAINS_FULL_TLS
@@ -4793,135 +4793,135 @@ if [ "$STATS_ENABLED_LOCAL" = "true" ]; then
     exit 9
   else
     echo "  ok: $STATS_DOMAIN /v1/stats/leaderboard responded 200"
   fi
 else
   # Stats disabled in deployed config. If STATS_REQUIRED=1, the operator
   # explicitly asked for strict mode but disabled stats — that's
   # incoherent; refuse. Otherwise just log and skip.
   if [ "${STATS_REQUIRED:-0}" = "1" ]; then
     echo "  ABORT: STATS_REQUIRED=1 but stats.enabled is not true in $DEPLOY_CONFIG." >&2
     echo "         Enable stats in coordinator.yaml or drop STATS_REQUIRED=1." >&2
     exit 9
   fi
   echo "  stats.enabled is not true in $DEPLOY_CONFIG — skipping $STATS_DOMAIN smoke check"
 fi
 
 log "step 9/9: tail the coordinator journal for sanity"
 $SSH 'journalctl -u macprovider-coordinator --no-pager -n 20'
 
 $SSH 'set -e
   exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
   flock -s 8
   # Sidecars remain frozen until every coordinator/catalog/canary check has
   # passed. Activate them as the final transaction mutation, immediately
   # before the commit marker.
   _sidecar_prior=/opt/macprovider/.coordinator-deploy-sidecar-prior-state
   if [ ! -r "$_sidecar_prior" ]; then
     echo "aborting deploy: missing stats-inventory prior state at final activation" >&2
     exit 13
   fi
   assert_stats_inventory_quiescent() {
     _timer_enabled=$(systemctl is-enabled stats-inventory-sync.timer 2>/dev/null || true)
     _timer_active=$(systemctl is-active stats-inventory-sync.timer 2>/dev/null || true)
     _service_active=$(systemctl is-active stats-inventory-sync.service 2>/dev/null || true)
     if [ "$_timer_enabled" != disabled ] ||
        [ "$_timer_active" != inactive ]; then
       echo "aborting deploy: stats-inventory timer did not remain disabled/inactive after parity hold (enabled=$_timer_enabled active=$_timer_active)" >&2
       exit 13
     fi
     case "$_service_active" in
       inactive|failed) ;;
       *)
         echo "aborting deploy: stats-inventory service did not remain quiescent after parity hold (active=$_service_active)" >&2
         exit 13
         ;;
     esac
   }
   _parity_required=$(sed -n "s/^parity_required=//p" "$_sidecar_prior")
   case "$_parity_required" in
     present)
       systemctl disable --now stats-inventory-sync.timer
       systemctl stop stats-inventory-sync.service
       assert_stats_inventory_quiescent
       touch /opt/macprovider/.coordinator-deploy-sidecar-parity-required
       echo "stats inventory timer remains disabled: pre-existing schema/binary parity marker requires a matching sidecar promotion"
       ;;
     absent) ;;
     *)
       echo "aborting deploy: invalid stats-inventory parity state at final activation" >&2
       exit 13
       ;;
   esac
   if [ "$_parity_required" = absent ] && [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ] && [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
     systemctl enable --now stats-inventory-sync.timer
     if ! systemctl start stats-inventory-sync.service; then
       systemctl disable --now stats-inventory-sync.timer
       systemctl stop stats-inventory-sync.service
       assert_stats_inventory_quiescent
       echo "warning: stats-inventory-sync.service failed; leaving coordinator deploy running with its parity marker and timer disabled"
       journalctl -u stats-inventory-sync.service -n 30 --no-pager || true
     else
       rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
       systemctl is-active stats-inventory-sync.timer
     fi
   elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
     systemctl start stats-inventory-sync.timer
     [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
   elif [ "$_parity_required" = absent ]; then
     echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
   fi
-  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ] && su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats; then
+  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
     systemctl enable --now stats-billing-mirror.timer
     if ! systemctl start stats-billing-mirror.service; then
       systemctl disable --now stats-billing-mirror.timer
       echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
       journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
       exit 13
     fi
     systemctl is-active stats-billing-mirror.timer
   elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-timer-was-active ]; then
     systemctl start stats-billing-mirror.timer
     [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
   else
     echo "stats billing mirror timer not enabled: missing env/sqlite source or macprovider-stats read ACL"
   fi
   if [ -f /etc/macprovider-stats/stats-hardware-verifier.env ]; then
     systemctl enable --now stats-hardware-verifier.timer
     # FIX 7 (issue #582): when hardware-trust approval is enabled (both onboarding
     # trust DSNs configured), the verifier is the only thing that promotes an
     # approved waiting_trust job to verified. A failed INITIAL run must fail the
     # deploy (fatal) rather than be a warning, or operators could commit approvals
     # against a coordinator whose verifier never runs. When approval is NOT enabled
     # the initial run stays best-effort (warn), matching prior behavior.
     hardware_trust_approval_enabled=0
     if [ -r /etc/macprovider/coordinator.env ] \
        && grep -Eq "^[[:space:]]*ONBOARDING_HARDWARE_TRUST_REQUEST_DSN=" /etc/macprovider/coordinator.env \
        && grep -Eq "^[[:space:]]*ONBOARDING_HARDWARE_TRUST_APPROVE_DSN=" /etc/macprovider/coordinator.env; then
       hardware_trust_approval_enabled=1
     fi
     if ! systemctl start stats-hardware-verifier.service; then
       journalctl -u stats-hardware-verifier.service -n 30 --no-pager || true
       if [ "$hardware_trust_approval_enabled" = 1 ]; then
         echo "aborting deploy: stats-hardware-verifier.service failed its initial run and hardware-trust approval is enabled; operator approvals would commit trust roots that never promote to verified" >&2
         exit 13
       fi
       echo "warning: stats-hardware-verifier.service failed; leaving coordinator deploy running"
     fi
     systemctl is-active stats-hardware-verifier.timer
   elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-timer-was-active ]; then
     systemctl start stats-hardware-verifier.timer
     [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-hardware-service-was-active ] || systemctl start stats-hardware-verifier.service
   else
     echo "stats hardware verifier timer not enabled: missing /etc/macprovider-stats/stats-hardware-verifier.env"
   fi
   rm -f "$_sidecar_prior"
   touch /opt/macprovider/.coordinator-deploy-rollback/committed
   /opt/macprovider/coordinator-deploy-recover --recover-under-global
 '
 COORDINATOR_DEPLOY_ARMED=0
 log "DONE. coordinator is live at https://$DOMAIN"
 echo
 echo "Next steps:"
 echo "  - Stage 3: restart M4 phase3-binary with --coordinator wss://$DOMAIN/ws/provider"
 echo "  - Verify: providers should appear in /poolz (auth: bearer operator_key from coordinator.yaml)"
 echo "  - End-to-end: run harness against https://$DOMAIN"
diff --git a/phase4-coordinator/dist/stats-billing-mirror.service b/phase4-coordinator/dist/stats-billing-mirror.service
index 056cf4f47..0fbb75a51 100644
--- a/phase4-coordinator/dist/stats-billing-mirror.service
+++ b/phase4-coordinator/dist/stats-billing-mirror.service
@@ -1,28 +1,28 @@
 [Unit]
 Description=MacProvider stats billing mirror
 Documentation=https://github.com/augstar/macprovider-poc
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
 NoNewPrivileges=true
 PrivateDevices=true
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
@@ -71,161 +71,161 @@ window_apply='python3 -I $DEPLOY_TMP/scripts/autotune_window.py apply --root \"\
 plan_line=$(grep -nF "$window_plan" "$DEPLOY_SH" | cut -d: -f1)
 apply_line=$(grep -nF "$window_apply" "$DEPLOY_SH" | cut -d: -f1)
 swap_line=$(grep -nF 'mv -Tf \"\$_catalog_root/current.next\" \"\$_catalog_root/current\"' "$DEPLOY_SH" | cut -d: -f1)
 deploy_tmp_rm_line=$(grep -nF -x '  rm -rf $DEPLOY_TMP' "$DEPLOY_SH" | cut -d: -f1)
 [ -n "$plan_line" ] && [ -n "$apply_line" ] && [ -n "$swap_line" ] && [ -n "$deploy_tmp_rm_line" ] &&
   [ "$plan_line" -lt "$apply_line" ] && [ "$apply_line" -lt "$swap_line" ] && [ "$swap_line" -lt "$deploy_tmp_rm_line" ] ||
   fail "deploy must log then apply the autotune_window.py window before the current swap, keeping DEPLOY_TMP until after it"
 if grep -Eq "os\.rename\(tmp_name, '\.previous-target'|\.previous-target\.tmp\.|> *[^ ]*\.previous-target" "$DEPLOY_SH"; then
   fail "deploy keeps an inline .previous-target writer; use scripts/autotune_window.py"
 fi
 
 grep -q 'sudo -u macprovider test -r /opt/macprovider/autotune/current/autotune-candidates.json' "$DEPLOY_SH" ||
   fail "deploy smoke must verify macprovider can read autotune feeds"
 grep -q 'sudo -u macprovider test -r /opt/macprovider/autotune/current/rate-card.json' "$DEPLOY_SH" ||
   fail "deploy smoke must verify macprovider can read the signed rate-card feed"
 
 grep -q 'mv -Tf.*current.next.*current' "$DEPLOY_SH" ||
   fail "deploy must atomically activate the verified release"
 
 grep -q 'restore_regular had-coordinator coordinator' "$RECOVER_SH" ||
   fail "catalog rollback must restore the previous coordinator binary"
 
 grep -q 'restore_regular had-config coordinator.yaml' "$RECOVER_SH" ||
   fail "catalog rollback must restore the previous coordinator config"
 grep -q 'snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay' "$DEPLOY_SH" &&
   grep -q 'restore_regular had-overlay coordinator.pearl-overlays.yaml' "$RECOVER_SH" ||
   fail "catalog rollback must restore the previous coordinator overlay"
 grep -q 'overlay-config-backup-name' "$DEPLOY_SH" &&
   grep -q 'overlay-config-backup-name' "$RECOVER_SH" ||
   fail "catalog rollback must preserve overlay dated backup collisions"
 
 grep -q 'COORDINATOR_DEPLOY_ARMED=1' "$DEPLOY_SH" ||
   fail "deploy must arm rollback before replacing live coordinator files"
 
 grep -q '_rollback_stage=.*stage' "$DEPLOY_SH" ||
   fail "deploy must construct rollback state outside the published snapshot path"
 
 grep -q 'touch.*_rollback_stage/complete' "$DEPLOY_SH" ||
   fail "deploy must mark a fully constructed rollback snapshot"
 
 grep -q 'mv.*_rollback_stage.*_rollback' "$DEPLOY_SH" ||
   fail "deploy must atomically publish the complete rollback snapshot"
 
 grep -q 'restore_link_or_file had-service-unit macprovider-coordinator.service' "$RECOVER_SH" ||
   fail "coordinator rollback must restore the previous systemd unit"
 
 grep -q 'release-was-absent' "$RECOVER_SH" ||
   fail "coordinator rollback must remove a newly staged uncommitted release"
 
 grep -q 'restore_link_or_file had-wants-link' "$RECOVER_SH" ||
   fail "coordinator rollback must preserve exact service enablement or masking state"
 
 grep -q 'had-recovery-helper' "$DEPLOY_SH" && grep -q 'had-recovery-helper' "$RECOVER_SH" ||
   fail "coordinator rollback must preserve its durable recovery guard"
 
 grep -q 'had-previous-target' "$RECOVER_SH" ||
   fail "coordinator rollback must preserve the prior catalog bridge state"
 
 grep -q 'had-tier2-catalog' "$DEPLOY_SH" && grep -q 'restore_regular had-tier2-catalog' "$RECOVER_SH" ||
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
 
-grep -q 'snapshot_acl /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" &&
+grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
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
 
 grep -q 'flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" ||
   fail "deploy must hold a controller-lifetime remote lock"
 
 grep -q 'flock -n /run/lock/macprovider-pearl-updater.lock flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" &&
   grep -q 'unsafe global Pearl deployment lock' "$DEPLOY_SH" ||
   fail "direct deploy and signed updater must share one validated global mutation lock"
 
 grep -q 'cmp -s \$DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator' "$DEPLOY_SH" &&
   ! grep -q 'install -o root -g macprovider -m 0750 \$DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator' "$DEPLOY_SH" ||
   fail "direct catalog deploy must not replace one half of the signed coordinator/gateway pair"
 
 grep -qF 'tier2_require_hash_verified()' "$DEPLOY_SH" &&
   grep -qF 'tracked-config deploy cannot change tier2.require_hash_verified' "$DEPLOY_SH" &&
   grep -qF 'if [ "$CONFIG_MODE" = "apply-tracked" ]; then' "$DEPLOY_SH" ||
   fail "tracked-config deploy must hard-block every Tier-2 enforcement state transition"
 enforcement_mode_line=$(grep -nF 'if [ "$CONFIG_MODE" = "apply-tracked" ]; then' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 enforcement_guard_line=$(grep -nF 'tracked-config deploy cannot change tier2.require_hash_verified' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 apply_tracked_drift_line=$(grep -nF 'CONFIG_MODE=apply-tracked may install tracked coordinator.yaml only when it already matches live' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
 [ -n "$enforcement_mode_line" ] && [ -n "$enforcement_guard_line" ] && [ -n "$apply_tracked_drift_line" ] &&
   [ "$enforcement_mode_line" -lt "$enforcement_guard_line" ] &&
   [ "$enforcement_guard_line" -lt "$apply_tracked_drift_line" ] ||
   fail "Tier-2 enforcement transition guard must run before tracked-config drift handling"
 tier2_parser_tmp="$(mktemp)"
 awk '/^tier2_require_hash_verified\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" >"$tier2_parser_tmp"
 # shellcheck disable=SC1090
 . "$tier2_parser_tmp"
 rm -f "$tier2_parser_tmp"
 [ "$(printf 'tier2:\n  require_hash_verified: false\npool:\n' | tier2_require_hash_verified)" = "false" ] ||
   fail "Tier-2 transition parser must read the live false posture"
 [ "$(printf 'tier2:\n  require_hash_verified: true\npool:\n' | tier2_require_hash_verified)" = "true" ] ||
   fail "Tier-2 transition parser must read the candidate true posture"
 [ "$(printf 'tier2:\n    require_hash_verified: true\npool:\n' | tier2_require_hash_verified)" = "true" ] ||
   fail "Tier-2 transition parser must read valid four-space YAML"
 if printf 'tier2:\n  require_hash_verified: false\n  require_hash_verified: true\n' |
   tier2_require_hash_verified >/dev/null; then
   fail "Tier-2 transition parser must reject duplicate enforcement keys"
 fi
 if printf 'tier2:\n  nested:\n    require_hash_verified: true\n' |
   tier2_require_hash_verified >/dev/null; then
   fail "Tier-2 transition parser must reject a missing direct enforcement key"
 fi
 
 grep -qF 'tier2-enforcement-transaction.json' "$DEPLOY_SH" ||
   fail "direct deploy must refuse an active Tier-2 enforcement transaction"
 
 grep -q 'O_NOFOLLOW' "$DEPLOY_SH" && grep -q 'info.st_nlink != 1' "$DEPLOY_SH" &&
   grep -q 'unsafe coordinator deploy lock' "$DEPLOY_SH" ||
   fail "deploy lock setup must reject symlinks, hardlinks, and unsafe ownership/modes"
 
 grep -q 'sidecar unit did not stop:' "$DEPLOY_SH" ||
   fail "deploy must prove every loaded sidecar is inactive before replacement"
 
 grep -q 'recover interrupted coordinator deploy' "$DEPLOY_SH" ||
   fail "deploy must recover an interrupted transaction before reading live state"
 
 grep -q 'CRITICAL: coordinator deploy rollback failed' "$DEPLOY_SH" ||
   fail "deploy must report rollback failure distinctly"
 
 grep -q 'systemctl start --no-block macprovider-coordinator-deploy-watchdog.service' "$DEPLOY_SH" ||
   fail "deploy must arm a remote watchdog that survives controller loss"
 
 [ "$(grep -c 'coordinator-deploy-recover --recover-under-global' "$DEPLOY_SH")" -eq 2 ] ||
   fail "controller-held recovery must not recursively reacquire the global deploy lock"
 
 grep -q 'TimeoutStartSec=infinity' "$WATCHDOG_UNIT" &&
diff --git a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
index 9a2075ab5..8d8816853 100755
--- a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
+++ b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
@@ -1,153 +1,153 @@
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
 grep -qF 'aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run' "$DEPLOY_SH" ||
   fail "deploy script must fail closed when the configured billing mirror cannot run"
 
 grep -qxF 'User=macprovider-stats' "$SERVICE" ||
   fail "billing mirror must run as dedicated stats user"
 grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
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
 import re
 import sys
 
 expected = [
     "p_sqlite_lrc_id", "p_request_id", "p_attempt_n", "p_provider_id",
     "p_ts_utc", "p_created_at_utc", "p_updated_at_utc", "p_prompt_tokens",
     "p_completion_tokens", "p_estimated_completion_tokens", "p_usage_source",
     "p_provider_credits", "p_fault_flag", "p_quarantined",
     "p_settlement_policy_mode", "p_spec022_verified", "p_requested_privacy_mode",
     "p_effective_privacy_outcome", "p_positive_verification_excluded",
     "p_rewards_excluded",
 ]
 
 def signature(path):
     text = open(path, encoding="utf-8").read()
     matches = re.findall(
         r"CREATE OR REPLACE FUNCTION stats_billing_mirror_upsert_request_credit\(\s*(.*?)\s*\)\s*"
         r"RETURNS void\s*LANGUAGE plpgsql\s*SECURITY DEFINER\s*"
         r"SET search_path = pg_catalog, public, pg_temp",
         text,
         flags=re.S,
     )
     if not matches:
diff --git a/phase4-coordinator/internal/stats/billingmirror/mirror.go b/phase4-coordinator/internal/stats/billingmirror/mirror.go
index 5cc0c9506..1caffe167 100644
--- a/phase4-coordinator/internal/stats/billingmirror/mirror.go
+++ b/phase4-coordinator/internal/stats/billingmirror/mirror.go
@@ -1,102 +1,102 @@
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
-	DefaultSQLitePath  = "/var/lib/macprovider/request-log.sqlite"
+	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
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

exec
/bin/bash -lc 'git diff --no-ext-diff --unified=8 origin/main...HEAD -- phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
exec
/bin/bash -lc "git diff --no-ext-diff --unified=8 origin/main...HEAD | sed -n '/"'^diff --git a'"\\/phase4-coordinator\\/dist\\/deploy-pearl-vps.sh/,/"'^diff --git /p'"' | sed -n '1,360p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
exec
/bin/bash -lc 'git diff --no-ext-diff --unified=3 origin/main...HEAD | head -120' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
exec
/bin/bash -lc 'git rev-parse origin/main HEAD; git diff --stat origin/main HEAD; git diff --stat origin/main...HEAD; git log --oneline --decorate -5 --all; git show --stat --oneline HEAD' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 99ms:
c6c326927 (HEAD -> fix/stats-mirror-coordinator-db, tag: v1.8.197, origin/main, origin/fix/stats-mirror-coordinator-db, origin/HEAD, main) Point the stats billing mirror at the coordinator DB that holds the ledger
71d64ee68 (origin/bench/1690-loopback-vs-native, macstudio/bench/1690-loopback-vs-native) Expect the F3 cancelled-prefix result in the loopback cancel test (#1690)
94bf0e2b9 Make the runbook step 4a feed check fail closed (#1690 E2E-F12)
8f90c6226 Stream native text byte-identical to the receipt across split UTF-8 characters (#1690 E2E-F13)
2dc5f4759 #1690 e2e evidence: post-fix re-run on 97b22eb3 (F2/F4/F5/F9/F10 fixed on real engines; new F12, F13)
c6c326927 Point the stats billing mirror at the coordinator DB that holds the ledger
 phase4-coordinator/cmd/stats-billing-mirror/main.go      |  2 +-
 phase4-coordinator/dist/deploy-pearl-vps.sh              | 16 ++++++++--------
 phase4-coordinator/dist/stats-billing-mirror.service     | 10 +++++-----
 .../dist/test/check_deploy_static_feed_access.test.sh    |  2 +-
 .../dist/test/check_stats_billing_mirror_deploy_test.sh  | 12 ++++++------
 .../internal/stats/billingmirror/mirror.go               |  2 +-
 6 files changed, 22 insertions(+), 22 deletions(-)

codex
The requested range is currently empty: both `origin/main` and `HEAD` resolve to the same commit (`c6c326927`). The checkout does contain the target change as that commit, so I’m auditing its parent-to-HEAD patch as the available evidence and will call out the ref mismatch explicitly if it affects the conclusion.
exec
/bin/bash -lc 'git show --format=fuller --stat --oneline HEAD && git diff --no-ext-diff --unified=12 HEAD''^ HEAD -- phase4-coordinator/cmd/stats-billing-mirror/main.go phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh phase4-coordinator/internal/stats/billingmirror/mirror.go' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
c6c326927 Point the stats billing mirror at the coordinator DB that holds the ledger
 phase4-coordinator/cmd/stats-billing-mirror/main.go      |  2 +-
 phase4-coordinator/dist/deploy-pearl-vps.sh              | 16 ++++++++--------
 phase4-coordinator/dist/stats-billing-mirror.service     | 10 +++++-----
 .../dist/test/check_deploy_static_feed_access.test.sh    |  2 +-
 .../dist/test/check_stats_billing_mirror_deploy_test.sh  | 12 ++++++------
 .../internal/stats/billingmirror/mirror.go               |  2 +-
 6 files changed, 22 insertions(+), 22 deletions(-)
diff --git a/phase4-coordinator/cmd/stats-billing-mirror/main.go b/phase4-coordinator/cmd/stats-billing-mirror/main.go
index 210cdaa4e..47f95fabf 100644
--- a/phase4-coordinator/cmd/stats-billing-mirror/main.go
+++ b/phase4-coordinator/cmd/stats-billing-mirror/main.go
@@ -2,25 +2,25 @@ package main
 
 import (
 	"context"
 	"flag"
 	"fmt"
 	"os"
 
 	"github.com/augstar/macprovider-coordinator/internal/stats/billingmirror"
 )
 
 func main() {
 	var opts billingmirror.Options
-	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/request-log.sqlite")
+	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/coordinator.db")
 	flag.StringVar(&opts.PostgresDSN, "dsn", "", "Postgres DSN; defaults to STATS_BILLING_MIRROR_DSN")
 	flag.IntVar(&opts.BatchSize, "batch-size", billingmirror.DefaultBatchSize, "maximum request-credit rows to fetch per batch")
 	flag.Int64Var(&opts.OverlapRows, "overlap-rows", billingmirror.DefaultOverlapRows, "number of recent SQLite row IDs to re-read every run")
 	flag.IntVar(&opts.SweepRows, "sweep-rows", 0, "historical primary-key sweep rows to refresh per run; defaults to batch-size")
 	flag.IntVar(&opts.MaxBatches, "max-batches", 5, "maximum new-row batches to process per run")
 	flag.BoolVar(&opts.EnsureSchema, "ensure-schema", true, "create/upgrade the narrow Postgres mirror schema before syncing")
 	flag.BoolVar(&opts.DryRun, "dry-run", false, "read SQLite and print counts without writing Postgres")
 	flag.Parse()
 	opts.Stdout = os.Stdout
 
 	if _, err := billingmirror.Run(context.Background(), opts); err != nil {
 		fmt.Fprintf(os.Stderr, "stats-billing-mirror: %v\n", err)
diff --git a/phase4-coordinator/dist/deploy-pearl-vps.sh b/phase4-coordinator/dist/deploy-pearl-vps.sh
index 3f00b577b..8bc28cb76 100755
--- a/phase4-coordinator/dist/deploy-pearl-vps.sh
+++ b/phase4-coordinator/dist/deploy-pearl-vps.sh
@@ -3129,27 +3129,27 @@ $SSH "set -e
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
-    snapshot_acl /var/lib/macprovider/request-log.sqlite request-log-db.acl had-request-log-db-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-wal request-log-wal.acl had-request-log-wal-acl
-    snapshot_acl /var/lib/macprovider/request-log.sqlite-shm request-log-shm.acl had-request-log-shm-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
+    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
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
@@ -3623,28 +3623,28 @@ $SSH "set -e
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
   # after the late connected-provider safeguard immediately before restart.
   _autotune_root=/opt/macprovider/autotune
   _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
   _autotune_lock=\$_autotune_release.lock
   _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
   install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
   if ! mkdir \$_autotune_lock; then
     echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
     exit 1
@@ -4861,25 +4861,25 @@ $SSH 'set -e
       echo "warning: stats-inventory-sync.service failed; leaving coordinator deploy running with its parity marker and timer disabled"
       journalctl -u stats-inventory-sync.service -n 30 --no-pager || true
     else
       rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
       systemctl is-active stats-inventory-sync.timer
     fi
   elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
     systemctl start stats-inventory-sync.timer
     [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
   elif [ "$_parity_required" = absent ]; then
     echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
   fi
-  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ] && su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats; then
+  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
     systemctl enable --now stats-billing-mirror.timer
     if ! systemctl start stats-billing-mirror.service; then
       systemctl disable --now stats-billing-mirror.timer
       echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
       journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
       exit 13
     fi
     systemctl is-active stats-billing-mirror.timer
   elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-timer-was-active ]; then
     systemctl start stats-billing-mirror.timer
     [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
   else
diff --git a/phase4-coordinator/dist/stats-billing-mirror.service b/phase4-coordinator/dist/stats-billing-mirror.service
index 056cf4f47..0fbb75a51 100644
--- a/phase4-coordinator/dist/stats-billing-mirror.service
+++ b/phase4-coordinator/dist/stats-billing-mirror.service
@@ -1,28 +1,28 @@
 [Unit]
 Description=MacProvider stats billing mirror
 Documentation=https://github.com/augstar/macprovider-poc
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
 NoNewPrivileges=true
 PrivateDevices=true
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
@@ -139,25 +139,25 @@ for marker in had-stats-inventory-binary had-stats-billing-binary had-stats-hard
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
 
-grep -q 'snapshot_acl /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" &&
+grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
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
diff --git a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
index 9a2075ab5..8d8816853 100755
--- a/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
+++ b/phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh
@@ -32,54 +32,54 @@ grep -qF 'STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.time
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
 grep -qF 'aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run' "$DEPLOY_SH" ||
   fail "deploy script must fail closed when the configured billing mirror cannot run"
 
 grep -qxF 'User=macprovider-stats' "$SERVICE" ||
   fail "billing mirror must run as dedicated stats user"
 grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
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
 grep -qxF 'OnUnitActiveSec=60s' "$TIMER" ||
   fail "billing mirror timer must run frequently enough for public stats"
 grep -qF 'stats_billing_mirror_writer' "$ENV_EXAMPLE" ||
   fail "env example must document dedicated writer role"
 grep -qF 'STATS_BILLING_MIRROR_DSN=' "$ENV_EXAMPLE" ||
   fail "env example must define the expected DSN variable"
 grep -qF 'runs with --ensure-schema=false' "$ENV_EXAMPLE" ||
   fail "env example must document bootstrap-before-service contract"
 grep -qF 'CREATE TABLE IF NOT EXISTS ledger_request_credits' "$BOOTSTRAP_SQL" ||
diff --git a/phase4-coordinator/internal/stats/billingmirror/mirror.go b/phase4-coordinator/internal/stats/billingmirror/mirror.go
index 5cc0c9506..1caffe167 100644
--- a/phase4-coordinator/internal/stats/billingmirror/mirror.go
+++ b/phase4-coordinator/internal/stats/billingmirror/mirror.go
@@ -10,25 +10,25 @@ import (
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
-	DefaultSQLitePath  = "/var/lib/macprovider/request-log.sqlite"
+	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
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

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/stats-billing-mirror.service; rg -n \"coordinator\\.db|request-log\\.sqlite|restore_acl|snapshot_acl|setfacl|InaccessiblePaths|ReadOnlyPaths|ledger_request_credits|sqliteutil\" phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/stats-billing-mirror.service phase4-coordinator/internal/stats/billingmirror phase4-coordinator/internal/sqliteutil phase4-coordinator/internal -g '*.go' | sed -n '1,260p'" in /Users/augstar/macprovider-mirror-dbpath
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
    28	InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:7:ConditionPathExists=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:14:ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false
phase4-coordinator/dist/stats-billing-mirror.service:23:ReadOnlyPaths=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:24:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/stats-billing-mirror.service:25:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/stats-billing-mirror.service:26:InaccessiblePaths=/etc/macprovider
phase4-coordinator/dist/stats-billing-mirror.service:27:InaccessiblePaths=-/opt/macprovider/coordinator.yaml
phase4-coordinator/dist/stats-billing-mirror.service:28:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3071:  snapshot_acl() {
phase4-coordinator/dist/deploy-pearl-vps.sh:3139:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3629:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3634:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3639:    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
phase4-coordinator/dist/deploy-pearl-vps.sh:4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
phase4-coordinator/internal/sqliteutil/dsn.go:1:package sqliteutil
phase4-coordinator/internal/sqliteutil/transact_test.go:1:package sqliteutil
phase4-coordinator/internal/sqliteutil/wal.go:1:package sqliteutil
phase4-coordinator/internal/sqliteutil/wal.go:44:		return "", fmt.Errorf("sqliteutil: unsupported wal checkpoint mode %q", mode)
phase4-coordinator/internal/sqliteutil/wal.go:92:		return fmt.Errorf("sqliteutil: nil db")
phase4-coordinator/internal/sqliteutil/transact.go:1:package sqliteutil
phase4-coordinator/internal/sqliteutil/transact.go:43:// see phase4-coordinator/internal/sqliteutil/transact_test.go for the
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:196:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:201:	if _, err := db.Exec(`CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY)`); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:246:	path := filepath.Join(t.TempDir(), "request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:253:CREATE TABLE ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:272:  FROM ledger_request_credits
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:285:INSERT INTO ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:310:	path := filepath.Join(t.TempDir(), "legacy-request-log.sqlite")
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:317:CREATE TABLE ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror_test.go:333:INSERT INTO ledger_request_credits (
phase4-coordinator/internal/sqliteutil/dsn.go:1:package sqliteutil
phase4-coordinator/internal/sqliteutil/transact_test.go:1:package sqliteutil
phase4-coordinator/internal/stats/billingmirror/mirror.go:16:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/stats/billingmirror/mirror.go:22:	DefaultSQLitePath  = "/var/lib/macprovider/coordinator.db"
phase4-coordinator/internal/stats/billingmirror/mirror.go:254:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
phase4-coordinator/internal/stats/billingmirror/mirror.go:285:	if err := db.QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go:286:		return 0, fmt.Errorf("select max ledger_request_credits id: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:312:	hasPolicy, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "settlement_policy_mode")
phase4-coordinator/internal/stats/billingmirror/mirror.go:320:	hasRequestedPrivacyMode, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "requested_privacy_mode")
phase4-coordinator/internal/stats/billingmirror/mirror.go:324:	hasEffectivePrivacyOutcome, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "effective_privacy_outcome")
phase4-coordinator/internal/stats/billingmirror/mirror.go:328:	hasPositiveVerificationExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "positive_verification_excluded")
phase4-coordinator/internal/stats/billingmirror/mirror.go:332:	hasRewardsExcluded, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "rewards_excluded")
phase4-coordinator/internal/stats/billingmirror/mirror.go:387:  FROM ledger_request_credits lrc
phase4-coordinator/internal/stats/billingmirror/mirror.go:430:		return nil, fmt.Errorf("select ledger_request_credits: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:447:			return nil, fmt.Errorf("scan ledger_request_credits: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go:468:		return nil, fmt.Errorf("iterate ledger_request_credits: %w", err)
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
phase4-coordinator/internal/stats/billingmirror/mirror.go:912:      FROM ledger_request_credits
phase4-coordinator/internal/stats/billingmirror/mirror.go:918:    INSERT INTO ledger_request_credits (
phase4-coordinator/internal/stats/billingmirror/mirror.go:964:        GRANT SELECT ON ledger_request_credits TO stats_rollup;
phase4-coordinator/internal/stats/billingmirror/mirror.go:968:        GRANT SELECT ON ledger_request_credits TO rewards_writer;
phase4-coordinator/internal/stats/billingmirror/mirror.go:1001:        REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
phase4-coordinator/internal/sqliteutil/wal.go:1:package sqliteutil
phase4-coordinator/internal/sqliteutil/wal.go:44:		return "", fmt.Errorf("sqliteutil: unsupported wal checkpoint mode %q", mode)
phase4-coordinator/internal/sqliteutil/wal.go:92:		return fmt.Errorf("sqliteutil: nil db")
phase4-coordinator/internal/sqliteutil/transact.go:1:package sqliteutil
phase4-coordinator/internal/sqliteutil/transact.go:43:// see phase4-coordinator/internal/sqliteutil/transact_test.go for the
phase4-coordinator/internal/sqliteutil/wal_test.go:1:package sqliteutil
phase4-coordinator/internal/sqliteutil/wal_test.go:1:package sqliteutil
phase4-coordinator/internal/ws/identity_migration_test.go:25:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/ws/identity_migration_test.go:123:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/identity_migration_test.go:221:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1781:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1840:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1895:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:1932:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:2316:	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/server_test.go:2588:	auditStore, err := audit.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
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
phase4-coordinator/internal/buyer/route_snapshot_test.go:25:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/buyer/route_snapshot_test.go:1442:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/buyer/route_snapshot_test.go:1494:	if err := reqLog.DB().QueryRow(`SELECT quarantine_reason, settlement_policy_mode, settlement_policy_version FROM ledger_request_credits WHERE status = 200 LIMIT 1`).Scan(&gapReason, &policyMode, &policyVersion); err != nil {
phase4-coordinator/internal/buyer/route_snapshot_test.go:1525:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/buyer/route_snapshot_test.go:1577:	if err := reqLog.DB().QueryRow(`SELECT quarantine_reason, settlement_policy_mode, settlement_policy_version FROM ledger_request_credits WHERE status = 200 LIMIT 1`).Scan(&gapReason, &policyMode, &policyVersion); err != nil {
phase4-coordinator/internal/buyer/route_snapshot_test.go:2089:	rows, err := db.Query(`SELECT settlement_policy_mode FROM ledger_request_credits ORDER BY attempt_n ASC`)
phase4-coordinator/internal/buyer/route_snapshot_test.go:2149:	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits`).Scan(&count); err != nil {
phase4-coordinator/internal/config/config.go:717:	// SPEC-005 v0.3 stores `ledger_request_credits.provider_credits`
phase4-coordinator/internal/config/config.go:1600:			DBPath:                   "coordinator.db",
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
phase4-coordinator/internal/explorer/handlers_test.go:984:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/explorer/handlers_test.go:1016:insert into ledger_request_credits (
phase4-coordinator/internal/explorer/handlers_test.go:1023:		t.Fatalf("seed ledger_request_credits: %v", err)
phase4-coordinator/internal/explorer/handlers_test.go:1140:	for _, table := range []string{"request_log", "ledger_request_credits", "ledger_operator_credits", "ledger_payout_ready", "ledger_reconciliation_runs", "provider_tokens"} {
phase4-coordinator/internal/explorer/handlers_test.go:1158:	for _, table := range []string{"request_log", "ledger_request_credits", "ledger_operator_credits", "ledger_payout_ready", "ledger_reconciliation_runs", "provider_tokens"} {
phase4-coordinator/internal/requestlog/store.go:13:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/requestlog/store.go:130:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(dbPath))
phase4-coordinator/internal/requestlog/store.go:156:	dsn := sqliteutil.WithPragmas(dbPath)
phase4-coordinator/internal/requestlog/store.go:158:		dsn = sqliteutil.WithManualWALCheckpointPragmas(dbPath)
phase4-coordinator/internal/ws/referral_core_test.go:31:	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_decision_store_test.go:25:			db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/canary_store_test.go:14:	reqStore, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go:379:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/requestlog/store_test.go:462:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go:540:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/requestlog/store_test.go:849:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/rewards/projection.go:166:          FROM ledger_request_credits lrc
phase4-coordinator/internal/explorer/store.go:48:		LEFT JOIN ledger_request_credits lrc ON lrc.request_id = rl.request_id
phase4-coordinator/internal/explorer/store.go:86:		FROM ledger_request_credits lrc
phase4-coordinator/internal/explorer/store.go:112:		FROM ledger_request_credits lrc
phase4-coordinator/internal/explorer/store.go:163:		FROM ledger_request_credits
phase4-coordinator/internal/explorer/store.go:198:		FROM ledger_request_credits lrc
phase4-coordinator/internal/explorer/store.go:300:		FROM ledger_request_credits lrc`, encodeTime(from), encodeTime(to))
phase4-coordinator/internal/ws/model_admission_disablement_test.go:23:			authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_disablement_test.go:120:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/explorer/store_test.go:41:	if _, err := db.Exec(`UPDATE ledger_request_credits SET quarantined=1, quarantine_reason='test_quarantine' WHERE request_id='req_seed'`); err != nil {
phase4-coordinator/internal/explorer/store_test.go:48:  FROM ledger_request_credits WHERE request_id='req_seed'`,
phase4-coordinator/internal/explorer/store_test.go:58:  FROM ledger_request_credits WHERE request_id='req_seed'`,
phase4-coordinator/internal/explorer/store_test.go:121:INSERT INTO ledger_request_credits (
phase4-coordinator/internal/explorer/store_test.go:134:  FROM ledger_request_credits WHERE request_id='req_force_credit_payable'`,
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
phase4-coordinator/internal/referralapi/advocacy_test.go:72:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/ws/model_admission_intake_test.go:279:	db, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/referralapi/serving.go:11:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/referralapi/serving.go:50:	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(s.Path))
phase4-coordinator/internal/buyer/server_test.go:32:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/buyer/server_test.go:101:	store, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/buyer/server_test.go:3002:	if err := db.QueryRow(`SELECT usage_source, quarantined, quarantine_reason FROM ledger_request_credits ORDER BY id DESC LIMIT 1`).Scan(&usageSource, &quarantined, &reason); err != nil {
phase4-coordinator/internal/buyer/server_test.go:3113:FROM ledger_request_credits
phase4-coordinator/internal/buyer/server_test.go:7291:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/server_test.go:7308:	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(filepath.Join(t.TempDir(), "trustpool.sqlite")))
phase4-coordinator/internal/buyer/server_test.go:7511:	if err := db.QueryRow(`SELECT gross_credits, provider_credits, fault_flag FROM ledger_request_credits ORDER BY id DESC LIMIT 1`).Scan(&gross, &provider, &fault); err != nil {
phase4-coordinator/internal/buyer/server_test.go:7538:FROM ledger_request_credits
phase4-coordinator/internal/audit/store.go:14:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/audit/store.go:74:	dsn := sqliteutil.WithPragmas(dbPath)
phase4-coordinator/internal/audit/store.go:76:		dsn = sqliteutil.WithManualWALCheckpointPragmas(dbPath)
phase4-coordinator/internal/rewards/useful_work.go:56:          FROM ledger_request_credits lrc
phase4-coordinator/internal/rewards/wallet_mirror.go:10:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/rewards/wallet_mirror.go:24:	source, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(r.cfg.SQLitePayoutDBPath))
phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:106:CREATE TABLE ledger_request_credits (
phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:134:		if _, err := db.ExecContext(ctx, `INSERT INTO ledger_request_credits VALUES ($1, $2, $3, $4, $5, $6)`, row.provider, row.at, row.verified, row.mode, row.quarantined, row.credits); err != nil {
phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:167:	if _, err := db.ExecContext(ctx, "ALTER TABLE ledger_request_credits ADD COLUMN rewards_excluded BOOLEAN"); err != nil {
phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:171:		if _, err := db.ExecContext(ctx, `INSERT INTO ledger_request_credits VALUES ($1, $2, TRUE, 'enforce', FALSE, 7, TRUE)`, provider, now.Add(-time.Minute)); err != nil {
phase4-coordinator/internal/rewards/projection_endpoints_integration_test.go:182:		if _, err := db.ExecContext(ctx, "UPDATE ledger_request_credits SET rewards_excluded = $1 WHERE provider_id = 'provider-excluded'", flag); err != nil {
phase4-coordinator/internal/audit/store_test.go:16:	if got, want := DefaultDBPath(filepath.Join("var", "lib", "macprovider", "coordinator.db")), filepath.Join("var", "lib", "macprovider", "coordinator-audit.db"); got != want {
phase4-coordinator/internal/audit/store_test.go:19:	if got := DefaultDBPath("coordinator.db"); got != "coordinator-audit.db" {
phase4-coordinator/internal/audit/store_test.go:86:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/audit/store_test.go:244:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/audit/store_test.go:533:	store, err := OpenStore(t.TempDir() + "/coordinator.db")
phase4-coordinator/internal/rewards/emission_integration_test.go:843:        CREATE TABLE ledger_request_credits (
phase4-coordinator/internal/rewards/emission_integration_test.go:854:        GRANT SELECT ON ledger_request_credits TO rewards_writer;
phase4-coordinator/internal/rewards/emission_integration_test.go:879:        INSERT INTO ledger_request_credits
phase4-coordinator/internal/rewards/emission_integration_test.go:980:        CREATE TABLE ledger_request_credits (
phase4-coordinator/internal/rewards/emission_integration_test.go:991:        GRANT SELECT ON ledger_request_credits TO rewards_writer;
phase4-coordinator/internal/rewards/emission_integration_test.go:1003:        INSERT INTO ledger_request_credits
phase4-coordinator/internal/rewards/emission_integration_test.go:1010:        INSERT INTO ledger_request_credits
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go:427:	if err := db.QueryRowContext(ctx, `SELECT spec022_verified FROM ledger_request_credits WHERE request_id=$1`, in.requestID).Scan(&got); err != nil {
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go:481:  FROM ledger_request_credits
phase4-coordinator/internal/buyer/billing_recorder_test.go:43:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/billing_recorder_test.go:113:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/billing_recorder_test.go:170:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/buyer/billing_recorder_test.go:249:			dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/ws/admin_onboarding_test.go:56:	authStore, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/rewards/unlock.go:11:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/rewards/unlock.go:183:	source, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(r.cfg.SQLitePayoutDBPath))
phase4-coordinator/internal/ws/model_admission_probe_test.go:531:	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/billing/route_snapshot_test.go:16:	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
phase4-coordinator/internal/billing/route_snapshot_test.go:240:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:264:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go:284:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:295:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go:328:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:338:	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
phase4-coordinator/internal/billing/route_snapshot_test.go:350:	lockDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go:401:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:412:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go:430:	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
phase4-coordinator/internal/billing/route_snapshot_test.go:451:	lockDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go:484:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:501:	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
phase4-coordinator/internal/billing/route_snapshot_test.go:532:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:542:	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath+".route-snapshots"))
phase4-coordinator/internal/billing/route_snapshot_test.go:581:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:591:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go:601:	lockDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go:634:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/billing/route_snapshot_test.go:644:	routeSnapshotDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/route_snapshot_test.go:654:	lockDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(dbPath))
phase4-coordinator/internal/billing/payout.go:65:  FROM ledger_request_credits
phase4-coordinator/internal/billing/payout.go:75:  FROM ledger_request_credits lrc

exec
/bin/bash -lc "command -v systemd-analyze || true; systemd-analyze --version 2>/dev/null | head -2 || true; man systemd.exec 2>/dev/null | col -b | rg -n -C 4 'ReadOnlyPaths=|InaccessiblePaths=' | head -100 || true; rg -n \"InaccessiblePaths=-/var/lib/macprovider/coordinator.db|ReadOnlyPaths=.*coordinator.db\" phase4-coordinator/dist/test phase4-coordinator -g '*.sh' -g '*.service' -g '*.md'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 223ms:
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/stats-billing-mirror.service:23:ReadOnlyPaths=/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-billing-mirror.service:24:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/stats-billing-mirror.service:25:ReadOnlyPaths=-/var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/stats-billing-mirror.service:28:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/stats-hardware-verifier.service:25:InaccessiblePaths=-/var/lib/macprovider/coordinator.db
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||

exec
/bin/bash -lc "rg -n -C 12 \"restore_acl|had-request-log-(dir|db|wal|shm)-acl|coordinator\\.db|request-log\\.sqlite\" phase4-coordinator/dist/coordinator-deploy-recover phase4-coordinator/dist/deploy-pearl-vps.sh phase4-coordinator/dist/*.sh 2>/dev/null | sed -n '1,360p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/dist/coordinator-sqlite-relief.sh-1-#!/usr/bin/env bash
phase4-coordinator/dist/coordinator-sqlite-relief.sh-2-# Safe, manual SQLite hot-DB relief for coordinator operators.
phase4-coordinator/dist/coordinator-sqlite-relief.sh-3-# Runs a passive WAL checkpoint and touches hot-table schema metadata without
phase4-coordinator/dist/coordinator-sqlite-relief.sh-4-# changing durability pragmas or emitting credential-bearing config values.
phase4-coordinator/dist/coordinator-sqlite-relief.sh-5-
phase4-coordinator/dist/coordinator-sqlite-relief.sh-6-set -euo pipefail
phase4-coordinator/dist/coordinator-sqlite-relief.sh-7-
phase4-coordinator/dist/coordinator-sqlite-relief.sh-8-usage() {
phase4-coordinator/dist/coordinator-sqlite-relief.sh:9:  echo "usage: coordinator-sqlite-relief.sh [coordinator.db]" >&2
phase4-coordinator/dist/coordinator-sqlite-relief.sh-10-  echo "       or set MACPROVIDER_COORDINATOR_DB" >&2
phase4-coordinator/dist/coordinator-sqlite-relief.sh-11-}
phase4-coordinator/dist/coordinator-sqlite-relief.sh-12-
phase4-coordinator/dist/coordinator-sqlite-relief.sh-13-DB_PATH="${1:-${MACPROVIDER_COORDINATOR_DB:-}}"
phase4-coordinator/dist/coordinator-sqlite-relief.sh-14-if [ -z "$DB_PATH" ]; then
phase4-coordinator/dist/coordinator-sqlite-relief.sh-15-  usage
phase4-coordinator/dist/coordinator-sqlite-relief.sh-16-  exit 2
phase4-coordinator/dist/coordinator-sqlite-relief.sh-17-fi
phase4-coordinator/dist/coordinator-sqlite-relief.sh-18-if [ "${2:-}" != "" ]; then
phase4-coordinator/dist/coordinator-sqlite-relief.sh-19-  usage
phase4-coordinator/dist/coordinator-sqlite-relief.sh-20-  exit 2
phase4-coordinator/dist/coordinator-sqlite-relief.sh-21-fi
--
phase4-coordinator/dist/coordinator-deploy-recover.sh-123-  snapshot=$2
phase4-coordinator/dist/coordinator-deploy-recover.sh-124-  destination=$3
phase4-coordinator/dist/coordinator-deploy-recover.sh-125-  rm -f "$destination"
phase4-coordinator/dist/coordinator-deploy-recover.sh-126-  if [ -f "$ROLLBACK/$marker" ]; then
phase4-coordinator/dist/coordinator-deploy-recover.sh-127-    [ -e "$ROLLBACK/$snapshot" ] || [ -L "$ROLLBACK/$snapshot" ] || {
phase4-coordinator/dist/coordinator-deploy-recover.sh-128-      echo "rollback snapshot missing $snapshot" >&2
phase4-coordinator/dist/coordinator-deploy-recover.sh-129-      exit 1
phase4-coordinator/dist/coordinator-deploy-recover.sh-130-    }
phase4-coordinator/dist/coordinator-deploy-recover.sh-131-    cp -a "$ROLLBACK/$snapshot" "$destination"
phase4-coordinator/dist/coordinator-deploy-recover.sh-132-  fi
phase4-coordinator/dist/coordinator-deploy-recover.sh-133-}
phase4-coordinator/dist/coordinator-deploy-recover.sh-134-
phase4-coordinator/dist/coordinator-deploy-recover.sh:135:restore_acl() {
phase4-coordinator/dist/coordinator-deploy-recover.sh-136-  marker=$1
phase4-coordinator/dist/coordinator-deploy-recover.sh-137-  snapshot=$2
phase4-coordinator/dist/coordinator-deploy-recover.sh-138-  if [ -f "$ROLLBACK/$marker" ]; then
phase4-coordinator/dist/coordinator-deploy-recover.sh-139-    [ -f "$ROLLBACK/$snapshot" ] || {
phase4-coordinator/dist/coordinator-deploy-recover.sh-140-      echo "rollback snapshot missing $snapshot" >&2
phase4-coordinator/dist/coordinator-deploy-recover.sh-141-      exit 1
phase4-coordinator/dist/coordinator-deploy-recover.sh-142-    }
phase4-coordinator/dist/coordinator-deploy-recover.sh-143-    "$SETFACL" --restore="$ROLLBACK/$snapshot"
phase4-coordinator/dist/coordinator-deploy-recover.sh-144-  fi
phase4-coordinator/dist/coordinator-deploy-recover.sh-145-}
phase4-coordinator/dist/coordinator-deploy-recover.sh-146-
phase4-coordinator/dist/coordinator-deploy-recover.sh-147-restore_active_state() {
--
phase4-coordinator/dist/coordinator-deploy-recover.sh-217-
phase4-coordinator/dist/coordinator-deploy-recover.sh-218-restore_link_or_file had-nginx-stats-shared stats-shared.conf "$NGINX_ROOT/conf.d/stats-shared.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-219-restore_link_or_file had-nginx-stats-security-headers stats-security-headers.conf "$NGINX_ROOT/conf.d/stats-security-headers.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-220-restore_link_or_file had-nginx-stats-cors-429 cors-429.conf "$NGINX_ROOT/conf.d/cors-429.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-221-restore_link_or_file had-nginx-stats-proxy-public stats-proxy-public.conf "$NGINX_ROOT/conf.d/stats-proxy-public.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-222-restore_link_or_file had-nginx-stats-proxy-partner stats-proxy-partner.conf "$NGINX_ROOT/conf.d/stats-proxy-partner.conf"
phase4-coordinator/dist/coordinator-deploy-recover.sh-223-restore_link_or_file had-nginx-coordinator-site nginx-coordinator.site "$NGINX_ROOT/sites-available/coordinator.malibu.tech"
phase4-coordinator/dist/coordinator-deploy-recover.sh-224-restore_link_or_file had-nginx-stats-site nginx-stats.site "$NGINX_ROOT/sites-available/stats.malibu.tech"
phase4-coordinator/dist/coordinator-deploy-recover.sh-225-restore_link_or_file had-nginx-coordinator-enabled nginx-coordinator.enabled "$NGINX_ROOT/sites-enabled/coordinator.malibu.tech"
phase4-coordinator/dist/coordinator-deploy-recover.sh-226-restore_link_or_file had-nginx-stats-enabled nginx-stats.enabled "$NGINX_ROOT/sites-enabled/stats.malibu.tech"
phase4-coordinator/dist/coordinator-deploy-recover.sh-227-restore_link_or_file had-nginx-coordinator-full nginx-coordinator.full "$NGINX_ROOT/sites-available/coordinator.malibu.tech.full"
phase4-coordinator/dist/coordinator-deploy-recover.sh-228-
phase4-coordinator/dist/coordinator-deploy-recover.sh:229:restore_acl had-request-log-dir-acl request-log-dir.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh:230:restore_acl had-request-log-db-acl request-log-db.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh:231:restore_acl had-request-log-wal-acl request-log-wal.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh:232:restore_acl had-request-log-shm-acl request-log-shm.acl
phase4-coordinator/dist/coordinator-deploy-recover.sh-233-
phase4-coordinator/dist/coordinator-deploy-recover.sh-234-previous=$(cat "$ROLLBACK/catalog-current-target" 2>/dev/null || true)
phase4-coordinator/dist/coordinator-deploy-recover.sh-235-case "$previous" in
phase4-coordinator/dist/coordinator-deploy-recover.sh-236-  releases/*)
phase4-coordinator/dist/coordinator-deploy-recover.sh-237-    mkdir -p "$CATALOG_ROOT"
phase4-coordinator/dist/coordinator-deploy-recover.sh-238-    if [ -e "$CATALOG_ROOT/current" ] && [ ! -L "$CATALOG_ROOT/current" ]; then
phase4-coordinator/dist/coordinator-deploy-recover.sh-239-      echo "unsafe non-symlink catalog current path" >&2
phase4-coordinator/dist/coordinator-deploy-recover.sh-240-      exit 1
phase4-coordinator/dist/coordinator-deploy-recover.sh-241-    fi
phase4-coordinator/dist/coordinator-deploy-recover.sh-242-    ln -sfn "$previous" "$CATALOG_ROOT/current"
phase4-coordinator/dist/coordinator-deploy-recover.sh-243-    ;;
phase4-coordinator/dist/coordinator-deploy-recover.sh-244-  '') rm -f "$CATALOG_ROOT/current" ;;
--
phase4-coordinator/dist/coordinator-archive-rotate.sh-1-#!/usr/bin/env bash
phase4-coordinator/dist/coordinator-archive-rotate.sh:2:# coordinator-archive-rotate.sh — coordinator.db archive-rotate scaffold (#1226).
phase4-coordinator/dist/coordinator-archive-rotate.sh-3-#
phase4-coordinator/dist/coordinator-archive-rotate.sh-4-# Manual ops capacity ceiling for the 1-writer money DB: dry-run-first sizing
phase4-coordinator/dist/coordinator-archive-rotate.sh-5-# and snapshot scaffolding only (VACUUM INTO + gzip + sha256). Same fail-closed
phase4-coordinator/dist/coordinator-archive-rotate.sh-6-# shape as gateway archive-rotate, without live row DELETE. It reports
phase4-coordinator/dist/coordinator-archive-rotate.sh-7-# coordinator hot table counts and candidate terminal settlement bundles, but
phase4-coordinator/dist/coordinator-archive-rotate.sh-8-# refuses live prune by default.
phase4-coordinator/dist/coordinator-archive-rotate.sh-9-# Do not weaken settlement/audit compliance here:
phase4-coordinator/dist/coordinator-archive-rotate.sh-10-#   - settlement chains are never age-only deleted;
phase4-coordinator/dist/coordinator-archive-rotate.sh-11-#   - audit_log is never considered below the existing 90-day floor;
phase4-coordinator/dist/coordinator-archive-rotate.sh-12-#   - live prune requires a later, reviewed delete plan.
phase4-coordinator/dist/coordinator-archive-rotate.sh-13-#
phase4-coordinator/dist/coordinator-archive-rotate.sh-14-# Environment:
phase4-coordinator/dist/coordinator-archive-rotate.sh:15:#   COORDINATOR_DB_PATH                  default: /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/coordinator-archive-rotate.sh-16-#   COORDINATOR_AUDIT_DB_PATH            default: sibling coordinator-audit.db
phase4-coordinator/dist/coordinator-archive-rotate.sh-17-#   COORDINATOR_ARCHIVE_DIR             default: /var/lib/macprovider-coordinator-archive
phase4-coordinator/dist/coordinator-archive-rotate.sh-18-#   COORDINATOR_ARCHIVE_TERMINAL_DAYS   default: 180
phase4-coordinator/dist/coordinator-archive-rotate.sh-19-#   COORDINATOR_ARCHIVE_AUDIT_DAYS      default: 90; values below 90 are refused
phase4-coordinator/dist/coordinator-archive-rotate.sh-20-#   COORDINATOR_ARCHIVE_SNAPSHOT_ONLY   default: 0; set 1 to take a verified archive
phase4-coordinator/dist/coordinator-archive-rotate.sh-21-#   COORDINATOR_ARCHIVE_ASSUME_QUIESCED default: 0; required for snapshot/live paths
phase4-coordinator/dist/coordinator-archive-rotate.sh-22-#   FORCE_ROTATE                        default: 0; required for snapshot/live paths
phase4-coordinator/dist/coordinator-archive-rotate.sh-23-#   LIVE_PRUNE                          default: 0; live prune still refuses in Phase 3
phase4-coordinator/dist/coordinator-archive-rotate.sh-24-#   DRY_RUN                             default: 1; report only, no state changes
phase4-coordinator/dist/coordinator-archive-rotate.sh-25-#
phase4-coordinator/dist/coordinator-archive-rotate.sh-26-# Exit codes:
phase4-coordinator/dist/coordinator-archive-rotate.sh-27-#   0  dry-run report or snapshot success
phase4-coordinator/dist/coordinator-archive-rotate.sh-28-#   1  generic error
phase4-coordinator/dist/coordinator-archive-rotate.sh-29-#   2  usage / malformed environment
phase4-coordinator/dist/coordinator-archive-rotate.sh-30-#   4  live/snapshot safety gate refused
phase4-coordinator/dist/coordinator-archive-rotate.sh-31-
phase4-coordinator/dist/coordinator-archive-rotate.sh-32-set -euo pipefail
phase4-coordinator/dist/coordinator-archive-rotate.sh-33-
phase4-coordinator/dist/coordinator-archive-rotate.sh:34:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-35-COORDINATOR_AUDIT_DB_PATH="${COORDINATOR_AUDIT_DB_PATH:-}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-36-COORDINATOR_ARCHIVE_DIR="${COORDINATOR_ARCHIVE_DIR:-/var/lib/macprovider-coordinator-archive}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-37-COORDINATOR_ARCHIVE_TERMINAL_DAYS="${COORDINATOR_ARCHIVE_TERMINAL_DAYS:-180}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-38-COORDINATOR_ARCHIVE_AUDIT_DAYS="${COORDINATOR_ARCHIVE_AUDIT_DAYS:-90}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-39-COORDINATOR_ARCHIVE_SNAPSHOT_ONLY="${COORDINATOR_ARCHIVE_SNAPSHOT_ONLY:-0}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-40-COORDINATOR_ARCHIVE_ASSUME_QUIESCED="${COORDINATOR_ARCHIVE_ASSUME_QUIESCED:-0}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-41-FORCE_ROTATE="${FORCE_ROTATE:-0}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-42-LIVE_PRUNE="${LIVE_PRUNE:-0}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-43-DRY_RUN="${DRY_RUN:-1}"
phase4-coordinator/dist/coordinator-archive-rotate.sh-44-
phase4-coordinator/dist/coordinator-archive-rotate.sh-45-log() { printf '[coordinator-archive-rotate] %s\n' "$*" >&2; }
phase4-coordinator/dist/coordinator-archive-rotate.sh-46-fail() { log "ERROR: $*"; exit 1; }
--
phase4-coordinator/dist/coordinator-archive-rotate.sh-262-  total=$(table_count "settlement_receipt_verdicts")
phase4-coordinator/dist/coordinator-archive-rotate.sh-263-  bytes=$(dbstat_bytes "settlement_receipt_verdicts")
phase4-coordinator/dist/coordinator-archive-rotate.sh-264-  if [ "$total" -le 0 ] || [ "$bytes" -le 0 ]; then
phase4-coordinator/dist/coordinator-archive-rotate.sh-265-    printf '0\n'
phase4-coordinator/dist/coordinator-archive-rotate.sh-266-    return 0
phase4-coordinator/dist/coordinator-archive-rotate.sh-267-  fi
phase4-coordinator/dist/coordinator-archive-rotate.sh-268-  awk -v e="$candidates" -v t="$total" -v b="$bytes" 'BEGIN { printf "%.0f\n", (e / t) * b }'
phase4-coordinator/dist/coordinator-archive-rotate.sh-269-}
phase4-coordinator/dist/coordinator-archive-rotate.sh-270-
phase4-coordinator/dist/coordinator-archive-rotate.sh-271-run_dry_report() {
phase4-coordinator/dist/coordinator-archive-rotate.sh-272-  local size bundles rows reclaim audit_rows
phase4-coordinator/dist/coordinator-archive-rotate.sh-273-  size=$(stat_size "$COORDINATOR_DB_PATH")
phase4-coordinator/dist/coordinator-archive-rotate.sh:274:  log "DRY_RUN=1 coordinator.db size=${size}B"
phase4-coordinator/dist/coordinator-archive-rotate.sh-275-  log "candidate terminal settlement bundle reporting requires closed terminal receipt verdicts older than ${COORDINATOR_ARCHIVE_TERMINAL_DAYS}d"
phase4-coordinator/dist/coordinator-archive-rotate.sh-276-  log "audit_log reporting floor=${COORDINATOR_ARCHIVE_AUDIT_DAYS}d (minimum 90d)"
phase4-coordinator/dist/coordinator-archive-rotate.sh-277-
phase4-coordinator/dist/coordinator-archive-rotate.sh-278-  for table in \
phase4-coordinator/dist/coordinator-archive-rotate.sh-279-    request_log audit_log \
phase4-coordinator/dist/coordinator-archive-rotate.sh-280-    ledger_request_credits ledger_provider_earnings ledger_operator_credits ledger_payout_ready \
phase4-coordinator/dist/coordinator-archive-rotate.sh-281-    ledger_provider_identity_snapshots ledger_config_audit_events ledger_quarantine_resolutions \
phase4-coordinator/dist/coordinator-archive-rotate.sh-282-    settlement_route_snapshots settlement_compute_integrity_captures settlement_attempt_outputs \
phase4-coordinator/dist/coordinator-archive-rotate.sh-283-    settlement_receipt_verdicts settlement_receipt_audit_outbox; do
phase4-coordinator/dist/coordinator-archive-rotate.sh-284-    report_table "$table"
phase4-coordinator/dist/coordinator-archive-rotate.sh-285-  done
phase4-coordinator/dist/coordinator-archive-rotate.sh-286-  report_audit_sibling
--
phase4-coordinator/dist/coordinator-archive-restore.sh-1-#!/usr/bin/env bash
phase4-coordinator/dist/coordinator-archive-restore.sh-2-# coordinator-archive-restore.sh — forensic restore for coordinator DB archives (#1226).
phase4-coordinator/dist/coordinator-archive-restore.sh-3-#
phase4-coordinator/dist/coordinator-archive-restore.sh-4-# Restores archives produced by coordinator-archive-rotate.sh to a separate
phase4-coordinator/dist/coordinator-archive-restore.sh-5-# target. Replacing the live coordinator DB is refused; promote restored files
phase4-coordinator/dist/coordinator-archive-restore.sh-6-# manually only after operator review.
phase4-coordinator/dist/coordinator-archive-restore.sh-7-
phase4-coordinator/dist/coordinator-archive-restore.sh-8-set -euo pipefail
phase4-coordinator/dist/coordinator-archive-restore.sh-9-
phase4-coordinator/dist/coordinator-archive-restore.sh:10:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
phase4-coordinator/dist/coordinator-archive-restore.sh-11-COORDINATOR_AUDIT_DB_PATH="${COORDINATOR_AUDIT_DB_PATH:-}"
phase4-coordinator/dist/coordinator-archive-restore.sh-12-SKIP_CHECKSUM="${SKIP_CHECKSUM:-0}"
phase4-coordinator/dist/coordinator-archive-restore.sh-13-ALLOW_UNPAIRED_AUDIT_RESTORE="${ALLOW_UNPAIRED_AUDIT_RESTORE:-0}"
phase4-coordinator/dist/coordinator-archive-restore.sh-14-
phase4-coordinator/dist/coordinator-archive-restore.sh-15-log() { printf '[coordinator-archive-restore] %s\n' "$*" >&2; }
phase4-coordinator/dist/coordinator-archive-restore.sh-16-fail() { log "ERROR: $*"; exit 1; }
phase4-coordinator/dist/coordinator-archive-restore.sh-17-refuse() { log "REFUSING: $*"; exit 4; }
phase4-coordinator/dist/coordinator-archive-restore.sh-18-
phase4-coordinator/dist/coordinator-archive-restore.sh-19-need_tool() {
phase4-coordinator/dist/coordinator-archive-restore.sh-20-  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
phase4-coordinator/dist/coordinator-archive-restore.sh-21-}
phase4-coordinator/dist/coordinator-archive-restore.sh-22-
--
phase4-coordinator/dist/coordinator-archive-restore.sh-170-  esac
phase4-coordinator/dist/coordinator-archive-restore.sh-171-
phase4-coordinator/dist/coordinator-archive-restore.sh-172-  integrity=$(sqlite3 "$tmp_db" "PRAGMA integrity_check;" || echo "fail")
phase4-coordinator/dist/coordinator-archive-restore.sh-173-  [ "$integrity" = "ok" ] || fail "restored DB integrity_check failed"
phase4-coordinator/dist/coordinator-archive-restore.sh-174-  fk=$(sqlite3 "$tmp_db" "PRAGMA foreign_key_check;" || echo "fail")
phase4-coordinator/dist/coordinator-archive-restore.sh-175-  [ -z "$fk" ] || fail "restored DB foreign_key_check failed"
phase4-coordinator/dist/coordinator-archive-restore.sh-176-}
phase4-coordinator/dist/coordinator-archive-restore.sh-177-
phase4-coordinator/dist/coordinator-archive-restore.sh-178-AUDIT_ARCHIVE_PATH=$(paired_audit_archive_for "$ARCHIVE_PATH")
phase4-coordinator/dist/coordinator-archive-restore.sh-179-if [ -z "$AUDIT_ARCHIVE_PATH" ] && [ "$ALLOW_UNPAIRED_AUDIT_RESTORE" != "1" ]; then
phase4-coordinator/dist/coordinator-archive-restore.sh-180-  refuse "paired coordinator-audit archive missing; set ALLOW_UNPAIRED_AUDIT_RESTORE=1 only for legacy primary-only forensic restores"
phase4-coordinator/dist/coordinator-archive-restore.sh-181-fi
phase4-coordinator/dist/coordinator-archive-restore.sh:182:PRIMARY_TMP="$TMP_DIR/coordinator.db"
phase4-coordinator/dist/coordinator-archive-restore.sh-183-AUDIT_TMP="$TMP_DIR/coordinator-audit.db"
phase4-coordinator/dist/coordinator-archive-restore.sh-184-if [ -n "$AUDIT_ARCHIVE_PATH" ]; then
phase4-coordinator/dist/coordinator-archive-restore.sh-185-  refuse_restore_target "audit" "$COORDINATOR_AUDIT_DB_PATH" "$LIVE_AUDIT_DB_PATH"
phase4-coordinator/dist/coordinator-archive-restore.sh-186-  primary_canon=$(resolved_path "$TARGET_PATH")
phase4-coordinator/dist/coordinator-archive-restore.sh-187-  audit_canon=$(resolved_path "$COORDINATOR_AUDIT_DB_PATH")
phase4-coordinator/dist/coordinator-archive-restore.sh-188-  if [ "$primary_canon" = "$audit_canon" ]; then
phase4-coordinator/dist/coordinator-archive-restore.sh-189-    refuse "audit restore target collides with primary restore target"
phase4-coordinator/dist/coordinator-archive-restore.sh-190-  fi
phase4-coordinator/dist/coordinator-archive-restore.sh-191-  if [ -e "$TARGET_PATH" ] && [ -e "$COORDINATOR_AUDIT_DB_PATH" ] && [ "$TARGET_PATH" -ef "$COORDINATOR_AUDIT_DB_PATH" ]; then
phase4-coordinator/dist/coordinator-archive-restore.sh-192-    refuse "audit restore target collides with primary restore target"
phase4-coordinator/dist/coordinator-archive-restore.sh-193-  fi
phase4-coordinator/dist/coordinator-archive-restore.sh-194-fi
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3128-  snapshot_node /etc/nginx/conf.d/stats-shared.conf stats-shared.conf had-nginx-stats-shared
phase4-coordinator/dist/deploy-pearl-vps.sh-3129-  snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
phase4-coordinator/dist/deploy-pearl-vps.sh-3130-  snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
phase4-coordinator/dist/deploy-pearl-vps.sh-3131-  snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
phase4-coordinator/dist/deploy-pearl-vps.sh-3132-  snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
phase4-coordinator/dist/deploy-pearl-vps.sh-3133-  snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
phase4-coordinator/dist/deploy-pearl-vps.sh-3134-  snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
phase4-coordinator/dist/deploy-pearl-vps.sh-3135-  snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
phase4-coordinator/dist/deploy-pearl-vps.sh-3136-  snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
phase4-coordinator/dist/deploy-pearl-vps.sh-3137-  snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full
phase4-coordinator/dist/deploy-pearl-vps.sh-3138-
phase4-coordinator/dist/deploy-pearl-vps.sh-3139-  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh-3144-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3145-  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3146-    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3147-    touch \"\$_rollback_stage/had-wants-link\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3148-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3149-  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3150-    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3151-    touch \"\$_rollback_stage/had-recovery-helper\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3152-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3153-  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3154-    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3155-    touch \"\$_rollback_stage/had-recovery-unit\"
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3617-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3618-  if [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3619-    printf '{}\n' > $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3620-    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3621-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3622-  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3623-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3624-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-3625-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3626-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-3627-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.service /etc/systemd/system/stats-hardware-verifier.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3628-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.timer /etc/systemd/system/stats-hardware-verifier.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:3629:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3630-    # Mutate only objects captured at the transaction boundary. WAL/SHM files
phase4-coordinator/dist/deploy-pearl-vps.sh-3631-    # can appear while the old coordinator is still running; granting an ACL
phase4-coordinator/dist/deploy-pearl-vps.sh-3632-    # to a newly appeared, unsnapshotted file would make exact rollback
phase4-coordinator/dist/deploy-pearl-vps.sh-3633-    # impossible.
phase4-coordinator/dist/deploy-pearl-vps.sh:3634:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3639-    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
phase4-coordinator/dist/deploy-pearl-vps.sh-3640-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3641-  # Stage the complete immutable catalog release. Activation happens only
phase4-coordinator/dist/deploy-pearl-vps.sh-3642-  # after the late connected-provider safeguard immediately before restart.
phase4-coordinator/dist/deploy-pearl-vps.sh-3643-  _autotune_root=/opt/macprovider/autotune
phase4-coordinator/dist/deploy-pearl-vps.sh-3644-  _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
phase4-coordinator/dist/deploy-pearl-vps.sh-3645-  _autotune_lock=\$_autotune_release.lock
phase4-coordinator/dist/deploy-pearl-vps.sh-3646-  _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
phase4-coordinator/dist/deploy-pearl-vps.sh-3647-  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
phase4-coordinator/dist/deploy-pearl-vps.sh-3648-  if ! mkdir \$_autotune_lock; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3649-    echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3650-    exit 1
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4861-      echo "warning: stats-inventory-sync.service failed; leaving coordinator deploy running with its parity marker and timer disabled"
phase4-coordinator/dist/deploy-pearl-vps.sh-4862-      journalctl -u stats-inventory-sync.service -n 30 --no-pager || true
phase4-coordinator/dist/deploy-pearl-vps.sh-4863-    else
phase4-coordinator/dist/deploy-pearl-vps.sh-4864-      rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
phase4-coordinator/dist/deploy-pearl-vps.sh-4865-      systemctl is-active stats-inventory-sync.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4866-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4867-  elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4868-    systemctl start stats-inventory-sync.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4869-    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-service-was-active ] || systemctl start stats-inventory-sync.service
phase4-coordinator/dist/deploy-pearl-vps.sh-4870-  elif [ "$_parity_required" = absent ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4871-    echo "stats inventory timer not enabled: missing /etc/macprovider-stats/stats-hardware-inventory.yaml or stats-inventory-sync.env"
phase4-coordinator/dist/deploy-pearl-vps.sh-4872-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh:4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4874-    systemctl enable --now stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4875-    if ! systemctl start stats-billing-mirror.service; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4876-      systemctl disable --now stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4877-      echo "aborting deploy: stats-billing-mirror.service failed its initial schema/binary parity run" >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-4878-      journalctl -u stats-billing-mirror.service -n 30 --no-pager || true
phase4-coordinator/dist/deploy-pearl-vps.sh-4879-      exit 13
phase4-coordinator/dist/deploy-pearl-vps.sh-4880-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4881-    systemctl is-active stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4882-  elif [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-timer-was-active ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-4883-    systemctl start stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4884-    [ ! -f /opt/macprovider/.coordinator-deploy-rollback/stats-billing-service-was-active ] || systemctl start stats-billing-mirror.service
phase4-coordinator/dist/deploy-pearl-vps.sh-4885-  else
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3128-  snapshot_node /etc/nginx/conf.d/stats-shared.conf stats-shared.conf had-nginx-stats-shared
phase4-coordinator/dist/deploy-pearl-vps.sh-3129-  snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
phase4-coordinator/dist/deploy-pearl-vps.sh-3130-  snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
phase4-coordinator/dist/deploy-pearl-vps.sh-3131-  snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
phase4-coordinator/dist/deploy-pearl-vps.sh-3132-  snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
phase4-coordinator/dist/deploy-pearl-vps.sh-3133-  snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
phase4-coordinator/dist/deploy-pearl-vps.sh-3134-  snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
phase4-coordinator/dist/deploy-pearl-vps.sh-3135-  snapshot_node /etc/nginx/sites-enabled/$DOMAIN nginx-coordinator.enabled had-nginx-coordinator-enabled
phase4-coordinator/dist/deploy-pearl-vps.sh-3136-  snapshot_node /etc/nginx/sites-enabled/$STATS_DOMAIN nginx-stats.enabled had-nginx-stats-enabled
phase4-coordinator/dist/deploy-pearl-vps.sh-3137-  snapshot_node /etc/nginx/sites-available/$DOMAIN.full nginx-coordinator.full had-nginx-coordinator-full
phase4-coordinator/dist/deploy-pearl-vps.sh-3138-
phase4-coordinator/dist/deploy-pearl-vps.sh-3139-  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
phase4-coordinator/dist/deploy-pearl-vps.sh:3140:    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh-3144-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3145-  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3146-    cp -a /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.wants\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3147-    touch \"\$_rollback_stage/had-wants-link\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3148-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3149-  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3150-    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3151-    touch \"\$_rollback_stage/had-recovery-helper\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3152-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3153-  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3154-    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
phase4-coordinator/dist/deploy-pearl-vps.sh-3155-    touch \"\$_rollback_stage/had-recovery-unit\"
--
phase4-coordinator/dist/deploy-pearl-vps.sh-3617-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3618-  if [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3619-    printf '{}\n' > $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3620-    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
phase4-coordinator/dist/deploy-pearl-vps.sh-3621-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3622-  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3623-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3624-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-3625-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3626-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-3627-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.service /etc/systemd/system/stats-hardware-verifier.service
phase4-coordinator/dist/deploy-pearl-vps.sh-3628-  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-hardware-verifier.timer /etc/systemd/system/stats-hardware-verifier.timer
phase4-coordinator/dist/deploy-pearl-vps.sh:3629:  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-db-acl ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3630-    # Mutate only objects captured at the transaction boundary. WAL/SHM files
phase4-coordinator/dist/deploy-pearl-vps.sh-3631-    # can appear while the old coordinator is still running; granting an ACL
phase4-coordinator/dist/deploy-pearl-vps.sh-3632-    # to a newly appeared, unsnapshotted file would make exact rollback
phase4-coordinator/dist/deploy-pearl-vps.sh-3633-    # impossible.
phase4-coordinator/dist/deploy-pearl-vps.sh:3634:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-dir-acl ] && setfacl -m u:macprovider-stats:--x /var/lib/macprovider
phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3639-    echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'
phase4-coordinator/dist/deploy-pearl-vps.sh-3640-  fi
phase4-coordinator/dist/deploy-pearl-vps.sh-3641-  # Stage the complete immutable catalog release. Activation happens only
phase4-coordinator/dist/deploy-pearl-vps.sh-3642-  # after the late connected-provider safeguard immediately before restart.
phase4-coordinator/dist/deploy-pearl-vps.sh-3643-  _autotune_root=/opt/macprovider/autotune
phase4-coordinator/dist/deploy-pearl-vps.sh-3644-  _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
phase4-coordinator/dist/deploy-pearl-vps.sh-3645-  _autotune_lock=\$_autotune_release.lock
phase4-coordinator/dist/deploy-pearl-vps.sh-3646-  _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
phase4-coordinator/dist/deploy-pearl-vps.sh-3647-  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
phase4-coordinator/dist/deploy-pearl-vps.sh-3648-  if ! mkdir \$_autotune_lock; then
phase4-coordinator/dist/deploy-pearl-vps.sh-3649-    echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
phase4-coordinator/dist/deploy-pearl-vps.sh-3650-    exit 1
--
phase4-coordinator/dist/deploy-pearl-vps.sh-4861-      echo "warning: stats-inventory-sync.service failed; leaving coordinator deploy running with its parity marker and timer disabled"
phase4-coordinator/dist/deploy-pearl-vps.sh-4862-      journalctl -u stats-inventory-sync.service -n 30 --no-pager || true
phase4-coordinator/dist/deploy-pearl-vps.sh-4863-    else
phase4-coordinator/dist/deploy-pearl-vps.sh-4864-      rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
phase4-coordinator/dist/deploy-pearl-vps.sh-4865-      systemctl is-active stats-inventory-sync.timer
phase4-coordinator/dist/deploy-pearl-vps.sh-4866-    fi
phase4-coordinator/dist/deploy-pearl-vps.sh-4867-  elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then

exec
/bin/bash -lc "sed -n '1,140p' phase4-coordinator/internal/sqliteutil/dsn.go; sed -n '220,285p' phase4-coordinator/internal/stats/billingmirror/mirror.go; sed -n '280,470p' phase4-coordinator/internal/stats/billingmirror/mirror.go; sed -n '880,1040p' phase4-coordinator/internal/stats/billingmirror/mirror.go" in /Users/augstar/macprovider-mirror-dbpath
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
}

func FetchMaxRequestCreditID(ctx context.Context, db *sql.DB) (int64, error) {
	var maxID sql.NullInt64
	if err := db.QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
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
		row.Quarantined = quarantined != 0
		row.Spec022Verified = spec022Verified != 0
		row.PositiveVerificationExcluded = positiveExcluded != 0
		row.RewardsExcluded = rewardsExcluded != 0
		out = append(out, row)
	}
	if err := cur.Err(); err != nil {
		return nil, fmt.Errorf("iterate ledger_request_credits: %w", err)
	}
	return out, nil
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
}

exec
/bin/bash -lc "rg -n -C 4 \"CREATE TABLE (IF NOT EXISTS )?provider_tokens|provider_tokens|token\" phase4-coordinator/internal phase4-coordinator/migrations phase4-coordinator/dist -g '*.go' -g '*.sql' -g '*.yaml' -g '*.sh' | sed -n '1,260p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
rg: phase4-coordinator/migrations: No such file or directory (os error 2)
phase4-coordinator/dist/install-micromdm-pearl.sh-163-
phase4-coordinator/dist/install-micromdm-pearl.sh-164-/opt/micromdm/bin/mdmctl config set \
phase4-coordinator/dist/install-micromdm-pearl.sh-165-  -name pearl \
phase4-coordinator/dist/install-micromdm-pearl.sh-166-  -server-url "http://127.0.0.1:8080" \
phase4-coordinator/dist/install-micromdm-pearl.sh:167:  -api-token "$API_KEY"
phase4-coordinator/dist/install-micromdm-pearl.sh-168-/opt/micromdm/bin/mdmctl config switch -name pearl
phase4-coordinator/dist/install-micromdm-pearl.sh-169-/opt/micromdm/bin/mdmctl mdmcert upload \
phase4-coordinator/dist/install-micromdm-pearl.sh-170-  -cert /etc/micromdm/apns/PushCertificate.pem \
phase4-coordinator/dist/install-micromdm-pearl.sh-171-  -private-key "$KEY_UPLOAD"
--
phase4-coordinator/dist/check-deploy-config.sh-10-#     cover the gateway's streaming ceiling, else the coordinator truncates a
phase4-coordinator/dist/check-deploy-config.sh-11-#     healthy long stream before the gateway's #760 ceiling has any effect.
phase4-coordinator/dist/check-deploy-config.sh-12-#     The gateway response-header transport timeout must cover both the gateway
phase4-coordinator/dist/check-deploy-config.sh-13-#     admission phase and the effective non-streaming request wall, else slow
phase4-coordinator/dist/check-deploy-config.sh:14:#     first-token streams or slow non-streaming completions can false-fail
phase4-coordinator/dist/check-deploy-config.sh-15-#     before their configured budgets expire.
phase4-coordinator/dist/check-deploy-config.sh-16-#
phase4-coordinator/dist/check-deploy-config.sh-17-# Usage: check-deploy-config.sh <coordinator.yaml> <gateway.yaml> [coordinator-overlay.yaml]
phase4-coordinator/dist/check-deploy-config.sh-18-# Exit 1 on HARD failure; 0 otherwise (WARN/note lines are non-blocking).
--
phase4-coordinator/dist/check-deploy-config.sh-300-
phase4-coordinator/dist/check-deploy-config.sh-301-# --- operator_key (inline literal or env:NAME deferred to runtime) ---
phase4-coordinator/dist/check-deploy-config.sh-302-check_hex_secret("coordinator operator_key", g_section(coord, "auth", "operator_key"))
phase4-coordinator/dist/check-deploy-config.sh-303-
phase4-coordinator/dist/check-deploy-config.sh:304:# --- gateway_service_token (coordinator side) — REQUIRED after PR #172 ---
phase4-coordinator/dist/check-deploy-config.sh-305-# PR #172 (issue #87 item 3) removed the legacy operator_key fallback on
phase4-coordinator/dist/check-deploy-config.sh:306:# /internal/*; the coordinator now accepts ONLY gateway_service_token there.
phase4-coordinator/dist/check-deploy-config.sh:307:# A coordinator deployed without auth.gateway_service_token boots but rejects
phase4-coordinator/dist/check-deploy-config.sh-308-# every gateway call to /internal/routing + /internal/sticky, taking the
phase4-coordinator/dist/check-deploy-config.sh-309-# buyer path offline.
phase4-coordinator/dist/check-deploy-config.sh:310:check_hex_secret("coordinator gateway_service_token",
phase4-coordinator/dist/check-deploy-config.sh:311:                 g_section(coord, "auth", "gateway_service_token"))
phase4-coordinator/dist/check-deploy-config.sh-312-
phase4-coordinator/dist/check-deploy-config.sh-313-# --- gateway credentials (same hazard class as the coordinator key) ---
phase4-coordinator/dist/check-deploy-config.sh-314-# Only checkable when the gateway config is present. Both operator_key (for
phase4-coordinator/dist/check-deploy-config.sh:315:# /poolz proxying) and service_token (for /internal/* upstream calls) are
phase4-coordinator/dist/check-deploy-config.sh-316-# REQUIRED by gateway
phase4-coordinator/dist/check-deploy-config.sh-317-# config.go Validate() after PR #172. The gateway runtime fails
phase4-coordinator/dist/check-deploy-config.sh:318:# closed on an unset/empty env:NAME or an empty token; the residual gap
phase4-coordinator/dist/check-deploy-config.sh-319-# this gate catches is an INLINE placeholder, which is non-empty and so
phase4-coordinator/dist/check-deploy-config.sh-320-# boots with a junk credential that silently fails gateway->coordinator
phase4-coordinator/dist/check-deploy-config.sh-321-# auth, symmetric to the coordinator operator_key check above.
phase4-coordinator/dist/check-deploy-config.sh-322-if gw:
phase4-coordinator/dist/check-deploy-config.sh-323-    check_hex_secret("gateway operator_key", g_section(gw, "coordinator", "operator_key"))
phase4-coordinator/dist/check-deploy-config.sh:324:    check_hex_secret("gateway service_token", g_section(gw, "coordinator", "service_token"))
phase4-coordinator/dist/check-deploy-config.sh-325-
phase4-coordinator/dist/check-deploy-config.sh:326:# --- C2c: operator/service token distinctness (rotation discipline) ---
phase4-coordinator/dist/check-deploy-config.sh:327:# Post-cutover, the operator_key and gateway_service_token are the only two
phase4-coordinator/dist/check-deploy-config.sh-328-# bearer classes on the coordinator: operator_key on /poolz + /admin/*,
phase4-coordinator/dist/check-deploy-config.sh:329:# service_token on /internal/*. If they collapse to the same value, the
phase4-coordinator/dist/check-deploy-config.sh-330-# operator credential still authenticates /internal/* by value, defeating
phase4-coordinator/dist/check-deploy-config.sh-331-# the operator-vs-service split this PR is meant to finish. Check on each
phase4-coordinator/dist/check-deploy-config.sh-332-# side (coordinator self, gateway self) AND cross-file (gateway operator_key
phase4-coordinator/dist/check-deploy-config.sh:333:# vs coordinator gateway_service_token, when both resolvable).
phase4-coordinator/dist/check-deploy-config.sh-334-def _env_name(raw):
phase4-coordinator/dist/check-deploy-config.sh-335-    """If raw is a well-formed env:NAME ref, return NAME. Else None."""
phase4-coordinator/dist/check-deploy-config.sh-336-    if not raw or not raw.startswith("env:"):
phase4-coordinator/dist/check-deploy-config.sh-337-        return None
--
phase4-coordinator/dist/check-deploy-config.sh-340-
phase4-coordinator/dist/check-deploy-config.sh-341-def _safe_describe(raw):
phase4-coordinator/dist/check-deploy-config.sh-342-    """Classify a secret-bearing field WITHOUT printing its value.
phase4-coordinator/dist/check-deploy-config.sh-343-    Audit-r5 (3-of-3 lanes) found that printing raw_a/raw_b in WARN
phase4-coordinator/dist/check-deploy-config.sh:344:    messages can leak a live bearer token into deploy/wrapper logs.
phase4-coordinator/dist/check-deploy-config.sh-345-    Categories: absent | inline-redacted | env:NAME (resolved|unresolved)
phase4-coordinator/dist/check-deploy-config.sh-346-    | env malformed."""
phase4-coordinator/dist/check-deploy-config.sh-347-    if not raw:
phase4-coordinator/dist/check-deploy-config.sh-348-        return "absent"
--
phase4-coordinator/dist/check-deploy-config.sh-356-
phase4-coordinator/dist/check-deploy-config.sh-357-def _resolved_value(raw):
phase4-coordinator/dist/check-deploy-config.sh-358-    """Return the resolved value (whitespace-trimmed) or None if deferred/
phase4-coordinator/dist/check-deploy-config.sh-359-    malformed/missing. TrimSpace mirrors auth.BearerTokenMatchesHeader so a
phase4-coordinator/dist/check-deploy-config.sh:360:    config with `service_token: "X "` is judged the same way the runtime
phase4-coordinator/dist/check-deploy-config.sh-361-    will judge it on the wire."""
phase4-coordinator/dist/check-deploy-config.sh-362-    if not raw:
phase4-coordinator/dist/check-deploy-config.sh-363-        return None
phase4-coordinator/dist/check-deploy-config.sh-364-    if raw.startswith("env:"):
--
phase4-coordinator/dist/check-deploy-config.sh-445-        ok(f"C2c {label_a} vs {label_b}: distinct")
phase4-coordinator/dist/check-deploy-config.sh-446-
phase4-coordinator/dist/check-deploy-config.sh-447-def _check_pair_equal(label_a, raw_a, proof_a, label_b, raw_b, proof_b, same_file=False):
phase4-coordinator/dist/check-deploy-config.sh-448-    """C2c pairing: assert two fields hold the SAME secret (gateway sends
phase4-coordinator/dist/check-deploy-config.sh:449:    coordinator.service_token on the wire; coordinator accepts only its
phase4-coordinator/dist/check-deploy-config.sh:450:    own auth.gateway_service_token). A mismatch boots green and 401s every
phase4-coordinator/dist/check-deploy-config.sh-451-    /internal/* call.
phase4-coordinator/dist/check-deploy-config.sh-452-
phase4-coordinator/dist/check-deploy-config.sh-453-    same_file defaults to False since the canonical pairing crosses files.
phase4-coordinator/dist/check-deploy-config.sh-454-    For same-file pairings the same-env-NAME shortcut proves equality;
--
phase4-coordinator/dist/check-deploy-config.sh-478-            ok(f"C2c pairing {label_a} == {label_b}: skipped, deferred to runtime "
phase4-coordinator/dist/check-deploy-config.sh-479-               f"(same file; module Validate enforces equality on resolution)")
phase4-coordinator/dist/check-deploy-config.sh-480-            return
phase4-coordinator/dist/check-deploy-config.sh-481-        # Cross-file: NO runtime backstop — neither module's Validate
phase4-coordinator/dist/check-deploy-config.sh:482:        # can see the other's token. Audit-r4 finding (3-of-3 lanes):
phase4-coordinator/dist/check-deploy-config.sh-483-        # any unresolved side here must WARN loudly, not skip silently.
phase4-coordinator/dist/check-deploy-config.sh-484-        # Pairing is the load-bearing /internal/* invariant — an
phase4-coordinator/dist/check-deploy-config.sh-485-        # operator typo in one env file is exactly the failure mode
phase4-coordinator/dist/check-deploy-config.sh-486-        # this gate exists to catch.
--
phase4-coordinator/dist/check-deploy-config.sh-499-             f"To verify: source both /etc/macprovider/coordinator.env and "
phase4-coordinator/dist/check-deploy-config.sh-500-             f"gateway.env into the gate process, inline both sides for "
phase4-coordinator/dist/check-deploy-config.sh-501-             f"the gate to compare, or perform a manual smoke check after "
phase4-coordinator/dist/check-deploy-config.sh-502-             f"deploy (curl /internal/routing with the gateway service "
phase4-coordinator/dist/check-deploy-config.sh:503:             f"token: 401 = mismatch).")
phase4-coordinator/dist/check-deploy-config.sh-504-        return
phase4-coordinator/dist/check-deploy-config.sh-505-    if a != b:
phase4-coordinator/dist/check-deploy-config.sh-506-        hard(f"C2c: {label_a} != {label_b} — cross-component credential pairing is broken")
phase4-coordinator/dist/check-deploy-config.sh-507-    else:
--
phase4-coordinator/dist/check-deploy-config.sh-518-    else:
phase4-coordinator/dist/check-deploy-config.sh-519-        ok(f"C2c {label_a} vs {label_b}: distinct (cross-file proof)")
phase4-coordinator/dist/check-deploy-config.sh-520-
phase4-coordinator/dist/check-deploy-config.sh-521-coord_op = g_section(coord, "auth", "operator_key")
phase4-coordinator/dist/check-deploy-config.sh:522:coord_svc = g_section(coord, "auth", "gateway_service_token")
phase4-coordinator/dist/check-deploy-config.sh-523-# Same-file: both fields are in coordinator.yaml and resolve from
phase4-coordinator/dist/check-deploy-config.sh-524-# coordinator.env, so same env:NAME -> same value at runtime (static fail).
phase4-coordinator/dist/check-deploy-config.sh-525-_check_distinct("coordinator auth.operator_key", coord_op,
phase4-coordinator/dist/check-deploy-config.sh:526:                "coordinator auth.gateway_service_token", coord_svc,
phase4-coordinator/dist/check-deploy-config.sh-527-                same_file=True)
phase4-coordinator/dist/check-deploy-config.sh-528-for operator_name, operator_secret in g_mapping(coord, "auth", "operator_keys").items():
phase4-coordinator/dist/check-deploy-config.sh-529-    _check_distinct(f"coordinator auth.operator_keys.{operator_name}", operator_secret,
phase4-coordinator/dist/check-deploy-config.sh:530:                    "coordinator auth.gateway_service_token", coord_svc,
phase4-coordinator/dist/check-deploy-config.sh-531-                    same_file=True)
phase4-coordinator/dist/check-deploy-config.sh-532-
phase4-coordinator/dist/check-deploy-config.sh-533-if gw:
phase4-coordinator/dist/check-deploy-config.sh-534-    gw_op = g_section(gw, "coordinator", "operator_key")
phase4-coordinator/dist/check-deploy-config.sh:535:    gw_svc = g_section(gw, "coordinator", "service_token")
phase4-coordinator/dist/check-deploy-config.sh-536-    # Same-file: both fields are in gateway.yaml and resolve from
phase4-coordinator/dist/check-deploy-config.sh-537-    # gateway.env, so same env:NAME -> same value at runtime (static fail).
phase4-coordinator/dist/check-deploy-config.sh-538-    _check_distinct("gateway coordinator.operator_key", gw_op,
phase4-coordinator/dist/check-deploy-config.sh:539:                    "gateway coordinator.service_token", gw_svc,
phase4-coordinator/dist/check-deploy-config.sh-540-                    same_file=True)
phase4-coordinator/dist/check-deploy-config.sh-541-    # Cross-file: gateway operator_key (proxied to coordinator for /poolz)
phase4-coordinator/dist/check-deploy-config.sh:542:    # vs coordinator gateway_service_token. Same env:NAME does NOT prove
phase4-coordinator/dist/check-deploy-config.sh-543-    # same value because coord and gw units source separate env files.
phase4-coordinator/dist/check-deploy-config.sh-544-    # Runtime validation cannot compare values sourced from two independent
phase4-coordinator/dist/check-deploy-config.sh-545-    # env files. Require wrapper-provided hashes instead of trusting this
phase4-coordinator/dist/check-deploy-config.sh-546-    # process's ambiguous os.environ or allowing an unverified warning.
phase4-coordinator/dist/check-deploy-config.sh-547-    _check_cross_file_distinct(
phase4-coordinator/dist/check-deploy-config.sh-548-        "gateway coordinator.operator_key", gw_op,
phase4-coordinator/dist/check-deploy-config.sh-549-        "C2C_GATEWAY_OPERATOR_KEY_SHA256",
phase4-coordinator/dist/check-deploy-config.sh:550:        "coordinator auth.gateway_service_token", coord_svc,
phase4-coordinator/dist/check-deploy-config.sh-551-        "C2C_COORD_SERVICE_TOKEN_SHA256")
phase4-coordinator/dist/check-deploy-config.sh-552-    # C2c operator pairing: gateway polls /poolz with its
phase4-coordinator/dist/check-deploy-config.sh-553-    # coordinator.operator_key, while coordinator /poolz remains
phase4-coordinator/dist/check-deploy-config.sh-554-    # operator-only and accepts auth.operator_key. A mismatch does not
phase4-coordinator/dist/check-deploy-config.sh:555:    # affect /internal/* service-token routing, but it breaks the gateway
phase4-coordinator/dist/check-deploy-config.sh-556-    # status/poolz path after deploy.
phase4-coordinator/dist/check-deploy-config.sh-557-    _check_pair_equal(
phase4-coordinator/dist/check-deploy-config.sh-558-        "gateway coordinator.operator_key", gw_op,
phase4-coordinator/dist/check-deploy-config.sh-559-        "C2C_GATEWAY_OPERATOR_KEY_SHA256",
phase4-coordinator/dist/check-deploy-config.sh-560-        "coordinator auth.operator_key", coord_op,
phase4-coordinator/dist/check-deploy-config.sh-561-        "C2C_COORD_OPERATOR_KEY_SHA256",
phase4-coordinator/dist/check-deploy-config.sh-562-        same_file=False)
phase4-coordinator/dist/check-deploy-config.sh:563:    # C2c pairing: gateway sends coordinator.service_token on /internal/*;
phase4-coordinator/dist/check-deploy-config.sh:564:    # coordinator accepts ONLY its own auth.gateway_service_token. Cross-file
phase4-coordinator/dist/check-deploy-config.sh-565-    # by definition. Same env:NAME on both sides DOES NOT prove pairing
phase4-coordinator/dist/check-deploy-config.sh-566-    # (separate env files). Mismatches are detectable only when both
phase4-coordinator/dist/check-deploy-config.sh-567-    # values are proven by service-specific digests; unresolved proof is a
phase4-coordinator/dist/check-deploy-config.sh-568-    # hard failure because pairing is the load-bearing /internal/* invariant.
phase4-coordinator/dist/check-deploy-config.sh:569:    _check_pair_equal("gateway coordinator.service_token", gw_svc,
phase4-coordinator/dist/check-deploy-config.sh-570-                      "C2C_GATEWAY_SERVICE_TOKEN_SHA256",
phase4-coordinator/dist/check-deploy-config.sh:571:                      "coordinator auth.gateway_service_token", coord_svc,
phase4-coordinator/dist/check-deploy-config.sh-572-                      "C2C_COORD_SERVICE_TOKEN_SHA256",
phase4-coordinator/dist/check-deploy-config.sh-573-                      same_file=False)
phase4-coordinator/dist/check-deploy-config.sh-574-
phase4-coordinator/dist/check-deploy-config.sh:575:# --- require_provider_tokens ---
phase4-coordinator/dist/check-deploy-config.sh-576-# Security-sensitive: the binary default is `true` (fail-closed), but a
phase4-coordinator/dist/check-deploy-config.sh:577:# pre-existing fleet without issued provider tokens needs `false` to keep
phase4-coordinator/dist/check-deploy-config.sh-578-# connecting. Silent-defaulting on this field caused the 2026-06-11 outage
phase4-coordinator/dist/check-deploy-config.sh-579-# (deployed a config without the field; new binary defaulted true; air5/air8gb
phase4-coordinator/dist/check-deploy-config.sh:580:# rejected with close_code:4005 reason:invalid_token). Force an explicit choice.
phase4-coordinator/dist/check-deploy-config.sh:581:rpt = g_section(coord, "auth", "require_provider_tokens")
phase4-coordinator/dist/check-deploy-config.sh-582-if rpt is None:
phase4-coordinator/dist/check-deploy-config.sh:583:    hard("auth.require_provider_tokens is ABSENT — binary default (true) "
phase4-coordinator/dist/check-deploy-config.sh:584:         "will reject any provider not presenting a token. "
phase4-coordinator/dist/check-deploy-config.sh:585:         "Set explicitly to true (production / tokens issued) or false (legacy fleet).")
phase4-coordinator/dist/check-deploy-config.sh-586-elif rpt.lower() == "false":
phase4-coordinator/dist/check-deploy-config.sh:587:    warn("auth.require_provider_tokens=false — provider WS is unauthenticated; "
phase4-coordinator/dist/check-deploy-config.sh:588:         "intended only for legacy providers without issued tokens. Plan token migration.")
phase4-coordinator/dist/check-deploy-config.sh-589-elif rpt.lower() == "true":
phase4-coordinator/dist/check-deploy-config.sh:590:    ok("auth.require_provider_tokens=true (fail-closed)")
phase4-coordinator/dist/check-deploy-config.sh-591-else:
phase4-coordinator/dist/check-deploy-config.sh:592:    hard(f"auth.require_provider_tokens must be true or false, got: {rpt!r}")
phase4-coordinator/dist/check-deploy-config.sh-593-
phase4-coordinator/dist/check-deploy-config.sh:594:# --- allow_tokenless_provisional_bootstrap ---
phase4-coordinator/dist/check-deploy-config.sh:595:# Public provider onboarding needs one narrowly-scoped tokenless path: the
phase4-coordinator/dist/check-deploy-config.sh:596:# first provisional connect can mint and persist its own provider_token, while
phase4-coordinator/dist/check-deploy-config.sh:597:# used-token provider IDs still fail closed via the coordinator TOFU gate. Force
phase4-coordinator/dist/check-deploy-config.sh-598-# an explicit deploy choice so public onboarding is not accidentally bricked by
phase4-coordinator/dist/check-deploy-config.sh-599-# the closed default, and invite-only deployments do not unknowingly open
phase4-coordinator/dist/check-deploy-config.sh-600-# first-claim bootstrap.
phase4-coordinator/dist/check-deploy-config.sh:601:aptb = g_section(coord, "auth", "allow_tokenless_provisional_bootstrap")
phase4-coordinator/dist/check-deploy-config.sh-602-if aptb is None:
phase4-coordinator/dist/check-deploy-config.sh:603:    hard("auth.allow_tokenless_provisional_bootstrap is ABSENT — set explicitly to "
phase4-coordinator/dist/check-deploy-config.sh-604-         "true for public curl-install onboarding or false for invite-only / "
phase4-coordinator/dist/check-deploy-config.sh-605-         "operator-preprovisioned providers.")
phase4-coordinator/dist/check-deploy-config.sh-606-elif aptb.lower() == "true":
phase4-coordinator/dist/check-deploy-config.sh:607:    ok("auth.allow_tokenless_provisional_bootstrap=true (first-install provider token self-bootstrap enabled)")
phase4-coordinator/dist/check-deploy-config.sh-608-elif aptb.lower() == "false":
phase4-coordinator/dist/check-deploy-config.sh:609:    warn("auth.allow_tokenless_provisional_bootstrap=false — clean public installs need a pre-provisioned provider_token.")
phase4-coordinator/dist/check-deploy-config.sh-610-else:
phase4-coordinator/dist/check-deploy-config.sh:611:    hard(f"auth.allow_tokenless_provisional_bootstrap must be true or false, got: {aptb!r}")
phase4-coordinator/dist/check-deploy-config.sh-612-
phase4-coordinator/dist/check-deploy-config.sh-613-# --- B6 fresh registration admission gate ---
phase4-coordinator/dist/check-deploy-config.sh-614-# Fresh provider-id creation must pass the operator-issued referral gate when
phase4-coordinator/dist/check-deploy-config.sh-615-# any self-minting registration surface is enabled. Otherwise a sanctioned
--
phase4-coordinator/internal/tier2/pillar_c.go-26-const (
phase4-coordinator/internal/tier2/pillar_c.go-27-	MaxAttestationTokenBytes    = 16 * 1024
phase4-coordinator/internal/tier2/pillar_c.go-28-	MaxAttestationEnvelopeBytes = MaxAttestationTokenBytes + 4*1024
phase4-coordinator/internal/tier2/pillar_c.go-29-	mockAttestationRoot         = "mock-root"
phase4-coordinator/internal/tier2/pillar_c.go:30:	mockAttestationToken        = "mock-devicecheck-token"
phase4-coordinator/internal/tier2/pillar_c.go-31-)
phase4-coordinator/internal/tier2/pillar_c.go-32-
phase4-coordinator/internal/tier2/pillar_c.go-33-var (
phase4-coordinator/internal/tier2/pillar_c.go-34-	mdaOIDSerialNumber                    = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 1}
--
phase4-coordinator/internal/tier2/pillar_c.go-55-)
phase4-coordinator/internal/tier2/pillar_c.go-56-
phase4-coordinator/internal/tier2/pillar_c.go-57-type AttestationToken struct {
phase4-coordinator/internal/tier2/pillar_c.go-58-	Format           string                 `json:"format"`
phase4-coordinator/internal/tier2/pillar_c.go:59:	Token            string                 `json:"token"`
phase4-coordinator/internal/tier2/pillar_c.go-60-	Challenge        string                 `json:"challenge"`
phase4-coordinator/internal/tier2/pillar_c.go-61-	IssuedAt         time.Time              `json:"issued_at"`
phase4-coordinator/internal/tier2/pillar_c.go-62-	ExpiresAt        time.Time              `json:"expires_at"`
phase4-coordinator/internal/tier2/pillar_c.go-63-	ProviderID       string                 `json:"provider_id"`
--
phase4-coordinator/internal/tier2/pillar_c.go-123-	})
phase4-coordinator/internal/tier2/pillar_c.go-124-	return AttestationVerifyResult{Status: status, SEResult: seResult, MDAHardware: mdaHardware}
phase4-coordinator/internal/tier2/pillar_c.go-125-}
phase4-coordinator/internal/tier2/pillar_c.go-126-
phase4-coordinator/internal/tier2/pillar_c.go:127:// VerifyAttestationToken verifies an attestation token and returns the status.
phase4-coordinator/internal/tier2/pillar_c.go-128-// Use VerifyAttestationTokenExt when the caller needs format-specific results.
phase4-coordinator/internal/tier2/pillar_c.go-129-func VerifyAttestationToken(raw json.RawMessage, cfg config.Tier2Config, challenge []byte, authAttemptID, providerID, providerECDHPublicKey string, now time.Time, logger zerolog.Logger) pool.AttestationStatus {
phase4-coordinator/internal/tier2/pillar_c.go-130-	status, _, _ := verifyAttestationTokenInternal(raw, cfg, challenge, authAttemptID, providerID, providerECDHPublicKey, nil, now, logger, attestationModelHashCheck{})
phase4-coordinator/internal/tier2/pillar_c.go-131-	return status
--
phase4-coordinator/internal/tier2/pillar_c.go-136-		return pool.AttestationStatusNotRequired, nil, false
phase4-coordinator/internal/tier2/pillar_c.go-137-	}
phase4-coordinator/internal/tier2/pillar_c.go-138-	if len(raw) == 0 || string(raw) == "null" {
phase4-coordinator/internal/tier2/pillar_c.go-139-		if cfg.RequireAttestation {
phase4-coordinator/internal/tier2/pillar_c.go:140:			logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "missing_token", "tier2.require_attestation")
phase4-coordinator/internal/tier2/pillar_c.go-141-			return pool.AttestationStatusFailed, nil, false
phase4-coordinator/internal/tier2/pillar_c.go-142-		}
phase4-coordinator/internal/tier2/pillar_c.go:143:		// A missing token is a capability absence, not an unsupported token
phase4-coordinator/internal/tier2/pillar_c.go-144-		// format. When attestation is optional, report the policy decision
phase4-coordinator/internal/tier2/pillar_c.go-145-		// explicitly so clients do not treat the accepted session as an
phase4-coordinator/internal/tier2/pillar_c.go-146-		// attestation failure during autoupdate eligibility checks.
phase4-coordinator/internal/tier2/pillar_c.go-147-		return pool.AttestationStatusNotRequired, nil, false
phase4-coordinator/internal/tier2/pillar_c.go-148-	}
phase4-coordinator/internal/tier2/pillar_c.go-149-	if len(raw) > MaxAttestationEnvelopeBytes {
phase4-coordinator/internal/tier2/pillar_c.go:150:		logAttestationEvent(logger, "attestation_token_too_large", "WARN", providerID, "reject", "token_too_large", "tier2.attestation_max_age_s")
phase4-coordinator/internal/tier2/pillar_c.go-151-		return pool.AttestationStatusFailed, nil, false
phase4-coordinator/internal/tier2/pillar_c.go-152-	}
phase4-coordinator/internal/tier2/pillar_c.go:153:	var token AttestationToken
phase4-coordinator/internal/tier2/pillar_c.go:154:	if err := json.Unmarshal(raw, &token); err != nil {
phase4-coordinator/internal/tier2/pillar_c.go-155-		logAttestationEvent(logger, "attestation_failed", "WARN", providerID, "reject", "invalid_json", "tier2.require_attestation")
phase4-coordinator/internal/tier2/pillar_c.go-156-		return pool.AttestationStatusFailed, nil, false

exec
/bin/bash -lc "rg -n -C 8 \"provider_tokens\" phase4-coordinator -g '*.go' -g '*.sql' -g '*.md' | head -220; find phase4-coordinator -maxdepth 3 -type f | rg 'migration|schema|bootstrap' | head -100" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/tools/spec032canary/main.go-1268-
phase4-coordinator/tools/spec032canary/main.go-1269-func (r *runner) activeTokenCount(providerID string) (int, error) {
phase4-coordinator/tools/spec032canary/main.go-1270-	db, err := sql.Open("sqlite", r.sqliteDB)
phase4-coordinator/tools/spec032canary/main.go-1271-	if err != nil {
phase4-coordinator/tools/spec032canary/main.go-1272-		return 0, err
phase4-coordinator/tools/spec032canary/main.go-1273-	}
phase4-coordinator/tools/spec032canary/main.go-1274-	defer db.Close()
phase4-coordinator/tools/spec032canary/main.go-1275-	var n int
phase4-coordinator/tools/spec032canary/main.go:1276:	if err := db.QueryRow(`SELECT COUNT(1) FROM provider_tokens WHERE provider_id = ? AND revoked_at IS NULL`, providerID).Scan(&n); err != nil {
phase4-coordinator/tools/spec032canary/main.go-1277-		return 0, err
phase4-coordinator/tools/spec032canary/main.go-1278-	}
phase4-coordinator/tools/spec032canary/main.go-1279-	return n, nil
phase4-coordinator/tools/spec032canary/main.go-1280-}
phase4-coordinator/tools/spec032canary/main.go-1281-
phase4-coordinator/tools/spec032canary/main.go-1282-func (r *runner) signalCoordinator(sig syscall.Signal) error {
phase4-coordinator/tools/spec032canary/main.go-1283-	if r.coordCmd == nil || r.coordCmd.Process == nil {
phase4-coordinator/tools/spec032canary/main.go-1284-		return errors.New("coordinator not running")
--
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-111-    sqlite_lrc_id BIGINT,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-112-    provider_credits BIGINT NOT NULL,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-113-    settlement_policy_mode TEXT NOT NULL CHECK (settlement_policy_mode = 'enforce'),
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-114-    source TEXT NOT NULL DEFAULT 'stats_billing_mirror',
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-115-    mirrored_at TIMESTAMPTZ NOT NULL DEFAULT now(),
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-116-    PRIMARY KEY (request_id, attempt_n, provider_id)
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-117-);
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-118-
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:119:CREATE TABLE IF NOT EXISTS provider_tokens (
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-120-    id BIGSERIAL PRIMARY KEY,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-121-    token_hash TEXT NOT NULL UNIQUE,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-122-    token_prefix TEXT NOT NULL DEFAULT '',
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-123-    provider_id TEXT NOT NULL DEFAULT '',
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-124-    provider_name TEXT NOT NULL DEFAULT '',
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-125-    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-126-    revoked_at TIMESTAMPTZ,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-127-    last_used_at TIMESTAMPTZ
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-128-);
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:129:ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS token_prefix TEXT DEFAULT '';
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:130:ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS provider_id TEXT DEFAULT '';
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:131:ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS provider_name TEXT DEFAULT '';
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:132:ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now();
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:133:ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:134:ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:135:CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_tokens_one_active_per_provider
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:136:    ON provider_tokens(provider_id)
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-137-    WHERE revoked_at IS NULL AND provider_id <> '';
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-138-
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-139-CREATE TABLE IF NOT EXISTS stats_billing_mirror_state (
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-140-    source TEXT PRIMARY KEY,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-141-    last_request_credit_id BIGINT NOT NULL DEFAULT 0,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-142-    sweep_after_request_credit_id BIGINT NOT NULL DEFAULT 0,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-143-    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-144-);
--
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-180-    p_created_at TIMESTAMPTZ,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-181-    p_last_used_at TIMESTAMPTZ
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-182-)
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-183-RETURNS void
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-184-LANGUAGE sql
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-185-SECURITY DEFINER
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-186-SET search_path = public
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-187-AS $$
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:188:    INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-189-    SELECT p_token_hash, 'stats-mirror', p_provider_id, p_provider_name, p_created_at, p_last_used_at
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-190-    WHERE NOT EXISTS (
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:191:        SELECT 1 FROM provider_tokens WHERE provider_id = p_provider_id AND provider_id <> ''
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-192-    )
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-193-    ON CONFLICT (token_hash) DO UPDATE SET
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-194-        provider_id = EXCLUDED.provider_id,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-195-        provider_name = EXCLUDED.provider_name,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-196-        last_used_at = EXCLUDED.last_used_at;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-197-$$;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-198-
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-199-CREATE OR REPLACE FUNCTION stats_billing_mirror_upsert_request_credit(
--
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-292-
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-293-DO $$
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-294-BEGIN
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-295-    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-296-        RAISE EXCEPTION 'create role stats_billing_mirror_writer with an operator-generated password before applying this bootstrap';
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-297-    END IF;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-298-    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_rollup') THEN
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-299-        GRANT SELECT ON ledger_request_credits TO stats_rollup;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:300:        GRANT SELECT ON provider_tokens TO stats_rollup;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-301-    END IF;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-302-    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rewards_writer') THEN
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-303-        GRANT SELECT ON ledger_request_credits TO rewards_writer;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-304-    END IF;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-305-END $$;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-306-
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-307-GRANT USAGE ON SCHEMA public TO stats_billing_mirror_writer;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-308-REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:309:REVOKE ALL ON provider_tokens FROM stats_billing_mirror_writer;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-310-REVOKE ALL ON stats_billing_mirror_state FROM stats_billing_mirror_writer;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-311-REVOKE ALL ON ledger_request_credit_spec022_verified_audit FROM stats_billing_mirror_writer;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-312-REVOKE ALL ON FUNCTION stats_billing_mirror_load_state(TEXT) FROM PUBLIC;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-313-REVOKE ALL ON FUNCTION stats_billing_mirror_save_state(TEXT, BIGINT, BIGINT) FROM PUBLIC;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-314-REVOKE ALL ON FUNCTION stats_billing_mirror_ensure_provider(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-315-REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN, BOOLEAN) FROM PUBLIC;
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-316-
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql-317-DO $$
--
phase4-coordinator/internal/onboarding/apptrack.go-109-// Handler wires SPEC-026 §4.1 dependencies. The coordinator keeps the durable
phase4-coordinator/internal/onboarding/apptrack.go-110-// store and referral recovery dependencies populated even when the public
phase4-coordinator/internal/onboarding/apptrack.go-111-// App-track registration route is disabled.
phase4-coordinator/internal/onboarding/apptrack.go-112-type Handler struct {
phase4-coordinator/internal/onboarding/apptrack.go-113-	// Postgres stats DB — for provider_identities, provider_auth_policy,
phase4-coordinator/internal/onboarding/apptrack.go-114-	// nonce replay cache, App Attest key uniqueness.
phase4-coordinator/internal/onboarding/apptrack.go-115-	StatsDB StatsDB
phase4-coordinator/internal/onboarding/apptrack.go-116-
phase4-coordinator/internal/onboarding/apptrack.go:117:	// SQLite auth DB — for provider_tokens mint. Reuses existing
phase4-coordinator/internal/onboarding/apptrack.go-118-	// phase4-coordinator/internal/auth store.
phase4-coordinator/internal/onboarding/apptrack.go-119-	AuthTokenStore AuthTokenStore
phase4-coordinator/internal/onboarding/apptrack.go-120-	ReferralStore  ReferralStore
phase4-coordinator/internal/onboarding/apptrack.go-121-	ReferralPolicy auth.ReferralPolicy
phase4-coordinator/internal/onboarding/apptrack.go-122-
phase4-coordinator/internal/onboarding/apptrack.go-123-	// Coordinator config
phase4-coordinator/internal/onboarding/apptrack.go-124-	CoordinatorDomain string
phase4-coordinator/internal/onboarding/apptrack.go-125-	CoordinatorWSURL  string
--
phase4-coordinator/internal/onboarding/apptrack.go-246-}
phase4-coordinator/internal/onboarding/apptrack.go-247-
phase4-coordinator/internal/onboarding/apptrack.go-248-// Sentinel errors surfaced by StatsDB / AuthTokenStore. The HTTP handler
phase4-coordinator/internal/onboarding/apptrack.go-249-// maps each to the right status per SPEC-026 §4.1.
phase4-coordinator/internal/onboarding/apptrack.go-250-var (
phase4-coordinator/internal/onboarding/apptrack.go-251-	ErrTOFUConflict             = errors.New("provider_id already registered with a different identity_pubkey")
phase4-coordinator/internal/onboarding/apptrack.go-252-	ErrNonceReplay              = errors.New("(provider_id, nonce) replay")
phase4-coordinator/internal/onboarding/apptrack.go-253-	ErrAttestKeyReused          = errors.New("app_attest_key_id already bound to a different provider_id")
phase4-coordinator/internal/onboarding/apptrack.go:254:	ErrProviderIDPubkeyMismatch = errors.New("provider_tokens row exists for a different identity_pubkey")
phase4-coordinator/internal/onboarding/apptrack.go-255-	ErrExistingTokenNoProof     = errors.New("existing active token requires current_token_proof")
phase4-coordinator/internal/onboarding/apptrack.go-256-	ErrAppAttestBinding         = errors.New("app attest binding failure")
phase4-coordinator/internal/onboarding/apptrack.go-257-	ErrAppAttestTransient       = errors.New("app attest transient verification failure")
phase4-coordinator/internal/onboarding/apptrack.go-258-)
phase4-coordinator/internal/onboarding/apptrack.go-259-
phase4-coordinator/internal/onboarding/apptrack.go-260-const hardwareProfilePersistTimeout = 2 * time.Second
phase4-coordinator/internal/onboarding/apptrack.go-261-const hardwareProfilePersistConcurrency = 2
phase4-coordinator/internal/onboarding/apptrack.go-262-const committedRetryConcurrency = 4
--
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-397-	a, b := in.usage.BillableInputTokens, in.usage.BillableOutputTokens
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-398-	h := billing.HotPathInput{RequestID: in.requestID, AttemptN: int(in.attemptN), ProviderAssignedID: "journey", ProviderID: in.providerID, Model: in.route.ModelID, Status: 200, TSUtc: time.UnixMilli(in.terminalMS).UTC(), PromptTokens: &a, CompletionTokens: &b, FaultFlag: "none", RateEntry: billing.RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 1000000}, MultiplierPPM: 1000000, ProviderShareBps: 10000, SettlementAccountScopeHash: billing.SettlementAccountScopeHash(in.accountScope), SettlementPolicyMode: in.route.RouteSnapshotMode, SettlementPolicyVersion: in.route.RouteSnapshotPolicyVersion}
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-399-	r := requestlog.Row{TSUtc: h.TSUtc, RequestID: h.RequestID, Model: h.Model, ProviderAssignedID: h.ProviderAssignedID, PromptTokens: h.PromptTokens, CompletionTokens: h.CompletionTokens, Status: h.Status, BuyerIP: "127.0.0.1"}
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-400-	if err := store.WriteHotPath(context.Background(), req, r, h); err != nil {
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-401-		t.Fatal(err)
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-402-	}
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-403-}
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-404-func seedJourneyMirrorIdentity(t *testing.T, db *sql.DB, provider string) {
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go:405:	_, err := db.Exec(`CREATE TABLE provider_tokens (id INTEGER PRIMARY KEY,token_hash TEXT NOT NULL UNIQUE,token_prefix TEXT NOT NULL,provider_id TEXT NOT NULL,provider_name TEXT NOT NULL,created_at TEXT NOT NULL,revoked_at TEXT,last_used_at TEXT); INSERT INTO provider_tokens VALUES (1,'journey-token','journey',?,'Journey','2026-01-01T00:00:00Z',NULL,NULL)`, provider)
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-406-	if err != nil {
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-407-		t.Fatal(err)
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-408-	}
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-409-}
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-410-func runJourneyMirror(t *testing.T, ctx context.Context, path, dsn string) {
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-411-	if _, err := billingmirror.Run(ctx, billingmirror.Options{SQLitePath: path, PostgresDSN: dsn, BatchSize: 10, OverlapRows: 10, SweepRows: 10, MaxBatches: 1, EnsureSchema: true}); err != nil {
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-412-		t.Fatal(err)
phase4-coordinator/internal/rewards/useful_work_journey_integration_test.go-413-	}
--
phase4-coordinator/internal/explorer/store.go-529-	return out, rows.Err()
phase4-coordinator/internal/explorer/store.go-530-}
phase4-coordinator/internal/explorer/store.go-531-
phase4-coordinator/internal/explorer/store.go-532-func tokenStatus(ctx context.Context, q ReadDB, providerID string) (map[string]any, error) {
phase4-coordinator/internal/explorer/store.go-533-	var prefix string
phase4-coordinator/internal/explorer/store.go-534-	var revoked sql.NullString
phase4-coordinator/internal/explorer/store.go-535-	err := q.QueryRowContext(ctx, `
phase4-coordinator/internal/explorer/store.go-536-		SELECT token_prefix, revoked_at
phase4-coordinator/internal/explorer/store.go:537:		FROM provider_tokens
phase4-coordinator/internal/explorer/store.go-538-		WHERE provider_id = ? AND provider_id != ''
phase4-coordinator/internal/explorer/store.go-539-		ORDER BY id DESC
phase4-coordinator/internal/explorer/store.go-540-		LIMIT 1`, providerID).Scan(&prefix, &revoked)
phase4-coordinator/internal/explorer/store.go-541-	if err == sql.ErrNoRows {
phase4-coordinator/internal/explorer/store.go-542-		return map[string]any{"status": "missing", "token_prefix": ""}, nil
phase4-coordinator/internal/explorer/store.go-543-	}
phase4-coordinator/internal/explorer/store.go-544-	if err != nil {
phase4-coordinator/internal/explorer/store.go-545-		return nil, err
--
phase4-coordinator/cmd/coordinator-cli/main.go-449-	if t, err := time.Parse(time.RFC3339, s); err == nil {
phase4-coordinator/cmd/coordinator-cli/main.go-450-		return t.UTC(), nil
phase4-coordinator/cmd/coordinator-cli/main.go-451-	}
phase4-coordinator/cmd/coordinator-cli/main.go-452-	return time.Time{}, fmt.Errorf("expected duration (e.g. 168h) or RFC3339 timestamp")
phase4-coordinator/cmd/coordinator-cli/main.go-453-}
phase4-coordinator/cmd/coordinator-cli/main.go-454-
phase4-coordinator/cmd/coordinator-cli/main.go-455-// preFlipAudit is the SPEC-003 FR-C9.4 executable runbook gate (#82 item 3).
phase4-coordinator/cmd/coordinator-cli/main.go-456-// Operators MUST run this before flipping RequireProviderTokens=true to ensure
phase4-coordinator/cmd/coordinator-cli/main.go:457:// every active provider_tokens row has a `last_used_at` no older than
phase4-coordinator/cmd/coordinator-cli/main.go-458-// --max-last-used-age. A row with last_used_at IS NULL is ALWAYS treated as
phase4-coordinator/cmd/coordinator-cli/main.go-459-// stale — it means no provider has ever authenticated with Bearer using that
phase4-coordinator/cmd/coordinator-cli/main.go-460-// token, so flipping the flag would brick that provider.
phase4-coordinator/cmd/coordinator-cli/main.go-461-//
phase4-coordinator/cmd/coordinator-cli/main.go-462-// Exit codes:
phase4-coordinator/cmd/coordinator-cli/main.go-463-//
phase4-coordinator/cmd/coordinator-cli/main.go-464-//	0 — no stale active rows; safe to flip RequireProviderTokens=true
phase4-coordinator/cmd/coordinator-cli/main.go-465-//	1 — at least one stale active row; refuse to flip
--
phase4-coordinator/internal/ws/compute_integrity_status.go-69-
phase4-coordinator/internal/ws/compute_integrity_status.go-70-func (s *Server) handleProviderComputeIntegrity(w http.ResponseWriter, r *http.Request) {
phase4-coordinator/internal/ws/compute_integrity_status.go-71-	if r.Method != http.MethodGet {
phase4-coordinator/internal/ws/compute_integrity_status.go-72-		w.Header().Set("Allow", http.MethodGet)
phase4-coordinator/internal/ws/compute_integrity_status.go-73-		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
phase4-coordinator/internal/ws/compute_integrity_status.go-74-		return
phase4-coordinator/internal/ws/compute_integrity_status.go-75-	}
phase4-coordinator/internal/ws/compute_integrity_status.go-76-	if !s.cfg.Auth.RequireProviderTokens {
phase4-coordinator/internal/ws/compute_integrity_status.go:77:		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "provider tokens not enabled", "code": "provider_tokens_not_enabled"}})
phase4-coordinator/internal/ws/compute_integrity_status.go-78-		return
phase4-coordinator/internal/ws/compute_integrity_status.go-79-	}
phase4-coordinator/internal/ws/compute_integrity_status.go-80-	if s.tokens == nil {
phase4-coordinator/internal/ws/compute_integrity_status.go:81:		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "provider tokens unavailable", "code": "provider_tokens_unavailable"}})
phase4-coordinator/internal/ws/compute_integrity_status.go-82-		return
phase4-coordinator/internal/ws/compute_integrity_status.go-83-	}
phase4-coordinator/internal/ws/compute_integrity_status.go-84-	if s.computeIntegrityStatus == nil {
phase4-coordinator/internal/ws/compute_integrity_status.go-85-		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "compute-integrity status unavailable", "code": "compute_integrity_status_unavailable"}})
phase4-coordinator/internal/ws/compute_integrity_status.go-86-		return
phase4-coordinator/internal/ws/compute_integrity_status.go-87-	}
phase4-coordinator/internal/ws/compute_integrity_status.go-88-	raw := bearerToken(r.Header.Get("Authorization"))
phase4-coordinator/internal/ws/compute_integrity_status.go-89-	if raw == "" {
phase4-coordinator/internal/ws/compute_integrity_status.go-90-		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "provider bearer token required", "code": "unauthorized"}})
phase4-coordinator/internal/ws/compute_integrity_status.go-91-		return
phase4-coordinator/internal/ws/compute_integrity_status.go-92-	}
phase4-coordinator/internal/ws/compute_integrity_status.go-93-	readOnlyTokens, ok := s.tokens.(computeIntegrityReadOnlyTokenValidator)
phase4-coordinator/internal/ws/compute_integrity_status.go-94-	if !ok {
phase4-coordinator/internal/ws/compute_integrity_status.go:95:		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "provider token read-only validation unavailable", "code": "provider_tokens_read_only_unavailable"}})
phase4-coordinator/internal/ws/compute_integrity_status.go-96-		return
phase4-coordinator/internal/ws/compute_integrity_status.go-97-	}
phase4-coordinator/dist/hardware-trust-roles-bootstrap.sql
phase4-coordinator/dist/test/coord_deploy_tier2_migration_gate.test.sh
phase4-coordinator/dist/test/c2_timer_config_migration_test.sh
phase4-coordinator/dist/test/autotune_rate_card_config_migration_test.sh
phase4-coordinator/dist/stats-hardware-verifier-bootstrap.sql
phase4-coordinator/dist/autotune-rate-card-config-migration.py
phase4-coordinator/dist/provider-auth-policy-roles-bootstrap.sql
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql
phase4-coordinator/dist/c2-timer-config-migration.py
phase4-coordinator/internal/payout/bootstrap.go
phase4-coordinator/internal/payout/migrations.go
phase4-coordinator/internal/payout/migrations_test.go
phase4-coordinator/internal/payout/bootstrap_test.go
phase4-coordinator/internal/ws/bootstrap_limiter.go
phase4-coordinator/internal/ws/bootstrap_limiter_test.go
phase4-coordinator/internal/ws/identity_migration_test.go

exec
/bin/bash -lc "nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '2980,3185p'; nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '3580,3660p'; nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '4810,4905p'; nl -ba phase4-coordinator/dist/coordinator-deploy-recover.sh | sed -n '115,155p;210,240p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
  2980	      while IFS='=' read -r key expected; do
  2981	        key="$(printf '%s' "$key" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  2982	        expected="$(printf '%s' "$expected" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  2983	        [ -n "$key" ] || continue
  2984	        [ "${key:0:1}" = "#" ] && continue
  2985	        expect_sysctl "$key" "$expected" || return 1
  2986	      done < "$tmp_conf"
  2987	      return 0
  2988	    }
  2989	
  2990	    if [ -f /etc/sysctl.d/99-macprovider-tcp.conf ] &&
  2991	       [ -f /etc/modules-load.d/tcp_bbr.conf ] &&
  2992	       cmp -s "$tmp_conf" /etc/sysctl.d/99-macprovider-tcp.conf &&
  2993	       cmp -s "$tmp_modules_load" /etc/modules-load.d/tcp_bbr.conf &&
  2994	       all_tcp_sysctls_applied >/dev/null 2>&1; then
  2995	      echo "already"
  2996	      exit 0
  2997	    fi
  2998	
  2999	    install -m 0644 -o root -g root "$tmp_conf" "$dst"
  3000	    # modules-load.d ensures tcp_bbr is loaded before systemd-sysctl at boot.
  3001	    install -m 0644 -o root -g root "$tmp_modules_load" "$modules_load_dst"
  3002	    if ! sysctl -p "$dst" >/dev/null; then
  3003	      echo "ABORT: failed to apply $dst" >&2
  3004	      fail_tcp_tuning_partial_apply
  3005	    fi
  3006	
  3007	    if ! all_tcp_sysctls_applied; then
  3008	      fail_tcp_tuning_partial_apply
  3009	    fi
  3010	    if ! expect_sysctl net.ipv4.tcp_congestion_control bbr; then
  3011	      fail_tcp_tuning_partial_apply
  3012	    fi
  3013	    echo "applied"
  3014	REMOTE_TCP_SYSCTL
  3015	  )
  3016	  case "$TCP_SYSCTL_RESULT" in
  3017	    already)
  3018	      log "  TCP sysctl overrides — already applied"
  3019	      ;;
  3020	    applied)
  3021	      log "  TCP sysctl overrides applied: bbr + slow_start_after_idle=0 + 16MB buffers"
  3022	      ;;
  3023	    *)
  3024	      echo "unexpected TCP sysctl deploy result: $TCP_SYSCTL_RESULT" >&2
  3025	      exit 10
  3026	      ;;
  3027	  esac
  3028	fi
  3029	
  3030	BACKUP_TS=$(date -u +%Y%m%dT%H%M%SZ)
  3031	log "step 4/9: upload binary + config + nginx site (with rollback snapshot)"
  3032	# Arm one coordinator release transaction before replacing any live file. The
  3033	# late connected-provider safeguard can still refuse the restart after upload;
  3034	# in that case the EXIT trap restores every release artifact touched after this
  3035	# boundary: coordinator/CLI/sidecar binaries, unit files and enablement links,
  3036	# nginx files, request-log ACLs, config, and catalog pointers.
  3037	$SSH "set -e
  3038	  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  3039	  flock -s 8
  3040	  _rollback=/opt/macprovider/.coordinator-deploy-rollback
  3041	  _rollback_stage=\$_rollback.stage.\$\$
  3042	  umask 077
  3043	  if [ -e \"\$_rollback\" ] || [ -L \"\$_rollback\" ]; then
  3044	    echo 'coordinator deploy transaction already exists; refusing to overwrite it' >&2
  3045	    exit 1
  3046	  fi
  3047	  $(_tier2_migration_gate_remote_script)
  3048	  rm -rf \"\$_rollback_stage\"
  3049	  mkdir \"\$_rollback_stage\"
  3050	  trap 'rm -rf \"\$_rollback_stage\"' EXIT HUP INT TERM
  3051	  chown root:root \"\$_rollback_stage\"
  3052	  chmod 0700 \"\$_rollback_stage\"
  3053	  snapshot_node() {
  3054	    _source=\"\$1\"
  3055	    _snapshot=\"\$2\"
  3056	    _marker=\"\$3\"
  3057	    if [ -e \"\$_source\" ] || [ -L \"\$_source\" ]; then
  3058	      if [ ! -f \"\$_source\" ] && [ ! -L \"\$_source\" ]; then
  3059	        echo \"unsafe rollback source: \$_source\" >&2
  3060	        exit 1
  3061	      fi
  3062	      cp -a \"\$_source\" \"\$_rollback_stage/\$_snapshot\"
  3063	      touch \"\$_rollback_stage/\$_marker\"
  3064	    fi
  3065	  }
  3066	  snapshot_active() {
  3067	    if systemctl is-active --quiet \"\$1\"; then
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
  3083	    touch \"\$_rollback_stage/had-coordinator\"
  3084	  fi
  3085	  snapshot_node /opt/macprovider/coordinator-cli coordinator-cli had-coordinator-cli
  3086	  snapshot_node /opt/macprovider/coordinator.yaml.prev coordinator.yaml.prev had-config-prev
  3087	  printf '%s' 'coordinator.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/config-backup-name\"
  3088	  snapshot_node /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS coordinator-dated-backup had-config-dated-backup
  3089	  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml coordinator.pearl-overlays.yaml had-overlay
  3090	  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.prev coordinator.pearl-overlays.yaml.prev had-overlay-prev
  3091	  printf '%s' 'coordinator.pearl-overlays.yaml.bak-$BACKUP_TS' > \"\$_rollback_stage/overlay-config-backup-name\"
  3092	  snapshot_node /etc/macprovider/coordinator.pearl-overlays.yaml.bak-$BACKUP_TS coordinator-overlay-dated-backup had-overlay-dated-backup
  3093	  snapshot_node /opt/macprovider-stats/stats-inventory-sync stats-inventory-sync had-stats-inventory-binary
  3094	  snapshot_node /opt/macprovider-stats/stats-billing-mirror stats-billing-mirror had-stats-billing-binary
  3095	  snapshot_node /opt/macprovider-stats/stats-hardware-verifier stats-hardware-verifier had-stats-hardware-binary
  3096	  if [ -f /opt/macprovider/coordinator.yaml ]; then
  3097	    cp -p /opt/macprovider/coordinator.yaml \"\$_rollback_stage/coordinator.yaml\"
  3098	    touch \"\$_rollback_stage/had-config\"
  3099	  fi
  3100	  if [ -L /opt/macprovider/tier2-catalog.json ] || { [ -e /opt/macprovider/tier2-catalog.json ] && [ ! -f /opt/macprovider/tier2-catalog.json ]; }; then
  3101	    echo 'unsafe existing Tier-2 catalog path' >&2
  3102	    exit 1
  3103	  fi
  3104	  if [ -f /opt/macprovider/tier2-catalog.json ]; then
  3105	    cp -p /opt/macprovider/tier2-catalog.json \"\$_rollback_stage/tier2-catalog.json\"
  3106	    touch \"\$_rollback_stage/had-tier2-catalog\"
  3107	  fi
  3108	  if [ -e /etc/systemd/system/macprovider-coordinator.service ] || [ -L /etc/systemd/system/macprovider-coordinator.service ]; then
  3109	    cp -a /etc/systemd/system/macprovider-coordinator.service \"\$_rollback_stage/macprovider-coordinator.service\"
  3110	    touch \"\$_rollback_stage/had-service-unit\"
  3111	  fi
  3112	  snapshot_node /etc/systemd/system/stats-inventory-sync.service stats-inventory-sync.service had-stats-inventory-service
  3113	  snapshot_node /etc/systemd/system/stats-inventory-sync.timer stats-inventory-sync.timer had-stats-inventory-timer
  3114	  snapshot_node /etc/systemd/system/stats-billing-mirror.service stats-billing-mirror.service had-stats-billing-service
  3115	  snapshot_node /etc/systemd/system/stats-billing-mirror.timer stats-billing-mirror.timer had-stats-billing-timer
  3116	  snapshot_node /etc/systemd/system/stats-hardware-verifier.service stats-hardware-verifier.service had-stats-hardware-service
  3117	  snapshot_node /etc/systemd/system/stats-hardware-verifier.timer stats-hardware-verifier.timer had-stats-hardware-timer
  3118	  snapshot_node /etc/systemd/system/timers.target.wants/stats-inventory-sync.timer stats-inventory-sync.wants had-stats-inventory-wants
  3119	  snapshot_node /etc/systemd/system/timers.target.wants/stats-billing-mirror.timer stats-billing-mirror.wants had-stats-billing-wants
  3120	  snapshot_node /etc/systemd/system/timers.target.wants/stats-hardware-verifier.timer stats-hardware-verifier.wants had-stats-hardware-wants
  3121	  snapshot_active stats-inventory-sync.timer stats-inventory-timer-was-active
  3122	  snapshot_active stats-inventory-sync.service stats-inventory-service-was-active
  3123	  snapshot_active stats-billing-mirror.timer stats-billing-timer-was-active
  3124	  snapshot_active stats-billing-mirror.service stats-billing-service-was-active
  3125	  snapshot_active stats-hardware-verifier.timer stats-hardware-timer-was-active
  3126	  snapshot_active stats-hardware-verifier.service stats-hardware-service-was-active
  3127	
  3128	  snapshot_node /etc/nginx/conf.d/stats-shared.conf stats-shared.conf had-nginx-stats-shared
  3129	  snapshot_node /etc/nginx/conf.d/stats-security-headers.conf stats-security-headers.conf had-nginx-stats-security-headers
  3130	  snapshot_node /etc/nginx/conf.d/cors-429.conf cors-429.conf had-nginx-stats-cors-429
  3131	  snapshot_node /etc/nginx/conf.d/stats-proxy-public.conf stats-proxy-public.conf had-nginx-stats-proxy-public
  3132	  snapshot_node /etc/nginx/conf.d/stats-proxy-partner.conf stats-proxy-partner.conf had-nginx-stats-proxy-partner
  3133	  snapshot_node /etc/nginx/sites-available/$DOMAIN nginx-coordinator.site had-nginx-coordinator-site
  3134	  snapshot_node /etc/nginx/sites-available/$STATS_DOMAIN nginx-stats.site had-nginx-stats-site
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
  3148	  fi
  3149	  if [ -e /opt/macprovider/coordinator-deploy-recover ] || [ -L /opt/macprovider/coordinator-deploy-recover ]; then
  3150	    cp -a /opt/macprovider/coordinator-deploy-recover \"\$_rollback_stage/coordinator-deploy-recover\"
  3151	    touch \"\$_rollback_stage/had-recovery-helper\"
  3152	  fi
  3153	  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-recovery.service ]; then
  3154	    cp -a /etc/systemd/system/macprovider-coordinator-deploy-recovery.service \"\$_rollback_stage/macprovider-coordinator-deploy-recovery.service\"
  3155	    touch \"\$_rollback_stage/had-recovery-unit\"
  3156	  fi
  3157	  if [ -e /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ] || [ -L /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service ]; then
  3158	    cp -a /etc/systemd/system/macprovider-coordinator-deploy-watchdog.service \"\$_rollback_stage/macprovider-coordinator-deploy-watchdog.service\"
  3159	    touch \"\$_rollback_stage/had-watchdog-unit\"
  3160	  fi
  3161	  if [ -e /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ] || [ -L /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf ]; then
  3162	    cp -a /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf \"\$_rollback_stage/10-deploy-transaction-guard.conf\"
  3163	    touch \"\$_rollback_stage/had-guard-dropin\"
  3164	  fi
  3165	  _catalog_target=\$(readlink /opt/macprovider/autotune/current 2>/dev/null || true)
  3166	  case \"\$_catalog_target\" in
  3167	    ''|releases/*) ;;
  3168	    *) echo \"invalid existing autotune current target: \$_catalog_target\" >&2; exit 1 ;;
  3169	  esac
  3170	  printf '%s' \"\$_catalog_target\" > \"\$_rollback_stage/catalog-current-target\"
  3171	  if [ -f /opt/macprovider/autotune/.previous-target ]; then
  3172	    cp -p /opt/macprovider/autotune/.previous-target \"\$_rollback_stage/catalog-previous-target\"
  3173	    touch \"\$_rollback_stage/had-previous-target\"
  3174	  fi
  3175	  if [ ! -d /opt/macprovider/autotune/releases/$AUTOTUNE_RELEASE_DIR_NAME ]; then
  3176	    touch \"\$_rollback_stage/release-was-absent\"
  3177	  fi
  3178	  printf '%s' '$AUTOTUNE_RELEASE_DIR_NAME' > \"\$_rollback_stage/release-id\"
  3179	  if systemctl is-active --quiet macprovider-coordinator; then
  3180	    touch \"\$_rollback_stage/service-was-active\"
  3181	  fi
  3182	  touch \"\$_rollback_stage/complete\"
  3183	  mv \"\$_rollback_stage\" \"\$_rollback\"
  3184	  trap - EXIT HUP INT TERM"
  3185	COORDINATOR_DEPLOY_ARMED=1
  3580	  fi
  3581	  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync
  3582	  # stats-billing-mirror is an out-of-band stats sidecar. It runs as the
  3583	  # dedicated macprovider-stats identity and gets read access only to the
  3584	  # SQLite ledger files via file ACLs below.
  3585	  if [ ! -x /opt/macprovider-stats/stats-billing-mirror ] ||
  3586	     ! cmp -s $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror; then
  3587	    echo "refusing stats-billing-mirror replacement from direct deploy: install the signed matching stats sidecar release first" >&2
  3588	    exit 1
  3589	  fi
  3590	  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror
  3591	  # stats-hardware-verifier is an out-of-band stats sidecar. It promotes
  3592	  # queued autotune evidence after conservative verification.
  3593	  if [ ! -x /opt/macprovider-stats/stats-hardware-verifier ] ||
  3594	     ! cmp -s $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier; then
  3595	    echo "refusing stats-hardware-verifier replacement from direct deploy: install the signed matching stats sidecar release first" >&2
  3596	    exit 1
  3597	  fi
  3598	  install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-hardware-verifier-linux-amd64 /opt/macprovider-stats/stats-hardware-verifier
  3599	  if [ '$CONFIG_MODE' = 'apply-tracked' ]; then
  3600	    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.yaml /opt/macprovider/coordinator.yaml
  3601	  elif [ '${RATE_CARD_CONFIG_MIGRATION_ACTIVE:-0}' = '1' ]; then
  3602	    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.rate-card-migration.yaml /opt/macprovider/coordinator.yaml
  3603	  elif [ '$C2_TIMER_CONFIG_MIGRATION' = '1' ]; then
  3604	    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.c2-timer-migration.yaml /opt/macprovider/coordinator.yaml
  3605	  else
  3606	    echo '  preserving live /opt/macprovider/coordinator.yaml'
  3607	  fi
  3608	  if [ '${RATE_CARD_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
  3609	    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.rate-card-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  3610	  elif [ '${C2_TIMER_MIGRATION_OVERLAY_ACTIVE:-0}' = '1' ]; then
  3611	    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.c2-timer-migration.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  3612	  fi
  3613	  install -d -o root -g macprovider -m 0750 /etc/macprovider
  3614	  if [ -e /etc/macprovider/coordinator.pearl-overlays.yaml ] && [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
  3615	    echo 'refusing unsafe coordinator overlay path: /etc/macprovider/coordinator.pearl-overlays.yaml' >&2
  3616	    exit 1
  3617	  fi
  3618	  if [ ! -f /etc/macprovider/coordinator.pearl-overlays.yaml ]; then
  3619	    printf '{}\n' > $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml
  3620	    install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.pearl-overlays.empty.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
  3621	  fi
  3622	  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
  3623	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service
  3624	  install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer
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
  3644	  _autotune_release=\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME
  3645	  _autotune_lock=\$_autotune_release.lock
  3646	  _autotune_stage=\$_autotune_root/releases/.stage-$AUTOTUNE_RELEASE_DIR_NAME-\$\$
  3647	  install -d -o root -g macprovider -m 0750 \$_autotune_root \$_autotune_root/releases
  3648	  if ! mkdir \$_autotune_lock; then
  3649	    echo 'catalog release staging is already in progress for $AUTOTUNE_RELEASE_ID' >&2
  3650	    exit 1
  3651	  fi
  3652	  trap 'rm -rf \"\$_autotune_stage\"; rmdir \"\$_autotune_lock\" 2>/dev/null || true' EXIT
  3653	  rm -rf \$_autotune_stage
  3654	  install -d -o root -g macprovider -m 0750 \$_autotune_stage
  3655	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json \$_autotune_stage/demand-rank.json
  3656	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/demand-rank.json.sig \$_autotune_stage/demand-rank.json.sig
  3657	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json \$_autotune_stage/autotune-candidates.json
  3658	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/autotune-candidates.json.sig \$_autotune_stage/autotune-candidates.json.sig
  3659	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json \$_autotune_stage/rate-card.json
  3660	  install -o root -g macprovider -m 0640 $DEPLOY_TMP/rate-card.json.sig \$_autotune_stage/rate-card.json.sig$AUTOTUNE_ARTIFACT_INSTALL_LINES
  4810	$SSH 'journalctl -u macprovider-coordinator --no-pager -n 20'
  4811	
  4812	$SSH 'set -e
  4813	  exec 8>/opt/macprovider/.coordinator-deploy-operation.lock
  4814	  flock -s 8
  4815	  # Sidecars remain frozen until every coordinator/catalog/canary check has
  4816	  # passed. Activate them as the final transaction mutation, immediately
  4817	  # before the commit marker.
  4818	  _sidecar_prior=/opt/macprovider/.coordinator-deploy-sidecar-prior-state
  4819	  if [ ! -r "$_sidecar_prior" ]; then
  4820	    echo "aborting deploy: missing stats-inventory prior state at final activation" >&2
  4821	    exit 13
  4822	  fi
  4823	  assert_stats_inventory_quiescent() {
  4824	    _timer_enabled=$(systemctl is-enabled stats-inventory-sync.timer 2>/dev/null || true)
  4825	    _timer_active=$(systemctl is-active stats-inventory-sync.timer 2>/dev/null || true)
  4826	    _service_active=$(systemctl is-active stats-inventory-sync.service 2>/dev/null || true)
  4827	    if [ "$_timer_enabled" != disabled ] ||
  4828	       [ "$_timer_active" != inactive ]; then
  4829	      echo "aborting deploy: stats-inventory timer did not remain disabled/inactive after parity hold (enabled=$_timer_enabled active=$_timer_active)" >&2
  4830	      exit 13
  4831	    fi
  4832	    case "$_service_active" in
  4833	      inactive|failed) ;;
  4834	      *)
  4835	        echo "aborting deploy: stats-inventory service did not remain quiescent after parity hold (active=$_service_active)" >&2
  4836	        exit 13
  4837	        ;;
  4838	    esac
  4839	  }
  4840	  _parity_required=$(sed -n "s/^parity_required=//p" "$_sidecar_prior")
  4841	  case "$_parity_required" in
  4842	    present)
  4843	      systemctl disable --now stats-inventory-sync.timer
  4844	      systemctl stop stats-inventory-sync.service
  4845	      assert_stats_inventory_quiescent
  4846	      touch /opt/macprovider/.coordinator-deploy-sidecar-parity-required
  4847	      echo "stats inventory timer remains disabled: pre-existing schema/binary parity marker requires a matching sidecar promotion"
  4848	      ;;
  4849	    absent) ;;
  4850	    *)
  4851	      echo "aborting deploy: invalid stats-inventory parity state at final activation" >&2
  4852	      exit 13
  4853	      ;;
  4854	  esac
  4855	  if [ "$_parity_required" = absent ] && [ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ] && [ -f /etc/macprovider-stats/stats-inventory-sync.env ]; then
  4856	    systemctl enable --now stats-inventory-sync.timer
  4857	    if ! systemctl start stats-inventory-sync.service; then
  4858	      systemctl disable --now stats-inventory-sync.timer
  4859	      systemctl stop stats-inventory-sync.service
  4860	      assert_stats_inventory_quiescent
  4861	      echo "warning: stats-inventory-sync.service failed; leaving coordinator deploy running with its parity marker and timer disabled"
  4862	      journalctl -u stats-inventory-sync.service -n 30 --no-pager || true
  4863	    else
  4864	      rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required
  4865	      systemctl is-active stats-inventory-sync.timer
  4866	    fi
  4867	  elif [ "$_parity_required" = absent ] && [ -f /opt/macprovider/.coordinator-deploy-rollback/stats-inventory-timer-was-active ]; then
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
  4889	    systemctl enable --now stats-hardware-verifier.timer
  4890	    # FIX 7 (issue #582): when hardware-trust approval is enabled (both onboarding
  4891	    # trust DSNs configured), the verifier is the only thing that promotes an
  4892	    # approved waiting_trust job to verified. A failed INITIAL run must fail the
  4893	    # deploy (fatal) rather than be a warning, or operators could commit approvals
  4894	    # against a coordinator whose verifier never runs. When approval is NOT enabled
  4895	    # the initial run stays best-effort (warn), matching prior behavior.
  4896	    hardware_trust_approval_enabled=0
  4897	    if [ -r /etc/macprovider/coordinator.env ] \
  4898	       && grep -Eq "^[[:space:]]*ONBOARDING_HARDWARE_TRUST_REQUEST_DSN=" /etc/macprovider/coordinator.env \
  4899	       && grep -Eq "^[[:space:]]*ONBOARDING_HARDWARE_TRUST_APPROVE_DSN=" /etc/macprovider/coordinator.env; then
  4900	      hardware_trust_approval_enabled=1
  4901	    fi
  4902	    if ! systemctl start stats-hardware-verifier.service; then
  4903	      journalctl -u stats-hardware-verifier.service -n 30 --no-pager || true
  4904	      if [ "$hardware_trust_approval_enabled" = 1 ]; then
  4905	        echo "aborting deploy: stats-hardware-verifier.service failed its initial run and hardware-trust approval is enabled; operator approvals would commit trust roots that never promote to verified" >&2
   115	    cp -p "$ROLLBACK/$snapshot" "$destination"
   116	  else
   117	    rm -f "$destination"
   118	  fi
   119	}
   120	
   121	restore_link_or_file() {
   122	  marker=$1
   123	  snapshot=$2
   124	  destination=$3
   125	  rm -f "$destination"
   126	  if [ -f "$ROLLBACK/$marker" ]; then
   127	    [ -e "$ROLLBACK/$snapshot" ] || [ -L "$ROLLBACK/$snapshot" ] || {
   128	      echo "rollback snapshot missing $snapshot" >&2
   129	      exit 1
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
   149	  active_marker=$2
   150	  if [ -f "$ROLLBACK/$active_marker" ]; then
   151	    "$SYSTEMCTL" start "$unit_name"
   152	  else
   153	    "$SYSTEMCTL" stop "$unit_name" 2>/dev/null || true
   154	    if "$SYSTEMCTL" is-active --quiet "$unit_name"; then
   155	      echo "$unit_name remained active after rollback stop" >&2
   210	restore_link_or_file had-stats-billing-service stats-billing-mirror.service "$SYSTEMD_ROOT/stats-billing-mirror.service"
   211	restore_link_or_file had-stats-billing-timer stats-billing-mirror.timer "$SYSTEMD_ROOT/stats-billing-mirror.timer"
   212	restore_link_or_file had-stats-hardware-service stats-hardware-verifier.service "$SYSTEMD_ROOT/stats-hardware-verifier.service"
   213	restore_link_or_file had-stats-hardware-timer stats-hardware-verifier.timer "$SYSTEMD_ROOT/stats-hardware-verifier.timer"
   214	restore_link_or_file had-stats-inventory-wants stats-inventory-sync.wants "$TIMERS_WANTS/stats-inventory-sync.timer"
   215	restore_link_or_file had-stats-billing-wants stats-billing-mirror.wants "$TIMERS_WANTS/stats-billing-mirror.timer"
   216	restore_link_or_file had-stats-hardware-wants stats-hardware-verifier.wants "$TIMERS_WANTS/stats-hardware-verifier.timer"
   217	
   218	restore_link_or_file had-nginx-stats-shared stats-shared.conf "$NGINX_ROOT/conf.d/stats-shared.conf"
   219	restore_link_or_file had-nginx-stats-security-headers stats-security-headers.conf "$NGINX_ROOT/conf.d/stats-security-headers.conf"
   220	restore_link_or_file had-nginx-stats-cors-429 cors-429.conf "$NGINX_ROOT/conf.d/cors-429.conf"
   221	restore_link_or_file had-nginx-stats-proxy-public stats-proxy-public.conf "$NGINX_ROOT/conf.d/stats-proxy-public.conf"
   222	restore_link_or_file had-nginx-stats-proxy-partner stats-proxy-partner.conf "$NGINX_ROOT/conf.d/stats-proxy-partner.conf"
   223	restore_link_or_file had-nginx-coordinator-site nginx-coordinator.site "$NGINX_ROOT/sites-available/coordinator.malibu.tech"
   224	restore_link_or_file had-nginx-stats-site nginx-stats.site "$NGINX_ROOT/sites-available/stats.malibu.tech"
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
   237	    mkdir -p "$CATALOG_ROOT"
   238	    if [ -e "$CATALOG_ROOT/current" ] && [ ! -L "$CATALOG_ROOT/current" ]; then
   239	      echo "unsafe non-symlink catalog current path" >&2
   240	      exit 1

codex
Static review found one concrete security/runtime defect to validate: the updated unit both grants read-only access to `coordinator.db` and still marks that same path inaccessible. I’m checking the existing wiring tests and billing-mirror package tests now, while also verifying the ACL rollback and DB access paths from source.
exec
/bin/bash -lc 'go test ./internal/stats/billingmirror' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh' in /Users/augstar/macprovider-mirror-dbpath
exec
/bin/bash -lc 'bash phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 212ms:
ok  	github.com/augstar/macprovider-coordinator/internal/stats/billingmirror	(cached)

 succeeded in 280ms:
ok: stats billing mirror deploy wiring

 succeeded in 2962ms:
/var/folders/dr/s790cqgx6dx_55127wsgnkw00000gn/T/tmp.iRL5oAeyI8: line 1: 92613 Alarm clock: 14         python3 -c '
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

exec
/bin/bash -lc "rg -n \"OpenSQLite|ReadOnlyDSN|query_only|DefaultSQLitePath|sqlite path|coordinator\\.db\" phase4-coordinator/internal/stats/billingmirror/*_test.go phase4-coordinator/internal/sqliteutil/*_test.go phase4-coordinator/cmd/stats-billing-mirror -g '*.go' && git diff --check HEAD"'^ HEAD && git diff --name-status origin/main...HEAD && git status --short' in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 26ms:
?? audits/2026-09-25-stats-mirror-db-path/

exec
/bin/bash -lc "nl -ba phase4-coordinator/internal/stats/billingmirror/mirror.go | sed -n '95,235p'; nl -ba phase4-coordinator/internal/sqliteutil/dsn.go | sed -n '45,90p'; nl -ba phase4-coordinator/dist/stats-billing-mirror.service | sed -n '9,32p'; nl -ba phase4-coordinator/dist/deploy-pearl-vps.sh | sed -n '3138,3145p;3629,3640p;4871,4888p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
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
   121					return Result{}, err
   122				}
   123			}
   124			state, err = LoadState(ctx, pg)
   125			if err != nil {
   126				return Result{}, err
   127			}
   128		}
   129	
   130		maxSourceID, err := FetchMaxRequestCreditID(ctx, source)
   131		if err != nil {
   132			return Result{}, err
   133		}
   134		newRows := make([]RequestCredit, 0, opts.BatchSize)
   135		newCursor := state.LastRequestID
   136		for batch := 0; batch < opts.MaxBatches; batch++ {
   137			batchRows, err := FetchRequestCredits(ctx, source, newCursor, opts.BatchSize)
   138			if err != nil {
   139				return Result{}, err
   140			}
   141			if len(batchRows) == 0 {
   142				break
   143			}
   144			newRows = append(newRows, batchRows...)
   145			newCursor = maxSQLiteID(batchRows, newCursor)
   146			if len(batchRows) < opts.BatchSize {
   147				break
   148			}
   149		}
   150		nextLastRequestID := maxSQLiteID(newRows, state.LastRequestID)
   151		rows := newRows
   152		if state.LastRequestID > 0 && opts.OverlapRows > 0 {
   153			startID := state.LastRequestID - opts.OverlapRows
   154			if startID < 0 {
   155				startID = 0
   156			}
   157			overlapRows, err := FetchRequestCreditsThrough(ctx, source, startID, state.LastRequestID, minInt(opts.BatchSize, int(opts.OverlapRows)))
   158			if err != nil {
   159				return Result{}, err
   160			}
   161			rows = mergeRequestCredits(overlapRows, rows)
   162		}
   163		nextSweepAfterID := state.SweepAfterID
   164		if opts.SweepRows > 0 && maxSourceID > 0 {
   165			sweepStart := state.SweepAfterID
   166			if sweepStart >= maxSourceID {
   167				sweepStart = 0
   168			}
   169			sweepRows, err := FetchRequestCreditsThrough(ctx, source, sweepStart, maxSourceID, opts.SweepRows)
   170			if err != nil {
   171				return Result{}, err
   172			}
   173			rows = mergeRequestCredits(rows, sweepRows)
   174			nextSweepAfterID = maxSQLiteID(sweepRows, sweepStart)
   175			if nextSweepAfterID >= maxSourceID {
   176				nextSweepAfterID = 0
   177			}
   178		}
   179		providers, err := FetchProviderIdentities(ctx, source)
   180		if err != nil {
   181			return Result{}, err
   182		}
   183		result := Result{
   184			RequestRowsRead:  len(rows),
   185			ProviderRowsRead: len(providers),
   186			DryRun:           opts.DryRun,
   187			LastRequestID:    nextLastRequestID,
   188			SweepAfterID:     nextSweepAfterID,
   189			SourceMaxID:      maxSourceID,
   190		}
   191		if maxSourceID > result.LastRequestID {
   192			result.PendingRequestRows = maxSourceID - result.LastRequestID
   193		}
   194		if opts.DryRun {
   195			fmt.Fprintf(out, "would upsert %d request credit rows and ensure %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsRead, result.ProviderRowsRead, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
   196			return result, nil
   197		}
   198	
   199		if err := Apply(ctx, pg, rows, providers, State{LastRequestID: result.LastRequestID, SweepAfterID: result.SweepAfterID}); err != nil {
   200			return Result{}, err
   201		}
   202		result.RequestRowsUpserted = len(rows)
   203		result.ProviderRowsEnsured = len(providers)
   204		fmt.Fprintf(out, "upserted %d request credit rows and ensured %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsUpserted, result.ProviderRowsEnsured, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
   205		return result, nil
   206	}
   207	
   208	func normalizeOptions(opts Options) Options {
   209		opts.SQLitePath = strings.TrimSpace(opts.SQLitePath)
   210		if opts.SQLitePath == "" {
   211			opts.SQLitePath = strings.TrimSpace(os.Getenv("STATS_BILLING_MIRROR_SQLITE"))
   212		}
   213		if opts.SQLitePath == "" {
   214			opts.SQLitePath = DefaultSQLitePath
   215		}
   216		opts.PostgresDSN = strings.TrimSpace(opts.PostgresDSN)
   217		if opts.PostgresDSN == "" {
   218			opts.PostgresDSN = strings.TrimSpace(os.Getenv("STATS_BILLING_MIRROR_DSN"))
   219		}
   220		if opts.BatchSize <= 0 {
   221			opts.BatchSize = DefaultBatchSize
   222		}
   223		if opts.BatchSize > 50000 {
   224			opts.BatchSize = 50000
   225		}
   226		if opts.MaxBatches <= 0 {
   227			opts.MaxBatches = 5
   228		}
   229		if opts.MaxBatches > 20 {
   230			opts.MaxBatches = 20
   231		}
   232		if opts.OverlapRows < 0 {
   233			opts.OverlapRows = 0
   234		}
   235		if opts.OverlapRows == 0 {
    45	func WithManualWALCheckpointPragmas(path string) string {
    46		base := WithPragmas(path)
    47		values := url.Values{}
    48		values.Add("_pragma", "wal_autocheckpoint(0)")
    49		separator := "?"
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
    28	InaccessiblePaths=-/var/lib/macprovider/coordinator.db
  3138	
  3139	  if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
  3140	    snapshot_acl /var/lib/macprovider request-log-dir.acl had-request-log-dir-acl
  3141	    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
  3142	    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
  3143	    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
  3144	  fi
  3145	  if [ -e /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ] || [ -L /etc/systemd/system/multi-user.target.wants/macprovider-coordinator.service ]; then
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

exec
/bin/bash -lc "rg -n \"CREATE TABLE.*(secret|token|key|credential|password)|token_hash|operator_key|gateway_service_token|api_key|private_key|secret\" phase4-coordinator/internal phase4-coordinator/dist -g '*.go' -g '*.sql' | head -320" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:119:CREATE TABLE IF NOT EXISTS provider_tokens (
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:121:    token_hash TEXT NOT NULL UNIQUE,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:177:    p_token_hash TEXT,
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:188:    INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:189:    SELECT p_token_hash, 'stats-mirror', p_provider_id, p_provider_name, p_created_at, p_last_used_at
phase4-coordinator/dist/stats-billing-mirror-bootstrap.sql:193:    ON CONFLICT (token_hash) DO UPDATE SET
phase4-coordinator/internal/config/config_env_test.go:12:// auth.operator_key resolves at Load time against the process
phase4-coordinator/internal/config/config_env_test.go:20:  operator_key: env:M3_2_TEST_OPERATOR_KEY
phase4-coordinator/internal/config/config_env_test.go:21:  gateway_service_token: env:M3_2_TEST_GATEWAY_TOKEN_DEFAULT
phase4-coordinator/internal/config/config_env_test.go:37:  operator_key: env:M3_2_TEST_MISSING
phase4-coordinator/internal/config/config_env_test.go:48:// gateway_service_token field on the same env:NAME pathway.
phase4-coordinator/internal/config/config_env_test.go:51:	t.Setenv("M3_2_TEST_GATEWAY_TOKEN", "gateway-secret")
phase4-coordinator/internal/config/config_env_test.go:55:  operator_key: env:M3_2_TEST_OPERATOR_KEY
phase4-coordinator/internal/config/config_env_test.go:56:  gateway_service_token: env:M3_2_TEST_GATEWAY_TOKEN
phase4-coordinator/internal/config/config_env_test.go:61:	if cfg.Auth.GatewayServiceToken != "gateway-secret" {
phase4-coordinator/internal/config/config_env_test.go:78:  operator_key: env:S4R1_TEST_OP_KEY
phase4-coordinator/internal/config/config_env_test.go:79:  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_env_test.go:127:  operator_key: env:M3_2_TEST_OPERATOR_KEY
phase4-coordinator/internal/config/config_env_test.go:128:  gateway_service_token: env:M3_2_TEST_BLANK_GATEWAY_TOKEN
phase4-coordinator/internal/config/config_env_test.go:130:	if err == nil || !strings.Contains(err.Error(), "gateway_service_token must be set") {
phase4-coordinator/internal/config/config_env_test.go:147:  operator_key: env:M3_2_TEST_OPERATOR_KEY
phase4-coordinator/internal/config/config_env_test.go:148:  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_env_test.go:174:  operator_key: env:M3_2_TEST_OPERATOR_KEY
phase4-coordinator/internal/config/config_env_test.go:197:	t.Setenv("GATEWAY_SERVICE_TOKEN", "gateway-secret")
phase4-coordinator/internal/config/config_env_test.go:270:  operator_key: env:M3_2_TEST_OPERATOR_KEY
phase4-coordinator/internal/config/config_env_test.go:271:  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_env_test.go:272:  operator_keys:
phase4-coordinator/internal/config/config_env_test.go:279:	if !strings.Contains(err.Error(), "auth.operator_keys.alice") || !strings.Contains(err.Error(), "placeholder_denied") {
phase4-coordinator/internal/config/config_env_test.go:285:// Validate() (defaults + a non-empty operator_key) and Loads it.
phase4-coordinator/internal/config/config_env_test.go:308:// payout.enabled=false so registration-only can use secret indirection.
phase4-coordinator/internal/config/config_env_test.go:315:  operator_key: env:S954_TEST_OP_KEY
phase4-coordinator/internal/config/config_env_test.go:316:  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_env_test.go:335:	t.Setenv("PHASE3_TEST_MDM_TOKEN", "micromdm-secret-token")
phase4-coordinator/internal/config/config_env_test.go:339:  operator_key: env:PHASE3_TEST_OP_KEY
phase4-coordinator/internal/config/config_env_test.go:340:  gateway_service_token: env:PHASE3_TEST_GW_TOKEN
phase4-coordinator/internal/config/config_env_test.go:347:	if cfg.Tier2.MDM.APIToken != "micromdm-secret-token" {
phase4-coordinator/internal/config/config_env_test.go:348:		t.Fatalf("APIToken=%q want resolved micromdm-secret-token", cfg.Tier2.MDM.APIToken)
phase4-coordinator/internal/config/config_env_test.go:359:  operator_key: env:PHASE3_TEST_OP_KEY2
phase4-coordinator/internal/config/config_env_test.go:360:  gateway_service_token: env:PHASE3_TEST_GW_TOKEN2
phase4-coordinator/internal/config/config_env_test.go:382:  operator_key: env:PHASE3_TEST_OP_KEY3
phase4-coordinator/internal/config/config_env_test.go:383:  gateway_service_token: env:PHASE3_TEST_GW_TOKEN3
phase4-coordinator/internal/config/config_env_test.go:398:	t.Setenv("PHASE3_TEST_MDM_TOKEN4", "micromdm-secret-token")
phase4-coordinator/internal/config/config_env_test.go:402:  operator_key: env:PHASE3_TEST_OP_KEY4
phase4-coordinator/internal/config/config_env_test.go:403:  gateway_service_token: env:PHASE3_TEST_GW_TOKEN4
phase4-coordinator/internal/config/config_test.go:157:	cfg.Referrals.XAPIBearerToken = "secret"
phase4-coordinator/internal/config/config_test.go:169:	cfg.Referrals.JoinBaseURL = "https://user:secret@malibu.tech/j"
phase4-coordinator/internal/config/config_test.go:192:		"https://user:secret@access.example.test/waitlist",
phase4-coordinator/internal/config/config_test.go:384:			if err == nil || !strings.Contains(err.Error(), "must differ from auth.operator_key") {
phase4-coordinator/internal/config/config_test.go:395:	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "gateway_service_token must be set") {
phase4-coordinator/internal/config/config_test.go:403:	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "auth.operator_keys.alice") {
phase4-coordinator/internal/config/config_test.go:446:			_, err := loadConfigFromYAML(t, "auth:\n  operator_key: "+tc.key+"\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\n")
phase4-coordinator/internal/config/config_test.go:460:  operator_key: 0123456789abcdefABCDEFghijklmnop
phase4-coordinator/internal/config/config_test.go:461:  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_test.go:483:  operator_key: 0123456789abcdefABCDEFghijklmnop
phase4-coordinator/internal/config/config_test.go:484:  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_test.go:485:  operator_keys:
phase4-coordinator/internal/config/config_test.go:492:			if !strings.Contains(err.Error(), "auth.operator_keys.alice") || !strings.Contains(err.Error(), tc.want) {
phase4-coordinator/internal/config/config_test.go:493:				t.Fatalf("error=%v want field auth.operator_keys.alice and %q", err, tc.want)
phase4-coordinator/internal/config/config_test.go:803:			want: "auth.operator_key",
phase4-coordinator/internal/config/config_test.go:810:			want: "auth.gateway_service_token",
phase4-coordinator/internal/config/config_test.go:815:				cfg.Auth.OperatorKeys = map[string]string{"alice": "named-operator-secret"}
phase4-coordinator/internal/config/config_test.go:816:				cfg.TrustedPools.CreatorAdminCredentials = []TrustedPoolsCreatorAdminCredentialConfig{trustedPoolsCreatorCredentialConfig("creator-a", "creator-a-cred", "named-operator-secret")}
phase4-coordinator/internal/config/config_test.go:818:			want: "auth.operator_keys.alice",
phase4-coordinator/internal/config/config_test.go:831:			want: "must not reuse secret",
phase4-coordinator/internal/config/config_test.go:896:  operator_key: 0123456789abcdefABCDEFghijklmnop
phase4-coordinator/internal/config/config_test.go:897:  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_test.go:1584:	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "auth.operator_keys") {
phase4-coordinator/internal/config/config_test.go:1588:	cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
phase4-coordinator/internal/config/config_test.go:1590:		t.Fatalf("enabled with required secrets should validate: %v", err)
phase4-coordinator/internal/config/config_test.go:1594:	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "auth.operator_key") {
phase4-coordinator/internal/config/config_test.go:1595:		t.Fatalf("enabled without operator_key err=%v", err)
phase4-coordinator/internal/config/config_test.go:1612:	cfg.Auth.OperatorKeys = map[string]string{"alice": "same-secret", "bob": "same-secret"}
phase4-coordinator/internal/config/config_test.go:1613:	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "must not reuse secret") {
phase4-coordinator/internal/config/config_test.go:1614:		t.Fatalf("duplicate operator secret err=%v", err)
phase4-coordinator/internal/config/config_test.go:1622:	cfg.Auth.OperatorKeys = map[string]string{"alice": "same-secret", "bob": "same-secret"}
phase4-coordinator/internal/config/config_test.go:1627:	cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret"}
phase4-coordinator/internal/config/config_test.go:1691:	if err := os.WriteFile(basePath, []byte("auth:\n  operator_key: test-operator-key-with-32-byte-minimum-length\n  gateway_service_token: test-gateway-token-with-32-byte-minimum-length\npool:\n  canary_enabled: false\n"), 0o644); err != nil {
phase4-coordinator/internal/config/config_test.go:1721:	if err := os.WriteFile(basePath, []byte("auth:\n  operator_key: test-operator-key-with-32-byte-minimum-length\n  gateway_service_token: test-gateway-token-with-32-byte-minimum-length\n"), 0o644); err != nil {
phase4-coordinator/internal/config/config_payout_reload_test.go:100:  operator_key: env:PAYOUT_RELOAD_TEST_OP_KEY
phase4-coordinator/internal/config/config_payout_reload_test.go:101:  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/config_payout_reload_test.go:144:  operator_key: env:PAYOUT_RELOAD_TEST_OP_KEY
phase4-coordinator/internal/config/config_payout_reload_test.go:145:  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA
phase4-coordinator/internal/config/proof_of_weights_test.go:43:	cfg.Auth.OperatorKeys = map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
phase4-coordinator/internal/mdm/live_mda_test.go:109:		mdmCfg:   config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
phase4-coordinator/internal/mdm/live_mda_test.go:138:	req.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
phase4-coordinator/internal/mdm/live_mda_test.go:174:	req2.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
phase4-coordinator/internal/mdm/live_mda_test.go:229:		mdmCfg:   config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
phase4-coordinator/internal/mdm/live_mda_test.go:243:	req.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
phase4-coordinator/internal/billing/payout_ready_test.go:37:		`CREATE TABLE IF NOT EXISTS provider_tokens (
phase4-coordinator/internal/billing/payout_ready_test.go:39:    token_hash TEXT NOT NULL UNIQUE,
phase4-coordinator/internal/billing/payout_ready_test.go:97:INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name)
phase4-coordinator/internal/billing/payout_ready_test.go:344:		t.Errorf("actor=%v want %q (principal marker, not the secret)", payload["actor"], payoutReadyActor)
phase4-coordinator/internal/config/config.go:132:	// secrets paths (§4.4 trust-separation requirement); this is
phase4-coordinator/internal/config/config.go:472:// (operator-managed secret hygiene).
phase4-coordinator/internal/config/config.go:561:	// secret it needs); an explicit true without a salt fails startup; an
phase4-coordinator/internal/config/config.go:572:	// PolicySalt is the operator secret under which the published
phase4-coordinator/internal/config/config.go:1128:	// CommandWebhookSecret is an optional shared secret for the MicroMDM
phase4-coordinator/internal/config/config.go:1131:	CommandWebhookSecret string `yaml:"command_webhook_secret"`
phase4-coordinator/internal/config/config.go:1157:	OperatorKey  string            `yaml:"operator_key"`
phase4-coordinator/internal/config/config.go:1158:	OperatorKeys map[string]string `yaml:"operator_keys"`
phase4-coordinator/internal/config/config.go:1163:	// — the legacy operator_key fallback is removed by PR #172 (issue
phase4-coordinator/internal/config/config.go:1169:	GatewayServiceToken string `yaml:"gateway_service_token"`
phase4-coordinator/internal/config/config.go:1216:	ClientSecret        string `yaml:"client_secret"`
phase4-coordinator/internal/config/config.go:2024:	if err := validateOperatorSecretStrength("auth.operator_key", cfg.Auth.OperatorKey); err != nil {
phase4-coordinator/internal/config/config.go:2028:		if err := validateOperatorSecretStrength("auth.operator_keys."+name, key); err != nil {
phase4-coordinator/internal/config/config.go:2040:// resolveEnv expands "env:NAME" sentinels in secret-bearing fields by
phase4-coordinator/internal/config/config.go:2049:// operator_key in places where Validate's "must be set" guard does not
phase4-coordinator/internal/config/config.go:2052:	if v, err := resolveEnvValue("auth.operator_key", c.Auth.OperatorKey); err != nil {
phase4-coordinator/internal/config/config.go:2057:	if v, err := resolveEnvValue("auth.gateway_service_token", c.Auth.GatewayServiceToken); err != nil {
phase4-coordinator/internal/config/config.go:2068:		v, err := resolveEnvValue("auth.operator_keys."+name, raw)
phase4-coordinator/internal/config/config.go:2099:	// webhook secret) so env:MICROMDM_API_TOKEN is not sent as Basic Auth.
phase4-coordinator/internal/config/config.go:2105:	if v, err := resolveEnvValue("tier2.mdm.command_webhook_secret", c.Tier2.MDM.CommandWebhookSecret); err != nil {
phase4-coordinator/internal/config/config.go:2237:	"secret":      {},
phase4-coordinator/internal/config/config.go:2431:		return fmt.Errorf("auth.operator_key must be set")
phase4-coordinator/internal/config/config.go:2434:	// operator_key fallback on /internal/* is gone, so the coordinator
phase4-coordinator/internal/config/config.go:2435:	// MUST have a distinct gateway_service_token or every /internal/*
phase4-coordinator/internal/config/config.go:2439:		return fmt.Errorf("auth.gateway_service_token must be set (post-M3-2 cutover: required for /internal/* gateway auth)")
phase4-coordinator/internal/config/config.go:2447:		return fmt.Errorf("auth.gateway_service_token must differ from auth.operator_key (rotation discipline: equal values — including whitespace-equivalent — defeat the operator-vs-service credential split)")
phase4-coordinator/internal/config/config.go:2451:			return fmt.Errorf("auth.gateway_service_token must differ from auth.operator_keys.%s (service credentials must not grant a named operator identity)", name)
phase4-coordinator/internal/config/config.go:3022:		reserved[token] = "auth.operator_key"
phase4-coordinator/internal/config/config.go:3025:		reserved[token] = "auth.gateway_service_token"
phase4-coordinator/internal/config/config.go:3030:			reserved[token] = "auth.operator_keys." + name
phase4-coordinator/internal/config/config.go:3073:			return fmt.Errorf("%s.token must not reuse secret from %s", field, previous)
phase4-coordinator/internal/config/config.go:3423:	secret := r.HMACKeys[r.CurrentKeyID]
phase4-coordinator/internal/config/config.go:3424:	if len(secret) < 32 {
phase4-coordinator/internal/config/config.go:3615:		// dual_control_unavailable until two distinct actors and secrets exist.
phase4-coordinator/internal/config/config.go:3640:		return fmt.Errorf("auth.operator_key must be set when onboarding.app_track_register_enabled is true")
phase4-coordinator/internal/config/config.go:3696:		return fmt.Errorf("auth.operator_keys must contain at least two operators")
phase4-coordinator/internal/config/config.go:3699:	for actor, secret := range keys {
phase4-coordinator/internal/config/config.go:3702:			return fmt.Errorf("auth.operator_keys contains invalid operator id %q", actor)
phase4-coordinator/internal/config/config.go:3707:				return fmt.Errorf("auth.operator_keys contains invalid operator id %q", actor)
phase4-coordinator/internal/config/config.go:3710:		secret = strings.TrimSpace(secret)
phase4-coordinator/internal/config/config.go:3711:		if secret == "" {
phase4-coordinator/internal/config/config.go:3712:			return fmt.Errorf("auth.operator_keys.%s must be non-empty", actor)
phase4-coordinator/internal/config/config.go:3714:		if previous, ok := seenSecrets[secret]; ok {
phase4-coordinator/internal/config/config.go:3715:			return fmt.Errorf("auth.operator_keys.%s must not reuse secret from auth.operator_keys.%s", actor, previous)
phase4-coordinator/internal/config/config.go:3717:		seenSecrets[secret] = actor
phase4-coordinator/internal/config/config.go:3753:		return fmt.Errorf("auth.operator_key must be set when explorer.enabled is true")
phase4-coordinator/internal/mdm/device_binding_test.go:606:		cfg: cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
phase4-coordinator/internal/mdm/device_binding_test.go:628:		cfg: cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
phase4-coordinator/internal/mdm/device_binding_test.go:646:	req.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
phase4-coordinator/internal/mdm/device_binding_test.go:726:		cfg: cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
phase4-coordinator/internal/mdm/device_binding_test.go:749:	req.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
phase4-coordinator/internal/mdm/device_binding_test.go:898:		cfg: cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
phase4-coordinator/internal/mdm/device_binding_test.go:922:	req.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
phase4-coordinator/internal/mdm/device_binding_test.go:977:		cfg:    cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
phase4-coordinator/internal/mdm/device_binding_test.go:1036:	req.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
phase4-coordinator/internal/tier2/pillar_b_test.go:58:		t.Fatal("short shared secret accepted")
phase4-coordinator/internal/tier2/pillar_b_test.go:92:	plaintext := []byte(`{"model":"model-a","messages":[{"role":"user","content":"secret"}]}`)
phase4-coordinator/internal/tier2/pillar_b_test.go:105:	if bytes.Contains(raw, []byte("secret")) {
phase4-coordinator/internal/requestlog/store.go:267:CREATE TABLE IF NOT EXISTS request_idempotency_keys (
phase4-coordinator/internal/requestlog/store.go:704:CREATE TABLE request_idempotency_keys_v2 (
phase4-coordinator/internal/requestlog/store_test.go:405:CREATE TABLE request_idempotency_keys (
phase4-coordinator/internal/explorer/handlers.go:576:	// operator_key still means DENY (M1-5 / SECU-5).
phase4-coordinator/internal/explorer/handlers.go:580:	h.logBearerAccepted(r, "operator_key")
phase4-coordinator/internal/explorer/handlers.go:662:		"active_api_keys":        valueOrZero(gateway["active_api_keys"]),
phase4-coordinator/internal/billing/endpoints.go:81:// audit on PR #73, HIGH-1, flagged that accepting gateway_service_token
phase4-coordinator/internal/billing/endpoints.go:641:	// operator_key still means DENY (M1-5 / SECU-5).
phase4-coordinator/internal/billing/endpoints.go:655:		Str("key", "operator_key").
phase4-coordinator/internal/github/client.go:38:		"client_secret": clientSecret,
phase4-coordinator/internal/explorer/handlers_test.go:283:insert into provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at)
phase4-coordinator/internal/explorer/handlers_test.go:334:insert into provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at)
phase4-coordinator/internal/explorer/handlers_test.go:367:insert into provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at)
phase4-coordinator/internal/explorer/handlers_test.go:368:values ('secret-token-hash', 'tok_hash', 'provider_hash', 'hash', ?)`, fixedExplorerTime().Format(time.RFC3339Nano)); err != nil {
phase4-coordinator/internal/explorer/handlers_test.go:379:		if strings.Contains(resp.Body.String(), "secret-token-hash") {
phase4-coordinator/internal/explorer/handlers_test.go:496:			Body:       io.NopCloser(strings.NewReader(`{"gateway_health":"ok","capacity_tier":2,"public_api_paused":false,"demo_paused":false,"active_accounts_window":7,"new_accounts_window":3,"active_api_keys":11}`)),
phase4-coordinator/internal/explorer/handlers_test.go:504:	if buyers["active_accounts_window"] != float64(7) || buyers["new_accounts_window"] != float64(3) || buyers["active_api_keys"] != float64(11) {
phase4-coordinator/internal/mdm/live_mda.go:504:// bootstrap with the same webhook secret / loopback gate as command-webhook.
phase4-coordinator/internal/mdm/live_mda.go:570:// Auth: if tier2.mdm.command_webhook_secret is set, require matching
phase4-coordinator/internal/mdm/live_mda.go:728:	secret := strings.TrimSpace(s.mdmCfg.CommandWebhookSecret)
phase4-coordinator/internal/mdm/live_mda.go:729:	if secret != "" {
phase4-coordinator/internal/mdm/live_mda.go:731:		if got == "" || subtle.ConstantTimeCompare([]byte(got), []byte(secret)) != 1 {
phase4-coordinator/internal/referralapi/xapi_test.go:53:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:95:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:103:		if request.Header.Get("Authorization") != "Bearer secret" {
phase4-coordinator/internal/referralapi/xapi_test.go:150:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:170:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:201:	client := mustXClient(t, "secret", "https://malibu.tech/j")
phase4-coordinator/internal/referralapi/xapi_test.go:223:		"https://user:secret@malibu.tech/j",
phase4-coordinator/internal/referralapi/xapi_test.go:233:		if _, err := NewXAPIClient("secret", raw); err == nil {
phase4-coordinator/internal/ws/server_test.go:4639:		return tier2.PillarBKeyMaterial{}, fmt.Errorf("derive rekey shared secret: %w", err)
phase4-coordinator/internal/ws/model_admission_test.go:539:	unsafe := signedModelAdmissionOffer(t, "provider-byom-a", stableModelAdmissionCandidateID("j"), "http://127.0.0.1:11434/private?api_key=secret", priv, nil)
phase4-coordinator/internal/trustpool/admin_handler_test.go:29:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:34:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:40:	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:41:	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:42:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:47:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:52:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:69:	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:74:	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:79:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:95:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:99:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:105:	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:106:	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:107:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:125:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:129:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:135:	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:136:	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:137:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:142:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:147:	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:156:	req.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:180:				postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:191:				postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusBadRequest)
phase4-coordinator/internal/trustpool/admin_handler_test.go:218:				OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:222:			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:228:			postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:229:			postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:230:			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:235:			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:262:				postAdminCreator(t, handler, "operator-secret", trustpool.CreatorApproval{
phase4-coordinator/internal/trustpool/admin_handler_test.go:294:				postAdminCreator(t, handler, "operator-secret", validCreatorApproval("creator-a", "approval-v1", "approval-version-1", "candidate", testAdminTS(86400), trustpool.CreatorStatusEnabled), http.StatusBadRequest)
phase4-coordinator/internal/trustpool/admin_handler_test.go:301:				postAdminRootRegistrationNonce(t, handler, "operator-secret", trustpool.RootRegistrationNonceIssue{
phase4-coordinator/internal/trustpool/admin_handler_test.go:315:				postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
phase4-coordinator/internal/trustpool/admin_handler_test.go:330:				postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
phase4-coordinator/internal/trustpool/admin_handler_test.go:352:				OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:357:			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:363:			postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:364:			postAdminEvent(t, handler, "operator-secret", manifest, "op-manifest", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:365:			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:370:			postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:409:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:413:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:421:	req.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:454:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:458:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:464:	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:465:	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:466:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:471:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:487:	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:504:	rec := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-pause", trustpool.LifecyclePaused, "maintenance", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:522:	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-pause", trustpool.LifecyclePaused, "maintenance", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:659:	postAdminSignedLifecycle(t, routeable.store, handler, "operator-secret", root, "op-bad-signature-pause", trustpool.LifecyclePaused, "signed incident", true, http.StatusBadRequest)
phase4-coordinator/internal/trustpool/admin_handler_test.go:673:	postAdminSignedLifecycleBody(t, handler, "operator-secret", root.poolID, body, "", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:674:	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire-after-signed-pause", trustpool.LifecycleRetired, "retire", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:675:	postAdminSignedLifecycleBody(t, handler, "operator-secret", root.poolID, body, "", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:686:	postAdminSignedLifecycleBody(t, handler, "operator-secret", root.poolID, body, "op-header-only", http.StatusBadRequest)
phase4-coordinator/internal/trustpool/admin_handler_test.go:696:	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-pause", trustpool.LifecyclePaused, "maintenance", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:702:	rec := postAdminPromote(t, handler, "operator-secret", root.poolID, "op-resume", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:721:	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-resume", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:735:	rec := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-drain", trustpool.LifecycleDraining, "drain", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:754:	blocked := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire-blocked", trustpool.LifecycleRetired, "retire", http.StatusConflict)
phase4-coordinator/internal/trustpool/admin_handler_test.go:768:	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire", trustpool.LifecycleRetired, "retire", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:773:	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire", trustpool.LifecycleRetired, "retire", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:788:	blocked := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire-blocked", trustpool.LifecycleRetired, "retire", http.StatusConflict)
phase4-coordinator/internal/trustpool/admin_handler_test.go:802:	blocked = postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire-routeable-blocked", trustpool.LifecycleRetired, "retire", http.StatusConflict)
phase4-coordinator/internal/trustpool/admin_handler_test.go:810:	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-drain-before-retire", trustpool.LifecycleDraining, "drain", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:811:	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-retire", trustpool.LifecycleRetired, "retire", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:828:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:832:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:839:	rec := postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-active", trustpool.LifecycleActive, "manual activation", http.StatusConflict)
phase4-coordinator/internal/trustpool/admin_handler_test.go:851:	rec = postAdminLifecycleWithIDs(t, handler, "operator-secret", root.poolID, "body-active", "header-active", trustpool.LifecycleActive, "manual activation", http.StatusConflict)
phase4-coordinator/internal/trustpool/admin_handler_test.go:858:	postAdminLifecycle(t, handler, "operator-secret", root.poolID, "op-pause", trustpool.LifecyclePaused, "prelaunch pause", http.StatusBadRequest)
phase4-coordinator/internal/trustpool/admin_handler_test.go:902:			postAdminEvent(t, handler, "operator-secret", tc.event, tc.operationID, http.StatusBadRequest)
phase4-coordinator/internal/trustpool/admin_handler_test.go:919:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:923:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:929:	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:930:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:949:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:953:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:959:	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:967:	req.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:1000:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1054:	postAdminCreator(t, handler, "operator-secret", approval, http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1060:	postAdminCreator(t, handler, "operator-secret", approval, http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1066:	req.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:1075:	req.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:1110:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1114:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1120:	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssueInEnvironment(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonceInEnvironment(t, store, "creator-a", "approval-v1", "public", testAdminTS(3600)), root, "public"), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1122:	postAdminEvent(t, handler, "operator-secret", manifest, "op-manifest", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1125:	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1134:	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1142:	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1150:	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1159:	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1168:	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1177:	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1185:	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-reviewed-artifact-v1", http.StatusConflict)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1186:	rec := postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1207:	retry := postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1224:	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1232:	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1242:	auditReq.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:1275:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1292:	req.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:1309:	retryReq.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:1325:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1331:	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", nonceResp.RootRegistrationNonce, root), "op-root", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1332:	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1333:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1338:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1357:	req2.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:1369:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1375:	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root-2", testAdminTS(3), root2.poolID, "creator-a", "approval-v1", nonceResp2.RootRegistrationNonce, root2), "op-root-2", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1405:		req.Header.Set("Authorization", "Bearer operator-secret")
phase4-coordinator/internal/trustpool/admin_handler_test.go:1434:	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{Store: store, Registry: trustpool.NewRegistry(), OperatorKey: "operator-secret"})
phase4-coordinator/internal/trustpool/admin_handler_test.go:1456:		OperatorKey:                      "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1531:		OperatorKey:                      "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1566:		OperatorKey:             "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1648:		OperatorKey:                      "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1711:	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1790:		OperatorKey:                      "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1825:		OperatorKey:                      "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1858:		OperatorKey:                      "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1891:		OperatorKey:                      "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1917:		OperatorKey:                      "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1943:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1947:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1953:	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
phase4-coordinator/internal/trustpool/admin_handler_test.go:1977:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:1987:	postAdminEvent(t, handler, "operator-secret", create, "op-create", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1988:	postAdminEvent(t, handler, "operator-secret", create, "op-create", http.StatusAccepted)
phase4-coordinator/internal/trustpool/admin_handler_test.go:1990:	postAdminEvent(t, handler, "operator-secret", create, "op-create", http.StatusConflict)
phase4-coordinator/internal/trustpool/admin_handler_test.go:2002:		OperatorKey: "operator-secret",
phase4-coordinator/internal/trustpool/admin_handler_test.go:2015:	req.Header.Set("Authorization", "Bearer operator-secret")

exec
/bin/bash -lc "rg -n -C 14 \"func FetchProviderIdentities|FROM (provider|ledger|request|audit)_|provider_tokens\" phase4-coordinator/internal/stats/billingmirror/mirror.go phase4-coordinator/internal/requestlog/store.go phase4-coordinator/internal/auth -g '*.go' | sed -n '1,280p'" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
phase4-coordinator/internal/requestlog/store.go-314-	if s == nil || s.db == nil {
phase4-coordinator/internal/requestlog/store.go-315-		return "", false, fmt.Errorf("store is closed")
phase4-coordinator/internal/requestlog/store.go-316-	}
phase4-coordinator/internal/requestlog/store.go-317-	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{})
phase4-coordinator/internal/requestlog/store.go-318-	if err != nil {
phase4-coordinator/internal/requestlog/store.go-319-		return "", false, err
phase4-coordinator/internal/requestlog/store.go-320-	}
phase4-coordinator/internal/requestlog/store.go-321-	committed := false
phase4-coordinator/internal/requestlog/store.go-322-	defer func() {
phase4-coordinator/internal/requestlog/store.go-323-		if !committed {
phase4-coordinator/internal/requestlog/store.go-324-			_ = tx.Rollback()
phase4-coordinator/internal/requestlog/store.go-325-		}
phase4-coordinator/internal/requestlog/store.go-326-	}()
phase4-coordinator/internal/requestlog/store.go-327-	var existingHash, existingRequestID string
phase4-coordinator/internal/requestlog/store.go:328:	err = tx.QueryRowContext(ctx, `SELECT body_sha256, request_id FROM request_idempotency_keys WHERE account_id = ? AND idempotency_key = ?`, accountID, key).Scan(&existingHash, &existingRequestID)
phase4-coordinator/internal/requestlog/store.go-329-	if err == nil {
phase4-coordinator/internal/requestlog/store.go-330-		if existingHash != bodySHA256 {
phase4-coordinator/internal/requestlog/store.go-331-			return "", false, ErrIdempotencyConflict
phase4-coordinator/internal/requestlog/store.go-332-		}
phase4-coordinator/internal/requestlog/store.go-333-		if err := tx.Commit(); err != nil {
phase4-coordinator/internal/requestlog/store.go-334-			return "", false, err
phase4-coordinator/internal/requestlog/store.go-335-		}
phase4-coordinator/internal/requestlog/store.go-336-		committed = true
phase4-coordinator/internal/requestlog/store.go-337-		return existingRequestID, true, nil
phase4-coordinator/internal/requestlog/store.go-338-	}
phase4-coordinator/internal/requestlog/store.go-339-	if !errors.Is(err, sql.ErrNoRows) {
phase4-coordinator/internal/requestlog/store.go-340-		return "", false, err
phase4-coordinator/internal/requestlog/store.go-341-	}
phase4-coordinator/internal/requestlog/store.go-342-	if _, err := tx.ExecContext(ctx, `
--
phase4-coordinator/internal/requestlog/store.go-359-
phase4-coordinator/internal/requestlog/store.go-360-// pruneBatchSize bounds a single retention DELETE to keep the write lock
phase4-coordinator/internal/requestlog/store.go-361-// short while billing's 6s hot path is sharing the same SQLite handle.
phase4-coordinator/internal/requestlog/store.go-362-// The pruner loops until a partial batch comes back. PERF-3 (M3-1): the
phase4-coordinator/internal/requestlog/store.go-363-// comparison stays on julianday() for backwards compatibility with legacy
phase4-coordinator/internal/requestlog/store.go-364-// variable-width ts_utc rows; new request_log writes use fixed-width UTC
phase4-coordinator/internal/requestlog/store.go-365-// nanosecond text for billing range scans.
phase4-coordinator/internal/requestlog/store.go-366-const pruneBatchSize = 500
phase4-coordinator/internal/requestlog/store.go-367-
phase4-coordinator/internal/requestlog/store.go-368-func (s *Store) PruneBefore(ctx context.Context, cutoff time.Time) (int64, error) {
phase4-coordinator/internal/requestlog/store.go-369-	if s == nil || s.db == nil {
phase4-coordinator/internal/requestlog/store.go-370-		return 0, fmt.Errorf("store is closed")
phase4-coordinator/internal/requestlog/store.go-371-	}
phase4-coordinator/internal/requestlog/store.go-372-	cutoffText := cutoff.UTC().Format(time.RFC3339Nano)
phase4-coordinator/internal/requestlog/store.go:373:	if err := pruneBatched(ctx, s.db, `DELETE FROM request_idempotency_keys WHERE rowid IN (SELECT rowid FROM request_idempotency_keys WHERE julianday(created_at_utc) < julianday(?) LIMIT ?)`, cutoffText); err != nil {
phase4-coordinator/internal/requestlog/store.go-374-		return 0, err
phase4-coordinator/internal/requestlog/store.go-375-	}
phase4-coordinator/internal/requestlog/store.go:376:	return pruneBatchedCounting(ctx, s.db, `DELETE FROM request_log WHERE rowid IN (SELECT rowid FROM request_log WHERE julianday(ts_utc) < julianday(?) LIMIT ?)`, cutoffText)
phase4-coordinator/internal/requestlog/store.go-377-}
phase4-coordinator/internal/requestlog/store.go-378-
phase4-coordinator/internal/requestlog/store.go-379-// pruneBatchYieldMs is the sleep between full batches so concurrent
phase4-coordinator/internal/requestlog/store.go-380-// writers can acquire the SQLite writer lock between iterations.
phase4-coordinator/internal/requestlog/store.go-381-const pruneBatchYieldMs = 10
phase4-coordinator/internal/requestlog/store.go-382-
phase4-coordinator/internal/requestlog/store.go-383-// pruneBatched runs the DELETE in capped batches and ignores the count.
phase4-coordinator/internal/requestlog/store.go-384-// Used for the idempotency-keys side where the original PruneBefore
phase4-coordinator/internal/requestlog/store.go-385-// signature only reported request_log deletions.
phase4-coordinator/internal/requestlog/store.go-386-func pruneBatched(ctx context.Context, db *sql.DB, query, cutoffText string) error {
phase4-coordinator/internal/requestlog/store.go-387-	for {
phase4-coordinator/internal/requestlog/store.go-388-		res, err := db.ExecContext(ctx, query, cutoffText, pruneBatchSize)
phase4-coordinator/internal/requestlog/store.go-389-		if err != nil {
phase4-coordinator/internal/requestlog/store.go-390-			return err
--
phase4-coordinator/internal/requestlog/store.go-482-	//
phase4-coordinator/internal/requestlog/store.go-483-	// Callers SHOULD leave row.AttemptN nil to invoke this derivation.
phase4-coordinator/internal/requestlog/store.go-484-	// If a caller supplies a non-nil row.AttemptN, the supplied value is
phase4-coordinator/internal/requestlog/store.go-485-	// used verbatim and the derivation is skipped — this is the path
phase4-coordinator/internal/requestlog/store.go-486-	// the backfill subcommand takes (it knows the ordinal from id-ASC
phase4-coordinator/internal/requestlog/store.go-487-	// fallback and writes it directly).
phase4-coordinator/internal/requestlog/store.go-488-	attemptN := row.AttemptN
phase4-coordinator/internal/requestlog/store.go-489-	if attemptN == nil {
phase4-coordinator/internal/requestlog/store.go-490-		var accountIDArg any
phase4-coordinator/internal/requestlog/store.go-491-		if row.AccountID != "" {
phase4-coordinator/internal/requestlog/store.go-492-			accountIDArg = row.AccountID
phase4-coordinator/internal/requestlog/store.go-493-		}
phase4-coordinator/internal/requestlog/store.go-494-		var existing int
phase4-coordinator/internal/requestlog/store.go-495-		err := db.QueryRowContext(ctx,
phase4-coordinator/internal/requestlog/store.go:496:			`SELECT COUNT(*) FROM request_log WHERE account_id IS ? AND request_id = ?`,
phase4-coordinator/internal/requestlog/store.go-497-			accountIDArg, row.RequestID,
phase4-coordinator/internal/requestlog/store.go-498-		).Scan(&existing)
phase4-coordinator/internal/requestlog/store.go-499-		if err != nil {
phase4-coordinator/internal/requestlog/store.go-500-			return err
phase4-coordinator/internal/requestlog/store.go-501-		}
phase4-coordinator/internal/requestlog/store.go-502-		attemptN = &existing
phase4-coordinator/internal/requestlog/store.go-503-	}
phase4-coordinator/internal/requestlog/store.go-504-	_, err := db.ExecContext(ctx, `
phase4-coordinator/internal/requestlog/store.go-505-INSERT INTO request_log (
phase4-coordinator/internal/requestlog/store.go-506-    ts_utc,
phase4-coordinator/internal/requestlog/store.go-507-    request_id,
phase4-coordinator/internal/requestlog/store.go-508-    external_request_id,
phase4-coordinator/internal/requestlog/store.go-509-    account_id,
phase4-coordinator/internal/requestlog/store.go-510-    pool_id,
--
phase4-coordinator/internal/requestlog/store.go-702-	}
phase4-coordinator/internal/requestlog/store.go-703-	if _, err := tx.ExecContext(ctx, `
phase4-coordinator/internal/requestlog/store.go-704-CREATE TABLE request_idempotency_keys_v2 (
phase4-coordinator/internal/requestlog/store.go-705-    account_id      TEXT NOT NULL DEFAULT '',
phase4-coordinator/internal/requestlog/store.go-706-    idempotency_key TEXT NOT NULL,
phase4-coordinator/internal/requestlog/store.go-707-    body_sha256    TEXT NOT NULL,
phase4-coordinator/internal/requestlog/store.go-708-    request_id     TEXT NOT NULL UNIQUE,
phase4-coordinator/internal/requestlog/store.go-709-    created_at_utc TEXT NOT NULL,
phase4-coordinator/internal/requestlog/store.go-710-    PRIMARY KEY (account_id, idempotency_key)
phase4-coordinator/internal/requestlog/store.go-711-)`); err != nil {
phase4-coordinator/internal/requestlog/store.go-712-		return err
phase4-coordinator/internal/requestlog/store.go-713-	}
phase4-coordinator/internal/requestlog/store.go-714-	accountFromRequestLog := `(
phase4-coordinator/internal/requestlog/store.go-715-		SELECT rl.account_id
phase4-coordinator/internal/requestlog/store.go:716:		  FROM request_log rl
phase4-coordinator/internal/requestlog/store.go-717-		 WHERE rl.request_id = request_idempotency_keys.request_id
phase4-coordinator/internal/requestlog/store.go-718-		   AND rl.account_id IS NOT NULL
phase4-coordinator/internal/requestlog/store.go-719-		   AND rl.account_id != ''
phase4-coordinator/internal/requestlog/store.go-720-		 ORDER BY rl.id ASC
phase4-coordinator/internal/requestlog/store.go-721-		 LIMIT 1
phase4-coordinator/internal/requestlog/store.go-722-	)`
phase4-coordinator/internal/requestlog/store.go-723-	accountSelect := `COALESCE(` + accountFromRequestLog + `, '')`
phase4-coordinator/internal/requestlog/store.go-724-	if cols["account_id"].name != "" {
phase4-coordinator/internal/requestlog/store.go-725-		accountSelect = `COALESCE(NULLIF(request_idempotency_keys.account_id, ''), ` + accountFromRequestLog + `, '')`
phase4-coordinator/internal/requestlog/store.go-726-	}
phase4-coordinator/internal/requestlog/store.go-727-	if _, err := tx.ExecContext(ctx, `
phase4-coordinator/internal/requestlog/store.go-728-INSERT OR IGNORE INTO request_idempotency_keys_v2 (
phase4-coordinator/internal/requestlog/store.go-729-    account_id, idempotency_key, body_sha256, request_id, created_at_utc
phase4-coordinator/internal/requestlog/store.go-730-)
phase4-coordinator/internal/requestlog/store.go-731-SELECT `+accountSelect+`, idempotency_key, body_sha256, request_id, created_at_utc
phase4-coordinator/internal/requestlog/store.go:732:  FROM request_idempotency_keys
phase4-coordinator/internal/requestlog/store.go-733- ORDER BY created_at_utc, rowid`); err != nil {
phase4-coordinator/internal/requestlog/store.go-734-		return err
phase4-coordinator/internal/requestlog/store.go-735-	}
phase4-coordinator/internal/requestlog/store.go-736-	if _, err := tx.ExecContext(ctx, `DROP TABLE request_idempotency_keys`); err != nil {
phase4-coordinator/internal/requestlog/store.go-737-		return err
phase4-coordinator/internal/requestlog/store.go-738-	}
phase4-coordinator/internal/requestlog/store.go-739-	if _, err := tx.ExecContext(ctx, `ALTER TABLE request_idempotency_keys_v2 RENAME TO request_idempotency_keys`); err != nil {
phase4-coordinator/internal/requestlog/store.go-740-		return err
phase4-coordinator/internal/requestlog/store.go-741-	}
phase4-coordinator/internal/requestlog/store.go-742-	if _, err := tx.ExecContext(ctx, `CREATE INDEX IF NOT EXISTS idx_request_idempotency_request ON request_idempotency_keys(request_id)`); err != nil {
phase4-coordinator/internal/requestlog/store.go-743-		return err
phase4-coordinator/internal/requestlog/store.go-744-	}
phase4-coordinator/internal/requestlog/store.go-745-	if err := tx.Commit(); err != nil {
phase4-coordinator/internal/requestlog/store.go-746-		return err
--
phase4-coordinator/internal/requestlog/store.go-884-}
phase4-coordinator/internal/requestlog/store.go-885-
phase4-coordinator/internal/requestlog/store.go-886-// AttemptNState introspects the schema and row distribution to report
phase4-coordinator/internal/requestlog/store.go-887-// the current state without mutating. Safe to call on a read-only
phase4-coordinator/internal/requestlog/store.go-888-// store.
phase4-coordinator/internal/requestlog/store.go-889-func (s *Store) AttemptNState(ctx context.Context) (AttemptNStatus, error) {
phase4-coordinator/internal/requestlog/store.go-890-	cols, err := s.columns(ctx)
phase4-coordinator/internal/requestlog/store.go-891-	if err != nil {
phase4-coordinator/internal/requestlog/store.go-892-		return AttemptNStatus{}, err
phase4-coordinator/internal/requestlog/store.go-893-	}
phase4-coordinator/internal/requestlog/store.go-894-	if !cols["attempt_n"] {
phase4-coordinator/internal/requestlog/store.go-895-		return AttemptNStatus{MigrationState: "legacy"}, nil
phase4-coordinator/internal/requestlog/store.go-896-	}
phase4-coordinator/internal/requestlog/store.go-897-	var total, nullCount int64
phase4-coordinator/internal/requestlog/store.go:898:	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM request_log`).Scan(&total); err != nil {
phase4-coordinator/internal/requestlog/store.go-899-		return AttemptNStatus{}, err
phase4-coordinator/internal/requestlog/store.go-900-	}
phase4-coordinator/internal/requestlog/store.go:901:	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM request_log WHERE attempt_n IS NULL`).Scan(&nullCount); err != nil {
phase4-coordinator/internal/requestlog/store.go-902-		return AttemptNStatus{}, err
phase4-coordinator/internal/requestlog/store.go-903-	}
phase4-coordinator/internal/requestlog/store.go-904-	state := "populated"
phase4-coordinator/internal/requestlog/store.go-905-	if nullCount > 0 {
phase4-coordinator/internal/requestlog/store.go-906-		state = "populating"
phase4-coordinator/internal/requestlog/store.go-907-	}
phase4-coordinator/internal/requestlog/store.go-908-	return AttemptNStatus{
phase4-coordinator/internal/requestlog/store.go-909-		MigrationState: state,
phase4-coordinator/internal/requestlog/store.go-910-		NullCount:      nullCount,
phase4-coordinator/internal/requestlog/store.go-911-		TotalCount:     total,
phase4-coordinator/internal/requestlog/store.go-912-	}, nil
phase4-coordinator/internal/requestlog/store.go-913-}
phase4-coordinator/internal/requestlog/store.go-914-
phase4-coordinator/internal/requestlog/store.go-915-// BackfillAttemptN walks legacy NULL-attempt_n rows in id-ASC order
--
phase4-coordinator/internal/requestlog/store.go-941-	// SQLite ROW_NUMBER() OVER PARTITION BY assigns the in-group
phase4-coordinator/internal/requestlog/store.go-942-	// ordinal. We compute it over ALL request_log rows so the value
phase4-coordinator/internal/requestlog/store.go-943-	// matches what the v0.3.1 fallback would produce (which counts
phase4-coordinator/internal/requestlog/store.go-944-	// ALL rows in the group, including any future v1.5.2-written
phase4-coordinator/internal/requestlog/store.go-945-	// rows that already have non-NULL attempt_n). Then we filter the
phase4-coordinator/internal/requestlog/store.go-946-	// UPDATE target to attempt_n IS NULL so steady-state v1.5.2 rows
phase4-coordinator/internal/requestlog/store.go-947-	// are left untouched.
phase4-coordinator/internal/requestlog/store.go-948-	res, err := s.db.ExecContext(ctx, `
phase4-coordinator/internal/requestlog/store.go-949-WITH ranked AS (
phase4-coordinator/internal/requestlog/store.go-950-  SELECT id,
phase4-coordinator/internal/requestlog/store.go-951-         (ROW_NUMBER() OVER (
phase4-coordinator/internal/requestlog/store.go-952-            PARTITION BY account_id, request_id
phase4-coordinator/internal/requestlog/store.go-953-            ORDER BY id ASC
phase4-coordinator/internal/requestlog/store.go-954-          ) - 1) AS new_attempt_n
phase4-coordinator/internal/requestlog/store.go:955:    FROM request_log
phase4-coordinator/internal/requestlog/store.go-956-)
phase4-coordinator/internal/requestlog/store.go-957-UPDATE request_log
phase4-coordinator/internal/requestlog/store.go-958-   SET attempt_n = (SELECT new_attempt_n FROM ranked WHERE ranked.id = request_log.id)
phase4-coordinator/internal/requestlog/store.go-959- WHERE attempt_n IS NULL`)
phase4-coordinator/internal/requestlog/store.go-960-	if err != nil {
phase4-coordinator/internal/requestlog/store.go-961-		return 0, err
phase4-coordinator/internal/requestlog/store.go-962-	}
phase4-coordinator/internal/requestlog/store.go-963-	updated, _ := res.RowsAffected()
phase4-coordinator/internal/requestlog/store.go-964-	return updated, nil
phase4-coordinator/internal/requestlog/store.go-965-}
phase4-coordinator/internal/requestlog/store.go-966-
phase4-coordinator/internal/requestlog/store.go-967-// BackfillAttemptNDryRun is the preflight sibling of BackfillAttemptN.
phase4-coordinator/internal/requestlog/store.go-968-// It runs the same UPDATE inside a transaction, captures the
phase4-coordinator/internal/requestlog/store.go-969-// rows-that-would-be-affected count, then ROLLBACKs so no rows are
--
phase4-coordinator/internal/requestlog/store.go-991-	defer conn.Close()
phase4-coordinator/internal/requestlog/store.go-992-	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
phase4-coordinator/internal/requestlog/store.go-993-		return 0, err
phase4-coordinator/internal/requestlog/store.go-994-	}
phase4-coordinator/internal/requestlog/store.go-995-	defer func() {
phase4-coordinator/internal/requestlog/store.go-996-		_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
phase4-coordinator/internal/requestlog/store.go-997-	}()
phase4-coordinator/internal/requestlog/store.go-998-	res, err := conn.ExecContext(ctx, `
phase4-coordinator/internal/requestlog/store.go-999-WITH ranked AS (
phase4-coordinator/internal/requestlog/store.go-1000-  SELECT id,
phase4-coordinator/internal/requestlog/store.go-1001-         (ROW_NUMBER() OVER (
phase4-coordinator/internal/requestlog/store.go-1002-            PARTITION BY account_id, request_id
phase4-coordinator/internal/requestlog/store.go-1003-            ORDER BY id ASC
phase4-coordinator/internal/requestlog/store.go-1004-          ) - 1) AS new_attempt_n
phase4-coordinator/internal/requestlog/store.go:1005:    FROM request_log
phase4-coordinator/internal/requestlog/store.go-1006-)
phase4-coordinator/internal/requestlog/store.go-1007-UPDATE request_log
phase4-coordinator/internal/requestlog/store.go-1008-   SET attempt_n = (SELECT new_attempt_n FROM ranked WHERE ranked.id = request_log.id)
phase4-coordinator/internal/requestlog/store.go-1009- WHERE attempt_n IS NULL`)
phase4-coordinator/internal/requestlog/store.go-1010-	if err != nil {
phase4-coordinator/internal/requestlog/store.go-1011-		return 0, err
phase4-coordinator/internal/requestlog/store.go-1012-	}
phase4-coordinator/internal/requestlog/store.go-1013-	updated, _ := res.RowsAffected()
phase4-coordinator/internal/requestlog/store.go-1014-	return updated, nil
phase4-coordinator/internal/requestlog/store.go-1015-}
phase4-coordinator/internal/requestlog/store.go-1016-
phase4-coordinator/internal/requestlog/store.go-1017-// MigrateIndexes builds the request_log indexes whose underlying
phase4-coordinator/internal/requestlog/store.go-1018-// columns ensureColumns has already added.
phase4-coordinator/internal/requestlog/store.go-1019-//
--
phase4-coordinator/internal/stats/billingmirror/mirror.go-271-	db.SetConnMaxIdleTime(time.Minute)
phase4-coordinator/internal/stats/billingmirror/mirror.go-272-	return db, nil
phase4-coordinator/internal/stats/billingmirror/mirror.go-273-}
phase4-coordinator/internal/stats/billingmirror/mirror.go-274-
phase4-coordinator/internal/stats/billingmirror/mirror.go-275-func FetchRequestCredits(ctx context.Context, db *sql.DB, startID int64, limit int) ([]RequestCredit, error) {
phase4-coordinator/internal/stats/billingmirror/mirror.go-276-	caps, err := detectRequestCreditSourceCapabilities(ctx, db)
phase4-coordinator/internal/stats/billingmirror/mirror.go-277-	if err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go-278-		return nil, err
phase4-coordinator/internal/stats/billingmirror/mirror.go-279-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-280-	return scanRequestCredits(ctx, db, requestCreditsQuery(caps, false), startID, limit)
phase4-coordinator/internal/stats/billingmirror/mirror.go-281-}
phase4-coordinator/internal/stats/billingmirror/mirror.go-282-
phase4-coordinator/internal/stats/billingmirror/mirror.go-283-func FetchMaxRequestCreditID(ctx context.Context, db *sql.DB) (int64, error) {
phase4-coordinator/internal/stats/billingmirror/mirror.go-284-	var maxID sql.NullInt64
phase4-coordinator/internal/stats/billingmirror/mirror.go:285:	if err := db.QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go-286-		return 0, fmt.Errorf("select max ledger_request_credits id: %w", err)
phase4-coordinator/internal/stats/billingmirror/mirror.go-287-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-288-	if !maxID.Valid {
phase4-coordinator/internal/stats/billingmirror/mirror.go-289-		return 0, nil
phase4-coordinator/internal/stats/billingmirror/mirror.go-290-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-291-	return maxID.Int64, nil
phase4-coordinator/internal/stats/billingmirror/mirror.go-292-}
phase4-coordinator/internal/stats/billingmirror/mirror.go-293-
phase4-coordinator/internal/stats/billingmirror/mirror.go-294-func FetchRequestCreditsThrough(ctx context.Context, db *sql.DB, startID, endID int64, limit int) ([]RequestCredit, error) {
phase4-coordinator/internal/stats/billingmirror/mirror.go-295-	caps, err := detectRequestCreditSourceCapabilities(ctx, db)
phase4-coordinator/internal/stats/billingmirror/mirror.go-296-	if err != nil {
phase4-coordinator/internal/stats/billingmirror/mirror.go-297-		return nil, err
phase4-coordinator/internal/stats/billingmirror/mirror.go-298-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-299-	return scanRequestCredits(ctx, db, requestCreditsQuery(caps, true), startID, endID, limit)
--
phase4-coordinator/internal/stats/billingmirror/mirror.go-373-		rewardsExcludedExpr = "COALESCE(lrc.rewards_excluded, 0)"
phase4-coordinator/internal/stats/billingmirror/mirror.go-374-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-375-	where := "WHERE lrc.id > ?"
phase4-coordinator/internal/stats/billingmirror/mirror.go-376-	if bounded {
phase4-coordinator/internal/stats/billingmirror/mirror.go-377-		where += "\n   AND lrc.id <= ?"
phase4-coordinator/internal/stats/billingmirror/mirror.go-378-	}
phase4-coordinator/internal/stats/billingmirror/mirror.go-379-	return fmt.Sprintf(`
phase4-coordinator/internal/stats/billingmirror/mirror.go-380-SELECT lrc.id, lrc.request_id, lrc.attempt_n, lrc.provider_id, lrc.ts_utc, lrc.created_at_utc, lrc.updated_at_utc,
phase4-coordinator/internal/stats/billingmirror/mirror.go-381-       lrc.prompt_tokens, lrc.completion_tokens, lrc.estimated_completion_tokens, lrc.usage_source,
phase4-coordinator/internal/stats/billingmirror/mirror.go-382-       lrc.provider_credits, lrc.fault_flag, lrc.quarantined,
phase4-coordinator/internal/stats/billingmirror/mirror.go-383-       %s AS settlement_policy_mode,
phase4-coordinator/internal/stats/billingmirror/mirror.go-384-       %s AS spec022_verified,
phase4-coordinator/internal/stats/billingmirror/mirror.go-385-       %s AS requested_privacy_mode, %s AS effective_privacy_outcome,
phase4-coordinator/internal/stats/billingmirror/mirror.go-386-       %s AS positive_verification_excluded, %s AS rewards_excluded
phase4-coordinator/internal/stats/billingmirror/mirror.go:387:  FROM ledger_request_credits lrc
phase4-coordinator/internal/stats/billingmirror/mirror.go-388- %s
phase4-coordinator/internal/stats/billingmirror/mirror.go-389- ORDER BY lrc.id
phase4-coordinator/internal/stats/billingmirror/mirror.go-390- LIMIT ?`, policyExpr, verifiedExpr, requestedPrivacyExpr, effectivePrivacyExpr, positiveExcludedExpr, rewardsExcludedExpr, where)

exec
/bin/bash -lc "rg -n \"FetchProviderIdentities|provider_identities|provider_identity\" phase4-coordinator/internal/stats/billingmirror/mirror.go | head -80; sed -n '450,540p' phase4-coordinator/internal/stats/billingmirror/mirror.go" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
179:	providers, err := FetchProviderIdentities(ctx, source)
473:func FetchProviderIdentities(ctx context.Context, db *sql.DB) ([]ProviderIdentity, error) {
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
		row.Quarantined = quarantined != 0
		row.Spec022Verified = spec022Verified != 0
		row.PositiveVerificationExcluded = positiveExcluded != 0
		row.RewardsExcluded = rewardsExcluded != 0
		out = append(out, row)
	}
	if err := cur.Err(); err != nil {
		return nil, fmt.Errorf("iterate ledger_request_credits: %w", err)
	}
	return out, nil
}

func FetchProviderIdentities(ctx context.Context, db *sql.DB) ([]ProviderIdentity, error) {
	const q = `
SELECT provider_id,
       COALESCE(MAX(NULLIF(provider_name, '')), provider_id) AS provider_name,
       COALESCE(MIN(created_at), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) AS created_at,
       MAX(last_used_at) AS last_used_at
  FROM provider_tokens
 WHERE provider_id <> ''
 GROUP BY provider_id
 ORDER BY provider_id`
	cur, err := db.QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("select provider_tokens: %w", err)
	}
	defer cur.Close()
	var out []ProviderIdentity
	for cur.Next() {
		var p ProviderIdentity
		var created sql.NullString
		var lastUsed sql.NullString
		if err := cur.Scan(&p.ProviderID, &p.ProviderName, &created, &lastUsed); err != nil {
			return nil, fmt.Errorf("scan provider_tokens: %w", err)
		}
		createdAt, err := parseRequiredTime(created, "provider_tokens.created_at")
		if err != nil {
			return nil, err
		}
		p.CreatedAt = createdAt
		p.LastUsedAt, err = parseOptionalTime(lastUsed)
		if err != nil {
			return nil, fmt.Errorf("provider_tokens.last_used_at: %w", err)
		}
		out = append(out, p)
	}
	if err := cur.Err(); err != nil {
		return nil, fmt.Errorf("iterate provider_tokens: %w", err)
	}
	return out, nil
}

func Apply(ctx context.Context, db *sql.DB, rows []RequestCredit, providers []ProviderIdentity, state State) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin mirror transaction: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()
	var locked bool
	if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(47017, 1711)`).Scan(&locked); err != nil {
		return fmt.Errorf("acquire mirror advisory lock: %w", err)
	}
	if !locked {
		return errors.New("another stats billing mirror run is active")
	}
	for _, p := range providers {
		if err := ensureProvider(ctx, tx, p); err != nil {
			return err
		}
	}
	for _, row := range rows {
		if err := upsertRequestCredit(ctx, tx, row); err != nil {
			return err
		}
	}

exec
/bin/bash -lc "nl -ba phase4-coordinator/internal/config/config.go | sed -n '1585,1610p'; rg -n \"request-log\\.sqlite|coordinator\\.db|DBPath\" phase4-coordinator/dist phase4-coordinator/internal/config phase4-coordinator/internal/requestlog -g '*.yaml' -g '*.sh' -g '*.go' | head -180" in /Users/augstar/macprovider-mirror-dbpath
 succeeded in 0ms:
  1585				RequireAttestation:             false,
  1586				AttestationRoots:               []string{},
  1587				AttestationMaxAgeS:             600,
  1588				AttestationFormats:             []string{"apple-managed-device-attestation-acme-v1", "macprovider-se-p256-v1"},
  1589				AllowMockAttestation:           false,
  1590				BehavioralSafetyEnabled:        false,
  1591				OutputSizeCapBytes:             0,
  1592				OutputBytesPerTokenCeiling:     16,
  1593				DefaultOutputSizeCapBytes:      1048576,
  1594				EncodingValidationEnabled:      false,
  1595				ResponseTimeAnomalyEnabled:     false,
  1596				ResponseTimeAnomalyFactor:      5.0,
  1597				ResponseTimeAnomalyMinMS:       10000,
  1598			},
  1599			Storage: StorageConfig{
  1600				DBPath:                   "coordinator.db",
  1601				SnapshotIntervalS:        300,
  1602				RequestLogRetentionDays:  90,
  1603				RequestLogPruneOnStartup: true,
  1604				AuditLogPruneOnStartup:   true,
  1605				AuditLogRetentionDays:    90,
  1606			},
  1607			TrustedPools: TrustedPoolsConfig{
  1608				Enabled:                          false,
  1609				RefreshIntervalS:                 30,
  1610				RejectionTimingFloorMS:           0,
phase4-coordinator/dist/coordinator-archive-restore.sh:10:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
phase4-coordinator/dist/coordinator-archive-restore.sh:182:PRIMARY_TMP="$TMP_DIR/coordinator.db"
phase4-coordinator/dist/coordinator-archive-rotate.sh:2:# coordinator-archive-rotate.sh — coordinator.db archive-rotate scaffold (#1226).
phase4-coordinator/dist/coordinator-archive-rotate.sh:15:#   COORDINATOR_DB_PATH                  default: /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/coordinator-archive-rotate.sh:34:COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
phase4-coordinator/dist/coordinator-archive-rotate.sh:274:  log "DRY_RUN=1 coordinator.db size=${size}B"
phase4-coordinator/dist/deploy-pearl-vps.sh:3141:    snapshot_acl /var/lib/macprovider/coordinator.db request-log-db.acl had-request-log-db-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3142:    snapshot_acl /var/lib/macprovider/coordinator.db-wal request-log-wal.acl had-request-log-wal-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3143:    snapshot_acl /var/lib/macprovider/coordinator.db-shm request-log-shm.acl had-request-log-shm-acl
phase4-coordinator/dist/deploy-pearl-vps.sh:3635:    setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db
phase4-coordinator/dist/deploy-pearl-vps.sh:3636:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-wal-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-wal
phase4-coordinator/dist/deploy-pearl-vps.sh:3637:    [ -f /opt/macprovider/.coordinator-deploy-rollback/had-request-log-shm-acl ] && setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db-shm
phase4-coordinator/dist/deploy-pearl-vps.sh:3638:  elif [ -f /var/lib/macprovider/coordinator.db ]; then
phase4-coordinator/dist/deploy-pearl-vps.sh:4873:  if [ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ] && su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats; then
phase4-coordinator/dist/coordinator.yaml:243:  db_path: "/var/lib/macprovider/coordinator.db"
phase4-coordinator/internal/requestlog/store_test.go:379:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/requestlog/store_test.go:462:	store, err := OpenStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/internal/requestlog/store_test.go:540:	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
phase4-coordinator/internal/requestlog/store_test.go:849:	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
phase4-coordinator/dist/coordinator-sqlite-relief.sh:9:  echo "usage: coordinator-sqlite-relief.sh [coordinator.db]" >&2
phase4-coordinator/dist/test/check_deploy_static_feed_access.test.sh:151:grep -q 'snapshot_acl /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" &&
phase4-coordinator/internal/config/config.go:371:	SQLitePayoutDBPath           string   `yaml:"sqlite_payout_db_path"`
phase4-coordinator/internal/config/config.go:1223:	DBPath                   string `yaml:"db_path"`
phase4-coordinator/internal/config/config.go:1600:			DBPath:                   "coordinator.db",
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:44:grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/coordinator.db' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:48:grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/coordinator.db" macprovider-stats' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:54:grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/coordinator.db ]' "$DEPLOY_SH" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:67:grep -qxF 'ConditionPathExists=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:71:grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/coordinator.db --ensure-schema=false' "$SERVICE" ||
phase4-coordinator/dist/test/check_stats_billing_mirror_deploy_test.sh:73:grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/coordinator.db' "$SERVICE" ||
phase4-coordinator/dist/test/coordinator_sqlite_relief.test.sh:16:DB="$TMP/coordinator.db"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:20:DB="$TMP/coordinator.db"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:148:grep -q "DRY_RUN=1 coordinator.db size=" "$TMP/dry.err" || fail "dry-run size report missing"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:424:printf 'live-parent-marker\n' >"$LIVE_DIR/coordinator.db"
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:426:COORDINATOR_DB_PATH="$LIVE_DIR/coordinator.db" \
phase4-coordinator/dist/test/coordinator_archive_rotate.test.sh:433:[ "$(cat "$LIVE_DIR/coordinator.db")" = "live-parent-marker" ] || fail "directory restore mutated live coordinator.db"

codex
The existing tests pass, but they do not catch the contradiction: the wiring test positively checks `ReadOnlyPaths=/var/lib/macprovider/coordinator.db` without checking that the same path is absent from `InaccessiblePaths`. Source review confirms the mirror opens SQLite with `mode=ro` and `query_only(true)` and performs no coordinator-DB writes; ACL snapshots/restores target the new DB and its WAL/SHM paths.
exec
/bin/bash -lc 'go test ./internal/sqliteutil' in /Users/augstar/macprovider-mirror-dbpath/phase4-coordinator
 succeeded in 717ms:
ok  	github.com/augstar/macprovider-coordinator/internal/sqliteutil	(cached)

codex
Audit basis: `origin/main...HEAD` is empty because both refs point to `c6c326927`; I audited the target commit against its parent.

Finding:

- **HIGH** — `phase4-coordinator/dist/stats-billing-mirror.service:28` still declares `InaccessiblePaths=-/var/lib/macprovider/coordinator.db`, while lines 7, 14, and 23 configure that same file as the mirror’s source. Systemd will hide the coordinator DB inside the service sandbox, so the mirror cannot open the ledger. The deploy guard at `deploy-pearl-vps.sh:4873` checks readability outside that sandbox, allowing deployment to proceed until the initial service run fails and triggers rollback.  
  **Fix:** Remove only the coordinator DB entry from `InaccessiblePaths`; retain the `/etc/macprovider` and coordinator configuration protections. Add a wiring assertion that the source DB is not inaccessible.

Other checks:

- ACL scope is limited to `macprovider-stats:r--` on the DB and existing WAL/SHM files, with directory traverse-only access. SQLite file-level access necessarily covers the database file, but no write ACL is granted.
- Rollback snapshots and restores the coordinator DB, WAL, SHM, and directory ACLs via `getfacl`/`setfacl --restore`.
- The mirror uses SQLite `mode=ro` plus `query_only(true)` and has no coordinator-DB write path.
- `InaccessiblePaths` continues to hide `/etc/macprovider` and coordinator configuration secrets.
- Existing tests passed:
  - `check_stats_billing_mirror_deploy_test.sh`
  - `check_deploy_static_feed_access.test.sh`
  - `go test ./internal/stats/billingmirror`
  - `go test ./internal/sqliteutil`

VERDICT: FAIL (C=0, H=1, M=0)
tokens used
139 649

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
