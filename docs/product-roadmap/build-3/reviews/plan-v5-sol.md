# Product Build 3 — Independent Adversarial Plan Review, Revision 5

Review status: **FAIL — revision required before Gate H0 or Gate B0D work**
Reviewer: native Codex subagent, `gpt-5.6-sol`, high reasoning
Repository/base inspected: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Reviewed plan commit: `86e740323bf01a10e83aabbd454757593f1f8ab5`
Plan: `docs/product-roadmap/build-3/prd-implementation-plan-v5.md`
Plan SHA-256: `8f3e442f027a5908d7af913b900179e399a1cc7dd8134c14142c22d197246111`
Test specification: `docs/product-roadmap/build-3/test-spec-v5.md`
Test-spec SHA-256: `7da0c9b87a71bd3a9698ba9454365ae04a15cc56def090057db479c4f0adf3f8`
Disposition record SHA-256: `7704d6621d6e49315aa1f0fac25a8b6f8ef3fd42cfeaa39cb46a1312cca55b88`
Source failed review SHA-256: `11baf4d72c197d0947286a8ae03ccd82a25641799b135ca1300a726cb49ab6ee`

## Verdict

Revision 5 closes much of the prior review. It creates a separately gated collector before calibration, defines a coherent Postgres revision and as-of pagination model, fences old coordinator binaries after lineage activation, gives daily references a calibrated successor policy, separates executable feasibility tooling from production artifacts, moves `ProviderPreWarmer` under a process lifecycle lease, and defines segmented/checkpointed dual-archive continuation with rolling capacity qualification.

The plan still cannot pass. The collector has no technical authorization that makes its numeric path unreachable before Gate A0. The SQLite activation trigger proves only a writer protocol number, so an overlooked direct mutation inside the approved new process can bypass PREPARE and both lineage authorities. The proposed Postgres reward revision does not establish completeness for the authoritative payout-wallet source, which remains a separately polled SQLite table. The lifecycle contract assumes a supervisor-owned serving child and does not assign the supported foreground `macprovider-cli serve` entrypoint an exclusive lease. Finally, the plan unnecessarily orders the independent lineage-feasibility lane after the unavailable physical calibration campaign, preventing safe work that does not consume numeric evidence.

Finding counts: **0 Critical, 4 High, 1 Medium, 0 Low**.

## Findings

### H1 — A signed custody job is not bound to a non-bypassable Gate-A0 authorization

**Severity:** High

**Evidence:** The collector source containing the eventual real-tensor numeric path is built and audited at Gate H1, before Gate A0 (`prd-implementation-plan-v5.md:34-37,133-137`). The plan says the command accepts a “signed custody job,” but it does not define the trusted job issuer, a Gate-A0 approval signature/certificate, trust-root custody, issuance ordering, one-time sequence reservation, anti-rollback state, or the exact check that occurs before the hook reads/copies value storage (`:135`). Gate A0 instead relies on repository/process/signing logs and access records to prove that no prior acquisition occurred (`test-spec-v5.md:32-37`). F008 rejects a record claiming to predate approval, but no test proves that the approved collector binary cannot enter its numeric path with a syntactically signed yet pre-approval, replayed, rolled-back, or wrong-protocol job (`:35-37`).

**Consequence:** Once H1 produces the executable, a custodian or local operator can exercise the implemented numeric path before the threshold-selection and successor rules are frozen, then omit or relabel the result. Artifact timestamps and process logs cannot prove a negative against copied, rolled-back, or incomplete local evidence. Exposure lets protocol authors tune the threshold or refresh envelope to observed values, invalidating the held-out and custody claims even if every later result carries the expected collector digest.

**Required correction:** Define a technical acquisition authorization before H0 implementation. The collector must verify a Gate-A0 approval capsule signed by a separately governed approval key and binding the exact collector manifest, profile, calibration protocol, reference-successor policy, approval sequence root and not-before time. Each numeric job must reserve a unique monotonic custody sequence before execution and bind a nonce, expiry, physical unit, partition, destination key and approval capsule. The collector must check this authorization immediately before the first value read/copy, persist or remotely attest consumption without allowing rollback/reuse, and bind it into the encrypted result. Gate H0 must close key custody and offline/recovery behavior. Add instrumented tests proving that missing, pre-approval, wrong-digest, replayed, expired, rolled-back and post-revocation authorizations never reach the value-access function. Logs remain supporting evidence, not the gate.

### H2 — The SQLite writer-protocol trigger does not authorize the individual lineage mutation

**Severity:** High

**Evidence:** Activation installs triggers that call `macprovider_lineage_writer_protocol()` and accept any mutation when it returns at least 2 (`prd-implementation-plan-v5.md:241`). The test promises rejection for an old or missing writer function, not for a direct mutation issued by the approved new process after that function is registered (`test-spec-v5.md:121,136`). The current billing store exposes many direct `*sql.DB` and `*sql.Tx` mutation paths, including config snapshots, compute captures and receipt/outbox changes (`phase4-coordinator/internal/billing/snapshot.go:31-61`; `settlement_compute_integrity.go:17-81`; `settlement_receipts.go:1236-1254`). Under the normal SQLite Go driver pattern, a protocol function registered on approved-process connections is also visible to a forgotten or newly added direct SQL path on those connections. Nothing in the trigger binds the current transaction to the exact PREPARE sequence, event digest, witness acknowledgement, or lineage lease.

**Consequence:** A missed migration, recovery helper, maintenance path, or later direct `Exec` inside the protocol-2 binary can mutate money state without a local/witness PREPARE or a projection event. The old-binary fence remains green and the trigger approves the write, yet the lineage and Postgres mirror permanently lose completeness. M001’s static inventory can catch known symbols but is not an enforcement boundary for dynamic SQL or a newly introduced path.

**Required correction:** Make the SQLite trigger validate a transaction-scoped, single-use mutation authorization rather than a process-wide protocol number. The lineage owner must create that authorization only after both identical PREPARE records are durable; bind it to incarnation, sequence, predecessor, canonical event digest, allowed table/operation/key set and the specific connection/transaction; and consume it atomically with the mutation plus projection event. A plain protocol-2 connection, migration helper, recovery path or direct SQL call without the exact authorization must fail. Define cleanup after rollback/crash and prevent a token from authorizing a second or different mutation. Add tests that execute every legacy/direct path from the new binary’s registered-function connection, mutate the statement/body/key set, reuse a token, split a transaction, and race token setup/rollback; all must leave SQLite and both lineage heads unchanged.

### H3 — Postgres revision coherence does not prove the SQLite payout-wallet source is current

**Severity:** High

**Evidence:** The revised plan puts wallet binding/rotation and mirror completeness under one `reward_source_revision`, then reads the result in one Postgres repeatable-read transaction (`prd-implementation-plan-v5.md:227-229`). In the inspected implementation, however, payout-address authority is SQLite: reward status reads both `RewardsDB` and `PayoutDB` (`phase4-coordinator/internal/rewards/projection.go:41-48,65-84`), and the wallet mirror periodically scans `provider_payout_addresses` from SQLite and upserts Postgres one provider at a time (`internal/rewards/wallet_mirror.go:23-62,65-114`). SPEC-021 also defines this as a periodic poll (`specs/SPEC-021-malibu-emission-ledger.md:542-549`). The proposed billing journal inventory names route/capture/dispatch/receipt/finality/exclusion/quarantine/credit/reversal/refund/void mutations, but not payout-address add, replacement, revocation or removal (`prd-implementation-plan-v5.md:182`). R017-R022 test Postgres writers and a “wallet rotation,” but no test delays, omits, reorders or deletes the authoritative SQLite wallet source event relative to the Postgres revision (`test-spec-v5.md:182-187`).

**Consequence:** A fully coherent Postgres snapshot can still claim an old wallet is bound and withdrawal-eligible after SQLite replaced or revoked it, or claim a wallet is missing after a valid registration. Incrementing a revision when the poll happens proves only when Postgres changed; it does not prove that every authoritative SQLite wallet mutation through a source head was consumed. The result can be internally atomic and externally stale while stamped complete/fresh.

**Required correction:** Give payout-wallet authority an immutable source sequence/outbox and completeness watermark. Either include every `provider_payout_addresses` lifecycle mutation in the local/witness lineage and mirror its canonical event, or define a separate equally durable source journal with an explicit join rule. Postgres must apply add/replace/revoke/remove events idempotently in source order and include the applied wallet-source head, source time, gap state and freshness in the same reward revision. Provider reward projection must use the revisioned Postgres projection only; independently reported payment execution may retain its own freshness/domain. Add delayed rotation, missed deletion, replay, source restore, fork/gap, poll crash and concurrent cap-replay tests. An incomplete/stale wallet source must fail only wallet/withdrawal facts closed while preserving truthful balances and independent USDC/payment state.

### H4 — The supported foreground serving process has no defined cross-process lease owner

**Severity:** High

**Evidence:** The plan assigns the lifecycle `flock` to “the app/supervisor” and models a supervisor PID plus child PID/process group from birth through serving (`prd-implementation-plan-v5.md:215-217`). The product also directly exposes `macprovider-cli serve` as an `AsyncParsableCommand` (`phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:263-276`), and the conflict detector explicitly recognizes foreground `macprovider-cli serve` processes (`ProviderConflictDetector.swift:56-76`). That supported entrypoint is not necessarily a child of Malibu.app or a lifecycle-aware supervisor. P008 assumes that a serving lifecycle lease already exists, while P013-P017 cover only supervisor/candidate-child transitions (`test-spec-v5.md:105-115`). No test requires direct serve to acquire before MLX/model initialization, maintain a self-owned record, interoperate with app/launchd ownership, or recover a crashed foreground owner.

**Consequence:** A provider started from the documented CLI can load MLX without holding the global lifecycle lease. `ProviderPreWarmer`, decode, canary, benchmark or autotune can then acquire the apparently free lock and start a second Metal process. This invalidates the all-owner quiescence claim, can perturb buyer output/latency and observation measurements, and makes “no two MLX processes coexist” false for a supported provider journey.

**Required correction:** Define lifecycle ownership for every serving entrypoint. A foreground/direct `serve` must acquire the same exclusive lease before any model/Metal initialization and retain it through drain, synchronization and exit, with a self-supervised owner-record variant or a mandatory launcher wrapper. Define compatibility among launchd, Malibu.app, candidate supervisors and direct foreground mode, including lock inheritance, upgrade/re-exec and signal handling. Add real two-process tests for direct serve against every candidate/decode/SPEC-028/autotune launcher, two simultaneous direct serves, app-versus-direct serve, crash/PID reuse and release only after verified device quiescence.

### M1 — Physical calibration unnecessarily blocks the independent feasibility lane

**Severity:** Medium

**Evidence:** The artifact graph gives the preimplementation contract and B0 tooling their own acyclic inputs and separate B0D/B0E gates (`prd-implementation-plan-v5.md:39-41`). Nevertheless, the dependency graph and normative section order B0D only after Gate A0 and the complete calibration campaign (`:109-120,199-203`). The lineage schemas, mutation inventory, witness/storage topology, synthetic workload and durability benchmark do not consume probability values, reference results, a calibration threshold or physical calibration hosts. The current session explicitly lacks the 80-host campaign (`:154,264`).

**Consequence:** An unavailable external hardware/custody campaign blocks safe, reversible design and feasibility work that could independently discover whether the proposed money-path lineage is viable. That conflicts with the roadmap direction to complete every safely executable part and can defer a fundamental architecture rejection until after expensive calibration evidence has been collected.

**Required correction:** Make `Gate H0 -> H1 -> A0 -> calibration/reference` and `Gate B0D -> B0I -> B0E -> synthetic durability/capacity benchmarks` independent lanes that join at the evidence bundle and Gate B. Preserve all existing B0D/B0E source, nondeployability and digest gates. If any B0 contract actually depends on a calibration artifact, name the exact field and justify the dependency; otherwise no numeric or physical prerequisite may gate this lane. Add a graph/invariant test proving B0 work cannot read or import governed numeric evidence and cannot unlock Product Slices 1–7 by itself.

## Prior-finding disposition assessment

| Revision-4 finding | Revision-5 assessment |
| --- | --- |
| H1 collector ordered after calibration | **Partially resolved.** H0/H1 now build and freeze the collector before Gate A0, and production must use the same module bytes. New H1 addresses the missing technical authorization preventing that already-built numeric path from running before approval. |
| H2 no atomic reward revision | **Partially resolved.** Postgres facts, first page and revision-bound later pages now have one coherent snapshot. New H3 addresses the external SQLite wallet authority that a Postgres revision alone cannot make complete. |
| H3 old binary breaks lineage | **Partially resolved.** The one-way external/SQLite activation fence rejects older executables. New H2 addresses direct or forgotten paths inside the approved protocol-2 process. |
| H4 undefined reference refresh validity | **Resolved at plan level.** Per-source predecessor chains, atomic A+B epochs, calibrated movement/divergence/skew rules, prospective suspension and immutable captures define succession. |
| M1 docs-only versus executable feasibility | **Resolved for artifact ownership.** B0D, B0I and B0E define a bounded nonproduction command and reusable core. New M1 addresses only the unrelated calibration dependency. |
| M2 `ProviderPreWarmer` misclassified in-process | **Partially resolved.** It is correctly treated as a child-process path with lease/liveness/kill/reap rules. New H4 covers the supported serving entrypoint that is not necessarily such a child. |
| M3 one-year append-only capacity horizon | **Resolved at plan level.** Segments, checkpoints, two independent archives, relocation preconditions, five-year/two-migration testing and rolling 30-day capacity renewal provide a sustainable logical-lineage contract. |

No prior finding was waived. The remaining findings concern trust boundaries that the revised mechanisms do not yet cover.

## Fresh verification

The pinned commit and all supplied digests matched exactly. The test specification contains **144 unique test IDs**. Fresh conservative-baseline tests passed:

```text
cd phase4-coordinator && go test ./internal/computeintegrity ./internal/stats/billingmirror ./internal/rewards ./internal/billing ./internal/buyer -count=1
  PASS: five packages; zero reported failures

cd frontdoor/provider-portal && node --test mining-health.test.mjs
  PASS: 9 tests; 9 passed; 0 failed; 0 skipped

git diff --check HEAD^ HEAD
  PASS

rg -o 'B3-[A-Z]+[0-9]{3}' docs/product-roadmap/build-3/test-spec-v5.md | sort -u | wc -l
  PASS: 144
```

These runs prove only that the documentation revision leaves the conservative baseline intact and that the proposed matrix has 144 unique identifiers. They do not prove feasibility or implementability of those scenarios. No collector, numeric acquisition, B0 executable, witness/archive topology, actual MLX calibration, Xcode/browser journey, deployed service, production accrual, enforcement, economic activation or production qualification was executed.

## Gate decision

**FAIL.** Gate H0, Gate B0D, Collector Slice H0, Feasibility Tooling Slice B0I, governed numeric acquisition and Product Slices 1–7 remain blocked. Revise the plan and paired test specification to close H1-H4 and M1, commit exact new digests, and submit them to a fresh independent GPT-5.6 Sol high-reasoning review. Approval requires zero Critical, High and Medium findings.
