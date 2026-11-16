#!/bin/bash
# Runs ON THE STUDIO, started detached by `JOB_SCRIPT=job-2376-publish.sh studio-2376.sh`.
# Stages the abliterated MiniMax M3.1-Flash snapshot (APFS clones of the catalog base row,
# which stays untouched) and publishes it with the Studio's Hugging Face token (#2376).
# PUBLISH_ARGS=--dry-run stages and prints the manifest without contacting Hugging Face.
set -u
LAB=$HOME/lab-2376
JOB=$LAB/job
RES=$LAB/results
VENV=$LAB/venv-vlm
BASE=${BASE:-$(ls -d "$HOME"/lab-2189/models/*[Mm]ini[Mm]ax*oQ3e* 2>/dev/null | head -n 1)}
CATALOG_HASH=21188ee28f031b9444e8a250e16aea57ee37a0c2f8d1a24c2ad44686ad744f03
REPO_NAME=${REPO_NAME:-MiniMax-M3.1-Flash-oQ3e-mtp-abliterated}
log() { echo "$(date -u '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; exit "${2:-1}"; }
log "JOB_START publish base=$BASE"
[ -n "$BASE" ] && [ -f "$BASE/config.json" ] || blocker "no MiniMax oQ3e base row under ~/lab-2189/models" 11
[ -f "$LAB/direction-v1.safetensors" ] || blocker "no saved direction at $LAB/direction-v1.safetensors" 11
[ -f "$RES/ablate/eval.json" ] || blocker "no eval.json from the ablation run" 11
case " ${PUBLISH_ARGS:-} " in *" --dry-run "*) ;; *) [ -n "${EXPECT_STAGE:-}" ] || blocker "a real publish needs EXPECT_STAGE (the parity-tested stage manifest)" 11 ;; esac
case " ${PUBLISH_ARGS:-} " in *" --owner "*) blocker "--owner changes README.md and the stage manifest; publish as the token's user" 11 ;; esac
"$VENV/bin/python" -c "import huggingface_hub, hf_xet" 2>/dev/null || "$VENV/bin/pip" install -q "hf_xet" || blocker "hf_xet install failed" 12
"$VENV/bin/python" -c "import huggingface_hub as h; print('huggingface_hub', h.__version__)"
"$VENV/bin/python" -I "$JOB/publish_abliterated.py" "$BASE" "$LAB/direction-v1.safetensors" "$RES/ablate/eval.json" \
  "$LAB/publish/$REPO_NAME" "$REPO_NAME" --expect-base "$CATALOG_HASH" ${EXPECT_STAGE:+--expect-stage "$EXPECT_STAGE"} ${PUBLISH_ARGS:-} 2>&1 | tee "$RES/publish.log"
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || blocker "publish_abliterated.py exit $rc: $(tail -n 2 "$RES/publish.log" | tr '\n' ' ')" 14
log "JOB_PASS"
