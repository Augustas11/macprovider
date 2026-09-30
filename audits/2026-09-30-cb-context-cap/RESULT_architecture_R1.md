
### HIGH — The provider hard-codes a gateway-owned, not-yet-merged limit

[ContinuousBatchScheduler.swift:263](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:263) fixes the implicit budget at `32_768`, claiming it matches SPEC-006. On this branch, however:

- SPEC-006 still says the default is 4096: [SPEC-006:1677](/Users/augstar/macprovider-cb-context-cap/specs/SPEC-006-buyer-api.md:1677).
- Gateway code defaults to 4096: [config.go:428](/Users/augstar/macprovider-cb-context-cap/phase5-gateway/internal/config/config.go:428).
- The gateway reserves against its configured value but forwards the original body with `max_tokens` still omitted: [chat_proxy.go:339](/Users/augstar/macprovider-cb-context-cap/phase5-gateway/internal/router/chat_proxy.go:339), [chat_proxy.go:500](/Users/augstar/macprovider-cb-context-cap/phase5-gateway/internal/router/chat_proxy.go:500), [chat_proxy.go:643](/Users/augstar/macprovider-cb-context-cap/phase5-gateway/internal/router/chat_proxy.go:643).
- The 32k change exists only on sibling commit `1ba9aa3d0`; it is not an ancestor of this branch.

Failure scenario: after a clean gateway deployment or rollback using `origin/main`, an omitted request reserves 4096 output tokens while CB may generate up to 32768. The gateway can then classify honest provider usage as exceeding `max_tokens`, emit `stream_output_exceeded`, or reject the non-streaming provider response. This crosses the quota, deadline, streaming, and settlement boundaries.

Fix: make the gateway the sole authority. Land the SPEC-006/#1801 change first and canonicalize omitted `max_tokens` into one effective value before reservation, hashing, deadline calculation, and forwarding. Remove the provider’s independent 32768 constant; direct-provider requests should retain the SPEC-001 default.

### HIGH — “No receipt” contradicts the governing SPEC-015 contract

The new path explicitly marks the error non-settling/no-receipt at [ContinuousBatchScheduler.swift:1419](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1419), and SPEC-038 repeats “Non-settling; no receipt” at [SPEC-038:1079](/Users/augstar/macprovider-cb-context-cap/specs/SPEC-038-continuous-batching.md:1079).

SPEC-015 requires settlement-eligible providers returning `error_context_exceeded` to issue a signed zero-token error receipt: [SPEC-015:1854](/Users/augstar/macprovider-cb-context-cap/specs/SPEC-015-receipts.md:1854). The direct HTTP implementation currently constructs error receipts only for `model_not_loaded`, so the new rejection cannot comply: [HTTPServer.swift:1902](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1902).

Failure scenario: the provider receives and rejects a request, but the buyer gets no cryptographic acknowledgement, making the result indistinguishable from a coordinator-side preflight rejection. Financial treatment remains zero-credit/zero-debit, but receipt treatment is wrong.

Fix: preserve zero settlement while issuing the SPEC-015 §7.6 error receipt for non-streaming settlement-eligible direct and relay requests. Change SPEC-038 to say “zero credit/debit; receipt per SPEC-015,” not “no receipt.”

### MEDIUM — Explicit overflow behaves differently in serial and CB modes

The scheduler rejects `prompt + explicit max_tokens > context` at [ContinuousBatchScheduler.swift:1687](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:1687), describing this as “the serial path’s 413.”

The serial path only checks `prompt <= context`: [ModelRuntime.swift:8691](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:8691). SPEC-001 likewise constrains explicit `max_tokens` only to be positive: [SPEC-001:2057](/Users/augstar/macprovider-cb-context-cap/specs/SPEC-001-phase3-binary.md:2057).

Failure scenario: the same request returns 413 on a CB-enabled provider but enters generation on a serial provider or after permissive fallback. Routing or operator mode therefore changes API validity.

Fix: define one shared prompt-plus-output validation before choosing serial versus CB, enforce it on both paths, and update SPEC-001 accordingly.

### MEDIUM — The implicit cap reports false natural completion and fails at a full prompt

[ModelRuntime.swift:5420](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5420) changes omitted `max_tokens` from SPEC-001’s “remaining context capacity” to at most 32768. When that internal budget is exhausted, [ModelRuntime.swift:5559](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5559) deliberately reports `finish_reason: stop`, not `length`.

Additionally, when `promptTokens == maxContextTokens`, the formula returns one token because of `max(1, …)`, after which the scheduler rejects it. This contradicts SPEC-038’s statement that an omitted value “always fits” and “never trips this on its own.”

Failure scenario: a long reasoning response is truncated at 32768 yet reported as naturally complete; a prompt exactly at capacity self-rejects despite the specification claiming otherwise.

Fix: have the gateway forward its effective budget explicitly so exhaustion reports `length`. For direct-provider omission, retain remaining-context semantics and uniformly reject prompts with no room for at least one output token.

### MEDIUM — Conformance traceability was not updated

SPEC-038 says this lifecycle overlay binds R001/R006/R009/R013/R015, but the corresponding entries remain empty or stale, for example [CONFORMANCE.json:4365](/Users/augstar/macprovider-cb-context-cap/specs/CONFORMANCE.json:4365), [CONFORMANCE.json:4454](/Users/augstar/macprovider-cb-context-cap/specs/CONFORMANCE.json:4454), and [CONFORMANCE.json:4580](/Users/augstar/macprovider-cb-context-cap/specs/CONFORMANCE.json:4580). SPEC-039-R002 also remains an empty “future implementation” entry despite the allocator/context integration: [CONFORMANCE.json:4655](/Users/augstar/macprovider-cb-context-cap/specs/CONFORMANCE.json:4655).

Failure scenario: governance tooling cannot trace the new 413, relay mapping, context-cap, parity, and paged-capacity tests to their governing requirements; release review sees v0.3.4 but no evidence mapping.

Fix: add the new implementation and test anchors to the named SPEC-038 requirements and SPEC-039-R002. Keep production state pending until campaign evidence exists.

### INFO — A signed CLI release and Mac Studio campaign are required

This changes shipped Swift behavior while `binaryVersion` remains `1.8.207`: [CoordinatorClient.swift:423](/Users/augstar/macprovider-cb-context-cap/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:423). SPEC-038 requires packaged real-serving proof and a separate reviewed release: [SPEC-038:1092](/Users/augstar/macprovider-cb-context-cap/specs/SPEC-038-continuous-batching.md:1092).

Required ordering:

1. Land and deploy the gateway effective-budget/source-of-truth change.
2. Merge this provider fix, cut a new signed CLI release, and validate asset identity.
3. Run packaged streaming and non-streaming direct/relay cases on the designated Mac Studio, including omitted, near-cap, explicit-overflow, finish-reason, receipt, and settlement cases.
4. Deploy the released CLI, then enable CB. Roll back CB/provider before rolling back the gateway limit.

The coordinator’s existing FR-27 mapping is correct, and SPEC-039 FR-PKV2’s default-pool sizing is directionally aligned with this patch.

Static validation passed: `git diff --check` and `jq empty specs/CONFORMANCE.json`. No local build or hardware tests were run due the MacProvider host boundary.

VERDICT: C=0 H=2 M=3 L=0
