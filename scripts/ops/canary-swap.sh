#!/usr/bin/env bash
# Canary swap for the CLI release train (docs/releases/cli-release-train.md
# "Promotion gate" item 5, canary install/join smoke): put the verified signed
# candidate on the canary provider and get it back to buyer_serving, or put
# the previous version back.
#
# Usage:
#   scripts/ops/canary-swap.sh check --version V [--tarball PATH]
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/canary-swap.sh swap --version V
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/canary-swap.sh record-installed --version V
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/canary-swap.sh switch-model <catalog-key> [--artifact-path DIR]
#
# check (read-only, local): the archive holds only regular, relative members,
#   and every shipped metallib (mlx.metallib and the SwiftPM bundle's
#   default.metallib) carries every kernel the pinned MLX core loads by name
#   (scripts/mlx-metallib-kernels.py, phase3-binary/mlx-metallib-required-kernels.json).
#   The 1.8.254 candidate failed exactly this. --tarball checks any archive.
#   check and swap also refuse a candidate whose baked catalog-release/
#   (release_id, release.json and rate-card.json generated_at) differs from
#   what Pearl serves at COORDINATOR_URL /v1/autotune-release and /v1/rate-card:
#   the canary would fail to join with rate_card_update_required (1.8.262).
#   Activate the catalog first (scripts/ops/catalog-activate.sh). One exception,
#   the CLI's own rule: Pearl serves a strictly newer release with the same
#   policy_version and the same rate-card content version, generated no earlier
#   than the baked rate card (a cut that packaged a first native-MTP admission
#   scope, then the rebound catalog went live).
# swap: only the verified candidate bytes recorded by cli-release.sh
#   signed_byte_verification (the tarball sha256 must match the entry in that
#   run's signed checksums.txt). check, then under the live-ops lock: stop the
#   buyer runner, stage the tarball and lib/canary-swap-remote.sh on the canary
#   over STUDIO_SSH and start it detached, so a dropped ssh session cannot cut
#   a swap or a rollback short; this side polls its log and result. The remote
#   pauses and drains, backs up the install dir, swaps the payload, restarts and
#   resumes. A provider process restart or exit (crash loop), or a /v1/status
#   silence of CANARY_STATUS_TIMEOUT_S (default 120) after the candidate
#   reported its model loaded, restores the backup and resumes the previous
#   version once it is buyer_serving again. Silence while the model loads is
#   not a failure (a large model keeps /v1/status silent for minutes): with
#   the same pid alive it is bounded by CANARY_READY_TIMEOUT_S. The buyer runner is
#   restarted on every exit. A successful swap records the canary_swap marker
#   that `cli-release.sh next --done canary_smoke --probe` requires.
# record-installed: the verified bytes are already on the canary. Runs the
#   check, then records the canary_swap marker only when the canary's installed
#   macprovider-cli has the verified sha256 and /v1/status reports version V
#   buyer_serving. Nothing is restarted.
# switch-model: serve another signed catalog row on the canary (`models switch`
#   cannot: a catalog key is fit_unknown and two ~175 GB models cannot be warm
#   swapped). The row comes from this checkout's phase3-binary/dist/static/
#   autotune-candidates.json and must be `recommendable`, the only status a
#   normal provider admits at start, unless the canary's config.yaml sets
#   donor_mode: true; anything else is refused before config.yaml or the
#   provider is touched. The canary's `macprovider-cli models
#   verify-artifact <key>` must exit 0 and agree with it (model id, revision,
#   artifact sha256, catalog release and digest), so the artifact is already
#   downloaded and verified there. Under the live-ops lock it then backs up
#   config.yaml and rewrites all nine identity fields (model, model_artifact_path,
#   model_artifact_sha256, model_catalog_key/_model_id/_revision/_sha256/_version/
#   _hash) in one atomic write validated by the installed CLI; a config missing
#   any of them is refused, never appended (lib/canary-switch-model.py). It
#   kickstarts the provider, waits up to CANARY_READY_TIMEOUT_S for /v1/status
#   buyer_serving with the new model and sha256, then sets the Pearl buyer
#   runner's Studio target model to the row's model id (lib/runner-reserve.sh;
#   RUNNER_STUDIO_PROVIDER_PREFIX, none when no runner feeds the canary). A
#   timeout restores nothing: it exits 6 naming the config backup and the
#   switch back. --artifact-path names a verified snapshot outside the known
#   model roots. Expected downtime is printed first.
#
# Env (or ~/.config/macprovider/ops.env): COORDINATOR_URL, STUDIO_SSH (local = this Mac),
# STUDIO_SSH_KEY, STUDIO_STATUS_PORT, CANARY_RUNNER_STOP_CMD and
# CANARY_RUNNER_START_CMD (run on this Mac; "none" when no buyer runner
# feeds the canary), CANARY_INSTALL_DIR (default ~/macprovider on the canary),
# CANARY_LAUNCHD_LABEL (default live.malibu.provider), CANARY_CTL_SOCKET
# (default the canary user's temp dir macprovider-cli/ctl.sock),
# CANARY_STATUS_TIMEOUT_S (120), CANARY_READY_TIMEOUT_S (1800),
# CANARY_DRAIN_TIMEOUT_S (600), CANARY_STABLE_S (120), CANARY_POLL_S (5);
# switch-model also: CANARY_CONFIG (default ~/.config/macprovider/config.yaml on
# the canary), CANARY_MODELS_LIST_TIMEOUT_S (300, how long the installed CLI may
# take to validate the switched config; exceeding it refuses and writes nothing),
# PEARL_SSH and RUNNER_STUDIO_PROVIDER_PREFIX (lib/runner-reserve.sh).
#
# Exit codes: 0 ok; 2 usage; 3 refused (nothing changed); 4 refused on the
# canary before the swap (provider resumed); 5 candidate failed, previous
# version restored and buyer_serving; 6 recovery needs the operator.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034  # OPS_NAME is read by lib/common.sh
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_NAME=canary-swap
# shellcheck source=lib/common.sh
. "$OPS_DIR/lib/common.sh"
# shellcheck source=lib/runner-reserve.sh
. "$OPS_DIR/lib/runner-reserve.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# switch_model KEY [ARTIFACT_PATH]: see "switch-model" above.
switch_model() {
  local key="$1" override="${2:-}" feed="$REPO_ROOT/phase3-binary/dist/static/autotune-candidates.json"
  local label="${CANARY_LAUNCHD_LABEL:-live.malibu.provider}" ready_s="${CANARY_READY_TIMEOUT_S:-1800}" poll_s="${CANARY_POLL_S:-5}"
  local validate_s="${CANARY_MODELS_LIST_TIMEOUT_S:-300}"
  [[ "$key" =~ ^[a-z0-9][a-z0-9._/-]{0,127}$ ]] || refuse "invalid catalog key: $key"
  [ -z "$override" ] || [[ "$override" =~ ^/[A-Za-z0-9._/\ -]+$ ]] || refuse "--artifact-path must be an absolute plain path"
  [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || refuse "CANARY_LAUNCHD_LABEL is not a plain launchd label"
  case "$ready_s$poll_s$validate_s" in *[!0-9]*) refuse "CANARY_*_S values must be whole seconds" ;; esac
  case "${STUDIO_STATUS_PORT:-}" in ""|*[!0-9]*) refuse "STUDIO_STATUS_PORT must be set and numeric" ;; esac
  [ -n "${MACPROVIDER_OPS_OWNER:-}" ] || refuse "MACPROVIDER_OPS_OWNER is required for switch-model (live-ops lock owner)"
  [ -n "${RUNNER_STUDIO_PROVIDER_PREFIX:-}" ] ||
    refuse "set RUNNER_STUDIO_PROVIDER_PREFIX (the Studio target's provider_id prefix in the Pearl buyer runner targets.json, or none)"
  runner_reserve_enabled && runner_reserve_check
  require_studio_ssh
  python3 -I - "$feed" "$key" > "$OPS_TMP_DIR/switch-row.json" <<'PY' || refuse "no pinned row for $key in phase3-binary/dist/static/autotune-candidates.json"
import hashlib, json, re, sys
raw = open(sys.argv[1], "rb").read()
doc = json.loads(raw)
row = doc["rows"][sys.argv[2]]
if not re.fullmatch(r"[0-9a-f]{64}", row.get("model_sha256") or "") or not row.get("model_revision") or not row.get("model_id"):
    raise SystemExit("unpinned row")
print(json.dumps({"model_id": row["model_id"], "revision": row["model_revision"], "sha256": row["model_sha256"],
                  "runtime_status": row.get("runtime_status"),
                  "version": doc["version"], "catalog_hash": hashlib.sha256(raw).hexdigest()}))
PY
  local model_id sha
  model_id="$(json_field "$OPS_TMP_DIR/switch-row.json" 'd["model_id"]')"
  sha="$(json_field "$OPS_TMP_DIR/switch-row.json" 'd["sha256"]')"
  [[ "$model_id" =~ ^[A-Za-z0-9._/-]{1,160}$ ]] || refuse "catalog model id of $key is not a plain id"
  printf '=== EXPECTED DOWNTIME for switch-model %s: the canary provider restarts and loads %s; until it is buyer_serving again (up to %ss, minutes for a large model) its buyers go to other providers of its model or wait. The Pearl buyer runner restarts once to retarget its Studio target; the Pearl coordinator is not restarted. ===\n' \
    "$key" "$model_id" "$ready_s"
  "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose "$OPS_NAME:switch-model" --bind-pid >&2 ||
    refuse "live-ops lock is held by another owner"
  # shellcheck disable=SC2034  # released by cleanup_ops in lib/common.sh
  OPS_LOCK_OWNER="$MACPROVIDER_OPS_OWNER"
  local remote_env cli cfg
  remote_env="PATH=$(printf '%q' "${CANARY_REMOTE_PATH_PREFIX:+$CANARY_REMOTE_PATH_PREFIX:}")\$PATH; d=$(printf '%q' "${CANARY_INSTALL_DIR:-}"); c=$(printf '%q' "${CANARY_CONFIG:-}");"
  cli='"${d:-$HOME/macprovider}/macprovider-cli"'
  cfg='"${c:-$HOME/.config/macprovider/config.yaml}"'
  local vrc=0
  studio_ssh "$remote_env $cli models verify-artifact $key --json --config $cfg" > "$OPS_TMP_DIR/switch-verify.json" || vrc=$?
  [ "$vrc" = 0 ] || refuse "the $key artifact is not present and verified on the canary (models verify-artifact exit $vrc); download and verify it there first"
  python3 -I - "$OPS_TMP_DIR/switch-verify.json" "$OPS_TMP_DIR/switch-row.json" "$key" "$override" "$validate_s" "$label" "${CANARY_LAUNCHD_PLIST:-}" \
    > "$OPS_TMP_DIR/switch-request.json" 2> "$OPS_TMP_DIR/switch-verify.err" <<'PY' ||
import json, re, sys
v, r = (json.load(open(p)) for p in sys.argv[1:3])
key, override, validate_s = sys.argv[3], sys.argv[4], int(sys.argv[5])
want = {"verdict": "match", "catalog_key": key, "catalog_model_id": r["model_id"], "pinned_revision": r["revision"],
        "signed_hash": r["sha256"], "computed_hash": r["sha256"], "catalog_release": r["version"],
        "catalog_digest": r["catalog_hash"]}
bad = [k for k, value in want.items() if v.get(k) != value]
if bad:
    raise SystemExit("verify-artifact disagrees with this checkout's signed row on: " + ", ".join(bad))
buyer, local = v.get("buyer_model_key"), v.get("local_path")
if not isinstance(buyer, str) or not re.fullmatch(r"[A-Za-z0-9._/@+-]{1,160}", buyer):
    raise SystemExit("verify-artifact names no buyer model key (rate card) for this row")
if not isinstance(local, str) or not local:
    raise SystemExit("verify-artifact names no local snapshot")
values = {"model": buyer, "model_artifact_sha256": r["sha256"], "model_catalog_key": key,
          "model_catalog_model_id": r["model_id"], "model_catalog_revision": r["revision"],
          "model_catalog_sha256": r["sha256"], "model_catalog_version": r["version"],
          "model_catalog_hash": r["catalog_hash"]}
print(json.dumps({"values": values, "local_path": local, "artifact_path": override, "buyer": buyer,
                  "runtime_status": r["runtime_status"], "validate_timeout_s": validate_s,
                  "launchd_label": sys.argv[6], "launchd_plist": sys.argv[7]}))
PY
    refuse "$(tail -n1 "$OPS_TMP_DIR/switch-verify.err")"
  local buyer request arc=0
  buyer="$(json_field "$OPS_TMP_DIR/switch-request.json" 'd["buyer"]')"
  request="$(base64 < "$OPS_TMP_DIR/switch-request.json" | tr -d '\n')"
  studio_ssh "$remote_env python3 - apply $cfg $cli $request" < "$OPS_LIB_DIR/canary-switch-model.py" \
    > "$OPS_TMP_DIR/switch-apply.json" || arc=$?
  case "$arc" in 0) ;; 3) exit 3 ;; *) log "!!! config switch failed on the canary (exit $arc); inspect its config.yaml and any config.yaml.bak-switch-model-* there"; exit 6 ;; esac
  local backup previous
  backup="$(json_field "$OPS_TMP_DIR/switch-apply.json" 'd.get("backup")')"
  previous="$(json_field "$OPS_TMP_DIR/switch-apply.json" 'd["previous_key"]')"
  served_match() {
    studio_ssh "$remote_env curl -fsS -m 10 http://127.0.0.1:$STUDIO_STATUS_PORT/v1/status" 2>/dev/null |
      python3 -c 'import json,sys
d=json.load(sys.stdin); c=d.get("catalog") or {}
sys.exit(0 if d.get("network_state")=="buyer_serving" and d.get("model")==sys.argv[1] and sys.argv[2] in (d.get("model_hash"), c.get("artifact_sha256")) else 1)' "$buyer" "$sha"
  }
  if [ "$(json_field "$OPS_TMP_DIR/switch-apply.json" 'd["changed"]')" = true ]; then
    log "config.yaml switched from $previous to $key (backup $backup on the canary)"
    studio_ssh "$remote_env launchctl kickstart -k gui/\$(id -u)/$label" >&2 ||
      { log "!!! provider kickstart failed after the config switch; nothing was restored: restart it, or restore $backup"; exit 6; }
    log "provider restarted; waiting up to ${ready_s}s for buyer_serving on $buyer ($sha)"
  elif served_match; then
    log "canary already serves $key ($sha) buyer_serving"
  else
    log "config.yaml already names $key; waiting up to ${ready_s}s for buyer_serving on $buyer ($sha)"
  fi
  local deadline=$(( $(date +%s) + ready_s ))
  until served_match; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "!!! canary not buyer_serving on $key within ${ready_s}s; nothing was restored and the buyer runner was not retargeted. Inspect the provider; to go back run: scripts/ops/canary-swap.sh switch-model $previous${backup:+ (config backup $backup)}"
      exit 6
    fi
    sleep "$poll_s"
  done
  log "canary serves $key ($sha) buyer_serving"
  runner_set_studio_model "$model_id" ||
    { log "!!! buyer runner Studio target not retargeted to $model_id; rerun: scripts/ops/canary-swap.sh switch-model $key"; exit 6; }
  log "switch-model $key complete"
}

CMD="${1:-}"
[ "$#" -gt 0 ] && shift
if [ "$CMD" = switch-model ]; then
  SWITCH_KEY="${1:-}"
  [ "$#" -gt 0 ] && shift
  SWITCH_ARTIFACT=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --artifact-path) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; SWITCH_ARTIFACT="$2"; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [ -n "$SWITCH_KEY" ] || { usage >&2; exit 2; }
fi
V=""
TARBALL=""
TARBALL_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; V="$2"; shift 2 ;;
    --tarball) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; TARBALL="$2"; TARBALL_OVERRIDE=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$CMD" in check|swap|record-installed|switch-model|recover-air|restore-air) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
if [ "$CMD" = switch-model ]; then
  switch_model "$SWITCH_KEY" "$SWITCH_ARTIFACT"
  exit 0
fi
if [ "$CMD" = recover-air ] || [ "$CMD" = restore-air ]; then
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] && [ "$V" = 1.8.260 ] || refuse "Air recovery runs only through the guarded Air entrypoint"
  [ -n "${AIR_RECOVERY_PROVIDER_SHA256:-}" ] && [ -n "${AIR_RECOVERY_CONFIG:-}" ] && [ -n "${AIR_RECOVERY_BINARY_SHA256:-}" ] || refuse "Air recovery identity is missing"
  [[ "${AIR_RECOVERY_CONFIG_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || refuse "Air recovery baseline config digest is missing"
fi
is_semver "$V" || { usage >&2; exit 2; }
[ "$CMD" = check ] || [ -z "$TARBALL" ] ||
  refuse "swap takes only the verified candidate bytes; --tarball is for check"

OPS_SCOPE="cli-release-$V"
ASSET="macprovider-cli-v$V-darwin-arm64.tar.gz"
TARBALL_SHA=""

# bind_verified_tarball: TARBALL becomes the verified run's asset, and its
# sha256 must equal the entry in that run's signature-verified checksums.txt.
bind_verified_tarball() {
  local bytes_dir want_checksums got_checksums
  bytes_dir="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("bytes_dir")')"
  want_checksums="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("checksums_sha256")')"
  [ -n "$bytes_dir" ] && [ -d "$bytes_dir" ] && [ -n "$want_checksums" ] ||
    refuse "no verified candidate bytes for v$V; run the cli-release.sh signed_byte_verification step first"
  got_checksums="$(shasum -a 256 "$bytes_dir/checksums.txt" | awk '{print $1}')"
  [ "$got_checksums" = "$want_checksums" ] ||
    refuse "$bytes_dir/checksums.txt is not the signature-verified checksums.txt"
  TARBALL="$bytes_dir/$ASSET"
  [ -f "$TARBALL" ] || refuse "verified candidate tarball not found: $TARBALL"
  TARBALL_SHA="$(awk -v a="$ASSET" '$2 == a { print $1 }' "$bytes_dir/checksums.txt" | head -n1)"
  [ -n "$TARBALL_SHA" ] && [ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" = "$TARBALL_SHA" ] ||
    refuse "$TARBALL does not match its signed checksums.txt entry"
}

# candidate_manifest: the required-kernel manifest of the commit the candidate
# was built from (signed_byte_verification candidate_sha), not this checkout's.
# check --tarball without a verified candidate uses this checkout's manifest.
candidate_manifest() {
  local sha path="phase3-binary/mlx-metallib-required-kernels.json" out="$OPS_TMP_DIR/mlx-required-kernels.json"
  sha="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("candidate_sha")')"
  if [ "$CMD" = check ] && [ -n "$TARBALL_OVERRIDE" ]; then
    printf '%s\n' "$REPO_ROOT/$path"
    return
  fi
  is_sha40 "$sha" || refuse "the signed_byte_verification record names no candidate_sha"
  if git -C "$REPO_ROOT" cat-file -e "$sha:$path" 2>/dev/null; then
    git -C "$REPO_ROOT" show "$sha:$path" >"$out"
  else
    curl -fsSL --proto '=https' --max-time 60 \
      "https://raw.githubusercontent.com/$(gh_repo)/$sha/$path" -o "$out" ||
      refuse "cannot read $path at candidate commit $sha"
  fi
  printf '%s\n' "$out"
}

check_candidate() {
  local payload="$OPS_TMP_DIR/payload" want got libs
  rm -rf "$payload"
  mkdir -p "$payload"
  python3 - "$TARBALL" "$payload" <<'PY' || refuse "$TARBALL has unsafe or unexpected members"
import os, sys, tarfile
src, dest = sys.argv[1], sys.argv[2]
with tarfile.open(src, "r:gz") as tar:
    members, seen = tar.getmembers(), set()
    for m in members:
        name = os.path.normpath(m.name)
        if m.name.startswith("/") or name == ".." or name.startswith("../") or name in seen:
            sys.exit("unsafe member name: %r" % m.name)
        if not (m.isfile() or m.isdir()):
            sys.exit("non-regular member: %r" % m.name)
        seen.add(name)
    for m in members:
        tar.extract(m, dest, set_attrs=False)
PY
  [ -f "$payload/macprovider-cli" ] || refuse "$TARBALL lacks macprovider-cli"
  [ -f "$payload/mlx.metallib" ] || refuse "$TARBALL lacks mlx.metallib"
  if [ "$CMD" != check ]; then
    want="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("binary_sha256")')"
    got="$(shasum -a 256 "$payload/macprovider-cli" | awk '{print $1}')"
    [ -n "$want" ] && [ "$got" = "$want" ] ||
      refuse "macprovider-cli sha256 $got is not the verified candidate binary ${want:-<unrecorded>}"
    BINARY_SHA="$got"
  fi
  libs=("$payload/mlx.metallib")
  if [ -f "$payload/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
    libs+=("$payload/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
  fi
  python3 "$REPO_ROOT/scripts/mlx-metallib-kernels.py" check --manifest "$(candidate_manifest)" "${libs[@]}" >&2 ||
    refuse "candidate metallib lacks kernels the pinned MLX core loads by name; do not swap it onto the canary"
  log "candidate v$V passed the pre-swap checks"
}

# check_catalog_live: a candidate whose baked catalog release is not the one
# Pearl serves fails the canary join with rate_card_update_required (1.8.262).
# Compare the baked catalog-release/ release_id and generated_at stamps with
# the coordinator's /v1/autotune-release and /v1/rate-card; refuse on any
# difference, and when Pearl's catalog cannot be read.
check_catalog_live() {
  local payload="$OPS_TMP_DIR/payload" base verdict
  [ -f "$payload/catalog-release/release.json" ] || refuse "$TARBALL lacks catalog-release/release.json"
  base="$(coordinator_url)"
  [ -n "$base" ] || refuse "COORDINATOR_URL is unset; cannot compare the baked catalog with Pearl's"
  [ "$(http_get "$base/v1/autotune-release" "$OPS_TMP_DIR/live-release.json")" = 200 ] &&
    [ "$(http_get "$base/v1/rate-card" "$OPS_TMP_DIR/live-rate-card.json")" = 200 ] ||
    refuse "cannot read Pearl's live catalog from $base/v1/autotune-release and /v1/rate-card"
  verdict="$(python3 - "$payload/catalog-release" "$OPS_TMP_DIR/live-release.json" "$OPS_TMP_DIR/live-rate-card.json" <<'PY'
import datetime, json, os, sys
cand, live_rel_path, live_card_path = sys.argv[1:4]
def load(path):
    with open(path) as f:
        return json.load(f)
try:
    rel, live_rel, live_card = load(os.path.join(cand, "release.json")), load(live_rel_path), load(live_card_path)
    card = load(os.path.join(cand, "rate-card.json")) if os.path.exists(os.path.join(cand, "rate-card.json")) else None
except (OSError, ValueError) as exc:
    print("ERR unreadable catalog: %s" % exc); sys.exit(0)
cid, lid = rel.get("release_id"), live_rel.get("release_id")
def stamp(doc):
    try:
        return datetime.datetime.strptime(doc.get("generated_at"), "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None
# The provider takes a fetched feed only when its policy_version equals the
# baked one and it is generated no earlier than the baked bytes; otherwise it
# reports rate_card_update_required. A strictly newer live release is accepted
# only with the same rate-card content version, so no baked price is un-activated.
newer = (bool(cid) and cid != lid and rel.get("policy_version") == live_rel.get("policy_version") and
         None not in (stamp(rel), stamp(live_rel)) and stamp(rel) < stamp(live_rel) and
         (card is None or (card.get("version") == live_card.get("version") and
                           None not in (stamp(card), stamp(live_card)) and stamp(card) <= stamp(live_card))))
diffs = []
if not newer:
    if not cid or cid != lid:
        diffs.append("release_id")
    if rel.get("generated_at") != live_rel.get("generated_at"):
        diffs.append("release.json generated_at %s vs %s" % (rel.get("generated_at"), live_rel.get("generated_at")))
    if card is not None and (card.get("generated_at"), card.get("version")) != (live_card.get("generated_at"), live_card.get("version")):
        diffs.append("rate-card.json generated_at/version %s vs %s" % (card.get("generated_at"), live_card.get("generated_at")))
print("%s %s %s %s" % ("DIFF" if diffs else "OK", cid or "<none>", lid or "<none>", "; ".join(diffs)))
PY
)"
  local kind cid lid diffs
  read -r kind cid lid diffs <<<"$verdict"
  case "$kind" in
    OK) if [ "$cid" = "$lid" ]; then log "candidate bakes the catalog Pearl serves ($cid)"
        else log "candidate bakes catalog $cid; Pearl serves the newer $lid with the same policy and rate card"; fi ;;
    DIFF) refuse "candidate bakes catalog $cid; Pearl serves $lid: activate the catalog first (scripts/ops/catalog-activate.sh) [differs: $diffs]" ;;
    *) refuse "cannot compare the baked catalog with Pearl's: ${verdict#ERR }" ;;
  esac
}

if [ "$CMD" = check ]; then
  [ -n "$TARBALL" ] || bind_verified_tarball
  [ -f "$TARBALL" ] || refuse "candidate tarball not found: $TARBALL"
  check_candidate
  check_catalog_live
  exit 0
fi

BINARY_SHA=""
bind_verified_tarball
check_candidate
[ "$CMD" != swap ] || check_catalog_live

require_studio_ssh
if [ "$CMD" = record-installed ]; then
  installed="$(studio_ssh "d=$(printf '%q' "${CANARY_INSTALL_DIR:-}"); shasum -a 256 \"\${d:-\$HOME/macprovider}/macprovider-cli\" | awk '{print \$1}'")" ||
    refuse "cannot read the canary's installed macprovider-cli"
  [ "$installed" = "$BINARY_SHA" ] || refuse "canary runs macprovider-cli $installed, not the verified v$V binary $BINARY_SHA"
  served="$(studio_ssh "PATH=$(printf '%q' "${CANARY_REMOTE_PATH_PREFIX:+$CANARY_REMOTE_PATH_PREFIX:}")\$PATH curl -fsS -m 10 http://127.0.0.1:${STUDIO_STATUS_PORT}/v1/status" |
    python3 -c 'import json,sys; b=json.load(sys.stdin); print(b.get("binary_version"), b.get("network_state"))')" ||
    refuse "cannot read the canary /v1/status"
  [ "$served" = "$V buyer_serving" ] || refuse "canary /v1/status reports '$served', not '$V buyer_serving'"
  mark_done "$OPS_SCOPE" canary_swap "canary-swap.sh recorded the installed v$V" \
    "$(printf '{"candidate_sha":"%s","checksums_sha256":"%s","tarball_sha256":"%s","binary_sha256":"%s","kernel_check":"passed","installed_by":"record-installed"}' \
      "$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("candidate_sha")')" \
      "$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("checksums_sha256")')" \
      "$TARBALL_SHA" "$BINARY_SHA")"
  log "canary runs the verified v$V; record it: scripts/ops/cli-release.sh next --done canary_smoke --probe"
  exit 0
fi
record_air_result() {
  local action="$1" code="$2"
  case "$action:$code" in recover-air:0|recover-air:4|recover-air:5|restore-air:5) ;;
    *) return 0 ;;
  esac
  mark_done "$OPS_SCOPE" air_recovery_result "guarded signed Air recovery returned" \
    "$(python3 -c 'import json,sys; print(json.dumps(dict(stage=sys.argv[1],provider_id_sha256=sys.argv[2],action=sys.argv[3],exit_code=int(sys.argv[4]))))' "$stage" "$AIR_RECOVERY_PROVIDER_SHA256" "$action" "$code")"
}
case "${STUDIO_STATUS_PORT:-}" in ""|*[!0-9]*) refuse "STUDIO_STATUS_PORT must be set and numeric" ;; esac
[ -n "${MACPROVIDER_OPS_OWNER:-}" ] || refuse "MACPROVIDER_OPS_OWNER is required for swap (live-ops lock owner)"
[ -n "${CANARY_RUNNER_STOP_CMD:-}" ] && [ -n "${CANARY_RUNNER_START_CMD:-}" ] ||
  refuse "set CANARY_RUNNER_STOP_CMD and CANARY_RUNNER_START_CMD (none when no buyer runner feeds the canary)"
STATUS_TIMEOUT_S="${CANARY_STATUS_TIMEOUT_S:-120}"
READY_TIMEOUT_S="${CANARY_READY_TIMEOUT_S:-1800}"
DRAIN_TIMEOUT_S="${CANARY_DRAIN_TIMEOUT_S:-600}"
STABLE_S="${CANARY_STABLE_S:-120}"
POLL_S="${CANARY_POLL_S:-5}"
for n in "$STATUS_TIMEOUT_S" "$READY_TIMEOUT_S" "$DRAIN_TIMEOUT_S" "$STABLE_S" "$POLL_S"; do
  case "$n" in ""|*[!0-9]*) refuse "CANARY_*_S values must be whole seconds" ;; esac
done

q() {
  case "$1" in *"'"*) refuse "canary setting contains a single quote: $1" ;; esac
  printf "'%s'" "$1"
}
q "${CANARY_INSTALL_DIR:-}" >/dev/null
q "${CANARY_LAUNCHD_LABEL:-}" >/dev/null
q "${CANARY_CTL_SOCKET:-}" >/dev/null

"$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose "$OPS_NAME:v$V" --bind-pid >&2 ||
  refuse "live-ops lock is held by another owner"
# shellcheck disable=SC2034  # released by cleanup_ops in lib/common.sh
OPS_LOCK_OWNER="$MACPROVIDER_OPS_OWNER"

RUNNER_TOUCHED=0
REMOTE_STARTED=0
# shellcheck disable=SC2329  # EXIT trap
finish() {
  local rc=$?
  trap - EXIT
  # Once the remote run may have started, only its conclusive result (0, 4, 5)
  # lets buyers back: a signal, a lost launch or exit 6 leaves the runner down.
  if [ "$RUNNER_TOUCHED" = 1 ] && [ "$REMOTE_STARTED" = 1 ] && ! case "$rc" in 0|4|5) true ;; *) false ;; esac; then
    log "!!! buyer runner left STOPPED until the canary is recovered; then run CANARY_RUNNER_START_CMD"
  elif [ "$RUNNER_TOUCHED" = 1 ]; then
    if bash -c "$CANARY_RUNNER_START_CMD" >&2; then
      log "buyer runner restarted"
    else
      log "!!! buyer runner restart failed: run CANARY_RUNNER_START_CMD by hand"
      rc=6
    fi
  fi
  cleanup_ops
  exit "$rc"
}
trap finish EXIT

if [ "$CANARY_RUNNER_STOP_CMD" != none ]; then
  # Marked first: a stop that half-succeeds still gets a restart.
  RUNNER_TOUCHED=1
  bash -c "$CANARY_RUNNER_STOP_CMD" >&2 || refuse "buyer runner stop failed; nothing swapped"
  log "buyer runner stopped"
fi

# A unique stage per run: its log and result belong to this run only.
if [ "$CMD" = restore-air ]; then
  stage="$(marker_field "$OPS_SCOPE" air_recovery_dispatch 'd.get("stage")')"
  [ "$(marker_field "$OPS_SCOPE" air_recovery_dispatch 'd.get("provider_id_sha256")')" = "$AIR_RECOVERY_PROVIDER_SHA256" ] || refuse "Air recovery dispatch belongs to another provider"
  # Join the original detached actor; a recovery attempt must not turn its
  # lock-busy refusal into completion of the original transaction.
  deadline=$(( $(date +%s) + DRAIN_TIMEOUT_S + 2 * READY_TIMEOUT_S + 600 ))
  while studio_ssh 'p=$(cat "$HOME/.macprovider-canary-swap.lock/pid" 2>/dev/null) && kill -0 "$p" 2>/dev/null'; do
    [ "$(date +%s)" -lt "$deadline" ] || refuse "original Air payload actor is still active"
    sleep "$POLL_S"
  done
  original_rc="$(studio_ssh "cat $(q "$stage/result") 2>/dev/null" || true)"
  case "$original_rc" in 0|4|5)
    record_air_result recover-air "$original_rc"
    exit "$original_rc" ;;
  esac
else
  stage="$(studio_ssh "umask 077 && mkdir -p \"\$HOME/macprovider-canary-staging\" && mktemp -d \"\$HOME/macprovider-canary-staging/v$V-XXXXXX\"")" || refuse "could not create a staging dir on the canary"
fi
case "$stage" in /*/macprovider-canary-staging/v"$V"-*) ;; *) refuse "unexpected canary staging dir: $stage" ;; esac
q "$stage" >/dev/null
if [ "$CMD" != restore-air ]; then
  studio_ssh "cat > \"$stage/candidate.tar.gz\"" < "$TARBALL" || refuse "could not stage the candidate on the canary"
fi
remote_name=canary-swap-remote.sh
[ "$CMD" != restore-air ] || remote_name="air-restore-$$.sh"
studio_ssh "umask 077; cat > \"$stage/$remote_name\"" < "$OPS_DIR/lib/canary-swap-remote.sh" ||
  refuse "could not stage the swap script on the canary"
log "staged v$V on the canary ($TARBALL_SHA)"

result_file="$stage/result"
log_file="$stage/run.log"
if [ "$CMD" = restore-air ]; then result_file="$stage/restore-result-$$"; log_file="$stage/restore-$$.log"; fi
args="\"$stage/candidate.tar.gz\" $(q "$TARBALL_SHA") $(q "$V") $(q "${CANARY_INSTALL_DIR:-}") \
$(q "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}") $(q "${CANARY_CTL_SOCKET:-}") $(q "$STUDIO_STATUS_PORT") \
$(q "$STATUS_TIMEOUT_S") $(q "$READY_TIMEOUT_S") $(q "$DRAIN_TIMEOUT_S") $(q "$STABLE_S") $(q "$POLL_S") $(q "$result_file")"
if [ "$CMD" = recover-air ] || [ "$CMD" = restore-air ]; then
  args="$args $(q "$AIR_RECOVERY_PROVIDER_SHA256") $(q "$AIR_RECOVERY_CONFIG") $(q "$AIR_RECOVERY_BINARY_SHA256") $(q "$CMD") $(q "$AIR_RECOVERY_CONFIG_SHA256")"
fi
REMOTE_STARTED=1
if [ "$CMD" = recover-air ]; then
  mark_done "$OPS_SCOPE" air_recovery_dispatch "guarded signed Air payload recovery dispatched" \
    "$(python3 -c 'import json,sys; print(json.dumps({"stage":sys.argv[1],"provider_id_sha256":sys.argv[2],"incumbent_binary_sha256":sys.argv[3],"config_sha256":sys.argv[4]}))' "$stage" "$AIR_RECOVERY_PROVIDER_SHA256" "$AIR_RECOVERY_BINARY_SHA256" "$AIR_RECOVERY_CONFIG_SHA256")"
fi
studio_ssh "cd \"$stage\" && nohup bash $(q "$remote_name") $args > $(q "$log_file") 2>&1 < /dev/null &" ||
  refuse "could not start the swap on the canary"

# Poll the detached run until it records its exit code. ssh failures while
# polling are retried; the remote run carries on without this side.
deadline=$(( $(date +%s) + DRAIN_TIMEOUT_S + 2 * READY_TIMEOUT_S + 600 ))
shown=0
rc=""
while [ -z "$rc" ]; do
  # Complete log lines past the ones already shown, the line count, then the
  # result file (empty until the remote run ends).
  if out="$(studio_ssh "f=$(q "$log_file"); n=\$(wc -l < \"\$f\" 2>/dev/null || echo 0); n=\$((n)); \
if [ \"\$n\" -gt $shown ]; then sed -n \"$((shown + 1)),\${n}p\" \"\$f\"; fi; \
printf '@@COUNT@@%s\\n@@RESULT@@' \"\$n\"; cat $(q "$result_file") 2>/dev/null || true")"; then
    chunk="${out%%@@COUNT@@*}"
    [ -z "$chunk" ] || printf '%s' "$chunk" >&2
    count="${out#*@@COUNT@@}"
    count="${count%%$'\n'*}"
    case "$count" in ''|*[!0-9]*) ;; *) shown="$count" ;; esac
    rc="$(printf '%s' "${out##*@@RESULT@@}" | tr -d '[:space:]')"
  else
    log "canary unreachable while polling; retrying"
  fi
  [ -n "$rc" ] && break
  [ "$(date +%s)" -lt "$deadline" ] || { log "!!! no result from the canary swap by the deadline; check $stage/run.log on the canary"; exit 6; }
  sleep "$POLL_S"
done
case "$rc" in 0|4|5|6) ;; *) log "!!! canary swap reported '$rc'"; exit 6 ;; esac
case "$CMD" in recover-air|restore-air) record_air_result "$CMD" "$rc" ;; esac

case "$rc" in
  0)
    mark_done "$OPS_SCOPE" canary_swap "canary-swap.sh swapped v$V" \
      "$(printf '{"candidate_sha":"%s","checksums_sha256":"%s","tarball_sha256":"%s","binary_sha256":"%s","kernel_check":"passed"}' \
        "$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("candidate_sha")')" \
        "$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("checksums_sha256")')" \
        "$TARBALL_SHA" "$BINARY_SHA")"
    log "canary serves v$V; record it: scripts/ops/cli-release.sh next --done canary_smoke --probe"
    ;;
  4) log "canary refused the swap before touching the payload; provider resumed on its previous version" ;;
  5) log "v$V FAILED on the canary; the previous version was restored and is buyer_serving. Do not promote v$V." ;;
  *) log "!!! canary swap needs the operator: see the messages above ($stage/run.log on the canary)" ;;
esac
exit "$rc"
