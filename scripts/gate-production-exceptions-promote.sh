#!/usr/bin/env bash
# Fail-closed #615 stable-promotion gate against current origin/main.
#
# Durability: walks first-parent commits that touched the exception register
# or tombstone ledger (path-scoped), so unrelated successors cannot push the
# last sound authority out of a fixed numeric window. For each such commit:
#   - union all tombstone IDs ever present (anti-deletion)
#   - reconstruct previous expires_at as the earliest active expiry per ID
#     (anti self-extension)
#
# Authority binding: prints EXCEPTION_AUTHORITY_SHA=<origin/main> so callers
# can refuse undraft if main moved after the gate. Optional
# EXCEPTION_GATE_SHA_FILE captures that SHA for later comparison.
set -euo pipefail

# Optional safety cap on path history depth (0 = unlimited).
HISTORY_WINDOW="${EXCEPTION_HISTORY_WINDOW:-0}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"

git fetch --no-tags origin main
main_sha="$(git rev-parse origin/main)"

work="$(mktemp -d "${TMPDIR:-/tmp}/exception-promote.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$main_sha" "$HISTORY_WINDOW" "$work" "$root" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

main_sha = sys.argv[1]
window = int(sys.argv[2])
work = Path(sys.argv[3])
root = Path(sys.argv[4])
sys.path.insert(0, str(root / "scripts"))
import production_exceptions as pe  # noqa: E402

REGISTER_PATH = "ops/exceptions/production-exceptions.json"
TOMBSTONE_PATH = "ops/exceptions/removed-exception-tombstones.json"


def show_json(rev: str, path: str):
    try:
        raw = subprocess.check_output(
            ["git", "show", f"{rev}:{path}"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


# Path-scoped first-parent history: only commits that touched exception
# authority files. Unrelated successors do not consume the sample budget.
cmd = ["git", "rev-list", "--first-parent", main_sha, "--", REGISTER_PATH, TOMBSTONE_PATH]
if window > 0:
    cmd[3:3] = ["-n", str(window)]
revs = subprocess.check_output(cmd, text=True).split()
# Always include the current tip so we evaluate today's trees even when the
# tip commit itself did not modify the exception paths.
if not revs or revs[0] != main_sha:
    revs = [main_sha, *revs]
# Deduplicate while preserving newest-first order from rev-list.
seen = set()
ordered = []
for rev in revs:
    if rev in seen:
        continue
    seen.add(rev)
    ordered.append(rev)
revs = ordered
if not revs:
    raise SystemExit("no revisions for exception authority history")

# Helpers expect oldest-first history.
history_regs = [show_json(rev, REGISTER_PATH) for rev in reversed(revs)]
history_tombs = [show_json(rev, TOMBSTONE_PATH) for rev in reversed(revs)]

current_register = show_json(main_sha, REGISTER_PATH)
if not isinstance(current_register, dict):
    raise SystemExit("origin/main production-exceptions.json missing/invalid")

current_tombs = show_json(main_sha, TOMBSTONE_PATH)
if not isinstance(current_tombs, dict):
    current_tombs = {
        "schema_version": pe.TOMBSTONE_SCHEMA_VERSION,
        "updated_at": "1970-01-01T00:00:00Z",
        "updated_by": "missing",
        "environment": pe.ENVIRONMENT,
        "tombstones": [],
    }

base_tombs = pe.union_tombstone_docs(history_tombs)
previous = pe.earliest_expiry_previous_register(current_register, history_regs)

(work / "production-exceptions.json").write_text(
    json.dumps(current_register, indent=2) + "\n", encoding="utf-8"
)
(work / "removed-exception-tombstones.json").write_text(
    json.dumps(current_tombs, indent=2) + "\n", encoding="utf-8"
)
(work / "base-tombstones.json").write_text(
    json.dumps(base_tombs, indent=2) + "\n", encoding="utf-8"
)
(work / "previous-production-exceptions.json").write_text(
    json.dumps(previous, indent=2) + "\n", encoding="utf-8"
)
(work / "authority.sha").write_text(main_sha + "\n", encoding="ascii")
print(
    f"exception-promote-gate: main={main_sha} "
    f"history_commits={len(revs)} first_parent_path_scoped=1"
)
print(f"EXCEPTION_AUTHORITY_SHA={main_sha}")
PY

python3 scripts/check-production-exceptions.py \
  --register "$work/production-exceptions.json" \
  --tombstones "$work/removed-exception-tombstones.json" \
  --base-tombstones "$work/base-tombstones.json" \
  --previous-register "$work/previous-production-exceptions.json" \
  gate --mode=promote

# Re-confirm the fetched tip did not move under us before returning success.
fresh="$(git rev-parse origin/main)"
bound="$(cat "$work/authority.sha")"
if [ "$fresh" != "$bound" ]; then
  echo "FAIL: origin/main moved during exception gate ($bound -> $fresh); re-run required" >&2
  exit 1
fi
if [ -n "${EXCEPTION_GATE_SHA_FILE:-}" ]; then
  printf '%s\n' "$bound" > "$EXCEPTION_GATE_SHA_FILE"
fi
