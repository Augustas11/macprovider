#!/usr/bin/env bash
# Guard the #615 production exception register validator, report, and gates.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"

fail() {
  printf '[test-production-exceptions] ERROR: %s\n' "$*" >&2
  exit 1
}

python3 -m json.tool ops/exceptions/production-exceptions.json >/dev/null
python3 -m json.tool ops/exceptions/production-exceptions.schema.json >/dev/null
python3 -m json.tool ops/exceptions/removed-exception-tombstones.json >/dev/null

python3 scripts/check-production-exceptions.py \
  --now 2026-07-22T12:00:00Z \
  validate \
  || fail "committed register failed validate"

report="$(mktemp "${TMPDIR:-/tmp}/exception-report.XXXXXX")"
python3 scripts/check-production-exceptions.py \
  --now 2026-07-22T12:00:00Z \
  report \
  -o "$report" \
  || fail "report generation failed"
python3 - "$report" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report.get("secrets_redacted") is True
assert report.get("field_set") == "allowlisted-v1"
assert isinstance(report.get("exceptions"), list) and report["exceptions"]
assert report["validation"]["ok"] is True
# Free-prose inventory fields must never appear in the allowlisted report.
for forbidden_field in ("owner", "policy_delta", "authority_surface", "reason", "scope"):
    for row in report["exceptions"]:
        assert forbidden_field not in row
forbidden = ("Bearer ", "BEGIN ", "ghp_", "sk-", "password=", "AKIA", "eyJ", "Basic ")
blob = json.dumps(report)
for token in forbidden:
    if token in blob:
        raise SystemExit(f"report leaked secret-like token {token!r}")
# Adversarial free-prose must be omitted even when schema-valid.
PY
rm -f "$report"

# Schema-valid register with Basic/JWT/AKIA/owner secrets must not leak into report.
adv="$(mktemp -d "${TMPDIR:-/tmp}/exception-adv.XXXXXX")"
python3 - "$adv" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
jwt = (
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
  "eyJzdWIiOiIxMjM0NTY3ODkwIn0."
  "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
)
doc = {
  "$schema": "./production-exceptions.schema.json",
  "schema_version": "macprovider-production-exceptions-v1",
  "updated_at": "2026-07-22T00:00:00Z",
  "updated_by": "test",
  "environment": "pearl-production",
  "exceptions": [{
    "id": "exc-adv-secrets",
    "status": "active",
    "environment": "pearl-production",
    "component": "other",
    "policy_delta": f"Authorization: Basic dXNlcjpwYXNz {jwt}",
    "authority_surface": "test",
    "reason": "AKIAIOSFODNN7EXAMPLE",
    "owner": "Authorization: Basic dTpw",
    "issue": "https://github.com/Augustas11/macprovider/issues/615",
    "created_at": "2026-07-01T00:00:00Z",
    "expires_at": "2026-08-01T00:00:00Z",
    "scope": "api_key=supersecretvalue; must not widen",
    "removal_condition": "done",
    "rollback_command": "echo",
    "post_removal_validation": "echo",
    "blocks_stable_promotion": False,
    "evidence": ["https://github.com/Augustas11/macprovider/issues/615"],
  }],
  "open_questions": [],
}
tombs = {
  "schema_version": "macprovider-removed-exception-tombstones-v1",
  "updated_at": "2026-07-22T00:00:00Z",
  "updated_by": "test",
  "environment": "pearl-production",
  "tombstones": [],
}
(work / "reg.json").write_text(json.dumps(doc))
(work / "tombs.json").write_text(json.dumps(tombs))
PY
adv_report="$adv/report.json"
python3 scripts/check-production-exceptions.py \
  --register "$adv/reg.json" \
  --tombstones "$adv/tombs.json" \
  --now 2026-07-22T12:00:00Z \
  report -o "$adv_report" \
  || fail "adversarial allowlisted report failed"
python3 - "$adv_report" <<'PY'
import json, sys
blob = open(sys.argv[1], encoding="utf-8").read()
report = json.loads(blob)
assert report["secrets_redacted"] is True
assert report["field_set"] == "allowlisted-v1"
for token in (
  "dTpw",
  "dXNlcjpwYXNz",
  "AKIAIOSFODNN7EXAMPLE",
  "supersecretvalue",
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
  '"owner"',
):
    if token in blob:
        raise SystemExit(f"allowlisted report leaked {token!r}")
PY
rm -rf "$adv"

# Default-safe deploy gate must pass on the committed inventory (warnings OK).
python3 scripts/check-production-exceptions.py \
  --now 2026-07-22T12:00:00Z \
  gate --mode=deploy --no-enforce \
  || fail "default-safe deploy gate failed unexpectedly"

# Promote mode must fail closed while expired/unbounded exceptions remain.
if python3 scripts/check-production-exceptions.py \
  --now 2026-07-22T12:00:00Z \
  gate --mode=promote; then
  fail "promote gate unexpectedly passed while expired/unbounded exceptions remain"
fi

# Deploy tooling must invoke the exception gate.
grep -qF 'check-production-exceptions.py' \
  phase4-coordinator/dist/check-deploy-config.sh \
  || fail "check-deploy-config.sh does not reference the exception checker"
grep -qE 'gate --mode=deploy' \
  phase4-coordinator/dist/check-deploy-config.sh \
  || fail "check-deploy-config.sh does not invoke the exception deploy gate"

# Gateway deploy must invoke the exception gate before SKIP_C2_CHECK refusal,
# and the production path must still run runtime credential proof/config gate.
grep -qF 'check-production-exceptions.py' \
  phase5-gateway/dist/deploy-pearl-vps.sh \
  || fail "gateway deploy does not reference the exception checker"
exc_line="$(grep -nF 'check-production-exceptions.py' phase5-gateway/dist/deploy-pearl-vps.sh | head -n1 | cut -d: -f1)"
skip_line="$(grep -nF 'SKIP_C2_CHECK=1 is no longer supported' phase5-gateway/dist/deploy-pearl-vps.sh | head -n1 | cut -d: -f1)"
proof_line="$(grep -nF '_c2c_proofs=' phase5-gateway/dist/deploy-pearl-vps.sh | head -n1 | cut -d: -f1)"
check_line="$(grep -nF 'bash "$CHECK_SCRIPT" "${CHECK_ARGS[0]}" "$GATEWAY_REMOTE_CONFIG_TMP" "${CHECK_ARGS[@]:1}"' phase5-gateway/dist/deploy-pearl-vps.sh | head -n1 | cut -d: -f1)"
[ -n "$exc_line" ] && [ -n "$skip_line" ] && [ -n "$proof_line" ] && [ -n "$check_line" ] &&
  [ "$exc_line" -lt "$skip_line" ] && [ "$skip_line" -lt "$proof_line" ] && [ "$proof_line" -lt "$check_line" ] ||
  fail "gateway exception/skip-refusal/proof/check ordering invalid (exc=$exc_line skip=$skip_line proof=$proof_line check=$check_line)"
if grep -qF 'skipping timer/header assertions' phase5-gateway/dist/deploy-pearl-vps.sh; then
  fail "gateway deploy still advertises a SKIP_C2_CHECK timer/header bypass"
fi

# Stable promotion workflow must invoke the reusable promote gate helper.
grep -qF 'scripts/gate-production-exceptions-promote.sh' \
  .github/workflows/promote-acceptance-candidate.yml \
  || fail "promote-acceptance-candidate.yml missing exception promote helper"
grep -qF 'gate --mode=promote' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper missing gate --mode=promote"
grep -qF 'origin/main' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper must bind to origin/main"
grep -qF 'Re-check production exceptions before draft creation' \
  .github/workflows/promote-acceptance-candidate.yml \
  || fail "promote workflow missing pre-draft exception recheck"
# Undraft binding: bind SHA at publish start, re-gate immediately before
# draft=false PATCH, and refuse if the bound authority SHA moved.
python3 - <<'PY'
from pathlib import Path
text = Path(".github/workflows/promote-acceptance-candidate.yml").read_text(encoding="utf-8")
marker = "Reverify and publish only the captured numeric draft"
start = text.index(marker)
chunk = text[start:start + 6500]
if chunk.count("EXCEPTION_GATE_SHA_FILE=") < 2:
    raise SystemExit("publish step must bind then re-bind EXCEPTION_GATE_SHA_FILE")
if "EXCEPTION_AUTHORITY_SHA=" not in chunk:
    raise SystemExit("publish step missing EXCEPTION_AUTHORITY_SHA print")
if "exception authority moved before undraft" not in chunk:
    raise SystemExit("publish step missing pre-PATCH authority SHA compare")
first_gate = chunk.index("bash scripts/gate-production-exceptions-promote.sh")
second_gate = chunk.index("bash scripts/gate-production-exceptions-promote.sh", first_gate + 1)
bind_at = chunk.index("exception authority moved before undraft")
patch_at = chunk.index("-F draft=false -F prerelease=false")
if not (first_gate < second_gate < bind_at < patch_at):
    raise SystemExit("bind-gate -> re-gate -> SHA compare -> undraft PATCH ordering violated")
print("ok: undraft-bound exception recheck with SHA bind")
PY
grep -qF 'EXCEPTION_AUTHORITY_SHA=' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper missing EXCEPTION_AUTHORITY_SHA bind"
grep -qF 'earliest_expiry_previous_register' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper missing earliest-expiry history reconstruction"
grep -qF -- '--first-parent' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper must walk first-parent history"
grep -qF 'ops/exceptions/production-exceptions.json' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper must path-scope exception register history"
grep -qF 'first_parent_path_scoped=1' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper missing path-scoped history marker"
grep -qF 'EXCEPTION_HISTORY_WINDOW is no longer supported' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper must reject EXCEPTION_HISTORY_WINDOW cap"
grep -qF 'refusing to synthesize an empty current tombstone ledger' \
  scripts/gate-production-exceptions-promote.sh \
  || fail "promote helper must fail closed on missing/invalid current tombstones"

# Positive history-window caps must fail closed (not silently truncate).
if EXCEPTION_HISTORY_WINDOW=1 bash scripts/gate-production-exceptions-promote.sh >/tmp/exc-cap.out 2>&1; then
  fail "EXCEPTION_HISTORY_WINDOW=1 must not succeed"
fi
grep -qF 'EXCEPTION_HISTORY_WINDOW is no longer supported' /tmp/exc-cap.out \
  || fail "cap rejection message missing"
rm -f /tmp/exc-cap.out

# Path-scoped first-parent history must keep main~2 authority after many
# unrelated successors and a merge fan-out larger than any numeric window.
hist="$(mktemp -d "${TMPDIR:-/tmp}/exception-hist.XXXXXX")"
python3 - "$hist" "$root" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

hist = Path(sys.argv[1])
scripts = Path(sys.argv[2]) / "scripts"
sys.path.insert(0, str(scripts))
import production_exceptions as pe

repo = hist / "repo"
repo.mkdir()
git_env = os.environ.copy()
for name in ("GIT_COMMON_DIR", "GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    git_env.pop(name, None)


def git_call(*args, **kwargs):
    kwargs.setdefault("cwd", repo)
    kwargs.setdefault("env", git_env)
    return subprocess.check_call(["git", *args], **kwargs)


def git_output(*args, **kwargs):
    kwargs.setdefault("cwd", repo)
    kwargs.setdefault("env", git_env)
    kwargs.setdefault("text", True)
    return subprocess.check_output(["git", *args], **kwargs)


git_call("init", "-b", "main", stdout=subprocess.DEVNULL)
git_call("config", "user.email", "test@example.com")
git_call("config", "user.name", "test")

reg = {
  "$schema": "./production-exceptions.schema.json",
  "schema_version": "macprovider-production-exceptions-v1",
  "updated_at": "2026-07-22T00:00:00Z",
  "updated_by": "test",
  "environment": "pearl-production",
  "exceptions": [{
    "id": "exc-hist",
    "status": "active",
    "environment": "pearl-production",
    "component": "other",
    "policy_delta": "x",
    "authority_surface": "x",
    "reason": "x",
    "owner": "ops/test",
    "issue": "https://github.com/Augustas11/macprovider/issues/615",
    "created_at": "2026-07-01T00:00:00Z",
    "expires_at": "2026-08-01T00:00:00Z",
    "scope": "test; must not widen",
    "removal_condition": "done",
    "rollback_command": "echo",
    "post_removal_validation": "echo",
    "blocks_stable_promotion": False,
    "evidence": ["https://github.com/Augustas11/macprovider/issues/615"],
  }],
  "open_questions": [],
}
tombs = {
  "schema_version": "macprovider-removed-exception-tombstones-v1",
  "updated_at": "2026-07-22T00:00:00Z",
  "updated_by": "test",
  "environment": "pearl-production",
  "tombstones": [{
    "id": "exc-old",
    "removed_at": "2026-07-20T00:00:00Z",
    "removal_evidence": "prior",
    "authority_surface": "test",
  }],
}
reg_dir = repo / "ops/exceptions"
reg_dir.mkdir(parents=True)
(reg_dir / "production-exceptions.json").write_text(json.dumps(reg, indent=2) + "\n")
(reg_dir / "removed-exception-tombstones.json").write_text(json.dumps(tombs, indent=2) + "\n")
git_call("add", ".")
git_call("commit", "-m", "baseline", stdout=subprocess.DEVNULL)
baseline = git_output("rev-parse", "HEAD").strip()

reg["exceptions"][0]["expires_at"] = "2026-10-01T00:00:00Z"
tombs["tombstones"] = []
(reg_dir / "production-exceptions.json").write_text(json.dumps(reg, indent=2) + "\n")
(reg_dir / "removed-exception-tombstones.json").write_text(json.dumps(tombs, indent=2) + "\n")
git_call("add", ".")
git_call("commit", "-m", "weaken", stdout=subprocess.DEVNULL)
weaken = git_output("rev-parse", "HEAD").strip()

(repo / "unrelated.txt").write_text("0\n")
git_call("add", "unrelated.txt")
git_call("commit", "-m", "unrelated-0", stdout=subprocess.DEVNULL)
for i in range(1, 40):
    # Empty commits keep first-parent depth without stressing the object store.
    git_call("commit", "--allow-empty", "-m", f"unrelated-{i}", stdout=subprocess.DEVNULL)

git_call("checkout", "-b", "side", baseline, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for i in range(40):
    git_call("commit", "--allow-empty", "-m", f"side-{i}", stdout=subprocess.DEVNULL)
git_call("checkout", "main", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
git_call("merge", "--no-ff", "-m", "merge-side", "side", stdout=subprocess.DEVNULL)
tip = git_output("rev-parse", "HEAD").strip()

raw = git_output("rev-list", "-n", "32", tip).split()
path = git_output(
    "rev-list", "--first-parent", tip, "--",
      "ops/exceptions/production-exceptions.json",
      "ops/exceptions/removed-exception-tombstones.json",
).split()
if baseline not in path or weaken not in path:
    raise SystemExit(f"path-scoped history missing authority commits: {path}")
# Numeric -n 32 without path scope is expected to forget under merge fan-out.
if baseline in raw and weaken in raw:
    print("note: numeric window still saw authority in this topology; path-scope still required")

revs = list(path)
if not revs or revs[0] != tip:
    revs = [tip, *revs]


def show(rev, path_name):
    raw_doc = git_output("show", f"{rev}:{path_name}")
    return json.loads(raw_doc)

regs = [show(rev, "ops/exceptions/production-exceptions.json") for rev in reversed(revs)]
tomb_docs = [show(rev, "ops/exceptions/removed-exception-tombstones.json") for rev in reversed(revs)]
current = show(tip, "ops/exceptions/production-exceptions.json")
current_tombs = show(tip, "ops/exceptions/removed-exception-tombstones.json")
previous = pe.earliest_expiry_previous_register(current, regs)
base = pe.union_tombstone_docs(tomb_docs)
result = pe.validate_register(
    current,
    now=pe.parse_rfc3339("2026-07-22T12:00:00Z"),
    tombstones=current_tombs,
    previous_doc=previous,
    base_tombstones=base,
)
codes = {f.code for f in result.errors}
if "expiry_self_extension" not in codes:
    raise SystemExit(f"missing expiry_self_extension in {codes}")
if "tombstone_deleted" not in codes:
    raise SystemExit(f"missing tombstone_deleted in {codes}")
print("ok: path-scoped history keeps main~2 authority after unrelated+merge fan-out")
PY
rm -rf "$hist"

# sync-check CLI (documented form with --tombstones after subcommand).
work="$(mktemp -d "${TMPDIR:-/tmp}/exception-sync.XXXXXX")"
python3 - "$work" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
removed = {
  "$schema": "./production-exceptions.schema.json",
  "schema_version": "macprovider-production-exceptions-v1",
  "updated_at": "2026-07-22T00:00:00Z",
  "updated_by": "test",
  "environment": "pearl-production",
  "exceptions": [{
    "id": "exc-sync-removed",
    "status": "removed",
    "environment": "pearl-production",
    "component": "other",
    "policy_delta": "gone",
    "authority_surface": "test",
    "reason": "test",
    "owner": "ops/test",
    "issue": "https://github.com/Augustas11/macprovider/issues/615",
    "created_at": "2026-07-01T00:00:00Z",
    "expires_at": "2099-01-01T00:00:00Z",
    "scope": "test",
    "removal_condition": "done",
    "rollback_command": "echo",
    "post_removal_validation": "echo",
    "blocks_stable_promotion": False,
    "evidence": ["https://github.com/Augustas11/macprovider/issues/615"],
  }],
  "open_questions": [],
}
active = json.loads(json.dumps(removed))
active["exceptions"][0]["status"] = "active"
tombs = {
  "schema_version": "macprovider-removed-exception-tombstones-v1",
  "updated_at": "2026-07-22T00:00:00Z",
  "updated_by": "test",
  "environment": "pearl-production",
  "tombstones": [{
    "id": "exc-sync-removed",
    "removed_at": "2026-07-20T00:00:00Z",
    "removal_evidence": "test",
    "authority_surface": "test",
  }],
}
(work / "current.json").write_text(json.dumps(removed))
(work / "stale.json").write_text(json.dumps(active))
(work / "tombs.json").write_text(json.dumps(tombs))
PY
if python3 scripts/check-production-exceptions.py \
  --now 2026-07-22T12:00:00Z \
  sync-check \
  --current "$work/current.json" \
  --stale "$work/stale.json" \
  --tombstones "$work/tombs.json"; then
  fail "sync-check unexpectedly passed on resurrecting stale register"
fi
rm -rf "$work"

bash phase5-gateway/dist/test/gateway_deploy_c2_precheck.test.sh \
  || fail "gateway deploy C2/exception precheck failed"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_production_exceptions

printf '[test-production-exceptions] OK\n'
