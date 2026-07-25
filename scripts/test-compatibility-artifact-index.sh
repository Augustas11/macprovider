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
  catalog_demand_signature catalog_manifest catalog_trusted_keys
  compatibility_manifest coordinator coordinator_cli gateway
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

# Future provider publications must reject the historical Malibu role.
printf '%s\n' malibu_app > "$work/malibu_app.asset"
legacy_arguments=("${arguments[@]}" --artifact "malibu_app=$work/malibu_app.asset")
if python3 "$tool" build \
  --output "$work/future-legacy-index.json" \
  --compatibility-manifest "$work/compatibility-set.json" \
  "${legacy_arguments[@]}" >"$work/future-legacy.out" 2>&1; then
  echo "future provider artifact index accepted the legacy Malibu role" >&2
  exit 1
fi
grep -q 'Malibu role is allowed only for an immutable legacy release' "$work/future-legacy.out"

# Only the exact immutable v1.8.39 bridge may retain the legacy evidence row.
legacy_tag=v1.8.39
legacy_commit=71eb927a56011f00143b2989cb2bc455b86d4d7c
legacy_set_id="$repository:$legacy_tag@$legacy_commit"
printf '%s\n' '{"schema_version":"macprovider.compatibility-set-envelope.v1","signatures":[],"signed":{"compatibility_set_id":"'"$legacy_set_id"'","release":{"commit":"'"$legacy_commit"'","repository":"'"$repository"'","tag":"'"$legacy_tag"'","version":"1.8.39"}}}' > "$work/legacy-compatibility-set.json"
legacy_arguments=()
for role in "${roles[@]}"; do
  path="$work/${role}.asset"
  if [[ "$role" == compatibility_manifest ]]; then
    path="$work/legacy-compatibility-set.json"
  fi
  legacy_arguments+=(--artifact "$role=$path")
done
legacy_arguments+=(--artifact "malibu_app=$work/malibu_app.asset")
python3 "$tool" build \
  --output "$work/legacy-index.json" \
  --compatibility-manifest "$work/legacy-compatibility-set.json" \
  --repository "$repository" --tag "$legacy_tag" --commit "$legacy_commit" \
  "${legacy_arguments[@]}"
python3 "$tool" validate \
  --input "$work/legacy-index.json" \
  --compatibility-manifest "$work/legacy-compatibility-set.json" \
  --repository "$repository" --tag "$legacy_tag" --commit "$legacy_commit" \
  "${legacy_arguments[@]}"

# The immutable public v1.8.40 release also carried the historical evidence row.
legacy_tag=v1.8.40
legacy_commit=18638472fe3e885f3534eeac29ab89b4c7ffdd7a
legacy_set_id="$repository:$legacy_tag@$legacy_commit"
printf '%s\n' '{"schema_version":"macprovider.compatibility-set-envelope.v1","signatures":[],"signed":{"compatibility_set_id":"'"$legacy_set_id"'","release":{"commit":"'"$legacy_commit"'","repository":"'"$repository"'","tag":"'"$legacy_tag"'","version":"1.8.40"}}}' > "$work/legacy-compatibility-set.json"
legacy_arguments=()
for role in "${roles[@]}"; do
  path="$work/${role}.asset"
  if [[ "$role" == compatibility_manifest ]]; then
    path="$work/legacy-compatibility-set.json"
  fi
  legacy_arguments+=(--artifact "$role=$path")
done
legacy_arguments+=(--artifact "malibu_app=$work/malibu_app.asset")
python3 "$tool" build \
  --output "$work/legacy-index.json" \
  --compatibility-manifest "$work/legacy-compatibility-set.json" \
  --repository "$repository" --tag "$legacy_tag" --commit "$legacy_commit" \
  "${legacy_arguments[@]}"
python3 "$tool" validate \
  --input "$work/legacy-index.json" \
  --compatibility-manifest "$work/legacy-compatibility-set.json" \
  --repository "$repository" --tag "$legacy_tag" --commit "$legacy_commit" \
  "${legacy_arguments[@]}"

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
