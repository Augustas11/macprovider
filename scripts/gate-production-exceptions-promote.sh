#!/usr/bin/env bash
# Fail-closed #615 stable-promotion gate against current origin/main.
#
# Durability: walks ALL first-parent commits that touched the exception
# register or tombstone ledger (path-scoped, uncapped). For each such commit:
#   - union all tombstone IDs ever present (anti-deletion)
#   - reconstruct previous expires_at as the earliest active/planned/expired
#     expiry per ID (anti self-extension / expired reactivation)
#
# Authority binding: prints EXCEPTION_AUTHORITY_SHA=<origin/main> so callers
# can refuse undraft if main moved after the gate. Optional
# EXCEPTION_GATE_SHA_FILE captures that SHA for later comparison.
set -euo pipefail

if [ -n "${EXCEPTION_HISTORY_WINDOW:-}" ]; then
  echo "FAIL: EXCEPTION_HISTORY_WINDOW is no longer supported; path-scoped history is uncapped" >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"

git fetch --no-tags origin main
main_sha="$(git rev-parse origin/main)"

work="$(mktemp -d "${TMPDIR:-/tmp}/exception-promote.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "$main_sha" "$work" "$root" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

main_sha = sys.argv[1]
work = Path(sys.argv[2])
root = Path(sys.argv[3])
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
# authority files. Unrelated successors do not consume any sample budget.
# History is intentionally uncapped — a numeric window is fail-open.
revs = subprocess.check_output(
    ["git", "rev-list", "--first-parent", main_sha, "--", REGISTER_PATH, TOMBSTONE_PATH],
    text=True,
).split()
# Always include the current tip so we evaluate today's trees even when the
# tip commit itself did not modify the exception paths.
if not revs or revs[0] != main_sha:
    revs = [main_sha, *revs]
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
# Historical missing/invalid tombstone docs are tolerated (pre-ledger eras);
# only the tip ledger is required to be present and parseable.
history_tombs = [show_json(rev, TOMBSTONE_PATH) for rev in reversed(revs)]

current_register = show_json(main_sha, REGISTER_PATH)
if not isinstance(current_register, dict):
    raise SystemExit("origin/main production-exceptions.json missing/invalid")

current_tombs = show_json(main_sha, TOMBSTONE_PATH)
if not isinstance(current_tombs, dict):
    raise SystemExit(
        "origin/main removed-exception-tombstones.json missing/invalid; "
        "refusing to synthesize an empty current tombstone ledger"
    )

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
