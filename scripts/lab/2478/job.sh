#!/bin/bash
# Runs ON THE STUDIO, started detached by the #2478 window wrapper, which has already paused live,
# the runner's Studio target and the FLOP miner and holds the Studio GPU lock. This job never
# pauses, restores or restarts any of them; it refuses to start while anything still runs.
#
# #2478: in the SPEC-048 R015 gated cells (4 qualified slots, max_native_active_rows 1, rows 250 ms
# apart) the native arm's first row reached its first token ~1.2 s later than the ordinary arm's,
# and the later rows prefilled 1+2 instead of as one cohort of 3 (+6% gated TTFT p95, no drafting).
# Cause: the native runtime's Qwen text preparation lane admits the arrivals during the head's
# prefill forwards, and with no row decoding the leftover budget let some of them ride the head's
# forwards at offset 0 (SPEC-038 v0.3.66 stops that on shared-forward backends). This job measures
# the fix A/B/A against its base on mlx-community/Qwen3.8-27B-4bit (store snapshot 8a8786e9) with
# its MTP head mlx-community/Qwen3.8-27B-MTP-4bit (25d2e7e3):
#  1. preflight: nothing on :8080/:8000, no live agent, serve, FLOP agent or VM process; free disk
#     >= MIN_FREE_GB; inputs present; the metallib is the signed native-MTP entry's;
#  2. two lab-harness release builds (-DMACPROVIDER_LAB_HARNESS), each in its own tree:
#     A = BASE_SRC (git-archive of BASE_COMMIT, the fix's base on main), B = SRC (COMMIT, the fix);
#  3. fixture ~/lab-2478/fixtures/qwen38/{target,mtp} (APFS clones; the store stays read only);
#  4. runs in RUNS order (default "A1:A B:B A2:A", control-candidate-control), one process at a time:
#     per run a formal SPEC-048 R015 policy in the signed qwen/qwen3.8-27b shape (prompts
#     1536/4096/32768, outputs 128/512, MTP_BLOCKS 12, seed 20261119, single_token_identical_pair,
#     gated s2/s4 at p1536-o512), bound to that run's build commit; native-mtp-bench runs only the
#     CELLS (default "s4-p1536-o512 s2-p1536-o512") with --only-cell --phase matrix, then
#     scripts/native_mtp_r015_analyze.py (overall_status is partial by design: only gated cells ran;
#     the per-cell rows are the result). MACPROVIDER_LAB_OFFLINE=1 with MACPROVIDER_NATIVE_MTP_E2E=1
#     turns on only the CB preparation trace (`prefill_group_begin` ids/offsets/chunks), not the
#     per-token trace, so each run records its prefill groups;
#  5. summary: GROUPS lines (first prefill groups per run and cell), T2478_SUMMARY per run and cell
#     (medians over blocks of each arm's per-row TTFT and TTFT p95, native-minus-ordinary delta), then
#     one `T2478_ROW cell= arm=<native|ordinary> build=<base|fix> ttft_p95_s= e2e_tps= identical=`
#     per cell, arm and build (base = the A runs pooled, fix = the B runs; medians over blocks of
#     ttft_p95_seconds and aggregate_committed_tps; identical = no parity mismatch and every request's
#     content_sha256 equals the first A run's ordinary arm at the same block), and T2478_VERDICT last.
# Verdict PASS: every row identical; and in every fix run the goal cell s4-p1536-o512 passes the
# analyzer's gated TTFT p95, TPOT p95 and throughput bounds versus ordinary CB. Other cells print their
# T2478_GATE status and fail only on token mismatch (s2 TPOT is the per-step overhead filed as #2489).
# FAIL makes the job end JOB_FAIL.
# Knobs: CELLS RUNS MTP_BLOCKS (12) MIN_FREE_GB (60) SKIP_BUILD METALLIB.
# Every failure prints `BLOCKER:`; the job ends with JOB_PASS (every step ran, verdict PASS) or JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-2478
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
COMMIT=${COMMIT:?COMMIT unset}
BASE_SRC=${BASE_SRC:?BASE_SRC unset}
BASE_COMMIT=${BASE_COMMIT:?BASE_COMMIT unset}
HERE=$SRC/scripts/lab/2478
RES=$LAB/results/$RUN_ID
FIX=$LAB/fixtures
STORE="$HOME/Library/Application Support/macprovider/models"
HF="$HOME/.cache/huggingface/hub"
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-2478
MIN_FREE_GB=${MIN_FREE_GB:-60}
CELLS=${CELLS:-s4-p1536-o512 s2-p1536-o512}
RUNS=${RUNS:-A1:A B:B A2:A}
MTP_BLOCKS=${MTP_BLOCKS:-12}
QWEN_KEY=qwen/qwen3.8-27b
QWEN_SHA=8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05
QWEN_MTP_SHA=25d2e7e3846c6a95201b13a0299eb65527b8146541af3b1eb626eaac95fefb30
FAILED=0
log() { echo "$(date '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; FAILED=1; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
src_of() { [ "$1" = A ] && echo "$BASE_SRC" || echo "$SRC"; }
commit_of() { [ "$1" = A ] && echo "$BASE_COMMIT" || echo "$COMMIT"; }
bin_of() { echo "$(src_of "$1")/phase3-binary/$BUILD/release"; }
echo "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "COMMIT must be the 40-hex fix commit" 64
echo "$BASE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "BASE_COMMIT must be the 40-hex base commit" 64
case "$MTP_BLOCKS" in 1[0-9]|20) ;; *) die "MTP_BLOCKS must be 10..20 (formal R015)" 64 ;; esac
for c in $CELLS; do
  case "$c" in s2-p1536-o512|s4-p1536-o512) ;; *) die "CELLS names a cell outside the gated pair: $c" 64 ;; esac
done
for r in $RUNS; do
  case "${r#*:}" in A|B) ;; *) die "RUNS entry $r is not LABEL:A or LABEL:B" 64 ;; esac
done
mkdir -p "$RES"
log "JOB_START run=$RUN_ID commit=$COMMIT base=$BASE_COMMIT cells=\"$CELLS\" runs=\"$RUNS\" mtp_blocks=$MTP_BLOCKS"

# 1. Preflight.
listening 8080 && die "a server listens on :8080; the Studio is not paused" 3
listening 8000 && die "a server listens on :8000; the FLOP miner backend is not paused" 3
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
launchctl list 2>/dev/null | grep -q 'com\.flop\.' && die "a com.flop LaunchAgent is loaded (miner not paused)" 3
pgrep -f "[c]om.apple.Virtualization.VirtualMachine|[l]imactl|[m]lx_service" >/dev/null 2>&1 && die "a miner VM or backend process runs" 3
fg=$(free_gb)
log "DISK free_gb=$fg min=$MIN_FREE_GB"
[ "${fg:-0}" -ge "$MIN_FREE_GB" ] || die "only ${fg} GB free; need $MIN_FREE_GB (two builds; fixtures are APFS clones)" 13
for f in "$SRC/phase3-binary/Package.swift" "$BASE_SRC/phase3-binary/Package.swift" "$HERE/mtp_policy.py" \
         "$SRC/scripts/native_mtp_r015_analyze.py"; do
  [ -f "$f" ] || die "source tree incomplete: no $f" 11
done
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)
SIGNED_METALLIB=$(/usr/bin/python3 -I -c 'import json,sys
e=[e for e in json.load(open(sys.argv[1]))["entries"] if e.get("model_key")==sys.argv[2] and e.get("artifact_hash")==sys.argv[3]]
print(e[0]["metallib_sha256"] if len(e)==1 else "")' "$SRC/phase3-binary/catalog/autotune/native-mtp-admission.json" "$QWEN_KEY" "$QWEN_SHA")
log "METALLIB sha256=$METALLIB_SHA signed_native_mtp_entry=$SIGNED_METALLIB"
[ "$METALLIB_SHA" = "$SIGNED_METALLIB" ] || die "metallib $METALLIB_SHA is not the signed native-MTP entry's $SIGNED_METALLIB" 14
QWEN_DIR=""
for d in "$STORE"/mlx-community--Qwen3.8-27B-4bit/*/"$QWEN_SHA"; do [ -f "$d/config.json" ] && QWEN_DIR=$d; done
[ -n "$QWEN_DIR" ] || die "no durable qwen3.8-27b snapshot $QWEN_SHA in the provider store" 11
HEAD_DIR=""
for d in "$STORE"/mlx-community--Qwen3.8-27B-MTP-4bit/*/"$QWEN_MTP_SHA" "$HF"/models--mlx-community--Qwen3.8-27B-MTP-4bit/snapshots/b643c01b6d3b094e325edb6ebd832e16c486c575; do
  [ -z "$HEAD_DIR" ] && [ -f "$d/config.json" ] && HEAD_DIR=$d
done
[ -n "$HEAD_DIR" ] || die "no Qwen3.8-27B-MTP-4bit head ($QWEN_MTP_SHA) in the store or the HF cache" 11
QWEN_TOK=$(shasum -a 256 "$QWEN_DIR/tokenizer.json" | cut -d' ' -f1)
log "INPUTS qwen=$QWEN_DIR head=$HEAD_DIR tokenizer=$QWEN_TOK"

# 2. Builds: A (base) and B (fix), each in its own tree and build path.
for arm in A B; do
  pkg=$(src_of "$arm")/phase3-binary
  if [ "${SKIP_BUILD:-0}" != 1 ]; then
    log "BUILD_START $arm commit=$(commit_of "$arm")"
    (cd "$pkg" && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" -Xswiftc -DMACPROVIDER_LAB_HARNESS) \
      > "$RES/build-$arm.log" 2>&1 || die "release build $arm failed: $(grep -m3 'error:' "$RES/build-$arm.log" | tr '\n' ' ' | cut -c1-400)" 14
  fi
  bin=$(bin_of "$arm")
  [ -x "$bin/macprovider-cli" ] || die "no lab-harness binary at $bin" 14
  cp "$METALLIB" "$bin/mlx.metallib" || die "metallib copy $arm failed" 14
  digest=$(/usr/bin/python3 -I "$(src_of "$arm")/scripts/decode_path_digest.py" 2>/dev/null | tail -n 1)
  log "BUILD_DONE $arm $("$bin/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(shasum -a 256 "$bin/macprovider-cli" | cut -c1-16) decode_path_digest=$digest"
  shasum -a 256 "$bin/macprovider-cli" | sed "s/^/$arm /" >> "$RES/identity.sha256"
done

# 3. Fixture (APFS clones; the store and the head stay read only).
root=$FIX/qwen38
rm -rf -- "$root" && mkdir -p "$root" \
  && /bin/cp -c -R -L "$QWEN_DIR" "$root/target" && /bin/cp -c -R -L "$HEAD_DIR" "$root/mtp" \
  && rm -rf -- "$root/target/.cache" "$root/mtp/.cache" || die "fixture clone failed" 11
log "FIXTURE $root free_gb=$(free_gb)"

# 4. Runs.
run_one() {  # run_one LABEL ARM
  local label=$1 arm=$2 d=$RES/$1 bin fork i err rc cell ok=1
  bin=$(bin_of "$arm")
  fork=$(sed -n 's/.*static let mlxSwiftLMRevision = "\([0-9a-f]*\)".*/\1/p' \
    "$(src_of "$arm")/phase3-binary/Sources/macprovider-cli/KVConversationColdTierAdapter.swift" | head -n 1)
  mkdir -p "$d"
  /usr/bin/python3 -I "$HERE/mtp_policy.py" write "$d/policy.json" --model-id "$QWEN_KEY" --target-sha "$QWEN_SHA" \
    --mtp-sha "$QWEN_MTP_SHA" --tokenizer-sha "$QWEN_TOK" --qualified-slots 4 --prompts 1536,4096,32768 \
    --outputs 128,512 --blocks "$MTP_BLOCKS" --seed 20261119 --commit "$(commit_of "$arm")" --fork "$fork" \
    --hw "$(sysctl -n hw.model)" --os-build "$(sysctl -n kern.osversion)" --xcode unknown \
    --swift "$(/usr/bin/xcrun swift --version 2>/dev/null | head -n 1)" --exclusion single_token_identical_pair --formal \
    || { blocker "$label: policy generation failed"; return 1; }
  bench() { (cd "$bin" && env MACPROVIDER_NATIVE_MTP_E2E=1 MACPROVIDER_LAB_OFFLINE=1 ./macprovider-cli native-mtp-bench \
    --root "$root" --model-id "$QWEN_KEY" --policy "$d/policy.json" --provider-commit "$(commit_of "$arm")" "$@"); }
  for i in 1 2 3 4 5 6 7 8; do
    bench --out "$d/validate.jsonl" --validate-policy-only --identity-cache "$LAB/mtp-identity-cache.json" \
      > "$d/validate.out" 2> "$d/validate.err" && break
    err=$(cat "$d/validate.out" "$d/validate.err")
    /usr/bin/python3 -I "$HERE/mtp_policy.py" fix "$d/policy.json" "$err" \
      || { blocker "$label: native-mtp-bench refuses the policy: $(echo "$err" | tr '\n' ' ' | cut -c1-400)"; return 1; }
    [ "$i" = 8 ] && { blocker "$label: policy still refused after 8 environment fixes"; return 1; }
  done
  shasum -a 256 "$d/policy.json" | sed "s/^/$label /" >> "$RES/identity.sha256"
  rm -f "$d/bench.jsonl"
  for cell in $CELLS; do
    log "CELL_START $label ($arm) $cell"
    bench --out "$d/bench.jsonl" --only-cell "$cell" --phase matrix > "$d/$cell.out" 2> "$d/$cell.log"
    rc=$?
    log "CELL_DONE $label $cell rc=$rc records=$(wc -l < "$d/bench.jsonl" 2>/dev/null | tr -d ' ') prefill_groups=$(grep -c 'prefill_group_begin' "$d/$cell.log")"
    [ $rc = 0 ] || { blocker "$label $cell rc=$rc: $(tail -n 2 "$d/$cell.log" | tr '\n' ' ' | cut -c1-300)"; ok=0; break; }
  done
  /usr/bin/python3 -I "$SRC/scripts/native_mtp_r015_analyze.py" "$d/bench.jsonl" "$d/policy.json" > "$d/analysis.json" 2> "$d/analysis.err"
  /usr/bin/python3 -I "$SRC/scripts/native_mtp_r015_analyze.py" "$d/bench.jsonl" "$d/policy.json" --format markdown > "$d/analysis.md" 2>> "$d/analysis.err"
  sed "s/^/ANALYSIS $label /" "$d/analysis.md" 2>/dev/null | grep -E 'gated|parity|mismatch' | head -n 20
  [ $ok = 1 ]
}
for r in $RUNS; do
  run_one "${r%%:*}" "${r#*:}" || true
done

# 5. Summary. Prefill groups first, then per run and cell the medians over the matrix blocks, then one
# T2478_ROW per cell, arm and build (base = A runs pooled, fix = B runs), and T2478_VERDICT last.
for r in $RUNS; do
  label=${r%%:*}
  for cell in $CELLS; do
    grep -m 8 'prefill_group_begin' "$RES/$label/$cell.log" 2>/dev/null | sed "s/^/GROUPS $label $cell /"
  done
done
rm -rf -- "$FIX"
/usr/bin/python3 -I - "$RES" "$CELLS" $RUNS <<'PY' | tee "$RES/summary.txt"
import json, math, statistics, sys
res, cells, runs = sys.argv[1], sys.argv[2].split(), [r.split(":") for r in sys.argv[3:]]
med = lambda xs: statistics.median(xs) if xs else float("nan")
ARMS = {"native": "native_mtp", "ordinary": "ordinary"}
GOAL = "s4-p1536-o512"
recs = {}
for label, arm in runs:
    try:
        lines = [json.loads(l) for l in open(f"{res}/{label}/bench.jsonl")]
    except (OSError, ValueError):
        print(f"T2478_SUMMARY {label} missing"); lines = []
    recs[label] = [r for r in lines if r.get("record_type") == "run" and not r.get("warmup") and not r.get("sustained")]
    for cell in cells:
        arms = {p: [r for r in recs[label] if r["cell_id"] == cell and r["path"] == p] for p in ARMS.values()}
        if not all(arms.values()):
            print(f"T2478_SUMMARY {label} {cell} missing"); continue
        rows = {p: [med([r["per_request_ttft_seconds"][i] for r in rs if r["per_request_ttft_seconds"][i] is not None])
                    for i in range(len(rs[0]["per_request_ttft_seconds"]))] for p, rs in arms.items()}
        p95 = {p: med([r["ttft_p95_seconds"] for r in rs]) for p, rs in arms.items()}
        blocks = {r["block_index"]: r for r in arms["native_mtp"]}
        deltas = [blocks[o["block_index"]]["ttft_p95_seconds"] / o["ttft_p95_seconds"] - 1
                  for o in arms["ordinary"] if o["block_index"] in blocks]
        mism = sum(1 for rs in arms.values() for r in rs if r.get("parity_mismatch"))
        print(f"T2478_SUMMARY {label} {cell} blocks={len(deltas)} parity_mismatch={mism} "
              f"ttft_p95 ord={p95['ordinary']:.3f} nat={p95['native_mtp']:.3f} delta_median={med(deltas):+.4f} "
              f"rows_ttft ord={[round(x, 2) for x in rows['ordinary']]} nat={[round(x, 2) for x in rows['native_mtp']]}")
# Token reference: the first base run's ordinary arm, per cell, block and request. Every arm of every
# build must produce the same content per block and request, with no parity mismatch recorded.
ref_label = next((l for l, a in runs if a == "A"), None)
ref = {(r["cell_id"], r["block_index"], i): m["content_sha256"]
       for r in recs.get(ref_label, []) if r["path"] == "ordinary" for i, m in enumerate(r["request_metrics"])}
out, fails = {}, []
for cell in cells:
    for arm, path in ARMS.items():
        for build, letter in (("base", "A"), ("fix", "B")):
            rs = [r for l, a in runs if a == letter for r in recs[l] if r["cell_id"] == cell and r["path"] == path]
            same = bool(rs) and all(not r.get("parity_mismatch") for r in rs) and all(
                ref.get((cell, r["block_index"], i)) == m["content_sha256"]
                for r in rs for i, m in enumerate(r["request_metrics"]))
            ttft = med([r["ttft_p95_seconds"] for r in rs if r.get("ttft_p95_seconds") is not None])
            tps = med([r["aggregate_committed_tps"] for r in rs if r.get("aggregate_committed_tps") is not None])
            out[cell, arm, build] = (ttft, tps, same, rs)
            print(f"T2478_ROW cell={cell} arm={arm} build={build} ttft_p95_s={ttft:.3f} e2e_tps={tps:.2f} "
                  f"identical={'true' if same else 'false'}")
            if not same:
                fails.append(f"{cell}/{arm}/{build} tokens not identical or missing")
    # The analyzer's own gated bounds versus ordinary CB, per fix run (TTFT p95, TPOT p95, throughput).
    # The goal cell must pass all three in every fix run; other cells report status and fail only on
    # token mismatch (the s2 TPOT bound is the per-step overhead filed as #2489).
    for label, arm in runs:
        if arm != "B":
            continue
        try:
            cr = {c["cell_id"]: c for c in json.load(open(f"{res}/{label}/analysis.json"))["cells"]}[cell]
            st = {m: cr["metrics"][m]["status"] for m in ("ttft", "tpot", "throughput")}
        except (OSError, ValueError, KeyError):
            st = {m: "MISSING" for m in ("ttft", "tpot", "throughput")}
        print(f"T2478_GATE cell={cell} run={label} " + " ".join(f"{m}={v}" for m, v in st.items()))
        if cell == GOAL and any(v != "PASS" for v in st.values()):
            fails.append(f"{cell} {label} analyzer gates " + ",".join(f"{m}={v}" for m, v in st.items()))
print(f"T2478_VERDICT {'PASS' if not fails else 'FAIL'}" + ("" if not fails else ": " + "; ".join(fails)))
sys.exit(0 if not fails else 3)
PY
[ "${PIPESTATUS[0]}" = 0 ] || FAILED=1
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
