# SPEC-016 — Provider payout pipeline (USDC on Base)

**Version:** 0.1.1 (2026-06-24, draft — round-2 audit fix pass
absorbed: 5 CRITICAL + 12 MAJOR + 10 MEDIUM across CODE +
SECURITY + ARCHITECT lenses addressed; subsequent codex rounds
to follow per [[feedback-spec-audit-loop-before-pr]])
**Status:** Draft (design-only — no IMPL until operator funds hot
wallet and discharges the eight §9 prerequisites).
**Depends on:** SPEC-005 v0.3 (§5.1 unit definition; §10.1 WAL
mode + synchronous=FULL requirement; §11.4 earnings endpoint;
§2.1 D1 donation-only / no-custodial framing),
SPEC-006 v0.9 (buyer surface — not extended by this SPEC),
SPEC-014 v0.8 (provider portal — consumes SPEC-016 read
surface; SPEC-014 v0.9 candidate MUST add the payout-address
registration + payout history screens called out in §3 and §9,
filed as a separate follow-up).

---

## Change log

**v0.1.1 (2026-06-24, draft — round-2 audit fix pass):**

Round-2 lens-parallel audit (CODE + SECURITY + ARCHITECT,
three subagents run independently) returned a combined
5 CRITICAL + 12 MAJOR + 10 MEDIUM. All addressed. Substantive
contract changes below are normative; cosmetic/wording fixes
are not enumerated.

CRITICAL closures:

- **C1 (CODE) — trigger-bypass concurrency model was broken.**
  v0.1 §4.7 had IMPL `DROP TRIGGER trg_lpr_terminal_status_guard;
  UPDATE ...; CREATE TRIGGER ...` for reorg revert. In WAL mode,
  other connections see the schema mid-flight; a concurrent
  `ClaimPayoutReady` writer can transition rows without the
  guard. v0.1.1 §4.7 REWRITTEN: no runtime trigger manipulation.
  Reorg-revert is now record-only — orphan tx hashes land in a
  new `payout_reorg_orphans` table; the `consumed` row is NOT
  reverted (the trigger is intentional). Operator chooses
  whether to compensate the provider by issuing a fresh
  `ledger_payout_ready` row via the SPEC-005 settlement-admin
  path; SPEC-016 does NOT touch the SPEC-005 row's terminal
  state.
- **C2 (CODE) — trigger CREATE body not spelled out.** Moot
  under the §4.7 rewrite: SPEC-016 never re-creates the
  trigger.
- **C3 (SEC) — stolen `provider_token` rotates payout address
  and collects backlog.** v0.1.1 §3.3 adds a 24h cooling-off
  window: a freshly-registered address is `pending_until_utc`,
  during which queued `ledger_payout_ready` rows for that
  provider continue to use the previous address (or remain
  `ready` if no previous). The portal MUST surface the pending
  state so a legitimate provider notices an unexpected
  rotation within 24h.
- **C4 (SEC) — `/admin/payout/abandon-attempt` cancel
  self-transfer bypassed §5 day cap + had no tip ceiling.**
  v0.1.1 §4.6: tip multiplier capped at
  `payout.cancel_max_tip_multiplier` (default 5×); endpoint
  rate-limited to `payout.abandon_rate_per_hour` (default 3);
  cancel self-transfer gas spend MUST be accounted against
  `payout_runner_state` and surfaced in
  `/admin/payout/balance`; per-request `confirm: true` +
  `Idempotency-Key` required.
- **C5 (SEC) — single-RPC lying produces fake `consumed`
  rows.** v0.1.1 §4.4 + §9.2: TWO independent RPCs are now
  REQUIRED at v0.1; receipt confirmation MUST be cross-checked
  across both before §4.3 step 7 fires. Disagreement halts the
  runner and pages the operator. §7.4 reconciliation extended
  with a periodic on-chain `balanceOf(hot_wallet)` cross-check
  against in-DB cumulative outflow.

MAJOR closures (consolidated, by area):

- **§4.5 `payout_attempts` PRIMARY KEY** changed from
  `(payout_id)` to `(payout_id, attempt_seq)` to make the
  abandon-and-retry-with-fresh-nonce flow representable. A
  payout_id can now have multiple attempts, only one of which
  may be confirmed-and-non-abandoned (enforced by partial
  UNIQUE index).
- **§4.5 partial indexes** corrected: a second partial index
  on `(confirmed_at_utc) WHERE confirmed_at_utc IS NOT NULL
  AND abandoned_at_utc IS NULL` was missing — without it the
  §5.3 day-cap query falls back to a full scan of
  `payout_attempts`.
- **§7.1 log-event field names** scrubbed of residual
  `usd_cents` (the round-1 fix only renamed config keys, not
  the log-emission field names — same 10,000× unit-error
  regression class).
- **§4.5 FK + PRAGMA foreign_keys** spelled out: `ON DELETE
  RESTRICT`; `PRAGMA foreign_keys=ON` MUST be asserted on
  every connection touching the payout tables.
- **§4.7 `/admin/payout/void`** removed entirely as a status-
  mutating endpoint; replaced with `/admin/payout/record-orphan`
  (record-only). Eliminates the double-pay class flagged by
  SEC-M2 because there is no re-attempt path post-consume.
- **§3.3 `:8444` operator+provider mux risk** addressed: IMPL
  MUST declare every registered handler in a
  `map[path]authRealm` enforced at startup; routes without a
  declared realm fail-closed-reject.
- **§3.2 `expected_checksummed` echo removed** from the 400
  body — was a phishing vector. Response now returns only
  `{"error":"checksum_mismatch"}`.
- **§4.1 package layout**: `wallet.go` renamed to `signer.go`
  to make explicit the seam a v0.2 KMS swap will satisfy.
  `addresses.go` added (was implicit) so the
  `provider_payout_addresses` CRUD has a named home in
  `payout/`; `billing/` reads only via a thin accessor exposed
  by `payout/`.
- **§7.4 reconciliation** extended to surface
  `WHERE status='consumed' AND payout_currency IS NULL` as a
  separate failure class; unit test required.
- **All "round-1 audit X" parentheticals stripped from
  normative §-bodies** per ARCH-A4; provenance lives in this
  change log only.

MEDIUM closures (consolidated):

- §3.4 audit log MUST record the canonicalised checksummed
  form, not the submitted form.
- §3.5 + §3.3 provider_id existence validation against
  `provider_tokens` at registration time, emitting
  `provider_payout_address_rejected_unknown_provider` on
  miss.
- §4.3 step 5 explicitly persists `raw_signed_tx` AND
  `tx_hash` together pre-broadcast.
- §5.3 day-cap SQL gets an upper bound on `broadcast_at_utc`
  (`<= :now`) to defeat clock-skew under-counting and starts
  counting at `broadcast_at_utc` (not just `confirmed_at_utc`)
  so a broadcast burst cannot bypass the cap during
  confirmation lag.
- §6.3 hot-wallet process hardening:
  `setrlimit(RLIMIT_CORE, 0)`, `prctl(PR_SET_DUMPABLE, 0)` on
  Linux, mlock return-code check + fail-loud, dedicated
  no-shell uid; KEK env-var path includes process-listing
  exposure note.
- §7.1 missing log events added: `payout_run_now_invoked`,
  `payout_balance_queried`,
  `provider_payout_address_change_rejected`,
  `payout_chain_balance_drift`.
- §7.3 rate-limit posture pinned: identical to
  `/providers/{id}/earnings` per existing
  `phase4-coordinator/internal/billing/endpoints.go:453-465`
  machinery (MUST be reused, not reimplemented). Sibling-vs-
  fold rationale noted in §7.3 (different lifecycle: payouts
  append-only → cacheable hours; earnings current-window-
  mutable).
- §9 prerequisites grew from 5 to 8: added BetterStack
  alert-filter extension, nginx routing for `:8444` provider
  endpoints, encrypted-wallet-file + KEK backup policy.

QUESTION closures:

- §1 now explicitly preserves the SPEC-015 → SPEC-005 →
  SPEC-016 audit chain (`request_id → settlement_id →
  payout_id → tx_hash`).
- §8 `/admin/payout/allow` request body now includes
  `reason` (was missing; §7.1 log schema required it).
- §9 explicitly addresses SPEC-002 provisional-token
  sufficiency for §3.3 payout-address registration.

**v0.1 (2026-06-24, draft — round-1 internal-critic fix pass
absorbed, never pushed standalone):**

Initial draft. Defined the contract by which the existing
`ledger_payout_ready` rows produced by
`phase4-coordinator/internal/billing/settlement.go` (SPEC-005
§11.x) are turned into on-chain USDC transfers on Base
mainnet to operator-owned provider payout addresses, then
claimed via the existing `ClaimPayoutReady` primitive at
`phase4-coordinator/internal/billing/payout.go:10`.

**Rail locked: USDC on Base (chain id 8453).** Rationale lives
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

Scope explicitly EXCLUDED at v0.1 (see §2): non-Base rails
(ACH, Stripe Connect, USDC-Solana, etc.), custodial balances,
provider-side KYC, buyer refunds, multi-currency payout, and a
`PayoutAdapter` multi-rail abstraction. Each is a future vX.Y
if it ever ships.

Accounting schema is already complete — `payout_currency`
and `payout_external_id` columns on `ledger_payout_ready`
(`phase4-coordinator/internal/billing/store.go:111-112`) were
added in anticipation of exactly this work. SPEC-016's IMPL
MUST NOT modify the `ledger_payout_ready` DDL nor the existing
`trg_lpr_terminal_status_guard` trigger at
`store.go:121-126`.

`ClaimPayoutReady` is the only claim primitive — IMPL MUST
call the existing function at
`phase4-coordinator/internal/billing/payout.go:10`, NOT define
a replacement.

Hot-wallet design at v0.1.1 is local-file + operator-supplied
KEK at process start. KMS / HSM is a v0.2 thought experiment,
captured in §6.5 as a forward pointer; the `Signer` interface
in §4.1 is the seam.

Idempotency token at v0.1 is the chain-level `nonce`, NOT the
tx hash. The `UNIQUE(from_address, nonce)` constraint on
`payout_attempts` plus the chain's own nonce-uniqueness rule
guarantees at-most-one confirmed on-chain transfer per
`(payout_id, attempt_seq)`. On retry, IMPL MUST rebroadcast
the raw signed tx bit-for-bit (persisted in
`payout_attempts.raw_signed_tx`); re-signing is FORBIDDEN
because EIP-1559 envelopes re-pull a fresh gas-fee oracle
reading and produce different signed bytes (different tx
hash) at the same nonce.

Two RPCs are REQUIRED at v0.1 for receipt cross-confirmation
(round-2 SEC C5 fix); the originating prompt's "v0.1 MAY
assume single RPC" framing is superseded.

No IMPL bundled. Per [[feedback-bundle-spec-impl-one-pr]]
EXCEPTION rule, this is a net-new SPEC with NO downstream
implementer yet; IMPL will be written in a fresh session
against `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` (to be
authored after this v0.1.x merges).

Deferred follow-ups filed as Issue stubs, not inlined: (a)
SPEC-005 vX.Y+1 candidate: optional snapshot of the
credit→USD unit invariant in `ledger_config_snapshots` (today
the invariant is documented at SPEC-005 §5.1 only; if it ever
changes, payout rows MUST reference the snapshot active at
the row's window); (b) SPEC-014 v0.9 candidate: payout-address
registration + payout history screens (§3, §7).

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

**Receipt → payout audit chain preserved unchanged.** SPEC-015
v0.3.3 receipts bind to a `request_id` recorded in
`request_log`; SPEC-005 sets
`ledger_request_credits.settlement_id → ledger_payout_ready.id`;
SPEC-016 adds `payout_attempts.payout_id → ledger_payout_ready.id`
and records `payout_attempts.tx_hash`. The full chain
`request_id → settlement_id → payout_id → tx_hash` is the
operator's reconstruction path for "which signed receipt funded
which on-chain transfer". SPEC-016 MUST NOT modify any upstream
identifier.

## 2 Out of scope (v0.1)

1. **Custodial balances.** The operator MUST NOT hold per-
   provider balances. The hot wallet only debits; it never
   credits a per-provider account.
2. **Non-Base rails.** ACH, Stripe Connect, USDC-Solana,
   Polygon, Ethereum mainnet, USD-on-card, wire, gift card,
   etc. Future SPEC vX.Y or SPEC-NNN if ever shipped.
3. **Provider-side KYC.** Each provider supplies a Base
   address; the on-chain transfer IS the receipt. Tax
   reporting is the operator's separate obligation; SPEC-016
   does not mediate it.
4. **Buyer refunds / chargebacks.** SPEC-005's
   `idempotency_key` infrastructure on `ledger_payout_ready`
   plus the `voided` terminal status cover credit-side
   reversals. SPEC-016 only moves funds OUT, never back. The
   closest analogue (reorg revert) is handled by §4.7 as a
   compensation flow at the SPEC-005 layer, NOT by reversing
   the SPEC-016 on-chain transfer.
5. **Multi-currency payouts.** USDC-on-Base only at v0.1. The
   `payout_currency` column accommodates future expansion;
   v0.1 IMPL MUST always write the canonical string
   `"USDC-BASE"` (uppercase, hyphen-separated, no whitespace).
6. **`PayoutAdapter` multi-rail abstraction.** Single-rail
   concrete implementation is shorter, easier to audit, easier
   to refactor than a premature polymorphic interface. A
   future SPEC-016 vX.Y that adds a second rail will carry the
   refactor.
7. **Auto-refill of the hot wallet.** v0.1 has no upstream
   funding loop. The operator funds manually from operator
   treasury.
8. **Per-payout fee deduction from provider funds.** Gas is
   paid from the operator hot wallet (§5); the provider
   always receives the full `provider_credits → USDC` amount.

## 3 Provider payout-address registration (FR-P1)

### 3.1 Storage

There is no `providers` table on the coordinator today —
provider identity lives in `provider_tokens`
(`phase4-coordinator/internal/auth/tokens.go:247`) and the
in-memory `pool.Registry`. SPEC-016 IMPL MUST create:

```sql
CREATE TABLE IF NOT EXISTS provider_payout_addresses (
    provider_id      TEXT NOT NULL,
    chain            TEXT NOT NULL CHECK(chain = 'base-mainnet'),
    address          TEXT NOT NULL,
    payout_allowed   INTEGER NOT NULL DEFAULT 1 CHECK(payout_allowed IN (0,1)),
    pending_until_utc TEXT NULL,
    rotated_from     TEXT NULL,
    registered_at_utc TEXT NOT NULL,
    UNIQUE(provider_id, chain)
);
CREATE INDEX IF NOT EXISTS idx_ppa_provider ON provider_payout_addresses(provider_id);
```

The table MUST live in the same SQLite database as
`ledger_payout_ready` so the §7.4 reconciliation query can
join without cross-DB plumbing. Every connection touching this
table or `payout_attempts` MUST assert `PRAGMA
foreign_keys=ON` and `PRAGMA journal_mode=WAL` and `PRAGMA
synchronous=FULL` at open, failing fast otherwise (matches
SPEC-005 §10.1).

`payout_allowed` is the §8 compliance gate.

`pending_until_utc` is the §3.3 cooling-off field: a freshly-
registered or rotated address is NOT eligible for payout
selection (§4.3 step 1) until `now() >= pending_until_utc`.
Default cooling-off period is 24 hours; configurable via
`payout.address_cooling_off_period` (minimum 1 hour at
config-parse).

`chain` is locked to `'base-mainnet'` at v0.1. The CHECK
constraint is the canary that catches an accidentally-
broadened IMPL.

`registered_at_utc` is the timestamp of the current row's
address (rewritten on rotation). `rotated_from` preserves the
predecessor address for the MOST RECENT rotation only; deeper
history lives in the §3.4 structured log stream.

### 3.2 Address validation

The IMPL MUST validate, before INSERT or UPDATE:

1. Address is exactly 42 ASCII chars, starts with `0x`, and
   the remaining 40 chars are hex (`[0-9a-fA-F]`).
2. EIP-55 enforcement follows the standard exactly: an
   all-lowercase or all-uppercase 40-hex address is accepted
   as checksum-skipped (per EIP-55 backward-compat rule), and
   IMPL stores the canonicalised mixed-case checksummed form.
   A mixed-case address whose checksum DOES NOT match the
   canonical EIP-55 checksum is REJECTED.
3. `provider_id` MUST already exist in `provider_tokens`
   (`phase4-coordinator/internal/auth/tokens.go:247`).
   Rejection on miss emits
   `provider_payout_address_rejected_unknown_provider`.
4. Address MUST NOT be in the deny-list. The deny-list MUST
   include at minimum: the zero address
   `0x0000000000000000000000000000000000000000`, the USDC
   contract address itself
   `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, known
   burn addresses (`0x000…dead`), and the configured hot-
   wallet `from_address` (self-payment denial). Operator MAY
   add more.

When step 2 rejects a checksum mismatch, the 400 response
body MUST be exactly:

```
HTTP/1.1 400 Bad Request
{ "error": "checksum_mismatch" }
```

The canonical checksummed form is NOT echoed to the caller —
echoing it would let an attacker who tricks a provider into
posting a deliberately-broken attacker-controlled address see
the portal "helpfully" return an EIP-55-cased attacker
address. The canonical form is logged server-side per §3.4.

### 3.3 Registration / rotation endpoint

The handler and the `provider_payout_addresses` CRUD live in
`phase4-coordinator/internal/payout/addresses.go`. `billing/`
reads the table via a thin read-only accessor exposed by
`payout/`. The endpoint mounts on the `:8444` ws-mux listener
(the same listener that hosts `/providers/{id}/earnings` per
`phase4-coordinator/internal/billing/endpoints.go:68` — auth
realm is per-path, NOT per-listener).

IMPL MUST declare every registered handler in a single
`map[path]authRealm` table verified at coordinator startup;
any registered route NOT in the table fails closed (rejects
all requests). An IMPL audit MUST include a fuzzer asserting
no handler is registered outside the table. This defends
against a future refactor accidentally adding an
unauthenticated route on `:8444` that overlaps the operator-
key admin surface.

```
POST /providers/{provider_id}/payout-address
Authorization: Bearer <provider_token>   ; per SPEC-002 §7.3
Content-Type: application/json

{ "chain": "base-mainnet", "address": "0xAbC...checksummed" }

Response:
  201 Created      — first-ever registration; pending_until_utc
                     = now + 24h (or configured period).
  200 OK           — rotation; pending_until_utc rewritten.
  400 Bad Request  — failed §3.2 validation (body: error code only).
  401 Unauthorized — invalid / missing provider_token.
  403 Forbidden    — provider_token does not own provider_id.
  409 Conflict     — payout_allowed=0 (operator gate).
  429 Too Many     — provider-scoped rate-limit (default 6/hr).
```

Authentication is via the per-Mac `provider_token` (same
token SPEC-014 portal uses for `/providers/{id}/earnings`);
the operator key is NOT accepted on this surface (rotations
are provider-initiated only). Every response, including
4xx/5xx, MUST emit a structured log line per §7.1 — a
failed-registration burst is a stolen-token signal.

The 24h `pending_until_utc` cooling-off is the v0.1.1
defense against stolen-token + immediate-rotation + backlog-
drain. During the cooling-off, queued `ledger_payout_ready`
rows for this provider continue to use the PREVIOUS address
(or remain `ready` indefinitely if no previous). The portal
MUST surface "address change pending until X" as a banner so
a legitimate provider sees an unexpected rotation in time to
revoke the token. Operator MAY also receive a webhook /
email notification — v0.1 does NOT specify the notification
transport.

### 3.4 Rotation audit

Every successful INSERT or UPDATE MUST emit:

```
event=provider_payout_address_changed
provider_id=<id>
chain=base-mainnet
old_address=<canonical 0x...|none>
new_address=<canonical 0x...>
pending_until_utc=<RFC3339Nano>
actor=provider_token
ts_utc=<RFC3339Nano>
```

`new_address` and `old_address` MUST be the canonicalised
EIP-55 checksummed forms (not the submitted form). Failed
registrations emit `provider_payout_address_change_rejected`
with `reason`, `provider_id`, `src_ip`, `submitted` fields
so an enumeration / probing burst is detectable.

### 3.5 Gate on settlement

A provider with no row in `provider_payout_addresses`, OR
with `payout_allowed=0`, OR with `pending_until_utc >
now()` AND no `rotated_from` predecessor that the runner
could fall back to (first-ever registration during
cooling-off), MUST NOT have any payout attempt initiated on
their behalf. Their `ledger_payout_ready` rows remain in
`status='ready'`.

If a rotation is `pending_until_utc > now()` AND
`rotated_from` is set, the runner pays to `rotated_from`
during the cooling-off — the PREVIOUS address remains
canonical until the cooling-off expires.

The portal MUST surface this state per-provider (SPEC-014
v0.9 candidate) and the operator MUST be able to count it
system-wide via §7.4 reconciliation.

## 4 Payout execution loop (FR-P2)

### 4.1 Package layout

IMPL MUST add `phase4-coordinator/internal/payout/`
containing:

- `runner.go` — periodic loop.
- `evm.go` — Base RPC client + ABI encoding for USDC
  `transfer(address,uint256)`.
- `signer.go` — concrete local-file signer at v0.1.1; the
  package-internal `Signer` interface this satisfies is the
  seam for the v0.2 KMS substitution (§6.5).
- `attempts.go` — `payout_attempts` table CRUD (§4.5).
- `addresses.go` — `provider_payout_addresses` CRUD + the
  §3.3 handler (§3 entirety).

The runner starts from `cmd/coordinator/main.go` only when
config explicitly enables it (`payout.enabled: true`).
Default config ships `payout.enabled: false`.

### 4.2 Cadence

- Default cadence: every 6 hours.
- Configurable via `payout.run_interval` (Go duration, min 5
  minutes at config-parse).
- Operator MAY trigger a single immediate run via
  `POST /admin/payout/run-now` on the `:8444` listener
  (operator-key authenticated). Endpoint MUST be idempotent
  within an in-flight run (return 409 if one is active).
  Every invocation emits `payout_run_now_invoked` per §7.1.

### 4.3 Per-run algorithm

For each scheduled run, the loop MUST execute IN ORDER, exiting
any step on error and logging structurally:

1. **Select.**

   ```sql
   SELECT lpr.id, lpr.provider_id, lpr.gross_credits,
          lpr.provider_credits, lpr.window_start_utc,
          lpr.window_end_utc,
          COALESCE(
            CASE WHEN ppa.pending_until_utc IS NOT NULL
                  AND ppa.pending_until_utc > :now
                 THEN ppa.rotated_from
                 ELSE ppa.address END,
            ppa.address) AS effective_address
     FROM ledger_payout_ready lpr
     INNER JOIN provider_payout_addresses ppa
       ON ppa.provider_id = lpr.provider_id
      AND ppa.chain = 'base-mainnet'
      AND ppa.payout_allowed = 1
    WHERE lpr.status = 'ready'
      AND (ppa.pending_until_utc IS NULL
           OR ppa.pending_until_utc <= :now
           OR ppa.rotated_from IS NOT NULL)
    ORDER BY lpr.id ASC
    LIMIT :max_rows_per_run;
   ```

   `gross_credits` MUST be in the projection because step 7
   passes it to `ClaimPayoutReady`. `max_rows_per_run`
   default 50. The cooling-off + rotated_from fallback (§3.5)
   is encoded directly in the JOIN + WHERE.

2. **Per-row amount.** USDC amount in base units (6 decimals)
   equals `provider_credits` exactly. SPEC-005 §5.1 locks
   1 credit = 1 USD micro-dollar = 10⁻⁶ USD, and USDC on Base
   uses 6 decimals; the conversion is a unit identity, not a
   rate lookup. IMPL MUST hardcode this identity and MUST
   reject (log + skip) any configuration that introduces a
   multiplier.
3. **Cap check.** Apply §5 caps. If the row's amount exceeds
   per-payout cap, OR cumulative paid + broadcast amount this
   24h window would exceed per-day cap, skip the row and
   emit `payout_capped`. The row remains `ready` for a
   future run.
4. **Attempt record.** Load any non-abandoned
   `payout_attempts` row for the payout_id. If
   confirmed-and-non-abandoned, jump to step 7. If pending
   (broadcast but not confirmed), jump to step 6 to poll. If
   none exists, generate a fresh nonce per §4.6 and a new
   `attempt_seq` (next integer for this payout_id).
5. **Build + sign + broadcast.** Build USDC `transfer(to,
   amount)` calldata; build EIP-1559 tx with hot-wallet
   sender, the computed nonce, chain id 8453, USDC contract
   as `to`; sign via the `Signer` interface (§6.3). Persist
   `raw_signed_tx` AND its computed `tx_hash` AND
   `broadcast_at_utc` on the `payout_attempts` row BEFORE
   invoking `eth_sendRawTransaction` on either RPC. A
   process crash between persistence and broadcast leaves
   the row eligible for retry (§4.5) without nonce loss.
6. **Confirm via TWO independent RPCs.** Poll both configured
   RPCs (§9.2) until both return a receipt at depth ≥
   `payout.confirmation_blocks` (default 5; minimum 2;
   maximum 50). The TWO receipts MUST agree on `tx_hash`,
   `block_number`, `status` (success), and `to`. Any
   disagreement HALTS the runner, emits
   `payout_rpc_disagreement` per §7.1, and pages the
   operator. Single-RPC trust is REJECTED at v0.1 — the
   originating prompt's "MAY assume single RPC" is
   superseded.
7. **Claim.** Call
   `ClaimPayoutReady(ctx, payoutID, expectedGrossCredits,
   payoutExternalID, "USDC-BASE")` at
   `phase4-coordinator/internal/billing/payout.go:10`.
   Signature is
   `(ctx context.Context, payoutID int64, expectedGrossCredits int64, payoutExternalID, payoutCurrency string) (bool, error)`.
   `expectedGrossCredits` MUST be `lpr.gross_credits` from
   step 1 (NOT `provider_credits`). `payoutExternalID` MUST
   be the agreed tx hash from step 6. `payoutCurrency` MUST
   be the literal string `"USDC-BASE"` (never empty, never
   NULL). IMPL MUST add a unit test asserting the literal is
   passed; the §7.4 reconciliation surfaces a NULL
   `payout_currency` on a `consumed` row as a separate
   failure class to catch any regression.
8. **Log.** Emit `payout_paid` per §7.1. On failure in
   steps 5-7, emit `payout_failed` with `stage` and
   `error_class`.

### 4.4 RPC failure tolerance

The runner MUST tolerate transient RPC errors at steps 5/6:

- Step 5 broadcast failure on either RPC → retry up to N
  times (default 3) with exponential backoff. If at least
  ONE RPC confirms acceptance into its mempool, the
  broadcast is treated as successful for the purposes of
  step 6 polling. If both RPCs reject (e.g. nonce too low,
  insufficient funds, malformed envelope), leave the row
  pending; the next run cycle retries via step 4.
- Step 6 receipt-poll: if ONE RPC returns confirmed and the
  OTHER returns "not found" past a tolerance window
  (default 2 minutes), emit `payout_rpc_disagreement` and
  HALT — silent disagreement is the lying-RPC threat model.

The runner MUST NOT advance to step 7 without TWO-RPC
agreement on a confirmed receipt.

### 4.5 Per-row attempt table (deterministic retry)

```sql
CREATE TABLE IF NOT EXISTS payout_attempts (
    payout_id        INTEGER NOT NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    attempt_seq      INTEGER NOT NULL CHECK(attempt_seq >= 1),
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
    is_cancel_self_transfer INTEGER NOT NULL DEFAULT 0 CHECK(is_cancel_self_transfer IN (0,1)),
    last_error       TEXT NULL,
    abandoned_at_utc TEXT NULL,
    abandoned_reason TEXT NULL,
    updated_at_utc   TEXT NOT NULL,
    PRIMARY KEY(payout_id, attempt_seq),
    UNIQUE(from_address, nonce)
);
CREATE INDEX IF NOT EXISTS idx_pa_unconfirmed
    ON payout_attempts(payout_id)
 WHERE confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_confirmed_recent
    ON payout_attempts(confirmed_at_utc)
 WHERE confirmed_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_broadcast_recent
    ON payout_attempts(broadcast_at_utc)
 WHERE broadcast_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_one_active_per_payout
    ON payout_attempts(payout_id)
 WHERE confirmed_at_utc IS NOT NULL AND abandoned_at_utc IS NULL AND is_cancel_self_transfer = 0;
```

The `(payout_id, attempt_seq)` PK lets a payout_id have
multiple attempt rows (the original payout attempt, plus any
cancel self-transfers, plus any post-abandon fresh attempts).
The `idx_pa_one_active_per_payout` partial UNIQUE index
guarantees at most ONE confirmed non-cancel non-abandoned row
per payout_id (the double-spend guarantee at the application
layer; the chain nonce is the on-chain guarantee).

`is_cancel_self_transfer = 1` rows are emitted by
`/admin/payout/abandon-attempt` (§4.6) — they consume gas and
count toward the §5 day cap but are NOT a payout to a
provider.

The `chain` CHECK matches the §3.1 canary; a multi-rail
expansion must amend BOTH constraints.

The signed tx envelope itself is persisted in `raw_signed_tx`
BEFORE broadcast in step 5; on retry IMPL MUST rebroadcast
the exact bytes. Re-signing is FORBIDDEN.

### 4.6 Nonce strategy + abandon

- IMPL maintains a `wallet_nonce_cursor` (single row, single
  column) per `from_address`. At runner startup it MUST sync
  the cursor to `max(getTransactionCount(latest),
  getTransactionCount(pending))` from BOTH RPCs (take the
  max), then take `max(cursor_in_db, rpc_value)`.
- On fresh-attempt allocation, claim the next nonce
  atomically. Persist `(payout_id, attempt_seq, nonce)` in
  `payout_attempts` BEFORE signing.
- On retry of an existing non-abandoned attempt, REUSE the
  persisted nonce + `raw_signed_tx` (re-broadcast verbatim).
- Nonce gaps (an abandoned `payout_attempts` row that was
  never confirmed) MUST be filled with an explicit 0-value
  self-transfer at the same nonce before subsequent payouts
  can use higher nonces. v0.1.1 ships the operator-driven
  recovery path:

  ```
  POST /admin/payout/abandon-attempt
  Authorization: Bearer <operator_key>
  Content-Type: application/json
  Idempotency-Key: <opaque>

  { "payout_id": 123,
    "attempt_seq": 1,
    "broadcast_cancel_self_transfer": true,
    "confirm": true,
    "tip_multiplier": 2.0,
    "reason": "free-text required (logged)" }

  Response:
    200 OK   — abandoned_at_utc/abandoned_reason set; if
               broadcast_cancel_self_transfer=true, a new
               payout_attempts row with attempt_seq+1 and
               is_cancel_self_transfer=1 is inserted, signed,
               and broadcast at the original nonce with the
               capped tip. Counts toward §5 day cap.
    400      — missing confirm/Idempotency-Key/reason.
    409 Conflict — attempt already confirmed; nothing to abandon.
    422      — per-cancel gas spend would exceed
               payout.cancel_max_gas_native_wei ceiling.
    429      — exceeded payout.abandon_rate_per_hour
               (default 3).
  ```

  Configurables:

  - `payout.cancel_max_tip_multiplier` — default 5×; HARD
    cap on `tip_multiplier` field; requests above the cap
    are silently floored AND logged with `cap_applied`.
  - `payout.abandon_rate_per_hour` — default 3; per-
    operator-token rate limit on the endpoint.
  - `payout.cancel_max_gas_native_wei` — default `1e16`
    (0.01 ETH); per-cancel gas spend ceiling. If exceeded,
    the request is REJECTED with 422.

  Until this endpoint is called for a gap-causing nonce, the
  runner halts at the next cadence cycle and emits
  `payout_nonce_gap`. No automatic gap-filling.

### 4.7 Reorg handling (record-only, NO consumed-row revert)

Base reorgs past `payout.confirmation_blocks` are vanishingly
rare in practice but possible. The
`trg_lpr_terminal_status_guard` trigger
(`phase4-coordinator/internal/billing/store.go:121-126`) is
intentional and v0.1.1 does NOT bypass it.

If the runner observes that a previously-confirmed tx is no
longer present in the canonical chain on either RPC (receipt
returns "not found" after a prior confirmation), it MUST:

1. Emit `payout_reorg_revert` per §7.1 (severity: page
   operator).
2. NOT attempt automatic revert. The trigger forbids it; the
   runner has no bypass.
3. NOT attempt a new transfer for the same `payout_id`. The
   `payout_external_id` column already holds the orphaned tx
   hash; the row remains `consumed`.
4. Insert a row into `payout_reorg_orphans` (new table,
   below) capturing the orphan tx hash + observed reorg
   block + RPC source.

```sql
CREATE TABLE IF NOT EXISTS payout_reorg_orphans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payout_id        INTEGER NOT NULL REFERENCES ledger_payout_ready(id),
    attempt_seq      INTEGER NOT NULL,
    orphan_tx_hash   TEXT NOT NULL,
    last_seen_block  INTEGER NOT NULL,
    observed_at_utc  TEXT NOT NULL,
    rpc_source       TEXT NOT NULL,
    operator_resolution TEXT NULL,
    resolved_at_utc  TEXT NULL,
    FOREIGN KEY(payout_id, attempt_seq) REFERENCES payout_attempts(payout_id, attempt_seq)
);
```

Operator-driven resolution is record-only via:

```
POST /admin/payout/record-orphan
Authorization: Bearer <operator_key>
Content-Type: application/json

{ "payout_id": 123,
  "attempt_seq": 1,
  "operator_resolution": "free-text — e.g. 'compensated via SPEC-005 fresh row id 4567' or 'no compensation; provider acknowledged'",
  "reason": "free-text" }

Response:
  200 OK   — resolution recorded.
  404      — no matching orphan row.
```

If compensation is warranted, the operator MUST create a
fresh `ledger_payout_ready` row via the SPEC-005 settlement-
admin path (out of scope for SPEC-016). That row enters the
normal `status='ready'` → §4.3 flow with a new
`payout_id`. The original orphan row stays `consumed`
forever — the in-DB row records what the runner attempted,
the orphan_tx_hash is forensic evidence, and compensation is
a separate ledger event with its own audit trail.

Because there is no re-attempt path post-consume, the double-
pay class is structurally eliminated — the runner cannot
broadcast a second transfer for the same `payout_id` because
the row never returns to `ready`.

### 4.8 Runner state

```sql
CREATE TABLE IF NOT EXISTS payout_runner_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    last_run_started_at_utc  TEXT NULL,
    last_run_finished_at_utc TEXT NULL,
    last_run_paid            INTEGER NOT NULL DEFAULT 0,
    last_run_capped          INTEGER NOT NULL DEFAULT 0,
    last_run_failed          INTEGER NOT NULL DEFAULT 0,
    last_run_skipped_no_addr INTEGER NOT NULL DEFAULT 0,
    last_run_cancel_gas_native_wei INTEGER NOT NULL DEFAULT 0,
    last_run_error_text      TEXT NULL,
    updated_at_utc           TEXT NOT NULL
);
```

The `last_run_cancel_gas_native_wei` field tracks
`/admin/payout/abandon-attempt` gas consumption and is
surfaced in `/admin/payout/balance` (§6.2) so the operator
sees DoS-via-gas-burn signal.

## 5 Fee policy (FR-P3)

### 5.1 Gas on the operator

Gas fees on Base are paid from the operator hot wallet, NOT
deducted from `provider_credits`. The provider always receives
exactly `provider_credits` USDC base units. At Base's sub-cent
transfer cost the operator's per-payout gas overhead is
negligible; v0.2 MAY revisit if Base base-fees rise structurally.

### 5.2 Per-payout cap

`payout.per_payout_cap_usdc_base_units` — default
`500_000_000` (i.e. $500 = 500 USDC × 10⁶ base units). All
caps in SPEC-016 are USDC base units (== USD micro-dollars
== credits, by SPEC-005 §5.1 unit identity).

A row whose `provider_credits` exceeds this cap is SKIPPED
with `payout_capped reason=per_payout`. The row remains
`status='ready'`.

The operator MAY split a capped row manually via the SPEC-005
settlement-admin path (out of scope) or MAY raise the cap via
config + restart. v0.1 does NOT auto-split.

### 5.3 Per-day cap

`payout.per_day_cap_usdc_base_units` — default
`5_000_000_000` (i.e. $5,000). Computed against a rolling
24h window using `broadcast_at_utc` (NOT `confirmed_at_utc`)
so a broadcast burst cannot bypass the cap during the
confirmation-lag window:

```sql
SELECT COALESCE(SUM(amount_base_units), 0)
  FROM payout_attempts
 WHERE broadcast_at_utc IS NOT NULL
   AND abandoned_at_utc IS NULL
   AND broadcast_at_utc >= :now_minus_24h
   AND broadcast_at_utc <= :now;
```

The query includes `is_cancel_self_transfer = 1` rows so
operator-triggered cancel transfers count against the same
budget. Both sides are in USDC base units; no unit
conversion. The upper bound `<= :now` defeats clock-skew
under-counting.

When the next row's amount would push the 24h window past
the cap, the runner SKIPS that row (and subsequent rows)
and emits `payout_daily_cap_tripped`. The runner resumes on
the next cadence cycle whose 24h-window total is below the
cap.

### 5.4 Minimum payout

Inherited from SPEC-005 `MinPayoutCredits`; SPEC-016 MUST
NOT add a second check.

## 6 Hot-wallet operations (FR-P4)

### 6.1 Funding

The operator funds the hot wallet manually. v0.1 has NO
auto-refill path.

### 6.2 Balance monitoring

The runner MUST expose a `GET /admin/payout/balance` JSON
endpoint on the `:8444` listener (operator-key
authenticated):

```json
{
  "from_address": "0x...",
  "usdc_base_units": 12345600,
  "native_wei": 1234567890000000,
  "last_run_cancel_gas_native_wei": 0,
  "as_of_block": 1234567,
  "as_of_utc": "2026-..."
}
```

Every invocation emits `payout_balance_queried` per §7.1
(info disclosure trail — operator key holders' read pattern
is auditable).

The runner MUST emit a structured log line every cadence
cycle. When `usdc_base_units < payout.low_balance_threshold`
(default `2 * payout.per_day_cap_usdc_base_units` — a fixed
multiple, NOT a function of `sum(ready rows)` which can grow
unboundedly during a halt), emit `payout_low_balance` at
warning level. Native ETH balance has a separate threshold
`payout.low_native_threshold` (default `1e16` wei == 0.01
ETH) — when tripped, emit `payout_low_native_balance` (gas
exhaustion would silently halt the runner).

When `usdc_base_units` is insufficient for the next selected
row, the runner SKIPS that row + subsequent rows, emits
`payout_insufficient_funds`, and halts until the next
cadence cycle.

### 6.3 Key custody

The wallet signing key MUST be persisted on-disk in
encrypted form (AES-256-GCM recommended). The AES key-
encryption-key (KEK) MUST be supplied by the operator at
process start via either:

- environment variable `MACPROVIDER_PAYOUT_WALLET_KEK`
  (loaded ONLY into process memory; never echoed; never
  logged; only allowed when systemd `LoadCredential=` is
  not available), OR
- systemd `LoadCredential=` (PREFERRED — sourced from a
  systemd-creds-encrypted blob outside the process cwd).

Process hardening REQUIRED at startup:

- `setrlimit(RLIMIT_CORE, 0)` — disables core dumps so a
  crash cannot leak the in-memory key.
- On Linux: `prctl(PR_SET_DUMPABLE, 0)` — prevents
  ptrace-attached debuggers from reading process memory by
  the same uid.
- `mlock` (or `mlockall(MCL_CURRENT|MCL_FUTURE)`) on the
  decrypted key bytes; the return code MUST be checked and
  the process MUST fail-loud on `EPERM` / `ENOMEM` —
  silent fall-back to unpinned memory is FORBIDDEN. IMPL
  MUST add a test asserting `/proc/self/status` shows
  `VmLck` ≥ keysize on Linux.
- The coordinator process MUST run as a dedicated uid with
  no login shell; the env-var path (`/proc/<pid>/environ`
  is readable by same-uid processes) is closed by
  same-uid-isolation.

The wallet signing key is decrypted in process memory on
startup and held for the runner's lifetime. The plaintext
MUST NEVER be persisted to disk by the coordinator. The KEK
plaintext MUST NEVER be persisted to disk either.

Signing happens via the package-internal `Signer` interface
defined in `payout/signer.go`. v0.1.1 ships ONE
implementation: the local-file signer described above. The
`Signer` interface is the seam for the v0.2 KMS swap (§6.5);
the §4.3 step 5 sequence is unchanged under v0.2 because the
signed envelope is still received synchronously from the
signer before persistence + broadcast.

The chain-level `nonce` is the idempotency token; the
signed envelope is persisted to `payout_attempts.raw_signed_tx`
BEFORE broadcast (§4.3 step 5) and re-broadcast bit-for-bit
on retry. RFC 6979 deterministic ECDSA is RECOMMENDED for
general ECDSA-nonce-reuse hygiene but is NOT load-bearing
for SPEC-016's idempotency guarantee.

### 6.4 Key rotation

Procedure (manual, operator-driven):

1. Halt the runner (`payout.enabled: false` + restart).
2. For each `payout_attempts` row with `confirmed_at_utc IS
   NULL AND abandoned_at_utc IS NULL`, the operator MUST
   either wait for confirmation or call
   `POST /admin/payout/abandon-attempt` (§4.6,
   `broadcast_cancel_self_transfer=true`) to push a
   higher-tip self-transfer at the stuck nonce. v0.1.1
   ships this admin endpoint inline.
3. Generate fresh wallet; transfer remaining hot-wallet
   balance to the fresh address (a single regular USDC
   transfer signed by the OLD wallet); rewrite the
   encrypted wallet file + config; rotate the KEK if also
   compromising the on-disk envelope.
4. Restart with `payout.enabled: true`. The runner re-syncs
   the nonce cursor from BOTH RPCs' `getTransactionCount`
   for the new address.

A future v0.2 MAY add in-process rotation.

### 6.5 KMS / HSM (forward pointer, not normative)

A v0.2 thought-experiment: replace the local encrypted file
with a KMS-backed `Signer` implementation (AWS KMS, GCP KMS,
Vault Transit). v0.1.1 is sufficient because (a) the operator
is a single party, (b) the hot wallet float is small, and (c)
the v0.1 audit surface is materially shorter without remote
signing. The `Signer` interface (§4.1, §6.3) is the seam; no
§4.3 rewrite is required for the swap.

## 7 Auditability & receipts (FR-P5)

### 7.1 Structured logs (operator's source of truth)

Every payout-runner action MUST emit a structured log line
via the existing zerolog setup. Required event names and
minimum field set (all amounts in USDC base units; ALL
operator-key endpoints log actor=operator_key):

| event | fields |
|---|---|
| `payout_run_started` | `run_id, ts_utc` |
| `payout_run_finished` | `run_id, ts_utc, paid, capped, failed, skipped_no_addr, skipped_funds, error_text` |
| `payout_run_now_invoked` | `run_id, actor=operator_key, ts_utc` |
| `payout_paid` | `run_id, payout_id, attempt_seq, provider_id, amount_usdc_base_units, tx_hash, block_number, nonce, ts_utc` |
| `payout_failed` | `run_id, payout_id, attempt_seq, provider_id, stage, error_class, error_text, ts_utc` |
| `payout_capped` | `run_id, payout_id, provider_id, reason, ts_utc` |
| `payout_low_balance` | `from_address, usdc_base_units, threshold_usdc_base_units, ts_utc` |
| `payout_low_native_balance` | `from_address, native_wei, threshold_wei, ts_utc` |
| `payout_insufficient_funds` | `run_id, payout_id, provider_id, required_usdc_base_units, available_usdc_base_units, ts_utc` |
| `payout_daily_cap_tripped` | `run_id, window_paid_usdc_base_units, cap_usdc_base_units, ts_utc` |
| `payout_reorg_revert` | `payout_id, attempt_seq, tx_hash, last_seen_block, rpc_source, ts_utc` |
| `payout_rpc_disagreement` | `payout_id, attempt_seq, rpc_a_state, rpc_b_state, ts_utc` |
| `payout_chain_balance_drift` | `from_address, in_db_outflow_usdc_base_units, on_chain_outflow_usdc_base_units, drift_usdc_base_units, ts_utc` |
| `payout_nonce_gap` | `from_address, expected_nonce, observed_pending_nonce, ts_utc` |
| `payout_attempt_abandoned` | `payout_id, attempt_seq, nonce, cancel_self_transfer_tx_hash, cap_applied, reason, actor=operator_key, ts_utc` |
| `payout_reorg_orphan_recorded` | `payout_id, attempt_seq, orphan_tx_hash, operator_resolution, reason, actor=operator_key, ts_utc` |
| `payout_balance_queried` | `from_address, actor=operator_key, ts_utc` |
| `payout_allowed_changed` | `provider_id, old_allowed, new_allowed, reason, actor=operator_key, ts_utc` |
| `provider_payout_address_changed` | per §3.4 |
| `provider_payout_address_change_rejected` | `reason, provider_id, src_ip, submitted, ts_utc` |
| `provider_payout_address_rejected_unknown_provider` | `provider_id, submitted, src_ip, ts_utc` |

Retention: these logs are the operator's source of truth.
IMPL MUST document a 7-year retention default; operator MAY
override per local jurisdiction. Retention is enforced by
the existing journalctl/BetterStack archive pipeline.

### 7.2 Portal surface

SPEC-014 v0.9 (separate follow-up; NOT in this PR) MUST add
a "Payouts" surface that renders, per the requesting
provider's `provider_token`:

- Current registered payout address (or "not set"), plus
  any `pending_until_utc` cooling-off banner.
- Last 50 payouts: `(window_end_utc, provider_credits → USD,
  tx_hash → basescan link, block_number, paid_at_utc)`.
- Pending payouts count + total USD of `ready` rows for
  that provider waiting on address registration or runner
  cycle.

v0.1.1 surfaces the data via:

- `GET /providers/{provider_id}/earnings` (extend response —
  filed as SPEC-005 vX.Y+1 follow-up).
- `GET /providers/{provider_id}/payouts` (NEW; §7.3).

### 7.3 Provider-facing payouts read endpoint

The endpoint and `/providers/{provider_id}/earnings` are
SIBLINGS rather than folded into a single endpoint because
they have different lifecycles: earnings is current-window-
mutable (live accrual), payouts is append-only (cacheable
hours). A future consolidation in a SPEC-005 vX.Y+1
extension MAY collapse them; v0.1 keeps the split to avoid
forcing a cache-invalidation strategy that does not yet
exist.

```
GET /providers/{provider_id}/payouts?limit=50
Authorization: Bearer <provider_token>

200 OK:
{
  "provider_id": "...",
  "registered_address": "0x..." | null,
  "address_pending_until_utc": "..." | null,
  "payout_allowed": true | false,
  "paid": [
    {
      "payout_id": 123,
      "attempt_seq": 1,
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

Rate-limit posture is IDENTICAL to
`/providers/{id}/earnings`: bound by
`endpoints.provider_payouts.rate_limit_per_minute` (default
60); the existing per-provider sliding-window limiter at
`phase4-coordinator/internal/billing/endpoints.go:453-465`
MUST be reused, NOT reimplemented.

### 7.4 Weekly reconciliation queries

The operator MUST be able to run a small set of SQL queries
that confirms in-DB ledger matches on-chain ledger over an
arbitrary window. IMPL MUST commit them as a checked-in file
at `phase4-coordinator/internal/payout/reconcile.sql`.

```sql
-- Per-provider sum of on-chain transfers vs in-DB credits.
-- Units: both sides in USDC base units. By SPEC-005 §5.1 the
-- credit unit identity is 1 credit == $0.000001 == 1 USDC
-- base unit. delta != 0 means either (a) the runner broadcast
-- an amount that doesn't match the row's provider_credits OR
-- (b) DB hand-edit.
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
  AND pa.is_cancel_self_transfer = 0
  AND pa.confirmed_at_utc >= :from_utc
  AND pa.confirmed_at_utc <  :to_utc
GROUP BY lpr.provider_id
HAVING delta != 0;

-- Catches the silent-invisible regression class: any
-- consumed row with NULL payout_currency is an IMPL bug
-- (ClaimPayoutReady was called without the canonical string).
SELECT id, provider_id, gross_credits, payout_external_id
  FROM ledger_payout_ready
 WHERE status = 'consumed'
   AND payout_currency IS NULL;
```

Any row returned by either query is a reconciliation
failure.

Additionally the runner MUST periodically (every
`payout.chain_recon_interval`, default 24h) query the USDC
contract's on-chain `balanceOf(hot_wallet)` from BOTH RPCs
and compare against the in-DB cumulative outflow
(initial-funding-record minus
`SUM(payout_attempts.amount_base_units WHERE confirmed AND
NOT abandoned)`). When drift exceeds
`payout.chain_recon_tolerance_usdc_base_units` (default
`1_000_000` == 1 USDC), emit `payout_chain_balance_drift`
per §7.1 and halt the runner.

The operator MAY ALSO cross-check via Etherscan/Basescan
export of hot-wallet transfers; that cross-check is
procedural and NOT specified.

## 8 Compliance posture (FR-P6)

SPEC-016 takes NO position on the operator's KYC / AML
obligations. The technical machinery is rail-agnostic to
compliance state — a `ledger_payout_ready` row may be in
`status='ready'` and the runner gates separately on
`provider_payout_addresses.payout_allowed = 1` (§3.1).

The operator MUST consult counsel before flipping the runner
on for any provider in a regulated jurisdiction. The operator
controls eligibility via:

```
POST /admin/payout/allow
Authorization: Bearer <operator_key>
Content-Type: application/json

{ "provider_id": "...", "allowed": true,
  "reason": "free-text required (logged)" }

Response:
  200 OK   — transition recorded; structured log emitted.
  400      — missing reason.
```

Toggling `payout_allowed=0` does NOT void existing
`ledger_payout_ready` rows; it only prevents the runner from
selecting them in §4.3 step 1. Restoration to `allowed=1`
resumes payout on the next cadence cycle.

`payout_allowed_changed` log line per §7.1.

## 9 Operator-action prerequisites before IMPL ships

IMPL MUST NOT begin until ALL EIGHT prerequisites are
discharged:

1. **Hot wallet provisioned + funded.** Fresh Base address (or
   designated single-purpose address), funded with USDC for
   initial smoke (suggested 100 USDC) and ~$5 native ETH for
   gas headroom. Encrypted wallet file generated; KEK loaded
   via systemd `LoadCredential=` (preferred) or env var.
   Address pinned in `payout.hot_wallet_address`.
2. **TWO RPC providers chosen + API keys provisioned.**
   v0.1.1 REQUIRES two independent RPCs for receipt
   cross-confirmation (§4.4). Different operators (e.g.
   Alchemy + QuickNode), ideally different ASNs. Both URLs +
   keys pinned in `payout.rpc_url_primary` and
   `payout.rpc_url_secondary`. v0.1's single-RPC framing is
   superseded.
3. **Cap decisions.** Operator sets
   `payout.per_payout_cap_usdc_base_units`,
   `payout.per_day_cap_usdc_base_units`,
   `payout.run_interval`,
   `payout.confirmation_blocks`,
   `payout.address_cooling_off_period`,
   `payout.cancel_max_tip_multiplier`,
   `payout.abandon_rate_per_hour`,
   `payout.chain_recon_interval`,
   `payout.chain_recon_tolerance_usdc_base_units`.
4. **Compliance posture decision.** Initial bulk
   `payout_allowed` set; policy that gates future
   provider eligibility documented.
5. **SPEC-014 v0.9 portal screens** for payout-address
   registration + payout history. v0.1 IMPL MAY ship before
   SPEC-014 v0.9 if operator uses `curl` for the initial
   provider set — this is a SOFT prerequisite (the others
   are hard).
6. **BetterStack alert filter extended** to match each
   SPEC-016 event name (`payout_low_balance`,
   `payout_low_native_balance`, `payout_insufficient_funds`,
   `payout_reorg_revert`, `payout_rpc_disagreement`,
   `payout_chain_balance_drift`, `payout_nonce_gap`,
   `payout_capped`, `payout_failed`,
   `provider_payout_address_change_rejected`). Operator MUST
   verify with a synthetic alert before flipping
   `payout.enabled: true`. (Per [[deve2-betterstack-live]],
   BetterStack monitor config lives in the BetterStack UI,
   not the repo.)
7. **Nginx routing on Pearl VPS** updated to proxy
   `/providers/{id}/payout-address`,
   `/providers/{id}/payouts`, and the new `/admin/payout/*`
   endpoints through `coordinator.streamvc.live → :8444`;
   portal CORS verified. The `coordinator.streamvc.live`
   config is the touchpoint, NOT `portal.streamvc.live`.
8. **Backup + restore** for the encrypted wallet file AND
   the KEK on separate media (NOT the same VPS). Loss of
   EITHER = total loss of access to hot-wallet funds. The
   operator's existing secrets-management process applies;
   v0.1 only requires that the operator confirm a
   restore-from-backup dry run has been validated before
   IMPL enables the runner.

SPEC-002 sufficiency note for §3.3: SPEC-002 FR-P12 tokens
are operator-issued or self-minted (FR-C9.4 provisional). A
self-minted provisional token MAY register a payout address
under v0.1.1 — but the operator MAY (compliance posture
decision in item 4) flip `payout_allowed=0` for all
provisional-tier providers until promoted to pinned, by
joining `provider_payout_addresses` to the SPEC-002 token-tier
data at operator-discretion. The operator decision is
documented inline as part of item 4.

Without items 1, 2, 3, 4, 6, 7, 8 (item 5 is soft), IMPL is
blocked.

---

## Appendix A — IMPL prompt name

The next deliverable (NOT created in this PR) is
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`, authored in a
fresh session after this v0.1.x merges. That prompt will:

- Reference this SPEC at v0.1.x as the controlling contract.
- Carry the §9 prerequisites as a pre-flight checklist.
- Run the SPEC-audit-loop discipline applied to IMPL work per
  [[feedback-build-audit-loop]].

## Appendix B — Deferred follow-ups (filed as Issue stubs, not inlined)

- SPEC-014 v0.9: payout-address registration screen + payout
  history surface. Consumes §3.3 and §7.3.
- SPEC-005 vX.Y+1: extend `/providers/{id}/earnings` response
  with `next_payout_eta`, `last_payout_tx_hash`,
  `last_payout_paid_at_utc`. Pure additive; SPEC-016 v0.1
  does NOT require it.
- SPEC-016 v0.2 candidates: KMS-backed `Signer`
  implementation (§6.5); auto-split of over-cap payouts
  (§5.2); RPC fallback rotation (the v0.1.1 contract requires
  TWO RPCs in agreement; v0.2 MAY add N-of-M voting);
  in-process key rotation (§6.4); automated nonce-gap fill
  (§4.6, replacing the operator-driven
  `/admin/payout/abandon-attempt` flow); collapse
  `/providers/{id}/earnings` and `/providers/{id}/payouts`
  into one endpoint with a versioned schema. NOTE:
  `/admin/payout/abandon-attempt` (§4.6) and
  `/admin/payout/record-orphan` (§4.7) are IN-SCOPE for v0.1.1;
  the earlier-draft `/admin/payout/void` status-mutating
  endpoint was REMOVED in v0.1.1 per audit fix.
