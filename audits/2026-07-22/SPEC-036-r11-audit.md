# SPEC-036 — Round-11 codex confirmation

**Date:** 2026-07-23 · **Reviewed revision:** `18e5105a`

| Lane | C | H | M |
|---|---:|---:|---:|
| codex code | 0 | 2 | 4 |
| codex security | 0 | 0 | 0 (CLEAN) |
| codex architect | 0 | 1 | 0 |

**Security lane CLEAN (0/0/0).** The remaining HIGHs were two clean bounded gaps:
(1) `retry_of_probe_id` (added to FR-7 in R10) was missing from the closed FR-6
request/result schema — self-inflicted; (2) a new `assigned_id` restarts
`target_generation` at 1 and could alias a stale positive window (window key projects
away assigned_id).

## Fixes
- Added conditional `retry_of_probe_id` to the closed FR-6 request AND result payload
  (present exactly for a K=256 retry, echoing the K=64 `probe_id`; absent otherwise).
- FR-12: an `assigned_id` change MUST atomically invalidate/purge positive window
  state (`verified`/`warn`/`pending`) and outstanding probes while preserving the
  assigned-id-free adverse overlay + accumulators — a re-onboarded provider re-earns
  positive state and can never inherit a stale payable window.

Round-12 confirms; carried MEDIUMs (four-prompt-bound precision, etc.) are documented
residuals per repo audit discipline.
