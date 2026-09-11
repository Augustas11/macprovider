# Product Build 2 planning checkpoint

**Checkpoint revision:** R8
**Status:** R8 correction authored; implementation has not started and remains prohibited pending a fresh independent GPT-5.6 Sol gate with zero Critical, High, and Medium findings
**MacProvider branch/head before this checkpoint:** `codex/product-build-2` / `c2960f14ca966ec4aac9b2c74fb2ab42af8f31e6`
**MacProvider implementation base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Current fetched origin/main, deliberately not incorporated:** `c123ae2d2d08053612d940b3077994f7c4d709d7`
**Malibu inspected base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

## Exact artifacts submitted to the next gate

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r8.md` | `007b6527db673626c50298bfe2c39cb7de30f0fd03e59216a077c3dfc82fd30a` |
| `test-spec-r8.md` | `c437d153df0238a172a5aeddaf29fca93aad51e8414ac910de3f200afea01815` |
| `finding-dispositions-r8.md` | `ec7a2f89f47d6611b2fa9a647e8cd57057939097c47f628d579dbfa6362b1bb2` |
| failed predecessor `reviews/plan-r7-sol.md` | `a48ea052c9846976ef42bc0ac508a332aa45bb318a14c92247ee7d27729dd32a` |
| `baseline-assessment-r2.md` | `17abe6f546816929eda655cda7809eb0aa57fad3779c07ea25a2398949f0c3d3` |

Any byte change to the three R8 submission artifacts invalidates these hashes and requires a new checkpoint/gate input.

## R8 corrections

- Go local authority now uses one process-lifetime capacity-one gate plus canonical retained macOS BSD `flock` descriptors for the login-user coordination root and each state root. The contract covers same-process and cross-process Stores, unrelated closes, descriptor duplication, cancellation, panic/`Goexit`, fork/exec, `Store.Close`, and late noncancellable Keychain completion.
- Revocable-target accounting now distinguishes each record's own active/revoked state from retained history and ancestor invalidation. Exact normal-revoked, emergency-sealed, active-bound, and free invariants survive every profile/pin/bundle/signer restart boundary in the reachable 8,200-generation history.
- Production revocation recency now requires an independently operated linearizable witness outside the coordinator SQLite rollback/backup domain. Exact head/append/suffix APIs, challenge-bound proofs, prepared-to-witnessed-to-finalized mutation recovery, database catch-up, disaster recovery, key rotation, outage, retention, and capacity are specified. Internal signed checkpoints remain consistency evidence only.
- Signer activation, bundle upload, and signer/bundle/pin revocation have exact operator methods, paths, versions, closed schemas, target authority/CAS, named-actor authentication, request digests, replay, response/witness headers, error precedence, rate/capacity charges, parent/child serialization, and crash recovery.
- Buyer-retained operations are split into 256 nonborrowable operator-assigned account shards. Each coordinator shard owns 64 normal operations and 32 committed audits; each gateway shard owns 256 browser operations, eight paired authorities, and fixed DELETE capacity. Hostile saturation of 255 accounts cannot consume the final account's share.
- Reservation stability uses an epoch plus per-provider generation/decision digests and an exact approved-mapping projection. Unapproved churn cannot change the token or consume one of three rounds. Consume and final arm compare only the selected-provider token and preserve exact-session no-failover.
- Previously accepted exact response storage, mutation replay, two-kind browser head schemas/cleanup, Keychain selectors/policy, signed rejection-only refund, provider-plaintext disclosure, relay-visible response, ordinary settlement, and actual-MLX evidence boundaries remain intact.

## Read-only evidence and verification

MacProvider code remains pinned to the stated historical implementation base. The current pinned coordinator still selects the first globally sorted eligible provider without a buyer-profile intersection, and the planned profile/operator/witness/shard/scoped-token authorities are not landed. Current `origin/main` is one commit ahead of this branch and was recorded without rebasing or silently claiming it.

Malibu was inspected read-only at the exact stated git object. It still uses production-shaped `/api/mp`, ordinary-chat retries, a public Vite proxy target, and no browser automation dependency. R8 continues to require a separate encrypted no-retry transport and an explicit trusted-HTTPS loopback reverse-proxy harness.

Fresh docs verification for this revision consists of `git diff --check`, artifact SHA-256 recomputation, stale-token/capacity/reference searches, and local host confirmation that a BSD `flock(LOCK_EX|LOCK_NB)` on an independently opened descriptor conflicts in the same process and remains held after an unrelated descriptor closes. That primitive check is plan feasibility evidence only. No Go, Swift, Node, fixture, browser, actual MLX, deployed-service, or production acceptance test was run or claimed.

No `d-inference` source, operator secret, private key, production service, deployment, release, economic activation, reward, payout, Trusted Pool, epoch, or payment work was accessed or changed.

## Resumption sequence

1. Give a fresh independent native GPT-5.6 Sol reviewer the exact hashed R8 artifacts, failed R7 review, baseline, both pinned repository revisions, current-origin divergence, and prior review history.
2. Require independent MacProvider and Malibu inspection plus structured severity, evidence, consequence, and required correction. Any Critical, High, or Medium finding requires R9; do not downgrade or weaken acceptance.
3. If and only if R8 reaches zero, implement the governance and shared-vector slice first.
4. Produce the exact SQLite DDL, response/operator/witness byte oracles, page/index/WAL measurements, witness backend capacity/retention evidence, stable callsite labels, complete buyer/operator error-inventory JSON artifacts, and digests in Slice 2. Submit those exact artifacts to the separate zero-C/H/M gate.
5. Do not begin runtime storage, operator route, witness client, error emitter/adapter/reducer, or UI implementation until its applicable gate passes.
6. Reconcile current `origin/main` explicitly after plan approval; preserve per-build and cumulative dependent diffs instead of assuming the newer commit landed in these reviewed bytes.
7. Keep MacProvider and Malibu implementation in separate worktrees and preserve deterministic fixture, real-browser, actual MLX, deployed-service, and production-qualification evidence as distinct classes.
