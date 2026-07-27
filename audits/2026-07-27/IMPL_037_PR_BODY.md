## Summary

Implements **SPEC-037 v0.1.1** (spec merged #702; this PR lands the IMPL + a v0.1.1 AC addition): an encrypted, provider-namespaced KV **disk tier behind the shipped `ConversationCache`** so a reusable conversation prefix survives provider process loss (deploy / crash / supervisor relaunch / in-TTL reboot), cutting the restart-driven re-prefill contribution to the buyer-TTFT tail. Pure provider-local **residency-only** optimization — **no wire, receipt, billing, or hot-path semantic change** (FR-KVP1), **default-off**, and **synthetic-key-only** in v0.1 (`allow_buyer_keys=true` is rejected).

## Verification status (read this first)

This feature is **default-off and residency-only**, so merging it **cannot affect production** — the worst case for any defect is a no-op fallback to normal prefill. It reaches no provider until a signed release is built, the updater accepts it, and an operator explicitly enables the tier.

- **Verified now:** design-traced, builds green (debug+release), unit/integration suites green, and a multi-round blind audit loop (below) at 0 C/H/M across code / security / architect / adversarial / product lanes.
- **Deferred to the release-candidate pre-enable gate (NOT a merge blocker):** the end-to-end real-serve persist→restart→restore proof (KVS-01a) cannot run in-place on a dev Mac — a `serve` binary self-re-execs into the *installed* binary (PATH-repair security feature), and a plain `swift build` ships no `mlx.metallib`. The real proof requires a **packaged release install** on a test provider, which is itself the pre-enable gate. This is documented as **AC-10** and gated by FR-KVP13. Nothing is enabled off this merge.

## What landed (phase3-binary, all behind the disabled-by-default flag)
- **Format v1 / Keys / Store** (`KVDiskCacheFormat/Keys/Store.swift`): JCS-canonical manifest as non-circular AEAD associated data; framed AES-256-GCM chunks with per-chunk CSPRNG nonces; per-epoch master + **per-entry DEK** in the Data-Protection Keychain (DEK destruction = rollback-proof revocation authority); durable fail-closed admission; serialized owned purge fences; tombstone-first purge (durable before hot-tier callback); true aggregate staging budget; `KVCacheSimple`-only v1 allowlist.
- **Integration** (`ConversationCache.swift`, `ModelRuntime.swift`): snapshot-at-commit under the per-key lease; lazy promotion into the **existing** LCP/trim predicate; speculative-decode routing determined **before** any cache `begin()`; ingest-provenance synthetic-key gate (`conv:kvs-synth:` + direct-HTTP); **per-request `KVCacheSimple` allocation for tier-eligible requests** (see "Real-serve fix" below), `RotatingKVCache` retained for all buyer traffic.
- **Operator surface** (`ControlSocket.swift`, `KVCacheCommand.swift`, `UninstallCommand.swift`): `kv-cache purge --key-stdin | --all [--forget]` and `kv-cache status`, socket-first with standalone flock fallback; uninstall wired to `purgeAllAndForget`.
- **Config** (`KVDiskCacheConfig.swift`): FR-KVP11 triple-source (YAML/env/CLI), fail-closed on invalid values.
- **KVS-01a harness** (`test/e2e/coldwarm-ttft/`): four-arm restart-survival gate (the RC-stage / AC-10 fixture).

## Audit journey (honest, multi-phase)

The initial five-lane BUILD loop (R1→R5, 3 codex + adversarial + product) drove the store-internal concurrency/durability core to 0 C/H/M through a mid-loop root-cause redesign (durable admission + serialized owned fences + off-actor promotion). **That was not the end of the story** — three later phases found real defects the earlier anchored rounds could not:

1. **Blind unanchored round** (given only the feature + diff, no fix-history): found 3 integration-boundary gaps R5 missed — first-post-restart promotion impossible without a load-time geometry seed (HIGH), disabled-tier purge falsely reporting success without clearing RAM (HIGH), uninstall leaving Keychain DEKs (MEDIUM). All fixed.
2. **Blind re-verify of that fix** caught a HIGH **regression the fix itself introduced**: the disabled-tier socket purge returned `purge_ok` after clearing only RAM, blocking the CLI's standalone disk crypto-shred — so `--forget` left ciphertext + DEKs. Fixed (disabled path now delegates to the standalone shred); re-verify then 0/0/0.
3. **Real-hardware Stage-1 proof** found the feature was a **silent no-op in real serve**: serve always builds `RotatingKVCache`, but the tier only serializes `KVCacheSimple`, so `captureSnapshot` silently returned nil and persisted nothing for *any* standard model. Fixed: per-request `KVCacheSimple` for tier-eligible requests + a `serveCache` helper pinning the invariant + an **observable `disk_write_skipped(unsupported_cache_class)`** (never silent) for `newCache`-overriding families (gpt-oss/gemma-4/nemotron) + an attach-time unsupported-model warning. Two more blind audit rounds converged this to 0 C/H/M.

Every phase after R5 exists because a blind / real-hardware check refused to accept an anchored PASS. The lesson is captured as **AC-10**: the ACs never exercised the real serve cache-allocation path, which is why the silent no-op shipped past R5.

## AC-10 (new in v0.1.1)
Adds a normative acceptance criterion: an eligible request through the ordinary serve paths MUST allocate a serializable `KVCacheSimple` and commit a non-nil snapshot; a non-`KVCacheSimple` runtime MUST fail safe to a miss with an **observable** skip (never silent) + an attach warning. Headless serve-allocation + observable-skip fixtures are required CI tests; the full persist→restart→restore fixture is KVS-01a (RC-stage hardware run, FR-KVP13).

## Verification (mechanical)
- `swift build --package-path phase3-binary` green (debug + release).
- KV/serve/ColdTier/ControlSocket/ServeCommand/ModelRuntime suites green post-rebase onto current main (201+ tests, 0 failures; MLX-Metal / Data-Protection-keychain tests env-gated per the headless baseline).
- FR-KVP1: source diff touches only KV-tier internals + the eligible-request cache-type selection; no buyer `CompletionResult`/`Usage`/receipt/`cached_prompt_tokens`/wire change.

## Carried residual (blocking-before-enable, documented — NOT before-merge)
The KVS-01a real-serve evidence run requires a packaged release install on a test provider (a >32 GB lab Mac for the full perf campaign, standing P0 #584). Per FR-KVP13 the tier MUST NOT graduate past synthetic-key experiments until that passes. The machinery lands here; the tier stays default-off.

## Carried LOW/INFO (documented, non-blocking)
- LOW: a `conv:kvs-synth:` hot-cache key collision from a prior relay request could reuse a `RotatingKVCache` — now fails safe with the observable skip (no silent no-op).
- INFO: `kvBits` quantization mid-generation → eligible long requests skip observably (v1 KVCacheSimple-only limitation, made honest).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

SPEC-GOVERNANCE-DECLARATION-BEGIN
{
  "schema_version": "spec-pr-governance-v1",
  "behavior_change": "yes",
  "contract_change": "yes",
  "issue": "https://github.com/Augustas11/macprovider/issues/614",
  "specs": ["SPEC-037"],
  "requirements": ["SPEC-037-R001", "SPEC-037-R002", "SPEC-037-R003", "SPEC-037-R004", "SPEC-037-R005", "SPEC-037-R006", "SPEC-037-R007", "SPEC-037-R008", "SPEC-037-R009", "SPEC-037-R010", "SPEC-037-R011", "SPEC-037-R012", "SPEC-037-R013"],
  "authority_domains": ["kv-cache-persistence"],
  "arbitration": ["CODE_BUG"],
  "tests": [
    "swift build --package-path phase3-binary (debug + release)",
    "swift test --package-path phase3-binary KV/serve suites (KVDiskCacheStore/Format/Tier/ConversationColdTier/ConversationCache/ControlSocket/ServeCommand/ModelRuntime) — 0 failures",
    "headless serve-cache-allocation helper + observable unsupported_cache_class skip fixtures (AC-10 CI portion)",
    "KVS-01a real-serve harness test/e2e/coldwarm-ttft (AC-10 RC-stage hardware fixture; FR-KVP13 gate)",
    "multi-phase blind audit loop (3 codex + adversarial + product) to 0 C/H/M — prompts under audits/2026-07-23/, audits/2026-07-26/, audits/2026-07-27/"
  ],
  "journeys": ["not-required"]
}
SPEC-GOVERNANCE-DECLARATION-END
