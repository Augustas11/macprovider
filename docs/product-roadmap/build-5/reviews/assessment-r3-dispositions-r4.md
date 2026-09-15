# Product Build 5 assessment R3 finding dispositions

Date: 2026-09-11

Source review: `assessment-r3-sol.md`

Source review SHA-256:
`a58ae2d50e854221fbba61b9bc5905b8b05b4585d43db7f4e8c5146430134267`

Correction revision: assessment/evidence/benchmark/checkpoint R4

This record does not approve R4. A fresh independent GPT-5.6 Sol reviewer must
recompute the committed R4 digests, inspect the governing code and specs, and
report zero Critical, High, and Medium findings before the assessment gate
passes.

| Finding | R4 correction | Disposition |
|---|---|---|
| H1 memory calibration under-specified | `test-benchmark-spec.md` now requires exactly five dry runs across five clean worker starts. Each start records a ten-minute unloaded host window, loads the immutable artifact, performs five fixed warm-ups, waits for 60 seconds nominal/fair, and selects maxima from exactly 600 paired 100 ms loaded-idle samples. Each run's process peak is the maximum of sampled physical footprint and `ri_lifetime_max_phys_footprint`; its delta uses its own loaded-idle baseline, and the campaign takes `max_i` plus the analytical KV floor. Failures are retained and block promotion. Platforms without the lifetime counter add a fixed separate polling-gap allowance and remain development-only. | Corrected without weakening memory or pressure gates. |
| M1 incomplete loader-byte identity | R4 requires a dedicated read-only APFS adoption image containing the entire model snapshot, signed runtime package, and campaign directory; exhaustive recursive enumeration of every regular model/tokenizer/template/resource file; transitive shard checks; executable/metallib/dependency/runtime selector and non-platform Mach-O closure; normalized canonical paths; and pre/post image, mount, identity, and content recapture. Symlinks, custom/remote code, network fallback, missing/unreferenced shards, undeclared selectors, and mutation fail closed. | Corrected; caller declarations cannot omit bytes the loader may consume. |
| M2 non-reproducible disturbance/reference workloads | R4 names and fully shapes `REF-TTFT-512-R1`, `SLOW-CONSUMER-500-R1`, `CANCEL-2000-R1`, three warm-swap cells, three whole-batch failure cells, and three row-extension failure cells. It fixes prompt/output rotations, arrivals, concurrency authority, counts, starts, injection boundaries, request/cell timeouts, and retained outcomes. MSB-01 requires 100 valid runs and aggregate-TG coefficient of variation at most 10% before it can be a denominator. | Corrected; promotion workloads and references are preregisterable and reproducible. |
| M3 arbiter liveness unbounded | R4 scopes starvation freedom to terminating or fenced execution and fixes 120-second forward, 900-second granted-request execution, atomic opposite-mode admission closure with 250 ms acknowledgement, 250 ms queued-cancel, 5-second active-cancel, 1-second quiescent handoff, 30-second quiescent drain, 10-second worker fence, 906-second healthy grant, and 920-second total disposition bounds. Overrun fails the generation, prohibits lease/model reuse, and requires worker exit or supervision termination. Virtual-clock and shortened real-runtime tests prove no late output or unsafe swap. | Corrected; mutual exclusion now has an executable wall-clock liveness contract. |

No runtime, scheduler, configuration, conformance, release, hardware,
procurement, remote-transfer, or production-enablement change is part of R4.
