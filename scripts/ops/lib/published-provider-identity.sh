#!/usr/bin/env bash
# Verify that an installed provider snapshot is the exact published, signed
# release recorded by the CLI release workflow.
#
# The caller must source scripts/ops/lib/common.sh first. This helper uses its
# marker_path, json_field, gh_repo and OPS_TMP_DIR interfaces. On success it
# sets BINARY_SHA, TEAM_ID, SIGNING_IDENTIFIER, CDHASH and EXECUTABLE_PATH.

_published_provider_json_get() {
  printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1],{"d":d}); print(json.dumps(v) if isinstance(v,(dict,list,bool)) else ("" if v is None else v))' "$2" 2>/dev/null || true
}

published_provider_identity_ok() {
  local version="$1" probe_json="$2" install_dir="$3"
  local scope marker bytes pearl pearl_sig checksums asset tarball published
  local release expected_tar_sha actual_tar_sha member_sha candidate_sha checksums_sha
  local release_public_key
  scope="cli-release-$version"
  marker="$(marker_path "$scope" signed_byte_verification)"
  [ -f "$marker" ] || return 1
  bytes="$(json_field "$marker" 'd.get("bytes_dir")')"
  [ -d "$bytes" ] || return 1
  pearl="$bytes/pearl-release.json"; pearl_sig="$bytes/pearl-release.json.sig"
  checksums="$bytes/checksums.txt"
  for asset in "$pearl" "$pearl_sig" "$checksums"; do [ -f "$asset" ] || return 1; done
  published="$OPS_TMP_DIR/published-$version"; mkdir -p "$published"
  gh release download "v$version" -R "$(gh_repo)" -D "$published" \
    --clobber \
    -p checksums.txt -p checksums.txt.sig -p pearl-release.json -p pearl-release.json.sig >/dev/null 2>&1 || return 1
  release_public_key="$REPO_ROOT/ops/pearl-updater/release-signing-public.pem"
  openssl dgst -sha256 -verify "$release_public_key" \
    -signature "$published/checksums.txt.sig" "$published/checksums.txt" >/dev/null 2>&1 || return 1
  openssl dgst -sha256 -verify "$release_public_key" \
    -signature "$published/pearl-release.json.sig" "$published/pearl-release.json" >/dev/null 2>&1 || return 1
  cmp -s "$published/checksums.txt" "$checksums" && cmp -s "$published/pearl-release.json" "$pearl" || return 1
  openssl dgst -sha256 -verify "$release_public_key" \
    -signature "$pearl_sig" "$pearl" >/dev/null 2>&1 || return 1
  [ "$(json_field "$pearl" 'd.get("schema_version")')" = 1 ] || return 1
  [ "$(json_field "$pearl" 'd.get("repository")')" = "$(gh_repo)" ] || return 1
  [ "$(json_field "$pearl" 'd.get("tag")')" = "v$version" ] || return 1
  [ "$(json_field "$pearl" 'd.get("release_version")')" = "$version" ] || return 1
  candidate_sha="$(json_field "$pearl" 'd.get("commit")')"
  case "$candidate_sha" in ""|*[!0-9a-f]*) return 1 ;; esac
  [ "${#candidate_sha}" = 40 ] || return 1
  [ "$candidate_sha" = "$(json_field "$marker" 'd.get("candidate_sha")')" ] || return 1
  checksums_sha="$(shasum -a 256 "$checksums" | awk '{print $1}')"
  [ "$checksums_sha" = "$(json_field "$marker" 'd.get("checksums_sha256")')" ] || return 1
  asset="$(json_field "$pearl" 'd.get("provider_code_identity",{}).get("asset")')"
  [ "$asset" = "macprovider-cli-v$version-darwin-arm64.tar.gz" ] || return 1
  tarball="$bytes/$asset"; [ -f "$tarball" ] || return 1
  expected_tar_sha="$(awk -v a="$asset" '$2 == a {n++; v=$1} END {if (n == 1) print v}' "$checksums")"
  [ -n "$expected_tar_sha" ] || return 1
  actual_tar_sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  [ "$actual_tar_sha" = "$expected_tar_sha" ] || return 1
  BINARY_SHA="$(json_field "$pearl" 'd.get("provider_code_identity",{}).get("binary_sha256")')"
  [ -n "$BINARY_SHA" ] && [ "$(json_field "$marker" 'd.get("binary_sha256")')" = "$BINARY_SHA" ] || return 1
  member_sha="$(python3 - "$tarball" "$(json_field "$pearl" 'd.get("provider_code_identity",{}).get("member")')" <<'PY'
import hashlib, sys, tarfile
archive, member = sys.argv[1:]
with tarfile.open(archive, "r:gz") as bundle:
    matches = [item for item in bundle.getmembers() if item.name == member and item.isfile()]
    if len(matches) != 1:
        raise SystemExit(1)
    source = bundle.extractfile(matches[0])
    if source is None:
        raise SystemExit(1)
    digest = hashlib.sha256()
    for block in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(block)
print(digest.hexdigest())
PY
)" || return 1
  [ "$member_sha" = "$BINARY_SHA" ] || return 1
  [ "$(json_field "$pearl" 'd.get("provider_code_identity",{}).get("binary_version")')" = "$version" ] || return 1
  [ "$(json_field "$pearl" 'd.get("provider_advertised_version")')" = "$version" ] || return 1
  TEAM_ID="$(json_field "$pearl" 'd.get("provider_code_identity",{}).get("team_id")')"
  SIGNING_IDENTIFIER="$(json_field "$pearl" 'd.get("provider_code_identity",{}).get("signing_identifier")')"
  CDHASH="$(json_field "$pearl" 'next((s.get("code_cdhash") for s in d["provider_code_identity"].get("slices",[]) if s.get("arch")=="arm64"), None)')"
  EXECUTABLE_PATH="$install_dir/macprovider-cli"
  [ "$(_published_provider_json_get "$probe_json" 'd["installed"]["binary_sha256"]')" = "$BINARY_SHA" ] || return 1
  [ "$(_published_provider_json_get "$probe_json" 'd["installed"]["binary_version"]')" = "$version" ] || return 1
  [ -n "$TEAM_ID" ] && [ "$(_published_provider_json_get "$probe_json" 'd["installed"]["team_id"]')" = "$TEAM_ID" ] || return 1
  [ -n "$SIGNING_IDENTIFIER" ] && [ "$(_published_provider_json_get "$probe_json" 'd["installed"]["identifier"]')" = "$SIGNING_IDENTIFIER" ] || return 1
  [ -n "$CDHASH" ] && [ "$(_published_provider_json_get "$probe_json" 'd["installed"]["cdhash"]')" = "$CDHASH" ] || return 1
  [ "$(_published_provider_json_get "$probe_json" 'd["launch"]["executable_path"]')" = "$EXECUTABLE_PATH" ] || return 1
  [ "$(_published_provider_json_get "$probe_json" 'd["launch"]["pid"]')" = "$(_published_provider_json_get "$probe_json" 'd["status"]["service_instance.pid"]')" ] || return 1
  release="$(gh release view "v$version" -R "$(gh_repo)" --json tagName,isDraft,isPrerelease,publishedAt 2>/dev/null)" || return 1
  [ "$(_published_provider_json_get "$release" 'd["tagName"]')" = "v$version" ] &&
    [ "$(_published_provider_json_get "$release" 'd["isDraft"]')" = false ] &&
    [ "$(_published_provider_json_get "$release" 'd["isPrerelease"]')" = false ] &&
    [ -n "$(_published_provider_json_get "$release" 'd["publishedAt"]')" ]
}
