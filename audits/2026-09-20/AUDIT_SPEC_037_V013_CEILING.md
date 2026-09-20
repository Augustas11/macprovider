# SPEC-037 v0.1.3 FR-KVP9 ceiling raise — three-lane audit

Worktree: `/Users/augstar/macprovider-037-kvs01b-ceiling`
Branch: `spec/037-kvs01b-ceiling`
Base: `origin/main` (`355cdd3d`, KVS-01a evidence #1654)

## What this change is

Q6 on live Qwen3-Coder-30B-A3B 4-bit is unquantized `KVCacheSimple` (`kv_bits=null`, ~98 KiB/token). Q7 q4 is not the active representation. KVS-01b at 8k therefore needs a spec-revision FR-KVP9 promotion hard-ceiling raise, not a `QuantizedKVCache` codec v2.

This PR:
- Bumps SPEC-037 to v0.1.3
- Raises **hard** `staging_max_bytes` from 256 MiB to 1 GiB
- **Keeps the default at 256 MiB**
- Does **not** claim KVS-01b evidence or mark SPEC-037-R013 conformant
- Does **not** enable fleet default, buyer keys, CB, or raise slots

## Files

- `specs/SPEC-037-kv-survival-restart.md`
- `specs/CONFORMANCE.json` (SPEC-037 version + R009 rationale only)
- `specs/README.md` (generated)
- `phase3-binary/Sources/MacProviderCore/KVDiskCacheConfig.swift`
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` (CLI help)
- `phase3-binary/Sources/macprovider-cli/KVDiskCacheStore.swift` (comment)
- `phase3-binary/Sources/macprovider-cli/ConversationColdTier.swift` (comment)
- `phase3-binary/Tests/macprovider-cliTests/KVDiskCacheConfigTests.swift`
- `beta/DECISION_CRITERIA.md` Entry 245

Read `git diff origin/main` in this worktree. Do not review unrelated files.

## Constraints the change must keep

- Configuration may lower the ceiling, never raise it above the hard cap
- Write staging hard cap remains 1 GiB (already enough for 8k writes)
- v1 allowlist stays `KVCacheSimple` / codec `kvsurv-codec-v1`
- Default-off, `allow_buyer_keys` false, synthetic `conv:kvs-synth:` only
- 32k–64k still deferred (exceeds 1 GiB FP16)

## Tests already run

`swift test --package-path phase3-binary --filter KVDiskCacheConfigTests` — 27 tests, 0 failures, including:
- 1 GiB + 1 rejected
- 1 GiB accepted
- former 256 MiB + 1 now accepted

`swift test --package-path phase3-binary --filter KVDiskCacheStoreTests/testPromotionCeilingHardMaxTracksConfigOneGib` — pass.

R1 code+architect found HIGH: `KVDiskCacheStoreConfig.promotionCeilingHardMax` still 256 MiB. **Fixed:** store hard cap is now 1 GiB and a coupling test requires it to match `KVDiskCacheConfig.hardStagingMaxBytes`. Re-audit this complete diff.

## Return

Severity-rated findings: CRITICAL / HIGH / MEDIUM / LOW / INFO.
Gate for this slice: 0 CRITICAL, 0 HIGH, 0 MEDIUM.
If none, say so explicitly.
