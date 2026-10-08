# shellcheck shell=bash
# Exact runbook commands the ops entry points print or run. They are copied
# here, not read from the Markdown at run time, so runbook prose is never
# executed. Hosts are placeholders: <pearl-ssh> becomes "$PEARL_SSH" and
# <coordinator-url> becomes $COORDINATOR_URL when a script renders them.
# scripts/ops/test-runbook-commands.sh fails when a constant drifts from the
# fenced block it copies (RUNBOOK_SOURCES below), after the same placeholder
# normalization.
# shellcheck disable=SC2034  # read by the entry points

# NAME|document|heading substring|block number
RUNBOOK_SOURCES="RB_PEARL_PREFLIGHT|docs/runbooks/pearl-coordinator-rollout.md|Preflight (every time)|1
RB_PEARL_APPLY|docs/runbooks/pearl-coordinator-rollout.md|Runtime apply (signed updater)|1
RB_CATALOG_RESTORE|docs/runbooks/pearl-coordinator-rollout.md|Run, with an automatic restore|1
RB_NATIVE_AUTOTUNE_KEYS|docs/runbooks/native-mtp-enablement.md|## Order|1
RB_NATIVE_POOL_CANARY|docs/runbooks/native-mtp-enablement.md|## Order|2"

RB_PEARL_PREFLIGHT='ssh <pearl-ssh> '"'"'df -h /; du -sh /var/lib/macprovider-pearl-updater/transactions;
  systemctl list-units --all "mp-update*" --no-legend; pgrep -af "pearl-update|deploy-pearl";
  curl -s <coordinator-url>/healthz; readlink /opt/macprovider/autotune/current'"'"''

RB_PEARL_APPLY='ssh <pearl-ssh> '"'"'systemd-run --unit=mp-update-<ver> -p Environment=PYTHONDONTWRITEBYTECODE=1 \
  -p "Environment=PATH=/opt/macprovider-tools/sqlite-3.53.2/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -p UMask=0077 -p "ExecStopPost=/usr/local/sbin/macprovider-pearl-update --reconcile" \
  /usr/local/sbin/macprovider-pearl-update --apply --tag v<ver>'"'"''

RB_CATALOG_RESTORE='FORCE_RESTART=1 CONFIG_MODE=preserve-live \
  CATALOG_CANARY_PROVIDER_ID=<canary-provider-id> \
  CATALOG_CANARY_SSH_TARGET=<canary-ssh-target> \
  bash phase4-coordinator/dist/deploy-pearl-vps.sh \
  || ssh <pearl-ssh> '"'"'readlink /opt/macprovider/autotune/current | grep -q <new-release> ||
       { cp -a <pre-key-backup> /opt/macprovider/coordinator.yaml;
         curl -sf http://127.0.0.1:8443/healthz || systemctl restart macprovider-coordinator; }'"'"''

RB_NATIVE_AUTOTUNE_KEYS='  native_mtp_admission_path: /opt/macprovider/autotune/current/native-mtp-admission.json
  native_mtp_admission_sig_path: /opt/macprovider/autotune/current/native-mtp-admission.json.sig
  native_mtp_artifact_manifest_path: /opt/macprovider/autotune/current/native-mtp-artifact-manifest.json
  native_mtp_selftest_bank_path: /opt/macprovider/autotune/current/native-mtp-selftest-bank.json
  native_mtp_selftest_bank_sig_path: /opt/macprovider/autotune/current/native-mtp-selftest-bank.json.sig
  native_mtp_revocations_dir: /opt/macprovider/native-mtp-revocations/current'

RB_NATIVE_POOL_CANARY='  native_mtp_canary:
    enabled: true
    challenge_bank_path: /opt/macprovider/autotune/current/native-mtp-selftest-bank.json
    signature_path: /opt/macprovider/autotune/current/native-mtp-selftest-bank.json.sig
    signer_key_id: streamvc-autotune-static-v4
    public_keys:
      streamvc-autotune-static-v4: zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU=
    interval_s: 3600'
