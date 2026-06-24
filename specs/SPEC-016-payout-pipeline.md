# SPEC-016 — Provider payout pipeline (USDC on Base)

**Version:** 0.1.4 (2026-06-24, draft — round-5 audit fix pass:
1 CRIT + 2 MAJOR + 6 MEDIUM + 1 LOW absorbed across CODE +
SECURITY + ARCHITECT lenses. Audit history: round-1 1/5,
round-2 5/12/10, round-3 3/9/8, round-4 2/6/13, round-5 1/2/6.
See git log for full per-round detail per
[[feedback-spec-audit-loop-before-pr]].)
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

**v0.1.4 (2026-06-24, draft — round-5 audit fix pass):**

Round-5 returned 1 CRIT + 2 MAJOR + 6 MEDIUM + 1 LOW.
Substantive changes:

CRITICAL:

- **§4.9 `payout_hot_wallet_funding` schema was missing
  `to_address` column** that §7.4 chain-balance reconciliation
  queried — runtime SQL error in the negative-drift alarm.
  v0.1.4 adds `to_address TEXT NOT NULL` to the schema;
  request body persists `to_address` after the
  `== payout.hot_wallet_address` check; §4.9 funding-sum
  and §6.2 `/admin/payout/balance` queries switched to
  `WHERE to_address = :hot_wallet` (semantically correct:
  funding inflows go TO the hot wallet).

MAJOR:

- **`ts_utc` format inconsistency** — §3.2 EIP-712 input
  pinned `tsUtc: uint64` unix seconds, but §3.4 audit log
  and §7.1 events table imply RFC3339Nano. v0.1.4 §3.4 +
  §7.1.0 (new) explicitly normalise: the input `ts_utc` is
  uint64 unix seconds; the logger stamps the canonicalised
  RFC3339Nano form on the audit-log line. Every §7.1 event
  field named `ts_utc` is RFC3339Nano.
- **SPEC-005 vX.Y+1 contract surface was unspecified** — §9.5b
  HARD-blocked IMPL on an endpoint SPEC-005 doesn't know
  about. v0.1.4 adds §9.5b.1 "SPEC-005 vX.Y+1 normative
  contract surface required by SPEC-016" with the exact
  request body schema, idempotency_key format
  (`reorg_compensation:<orig_payout_id>:<orig_attempt_seq>`),
  and `min_payout_credits=0` bypass rule the SPEC-005 author
  must honor. SPEC-005 author can now implement cold without
  consulting SPEC-016.

MEDIUM:

- §4.8 bootstrap-flag flip mechanism PINNED as an
  `AFTER UPDATE OF confirmed_at_utc ON payout_attempts`
  trigger — earlier draft said "in the same DB transaction;
  IMPL test required" without specifying the mechanism,
  allowing a race-prone application-layer implementation.
- §4.8 bootstrap-flag soft-guard hardened: at runner startup
  AND every cadence cycle, IMPL MUST assert both bootstrap
  triggers (`trg_prs_bootstrap_one_way` AND
  `trg_pa_bootstrap_flip`) exist in `sqlite_master`; missing
  trigger emits `payout_invariant_violation` and HALTS the
  runner. Closes the DROP TRIGGER + UPDATE bypass class.
- §6.4 key-rotation procedure adds Step 5 "all registered
  providers MUST re-register against the new hot wallet";
  `provider_payout_addresses` gains a
  `registered_against_hot_wallet TEXT NOT NULL` column; §4.3
  step 1 SELECT filters `ppa.registered_against_hot_wallet =
  payout.hot_wallet_address` so stale-against-prior-rotation
  rows are not paid. Closes the EIP-712 verifyingContract
  rotation invalidation ambiguity.
- §6.5 split into `payout.security.*` (immutable: caps,
  hot_wallet_address, recon_*, cancel_max_*) vs
  `payout.tuning.*` (hot-reloadable: run_interval,
  confirmation_blocks, low_balance_threshold,
  rpc_url_*_pin_spki, address_cooling_off_period,
  run_now_min_interval). Tuning reload emits
  `payout_config_reloaded` per §7.1 with the key + old/new
  values; security-namespace hot-reload remains FORBIDDEN.
- Appendix B files a SPEC-005 v0.4 + SPEC-014 v0.9
  follow-up to cross-reference the SPEC-016 Linux-only
  inheritance.

LOW:

- §3.2 step 5 now REQUIRES `ecrecover(typedDataHash, sig)
  == canonical_address` AND `typed-data.providerId ==
  URL_provider_id`; REJECT 400 `providerid_mismatch` on
  inequality.

**v0.1.3 (2026-06-24, draft — round-4 audit fix pass):**

Round-4 lens-parallel audit returned 2 CRIT + 6 MAJOR + 13
MEDIUM. All addressed. Substantive changes:

CRITICAL:

- **C1 (SEC) — EIP-191 → EIP-712 migration.** v0.1.2 §3.2
  step 5 used plaintext-prefixed EIP-191 personal_sign,
  vulnerable to (a) `provider_id` newline injection (no charset
  constraint), (b) cross-message replay if any other
  macprovider EIP-191 surface ever signs a colliding prefix,
  (c) cross-provider replay (anti-replay PK was
  `(provider_id, nonce)`). v0.1.3 §3.2 step 5 specifies
  EIP-712 typed-data signing with a pinned domain (`name=
  "macprovider-payout"`, `version="1"`, `chainId=8453`,
  `verifyingContract=payout.hot_wallet_address`). The
  `PayoutAddressRegistration` struct carries
  `(providerId, address, chain, nonce, tsUtc)`.
  `provider_id` MUST match `^[A-Za-z0-9_-]{1,128}$` (REJECT
  400 `bad_provider_id`). Anti-replay table PK changed to
  `(canonical_address, nonce)` (global per-address), AND
  retention shortened to 10 minutes (== 2× ts_utc skew
  bound) — the v0.1.2 1-hour retention left a ~1h replay
  window past the ±5 min skew window.
- **C2 (SEC) — `source='manual'` enabled fake-funding
  drain.** A compromised operator key could record a
  non-existent funding tx via `POST /admin/payout/record-funding
  source=manual` to inflate `expected_balance`, masking
  drains in the §7.4 drift alert. v0.1.3 §4.9 + §9.1:
  `source='manual'` is now BOOTSTRAP-ONLY — gated by a
  one-way `payout_bootstrap_complete` flag in
  `payout_runner_state` that flips to `true` the moment any
  payout confirms. After that, `source='manual'` is REJECTED
  with 422 `bootstrap_complete`; ongoing funding records
  MUST use `source='rpc-confirmed'` which now REQUIRES the
  body's `from_address` (sender), `to_address == hot_wallet`,
  `amount_base_units`, and `block_number` to all match the
  on-chain receipt fetched from BOTH RPCs (mismatch → 422).
  §7.1 splits `payout_chain_balance_drift_negative` as a
  separate event with severity=PAGE and runbook text "POSSIBLE
  FAKE FUNDING RECORD; cross-check basescan".

MAJOR:

- **§4.7 manual SQL compensation recipe was non-executable.**
  v0.1.2's recipe omitted `created_at_utc` (NOT NULL) and
  the explicit `operator_credits` column, and synthetic-1s-
  window collided on the `UNIQUE(provider_id, window_start_utc,
  window_end_utc)` constraint when two orphans observed in
  the same second. v0.1.3 REMOVES the manual SQL recipe
  entirely. §9.5b (SPEC-005 vX.Y+1 `POST /admin/ledger/
  payout-ready` admin endpoint) is PROMOTED FROM SOFT TO
  HARD: IMPL is blocked until SPEC-005 vX.Y+1 lands the
  admin endpoint. §4.7 compensation flow is now: operator
  calls SPEC-005 admin endpoint, records the returned
  `payout_id` in `payout_reorg_orphans.compensation_settlement_id`
  via `/admin/payout/record-orphan`.
- **§4.6 + §6 runtime-immutable cap set extended.**
  v0.1.2 only pinned `payout.cancel_max_*` as runtime-
  immutable, leaving `payout.chain_recon_interval` /
  `chain_recon_tolerance_usdc_base_units` /
  `confirmation_blocks` / `per_*_cap_*` / `hot_wallet_address`
  / `rpc_url_*` / `address_cooling_off_period` mutable —
  a compromised operator key could hot-edit `coordinator.toml`
  + restart to silence the drift alarm. v0.1.3 §6.5: ALL
  `payout.*` config keys are RUNTIME-IMMUTABLE process-wide;
  SIGHUP / fsnotify / debug-endpoint reload of any
  `payout.*` key is FORBIDDEN. IMPL test required.
- **§4.7 `compensation_settlement_id` FK missing ON DELETE
  RESTRICT** added.
- **§6.3 systemd-coredump check option (b) was trivially
  satisfied** at process startup (zero `coredumpctl` entries
  is trivially true at startup). v0.1.3 drops option (b)
  entirely; requires option (a) — `kernel.core_pattern` MUST
  NOT begin with `|` AND MUST NOT contain `systemd-coredump`,
  else fail-loud. Operators using systemd-coredump must
  override `core_pattern` via sysctl on the runner host.
- **§6.3.1 Signer interface `SignMessage` removed.** YAGNI
  + footgun (exposes the hot-wallet signer for arbitrary
  off-chain message signing); test-only methods belong on
  the concrete struct, not the interface. The `unsignedTxBytes`
  format ambiguity (RLP envelope vs sighash) is pinned to
  EIP-2718-prefixed RLP-encoded unsigned EIP-1559 transaction
  with empty signature fields.
- **§2 Linux-only transitivity** documented: enabling
  `payout.enabled: true` constrains the whole coordinator
  process to Linux (since the registration handler + runner
  are co-resident per §3.3). SPEC-005 + SPEC-014 endpoints
  in the same process inherit the constraint.

MEDIUM:

- §4.6 abandon transaction MUST use `BEGIN IMMEDIATE` (not
  default `BEGIN DEFERRED`) so the partial-UNIQUE-INDEX
  check is serialised against concurrent abandons.
- §4.6 abandon broadcast-fail recovery clarified: the DB
  transaction commits BEFORE the cancel-tx broadcast; if
  the broadcast fails after commit, the cancel row remains
  in `payout_attempts` with its `raw_signed_tx` and the
  next cadence cycle picks it up for re-broadcast via §4.5
  retry path (NOT a new sign — the persisted bytes are
  re-broadcast bit-for-bit).
- §7.4 chain-balance outflow query now includes `AND
  is_cancel_self_transfer = 0` — cancel self-transfers move
  1 base unit hot→hot (net-zero on-chain) but the v0.1.2
  query subtracted them from expected, producing slow
  positive drift accumulation.
- §4.7 orphan compensation forgery detection added to
  §7.4: two new reconciliation queries surface (a)
  compensation_settlement_id pointing to a non-existent
  ledger_payout_ready row, (b) idempotency_key matching
  `reorg_compensation:*` pattern with no corresponding
  orphan row.
- §4.6 cold-start nonce ±1 disagreement now ALWAYS emits
  `payout_nonce_cold_start_within_tolerance` with both RPC
  values, even when within tolerance — the silent-within-
  tolerance v0.1.2 behavior would have lost the
  lying-RPC-by-1 signal.
- §9 curl path explicitly REQUIRES the provider (not the
  operator) to produce the EIP-712 signature out-of-band;
  operator MUST NEVER touch the provider's private key.
  Closes the operator-signs-for-provider attack class on
  the §9.5 SOFT path.
- §4.9 `payout_hot_wallet_funding` placement narrowed:
  endpoint mounted under `/admin/payout/record-funding` but
  the SPEC notes a v0.2 `treasury/` package extraction is a
  candidate; v0.1.3 keeps it in `payout/funding.go` to avoid
  premature abstraction.

Scope: v0.1.3 spec is ~2200 lines. The originating prompt's
~600 line "kill scope" budget is an audit-aware overshoot —
each round closed real money-path defects. Future v0.2 SHOULD
consider extracting §6.3 hardening checklist + §9 prereqs
into a separate non-normative `OPERATOR_RUNBOOK.md`; v0.1.3
keeps single-file for atomic merge.

**v0.1.2 (2026-06-24, draft — round-3 audit fix pass):**

Round-3 lens-parallel audit (CODE + SECURITY + ARCHITECT, three
independent subagents) returned 3 CRITICAL + 9 MAJOR + 8 MEDIUM.
All addressed. Substantive contract changes below; cosmetic
fixes not enumerated.

CRITICAL closures:

- **C1 (CODE) — §4.5 `UNIQUE(from_address, nonce)` blocked the
  §4.6 cancel-self-transfer write.** The round-2 abandon flow
  inserted a new `payout_attempts` row at the original nonce,
  which SQLite would reject. v0.1.2 replaces the unconditional
  UNIQUE with a partial UNIQUE INDEX `idx_pa_from_nonce_active
  ON payout_attempts(from_address, nonce) WHERE abandoned_at_utc
  IS NULL`. §4.6 also pins the abandon flow as a single
  transaction: set `abandoned_at_utc` on the original row, then
  INSERT the cancel-self-transfer row, atomically. The on-chain
  nonce uniqueness remains the ground-truth double-spend
  guard.
- **C2 (SEC) — 24h cooling-off didn't defeat first-ever-
  registration backlog drain.** A stolen `provider_token` for
  a provider who had never registered could register the
  attacker's address (no `rotated_from` fallback exists),
  wait 24h, then drain the backlog. The portal banner is a UX
  defense; the provider may never log in. v0.1.2 §3.2 adds a
  mandatory EIP-191 proof-of-possession signature: the
  registration body MUST include a signature over `(provider_id
  || canonical_address || nonce || ts)` produced by the
  registered address's private key; the coordinator verifies
  `ecrecover == submitted_address`. This defeats registration
  of an address the registrant cannot sign for, regardless of
  token theft, in both rotation AND first-ever cases.
- **C3 (SEC) — abandon-attempt gas budget was operator-
  mutable.** A compromised operator key could edit
  `coordinator.toml`, restart the runner, and burn the entire
  hot-wallet native ETH balance via abandons at any tip / any
  per-cancel ceiling — the §5 caps only protected USDC, not
  native. v0.1.2 §4.6 + §9.3: `payout.cancel_max_*` keys are
  RUNTIME-IMMUTABLE (loaded only at process start; hot-reload
  is FORBIDDEN — IMPL test required); a new aggregate ceiling
  `payout.cancel_max_gas_native_wei_per_24h` (default `5e16` =
  0.05 ETH/day) enforces a sliding-window cap from
  `payout_attempts WHERE is_cancel_self_transfer = 1`; every
  `payout_attempt_abandoned` event is severity=page (every
  invocation deserves human eyes — abandon should be a
  once-a-month operation).

MAJOR closures:

- **MAJOR (SEC) — RPC consensus needs separation hardening.**
  v0.1.2 §4.4 + §9.2 add three sub-requirements: (a) the two
  RPC keys MUST live under separate secrets paths (different
  systemd `LoadCredential=` files or different env-vars under
  different prefixes); (b) optional TLS certificate-pinning of
  the RPC hostnames via `payout.rpc_url_primary_pin_spki` /
  `payout.rpc_url_secondary_pin_spki` config keys; (c)
  `payout.chain_recon_interval` default lowered from 24h to
  1h; (d) drift tolerance default lowered from 1 USDC to the
  smallest plausible per-payout amount
  (`payout.chain_recon_tolerance_usdc_base_units` default
  `100_000` == $0.10).
- **MAJOR (SEC) — `last_run_cancel_gas_native_wei` was per-run
  only.** A malicious operator spreading burns across runs was
  invisible at `/admin/payout/balance`. v0.1.2 §4.8 + §6.2:
  surface is now `cancel_gas_native_wei_24h` computed from
  `SUM(payout_attempts.gas_used_native_wei WHERE
  is_cancel_self_transfer = 1 AND broadcast_at_utc >=
  now-24h)` directly, plus `cancel_gas_native_wei_total` over
  the lifetime. The per-run column is retained for the runner-
  state observability but not used for any cap-check.
- **MAJOR (ARCH) — `Signer` interface contract was never
  defined.** v0.1.2 adds §6.3.1 "Signer interface contract"
  with method signatures, error semantics, and
  determinism-on-retry guarantees the v0.2 KMS implementation
  must satisfy without amending SPEC-016.
- **MAJOR (ARCH) — §4.7 hand-waved compensation through a
  SPEC-005 path that does not exist.** SPEC-005 v0.3's
  `/admin/ledger/*` endpoints are GET-only; no
  fresh-`ledger_payout_ready`-row admin endpoint exists. v0.1.2
  §4.7 honest-ifies the compensation flow: it now describes
  the available manual path (operator-controlled SQL INSERT
  audited via a new structured log event
  `payout_reorg_compensation_recorded`) AND files SPEC-005
  vX.Y+1 candidate as a NEW HARD prerequisite in §9.5b for
  shipping the compensation as an admin endpoint rather than
  raw SQL. The orphan-recording surface itself (read-only) is
  unchanged.
- **MAJOR (ARCH) — audit-chain wording elided
  multi-attempt PK.** §1 now reads `request_id → settlement_id
  → payout_id → (attempt_seq, tx_hash)` and notes that
  "the canonical confirmed attempt" is the unique row matching
  `idx_pa_one_active_per_payout` (§4.5).

MAJOR closures (CODE):

- **MAJOR (CODE) — `payout_reorg_orphans` missing `ON DELETE
  RESTRICT`.** v0.1.2 §4.7 adds it to both FK declarations.
- **MAJOR (CODE) — `initial-funding-record` was undefined.**
  v0.1.2 adds a new §4.9 `payout_hot_wallet_funding` table
  + `POST /admin/payout/record-funding` endpoint
  (operator-key, Idempotency-Key, structured-log event
  `payout_funding_recorded`); §7.4 chain-balance reconciliation
  references this table directly instead of a magic constant.

MEDIUM closures:

- §3.4 `submitted` field tightened from raw bytes to a
  fingerprint (`submitted_fingerprint`: first 6 + last 4 chars
  + length); defeats log-injection + reduces info disclosure
  if log destination is breached.
- §6.3 hot-wallet runtime support narrowed to Linux only;
  macOS dev environments are FORBIDDEN for the runner
  (Crashreporter bypasses RLIMIT_CORE; per
  [[macprovider-launchd-amfi-blocker-macos-26]] the dev
  surface is macOS-only, so this is an explicit op-mode
  cut). The §6.3 hardening checklist adds a startup
  self-test that asserts `cat /proc/sys/kernel/core_pattern`
  does NOT pipe to `systemd-coredump`, OR that the
  coordinator's systemd unit has `Coredump=no`.
- §3.3 `:8444` handler routing restricted to EXACT-MATCH
  patterns only; trailing-slash prefix routes are FORBIDDEN;
  IMPL MUST use `chi` or `gorilla/mux` or an equivalent
  router that does not collapse prefixes (Go stdlib
  `http.ServeMux` is REJECTED for this listener at IMPL
  audit). Test required: POST a set of
  escaped/dot-segmented URLs and assert the realm hit.
- §4.1 `billing/` package boundary specified: `billing/` MUST
  NOT import `payout/`; cross-package reads go through a
  `PayoutAddressReader` interface DECLARED in `billing/`
  (not `payout/`) and SATISFIED by a thin adapter in
  `payout/`, wired in `main.go`. Method:
  `LookupPayoutAddress(ctx, providerID, chain) (address
  string, payoutAllowed bool, err error)`.
- §3.3 clock authority pinned: both `pending_until_utc`
  (write) and `:now` (read at §4.3 step 1) MUST come from
  the coordinator process clock; co-residency of registration
  handler and runner asserted at startup; clock-skew
  tolerance FORBIDDEN.
- §9 item 5 promoted from SOFT back to HARD on the
  notification-channel sub-requirement: IMPL MAY ship before
  SPEC-014 v0.9 ONLY if the operator runs a manual
  notification process (email/webhook) to providers on every
  `provider_payout_address_changed` event. The
  "curl-for-initial-set" escape valve is preserved for the
  registration surface itself but the legitimate-provider
  notification path becomes a hard prerequisite (item 5a).
- §4.6 cold-start nonce sync hardened: requires BOTH RPCs to
  agree within ±1 on `getTransactionCount`; disagreement
  halts the runner and pages.
- §4.3 step 1 SELECT outer `COALESCE(..., ppa.address)`
  dropped — the inner CASE alone is correct and the WHERE
  clause is the authoritative exclusion; the outer fallback
  was defense-in-depth in the wrong direction.
- §4.6 cancel self-transfer row spec: `to_address =
  from_address = payout.hot_wallet_address`,
  `amount_base_units = 1` (the §4.5 CHECK forbids 0; 1 base
  unit == $0.000001, the cheapest concrete reconciliation).

QUESTION closures:

- §4.2 `/admin/payout/run-now` gets a `payout.run_now_min_interval`
  (default 60s) rate-limit at the endpoint to prevent CPU/RPC
  DoS.
- §5.3 cancel-rows-count-against-day-cap is INTENTIONAL and
  now documented inline (a malicious operator-key holder
  burning the cap via cancels is bounded by the C3
  runtime-immutable abandon caps; if those caps land, the
  starvation risk is bounded).
- §7.1.1 added: `payout_chain_balance_drift` and
  `payout_rpc_disagreement` events are JOURNALCTL-ONLY at
  v0.1; SQL-side promotion to `phase4-coordinator/internal/audit/store.go`
  is a SPEC-016 v0.2 candidate.

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
captured in §6.6 as a forward pointer; the `Signer` interface
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
SPEC-016 adds `payout_attempts.(payout_id, attempt_seq) →
ledger_payout_ready.id` and records `payout_attempts.tx_hash`.
The full chain is
`request_id → settlement_id → payout_id → (attempt_seq,
tx_hash)`. Note the `(attempt_seq, tx_hash)` tail: a single
`payout_id` may have multiple `payout_attempts` rows (original,
cancel self-transfers, post-abandon retries). The CANONICAL
confirmed attempt is the unique row matching
`idx_pa_one_active_per_payout` per §4.5 (single confirmed
non-cancel non-abandoned row per payout_id); compensation rows
for reorg orphans live at the SPEC-005 layer with their own
`payout_id`. SPEC-016 MUST NOT modify any upstream identifier.

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

**Linux-only constraint when `payout.enabled = true`.** §6.3
requires the runner process to run on Linux (Crashreporter on
macOS bypasses `RLIMIT_CORE`). §3.3 requires the registration
handler + runner to be co-resident in the same coordinator
process (clock authority). Therefore enabling
`payout.enabled = true` constrains the ENTIRE coordinator
process — including SPEC-005 settlement + SPEC-014 portal
endpoints + buyer-mux + ws-mux — to Linux. macOS dev
environments cannot run a payout-enabled coordinator. This is
a deliberate cut; the dev workflow on macOS continues to work
with `payout.enabled = false` (default).

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
    registered_against_hot_wallet TEXT NOT NULL,
    UNIQUE(provider_id, chain)
);
CREATE INDEX IF NOT EXISTS idx_ppa_provider ON provider_payout_addresses(provider_id);
```

`registered_against_hot_wallet` is the operator's
`payout.hot_wallet_address` value AT registration time
(used as EIP-712 `verifyingContract`, §3.2 step 5). After a
§6.4 key rotation, rows whose
`registered_against_hot_wallet != payout.hot_wallet_address`
are SKIPPED by the runner (§4.3 step 1) until the provider
re-registers against the new hot wallet. This makes the
"EIP-712 signature is valid only for the current hot wallet"
property operationally explicit rather than implicit.

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
5. **EIP-712 proof-of-possession.** The request body MUST
   include a `signature` field — a 65-byte (r||s||v)
   hex-encoded EIP-712 typed-data signature over the
   following domain + struct:

   ```
   EIP-712 Domain:
   {
     name:              "macprovider-payout",
     version:           "1",
     chainId:           8453,
     verifyingContract: <payout.hot_wallet_address>
   }

   PayoutAddressRegistration:
   {
     providerId: string,    // matches ^[A-Za-z0-9_-]{1,128}$
     address:    address,   // canonical EIP-55 checksum
     chain:      string,    // exactly "base-mainnet"
     nonce:      bytes32,   // opaque 32 bytes hex
     tsUtc:      uint64     // unix seconds; ±5 min skew
   }
   ```

   EIP-712 (NOT EIP-191) is REQUIRED because the domain
   separator binds the signature to `(name, version,
   chainId, verifyingContract)`, defeating cross-message /
   cross-surface signature replay. The plaintext-prefix
   EIP-191 personal_sign format used in earlier drafts was
   vulnerable to (a) newline injection in `provider_id`,
   (b) cross-surface replay if any other macprovider EIP-191
   surface ever signs a colliding prefix, (c) confusing UX
   in wallets where the user sees plain text and can't tell
   what they're signing.

   The `verifyingContract` field is the operator's pinned
   `payout.hot_wallet_address` (a sentinel — there is no
   smart contract at this step; the address is canonical
   for the domain separator). Pinning to the hot wallet
   means a signature is valid only for the current hot
   wallet; key rotation (§6.4) implicitly invalidates all
   prior signatures, which is the correct behavior.

   `provider_id` MUST match `^[A-Za-z0-9_-]{1,128}$` —
   REJECT 400 `bad_provider_id` on miss. This sanitization
   defeats the newline-injection class even though EIP-712
   structured signing makes raw concatenation moot.

   `nonce` is a fresh 32-byte hex-encoded value (anti-replay
   table below). `ts_utc` MUST be within ±5 minutes of the
   coordinator's clock else REJECT 400 `signature_skew`.

   The coordinator MUST verify the EIP-712 signature using
   the canonical-checksummed address from step 2 as the
   expected signer (`ecrecover(typedDataHash, sig) ==
   canonical_address`) AND verify the typed-data
   `providerId` field equals the URL-path `provider_id`,
   AND verify the typed-data `address` field equals the
   canonical-checksummed address from step 2, AND verify
   the typed-data `chain` field equals the request body's
   `chain` field. REJECT 400 `signature_mismatch` on
   ecrecover inequality, `providerid_mismatch` on the
   providerId check, `address_mismatch` on the address
   check, `chain_mismatch` on the chain check. These
   field-by-field equality checks make every typed-data
   field operationally load-bearing — a typed-data field
   that isn't verified is decorative and creates a
   future-attack-surface seam.

   This defeats registration of an address the registrant
   cannot sign for — closes the stolen-token attack class
   for BOTH first-ever registration AND rotation. The
   provider portal (SPEC-014 v0.9) supplies the signing UX
   via a connected wallet (Coinbase Wallet, Rabby, Safe).
   The curl path (during §9.5 bootstrap before SPEC-014
   v0.9) REQUIRES the provider — NOT the operator — to
   produce the EIP-712 signature and send it to the
   operator out-of-band; the operator MUST NEVER touch the
   provider's private key (this would subvert the entire
   proof-of-possession threat model).

   Replay protection table (IMPL-internal):

   ```sql
   CREATE TABLE IF NOT EXISTS provider_payout_address_nonces (
       canonical_address TEXT NOT NULL,
       nonce             TEXT NOT NULL,
       seen_at_utc       TEXT NOT NULL,
       PRIMARY KEY(canonical_address, nonce)
   );
   CREATE INDEX IF NOT EXISTS idx_ppan_seen ON provider_payout_address_nonces(seen_at_utc);
   ```

   PK is scoped to the canonical signing address, NOT
   `provider_id`. This defeats cross-provider replay where
   an attacker holding a captured signature for one
   provider's registration could replay it under a different
   provider_id (the EIP-712 typed data includes providerId
   so ecrecover would yield a different address anyway, but
   the table-level scoping is defense-in-depth).

   IMPL prunes entries older than 10 MINUTES (== 2× the
   ts_utc skew bound) via a background cleanup. A longer
   retention left an open replay window past the skew
   window; the bound is `min(skew_window, prune_retention)`.

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
all requests). EXACT-MATCH patterns only — trailing-slash
prefix routes on `:8444` are FORBIDDEN because Go's stdlib
`http.ServeMux` longest-prefix matching can route a crafted
escaped URL (e.g. `/admin/payout/../providers/x/payouts`) to
an unexpected handler before normalization. IMPL MUST use
`chi`, `gorilla/mux`, or an equivalent router that does not
collapse prefixes — `http.ServeMux` is REJECTED for this
listener at IMPL audit. An IMPL test MUST POST a series of
escaped / dot-segmented URLs and assert each request lands
on the realm the path-table declared.

**Clock authority.** Both `pending_until_utc` (set at
registration) and `:now` (read at §4.3 step 1) MUST come
from the SAME coordinator process clock. The registration
handler and the runner are co-resident in the same
coordinator process per §4.1; IMPL MUST assert this
co-residency at startup (e.g. a deployment-mode check that
fails-fast if the runner is configured to a different
process or host) and MUST NOT honor any clock-skew tolerance
when comparing `pending_until_utc` to `:now`. This makes the
cooling-off boundary non-bypassable by multi-host
deployment expansion.

```
POST /providers/{provider_id}/payout-address
Authorization: Bearer <provider_token>   ; per SPEC-002 §7.3
Content-Type: application/json

{ "chain": "base-mainnet",
  "address": "0xAbC...checksummed",
  "nonce": "0x<64-hex-chars>",
  "ts_utc": 1719234896,
  "signature": "0x<130-hex-chars EIP-712 r||s||v>" }

Response:
  201 Created      — first-ever registration; pending_until_utc
                     = now + 24h (or configured period).
  200 OK           — rotation; pending_until_utc rewritten.
  400 Bad Request  — failed §3.2 validation. Body:
                     { "error": "<one of: bad_format,
                                 checksum_mismatch,
                                 unknown_provider,
                                 denylist,
                                 signature_mismatch,
                                 signature_skew,
                                 nonce_replayed,
                                 missing_field>" }
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
EIP-55 checksummed forms (not the submitted form). The
`pending_until_utc` and `ts_utc` fields in this audit log
are RFC3339Nano formatted strings — the logger stamps the
canonical RFC3339Nano form even though the §3.2 step 5
EIP-712 input takes `tsUtc` as uint64 unix seconds. The
input vs log normalisation lives at the handler boundary
(unix seconds in → RFC3339Nano out). All §7.1 event-table
fields named `ts_utc` are RFC3339Nano.

Failed registrations emit
`provider_payout_address_change_rejected` with `reason`,
`provider_id`, `src_ip`, `submitted_fingerprint` fields.
`submitted_fingerprint` is
NOT the raw submitted bytes — it is the first 6 + last 4
chars + length of the submitted address string (e.g.
`"0xAbCdEf...1234 len=42"`). Logging the raw bytes was an
info-disclosure + log-injection vector: an attacker
enumerating addresses via the public endpoint would write
attacker-controlled bytes (potentially containing newlines
or ANSI escapes) into operator log infra. The fingerprint
keeps the burst-detection signal (an enumeration burst
still produces N distinct fingerprints with consistent
length) while denying the attacker any controlled-bytes
pivot.

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
- `signer.go` — concrete local-file signer at v0.1.2; the
  package-internal `Signer` interface this satisfies (defined
  in §6.3.1) is the seam for the v0.2 KMS substitution
  (§6.6).
- `attempts.go` — `payout_attempts` table CRUD (§4.5).
- `addresses.go` — `provider_payout_addresses` CRUD + the
  §3.3 handler (§3 entirety).
- `funding.go` — `payout_hot_wallet_funding` CRUD + the
  `/admin/payout/record-funding` handler (§4.9).
- `orphans.go` — `payout_reorg_orphans` CRUD + the
  `/admin/payout/record-orphan` handler (§4.7).

**Cross-package boundary (billing/ ↔ payout/).** `billing/`
MUST NOT import `payout/`. Cross-package address reads from
`billing/` (if any) MUST go through a `PayoutAddressReader`
interface DECLARED in `billing/` and SATISFIED by a thin
adapter in `payout/`, wired in `main.go`. The interface
exposes exactly:

```go
type PayoutAddressReader interface {
    LookupPayoutAddress(ctx context.Context, providerID, chain string) (address string, payoutAllowed bool, err error)
}
```

`payout/` is permitted to import `billing/` for the
`ClaimPayoutReady` call (§4.3 step 7). The direction is
strictly one-way: `payout/ → billing/`, never the reverse.
IMPL audit MUST include an import-graph test asserting
this.

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
  within an in-flight run (return 409 if one is active) AND
  rate-limited via `payout.run_now_min_interval` (default
  60s — defends against a tight-loop CPU/RPC DoS by an
  operator-key holder; return 429 if invoked sooner than the
  interval). Every invocation emits `payout_run_now_invoked`
  per §7.1.

### 4.3 Per-run algorithm

For each scheduled run, the loop MUST execute IN ORDER, exiting
any step on error and logging structurally:

1. **Select.**

   ```sql
   SELECT lpr.id, lpr.provider_id, lpr.gross_credits,
          lpr.provider_credits, lpr.window_start_utc,
          lpr.window_end_utc,
          CASE WHEN ppa.pending_until_utc IS NOT NULL
                AND ppa.pending_until_utc > :now
               THEN ppa.rotated_from
               ELSE ppa.address END AS effective_address
     FROM ledger_payout_ready lpr
     INNER JOIN provider_payout_addresses ppa
       ON ppa.provider_id = lpr.provider_id
      AND ppa.chain = 'base-mainnet'
      AND ppa.payout_allowed = 1
      AND ppa.registered_against_hot_wallet = :hot_wallet
    WHERE lpr.status = 'ready'
      AND (ppa.pending_until_utc IS NULL
           OR ppa.pending_until_utc <= :now
           OR ppa.rotated_from IS NOT NULL)
    ORDER BY lpr.id ASC
    LIMIT :max_rows_per_run;
   ```

   The `registered_against_hot_wallet = :hot_wallet` clause
   excludes rows that were registered against a prior hot
   wallet (pre-§6.4 rotation). Such rows wait until the
   provider re-registers against the current hot wallet
   (operator notifies via §5a channel during rotation).

   The outer `COALESCE(..., ppa.address)` was REMOVED in
   v0.1.2: for first-ever registration during cooling-off the
   CASE returns NULL, but that row is already excluded by the
   WHERE `rotated_from IS NOT NULL`. The COALESCE was a
   defense-in-depth in the WRONG direction — if the WHERE
   ever loosened, the SELECT would silently pay to the
   pending-but-uncooled-off address. IMPL MUST treat a NULL
   `effective_address` as a hard error (skip + log
   `payout_invariant_violation`) — it can never legally
   appear given the WHERE clause.

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

### 4.4 RPC failure tolerance + key/trust separation

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

**RPC trust separation requirements** (defense against the
case where both RPC endpoints are subverted in tandem —
DNS hijack on operator resolver, shared TLS trust-store
compromise, single secrets-store breach):

1. The two RPC URLs + keys MUST be loaded from SEPARATE
   secrets paths. Single-config-file with both keys is
   FORBIDDEN. Acceptable: two distinct systemd
   `LoadCredential=` entries; two distinct env-vars under
   different prefixes (`PAYOUT_RPC_PRIMARY_*` and
   `PAYOUT_RPC_SECONDARY_*`).
2. The two RPC hostnames SHOULD resolve via different DNS
   chains where the operator's infrastructure allows.
3. Optional TLS certificate-pinning via
   `payout.rpc_url_primary_pin_spki` /
   `payout.rpc_url_secondary_pin_spki` config keys (SHA-256
   of the SubjectPublicKeyInfo); when set, the runner MUST
   verify the served cert chain anchors to the pinned SPKI
   and reject otherwise. v0.1.2 makes the keys OPTIONAL but
   the configurability hooks are normative.
4. `payout.chain_recon_interval` default is 1 HOUR (NOT
   24h — earlier default would give an attacker who fakes
   both RPC receipts a 24-hour drain window before the
   on-chain `balanceOf` discrepancy is detected).
5. `payout.chain_recon_tolerance_usdc_base_units` default
   is `100_000` (== $0.10) — the smallest plausible
   per-payout amount; any drift above this is paged.

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
    gas_used_native_wei INTEGER NULL,
    is_cancel_self_transfer INTEGER NOT NULL DEFAULT 0 CHECK(is_cancel_self_transfer IN (0,1)),
    last_error       TEXT NULL,
    abandoned_at_utc TEXT NULL,
    abandoned_reason TEXT NULL,
    updated_at_utc   TEXT NOT NULL,
    PRIMARY KEY(payout_id, attempt_seq)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_from_nonce_active
    ON payout_attempts(from_address, nonce)
 WHERE abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_unconfirmed
    ON payout_attempts(payout_id)
 WHERE confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_confirmed_recent
    ON payout_attempts(confirmed_at_utc)
 WHERE confirmed_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_broadcast_recent
    ON payout_attempts(broadcast_at_utc)
 WHERE broadcast_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;
CREATE INDEX IF NOT EXISTS idx_pa_cancel_recent
    ON payout_attempts(broadcast_at_utc)
 WHERE is_cancel_self_transfer = 1 AND broadcast_at_utc IS NOT NULL AND abandoned_at_utc IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_pa_one_active_per_payout
    ON payout_attempts(payout_id)
 WHERE confirmed_at_utc IS NOT NULL AND abandoned_at_utc IS NULL AND is_cancel_self_transfer = 0;
```

`gas_used_native_wei` is populated post-confirmation from
the receipt; it powers the §6.2 aggregate cancel-gas-burn
visibility (`cancel_gas_native_wei_24h`).

The `(payout_id, attempt_seq)` PK lets a payout_id have
multiple attempt rows (the original payout attempt, plus any
cancel self-transfers, plus any post-abandon fresh attempts).
The `idx_pa_one_active_per_payout` partial UNIQUE index
guarantees at most ONE confirmed non-cancel non-abandoned row
per payout_id (the double-spend guarantee at the application
layer; the chain nonce is the on-chain guarantee).

The `idx_pa_from_nonce_active` partial UNIQUE index requires
`abandoned_at_utc IS NULL`, so an abandon-then-cancel flow
can re-use the same nonce in a fresh row after the abandon
row is flagged in the same transaction. An unconditional
UNIQUE would make the §4.6 cancel-self-transfer insert at
the original nonce impossible. The chain itself enforces
real on-chain nonce uniqueness (only one tx per nonce can
confirm).

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
  the cursor by querying `getTransactionCount(pending)` from
  BOTH RPCs. The two MUST agree within ±1; difference >1
  halts the runner and pages the operator
  (`payout_rpc_disagreement` per §7.1, reason=
  `nonce_cold_start_mismatch`). The cursor is set to
  `max(cursor_in_db, max(rpc_a, rpc_b))`. A lying RPC
  returning a too-high nonce would silently force every
  fresh attempt to fail at broadcast against the honest RPC
  until §7.4 catches the drift — the ±1 check at cold-start
  closes that stealth-DoS window. Even within tolerance,
  any disagreement (`rpc_a != rpc_b`) MUST emit
  `payout_nonce_cold_start_within_tolerance` per §7.1 with
  both RPC values, so a 1-off lying-RPC signal is not silently
  absorbed.
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
    200 OK   — atomic transaction completed: abandoned_at_utc
               + abandoned_reason set on the original row;
               if broadcast_cancel_self_transfer=true, a new
               payout_attempts row with attempt_seq+1 is
               INSERTed (same transaction) with
               is_cancel_self_transfer=1,
               to_address = from_address = payout.hot_wallet_address,
               amount_base_units = 1 (cheapest
               §4.5-CHECK-compatible value; 1 base unit ==
               $0.000001), original nonce, capped tip; the
               cancel tx is signed in-tx and persisted with
               raw_signed_tx + tx_hash + broadcast_at_utc
               BEFORE COMMIT. The DB transaction MUST use
               `BEGIN IMMEDIATE` so the partial-UNIQUE-INDEX
               check on (from_address, nonce) is serialised
               against concurrent abandons; default
               `BEGIN DEFERRED` permits the SQLite writer
               race that would break atomicity. After
               COMMIT, the runner invokes
               `eth_sendRawTransaction` on both RPCs. If
               broadcast fails post-commit (RPC down,
               gas-spike rejection), the cancel row remains
               in `payout_attempts` with its raw_signed_tx;
               the next cadence cycle picks it up for
               re-broadcast via the §4.3 step 4 pending-
               attempt path. The persisted bytes are
               re-broadcast bit-for-bit (re-signing is
               FORBIDDEN, same as §4.5 retry discipline).
               Counts toward §5 day cap + §6.2 24h
               aggregate gas-burn cap. The
               idx_pa_from_nonce_active partial UNIQUE index
               permits the same (from_address, nonce) tuple
               on the new row because the original row's
               abandoned_at_utc is now non-NULL in the same
               transaction.
    400      — missing confirm/Idempotency-Key/reason.
    409 Conflict — attempt already confirmed; nothing to
                   abandon.
    422      — per-cancel gas spend would exceed
               payout.cancel_max_gas_native_wei ceiling
               OR per-24h aggregate gas spend would exceed
               payout.cancel_max_gas_native_wei_per_24h.
    429      — exceeded payout.abandon_rate_per_hour
               (default 3).
  ```

  Configurables — ALL RUNTIME-IMMUTABLE (loaded only at
  process start; SIGHUP / file-watch hot-reload is FORBIDDEN
  for this set; IMPL MUST add a test asserting they are not
  re-read post-startup). A compromised operator-key holder
  with `coordinator.toml` write access can otherwise edit
  the caps and burn the hot wallet via abandons.

  - `payout.cancel_max_tip_multiplier` — default 5×; HARD
    cap on `tip_multiplier` field; requests above the cap
    are silently floored AND logged with `cap_applied`.
  - `payout.abandon_rate_per_hour` — default 3; per-
    operator-token rate limit on the endpoint.
  - `payout.cancel_max_gas_native_wei` — default `1e16`
    (0.01 ETH); per-cancel gas spend ceiling. If exceeded,
    the request is REJECTED with 422.
  - `payout.cancel_max_gas_native_wei_per_24h` — default
    `5e16` (0.05 ETH/day); aggregate sliding-window
    ceiling computed as `SUM(payout_attempts.gas_used_native_wei
    WHERE is_cancel_self_transfer = 1 AND broadcast_at_utc
    >= now - 24h)` — for pending cancels (gas_used_native_wei
    NULL) use the cap-time gas estimate. If this estimate
    plus the historic sum would exceed the budget, the
    request is REJECTED with 422. Defends against the
    "3/hr × 24h × 5× tip" aggregate-drain attack class.

  Every `payout_attempt_abandoned` event MUST emit at
  severity=PAGE (per §7.1). Abandon should be a once-a-month
  operation; every invocation deserves human eyes.

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
    payout_id        INTEGER NOT NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    attempt_seq      INTEGER NOT NULL,
    orphan_tx_hash   TEXT NOT NULL,
    last_seen_block  INTEGER NOT NULL,
    observed_at_utc  TEXT NOT NULL,
    rpc_source       TEXT NOT NULL,
    operator_resolution TEXT NULL,
    compensation_settlement_id INTEGER NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    resolved_at_utc  TEXT NULL,
    FOREIGN KEY(payout_id, attempt_seq) REFERENCES payout_attempts(payout_id, attempt_seq) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_pro_unresolved ON payout_reorg_orphans(observed_at_utc) WHERE resolved_at_utc IS NULL;
```

`compensation_settlement_id` is the new SPEC-005 row's id
issued to compensate the provider for the orphaned payment
(NULL until compensation is recorded). The §7.4
reconciliation surface MUST surface any orphan unresolved
> N days as a separate failure class to defeat
favoritism / fraud via selective compensation.

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

If compensation is warranted, the operator inserts a fresh
`ledger_payout_ready` row VIA THE SPEC-005 ADMIN
ENDPOINT (NOT raw SQL). SPEC-005 v0.3 does NOT currently
define such an endpoint; SPEC-005 vX.Y+1 candidate
`POST /admin/ledger/payout-ready` is a HARD §9.5b
prerequisite. Earlier drafts of this SPEC carried a manual
SQL recipe for compensation; the recipe was REMOVED because
(a) it omitted required `ledger_payout_ready` columns
(`created_at_utc`, explicit `operator_credits`); (b) the
synthetic 1-second window risked colliding with the
`UNIQUE(provider_id, window_start_utc, window_end_utc)`
constraint when two orphans observed in the same second;
(c) raw SQL bypasses SPEC-005's settlement-time invariants
and audit triggers. Compensation flow under v0.1.3:

1. Operator calls the SPEC-005 admin endpoint with the
   orphan's `provider_id`, `provider_credits`, and an
   `idempotency_key` of the form
   `reorg_compensation:<orig_payout_id>:<orig_attempt_seq>`.
2. The endpoint returns the new `ledger_payout_ready.id`.
3. Operator calls
   `POST /admin/payout/record-orphan` with
   `compensation_settlement_id = <new id>` to link the
   compensation back to the orphan record.
4. The runner picks up the fresh row on the next cadence
   cycle and pays it via §4.3 — with a NEW nonce and a
   NEW tx hash, so the double-pay class remains
   structurally eliminated (the original orphan row's
   `payout_external_id` is never re-used).

A `payout_reorg_compensation_recorded` event MUST emit per
§7.1 with `payout_id`, `attempt_seq`,
`compensation_settlement_id`, `reason`, `actor=operator_key`.

The original orphan row stays `consumed` forever — the in-DB
row records what the runner attempted, the orphan_tx_hash is
forensic evidence, and compensation is a separate
`ledger_payout_ready` row with its own audit trail.

Because there is no re-attempt path post-consume on the
ORIGINAL row, the double-pay class is structurally
eliminated — the runner cannot broadcast a second transfer
for the same original `payout_id` because the row never
returns to `ready`. Compensation transfers happen on a
different `payout_id` with a fresh on-chain nonce.

`POST /admin/payout/record-orphan` request body extends to:

```
{ "payout_id": 123,
  "attempt_seq": 1,
  "operator_resolution": "free-text",
  "compensation_settlement_id": 4567 | null,
  "reason": "free-text" }
```

`compensation_settlement_id` is optional on first call (a
record-only resolution like "provider acknowledged loss; no
compensation") but if non-NULL MUST reference a
`ledger_payout_ready.id` that exists.

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
    payout_bootstrap_complete INTEGER NOT NULL DEFAULT 0 CHECK(payout_bootstrap_complete IN (0,1)),
    bootstrap_completed_at_utc TEXT NULL,
    updated_at_utc           TEXT NOT NULL
);

-- One-way flip: 0 → 1 permitted; 1 → 0 rejected by trigger.
CREATE TRIGGER IF NOT EXISTS trg_prs_bootstrap_one_way
BEFORE UPDATE OF payout_bootstrap_complete ON payout_runner_state
WHEN OLD.payout_bootstrap_complete = 1 AND NEW.payout_bootstrap_complete = 0
BEGIN
    SELECT RAISE(ABORT, 'payout_bootstrap_complete is one-way');
END;

-- Auto-flip on first confirmation. The runner does NOT
-- application-write this — the trigger fires inside the
-- same SQLite transaction that wrote confirmed_at_utc.
CREATE TRIGGER IF NOT EXISTS trg_pa_bootstrap_flip
AFTER UPDATE OF confirmed_at_utc ON payout_attempts
WHEN NEW.confirmed_at_utc IS NOT NULL AND OLD.confirmed_at_utc IS NULL
BEGIN
    UPDATE payout_runner_state
       SET payout_bootstrap_complete = 1,
           bootstrap_completed_at_utc = NEW.confirmed_at_utc,
           updated_at_utc = NEW.confirmed_at_utc
     WHERE id = 1 AND payout_bootstrap_complete = 0;
END;
```

The `payout_bootstrap_complete` flag flips the first time
any `payout_attempts` row reaches `confirmed_at_utc IS NOT
NULL`. The `trg_pa_bootstrap_flip` trigger guarantees
atomicity with the confirmation regardless of which Go code
path UPDATEs the row. The flag gates §4.9 `source='manual'`
funding records (rejected post-flip).

**Trigger-presence assertion (defense against DROP TRIGGER
+ UPDATE bypass).** Both bootstrap triggers (and the
`trg_lpr_terminal_status_guard` trigger from SPEC-005) are
soft DB-side guards — a compromised actor with DB write
access can `DROP TRIGGER` + mutate + `CREATE TRIGGER` to
bypass them. v0.1.4 hardens this by requiring IMPL to
assert trigger presence at runner startup AND at the top
of every cadence cycle:

```sql
SELECT name FROM sqlite_master
 WHERE type = 'trigger'
   AND name IN ('trg_prs_bootstrap_one_way',
                'trg_pa_bootstrap_flip',
                'trg_lpr_terminal_status_guard');
```

If the result set does NOT include all three trigger
names, IMPL MUST emit
`payout_invariant_violation where='trigger missing' detail='<name>'`
per §7.1 and HALT the runner. Operator response is
forensic — investigate why the trigger is missing
(legitimate schema migration vs. compromise) before
re-creating and resuming.

The `last_run_cancel_gas_native_wei` field is observability
only — the cap-check at §4.6 reads from
`SUM(payout_attempts.gas_used_native_wei WHERE
is_cancel_self_transfer = 1 AND broadcast_at_utc >=
now - 24h)` directly, NOT from this column (which would
miss cancel transfers across runs).

### 4.9 Hot-wallet funding records

The `/admin/payout/balance` surface and the §7.4 chain-balance
reconciliation BOTH need an in-DB record of every USDC deposit
into the hot wallet, so they can compute "expected on-chain
balance = (sum of deposits) − (sum of confirmed non-abandoned
non-cancel outflows)". v0.1.2 ships this table inline:

```sql
CREATE TABLE IF NOT EXISTS payout_hot_wallet_funding (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_address       TEXT NOT NULL,
    to_address         TEXT NOT NULL,
    amount_base_units  INTEGER NOT NULL CHECK(amount_base_units > 0),
    tx_hash            TEXT NOT NULL,
    block_number       INTEGER NOT NULL,
    observed_at_utc    TEXT NOT NULL,
    source             TEXT NOT NULL CHECK(source IN ('manual','rpc-confirmed')),
    operator_note      TEXT NULL,
    UNIQUE(tx_hash)
);
CREATE INDEX IF NOT EXISTS idx_phwf_to ON payout_hot_wallet_funding(to_address);
```

`to_address` is the recipient of the inbound USDC transfer
— always equal to `payout.hot_wallet_address` per the
request body validation. The column was added in v0.1.4 to
fix a §7.4 query-vs-schema mismatch where the
chain-balance reconciliation referenced `to_address` but
the schema only had `from_address` (the SENDER), breaking
the negative-drift alarm at runtime.

Records are inserted via:

```
POST /admin/payout/record-funding
Authorization: Bearer <operator_key>
Content-Type: application/json
Idempotency-Key: <opaque>

{ "from_address": "0x...sender of funds...",
  "to_address":   "0x...hot wallet — MUST equal payout.hot_wallet_address...",
  "amount_base_units": 100000000,
  "tx_hash": "0x...funding tx hash...",
  "block_number": 1234567,
  "source": "rpc-confirmed" | "manual",
  "operator_note": "free-text" }

Response:
  201 Created — record inserted; payout_funding_recorded
                event emitted per §7.1.
  400         — missing field / amount_base_units <= 0 /
                to_address != payout.hot_wallet_address.
  409 Conflict — UNIQUE(tx_hash) violation (already recorded).
  422         — receipt verification mismatch (see below).
```

**`source = 'rpc-confirmed'` (ongoing, post-bootstrap):**

IMPL MUST fetch the receipt for `tx_hash` from BOTH RPCs
(§4.4 two-RPC discipline) and REJECT 422
`receipt_mismatch` unless ALL of the following hold on
BOTH receipts:

- `to` field matches the USDC contract address pinned in
  the operator's config.
- The USDC `Transfer` event log within the receipt has
  `from = <request body's from_address>`,
  `to = payout.hot_wallet_address`, `value =
  amount_base_units`.
- `block_number` matches.
- `status` = success.

If EITHER RPC returns a null receipt or
`eth_getTransactionReceipt` returns "not found" (e.g.
the funding tx is older than the RPC's pruning window),
REJECT 422 `receipt_not_available`. The operator MUST
either pick an RPC that retains the receipt or use the
`source='manual'` bootstrap path BEFORE the bootstrap
flag flips.

**`source = 'manual'` (BOOTSTRAP-ONLY):**

The endpoint accepts `source='manual'` ONLY when the
`payout_runner_state.payout_bootstrap_complete` flag is
FALSE. The flag starts FALSE on a fresh deployment and
flips IRREVOCABLY to TRUE the first time any
`payout_attempts` row reaches `confirmed_at_utc IS NOT
NULL`. After the flip, `source='manual'` requests are
REJECTED with 422 `bootstrap_complete`. The flag is
runtime-immutable via the §6.5 hot-reload prohibition;
once flipped, only a fresh database can reset it.

This narrowing closes the operator-key-compromise
fake-funding attack class: the only window where an
attacker can record a non-existent funding tx is the
bootstrap window before the first payout confirms, which
is operator-supervised and naturally short. After
bootstrap, all funding records require BOTH-RPC receipt
match, defeating the inflated-expected-balance attack on
§7.4.

A `payout_funding_recorded` event MUST emit per §7.1.

§7.4 chain-balance reconciliation reads from this table:

```sql
SELECT COALESCE(SUM(amount_base_units), 0) FROM payout_hot_wallet_funding
  WHERE to_address = :hot_wallet
```

versus the on-chain `balanceOf` + the §7.4 outflow query.

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
budget. This is INTENTIONAL: a malicious operator-key holder
burning the day cap via cancels (DoS against legitimate
payouts, but no fund drain) is bounded by the §4.6
runtime-immutable abandon caps; with those caps loaded at
startup-only, the worst-case starvation is bounded by the
configured `cancel_max_gas_native_wei_per_24h` + abandon
rate-limit, both of which a compromised operator-key holder
cannot escalate without process restart visibility.

Both sides are in USDC base units; no unit conversion. The
upper bound `<= :now` defeats clock-skew under-counting.

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
  "cancel_gas_native_wei_24h": 0,
  "cancel_gas_native_wei_total": 0,
  "cumulative_funding_usdc_base_units": 100000000,
  "as_of_block": 1234567,
  "as_of_utc": "2026-..."
}
```

The `cancel_gas_native_wei_24h` field is computed at request
time from `SUM(payout_attempts.gas_used_native_wei WHERE
is_cancel_self_transfer = 1 AND broadcast_at_utc >= now -
24h)`; `_total` sums lifetime. The per-run
`last_run_cancel_gas_native_wei` field on
`payout_runner_state` is observability only and is NOT
used for cap-checks (it would miss multi-run drain
attacks).

`cumulative_funding_usdc_base_units` is the §4.9
`SUM(payout_hot_wallet_funding.amount_base_units WHERE
to_address = hot_wallet)` (recipient column).

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

**Runtime OS:** v0.1.2 SUPPORTS LINUX ONLY for the runner
process. macOS dev environments are EXPLICITLY FORBIDDEN
because (a) macOS Crashreporter writes diagnostic reports
to `~/Library/Logs/DiagnosticReports/` regardless of
`RLIMIT_CORE`, and (b) per
[[macprovider-launchd-amfi-blocker-macos-26]] macOS is the
provider-side dev surface only — the coordinator + payout
runner live on Pearl Linux. IMPL MUST refuse to start the
runner on `runtime.GOOS != "linux"`.

Process hardening REQUIRED at startup:

- `setrlimit(RLIMIT_CORE, 0)` — disables core dumps from
  the kernel side.
- `prctl(PR_SET_DUMPABLE, 0)` — prevents ptrace-attached
  debuggers from reading process memory by the same uid.
- **systemd-coredump bypass check.** Modern systemd-Linux
  configures `kernel.core_pattern` as
  `|/lib/systemd/systemd-coredump`. The kernel pipes cores
  to systemd BEFORE `RLIMIT_CORE` is consulted in many
  configurations. IMPL startup self-test MUST verify:
  `cat /proc/sys/kernel/core_pattern` MUST NOT start with
  `|` AND MUST NOT contain `systemd-coredump`. Fail-loud
  otherwise. Operators who use systemd-coredump MUST override
  `kernel.core_pattern` at the runner host via sysctl (e.g.
  `kernel.core_pattern = core.%p`) — simpler and harder to
  misconfigure than per-unit `Coredump=no`. The "check unit
  for Coredump=no" alternative was dropped in v0.1.3 because
  it required brittle systemd introspection AND the per-PID
  `coredumpctl` check was trivially zero at process startup.
- `mlock` (or `mlockall(MCL_CURRENT|MCL_FUTURE)`) on the
  decrypted key bytes; the return code MUST be checked and
  the process MUST fail-loud on `EPERM` / `ENOMEM` —
  silent fall-back to unpinned memory is FORBIDDEN. IMPL
  MUST add a test asserting `/proc/self/status` shows
  `VmLck` ≥ keysize.
- The coordinator process MUST run as a dedicated uid with
  no login shell; the env-var path (`/proc/<pid>/environ`
  is readable by same-uid processes) is closed by
  same-uid-isolation.

The wallet signing key is decrypted in process memory on
startup and held for the runner's lifetime. The plaintext
MUST NEVER be persisted to disk by the coordinator. The KEK
plaintext MUST NEVER be persisted to disk either.

Signing happens via the package-internal `Signer` interface
defined in `payout/signer.go`. v0.1.2 ships ONE
implementation: the local-file signer described above. The
`Signer` interface is the seam for the v0.2 KMS swap (§6.6);
the §4.3 step 5 sequence is unchanged under v0.2 because the
signed envelope is still received synchronously from the
signer before persistence + broadcast.

The chain-level `nonce` is the idempotency token; the
signed envelope is persisted to `payout_attempts.raw_signed_tx`
BEFORE broadcast (§4.3 step 5) and re-broadcast bit-for-bit
on retry. RFC 6979 deterministic ECDSA is RECOMMENDED for
general ECDSA-nonce-reuse hygiene but is NOT load-bearing
for SPEC-016's idempotency guarantee.

### 6.3.1 Signer interface contract

The package-internal interface in `payout/signer.go` MUST
expose at minimum:

```go
type Signer interface {
    // FromAddress returns the EIP-55-checksummed Ethereum
    // address of the signing key. MUST return the same
    // value for the signer's lifetime.
    FromAddress() string

    // SignTx signs an unsigned EIP-1559 transaction envelope
    // and returns (rawSignedTx, txHash). MUST NOT broadcast.
    //
    // unsignedTxBytes format: EIP-2718 type-prefixed RLP-
    // encoded unsigned EIP-1559 transaction (txType 0x02)
    // with empty signature fields (V, R, S = 0). I.e. the
    // exact bytes that, when keccak256-hashed and signed,
    // produce the signing-hash for an EIP-1559 tx. KMS
    // implementations that require a 32-byte digest input
    // MUST keccak256 the unsignedTxBytes themselves; the
    // SPEC-016 caller does NOT pre-hash.
    //
    // For the same input bytes called twice, the
    // implementation SHOULD return identical output bytes
    // (deterministic ECDSA via RFC 6979) but SPEC-016
    // does NOT depend on determinism for idempotency —
    // the chain-level nonce + raw_signed_tx persistence
    // (§4.3 step 5) is the actual guarantee. ctx supports
    // cancellation; KMS implementations MAY block on a
    // network call; local-file implementations MUST NOT
    // block longer than 100ms.
    SignTx(ctx context.Context, unsignedTxBytes []byte) (rawSignedTx []byte, txHash string, err error)
}

// EIP-712 signature verification (§3.2 step 5) uses ecrecover
// — a public-key operation. It does NOT invoke the Signer
// interface, because verification does not require the
// hot-wallet private key. The Signer interface MUST NOT
// expose any sign-arbitrary-message primitive at v0.1.3
// (footgun: would let a future code path sign anything with
// the hot-wallet key). v0.2 MAY add `SignMessage` on a
// SEPARATELY-keyed signer when an actual production caller
// emerges.
```

Error semantics:

- A nil `err` REQUIRES non-nil `rawSignedTx` AND non-empty
  `txHash`. The runner treats partial returns as a
  protocol violation and panics in tests / fail-loud in
  production.
- `ctx.Err() != nil` paths return `err = ctx.Err()`; the
  runner treats this as transient and retries at the next
  cadence cycle.
- "Wrong chain id" / "key unavailable" / "policy refused
  (KMS)" MUST return a typed error that the runner can
  distinguish from transient — these halt the runner and
  page the operator (`payout_signer_unavailable` per §7.1).
- The implementation MUST NOT log, print, or return the
  signing key in any error path. IMPL audit MUST include
  a regression test asserting this.

The v0.2 KMS substitution implements this exact interface;
no §4.3 step 5 change is required because the synchronous
return contract is preserved.

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
5. **All registered providers MUST re-register their payout
   address against the new hot wallet.** The EIP-712
   `verifyingContract` field in §3.2 step 5 pins to
   `payout.hot_wallet_address` — rotating the hot wallet
   invalidates every prior signature's typed-data hash.
   The runner's §4.3 step 1 SELECT filters
   `ppa.registered_against_hot_wallet =
   payout.hot_wallet_address`, so post-rotation rows
   registered against the old wallet are SKIPPED until
   re-registration. Operator MUST notify every provider via
   the §9.5a channel (manual email/webhook process) within
   the rotation runbook. Until each provider re-registers,
   their `ledger_payout_ready` backlog accumulates with
   `status='ready'` — not lost, but unpaid.

A future v0.2 MAY add in-process rotation + automatic
provider notification.

### 6.5 Config namespaces: security (immutable) vs tuning (hot-reloadable)

`payout.*` config splits into TWO namespaces with distinct
hot-reload semantics:

**`payout.security.*` — RUNTIME-IMMUTABLE.** Loaded only
at process start; SIGHUP / fsnotify / runtime-debug-endpoint
reload is FORBIDDEN. Keys:

- `payout.security.hot_wallet_address`
- `payout.security.rpc_url_primary` /
  `payout.security.rpc_url_secondary`
- `payout.security.per_payout_cap_usdc_base_units`
- `payout.security.per_day_cap_usdc_base_units`
- `payout.security.cancel_max_tip_multiplier`
- `payout.security.cancel_max_gas_native_wei`
- `payout.security.cancel_max_gas_native_wei_per_24h`
- `payout.security.abandon_rate_per_hour`
- `payout.security.chain_recon_interval`
- `payout.security.chain_recon_tolerance_usdc_base_units`

These defend against an operator-key-compromised attacker
who could otherwise hot-edit `coordinator.toml` to silence
the §7.4 drift alarm, inflate the cancel-gas budget, or
redirect outflows. Mutating ANY of these in
`coordinator.toml` post-start has NO effect until restart;
IMPL test required.

**`payout.tuning.*` — HOT-RELOADABLE.** Operator MAY
mutate + SIGHUP without restart; the runner re-reads on
the next cadence cycle. Each successful reload emits
`payout_config_reloaded` per §7.1 with the key + old + new
values for operator audit trail. Keys:

- `payout.tuning.run_interval`
- `payout.tuning.confirmation_blocks`
- `payout.tuning.low_balance_threshold`
- `payout.tuning.low_native_threshold`
- `payout.tuning.address_cooling_off_period`
- `payout.tuning.run_now_min_interval`
- `payout.tuning.rpc_url_primary_pin_spki` /
  `payout.tuning.rpc_url_secondary_pin_spki` (cert pinning
  hash is operational hygiene, not security-critical: cert
  rotation by the RPC provider is the legitimate hot-reload
  case)
- `payout.tuning.max_rows_per_run`

Splitting the namespace gives operators tuning headroom
(adjust `confirmation_blocks` after observing first-month
drift patterns without dropping the live money path)
while preserving the security-namespace's threat-model
guarantees against operator-key compromise.

The non-`payout.*` namespace (SPEC-005 / SPEC-014 / SPEC-006
keys) is unaffected by this rule and follows its own
discipline.

### 6.6 KMS / HSM (forward pointer, not normative)

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
| `payout_chain_balance_drift_positive` | `from_address, in_db_expected_usdc_base_units, on_chain_usdc_base_units, drift_usdc_base_units, ts_utc` |
| `payout_chain_balance_drift_negative` (severity=PAGE) | `from_address, in_db_expected_usdc_base_units, on_chain_usdc_base_units, drift_usdc_base_units, ts_utc` |
| `payout_nonce_cold_start_within_tolerance` | `from_address, rpc_a_nonce, rpc_b_nonce, chosen_nonce, ts_utc` |
| `payout_config_reloaded` | `key (payout.tuning.* only), old_value, new_value, actor, ts_utc` |
| `payout_nonce_gap` | `from_address, expected_nonce, observed_pending_nonce, ts_utc` |
| `payout_attempt_abandoned` (severity=PAGE) | `payout_id, attempt_seq, nonce, cancel_self_transfer_tx_hash, cap_applied, reason, actor=operator_key, ts_utc` |
| `payout_reorg_orphan_recorded` | `payout_id, attempt_seq, orphan_tx_hash, operator_resolution, compensation_settlement_id, reason, actor=operator_key, ts_utc` |
| `payout_reorg_compensation_recorded` | `payout_id, attempt_seq, compensation_settlement_id, reason, actor=operator_key, ts_utc` |
| `payout_funding_recorded` | `from_address, amount_base_units, tx_hash, block_number, source, operator_note, actor=operator_key, ts_utc` |
| `payout_balance_queried` | `from_address, actor=operator_key, ts_utc` |
| `payout_allowed_changed` | `provider_id, old_allowed, new_allowed, reason, actor=operator_key, ts_utc` |
| `payout_signer_unavailable` | `from_address, error_class, ts_utc` |
| `payout_invariant_violation` | `where, detail, ts_utc` |
| `provider_payout_address_changed` | per §3.4 |
| `provider_payout_address_change_rejected` | `reason, provider_id, src_ip, submitted_fingerprint, ts_utc` |
| `provider_payout_address_rejected_unknown_provider` | `provider_id, submitted_fingerprint, src_ip, ts_utc` |

### 7.1.1 Where these events live

All events listed above are JOURNALCTL-only at v0.1.2 (zerolog
to stdout, captured by systemd-journald, archived per the
existing pipeline + BetterStack filter §9.6). SQL-side
promotion of `payout_chain_balance_drift`,
`payout_rpc_disagreement`, `payout_signer_unavailable`, and
`payout_invariant_violation` to the existing audit-store
schema (`phase4-coordinator/internal/audit/store.go`, which
already has `receipt_rotation` + `swap_event`) is a SPEC-016
v0.2 candidate (Appendix B) — deferred because the journalctl
path is sufficient for the v0.1 alert workflow.

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
`payout.chain_recon_interval`, default **1h**) query the
USDC contract's
on-chain `balanceOf(hot_wallet)` from BOTH RPCs and
compare against the in-DB expected balance:

```sql
-- expected_balance = total_funded - total_paid_out
-- Cancel self-transfers (is_cancel_self_transfer=1) move
-- 1 base unit hot→hot (net-zero on-chain), so they MUST be
-- excluded from outflow; including them would slowly drift
-- expected below on_chain producing false drift alerts.
SELECT
  (SELECT COALESCE(SUM(amount_base_units), 0)
     FROM payout_hot_wallet_funding
    WHERE to_address = :hot_wallet)
  -
  (SELECT COALESCE(SUM(amount_base_units), 0)
     FROM payout_attempts
    WHERE confirmed_at_utc IS NOT NULL
      AND abandoned_at_utc IS NULL
      AND is_cancel_self_transfer = 0
      AND from_address = :hot_wallet);
```

When `|on_chain_balance − expected_balance| >
payout.chain_recon_tolerance_usdc_base_units` (default
`100_000` == $0.10), emit a SIGNED drift event per §7.1
and HALT the runner. The sign matters:

- `on_chain − expected > tolerance` →
  `payout_chain_balance_drift_positive` (operator likely
  forgot to record a funding deposit; benign default).
- `on_chain − expected < -tolerance` →
  `payout_chain_balance_drift_negative` (severity=PAGE;
  runbook: "POSSIBLE FAKE FUNDING RECORD — in-DB
  cumulative funding exceeds on-chain balance; cross-check
  basescan for every `source='manual'` row inserted during
  bootstrap"). Negative drift is the signature of the
  operator-key-compromise fake-funding attack class.

Both RPCs MUST agree on `balanceOf(hot_wallet)` within the
same tolerance; RPC disagreement triggers
`payout_rpc_disagreement` instead.

The §4.9 `payout_hot_wallet_funding` table is the ground
truth for the funding side; if the operator forgets to
record a deposit, the positive-drift alert fires (benign
default interpretation).

Reconciliation also surfaces stale orphans:

```sql
-- (A) Orphans unresolved >30d signal compensation neglect /
-- favoritism. Operator must either resolve with a
-- compensation_settlement_id or document
-- operator_resolution as 'no compensation'.
SELECT id, payout_id, attempt_seq, orphan_tx_hash, observed_at_utc
  FROM payout_reorg_orphans
 WHERE resolved_at_utc IS NULL
   AND observed_at_utc < :now_minus_30d;

-- (B) Compensation FORGERY detection — any orphan whose
-- compensation_settlement_id references a row that no longer
-- exists. Hand-edit / silent delete signal.
SELECT pro.id, pro.payout_id, pro.attempt_seq, pro.compensation_settlement_id
  FROM payout_reorg_orphans pro
 WHERE pro.compensation_settlement_id IS NOT NULL
   AND pro.compensation_settlement_id NOT IN
       (SELECT id FROM ledger_payout_ready);

-- (C) Detect ledger_payout_ready rows whose idempotency_key
-- matches the reorg_compensation:* pattern (created via the
-- SPEC-005 admin endpoint) but have no corresponding orphan
-- row linking back. Fake-compensation signal.
SELECT lpr.id, lpr.provider_id, lpr.idempotency_key, lpr.gross_credits
  FROM ledger_payout_ready lpr
 WHERE lpr.idempotency_key LIKE 'reorg_compensation:%'
   AND lpr.id NOT IN
       (SELECT compensation_settlement_id FROM payout_reorg_orphans
         WHERE compensation_settlement_id IS NOT NULL);
```

Any row returned by (B) or (C) is a SECURITY incident: the
operator MUST investigate whether an operator-key compromise
or DB hand-edit produced an off-the-books compensation. The
queries are intentionally read-only — the SPEC does NOT
auto-remediate; operator judgment is the response gate.

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
   registration + payout history. IMPL MAY ship the
   registration ENDPOINT before SPEC-014 v0.9 if the operator
   uses `curl` for the initial provider set. Constraints on
   the curl path:

   - The EIP-712 signature (§3.2 step 5) MUST be produced by
     the PROVIDER, not the operator. The provider runs e.g.
     `cast wallet sign` against their own private key,
     produces the signature, and sends it to the operator
     out-of-band (email, signal, secure channel). The operator
     MUST NEVER touch the provider's private key — doing so
     subverts the entire proof-of-possession threat model.
   - The operator's curl command relays the provider-produced
     signature in the POST body verbatim; no signing happens
     operator-side.
   This part of item 5 is SOFT.

5a. **Manual provider-notification channel HARD prerequisite.**
   The §3.3 cooling-off banner is the legitimate-provider's
   out-of-band notice that an unexpected rotation happened.
   Without SPEC-014 v0.9's portal banner, that signal does
   not reach the provider. IMPL MUST NOT ship without the
   operator having a documented manual notification process
   (email or webhook to the provider) that fires on every
   `provider_payout_address_changed` event until SPEC-014
   v0.9 lands. The §3.2 EIP-712 proof-of-possession defeats
   most of the C2 threat class but does NOT defeat the case
   where a provider's wallet itself is compromised — the
   notification is the human-in-the-loop backstop.

5b. **SPEC-005 vX.Y+1 `POST /admin/ledger/payout-ready`
   admin endpoint — HARD PREREQUISITE.** v0.1.2 marked this
   as SOFT with a manual SQL fallback; the v0.1.2 manual SQL
   recipe was non-executable (omitted required columns + had
   a `UNIQUE(provider_id, window_start_utc, window_end_utc)`
   collision risk). v0.1.3 REMOVES the manual SQL fallback
   entirely. IMPL MUST NOT ship the payout runner without
   SPEC-005 vX.Y+1 also shipping the admin endpoint; the
   §4.7 reorg-compensation flow has no other safe path.

   **§9.5b.1 — Normative SPEC-005 vX.Y+1 contract surface
   required by SPEC-016.** SPEC-005 author can implement
   cold against this contract without consulting SPEC-016:

   ```
   POST /admin/ledger/payout-ready
   Authorization: Bearer <operator_key>
   Content-Type: application/json
   Idempotency-Key: <opaque>

   { "provider_id":      "<provider id>",
     "gross_credits":    <int>,
     "provider_credits": <int>,
     "operator_credits": 0,
     "cadence_days":     1,
     "source_credit_count": 1,
     "min_payout_credits_override": 0,
     "idempotency_key":  "reorg_compensation:<orig_payout_id>:<orig_attempt_seq>",
     "window_start_utc": "<RFC3339Nano synthetic — orphan observation time>",
     "window_end_utc":   "<RFC3339Nano synthetic — orphan observation time + 1µs * orphan_id>",
     "reason":           "<free-text required>" }

   Response:
     201 Created — { "payout_id": <int> } — fresh
                   ledger_payout_ready row inserted with
                   status='ready', payout_currency=NULL,
                   payout_external_id=NULL.
     400         — missing required field, or
                   idempotency_key does not match
                   `^reorg_compensation:\d+:\d+$`.
     409 Conflict — Idempotency-Key replay (return the
                   original 201 response body).
     422         — provider_id not found in provider_tokens,
                   OR provider_credits > gross_credits.
   ```

   Normative requirements on the SPEC-005 IMPL:

   - The endpoint MUST honor the `min_payout_credits_override:
     0` field by inserting `min_payout_credits = 0` on the
     row, bypassing the SPEC-005 §5 minimum threshold. The
     orphan being compensated already cleared the threshold
     at original-payment time; the compensation MUST NOT
     re-test it.
   - The endpoint MUST NOT trigger a fresh settlement run.
     The row is inserted directly into
     `ledger_payout_ready`, not into
     `ledger_request_credits`. There is no `settlement_id`
     linkage on the underlying request rows because the
     compensation is operator-funded out of band, not
     accrual-funded.
   - The `idempotency_key` MUST use the exact prefix
     `reorg_compensation:` — SPEC-016 §7.4 reconciliation
     query (C) LIKE-matches this prefix to detect
     compensation rows without a corresponding
     `payout_reorg_orphans` entry.
   - The `window_start_utc` / `window_end_utc` are
     SYNTHETIC values used to satisfy SPEC-005's
     `UNIQUE(provider_id, window_start_utc, window_end_utc)`
     constraint. The `+ 1µs * orphan_id` offset on the end
     prevents collision when multiple orphans for the same
     provider are observed in the same nanosecond.
   - Every successful invocation MUST emit a SPEC-005
     structured log event
     `ledger_payout_ready_admin_inserted` with
     `provider_id, payout_id, idempotency_key, reason,
     actor=operator_key, ts_utc` so the operator audit
     trail covers admin-inserted rows separately from
     settlement-emitted rows.
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

Without items 1, 2, 3, 4, 5a, 5b, 6, 7, 8 (item 5 itself
is the only soft prerequisite), IMPL is blocked.

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
  implementation (§6.6, satisfying the §6.3.1 interface
  contract unchanged); auto-split of over-cap payouts
  (§5.2); RPC fallback rotation (v0.1.x requires TWO RPCs
  in agreement; v0.2 MAY add N-of-M voting); in-process
  key rotation (§6.4); automated nonce-gap fill (§4.6,
  replacing the operator-driven
  `/admin/payout/abandon-attempt` flow); collapse
  `/providers/{id}/earnings` and `/providers/{id}/payouts`
  into one endpoint with a versioned schema; SQL-side
  promotion of journalctl-only events
  (`payout_chain_balance_drift`, `payout_rpc_disagreement`,
  `payout_signer_unavailable`, `payout_invariant_violation`)
  into `phase4-coordinator/internal/audit/store.go`. NOTE:
  `/admin/payout/abandon-attempt` (§4.6),
  `/admin/payout/record-orphan` (§4.7), and
  `/admin/payout/record-funding` (§4.9) are IN-SCOPE for
  v0.1.x; the earlier-draft `/admin/payout/void`
  status-mutating endpoint was removed in v0.1.1.
- SPEC-005 vX.Y+1 candidate (HARD §9.5b prerequisite):
  add a `POST /admin/ledger/payout-ready` operator-key admin
  endpoint that inserts a fresh `ledger_payout_ready` row,
  to replace the §4.7 manual SQL compensation procedure
  with a structurally-audited admin surface. **Normative
  contract surface is pinned in §9.5b.1; SPEC-005 author
  can implement cold against it.**
- SPEC-005 v0.4 + SPEC-014 v0.9 cross-reference candidate:
  add a one-line normative note to SPEC-005 §10 and
  SPEC-014 §0 along the lines of "**SPEC-016 Linux-only
  constraint.** If the operator enables `payout.enabled=true`
  per SPEC-016 §2, this entire coordinator process inherits
  the Linux-only requirement from SPEC-016 §6.3." This
  surfaces the Linux-only transitivity to readers of those
  specs who never read SPEC-016.
