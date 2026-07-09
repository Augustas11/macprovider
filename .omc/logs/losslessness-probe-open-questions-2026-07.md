# SPEC-029 Open Questions

**Date:** 2026-07-09
**Branch:** `feat/losslessness-probe`

These are the human-blocking items before SPEC-029 can move toward LOCK:

1. **Threshold and K approval:** Approve or revise the draft TV thresholds and decide whether v0.1 accepts default `K=64` with `K=256` retry, or requires `K=256` for all stochastic probes.
2. **Prompt corpus owner:** Assign an owner for the normative probe corpus and decide how corpus changes are versioned.
3. **Telemetry surface:** Confirm that out-of-band `losslessness_probe_v1` telemetry is sufficient for v0.1 and that SPEC-015 v0.4 receipts remain unchanged.
4. **Sanction scope:** Decide whether repeated losslessness failures affect only stochastic speculative-decoding eligibility or also general provider readiness.
5. **Operational details:** Decide whether v0.1 needs an HTTP provider-control fallback, set retention/redaction rules for compact top-K evidence, and decide whether a future SPEC-015 v0.5 should bind a recent probe digest.

Self-review result: no product-code changes proposed; SPEC-015 v0.4 receipt tuple and `usage` remain unchanged; SPEC-022 settlement semantics remain unchanged; buyer API remains unchanged; compute-integrity and covert canaries remain out of scope.
