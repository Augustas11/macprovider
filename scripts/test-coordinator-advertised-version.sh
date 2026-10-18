#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift"
app_project_file="$repo_root/phase3-binary/app/project.yml"
app_version_helper="$repo_root/scripts/malibu-app-version.sh"
expected_version="${1:-}"
expected_version="${expected_version#v}"
previous_stable_version=""
staged_candidate_version=""
if [[ "$#" -gt 3 ]]; then
  echo "usage: $0 [vX.Y.Z] [--allow-previous-stable=X.Y.Z] [--staged-candidate=X.Y.Z]" >&2
  exit 2
fi
for policy in "${@:2}"; do
  case "$policy" in
    --allow-previous-stable=*)
      previous_stable_version="${policy#--allow-previous-stable=}"
      ;;
    --staged-candidate=*)
      staged_candidate_version="${policy#--staged-candidate=}"
      ;;
    *)
      echo "usage: $0 [vX.Y.Z] [--allow-previous-stable=X.Y.Z] [--staged-candidate=X.Y.Z]" >&2
      exit 2
      ;;
  esac
done
if [[ -n "$previous_stable_version" && ! "$previous_stable_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "previous stable coordinator recommendation is not semver: $previous_stable_version" >&2
  exit 1
fi
if [[ -n "$staged_candidate_version" && ! "$staged_candidate_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "staged candidate coordinator version is not semver: $staged_candidate_version" >&2
  exit 1
fi
if [[ -n "$previous_stable_version" && -z "$staged_candidate_version" ]]; then
  echo "staged previous stable policy must bind an explicit candidate version" >&2
  exit 1
fi
if [[ -z "$previous_stable_version" && -n "$staged_candidate_version" ]]; then
  echo "staged candidate policy requires a previous stable coordinator policy" >&2
  exit 1
fi

if [[ ! -f "$source_file" ]]; then
  echo "missing CLI version source: $source_file" >&2
  exit 1
fi
if [[ ! -f "$app_project_file" ]]; then
  echo "missing Malibu app project: $app_project_file" >&2
  exit 1
fi
if [[ ! -f "$app_version_helper" ]]; then
  echo "missing Malibu app version helper: $app_version_helper" >&2
  exit 1
fi

binary_definition_count="$(awk '/^[[:space:]]*static let binaryVersion[[:space:]]*=/ { count++ } END { print count + 0 }' "$source_file")"
if [[ "$binary_definition_count" -ne 1 ]]; then
  echo "CoordinatorClient.swift must contain exactly one binaryVersion definition (found $binary_definition_count)" >&2
  exit 1
fi
binary_version_lines="$(sed -nE 's/^[[:space:]]*static let binaryVersion[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "$source_file")"
binary_version_count="$(printf '%s\n' "$binary_version_lines" | awk 'NF { count++ } END { print count + 0 }')"
if [[ "$binary_version_count" -ne 1 ]]; then
  echo "CoordinatorClient.binaryVersion must be one quoted value" >&2
  exit 1
fi
binary_version="$binary_version_lines"

if [[ ! "$binary_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "CLI binary version is not semver: $binary_version" >&2
  exit 1
fi

if [[ -n "$expected_version" && "$expected_version" != "$binary_version" ]]; then
  echo "release tag v$expected_version does not match CLI binary version $binary_version" >&2
  exit 1
fi

app_version_definition_count="$(awk '/^[[:space:]]*MARKETING_VERSION[[:space:]]*:/ { count++ } END { print count + 0 }' "$app_project_file")"
if [[ "$app_version_definition_count" -ne 1 ]]; then
  echo "project.yml must contain exactly one MARKETING_VERSION definition (found $app_version_definition_count)" >&2
  exit 1
fi
app_version_lines="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*:[[:space:]]*"([^"]+)".*$/\1/p' "$app_project_file")"
app_version_count="$(printf '%s\n' "$app_version_lines" | awk 'NF { count++ } END { print count + 0 }')"
if [[ "$app_version_count" -ne 1 ]]; then
  echo "project.yml MARKETING_VERSION must be one quoted value" >&2
  exit 1
fi
app_version="$app_version_lines"

app_build_definition_count="$(awk '/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*:/ { count++ } END { print count + 0 }' "$app_project_file")"
if [[ "$app_build_definition_count" -ne 1 ]]; then
  echo "project.yml must contain exactly one numeric CURRENT_PROJECT_VERSION definition (found $app_build_definition_count)" >&2
  exit 1
fi
app_build_lines="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*:[[:space:]]*"?([0-9]+)"?.*$/\1/p' "$app_project_file")"
app_build_count="$(printf '%s\n' "$app_build_lines" | awk 'NF { count++ } END { print count + 0 }')"
if [[ "$app_build_count" -ne 1 ]]; then
  echo "project.yml CURRENT_PROJECT_VERSION must be one numeric value" >&2
  exit 1
fi
app_build="$app_build_lines"

# SPEC-025 §3.3: the shipped app version is stamped from the release tag at
# build time. project.yml keeps only the development default so a stale
# hardcoded release version can never reach a shipped bundle again.
if [[ "$app_version" != "0.0.0" || "$app_build" != "0" ]]; then
  echo "project.yml must keep the development default MARKETING_VERSION \"0.0.0\" / CURRENT_PROJECT_VERSION \"0\" (found $app_version/$app_build); release builds stamp the version from the tag" >&2
  exit 1
fi
stamp_line="$(bash "$app_version_helper" "v$binary_version")" || exit 1
read -r release_app_version release_app_build <<<"$stamp_line"
if [[ "$release_app_version" != "$binary_version" ]]; then
  echo "Malibu app stamp $release_app_version does not match release version $binary_version" >&2
  exit 1
fi

config_files=(
  "$repo_root/phase4-coordinator/dist/coordinator.yaml"
  "$repo_root/phase4-coordinator/coordinator.yaml.example"
  "$repo_root/phase4-coordinator/dist/coordinator.yaml.example"
)

for config_file in "${config_files[@]}"; do
  if [[ ! -f "$config_file" ]]; then
    echo "missing coordinator config: $config_file" >&2
    exit 1
  fi

  version_lines="$(grep -E '^[[:space:]]*latest_binary_version:' "$config_file" || true)"
  version_count="$(printf '%s\n' "$version_lines" | awk 'NF { count++ } END { print count + 0 }')"
  if [[ "$version_count" -ne 1 ]]; then
    echo "$config_file must contain exactly one latest_binary_version (found $version_count)" >&2
    exit 1
  fi

  advertised_version="$(printf '%s\n' "$version_lines" | sed -nE 's/^[[:space:]]*latest_binary_version: "([^"]+)".*$/\1/p')"
  if [[ -z "$advertised_version" ]]; then
    echo "missing coordinator advertised version in $config_file" >&2
    exit 1
  fi

  if [[ -n "$previous_stable_version" ]]; then
    if [[ "$previous_stable_version" == "$binary_version" ]]; then
      echo "previous stable coordinator recommendation must differ from candidate $binary_version" >&2
      exit 1
    fi
    if [[ "$advertised_version" != "$previous_stable_version" ]]; then
      echo "$config_file advertises $advertised_version; expected staged previous stable $previous_stable_version" >&2
      exit 1
    fi
  elif [[ "$advertised_version" != "$binary_version" ]]; then
    echo "$config_file advertises $advertised_version; expected $binary_version" >&2
    exit 1
  fi
done

if [[ -n "$previous_stable_version" ]]; then
  if [[ "$staged_candidate_version" != "$binary_version" ]]; then
    echo "staged candidate $staged_candidate_version does not match CLI binary $binary_version" >&2
    exit 1
  fi
  echo "CLI $binary_version is staged with previous stable coordinator recommendation $previous_stable_version; Malibu is stamped $release_app_version build $release_app_build from the release tag"
else
  echo "CLI and coordinator advertised versions are aligned at $binary_version; Malibu is stamped $release_app_version build $release_app_build from the release tag"
fi
