#!/usr/bin/env bash
# Author a reviewed pricing-correction commit in the scratch repo, the way the
# runbook's "Author the PR" section describes, and land it on the scratch
# origin/main (plays "reviewed by CODEOWNERS, merged"):
#   1. rate-card-source.json rows: change / add / remove (spec JSON, $2)
#   2. restamp to a new release id, then re-sign with the TEST feed key through
#      scripts/resign-autotune-static.sh (runs catalog-release.py generate+verify)
#   3. the matching rewards.rate_card block pasted into
#      phase4-coordinator/dist/coordinator.yaml (catalog-release.py
#      coordinator_rate_card_yaml of the generated card, spliced with the
#      lane's own splice-coordinator-rate-card)
#   4. acknowledged-pricing-moves.json = spec "acks"
# Usage: make-pricing-commit.sh <base-ref> <spec.json> -> prints the new commit sha
# spec: {"release_id": "...", "change": {"row": [p, cache_hit, completion]},
#        "add": {"row": [p, c, comp]}, "remove": ["row"], "acks": [{"model","from_row","to_row"}],
#        "message": "..."}
set -euo pipefail
. "$(dirname "$0")/../env.sh"
BASE="$1"; SPEC="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
trap '[ $? = 0 ] || git -C "$E2E_REPO" checkout -q -- . 2>/dev/null' EXIT
cd "$E2E_REPO"
[ -z "$(git status --porcelain)" ] || e2e_die "scratch repo dirty"
git checkout -q --detach "$BASE"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rid="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["release_id"])' "$SPEC")"
python3 scripts/catalog-release.py restamp --release-id "$rid" --generated-at "$now" >/dev/null
python3 - "$SPEC" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
p = "phase3-binary/catalog/autotune/rate-card-source.json"
src = json.load(open(p))
def row(v):
    return {"prompt_rate_per_mtok": v[0], "prompt_cache_hit_rate_per_mtok": v[1], "completion_rate_per_mtok": v[2]}
for k, v in spec.get("change", {}).items():
    assert k in src["rows"], k
    src["rows"][k] = row(v)
for k, v in spec.get("add", {}).items():
    assert k not in src["rows"], k
    src["rows"][k] = row(v)
for k in spec.get("remove", []):
    del src["rows"][k]
open(p, "w").write(json.dumps(src, indent=2, sort_keys=True) + "\n")
a = "phase3-binary/catalog/autotune/acknowledged-pricing-moves.json"
acks = json.load(open(a))
acks["moves"] = spec.get("acks", [])
open(a, "w").write(json.dumps(acks, indent=2) + "\n")
PY
# The coordinator block for the card `generate` will publish (parity-checked by generate).
python3 "$E2E_HARNESS/lib/sync-dist-rate-card.py" --source
AUTOTUNE_STATIC_KEY_ID="$E2E_AUTOTUNE_KEY_ID" AUTOTUNE_STATIC_PRIVATE_KEY_PATH="$E2E_KEYS/autotune.private.base64" \
  bash scripts/resign-autotune-static.sh >"$E2E_LOGS/resign-$rid.log" 2>&1 || { tail -20 "$E2E_LOGS/resign-$rid.log" >&2; exit 1; }
msg="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("message","E2E pricing correction"))' "$SPEC")"
git add -A phase3-binary phase4-coordinator
git commit -q -m "$msg ($rid)"
sha="$(git rev-parse HEAD)"
if [ "${E2E_NO_PUSH:-0}" != 1 ]; then
  git push -q origin "HEAD:refs/heads/main"
  git fetch -q origin
fi
git checkout -q main 2>/dev/null && git reset -q --hard origin/main
echo "$sha"
