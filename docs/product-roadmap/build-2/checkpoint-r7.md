# Product Build 2 planning checkpoint

**Checkpoint revision:** R7
**Status:** R7 correction authored; implementation has not started and remains prohibited pending a fresh independent GPT-5.6 Sol gate with zero Critical, High, and Medium findings
**MacProvider branch/head before this checkpoint:** `codex/product-build-2` / `e8c44ade8dac56e70cb091ff2bcc0f6e33a51e46`
**MacProvider implementation base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Malibu inspected base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

## Exact artifacts submitted to the next gate

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r7.md` | `1ef0a654460d24180231933fe6fda442a01ae7673e0ec7d3689e2792f3718eaa` |
| `test-spec-r7.md` | `fe916b0e5eb53c9afa67e946bd3c380193b37715d199f19638eedff0a425b639` |
| `finding-dispositions-r7.md` | `7e3943f06e8661d7879c30aad12e5fed1c6a1a8e98733ebcbad44b4469784e67` |
| failed predecessor `reviews/plan-r6-sol.md` | `710b34aa775c4262b5c217c274b60cc93b2dc0b42ebfed5766a552e88b00bc01` |
| `baseline-assessment-r2.md` | `17abe6f546816929eda655cda7809eb0aa57fad3779c07ea25a2398949f0c3d3` |

Any byte change to the three R7 submission artifacts invalidates these hashes and requires a new checkpoint and gate input.

## R7 corrections

- Profile responses now have an exact 16,384-byte canonical encoding ceiling checked for both the active document and its maximum-timestamp revoked projection before mutation. Migration preallocates fixed response BLOB extents; terminal operations reference sealed bytes, replay never regenerates them, and maximum error bodies remain inline under an exact 2,048-byte ceiling.
- The proposed sizing slice must commit a byte oracle, exact DDL, and physical SQLite measurements. It verifies every one of the 16,384 fixed extents, maximum success/error/revoke replay, byte-aware list pagination, incremental revoke writes, WAL/page/disk ceilings, and all corruption cases before runtime storage implementation is allowed.
- Every conforming Go authority uses a non-overridable login-user coordination root and a retained-descriptor whole-file `fcntl` lock before its state-root lock and Keychain access. Exact root markers are bootstrap/head-bound, current-head reread is mandatory before replacement, and stale cloned roots quarantine rather than publish a second successor.
- The Keychain contract now freezes `account_scope_digest`, item services/accounts, complete add/read/update dictionaries, Data Protection accessibility, synchronizability, noninteractive behavior, process-default access group, returned-attribute normalization, policy/access-group/root digests, and future-policy migration behavior.
- The normal revocation partition is 1,024 slots and the emergency partition has one slot for each of 7,176 maximum live targets. A supported 129-hour history fills normal capacity with 1,024 temporary profiles, creates the 7,176-target maximum live set before the 24-hour activation boundary, and revokes every live target over 113 further rate-limited windows without allocation or early reuse.
- The joint history records every emergency-slot owner/free/sealed transition. It reaches 8,200 consecutive tombstones and at most 9 checkpoints while remaining within pin and evidence horizons. Independent revision/response maxima are tested separately and are not falsely asserted as jointly reachable.
- Previously approved selection-before-encryption, exact mutation recovery, signed revocation/checkpoint evidence, browser two-kind ledger, no ciphertext failover, provider-plaintext disclosure, relay-visible response, refund, ordinary-settlement, and actual-MLX boundaries remain unchanged.

## Read-only repository evidence

MacProvider remained at the stated implementation base for code-grounding. `phase4-coordinator/internal/buyer/relay_blind.go::selectRelayBlindProvider` still sorts the global pool snapshot and selects the first matching serving provider without a buyer-profile intersection. The planned profile, response-slot, root-coordination, Keychain, and browser authority contracts are not landed.

Malibu remained read-only at the pinned revision. `console/api.js` still routes through `/api/mp` and retries selected ordinary-chat failures; `vite.config.js` still proxies that prefix to the current upstream and removes it; `package.json` still has no browser-automation dependency. R7 therefore retains a separate no-retry private transport and an isolated production-shaped trusted-HTTPS browser harness.

No `d-inference` source, operator secret, or private key was inspected. No product code, schema, SPEC, deployment, release, production mutation, economic activation, browser journey, MLX run, or implementation test occurred.

## Resumption sequence

1. Give a fresh independent native GPT-5.6 Sol reviewer the exact hashed R7 artifacts, failed R6 review, baseline, both repository revisions, and prior review history.
2. Require independent MacProvider and Malibu inspection plus structured severity, evidence, consequence, and required correction. Any Critical, High, or Medium finding requires R8; do not downgrade or weaken acceptance.
3. If and only if R7 reaches zero, implement the governance and shared-vector slice first.
4. Produce the exact SQLite DDL, response byte oracle, page/index/WAL measurements, stable callsite labels, complete error-inventory JSON, and digests in Slice 2. Submit those exact artifacts to a second independent zero-C/H/M gate.
5. Do not begin runtime storage, error emitter, adapter, reducer, or UI implementation until that second gate passes.
6. Keep MacProvider and Malibu implementation in separate worktrees and identify each per-repository and cumulative dependent diff.
7. Preserve deterministic Swift fixtures, browser harness, actual MLX inference, deployed services, and production evidence as distinct evidence classes.
