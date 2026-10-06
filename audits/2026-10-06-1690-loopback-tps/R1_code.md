
```text
Findings:

- HIGH — `phase3-binary/Sources/macprovider-cli/OpenAICompatibleLoopbackRuntime.swift:601,735,1361-1367`  
  If upstream omits usage, `completionTokens` becomes `deltaEvents`, which counts chunks rather than tokens. The same result is marked `usageUnattested`, but the probe uses it for routing throughput. Chunking can therefore over/understate TPS and clear the 1 TPS floor incorrectly. Fix: require trusted token evidence or return `no_tokens`; add a no-usage streaming test.

- MEDIUM — `OpenAICompatibleLoopbackRuntime.swift:1343-1346,1364-1365`  
  Decode-window timestamps are recorded for every non-`[DONE]` data event, including role-only, finish, and usage-only chunks. Prefill or post-generation delay can enter the “token” window. Fix: timestamp only token-bearing events returned by the accumulator and test spaced role/content/usage chunks.

- MEDIUM — `OpenAICompatibleLoopbackRuntime.swift:1298,1718-1726`  
  The startup probe checks local identity but skips llama.cpp’s upstream `/props` identity check implemented at `1487-1503`. If llama-server reloads another GGUF at the same origin, throughput from the wrong model is advertised under the bound hash. Fix: perform the llama `/props` artifact check immediately before probing, and revalidate after completion.

- MEDIUM — `OpenAICompatibleLoopbackRuntime.swift:1313-1316,1780-1795`  
  `bounded` has no caller-cancellation handler. Cancelling serve during a slow startup probe leaves the continuation waiting until the 60-second deadline, with the worker/upstream request not promptly cancelled. The test only verifies deadline cancellation. Fix: propagate caller cancellation to the worker and upstream stream.

- LOW — `OpenAICompatibleLoopbackRuntime.swift:1334-1336,343-370`  
  A non-2xx response returns before consuming or explicitly closing `response.lines`. With a persistent/slow error body, the reader and URLSession can remain active until their backstop timeout. Fix: explicitly cancel/drain the response stream on status failure.

- LOW — `phase3-binary/Tests/macprovider-cliTests/OpenAICompatibleLoopbackRuntimeTests.swift:1770-1811,1871-1883`  
  Successful probe tests use the buffered-only stub; the production `LoopbackServeHTTPClient.postLines` path is not exercised. The streaming timeout test uses a custom fake, so it cannot catch the timestamp, no-usage, caller-cancellation, or non-2xx cleanup defects. Fix: add a URLProtocol/local streaming test covering those paths.

- INFO — `specs/SPEC-001-phase3-binary.md:1628-1630`; `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:3966-3976`  
  SPEC-001 says standalone `self-test` runs the same probe, but `SelfTestCommand` always instantiates `ModelRuntime`; it never selects `OpenAICompatibleLoopbackRuntime`. A loopback self-test therefore cannot exercise the new upstream probe. Fix: clarify the spec as MLX-only or add loopback runtime selection.

The nginx location and static route test are correct; targeted probe tests, the arithmetic test, the nginx test, and `git diff --check` passed.

C=0 H=1 M=3 L=2


