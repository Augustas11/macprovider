#!/usr/bin/env bash
# Fail-closed structural checks for protected autotune-feed signed renewal.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/renew-autotune-static-feed-signed.yml"
script="$root/scripts/renew-autotune-static-feed.sh"
helper="$root/scripts/pearl_autotune_deploy_lock.py"
runbook="$root/docs/runbooks/autotune-feed-renewal.md"
[[ -f "$workflow" ]] || {
  printf '[test-renew-autotune-static-feed-signed] ERROR: missing signed renewal workflow\n' >&2
  exit 1
}
[[ -f "$script" ]] || {
  printf '[test-renew-autotune-static-feed-signed] ERROR: missing renew script\n' >&2
  exit 1
}
[[ -f "$helper" ]] || {
  printf '[test-renew-autotune-static-feed-signed] ERROR: missing Pearl lock validator\n' >&2
  exit 1
}
[[ -f "$runbook" ]] || {
  printf '[test-renew-autotune-static-feed-signed] ERROR: missing renewal runbook\n' >&2
  exit 1
}

python3 - "$workflow" "$script" "$runbook" <<'PY'
import pathlib
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
script = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
runbook = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
SEALED_OUTPUT = 'OPENSSL_BIN: ${{ steps.protected_openssl.outputs.bin }}'
SEALED_RUNNER = "    runs-on: macos-15-intel"

if workflow.count(SEALED_RUNNER) != 1:
    raise SystemExit("signed renewal runner must match the reviewed Intel OpenSSL bottle")

for requirement in (
    "name: Renew signed autotune static feed",
    "workflow_dispatch:",
    "concurrency:",
    "group: production-release",
    "cancel-in-progress: false",
    "environment: production-release",
    "scripts/install-sealed-release-openssl.sh",
    "/private/var/macprovider-openssl-autotune-renewal",
    "AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64",
    "PEARL_AUTOTUNE_DEPLOY_SSH_KEY",
    "AUTOTUNE_STATIC_PRIVATE_KEY_PATH",
    "PEARL_SSH_IDENTITY",
    "PEARL_SSH_KNOWN_HOSTS",
    'export PEARL_SSH="root@159.223.165.194"',
    "scripts/dist/malibu-download-known_hosts",
    "bash scripts/renew-autotune-static-feed.sh --deploy",
    "persist-credentials: false",
    "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
    "timeout-minutes: 20",
    "unset AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64 PEARL_AUTOTUNE_DEPLOY_SSH_KEY",
    'chmod 600 "$key" "$ssh_key"',
    """trap 'rm -f "$key" "$ssh_key"' EXIT""",
    "scripts/verify-github-release-posture.sh",
    "RELEASE_POSTURE_TOKEN",
    'cron: "0 16 * * 3"',
):
    if requirement not in workflow:
        raise SystemExit(f"signed renewal workflow omits: {requirement}")

before_secrets = workflow.split("- name: Sign a freshness restamp and deploy to Pearl", 1)[0]
if "scripts/verify-github-release-posture.sh" not in before_secrets:
    raise SystemExit("posture check must run before the secret-bearing deploy step")
if "AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64: ${{ secrets.AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64 }}" in before_secrets:
    raise SystemExit("feed key must not be in env before the deploy step")
seal_idx = workflow.find("- name: Seal reviewed OpenSSL 3")
posture_idx = workflow.find("- name: Verify protected GitHub release posture")
if posture_idx < 0 or seal_idx < 0 or posture_idx > seal_idx:
    raise SystemExit("posture check must run before OpenSSL seal")

if 'cron: "0 16 * * 1"' in workflow:
    raise SystemExit("signed renewal must not share Monday 16:00 UTC with discovery-head")
if 'cron: "0 16 * * 2"' in workflow:
    raise SystemExit("signed renewal must not share Tuesday 16:00 UTC with the watch workflow")

for forbidden in (
    "MACPROVIDER_RELEASE_SIGNING_KEY_PEM",
    "MALIBU_DOWNLOAD_SSH_KEY",
    "contents: write",
    "/etc/macprovider/keys",
    "brew install openssl@3",
    "brew --prefix openssl@3",
    "GITHUB_ENV",
    "autotune-feed-renewal.service",
    "install-autotune-feed-renewal-pearl.sh",
):
    if forbidden in workflow:
        raise SystemExit(f"signed renewal workflow must not contain {forbidden!r}")

if "OPENSSL_BIN=" in workflow:
    raise SystemExit("signed renewal must not publish mutable OpenSSL environment state")
if workflow.count(SEALED_OUTPUT) != 1:
    raise SystemExit("the deploy crypto consumer must bind the sealed step output once")

for requirement in (
    "- name: Seal reviewed OpenSSL 3",
    "id: protected_openssl",
    "printf 'bin=%s\\n' \"$sealed_bin\" >> \"$GITHUB_OUTPUT\"",
):
    if requirement not in workflow:
        raise SystemExit(f"signed renewal OpenSSL seal omits: {requirement}")

deploy = workflow.split("- name: Sign a freshness restamp and deploy to Pearl", 1)[1]
if deploy.count(SEALED_OUTPUT) != 1:
    raise SystemExit("deploy step does not bind the sealed OpenSSL output")
if "cat \"$key\"" in deploy or "cat \"$ssh_key\"" in deploy:
    raise SystemExit("deploy step must not print key material")
if 'printf \'%s\\n\' "$AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64" > "$key"' not in deploy:
    raise SystemExit("deploy step must materialize the feed key to a 0600 file")

top_level, _, rest = workflow.partition("\njobs:\n")
if "contents: write" in top_level or "contents: write" in rest:
    raise SystemExit("signed autotune renewal must remain contents: read (no GitHub release publish)")
if "contents: read" not in rest:
    raise SystemExit("protected renewal job must request contents: read")

for requirement in (
    "PEARL_SSH_IDENTITY",
    "IdentitiesOnly=yes",
    "UserKnownHostsFile",
    "StrictHostKeyChecking=yes",
    "GITHUB_SHA",
    "flock -n 8",
    "flock -n 9",
    "/run/lock/macprovider-pearl-updater.lock",
    "/opt/macprovider/.coordinator-deploy.lock",
    "exec 8</run/lock/macprovider-pearl-updater.lock",
    "exec 9</opt/macprovider/.coordinator-deploy.lock",
    "do not create them",
    "pearl_autotune_deploy_lock.py",
    "mutated=1",
    'elif [ "$publish_rc" -eq 1 ]; then',
    "aborted before mutating current",
    "content drift under lock",
    "rollback: Pearl updater lock held",
    "python3 \"$helper\" validate",
    "mktemp -d /tmp/macprovider-autotune-lock.XXXXXXXX",
    "abort_pre_mutation",
    "chown root:root",
    "rollback: current is",
    '"releases/$RELEASE_DIRNAME"',
    "restored .previous-target only",
    "__EMPTY__",
    "current moved under lock",
    # The restamp goes through the generator, which is the only thing that knows
    # rate-card.json is MATERIALISED from rate-card-source.json. A hand-rolled
    # restamp in shell re-dates the generated file, `generate` reverts it from the
    # stale source, and the atomic-release check aborts the monthly renewal on a
    # feed that is otherwise correct. The executable regression is RenewalFlowTest
    # in scripts/tests/test_catalog_artifact_feed.py, run below.
    "catalog-release.py restamp",
    "--generated-at",
    # The freshness-only guard must cover the artifact feed once a release is
    # artifact-bound: a model-set change confined to autotune-artifacts.json
    # must not ride the scheduled restamp. The pre-deploy check delegates to the
    # unit-tested generator rules; the under-lock recheck mirrors them inline.
    "catalog-release.py continuity-check",
    'live-current',
    # Post-activation, generate needs the previous signed release; the cron
    # fetches the live current release from Pearl and lets generate
    # authenticate it, so the monthly renewal cannot fail closed at generate.
    "artifact-feed state",
    'AUTOTUNE_PREVIOUS_RELEASE_DIR="$PREVIOUS_RELEASE_DIR"',
    "cannot fetch the live signed release",
    # Dry-run never contacts Pearl; staging follows release.json only.
    "dry-run makes no contact with",
    'staged_artifact_bound="$(python3 - "$CAT_DIR/release.json"',
    "release.json does not bind autotune-artifacts.json but",
):
    if requirement not in script:
        raise SystemExit(f"renew script omits: {requirement}")
before_generate = script.split('catalog-release.py "${GENERATE_ARGS[@]}"', 1)[0]
if 'cat_dir / "rate-card.json"' in before_generate:
    raise SystemExit("renewal must not re-stamp the GENERATED rate-card.json; the generator writes it")
if 'AUTOTUNE_PREVIOUS_RELEASE_DIR="$PREVIOUS_RELEASE_DIR"' not in before_generate:
    raise SystemExit("the previous-release fetch must run before generate")
fetch_position = script.find("SSH \"tar -C '$REMOTE_AUTOTUNE_DIR/current'")
guard_position = script.find('case "$REMOTE_AUTOTUNE_DIR" in ""|*[!A-Za-z0-9._/-]*)')
if min(fetch_position, guard_position) < 0 or guard_position > fetch_position:
    raise SystemExit("REMOTE_AUTOTUNE_DIR must be allowlisted before the previous-release fetch interpolates it")
if script.find('[ "$DEPLOY" = 1 ] ||') < 0 or script.find('[ "$DEPLOY" = 1 ] ||') > fetch_position:
    raise SystemExit("the previous-release fetch must be gated on --deploy so dry-run stays no-contact")
if 'rm -rf "$PREVIOUS_RELEASE_DIR"' not in script.split("cleanup() {", 1)[1].split("\n}", 1)[0]:
    raise SystemExit("the fetched previous release must be removed on exit")
rollback = script.split("rollback() {", 1)[1].split("\n}", 1)[0]
if "flock -n 8" not in rollback or "flock -n 9" not in rollback:
    raise SystemExit("rollback must take Pearl deploy locks before mutating current")
if 'readlink "$root/current"' not in rollback:
    raise SystemExit("rollback must re-read current under lock before restoring")
if "not $expected" not in rollback:
    raise SystemExit("rollback must skip unless current still points at this renewal")
if "restored .previous-target only" not in rollback:
    raise SystemExit("rollback must restore .previous-target when current never swapped")
if 'elif [ "$publish_rc" -eq 1 ]; then' in script:
    after = script.split('elif [ "$publish_rc" -eq 1 ]; then', 1)[1]
    else_branch = after.split("else", 1)[1].split("fi", 1)[0]
    if "rollback" in else_branch:
        raise SystemExit("pre-mutation publish failure must not rollback")
if "/tmp/macprovider-autotune-lock-validate." in script:
    raise SystemExit("lock helper must not use a predictable /tmp/$$ path")
if "/etc/macprovider/keys" in script:
    raise SystemExit("renew script must not place the feed key on Pearl")
remote = script.split("<<'REMOTE'", 1)[1].split("\nREMOTE", 1)[0]
if remote.find("mutated=1") > remote.find('printf \'%s\\n\' "$prev" > "$root/.previous-target"'):
    raise SystemExit("mutated=1 must be set before writing .previous-target")
under_lock = remote.split("Re-check dates-only continuity under the lock", 1)[1].split("\nPY", 1)[0]
for requirement in (
    'artifact = "autotune-artifacts.json"',
    "(presence)",
    # The inline mirror of RENEWAL_ARTIFACT_RELEASE_FIELDS on Pearl (no
    # checkout there) must carry the FULL tuple, not a subset.
    '("version", "release_id", "generated_at", "candidate_catalog_sha256")',
):
    if requirement not in under_lock:
        raise SystemExit(f"under-lock continuity recheck omits the artifact feed rule: {requirement}")
if remote.find("(presence)") > remote.find('mv "$incoming" "$final"'):
    raise SystemExit("artifact-feed continuity must be rechecked before the release directory is installed")
if "rsync" in script and ".private.base64" in script.split("rsync", 1)[1][:800]:
    raise SystemExit("renew script must not rsync the private key to Pearl")
if 'ln -sfn "$(cat .previous-target)"' in runbook:
    raise SystemExit("runbook must not use unguarded manual rollback")
if "flock -n 8" not in runbook or "flock -n 9" not in runbook:
    raise SystemExit("runbook manual rollback must take Pearl deploy locks")
if "not $expected" not in runbook:
    raise SystemExit("runbook manual rollback must skip unless current matches the failed renewal")
if "orig_prev" not in runbook:
    raise SystemExit("runbook manual rollback must restore the pre-renewal .previous-target")
PY

python3 -m py_compile "$helper"
bash -n "$script"

# EXECUTABLE renewal-flow regression: restamp -> generate -> sign -> generate ->
# verify, in both the pre-activation four-feed state and the post-activation
# five-feed state, against a throwaway catalog and key. Structural greps above
# cannot tell whether the flow still COMPLETES, and this job runs unattended on a
# 30-day freshness clock.
( cd "$root" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  scripts.tests.test_catalog_artifact_feed.RenewalFlowTest ) >/dev/null 2>&1 || {
  printf '[test-renew-autotune-static-feed-signed] ERROR: renewal flow regression failed; re-run:\n' >&2
  printf '  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_catalog_artifact_feed.RenewalFlowTest\n' >&2
  exit 1
}

printf '[test-renew-autotune-static-feed-signed] ok: protected autotune renewal fails closed\n'
