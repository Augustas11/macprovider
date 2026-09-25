#!/usr/bin/env bash
# Runbook section 9 step 4a feed check (docs/runbooks/trusted-pool-production-
# launch.md), run exactly as written: the python block is extracted from the
# runbook itself, then run against lab renderings of the coordinator config.
# Each case prints the runbook's VERDICT and exit code next to the expected
# one; any difference is a failure. Lab paths only; no served-feed curl.
set -uo pipefail
LAB=${1:?lab}
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNBOOK="$HERE/../../../docs/runbooks/trusted-pool-production-launch.md"
CHECK=$LAB/tmp/check4a.py
awk '/^   python3 - \/etc\/macprovider\/coordinator.yaml <<.PY.$/ {on=1; next} on && /^   PY$/ {exit} on {sub(/^   /, ""); print}' "$RUNBOOK" >"$CHECK"
[ -s "$CHECK" ] || { echo "FAIL: step 4a check block not found in the runbook"; exit 1; }
FEED=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["autotune"].get("catalog_artifacts_path") or "")' "$LAB/run/coordinator.yaml")
[ -n "$FEED" ] || { echo "FAIL: lab config has no catalog_artifacts_path"; exit 1; }
D=$LAB/tmp/check4a
mkdir -p "$D"
printf '{"kind":"clean"}\n' >"$D/clean-feed.json"
# expected: "<verdict> <exit>"
declare -a CASES=(
  "json|$LAB/run/coordinator.yaml|replace-feed 1"
  "yaml-plain|$D/plain.yaml|replace-feed 1"
  "yaml-quoted|$D/quoted.yaml|replace-feed 1"
  "yaml-unset|$D/unset.yaml|no-feed 0"
  "yaml-clean-feed|$D/clean.yaml|clean 0"
  "yaml-relative|$D/relative.yaml|STOP 2"
  "yaml-missing-file|$D/missing.yaml|STOP 2"
  "yaml-broken|$D/broken.yaml|STOP 2"
  "config-absent|$D/absent.yaml|STOP 2"
)
printf 'autotune:\n  catalog_artifacts_path: %s\n' "$FEED" >"$D/plain.yaml"
printf 'autotune:\n  catalog_artifacts_path: "%s"\n' "$FEED" >"$D/quoted.yaml"
printf 'autotune:\n  rate_card_path: /x\n' >"$D/unset.yaml"
printf 'autotune:\n  catalog_artifacts_path: %s\n' "$D/clean-feed.json" >"$D/clean.yaml"
printf 'autotune:\n  catalog_artifacts_path: static/autotune-artifacts.json\n' >"$D/relative.yaml"
printf 'autotune:\n  catalog_artifacts_path: %s\n' "$D/does-not-exist.json" >"$D/missing.yaml"
printf 'autotune: [unclosed\n' >"$D/broken.yaml"
rm -f "$D/absent.yaml"
fail=0
for c in "${CASES[@]}"; do
  IFS='|' read -r name cfg want <<<"$c"
  out=$(python3 "$CHECK" "$cfg" 2>&1); rc=$?
  got="$(printf '%s\n' "$out" | sed -n 's/^VERDICT: //p') $rc"
  if [ "$got" = "$want" ]; then echo "PASS $name: $got"; else echo "FAIL $name: got '$got' want '$want'"; printf '%s\n' "$out" | sed 's/^/    /'; fail=1; fi
done
exit $fail
