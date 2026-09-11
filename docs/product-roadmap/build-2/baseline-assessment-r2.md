# Product Build 2 baseline assessment and R1 finding disposition

**Assessment revision:** R2
**MacProvider inspected base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, fetched 2026-09-11)
**Malibu inspected base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`origin/main`, fetched 2026-09-11)
**Historical roadmap baseline:** `422fc2f13fc62c1ff8987522f822d9ef856e4a96`
**Predecessor:** `baseline-assessment.md`
**R1 plan review:** `reviews/plan-r1-sol.md`, SHA-256 `a0e377960943cac3cdfb17a9d61e49d72f8a1f1d03b3575050dcc9dda623ca49`

## Inspection boundary

Both repository origins were fetched before this revision. MacProvider `origin/main` remains the worktree base. Malibu `origin/main` remains the R1-inspected revision; its canonical checkout is two commits behind and contains unrelated untracked `.omc/` and `social/`, so inspection continued through `git show origin/main:<path>` without modifying it. No implementation was performed. Historical tests in R1 remain evidence of that earlier inspection and are not rerun or promoted here.

The R1 baseline classifications remain current:

| Outcome | Current classification | Evidence / implication |
|---|---|---|
| Relay-blind transport, provider decryption, exact-session binding, no-failover pilot | Landed, default-off | `phase4-coordinator/internal/relayblind`, coordinator buyer handlers, gateway relay-blind router/storage, Swift `RelayBlindProvider`, SPEC-041. This is substrate, not the supported product. |
| Buyer-approved acceptable-identity selection before encryption | Missing | `buyer.(*Server).selectRelayBlindProvider` still selects from the global pool before any buyer profile authority. |
| Account trust profile, A-only/A+B lifecycle | Missing | No invitation/profile/revision/tombstone schema or profile headers exist. |
| Authenticated pin delivery without TOFU | Missing | Existing runbook uses manual out-of-band delivery; no release-trusted signed bundle/invitation flow exists. |
| Supported Go library/CLI typed recovery | Partial | Reference `cmd/relay-blind-client` is a `main` package and discards typed error detail; no durable buyer journal/status command exists. |
| Gateway recovery/ordinary settlement | Partial | Existing quota/settlement holds recover dispatched uncertainty, but no profile invalidation join exists across coordinator/gateway stores. |
| Wallet reservation execution | Landed for pilot | SPEC-040 signs current reservation semantics, but profile headers and public v2 status route are absent. |
| Malibu private-request product | Missing | Current `console/api.js::fetchChatCompletions` retries eligible 502/503 responses and stores ordinary thread/settings data in `localStorage`; there is no signed-bundle, Web Crypto, IndexedDB/Web Locks, or private transport UI. |
| Two-provider deterministic journey | Missing | Existing integration uses one deterministic Swift fixture provider. |
| Actual encrypted MLX journey | Blocked/unproven | Prior evidence separates cached MLX selftest from deterministic encrypted fixture; no combined journey exists. |
| Production qualification | Blocked/out of authority | SPEC-041 is draft/pending/not deployed; bundle signer/release, deployment, hardware, and activation evidence are absent. |

## Code-grounded constraints added by R1 review

1. Current coordinator status indexes an envelope digest written only during consume (`relayblind.Store.Consume` and `LookupStatus`), so it cannot authenticate a never-seen digest for `reserved` state.
2. Existing identity-pin timestamps accept signed 64-bit values and coordinator internally uses `math.MaxInt64`; JavaScript `Number` cannot represent that range exactly.
3. The pool is an independent mutex-protected in-memory registry (`pool.Registry.Snapshot`), while profile/key/reservation authority is SQLite. A single transaction cannot directly include current WebSocket state.
4. Gateway quota/session reservations are created after coordinator consume, and existing settlement recovery primarily discovers held rows. Profile mutation needs a durable join from the first held token.
5. Current wallet semantic profiles contain route reservations but no Build 2 profile headers or public status route.
6. Current limits do not define profile/revision/invitation/journal capacities or a coordinator status-evidence horizon long enough for gateway settlement recovery.
7. Current Malibu browser code has no cross-tab private transaction authority; its ordinary retry helper is unsafe for ciphertext.

## R1 finding disposition in R2 artifacts

No finding is downgraded, waived, or marked resolved by authorship. The following changes are submitted for independent review:

| Finding | R2 correction submitted | Verification mapping |
|---|---|---|
| H1 impossible reserved-status digest pair | Versioned status request always uses account-scoped binding digest; envelope digest is nullable/state-dependent; `reserved` reports `unbound` and explicitly does not authenticate a supplied digest. | T-L01, T-L02, journal crash cuts. |
| H2 undefined cross-language framing/numeric range | Exact domains, field order, u16 length framing, big-endian integers, raw decoded bytes, ASCII policy, pin framing, `2^53-1` ceiling, and route schemas. | T-C01 through T-C05 shared Go/Swift/JS vectors. |
| H3 infeasible atomic pool/SQLite transaction | Process epoch plus monotonic pool generation, bounded approved-ID snapshot, no overlapping locks, three-round double collect around D2, exact linearization and churn fencing. | T-S01 through T-S06 lock/barrier/race tests. |
| H4 invalidation not joined to quota/recovery | Atomic gateway quota/session/recovery join, atomic dispatch intent, rejection-only refund table, scan of all nonterminal joins, exact retention/convergence. | T-Q01 through T-Q06 API-key/wallet crash matrix. |
| M1 unowned authenticated pin delivery | Dedicated release-baked bundle signer keyring, exact signed bundle, authenticated account invitation, signer/freshness/revocation and cross-account rules. | T-C03, T-C04, T-W01. |
| M2 wallet status/signature gap | Exact canonical status route, raw body/Accept profile, request-ID replay and account/session rules; reservation profile headers added to semantic profile. | T-C05 and T-L01. |
| M3 missing capacity/retention values | Positive caps for every profile/invitation/operation/audit/reservation/recovery/journal surface and an 8-day coordinator evidence horizon with startup inequalities. | T-P04, T-Q05, T-G03, T-W02. |
| M4 undefined journal failure/multi-actor behavior | Monotonic send fence; no takeover; Go flock/fsync/rename/corruption rules; browser IndexedDB plus Web Locks; exact caps/failure actions. | T-G02/T-G03 and T-W02/T-W03. |

## Remaining blockers and non-claims

R2 is a plan correction only. It does not prove feasibility until an independent GPT-5.6 Sol gate reports zero Critical, High, and Medium findings on the exact R2 bytes. It does not create a production signing key, issue an invitation, modify Malibu, run browser/MLX tests, deploy, enable production, activate settlement enforcement/rewards, or qualify hardware. Build 4 pool-private requests and verified private settlement remain outside Build 2.
