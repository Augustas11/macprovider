# Takeover catalog diagnostic — 2026-10-07

The exact source-bound LAB binary built and passed the catalog-target hardware correctness check on the designated Studio. The isolated serving journey **failed**. This record is not performance qualification, a complete serving/release journey, signed release evidence, or live activation.

The hardware check observed three admissions, batch depth two, and serve-path verification. The serving journey passed the serial oracle, streaming/stop, and mixed-row capacity checks. Cache-state boundary and phase cancellation encountered `continuous_batching_native_mtp_observer_failed` (503). Warm swap published native capability as disabled, but the subsequent request still recorded a native admission and counters. These findings require fixes and fresh physical reruns.

The provider-local self-test passed its executed checks but remains partial because the coordinator-issued canary and negative outcomes were not exercised by this command. The unchanged signed live provider was restored and resumed after the diagnostic. Native MTP remains off.

`source-binding.json` binds the source and built LAB bytes. `hardware-result.json` preserves the hardware result; `journey-checks.json` preserves every executed check and uncovered clause. Detailed operational logs remain private.
