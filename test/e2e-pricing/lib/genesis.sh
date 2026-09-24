#!/usr/bin/env bash
# Tier E2 "test world" genesis, applied inside a scratch checkout ($1).
#
# Replaces every production trust identity the operator lane and the deploy
# check with a TEST identity generated under $E2E_KEYS, and nothing else:
#   - release-tag signer line + canonical remote URL in the coordinator build
#     and deploy scripts (the scratch origin is a local bare repo);
#   - the static-feed keyring (trusted-keys.json + coordinator autotune.public_keys);
#   - the Tier-2 catalog public key (coordinator tier2.catalog_public_key) and
#     the Tier-2 catalog signature;
# then (unless $2 = keep-release) re-stamps and re-signs the catalog release as
# $E2E_RELEASE_A with the test key through the repo's own tooling
# (catalog-release.py restamp + scripts/resign-autotune-static.sh).
set -euo pipefail
. "$(dirname "$0")/../env.sh"
REPO="$1"; MODE="${2:-cut}"
cd "$REPO"

fp="$(ssh-keygen -lf "$E2E_KEYS/tag_signing_ed25519.pub" | awk '{print $2}')"
signer_line="Good \"git\" signature for e2e@test.invalid with ED25519 key $fp"
for f in phase4-coordinator/scripts/build-linux.sh phase4-coordinator/dist/deploy-pearl-vps.sh; do
  python3 - "$f" "$signer_line" "$E2E_BARE_URL" <<'PY'
import re, sys
path, line, url = sys.argv[1:]
s = open(path).read()
old_line = re.search(r"release_tag_signer_line='([^']*)'", s)
assert old_line, path
s = s.replace(old_line.group(0), "release_tag_signer_line='%s'" % line)
s = s.replace("https://github.com/Augustas11/macprovider.git", url)
open(path, "w").write(s)
PY
done

# WORKAROUND for a pre-existing deploy-pearl-vps.sh bug (reported, NOT a
# #1693 change; present at v1.8.191, origin/main and the branch): the step-8
# exact-byte canary proof hashes rate-card.json + rate-card.json.sig from the
# canary install dir, but the comparator's expected set omits
# $STATIC_RATE_CARD_JSON/$STATIC_RATE_CARD_SIG, so every deploy fails with
# "canary catalog byte mismatch: missing=[] extra=['rate-card.json',
# 'rate-card.json.sig']" and rolls back. Set E2E_NO_CANARY_WORKAROUND=1 to
# reproduce it (the as-written deploy then fails at step 8).
if [ "${E2E_NO_CANARY_WORKAROUND:-0}" != 1 ]; then
  python3 - phase4-coordinator/dist/deploy-pearl-vps.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '  "$STATIC_DEMAND_SIG" \\\n  "$AUTOTUNE_TIER2_JSON" <<\'PY\'\n'
new = '  "$STATIC_DEMAND_SIG" \\\n  "$STATIC_RATE_CARD_JSON" \\\n  "$STATIC_RATE_CARD_SIG" \\\n  "$AUTOTUNE_TIER2_JSON" <<\'PY\'\n'
assert s.count(old) == 1, "canary comparator block not found exactly once"
open(p, "w").write(s.replace(old, new))
PY
fi

# Pearl runtime release signing key (updater + deploy release assets).
openssl pkey -in "$E2E_KEYS/release-signing.key" -pubout -out ops/pearl-updater/release-signing-public.pem

auto_pub="$(tr -d '\n' <"$E2E_KEYS/autotune.public.base64")"
t2_pub="$(tr -d '\n' <"$E2E_KEYS/tier2.pub")"
python3 - "$auto_pub" "$t2_pub" "$E2E_AUTOTUNE_KEY_ID" <<'PY'
import json, re, sys
auto_pub, t2_pub, key_id = sys.argv[1:]
p = "phase3-binary/catalog/autotune/trusted-keys.json"
json.dump({"keys": {key_id: {"public_key_base64": auto_pub, "status": "active"}},
           "schema_version": "macprovider.autotune-keys.v1"}, open(p, "w"), indent=2, sort_keys=True)
open(p, "a").write("\n")
y = "phase4-coordinator/dist/coordinator.yaml"
s = open(y).read()
s = re.sub(r"(  public_keys:\n)((?:    [^\n]+\n)+)", lambda m: m.group(1) + '    %s: "%s"\n' % (key_id, auto_pub), s, count=1)
s = re.sub(r"(\n  catalog_public_key: )\S+", lambda m: m.group(1) + t2_pub, s, count=1)
open(y, "w").write(s)
PY

# Tier-2 catalog: same body, test signature.
python3 - <<'PY' >"$E2E_WORK/tier2-unsigned.json"
import json
d = json.load(open("phase3-binary/catalog/autotune/tier2-catalog.json"))
d.pop("signature", None)
print(json.dumps(d, indent=2, sort_keys=True))
PY
go run scripts/sign-catalog.go sign -key "$E2E_KEYS/tier2.priv" -key-id e2e-tier2-key \
  -out phase3-binary/catalog/autotune/tier2-catalog.json "$E2E_WORK/tier2-unsigned.json" >/dev/null

[ "$MODE" = cut ] || exit 0
python3 scripts/catalog-release.py restamp --release-id "$E2E_RELEASE_A" --generated-at "${E2E_GENERATED_AT:?}"
# Test-world rate row that no catalog model needs: a later reviewed correction
# can remove it (V1), moving any request_log name that resolved to it onto
# `default` (an acknowledged move). Every real row is required by a
# recommendable candidate (SPEC-023 §3.3.1 rule 7), so none can be removed.
python3 -c '
import json
p = "phase3-binary/catalog/autotune/rate-card-source.json"
s = json.load(open(p))
s["rows"]["e2e-legacy-model"] = {"prompt_rate_per_mtok": 90000, "prompt_cache_hit_rate_per_mtok": 22500, "completion_rate_per_mtok": 180000}
open(p, "w").write(json.dumps(s, indent=2, sort_keys=True) + "\n")'
python3 "$E2E_HARNESS/lib/sync-dist-rate-card.py" --source
AUTOTUNE_STATIC_KEY_ID="$E2E_AUTOTUNE_KEY_ID" AUTOTUNE_STATIC_PRIVATE_KEY_PATH="$E2E_KEYS/autotune.private.base64" \
  bash scripts/resign-autotune-static.sh
