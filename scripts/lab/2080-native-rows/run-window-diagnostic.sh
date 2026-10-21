#!/usr/bin/env bash
# Fixed offline diagnostic for the guarded Studio window. This is not a
# provider server, release qualification, or proof of buyer-path throughput.
set -euo pipefail
umask 077

[ "$#" = 1 ] && [ "$1" = --offline ] ||
  { [ "$#" = 3 ] && [ "$1" = --offline ] && [ "$2" = --manifest ]; } || {
  echo "usage: run-window-diagnostic.sh --offline [--manifest PATH]" >&2
  exit 2
}
[ "$(uname -s)" = Darwin ] && [ "$(sysctl -n hw.model)" = Mac15,14 ] || {
  echo "diagnostic requires the designated Mac Studio" >&2
  exit 3
}

if [ "$#" = 3 ]; then
  script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
  helper="$script_dir/manifest.py"
  [ -f "$helper" ] && [ ! -L "$helper" ] || {
    echo "fixed Studio job helper is missing" >&2
    exit 3
  }
  exec /usr/bin/python3 "$helper" run-job --manifest "$3"
fi

# The reviewed supervisor supplies a clean, hash-bound source directory as
# cwd. Neither the command nor its flags come from operator shell snippets.
source_dir="$(pwd -P)"
fixture="$source_dir/.lab-window/fixture"
provider="$source_dir/phase3-binary/.build/release/macprovider-cli"
bench="$source_dir/scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench"
[ -x "$provider" ] && [ -x "$bench" ] && [ -d "$fixture/target" ] || {
  echo "prepare both release lab binaries and the embedded-MTP target fixture before the window" >&2
  exit 3
}
[ -d "$source_dir/.lab-window" ] && [ ! -L "$source_dir/.lab-window" ] || exit 3
result_dir="$(mktemp -d "$source_dir/.lab-window/result-XXXXXX")"
printf 'diagnostic_results=%s\n' "$result_dir"

# NativeMTPJourneyE2E is an in-process model harness with no coordinator
# connection. Never replace this command with `serve` in a live window.
MACPROVIDER_NATIVE_MTP_E2E=1 MACPROVIDER_CB_TRACE=1 \
  nice -n 19 "$provider" native-mtp-journey-e2e \
    --root "$fixture" --model-id zai-org/glm-5.3-flash \
    --qualified-slots 4 --max-native-active-rows 4 --max-prompt-tokens 4096 \
    > "$result_dir/journey.json" 2> "$result_dir/journey.log"

# Only run the component diagnostic after the full-bound correctness command
# exits successfully. One repetition checks the profiling path, not a gain.
nice -n 19 "$bench" "$fixture/target" \
  --mtp-multirow-profile --mtp-multirow-reps 1 \
  > "$result_dir/component-profile.log" 2>&1
printf 'diagnostic_completed=true qualification=false\n'
