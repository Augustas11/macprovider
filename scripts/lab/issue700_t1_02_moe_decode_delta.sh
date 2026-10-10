#!/bin/bash
# T1-02 (issue #700): MoE decode delta, mlx-swift-lm 3.31.4 -> 3.32.3.
#
# Re-runs the T0-02 matrix (512 prefill / 256 decode, 5 timed runs + warmup,
# decode-bench generation-only TPS) on ONE host with the pre-bump and the
# post-bump binary, interleaved A/B/A/B per model so thermal drift hits both
# sides. Gemma 4 26B-A4B has no pre-bump number (3.31.4 cannot load it); its
# pre-bump leg is recorded as a load attempt only.
#
# THROUGHPUT RUN. Start it only when the host is free for benchmarking.
#
# usage:
#   issue700_t1_02_moe_decode_delta.sh prepare   # fetch the dense control, write manifest (no timing)
#   issue700_t1_02_moe_decode_delta.sh run       # the timed matrix
#   issue700_t1_02_moe_decode_delta.sh summary   # p50 table + deltas + catalog gates (JSON + text)
#
# env:
#   LAB         lab root (default: directory of this script)
#   PRE_BIN     pre-bump bin dir  (macprovider-cli + its own mlx.metallib); default $LAB/bin-prebump
#   POST_BIN    post-bump bin dir (macprovider-cli + its own mlx.metallib); default $LAB/bin
#   MODELS_DIR  where the reviewed artifacts live (default: provider model store)
#   BW_GBPS     host memory bandwidth for --report-sparsity (default 819, M3 Ultra)
#   ROUNDS      A/B rounds per model (default 2)
#   SKIP_PRE    1 = post-bump leg only (T0-02 reference host, compared to the recorded T0-02 rows)
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=${LAB:-$(cd "$(dirname "$0")" && pwd)}
PRE_BIN=${PRE_BIN:-$LAB/bin-prebump}
POST_BIN=${POST_BIN:-$LAB/bin}
STORE=${MODELS_DIR:-"$HOME/Library/Application Support/macprovider/models"}
BW_GBPS=${BW_GBPS:-819}
ROUNDS=${ROUNDS:-2}
OUT=$LAB/t1-02
QWEN_DIR=$LAB/models/Qwen2.5-7B-Instruct-4bit
QWEN_REV=c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed

# name | model dir | total params (B, the T0-02 values) | catalog min_sustained_tps (0 = no row)
models() {
  cat <<EOF
qwen2.5-7b|$QWEN_DIR|7.0|0
gpt-oss-20b|$STORE/mlx-community--gpt-oss-20b-MXFP4-Q8/773a7da77e569019bb0fd17a554b263738d669a3/f25592861e0b7f4eb8489d9103214f3f0dc4f798bb0e4e0cd817ff2f4191f1b1|20.0|15
gemma-4-26b-a4b|$STORE/mlx-community--gemma-4-26b-a4b-it-4bit/0d77464eeb233a2da68ebf9d7dc4edaac7db956d/b245e39f1476907653e3fe1897bba36b0e2a90c471828a9e13b5fdf3e1b6db01|26.0|10
EOF
}

refuse_if_busy() {
  if pgrep -f lab-cb-sampling/bench.sh >/dev/null; then echo "another benchmark window is active; refusing" >&2; exit 3; fi
}

prepare() {
  mkdir -p "$QWEN_DIR" "$OUT"
  for f in config.json model.safetensors model.safetensors.index.json tokenizer.json tokenizer_config.json \
           special_tokens_map.json added_tokens.json merges.txt vocab.json; do
    [ -s "$QWEN_DIR/$f" ] || curl -fsSL -o "$QWEN_DIR/$f" \
      "https://huggingface.co/mlx-community/Qwen2.5-7B-Instruct-4bit/resolve/$QWEN_REV/$f"
  done
  {
    echo "qwen_revision=$QWEN_REV"
    (cd "$QWEN_DIR" && shasum -a 256 ./*)
    for b in $([ "${SKIP_PRE:-0}" = 1 ] || echo "$PRE_BIN") "$POST_BIN"; do
      echo "bin=$b version=$("$b/macprovider-cli" --version)"
      shasum -a 256 "$b/macprovider-cli" "$b/mlx.metallib"
    done
    sysctl -n machdep.cpu.brand_string hw.memsize; sw_vers -productVersion
  } > "$OUT/manifest.txt"
  cat "$OUT/manifest.txt"
}

bench() { # side bin name dir params
  local side=$1 bin=$2 name=$3 dir=$4 params=$5 round=$6
  local o="$OUT/$name-$side-r$round.json"
  refuse_if_busy
  # Read-only: record the live provider's request counter so contention is visible.
  local live_before; live_before=$(curl -s --max-time 2 http://127.0.0.1:8080/v1/status | python3 -c 'import json,sys;print(json.load(sys.stdin).get("requests_total"))' 2>/dev/null || echo na)
  set +e
  env HOME="$LAB/home" TMPDIR="$LAB/tmp/" "$bin/macprovider-cli" decode-bench --model "$dir" \
    --prefill-tokens 512 --decode-tokens 256 --runs 5 --label "t1-02-$side" \
    --report-sparsity --total-params-b "$params" --bandwidth-gbps "$BW_GBPS" \
    --output "$o" > "$OUT/$name-$side-r$round.log" 2>&1
  local rc=$?
  set -e
  local live_after; live_after=$(curl -s --max-time 2 http://127.0.0.1:8080/v1/status | python3 -c 'import json,sys;print(json.load(sys.stdin).get("requests_total"))' 2>/dev/null || echo na)
  echo "$name $side r$round exit=$rc live_requests_total=$live_before->$live_after $(date -u +%T)" | tee -a "$OUT/run.log"
}

run() {
  mkdir -p "$OUT" "$LAB/home" "$LAB/tmp"
  [ -s "$OUT/manifest.txt" ] || { echo "run prepare first" >&2; exit 2; }
  refuse_if_busy
  echo "start $(date -u +%FT%TZ)" >> "$OUT/run.log"
  while IFS='|' read -r name dir params _gate; do
    for round in $(seq 1 "$ROUNDS"); do
      if [ "${SKIP_PRE:-0}" = 1 ] || { [ "$name" = gemma-4-26b-a4b ] && [ "$round" -gt 1 ]; }; then :; else
        bench pre "$PRE_BIN" "$name" "$dir" "$params" "$round"
      fi
      bench post "$POST_BIN" "$name" "$dir" "$params" "$round"
    done
  done < <(models)
  echo "done $(date -u +%FT%TZ)" >> "$OUT/run.log"
}

summary() {
  mkdir -p "$OUT"
  models | python3 -I -c '
import json, statistics, sys, glob, os
out = sys.argv[1]
# T0-02 reference rows (M5 32 GB, 2026-07-07, mlx-swift-lm 3.31.4). Context only
# unless this run is on that same host.
t0 = {"qwen2.5-7b": 27.1, "gpt-oss-20b": 26.3, "gemma-4-26b-a4b": None}
rows = []
for line in sys.stdin:
    name, _dir, _params, gate = line.strip().split("|")
    r = {"model": name, "catalog_min_sustained_tps": float(gate) or None, "t0_02_m5_decode_tps_p50": t0[name]}
    for side in ("pre", "post"):
        dec, pre, ttft, implied = [], [], [], []
        for f in sorted(glob.glob(os.path.join(out, f"{name}-{side}-r*.json"))):
            d = json.load(open(f))
            for s in d.get("samples", []):
                if s.get("isWarmup"):
                    continue
                dec.append(s["decodeTPS"]); pre.append(s["prefillTPS"]); ttft.append(s["ttftSeconds"] * 1000)
            sp = d.get("sparsity") or {}
            if sp.get("impliedActiveParamsB") is not None:
                implied.append(sp["impliedActiveParamsB"])
        r[side] = {"n": len(dec),
                   "decode_tps_p50": round(statistics.median(dec), 2) if dec else None,
                   "prefill_tps_p50": round(statistics.median(pre), 1) if pre else None,
                   "ttft_ms_p50": round(statistics.median(ttft)) if ttft else None,
                   "implied_active_params_B": round(statistics.median(implied), 2) if implied else None}
    a, b = r["pre"]["decode_tps_p50"], r["post"]["decode_tps_p50"]
    r["decode_delta_pct"] = round((b - a) / a * 100, 1) if a and b else None
    g = r["catalog_min_sustained_tps"]
    r["gate"] = None if not g or b is None else ("PASS" if b >= g else "BELOW_GATE")
    r["regression_gt_5pct"] = r["decode_delta_pct"] is not None and r["decode_delta_pct"] < -5
    rows.append(r)
json.dump(rows, open(os.path.join(out, "summary.json"), "w"), indent=1)
for r in rows:
    pre, post = r["pre"], r["post"]
    print("%-18s pre=%s post=%s delta=%s%% gate=%s->%s implied_active_B=%s n=%s/%s" % (
        r["model"], pre["decode_tps_p50"], post["decode_tps_p50"], r["decode_delta_pct"],
        r["catalog_min_sustained_tps"], r["gate"], post["implied_active_params_B"], pre["n"], post["n"]))
' "$OUT"
}

case "${1:-}" in
  prepare) prepare ;;
  run) run ;;
  summary) summary ;;
  *) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 2 ;;
esac
