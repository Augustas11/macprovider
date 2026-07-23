#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$root/scripts/compatibility-artifact-index.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/compatibility-artifact-index.XXXXXX")"
trap 'rm -rf "$work"' EXIT

tag=v1.8.33
commit=0123456789abcdef0123456789abcdef01234567
repository=Augustas11/macprovider
set_id="$repository:$tag@$commit"
printf '%s\n' '{"schema_version":"macprovider.compatibility-set-envelope.v1","signatures":[],"signed":{"compatibility_set_id":"'"$set_id"'","release":{"commit":"'"$commit"'","repository":"'"$repository"'","tag":"'"$tag"'","version":"1.8.33"}}}' > "$work/compatibility-set.json"

roles=(
  catalog_candidates catalog_candidates_signature catalog_demand
  catalog_demand_signature catalog_manifest catalog_tier2 catalog_trusted_keys
  compatibility_manifest coordinator coordinator_cli gateway malibu_app
  pearl_metadata pearl_metadata_signature provider_cli
)
arguments=()
for role in "${roles[@]}"; do
  path="$work/${role}.asset"
  if [[ "$role" == compatibility_manifest ]]; then
    path="$work/compatibility-set.json"
  else
    printf '%s\n' "$role" > "$path"
  fi
  arguments+=(--artifact "$role=$path")
done

python3 "$tool" build \
  --output "$work/index.json" \
  --compatibility-manifest "$work/compatibility-set.json" \
  --repository "$repository" --tag "$tag" --commit "$commit" \
  "${arguments[@]}"
python3 "$tool" validate \
  --input "$work/index.json" \
  --compatibility-manifest "$work/compatibility-set.json" \
  --repository "$repository" --tag "$tag" --commit "$commit" \
  "${arguments[@]}"

printf 'tampered\n' >> "$work/coordinator.asset"
if python3 "$tool" validate \
  --input "$work/index.json" \
  --compatibility-manifest "$work/compatibility-set.json" \
  "${arguments[@]}" >"$work/tamper.out" 2>&1; then
  echo "artifact index accepted a tampered coordinator" >&2
  exit 1
fi
grep -q 'coordinator differs from supplied release asset' "$work/tamper.out"

printf '[test-compatibility-artifact-index] PASS\n'
