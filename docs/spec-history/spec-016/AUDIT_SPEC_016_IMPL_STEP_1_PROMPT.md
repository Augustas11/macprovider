# IMPL audit prompt — SPEC-016 Step 1 (schema + §3 address registration + §3.2 EIP-712)

> **THIS FILE IS THE SHARED-CONTEXT INDEX, NOT A FIREABLE PROMPT.**
> Three parallel codex lanes consume the context preamble below.
> Do NOT fire this file solo — fire the three lane files in
> parallel instead:
>
> - `specs/AUDIT_SPEC_016_IMPL_STEP_1_CODE_PROMPT.md`     → `omc ask codex --agent-prompt code-reviewer`
> - `specs/AUDIT_SPEC_016_IMPL_STEP_1_SECURITY_PROMPT.md` → `omc ask codex --agent-prompt security-reviewer`
> - `specs/AUDIT_SPEC_016_IMPL_STEP_1_ARCH_PROMPT.md`     → `omc ask codex --agent-prompt architect`
>
> Each lane references this file for the shared context preamble
> (lines 1–247: PR consolidation note, version history, deltas
> intersection, threat model, required reading, file/LOC catalog).
> Each lane scopes to ONE dimension and writes to a lane-specific
> findings file. House practice is parallel fan-out so the three
> lenses stay diverse and independent. Loop the fan-out as a unit
> until ALL THREE lanes combined return 0 CRITICAL / 0 MAJOR /
> 0 MEDIUM before push/PR.

Master shared-context for the SPEC-016 Step 1 IMPL three-lane
codex audit. Reviews target the SPEC-016 Step 1 IMPL commit on
branch `impl/spec-016`.

**PR consolidation note (operator decision, 2026-06-25):** the BUILD
prompt at `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` §2 / §7 / §8
originally directed one PR per step (4 PRs total). The operator has
revised this to a **single PR covering all four steps** of the full
SPEC-016 IMPL. Each step's audit loop still runs independently
(this prompt is Step 1's), but Steps 2 / 3 / 4 land as additional
commits on `impl/spec-016`. The PR opens once after Step 4's audit
converges to 0/0/0/0. No "push after Step 1 converges" intermediate
step.

Per [[feedback-codex-only-audits]] this loop is **codex-only**. Do NOT
fire Claude internal subagents (`code-reviewer`, `security-reviewer`,
`architect`) on this audit — same-family auditors share the writer's
blind spots; the audit-loop discipline depends on diverse-model lens.

| Commit  | Scope |
|---------|-------|
| `1df0235` | Step 1 — payout package skeleton, migrations 0001–0008, §3.3 registration handler, §3.2 EIP-712 verification, startup invariants, DSN durability bump |

Full coordinator test suite is green
(`go test ./... && go vet ./...` from `/Users/augstar/macprovider-poc/phase4-coordinator`).
32 new payout tests pass; no existing test regressed.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~40–60 minutes
(Step 1 lands ~1.5k net production LOC + 11 schema files + 7 test
files; SPEC §§3–3.4 + §3.5 + §4.1 + §4.5 + §4.7 + §4.8 + §4.8a +
§4.8b + §4.8c + §4.9 are all in scope).

This is a **read-only** review — codex MUST NOT modify any file. Do
not commit, do not push, do not create branches.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial mid-stream review of commit
`1df0235` on branch `impl/spec-016` in the Augustas11/macprovider
repository. The branch is already checked out at
`/Users/augstar/macprovider-poc`. Steps 2 / 3 / 4 of the IMPL have
NOT landed yet — your scope is exclusively Step 1. The operator has
chosen to land all four steps on a SINGLE branch + SINGLE PR (Steps
2 / 3 / 4 will be additional commits on this same branch); your
audit is the Step 1 mid-stream gate, NOT a pre-merge audit.

This is a **read-only review**. You MUST NOT edit any file, commit,
push, or modify the git state in any way. Your only output is the
structured findings report at the end.

## Context

This repository hosts the macprovider stack — a P2P AI marketplace
on Base mainnet. The Go coordinator under `phase4-coordinator/`
accepts WS connections from provider Macs, routes inference, splits
revenue, and (via the SPEC-016 pipeline you're auditing) will pay
providers in USDC on Base.

SPEC-016 v0.1.21 is the controlling contract for this work. It is
LOCKED at commit `f0152c0` on branch `impl/spec-016`. Re-read every
MUST / MUST NOT / SHOULD in the SPEC against the IMPL code; SPEC
§-references in this prompt point at that v0.1.21 text.

**Version history between Step 1 IMPL and this audit fire.** The
Step 1 IMPL commit `1df0235` was authored against SPEC v0.1.19.
Between then and now, a Claude-side adversarial cross-check
(`specs/SPEC-016-r20-audit.md`, 2 parallel subagents — critic +
analyst lenses) surfaced 3 criticals + 5 majors that 19 codex
rounds with one lens missed. v0.1.20 absorbed 7 of 8 (M3 EIP-712
verifyingContract UX deferred to SPEC-014 v0.9). Codex round 21
(`specs/SPEC-016-r21-audit.md`) fix-pass produced v0.1.21; codex
round 22 declared CONVERGED 0/0/0/0 and GO for Step 2 IMPL.
**None of the v0.1.20 / v0.1.21 deltas invalidated Step 1 IMPL**
— codex re-ran `go test ./internal/payout` in r22 and all tests
passed.

**Step 1 IMPL ∩ v0.1.21 deltas — the in-scope intersection.** Most
v0.1.21 deltas land in §4.3 / §4.7 / §4.9 territory (Step 2 / 3 /
4 work). The deltas that COULD touch Step 1's surface:

- §3.2 deny-list (line ~438 at v0.1.21) — extended framing: hot
  wallet denied as funding SOURCE AND payout DESTINATION. Step 1's
  `internal/payout/deny.go` denies the hot wallet from the
  `SecurityConfig.HotWalletAddress` (correct for the §3.3 payout-
  destination surface). The funding-SOURCE denial lands at §4.9
  (Step 3). Verify Step 1's deny-list is complete for §3.3's scope
  and the v0.1.21 destination framing is honored.
- §4.5 / §4.7 / §4.8 / §4.8a / §4.8b / §4.8c / §4.9 schema — no
  schema-level changes in v0.1.20 / v0.1.21. Verify Step 1's
  migration SQL still matches v0.1.21 §-text byte-for-byte.
- `payout.tuning.confirmation_blocks` bounds widened
  `[2, 50]` → `[5, 200]` (M2). Step 1's `PayoutTuningConfig` only
  declares `address_cooling_off_period`, not `confirmation_blocks`
  — verify no stale bounds linger anywhere in Step 1.

Any other delta surfacing in code review SHOULD be called out
explicitly with the SPEC version that introduced it.

The branch under review implements **Step 1** of the IMPL prompt at
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` §2. Step 1 covers
SPEC-016 §3 (provider payout-address registration) entire (§3.1 to
§3.5), §3.2 EIP-712 verification, and the schema for §4.5 / §4.7 /
§4.8 / §4.8a / §4.8b / §4.8c / §4.9 (the runner cycle, lease, and
admin endpoints land in Steps 2–4 and are out of scope for this
audit — but you SHOULD flag if Step 1 made an assumption that 2–4
will have to fight).

The coordinator's threat model on the payout surface:

- **Provider portals + wallets (signers of §3.2 EIP-712 messages)** —
  semi-trusted. A malicious provider can submit any bytes that match
  the §3.3 wire format AND ecrecover to itself. The proof-of-
  possession contract is "we will pay you at the address you signed
  for; the registered address MUST be one you control."
- **An attacker holding a stolen `provider_token`** — the §3.2
  EIP-712 proof-of-possession is the closing-of-the-stolen-token
  pivot from credential theft to fund theft. If EIP-712 verification
  is wrong, a stolen token becomes a USDC-drain primitive.
- **Operator-key holder** — semi-trusted. SPEC §4.8a outbox + §4.9
  bootstrap-window narrowing exist to bound operator-key compromise
  blast radius. Step 1 does NOT mount the operator-key admin
  endpoints (those land in Steps 3 / 4), but the schema migrations
  Step 1 ships are the foundation those steps will lean on.
- **Coordinator administrators** — trusted.

This is money-OUT code. A defect here can drain a hot wallet that
holds operator USDC. **Be paranoid.**

## Required reading (in this order)

1. The Step 1 commit:
   - `git show 1df0235`
   The commit body summarises every change; treat it as a
   non-binding map.

2. The IMPL kickoff prompt that authored Step 1:
   - `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` §1 (pre-flight),
     §2 "Step 1" entry (the binding scope + AC list + test corpus),
     §3 (audit-loop discipline), §5 (repo layout), §6 (existing
     primitives), §10 (what you must NOT do).

3. The SPEC (READ-ONLY, do not edit):
   - `specs/SPEC-016-payout-pipeline.md` v0.1.21 — focus on:
     - §3.1 storage (the `provider_payout_addresses` schema, same-DB
       pin, PRAGMA assertions)
     - §3.2 address validation (EIP-55, EIP-712 typed-data + field-
       by-field equality, anti-replay table)
     - §3.3 registration / rotation endpoint (path-table, pre-auth
       pause check, TOCTOU re-check inside BEGIN IMMEDIATE,
       DisallowUnknownFields prohibition, response codes)
     - §3.4 rotation audit (audit-log event field set, fingerprint
       discipline)
     - §3.5 settlement gate (the SELECT-side filters Step 2 will
       use; Step 1's job is to make those filters expressible)
     - §4.1 package layout + cross-package boundary
     - §4.5 (`payout_attempts` schema + seven indexes incl. two
       partial UNIQUE)
     - §4.7 (`payout_reorg_orphans` schema; observed_* snapshot
       columns are normative)
     - §4.8 (`payout_runner_state` + three bootstrap triggers;
       startup INSERT OR IGNORE)
     - §4.8a (`runtime_flags` + outbox + sentinel; bootstrap-seed
       action table; intra-transaction trigger-presence
       requirements)
     - §4.8b (`payout_runner_lease` schema; zero-row default)
     - §4.8c (`cancel_reconfirm_stale_outbox` schema)
     - §4.9 (`payout_hot_wallet_funding` schema + UNIQUE(tx_hash))
     - §6.5 (only the §6.5 "security namespace is IMMUTABLE-at-
       startup" assertion against Step 1's `config_security.go` —
       the full dual-loader split is Step 4 and out of scope here)
   - The audit-round narrative files
     `specs/SPEC-016-r9-audit.md` through
     `specs/SPEC-016-r21-audit.md` contain the *why* for many
     normative requirements; skim them when a SPEC paragraph looks
     defensive in a way you don't immediately understand.
     `specs/SPEC-016-r20-audit.md` is the Claude-side cross-check
     and `specs/SPEC-016-r21-audit.md` is the codex fix-pass; both
     produced the v0.1.20 → v0.1.21 deltas summarised above.

4. The existing primitives Step 1 builds on:
   - `phase4-coordinator/internal/billing/store.go:100-127` —
     `ledger_payout_ready` schema + `trg_lpr_terminal_status_guard`
     (SPEC-005-shipped; SPEC-016 §9.5b.1 binds SPEC-005 vX.Y+1 to
     this exact trigger name; Step 1 must not rename or drop it).
   - `phase4-coordinator/internal/billing/payout.go:10` — the
     `ClaimPayoutReady` method Step 2 will invoke.
   - `phase4-coordinator/internal/auth/tokens.go:247` —
     `provider_tokens` (the SPEC-016 §3.2 step 3 identity surface).
   - `phase4-coordinator/internal/sqliteutil/dsn.go` — the shared
     SQLite DSN. Step 1 changed `synchronous=NORMAL` → `FULL` per
     SPEC §3.1; this is a CROSS-CUTTING change that affects
     requestlog / billing / audit write throughput. See dimension 3
     "DSN durability bump" below.

## What Step 1 added (files / approximate line counts)

Production code:
- `phase4-coordinator/internal/payout/migrations/0001..0008.sql`
  (8 migration files; total ~150 LOC of DDL)
- `phase4-coordinator/internal/payout/migrations/embed.go` (~10 LOC,
  `//go:embed *.sql`)
- `phase4-coordinator/internal/payout/migrations.go` (~170 LOC —
  Migrate, AssertPragmas, AssertSameDB, AssertTriggersPresent)
- `phase4-coordinator/internal/payout/config_security.go` (~50 LOC)
- `phase4-coordinator/internal/payout/eip55.go` (~110 LOC)
- `phase4-coordinator/internal/payout/eip712.go` (~220 LOC)
- `phase4-coordinator/internal/payout/deny.go` (~70 LOC)
- `phase4-coordinator/internal/payout/errors.go` (~25 LOC)
- `phase4-coordinator/internal/payout/addresses.go` (~520 LOC — the
  §3.3 handler + state)
- `phase4-coordinator/internal/payout/mux.go` (~120 LOC — chi
  router + path-table verify)
- `phase4-coordinator/internal/payout/bootstrap.go` (~190 LOC —
  three-table-empty seed gating + sentinel-asymmetry detection)
- `phase4-coordinator/internal/payout/pause_reader.go` (~45 LOC)
- `phase4-coordinator/internal/billing/payout_address_reader.go`
  (~30 LOC — interface DECLARED in billing/)
- `phase4-coordinator/internal/sqliteutil/dsn.go` (~10 LOC delta —
  the durability bump)
- `phase4-coordinator/internal/config/config.go` (~50 LOC delta —
  PayoutConfig struct + validation)
- `phase4-coordinator/cmd/coordinator/main.go` (~110 LOC delta —
  setupPayout helper + payout-nonce pruner + wiring on the
  provider listener)

Tests (under `phase4-coordinator/internal/payout/`):
- `testing_helpers_test.go`
- `eip55_test.go` (3 tests — official EIP-55 vectors)
- `eip712_test.go` (5 tests — happy + 4 rejection branches)
- `migrations_test.go` (4 tests — idempotency, partial UNIQUE,
  one-way trigger, AssertPragmas)
- `bootstrap_test.go` (5 tests — first-init seed, normal restart,
  sentinel asymmetry both directions, InitRunnerStateRow
  idempotency)
- `addresses_test.go` (6 tests — happy path, pre-auth 503, TOCTOU
  re-check, anti-replay, decorative-field replay rejection,
  deny-list, skew window)
- `mux_test.go` (3 tests — path-table consistency, fallback
  delegation, escaped-URL non-collapse)
- `importgraph_test.go` (1 test — billing/ does not import payout/)

## Audit dimensions

> **Lane-split note (2026-06-25):** the dimension focus-area lists
> below are the canonical source of truth for what each lane
> audits. The lane prompt files
> (`AUDIT_SPEC_016_IMPL_STEP_1_{CODE,SECURITY,ARCH}_PROMPT.md`)
> reference these focus-area sections directly. Do not fire this
> file as a single prompt — the three lanes run in parallel
> against the three dimensions.

You will perform **three dimensions** of review and emit findings
in the format below each. Under the parallel-lane fan-out, each
lane attends to ONE dimension only.

### Dimension 1: CODE REVIEW

Focus areas:

- **Migration byte-identity vs SPEC.** Every CREATE TABLE / INDEX /
  TRIGGER in `internal/payout/migrations/0001..0008.sql` MUST match
  the SPEC §3.1 / §3.2 / §4.5 / §4.7 / §4.8 / §4.8a / §4.8b / §4.8c
  / §4.9 DDL byte-for-byte (modulo whitespace + comments). Diff each
  CREATE statement against the SPEC text. Flag any column rename,
  reordering, default-value drift, CHECK-constraint drift, or index
  name drift.

- **EIP-55 canonicalisation.** `eip55.go` implements the
  pure-lowercase / pure-uppercase / mixed-case branches. Verify
  against the EIP-55 reference vectors at
  https://eips.ethereum.org/EIPS/eip-55#test-cases (the test file
  already includes them; check the IMPL handles all eight). Look
  particularly for off-by-one in the nibble-extraction loop.

- **EIP-712 typed-data hash.** `eip712.go` precomputes
  `domainTypeHash` and `payoutAddressRegistrationTypeHash` from
  literal strings. Verify the strings byte-match SPEC §3.2 step 5:
  `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)`
  and
  `PayoutAddressRegistration(string providerId,address address,string chain,bytes32 nonce,uint64 tsUtc)`.
  Off-by-one in field names, capitalisation, or whitespace silently
  invalidates every signature without the test corpus catching it
  (because the same wrong string is used to sign AND verify).
  Compute the hashes by hand if you can.

- **EIP-712 wire-format conversion.** `decodeSignatureHex` reorders
  the wire `r||s||v` to decred's `v||r||s` for RecoverCompact, and
  enforces v ∈ {27, 28}. Verify the byte arithmetic AND that v=0/1
  rejection is correct for Ethereum's EIP-712 surface. Flag if the
  IMPL should accept {0, 1} too (it should NOT — see the comment in
  `decodeSignatureHex` for the rationale).

- **EIP-712 field-by-field equality at the handler boundary.** SPEC
  §3.2 step 5 demands the handler verify EVERY typed-data field
  against the request body's field. The IMPL puts the verification
  inside `VerifyEIP712`, which receives `EIP712Inputs` constructed
  from the body. Trace each input field — `providerID`, `chain`,
  `nonce`, `ts_utc`, `address`, `verifyingContract` — back to the
  request body and confirm each is byte-equal-asserted. Note that
  the handler does not explicitly re-check `inputs.ProviderID ==
  req.providerID` etc. because the inputs ARE the body — but verify
  that's enough: a sneaky cast or copy that silently normalises a
  field would defeat the discipline.

- **TOCTOU pause re-check uses BEGIN IMMEDIATE.** The handler calls
  `conn.ExecContext(ctx, "BEGIN IMMEDIATE")` after `db.Conn(ctx)`.
  Verify modernc.org/sqlite honors this (vs surfacing it as a
  `transaction within a transaction` error). Cross-check with the
  existing `internal/auth/tokens.go:927` pattern — same DB, same
  driver. If `BEGIN IMMEDIATE` is silently downgraded to DEFERRED,
  the re-check still reads the latest value but does NOT take the
  write-intent lock, leaving a tiny window where two concurrent
  registration calls race the pause flip. Run
  `go test -race ./internal/payout/...` to see if the race detector
  surfaces anything.

- **DisallowUnknownFields prohibition.** SPEC §3.4 / §3.3 prohibits
  `DisallowUnknownFields` on the §3.3 decoder because the silent-
  ignore of `registered_against_hot_wallet` is load-bearing for the
  probing defense. Confirm the IMPL's decoder omits this option AND
  the `registerRequest` struct does not include
  `registered_against_hot_wallet`. Probe for any future API
  middleware that might apply `DisallowUnknownFields` globally.

- **Same-DB pin coverage.** `AssertSameDB` enumerates a list of
  tables. Verify each of the §3.1 / §4.7 / §4.8a / §4.8b / §4.9
  same-DB-pinned tables appears in `payoutTables`, and that the
  walker checks via `main.sqlite_master`. Also verify the function
  rejects ATTACHed databases (the `databases != 1` branch).

- **Trigger-presence list completeness.** `RequiredTriggers`
  enumerates the four SPEC §4.8a + §4.7 mandated triggers
  (`trg_prs_bootstrap_one_way`, `trg_pa_bootstrap_flip`,
  `trg_pa_bootstrap_flip_insert`, `trg_lpr_terminal_status_guard`).
  Confirm the list matches the SPEC L2492-L2495 set exactly. The
  intra-transaction trigger-presence check at the §4.9 manual-
  funding gate and the §4.3 step 8 ClaimPayoutReady boundary lands
  in Steps 3 / 2 — Step 1's startup check is the first line. Flag
  if Step 1's startup check is missing any trigger that Steps 2/3
  will need to assert intra-transaction.

- **Bootstrap-seed action table.** `BootstrapRuntimeFlags` encodes
  the SPEC §4.8a four-row action table. Walk the four branches:
  (1) all-three-empty → seed; (2) sentinel-NONEMPTY + flag-EMPTY →
  HALT `runtime_flag missing`; (3) sentinel-EMPTY + flag-NONEMPTY-OR-audit-NONEMPTY →
  HALT `runtime_flags_bootstrap_sentinel_missing`; (4) bootstrapped-
  NONEMPTY + flag-NONEMPTY → skip. Confirm the IMPL implements all
  four branches without a default fall-through to "seed". Flag if
  the sentinel-asymmetry detection direction is inverted in either
  case (look for `runtime_flags_bootstrapped` empty/nonempty
  semantics confusion).

- **payout_runner_state INSERT BEFORE runner.Start.** SPEC §4.8
  requires `INSERT OR IGNORE INTO payout_runner_state` to run in
  `main.go` BEFORE the runner constructs its goroutines. Step 1
  does not start the runner (that's Step 2) but the INSERT must
  still happen for the bootstrap-flip triggers to find a row when
  they fire. Confirm `setupPayout` invokes `InitRunnerStateRow`
  unconditionally (regardless of `payout.enabled`) so a future
  enable-flip doesn't have to migrate state.

- **Anti-replay table lifecycle.** Step 1 ships the
  `provider_payout_address_nonces` PK on `(canonical_address,
  nonce)` AND the background pruner that deletes entries older
  than 10 minutes. Verify the bound is `min(skew_window,
  prune_retention)` — 5min skew + 10min retention = effective
  10-min window with the skew check + replay table. Increasing
  either without the other re-opens the replay window. Flag if a
  future code path could lift one without the other.

- **DSN durability bump.** Step 1 changed
  `synchronous=NORMAL` to `FULL` in `internal/sqliteutil/dsn.go`.
  This affects every coordinator package that shares the DB
  (requestlog, billing, audit, admission, auth tokens, payout).
  SPEC §3.1 explicitly requires FULL for connections touching
  `provider_payout_addresses` or `payout_attempts`. Because the
  coordinator uses one shared `*sql.DB`, the only way to satisfy
  the per-connection SPEC requirement is to set the DSN globally.
  Quantify the regression risk: how much does NORMAL→FULL slow
  the request-log write hot-path on a typical MacBook SSD?
  Check whether any test now flakes from increased fsync latency.
  If the regression is unacceptable, suggest an alternative (e.g.
  a per-conn callback that sets FULL only on the conn pool the
  payout package owns) and quantify the complexity / correctness
  trade-off.

- **chi path-table verification.** `verifyPathTable` walks the
  registered routes and asserts parity with `step1PathTable`.
  Verify the walk correctly excludes the `/providers/*` wildcard
  fallback (it is registered with chi via `HandleFunc` so it
  surfaces in `chi.Walk`). Probe whether a future Step 2 / 3
  addition would silently slip past — e.g. if a new route uses
  `r.MethodFunc` or `r.Handle` instead of the verb-shaped
  registration. Confirm the audit assertion catches new routes,
  not just missing ones.

- **Address fingerprint discipline.** `addressFingerprint` claims
  to defeat raw-bytes log-injection by rejecting non-hex
  submissions. Confirm the function is the only path that emits
  the submitted address into a log line. Probe whether any
  `s.Log.Info().Str("address", ...)` call site echoes raw user
  input that bypasses the fingerprint.

- **`payout.enabled=false` posture.** When the flag is false,
  Step 1 still applies migrations + asserts + bootstrap-seed but
  does NOT mount the §3.3 handler. Confirm a future operator who
  flips the flag does not need a schema migration window — the
  schema is already applied; only the handlers light up. Flag if
  the order of `setupPayout` operations leaves any partial state
  on flip.

Findings format:

```
[code:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <one-paragraph description of the issue>
  Why: <impact — what breaks, when, and how bad>
  Fix: <suggested remediation; cite the binding SPEC rule if applicable>
```

### Dimension 2: SECURITY REVIEW

Threat models recap:

- **Adversary A — stolen `provider_token`.** Owns a valid provider
  token but does NOT own the wallet at the address being
  registered. The EIP-712 proof-of-possession is the gate; if the
  IMPL accepts a forged or replayed signature, the attacker drains
  the next payout cycle.
- **Adversary B — malicious portal / on-path attacker.** Intercepts
  a legitimate provider's signed registration request and replays
  it with a different `chain`, `ts_utc`, or `verifyingContract`.
  If the typed-data field-by-field equality discipline is wrong,
  the attacker pivots to a fresh effective replay.
- **Adversary C — DoS attacker.** Submits high volumes of well-
  formed-but-signature-invalid requests. The nonce table grows,
  the deny-list test runs, the EIP-712 keccak runs (~32MB/s
  on commodity hardware). Verify the pre-auth checks defang
  unauthenticated burst before EIP-712 verification spends CPU.
- **Adversary D — operator-key compromise (Step 1 scope-limited).**
  Step 1 does NOT mount operator-key admin endpoints (Steps 3 / 4
  do); the schema migrations Step 1 ships are the foundation for
  later attestation. If a §4.8a `runtime_flags` row is writable
  via a direct DB connection an attacker could bypass §6.4.1 paths.

Focus areas:

- **EIP-712 verification end-to-end.** Re-derive the digest for the
  IMPL's happy-path vector by hand. The known private key in
  `eip712_test.go` (`59c6...690d`) corresponds to a known signer
  address — recompute it (keccak256 of uncompressed pubkey X||Y,
  take last 20 bytes). Recompute the EIP-712 digest from the test
  inputs and confirm decred's RecoverCompact yields the same
  signer. Flag any divergence — the test could be self-consistent
  on the IMPL's own primitives but wrong against an independent
  reference (e.g. ethers.js's signer.signTypedData would yield a
  different signature).

- **Decorative-field replay.** SPEC §3.2 step 5 explicitly cites
  the decorative-field replay class. The handler MUST verify that
  every typed-data field — `providerId`, `address`, `chain`,
  `nonce`, `tsUtc`, `verifyingContract` — corresponds to the
  request-body field of the same name. Confirm: a request whose
  body `nonce` differs from the typed-data `nonce` is rejected
  (the test asserts this). What about a body whose `chain` is
  `"BASE-MAINNET"` (uppercase) but the typed-data chain is
  `"base-mainnet"` — is the case-fold handled correctly via
  keccak256 of the UTF-8 bytes? Pure case-sensitive byte match
  is the correct discipline. Probe `Chain` and `ProviderID`.

- **Cross-provider replay table scoping.** SPEC §3.2 step 5 says
  the anti-replay table PK is on `(canonical_address, nonce)` —
  NOT `provider_id`. Confirm the IMPL respects this. Verify what
  happens if Alice's signature is replayed under Bob's
  provider_id: ecrecover yields Alice's address (the signer), the
  body's `providerId` field equals Bob (from URL path), the
  typed-data `providerId` equals Alice (decorative-field check
  catches it). But the anti-replay table doesn't catch it
  because nonces are signer-scoped. Confirm the catch-stack is
  complete (decorative-field check is the load-bearing one
  here).

- **EIP-55 backward-compat for pure-uppercase + pure-lowercase.**
  SPEC §3.2 step 2 says both are accepted with checksum SKIPPED.
  Verify the IMPL's branches: a mixed-case input that happens to
  satisfy `pureLower || pureUpper` somehow (impossible per the
  branch logic but probe) MUST go through the checksum check.
  Confirm `pureLower` and `pureUpper` cannot both be true (only
  when the hex body is all-digits — which is fine because the
  EIP-55 algorithm leaves digits unchanged so the checksum form
  IS the lowercase form). No regression possible there.

- **EIP-712 RecoverCompact edge cases.** decred's RecoverCompact
  succeeds on certain inputs that don't correspond to legitimate
  Ethereum signatures — e.g. recovery codes that produce non-
  canonical points. Verify the implementation rejects v outside
  {27,28} (it does — `decodeSignatureHex` enforces this), but
  also verify it doesn't accept compressed-pubkey variants
  (v ∈ {31,32}) silently. Probe with crafted signatures.

- **Bearer extraction strict-trimming.** `bearerFromHeader`
  uses `strings.TrimSpace`. Verify it doesn't accept multi-line
  bearer headers (Go's net/http strips CR/LF already, so this is
  mostly safe — but if a future middleware allows folded
  headers, a token-injected attack class opens). Flag if any
  custom Authorization-header path could bypass this.

- **Anti-replay DoS surface.** The pruner runs every minute and
  deletes entries older than 10 minutes. An attacker submitting
  6 valid signatures/minute (the rate limit isn't ours to check
  in Step 1; SPEC says 6/hr — but if the rate limit is wired in
  Step 2+) could grow the table to 60 entries every 10 min,
  bounded by the cleanup. Compute the worst-case table size at
  the SPEC's allowed throughput (1 request/sec × 600 sec
  retention = 600 entries max during the window). Confirm the
  table cannot grow unbounded under adversarial nonce values.

- **Migrations executed on operator-controlled DB file.** A
  hostile operator who pre-creates `payout_attempts` with
  malicious indexes BEFORE Step 1 migrates would slip past
  `CREATE INDEX IF NOT EXISTS`. Verify whether SPEC §4.8a's
  `RequiredTriggers` assertion catches a tampered DB at startup
  — if not, document the residual risk. (Note: Step 1 is the
  first deployment to ship these schemas, so the threat is
  hypothetical for the cutover. Future operator-DB-corruption
  recovery scenarios would re-expose it.)

- **PRAGMA synchronous=FULL on every connection.** The pragma is
  set per-DSN. modernc.org/sqlite applies it on every new
  connection in the pool. Verify by spinning up multiple
  goroutines that each open a transaction and reading their
  per-conn PRAGMA value. Flag if any connection silently runs
  with NORMAL — the §4.x atomicity arguments depend on FULL.

- **Pre-auth pause check bypass timing.** SPEC §3.3 requires the
  pre-auth pause check to defang response-code timing
  oracles — an unauthenticated and an authenticated request must
  produce identical 503 bodies during pause. Verify the IMPL's
  response body matches exactly across the two callsites (the
  pre-auth path AND the in-txn re-check path emit the same
  `{"error":"rotation_in_progress"}` body). Probe via
  `curl -s -w '%{time_total}'` to compare timing — if the
  pre-auth path runs noticeably faster, an attacker could
  distinguish (the IMPL passes here because the DB read is the
  same on both sides; flag if a future optimisation diverges).

Findings format:

```
[sec:N.M] [SEVERITY] <short title>
  Asset: <what's at risk>
  Vector: <how the attacker exploits it>
  File: <path>:<line>
  Fix: <suggested remediation>
```

### Dimension 3: ARCHITECTURE REVIEW

Focus areas:

- **billing/ → payout/ import direction.** SPEC §4.1 normative.
  The IMPL audit includes an import-graph test
  (`importgraph_test.go`). Verify the test catches transitive
  imports too (not just direct). Specifically: if billing/ ever
  imports a sub-package that imports payout/, the test must
  trip. `go/build` returns the transitive list — confirm the
  test walks it.

- **Same-`*sql.DB` handle discipline.** SPEC §4.8a / §4.8b
  require sharing one `*sql.DB` handle across runner +
  endpoints + lease. Step 1 only mounts the §3.3 handler; the
  runner + lease land in Step 2. Confirm the `setupPayout`
  helper signature accepts the shared handle and that nothing
  in Step 1 grabs a second `sql.Open` (which would defeat
  same-conn-pool semantics).

- **Config namespace split.** Step 1 introduces `PayoutConfig
  {Enabled, Security{HotWalletAddress}, Tuning{AddressCoolingOffPeriod}}`.
  SPEC §6.5 dictates a three-way split (`payout.security.*`
  immutable, `payout.tuning.*` SIGHUP-reloadable, `runtime.*`
  closed). Step 1's struct is the seed; Step 4 will grow it.
  Confirm Step 1 does NOT plumb `payout.security.*` through a
  reload path (no SIGHUP / fsnotify watcher on Security). Probe
  whether a future contributor could accidentally hot-reload
  `HotWalletAddress` by adding a setter — the struct lacks one
  but Go does not prevent reflection-style access. Flag if
  comment discipline insufficient to communicate the
  invariant.

- **chi router placement on the provider listener.** The IMPL
  mounts `chi.NewRouter()` under the provider listener at
  `/providers/` — replacing the prior direct `billingHandler`
  registration. Verify the existing `/providers/{id}/earnings`
  billing path still resolves through the chi fallback. The
  `TestMux_FallbackForNonPayoutProvidersPath` test asserts
  this, but probe edge cases: `/providers/foo/earnings/`
  (trailing slash), `/providers/`, `/providers/foo`
  (no /earnings).

- **payout package internal structure.** Step 1 splits payout/
  into ~13 files. Is the split clean — config, schema, EIP-55,
  EIP-712, deny, errors, addresses, mux, bootstrap, pause,
  migrations? Compare to the SPEC §5 IMPL prompt repo-layout
  table; is anything Step 1 added meant to live elsewhere? Are
  the helpers (`bearerFromHeader`, `clientIP`, `orNone`,
  `statusName`, `writeError`, `writeJSON`, `jsonString`,
  `isUniqueViolation`) properly scoped — or are they too
  package-private to reuse in Steps 2-4?

- **Testing surface vs SPEC test-corpus list.** The IMPL prompt
  Step 1 test corpus lists 7 minimums. Walk each one:
    1. Schema migration up + down idempotent — partial test
       (idempotency yes; down NOT tested. Step 1 SQL lacks
       DOWN migrations; SPEC does not require them; confirm
       this is an intentional omission).
    2. Partial UNIQUE index enforced — tested.
    3. EIP-712 vector: known key signature verifies — tested.
    4. EIP-712 vector: wrong `verifyingContract` rejected — tested.
    5. EIP-712 vector: wrong `nonce` typed-data rejected — tested.
    6. TOCTOU race — tested via the toctouPause fake.
    7. Anti-replay — tested.
    8. Bootstrap-seed gating — tested across all four action-
       table branches.
    9. Sentinel asymmetry both directions — tested.
    10. Trigger-presence at startup — tested via the
        `TestMigrate_Idempotent` AssertTriggersPresent call.
    11. Co-residency — UNTESTED. SPEC §3.3 normative requires
        a deployment-mode check that fails-fast if the runner
        is configured to a different process. Step 1 has no
        runner so the check is not exercisable yet — but the
        SPEC text demands a startup assertion regardless.
        Flag whether this should land in Step 1 or wait for
        Step 2's runner introduction.

- **DSN durability bump: scope tradeoff.** This is the single
  most cross-cutting change in Step 1. Should it have landed
  here, in a separate prep PR, or be reverted in favour of a
  payout-scoped conn pool? Quantify the alternatives:
    - **Option A (current):** Global DSN → FULL. All requestlog
      / billing / audit writes pay the fsync cost.
    - **Option B:** Per-conn callback that sets FULL only on
      payout-package operations. Requires distinguishing
      "payout txn" from "billing txn" at the connection level
      — modernc doesn't surface that cleanly.
    - **Option C:** Separate `*sql.DB` for payout. Breaks
      SPEC §4.7 / §4.8 / §4.9 same-DB pin (the §9.5b.1
      SPEC-005 admin endpoint must be transactionally atomic
      with `payout_reorg_orphans` in the SAME txn).
  The IMPL chose A. Confirm A is the right tradeoff and flag
  if you disagree.

- **Step 1 → Step 2 readiness.** Step 2 lands the runner cycle,
  Signer interface, two-RPC confirmation, and §4.6 abandon
  endpoint. Are Step 1's primitives ready?
    - `payout_attempts` schema includes all columns Step 2's
      INSERTs will use? Check the §4.3 step-5 SQL against the
      schema (`payout_id`, `attempt_seq`, `chain`,
      `from_address`, `to_address`, `amount_base_units`,
      `nonce`, `raw_signed_tx`, `tx_hash`, `broadcast_at_utc`,
      `confirmed_at_utc`, `block_number`,
      `gas_used_native_wei`, `is_cancel_self_transfer`,
      `last_error`, `abandoned_at_utc`, `abandoned_reason`,
      `cancel_reconfirm_stale_paged_at_utc`, `updated_at_utc`).
    - Does `LookupPayoutAddress` return enough info for Step
      2's §4.3 step 1 SELECT? Step 2's SELECT uses the
      `CASE WHEN ... THEN ppa.rotated_from ELSE ppa.address END
      AS effective_address` projection that the IMPL's
      LookupPayoutAddress does NOT replicate — but Step 2's
      SELECT is a JOIN against `ledger_payout_ready` and likely
      lives in payout/, not billing/. Confirm
      `LookupPayoutAddress` is for cross-package
      consumption only (read-side mirror for billing), not the
      runner's actual SELECT.
    - Is the `payout.tuning.address_cooling_off_period` plumbed
      so Step 2 / 4 can extend the tuning struct without
      breaking the Step 1 wiring?

- **Co-residency invariant communication.** SPEC §3.3 demands
  a startup assertion that the runner and the handler are in
  the same process. Step 1 has no runner. Step 2 will install
  the runner; will Step 2's wiring trip if a future operator
  splits handler and runner across processes? Flag if Step 1
  should have a placeholder assertion.

- **Documentation discipline.** Verify the binding SPEC rule
  citations in code comments are adequate for the post-merge
  reviewer working only from code. Specifically:
    - `addresses.go` ServePayoutAddress: are the 11 pipeline
      stages well-commented with SPEC §-references?
    - `eip712.go` buildDigest: is the encoding scheme
      attributable to EIP-712 §4?
    - `bootstrap.go` BootstrapRuntimeFlags: does the four-
      branch action table comment match the SPEC L2319-L2336
      table?

Findings format:

```
[arch:N.M] [SEVERITY] <short title>
  What: <one-paragraph description>
  Trade-off: <what's gained vs lost by the current choice>
  Suggestion: <a concrete refactor or follow-up; NOT required for
              merge unless the severity says so>
```

## Severity scale (consistent across all three dimensions)

- **CRITICAL** — money loss vector, signature-verification bypass,
  silent migration corruption, or any defect that would let a
  stolen `provider_token` register a wallet the holder doesn't
  control. MUST be fixed before pushing the branch.
- **MAJOR** — real bug with confirmed reproduction, but not on the
  money path. SHOULD be fixed before merge OR explicitly deferred
  to a follow-up tracked in `specs/SPEC-016-payout-pipeline.md`
  Appendix B.
- **MEDIUM** — defect or deviation from the SPEC that would survive
  to production but does not obviously enable an exploit or break
  an invariant immediately. Fix before merge OR Appendix B.
- **LOW** — style, idiom drift, missing comment, naming
  inconsistency. MAY be deferred with explicit justification per
  the audit-loop discipline.

The audit-loop discipline at `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`
§3 requires 0 CRITICAL / 0 MAJOR / 0 MEDIUM before push / PR. LOW
findings MAY be deferred to Appendix B.

## Output format

Return your findings as a single Markdown document at
`specs/SPEC-016-IMPL-STEP_1-audit.md` (per
[[feedback-spec-audit-file-convention]]) with the following
structure:

```
# SPEC-016 IMPL Step 1 audit — codex GPT-5 round 1

## Verdict

<one-line summary: PROCEED-TO-STEP-2-ON-SAME-BRANCH | FIX-THEN-PROCEED | BLOCK>
(Note: no push / PR yet — Steps 2 / 3 / 4 land as additional commits
on `impl/spec-016` per the operator's single-PR plan.)

## Counts

| Dimension    | CRITICAL | MAJOR | MEDIUM | LOW |
|--------------|----------|-------|--------|-----|
| Code         | <N>      | <N>   | <N>    | <N> |
| Security     | <N>      | <N>   | <N>    | <N> |
| Architecture | <N>      | <N>   | <N>    | <N> |
| **Total**    | <N>      | <N>   | <N>    | <N> |

## Findings

### Code review

[code:1.1] [SEVERITY] ...
...

### Security review

[sec:1.1] [SEVERITY] ...
...

### Architecture review

[arch:1.1] [SEVERITY] ...
...

## AC traceability check

| AC (from IMPL prompt Step 1 "ACs touched") | Where satisfied | Test name |
|---|---|---|
| Address registration end-to-end                | <file:line> | <test> |
| EIP-712 verification                           | <file:line> | <test> |
| Deny-list                                      | <file:line> | <test> |
| Cooling-off `pending_until_utc`                | <file:line> | <test or deferred> |
| Persistent `runtime.registration_paused`       | <file:line> | <test> |
| Schema presence + trigger-presence at startup  | <file:line> | <test> |

A row marked "deferred to Step 2/3/4" is fine if the SPEC genuinely
defers it. A blank row OR a "missing" row is a finding.

## SPEC drift catalog

Any normative paragraph in SPEC-016 §§3–3.4 / 3.5 / 4.1 / 4.5 / 4.7
/ 4.8 / 4.8a / 4.8b / 4.8c / 4.9 / 6.5 (Security-immutability
sub-rule only) that Step 1 does NOT implement faithfully. Cite
SPEC line numbers and IMPL file:line.

## What I didn't review

<list of files / areas you intentionally skipped, with rationale>

## Cross-cutting observations

<any patterns that span multiple findings>
```

## Discipline

- Be specific. Cite `<file>:<line>` for every finding.
- Be conservative on CRITICAL. A finding is only CRITICAL if you
  can describe the concrete failure mode AND its impact in one
  sentence.
- Be honest about uncertainty. If you suspect an issue but cannot
  confirm without running the code, mark it as MAJOR with a
  "needs verification" tag rather than CRITICAL.
- Do not invent findings to fill quota. If a dimension yields zero
  findings, report zero. Finding nothing IS a valid result on a
  Step 1 commit if Step 1 actually got the SPEC right.
- Cite the binding SPEC rule when claiming a violation.
- For security findings, model the attacker explicitly. Without
  the attacker model, it is just a code smell.

You may run shell commands to explore the repo (git log, grep,
find, file inspection, `go vet`, `go test -count=1 ./...`,
`go test -race ./internal/payout/...`). You MUST NOT modify any
file. Cap shell output volume.

You may take up to 60 minutes wall-clock. If you finish earlier
with a clean report, that's fine; do not pad.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- This is the **Step 1 of 4** mid-stream audit per the IMPL prompt's
  §2 decomposition. Step 1 covers schema + §3 registration + §3.2
  EIP-712. Steps 2 / 3 / 4 each get their own narrow audit prompt
  authored at the end of their respective IMPL stretches.
- Expected wall-clock: 40–60 min. Surface is moderate (~1.5k net
  production LOC + 11 schema files + 32 new tests) but the SPEC
  citation density is HIGH (~10 SPEC subsections plus 11 audit-
  round narrative files).
- If codex returns CRITICAL / MAJOR / MEDIUM findings, draft a
  focused fix-pass on `impl/spec-016` (do NOT branch out) and
  re-fire this audit prompt with the round number incremented
  (`SPEC-016-IMPL-STEP_1-r2-audit.md`, etc.) per
  [[feedback-spec-audit-file-convention]]. Loop until 0/0/0/0.
- LOW findings MAY be deferred to
  `specs/SPEC-016-payout-pipeline.md` Appendix B per
  [[tracking-issue-scope-control]].
- After 0/0/0/0 convergence + smoke check, **proceed directly to
  Step 2 IMPL on the same `impl/spec-016` branch.** Do NOT push,
  do NOT open the PR yet — Steps 2 / 3 / 4 land as additional
  commits, each with its own narrow audit prompt + loop, and the
  PR opens once after Step 4's audit converges. The SPEC-005
  admin endpoint hard prereq at §9.5b lands as a SEPARATE SPEC
  PR; do NOT bundle.
- The `/code-review ultra` parallel-fleet pass is the third
  defense and runs on the final PR AFTER all four codex loops
  (Steps 1 / 2 / 3 / 4) have each converged to 0/0/0/0.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-016 v0.1.21 IMPL Step 1.
