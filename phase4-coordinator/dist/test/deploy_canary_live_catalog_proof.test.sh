#!/usr/bin/env bash
# Step 8's canary proof (deploy-pearl-vps.sh) proves what the live canary
# process loaded, not what a CLI payload installed. Running providers select
# the coordinator's live signed catalog (loadSignedStatic) and keep it in
# memory; only a signed CLI payload writes ~/macprovider/catalog-release. A
# byte comparison against that directory failed every catalog-only release
# (v1.8.194 rollback, 2026-09-25), so the proof must:
#   - not read or hash the installed catalog-release files;
#   - require the live status catalog state=live_verified, source=coordinator;
#   - keep the provider/PID/text-vnode/session/envelope bindings.
# Behavioural: the extracted comparator is run against synthetic proofs.
set -euo pipefail
DEPLOY="$(cd "$(dirname "$0")/.." && pwd -P)/deploy-pearl-vps.sh"
python3 - "$DEPLOY" <<'PY'
import json, os, re, subprocess, sys, tempfile
s = open(sys.argv[1], encoding="utf-8").read()
fn_start = s.index("run_catalog_canary_mac_proof() {")
fn = s[fn_start:s.index("\nPY\n}\n", fn_start)]
assert "names = (" not in fn, "Mac proof must not hash installed catalog-release files"
assert "catalog_fd" not in fn and '"files"' not in fn, "Mac proof must not emit installed-file hashes"
for needle in (
    'catalog.get("state") != "live_verified"',
    'catalog.get("source") != "coordinator"',
    'catalog.get("release_id") != expected_release_id',
    'catalog.get("digest") != expected_digest',
    'catalog.get("signer_key_id") != expected_signer',
    "running_text_vnode_path(pid, binary_info, expected_binary)",
    "canary provider identity mismatch",
):
    assert needle in fn, "Mac proof lost: " + needle
assert "canary catalog byte mismatch" not in s, "deploy must not compare installed catalog bytes"

marker = 'if ! python3 - \\\n  "$CANARY_INSTALLED_BODY" \\\n  "$CANARY_POOL_BODY" \\\n  "$CATALOG_CANARY_PROVIDER_ID" <<\'PY\'\n'
start = s.index(marker) + len(marker)
comparator = s[start:s.index("\nPY\n", start)]

row = "a" * 64
def proof(**catalog_overrides):
    catalog = {"state": "live_verified", "source": "coordinator", "release_id": "rel-new",
               "policy_version": "autotune-policy-v1", "digest": "d" * 64,
               "signer_key_id": "k1", "row_identity": row}
    catalog.update(catalog_overrides)
    return {"provider_id": "canary", "assigned_id": "sess", "launchd_pid": 42,
            "local_status": {"network_state": "buyer_serving",
                             "coordinator": {"connected": True, "session": "sess"},
                             "catalog": catalog}}
pool = {"provider_id": "canary", "assigned_id": "sess", "catalog_row_identity": row,
        "catalog_release_id": "rel-new", "catalog_policy_version": "autotune-policy-v1",
        "catalog_candidate_sha256": "d" * 64, "catalog_signer_key_id": "k1"}

def run(p):
    with tempfile.TemporaryDirectory() as d:
        pp, qp = os.path.join(d, "proof.json"), os.path.join(d, "pool.json")
        json.dump(p, open(pp, "w")); json.dump(pool, open(qp, "w"))
        return subprocess.run([sys.executable, "-c", comparator, pp, qp, "canary"],
                              capture_output=True, text=True).returncode

assert run(proof()) == 0, "live coordinator-sourced proof bound to the admitted envelope must pass"
for label, override in {
    "baked fallback": {"source": "baked"},
    "offline fallback state": {"state": "safe_offline_fallback"},
    "previous release": {"release_id": "rel-old"},
    "different digest": {"digest": "e" * 64},
    "different row": {"row_identity": "b" * 64},
}.items():
    assert run(proof(**override)) != 0, "comparator accepted " + label
print("[deploy_canary_live_catalog_proof] ok: canary proves the live coordinator-loaded catalog, not installed bytes")
PY
