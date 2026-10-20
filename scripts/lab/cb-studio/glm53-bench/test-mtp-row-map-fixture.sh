#!/usr/bin/env bash
set -euo pipefail

bench=${1:?usage: test-mtp-row-map-fixture.sh /absolute/path/to/GLMBench}
output=$("$bench" --mtp-row-map-fixture)
expected='mtp-row-map-fixture pass rows=4 width=2 query_offset=17'

if [[ $output != "$expected" ]]; then
  printf 'unexpected row-map fixture output: %s\n' "$output" >&2
  exit 1
fi
