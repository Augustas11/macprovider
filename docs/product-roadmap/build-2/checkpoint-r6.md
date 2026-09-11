# Product Build 2 planning checkpoint

**Checkpoint revision:** R6
**Status:** R6 correction authored; implementation has not started and remains prohibited pending a fresh independent GPT-5.6 Sol gate with zero Critical, High, and Medium findings
**MacProvider branch/head before this checkpoint:** `codex/product-build-2` / `0661923226645abca5e8f0d11491c84fc6531664`
**MacProvider implementation base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Malibu inspected base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

## Exact artifacts submitted to the next gate

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r6.md` | `21018218a25cfa1f92a886599bf315bec019a1aad5434c1f8cd02e111bd449e2` |
| `test-spec-r6.md` | `4ec5f42c4c1478f83a864efff206e1b545bc7ee184361acc381a8ed6e6783996` |
| `finding-dispositions-r6.md` | `d28eab029df3658766adf1233b192fce6ff43fbdf6858f03b6e40e5ff33a4da9` |
| failed predecessor `reviews/plan-r5-sol.md` | `00b9d3a808e734fbaf60d4c813091ca1b17fd7a5011734bdbb8f71509a02d93f` |
| `baseline-assessment-r2.md` | `17abe6f546816929eda655cda7809eb0aa57fad3779c07ea25a2398949f0c3d3` |

Any byte change to the three R6 submission artifacts invalidates these hashes and requires a new checkpoint and gate input.

## R6 corrections

- Profile create, replace, and revoke now have one executable `sent_or_unknown` recovery operation: exact replay of the persisted method, canonical route, content type, and body. A terminal server row is sealed in the same transaction as commit or no-commit; transient inability to reserve the row remains pending and cannot restore local authority.
- Go authority bootstrap now has a creation-only Keychain discriminator and deterministic, authenticated genesis. Orphan selectors/files, rollback, and inconsistent partial initialization quarantine instead of becoming fresh state.
- Every append publishes a new immutable pointer and externally chained Keychain head. Exact tuple equality selects authority, old/new readback resolves publication, and mandatory retirement keeps full-copy tails bounded to current plus candidate.
- Browser authority now has literal paired-allocation, per-kind GET/CAS, paginated-list, and pair-DELETE protocols through Malibu's `/api/mp` boundary. Both kinds are allocated atomically; one-kind state is cleanup-only and cannot authorize private mode.
- Capacity covers every reachable live revocation target: 65,536 normal tombstone slots plus 45,064 target-bound emergency slots for signers, bundle revisions, live profile IDs, and unique stored-bundle pin fingerprints. Coordinator and browser global caps bound the co-reachable set inside frozen physical ceilings.
- Error mapping has an exact source-callsite inventory schema and key derivation. Slice 2 must materialize every row and digest and pass the separate zero-C/H/M gate before error emitters, adapters, reducers, or UI work.
- Revocation checkpoints have exact framing, authentication, rollover, contiguous range, pruning, suffix-predecessor, and empty-log rules.
- Five seconds is solely the nonblocking authority-lock acquisition deadline. Once a noncancellable Keychain operation starts, the lock remains held and admission stays blocked until synchronous completion and authoritative readback.
- The coordinator profile-revision cap is 32,768 rows/256 MiB globally. Fixed revoke operation/audit slots remain available after normal operation/audit saturation, and browser responses use their own domain-separated digest.

## Read-only repository evidence

MacProvider remained at the stated implementation base for code-grounding; this revision changes planning evidence only. Malibu was re-inspected read-only at the stated commit. `console/api.js` uses `BASE = '/api/mp'` and ordinary-chat retry handling; `vite.config.js` proxies `/api/mp` to `https://api.streamvc.live` with prefix removal; `package.json` declares Vite 8.0.16 and no browser-automation dependency. The R6 acceptance design therefore keeps an isolated trusted-HTTPS reverse-proxy harness and a separate no-retry private transport.

No `d-inference` source, operator secret, or private key was inspected. No product code, deployment, release, production mutation, economic activation, browser journey, MLX run, or implementation test occurred.

## Resumption sequence

1. Give a fresh independent native GPT-5.6 Sol reviewer the exact hashed R6 artifacts, failed R5 review, baseline, both repository revisions, and prior review history.
2. Require independent MacProvider and Malibu inspection plus structured severity, evidence, consequence, and required correction. Any Critical, High, or Medium finding requires R7; do not downgrade or weaken acceptance.
3. If and only if R6 reaches zero, implement the governance and shared-vector slice first.
4. Produce the exact SQLite DDL, page/index/WAL measurements, stable callsite labels, complete error-inventory JSON, and digests in Slice 2. Submit those exact artifacts to a second independent zero-C/H/M gate.
5. Do not begin runtime storage, error emitter, adapter, reducer, or UI implementation until that second gate passes.
6. Keep MacProvider and Malibu implementation in separate worktrees and identify each per-repository and cumulative dependent diff.
7. Preserve deterministic Swift fixtures, browser harness, actual MLX inference, deployed services, and production evidence as distinct evidence classes.
