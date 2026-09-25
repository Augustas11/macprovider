#!/usr/bin/env bash
# Runbook section 9 step 4a feed check, run exactly as written against
# (1) a YAML rendering of the lab coordinator config (Pearl's shape), and
# (2) the lab JSON config itself. Lab paths only.
set -uo pipefail
LAB=${1:?lab}
Y=$LAB/tmp/coordinator-4a.yaml
python3 - "$LAB/run/coordinator.yaml" "$Y" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
a = c["autotune"]
open(sys.argv[2], "w").write("autotune:\n" + "".join(f"  {k}: {v}\n" for k, v in a.items() if isinstance(v, str)))
PY
for cfg in "$Y" "$LAB/run/coordinator.yaml"; do
  echo "--- config $(basename "$cfg")"
  F=$(awk '/catalog_artifacts_path:/ {print $2}' "$cfg")
  echo "feed: ${F:-none}"
  [ -z "$F" ] || grep -c -e '"file_path"' -e mlxlm_loopback "$F"
done
