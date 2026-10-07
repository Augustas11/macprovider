# Catalog diagnostic rerun — 66c9090ef

The exact-source Studio LAB build and catalog-bound hardware correctness check passed. Cancellation and warm-swap checks now pass, including zero native admissions on the new post-swap request. Serial parity, streaming/stop, and mixed-row capacity checks also passed.

The serving journey still failed the cache-state boundary with `continuous_batching_native_mtp_finalize_failed` (503). Its local self-test passed executed checks but remains partial; coordinator canary and negative outcomes remain uncovered. The subsequent synthetic replay command was not run because the journey failed.

This is correctness-only isolated no-join diagnostic evidence, not performance qualification, signed release evidence, or live activation. The unchanged signed provider was restored and resumed. MTP remains off. Detailed operational logs remain private.
