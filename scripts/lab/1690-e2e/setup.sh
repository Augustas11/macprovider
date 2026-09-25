#!/usr/bin/env bash
# #1690 e2e: prepare a fresh lab dir for scripts/lab/1690-m6/rig.sh.
# Clones (APFS cp -c, no extra space) the pinned GGUF, the MLX snapshot, and
# the Ollama store from an earlier lab (M8 by default), lays the MLX snapshot
# out as a Hugging Face cache under $LAB/home so the native (mlx_cache) CLI
# finds it offline, and links the lab mlx_lm venv and Ollama binary. Never
# touches ~/.config/macprovider or the live provider.
set -euo pipefail
LAB="${LAB:?set LAB}"
SRC_LAB="${SRC_LAB:-/Users/a1/lab-1690-m6/m8}"
REV=a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3
GGUF=qwen2.5-0.5b-instruct-q4_k_m.gguf
SNAP=Qwen2.5-0.5B-Instruct-4bit
case "$LAB" in /Users/a1/lab-1690-m6/*) ;; *) echo "refusing: LAB must be under /Users/a1/lab-1690-m6" >&2; exit 2 ;; esac
mkdir -p "$LAB"/{bin,logs,models/mlx,keys,db,run,static,pools,home/hf,tmp,provider}
chmod 700 "$LAB/keys" "$LAB/home"
[[ -f "$LAB/models/$GGUF" ]] || cp -c "$SRC_LAB/models/$GGUF" "$LAB/models/$GGUF"
[[ -d "$LAB/models/mlx/$SNAP" ]] || cp -cR "$SRC_LAB/models/mlx/$SNAP" "$LAB/models/mlx/$SNAP"
HUB="$LAB/home/.cache/huggingface/hub"
REPO="$HUB/models--mlx-community--$SNAP"
if [[ ! -d "$REPO/snapshots/$REV" ]]; then
  mkdir -p "$REPO/refs" "$REPO/snapshots"
  cp -cR "$LAB/models/mlx/$SNAP" "$REPO/snapshots/$REV"
  printf '%s' "$REV" >"$REPO/refs/main"
fi
[[ -e "$LAB/home/hf/hub" ]] || ln -s "$HUB" "$LAB/home/hf/hub"
[[ -e "$LAB/venv" ]] || ln -s "$SRC_LAB/venv" "$LAB/venv"
[[ -e "$LAB/ollama" ]] || ln -s "$SRC_LAB/ollama" "$LAB/ollama"
[[ -d "$LAB/ollama-models" ]] || cp -cR "$SRC_LAB/ollama-models" "$LAB/ollama-models"
# #1690 M9: LM Studio (headless llmster) and oMLX. LMS_HOME is an llmster
# install in its own HOME (install.sh run with HOME set there), with the
# pinned GGUF under .lmstudio/models; OMLX_VENV is a venv with oMLX installed
# from source and setproctitle removed, so its process keeps a command line
# pidguard can verify. Both are linked, never installed, here.
LMS_HOME_SRC="${LMS_HOME_SRC:-/Users/a1/lab-1690-m9/lmshome}"
OMLX_VENV_SRC="${OMLX_VENV_SRC:-/Users/a1/lab-1690-m9/omlx-venv}"
if [[ -x "$LMS_HOME_SRC/.lmstudio/bin/lms" && ! -e "$LAB/lmshome" ]]; then ln -s "$LMS_HOME_SRC" "$LAB/lmshome"; fi
LMS_GGUF="$LAB/lmshome/.lmstudio/models/lmstudio-community/Qwen2.5-0.5B-Instruct-GGUF/$GGUF"
if [[ -e "$LAB/lmshome" && ! -f "$LMS_GGUF" ]]; then mkdir -p "$(dirname "$LMS_GGUF")" && cp -c "$LAB/models/$GGUF" "$LMS_GGUF"; fi
if [[ -x "$OMLX_VENV_SRC/bin/omlx" && ! -e "$LAB/omlx-venv" ]]; then ln -s "$OMLX_VENV_SRC" "$LAB/omlx-venv"; fi
[[ -d "$LAB/omlx-models/$SNAP" ]] || { mkdir -p "$LAB/omlx-models" && cp -cR "$LAB/models/mlx/$SNAP" "$LAB/omlx-models/$SNAP"; }
mkdir -p "$LAB/omlxhome"
echo "setup ok: $LAB"
