#!/usr/bin/env bash

# Submit an Apple notarization request and survive transient service throttling.
# If notarytool returns a submission ID before failing, retries poll that existing
# submission instead of uploading the same artifact again.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <artifact> [notarytool submit options]" >&2
  exit 2
fi

artifact="$1"
shift

max_attempts="${NOTARYTOOL_MAX_ATTEMPTS:-4}"
retry_delay_seconds="${NOTARYTOOL_RETRY_DELAY_SECONDS:-30}"
max_retry_delay_seconds=300

case "$max_attempts" in
  ''|*[!0-9]*|0)
    echo "NOTARYTOOL_MAX_ATTEMPTS must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "$max_attempts" -gt 6 ]; then
  echo "NOTARYTOOL_MAX_ATTEMPTS must not exceed 6" >&2
  exit 2
fi
case "$retry_delay_seconds" in
  ''|*[!0-9]*)
    echo "NOTARYTOOL_RETRY_DELAY_SECONDS must be a non-negative integer" >&2
    exit 2
    ;;
esac
if [ "$retry_delay_seconds" -gt "$max_retry_delay_seconds" ]; then
  echo "NOTARYTOOL_RETRY_DELAY_SECONDS must not exceed $max_retry_delay_seconds" >&2
  exit 2
fi

submit_args=("$@")
wait_args=()
for arg in "$@"; do
  if [ "$arg" != "--wait" ]; then
    wait_args+=("$arg")
  fi
done

attempt=1
submission_id=""
log_file=""

cleanup_log() {
  if [ -n "$log_file" ]; then
    rm -f "$log_file"
  fi
}
trap cleanup_log EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [ "$attempt" -le "$max_attempts" ]; do
  log_file="$(mktemp "${TMPDIR:-/tmp}/notarytool-submit.XXXXXX")"

  if [ -n "$submission_id" ]; then
    echo "Waiting for existing Apple notarization submission $submission_id (attempt $attempt/$max_attempts)..."
    if xcrun notarytool wait "$submission_id" "${wait_args[@]}" 2>&1 | tee "$log_file"; then
      rm -f "$log_file"
      exit 0
    else
      status="${PIPESTATUS[0]}"
    fi
  else
    echo "Submitting $artifact for Apple notarization (attempt $attempt/$max_attempts)..."
    if xcrun notarytool submit "$artifact" "${submit_args[@]}" 2>&1 | tee "$log_file"; then
      rm -f "$log_file"
      exit 0
    else
      status="${PIPESTATUS[0]}"
    fi

    submission_id="$(sed -nE 's/^[[:space:]]*id:[[:space:]]*([0-9A-Fa-f-]+)[[:space:]]*$/\1/p' "$log_file" | tail -1)"
  fi

  if ! grep -Eiq \
    'serviceUnavailable|503[[:space:]]+Slow Down|Code:[[:space:]]*SlowDown|Please reduce your request rate|temporarily unavailable|timed out|timeout|network connection was lost' \
    "$log_file"; then
    rm -f "$log_file"
    exit "$status"
  fi

  rm -f "$log_file"
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Apple notarization remained unavailable after $max_attempts attempts." >&2
    exit "$status"
  fi

  echo "::warning::Apple notarization service is temporarily unavailable; retrying in ${retry_delay_seconds}s."
  sleep "$retry_delay_seconds"
  attempt=$((attempt + 1))
  retry_delay_seconds=$((retry_delay_seconds * 2))
  if [ "$retry_delay_seconds" -gt "$max_retry_delay_seconds" ]; then
    retry_delay_seconds="$max_retry_delay_seconds"
  fi
done
