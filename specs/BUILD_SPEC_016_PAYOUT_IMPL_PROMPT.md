# BUILD_SPEC_016_PAYOUT_IMPL — Provider payout pipeline (USDC on Base) implementation (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing any code.**

Your job is to implement [`specs/SPEC-016-payout-pipeline.md`](SPEC-016-payout-pipeline.md) — the
provider payout pipeline that converts `ledger_payout_ready`
rows into USDC transfers on Base mainnet (chain id 8453).
The SPEC is the **single controlling contract** for this
work; every section of this prompt cites SPEC-016 §-numbers
and you MUST verify those §-references against the merged
SPEC at HEAD before encoding them.

## 0. Controlling contract

- **SPEC:** [`specs/SPEC-016-payout-pipeline.md`](SPEC-016-payout-pipeline.md)
  at v0.1.x (LOCKED at v0.1.19 on commit `5c034a0` on `main`,
  byte-identical normative content to v0.1.17 which codex
  round-19 declared CONVERGED at 0/0/0 over 11 codex rounds
  plus 8 prior Claude rounds). Re-read every "MUST / MUST NOT
  / SHOULD" in the SPEC before you write the corresponding
  IMPL code. Every section heading referenced below
  (`§3`, `§4.3`, `§4.8b`, etc.) points at the merged SPEC.
- **Per-round audit detail:** [`specs/SPEC-016-r9-audit.md`](SPEC-016-r9-audit.md)
  through [`specs/SPEC-016-r19-audit.md`](SPEC-016-r19-audit.md).
  Skim these for the *why* behind individual SPEC requirements
  — many normative paragraphs are written to close a specific
  finding (e.g. round-14 MAJOR-1 confused-deputy class,
  round-15 MAJOR-2 cancel-reorg carve-out).
- **Decision rationale (rail = USDC on Base):**
  [`beta/DECISION_CRITERIA.md`](../beta/DECISION_CRITERIA.md)
  Entry 88 records why USDC-on-Base, why no `PayoutAdapter`
  abstraction, and why the SPEC is design-only until the
  operator discharges §9. **DO NOT re-litigate any of those
  decisions in this IMPL.**

**The IMPL author's job is to encode the SPEC, not to
re-question it.** If you find yourself disagreeing with a
normative requirement, STOP and surface the disagreement
to the operator — do NOT silently deviate. If you find an
ambiguity, file a SPEC v0.2 candidate; do NOT resolve it
in code.

## 1. Pre-flight checklist — §9 operator-action prerequisites

**SPEC-016 [§9](SPEC-016-payout-pipeline.md) is unambiguous:
"IMPL MUST NOT begin until ALL EIGHT prerequisites are
discharged."** That gate is binding on this prompt — do
NOT start writing code (not even Step 1 schema) until every
box below is checked. The earlier draft of this prompt
permitted "code can land on `main` with `payout.enabled:
false`" and "Steps 1-3 can proceed without §9.1 / §9.2 /
§9.5b"; both carve-outs were CRITICAL findings in the
round-1 codex audit (see
[`specs/SPEC-016-IMPL-PROMPT-audit.md`](SPEC-016-IMPL-PROMPT-audit.md)
C1) and have been removed. The SPEC blocks the IMPL until
the operator discharges all eight items; the operator-side
work runs first, and the IMPL session is kicked off after
the checklist is complete.

1. **[§9.1] Hot wallet provisioned + funded.** Fresh Base
   address (or single-purpose existing address). Funded with
   USDC for initial smoke (~100 USDC) and ~0.005 ETH for gas
   headroom. Encrypted wallet file generated; KEK loaded via
   systemd `LoadCredential=` (preferred) or
   `MACPROVIDER_PAYOUT_WALLET_KEK` env var. Address pinned in
   `payout.security.hot_wallet_address`.
2. **[§9.2] TWO RPC providers chosen + API keys
   provisioned.** §4.4 REQUIRES two independent RPCs for
   receipt cross-confirmation; ideally different operators
   (Alchemy + QuickNode-class) on different ASNs. Both URLs
   pinned in `payout.security.rpc_url_primary` /
   `..._secondary`. Single-RPC operation is REJECTED at
   v0.1.x.
3. **[§9.3] Caps decided.** Operator sets at minimum:
   `payout.security.per_payout_cap_usdc_base_units` (default
   `500_000_000` = $500),
   `payout.security.per_day_cap_usdc_base_units` (default
   `5_000_000_000` = $5,000),
   `payout.tuning.run_interval` (default 6h, bounds
   `[5m, 24h]`),
   `payout.tuning.confirmation_blocks` (default 5, bounds
   `[5, 200]` — widened by SPEC v0.1.20 round-20 M2; was
   `[2, 50]`),
   `payout.tuning.address_cooling_off_period` (default 24h,
   floor 1h),
   `payout.security.cancel_max_tip_multiplier`,
   `payout.security.cancel_max_gas_native_wei`,
   `payout.security.cancel_max_gas_native_wei_per_24h`,
   `payout.security.abandon_rate_per_hour`,
   `payout.security.chain_recon_interval` (default 1h),
   `payout.security.chain_recon_tolerance_usdc_base_units`
   (default `100_000` = $0.10),
   `payout.security.pause_resume_min_interval` (default 60s).
4. **[§9.4] Compliance posture decision.** Initial bulk
   `payout_allowed` set; policy gating future provider
   eligibility documented (see also §8).
5. **[§9.5] SPEC-014 v0.9 portal screens.** Payout-address
   registration + payout history. SOFT prereq — IMPL MAY
   ship the §3.3 endpoint before SPEC-014 v0.9 if the
   operator drives initial registrations via curl. See §9.5
   for the strict constraint that the EIP-712 signature is
   PROVIDER-side, not operator-side. Filed as a separate
   SPEC PR per [[feedback-bundle-spec-impl-one-pr]] — do NOT
   bundle SPEC-014 v0.9 into this IMPL PR.
   **[§9.5a] HARD sub-prereq:** documented manual provider-
   notification process (email or webhook fired on every
   `provider_payout_address_changed` event) until SPEC-014
   v0.9 lands.
6. **[§9.5b] SPEC-005 vX.Y+1 `POST /admin/ledger/payout-ready`
   admin endpoint.** HARD prereq — §4.7 reorg-compensation has
   no other safe path. Normative contract surface is pinned
   in [§9.5b.1](SPEC-016-payout-pipeline.md) (the SPEC-005
   author can implement cold against it). The SPEC-005 IMPL
   MUST:
   - parse `orig_payout_id` and `orig_attempt_seq` from the
     `idempotency_key` regex `^reorg_compensation:\d+:\d+$`
     and REJECT 400 on mismatch;
   - enforce `Idempotency-Key` HTTP header BYTE-EQUAL to the
     JSON body `idempotency_key` field (REJECT 400 on
     diff) — closes codex round-9 MED-8: replay detection
     references the header while reconciliation depends on
     the body/DB key, so equality MUST be enforced;
   - replay: 409 Conflict on `Idempotency-Key` repeat
     (return the original 201 body verbatim);
   - bind the compensation row to
     `payout_reorg_orphans.observed_*` (SNAPSHOT columns,
     NOT mutable `ledger_payout_ready.*` columns) in the SAME
     SQLite transaction as the INSERT — closes round-9
     CRIT-1 / round-10 MED-5 operator-key-compromise
     high-leverage drain;
   - assert ALL of: exactly one matching orphan row;
     `compensation_settlement_id IS NULL` (else 422
     `orphan_already_compensated`);
     request `provider_id == observed_provider_id`;
     request `provider_credits == observed_provider_credits`;
     request `gross_credits == observed_provider_credits`
     (NOTE: equals `observed_provider_credits`, NOT
     `observed_gross_credits` — compensation is provider-only,
     no operator share);
     request `operator_credits == 0`;
     any miss returns 422 `orphan_mismatch` naming which
     assertion failed;
   - enforce STRICT EQUALITY `gross_credits ==
     provider_credits` (closes codex round-9 MED-9; the
     asymmetric `>` wording admitted
     `provider_credits < gross_credits` which skims USDC
     into reconciliation drift unaccountably);
   - cap `provider_credits` at
     `payout.security.per_payout_cap_usdc_base_units` —
     same per-payout cap §5.2 enforces on the runner;
   - honor `min_payout_credits_override: 0` by inserting
     `min_payout_credits = 0` on the row — the orphan
     being compensated already cleared the SPEC-005 §5
     threshold at original-payment time and MUST NOT
     re-test it;
   - **MUST NOT trigger a fresh settlement run.** Row goes
     directly into `ledger_payout_ready`, NOT into
     `ledger_request_credits`; no `settlement_id` linkage
     on underlying request rows (compensation is
     operator-funded out-of-band, not accrual-funded);
   - emit a SPEC-005 structured log event
     `ledger_payout_ready_admin_inserted` with
     `provider_id, id, idempotency_key, reason,
     actor=operator_key, ts_utc` so the operator audit
     trail covers admin-inserted rows separately from
     settlement-emitted rows;
   - preserve the existing trigger `trg_lpr_terminal_status_guard`
     by EXACT name (currently at
     [`phase4-coordinator/internal/billing/store.go:121-126`](../phase4-coordinator/internal/billing/store.go)) —
     SPEC-005 vX.Y+1 MUST NOT rename or drop it across
     schema migrations; SPEC-016 §4.8 asserts presence by
     exact name at every cadence cycle;
   - **Same-SQLite-DB requirement (NORMATIVE).** The
     SPEC-005 admin endpoint MUST query
     `payout_reorg_orphans` (SPEC-016-owned, created in
     `payout/orphans.go`) in the SAME SQLite transaction
     as the `ledger_payout_ready` INSERT; the SPEC-005
     vX.Y+1 IMPL MUST use the same `*sql.DB` handle — a
     separate DB connection cannot satisfy "same SQLite
     transaction".
   This SPEC-005 endpoint is a SEPARATE SPEC PR + IMPL —
   IMPL of SPEC-016 cannot ship without it.
7. **[§9 item 6 — BetterStack] Alert filter** updated to match
   EVERY §7.1 event with severity=PAGE or severity=WARN by
   **enumerated name** (NOT by severity tier — codex round-11
   MED-2 closure). Re-verify the live list in §9 item 6
   against §7.1 at IMPL time; the v0.1.19 list includes
   `payout_low_balance`, `payout_low_native_balance`,
   `payout_insufficient_funds`, `payout_reorg_revert`,
   `payout_rpc_disagreement`,
   `payout_chain_balance_drift_positive`,
   `payout_chain_balance_drift_negative`,
   `payout_nonce_gap`, `payout_capped`, `payout_failed`,
   `payout_attempt_abandoned`, `payout_config_reloaded`,
   `payout_config_reload_rejected`,
   `payout_registration_paused`, `payout_registration_resumed`,
   `payout_invariant_violation`, `payout_signer_unavailable`,
   `payout_chain_value_mismatch`,
   `payout_runner_lease_conflict`,
   `payout_flag_audit_reaped`,
   `payout_runner_lease_taken_over`,
   `payout_runner_lease_lost`,
   `payout_cancel_self_transfer_reconfirm_stale`,
   `payout_stale_outbox_reaped`,
   `provider_payout_address_change_rejected`,
   `provider_payout_address_rejected_unknown_provider`,
   plus INFO `payout_cancel_self_transfer_confirmed` if the
   operator wants per-cancel visibility. Operator MUST fire
   ONE synthetic alert per ENUMERATED PAGE/WARN event name
   before flipping `payout.enabled: true`.
8. **[§9 item 7 — Nginx] Routing on Pearl VPS** updated to
   proxy `/providers/{id}/payout-address`,
   `/providers/{id}/payouts`, and the new `/admin/payout/*`
   endpoints through `coordinator.streamvc.live → :8444`;
   portal CORS verified. The `coordinator.streamvc.live`
   config is the touchpoint, NOT `portal.streamvc.live`.
9. **[§9.8] Backup + restore** for the encrypted wallet file
   AND the KEK, on separate media (NOT the same VPS). Loss of
   EITHER = total loss of access to hot-wallet funds. Operator
   MUST validate a dry restore-from-backup before IMPL enables
   the runner.

Without items 1, 2, 3, 4, 5a, 5b, 6, 7, 8 (item 5 itself is
the only soft prerequisite), IMPL is blocked per SPEC §9
closing sentence at SPEC L4166-4167. The checklist runs
FIRST — IMPL kickoff is a downstream event.

## 2. Stepped-IMPL decomposition — 4 steps + 4 audit loops

This SPEC is large and structurally complex (the dual-loader
+ cancel-handling + `runtime_flags` machinery is ~3× the
scope of a typical single-step IMPL). Mirror the SPEC-015
stepped-IMPL pattern: split into four sequential steps with a
codex audit loop after each. **Do NOT skip the loop; do NOT
fold steps together** — each step has a natural seam where
the SPEC sections cluster, and the audits are sized to be
genuinely scrutable round-by-round.

Single-step IMPL was considered and REJECTED: the §6.5
namespace-split alone (immutable security loader,
SIGHUP-only tuning loader, persistent `runtime_flags` table)
is enough non-trivial structural complexity that bundling it
with the runner cycle + admin endpoints + reconciliation
would either overwhelm a codex audit round or be split into
ad-hoc post-hoc fix-passes that lose the audit-loop's
diverse-lens benefit.

The recommended PR grouping mirrors the steps 1:1 (one PR
per step). Per `pr-rebase-silent-dependency-regression`
memory, rebase each PR on the merged tip of the previous
one before pushing.

### Step 1 — Schema + §3 address registration + §3.2 EIP-712 verification

**What lands:**

- New package directory `phase4-coordinator/internal/payout/`
  per [§4.1](SPEC-016-payout-pipeline.md). Cross-package
  boundary discipline: `billing/` MUST NOT import `payout/`;
  `payout/ → billing/` is permitted (one-way) for the
  `ClaimPayoutReady` call. IMPL audit MUST include an
  import-graph test asserting this direction.
- Schema migrations under
  `phase4-coordinator/internal/payout/migrations/`:
  - [§3.1] `provider_payout_addresses` (with
    `registered_against_hot_wallet` column +
    `idx_ppa_provider`).
  - [§3.2] `provider_payout_address_nonces` replay table.
  - [§4.5] `payout_attempts` (PK `(payout_id, attempt_seq)`)
    with seven partial indexes (five non-UNIQUE + two
    partial UNIQUE per SPEC L1408-1463):
    `idx_pa_from_nonce_active`, `idx_pa_unconfirmed`,
    `idx_pa_confirmed_recent`, `idx_pa_broadcast_recent`,
    `idx_pa_cancel_recent`, `idx_pa_one_active_per_payout`
    (CONFIRMED non-cancel non-abandoned),
    `idx_pa_one_live_non_cancel_per_payout` (LIVE non-cancel).
    Include the `cancel_reconfirm_stale_paged_at_utc` column
    per v0.1.16 codex round-17 MED-1.
  - [§4.7] `payout_reorg_orphans` table (read SPEC §4.7 for
    the schema — observed_* snapshot columns are normative).
  - [§4.8] `payout_runner_state` (single-row, PK CHECK id=1)
    + the `trg_prs_bootstrap_one_way` /
    `trg_pa_bootstrap_flip` /
    `trg_pa_bootstrap_flip_insert` trigger set. Startup
    `INSERT OR IGNORE INTO payout_runner_state` MUST run in
    `cmd/coordinator/main.go` BEFORE `runner.Start()`.
  - [§4.8a] `runtime_flags` + `runtime_flag_audit` outbox
    + `runtime_flags_bootstrapped` sentinel. Bootstrap-seed
    is GATED by the three-table empty-check (NONE-of-three
    NONEMPTY: proceed; ANY conflicting state: HALT). The
    closed-set namespace currently contains exactly one
    flag: `registration_paused`.
  - [§4.8b] `payout_runner_lease` (zero-row default).
  - [§4.8c] `cancel_reconfirm_stale_outbox`.
  - [§4.9] `payout_hot_wallet_funding` (UNIQUE on `tx_hash`).
- **Per-table same-DB pins.** The SPEC currently locks
  per-table pins (NOT a comprehensive all-table pin —
  that is a v0.2 candidate per SPEC L2456-2457 and
  L2738-2739; do NOT pre-empt the SPEC). Each of the
  following tables MUST live in the same SQLite database
  file as SPEC-005's `ledger_payout_ready`:
  - `provider_payout_addresses` (§3.1)
  - `payout_reorg_orphans` (§4.7)
  - `runtime_flags` + `runtime_flag_audit` +
    `runtime_flags_bootstrapped` (§4.8a)
  - `payout_runner_lease` (§4.8b)
  - `payout_hot_wallet_funding` (§4.9)
  IMPL test required: `PRAGMA database_list` from both
  `billing/` and `payout/` entry points returns the same
  DB file for each table named above.
- [§3.3] `POST /providers/{provider_id}/payout-address`
  handler in `payout/addresses.go`. Mounts on the `:8444`
  ws-mux listener. Use `chi` or `gorilla/mux` (NOT
  `http.ServeMux` — see §3.3 path-table requirement).
  Single `map[path]authRealm` table verified at coordinator
  startup; any registered route NOT in the table fails
  closed.
  - Pre-auth pause check (returns 503 BEFORE evaluating
    `provider_token` to defeat response-code timing probing).
  - TOCTOU pause re-check inside the SAME `BEGIN IMMEDIATE`
    txn that writes the `provider_payout_addresses` row
    (closes the v0.1.7 single-check gap).
  - Server-side stamp of `registered_against_hot_wallet`
    (client-supplied value is silently ignored — NOT
    rejected; DisallowUnknownFields is FORBIDDEN here).
  - Co-residency assertion: registration handler and runner
    in same process; fail-fast on multi-host config.
- [§3.2] EIP-712 verification of the request signature
  against the domain
  `(name="macprovider-payout", version="1", chainId=8453,
   verifyingContract=payout.security.hot_wallet_address)`
  and struct `PayoutAddressRegistration{providerId, address,
  chain, nonce, tsUtc}`. Every typed-data field MUST be
  field-by-field-verified equal to the request body (NOT just
  ecrecover-pass — a decorative field is a replay vector).
- [§3.2 step 5] `ts_utc` (body field, unix seconds) MUST be
  within ±5 minutes of the coordinator's clock. Outside the
  window: REJECT 400 `signature_skew`. This is the
  short-window bound that pairs with the 10-minute
  nonce-table prune retention (window =
  `min(skew_window, prune_retention)`) — extending one
  without the other re-opens the replay window.
- [§3.2] EIP-55 enforcement: pure lowercase / pure uppercase
  accepted (checksum-skipped per EIP-55 backward-compat);
  mixed-case with checksum mismatch is REJECTED. Canonical
  form is stored server-side; 400 responses MUST NOT echo
  the canonical form.
- [§3.2] Deny-list at minimum: zero address, USDC contract
  `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, the
  configured hot-wallet `from_address`, known burn addresses.
- [§3.2] Anti-replay table:
  `provider_payout_address_nonces` PK on
  `(canonical_address, nonce)`; background cleanup prunes
  entries older than 10 minutes.
- [§3.4] `provider_payout_address_changed` event emission
  with `old_address` / `new_address` in canonical EIP-55
  form. Failed registrations emit
  `provider_payout_address_change_rejected` with the
  6-prefix-4-suffix `submitted_fingerprint` (NEVER the raw
  bytes — log-injection vector).

**ACs touched (this step):** address registration end-to-end,
EIP-712 verification, deny-list, cooling-off
`pending_until_utc`, persistent `runtime.registration_paused`,
schema presence + trigger presence checks at startup.

**Test corpus (minimum):**

- Schema migration up + down idempotent; partial UNIQUE
  indexes enforced (`idx_pa_one_live_non_cancel_per_payout`
  REJECTS a second live non-cancel attempt with `UNIQUE
  constraint violation`).
- EIP-712 vector: a signature produced by a known private key
  verifies end-to-end; a signature for a different
  `verifyingContract` is REJECTED `signature_mismatch`; a
  signature where typed-data `nonce` differs from body
  `nonce` is REJECTED `nonce_mismatch` (defeats decorative-
  field replay).
- TOCTOU race: pause flag flipped between pre-auth check and
  the inner `BEGIN IMMEDIATE` re-check → response is 503,
  no row written.
- Anti-replay: same `(canonical_address, nonce)` submitted
  twice → second is REJECTED 400 `nonce_replayed`.
- Bootstrap-seed gating: three-table empty → seed runs and
  `runtime_flags_bootstrapped` row is inserted; any non-empty
  combination → seed does NOT run.
- Sentinel-asymmetry: sentinel present, `registration_paused`
  row deleted → startup emits
  `payout_invariant_violation where='runtime_flag missing'`
  and HALTS before §3.3 accepts traffic.
- Trigger-presence assertion at startup AND at top of every
  cycle (deferred to Step 2 for the per-cycle check; the
  startup check lands here).
- Co-residency: a config that places the runner on a
  different process FAILS-FAST at startup.

**IMPL audit:** `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md`.
Per [[feedback-codex-only-audits]] this MUST be fired at
codex via `omc ask codex` or `/ccg` — NOT at Claude internal
subagents. Findings file: `specs/SPEC-016-IMPL-STEP_1-audit.md`
per [[feedback-spec-audit-file-convention]]. Loop fix-pass →
re-audit until 0 CRITICAL / 0 MAJOR / 0 MEDIUM. Verify:
(a) schema bytes match SPEC-016 §§3.1, 3.2, 4.5, 4.7, 4.8,
4.8a, 4.8b, 4.8c, 4.9 byte-for-byte; (b) the §3.2 typed-data
field-by-field equality is enforced; (c) the TOCTOU pause
re-check uses `BEGIN IMMEDIATE` (not `BEGIN DEFERRED`);
(d) `DisallowUnknownFields` is NOT used on §3.3; (e) the
import-graph test enforces `payout/ → billing/` one-way;
(f) all five same-DB pins from §3.1 / §4.7 / §4.8a / §4.8b /
§4.9 hold against `PRAGMA database_list`.

### Step 2 — §4.3 runner cycle + §6.3 Signer + §4.6 abandon + two-RPC confirm

**What lands:**

- [§4.1] Package skeleton additions: `runner.go`, `evm.go`,
  `signer.go`, `attempts.go`, `addresses.go` accessor (the
  read-only `PayoutAddressReader` interface DECLARED in
  `billing/` and SATISFIED by a thin adapter in `payout/`).
- [§6.3 + §6.3.1] `Signer` interface in `payout/signer.go`
  with EXACTLY the surface in SPEC §6.3.1: `FromAddress()
  string`, `SignTx(ctx, unsignedTxBytes) (rawSignedTx,
  txHash, error)`. NO `SignMessage` primitive (footgun per
  v0.1.3 carve-out). Concrete local-file `Signer` ships at
  v0.1.x; KMS is v0.2 (§6.6 forward pointer only).
  - **`unsignedTxBytes` format (SPEC L3155-3164):**
    EIP-2718 type-prefixed RLP-encoded unsigned EIP-1559
    transaction (txType `0x02`) with empty signature
    fields (V, R, S = 0) — i.e. the exact bytes that, when
    keccak256-hashed and signed, produce the signing-hash
    for an EIP-1559 tx. **Caller does NOT pre-hash.** KMS
    implementations that require a 32-byte digest input
    MUST keccak256 the `unsignedTxBytes` themselves.
  - **Determinism guidance (SPEC L3165-3171):** for the
    same input bytes called twice, the implementation
    SHOULD return identical output bytes (deterministic
    ECDSA via RFC 6979) but SPEC-016 does NOT depend on
    determinism for idempotency — the chain-level nonce +
    `raw_signed_tx` persistence (§4.3 step 6) is the
    actual guarantee.
  - **Cancellation (SPEC L3171-3173):** `ctx` supports
    cancellation; KMS implementations MAY block on a
    network call; the local-file implementation MUST NOT
    block longer than 100 ms.
  - **Error semantics (SPEC L3188-3203):** nil `err`
    REQUIRES non-nil `rawSignedTx` AND non-empty
    `txHash` (partial returns → panic in tests / fail-loud
    in production). `ctx.Err() != nil` paths return
    `err = ctx.Err()` and are treated as transient
    (retried next cycle). "Wrong chain id" / "key
    unavailable" / "policy refused (KMS)" MUST return a
    typed error the runner distinguishes from transient —
    these HALT the runner and page the operator via
    `payout_signer_unavailable` per §7.1.
    Implementation MUST NOT log, print, or return the
    signing key in any error path (regression test
    required).
  - EIP-712 signature verification at §3.2 step 5 uses
    `ecrecover` — a public-key operation. It does NOT
    invoke the `Signer` interface, because verification
    does not require the hot-wallet private key.
- [§6.3] Process hardening at startup: `setrlimit(RLIMIT_CORE,
  0)`, `prctl(PR_SET_DUMPABLE, 0)`, `mlockall` with
  fail-loud on EPERM/ENOMEM (test asserts `VmLck` ≥
  keysize in `/proc/self/status`), systemd-coredump
  bypass check on `/proc/sys/kernel/core_pattern` (MUST NOT
  start with `|`, MUST NOT contain `systemd-coredump`),
  `runtime.GOOS == "linux"` enforcement.
- [§4.3] Per-run algorithm STEP-BY-STEP. All 9 steps
  including:
  - **Step 1 SELECT** with the `effective_address` CASE +
    `registered_against_hot_wallet = :hot_wallet` filter;
    NULL `effective_address` treated as hard error
    (`payout_invariant_violation`).
  - **Step 2 unit identity** hardcoded; reject any config
    that introduces a multiplier (§5.1).
  - **Step 3 three compound guards:**
    (a) `payout_runner_lease.holder_token` re-read inside
    the same `BEGIN IMMEDIATE` txn (mismatch →
    `payout_runner_lease_lost`),
    (b) per-attempt `BEGIN IMMEDIATE` transaction wrapping
    the cap re-read + lease re-read + nonce allocation +
    `payout_attempts` INSERT,
    (c) DB-side partial UNIQUE INDEX
    `idx_pa_one_live_non_cancel_per_payout` as
    belt-and-suspenders (the second INSERT MUST fail with
    `UNIQUE constraint violation` and HALT the runner with
    `payout_invariant_violation where='duplicate live attempt'`).
  - **Step 4 cap check.** Per-payout cap (§5.2) + per-day
    cap (§5.3) with the **reservation-aware query**:
    counts (A) broadcasts in the rolling 24h window AND
    (B) ALL live reserved attempts (broadcast NULL,
    confirmed NULL, abandoned NULL) regardless of age.
    Stale-reservation halt (NORMATIVE per v0.1.10 codex
    round-11 MAJOR-1): BEFORE the cap sum, run the
    `COUNT(*) FROM payout_attempts WHERE broadcast_at_utc
    IS NULL AND confirmed_at_utc IS NULL AND
    abandoned_at_utc IS NULL AND updated_at_utc <
    :now_minus_24h` check inside the same
    `BEGIN IMMEDIATE` txn; > 0 → ROLLBACK + emit
    `payout_invariant_violation where='stale_unbroadcast_attempt'`
    + HALT.
  - **Step 5 attempt record + cancel-handling pre-check
    (NORMATIVE, closes codex round-14 MAJOR-1).** Filter
    the existing-attempt lookup to
    `is_cancel_self_transfer = 0` so a confirmed CANCEL is
    NOT mistaken for a confirmed provider payout. BEFORE
    allocating a fresh non-cancel attempt, query live
    cancel rows; handle by state (unbroadcast → rebroadcast
    persisted bytes bit-for-bit; broadcast-unconfirmed →
    poll via cancel-specific verification;
    confirmed → emit `payout_cancel_self_transfer_confirmed`
    INFO **only on transition** + clear
    `cancel_reconfirm_stale_paged_at_utc = NULL` + DO NOT
    call `ClaimPayoutReady`).
    Live unconfirmed cancel ⇒ HALT fresh non-cancel
    allocation for that `payout_id` (no
    `payout_invariant_violation` — legitimate state).
  - **Step 6 build + sign + pre-broadcast verify + CAS
    persist + broadcast.** Pre-broadcast verification
    (NORMATIVE per codex round-10 MAJOR-1): locally decode
    `rawSignedTx` and assert ALL: nonce, chain_id=8453,
    `to == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`,
    `value == 0`, calldata = `0xa9059cbb || abi.encode(
    address, uint256)` exactly 68 bytes, fee bounds,
    locally-recomputed `tx_hash` equals Signer's returned
    `txHash`, `ecrecover(sender) ==
    payout.security.hot_wallet_address` (do NOT trust
    `Signer.FromAddress()` blindly).
    CAS persist (NORMATIVE per codex round-11 MAJOR-2):
    `BEGIN IMMEDIATE` → re-read lease holder_token (lost →
    discard envelope, do NOT broadcast, do NOT log
    `raw_signed_tx`/`tx_hash` — side-channel discipline) →
    `UPDATE payout_attempts SET raw_signed_tx, tx_hash,
    updated_at_utc WHERE payout_id AND attempt_seq AND
    raw_signed_tx IS NULL AND confirmed_at_utc IS NULL AND
    abandoned_at_utc IS NULL` (closes the concurrent-
    abandon-vs-sign race per v0.1.11 codex round-12
    MAJOR-1). Row-count = 0 disambiguation: missing row →
    `payout_invariant_violation
    where='attempt_row_missing_during_sign'`; state changed
    → `where='attempt_state_changed_during_sign'`;
    `raw_signed_tx` already present → reuse persisted bytes,
    re-signing FORBIDDEN.
    Post-COMMIT lease re-read (standalone) before broadcast;
    mismatch → do NOT broadcast.
  - **Step 7 confirm via TWO independent RPCs with
    chain-side value verification.** Both receipts MUST
    agree on `tx_hash`, `block_hash`, `block_number`,
    `status=0x1`, `to == USDC contract`. Additionally
    (NORMATIVE):
    (a) `eth_getTransactionByHash` on each RPC; `tx.input`
    byte-equal to `0xa9059cbb || abi.encode(address,
    uint256)`; reject any other selector OR any length
    other than 68 bytes;
    (b) ecrecover'd `from == hot_wallet_address`;
    (c) exactly ONE matching Transfer log: address = USDC
    contract, topic0 = keccak256("Transfer(address,address,
    uint256)"), topic1 = hot_wallet (left-padded 32),
    topic2 = effective_address (left-padded 32),
    abi.decode(log.data, uint256) = amount_base_units.
    Cancel-specific verification (NORMATIVE per
    round-14 MAJOR-1): `tx.to ==
    payout.security.hot_wallet_address` (NOT USDC),
    calldata empty, `value == 1 wei`, NO Transfer log,
    do NOT call `ClaimPayoutReady`.
  - **Step 8 claim.** Call
    [`ClaimPayoutReady`](../phase4-coordinator/internal/billing/payout.go)
    with signature `(ctx, payoutID int64,
    expectedGrossCredits int64, payoutExternalID,
    payoutCurrency string)`. `expectedGrossCredits` MUST be
    `lpr.gross_credits` (NOT `provider_credits`).
    `payoutCurrency` MUST be the literal `"USDC-BASE"`
    (never empty, never NULL — IMPL test required).
    Wrap with the §4.8a intra-transaction trigger-presence
    check: `SELECT count(*) FROM sqlite_master WHERE
    type='trigger' AND name = 'trg_lpr_terminal_status_guard'`
    inside the same `BEGIN IMMEDIATE` as the claim; count
    != 1 → abort + leave row in `ready` + emit
    `payout_invariant_violation`.
  - **Step 9 log.** `payout_paid` / `payout_failed` per
    §7.1.
- [§4.2] Cadence: default every 6h; configurable via
  `payout.tuning.run_interval` (Go duration, parse-time min
  5m). Operator-triggered `POST /admin/payout/run-now` on
  the `:8444` listener (idempotent within an in-flight run:
  409 if active; 429 if invoked within
  `payout.tuning.run_now_min_interval`).
  `payout_run_now_invoked` per §7.1 on every call.
- [§4.4] RPC failure tolerance: cold-start nonce sync via
  `getTransactionCount(pending)` on BOTH RPCs; require ±1
  agreement; cursor = `max(cursor_in_db, max(rpc_a, rpc_b))`;
  any disagreement within tolerance emits
  `payout_nonce_cold_start_within_tolerance`; >1 difference
  HALTS with `payout_rpc_disagreement reason=
  nonce_cold_start_mismatch`.
- [§4.6] `POST /admin/payout/abandon-attempt` endpoint:
  - **Runner-active gate (NORMATIVE per v0.1.11 codex
    round-12 MAJOR-1):** in the SAME `BEGIN IMMEDIATE` txn,
    `SELECT 1 FROM payout_runner_lease WHERE id=1 AND
    heartbeat_at_utc >= now - (3 × run_interval_seconds)`;
    row returned → 409 `runner_active` + ROLLBACK.
  - **Abandon-marker UPDATE** gated on
    `confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL`
    (closes round-13 MED-1). Row-count = 0 disambiguation:
    no row → 404 `not_found`; confirmed → 409
    `already_confirmed`; abandoned → 409
    `already_abandoned`.
  - **Cancel-row INSERT** if
    `broadcast_cancel_self_transfer=true`: same txn,
    `is_cancel_self_transfer=1`, `to=from=hot_wallet`,
    `amount_base_units=1`, original nonce, capped tip,
    `broadcast_at_utc=NULL` (v0.1.14 codex round-15
    MAJOR-1 closure — do NOT pre-stamp).
  - **Post-COMMIT broadcast:** cancel-broadcast preflight
    verification (NORMATIVE v0.1.14): locally decode
    `raw_signed_tx`, assert nonce, chain_id=8453, `to ==
    hot_wallet`, `value == 1 wei`, calldata empty, fee
    bounds, `tx_hash` match, ecrecover match. Then
    `eth_sendRawTransaction` on both RPCs. If ≥ 1 accepts,
    CAS-stamp `broadcast_at_utc=now` where still NULL. If
    both reject, leave NULL — next cadence cycle's §4.3
    cancel-handling pre-check rebroadcasts the persisted
    bytes bit-for-bit.
  - Caps RUNTIME-IMMUTABLE per §6.5:
    `payout.security.cancel_max_tip_multiplier` (default 5×,
    silently floored on exceed + `cap_applied` log),
    `payout.security.abandon_rate_per_hour` (default 3),
    `payout.security.cancel_max_gas_native_wei` (default
    `1e16`),
    `payout.security.cancel_max_gas_native_wei_per_24h`
    (default `5e16`).
  - `payout_attempt_abandoned` severity=PAGE per §7.1.
- [§4.4] **Two-RPC discipline.** Single-RPC operation is
  REJECTED at v0.1.x. RPC URL TLS pinning via
  `payout.tuning.rpc_url_primary_pin_spki` /
  `..._secondary_pin_spki` (64-hex-char SHA-256 or empty).
- [§4.8b] **Singleton-runner lease.** Acquire (insert if
  none; fail with `payout_runner_lease_conflict` if holder
  fresh; takeover if holder stale-by-`3 × run_interval`
  with `takeover_count++` and
  `payout_runner_lease_taken_over` PAGE).
  Heartbeat at `payout.tuning.run_interval` cadence with
  `BEGIN IMMEDIATE` UPDATE re-asserting `WHERE
  holder_token=<our token>`; affected rows = 0 → self-halt
  with `payout_runner_lease_lost` PAGE.
  Self-fencing on every §4.3 step 4–8.
  Clean-shutdown DELETE `WHERE id=1 AND holder_token=<ours>`.

**ACs touched:** end-to-end payout for a single
`ledger_payout_ready` row → confirmed on-chain → ledger
consumed; two-RPC disagreement HALTS; lease takeover after
stale window; cancel self-transfer at original nonce
(unbroadcast / unconfirmed / confirmed transitions); CAS race
defenses; pre-broadcast Signer verification catches a
malicious Signer pre-flight.

**Test corpus (minimum):**

- End-to-end against a local Anvil (or equivalent) fork
  pinned at the Base USDC contract address: a single
  `ready` row → confirmed in N blocks → ledger row
  `consumed` with `payout_currency = "USDC-BASE"` and
  `payout_external_id = <tx hash>`.
- RPC disagreement (different `block_hash`, same
  `block_number`) at step 7 → HALT + emit
  `payout_chain_value_mismatch` (or `payout_rpc_disagreement`
  per the matrix).
- Signer-compromise simulation: Signer returns a valid sig
  but for a different sender → pre-broadcast check HALTS
  with `mismatch_class='prebroadcast_signed_tx'`; no
  broadcast.
- Calldata-bug simulation: tx confirms but `tx.input` is
  not the expected `0xa9059cbb`-prefix-68-byte payload →
  HALT with `mismatch_class='input_calldata'`.
- Concurrent-abandon-vs-sign race: abandon endpoint called
  during the runner's sign phase → runner_active 409 from
  abandon side; OR (in the unlikely lease-stale window) the
  runner's CAS predicate
  `AND abandoned_at_utc IS NULL` catches it from the
  runner side.
- Cancel-row state machine: unbroadcast crash recovery
  re-broadcasts the persisted bytes bit-for-bit; confirmed
  cancel does NOT call `ClaimPayoutReady`; live unconfirmed
  cancel HALTs fresh non-cancel allocation but does NOT
  emit `payout_invariant_violation`.
- Lease takeover after kill -9: second process emits
  `payout_runner_lease_taken_over` with `takeover_count=1`
  after `3 × run_interval`.
- Lease self-fence: process A is stop-the-world-paused
  longer than the takeover window; process B takes over;
  process A resumes and tries step 6 CAS — sees mismatched
  `holder_token`, emits `payout_runner_lease_lost`, does
  NOT broadcast.
- Linux-only enforcement: `runtime.GOOS != "linux"` →
  runner refuses to start.

**IMPL audit:**
`specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md` → codex →
`specs/SPEC-016-IMPL-STEP_2-audit.md` → fix → loop until
0/0/0. Verify: (a) the §4.3 step ordering is byte-correct
against the SPEC; (b) all CAS predicates include the v0.1.11
extensions (`AND confirmed_at_utc IS NULL AND
abandoned_at_utc IS NULL`); (c) cancel-specific verification
is reachable only through the cancel pre-check (no shared
code path that could pass a cancel through the
`ClaimPayoutReady` branch); (d) side-channel discipline
holds — `raw_signed_tx` / `tx_hash` bytes never log on the
discard paths; (e) lease self-fence runs at every §4.3 step
4–8 (NOT just step 3); (f) ALL `payout_*` events emitted by
the runner cycle match §7.1 field-by-field.

### Step 3 — §4.9 admin endpoints + §6.4.1 pause/resume + §4.7 reorg

**What lands:**

- [§4.9] `POST /admin/payout/record-funding`:
  - `source='manual'` accepted ONLY when
    `payout_runner_state.payout_bootstrap_complete = 0`
    (bootstrap window). One-way flip 0→1 via
    `trg_pa_bootstrap_flip` + `trg_pa_bootstrap_flip_insert`
    triggers; reverse flip REJECTED by
    `trg_prs_bootstrap_one_way`.
  - **Intra-transaction bootstrap-trigger presence check
    (NORMATIVE per §4.8a, SPEC L2514-2538).** The
    `payout_bootstrap_complete` SELECT that gates the
    `source='manual'` INSERT MUST be performed in the SAME
    SQLite transaction as:
    ```sql
    SELECT count(*) FROM sqlite_master
     WHERE type='trigger'
       AND name IN ('trg_prs_bootstrap_one_way',
                    'trg_pa_bootstrap_flip',
                    'trg_pa_bootstrap_flip_insert');
    ```
    If `count != 3`, REJECT 422
    `bootstrap_trigger_missing` AND emit
    `payout_invariant_violation` per §7.1 (severity=PAGE).
    This closes the DROP-trigger + reset-flag +
    CREATE-trigger intra-cycle attack class — the two
    AFTER-triggers alone cannot detect a drop+mutate+recreate
    that completes between top-of-cycle checks, so the gate
    fires at the money-path call boundary.
  - `source='rpc-confirmed'` REQUIRES receipt from BOTH
    RPCs with matching `to=USDC`, Transfer log with
    `to=hot_wallet`, `from=request.from_address`,
    `value=amount_base_units`, `block_number` match,
    `status=success`. 422 `receipt_mismatch` /
    `receipt_not_available` otherwise.
  - `UNIQUE(tx_hash)` enforces 409 idempotency.
  - `payout_funding_recorded` event per §7.1.
- [§6.4.1] `POST /admin/payout/pause-registration` and
  `POST /admin/payout/resume-registration`:
  - **Outbox audit pattern (NORMATIVE per §4.8a, closes
    round-9 MAJOR-5):** ONE `BEGIN IMMEDIATE` txn that
    UPDATEs `runtime_flags` AND INSERTs
    `runtime_flag_audit` with `emitted_to_log=0` AND
    COMMITs. AFTER COMMIT, run the CAS-claim `UPDATE
    runtime_flag_audit SET emitted_to_log=1 WHERE
    id=<committed audit id> AND emitted_to_log=0
    RETURNING id`; on claim success, emit the §7.1 zerolog
    line synchronously with `event_id=<audit id>`.
  - Rate-limited by
    `payout.security.pause_resume_min_interval` (default
    60s — RUNTIME-IMMUTABLE).
  - 409 if already in the target state.
  - `payout_registration_paused` /
    `payout_registration_resumed` both severity=PAGE.
- [§4.8a] **Background reaper** at cadence
  `payout.tuning.run_interval`: scan
  `runtime_flag_audit WHERE emitted_to_log=0 AND
  occurred_at_utc < now - 5 minutes`; for each row, run
  CAS-claim `UPDATE ... SET emitted_to_log=1 WHERE id=<row>
  AND emitted_to_log=0 RETURNING id` (v0.1.18 codex
  round-11 LOW-2 closure aligned shorthand to sync emitter
  with `RETURNING id`); on claim success emit zerolog line
  with `event_id` AND increment
  `payout_flag_audit_reaped` (severity=WARN).
- [§4.7] `POST /admin/payout/record-orphan`:
  - Records a reorg orphan with the IMMUTABLE snapshot
    columns (`observed_provider_id`,
    `observed_provider_credits`, `observed_gross_credits`,
    `observed_amount_base_units`) needed by the SPEC-005
    vX.Y+1 admin endpoint (per §9.5b.1 binding
    requirement).
  - Provider-payout orphan (`is_cancel_self_transfer=0`)
    follows the provider-orphan flow + compensation path;
    cancel-self-transfer orphan
    (`is_cancel_self_transfer=1`) follows the §4.7
    cancel-reorg carve-out (v0.1.14 codex round-15
    MAJOR-2): NO `ledger_payout_ready` revert, NO
    compensation row; observability via
    `payout_reorg_revert is_cancel_self_transfer=1` event +
    reconfirm-stale outbox if non-NULL.
  - `payout_reorg_orphan_recorded` event per §7.1.
- [§4.7 reconfirm-stale outbox (§4.8c, v0.1.17 codex
  round-18 MED-1 closure):** When the cancel-reorg
  reconfirmation never lands within `3 × run_interval`,
  emit `payout_cancel_self_transfer_reconfirm_stale`
  (PAGE) once-per-stale-transition (via
  `cancel_reconfirm_stale_paged_at_utc` marker), durably
  via the outbox table. Reaper for stale outbox rows emits
  `payout_stale_outbox_reaped` (WARN).
- [§6.4] **Key-rotation runbook surface.** Steps 1-4 in
  §6.4 are operator-procedural. IMPL MUST ensure: (a)
  `payout.enabled: false` halts the runner cleanly; (b)
  `runtime.registration_paused=1` persists across restart
  (no auto-unpause); (c) post-rotation §4.3 step 1 SELECT's
  `registered_against_hot_wallet = :hot_wallet` filter
  silently skips pre-rotation rows.
- [§3.5] Settlement gate: a provider with no
  `provider_payout_addresses` row OR `payout_allowed=0` OR
  unexpired `pending_until_utc` without `rotated_from` OR
  `registered_against_hot_wallet != <current>` has NO
  payout attempt initiated; their rows stay `status='ready'`.

**ACs touched:** funding records insert; bootstrap window
correctly gates `source='manual'`; pause/resume persists
across restart; reaper backfills missed log emissions;
cancel-reorg recorded without consuming `ledger_payout_ready`;
provider-reorg orphan is recordable + compensable via
SPEC-005 vX.Y+1 admin endpoint.

**Test corpus (minimum):**

- Bootstrap window: `payout_bootstrap_complete=0` →
  `source='manual'` accepts; first confirmed
  `payout_attempts` row flips the flag via trigger;
  post-flip `source='manual'` is REJECTED 422
  `bootstrap_complete`.
- Pause/resume restart: pause endpoint flips the flag → kill
  -9 the coordinator → restart → `runtime.registration_paused`
  is still 1; §3.3 returns 503 BEFORE the runner starts.
- Outbox crash recovery: spawn a fake §6.4.1 endpoint
  handler that COMMITS then panics before the synchronous
  emit; the reaper picks up the row via CAS-claim and emits
  with `event_id` + `payout_flag_audit_reaped` increment.
- Outbox dedupe: spawn a slow synchronous emitter + the
  reaper concurrently → CAS-claim ensures exactly ONE
  emission of any given `event_id`.
- Provider-reorg orphan: record-orphan → SPEC-005 vX.Y+1
  admin endpoint compensates via
  `idempotency_key='reorg_compensation:<orig_payout_id>:<orig_attempt_seq>'`
  → §7.4 query (B) and (C) detect a forged
  `compensation_settlement_id`.
- Cancel-reorg orphan: `is_cancel_self_transfer=1` orphan
  recorded → no `ledger_payout_ready` mutation; reconfirm-
  stale PAGE fires once per transition; subsequent §4.3
  confirmation clears `cancel_reconfirm_stale_paged_at_utc`
  back to NULL.

**IMPL audit:**
`specs/AUDIT_SPEC_016_IMPL_STEP_3_PROMPT.md` → codex →
`specs/SPEC-016-IMPL-STEP_3-audit.md` → fix → loop until
0/0/0. Verify: (a) the outbox audit pattern preserves the
"audit row IS the canonical record" property — a process
crash between the SQLite COMMIT and the synchronous emit
results in eventual emit-by-reaper, never silent loss;
(b) all `runtime.*` toggles go through §6.4.1 endpoints
(NOT direct DB writes); (c) the §3.3 path-table check
rejects any handler registration that escapes the table;
(d) reorg cancel-vs-provider carve-out is observed end-to-end
(no `ledger_payout_ready` revert ever happens on the cancel
path).

### Step 4 — §6.5 config-loader split + §7.4 reconciliation + §7.1 emitters + ops

**What lands:**

- [§6.5] **Dual-namespace config loader.** TWO distinct
  code paths:
  - `payout.security.*` immutable-at-startup loader.
    Loaded once at process start. SIGHUP / fsnotify /
    runtime-debug endpoint reload is FORBIDDEN — IMPL MUST
    add an explicit test asserting that no SIGHUP handler
    and no fsnotify watcher touches a `payout.security.*`
    key. A post-startup attempt to mutate any
    `payout.security.*` value MUST be a no-op (config file
    mtime advance without SIGHUP MUST NOT change any live
    value).
  - `payout.tuning.*` SIGHUP-only loader. fsnotify and
    reload endpoints FORBIDDEN. Hot-reload re-enforces ALL
    bounds at reload time (round-13 round-14 bounds
    matrix):
    `address_cooling_off_period >= 1h`;
    `confirmation_blocks ∈ [5, 200]` (SPEC v0.1.20 round-20
    M2 — was `[2, 50]`);
    `low_balance_threshold <= 2 × per_day_cap`;
    `low_native_threshold <= 1e18`;
    `run_interval ∈ [5m, 24h]`;
    `run_now_min_interval ∈ [10s, 1h]`;
    `max_rows_per_run ∈ [1, 500]`;
    `rpc_url_*_pin_spki` is 64-hex-char SHA-256 or empty.
    Successful reload → `payout_config_reloaded` PAGE per
    §7.1 with key + old + new. Bound violation →
    `payout_config_reload_rejected` PAGE; live value
    retained.
  - `runtime.*` CLOSED namespace; ONLY
    `runtime.registration_paused`. Toggled by §6.4.1
    endpoints (Step 3). Persistent via the §4.8a
    `runtime_flags` table + sentinel.
  - In-flight `pending_until_utc` rows MUST NOT be
    recomputed on `address_cooling_off_period` reload —
    NEW registrations cool off against the NEW value;
    in-flight rows keep their original
    `pending_until_utc`.
  - `payout.enabled` retained as a singleton master switch
    OUTSIDE the three buckets (grandfathered for backward
    compatibility per §6.5; no new bare `payout.X` keys
    are permitted).
- [§7.4] Reconciliation queries committed to
  `phase4-coordinator/internal/payout/reconcile.sql`. SPEC
  §7.4 names FOUR specific labeled queries —
  **(A)** stale-orphan (unresolved >30d),
  **(B)** compensation-forgery (orphan whose
  `compensation_settlement_id` references a missing row),
  **(C)** reorg-compensation orphan-mismatch
  (`ledger_payout_ready` rows whose
  `idempotency_key LIKE 'reorg_compensation:%'` without a
  back-link),
  **(D)** cancel-self-transfer observability roll-up.
  The file MUST contain those four labeled queries verbatim
  PLUS three un-labeled regression queries from SPEC §7.4:
  the per-provider in-DB vs on-chain delta query (whose
  `HAVING delta != 0` row is a reconciliation failure),
  the NULL-`payout_currency` regression detector,
  and the chain-balance recon
  `total_funded - total_paid_out` query excluding
  `is_cancel_self_transfer = 1` from outflow. DO NOT
  reuse the (A)/(B)/(C)/(D) labels for the un-labeled
  regression queries — the SPEC reserves those labels.
- [§7.4] **Chain-balance reconciliation worker** at cadence
  `payout.security.chain_recon_interval` (default 1h). Both
  RPCs `balanceOf(hot_wallet)`; agreement within tolerance
  else `payout_rpc_disagreement`. Compare against
  `total_funded - total_paid_out` (cancels excluded);
  signed drift event per §7.1 (positive WARN, negative
  PAGE) AND HALT the runner on |drift| > tolerance.
- [§6.2] Balance monitoring:
  `payout.tuning.low_balance_threshold` →
  `payout_low_balance` WARN;
  `payout.tuning.low_native_threshold` →
  `payout_low_native_balance` WARN;
  `payout_insufficient_funds` PAGE on attempt
  insufficient-funds.
- [§7.1] **Structured log emitters.** All v0.1.19 event
  types implemented with field-by-field parity to the
  §7.1 table. INFO `payout_cancel_self_transfer_confirmed`
  emits ONLY on the cancel-confirmation transition (NOT
  every cycle).
- [§7.3] `GET /providers/{provider_id}/payouts?limit=50`
  read endpoint (provider-token auth, NOT operator-token).
  Reuses the existing per-provider sliding-window limiter
  at
  [`phase4-coordinator/internal/billing/endpoints.go:453-465`](../phase4-coordinator/internal/billing/endpoints.go)
  — do NOT reimplement.
- [§7.1.1] Retention: 7-year journalctl default per the
  existing BetterStack archive pipeline. NO SQL-side
  promotion at v0.1.x (filed as v0.2 candidate in
  Appendix B).
- **Operator runbook.** A new doc at
  `phase4-coordinator/dist/payout-runbook.md` covering:
  hot-wallet provisioning + funding (§9.1 / §6.1),
  key-rotation procedure (§6.4 steps 1-5),
  cap-decision worksheet (§9.3),
  BetterStack synthetic-alert verification (§9.7 prereq
  item 6),
  cutover sequence ("`payout.enabled: true` ONLY after all
  §9 items checked + synthetic alerts verified").
- **Deploy gate.** Extend
  [`phase4-coordinator/dist/check-deploy-config.sh`](../phase4-coordinator/dist/check-deploy-config.sh)
  to validate every `payout.security.*` and
  `payout.tuning.*` key is either present-with-value or
  absent (any placeholder `<...>` or `env:NAME` mismatch
  fails the gate per
  [[c2-gate-resolves-env-indirected-secrets]]).
- **Config example.** Add a `payout.*` block to
  `phase4-coordinator/dist/coordinator.yaml.example`
  showing every key with placeholder values and a comment
  pointing at SPEC-016 §6.5.

**ACs touched:** SIGHUP-only tuning reload with bound
re-enforcement; security-namespace immutability; chain-
balance drift detection (positive + negative); reconciliation
queries return 0 rows on a healthy fixture; nginx config
forwards `/admin/payout/*` correctly; `dist/check-deploy-config.sh`
rejects a placeholder-only example.

**Test corpus (minimum):**

- Immutability test: mutate every `payout.security.*` key
  in the config file → assert the live value is unchanged
  in the running process (sample via debug endpoint
  scoped to test build, OR via behavior — e.g. hot-edit
  the cap to 0 and observe the runner is NOT capped to 0).
- SIGHUP-tuning test: hot-edit `confirmation_blocks` to 7
  → SIGHUP → next cadence cycle uses 7; emit
  `payout_config_reloaded` PAGE.
- Bound-violation test: hot-edit
  `address_cooling_off_period` to 30m → SIGHUP → live
  value retained at the previous value; emit
  `payout_config_reload_rejected` PAGE.
- fsnotify test: change file mtime without SIGHUP → no
  reload event; live values unchanged.
- Chain-balance drift positive: insert a
  `payout_hot_wallet_funding` row with
  `source='rpc-confirmed'` that exceeds on-chain → emit
  `payout_chain_balance_drift_positive` WARN.
- Chain-balance drift negative: fake-funding-record
  attack simulation → emit
  `payout_chain_balance_drift_negative` PAGE + HALT runner.
- Reconciliation queries: a healthy fixture returns 0 rows
  for each of (A), (B), (chain), (B-forgery), (C-mismatch).
  Inject a NULL `payout_currency` consumed row → query
  finds it.
- Cancel observability query (D): a confirmed cancel
  appears with gas; the result is NEVER added to outflow
  sums in (A) or (chain).

**IMPL audit:**
`specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT.md` → codex →
`specs/SPEC-016-IMPL-STEP_4-audit.md` → fix → loop until
0/0/0. Verify: (a) the security/tuning loader split has NO
shared mutable state (a security key is unreachable from the
tuning reload path); (b) bound re-enforcement at SIGHUP is
identical to parse-time bounds; (c) the
chain-balance reconciliation worker's RPC disagreement path
emits `payout_rpc_disagreement` (not silent fall-through);
(d) `reconcile.sql` is committed verbatim against the §7.4
SPEC text; (e) the deploy gate rejects a placeholder-only
example config.

## 3. Audit-loop discipline (per [[feedback-build-audit-loop]] + [[feedback-codex-only-audits]] + [[feedback-spec-audit-loop-before-pr]])

After each step's code lands on the feature branch:

1. Author the narrow audit prompt at
   `specs/AUDIT_SPEC_016_IMPL_STEP_<N>_PROMPT.md` matching
   existing house style (model after
   [`specs/AUDIT_SPEC_002_v1_3_5_IMPL_PHASES_2A_2B_PROMPT.md`](AUDIT_SPEC_002_v1_3_5_IMPL_PHASES_2A_2B_PROMPT.md)
   or any `AUDIT_SPEC_*_IMPL_*_PROMPT.md`). The audit
   prompt MUST scope to the work just landed — do NOT
   re-audit prior steps' code unless asked.
2. **Fire at codex** via `omc ask codex` or `/ccg`. Per
   [[feedback-codex-only-audits]], **do NOT spawn Claude
   internal subagents** (`code-reviewer`, `security-reviewer`,
   `architect`) for this loop. Same-family auditors share
   the writer's blind spots; the audit-loop discipline
   depends on the diverse-model lens. Claude-internal review
   is OK for one-shot sanity checks but NOT as a replacement
   for codex on the canonical loop.
3. Codex writes findings to a fresh
   `specs/SPEC-016-IMPL-STEP_<N>-audit.md` file per
   [[feedback-spec-audit-file-convention]]. The audit file
   is the canonical narrative; DO NOT inline audit findings
   into IMPL code comments or this prompt or the SPEC body.
4. Claude reads findings, fixes ALL CRITICAL + MAJOR + MED
   in the SAME working branch. If a finding is genuinely
   out-of-scope (e.g. it surfaces a SPEC v0.2 candidate
   rather than an IMPL bug), file it in the SPEC's
   Appendix B follow-up list and DO NOT silently defer in
   code.
5. Re-audit. Loop until codex returns
   **0 CRITICAL / 0 MAJOR / 0 MEDIUM**. LOW findings MAY be
   deferred with explicit justification, but every deferred
   LOW MUST be filed in Appendix B or as a tracking issue
   (per [[tracking-issue-scope-control]]).
6. **Smoke check between code and audit fire** per
   [[feedback-pause-before-audit]]. Run the step's test
   suite first; if anything looks cross-step inconsistent
   (e.g. a Step 2 change accidentally regressed a Step 1
   schema migration), PAUSE and surface — do NOT fire the
   audit on a known-broken state.
7. Only THEN push the branch and open the PR for human
   review.

**`/code-review ultra` composes on top.** The audit loop is
codex; `/code-review ultra` is a parallel-fleet multi-lens
pass. The operator MAY run `/code-review ultra` on each PR
after the codex loop converges; it is the third defense.

## 4. SPEC v0.1.x bundling — NOT applicable here

Per [[feedback-bundle-spec-impl-one-pr]], the
bundling-exception rule covers downstream/incremental SPEC
versions (e.g. v0.2 on top of locked v0.1). **SPEC-016
v0.1.19 is the locked controlling contract** at commit
`5c034a0` on `main`; the IMPL is a separate PR (or PR group)
that depends on it. Do NOT bundle SPEC normative deltas into
this IMPL series. If you discover the SPEC needs to change,
that is a SPEC v0.2 candidate — file it in Appendix B and
proceed with the IMPL against the locked text.

## 5. Repo layout convention (mirrors SPEC-015 v0.3 IMPL)

```
phase4-coordinator/
├── cmd/coordinator/
│   └── main.go                                  (wire-in: payout runner + handlers, gated on payout.enabled)
├── internal/
│   ├── billing/
│   │   ├── payout.go                            (existing — ClaimPayoutReady; SPEC-016 calls but does NOT modify)
│   │   ├── settlement.go                        (existing — RunSettlement; NOT modified by SPEC-016)
│   │   ├── store.go                             (existing — ledger_payout_ready DDL + trg_lpr_terminal_status_guard; NOT modified)
│   │   ├── endpoints.go                         (existing — sliding-window limiter at L453-465 reused by §7.3)
│   │   └── payout_address_reader.go             (NEW — PayoutAddressReader interface DECLARED in billing/)
│   └── payout/                                  (NEW package; cross-package boundary §4.1)
│       ├── runner.go                            (§4.2 cadence, §4.3 per-run algorithm)
│       ├── evm.go                               (§4.4 RPC client, USDC ABI calldata)
│       ├── signer.go                            (§6.3.1 Signer interface + local-file impl)
│       ├── attempts.go                          (§4.5 payout_attempts CRUD)
│       ├── addresses.go                         (§3.1 + §3.3 handler + §3.4 audit)
│       ├── funding.go                           (§4.9 record-funding endpoint)
│       ├── orphans.go                           (§4.7 record-orphan endpoint, payout_reorg_orphans CRUD)
│       ├── abandon.go                           (§4.6 abandon-attempt endpoint)
│       ├── lease.go                             (§4.8b payout_runner_lease semantics)
│       ├── runtime_flags.go                     (§4.8a runtime_flags + outbox + reaper)
│       ├── reorg.go                             (§4.7 reorg detection + cancel/provider carve-out)
│       ├── reconcile.go                         (§7.4 chain-balance worker + observability queries)
│       ├── config_security.go                   (§6.5 immutable-at-startup loader)
│       ├── config_tuning.go                     (§6.5 SIGHUP-only loader + bound re-enforcement)
│       ├── reconcile.sql                        (§7.4 checked-in SQL queries A/B/C/D)
│       └── migrations/                          (§3, §4 schema + triggers + bootstrap seed)
│           ├── 0001_provider_payout_addresses.sql
│           ├── 0002_payout_attempts.sql
│           ├── 0003_payout_runner_state.sql
│           ├── 0004_runtime_flags.sql
│           ├── 0005_payout_runner_lease.sql
│           ├── 0006_payout_hot_wallet_funding.sql
│           ├── 0007_payout_reorg_orphans.sql
│           └── 0008_cancel_reconfirm_stale_outbox.sql
└── dist/
    ├── coordinator.yaml.example                 (extend with payout.* block per §6.5)
    ├── check-deploy-config.sh                   (extend with payout.security.* + payout.tuning.* gates)
    └── payout-runbook.md                        (NEW — operator runbook per §9 + §6.4)
```

The two `config_*.go` files are deliberately separate to
make the security/tuning split visible at the package layer
— a code reviewer looking at `config_tuning.go` can confirm
at a glance that NO `payout.security.*` reference appears.
Similarly the dedicated `lease.go` / `runtime_flags.go`
files keep the §4.8a/b/c machinery scoped.

## 6. Existing primitives — build on, do NOT replace

The IMPL MUST cite and reuse these existing primitives:

- [`phase4-coordinator/internal/billing/store.go:100-127`](../phase4-coordinator/internal/billing/store.go)
  — `ledger_payout_ready` schema (status enum,
  `payout_currency`, `payout_external_id`,
  `idempotency_key` UNIQUE) and
  `trg_lpr_terminal_status_guard` trigger. The
  anticipatory schema columns shipped with SPEC-005
  settlement IMPL; SPEC-016 v0.1.x does NOT touch this
  DDL or the trigger.
- [`phase4-coordinator/internal/billing/payout.go:10`](../phase4-coordinator/internal/billing/payout.go)
  — `func (s *Store) ClaimPayoutReady(ctx context.Context,
  payoutID int64, expectedGrossCredits int64,
  payoutExternalID, payoutCurrency string) (bool, error)`.
  §4.3 step 8 invokes this with
  `payoutCurrency = "USDC-BASE"` (NEVER empty, NEVER NULL).
- [`phase4-coordinator/internal/billing/settlement.go:10`](../phase4-coordinator/internal/billing/settlement.go)
  — `func (s *Store) RunSettlement(ctx, cfg, windowStart,
  windowEnd) error`. Produces `ledger_payout_ready` rows;
  NOT modified by SPEC-016.
- [`phase4-coordinator/internal/billing/store.go:121-126`](../phase4-coordinator/internal/billing/store.go)
  — `trg_lpr_terminal_status_guard`. MUST be preserved by
  exact name (case-sensitive); §4.8a intra-transaction
  trigger-presence check asserts this on every
  `ClaimPayoutReady` call site.
- [`phase4-coordinator/internal/billing/endpoints.go:453-465`](../phase4-coordinator/internal/billing/endpoints.go)
  — per-provider sliding-window limiter. §7.3 MUST reuse,
  NOT reimplement.
- [`phase4-coordinator/internal/auth/tokens.go:247`](../phase4-coordinator/internal/auth/tokens.go)
  — `provider_tokens` is the provider-identity source of
  truth; §3.2 step 3 validates `provider_id` against this.

## 7. Budget + cadence

Estimate: ~1.5 calendar weeks single-engineer for the full
four-step flow + audit loops, NOT counting the operator-side
§9 prerequisites (which are out-of-band). Rough breakdown:

| Step | Code | Audit loop(s) | Total |
|---|---|---|---|
| Step 1 (schema + §3 + §3.2)              | ~2 days | ~1 day  | ~3 days |
| Step 2 (§4.3 runner + §6.3 + §4.6)       | ~3 days | ~1 day  | ~4 days |
| Step 3 (§4.9 + §6.4.1 + §4.7)            | ~2 days | ~0.5 day| ~2.5 days |
| Step 4 (§6.5 + §7.4 + emitters + ops)    | ~1.5 days | ~0.5 day | ~2 days |

Audit rounds: expect 2-4 per step on a money-OUT spec at
this complexity. SPEC-015 receipts IMPL ran 11 steps × 21
audit rounds across the v0.1.3 + v0.2 + v0.3 sequence; a
4-step IMPL with comparable density should expect roughly
8-15 total audit rounds.

The cutover gate (`payout.enabled: false → true` on Pearl
VPS) is downstream of this budget. It runs ONLY after:

- All four IMPL audits return 0/0/0.
- §9 prerequisites checked.
- BetterStack synthetic alerts fired per enumerated
  PAGE/WARN event NAME (§9 prereq item 6).
- A staging-fork run completes the §4.3 cycle end-to-end
  against a real Base RPC pair (Alchemy + QuickNode-class)
  with a $1 test payout to a known address.
- Operator runbook drilled at least once (key-rotation step
  1-5 walkthrough on staging).

## 8. PR workflow on this repo

Per the project [CLAUDE.md](../CLAUDE.md) PR rules:

- **Never develop on local `main`.** Create
  `impl/spec-016-step-1`, `impl/spec-016-step-2`,
  `impl/spec-016-step-3`, `impl/spec-016-step-4` branches
  off the merged tip of the previous step.
- Per [[macprovider-required-review-merge-pattern]] the
  ruleset on `main` requires 1 approving review + CI green
  + branch up-to-date with main. Workflow:
  1. Author + push from `Augustas11` token (the per-repo
     credential helper in `.git/config` routes
     `git push` automatically).
  2. Wait for CI.
  3. `GH_TOKEN=$(gh auth token -u antfleet-ops) gh pr
     review N --approve --body "..."` for the
     code-owner-review approval.
  4. `GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge
     N --squash --delete-branch` (per
     [[gh-pr-merge-augustas11-token-prefix]] the `GH_TOKEN`
     prefix is REQUIRED for `gh pr merge` on this repo).
  5. Locally: `git checkout main && git fetch origin &&
     git reset --hard origin/main` to mirror origin
     (per [[pr-merge-workflow-rule]]).

## 9. Final deliverables when you're done

1. Four IMPL PRs (one per step) merged to `main` on this
   repo.
2. Four audit-file artifacts committed under `specs/`:
   `SPEC-016-IMPL-STEP_{1,2,3,4}-audit.md` (plus any rN
   round files if a step needed multiple audit rounds —
   name as `SPEC-016-IMPL-STEP_N-rN-audit.md`).
3. `phase4-coordinator/dist/payout-runbook.md` checked in.
4. `phase4-coordinator/dist/check-deploy-config.sh`
   extended with all `payout.security.*` and
   `payout.tuning.*` gates.
5. `phase4-coordinator/dist/coordinator.yaml.example`
   extended with the `payout.*` block.
6. [`beta/DECISION_CRITERIA.md`](../beta/DECISION_CRITERIA.md)
   gets a new entry (next available number, decision-log
   merge-last per [[feedback-decision-log-merge-last]])
   recording the IMPL LOCK with: the 4 PRs that landed
   (links), each step's IMPL audit summary (rounds + final
   verdict), operator-pending items (BetterStack synthetic
   alerts, nginx routes, hot wallet funding, KEK backup),
   and cross-cutting follow-ups (the SPEC-016 v0.2 candidates
   listed in Appendix B).

**You're not done when the code compiles. You're not done
when the tests pass. You're done when:**

- All four IMPL audits each return 0 CRITICAL / 0 MAJOR /
  0 MEDIUM,
- The runner has successfully paid a real test transfer on
  Base mainnet via the full §4.3 cycle, with two-RPC
  agreement, against an operator-provisioned hot wallet,
- The §7.4 chain-balance reconciliation reads consistent on
  the first hour post-payment,
- The operator has fired one synthetic BetterStack alert
  per enumerated PAGE/WARN event NAME and confirmed
  delivery,
- The DECISION_CRITERIA entry is appended,
- `payout.enabled: true` is flipped on Pearl VPS and the
  first real provider payment lands on-chain.

## 10. What you must NOT do

- Do NOT re-litigate the rail decision (USDC on Base; see
  [`beta/DECISION_CRITERIA.md`](../beta/DECISION_CRITERIA.md)
  Entry 88). The IMPL author's job is to encode the SPEC.
- Do NOT modify
  [`phase4-coordinator/internal/billing/store.go`](../phase4-coordinator/internal/billing/store.go)
  to extend `ledger_payout_ready` schema — the
  `payout_currency` / `payout_external_id` columns and the
  `trg_lpr_terminal_status_guard` trigger are anticipatory
  primitives shipped with SPEC-005; SPEC-016 v0.1.x reuses
  them unchanged.
- Do NOT rename or drop `trg_lpr_terminal_status_guard`.
  The cross-spec contract pinned in §9.5b.1 binds SPEC-005
  vX.Y+1 to that exact name; renaming it would halt the
  SPEC-016 runner at every cadence cycle's trigger-presence
  check.
- Do NOT introduce a `PayoutAdapter` multi-rail abstraction
  (out of scope per §2 item 6).
- Do NOT add per-payout fee deduction from provider funds
  (out of scope per §2 item 8; gas is paid by the operator).
- Do NOT add an auto-refill loop for the hot wallet (out of
  scope per §2 item 7).
- Do NOT bypass the two-RPC requirement (§4.4); single-RPC
  operation is REJECTED at v0.1.x.
- Do NOT add a `SignMessage` primitive to the Signer
  interface (§6.3.1 footgun carve-out).
- Do NOT use `http.ServeMux` for the `:8444` listener (§3.3
  path-table requirement); use `chi` or `gorilla/mux`.
- Do NOT use `DisallowUnknownFields()` on the §3.3 handler
  — the silent-ignore of `registered_against_hot_wallet` is
  load-bearing for the probing defense.
- Do NOT log `raw_signed_tx` bytes, the `tx_hash` of a
  discarded envelope, or any timing measurement of the
  sign+CAS critical section (§4.3 step 6 side-channel
  discipline).
- Do NOT echo the canonical EIP-55 form in a 400 response
  body (§3.2 step 2; attacker-controlled-input pivot).
- Do NOT add an fsnotify watcher OR a reload-endpoint for
  any `payout.tuning.*` key (§6.5; SIGHUP only).
- Do NOT introduce ANY new bare `payout.X` key without the
  `security.` / `tuning.` infix (§6.5; only `payout.enabled`
  is grandfathered).
- Do NOT introduce ANY new `runtime.*` flag — the namespace
  is CLOSED at v0.1.x (only `runtime.registration_paused`).
  A future SPEC-016 vX.Y MAY extend it but only with the
  full §6.5 discipline (admin endpoint + PAGE event +
  blast-radius analysis).
- Do NOT spawn Claude internal subagents for the audit loop
  (per [[feedback-codex-only-audits]]) — use codex.
- Do NOT inline audit findings into the SPEC body OR into
  this prompt OR into IMPL code comments (per
  [[feedback-spec-audit-file-convention]]) — they live in
  `specs/SPEC-016-IMPL-STEP_<N>-audit.md` files only.
- Do NOT push the branch or open the PR until the
  step-N audit loop returns 0 CRITICAL / 0 MAJOR / 0 MEDIUM
  (per [[feedback-build-audit-loop]]).

When in doubt, re-read
[`specs/SPEC-016-payout-pipeline.md`](SPEC-016-payout-pipeline.md)
at v0.1.x. Every "MUST / MUST NOT" in that file is the
contract you are implementing. Every audit finding from
rounds 9-19 (`specs/SPEC-016-r9-audit.md` through
`SPEC-016-r19-audit.md`) is a real defect class the SPEC
text exists to close — keep them at hand when reading the
SPEC sections.
