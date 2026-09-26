# #1690 freeze audit (PR #1719): common brief

**Method constraint.** This is a first-party software-correctness review. Do NOT author malformed payloads or exploit inputs. Evaluate by reading the source and running EXISTING tests only if needed. Describe any gap abstractly, in prose.

**Scope.** The FULL diff `git diff origin/main...HEAD`: 42 files, 8 code/docs commits plus audit prompts.
- **M0:** the `msb-loopback` and `msb-perplexity` harness, `msb-throughput` report fields, and the runner script `phase3-binary/scripts/bench-1690-loopback-vs-native.sh`, which can opt-in pause a live provider through its control socket.
- **M1** (`phase4-coordinator`):
  - SPEC-042-R006 route-snapshot labels (`manifest_version`, `manifest_core_digest`), digested only when non-empty
  - a separate settlement pool-label verdict (`settlement_pool_labels.go`) with `label_disputed`
  - rejection of candidate-env pools on production-activated coordinators (promotion and routing)
  - on-call readiness inside `validatePromotion`
  - a new required `production_activation.root_custody_classes` config
- **M2** (`phase3-binary`):
  - `OllamaLoopbackRuntime` becomes `OpenAICompatibleLoopbackRuntime` (`ollama:` + `llamacpp:`)
  - streaming, cancel, full forwarding, tool calls, preflight and timeouts
  - loopback stays non-earning (`isSettlementReceiptEligible=false`)
  - `HTTPServer.swift` now passes `shouldCancel` to ALL local streams, including native MLX

**Invariants:**
- Global (poolless) route-snapshot digests are byte-identical.
- No money-path arithmetic change.
- A disputed label never attributes pool usage.
- The loopback runtime never signs receipts.
- Coordinators without `production_activation` keep the current behavior.
- The runner never touches a provider unless `PAUSE_PROVIDER_SOCKET` is explicitly set, and always resumes it.

**Output format.** Numbered findings. Each has a severity (CRITICAL/HIGH/MEDIUM/LOW), file:line, the failure scenario, and a fix. End with exactly one line: `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
