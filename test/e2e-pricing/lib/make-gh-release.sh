#!/usr/bin/env bash
# Build the tier E2 stand-in for a tag's GitHub "Pearl runtime release" assets
# (scripts/verify-pearl-runtime-release.sh contract): the tag's linux binaries,
# its catalog release files, pearl-release.json + checksums.txt and their .sig
# made with the TEST release key (openssl dgst -sha256, the updater's verifier).
# Usage: make-gh-release.sh <tag>
set -euo pipefail
. "$(dirname "$0")/../env.sh"
tag="$1"; bins="$E2E_WORK/bins/$tag"; out="$E2E_WORK/gh-releases/$tag"
[ -d "$bins" ] || e2e_die "no binaries for $tag"
commit="$(git -C "$E2E_REPO" rev-parse "$tag^{commit}")"
rm -rf "$out"; mkdir -p "$out"
# #1721: the full deploy's verify-pearl-runtime-release.sh --deploy-artifacts-dir
# now requires pearl-release.json to bind the stats sidecars too (the signed
# updater installs them; the deploy only byte-compares). Same bytes
# install-runtime-pair.sh installs on the VM from $E2E_WORK/bins/$tag.
cp "$bins/coordinator-linux-amd64" "$bins/coordinator-cli-linux-amd64" "$bins/gateway-linux-amd64" \
   "$bins/stats-inventory-sync-linux-amd64" "$bins/stats-billing-mirror-linux-amd64" "$bins/stats-hardware-verifier-linux-amd64" "$out/"
for f in release.json trusted-keys.json tier2-catalog.json; do git -C "$E2E_REPO" show "$tag:phase3-binary/catalog/autotune/$f" >"$out/$f"; done
for f in autotune-candidates.json autotune-candidates.json.sig demand-rank.json demand-rank.json.sig rate-card.json rate-card.json.sig; do
  git -C "$E2E_REPO" show "$tag:phase3-binary/dist/static/$f" >"$out/$f"
done
python3 - "$out" "$tag" "$commit" <<'PY'
import hashlib, json, os, sys
d, tag, commit = sys.argv[1:]
h = lambda n: hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest()
cat = ["release.json", "trusted-keys.json", "tier2-catalog.json", "autotune-candidates.json", "autotune-candidates.json.sig",
       "demand-rank.json", "demand-rank.json.sig", "rate-card.json", "rate-card.json.sig"]
v = tag[1:]
meta = {"schema_version": 1, "release_lane": "pearl_runtime_catalog", "repository": "Augustas11/macprovider", "tag": tag,
        "commit": commit, "architecture": "linux-amd64", "release_version": v, "provider_advertised_version": v,
        "components": {"coordinator": {"asset": "coordinator-linux-amd64", "sha256": h("coordinator-linux-amd64")},
                       "gateway": {"asset": "gateway-linux-amd64", "sha256": h("gateway-linux-amd64")}},
        "operator_artifacts": {"coordinator_cli": {"asset": "coordinator-cli-linux-amd64", "sha256": h("coordinator-cli-linux-amd64")},
                               "stats_inventory_sync": {"asset": "stats-inventory-sync-linux-amd64", "sha256": h("stats-inventory-sync-linux-amd64")},
                               "stats_billing_mirror": {"asset": "stats-billing-mirror-linux-amd64", "sha256": h("stats-billing-mirror-linux-amd64")},
                               "stats_hardware_verifier": {"asset": "stats-hardware-verifier-linux-amd64", "sha256": h("stats-hardware-verifier-linux-amd64")}},
        "catalog": {"files": {n: h(n) for n in cat}}}
json.dump(meta, open(os.path.join(d, "pearl-release.json"), "w"), indent=2, sort_keys=True)
PY
openssl dgst -sha256 -sign "$E2E_KEYS/release-signing.key" -out "$out/pearl-release.json.sig" "$out/pearl-release.json"
(cd "$out" && for n in *; do case "$n" in checksums.txt*) ;; *) printf '%s  %s\n' "$(shasum -a 256 "$n" | cut -d' ' -f1)" "$n" ;; esac; done) >"$out/checksums.txt"
openssl dgst -sha256 -sign "$E2E_KEYS/release-signing.key" -out "$out/checksums.txt.sig" "$out/checksums.txt"
e2e_log "gh release stand-in for $tag at $out"
