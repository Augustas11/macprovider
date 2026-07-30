# SPEC-026 R4 — 3-lane codex audit results and R5 dispositions

Round 4 re-fired all three codex lanes against SPEC-026 v0.4.

## R4 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | 0 | 5 | 3 | 0 | 0 |
| SECURITY  | 0 | 1 | 5 | 2 | 1 |
| ARCHITECT | 0 | 1 | 3 | 1 | 0 |
| **Combined R4** | **0** | **7** | **11** | **3** | **1** |

CODE went UP on HIGHs from 0 → 5 due to text-drift between the
targeted patches I applied in v0.4 and the surrounding prose. This
is an editing-hygiene issue, not a design regression.

## HIGHs closed in v0.5

- **CODE-1 (§4.3 `auth_proof` prose drift):** v0.4 fixed the JSON
  example to `type: "auth_request", stage: "proof"` but the
  surrounding paragraph still said "auth_proof". v0.5 sweeps
  every reference to match SPEC-001 v1.6 §6.7 literal, and
  removes `provider_ecdh_public_key` from the proof frame body
  (ECDH is initial-stage-only per SPEC-001).
- **CODE-2 (§4.5 email verification link auth):** v0.4 had the
  email link go to a `GET /notification-channel/verify?token=…`
  route in a browser, but the underlying `POST` required bearer +
  identity signature — a browser can't produce either. v0.5
  changes the email link to a `malibu-app://verify-email?token=…`
  deep-link that opens the App; the App produces the signed
  POST.
- **CODE-3 (§5.1 `amount_usd NOT NULL`):** v0.4 wanted MALIBU-only
  rows with null USD but the existing column is `NOT NULL`. v0.5
  drops the constraint in the same migration; rollback backfills
  nulls with `0.00`.
- **CODE-4 (§8.4 wrong marker filename):** v0.4 used
  `.malibu-owned`; actual `ProviderPaths.appMarkerFile` at
  `ProviderPaths.swift:24` is `.installed-by-app`. v0.5 fixed
  globally.
- **CODE-5 (§8.4 "Import" doesn't satisfy `isConfigured`):** v0.4
  Option A only added the marker file, but
  `ProviderConfig.isConfigured` requires the token in the
  Keychain (not the YAML). v0.5 defines the full SPEC-025 §7
  import contract: parse YAML → save token to Keychain →
  rewrite YAML without token → create marker → verify
  `isConfigured` before dismissing dialog.
- **CODE-6 (§10 step 7 stale wording):** step 7 still said
  `identity_signature_exempt_until` column and `+ 30 days` from
  v0.3. v0.5 rewritten to use `provider_auth_policy.signature_exempt_until`,
  `CUTOVER_TIME + 7 days`, both App and CLI.
- **SEC-1 / ARCH-1 (§4.6 GET mutates state + SPEC-016 has no
  cancel endpoint):** v0.5 splits into `GET
  /wallet-swap/cancel-confirm` (renders confirmation page,
  read-only) + `POST /wallet-swap/cancel` (atomic CAS mutation).
  SPEC-016 addendum called out as required; deploy checklist
  gates on it.
- **SEC-2 (§9.3 channel-authority transfer via wait):** v0.4
  let bearer+identity malware set an email, wait 24h, and own
  the channel. v0.5 requires ONE of: old-email approval OR
  currently-bound-wallet EIP-712 signature OR dual-control
  operator recovery. Time passage alone does NOT transfer
  authority. Fresh install (no old email + no bound wallet) is
  the only exception, and its exposure is bounded by the swap
  fail-closed rule.

## MEDIUMs closed in v0.5

- SEC-M3 (§4.5 email `unset` rate limit): 1-per-7-days now
  applies to `set`, `unset`, `confirm`, AND rejected changes.
- SEC-M4 (§4.5 pending overwrite): v0.5 uses
  `provider_email_change_requests` with immutable
  `pending_change_id`; second `set` while pending returns
  `409 pending_change_active`; no silent overwrite.
- SEC-M5 (§5.2 distinct criteria): v0.5 requires two distinct
  satisfied criterion IDs; one condition cannot satisfy both
  slots.
- SEC-M6 (§5.1 replay atomicity at bind): v0.5 adds
  `cap_replay_pending` flag; withdrawal + Trust promotion
  blocked until replay completes; same aggregate lock as live
  emissions.
- CODE-M4 (§4.6 HMAC verification order): v0.5 loads pending
  swap by `swap_id` FIRST, then computes HMAC over row-loaded
  fields + URL `kid`/`exp` and compares to URL `sig`. Field
  names normalized.
- CODE-M7 (§8.4 "Start fresh" backup path): v0.5 moves the
  file (not directory) to
  `~/.config/macprovider/config.yaml.cli-backup-<timestamp>`
  and documents the exact `macprovider-cli --config
  <backup-file>` reclaim command.
- ARCH-M2 (§10 seeding at cutover): v0.5 splits schema
  migration (Phase 1a, deploys with release) from row seeding
  (Phase 1b, runs at auth-verifier cutover), so the 7-day
  clock anchors from cutover, not from schema deploy.
- ARCH-M3 (§4.3 NULL semantics): v0.5 explicit `IS NULL`
  disjunction in the auth-policy pseudocode.
- ARCH-M4 (§5.1 SERIALIZABLE + Postgres owner): v0.5 pins the
  emission ledger to a dedicated `rewards_writer` Postgres role
  with `default_transaction_isolation = 'serializable'` and
  retry-metrics; SQLite billing/payout isolation unchanged.
- SEC-M2 (§4.3 exemption seeding contradiction): resolved by
  §10 rewrite.
- SEC-M-admin-flow (§4.3 admin exemption single-insider):
  `provider_auth_policy_pending` table with
  `approved_by != requested_by` constraint; cumulative
  renewal cap 30 days per provider_id absent explicit
  break-glass with incident ID.

## LOW/INFO addressed inline

- SEC-L1 (§9.3 email delivery exhaustion indefinite hold): v0.5
  promoted to explicit auto-cancel after retry exhaustion. No
  support-bypass path.
- SEC-L2 (§4.6 single-use enforcement): v0.5 uses atomic CAS on
  swap row state.
- ARCH-L1 (§5.2 E3 operator promotion): v0.5 §11 documents E3
  as manual audited exception, not part of automated
  sybil-economics bound.
- SEC-INFO (rejected-email notification visibility): v0.5 App
  dashboard shows rejected changes.

## R5 plan

- Fire all three lanes against v0.5.
- If R5 lands 0 C/H/M → push v0.5 → PR ready to merge.
- If not, decide between R6 or accept-and-carry-forward on the
  R5 findings after review.
