#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: $0 <cli-tag> <cli-version> <cli-sha256> <cli-archive-sha256>" >&2
  exit 2
fi

cli_tag="$1"
cli_version="$2"
cli_sha256="$3"
cli_archive_sha256="$4"

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
bash "$repo_root/scripts/test-coordinator-advertised-version.sh" "$cli_tag"
