# SPEC-016 — Provider payout pipeline (USDC on Base)

**Version:** 0.1 (2026-06-24, draft — round-1 internal-critic fix
pass absorbed: 1 CRITICAL + 5 MAJOR + 4 MINOR + 3 QUESTION
addressed before PR open; subsequent codex round-1/2/.../N
audits to follow on the open PR per
[[feedback-spec-audit-loop-before-pr]])
**Status:** Draft (design-only — no IMPL until operator funds hot wallet
and discharges the five §9 prerequisites).
**Depends on:** SPEC-005 v0.3 (§5.1 unit definition; §11.4 earnings
endpoint; §2.1 D1 donation-only / no-custodial framing),
SPEC-006 v0.9 (buyer surface — not extended by this SPEC),
SPEC-014 v0.8 (provider portal — consumes SPEC-016 read surface;
a SPEC-014 v0.9 candidate MUST add the payout-address registration
screen called out in §3 and §9, filed as a separate follow-up).

---

## Change log

**v0.1 (2026-06-24, draft):**

- Initial draft. Defines the contract by which the existing
  `ledger_payout_ready` rows produced by
  `phase4-coordinator/internal/billing/settlement.go` (SPEC-005
  §11.x) are turned into on-chain USDC transfers on Base mainnet
  to operator-owned provider payout addresses, then claimed
  via the existing `ClaimPayoutReady` primitive at
  `phase4-coordinator/internal/billing/payout.go:10`.
- **Rail locked: USDC on Base (chain id 8453).** Rationale lives
  in `beta/DECISION_CRITERIA.md` Entry 88 (rail decision), not in
  this SPEC body. Summary for reviewers: Antfeed (the P2P AI
  marketplace this network composes with) already settles on
  Base, so the operator's hot-wallet operational surface area is
  shared; sub-cent transfer cost; ~2s blocks; EVM tooling parity.
  USDC contract on Base mainnet is
  `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` — the operator
  MUST verify this against
  `https://basescan.org/token/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
  at IMPL kickoff and pin it into a config constant.
- **Scope explicitly EXCLUDED at v0.1** (see §2): non-Base rails
  (ACH, Stripe Connect, USDC-Solana, etc.), custodial balances,
  provider-side KYC, buyer refunds, multi-currency payout, and
  a `PayoutAdapter` multi-rail abstraction. Each is a future
  vX.Y if it ever ships.
- **Accounting schema is already complete** — `payout_currency`
  and `payout_external_id` columns on `ledger_payout_ready`
  (`phase4-coordinator/internal/billing/store.go:111-112`) were
  added in anticipation of exactly this work. SPEC-016's IMPL
  MUST NOT touch the `ledger_payout_ready` DDL or the existing
  `trg_lpr_terminal_status_guard` trigger
  (`store.go:121-126`).
- **`ClaimPayoutReady` is the only claim primitive** — IMPL
  MUST call the existing function at
  `phase4-coordinator/internal/billing/payout.go:10`, NOT
  define a replacement. The optimistic-concurrency on
  `(id, status='ready', gross_credits=expected)` is the
  double-spend guard.
- **Hot-wallet design at v0.1 is local-file** with an
  operator-supplied encryption key at process start (env var or
  systemd `LoadCredential=`). KMS / HSM is a v0.2 thought
  experiment, captured as a forward pointer in §6 only.
- **Idempotency token at v0.1 is the chain-level `nonce`, NOT
  the tx hash.** The `UNIQUE(from_address, nonce)` constraint on
  `payout_attempts` plus the chain's own nonce-uniqueness rule
  is what guarantees at-most-one on-chain transfer per
  `payout_id`. On retry, IMPL MUST rebroadcast the raw signed
  tx bit-for-bit (stored verbatim in `payout_attempts.raw_signed_tx`)
  rather than re-sign — because re-signing would re-pull a
  fresh gas-fee oracle reading and produce a different signed
  envelope (and therefore a different tx hash) at the same
  nonce. Round-1 audit C1 escalated an earlier draft that
  claimed RFC 6979 deterministic ECDSA alone made the tx hash
  reproducible; the corrected v0.1 wording locks the
  raw-bytes-persistence path. See §4.5 and §6.3.
- **Minimum-viable admin recovery endpoints ship in v0.1.**
  Round-1 audit M1 flagged a three-way circular dependency
  between key rotation (§6.4), reorg-revert handling (§4.7),
  and nonce-gap recovery (§4.6) — all three deferred to a
  hypothetical admin path. v0.1 now ships
  `POST /admin/payout/abandon-attempt` (§4.6) and
  `POST /admin/payout/void` (§4.7) inline so each recovery
  path has a documented operator action that does not require
  direct SQL on a money-path DB.
- **Operator-action prerequisites before IMPL kickoff** —
  enumerated in §9. All five must be discharged or IMPL is
  blocked. The new SPEC-014 portal screen (item 5) is a
  separate v0.9 SPEC-014 bump, not bundled here.
- **Deferred follow-ups filed as Issue stubs**, not inlined:
  (a) SPEC-005 vX.Y+1 candidate: optional snapshot of the
  credit→USD unit invariant in `ledger_config_snapshots` (today
  the invariant is documented at SPEC-005 §5.1 only; if it ever
  changes, payout rows MUST reference the snapshot active at
  the row's window). v0.1 of SPEC-016 takes the invariant as
  read; (b) SPEC-014 v0.9 candidate: payout-address
  registration + payout history screens (§3, §7).
- **No IMPL bundled.** Per
  [[feedback-bundle-spec-impl-one-pr]] EXCEPTION rule, this is
  a net-new SPEC with NO downstream implementer yet; IMPL will
  be written in a fresh session against
  `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` (to be authored
  after v0.1 merges, NOT in this PR).

---

## 1 Scope

SPEC-016 specifies the contract by which `ledger_payout_ready`
rows in `status='ready'` are converted to USDC transfers on Base
mainnet (chain id 8453) to operator-owned provider payout
addresses, marked `status='consumed'` with the on-chain tx hash
recorded in `payout_external_id` and the canonical currency tag
in `payout_currency`, and surfaced in the provider portal
(SPEC-014).

It does NOT specify:

- Settlement (the production of `ledger_payout_ready` rows) —
  that lives in SPEC-005 and ships today via
  `phase4-coordinator/internal/billing/settlement.go:79-130`.
- Portal UI — that lives in SPEC-014; SPEC-016 only defines the
  data shape the portal consumes.
- Buyer billing (gross credits, splits, rate cards) — SPEC-005
  / SPEC-006.

## 2 Out of scope (v0.1)

The following are EXPLICITLY out of scope at v0.1. Future audit
cycles SHOULD use this list as the gate when scope expansion is
proposed.

1. **Custodial balances.** The operator MUST NOT hold per-provider
   balances. The hot wallet only debits; it never credits a
   per-provider account. A provider's USDC ownership transfers
   from "the operator's hot wallet" to "the provider's Base
   address" in a single on-chain transaction.
2. **Non-Base rails.** ACH, Stripe Connect, USDC-Solana, Polygon,
   Ethereum mainnet, USD-on-card, wire, gift card, etc. Filed as
   a future SPEC-016 vX.Y or SPEC-NNN if any rail beyond Base
   USDC ever ships. v0.1 hardcodes USDC-on-Base.
3. **Provider-side KYC.** Each provider supplies a Base address;
   the on-chain transfer IS the receipt. Tax reporting (1099-MISC
   thresholds, T2125 in CA, etc.) is the operator's separate
   obligation and is NOT mediated by this SPEC. SPEC-016 produces
   per-provider per-payout records sufficient for the operator's
   accountant to file; it does not file them.
4. **Buyer refunds / chargebacks.** SPEC-005's
   `idempotency_key` infrastructure on `ledger_payout_ready`
   plus the `voided` terminal status cover credit-side
   reversals. SPEC-016 only moves funds OUT, never back. A
   reorg revert is the closest analogue and is handled by §4
   operator alert + manual `voided`-by-admin path.
5. **Multi-currency payouts.** USDC-on-Base only at v0.1. The
   `payout_currency` column accommodates future expansion;
   v0.1 IMPL MUST always write the canonical string
   `"USDC-BASE"` (uppercase, hyphen-separated, no whitespace
   variants). A future SPEC vX.Y that adds another rail MUST
   define its own canonical string and MUST NOT collide with
   `"USDC-BASE"`.
6. **`PayoutAdapter` multi-rail abstraction.** Do NOT introduce
   a polymorphic rail interface at IMPL time. YAGNI; the
   single-rail concrete implementation is shorter, easier to
   audit, and easier to refactor than a premature abstraction.
   If a SPEC-016 vX.Y ever adds a second rail, that SPEC will
   carry the refactor.
7. **Auto-refill of the hot wallet.** v0.1 has no upstream
   funding loop. The operator funds the hot wallet manually
   from operator treasury; balance monitoring (§6) alerts when
   funds run low; the runner halts when funds insufficient
   (§4).
8. **Per-payout fee deduction from provider funds.** Gas is
   paid from the operator hot wallet (§5); the provider always
   receives the full `provider_credits → USDC` amount.

## 3 Provider payout-address registration (FR-P1)

### 3.1 Storage

There is no `providers` table on the coordinator today —
provider identity lives in `provider_tokens`
(`phase4-coordinator/internal/auth/tokens.go:247`) and the
in-memory `pool.Registry`
(`phase4-coordinator/internal/pool/provider.go:230`). SPEC-016
IMPL MUST create the smallest viable new table:

```sql
CREATE TABLE IF NOT EXISTS provider_payout_addresses (
    provider_id      TEXT NOT NULL,
    chain            TEXT NOT NULL CHECK(chain = 'base-mainnet'),
    address          TEXT NOT NULL,
    payout_allowed   INTEGER NOT NULL DEFAULT 1 CHECK(payout_allowed IN (0,1)),
    registered_at_utc TEXT NOT NULL,
    rotated_from     TEXT NULL,
    UNIQUE(provider_id, chain)
);
CREATE INDEX IF NOT EXISTS idx_ppa_provider ON provider_payout_addresses(provider_id);
```

`registered_at_utc` MUST be rewritten on every successful
rotation (it is the timestamp of the current row's address,
not the timestamp of the first-ever registration). The
predecessor address is preserved in `rotated_from` for the
most recent rotation only; deeper history lives in the
structured log stream (§3.4). v0.1 deliberately omits a
deeper rotation-audit table — round-1 audit Q3 flagged the
same call for `payout_allowed_changed`; both decisions are
revisitable in v0.2 if a fraud-investigation use case
emerges.

The table MUST live in the same SQLite database as
`ledger_payout_ready` so the §7 reconciliation query can join
without cross-DB plumbing.

`payout_allowed` is the §8 compliance gate. Default 1 (allow);
operator MAY flip to 0 to halt payouts for a specific provider
without affecting `ledger_payout_ready` row production.

`chain` is locked to `'base-mainnet'` at v0.1. A future
multi-rail SPEC would relax the CHECK; until then the CHECK is
the canary that catches an accidentally-broadened IMPL.

### 3.2 Address validation

The IMPL MUST validate, before INSERT or UPDATE:

1. Address is exactly 42 ASCII chars, starts with `0x`, and the
   remaining 40 chars are hex (`[0-9a-fA-F]`).
2. EIP-55 enforcement follows the EIP-55 rule exactly: an
   all-lowercase or all-uppercase 40-hex address is accepted
   as checksum-skipped (per EIP-55 §"backward compatibility")
   and IMPL stores the canonicalised mixed-case checksummed
   form. A mixed-case address whose checksum DOES NOT match
   the canonical EIP-55 checksum is REJECTED — that case
   indicates a typo or copy-paste corruption.
3. Address is NOT in a configured deny-list (zero address,
   known burn addresses, known contract addresses incompatible
   with USDC `transfer` semantics — operator MAY add more at
   their discretion via config).

When step 2 rejects a checksum mismatch, the 400 response
body MUST include the canonical checksummed form so the
provider can re-paste without guessing:

```
HTTP/1.1 400 Bad Request
{ "error": "checksum_mismatch",
  "submitted": "0xAbC...wrong...",
  "expected_checksummed": "0xAbC...right..." }
```

The deny-list MUST include at minimum
`0x0000000000000000000000000000000000000000`.

### 3.3 Registration / rotation endpoint

IMPL MUST add a single authenticated endpoint on the
coordinator's `:8444` ws-mux listener. The `:8444` listener
hosts BOTH the operator-key `/admin/*` family AND the
provider-token-authenticated `/providers/{id}/*` family today
(`/providers/{id}/earnings` is the existing precedent at
`phase4-coordinator/internal/billing/endpoints.go:68` —
authenticated on a per-request basis by `provider_token`, not
on a per-listener basis). The new endpoint joins the
`/providers/{id}/*` family on the same listener; the auth
realm is decided per-path, NOT per-listener. A future SPEC
that wants to physically separate operator and provider
surfaces MAY do so, but v0.1 follows the existing convention
to keep operator-side nginx config one block.

```
POST /providers/{provider_id}/payout-address
Authorization: Bearer <provider_token>   ; per SPEC-002 §7.3
Content-Type: application/json

{ "chain": "base-mainnet", "address": "0xAbC...checksummed" }

Response (2xx):
  201 Created      — new registration
  200 OK           — rotation (replaces existing row)
  400 Bad Request  — failed §3.2 validation (include reason)
  401 Unauthorized — invalid / missing provider_token
  403 Forbidden    — provider_token does not own provider_id
  409 Conflict     — payout_allowed=0 (operator gate; surface
                     reason as "payout_disabled_by_operator")
```

The endpoint MUST authenticate via the provider's per-Mac
`provider_token` (the same token SPEC-014 portal uses for
`/providers/{id}/earnings`); the operator key is NOT accepted on
this surface (rotations are provider-initiated only).

The endpoint MUST NOT be exposed on the buyer-facing `:8443`
listener.

### 3.4 Rotation audit

Every successful INSERT or UPDATE MUST emit a structured log
line at info level:

```
event=provider_payout_address_changed
provider_id=<id>
chain=base-mainnet
old_address=<0x...|none>
new_address=<0x...>
actor=provider_token
ts_utc=<RFC3339Nano>
```

These log lines are operator-monitorable. v0.1 does NOT add a
separate audit table for address changes; the structured log
plus the `provider_payout_addresses.rotated_from` column are
sufficient. A future SPEC vX.Y MAY promote to a dedicated audit
table if a fraud-investigation use case emerges.

### 3.5 Gate on settlement

A provider with no row in `provider_payout_addresses` (or with
`payout_allowed=0`) MUST NOT have any payout attempt initiated
on their behalf. Their `ledger_payout_ready` rows remain in
`status='ready'` indefinitely until §3.3 succeeds.

The portal MUST surface this state per-provider (SPEC-014 v0.9
candidate) and the operator MUST be able to count it system-wide
(see §7 reconciliation query).

## 4 Payout execution loop (FR-P2)

### 4.1 Process placement

IMPL MUST add a new package
`phase4-coordinator/internal/payout/` containing:

- `runner.go` — the periodic loop.
- `evm.go` — Base RPC client + ABI encoding for USDC
  `transfer(address,uint256)`.
- `wallet.go` — encrypted-at-rest signing key load + sign.
- `attempts.go` — `payout_attempts` table CRUD (§4.5).

The runner is started from `cmd/coordinator/main.go` only when
config explicitly enables it (`payout.enabled: true`). Default
config MUST ship `payout.enabled: false` so a production
coordinator does not start the loop without operator intent.

### 4.2 Cadence

- Default cadence: every 6 hours.
- Configurable via `payout.run_interval` (Go duration string,
  minimum 5 minutes — below 5m is rejected at config-parse so
  a typo cannot turn the runner into a tight RPC loop).
- Operator MAY trigger a single immediate run via
  `POST /admin/payout/run-now` on the `:8444` listener
  (operator-key authenticated, same pattern as
  `/admin/ledger/*`). This endpoint MUST be idempotent within
  a single in-flight run (return 409 if a run is already
  active).

### 4.3 Per-run algorithm

For each scheduled run, the loop MUST execute the following
steps **in order**, exiting any later step on error and logging
the failure structurally:

1. **Select.** `SELECT lpr.id, lpr.provider_id,
   lpr.gross_credits, lpr.provider_credits,
   lpr.window_start_utc, lpr.window_end_utc, ppa.address
   FROM ledger_payout_ready lpr
   INNER JOIN provider_payout_addresses ppa
     ON ppa.provider_id = lpr.provider_id
    AND ppa.chain = 'base-mainnet'
    AND ppa.payout_allowed = 1
   WHERE lpr.status = 'ready'
   ORDER BY lpr.id ASC`. The `gross_credits` column MUST be
   in the projection because step 7's
   `ClaimPayoutReady(expectedGrossCredits=...)` optimistic-
   concurrency guard locks on the row's unsplit total, NOT
   on `provider_credits` (round-1 audit M2). Cap at
   `payout.max_rows_per_run` (default 50) to bound a single
   run's wall-clock and gas exposure.
2. **Per-row amount.** USDC amount in base units (6 decimals on
   Base) equals `provider_credits` exactly. SPEC-005 §5.1 locks
   1 credit = 1 USD micro-dollar = 10⁻⁶ USD, and USDC on Base
   uses 6 decimals, so the conversion is a unit identity, not a
   rate lookup. IMPL MUST hardcode this identity and MUST
   reject (log + skip row) any future configuration that tries
   to introduce a multiplier.
3. **Cap check.** Apply §5 caps. If the row's amount exceeds
   the per-payout cap, OR cumulative paid amount this calendar
   day would exceed the per-day cap, skip the row and emit a
   `payout_capped` log line citing which cap fired. The row
   remains in `status='ready'` for a future run.
4. **Attempt record.** Open or load the row's
   `payout_attempts` entry (§4.5). If a prior attempt's tx is
   already confirmed, jump to step 7. If a prior attempt is
   pending and not yet timed out, jump to step 6 to poll. If
   no attempt exists, generate a fresh nonce per §4.6.
5. **Build + sign + broadcast.** Build USDC `transfer(to,
   amount)` calldata; build EIP-1559 tx with hot-wallet
   sender, the computed nonce, the chain id 8453, and the
   USDC contract from §change-log as `to`; sign with the
   wallet key (§6); broadcast via configured RPC. Persist the
   resulting tx hash on the `payout_attempts` row BEFORE
   broadcasting (so a process crash mid-broadcast leaves the
   nonce reserved for the same row).
6. **Confirm.** Poll the RPC for the tx receipt. MUST wait
   `payout.confirmation_blocks` deep (default 5; minimum 2;
   maximum 50). Base produces ~2s blocks so default ~10s
   wall-clock at the bottom of the loop. Two blocks is the
   bare minimum used in v0.1 examples; operator MAY raise.
   Document the tradeoff inline in config: lower = faster
   payout but higher reorg-exposure; higher = slower but
   safer.
7. **Claim.** Call the existing
   `ClaimPayoutReady(ctx, payoutID, expectedGrossCredits,
   payoutExternalID, "USDC-BASE")` at
   `phase4-coordinator/internal/billing/payout.go:10`. The
   function signature is
   `(ctx context.Context, payoutID int64, expectedGrossCredits int64, payoutExternalID, payoutCurrency string) (bool, error)`.
   `expectedGrossCredits` MUST be `lpr.gross_credits` from
   step 1 (NOT `provider_credits` — the optimistic-
   concurrency guard locks on the unsplit row total).
   `payoutExternalID` MUST be the confirmed tx hash from
   step 6. `payoutCurrency` MUST be the literal string
   `"USDC-BASE"`. The function already does optimistic
   concurrency on `(id, status='ready',
   gross_credits=expected)` so a parallel runner instance
   cannot double-claim.
8. **Log.** Emit a `payout_paid` structured log line per
   §7. On any failure in steps 5-7, emit `payout_failed` with
   the error class.

### 4.4 RPC failure tolerance

The runner MUST tolerate transient RPC errors at steps 5 and
6:

- Step 5 broadcast failure → retry up to N times (default 3)
  with exponential backoff, then leave the row pending for the
  next run cycle. Do NOT mark `consumed` (no tx hash exists).
- Step 6 receipt-poll failure → retry up to a wall-clock budget
  (default 5 minutes per row). If the budget expires, leave
  the attempt in pending state; the next run cycle picks it up
  via step 4.

The runner MUST NOT advance to step 7 (claim) without a
confirmed tx hash from step 6.

### 4.5 Per-row attempt table (deterministic retry)

```sql
CREATE TABLE IF NOT EXISTS payout_attempts (
    payout_id        INTEGER PRIMARY KEY REFERENCES ledger_payout_ready(id),
    chain            TEXT NOT NULL CHECK(chain = 'base-mainnet'),
    from_address     TEXT NOT NULL,
    to_address       TEXT NOT NULL,
    amount_base_units INTEGER NOT NULL CHECK(amount_base_units > 0),
    nonce            INTEGER NOT NULL CHECK(nonce >= 0),
    raw_signed_tx    BLOB NULL,
    tx_hash          TEXT NULL,
    broadcast_at_utc TEXT NULL,
    confirmed_at_utc TEXT NULL,
    block_number     INTEGER NULL,
    last_error       TEXT NULL,
    abandoned_at_utc TEXT NULL,
    abandoned_reason TEXT NULL,
    updated_at_utc   TEXT NOT NULL,
    UNIQUE(from_address, nonce)
);
CREATE INDEX IF NOT EXISTS idx_pa_unconfirmed ON payout_attempts(confirmed_at_utc) WHERE confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL;
```

The `chain` CHECK matches the §3.1 canary on
`provider_payout_addresses.chain` so a future multi-rail
expansion cannot silently land here without amending both
constraints.

The `UNIQUE(from_address, nonce)` constraint plus the
chain's own nonce-uniqueness rule guarantees at most ONE
confirmed on-chain transfer per `payout_id`. The signed tx
envelope itself is persisted in `raw_signed_tx` BEFORE
broadcast in step 5, so on retry IMPL MUST rebroadcast the
exact bytes — re-signing is FORBIDDEN, because re-signing
would re-pull a fresh gas-fee oracle reading and produce a
different signed envelope (different tx hash) at the same
nonce. On retry, IMPL MAY accept that a previously-broadcast
nonce is already pending or confirmed on-chain — the canonical
resolution path is `getTransactionByNonce`/`getTransactionCount`,
NOT the locally-stored tx hash.

`abandoned_at_utc` + `abandoned_reason` are populated only
via the `POST /admin/payout/abandon-attempt` admin endpoint
in §4.6. An abandoned attempt is no longer eligible for the
runner's step 4 reuse path; the row's payout_id is moved
back to the runner's fresh-attempt path on the next cadence
cycle (which will allocate a new nonce, requiring the
operator to have already filled the abandoned nonce with a
self-transfer per §4.6).

### 4.6 Nonce strategy

- IMPL maintains a `wallet_nonce_cursor` (single row, single
  column) per `from_address`. At runner startup it MUST sync
  the cursor to `max(getTransactionCount(latest),
  getTransactionCount(pending))` from the RPC, then take
  `max(cursor_in_db, rpc_value)` to handle the case where the
  in-DB cursor is ahead (a prior broadcast crashed before
  receipt-poll).
- On step 4 fresh-attempt, claim the next nonce from the
  cursor atomically (`UPDATE wallet_nonce_cursor SET nonce =
  nonce + 1 WHERE ...; assign returned value`). Persist
  `(payout_id, nonce)` in `payout_attempts` BEFORE step 5.
- On step 5 retry of an existing attempt, REUSE the persisted
  nonce. Do not allocate a new one.
- Nonce gaps (a payout_id whose attempt was abandoned without
  ever confirming on-chain) MUST be filled with an explicit
  0-value self-transfer at the same nonce before any
  subsequent payout can use higher nonces. v0.1 ships the
  minimum-viable operator-driven recovery path:

  ```
  POST /admin/payout/abandon-attempt
  Authorization: Bearer <operator_key>
  { "payout_id": 123,
    "broadcast_cancel_self_transfer": true,
    "reason": "free-text required" }

  Response:
    200 OK   — abandoned_at_utc/abandoned_reason set on the row;
               if broadcast_cancel_self_transfer=true, the runner
               also signs + broadcasts a 0-value transfer from
               from_address → from_address at the same nonce
               with a higher gas tip (default 2× current oracle)
               to outrun any stuck pending tx at that nonce.
    409 Conflict — attempt already confirmed; nothing to abandon.
  ```

  Until this endpoint is called for a gap-causing payout_id,
  the runner halts at the next cadence cycle and emits
  `payout_nonce_gap` per cycle. No automatic gap-filling is
  attempted — the operator is the only authority for
  cancelling a payment-in-progress.

### 4.7 Reorg handling

Base reorgs past `payout.confirmation_blocks` are vanishingly
rare in practice but possible. The `trg_lpr_terminal_status_guard`
trigger
(`phase4-coordinator/internal/billing/store.go:121-126`) is
intentional: `consumed` is terminal under normal updates. If
the runner observes that a previously-confirmed tx is no
longer present in the canonical chain (receipt returns "not
found" after a prior confirmation), it MUST:

1. Emit a `payout_reorg_revert` structured log + alert
   (severity: page operator).
2. NOT attempt automatic revert. The runner has no controlled
   trigger-bypass path.
3. NOT attempt a new transfer for the same `payout_id` without
   operator action. The `payout_external_id` column already
   holds the orphaned tx hash.

Operator-driven recovery is via a v0.1 admin endpoint:

```
POST /admin/payout/void
Authorization: Bearer <operator_key>
{ "payout_id": 123,
  "new_status": "voided",   ; or "ready" to re-attempt
  "reason": "free-text required (logged)" }

Response:
  200 OK   — status transitioned; payout_external_id retained
             (orphan tx hash is forensic evidence, not deleted).
  400      — new_status not in {voided, ready}.
  409      — current status not 'consumed'.
```

Implementation MUST use a single-transaction
`DROP TRIGGER trg_lpr_terminal_status_guard; UPDATE
ledger_payout_ready SET status = ? WHERE id = ?; CREATE
TRIGGER trg_lpr_terminal_status_guard ...;` sequence to
bypass the terminal guard for this controlled path. The
trigger MUST be reinstated within the same transaction; a
crash mid-transaction leaves the trigger restored on the
next sqlite open because the DROP and CREATE are atomic
with the UPDATE. A `payout_voided_by_admin` structured log
line MUST be emitted with the full request payload + the
operator-key principal.

The endpoint exists ONLY for reorg-revert resolution and
operator-disputed-payment handling; routine flow MUST NEVER
touch this path. A unit test MUST assert the trigger is
present after the endpoint runs.

### 4.8 Runner state

The runner MUST persist its high-water-mark wall-clock and
result counters to a single-row `payout_runner_state` table so
SPEC-014's portal can render "last run: <ts>, paid: N, capped:
M, failed: K, skipped-no-address: J". Schema:

```sql
CREATE TABLE IF NOT EXISTS payout_runner_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    last_run_started_at_utc  TEXT NULL,
    last_run_finished_at_utc TEXT NULL,
    last_run_paid            INTEGER NOT NULL DEFAULT 0,
    last_run_capped          INTEGER NOT NULL DEFAULT 0,
    last_run_failed          INTEGER NOT NULL DEFAULT 0,
    last_run_skipped_no_addr INTEGER NOT NULL DEFAULT 0,
    last_run_error_text      TEXT NULL,
    updated_at_utc           TEXT NOT NULL
);
```

## 5 Fee policy (FR-P3)

### 5.1 Gas on the operator

Gas fees on Base are paid from the operator hot wallet, NOT
deducted from `provider_credits`. The provider always receives
exactly `provider_credits` USDC base units. At Base's typical
sub-cent transfer cost (~$0.001-$0.01 per ERC-20 `transfer` at
2026 base-fee levels), the operator's per-payout gas overhead
is negligible against the per-payout amount; v0.2 MAY revisit
if Base base-fees rise structurally above 10% of typical
payout sizes.

### 5.2 Per-payout cap

`payout.per_payout_cap_usdc_base_units` — default
`500_000_000` (i.e. $500 = 500 USDC = 500 × 10⁶ base units).
All caps in SPEC-016 are expressed in USDC base units (==
USD micro-dollars == credits, by the SPEC-005 §5.1 unit
identity); the legacy "USD cents" wording from an earlier
draft was a 10,000× unit error caught by round-1 audit M3.

A row whose `provider_credits` exceeds this cap is SKIPPED
with `payout_capped reason=per_payout`. The row remains
`status='ready'` for operator review.

The operator MAY split a capped row manually via the SPEC-005
settlement-admin path (out of scope here) or MAY raise the
cap via config + restart. v0.1 does NOT auto-split.

### 5.3 Per-day cap

`payout.per_day_cap_usdc_base_units` — default
`5_000_000_000` (i.e. $5,000 = 5,000 USDC). Computed against
a rolling 24h window of confirmed transfers from the hot
wallet:

```sql
SELECT COALESCE(SUM(amount_base_units), 0)
  FROM payout_attempts
 WHERE confirmed_at_utc IS NOT NULL
   AND abandoned_at_utc IS NULL
   AND confirmed_at_utc >= :now_minus_24h;
```

Both sides are in USDC base units; no unit conversion. When
the next row's amount would push the window total past the
cap, the runner SKIPS that row (and all subsequent rows in
the run) and emits `payout_daily_cap_tripped`. The runner
resumes on the next cadence cycle whose 24h-window total is
back below the cap.

### 5.4 Minimum payout

The minimum payout is already enforced upstream by SPEC-005
`MinPayoutCredits`
(`phase4-coordinator/internal/billing/settlement.go`); a row
below the threshold is never written to `ledger_payout_ready`
in the first place. SPEC-016 IMPL MUST NOT add a second
minimum-payout check.

## 6 Hot-wallet operations (FR-P4)

### 6.1 Funding

The operator funds the hot wallet manually from operator
treasury (a separate cold wallet or exchange withdrawal). v0.1
has NO auto-refill path. v0.2 MAY add an alert hook to the
operator's treasury management; v0.1 does not.

### 6.2 Balance monitoring

The runner MUST expose hot-wallet USDC balance + native ETH
balance as a `/admin/payout/balance` JSON endpoint on the
`:8444` listener (operator-key authenticated). Response shape:

```json
{
  "from_address": "0x...",
  "usdc_base_units": 12345600,
  "native_wei": 1234567890000000,
  "as_of_block": 1234567,
  "as_of_utc": "2026-..."
}
```

The runner MUST also emit a structured log line every cadence
cycle. When `usdc_base_units < payout.low_balance_threshold`
(default: `2 * payout.per_day_cap_usdc_base_units` — round-1
audit Q2 flagged an earlier draft that referenced
`sum(ready rows)` which can grow unboundedly during a halt
state and would render the threshold useless), emit a
`payout_low_balance` alert at warning level. The operator's
existing alerting path (BetterStack journalctl filter, per
Entry 81 — `[[deve2-betterstack-live]]`) MUST be the consumer;
SPEC-016 does NOT add a new alerting channel.

When `usdc_base_units` is insufficient to cover the next
selected row's amount, the runner SKIPS that row (and any
subsequent rows in the run), emits `payout_insufficient_funds`,
and halts until the next cadence cycle.

### 6.3 Key custody

The wallet signing key MUST be persisted on-disk in encrypted
form. The AES key-encryption-key that decrypts the on-disk
wallet file MUST be supplied by the operator at process start
via either:

- environment variable `MACPROVIDER_PAYOUT_WALLET_KEK`
  (loaded ONLY into process memory; never echoed; never
  printed in logs), OR
- systemd `LoadCredential=` (preferred — sourced from a
  systemd-creds-encrypted blob outside the process working
  directory).

The wallet signing key is decrypted in process memory on
startup and held in a `[]byte` pinned with `mlock` (or the
equivalent) for the runner's lifetime. The plaintext signing
key MUST NEVER be persisted to disk by the coordinator. The
plaintext MUST NEVER be written to log lines or returned in
any HTTP response. The KEK plaintext MUST NEVER be persisted
to disk either; if the operator provides it via env var, the
unit/launchd file MUST source from a credentials store, not
hardcode the secret.

Round-1 audit C1 escalated an earlier draft claim that RFC
6979 deterministic ECDSA reproduces tx hashes on retry. That
claim is FALSE in EIP-1559: the signed envelope includes
`maxFeePerGas` and `maxPriorityFeePerGas`, which a retry
re-pulls from a live gas oracle, producing a different
signed envelope (and therefore different tx hash) at the
same nonce. v0.1's correct invariant: the chain-level
`nonce` is the idempotency token; the signed envelope is
persisted to `payout_attempts.raw_signed_tx` BEFORE
broadcast (§4.3 step 5) and re-broadcast bit-for-bit on
retry. RFC 6979 is RECOMMENDED for general safety hygiene
(eliminates nonce-reuse attack class against the ECDSA
signing nonce, NOT the EVM tx nonce) but is NOT
load-bearing for SPEC-016's idempotency guarantee.

### 6.4 Key rotation

Procedure (manual, operator-driven):

1. Halt the runner (`payout.enabled: false` + restart).
2. For each `payout_attempts` row with `confirmed_at_utc IS
   NULL AND abandoned_at_utc IS NULL`, the operator MUST
   either wait for confirmation or call
   `POST /admin/payout/abandon-attempt` (§4.6,
   `broadcast_cancel_self_transfer=true`) to push a
   higher-tip self-transfer at the stuck nonce. v0.1 ships
   this admin endpoint inline; round-1 audit M1 flagged the
   earlier draft's circular-dependency hand-wave.
3. Generate fresh wallet; transfer remaining hot-wallet
   balance to the fresh address (a single regular USDC
   transfer signed by the OLD wallet); rewrite the
   encrypted wallet file + config; rotate the KEK if also
   compromising the on-disk envelope.
4. Restart with `payout.enabled: true`. The runner re-syncs
   the nonce cursor from the new address's `getTransactionCount`
   per §4.6, so the new wallet starts at its own nonce 0.

A future v0.2 MAY add an in-process rotation path; v0.1
requires the restart.

### 6.5 KMS / HSM (forward pointer, not normative for v0.1)

A v0.2 thought-experiment: replace the local encrypted file
with a KMS-backed signing API (AWS KMS, GCP Cloud KMS, or a
self-hosted Vault Transit). This is NOT part of v0.1. v0.1
local-file is sufficient because (a) the operator is a single
party, (b) the hot wallet float is small (§6.1 manual
funding), and (c) the v0.1 audit surface is materially shorter
without a remote-signing dependency.

## 7 Auditability & receipts (FR-P5)

### 7.1 Structured logs (operator's source of truth)

Every payout-runner action MUST emit a structured log line at
info or warn level via the existing zerolog setup
(`phase4-coordinator/internal/billing/endpoints.go:44`-style).
Required event names and minimum field set:

| event | fields |
|---|---|
| `payout_run_started` | `run_id, ts_utc` |
| `payout_run_finished` | `run_id, ts_utc, paid, capped, failed, skipped_no_addr, skipped_funds, error_text` |
| `payout_paid` | `run_id, payout_id, provider_id, amount_usdc_base_units, tx_hash, block_number, nonce, ts_utc` |
| `payout_failed` | `run_id, payout_id, provider_id, stage, error_class, error_text, ts_utc` |
| `payout_capped` | `run_id, payout_id, provider_id, reason, ts_utc` |
| `payout_low_balance` | `from_address, usdc_base_units, threshold, ts_utc` |
| `payout_insufficient_funds` | `run_id, payout_id, provider_id, required_usdc_base_units, available_usdc_base_units, ts_utc` |
| `payout_daily_cap_tripped` | `run_id, window_paid_usd_cents, cap_usd_cents, ts_utc` |
| `payout_reorg_revert` | `payout_id, tx_hash, last_seen_block, ts_utc` |
| `payout_nonce_gap` | `from_address, expected_nonce, observed_pending_nonce, ts_utc` |
| `payout_attempt_abandoned` | `payout_id, nonce, cancel_self_transfer_tx_hash, reason, actor=operator_key, ts_utc` |
| `payout_voided_by_admin` | `payout_id, old_status, new_status, orphan_tx_hash, reason, actor=operator_key, ts_utc` |
| `payout_allowed_changed` | `provider_id, old_allowed, new_allowed, reason, actor=operator_key, ts_utc` |
| `provider_payout_address_changed` | per §3.4 |

Retention: these logs are the operator's source of truth for
tax filings and dispute response. IMPL MUST document a 7-year
retention default; operator MAY override per local jurisdiction.
Retention is enforced by the existing journalctl/BetterStack
archive pipeline, not by SPEC-016.

### 7.2 Portal surface

SPEC-014 v0.9 (filed as a separate follow-up; NOT in this PR)
MUST add a "Payouts" surface that renders, per the requesting
provider's `provider_token`:

- Current registered payout address (or "not set" with a CTA).
- Last 50 payouts: `(window_end_utc, provider_credits → USD,
  tx_hash → basescan link, block_number, paid_at_utc)`.
- Pending payouts: count + total USD of `ready` rows for that
  provider waiting on either §3 address registration or the
  next runner cycle.

SPEC-016 v0.1 surfaces the data via two existing endpoints:

- `GET /providers/{provider_id}/earnings` (extend response —
  filed as a SPEC-005 vX.Y+1 follow-up; v0.1 of SPEC-016 does
  NOT inline the schema change).
- `GET /providers/{provider_id}/payouts` (NEW; specified
  inline below).

### 7.3 Provider-facing payouts read endpoint

```
GET /providers/{provider_id}/payouts?limit=50
Authorization: Bearer <provider_token>

200 OK:
{
  "provider_id": "...",
  "registered_address": "0x..." | null,
  "payout_allowed": true | false,
  "paid": [
    {
      "payout_id": 123,
      "window_start_utc": "...",
      "window_end_utc": "...",
      "amount_usdc_base_units": 12340000,
      "tx_hash": "0x...",
      "block_number": 1234567,
      "paid_at_utc": "..."
    }
  ],
  "pending": {
    "count": 2,
    "total_amount_usdc_base_units": 5400000
  }
}
```

Same auth contract as `/providers/{id}/earnings`: the
`provider_token` MUST own `provider_id`, else 403.

### 7.4 Weekly reconciliation query

The operator MUST be able to run a single SQL query that
confirms the on-chain ledger matches the in-DB ledger over an
arbitrary window. IMPL MUST commit the query as a checked-in
file at `phase4-coordinator/internal/payout/reconcile.sql`
matching this shape:

```sql
-- Per-provider sum of on-chain transfers (DB-side proxy via
-- payout_attempts.confirmed_at_utc + amount_base_units),
-- joined to ledger_payout_ready rows transitioned to consumed
-- in the same window.
-- Units: both sides are in USDC base units. By SPEC-005 §5.1
-- the credit unit identity is 1 credit == $0.000001 == 1 USDC
-- base unit, and §4.3 step 2 of SPEC-016 hardcodes the same
-- identity in the runner. delta != 0 means either (a) the
-- runner broadcast an amount that doesn't match the row's
-- provider_credits (paths through cap/abandon/admin are the
-- candidates) or (b) someone hand-edited the DB.
SELECT
  lpr.provider_id,
  SUM(lpr.provider_credits) AS in_db_credits,
  SUM(pa.amount_base_units) AS on_chain_usdc_base_units,
  SUM(lpr.provider_credits) - SUM(pa.amount_base_units) AS delta
FROM ledger_payout_ready lpr
INNER JOIN payout_attempts pa ON pa.payout_id = lpr.id
WHERE lpr.status = 'consumed'
  AND lpr.payout_currency = 'USDC-BASE'
  AND pa.confirmed_at_utc IS NOT NULL
  AND pa.abandoned_at_utc IS NULL
  AND pa.confirmed_at_utc >= :from_utc
  AND pa.confirmed_at_utc <  :to_utc
GROUP BY lpr.provider_id
HAVING delta != 0;
```

Any row returned (i.e. `delta != 0`) is a reconciliation
failure and MUST be investigated. The expected steady-state
output is zero rows. The query is intentionally in-DB only —
the operator MAY ALSO cross-check via Etherscan/Basescan
export of hot-wallet transfers in the same window; that
cross-check is procedural and NOT specified in SPEC-016.

## 8 Compliance posture (FR-P6)

SPEC-016 takes NO position on the operator's KYC / AML
obligations. The technical machinery is rail-agnostic to
compliance state — a `ledger_payout_ready` row may be in
`status='ready'` and the runner gates separately on
`provider_payout_addresses.payout_allowed = 1` (§3.1).

The operator MUST consult counsel before flipping the runner
on for any provider in a regulated jurisdiction. The operator
controls which providers are eligible by toggling
`payout_allowed` via a separate operator-only admin endpoint:

```
POST /admin/payout/allow
Authorization: Bearer <operator_key>
{"provider_id": "...", "allowed": true}
```

Toggling `payout_allowed=0` does NOT void existing
`ledger_payout_ready` rows; it only prevents the runner from
selecting them in §4.3 step 1. Operator restoration to
`allowed=1` resumes payout on the next cadence cycle.

A `payout_allowed_changed` structured log line MUST be emitted
on every transition, with the same field set as
`provider_payout_address_changed` plus an `actor=operator_key`
tag.

## 9 Operator-action prerequisites before IMPL ships

IMPL MUST NOT begin until ALL FIVE of the following are
discharged by the operator. Each is the operator's responsibility,
not SPEC-016 IMPL's:

1. **Hot wallet provisioned + funded.** Operator creates a fresh
   Base address (or designates an existing single-purpose
   address), funds it with USDC for initial testing (suggested
   float: 100 USDC for v0.1 smoke), and funds it with ~$5
   equivalent of native ETH for gas headroom. The encrypted
   wallet file is generated and the AES key is loaded via
   systemd `LoadCredential=` (preferred) or env var (acceptable
   for early testing). The address is pinned in
   `payout.hot_wallet_address` config.
2. **RPC provider chosen + API key provisioned.** Operator
   picks an RPC (Alchemy / QuickNode / Infura / self-hosted),
   provisions an API key with rate limits suitable for one
   payout run per 6h plus admin balance reads, pins the URL +
   key in `payout.rpc_url` config. v0.1 IMPL MAY assume a
   single RPC; v0.2 MAY add a fallback.
3. **Cap decisions.** Operator sets `payout.per_payout_cap`,
   `payout.per_day_cap`, `payout.run_interval`,
   `payout.confirmation_blocks`. Defaults from §4.2 and §5 are
   the starting point; operator MAY override per their risk
   tolerance.
4. **Compliance posture decision.** Operator decides which
   providers are eligible at flip-on time (initial bulk
   `payout_allowed = 1` set), and documents the policy that
   gates future provider eligibility. Without this, default 1
   in §3.1 ships every provider eligible — that is the
   operator's choice, not SPEC-016's.
5. **SPEC-014 v0.9 portal screen** for payout-address
   registration. Without the portal screen, providers have no
   way to register the address `:8444 POST
   /providers/{id}/payout-address` requires. The portal screen
   is a SEPARATE follow-up SPEC and a separate IMPL; SPEC-016
   IMPL MAY ship before SPEC-014 v0.9 if the operator is
   willing to use `curl` for the initial provider set, but the
   SPEC-014 v0.9 work is named here as the gating production
   surface.

Without all 5, IMPL is blocked.

---

## Appendix A — IMPL prompt name

The next deliverable (NOT created in this PR) is
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`, authored in a
fresh session after this v0.1 merges. That prompt will:

- Reference this SPEC at v0.1 as the controlling contract.
- Carry the §9 prerequisites as a pre-flight checklist.
- Run the same SPEC-audit-loop discipline applied to IMPL work
  per `[[feedback-build-audit-loop]]`.

## Appendix B — Deferred follow-ups (filed as Issue stubs, not inlined)

- SPEC-014 v0.9: payout-address registration screen + payout
  history surface. Consumes §3.3 and §7.3.
- SPEC-005 vX.Y+1: extend `/providers/{id}/earnings` response
  with `next_payout_eta`, `last_payout_tx_hash`,
  `last_payout_paid_at_utc`. Pure additive; SPEC-016 v0.1 does
  NOT require it.
- SPEC-016 v0.2 candidates: KMS-backed signing (§6.5);
  auto-split of over-cap payouts (§5.2); RPC fallback (§9
  item 2); in-process key rotation (§6.4); automated nonce-gap
  fill (§4.6, replacing the operator-driven
  `/admin/payout/abandon-attempt` flow with a runner-internal
  policy). NOTE: `POST /admin/payout/void` (§4.7) and
  `POST /admin/payout/abandon-attempt` (§4.6) are IN-SCOPE
  for v0.1 per the round-1 audit M1 fix, not deferred.
