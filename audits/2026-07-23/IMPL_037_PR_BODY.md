## Summary

Implements **SPEC-037 v0.1.0** (merged #702): an encrypted, provider-namespaced KV **disk tier behind the shipped `ConversationCache`** so a reusable conversation prefix survives provider process loss (deploy / crash / supervisor relaunch / in-TTL reboot), cutting the restart-driven re-prefill contribution to the buyer-TTFT tail. Pure provider-local **residency-only** optimization — **no wire, receipt, billing, or hot-path semantic change** (FR-KVP1), **default-off**, and **synthetic-key-only** in v0.1 (`allow_buyer_keys=true` is rejected; buyer-key persistence is gated on future coordinator purge propagation).

### What landed (phase3-binary, all behind the disabled-by-default flag)
- **Format v1** (`KVDiskCacheFormat.swift`): JCS-canonical manifest as non-circular AEAD associated data (blob hash excluded, structural fast-fail), framed AES-256-GCM chunks with per-chunk CSPRNG nonces, self-delimiting payload codec with the exact `decoded_length` geometry equation, closed field/bounds validation before allocation, `KVCacheSimple`-only v1 allowlist.
- **Keys** (`KVDiskCacheKeys.swift`): per-epoch master + **per-entry DEK** in the Data-Protection Keychain; HKDF-SHA256 index keys; epoch-rotation intent journal; DEK destruction is the rollback-proof revocation authority.
- **Store** (`KVDiskCacheStore.swift`, actor): durable fail-closed admission derived from on-disk incomplete-tombstones + rotation journals; serialized owned purge fences; tombstone-first purge (tombstone+HWM durable **before** the hot-tier callback); shared-DEK-across-generations; throwing fsync so `disk_write_committed` cannot lie; streaming seal + two-pass streaming read under a true aggregate staging budget; full-artifact quota accounting + bounded crash-tolerant usage journal; retryable Keychain dormancy; per-namespace quota, free-space floor, retention/compaction.
- **Integration** (`ConversationCache.swift`, `ModelRuntime.swift`): snapshot-at-commit under the per-key lease (immutable deep copy + full envelope identity); lazy promotion into the **existing** LCP/trim predicate (no second predicate); purge hot-callbacks fencing outstanding lease commits; speculative-decode routing determined **before** any cache `begin()` on both endpoints (also fixes a latent stuck-busy-key bug); ingest-provenance synthetic-key gate (`conv:kvs-synth:` + direct-HTTP).
- **Operator surface** (`ControlSocket.swift`, `KVCacheCommand.swift`): `macprovider-cli kv-cache purge --key-stdin | --all [--forget]` and `kv-cache status`; socket-first (lock-holder executes) with standalone flock fallback.
- **Config** (`KVDiskCacheConfig.swift`): FR-KVP11 triple-source table (YAML/env/CLI), fail-closed on invalid values, enable-time notice + free-space headroom.
- **KVS-01a harness** (`test/e2e/coldwarm-ttft/`): four-arm restart-survival gate (restored / warm-repeat / disk-disabled / disk-enabled-miss), genuine-second-turn warm control, §6 evidence recording, production fence. Delivered as syntax-valid capability — see residual below.

### Audit convergence (five lanes, four rounds — 3 codex + adversarial verificator + product critic)
| Round | Aggregate | Outcome |
|---|---|---|
| R1 | 2 C / 14 H | purge not wired to hot tier; snapshot-vs-live-trim race; identities fabricated |
| R2 | 1 C / 8 H | purge hot-only + suspension-window gaps; write budget/streaming cosmetic |
| R3 | 2 C / 4 H | purge-fence failure-path fail-open + no fence ownership — **recurrence signalled a wrong model** |
| Redesign | — | root-cause: durable admission state + serialized owned fences + true aggregate budgets + off-actor promotion admission |
| R4 | **certified** | see per-lane verdicts below |

The R3 recurrence (each round closed the prior CRITICAL and opened a new one in the same purge-fence subsystem) triggered a deliberate concurrency+durability redesign rather than another incremental patch; R4 certifies it.

### Verification
- `swift build --package-path phase3-binary` green (debug + release; `#if DEBUG` test-injection hooks excluded from release).
- Touched suites green, 0 failures (MLX-Metal / Data-Protection-keychain tests XCTSkip-gated for the headless environment — pre-existing baseline).
- FR-KVP1: source diff touches only KV-tier internals; no buyer `CompletionResult` / `Usage` / receipt / `cached_prompt_tokens` / wire change.

### Carried residual (blocking-before-enable, documented)
The KVS-01a benchmark **evidence** arm requires a controllable >32 GB lab Mac (standing P0 #584) and has not been executed; per FR-KVP13 the tier MUST NOT graduate past synthetic-key experiments until KVS-01b passes on that host. The machinery lands here; the tier stays default-off. The load-time-geometry item (first post-restart turn needs one in-process commit before promoting) is a documented follow-up — model-hash fencing means a stale template can only miss, never promote incorrectly.

## Test plan
- [x] `swift build --package-path phase3-binary` (debug + release)
- [x] KV suites: KVDiskCacheStore/Format/Tier/ConversationColdTier/ConversationCache/ControlSocket/KVBuildIdentityDrift/KVTokenizerIdentity — 0 failures
- [x] `bash -n` + `node --check` on the KVS-01a harness
- [x] `git diff --check`
- [x] Five-lane BUILD audit loop (3 codex + adversarial + product) — R4 certification at 0 C/H/M (LOW/INFO carried below)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

SPEC-GOVERNANCE-DECLARATION-BEGIN
{
  "schema_version": "spec-pr-governance-v1",
  "behavior_change": "yes",
  "contract_change": "none",
  "issue": "https://github.com/Augustas11/macprovider/issues/614",
  "specs": ["SPEC-037"],
  "requirements": ["SPEC-037-R001", "SPEC-037-R002", "SPEC-037-R003", "SPEC-037-R004", "SPEC-037-R005", "SPEC-037-R006", "SPEC-037-R007", "SPEC-037-R008", "SPEC-037-R009", "SPEC-037-R010", "SPEC-037-R011", "SPEC-037-R012", "SPEC-037-R013"],
  "authority_domains": ["kv-cache-persistence"],
  "arbitration": ["CODE_BUG"],
  "tests": [
    "swift build --package-path phase3-binary (debug + release)",
    "swift test --package-path phase3-binary KV suites (KVDiskCacheStore/Format/Tier/ConversationColdTier/ConversationCache/ControlSocket/KVBuildIdentityDrift/KVTokenizerIdentity)",
    "bash -n + node --check on test/e2e/coldwarm-ttft/kvs-01a.sh + kvs-01a-probe.mjs",
    "five-lane BUILD audit loop (3 codex + adversarial + product) to 0 C/H/M, prompts under audits/2026-07-23/"
  ],
  "journeys": ["not-required"]
}
SPEC-GOVERNANCE-DECLARATION-END
