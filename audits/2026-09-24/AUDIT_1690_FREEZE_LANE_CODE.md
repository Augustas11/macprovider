Read `audits/2026-09-24/AUDIT_1690_FREEZE_COMMON.md` first.

**Lane: code correctness.** Check:
- concurrency (actor isolation, Sendable, cancellation races in the streaming proxy and watchdog)
- error mapping and the timeouts
- SSE parsing edge cases
- the preflight arithmetic
- the migration and nullable columns in `settlement_pool_labels`
- golden-digest stability
- test adequacy for each behavior change
- shell correctness of the runner under bash 3.2 with `set -euo pipefail`

For the native-MLX effect of `HTTPServer.shouldCancel`: what does a client disconnect now do to usage, receipts and billing of a partially streamed native response? Is that consistent with the relay (coordinator) path?
