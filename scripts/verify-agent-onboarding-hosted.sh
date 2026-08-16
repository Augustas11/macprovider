#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-agent-onboarding-hosted] ERROR: %s\n' "$*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill="${1:-$repo_root/docs/agent-onboarding/SKILL.md}"
index="${2:-$repo_root/docs/agent-onboarding/.well-known/skills/index.json}"
host="${MALIBU_AGENT_ONBOARDING_HOST:-get.malibu.tech}"
base="https://${host}"

[[ "$host" == "get.malibu.tech" ]] || die "unexpected agent onboarding host: $host"
for path in "$skill" "$index"; do
  [[ -f "$path" && ! -L "$path" ]] || die "expected regular local artifact: $path"
done

PYTHONDONTWRITEBYTECODE=1 python3 "$repo_root/scripts/verify-agent-onboarding-skill.py" \
  --skill "$skill" --index "$index"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/agent-onboarding-public.XXXXXX")"
trap 'rm -rf "$work"' EXIT

curl_args=(
  --fail --show-error --silent --location --proto '=https' --tlsv1.2
  --connect-timeout 20 --max-time 120 --retry 3 --retry-delay 2
)
curl "${curl_args[@]}" -o "$work/skill.md" "${base}/skill.md"
curl "${curl_args[@]}" -o "$work/index.json" \
  "${base}/.well-known/skills/index.json"

cmp -s "$skill" "$work/skill.md" ||
  die "hosted skill bytes differ from repo source"
cmp -s "$index" "$work/index.json" ||
  die "hosted discovery index bytes differ from repo source"

printf '[verify-agent-onboarding-hosted] ok: %s serves skill/index bytes\n' "$base"
