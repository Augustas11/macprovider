#!/usr/bin/env bash
# #1269: a fresh Mac's first paid-yield benchmark can run cold or thermally
# throttled and transiently report "no paid model", stranding a capable Mac in
# donor mode. run_autotune_recommend_apply must re-benchmark a bounded number of
# times before falling back to donor, so a transient miss does not strand.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract only the function under test; every dependency is stubbed below so the
# retry-loop control flow is exercised in isolation.
python3 - "$INSTALL_SH" > "$TMP/fn.sh" <<'PY'
import sys
names = {"run_autotune_recommend_apply"}
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
i = 0
while i < len(lines):
    name = lines[i].split("()", 1)[0] if "()" in lines[i] else ""
    if name not in names:
        i += 1
        continue
    depth = 0
    while i < len(lines):
        line = lines[i]
        print(line)
        depth += line.count("{") - line.count("}")
        i += 1
        if depth == 0:
            break
PY

# run_case <reveal_at> <max_attempts> <donor_answer>
#   reveal_at    : attempt number at which the paid model first "clears"
#                  (a huge value means it never clears)
#   max_attempts : MACPROVIDER_RECOMMEND_MAX_ATTEMPTS
#   donor_answer : yes|no answer to the "Enable donor mode?" prompt
# echoes: "<rc>|<paid_recommend_calls>|<donor_recommend_calls>|<creds>|<skip>"
run_case() {
  local reveal_at="$1" max_attempts="$2" donor_answer="$3"
  local root="$TMP/case-$reveal_at-$max_attempts-$donor_answer"
  mkdir -p "$root"
  : > "$root/macprovider-cli"; chmod +x "$root/macprovider-cli"
  : > "$root/paid_calls"; : > "$root/donor_calls"; : > "$root/creds"

  (
    set +e
    export REVEAL_AT="$reveal_at" DONOR_ANSWER="$donor_answer" ROOT="$root"
    export MACPROVIDER_RECOMMEND_MAX_ATTEMPTS="$max_attempts"
    export MACPROVIDER_RECOMMEND_RETRY_SLEEP_SECONDS=0

    DRY_RUN=0
    INSTALL_DIR="$root"
    MACPROVIDER_CLI_EXECUTABLE="$root/macprovider-cli"
    CONFIG_PATH="$root/config.yaml"
    AUTOTUNE_BENCHMARK_PORT=19080
    SKIP_PROVIDER_START=0
    # App/non-interactive mode + donor opt-in are controlled per-case via NP/HL/DM.
    NO_PROMPT="${NP:-0}"; HEADLESS="${HL:-0}"; MACPROVIDER_DONOR_MODE="${DM:-0}"
    model=""; recommended_model=""; artifact_path=""; artifact_sha=""

    log() { :; }
    die() { echo "DIE:$*" >&2; exit "${1:-1}"; }
    sleep() { :; }
    submit_required_hardware_evidence() { :; }
    ensure_provider_credentials() { echo x >> "$ROOT/creds"; }
    enforce_headless_config_overrides() { :; }

    # Count paid vs donor recommendation invocations.
    run_macprovider_cli_with_amfi_retry() {
      case " $* " in
        *" --donor-mode "*) echo x >> "$ROOT/donor_calls" ;;
        *" --recommend --apply "*) echo x >> "$ROOT/paid_calls" ;;
      esac
      return 0
    }
    # A paid model "clears" only once enough paid attempts have run. The donor
    # recommendation (which sets --donor-mode) always clears a local model.
    _paid_attempts() { wc -l < "$ROOT/paid_calls" | tr -d ' '; }
    _donor_done() { [ -s "$ROOT/donor_calls" ]; }
    read_config_model() {
      if _donor_done || [ "$(_paid_attempts)" -ge "$REVEAL_AT" ]; then
        echo "meta-llama/llama-3.2-3b-instruct"
      fi
    }
    read_config_artifact_path() {
      if _donor_done || [ "$(_paid_attempts)" -ge "$REVEAL_AT" ]; then
        echo "/models/llama-3.2-3b/model.safetensors"
      fi
    }
    read_config_artifact_sha() {
      if _donor_done || [ "$(_paid_attempts)" -ge "$REVEAL_AT" ]; then
        echo "deadbeef"
      fi
    }
    # "Start provider now?" -> yes; "Enable donor mode?" -> per DONOR_ANSWER.
    prompt_yes_no() {
      case "$1" in
        *"donor mode"*) [ "$DONOR_ANSWER" = "yes" ] && return 0 || return 1 ;;
        *) return 0 ;;
      esac
    }

    # shellcheck disable=SC1090
    . "$TMP/fn.sh"
    run_autotune_recommend_apply
    rc=$?
    echo "$rc|$(wc -l < "$ROOT/paid_calls" | tr -d ' ')|$(wc -l < "$ROOT/donor_calls" | tr -d ' ')|$([ -s "$ROOT/creds" ] && echo 1 || echo 0)|$SKIP_PROVIDER_START"
  )
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Case 1: transient miss on attempt 1, clears on attempt 2 -----------------
out="$(run_case 2 3 no)"
[ "$out" = "0|2|0|1|0" ] \
  || fail "transient-then-clear expected rc0, 2 paid recs, 0 donor, creds, no-skip; got [$out]"
echo "ok: transient miss re-benchmarks and starts the paid provider (no donor strand)"

# --- Case 2: never clears within attempts, donor accepted ---------------------
out="$(run_case 99 3 yes)"
[ "$out" = "0|3|1|0|1" ] \
  || fail "never-clear+donor expected rc0, 3 paid recs, 1 donor rec, no creds, skip; got [$out]"
echo "ok: exhausts $((3)) attempts then falls back to donor when accepted"

# --- Case 3: never clears, donor declined ------------------------------------
out="$(run_case 99 2 no)"
[ "$out" = "0|2|0|0|1" ] \
  || fail "never-clear+decline expected rc0, 2 paid recs, 0 donor, no creds, skip; got [$out]"
echo "ok: exhausts attempts then leaves service unstarted when donor declined"

# --- Case 4: non-integer MACPROVIDER_RECOMMEND_MAX_ATTEMPTS must not dead-end --
# A bogus override must fall back to the default (3), so a transient miss still
# re-benchmarks and clears on attempt 2 rather than stranding after one attempt.
out="$(run_case 2 abc no)"
[ "$out" = "0|2|0|1|0" ] \
  || fail "non-integer max-attempts expected clamp-to-default retry (rc0, 2 paid recs, creds, no-skip); got [$out]"
echo "ok: non-integer max-attempts override is sanitized and still retries"

# --- Case 5 (#1289): app/non-interactive mode + no paid model must FAIL LOUD ---
# It must NOT silently SKIP (commit-without-start). Expect die 30, and crucially
# NO donor recommendation was run and SKIP was never set.
set +e
out="$(NP=1 HL=0 run_case 99 2 no)"; rc=$?
set -euo pipefail
[ "$rc" = "30" ] \
  || fail "app-mode no-paid expected die 30 (fail loud); got rc=$rc out=[$out]"
echo "ok: app/non-interactive no-paid FAILS LOUD (die 30), never silent commit-without-start"

# Case 5b: headless non-interactive is ALSO fail-loud (no silent idle).
set +e
out="$(NP=1 HL=1 run_case 99 2 no)"; rc=$?
set -euo pipefail
[ "$rc" = "30" ] || fail "headless no-paid expected die 30; got rc=$rc out=[$out]"
echo "ok: headless non-interactive no-paid also fails loud (die 30)"

# --- Case 6 (#1289): explicit MACPROVIDER_DONOR_MODE=1 opts into donor, no prompt ---
out="$(NP=1 HL=0 DM=1 run_case 99 2 no)"
[ "$out" = "0|2|1|0|1" ] \
  || fail "explicit donor opt-in expected rc0, 2 paid recs, 1 donor rec, no creds, skip; got [$out]"
echo "ok: MACPROVIDER_DONOR_MODE=1 opts into donor without a prompt (no die)"

echo "PASS: install_recommend_retry"
