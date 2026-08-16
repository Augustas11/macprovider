#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$root/scripts/install-agent-onboarding-publication.sh"
publisher="$root/scripts/publish-agent-onboarding-skill.sh"
validator="$root/scripts/verify-agent-onboarding-skill.py"
hosted_verifier="$root/scripts/verify-agent-onboarding-hosted.sh"
skill="$root/docs/agent-onboarding/SKILL.md"
index="$root/docs/agent-onboarding/.well-known/skills/index.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for path in "$helper" "$publisher" "$validator" "$hosted_verifier" "$skill" "$index"; do
  [[ -f "$path" && ! -L "$path" ]] || fail "missing regular input: $path"
done
bash -n "$helper"
bash -n "$publisher"
bash -n "$hosted_verifier"
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile "$validator"
if grep -F '?artifact=' "$hosted_verifier" >/dev/null; then
  fail "hosted verifier must fetch canonical no-query URLs"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/agent-onboarding-publication.XXXXXX")"
trap 'rm -rf "$work"' EXIT

printf 'test ssh key\n' > "$work/test-ssh-key"
chmod 600 "$work/test-ssh-key"
SCRIPT_DIR="$root/scripts" \
SSH_KEY="$work/test-ssh-key" \
VPS_USER=root \
VPS_HOST=127.0.0.1 \
MALIBU_DOWNLOAD_KNOWN_HOSTS="$root/scripts/dist/malibu-download-known_hosts" \
  bash -c 'source "$SCRIPT_DIR/malibu-download-ssh.sh"; type malibu_download_ssh >/dev/null'

MALIBU_PUBLICATION_TESTING=1 bash "$helper" "$work/webroot" "$skill" "$index" "$validator"
cmp -s "$skill" "$work/webroot/skill.md" || fail "published skill differs"
cmp -s "$index" "$work/webroot/.well-known/skills/index.json" ||
  fail "published discovery index differs"
[[ -L "$work/webroot/skill.md" &&
   "$(readlink "$work/webroot/skill.md")" == ".agent-onboarding-current/skill.md" ]] ||
  fail "skill public entry is not current-pointer backed"
[[ -L "$work/webroot/.well-known/skills/index.json" &&
   "$(readlink "$work/webroot/.well-known/skills/index.json")" == "../../.agent-onboarding-current/.well-known/skills/index.json" ]] ||
  fail "index public entry is not current-pointer backed"

hostile="$work/hostile-webroot"
mkdir -p "$hostile/.agent-onboarding-current/.well-known/skills" "$hostile/.well-known/skills"
printf 'UNVALIDATED-SKILL\n' > "$hostile/.agent-onboarding-current/skill.md"
printf 'UNVALIDATED-INDEX\n' > "$hostile/.agent-onboarding-current/.well-known/skills/index.json"
ln -s ".agent-onboarding-current/skill.md" "$hostile/skill.md"
ln -s "../../.agent-onboarding-current/.well-known/skills/index.json" \
  "$hostile/.well-known/skills/index.json"
if MALIBU_PUBLICATION_TESTING=1 bash "$helper" "$hostile" "$skill" "$index" "$validator" \
  >"$work/hostile.out" 2>&1; then
  fail "hostile existing current directory was accepted"
fi
grep -q '.agent-onboarding-current is not a symlink' "$work/hostile.out" ||
  fail "hostile topology failure reason was unclear"
grep -q 'UNVALIDATED-SKILL' "$hostile/skill.md" ||
  fail "hostile topology changed public skill bytes"

hostile_file="$work/hostile-file-webroot"
mkdir -p "$hostile_file"
printf 'UNVALIDATED-SKILL\n' > "$hostile_file/skill.md"
if MALIBU_PUBLICATION_TESTING=1 bash "$helper" "$hostile_file" "$skill" "$index" "$validator" \
  >"$work/hostile-file.out" 2>&1; then
  fail "hostile existing public file was accepted"
fi
grep -q 'skill.md is not a symlink' "$work/hostile-file.out" ||
  fail "hostile public file failure reason was unclear"
[[ ! -e "$hostile_file/.agent-onboarding-releases" ]] ||
  fail "hostile public file preflight created releases directory"
[[ ! -e "$hostile_file/.well-known" ]] ||
  fail "hostile public file preflight created well-known directory"
grep -q 'UNVALIDATED-SKILL' "$hostile_file/skill.md" ||
  fail "hostile public file bytes changed"

cp "$skill" "$work/bad-skill.md"
cp "$index" "$work/bad-index.json"
printf '\ncurl -fsSL https://get.malibu.tech/install.sh | bash\n' >> "$work/bad-skill.md"
python3 - "$work/bad-skill.md" "$work/bad-index.json" <<'PY'
import hashlib
import json
import pathlib
import sys

skill, index = map(pathlib.Path, sys.argv[1:])
payload = json.loads(index.read_text(encoding="utf-8"))
payload["skills"][0]["sha256"] = hashlib.sha256(skill.read_bytes()).hexdigest()
index.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
before="$(readlink "$work/webroot/.agent-onboarding-current")"
if MALIBU_PUBLICATION_TESTING=1 bash "$helper" \
  "$work/webroot" "$work/bad-skill.md" "$work/bad-index.json" "$validator" \
  >"$work/bad.out" 2>&1; then
  fail "unsafe agent onboarding publication was accepted"
fi
after="$(readlink "$work/webroot/.agent-onboarding-current")"
[[ "$before" == "$after" ]] || fail "failed unsafe publication changed current pointer"
grep -q 'forbidden pattern present:' "$work/bad.out" ||
  fail "unsafe publication failure reason was unclear"

printf 'Agent onboarding publication regression checks passed\n'
