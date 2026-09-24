## Lane: SECURITY / MONEY PATH

Look for:
- Cross-row (cross-buyer) data leakage in batched KV or Mamba state.
- Usage/billing token counts that a buyer or provider could inflate or deflate.
- Receipt and settlement interaction with batched rows and relay error codes
  (`error_queue_full` re-route vs double execution/double charge).
- Whether the lab catalog-readiness waiver can trigger outside the exact lab
  condition.
- Trace/telemetry leaking prompt content.
- Fail-open behavior on bad config.
