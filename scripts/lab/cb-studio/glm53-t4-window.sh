#!/bin/zsh
# GLM-5.3-Flash T4.4/T4.5 provider wiring window (epic #2029). Lab only.
#
#   glm53-t4-window.sh prepare   builds only; run any time outside a window
#                                (nice 10, nothing paused, no model load)
#   glm53-t4-window.sh run       run only inside an announced Studio window:
#                                buyer runner stopped, 0 in flight, the live
#                                provider paused. Three legs, one model load each:
#     1. AC-20 / FR-PKV4 fixture: GLM5NextPagedMLAParityTests through the
#        xctest host (paged MLA vs stock cache, 48 exact greedy tokens, gather
#        coverage, byte-equal pending window, attach probes).
#     2. FR-CB10 self-check ladder on an isolated no-join lab serve of the
#        lab-harness binary (lab-local config, CB `canary`, own self-check
#        store): the unequal-length exactness probe at k = 2, 3, 4 and the
#        SPEC-038 FR-CB10 gain rule, quoted: "the gain is the median
#        batch/serial ratio ... It grants the rung with the highest gain,
#        preferring the lowest k within 15% of it, only when that gain is at
#        least 1.2x". PASS: every k = 2..4 measured conformant (equal to its
#        lone run, or first differing only at the FR-CB10 near-tie: stock
#        serial top two within 1/1024 logit), verified_k >= 4, and decision
#        `granted` (some rung's median gain >= 1.2x).
#        Unsigned-tuple lab path: docs/runbooks/continuous-batching-enable-gate.md
#        documents no lab self-check procedure for an unsigned tuple, and the
#        signed GLM CB policy entry is T7 work bound to the final CLI CDHash.
#        So paged attach for glm5_next is opened only by the lab-harness gate
#        (`-DMACPROVIDER_LAB_HARNESS` build plus
#        MACPROVIDER_LAB_GLM5_NEXT_PAGED_ATTACH=1), the documented way here.
#        The serve runs `--no-join --no-idle-prewarm` WITHOUT
#        `--autotune-candidate`: an autotune child skips the served-slots plan
#        (MacProviderCLI `if !autotuneCandidate, ...` before AutoServedSlots),
#        so the FR-CB10 self-check driver would never start (also recorded in
#        1971-selfcheck/studio-selfcheck-validation.sh).
#     3. msb-throughput, paged engine, rows 1, 2 and 4 at block 256.
#   It never binds or signals the live port; pausing the live provider is the
#   window owner's job, and `run` refuses to start while it serves.
#
# Env: POC (lab copy), MODEL (artifact dir), OUT, LAB_CONFIG_TEMPLATE (an
# isolated no-join lab config: credential_store: protected_file, no
# draft_model; CB-accepted for the GLM artifact's tuple), LIVE_PORT (8080),
# LEGS (default "1 2 3"; `run-selfcheck` runs leg 2 only),
# LAB_PORT (18096), METALLIB (core v0.32.4-macprovider.4 kernels), XCTEST_HOST,
# LIVE_INSTALL_DIR (prepare: pin the lab serve binary to the live version).
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}
POC=${POC:-$HOME/lab-glm53/t3/poc}
PKG=$POC/phase3-binary
MODEL=${MODEL:-$HOME/lab-glm53/models/GLM-5.3-Flash-oQ4e-mtp}
METALLIB=${METALLIB:-$HOME/lab-glm53/t3/metallib-v4/mlx.metallib}
XCTEST_HOST=${XCTEST_HOST:-$HOME/lab-glm53/t3/xctest-host/run.sh}
LIVE_PORT=${LIVE_PORT:-8080}
LAB_PORT=${LAB_PORT:-18096}
HARNESS=$PKG/.build-lab-harness/release
LEGS=${LEGS:-1 2 3}
# The catalog snapshot-manifest hash of Jundot/GLM-5.3-Flash-oQ4e-mtp @
# 36defc50 (46 files); serve verifies it against the bytes at startup.
MODEL_ARTIFACT_SHA256=${MODEL_ARTIFACT_SHA256:-7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9}
TEST_BUNDLE=$PKG/.build/debug/phase3-binaryPackageTests.xctest

prepare() {
  # The test bundle (debug) for leg 1 and a lab-harness release binary for
  # legs 2 and 3. The harness define enables only lab overrides.
  (cd $PKG && nice -n 10 swift build --build-tests)
  # Serve refuses to start when the installed compatibility set names another
  # provider_cli version, so the lab serve binary carries the live version
  # (LIVE_INSTALL_DIR, as in 1971-selfcheck/build-lab-binaries.sh). Lab copy
  # only; the source is restored after the build.
  local src=$PKG/Sources/macprovider-cli/CoordinatorClient.swift
  if [[ -n ${LIVE_INSTALL_DIR:-} ]]; then
    local live_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["signed"]["components"]["provider_cli"]["version"])' \
      $LIVE_INSTALL_DIR/compatibility-set.json)
    cp $src $src.lab-orig
    trap "mv -f $src.lab-orig $src" EXIT
    sed -i '' "s/static let binaryVersion = \"[0-9.]*\"/static let binaryVersion = \"$live_version\"/" $src
    grep -q "static let binaryVersion = \"$live_version\"" $src || { echo "version pin failed" >&2; exit 3; }
  fi
  (cd $PKG && nice -n 10 swift build -c release --product macprovider-cli \
    --build-path .build-lab-harness -Xswiftc -DMACPROVIDER_LAB_HARNESS)
  if [[ -f $src.lab-orig ]]; then mv -f $src.lab-orig $src; trap - EXIT; fi
  cp $METALLIB $HARNESS/mlx.metallib
  $HARNESS/macprovider-cli --version
  shasum -a 256 $HARNESS/macprovider-cli $HARNESS/mlx.metallib
  echo "prepared: $TEST_BUNDLE and $HARNESS/macprovider-cli"
}

status_json() { curl -fsS --max-time 5 "http://127.0.0.1:$1/v1/status" 2>/dev/null; }

run() {
  : ${LAB_CONFIG_TEMPLATE:?LAB_CONFIG_TEMPLATE is required for the self-check leg}
  [[ $LAB_PORT != $LIVE_PORT ]] || { echo "LAB_PORT must differ from LIVE_PORT" >&2; exit 2; }
  [[ -d $TEST_BUNDLE && -x $HARNESS/macprovider-cli && -f $HARNESS/mlx.metallib ]] || {
    echo "run '$0 prepare' first" >&2; exit 2; }
  [[ -f $MODEL/config.json ]] || { echo "no artifact at $MODEL" >&2; exit 2; }
  grep -q '^credential_store: protected_file$' $LAB_CONFIG_TEMPLATE || {
    echo "template must set credential_store: protected_file (isolated no-join lab serve)" >&2; exit 2; }
  # The window owner pauses the live provider; refuse to measure beside it.
  if body=$(status_json $LIVE_PORT); then
    print -r -- $body | python3 -c 'import json,sys
d = json.load(sys.stdin)
paused = (d.get("lifecycle") or {}).get("operator_paused") is True
sys.exit(0 if paused and d.get("requests_in_flight", 1) == 0 else 1)' || {
      echo "live provider on :$LIVE_PORT is not paused with 0 in flight; not starting" >&2; exit 3; }
  fi
  OUT=${OUT:-$HOME/lab-glm53/t3/t4-window-$(date -u +%Y%m%dT%H%M%SZ)}
  mkdir -p $OUT
  shasum -a 256 $HARNESS/macprovider-cli $HARNESS/mlx.metallib | tee $OUT/identity.sha256
  local result=PASS
  echo "legs=$LEGS" | tee -a $OUT/summary.txt

  if [[ " $LEGS " == *" 1 "* ]]; then
  # --- Leg 1: AC-20 fixture -------------------------------------------------
  echo "leg1 fixture start $(date -u +%T)" | tee -a $OUT/summary.txt
  if MACPROVIDER_GLM53_ARTIFACT_DIR=$MODEL zsh $XCTEST_HOST \
      macprovider_cliTests.GLM5NextPagedMLAParityTests $TEST_BUNDLE > $OUT/leg1-fixture.log 2>&1 \
     && grep -q "Executed 1 test, with 0 failures" $OUT/leg1-fixture.log \
     && ! grep -q "skipped" $OUT/leg1-fixture.log; then
    echo "leg1 fixture PASS" | tee -a $OUT/summary.txt
  else
    result=FAIL; echo "leg1 fixture FAIL (see leg1-fixture.log)" | tee -a $OUT/summary.txt
  fi
  grep -E "\[AC-20" $OUT/leg1-fixture.log | tee -a $OUT/summary.txt || true
  fi

  if [[ " $LEGS " == *" 2 "* ]]; then
  # --- Leg 2: FR-CB10 self-check, k = 2..4 -----------------------------------
  echo "leg2 self-check start $(date -u +%T)" | tee -a $OUT/summary.txt
  local dir=$OUT/selfcheck; mkdir -p $dir; chmod 700 $dir
  python3 - $LAB_CONFIG_TEMPLATE $dir/config.yaml $LAB_PORT $MODEL $MODEL_ARTIFACT_SHA256 <<'PY'
import sys
src, dst, port, model, artifact_sha = sys.argv[1:]
# Every top-level key below is dropped with its indented block and then set
# (or left out) here, so nothing of the template's own model, catalog
# binding, accepted tuples or paged/native settings reaches the GLM serve.
# model_artifact_* (the template's Qwen model_artifact_sha256) is replaced:
# serve requires a hash with model_artifact_path and checks it against the
# bytes at startup, so the GLM catalog snapshot-manifest hash is written and
# that startup check is the on-disk proof of it. The directory must hold
# exactly the 46 snapshot files (no .cache/huggingface).
want = {"port": port, "model": "zai-org/glm-5.3-flash", "model_artifact_path": f'"{model}"',
        "model_artifact_sha256": artifact_sha,
        "max_context_override": "65536", "max_concurrency_override": "4",
        "continuous_batch_queue_limit": "4", "continuous_batching": "canary",
        "native_mtp_mode": "off"}
drop = set(want) | {"draft_model", "max_context_override_provenance", "continuous_batching_accepted_tuples",
                    "paged_kv", "native_mtp_admission"}
out, skipping = [], False
for line in open(src).read().splitlines():
    if line and not line[0].isspace() and ":" in line:
        key = line.split(":", 1)[0]
        skipping = key in drop or key.startswith("model_catalog_") or key.startswith("model_artifact_")
    elif not line.strip():
        skipping = False
    if not skipping:
        out.append(line)
out += [f"{k}: {v}" for k, v in want.items()]
open(dst, "w").write("\n".join(out) + "\n")
PY
  chmod 600 $dir/config.yaml
  MACPROVIDER_PAGED_KV_ENABLED=1 MACPROVIDER_LAB_GLM5_NEXT_PAGED_ATTACH=1 \
    $HARNESS/macprovider-cli serve --config $dir/config.yaml --port $LAB_PORT --no-join --no-idle-prewarm \
    > $dir/serve.log 2>&1 &
  local pid=$! t0=$(date +%s) decided=0
  trap "kill $pid 2>/dev/null || true" EXIT INT TERM HUP
  while kill -0 $pid 2>/dev/null && (( $(date +%s) - t0 < ${SELFCHECK_TIMEOUT_S:-3600} )); do
    sleep 10
    # Fail fast when the driver never starts (load plus first step).
    if (( $(date +%s) - t0 > ${SELFCHECK_START_TIMEOUT_S:-1800} )) \
       && ! grep -q 'event=cb_self_check action=step' $dir/serve.log; then
      echo "leg2: no self-check step within ${SELFCHECK_START_TIMEOUT_S:-1800}s" | tee -a $OUT/summary.txt
      break
    fi
    if body=$(status_json $LAB_PORT) && print -r -- $body | python3 -c 'import json,sys
s = ((json.load(sys.stdin).get("continuous_batching") or {}).get("self_check") or {})
d = str(s.get("decision"))
sys.exit(0 if d not in ("None", "pending") and not d.startswith("prior_grant") and "cb-probe" in str(s.get("runtime_build")) else 1)' 2>/dev/null; then
      print -r -- $body > $dir/status.json; decided=1; break
    fi
  done
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  trap - EXIT INT TERM HUP
  grep -E "event=(paged_kv|served_slots|cb_self_check|continuous_batching_policy|batching_unsupported|continuous_batch_decode_row_bound)|paged-kv|measure (nil|OK)" \
    $dir/serve.log > $dir/events.log || true
  # Did serve's startup check accept the artifact hash? (It hashes every
  # file of the directory before loading, at disk speed.)
  local hash_verdict=unknown
  if grep -q "model artifact hash mismatch" $dir/serve.log; then hash_verdict=rejected
  elif grep -q "requires model_artifact_sha256\|provider startup preflight failed" $dir/serve.log; then hash_verdict=preflight_failed
  elif grep -qE "event=served_slots|event=cb_self_check|paged-kv|model_loaded" $dir/serve.log; then hash_verdict=accepted
  fi
  echo "leg2 startup artifact hash ${hash_verdict} expected=$MODEL_ARTIFACT_SHA256 dir=$MODEL" | tee -a $OUT/summary.txt
  # Every ladder step and the applied decision, whatever the verdict below.
  grep -E "event=cb_self_check action=(step|measured|applied|ladder_ended|probe_shape_unmet)|batching_unsupported|model artifact hash" \
    $dir/serve.log | tee -a $OUT/summary.txt || true
  if (( decided )) && python3 - $dir/events.log $dir/status.json <<'PY' | tee -a $OUT/summary.txt
import json, re, sys
events, status = sys.argv[1:]
rows = {}
for line in open(events):
    if "action=measured" not in line:
        continue
    f = dict(re.findall(r"(\w+)=(\S+)", line))
    rows[int(f["slots"])] = (f["conformant"] == "true", float(f["gain"]), f["divergent_rows"])
s = json.load(open(status))["continuous_batching"]["self_check"]
ok = True
for k in (2, 3, 4):
    if k not in rows:
        print(f"leg2 k={k} not measured"); ok = False; continue
    conformant, gain, divergent = rows[k]
    print(f"leg2 k={k} conformant={conformant} median_gain={gain:.2f} at_least_1.2x={gain >= 1.2} divergent_rows={divergent}")
    ok = ok and conformant
best = max((g for _, g, _ in rows.values()), default=0.0)
print(f"leg2 decision={s.get('decision')} verified_k={s.get('verified_k')} served_slots={s.get('served_slots')} best_median_gain={best:.2f}")
# FR-CB10: granted only when the chosen rung's median gain is at least 1.2x.
ok = ok and int(s.get("verified_k") or 0) >= 4 and str(s.get("decision")) == "granted" \
    and int(s.get("served_slots") or 0) >= 2 and best >= 1.2
print("leg2 self-check " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
  then :; else result=FAIL; echo "leg2 self-check FAIL (see selfcheck/)" | tee -a $OUT/summary.txt; fi
  fi

  if [[ " $LEGS " == *" 3 "* ]]; then
  # --- Leg 3: msb-throughput at rows 1, 2, 4 ----------------------------------
  for rows in 1 2 4; do
    echo "leg3 msb rows=$rows start $(date -u +%T)" | tee -a $OUT/summary.txt
    if $HARNESS/macprovider-cli msb-throughput --model $MODEL --engine paged --no-compile \
        --rows $rows --block-size-tokens 256 --prompt-tokens 1024 --decode-tokens 128 --runs 3 \
        --output $OUT/msb-rows$rows.json > $OUT/msb-rows$rows.log 2>&1; then
      python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
keys = [k for k in d if "tps" in k.lower() or "speedup" in k.lower() or "parity" in k.lower()]
print("leg3 rows=" + sys.argv[2] + " " + " ".join(f"{k}={d[k]}" for k in keys))' $OUT/msb-rows$rows.json $rows | tee -a $OUT/summary.txt
    else
      result=FAIL; echo "leg3 msb rows=$rows FAIL (see msb-rows$rows.log)" | tee -a $OUT/summary.txt
    fi
  done
  fi

  echo "RESULT=$result evidence=$OUT" | tee -a $OUT/summary.txt
  [[ $result == PASS ]]
}

case ${1:-} in
  prepare) prepare ;;
  run) run ;;
  run-selfcheck) LEGS=2 run ;;
  *) echo "usage: $0 prepare|run|run-selfcheck" >&2; exit 2 ;;
esac
