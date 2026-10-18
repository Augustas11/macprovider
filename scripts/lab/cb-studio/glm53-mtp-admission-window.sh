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
#        BANK_MIN_SPEEDUP (1.25: margin over the provider's 1.15x bar).
#   glm53-mtp-admission-window.sh r015   the SPEC-048-R015 matrix and the
#        1800 s sustained window (`native-mtp-bench --phase all`) under the
#        frozen policy docs/research/spec048-r015/glm53-flash-v1.8.256/policy.json.
#        The bench resumes a partial matrix from --out; an interrupted
#        sustained window is rerun whole (SPEC-048-R015).
#   glm53-mtp-admission-window.sh run    bank, then r015.
#
# Both legs need the GPU and all of unified memory: run them only inside an
# announced Studio window with the buyer runner stopped, the live provider
# paused, drained to 0 in flight and booted out, and an independent watchdog
# armed. The script refuses to start while :8080 answers. Pausing and
# restoring the live provider is the window owner's job.
#
# Binary: a lab-harness release build of the v1.8.256 tag source with the
# lab-only journey overlay (this branch's NativeMTPJourneyE2ECommand.swift),
# carrying the signed 1.8.256 mlx.metallib (3d9b4a74...), never a lab-built
# metallib: the canary compares exact tokens, counters and committed state.
#
# Env: HARNESS (dir holding macprovider-cli + mlx.metallib), MODEL (served
# artifact dir), OUT, POLICY, LIVE_PORT (8080), BANK_MIN_SPEEDUP (1.25),
# BANK_TIMEOUT_S (1800), R015_TIMEOUT_S (14400).
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
# The bench records `xcrun swift --version` and `xcodebuild -version`; the
# frozen policy names the Command Line Tools toolchain, so no Xcode override.
unset DEVELOPER_DIR
HARNESS=${HARNESS:-$HOME/lab-glm53-mtp/src/phase3-binary/.build-lab-harness/release}
MODEL=${MODEL:-"$HOME/Library/Application Support/macprovider/models/Jundot--GLM-5.3-Flash-oQ4e-mtp/36defc5042d92a992a7948e83d6f110b8df69329/7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9"}
OUT=${OUT:-$HOME/lab-glm53-mtp/window-$(date -u +%Y%m%dT%H%M%SZ)}
POLICY=${POLICY:-$HOME/lab-glm53-mtp/policy.json}
LIVE_PORT=${LIVE_PORT:-8080}
MODEL_ID=zai-org/glm-5.3-flash
RELEASE_METALLIB_SHA256=3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b
POLICY_SHA256=14741db03be1fc6ac4e1c9009b1747e6259f9c82881ac00ff12654692737904c
PROVIDER_COMMIT=2a575c453639938ff6dbbf905001b7ea893d650d
CHALLENGE_ID=native-mtp-selftest-glm53-flash-0001
# Candidate challenge texts, in preference order. The first is the text the
# journey has always used (GLM: acceptance 19/43, about 1.0x at 07301b6bf).
CANDIDATES=(
  "native_mtp_selftest_v1 synthetic challenge: continue the sequence alpha beta gamma delta"
  "native_mtp_selftest_v1 synthetic challenge: count upward by one. 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,"
  "native_mtp_selftest_v1 synthetic challenge: repeat the line exactly. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog."
  'native_mtp_selftest_v1 synthetic challenge: complete the code.'$'\n''def fibonacci(n):'$'\n''    if n < 2:'$'\n''        return n'$'\n''    return'
)

preflight() {
  if curl -fsS --max-time 3 "http://127.0.0.1:$LIVE_PORT/v1/status" > /dev/null 2>&1; then
    echo "refusing: the live provider answers on :$LIVE_PORT" >&2; exit 3
  fi
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
  local root=$(fixture bank-fixture) rc=0
  local args=()
  for text in "${CANDIDATES[@]}"; do args+=(--selftest-prompt "$text"); done
  run_bounded ${BANK_TIMEOUT_S:-1800} bank $OUT/bank-journey.json $OUT/bank-journey.log \
    env MACPROVIDER_NATIVE_MTP_E2E=1 \
    $HARNESS/macprovider-cli native-mtp-journey-e2e --root $root --model-id $MODEL_ID \
    --qualified-slots 4 --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --selftest-only --selftest-challenge-id $CHALLENGE_ID "${args[@]}" || rc=$?
  echo "bank native-mtp-journey-e2e rc=$rc end $(date -u +%FT%TZ)" | tee -a $OUT/summary.txt
  # A failed bank leg does not stop `run`: R015 still uses the window.
  { python3 - $OUT/bank-journey.json ${BANK_MIN_SPEEDUP:-1.25} $OUT/bank-entry.json <<'PY' 2>&1 || true; } | tee -a $OUT/summary.txt
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
  rm -rf $root/target
}

r015() {
  [[ $(shasum -a 256 $POLICY | cut -d' ' -f1) == $POLICY_SHA256 ]] ||
    { echo "refusing: $POLICY is not the frozen GLM R015 policy" >&2; exit 3; }
  echo "r015 start $(date -u +%FT%TZ)" | tee -a $OUT/summary.txt
  local root=$(fixture r015-fixture) rc=0
  run_bounded ${R015_TIMEOUT_S:-14400} r015 $OUT/r015-bench.stdout $OUT/r015-bench.log \
    env MACPROVIDER_NATIVE_MTP_E2E=1 \
    $HARNESS/macprovider-cli native-mtp-bench --root $root --model-id $MODEL_ID \
    --policy $POLICY --out $OUT/r015-glm53.jsonl --provider-commit $PROVIDER_COMMIT --phase all || rc=$?
  echo "r015 native-mtp-bench rc=$rc end $(date -u +%FT%TZ) records=$(wc -l < $OUT/r015-glm53.jsonl 2>/dev/null || echo 0)" |
    tee -a $OUT/summary.txt
  shasum -a 256 $OUT/r015-glm53.jsonl | tee -a $OUT/summary.txt || true
  (( rc == 0 )) && rm -rf $root/target
  return $rc
}

case ${1:-} in
  bank) preflight; bank ;;
  r015) preflight; r015 ;;
  run) preflight; bank; r015 ;;
  *) echo "usage: $0 bank|r015|run" >&2; exit 2 ;;
esac
