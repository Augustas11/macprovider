codex
Architecture audit complete. No new C/H/M findings.

- FR-CB10 is fail-closed: accepted tuples require model/cache/KV/MoE/hardware plus `metallib_sha256` and `kernel_identifier` ([Config.swift:33](/Users/augstar/macprovider-ac25-m2/phase3-binary/Sources/MacProviderCore/Config.swift:33), [ContinuousBatching.swift:320](/Users/augstar/macprovider-ac25-m2/phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift:320)).
- FR-PKV13 is correctly delegated to operator acceptance coverage bound to the measured runtime revision; no unsafe startup microbenchmark gate was added.
- Canary serial-routes unsupported, uncovered, cached-hit, or unrepresentable requests. `off` remains inert. First-turn hybrid scope is enforced.
- Queue/cache knobs are bounded and correctly coupled; rollback is `continuous_batching: off` plus provider restart/reload. With 8 seats, unset queue limit resolves to 16.
- SPEC versions match `CONFORMANCE.json`; `AUTHORITY.json` mappings are consistent and unchanged.
- #1713 merge preserved batching status, queue-wait plumbing, served-slot sizing, and `error_queue_full` mappings.
- Existing tests passed: 5 probe, 98 config, 31 bridge, 2 mixed-cache, 79 scheduler, 2 relay, and 40 receipt tests. Existing MLX skips remained host-related.

Carried observation confirmed, not introduced by this diff: `.on` has no Gate A5 predicate ([ContinuousBatching.swift:350](/Users/augstar/macprovider-ac25-m2/phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift:350)). Enabling `.on` before A5 could expose the shared path without economics promotion evidence; add that gate before production-default promotion. The live rollout is `canary`, so this is not active in the stated deployment.

No new malformed payloads or tests were constructed.

VERDICT: PASS
