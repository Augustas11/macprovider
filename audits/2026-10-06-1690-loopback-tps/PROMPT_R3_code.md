# #1690 M1 fix audit ROUND 3 (final) — lane: code (single lane only)

Anchored re-audit. Branch fix/1690-loopback-startup-throughput. The branch's own change set is ONLY the three-dot diff vs main: audits/2026-10-06-1690-loopback-tps/diff-r3.patch (= git diff origin/main...HEAD). Round-2 fix commit is beeb86b51 (after merge 26106d9b9 of origin/main). Read touched files in full. Do NOT audit code that is not in diff-r3.patch.

Note: the round-2 security lane's two Pearl-updater findings came from a stale two-dot diff that showed main's own #1861 in reverse; ops/pearl-updater is not changed by this branch and is out of scope.

1. For EACH round-2 open finding below, state FIXED / NOT FIXED / PARTIAL with file:line evidence.
2. Then report any NEW issue in diff-r3.patch for this lane only.

## Round-2 output for this lane

```text
Result: 6 findings are fixed; 1 LOW remains partially fixed. No new code-lane defects found.

- HIGH — FIXED — `OpenAICompatibleLoopbackRuntime.swift:1377-1379` uses only upstream usage or `timings.predicted_n`; chunk count is excluded. No-usage coverage is present at `OpenAICompatibleLoopbackRuntimeTests.swift:1892-1907`.

- MEDIUM — FIXED — `OpenAICompatibleLoopbackRuntime.swift:1348,1375,1380-1384` measures total request elapsed time, eliminating event-window contamination. Arithmetic coverage is at tests `1843-1889`.

- MEDIUM — FIXED — identity is checked before and after probing at `OpenAICompatibleLoopbackRuntime.swift:1322-1325`; llama `/props` validation is in `1334-1338`. Tests cover reload-before/after behavior at `OpenAICompatibleLoopbackRuntimeTests.swift:1938-1968`.

- MEDIUM — FIXED — caller cancellation is propagated through `bounded` at `OpenAICompatibleLoopbackRuntime.swift:1811-1844`, with stream termination handled at `304-370`. Cancellation coverage is at tests `2024-2038`.

- LOW — FIXED — non-2xx responses call `closeLines` at `OpenAICompatibleLoopbackRuntime.swift:1357-1359`; termination is implemented at `1416-1422`. Test coverage: `OpenAICompatibleLoopbackRuntimeTests.swift:2001-2007`.

- LOW — PARTIAL / OPEN — tests cover the custom streaming protocol, but still do not exercise production `LoopbackServeHTTPClient.postLines` / `URLSession.AsyncBytes`. Successful and no-usage tests use the buffered stub at `OpenAICompatibleLoopbackRuntimeTests.swift:1799`, `1836`, `1904`; streaming cleanup tests use custom fakes at `1427-1480`. The production branch is `OpenAICompatibleLoopbackRuntime.swift:1877-1885`. Add a URLProtocol or local HTTP streaming test.

- INFO — FIXED — SPEC-001 now explicitly limits standalone `self-test` to the native MLX probe at `specs/SPEC-001-phase3-binary.md:1639-1642`, matching `MacProviderCLI.swift:3966-3979`.

New issues: none found in the code lane. Nginx route validation passed; targeted Swift tests passed: 74/74.

C=0 H=0 M=0 L=1



## Lane focus
Correctness and semantics: probe arithmetic (predicted_per_second precedence, decode-window vs fallback), timeout/cancellation and upstream stream closure, identity check before probing, failure reason codes, that probe tokens never reach usage/billing/request counters, warm-swap/restart behaviour, SPEC-001 text vs code drift, test adequacy (do the tests exercise the real code paths), nginx block correctness and ordering, the new test's ability to fail.

## Output
Severity CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line, failure scenario and fix; only verified issues. End with one line: "C=<n> H=<n> M=<n> L=<n>" counting OPEN in-scope issues only.
