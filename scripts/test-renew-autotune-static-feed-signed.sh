#!/usr/bin/env bash
# Fail-closed structural checks for protected autotune-feed signed renewal.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="$root/.github/workflows/renew-autotune-static-feed-signed.yml"
script="$root/scripts/renew-autotune-static-feed.sh"
helper="$root/scripts/pearl_autotune_deploy_lock.py"
lib="$root/scripts/lib/autotune-activate.sh"
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
[[ -f "$lib" ]] || {
  printf '[test-renew-autotune-static-feed-signed] ERROR: missing shared activation lib\n' >&2
  exit 1
}

# #1688 C1: renew publishes through scripts/lib/autotune-activate.sh. Render the
# exact remote publish/rollback scripts renew sends (flock locks, warn coverage,
# continuity gate) so the pins below read the bytes that reach Pearl.
render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT
bash -c '
set -euo pipefail
log() { :; }
fatal() { printf "%s\n" "$*" >&2; exit 1; }
. "$1"
AA_GATE_SNIPPET="$AA_GATE_CONTINUITY_CHECK"
AA_COVERAGE_POLICY=warn
AA_LOCK_MODE=flock
aa_render_publish_script > "$2/publish.sh"
aa_render_rollback_script flock > "$2/rollback.sh"
' _ "$lib" "$render_dir"

python3 - "$workflow" "$script" "$runbook" "$lib" "$render_dir/publish.sh" "$render_dir/rollback.sh" \
  "$root/scripts/tests/fixtures/renew-remote-publish.golden.sh" "$root/scripts/tests/fixtures/renew-remote-rollback.golden.sh" <<'PY'
import pathlib
import sys

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
renew = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
runbook = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
lib = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
remote = pathlib.Path(sys.argv[5]).read_text(encoding="utf-8")
rendered_rollback = pathlib.Path(sys.argv[6]).read_text(encoding="utf-8")
# The remote bytes renew sends are frozen: moving them into the shared lib must
# not change one byte of what Pearl executes.
if pathlib.Path(sys.argv[5]).read_bytes() != pathlib.Path(sys.argv[7]).read_bytes():
    raise SystemExit("renew's rendered remote publish script drifted from the golden bytes")
if pathlib.Path(sys.argv[6]).read_bytes() != pathlib.Path(sys.argv[8]).read_bytes():
    raise SystemExit("renew's rendered remote rollback script drifted from the golden bytes")
for requirement in (
    '. "$SCRIPT_DIR/lib/autotune-activate.sh"',
    'AA_GATE_SNIPPET="$AA_GATE_CONTINUITY_CHECK"',
    "AA_COVERAGE_POLICY=warn",
    "AA_LOCK_MODE=flock",
    "aa_install_helpers",
    'aa_upload_release "$RELEASE_STAGE"',
    "aa_publish",
    "aa_post_activation_evidence renew_served_feed_evidence",
):
    if requirement not in renew:
        raise SystemExit(f"renew script omits: {requirement}")
if renew.find("aa_install_helpers") > renew.find("\naa_publish"):
    raise SystemExit("renew must ship and verify helpers before the remote publish")
# Renew-owned text plus the shared lib it sources.
script = renew + "\n" + lib
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
    "environment: autotune-feed-renewal",
    "POSTURE_PROFILE=unattended",
    "autotune-feed-renewal 28995904",
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
    "uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e",
    "go-version-file: phase4-coordinator/go.mod",
    "cache: false",
    "/private/var/macprovider-go-verifier",
    "Seal the Tier-2 verifier toolchain",
    'source_root="$(go env GOROOT)"',
    "CATALOG_RELEASE_REQUIRE_SEALED_GO_VERIFIER=1",
    "sudo chown -R root:wheel /private/var/macprovider-go-verifier",
):
    if requirement not in workflow:
        raise SystemExit(f"signed renewal workflow omits: {requirement}")

if "environment: production-release" in workflow:
    raise SystemExit("signed renewal must not gate on production-release")
if "antfleet-ops approves" in workflow:
    raise SystemExit("signed renewal must not require antfleet-ops approval")

before_secrets = workflow.split("- name: Sign a freshness restamp and deploy to Pearl", 1)[0]
if "POSTURE_PROFILE=unattended" not in before_secrets:
    raise SystemExit("unattended posture must run before the secret-bearing deploy step")
if "scripts/verify-github-release-posture.sh" not in before_secrets:
    raise SystemExit("posture check must run before the secret-bearing deploy step")
if "AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64: ${{ secrets.AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64 }}" in before_secrets:
    raise SystemExit("feed key must not be in env before the deploy step")
seal_idx = workflow.find("- name: Seal reviewed OpenSSL 3")
posture_idx = workflow.find("- name: Verify protected GitHub release posture")
setup_go_idx = workflow.find("- name: Set up Go for the Tier-2 signature verifier")
seal_go_idx = workflow.find("- name: Seal the Tier-2 verifier toolchain")
if posture_idx < 0 or seal_idx < 0 or posture_idx > seal_idx:
    raise SystemExit("posture check must run before OpenSSL seal")
if min(setup_go_idx, seal_go_idx) < 0 or setup_go_idx > seal_go_idx:
    raise SystemExit("setup-go must run before the Go verifier is sealed")
if seal_go_idx > seal_idx:
    raise SystemExit("sealed Go verifier must be installed before OpenSSL seal / deploy")
if "CATALOG_RELEASE_REQUIRE_SEALED_GO_VERIFIER" in before_secrets:
    raise SystemExit("sealed Go requirement must be set only on the secret-bearing deploy step")

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
if "CATALOG_RELEASE_REQUIRE_SEALED_GO_VERIFIER=1" not in deploy:
    raise SystemExit("deploy must require the sealed Go verifier")

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
    # must not ride the scheduled restamp. Both the pre-deploy check and the
    # under-lock recheck run the unit-tested generator rules.
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
    # fetch-depth:1 checkouts have GITHUB_SHA but not origin/main; generate
    # must read the ledger from the same reviewed commit.
    'export CATALOG_RELEASE_BASE_REF="$GITHUB_SHA"',
):
    if requirement not in script:
        raise SystemExit(f"renew script omits: {requirement}")
before_generate = script.split('catalog-release.py "${GENERATE_ARGS[@]}"', 1)[0]
if 'export CATALOG_RELEASE_BASE_REF="$GITHUB_SHA"' not in before_generate:
    raise SystemExit("Actions ledger base must be set before generate")
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
rollback = rendered_rollback
if "aa_rollback() {" not in lib or 'aa_render_rollback_script "$rb_mode"' not in lib:
    raise SystemExit("rollback must run the rendered remote rollback script")
if "flock -n 8" not in rollback or "flock -n 9" not in rollback:
    raise SystemExit("rollback must take Pearl deploy locks before mutating current")
if 'readlink "$root/current"' not in rollback:
    raise SystemExit("rollback must re-read current under lock before restoring")
if "not $expected" not in rollback:
    raise SystemExit("rollback must skip unless current still points at this renewal")
if "restored .previous-target only" not in rollback:
    raise SystemExit("rollback must restore .previous-target when current never swapped")
if 'elif [ "$publish_rc" -eq 1 ]; then' in lib:
    after = lib.split('elif [ "$publish_rc" -eq 1 ]; then', 1)[1]
    else_branch = after.split("else", 1)[1].split("fi", 1)[0]
    if "rollback" in else_branch:
        raise SystemExit("pre-mutation publish failure must not rollback")
if "/tmp/macprovider-autotune-lock-validate." in script:
    raise SystemExit("lock helper must not use a predictable /tmp/$$ path")
if "/etc/macprovider/keys" in script:
    raise SystemExit("renew script must not place the feed key on Pearl")
apply_call = 'python3 -I "$window" apply --root "$root" --incoming "releases/$final" --expect-current "$prev"'
if remote.count(apply_call) != 1:
    raise SystemExit("catalog publish must write the window via autotune_window.py apply")
if remote.find("mutated=1") > remote.find(apply_call):
    raise SystemExit("mutated=1 must be set before writing .previous-target")
if remote.find(apply_call) > remote.find('mv -Tf "$root/.current.next" "$root/current"'):
    raise SystemExit("the previous-target window must be written before the current swap")
restore_call = 'python3 -I "$window" restore --root "$root" --from-file "$prior_window" --expect-current "$cur"'
if rollback.count(restore_call) != 2:
    raise SystemExit("rollback must restore the exact prior window via autotune_window.py restore")
if '< "$SCRIPT_DIR/autotune_window.py"' not in script or 'sha256sum \'$WINDOW_HELPER\'' not in script:
    raise SystemExit("renew must ship autotune_window.py to Pearl and verify its sha256")
# #1688: autotune_window.py is the single .previous-target writer.
for forbidden in ('> "$root/.previous-target"', 'rm -f "$root/.previous-target"', "path.write_text(", "len(out) == 3"):
    if forbidden in script:
        raise SystemExit(f"renew keeps an inline .previous-target writer: {forbidden}")
# #1688 B1: the under-lock recheck runs the shipped, sha-verified
# catalog-release.py continuity-check (Tier-2 content + keyring bytes included),
# never an inline mirror that can drift out of step with feed_continuity_drift.
under_lock = remote.split("Re-check dates-only continuity under the lock", 1)[1].split('mv "$incoming" "$final"', 1)[0]
continuity_call = 'python3 -I "$verifier" continuity-check --incoming "$incoming_path" --live "$root/current"'
if under_lock.count(continuity_call) != 1:
    raise SystemExit("under-lock continuity recheck must run the shipped catalog-release.py continuity-check")
if 'abort_pre_mutation "content drift under lock; not mutating"' not in under_lock:
    raise SystemExit("under-lock continuity drift must abort before mutation (exit 2, no rollback)")
for position in (remote.find("flock -n 8"), remote.find("flock -n 9"), remote.find("current moved under lock")):
    if position < 0 or position > remote.find(continuity_call):
        raise SystemExit("continuity-check must run under both Pearl locks after the current re-read")
if remote.find(continuity_call) > remote.find("mutated=1"):
    raise SystemExit("continuity-check must run before any mutation")
for forbidden in ("<<'PY'", "def norm(", "norm_artifact", "(presence)", 'artifact = "autotune-artifacts.json"'):
    if forbidden in remote:
        raise SystemExit(f"renew keeps an inline continuity mirror on Pearl: {forbidden}")
if 'done < "$SCRIPT_DIR/catalog-verifier-bundle.txt"' not in script:
    raise SystemExit("renew must ship the catalog verifier bundle to Pearl")
bundle_loop = script.split("installing Pearl catalog continuity verifier bundle", 1)[1].split('done < "$SCRIPT_DIR/catalog-verifier-bundle.txt"', 1)[0]
if "sha256sum '$remote_bundle_file'" not in bundle_loop or "does not match the reviewed copy" not in bundle_loop:
    raise SystemExit("every shipped verifier bundle file must be sha256-verified against the reviewed copy")
install_fn = lib.split("aa_install_helpers() {", 1)[1].split("\n}", 1)[0]
if "installing Pearl catalog continuity verifier bundle" not in install_fn:
    raise SystemExit("the verifier bundle must be shipped and verified before the remote publish")
publish_fn = lib.split("aa_publish() {", 1)[1].split("\n}", 1)[0]
if '"$WINDOW_HELPER" "$CONTINUITY_VERIFIER")' not in publish_fn or 'verifier="$8"' not in remote:
    raise SystemExit("the remote publish must receive the shipped continuity verifier path")
if 'rate-card.json tier2-catalog.json trusted-keys.json; do' not in script:
    raise SystemExit("pre-lock live snapshot must include tier2-catalog.json and trusted-keys.json")
# #1688 B2: renewals keep minting a new release_id, so coverage loss is
# reported loudly and NEVER blocks or rolls back the renewal.
import json
import subprocess
coverage_call = 'python3 -I "$window" coverage --admitted-json "$check/admitted.json" --poolz-json "$poolz"'
if remote.count(coverage_call) != 1:
    raise SystemExit("renewal must compute window coverage with the shipped autotune_window.py")
cov_fn = remote.split("renewal_coverage() {", 1)[1].split("\n}", 1)[0]
# Coverage is the LIVE coordinator's admitted set for the final release with
# the planned window (restamps via the live releases/), never the Python mirror.
validator_call = '/opt/macprovider/coordinator --config /opt/macprovider/coordinator.yaml $overlay --validate-autotune-release "$root/releases/$final"'
if cov_fn.count(validator_call) != 1 or '--previous-target "$check/.previous-target"' not in cov_fn:
    raise SystemExit("renewal coverage must dry-load the final release with the planned window in the live coordinator binary")
if 'ln -s "$root/releases" "$check/releases"' not in cov_fn or not (cov_fn.find(validator_call) < cov_fn.find(coverage_call)):
    raise SystemExit("renewal coverage must judge /poolz against the validator's admitted set (live releases/ for restamps)")
if 'install -m 0640 "$root/.row-continuity-target" "$check/.row-continuity-target"' not in cov_fn:
    raise SystemExit("renewal coverage must carry the live .row-continuity-target into the validation root (#1705)")
if "coverage --root" in remote or "--incoming \"releases/$final\" --poolz-json" in remote:
    raise SystemExit("renewal coverage must not use the legacy Python admission mode")
if not (remote.find('mv "$incoming" "$final"') < remote.find(coverage_call) < remote.find(apply_call)):
    raise SystemExit("coverage must run on the final release dir before the window is applied")
if "abort_pre_mutation" in cov_fn or "exit" in cov_fn:
    raise SystemExit("renewal coverage must never abort the publish")
if 'cov_json="$(renewal_coverage)" || cov_rc=$?' not in remote:
    raise SystemExit("renewal coverage failure must be captured, not trip errexit")
if '/proc/$pid/environ' not in cov_fn or "curl --config -" not in cov_fn or "http://127.0.0.1:8444/poolz" not in cov_fn:
    raise SystemExit("renewal coverage must read /poolz on loopback with the running coordinator's key via curl --config stdin")
for leak in ('echo "$key"', "printf '%s' \"$key\"", '-H "Authorization', '"$key" >'):
    if leak in cov_fn:
        raise SystemExit(f"operator key must never be echoed, argv-passed, or written: {leak}")
tail = renew.split('log "previous release retained as .previous-target', 1)[1]
for requirement in ("::warning title=Autotune renewal coverage loss::", "::warning title=Autotune renewal coverage unknown::",
                    '"kind": "renewal_coverage_loss"', "/var/lib/macprovider/catalog-window-overrides.jsonl",
                    "os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600"):
    if requirement not in tail:
        raise SystemExit(f"renewal coverage report omits: {requirement}")
for forbidden in ("fatal", "rollback", "exit 1"):
    if forbidden in tail:
        raise SystemExit(f"renewal coverage report must never fail the renewal: {forbidden}")
classifier = tail.split('RENEW_COVERAGE_RECORDS="$(python3 - "$RENEW_COVERAGE_RC" "$RENEW_COVERAGE_JSON" <<\'PY\'\n', 1)[1].split("\nPY\n", 1)[0]
def classify(rc, report):
    raw = report if isinstance(report, str) else json.dumps(report)
    run = subprocess.run([sys.executable, "-c", classifier, rc, raw], capture_output=True, text=True)
    return run.returncode, run.stdout.strip()
lost = {"release_id": "published-2026-09-02-x", "sha": "ab" * 32, "providers": 2, "routing_eligible": 1}
got = classify("4", {"covered": [], "uncovered": [lost], "advertised_total": 3})
if got != (0, json.dumps([lost], sort_keys=True, separators=(",", ":"))):
    raise SystemExit(f"coverage loss must yield the uncovered records, got {got}")
if classify("0", {"covered": [], "uncovered": [], "advertised_total": 3}) != (0, ""):
    raise SystemExit("full coverage must yield no records")
for rc, report in (("10", ""), ("1", ""), ("", ""), ("4", {"covered": [], "uncovered": [], "advertised_total": 0}),
                   ("0", {"covered": [], "uncovered": [lost], "advertised_total": 1}),
                   ("4", {"covered": [], "uncovered": [dict(lost, release_id="a'b")], "advertised_total": 1}),
                   ("4", {"covered": [], "uncovered": [dict(lost, sha="AB" * 32)], "advertised_total": 1}),
                   ("4", {"covered": [], "uncovered": [dict(lost, providers=True)], "advertised_total": 1}),
                   ("0", "not json")):
    if classify(rc, report)[0] != 3:
        raise SystemExit(f"coverage report must be 'unknown' for rc={rc!r} report={report!r}")
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
if "environment: autotune-feed-renewal" not in runbook:
    raise SystemExit("runbook must name the unattended autotune-feed-renewal environment")
if "approval still pending" in runbook or "antfleet-ops approval" in runbook:
    raise SystemExit("runbook must not describe a human approval gate for signed renewal")
if "/private/var/macprovider-go-verifier" not in runbook:
    raise SystemExit("runbook must name the sealed Go verifier path")
if "CATALOG_RELEASE_REQUIRE_SEALED_GO_VERIFIER" not in runbook:
    raise SystemExit("runbook must require the sealed Go verifier on Actions")
if "CATALOG_RELEASE_BASE_REF" not in runbook:
    raise SystemExit("runbook must bind the Actions ledger base to GITHUB_SHA")
PY

python3 -m py_compile "$helper"
bash -n "$script"
bash -n "$lib"

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
