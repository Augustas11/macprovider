#!/usr/bin/env bash
# Collect third-party license/notice files from SwiftPM checkouts and write
# them to a single attribution file.
#
# Usage:
#   ./scripts/gather-third-party-notices.sh [OUTPUT_PATH]
#
# OUTPUT_PATH defaults to phase3-binary/dist/THIRD-PARTY-NOTICES.txt
# The script must be run from the repository root.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

CHECKOUTS_DIR="$REPO_ROOT/phase3-binary/.build/checkouts"
OUTPUT="${1:-$REPO_ROOT/phase3-binary/dist/THIRD-PARTY-NOTICES.txt}"

if [ ! -d "$CHECKOUTS_DIR" ]; then
    echo "ERROR: checkouts directory not found: $CHECKOUTS_DIR" >&2
    echo "Run 'swift package resolve' in phase3-binary/ first." >&2
    exit 1
fi

# Candidate filenames, in preference order (case-insensitive match below)
LICENSE_NAMES=(LICENSE LICENSE.txt LICENSE.md NOTICE NOTICE.txt COPYING)

mkdir -p "$(dirname "$OUTPUT")"

{
    printf "THIRD-PARTY NOTICES\n"
    printf "===================\n"
    printf "This file lists the open-source packages statically linked into\n"
    printf "the macprovider-cli binary, together with their license/notice text.\n\n"
} > "$OUTPUT"

found_any=0

for pkg_dir in "$CHECKOUTS_DIR"/*/; do
    [ -d "$pkg_dir" ] || continue
    pkg_name=$(basename "$pkg_dir")
    found_files=()

    for name in "${LICENSE_NAMES[@]}"; do
        # Case-insensitive search (find -iname)
        while IFS= read -r -d '' match; do
            found_files+=("$match")
        done < <(find "$pkg_dir" -maxdepth 1 -iname "$name" -print0 2>/dev/null)
    done

    if [ "${#found_files[@]}" -eq 0 ]; then
        echo "NOTICE: no license file found for $pkg_name — skipping" >&2
        continue
    fi

    for f in "${found_files[@]}"; do
        fname=$(basename "$f")
        {
            printf "\n===== %s (%s) =====\n\n" "$pkg_name" "$fname"
            cat "$f"
            printf "\n"
        } >> "$OUTPUT"
    done

    found_any=1
done

if [ "$found_any" -eq 0 ]; then
    echo "WARNING: no license files collected — output file may be incomplete" >&2
fi

echo "Wrote third-party notices to: $OUTPUT" >&2
