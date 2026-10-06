
```text
Scope audited: only `git diff origin/main...HEAD` / `diff-r3.patch`. Excluded unrelated working-tree changes and `ops/pearl-updater`.

- HIGH — FIXED — `OpenAICompatibleLoopbackRuntime.swift:1388-1394` uses upstream usage or `timings.predicted_n`; chunk count is not authoritative. No-usage coverage: `OpenAICompatibleLoopbackRuntimeTests.swift:1985-2001`. Forged/chunk-only counts no longer inflate TPS.

- MEDIUM — FIXED — Request timing starts before stream opening and ends after accumulation at `OpenAICompatibleLoopbackRuntime.swift:1358,1388-1399`. Arithmetic tests: `OpenAICompatibleLoopbackRuntimeTests.swift:1919-1983`.

- MEDIUM — FIXED — Identity is checked before and after probing at `OpenAICompatibleLoopbackRuntime.swift:1328-1335`; llama `/props` validation is at `1343-1348`. Reload coverage: `OpenAICompatibleLoopbackRuntimeTests.swift:2031-2062`.

- MEDIUM — FIXED — Caller cancellation reaches `bounded` with `cancelWithCaller: true` at `OpenAICompatibleLoopbackRuntime.swift:1830-1863`; stream termination cancels the reader/session at `304-370`. Coverage: `OpenAICompatibleLoopbackRuntimeTests.swift:2117-2132`.

- LOW — FIXED — Non-2xx responses close the stream at `OpenAICompatibleLoopbackRuntime.swift:1367-1369`; `closeLines` terminates the iterator at `1435-1441`. Coverage: `OpenAICompatibleLoopbackRuntimeTests.swift:2094-2100`.

- LOW — PARTIAL / OPEN — Tests still do not exercise production `LoopbackServeHTTPClient.postLines` / `URLSession.AsyncBytes` at `OpenAICompatibleLoopbackRuntime.swift:304-372`, selected through `openLines` at `1896-1904`. Success/no-usage tests use the buffered stub, while cleanup tests use custom streaming fakes. Add URLProtocol or local HTTP streaming coverage.

- INFO — FIXED — SPEC-001 limits standalone `self-test` to the native MLX probe at `specs/SPEC-001-phase3-binary.md:1639-1650`, matching `MacProviderCLI.swift:3966-3979`.

No new code-lane issues found. Validation passed: targeted Swift tests 77/77, contract-lock tests 16/16, nginx route test, shell syntax checks, and diff whitespace check.

C=0 H=0 M=0 L=1


