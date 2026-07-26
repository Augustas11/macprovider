# BLIND independent audit — ARCHITECT lane

You are auditing a feature branch before it merges to `main`, in the git worktree that is your current working directory (branch `impl/233-kv-survival`). Review the code on its own merits, first-principles — this is a fresh independent review, not a re-check of anything.

**Feature:** SPEC-037 — an encrypted, provider-local **KV-cache disk tier** layered behind the in-RAM `ConversationCache` in a P2P Mac LLM-inference provider. Goal: a reusable conversation KV prefix survives provider process restart (deploy/crash/relaunch), cutting re-prefill latency. The normative contract is `specs/SPEC-037-kv-survival-restart.md` — **read it fully first**; it defines the on-disk format, the strict match/validation envelope, the per-provider namespace/quota model, the purge/revocation primitive, promotion into RAM, and the residency-only invariant.

**Scope:** the full diff `git diff origin/main...HEAD` (three-dot). Core new files in `phase3-binary/Sources/macprovider-cli/`: `KVDiskCacheStore.swift` (the store actor), `KVDiskCacheFormat.swift`, `KVDiskCacheKeys.swift`, `KVConversationColdTierAdapter.swift`, `ConversationColdTier.swift`, `KVDiskTier.swift`, `KVCacheCommand.swift`, and `MacProviderCore/KVDiskCacheConfig.swift`. Integration edits: `ConversationCache.swift`, `ModelRuntime.swift`, `ControlSocket.swift`, `HTTPServer.swift`, `InferenceRelay.swift`, `ChatCompletionRequest.swift`, `MacProviderCLI.swift`. Tests in `phase3-binary/Tests/macprovider-cliTests/` and the harness in `test/e2e/coldwarm-ttft/`.

**What matters (security-sensitive):** the tier holds a provider-side **purge/revocation** primitive (a buyer/operator must be able to make a cached prefix unrecoverable), **encrypted-at-rest** KV with per-provider key isolation, per-provider quotas, and it must be **residency-only** — no change to buyer wire/receipt/billing semantics or the `cached_prompt_tokens` computation. It is disabled-by-default and (per spec) persists only provider-owned synthetic keys in v0.1. It is heavily concurrent (a Swift `actor` with off-actor work, async writers, restart recovery).

Build/test freely: `swift build --package-path phase3-binary`; `swift test --package-path phase3-binary --filter <suite>`. Report only defects you can substantiate with file:line + a concrete failing scenario + a fix. Rate each CRITICAL / HIGH / MEDIUM / LOW / INFO and apply a realist severity check.

## Lane focus: architecture & spec fidelity
- Does the implementation faithfully honor the spec's boundaries — residency-only (no receipt/billing/wire change), hot-tier behavior unchanged for non-gated keys, promotion under the existing reuse predicate (no second predicate), the safety envelope, the purge ship-blocker?
- Concurrency/durability model soundness: is the admission/revocation model coherent and correct across in-process failure AND restart, or are there structural gaps?
- Lifecycle wiring: serve activation/dormancy/shutdown, control-socket vs standalone CLI, config surface.
- Is v0.1 buildable/operable as the spec intends, and are residuals correctly scoped vs violating a normative MUST?

End with exactly one line:
VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO
PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
