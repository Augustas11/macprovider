#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$root/scripts/verify-live-coordinator-release-gate.py"
workflow="$root/.github/workflows/release.yml"
promotion_workflow="$root/.github/workflows/promote-acceptance-candidate.yml"
rollout_workflow="$root/.github/workflows/verify-live-coordinator-release-rollout.yml"
work="$(mktemp -d "${TMPDIR:-/tmp}/live-coordinator-release-gate.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$0"
python3 -m py_compile "$guard"

make_fixture() {
  local directory="$1"
  local tag="${2:-v1.8.68}"
  local live_version="${3:-v1.8.68}"
  local generated_at="${4:-2026-07-30T12:00:00Z}"
  local demand_generated_at="${5:-$generated_at}"
  local signer="${6:-streamvc-autotune-static-v4}"
  local recommended_version="${7:-${tag#v}}"
  rm -rf "$directory"
  mkdir -p "$directory/live"
  python3 - "$directory" "$tag" "$live_version" "$generated_at" "$demand_generated_at" "$signer" "$recommended_version" <<'PY'
import hashlib
import json
import base64
import pathlib
import subprocess
import sys

directory = pathlib.Path(sys.argv[1])
tag = sys.argv[2]
live_version = sys.argv[3]
generated_at = sys.argv[4]
demand_generated_at = sys.argv[5]
signer = sys.argv[6]
recommended_version = sys.argv[7]
live = directory / "live"
policy_version = "autotune-policy-v1"
key_path = directory / "autotune-test-ed25519.pem"
subprocess.run(
    ["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(key_path)],
    check=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    text=True,
)
public_der = subprocess.check_output(
    ["openssl", "pkey", "-in", str(key_path), "-pubout", "-outform", "DER"],
)
public_key_base64 = base64.b64encode(public_der[-32:]).decode("ascii")

def write_endpoint(name, value):
    (live / name).write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )

write_endpoint("v1_autotune-candidates", {
    "version": "fixture-release",
    "generated_at": generated_at,
    "policy_version": policy_version,
    "source": "fixture",
    "rows": {},
})
write_endpoint("v1_demand-rank", {
    "version": "fixture-release",
    "generated_at": demand_generated_at,
    "policy_version": policy_version,
    "source": "fixture",
    "cold_start_floor": 0.15,
    "diversification_band": 0.85,
    "rows": {},
})
write_endpoint("v1_rate-card", {
    "version": "fixture-rate-card",
    "generated_at": generated_at,
    "policy_version": policy_version,
    "usd_per_million_credits": 1.0,
    "rows": {
        "default": {
            "prompt_rate_per_mtok": 1,
            "prompt_cache_hit_rate_per_mtok": 1,
            "completion_rate_per_mtok": 1,
            "provider_share_bps": 9000,
            "global_multiplier_ppm": 1000000,
        }
    },
})

for feed_name, sig_name in (
    ("v1_autotune-candidates", "v1_autotune-candidates.sig"),
    ("v1_demand-rank", "v1_demand-rank.sig"),
    ("v1_rate-card", "v1_rate-card.sig"),
):
    signature = subprocess.check_output(
        [
            "openssl",
            "pkeyutl",
            "-sign",
            "-inkey",
            str(key_path),
            "-rawin",
            "-in",
            str(live / feed_name),
        ],
    )
    write_endpoint(sig_name, {
        "alg": "ed25519",
        "key_id": signer,
        "signature": base64.b64encode(signature).decode("ascii"),
    })
healthz = {"status": "ok", "version": live_version}
if recommended_version != "__absent__":
    healthz["recommended_binary_version"] = recommended_version
write_endpoint("healthz.json", healthz)

(directory / "trusted-keys.json").write_text(
    json.dumps({
        "schema_version": "macprovider.autotune-keys.v1",
        "keys": {
            "streamvc-autotune-static-v4": {
                "status": "active",
                "public_key_base64": public_key_base64,
            }
        },
    }, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
endpoint_to_asset = {
    "autotune-candidates.json": "v1_autotune-candidates",
    "autotune-candidates.json.sig": "v1_autotune-candidates.sig",
    "demand-rank.json": "v1_demand-rank",
    "demand-rank.json.sig": "v1_demand-rank.sig",
    "rate-card.json": "v1_rate-card",
    "rate-card.json.sig": "v1_rate-card.sig",
}
files = {
    asset: hashlib.sha256((live / endpoint).read_bytes()).hexdigest()
    for asset, endpoint in endpoint_to_asset.items()
}
files["trusted-keys.json"] = hashlib.sha256((directory / "trusted-keys.json").read_bytes()).hexdigest()
metadata = {
    "schema_version": 1,
    "release_lane": "pearl_runtime_catalog",
    "repository": "Augustas11/macprovider",
    "tag": tag,
    "release_version": tag.removeprefix("v"),
    "provider_advertised_version": tag.removeprefix("v"),
    "commit": "a" * 40,
    "architecture": "linux-amd64",
    "catalog": {
        "release_id": "fixture-release",
        "policy_version": policy_version,
        "files": files,
    },
}
(directory / "pearl-release.json").write_text(
    json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}

run_guard() {
  local directory="$1"
  run_guard_phase "$directory" post-publication
}

run_guard_phase() {
  local directory="$1"
  local phase="$2"
  python3 "$guard" \
    --tag v1.8.68 \
    --pearl-release-json "$directory/pearl-release.json" \
    --trusted-keys "$directory/trusted-keys.json" \
    --coordinator-url https://coordinator.fixture.invalid \
    --coordinator-dir "$directory/live" \
    --now 2026-07-30T12:05:00Z \
    ${phase:+--expected-previous-recommendation 1.8.67} \
    --publication-phase "$phase"
}

make_fixture "$work/ok"
run_guard "$work/ok" | grep -q 'ok: https://coordinator.fixture.invalid serves v1.8.68 feed set'

make_fixture "$work/git-describe-healthz" v1.8.68 v1.8.69-2-gabcdef0
run_guard "$work/git-describe-healthz" | grep -q 'healthz_version=v1.8.69-2-gabcdef0'

make_fixture "$work/prerelease-healthz" v1.8.68 v1.8.68-rc.1
if run_guard "$work/prerelease-healthz" >"$work/prerelease-healthz.out" 2>&1; then
  fail "accepted a prerelease coordinator health version"
fi
grep -q "/healthz version is not vX.Y.Z or X.Y.Z: 'v1.8.68-rc.1'" "$work/prerelease-healthz.out"

make_fixture "$work/dirty-healthz" v1.8.68 v1.8.68-dirty
if run_guard "$work/dirty-healthz" >"$work/dirty-healthz.out" 2>&1; then
  fail "accepted a dirty coordinator health version"
fi
grep -q "/healthz version is not vX.Y.Z or X.Y.Z: 'v1.8.68-dirty'" "$work/dirty-healthz.out"

make_fixture "$work/padded-healthz" v1.8.68 " v1.8.68 "
if run_guard "$work/padded-healthz" >"$work/padded-healthz.out" 2>&1; then
  fail "accepted a padded coordinator health version"
fi
grep -q "/healthz version is not vX.Y.Z or X.Y.Z: ' v1.8.68 '" "$work/padded-healthz.out"

make_fixture "$work/missing-sig"
rm "$work/missing-sig/live/v1_rate-card.sig"
if run_guard "$work/missing-sig" >"$work/missing-sig.out" 2>&1; then
  fail "accepted a live coordinator missing rate-card.sig"
fi
grep -q 'fixture coordinator response is missing for /v1/rate-card.sig' "$work/missing-sig.out"

make_fixture "$work/stale-healthz" v1.8.68 v1.8.67
if run_guard "$work/stale-healthz" >"$work/stale-healthz.out" 2>&1; then
  fail "accepted a coordinator older than the shipped CLI release"
fi
grep -q "/healthz version 'v1.8.67' is older than release 1.8.68" "$work/stale-healthz.out"

make_fixture "$work/missing-recommended" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:00Z streamvc-autotune-static-v4 __absent__
if run_guard "$work/missing-recommended" >"$work/missing-recommended.out" 2>&1; then
  fail "accepted a live coordinator without recommended_binary_version"
fi
grep -q '/healthz recommended_binary_version is missing or not a version string' "$work/missing-recommended.out"
if run_guard_phase "$work/missing-recommended" pre-publication >"$work/missing-recommended-pre.out" 2>&1; then
  fail "pre-publication gate accepted a coordinator without the previous recommendation"
fi
grep -q 'recommended_binary_version is missing or not the expected previous stable version' \
  "$work/missing-recommended-pre.out"

make_fixture "$work/previous-recommended" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:00Z streamvc-autotune-static-v4 1.8.67
if ! run_guard_phase "$work/previous-recommended" pre-publication >"$work/previous-recommended.out" 2>&1; then
  fail "pre-publication gate rejected the previous stable recommendation"
fi
grep -q 'recommended_binary_version=1.8.67 publication_phase=pre-publication' \
  "$work/previous-recommended.out"

make_fixture "$work/malformed-recommended" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:00Z streamvc-autotune-static-v4 latest
if run_guard "$work/malformed-recommended" >"$work/malformed-recommended.out" 2>&1; then
  fail "accepted a malformed recommended_binary_version"
fi
grep -q "/healthz recommended_binary_version is not X.Y.Z: 'latest'" "$work/malformed-recommended.out"

make_fixture "$work/suffixed-recommended" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:00Z streamvc-autotune-static-v4 1.8.68-2-gabcdef0
if run_guard "$work/suffixed-recommended" >"$work/suffixed-recommended.out" 2>&1; then
  fail "accepted a git-describe recommended_binary_version"
fi
grep -q "/healthz recommended_binary_version is not X.Y.Z: '1.8.68-2-gabcdef0'" "$work/suffixed-recommended.out"

make_fixture "$work/zero-padded-tag" v01.8.68 v1.8.68
if python3 "$guard" \
  --tag v01.8.68 \
  --pearl-release-json "$work/zero-padded-tag/pearl-release.json" \
  --trusted-keys "$work/zero-padded-tag/trusted-keys.json" \
  --coordinator-url https://coordinator.fixture.invalid \
  --coordinator-dir "$work/zero-padded-tag/live" \
  --now 2026-07-30T12:05:00Z \
  >"$work/zero-padded-tag.out" 2>&1; then
  fail "accepted a zero-padded release tag"
fi
grep -q -- '--tag must be vX.Y.Z' "$work/zero-padded-tag.out"

make_fixture "$work/stale-recommended" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:00Z streamvc-autotune-static-v4 1.8.67
if run_guard "$work/stale-recommended" >"$work/stale-recommended.out" 2>&1; then
  fail "accepted a live coordinator recommending an older CLI than the release"
fi
grep -q "/healthz recommended_binary_version '1.8.67' does not match release 1.8.68" "$work/stale-recommended.out"

make_fixture "$work/padded-recommended" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:00Z streamvc-autotune-static-v4 " 1.8.68 "
if run_guard "$work/padded-recommended" >"$work/padded-recommended.out" 2>&1; then
  fail "accepted a live coordinator with padded recommended_binary_version"
fi
grep -q "/healthz recommended_binary_version is not X.Y.Z: ' 1.8.68 '" "$work/padded-recommended.out"

make_fixture "$work/zero-padded-recommended" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:00Z streamvc-autotune-static-v4 01.8.68
if run_guard "$work/zero-padded-recommended" >"$work/zero-padded-recommended.out" 2>&1; then
  fail "accepted a live coordinator with zero-padded recommended_binary_version"
fi
grep -q "/healthz recommended_binary_version is not X.Y.Z: '01.8.68'" "$work/zero-padded-recommended.out"

make_fixture "$work/future-recommended" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:00Z streamvc-autotune-static-v4 1.8.69
if run_guard "$work/future-recommended" >"$work/future-recommended.out" 2>&1; then
  fail "accepted a live coordinator recommending a different CLI than the release"
fi
grep -q "/healthz recommended_binary_version '1.8.69' does not match release 1.8.68" "$work/future-recommended.out"

make_fixture "$work/hash-drift"
printf '\n' >> "$work/hash-drift/live/v1_rate-card"
if run_guard "$work/hash-drift" >"$work/hash-drift.out" 2>&1; then
  fail "accepted live feed bytes that differ from release metadata"
fi
grep -q 'live coordinator /v1/rate-card sha256 .* does not match release metadata' "$work/hash-drift.out"

make_fixture "$work/unpaired" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:01Z
if run_guard "$work/unpaired" >"$work/unpaired.out" 2>&1; then
  fail "accepted feeds that are not mutually paired"
fi
grep -q 'feed set is not mutually paired by generated_at and policy_version' "$work/unpaired.out"

make_fixture "$work/future-feed" v1.8.68 v1.8.68 2026-07-30T12:15:01Z
if run_guard "$work/future-feed" >"$work/future-feed.out" 2>&1; then
  fail "accepted a live feed generated more than 10 minutes in the future"
fi
grep -q "generated_at '2026-07-30T12:15:01Z' is more than 10 minutes in the future" "$work/future-feed.out"

make_fixture "$work/stale-feed" v1.8.68 v1.8.68 2026-06-30T12:04:59Z
if run_guard "$work/stale-feed" >"$work/stale-feed.out" 2>&1; then
  fail "accepted a live feed generated more than 30 days ago"
fi
grep -q "generated_at '2026-06-30T12:04:59Z' is more than 30 days old" "$work/stale-feed.out"

make_fixture "$work/bad-signature"
python3 - "$work/bad-signature" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
sig_path = directory / "live" / "v1_rate-card.sig"
sidecar = json.loads(sig_path.read_text(encoding="utf-8"))
sidecar["signature"] = base64.b64encode(b"\0" * 64).decode("ascii")
sig_path.write_text(json.dumps(sidecar, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
metadata_path = directory / "pearl-release.json"
metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
metadata["catalog"]["files"]["rate-card.json.sig"] = hashlib.sha256(sig_path.read_bytes()).hexdigest()
metadata_path.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
if run_guard "$work/bad-signature" >"$work/bad-signature.out" 2>&1; then
  fail "accepted a metadata-bound signature sidecar that does not verify"
fi
grep -q 'rate-card.json.sig signature verification failed' "$work/bad-signature.out"

make_fixture "$work/unknown-signer" v1.8.68 v1.8.68 2026-07-30T12:00:00Z 2026-07-30T12:00:00Z unknown-static-key
if run_guard "$work/unknown-signer" >"$work/unknown-signer.out" 2>&1; then
  fail "accepted a signature key outside the release trusted keyring"
fi
grep -q "key_id 'unknown-static-key' is not in the release trusted keyring" "$work/unknown-signer.out"

make_fixture "$work/disabled-key"
python3 - "$work/disabled-key" <<'PY'
import hashlib
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
trusted = directory / "trusted-keys.json"
value = json.loads(trusted.read_text(encoding="utf-8"))
value["keys"]["streamvc-autotune-static-v4"]["status"] = "disabled"
trusted.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
metadata = json.loads((directory / "pearl-release.json").read_text(encoding="utf-8"))
metadata["catalog"]["files"]["trusted-keys.json"] = hashlib.sha256(trusted.read_bytes()).hexdigest()
(directory / "pearl-release.json").write_text(
    json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
if run_guard "$work/disabled-key" >"$work/disabled-key.out" 2>&1; then
  fail "accepted an unsupported trusted key status"
fi
grep -q "status is unsupported: 'disabled'" "$work/disabled-key.out"

make_fixture "$work/keyring-drift"
python3 - "$work/keyring-drift/trusted-keys.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["keys"]["streamvc-autotune-static-extra"] = {
    "status": "active",
    "public_key_base64": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
}
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
if run_guard "$work/keyring-drift" >"$work/keyring-drift.out" 2>&1; then
  fail "accepted trusted-keys.json that differs from release metadata"
fi
grep -q 'trusted-keys.json sha256 .* does not match release metadata' "$work/keyring-drift.out"

make_fixture "$work/http-policy"
if python3 "$guard" \
  --tag v1.8.68 \
  --pearl-release-json "$work/http-policy/pearl-release.json" \
  --trusted-keys "$work/http-policy/trusted-keys.json" \
  --coordinator-url http://coordinator.fixture.invalid \
  >"$work/http-policy.out" 2>&1; then
  fail "accepted a non-HTTPS live coordinator URL"
fi
grep -q -- '--coordinator-url must use https:// for live verification' "$work/http-policy.out"

python3 - "$guard" <<'PY'
import importlib.util
import types
import urllib.error
import sys

spec = importlib.util.spec_from_file_location("live_gate", sys.argv[1])
live_gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live_gate)

captured_headers = {}

class RedirectingOpener:
    def open(self, request, timeout):
        captured_headers.update(request.header_items())
        raise urllib.error.HTTPError(
            request.full_url,
            302,
            "Found",
            {"Location": "https://coordinator.fixture.invalid/other"},
            None,
        )

live_gate.urllib.request.build_opener = lambda *args, **kwargs: RedirectingOpener()
args = types.SimpleNamespace(
    coordinator_dir=None,
    coordinator_url="https://coordinator.fixture.invalid",
    timeout_s=1,
    max_bytes=1024,
)
try:
    live_gate.load_endpoint(args, "/v1/rate-card")
except live_gate.GateError as exc:
    message = str(exc)
else:
    raise SystemExit("accepted redirected live coordinator response")
if "redirected with HTTP 302" not in message:
    raise SystemExit(f"expected redirect rejection, got: {message}")
if captured_headers.get("Cache-control") != "no-cache" or captured_headers.get("Pragma") != "no-cache":
    raise SystemExit(f"expected no-cache request headers, got: {captured_headers}")
if captured_headers.get("User-agent") not in ("", None):
    raise SystemExit(f"expected no gate-specific user-agent, got: {captured_headers}")
PY

python3 - "$workflow" "$promotion_workflow" "$rollout_workflow" <<'PY'
import pathlib
import sys

def require_stable_gate(
    workflow_path,
    step_name,
    tag_arg,
    pearl_release_arg,
    trusted_keys_arg,
    final_authority_marker=None,
):
    workflow = pathlib.Path(workflow_path).read_text(encoding="utf-8")
    if "Verify pre-publication live coordinator feed gate" not in workflow:
        raise SystemExit(f"{workflow_path} must include the pre-publication live coordinator phase")
    if "Verify post-publication live coordinator release gate" in workflow:
        raise SystemExit(f"{workflow_path} must not run the post-publication gate inline")
    if "scripts/verify-live-coordinator-release-gate.py" not in workflow:
        raise SystemExit(f"{workflow_path} must call the live coordinator release gate")
    publish = workflow.split(f"- name: {step_name}", 1)[1]
    checksum_verify = publish.find("scripts/verify-release-checksums.sh")
    draft_capture = publish.find("scripts/capture-release-publication.py --draft")
    final_authority = (
        publish.find(final_authority_marker)
        if final_authority_marker is not None
        else -1
    )
    public_patch = publish.find("gh api --method PATCH")
    draft_false = publish.find("-F draft=false")
    make_latest = publish.find("-f make_latest")
    published = publish.find("scripts/verify-published-release.py")
    pre_gate_label = publish.find("Verify pre-publication live coordinator feed gate")
    pre_gate = publish.find("scripts/verify-live-coordinator-release-gate.py", pre_gate_label)
    discovery = publish.find("- name: Publish one append-only immutable discovery transport")
    if checksum_verify < 0:
        raise SystemExit(f"{workflow_path} lost signed checksum verification")
    if draft_capture < 0:
        raise SystemExit(f"{workflow_path} lost final draft publication capture")
    if final_authority_marker is not None and final_authority < 0:
        raise SystemExit(f"{workflow_path} lost final exception/source authority gate")
    if public_patch < 0 or draft_false < 0 or make_latest < 0:
        raise SystemExit(f"{workflow_path} lost public/latest publication transition")
    if published < 0:
        raise SystemExit(f"{workflow_path} lost immutable publication verification")
    if pre_gate_label < 0 or pre_gate < 0:
        raise SystemExit(f"{workflow_path} lost pre-publication live coordinator gate")
    if pre_gate < pre_gate_label:
        raise SystemExit("live coordinator gate command must follow its gate label")
    if pre_gate < checksum_verify:
        raise SystemExit("pre-publication gate must run after signed checksum verification")
    if pre_gate < draft_capture:
        raise SystemExit("pre-publication gate must run after final draft publication capture")
    if final_authority_marker is not None and pre_gate < final_authority:
        raise SystemExit("pre-publication gate must run after final exception/source authority gate")
    if pre_gate > public_patch or pre_gate > draft_false or pre_gate > make_latest:
        raise SystemExit("pre-publication gate must run before public/latest publication")
    if published < public_patch:
        raise SystemExit("immutable publication verification must run after publication")
    if discovery >= 0:
        raise SystemExit("append-only discovery transport must be published by the post-publication rollout workflow")
    if "--publication-phase pre-publication" not in publish[pre_gate:]:
        raise SystemExit("pre-publication gate does not select the pre-publication policy")
    for required in (
        tag_arg,
        pearl_release_arg,
        trusted_keys_arg,
        "--coordinator-url https://coordinator.streamvc.live",
        "--openssl \"$OPENSSL_BIN\"",
        "--expected-previous-recommendation 1.8.81",
        "env -u GH_TOKEN -u RELEASE_POSTURE_TOKEN",
    ):
        if required not in publish[pre_gate_label:]:
            raise SystemExit(f"live coordinator gate call is missing {required}")

def require_rollout(workflow_path):
    workflow = pathlib.Path(workflow_path).read_text(encoding="utf-8")
    if "workflow_dispatch:" not in workflow:
        raise SystemExit("post-publication rollout proof must be manually dispatchable")
    if "environment: production-release" not in workflow:
        raise SystemExit("post-publication rollout proof must use the production environment")
    if "concurrency:" not in workflow or "group: production-release" not in workflow:
        raise SystemExit("post-publication rollout proof must share the production serialization")
    if "contents: write" not in workflow or "secrets." in workflow:
        raise SystemExit("post-publication rollout must have only GitHub contents publication authority")
    if "runs-on: macos-15" not in workflow or "runs-on: ubuntu-" in workflow:
        raise SystemExit("rollout anonymous discovery proof must run on the reviewed macOS runner")
    if "ref: refs/heads/main" not in workflow or "fetch-depth: 0" not in workflow:
        raise SystemExit("rollout proof must check out the reviewed main branch with history")
    if "git fetch --no-tags origin refs/heads/main:refs/remotes/origin/main" not in workflow:
        raise SystemExit("rollout proof must refresh the exact main source authority")
    if 'git rev-parse origin/main)" = "$GITHUB_SHA"' not in workflow:
        raise SystemExit("rollout proof must bind source authority to GITHUB_SHA")
    published = workflow.find("scripts/verify-published-release.py")
    download = workflow.find("gh release download")
    post_label = workflow.find("# Pearl recommendation deployment is the serialized external step")
    post_gate = workflow.find("scripts/verify-live-coordinator-release-gate.py", post_label)
    transport_publish = workflow.find("gh release create \"$transport_tag\"")
    final_post_gate = workflow.rfind("scripts/verify-live-coordinator-release-gate.py")
    transport_verify = workflow.find("scripts/verify-release-discovery-transport.py", transport_publish)
    anonymous_verify = workflow.find("scripts/verify-anonymous-release-discovery.sh", transport_verify)
    if published < 0 or download < published:
        raise SystemExit("rollout proof must verify the public release before downloading metadata")
    if post_label < 0 or post_gate < post_label:
        raise SystemExit("rollout proof must mark the external Pearl boundary before the gate")
    if "--publication-phase post-publication" not in workflow[post_gate:]:
        raise SystemExit("rollout proof must select the post-publication policy")
    if transport_publish < post_gate:
        raise SystemExit("discovery transport must publish only after the post-publication gate")
    if workflow.count("--publication-phase post-publication") < 2 or not (
        post_gate < final_post_gate < transport_publish
    ):
        raise SystemExit("rollout must re-check Pearl immediately before discovery publication")
    if transport_verify < transport_publish or anonymous_verify < transport_verify:
        raise SystemExit("rollout must verify the immutable discovery transport and anonymous client path")
    for required in (
        '"repos/$GITHUB_REPOSITORY/releases/tags/$TAG"',
        '"repos/$GITHUB_REPOSITORY/releases/latest"',
        '"repos/$GITHUB_REPOSITORY/releases/$release_id"',
        "pearl-release.json",
        "trusted-keys.json",
        "compatibility-artifact-index.json",
        "macprovider-release-discovery.json",
        "--require-immutable",
        "https://coordinator.streamvc.live",
    ):
        if required not in workflow:
            raise SystemExit(f"rollout proof omits {required}")

require_stable_gate(
    sys.argv[1],
    "Publish only the revalidated numeric draft",
    "--tag \"$tag\"",
    "--pearl-release-json pearl-release.json",
    "--trusted-keys trusted-keys.json",
)
require_stable_gate(
    sys.argv[2],
    "Reverify and publish only the captured numeric draft",
    "--tag \"$TAG\"",
    "--pearl-release-json \"$accepted/pearl-release.json\"",
    "--trusted-keys \"$accepted/trusted-keys.json\"",
    final_authority_marker="origin/main moved under bound exception authority before undraft",
)
require_rollout(sys.argv[3])
PY

echo "PASS: live coordinator release gate"
