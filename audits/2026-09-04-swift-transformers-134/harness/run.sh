#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

QWEN3="$HOME/.cache/huggingface/hub/models--mlx-community--Qwen3-8B-4bit/snapshots/545dc4251c05440727734bcd94334791f6ab0192"
LLAMA32="$HOME/.cache/huggingface/hub/models--mlx-community--Llama-3.2-3B-Instruct-4bit/snapshots/7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"

OUT=out
mkdir -p "$OUT"

for VER in 1.0.0 1.3.4; do
  export TOKPARITY_TRANSFORMERS_VERSION="$VER"
  echo "### building at $VER"
  # force re-resolve to the version encoded in Package.swift env
  rm -f Package.resolved
  swift build -c release >/dev/null 2>"$OUT/build-$VER.log" || { echo "BUILD FAILED $VER"; tail -20 "$OUT/build-$VER.log"; exit 1; }
  BIN=$(swift build -c release --show-bin-path 2>/dev/null)/tokparity
  echo "### running $VER on qwen3 + llama32"
  "$BIN" "$QWEN3"   corpus.json "$OUT/qwen3-$VER.json"
  "$BIN" "$LLAMA32" corpus.json "$OUT/llama32-$VER.json"
done

echo "### done"
ls -la "$OUT"/*.json
