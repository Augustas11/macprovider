#!/usr/bin/env bash
# Step 8's exact-byte canary proof (deploy-pearl-vps.sh): the file set the
# canary Mac hashes (run_catalog_canary_mac_proof `names`) must be exactly the
# file set the comparator expects from the verified release. The rate card
# was hashed by the proof but missing from the comparator, so every deploy
# reaching step 8 failed "canary catalog byte mismatch: extra=['rate-card.json',
# 'rate-card.json.sig']" (#1693 E2). Static: both lists are parsed from the
# script, the comparator's variables resolved through their assignments.
set -euo pipefail
DEPLOY="$(cd "$(dirname "$0")/.." && pwd -P)/deploy-pearl-vps.sh"
python3 - "$DEPLOY" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
proof_fn = s[s.index("run_catalog_canary_mac_proof() {"):]
names_block = re.search(r"\n    names = \(\n(.*?)\n    \)\n", proof_fn, re.S)
assert names_block, "canary proof names tuple not found"
proof = set(re.findall(r'"([^"]+)"', names_block.group(1)))
marker = 'raise SystemExit(f"canary catalog byte mismatch'
cmp_start = s.rindex('if ! python3 - \\\n  "$CANARY_INSTALLED_BODY" \\\n  "$CANARY_POOL_BODY" \\\n  "$CATALOG_CANARY_PROVIDER_ID" \\\n', 0, s.index(marker))
args = re.findall(r'^  "\$([A-Z0-9_]+)"', s[cmp_start:s.index("<<'PY'", cmp_start)], re.M)
assert args[:3] == ["CANARY_INSTALLED_BODY", "CANARY_POOL_BODY", "CATALOG_CANARY_PROVIDER_ID"], args
expected = set()
for var in args[3:]:
    m = re.search(r'^%s="[^"]*/([^"/]+)"$' % re.escape(var), s, re.M)
    assert m, "no assignment for $%s" % var
    expected.add(m.group(1))
assert proof == expected, "canary proof hashes %s but step 8 expects %s (extra=%s missing=%s)" % (
    sorted(proof), sorted(expected), sorted(proof - expected), sorted(expected - proof))
assert {"rate-card.json", "rate-card.json.sig"} <= expected
print("[deploy_canary_byte_proof_names] ok: step 8 compares exactly the %d files the canary proof hashes" % len(expected))
PY
