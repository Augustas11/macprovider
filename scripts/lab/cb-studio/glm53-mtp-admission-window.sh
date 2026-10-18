#!/bin/zsh
# GLM-5.3-Flash native-MTP admission inputs on the CLI 1.8.256 runtime
# (epic #2029). Lab only. Two legs, each one isolated in-process lab run
# (no coordinator, no network, no serve port) on an APFS clone of the
# served artifact:
#
#   glm53-mtp-admission-window.sh bank   step 12 only (`native-mtp-journey-e2e
#        --selftest-only`), one model load, one step per candidate challenge
#        text. Prints, per candidate, the provider-local checks and the
#        on-device self-check speedup estimate. The release bank takes the
#        first candidate whose checks all pass and whose estimate is at least
#        BANK_MIN_SPEEDUP (1.20, over the provider's 1.15x bar; window 1
#        measured 1.237 for the counting text).
#   glm53-mtp-admission-window.sh r015   the SPEC-048-R015 matrix and the
#        1800 s sustained window under the frozen policy
#        docs/research/spec048-r015/glm53-flash-r015-v2/policy.json (the
#        1.8.256 policy failed on the gated-cell prefill schedule and the
#        4096 TTFT order effect; see that directory's PREREGISTRATION.md): one
#        `native-mtp-bench` process per matrix cell and one for the sustained
#        window (R015_STEPS); each checks layout, identities, policy and
#        environment before its load (`--validate-only` runs exactly those
#        checks outside a window). Runs
#        alone, without the bank leg. R015_FROM=<n> resumes at step n; an
#        interrupted sustained window is rerun whole (SPEC-048-R015).
#   glm53-mtp-admission-window.sh run    bank, then r015.
#
# Both legs need the GPU and all of unified memory: run them only inside an
# announced Studio window with the buyer runner stopped, the live provider
# paused, drained to 0 in flight and booted out, and an independent watchdog
# armed. The script refuses to start, and each R015 step refuses to start,
# while anything listens on :8080, a `macprovider-cli serve` process runs, or
# the live provider's LaunchAgent is loaded; one window runs at a time (a lock
# directory). Pausing and restoring the live provider is the window owner's
# job.
#
# Binary: the bank leg ran a lab-harness release build of the v1.8.256 tag
# source with this branch's lab-only journey overlay. The r015 leg runs a
# lab-harness release build of this branch at PROVIDER_COMMIT. Both carry the
# signed 1.8.256 mlx.metallib (3d9b4a74...), never a lab-built metallib: the
# canary compares exact tokens, counters and committed state.
#
# Env: HARNESS (dir holding macprovider-cli + mlx.metallib), MODEL (served
# artifact dir), OUT, POLICY, BANK_MIN_SPEEDUP (1.20), BANK_TIMEOUT_S (1800),
# R015_STEP_TIMEOUT_S (3600), R015_FROM (1). The r015 leg refuses a harness
# whose macprovider-cli is not R015_HARNESS_SHA256, the build of
# PROVIDER_COMMIT named in the preregistration.
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
# The bench records `xcrun swift --version` and `xcodebuild -version`; the
# frozen policy names the Command Line Tools toolchain, so no Xcode override.
unset DEVELOPER_DIR
HARNESS=${HARNESS:-$HOME/lab-glm53-r015v2/src/phase3-binary/.build-lab-harness/release}
MODEL=${MODEL:-"$HOME/Library/Application Support/macprovider/models/Jundot--GLM-5.3-Flash-oQ4e-mtp/36defc5042d92a992a7948e83d6f110b8df69329/7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9"}
OUT=${OUT:-$HOME/lab-glm53-r015v2/window-$(date -u +%Y%m%dT%H%M%SZ)}
POLICY=${POLICY:-$HOME/lab-glm53-r015v2/policy.json}
LIVE_PORT=8080
LIVE_LABEL=live.malibu.provider
LOCK=$HOME/.glm53-mtp-admission-window.lock
MODEL_ID=zai-org/glm-5.3-flash
RELEASE_METALLIB_SHA256=3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b
POLICY_SHA256=5ca7e3b34a7eec5163a136782d85551cd57f6da0da0b02c808355ba02a67cfab
PROVIDER_COMMIT=916faf3b7faedc815d864987a185c1464e5c4962
R015_HARNESS_SHA256=pending
CHALLENGE_ID=native-mtp-selftest-glm53-flash-0001
# Candidate challenge texts, in preference order. The first is the text the
# journey has always used (GLM: acceptance 19/43, about 1.0x at 07301b6bf).
CANDIDATES=(
  "native_mtp_selftest_v1 synthetic challenge: continue the sequence alpha beta gamma delta"
  "native_mtp_selftest_v1 synthetic challenge: count upward by one. 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,"
  "native_mtp_selftest_v1 synthetic challenge: repeat the line exactly. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog."
  'native_mtp_selftest_v1 synthetic challenge: complete the code.'$'\n''def fibonacci(n):'$'\n''    if n < 2:'$'\n''        return n'$'\n''    return'
)

# Refuses while the live provider could share the GPU: a listener on its
# port (any response or none), a serve process, or its LaunchAgent loaded.
live_absent() {
  if lsof -nP -iTCP:$LIVE_PORT -sTCP:LISTEN > /dev/null 2>&1; then
    echo "refusing: something listens on :$LIVE_PORT" >&2; return 3
  fi
  if pgrep -f "macprovider-cli serve" > /dev/null 2>&1; then
    echo "refusing: a macprovider-cli serve process runs" >&2; return 3
  fi
  if launchctl print gui/$(id -u)/$LIVE_LABEL > /dev/null 2>&1; then
    echo "refusing: $LIVE_LABEL is loaded" >&2; return 3
  fi
}

preflight() {
  live_absent || exit 3
  mkdir $LOCK 2> /dev/null || { echo "refusing: another window holds $LOCK" >&2; exit 3; }
  LOCKED=1
  [[ -x $HARNESS/macprovider-cli && -f $HARNESS/mlx.metallib ]] || { echo "no harness at $HARNESS" >&2; exit 3; }
  [[ $(shasum -a 256 $HARNESS/mlx.metallib | cut -d' ' -f1) == $RELEASE_METALLIB_SHA256 ]] ||
    { echo "refusing: $HARNESS/mlx.metallib is not the signed 1.8.256 metallib" >&2; exit 3; }
  mkdir -p $OUT
  shasum -a 256 $HARNESS/macprovider-cli $HARNESS/mlx.metallib | tee $OUT/identity.sha256
}

# Runs "$@" with stdout to $3 and stderr to $4, killed after $1 seconds; on a
# timeout the stacks are sampled first so a hang leaves its diagnosis.
run_bounded() {
  local limit=$1 label=$2 out=$3 err=$4; shift 4
  "$@" > $out 2> $err &
  local pid=$! t0=$(date +%s)
  while kill -0 $pid 2>/dev/null; do
    if (( $(date +%s) - t0 >= limit )); then
      echo "$label TIMEOUT after ${limit}s; sampling pid $pid" | tee -a $OUT/summary.txt
      /usr/bin/sample $pid 5 -file $OUT/$label-sample.txt > /dev/null 2>&1 || true
      kill -TERM $pid 2>/dev/null; sleep 5; kill -KILL $pid 2>/dev/null || true
      wait $pid 2>/dev/null || true
      return 124
    fi
    sleep 5
  done
  wait $pid
}

fixture() {
  local root=$OUT/$1
  mkdir -p $root
  [[ -d $root/target ]] || cp -cR "$MODEL" $root/target
  echo $root
}

bank() {
  echo "bank start $(date -u +%FT%TZ)" | tee -a $OUT/summary.txt
  rm -f $OUT/bank-journey.json $OUT/bank-entry.json
  local root=$(fixture bank-fixture) rc=0
  local args=()
  for text in "${CANDIDATES[@]}"; do args+=(--selftest-prompt "$text"); done
  run_bounded ${BANK_TIMEOUT_S:-1800} bank $OUT/bank-journey.json $OUT/bank-journey.log \
    env MACPROVIDER_NATIVE_MTP_E2E=1 \
    $HARNESS/macprovider-cli native-mtp-journey-e2e --root $root --model-id $MODEL_ID \
    --qualified-slots 4 --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --selftest-only --selftest-challenge-id $CHALLENGE_ID "${args[@]}" || rc=$?
  echo "bank native-mtp-journey-e2e rc=$rc end $(date -u +%FT%TZ)" | tee -a $OUT/summary.txt
  local verdict=0
  python3 - $OUT/bank-journey.json ${BANK_MIN_SPEEDUP:-1.20} $OUT/bank-entry.json > $OUT/bank-verdict.txt 2>&1 <<'PY' || verdict=$?
import json, sys
text = open(sys.argv[1]).read()
if "{" not in text:
    sys.exit("bank: no result document (see bank-journey.log)")
doc, floor, chosen = json.loads(text[text.index("{"):]), float(sys.argv[2]), None
for step in doc["steps"]:
    d = step["details"]; est = d.get("on_device_selfcheck_estimate", {})
    ok = all(v is True for v in step["checks"].values()) and "challenge_bank_entry" in d
    c = d.get("challenge_bank_entry", {}).get("expected_counters", {})
    print(f"bank candidate={d.get('selftest_prompt_index')} checks_ok={ok} speedup={est.get('speedup', 0):.3f} "
          f"accepted={c.get('accepted')} rejected={c.get('rejected')}")
    if chosen is None and ok and est.get("speedup", 0) >= floor:
        chosen = d
if chosen is None:
    sys.exit(f"bank FAIL: no candidate passes its checks at speedup >= {floor}")
json.dump(chosen["challenge_bank_entry"], open(sys.argv[3], "w"), sort_keys=True, separators=(",", ":"))
print(f"bank PASS: candidate {chosen['selftest_prompt_index']} -> {sys.argv[3]}")
PY
  tee -a $OUT/summary.txt < $OUT/bank-verdict.txt
  rm -rf $root/target
  if (( rc != 0 || verdict != 0 )); then
    rm -f $OUT/bank-entry.json
    echo "bank FAIL (journey rc=$rc, verdict rc=$verdict)" | tee -a $OUT/summary.txt
    return 1
  fi
}

# One bench process per step: each loads GLM once and exits, so a cell never
# starts while the previous cell's target is still resident (two copies do
# not fit). The sustained window is its own process after its cell's matrix.
R015_STEPS=(
  "--only-cell s1-p1536-o128 --phase matrix"
  "--only-cell s1-p1536-o512 --phase matrix"
  "--only-cell s1-p4096-o128 --phase matrix"
  "--only-cell s1-p4096-o512 --phase matrix"
  "--only-cell s2-p1536-o512 --phase matrix"
  "--only-cell s4-p1536-o512 --phase matrix"
  "--phase sustained"
)

r015() {
  [[ $(shasum -a 256 $POLICY | cut -d' ' -f1) == $POLICY_SHA256 ]] ||
    { echo "refusing: $POLICY is not the frozen GLM R015 policy" >&2; exit 3; }
  [[ $(shasum -a 256 $HARNESS/macprovider-cli | cut -d' ' -f1) == $R015_HARNESS_SHA256 ]] ||
    { echo "refusing: $HARNESS/macprovider-cli is not the preregistered build of $PROVIDER_COMMIT" >&2; exit 3; }
  echo "r015 start $(date -u +%FT%TZ)" | tee -a $OUT/summary.txt
  # The fixture is target/ only: the GLM next-N layer is embedded in it.
  local root=$(fixture r015-fixture) rc=0 step=0
  local bench=(env MACPROVIDER_NATIVE_MTP_E2E=1 $HARNESS/macprovider-cli native-mtp-bench --root $root
    --model-id $MODEL_ID --policy $POLICY --out $OUT/r015-glm53.jsonl --provider-commit $PROVIDER_COMMIT)
  # R015_FROM (1-based) resumes at a later step after a partial run; a matrix
  # step resumes its own completed blocks, a partial sustained window must be
  # moved aside first (the bench refuses to resume it).
  for args in "${(@)R015_STEPS[${R015_FROM:-1},-1]}"; do
    step=$((step + 1))
    live_absent || { rc=3; break; }
    echo "r015 step '$args' start $(date -u +%FT%TZ)" | tee -a $OUT/summary.txt
    run_bounded ${R015_STEP_TIMEOUT_S:-3600} r015-$step $OUT/r015-$step.stdout $OUT/r015-$step.log \
      $bench ${=args} || rc=$?
    echo "r015 step '$args' rc=$rc end $(date -u +%FT%TZ) lines=$(wc -l < $OUT/r015-glm53.jsonl)" | tee -a $OUT/summary.txt
    (( rc == 0 )) || break
  done
  shasum -a 256 $OUT/r015-glm53.jsonl | tee -a $OUT/summary.txt || true
  (( rc == 0 )) && rm -rf $root/target
  return $rc
}

# Top level: a zsh EXIT trap set inside a function fires when it returns.
LOCKED=
trap '[[ -n $LOCKED ]] && rmdir $LOCK 2> /dev/null' EXIT

case ${1:-} in
  bank) preflight; bank ;;
  r015) preflight; r015 ;;
  # A failed bank leg does not stop `run`: R015 still uses the window.
  run) preflight; bank || echo "run: continuing to r015 after the bank failure" | tee -a $OUT/summary.txt; r015 ;;
  *) echo "usage: $0 bank|r015|run" >&2; exit 2 ;;
esac
