#!/usr/bin/env bash
# Build the tier E2 stand-in for a tag's GitHub "Pearl runtime release" assets
# (scripts/verify-pearl-runtime-release.sh contract): the tag's linux binaries,
# its catalog release files, pearl-release.json + checksums.txt and their .sig
# made with the TEST release key (openssl dgst -sha256, the updater's verifier).
# A stand-in provider CLI tarball carries the signed provider_code_identity (#1842).
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
catalog_static=(autotune-candidates.json autotune-candidates.json.sig demand-rank.json demand-rank.json.sig rate-card.json rate-card.json.sig)
if python3 - "$out/release.json" <<'PY'
import json, sys
feeds = json.load(open(sys.argv[1], encoding="utf-8")).get("feeds", {})
raise SystemExit(0 if "continuous-batching-policy.json" in feeds else 1)
PY
then
  catalog_static+=(continuous-batching-policy.json continuous-batching-policy.json.sig)
fi
for f in "${catalog_static[@]}"; do
  git -C "$E2E_REPO" show "$tag:phase3-binary/dist/static/$f" >"$out/$f"
done
# #1842: a catalog-lane release ships the provider CLI and, from 1.8.214 on,
# MUST sign its provider_code_identity (SPEC-025 §6.2.1); the E2E tags are
# v90.x. Tier E2 has no Developer ID, so a stand-in CLI goes through the real
# producer (scripts/provider-code-identity.py) with fake codesign/lipo on PATH,
# exactly as scripts/tests/test_provider_code_identity.py drives it.
provider_cli_asset="macprovider-cli-${tag}-darwin-arm64.tar.gz"
cli_stage="$(mktemp -d "${TMPDIR:-/tmp}/e2e-provider-cli.XXXXXX")"
trap 'rm -rf "$cli_stage"' EXIT
mkdir -p "$cli_stage/payload" "$cli_stage/bin"
printf 'e2e stand-in macprovider-cli %s\n' "$tag" >"$cli_stage/payload/macprovider-cli"
chmod 755 "$cli_stage/payload/macprovider-cli"
tar -czf "$out/$provider_cli_asset" -C "$cli_stage/payload" macprovider-cli
cat >"$cli_stage/bin/lipo" <<'SH'
#!/bin/sh
[ "$1" = -archs ] || { echo "e2e fake lipo: unexpected argv: $*" >&2; exit 2; }
echo arm64
SH
cat >"$cli_stage/bin/codesign" <<'SH'
#!/bin/sh
[ "$1" = -d ] && [ "$2" = --arch ] && [ "$3" = arm64 ] && [ "$4" = -vvv ] ||
  { echo "e2e fake codesign: unexpected argv: $*" >&2; exit 2; }
{
  echo "Executable=$5"
  echo "Identifier=live.malibu.provider.cli"
  echo "Format=Mach-O thin (arm64)"
  echo "CDHash=$(shasum -a 256 "$5" | cut -c1-40)"
  echo "TeamIdentifier=$E2E_FAKE_TEAM_ID"
} >&2
SH
chmod 755 "$cli_stage/bin/lipo" "$cli_stage/bin/codesign"
PATH="$cli_stage/bin:$PATH" E2E_FAKE_TEAM_ID=E2ETEAM001 \
  python3 "$E2E_SRC_REPO/scripts/provider-code-identity.py" \
    --tarball "$out/$provider_cli_asset" \
    --binary-version "${tag#v}" \
    --expected-team-id E2ETEAM001 \
    --expect-sha256 "$(shasum -a 256 "$cli_stage/payload/macprovider-cli" | cut -d' ' -f1)" \
    --output "$cli_stage/provider-code-identity.json"
python3 - "$out" "$tag" "$commit" "$cli_stage/provider-code-identity.json" <<'PY'
import hashlib, json, os, sys
d, tag, commit, code_identity = sys.argv[1:]
h = lambda n: hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest()
cat = ["release.json", "trusted-keys.json", "tier2-catalog.json", "autotune-candidates.json", "autotune-candidates.json.sig",
       "demand-rank.json", "demand-rank.json.sig", "rate-card.json", "rate-card.json.sig"]
feeds = json.load(open(os.path.join(d, "release.json"), encoding="utf-8")).get("feeds", {})
if "continuous-batching-policy.json" in feeds:
    cat += ["continuous-batching-policy.json", "continuous-batching-policy.json.sig"]
v = tag[1:]
meta = {"schema_version": 1, "release_lane": "pearl_runtime_catalog", "repository": "Augustas11/macprovider", "tag": tag,
        "commit": commit, "architecture": "linux-amd64", "release_version": v, "provider_advertised_version": v,
        "components": {"coordinator": {"asset": "coordinator-linux-amd64", "sha256": h("coordinator-linux-amd64")},
                       "gateway": {"asset": "gateway-linux-amd64", "sha256": h("gateway-linux-amd64")}},
        "operator_artifacts": {"coordinator_cli": {"asset": "coordinator-cli-linux-amd64", "sha256": h("coordinator-cli-linux-amd64")},
                               "stats_inventory_sync": {"asset": "stats-inventory-sync-linux-amd64", "sha256": h("stats-inventory-sync-linux-amd64")},
                               "stats_billing_mirror": {"asset": "stats-billing-mirror-linux-amd64", "sha256": h("stats-billing-mirror-linux-amd64")},
                               "stats_hardware_verifier": {"asset": "stats-hardware-verifier-linux-amd64", "sha256": h("stats-hardware-verifier-linux-amd64")}},
        "catalog": {"files": {n: h(n) for n in cat}},
        "provider_code_identity": json.load(open(code_identity, encoding="utf-8"))}
json.dump(meta, open(os.path.join(d, "pearl-release.json"), "w"), indent=2, sort_keys=True)
PY
openssl dgst -sha256 -sign "$E2E_KEYS/release-signing.key" -out "$out/pearl-release.json.sig" "$out/pearl-release.json"
(cd "$out" && for n in *; do case "$n" in checksums.txt*) ;; *) printf '%s  %s\n' "$(shasum -a 256 "$n" | cut -d' ' -f1)" "$n" ;; esac; done) >"$out/checksums.txt"
openssl dgst -sha256 -sign "$E2E_KEYS/release-signing.key" -out "$out/checksums.txt.sig" "$out/checksums.txt"
e2e_log "gh release stand-in for $tag at $out"
