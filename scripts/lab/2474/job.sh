#!/bin/bash
# Runs ON THE STUDIO, started detached by the #2474 window wrapper
# (scratchpad/windows/window-2474.sh on the operator Mac), which has already paused live, the
# runner's Studio target and the FLOP miner and holds the Studio GPU lock. This job never pauses,
# restores or restarts any of them; it refuses to start when anything still runs.
#
# #2474: GLM-5.3-Flash uncensored long-prompt TTFT gap to oMLX, after #2451 (PR 2457 + PR 2473).
# One window, one row, the production batching route, the #2451 grid (4k/16k = 3,673/14,126 prompt
# tokens, scripts/lab/parity-grid/grid.json):
#   base   = phase3-binary at COMMIT (origin/main: mlx-swift-lm 3.33.0-macprovider.89, 10584fc0);
#   fused  = the candidate (pass label kept from r1-r6): the same tree with mlx-swift-lm replaced
#            by SRC/mlx-swift-lm (FORK_COMMIT, one commit on .89; r7: macprovider/2474-last-rows-
#            logits-89, a sliced prefill projects only its last 64 rows to logits);
#   omlx   = oMLX 0.8.0rc1 @ c74f1b18 (the #2451 reference: MTP, DFlash off, --no-cache), driven by
#            parity-grid reference_omlx.py on the same grid prompts.
# Steps:
#  1. preflight: nothing on :8080/:8000, no live agent, no serve, no com.flop agent, no
#     Virtualization VM / limactl / mlx_service process; free disk >= MIN_FREE_GB; the shipped fork
#     tree is FORK_COMMIT and carries the fused path; the GLM snapshot is in the provider store;
#  2. oMLX at OMLX_DIR (default ~/lab-2474/omlx): reused when omlx-src is a git checkout at
#     OMLX_COMMIT and the venv imports; else installed (docs/runbooks/runtime-agnostic-m9-engines-
#     e2e-evidence-2026-09-25.md recipe: clone, python3.12 venv, pip install -e, uninstall
#     setproctitle). Versions must match the #2451 reference (mlx 0.32.4, mlx-lm g0d4d3d04f);
#  3. fork test: `swift test --filter "GLM5NextTests/($FORK_TESTS)"` in a copy of SRC/mlx-swift-lm
#     (full Xcode, metallib beside the test binary): the candidate's bitwise tests (every matching test in the file must pass), at GLM-5.3-Flash
#     expert shapes. A failure is recorded (FORK_TEST FAIL, JOB_FAIL at the end); the TTFT passes
#     still run so the window yields the oMLX gap;
#  4. release lab-harness builds: base on its pins (.build-lab-main), fused in its own copy with
#     `swift package edit mlx-swift-lm --path SRC/mlx-swift-lm` (.build-lab-fused); the base build's
#     resolved mlx-swift-lm must be FORK_BASE (the fork commit's parent);
#  5. the signed CB tuple of zai-org/glm-5.3-flash-uncensored (as the #2451 ship job);
#  6. run-grid passes, A/B/A then the reference: base-a, fused, base-b (each its own serve,
#     --skip-reference), then omlx (--reference-only over base-b's stored grid and rows);
#  7. wide_prefill_gate.py (control A base-a, candidate fused, control B base-b, reference omlx):
#     tokens of fused and base-b identical to base-a per cell, trial and row; TTFT medians; KEEP when
#     fused beats both controls in every cell;
#  8. lines (also in RES/verdict.md):
#       TTFT_ROW engine=<omlx|base|fused> pass=<base-a|fused|base-b|omlx> prompt_tokens=N out=M ttft_s=X n=K
#       GAP_ROW prompt_tokens=N out=M base_vs_omlx=+x% fused_vs_omlx=+x% fused_vs_base_a=x% fused_vs_base_b=x%
#       PARITY_ROW engine=fused vs=base-a prompt_tokens=N out=M identical=<true|false>
#       T2474_VERDICT fork_test=.. tokens=.. fused=KEEP|REVERT omlx=ok|missing
#     then JOB_PASS (every step ran, the oMLX rows exist, fork test passed, tokens identical) or JOB_FAIL.
# Knobs: CONTEXTS (4k,16k) OUTPUTS (128,512) TRIALS (3) MIN_FREE_GB (60) E2E_EXTRA_GB (40) LIVE_SET (~/macprovider/compatibility-set.json: the lab binaries take its provider_cli version)
#   SKIP_BUILD SKIP_FORK_TEST SKIP_OMLX GLM_PATH OMLX_DIR.
#   JOB_CHECK=1: validate the knobs, print the grid argvs and exit 0 before touching anything.
# Every failure prints `BLOCKER:`.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
LAB=${LAB:-$HOME/lab-2474}
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
COMMIT=${COMMIT:-unknown}
FORK_COMMIT=${FORK_COMMIT:?FORK_COMMIT unset}
FORK_BASE=${FORK_BASE:?FORK_BASE unset}
GRID=$SRC/scripts/lab/parity-grid
GATE=$SRC/scripts/lab/ablit-perf/wide_prefill_gate.py
PKG=$SRC/phase3-binary
FORK=$SRC/mlx-swift-lm
RES=$LAB/results/$RUN_ID
STORE="$HOME/Library/Application Support/macprovider/models"
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
GLM_ID=zai-org/glm-5.3-flash-uncensored
GLM_SHA256=242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919
GLM_NAME=glm53-flash-uncensored
GLM_PATH=${GLM_PATH:-}
CONTEXTS=${CONTEXTS:-4k,16k}
OUTPUTS=${OUTPUTS:-128,512}
TRIALS=${TRIALS:-3}
MIN_FREE_GB=${MIN_FREE_GB:-60}
E2E_EXTRA_GB=${E2E_EXTRA_GB:-40}
SKIP_OMLX=${SKIP_OMLX:-0}
SKIP_FORK_TEST=${SKIP_FORK_TEST:-0}
OMLX_DIR=${OMLX_DIR:-$LAB/omlx}
OMLX_REPO=https://github.com/jundot/omlx
OMLX_COMMIT=c74f1b18558842e6b10fcfa6e2e901bb382129d4
OMLX_PY=/opt/homebrew/bin/python3.12
# The candidate's fork tests (swift test --filter regex) and a symbol its source must contain.
FORK_TESTS=${FORK_TESTS:-testWidePrefillSlices|testPrefillLogitRows}
FORK_TEST_FILTER="GLM5NextTests/($FORK_TESTS)"
CAND_MARKER=${CAND_MARKER:-glm5NextPrefillLogitRows}
FORK_COPY=$LAB/fork-mlx-swift-lm
FORK_BUILD=$LAB/fork-mlx-swift-lm-build
# Swift tests need full Xcode (XCTest); the release builds keep the default toolchain.
TEST_DEV=${TEST_DEV:-$HOME/Applications/Xcode.app/Contents/Developer}
MAIN_BIN=$PKG/.build-lab-main/release
CAND_PKG=$LAB/cand-$RUN_ID/phase3-binary
CAND_BIN=$CAND_PKG/.build-lab-fused/release
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

case "$CONTEXTS" in ""|*[!A-Za-z0-9,]*) die "CONTEXTS=$CONTEXTS must be a comma list" 64 ;; esac
case "$OUTPUTS" in ""|*[!0-9,]*) die "OUTPUTS=$OUTPUTS must be a comma list of token counts" 64 ;; esac
case ",$OUTPUTS," in *,512,*) ;; *) die "OUTPUTS=$OUTPUTS must include 512 (the gate's cells)" 64 ;; esac
case "$TRIALS" in [1-9]) ;; *) die "TRIALS=$TRIALS must be 1..9" 64 ;; esac
case "$MIN_FREE_GB" in ""|*[!0-9]*) die "MIN_FREE_GB=$MIN_FREE_GB must be a number" 64 ;; esac
case "$E2E_EXTRA_GB" in ""|*[!0-9]*) die "E2E_EXTRA_GB=$E2E_EXTRA_GB must be a number" 64 ;; esac
case "$SKIP_OMLX" in 0|1) ;; *) die "SKIP_OMLX=$SKIP_OMLX must be 0 or 1" 64 ;; esac
case "$SKIP_FORK_TEST" in 0|1) ;; *) die "SKIP_FORK_TEST=$SKIP_FORK_TEST must be 0 or 1" 64 ;; esac
case "$OMLX_DIR" in *[[:space:]]*|"") die "OMLX_DIR must be set and contain no whitespace" 64 ;; esac
case "$FORK_COMMIT" in *[!0-9a-f]*|"") die "FORK_COMMIT=$FORK_COMMIT must be a commit id" 64 ;; esac
case "$FORK_BASE" in *[!0-9a-f]*|"") die "FORK_BASE=$FORK_BASE must be a commit id" 64 ;; esac

glm_dir() {  # GLM_PATH, else the provider-store snapshot of the catalog artifact (read only)
  [ -n "$GLM_PATH" ] && [ -f "$GLM_PATH/config.json" ] && { echo "$GLM_PATH"; return; }
  local d
  for d in "$STORE/Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2"/*/"$GLM_SHA256"; do
    [ -f "$d/config.json" ] && { echo "$d"; return; }
  done
  echo ""
}

# pass_args PASS: the run-grid argv of one pass (GARGS).
pass_args() {
  local out=$RES/e2e/$1
  GARGS=(--model-path "$GLM_MODEL" --model-name "$GLM_NAME" --out-dir "$out" --rows 1 --trials "$TRIALS")
  case $1 in
    omlx)
      # The stored base-b grid and rows: no --contexts/--outputs, so run-grid reuses OUT/grid.json.
      GARGS+=(--reference-only --python /usr/bin/python3 --reference omlx
              --ref-arg --omlx-dir --ref-arg "$OMLX_DIR" --ref-arg --state-root --ref-arg "$LAB/omlx-state"
              --ref-arg --expect-commit --ref-arg "$OMLX_COMMIT") ;;
    *)
      local bin=$MAIN_BIN
      [ "$1" = fused ] && bin=$CAND_BIN
      GARGS+=(--model-id "$GLM_ID" --model-sha256 "$GLM_SHA256" --bin-dir "$bin" --cb auto
              --config-extra "$RES/e2e/cb-tuple.yaml" --expect-route batched --no-autotune-candidate
              --contexts "$CONTEXTS" --outputs "$OUTPUTS" --skip-reference --skip-compare) ;;
  esac
}

PASSES=(base-a fused base-b)
[ "$SKIP_OMLX" = 1 ] || PASSES+=(omlx)
if [ "${JOB_CHECK:-0}" = 1 ]; then
  GLM_MODEL='<glm-dir>'
  printf 'FORK_TEST_ARGV DEVELOPER_DIR=%s swift test --build-system native --skip-build --scratch-path %s --filter %s\n' \
    "$TEST_DEV" "$FORK_BUILD" "$FORK_TEST_FILTER"
  for p in "${PASSES[@]}"; do
    pass_args "$p"
    printf 'GRID_ARGS_%s' "$p"; printf ' %s' "${GARGS[@]}"; echo
  done
  log "JOB_CHECK ok"
  exit 0
fi

mkdir -p "$RES/e2e"
log "JOB_START run=$RUN_ID commit=$COMMIT fork=$FORK_COMMIT fork_base=$FORK_BASE contexts=$CONTEXTS outputs=$OUTPUTS trials=$TRIALS skip_omlx=$SKIP_OMLX skip_fork_test=$SKIP_FORK_TEST"

# 1. Preflight.
listening 8080 && die "a server listens on :8080; the Studio is not paused" 3
listening 8000 && die "a server listens on :8000; the FLOP miner backend is not paused" 3
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
launchctl list 2>/dev/null | grep -q 'com\.flop\.' && die "a com.flop LaunchAgent is loaded (miner not paused)" 3
pgrep -f "[c]om.apple.Virtualization.VirtualMachine|[l]imactl|[m]lx_service" >/dev/null 2>&1 && die "a miner VM or backend process runs" 3
pgrep -f "[o]mlx serve" >/dev/null 2>&1 && die "an omlx serve process runs" 3
fg=$(free_gb)
log "DISK free_gb=$fg min=$MIN_FREE_GB"
[ "${fg:-0}" -ge "$MIN_FREE_GB" ] || die "only ${fg} GB free on the data volume; need $MIN_FREE_GB" 13
[ -f "$GATE" ] && [ -f "$GRID/run-grid.sh" ] && [ -f "$PKG/Package.swift" ] || die "source tree incomplete at $SRC" 11
grep -q "^commit=$FORK_COMMIT$" "$FORK/LAB_2474_FORK" 2>/dev/null \
  || die "the shipped mlx-swift-lm tree is not $FORK_COMMIT: $(tr '\n' ' ' < "$FORK/LAB_2474_FORK" 2>/dev/null)" 11
grep -q "$CAND_MARKER" "$FORK/Libraries/MLXLLM/Models/GLM5Next.swift" 2>/dev/null \
  || die "the shipped mlx-swift-lm tree has no candidate marker ($CAND_MARKER)" 11
grep -q "$FORK_BASE" "$PKG/Package.swift" || die "phase3-binary/Package.swift does not pin mlx-swift-lm $FORK_BASE" 11
[ -n "${MLX_GLM5_FUSED_GATE_UP:-}" ] && die "MLX_GLM5_FUSED_GATE_UP is set in the job environment" 11
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)
log "METALLIB sha256=$METALLIB_SHA"
GLM_MODEL=$(glm_dir)
[ -n "$GLM_MODEL" ] || die "no GLM-5.3-Flash snapshot $GLM_SHA256 in the provider store (or GLM_PATH)" 11
log "MODEL $GLM_ID path=$GLM_MODEL"
MODEL_GB=$(du -sg "$GLM_MODEL" | cut -f1)
need=$((MODEL_GB + E2E_EXTRA_GB))
[ "$fg" -ge "$need" ] || die "glm needs ${need} GB free (model ${MODEL_GB} GB plus ${E2E_EXTRA_GB} GB); ${fg} GB free" 13
[ "$SKIP_FORK_TEST" = 1 ] || [ -d "$TEST_DEV" ] || die "no Xcode developer dir at $TEST_DEV (TEST_DEV): the fork test cannot build" 14

# 2. oMLX, before any build: a reference that cannot be installed fails the window early.
omlx_versions() {
  "$OMLX_DIR/omlx-venv/bin/python" -I -c 'import importlib.metadata as m
for p in ("omlx", "mlx", "mlx-metal", "mlx-lm", "mlx-vlm", "transformers"):
    try: print(p, m.version(p))
    except m.PackageNotFoundError: print(p, "missing")' 2>/dev/null
}
if [ "$SKIP_OMLX" = 0 ]; then
  have=$(git -C "$OMLX_DIR/omlx-src" rev-parse HEAD 2>/dev/null)
  if [ "$have" = "$OMLX_COMMIT" ] && [ -x "$OMLX_DIR/omlx-venv/bin/omlx" ] && omlx_versions | grep -q '^omlx [0-9]'; then
    log "OMLX_REUSE $OMLX_DIR commit=$have"
  else
    [ -x "$OMLX_PY" ] || die "no $OMLX_PY for the oMLX venv" 11
    log "OMLX_INSTALL $OMLX_REPO@$OMLX_COMMIT -> $OMLX_DIR"
    rm -rf "$OMLX_DIR" && mkdir -p "$OMLX_DIR" || die "cannot create $OMLX_DIR" 11
    { git clone -q "$OMLX_REPO" "$OMLX_DIR/omlx-src" \
        && git -C "$OMLX_DIR/omlx-src" checkout -q --detach "$OMLX_COMMIT" \
        && "$OMLX_PY" -m venv "$OMLX_DIR/omlx-venv" \
        && "$OMLX_DIR/omlx-venv/bin/pip" install -q -e "$OMLX_DIR/omlx-src" \
        && "$OMLX_DIR/omlx-venv/bin/pip" uninstall -q -y setproctitle; } > "$RES/omlx-install.log" 2>&1 \
      || die "oMLX install failed: $(tail -n 3 "$RES/omlx-install.log" | tr '\n' ' ' | cut -c1-400)" 11
  fi
  vers=$(omlx_versions)
  log "OMLX_VERSIONS commit=$(git -C "$OMLX_DIR/omlx-src" rev-parse HEAD) $(echo "$vers" | tr '\n' ' ')"
  # The #2451 reference: oMLX 0.8.0rc1 @ c74f1b18, mlx 0.32.4, mlx-lm 0.32.3.dev8+g0d4d3d04f, mlx-vlm 0.7.11.
  echo "$vers" | grep -qx 'mlx 0.32.4' || die "oMLX venv mlx is not 0.32.4: not the #2451 reference" 11
  echo "$vers" | grep -q '^mlx-lm .*g0d4d3d04f' || die "oMLX venv mlx-lm is not g0d4d3d04f: not the #2451 reference" 11
fi

# 3. Fork test: fused against unfused, bitwise, on the Studio GPU.
FORK_TEST=skipped
if [ "$SKIP_FORK_TEST" = 0 ]; then
  rm -rf "$FORK_BUILD"
  rsync -a --delete --exclude '.build' --exclude '.swiftpm' "$FORK/" "$FORK_COPY/" > "$RES/fork-copy.log" 2>&1 \
    || die "mlx-swift-lm tree copy failed" 14
  log "BUILD_START fork-tests"
  if (cd "$FORK_COPY" && env DEVELOPER_DIR="$TEST_DEV" nice -n 10 swift build --build-tests --build-system native \
        --scratch-path "$FORK_BUILD") > "$RES/fork-tests-build.log" 2>&1; then
    fbundle=""
    for b in "$FORK_BUILD"/debug/*PackageTests.xctest "$FORK_BUILD"/debug/MLXLMTests.xctest; do
      [ -d "$b" ] && { fbundle=$b; break; }
    done
    [ -n "$fbundle" ] || die "no test bundle under $FORK_BUILD/debug" 14
    # MLX loads mlx.metallib from beside the test binary; without it no Metal test runs.
    { cp "$METALLIB" "$fbundle/Contents/MacOS/mlx.metallib" && cp "$METALLIB" "$FORK_BUILD/debug/mlx.metallib"; } \
      || die "metallib copy into the test bundle failed" 14
    log "BUILD_DONE fork-tests"
    log "FORK_TEST_START $FORK_TEST_FILTER"
    (cd "$FORK_COPY" && env -u MLX_GLM5_FUSED_GATE_UP DEVELOPER_DIR="$TEST_DEV" swift test --build-system native \
       --skip-build --scratch-path "$FORK_BUILD" --filter "$FORK_TEST_FILTER") > "$RES/fork-test.log" 2>&1
    rc=$?
    grep -q "Failed to load the default metallib" "$RES/fork-test.log" \
      && die "the fork test could not load the metallib (no test ran): $RES/fork-test.log" 15
    case_re="Test Case '-\[MLXLMTests\.GLM5NextTests ($FORK_TESTS)[A-Za-z0-9_]*\]'"
    p=$(grep -cE "$case_re passed" "$RES/fork-test.log")
    f=$(grep -cE "$case_re failed" "$RES/fork-test.log")
    sk=$(grep -cE "$case_re skipped" "$RES/fork-test.log")
    # Every matching test in the shipped test file must pass (r4-r6 hardcoded 2 of 3: FORK_TEST FAIL).
    want=$(grep -cE "func ($FORK_TESTS)[A-Za-z0-9_]*\(" "$FORK/Tests/MLXLMTests/GLM5NextTests.swift")
    log "FORK_TEST_DONE rc=$rc passed=$p want=$want failed=$f skipped=$sk"
    grep -E "XCTAssert|error:" "$RES/fork-test.log" | head -n 10 | sed 's/^/FORK_TEST_FAILURE /'
    if [ "$rc" = 0 ] && [ "$want" -ge 1 ] && [ "$p" = "$want" ] && [ "$f" = 0 ] && [ "$sk" = 0 ]; then FORK_TEST=PASS; else FORK_TEST=FAIL; fi
  else
    log "BLOCKER: fork test build failed: $(grep -m3 'error:' "$RES/fork-tests-build.log" | tr '\n' ' ' | cut -c1-400)"
    FORK_TEST=FAIL
  fi
  rm -rf "$FORK_BUILD" "$FORK_COPY"
fi
log "FORK_TEST $FORK_TEST"

# 4. Builds: base on its pins, fused with mlx-swift-lm replaced by the shipped fork tree.
# Serve refuses to start when the installed signed compatibility set names another provider_cli
# version, so both lab binaries carry the live install's version (read from the set, never pinned
# here). SRC is this run's throwaway archive, so the edit stays in the lab copy.
LIVE_SET=${LIVE_SET:-$HOME/macprovider/compatibility-set.json}
LIVE_VERSION=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["signed"]["components"]["provider_cli"]["version"])' \
  "$LIVE_SET" 2>/dev/null)
case "$LIVE_VERSION" in ""|*[!0-9.]*) die "cannot read provider_cli version from $LIVE_SET: '$LIVE_VERSION'" 11 ;; esac
log "LIVE_VERSION $LIVE_VERSION (from $LIVE_SET)"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  vsrc=$PKG/Sources/macprovider-cli/CoordinatorClient.swift
  sed -i '' "s/static let binaryVersion = \"[0-9.]*\"/static let binaryVersion = \"$LIVE_VERSION\"/" "$vsrc"
  grep -q "static let binaryVersion = \"$LIVE_VERSION\"" "$vsrc" || die "binaryVersion pin to $LIVE_VERSION failed" 14
  log "BUILD_START base"
  (cd "$PKG" && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-main \
    -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/e2e/build-base.log" 2>&1 \
    || die "base build failed: $(tail -n 3 "$RES/e2e/build-base.log" | tr '\n' ' ')" 14
  log "BUILD_START fused"
  rm -rf "$LAB"/cand-*
  { mkdir -p "$CAND_PKG" && rsync -a --exclude '.build*' --exclude '.swiftpm' --exclude 'Packages' "$PKG/" "$CAND_PKG/"; } \
    || die "candidate tree copy failed" 14
  (cd "$CAND_PKG" && swift package --build-path .build-lab-fused edit mlx-swift-lm --path "$FORK" \
     && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-fused \
       -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/e2e/build-fused.log" 2>&1 \
    || die "fused build failed: $(tail -n 3 "$RES/e2e/build-fused.log" | tr '\n' ' ')" 14
fi
base_lm=$(git -C "$PKG/.build-lab-main/checkouts/mlx-swift-lm" rev-parse HEAD 2>/dev/null)
[ "$base_lm" = "$FORK_BASE" ] || die "the base build's mlx-swift-lm is '$base_lm', not $FORK_BASE (the fork commit's parent)" 14
for side in base fused; do
  bin=$MAIN_BIN; [ $side = fused ] && bin=$CAND_BIN
  [ -x "$bin/macprovider-cli" ] || die "no $side lab-harness binary at $bin" 14
  cp "$METALLIB" "$bin/mlx.metallib" || die "metallib copy failed" 14
  shasum -a 256 "$bin/macprovider-cli" "$bin/mlx.metallib" > "$RES/e2e/identity-$side.sha256"
  ver=$("$bin/macprovider-cli" --version 2>&1 | head -n 1)
  log "BUILD_DONE $side $ver cli_sha256=$(cut -c1-16 "$RES/e2e/identity-$side.sha256" | head -n 1)"
  case " $ver " in *" $LIVE_VERSION "*) ;; *) die "the $side binary reports '$ver', not the live $LIVE_VERSION: serve would refuse the installed set" 14 ;; esac
done
cmp -s "$MAIN_BIN/macprovider-cli" "$CAND_BIN/macprovider-cli" && die "the base and fused binaries are identical: the fork did not reach the fused build" 14

# 5. The signed CB entry's tuple: the production batching route.
/usr/bin/python3 -I - "$PKG/catalog/autotune/continuous-batching-policy.json" "$GLM_ID" "$METALLIB_SHA" \
  > "$RES/e2e/cb-tuple.yaml" 2> "$RES/e2e/cb-tuple.err" <<'PY' || die "CB tuple: $(cat "$RES/e2e/cb-tuple.err")" 11
import json, sys
policy, model_id, metallib = sys.argv[1:4]
entries = [e for e in json.load(open(policy))["entries"] if e["model_id"] == model_id]
if len(entries) != 1:
    sys.exit(f"{len(entries)} signed CB entries for {model_id}")
e = entries[0]
# The release metallib can differ from the signed entry's (1.8.300: native-MTP admission logs
# decode_path=provenance_differs). Serve matches the CB tuple's metallib against the file it loads,
# so the lab tuple names the installed metallib; every other field stays the signed entry's.
if e["metallib_sha256"] != metallib:
    print(f"METALLIB_PROVENANCE_DIFFERS installed={metallib} signed={e['metallib_sha256']}", file=sys.stderr)
    e["metallib_sha256"] = metallib
keys = ("model_id", "model_sha256", "tokenizer_sha256", "chat_template_sha256", "cache_class", "kv_dtype",
        "requires_moe", "hardware_class", "metallib_sha256", "kernel_identifier", "cached_turns_accepted")
print("continuous_batching: canary")
print("continuous_batching_cached_turns: true")
print(f"continuous_batch_queue_limit: {e.get('max_served_slots', 4)}")
print("continuous_batching_accepted_tuples:")
print("  - {" + ", ".join(f"{k}: {json.dumps(e[k])}" for k in keys) + "}")
PY
grep '^METALLIB_PROVENANCE_DIFFERS ' "$RES/e2e/cb-tuple.err" | while read -r l; do log "$l"; done

# 6. base-a, fused, base-b, then the oMLX reference on base-b's stored grid.
OMLX_OK=missing
for p in "${PASSES[@]}"; do
  out=$RES/e2e/$p
  mkdir -p "$out"
  if [ "$p" = omlx ]; then
    cp "$RES/e2e/base-b/provider.jsonl" "$RES/e2e/base-b/grid.json" "$out/" || die "omlx: cannot seed from base-b" 15
  fi
  pass_args "$p"
  log "GRID_START $p"
  bash "$GRID/run-grid.sh" "${GARGS[@]}" > "$out/run.log" 2>&1
  rc=$?
  grep -E '^(CB_WARMUP_DONE|CB_WARMUP_STALL|CB_WARMUP_FAIL|ROUTE|ROUTE_FAIL|REFERENCE_SANE|REFERENCE_SUSPECT|REFERENCE_FAIL) ' \
    "$out/run.log" | sed "s/^/GRID_$(echo "$p" | tr 'a-z-' 'A-Z_') /"
  log "GRID_DONE $p rc=$rc"
  if [ "$p" = omlx ]; then
    # rc is compare's (greedy text differs from oMLX in long cells, #2451): the rows decide.
    if [ -s "$out/reference.jsonl" ] && ! grep -qE '^REFERENCE_(FAIL|SUSPECT) ' "$out/run.log"; then
      OMLX_OK=ok
    else
      log "BLOCKER: the oMLX reference failed or is suspect (rc=$rc): $(grep -m1 -E 'REFERENCE_(FAIL|SUSPECT)|OmlxReferenceError' "$out/run.log" | cut -c1-300)"
    fi
    continue
  fi
  grep -q '^ROUTE_FAIL ' "$out/run.log" && die "$p: ROUTE_FAIL, the serve was serial: not the batching route" 10
  { [ "$rc" = 0 ] && [ -s "$out/provider.jsonl" ]; } || die "$p: grid rc=$rc: $(tail -n 3 "$out/run.log" | tr '\n' ' ')" 15
done

# 7. Gate.
d=$RES/e2e
REF_ARGS=()
[ "$OMLX_OK" = ok ] && REF_ARGS=(--reference "$d/omlx/reference.jsonl")
/usr/bin/python3 -I "$GATE" --control-a "$d/base-a/provider.jsonl" --candidate "$d/fused/provider.jsonl" \
  --control-b "$d/base-b/provider.jsonl" ${REF_ARGS[@]+"${REF_ARGS[@]}"} --out-md "$d/gate.md" --out-json "$d/gate.json" \
  > "$d/gate.stdout" 2> "$d/gate.stderr"
rc=$?
cat "$d/gate.md" "$d/gate.stdout" 2>/dev/null
[ "$rc" = 2 ] && die "gate input: $(cat "$d/gate.stderr")" 16

# 8. Machine-greppable lines.
/usr/bin/python3 -I - "$d" "$FORK_TEST" "$OMLX_OK" <<'PY' | tee "$RES/verdict.md"
import json, os, statistics, sys
d, fork_test, omlx_ok = sys.argv[1:4]

def rows(path):
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        if line.strip():
            r = json.loads(line)
            if r.get("kind", "row") == "row" and r.get("turn", 1) != 2 and not r.get("error"):
                out.append(r)
    return out

engine = {"base-a": "base", "fused": "fused", "base-b": "base", "omlx": "omlx"}
for p, f in (("omlx", "reference.jsonl"), ("base-a", "provider.jsonl"), ("fused", "provider.jsonl"), ("base-b", "provider.jsonl")):
    cells = {}
    for r in rows(os.path.join(d, p, f)):
        cells.setdefault((r["ctx_target"], r["max_tokens"]), []).append(r)
    for (ctx, out), rs in sorted(cells.items(), key=lambda kv: (str(kv[0][0]), kv[0][1])):
        t = [r["ttft_s"] for r in rs if r.get("ttft_s") is not None]
        pts = [r["prompt_tokens"] for r in rs if r.get("prompt_tokens") is not None]
        pt = int(statistics.median(pts)) if pts else "none"
        ttft = f"{statistics.median(t):.3f}" if t else "none"
        print(f"TTFT_ROW engine={engine[p]} pass={p} prompt_tokens={pt} out={out} ttft_s={ttft} n={len(t)}")

g = json.load(open(os.path.join(d, "gate.json")))
pct = lambda v: "n/a" if v is None else f"{v * 100:+.2f}%"
for c in g["cells"]:
    pt = int(c["prompt_tokens"]) if c["prompt_tokens"] is not None else "none"
    print(f"GAP_ROW prompt_tokens={pt} out={c['out']} base_vs_omlx={pct(c['main_vs_omlx'])} "
          f"fused_vs_omlx={pct(c['candidate_vs_omlx'])} fused_vs_base_a={pct(c['change_vs_a'])} "
          f"fused_vs_base_b={pct(c['change_vs_b'])} beats_both={str(c['beats_both_controls']).lower()}")
for c in g["cells"]:
    pt = int(c["prompt_tokens"]) if c["prompt_tokens"] is not None else "none"
    print(f"PARITY_ROW engine=fused vs=base-a prompt_tokens={pt} out={c['out']} "
          f"identical={str(c['identical']).lower()}")
for f in g["failures"]:
    print(f"PARITY_FAILURE {f}")
print(f"T2474_VERDICT fork_test={fork_test} tokens={'identical' if g['pass'] else 'differ'} "
      f"fused={g['verdict']} omlx={omlx_ok}")
PY
[ "${PIPESTATUS[0]}" = 0 ] || die "summary lines failed" 16

ok=1
[ "$FORK_TEST" = FAIL ] && { log "BLOCKER: the fork bit-identity test did not pass ($RES/fork-test.log)"; ok=0; }
[ "$rc" = 0 ] || { log "BLOCKER: greedy tokens of fused or base-b differ from base-a ($d/gate.md)"; ok=0; }
[ "$SKIP_OMLX" = 1 ] || [ "$OMLX_OK" = ok ] || { log "BLOCKER: no oMLX rows: the gap to oMLX is not measured"; ok=0; }
[ "$ok" = 1 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
