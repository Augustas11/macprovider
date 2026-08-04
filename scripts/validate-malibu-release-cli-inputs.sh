#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 4 || "$#" -gt 6 ]]; then
  echo "usage: $0 <cli-tag> <cli-version> <cli-sha256> <cli-archive-sha256> [coordinator-version-policy] [coordinator-candidate-policy]" >&2
  exit 2
fi

cli_tag="$1"
cli_version="$2"
cli_sha256="$3"
cli_archive_sha256="$4"
coordinator_version_policy="${5:-}"
coordinator_candidate_policy="${6:-}"

if [[ ! "$cli_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "CLI version must be numeric semver without a v prefix" >&2
  exit 1
fi
if [[ "$cli_tag" != "v${cli_version}" ]]; then
  echo "CLI tag must equal v plus the exact CLI version" >&2
  exit 1
fi
if [[ ! "$cli_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "CLI SHA-256 must be exactly 64 lowercase hexadecimal characters" >&2
  exit 1
fi
if [[ ! "$cli_archive_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "CLI archive SHA-256 must be exactly 64 lowercase hexadecimal characters" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "$coordinator_version_policy" ]]; then
  bash "$repo_root/scripts/test-coordinator-advertised-version.sh" \
    "$cli_tag" "$coordinator_version_policy" "$coordinator_candidate_policy"
else
  if [[ -n "$coordinator_candidate_policy" ]]; then
    echo "coordinator candidate policy requires a coordinator version policy" >&2
    exit 1
  fi
  bash "$repo_root/scripts/test-coordinator-advertised-version.sh" "$cli_tag"
fi
