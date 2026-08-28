#!/usr/bin/env bash
# Collect third-party license/notice files from SwiftPM checkouts and write
# them to a single attribution file.
#
# Usage:
#   ./scripts/gather-third-party-notices.sh [OUTPUT_PATH [CHECKOUTS_DIR]]
#
# OUTPUT_PATH defaults to phase3-binary/dist/THIRD-PARTY-NOTICES.txt
# CHECKOUTS_DIR defaults to phase3-binary/.build/checkouts (local dev default).
#   For release builds pass the actual xcodebuild checkouts path, e.g.:
#   phase3-binary/build-release/SourcePackages/checkouts
#
# The script must be run from the repository root.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

OUTPUT="${1:-$REPO_ROOT/phase3-binary/dist/THIRD-PARTY-NOTICES.txt}"
CHECKOUTS_DIR="${2:-$REPO_ROOT/phase3-binary/.build/checkouts}"

if [ ! -d "$CHECKOUTS_DIR" ]; then
    echo "ERROR: checkouts directory not found: $CHECKOUTS_DIR" >&2
    echo "Run 'swift package resolve' in phase3-binary/ first, or pass the" >&2
    echo "xcodebuild SourcePackages/checkouts path as the second argument." >&2
    exit 1
fi

# Resolve the checkouts root to a canonical real path for containment checks.
CHECKOUTS_REAL=$(realpath "$CHECKOUTS_DIR")

mkdir -p "$(dirname "$OUTPUT")"

{
    printf "THIRD-PARTY NOTICES\n"
    printf "===================\n"
    printf "This file lists the open-source packages statically linked into\n"
    printf "the malibu-cli binary, together with their license/notice text.\n\n"
} > "$OUTPUT"

found_any=0
missing_packages=()

# Use -P so find never follows symlinks when descending into directories.
while IFS= read -r -d '' pkg_dir; do
    # Containment check: verify the resolved path is still under CHECKOUTS_REAL.
    pkg_real=$(realpath "$pkg_dir")
    case "$pkg_real" in
        "$CHECKOUTS_REAL"/*)
            ;;
        *)
            echo "WARNING: skipping checkout outside root (possible symlink): $pkg_dir" >&2
            continue
            ;;
    esac

    pkg_name=$(basename "$pkg_dir")
    pkg_found_files=()

    # -P -type f: do NOT follow symlinks; only collect regular files at depth 1.
    while IFS= read -r -d '' f; do
        # Double-check the resolved file path is still inside this package dir.
        f_real=$(realpath "$f")
        case "$f_real" in
            "$pkg_real"/*)
                pkg_found_files+=("$f")
                ;;
            *)
                echo "WARNING: skipping symlink escape in $pkg_name: $f -> $f_real" >&2
                ;;
        esac
    done < <(find -P "$pkg_dir" -maxdepth 1 -type f \
        \( -iname LICENSE \
        -o -iname LICENSE.txt \
        -o -iname LICENSE.md \
        -o -iname NOTICE \
        -o -iname NOTICE.txt \
        -o -iname NOTICE.md \
        -o -iname COPYING \) -print0 2>/dev/null)

    if [ "${#pkg_found_files[@]}" -eq 0 ]; then
        echo "NOTICE: no license file found for $pkg_name — skipping" >&2
        missing_packages+=("$pkg_name")
        continue
    fi

    for f in "${pkg_found_files[@]}"; do
        fname=$(basename "$f")
        {
            printf "\n===== %s (%s) =====\n\n" "$pkg_name" "$fname"
            cat "$f"
            printf "\n"
        } >> "$OUTPUT"
    done

    found_any=1
done < <(find -P "$CHECKOUTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

if [ "$found_any" -eq 0 ] && [ "${#missing_packages[@]}" -eq 0 ]; then
    echo "WARNING: no license files collected — output file may be incomplete" >&2
fi

# Append a footer listing any packages that lacked attribution files.
# This ensures the artifact is a durable record of what was skipped.
if [ "${#missing_packages[@]}" -gt 0 ]; then
    {
        printf "\n===== PACKAGES WITH MISSING LICENSE/NOTICE FILES =====\n\n"
        printf "The following packages were present in the SwiftPM checkouts but\n"
        printf "contained no recognized license or notice file. Manual review required.\n\n"
        for pkg in "${missing_packages[@]}"; do
            printf "  - %s\n" "$pkg"
        done
        printf "\n"
    } >> "$OUTPUT"
fi

echo "Wrote third-party notices to: $OUTPUT" >&2
