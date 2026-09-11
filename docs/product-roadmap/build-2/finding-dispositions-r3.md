# Product Build 2 R3 finding dispositions

**Disposition revision:** R3
**Status:** authored for a fresh independent GPT-5.6 Sol gate; no R3 implementation is authorized by this document
**Failed review:** `reviews/plan-r2-sol.md` at SHA-256 `c1e327a2ddd0efbe3ed14740cca4111a53cbd3c6c92b279dcab3074ee1e97b4e`
**Reviewed MacProvider commit:** `30c7c3d577b26857db89c45ae4145c248ef0ae35`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Malibu read-only base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

No finding was downgraded, waived, or addressed by weakening an acceptance criterion. R3 preserves R2's passed pool/SQLite double collect, signed-bundle plus account-invitation bootstrap, provider-plaintext disclosure, no ciphertext failover, rejection-only refund rule, and actual-MLX evidence boundary.

| R2 finding | R3 correction | Verification requirement |
|---|---|---|
| H1 incompatible null/locator rules | C1 replaces the universal null rule with an exact per-object presence/nullability table. It freezes `SHA256(ASCII(canonical_provider_binding))` and three literal expected vectors, preserving current gateway representation-byte behavior. | T-C01 mutates null/absent/type per field from one schema manifest. T-C02 requires byte-identical Go/Swift/JavaScript locator outputs and rejects decoded-byte hashing. |
| H2 no durable local confirmed-profile authority | C3A defines an account/origin-bound, signed-bundle/pin-bearing confirmed-profile record, HMAC/predecessor/generation authority, exact pending replace/revoke convergence, Go/IndexedDB ownership, caps, retention, corruption and clearing behavior. Server GET synchronizes but cannot bootstrap. | T-P07, T-G01, T-W01, and T-W02 cover restart/reload after activation-artifact expiry, fresh-store GET, cross-account/origin, rollback, tamper, key loss, pending mutation cuts, revocation, and capacity. |
| H3 unauthenticated refund response | C6A adds a dedicated pinned Ed25519 coordinator-evidence authority bound to a fresh challenge, operation, account, wallet session, request, locator, envelope, exact response digest, and short validity. Production also requires verified HTTPS; only explicit loopback development may use HTTP. | T-Q03A mutates every proof field, exercises TLS identity/misroute/redirect/plaintext, key rotation, replay/mix-up, crash/idempotency, and holds state on any authentication outage. |
| H4 incomplete request journal | C8 freezes exact common and state-conditional record schemas, transaction/account/profile/request binding, HMAC request commitment, locator availability, generation/predecessor/MAC, owner epoch, terminal classes, atomic transitions and compaction. Reopened epochs are recovery-only. | T-C01, T-G03, and T-W02 consume shared record/state vectors and crash/reopen at every state, proving status is possible when promised and no old ciphertext is reauthorized. |
| H5 impossible emergency capacity | C9 assigns total physical and normal/emergency row+byte partitions. Revoke updates the existing profile and uses bounded dedicated operation/audit capacity; recovery/status update existing rows. Exhaustion has an exact fail-closed outcome. | T-P04 exercises normal limit minus one, exact normal limit, every emergency slot, actual emergency exhaustion, restart, retained references, and total-cap invariants. |
| H6 wallet polls exhaust replay authority | C4 replaces per-poll replay rows with one fixed, separately capped status-authority row created before each wallet reservation is returned. A signed monotonic sequence updates that row in place; it cannot consume inference replay rows, and at cap new reservations fail before encryption while existing recovery remains available. | T-C05 faults authority creation, exercises sequence replay/rollback/restart and session/account row+byte boundaries, proves higher-sequence polls through the safe-integer ceiling do not grow storage, preserves inference replay, and covers stale/revoked sessions plus continued background recovery. |
| M1 unreachable per-profile cap | C9 changes the nested cap to 128/profile under 512/account. | T-P04 independently reaches 128 on one profile and 512 across four profiles without bypassing either limit. |
| M2 convergence omitted work bounds | C6 fixes scheduler ordering, 20-call concurrency, two-second calls, bounded database work, 15-second pass work/interpass delay, cancellation, and the conservative 285-second/1,000-row formula. | T-Q05 runs a real scheduler with slow/hung/TLS/busy/malformed calls and validates work duration, non-starvation, cancellation, startup formula, and the separate fake-clock retention boundary. |
| M3 typed errors deferred | Section 6 now contains the complete versioned code/origin/HTTP/phase/retry/action matrix plus malformed/unknown mapping and precedence before implementation. | T-C06 generates shared fixtures from the table, rejects missing/extra/divergent codes, tests both sides of `send_fenced`, and exercises pairwise precedence. |
| M4 Go journal pathname ancestry incomplete | C8 mandates descriptor-relative root-to-leaf `openat` traversal, ownership/mode/sticky rules, retained directory descriptors, link count, repeated device/inode recapture, lock-first ordering, and exact rename/reopen identity. Unsupported platforms fail before private action. | T-G02 races every ancestor/final-component replacement and faults each traversal, append, fsync, compaction, rename and reopen stage on macOS. |

## Current Malibu evidence retained

The R3 author fetched Malibu `origin/main` and confirmed it remains `dc7f425ba7d50c86467f31a82f419df6a0904b13`. The canonical checkout is two commits behind with unrelated untracked `.omc/` and `social/`, so it was inspected read-only and not modified. At that revision:

- `console/api.js` stores API key/settings/threads in `localStorage` and a demo token in `sessionStorage`;
- `console/api.js::fetchChatCompletions` retries selected ordinary 502/503 responses;
- no private-request confirmed-profile or request-journal IndexedDB authority exists;
- `package.json` exposes Node tests, docs validation, Vite build, and preview, but no existing real-browser private-request suite.

R3 therefore keeps the private transport separate from ordinary chat retries and requires new IndexedDB/Web Locks/Web Crypto authorities plus real Safari/Chromium evidence. This is planning evidence, not an implementation claim.

## Gate instruction

The next reviewer must inspect the exact R3 plan, test specification, this disposition record, both repository revisions, and the complete R2 failed review. It must challenge schema interoperability, local trust continuity, response authentication, economic/refund safety, state recovery, denial resistance, browser feasibility, filesystem race safety, UX truthfulness, and whether tests prove each claim. Any Critical, High, or Medium finding requires R4; implementation remains prohibited until a fresh review reports zero in all three severities.
