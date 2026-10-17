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
#        Paged attach for glm5_next is open in every build since SPEC-039
#        v0.1.20 recorded its evidence; the lab serve needs no attach override.
#        The serve runs `--no-join --no-idle-prewarm` WITHOUT
#        `--autotune-candidate`: an autotune child skips the served-slots plan
#        (MacProviderCLI `if !autotuneCandidate, ...` before AutoServedSlots),
#        so the FR-CB10 self-check driver would never start (also recorded in
#        1971-selfcheck/studio-selfcheck-validation.sh).
#     3. msb-throughput, paged engine, rows 1, 2 and 4 at block 256.
#     4. (`run-leftovers`, not in the default legs) SPEC-039 FR-PKV12
#        replay and drain record for this identity: msb-throughput
#        `--engine scheduler --scenario leftovers --rows 4 --prompt-tokens 1024
#        --parity-tokens 48`, the harness the gpt-oss-120b entry used. PASS:
#        isolation, replay, drain and parity all `pass=true`.
#     5. (`run-mtp-e2e`, not in the default legs) SPEC-048 native MTP through
#        the provider's real path: `native-mtp-hardware-e2e` (lab-signed
#        sidecar; serve-path admission loader unless MTP_E2E_SERVE_PATH=0)
#        on a fixture root whose `target/` is an APFS clone of MODEL,
#        4 slots, depth 1, packed verify in continuous batching. Greedy
#        native rows must equal ordinary rows, every row admitted native,
#        paged KV attached, batch depth >= 2; then the lab throughput phase
#        (`--throughput-tokens`, default 256) at 1 and 4 rows reports native
#        over ordinary end-to-end tok/s and acceptance. Not the R015 matrix.
#        Legs 5 and 6 run with MACPROVIDER_CB_TRACE=1 and their own time
#        limits (MTP_E2E_TIMEOUT_S 900, MTP_JOURNEY_TIMEOUT_S 1200); on a
#        timeout the process's stacks are sampled to <leg>-sample.txt before
#        it is killed, so a hang cannot take the window and leaves evidence.
#     6. (`run-mtp-journey`, not in the default legs) the hidden
#        JOURNEY-NATIVE-MTP-SERVING hardware steps (`native-mtp-journey-e2e`:
#        04 serial oracle, 05 cache/state boundary at the 256-token block,
#        06 streaming/stop, 07/08 mixed rows and capacity, 09 cancellation,
#        10 warm swap, 12 provider self-test) on the same cloned fixture,
#        at JOURNEY_SLOTS (4) slots, JOURNEY_NATIVE_ROWS (4) native rows and
#        a 4096-token prompt cap. Records executed_steps_status and each
#        step's status; PASS only when the harness exits 0 (no executed step
#        failed). The result is lab evidence, never a journey verdict.
#   It never binds or signals the live port; pausing the live provider is the
#   window owner's job, and `run` refuses to start while it serves.
#
# Env: POC (lab copy), MODEL (artifact dir), OUT, LAB_CONFIG_TEMPLATE (an
# isolated no-join lab config: credential_store: protected_file, no
# draft_model; CB-accepted for the GLM artifact's tuple), LIVE_PORT (8080),
# LEGS (default "1 2 3"; any subset of 1..6 selects legs for `run`, e.g.
# LEGS="1 2"; `run-selfcheck` runs leg 2 only),
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

# Runs "$@" with stdout to $3 and stderr to $4, killed after $1 seconds.
# On timeout it first records every thread's stack (`sample`) to
# $OUT/$2-sample.txt, so a hang leaves its diagnosis, then exits 124.
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

# SPEC-039 FR-PKV12 replay/drain record: every leftovers scenario passed.
evaluate_leftovers() {
  python3 - $1 <<'PY'
import json, sys
text = open(sys.argv[1]).read()
decoder, docs, i = json.JSONDecoder(), [], 0
while True:
    while i < len(text) and text[i] not in "{[":
        i += 1
    if i >= len(text):
        break
    doc, i = decoder.raw_decode(text, i)
    docs.append(doc)
ok = bool(docs)
print(f"leg4 documents={len(docs)}")
for name in ("isolation", "replay", "drain", "parity"):
    found = [d["leftovers"][name] for d in docs
             if isinstance(d.get("leftovers"), dict) and isinstance(d["leftovers"].get(name), dict)]
    passed = len(found) == 1 and found[0].get("pass") is True
    print(f"leg4 {name} pass={passed}")
    ok = ok and passed
print("leg4 leftovers " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
}

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
  MACPROVIDER_PAGED_KV_ENABLED=1 \
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

  if [[ " $LEGS " == *" 4 "* ]]; then
  # --- Leg 4: scheduler leftovers (isolation, replay, drain, parity) ---------
  echo "leg4 leftovers start $(date -u +%T)" | tee -a $OUT/summary.txt
  # `--scenario leftovers` prints one JSON document per scenario
  # (isolation, replay, drain, parity) to stdout, each with its result under
  # `leftovers.<name>.pass`. The harness exit code is recorded on its own.
  local msb_rc=0
  $HARNESS/macprovider-cli msb-throughput --model $MODEL --engine scheduler --no-compile \
    --scenario leftovers --rows 4 --prompt-tokens 1024 --parity-tokens 48 --runs 1 --stdout-only \
    > $OUT/leftovers.json 2> $OUT/leftovers.log || msb_rc=$?
  echo "leg4 msb-throughput rc=$msb_rc" | tee -a $OUT/summary.txt
  local eval_rc=1
  if (( msb_rc == 0 )); then
    eval_rc=0
    evaluate_leftovers $OUT/leftovers.json > $OUT/leftovers-eval.txt 2>&1 || eval_rc=$?
    tee -a $OUT/summary.txt < $OUT/leftovers-eval.txt
  fi
  (( eval_rc == 0 )) || { result=FAIL; echo "leg4 leftovers FAIL (see leftovers.json / leftovers.log)" | tee -a $OUT/summary.txt; }
  shasum -a 256 $OUT/leftovers.json $OUT/leftovers.log | tee -a $OUT/summary.txt
  fi

  if [[ " $LEGS " == *" 5 "* ]]; then
  # --- Leg 5: native-MTP hardware e2e (glm5_next, depth 1, 4 slots) ---------
  echo "leg5 mtp-e2e start $(date -u +%T)" | tee -a $OUT/summary.txt
  local fixture=$OUT/mtp-fixture
  mkdir -p $fixture
  # APFS clone: the snapshot's exact files, no copy of the bytes.
  cp -cR $MODEL $fixture/target
  local e2e_rc=0
  run_bounded ${MTP_E2E_TIMEOUT_S:-900} leg5 $OUT/mtp-e2e.json $OUT/mtp-e2e.log \
    env MACPROVIDER_NATIVE_MTP_E2E=1 MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH=${MTP_E2E_SERVE_PATH:-1} MACPROVIDER_CB_TRACE=1 \
    $HARNESS/macprovider-cli native-mtp-hardware-e2e --root $fixture --model-id zai-org/glm-5.3-flash \
    --max-batch 4 --sizing-prompt-tokens 1024 --sizing-output-tokens ${MTP_E2E_TOKENS:-256} \
    --throughput-tokens ${MTP_E2E_TOKENS:-256} || e2e_rc=$?
  echo "leg5 native-mtp-hardware-e2e rc=$e2e_rc" | tee -a $OUT/summary.txt
  local mtp_eval_rc=1
  if (( e2e_rc == 0 )); then
    mtp_eval_rc=0
    python3 - $OUT/mtp-e2e.json > $OUT/mtp-e2e-eval.txt 2>&1 <<'PY' || mtp_eval_rc=$?
import json, sys
line = next(l for l in open(sys.argv[1]) if l.startswith("{"))
r = json.loads(line)
ok = r.get("status") == "pass" and r.get("model_family") == "glm5_next" \
    and r.get("family_adapter") == "glm5_next_mtp_v1" and int(r.get("max_observed_batch_depth", 0)) >= 2
print(f"leg5 status={r.get('status')} family={r.get('model_family')} serve_path_verified={r.get('serve_path_verified')} "
      f"admissions={r.get('admissions')} max_batch_depth={r.get('max_observed_batch_depth')} "
      f"parity_proposed={r.get('parity_proposed')} parity_accepted={r.get('parity_accepted')}")
cells = (r.get("lab_throughput") or {}).get("cells") or []
ok = ok and len(cells) == 2
for c in cells:
    print(f"leg5 rows={c['rows']} native_over_ordinary={c['native_over_ordinary_median']:.3f} "
          f"ordinary_e2e_tps={c['ordinary_e2e_tps_median']:.1f} native_e2e_tps={c['native_e2e_tps_median']:.1f} "
          f"acceptance={c['acceptance']:.3f} greedy_equal={c['greedy_equal']}")
    ok = ok and c["greedy_equal"] is True and c["proposed"] > 0
print("leg5 mtp-e2e " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
    tee -a $OUT/summary.txt < $OUT/mtp-e2e-eval.txt
  fi
  (( mtp_eval_rc == 0 )) || { result=FAIL; echo "leg5 mtp-e2e FAIL (see mtp-e2e.json / mtp-e2e.log)" | tee -a $OUT/summary.txt; }
  shasum -a 256 $OUT/mtp-e2e.json $OUT/mtp-e2e.log | tee -a $OUT/summary.txt
  # The lab-signed sidecar, bank and projection stay with the evidence; the
  # clone of the weights does not.
  rm -rf $fixture/target
  fi

  if [[ " $LEGS " == *" 6 "* ]]; then
  # --- Leg 6: JOURNEY-NATIVE-MTP-SERVING hardware steps (lab) ---------------
  echo "leg6 mtp-journey start $(date -u +%T)" | tee -a $OUT/summary.txt
  local jfixture=$OUT/mtp-journey-fixture
  mkdir -p $jfixture
  cp -cR $MODEL $jfixture/target
  local journey_rc=0
  run_bounded ${MTP_JOURNEY_TIMEOUT_S:-1200} leg6 $OUT/mtp-journey.json $OUT/mtp-journey.log \
    env MACPROVIDER_NATIVE_MTP_E2E=1 MACPROVIDER_CB_TRACE=1 \
    $HARNESS/macprovider-cli native-mtp-journey-e2e --root $jfixture --model-id zai-org/glm-5.3-flash \
    --qualified-slots ${JOURNEY_SLOTS:-4} --max-native-active-rows ${JOURNEY_NATIVE_ROWS:-4} \
    --max-prompt-tokens 4096 || journey_rc=$?
  echo "leg6 native-mtp-journey-e2e rc=$journey_rc" | tee -a $OUT/summary.txt
  python3 - $OUT/mtp-journey.json <<'PY' 2>&1 | tee -a $OUT/summary.txt || true
import json, sys
text = open(sys.argv[1]).read()
r = json.loads(text[text.index("{"):])
print(f"leg6 executed_steps_status={r.get('executed_steps_status')} journey_complete={r.get('journey_complete')}")
for step in r.get("steps", []):
    failed = sorted(k for k, v in step.get("checks", {}).items() if v is not True)
    print(f"leg6 {step['step_id']} status={step['status']} failed_checks={failed} uncovered={step.get('uncovered_contract')}")
PY
  (( journey_rc == 0 )) || { result=FAIL; echo "leg6 mtp-journey FAIL (see mtp-journey.json / mtp-journey.log)" | tee -a $OUT/summary.txt; }
  shasum -a 256 $OUT/mtp-journey.json $OUT/mtp-journey.log | tee -a $OUT/summary.txt
  rm -rf $jfixture/target
  fi

  echo "RESULT=$result evidence=$OUT" | tee -a $OUT/summary.txt
  [[ $result == PASS ]]
}

case ${1:-} in
  prepare) prepare ;;
  run) run ;;
  run-selfcheck) LEGS=2 run ;;
  run-leftovers) LEGS=4 run ;;
  run-mtp-e2e) LEGS=5 run ;;
  run-mtp-journey) LEGS=6 run ;;
  *) echo "usage: $0 prepare|run|run-selfcheck|run-leftovers|run-mtp-e2e|run-mtp-journey" >&2; exit 2 ;;
esac
