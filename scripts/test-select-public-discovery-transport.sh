#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
selector="$root/scripts/select_public_discovery_transport.py"
verifier="$root/scripts/verify-anonymous-release-discovery.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/select-public-discovery-transport.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf '[test-select-public-discovery-transport] ERROR: %s\n' "$*" >&2
  exit 1
}

repository=Augustas11/macprovider
commit=896359c7b0fc871d4ea372517f4de47ec19433bd
expected=release-discovery-v1-2110220523208705
older=release-discovery-v1-2103892340310017
newer=release-discovery-v1-2110220523208706

write_release() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$commit" "$repository" <<'PY'
import json
import pathlib
import sys

path, tag, draft, prerelease, immutable, commit, repository = sys.argv[1:]
assets = [
    {
        "name": name,
        "browser_download_url": f"https://github.com/{repository}/releases/download/{tag}/{name}",
    }
    for name in (
        "compatibility-artifact-index.json",
        "macprovider-release-discovery.json",
        "macprovider-release-discovery.json.sig",
    )
]
pathlib.Path(path).write_text(
    json.dumps(
        {
            "tag_name": tag,
            "target_commitish": commit,
            "draft": draft == "true",
            "prerelease": prerelease == "true",
            "immutable": immutable == "true",
            "assets": assets,
        }
    ),
    encoding="utf-8",
)
PY
}

run_selector() {
  python3 "$selector" \
    "$1" \
    "$expected" \
    "$commit" \
    "$repository" \
    "$work/release.json" \
    "$work/assets.tsv"
}

write_release "$work/expected.json" "$expected" false true true
write_release "$work/older.json" "$older" false true true
write_release "$work/newer.json" "$newer" false true true
write_release "$work/draft.json" "$expected" true true true

python3 - "$work/stale.json" "$work/older.json" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text(
    json.dumps([json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))]),
    encoding="utf-8",
)
PY
python3 - "$work/caught-up.json" "$work/older.json" "$work/expected.json" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        [
            json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")),
            json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")),
        ]
    ),
    encoding="utf-8",
)
PY
python3 - "$work/newer-head.json" "$work/expected.json" "$work/newer.json" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(
        [
            json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")),
            json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")),
        ]
    ),
    encoding="utf-8",
)
PY
python3 - "$work/draft-head.json" "$work/draft.json" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text(
    json.dumps([json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))]),
    encoding="utf-8",
)
PY
python3 - "$work/empty.json" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text("[]\n", encoding="utf-8")
PY

set +e
run_selector "$work/stale.json"
stale_status=$?
run_selector "$work/empty.json"
empty_status=$?
run_selector "$work/draft-head.json"
draft_status=$?
run_selector "$work/newer-head.json"
newer_status=$?
run_selector "$work/caught-up.json"
ok_status=$?
set -e

[ "$stale_status" -eq 2 ] || fail "stale listing must be retryable, got $stale_status"
[ "$empty_status" -eq 2 ] || fail "empty listing must be retryable, got $empty_status"
[ "$draft_status" -eq 2 ] || fail "draft head must be retryable, got $draft_status"
[ "$newer_status" -eq 1 ] || fail "newer competing head must fail closed, got $newer_status"
[ "$ok_status" -eq 0 ] || fail "caught-up listing must succeed, got $ok_status"
grep -Fqx "$expected" <<<"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$work/release.json")" \
  || fail "successful selection did not persist the expected transport"

page_state="$root/scripts/discovery_listing_page_state.py"
python3 - "$work" "$expected" <<'PY'
import json
import pathlib
import sys
work, transport = pathlib.Path(sys.argv[1]), sys.argv[2]
pearls = [{"tag_name": f"v1.8.{n}", "assets": []} for n in range(300, 200, -1)]
(work / "page-full.json").write_text(json.dumps(pearls), encoding="utf-8")
(work / "page-short.json").write_text(json.dumps(pearls[:3]), encoding="utf-8")
(work / "page-transport.json").write_text(
    json.dumps(pearls[:98] + [{"tag_name": transport, "assets": []}]), encoding="utf-8"
)
(work / "page-bad-grammar.json").write_text(
    json.dumps(pearls[:3] + [{"tag_name": "release-discovery-v1-01", "assets": []}]), encoding="utf-8"
)
(work / "page-oversized.json").write_text(" " * (16 * 1024 * 1024 + 1), encoding="utf-8")
PY
[ "$(python3 "$page_state" "$work/page-full.json")" = next ] \
  || fail "full page without a transport must continue to the next page"
[ "$(python3 "$page_state" "$work/page-short.json")" = end ] \
  || fail "short page without a transport must end the listing"
[ "$(python3 "$page_state" "$work/page-transport.json")" = transport ] \
  || fail "page holding a transport past prerelease churn must stop the walk"
[ "$(python3 "$page_state" "$work/page-bad-grammar.json")" = end ] \
  || fail "malformed transport tag must not stop the walk"
if python3 "$page_state" "$work/page-oversized.json" >/dev/null 2>&1; then
  fail "oversized listing page must fail closed"
fi
swift_source="$root/phase3-binary/Sources/macprovider-cli/SelfUpdate.swift"
python3 - "$page_state" "$swift_source" <<'PY' || fail "verifier listing bounds must match the CLI's"
import importlib.util
import re
import sys
spec = importlib.util.spec_from_file_location("page_state", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
swift = open(sys.argv[2], encoding="utf-8").read()
def constant(name):
    expr = re.search(rf"static let {name} = ([0-9_ *]+)\n", swift).group(1)
    value = 1
    for factor in expr.replace("_", "").split("*"):
        value *= int(factor)
    return value
assert constant("releaseDiscoveryPageSize") == module.PAGE_SIZE
assert constant("maxReleaseDiscoveryPages") == module.MAX_PAGES
assert constant("maxReleaseDiscoveryListingBytes") == module.MAX_PAGE_BYTES
PY
python3 - "$work" <<'PY'
import json
import pathlib
import sys
(pathlib.Path(sys.argv[1]) / "page-overflow.json").write_text(
    json.dumps([{"tag_name": "release-discovery-v1-18446744073709551616", "assets": []}]),
    encoding="utf-8",
)
PY
[ "$(python3 "$page_state" "$work/page-overflow.json")" = end ] \
  || fail "transport sequence beyond UInt64 must not stop the walk"
grep -Fq 'no discovery transport within the client-visible listing bound' "$verifier" \
  || fail "anonymous verifier must fail without retrying once the page bound is exhausted"
grep -Fq 'scripts/discovery_listing_page_state.py' "$verifier" \
  || fail "anonymous verifier must walk the listing like the client"
grep -Fq 'releases?per_page=100&page=$page' "$verifier" \
  || fail "anonymous verifier must request numbered listing pages"

grep -Fq 'scripts/select_public_discovery_transport.py' "$verifier" \
  || fail "anonymous verifier must use the shared listing selector"
grep -Fq 'releases?per_page=100' "$verifier" \
  || fail "anonymous verifier must page enough public releases to observe the head"
grep -Fq 'MACPROVIDER_DISCOVERY_LISTING_ATTEMPTS' "$verifier" \
  || fail "anonymous verifier must retry a lagging public listing"
grep -Fq 'MACPROVIDER_RELEASE_FIXTURE_GITHUB_TOKEN' "$verifier" \
  || fail "anonymous verifier must allow authenticated fixture setup in CI"
grep -Fq -- '-u MACPROVIDER_RELEASE_FIXTURE_GITHUB_TOKEN' "$verifier" \
  || fail "anonymous verifier must remove fixture tokens before running the client"
grep -Fq -- '-u GITHUB_TOKEN' "$verifier" \
  || fail "anonymous verifier must remove GitHub tokens before running the client"
grep -Fq -- '-u RELEASE_POSTURE_TOKEN' "$verifier" \
  || fail "anonymous verifier must remove release posture tokens before running the client"
grep -Fq 'rm -f -- "$github_api_curl_config"' "$verifier" \
  || fail "anonymous verifier must delete fixture auth config before running the client"
grep -Fq 'unset \' "$verifier" \
  || fail "anonymous verifier must unset fixture auth environment after listing"
grep -Fq 'MACPROVIDER_RELEASE_FIXTURE_GITHUB_TOKEN \' "$verifier" \
  || fail "anonymous verifier must unset fixture auth token after listing"

printf '[test-select-public-discovery-transport] ok: verifier walks the client-visible listing\n'
