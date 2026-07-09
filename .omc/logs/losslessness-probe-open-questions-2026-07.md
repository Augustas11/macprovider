# SPEC-029 Open Questions

**Date:** 2026-07-09
**Branch:** `feat/losslessness-probe`

These are the remaining maintainer-input items before SPEC-029 can move toward LOCK:

1. **Retention TTL:** Decide whether the default 30-day compact-evidence retention TTL should be shorter for public beta.
2. **Future receipt binding:** Decide whether a future SPEC-015 v0.5 should bind a recent losslessness probe digest, without changing v0.4.
3. **Maintainer approval:** MacProvider SPEC Maintainers must approve the v0.1 corpus, threshold table, calibration process, and SPEC-028 rollout consumer rule before LOCK.

Self-review result: no product-code changes proposed; SPEC-015 v0.4 receipt tuple and `usage` remain unchanged; SPEC-022 settlement semantics remain unchanged; buyer API remains unchanged; compute-integrity and covert canaries remain out of scope.
