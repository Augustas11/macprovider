# SPEC-028 Open Questions

**Date:** 2026-07-05
**Branch:** `research/spec-decode-serve`

These are the human-blocking items before SPEC-028 can move toward LOCK:

1. **gpt-oss draft candidate:** Confirm whether a smaller same-tokenizer, license-clean draft exists for `mlx-community/gpt-oss-20b-MXFP4-Q8`, or waive gpt-oss from v0.1 compatibility requirements.
2. **Greedy-only gate:** Decide whether v0.1 may restrict spec decode to `temperature=0.0`, with stochastic requests falling back to the existing path.
3. **SPEC-011 amendment boundary:** Decide whether draft model hash must appear in heartbeat, or whether `spec_decode_draft_model_id` plus acceptance counters is sufficient.
4. **Model-card approval:** Confirm Qwen and Llama draft-target candidate pairs are acceptable for the static catalog under their respective licenses.
5. **LOCK canary threshold:** Approve the first canary threshold: Qwen2.5-Coder 7B + 1.5B draft on air5, `code_completion`, median generation throughput >= 24 tok/s and acceptance rate >= 0.35.

Self-review result: no code changes proposed; SPEC-015 usage remains unchanged; buyer API remains unchanged; coordinator routing remains unchanged. Main unresolved risk is compatibility evidence for gpt-oss and Qwen3 behavior under current upstream MLX-LM reports.
