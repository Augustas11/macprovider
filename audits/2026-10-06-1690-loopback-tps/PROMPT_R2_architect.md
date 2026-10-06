# #1690 M1 fix audit ROUND 2 — lane: architect (single lane only)

Anchored re-audit. Branch fix/1690-loopback-startup-throughput, base origin/main 359f73e43, full combined diff in audits/2026-10-06-1690-loopback-tps/diff-r2.patch (round-1 fix commit is 9fb880247). Read touched files in full.

1. For EACH round-1 finding below, state FIXED / NOT FIXED / PARTIAL with file:line evidence.
2. Then report any NEW issue in the full combined diff for this lane only.

## Round-1 findings for this lane

```text
No CRITICAL or HIGH findings.

- **MEDIUM — incompatible throughput semantics.** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:8219`, `phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:1284`, `phase4-coordinator/internal/buyer/server.go:641`. Native throughput includes prefill/model load; loopback excludes both. The coordinator applies the same field to the hard routing floor and fast-mode ordering (`specs/SPEC-002-coordinator.md:1986`, `2416`). A cold loopback can advertise ~100 TPS while a similarly cold native runtime reports below 1 TPS. Fix: make FR-17’s metric semantically uniform across runtimes, with coordinator documentation/tests matching that definition.

- **MEDIUM — chunk-count fallback is used as an authoritative probe rate.** `phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:599`, `:1360`. When upstream usage is absent, `deltaEvents` counts SSE chunks, not tokens. Existing tests explicitly model plain mlx_lm/oMLX-style chunks without usage (`OpenAICompatibleLoopbackRuntimeTests.swift:479`, `:1485`). Identical output can therefore pass or fail the coordinator floor based only on chunking. Fix: require authoritative usage/timing/tokenizer counts; return zero when unavailable instead of using the display-only fallback.

- **MEDIUM — deploy verification does not validate the artifact actually uploaded.** `phase4-coordinator/dist/deploy-pearl-vps.sh:607`, `:701`, `:1795`, `:3513`; `phase4-coordinator/dist/test/check_nginx_model_admission_routes_test.sh:8`. The new test is wired into `make test-dist` (`Makefile:199`), but Pearl deploy only runs the catalog-route check and uploads `PINNED_DIST_DIR`’s vhost. A stale pinned vhost can therefore ship without the model-admission route and reproduce the 404 incident. Fix: parameterize the route test by config path and run it against `$NGINX_SITE` before upload.

- **LOW — probe timestamps are data-event timestamps, not token timestamps.** `phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:1342`, `:1398`. Role-only, finish, and usage-only SSE events update `firstDataAt`/`lastDataAt`; the fixture contains all of these (`OpenAICompatibleLoopbackRuntimeTests.swift:1758`). Delayed metadata or an initial role event changes the reported decode rate. Fix: timestamp only content-bearing events or use upstream timing metadata.

- **LOW — probe contract is still coupled to concrete runtime types and duplicates the prompt.** `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:2733`, `:2738`; `ModelRuntime.swift:13`, `:8226`; `OpenAICompatibleLoopbackRuntime.swift:1295`, `:1301`. The token budget is shared, but the prompt and measurement contract are duplicated, and `ServeCommand` downcasts the existential to two concrete actors. A new conforming runtime can serve successfully yet silently report zero throughput. Fix: introduce a shared probe specification/measurer protocol and dispatch through it.

Focused nginx test passed; `git diff --check` passed.

C=0 H=0 M=3 L=2



## Lane focus
Architecture: is a CLI-side probe the right layer vs coordinator floor semantics; single source of truth for the probe constant/semantics shared with native ModelRuntime; coupling between MacProviderCLI serve wiring and the runtime actor; SPEC-001 FR-20/FR-17 amendment consistency with SPEC-002 routing and SPEC-046/SPEC-010 loopback SPECs; whether the nginx template + test are the right durable home (vs deploy tooling) and consistent with existing route tests.

## Output
Severity CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line, failure scenario and fix; only verified issues. End with one line: "C=<n> H=<n> M=<n> L=<n>" counting OPEN issues only.
