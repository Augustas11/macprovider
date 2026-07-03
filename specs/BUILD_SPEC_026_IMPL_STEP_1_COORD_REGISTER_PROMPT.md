# BUILD_SPEC — SPEC-026 IMPL Step 1: Coordinator `/v1/providers/register`

Implement the App-track register endpoint end-to-end per SPEC-026 v0.11 §4.1.
This PR's scope is **coordinator-only**; the Swift App-side sits in a
sibling PR (`feat/spec-026-app-onboarding-impl`).

## Source of truth

- `specs/SPEC-026-browserless-provider-onboarding.md` v0.11 (audit-loop
  converged R1..R10 + Claude critic + designer passes)
- SPEC-026 §4.1 lines ~700-810 for the endpoint contract
- SPEC-026 §10 Phase 1a for the migration list
- SPEC-026 §5.3 for App Attest clientDataHash binding
- SPEC-026 §4.3 for `provider_auth_policy` semantics (auth policy read
  path lands here since /register writes rows for future WS auth)

## Scope in this PR

**IN:**

1. **Migration `006_spec_026_identity.up.sql`** — scaffold committed;
   verify SQL is correct against Postgres 14+, add `.down.sql` mirror.
2. **`phase4-coordinator/internal/onboarding/apptrack.go`** — scaffold
   committed. Fill in `HandleAppTrackRegister` per the 10 ordered steps
   in the file's IMPLEMENTER note.
3. **Store implementations** for `StatsDB` and `AuthTokenStore`
   interfaces. `StatsDB` lives in
   `phase4-coordinator/internal/onboarding/store_pg.go`;
   `AuthTokenStore` extends the existing
   `phase4-coordinator/internal/auth/tokens.go` store with
   `MintProviderTokenAppTrack`.
4. **JCS parity fixture** at
   `phase4-coordinator/test/jcs_fixtures/spec026_register.json` — both
   the Go coordinator side and the Swift App-track side MUST canonicalize
   the same request body to the same bytes. Include ≥ 5 rows: minimal,
   with app_attest present, with unicode in `chip`, with nested
   `hardware_summary`, and a signature-stripped variant.
5. **Rate-limit metrics wiring** — `provider_register_rate_limit_hits{scope}`
   and `provider_register_source{track}` per SPEC-026 §10 step 6. Existing
   `providerhttp` metrics package likely holds the Prometheus registry;
   plug into it.
6. **HTTP handler registration** — wire `HandleAppTrackRegister` onto the
   coordinator's public buyer-side (probably `providerhttp` or a new
   route in the main mux). Confirm which mux by grep for existing
   provider-token-adjacent endpoints.
7. **Nonce replay cache** — implement `StatsDB.InsertRegisterNonce` with
   65s TTL. Use Postgres UNIQUE constraint on
   `(provider_id, nonce, ts_utc_bucket)` where `ts_utc_bucket` is
   `date_trunc('minute', ts_utc)` to keep the index small. Also add a
   `(source_ip, nonce)` cache with the same TTL per SPEC-026 §4.1 step 3.
8. **App Attest verification** — verify against Apple App Attest CA root
   using the `clientDataHash` binding from SPEC-026 §5.3. Bounded CBOR
   parse (max depth 8, max elements 128) with 2s timeout. Reject
   cross-`provider_id` `app_attest_key_id` reuse with 409.
9. **Tests** — HTTP-level table tests for all 10 ordered steps' happy +
   error paths. Include AC-026-05 (409 CONFLICT on TOFU),
   AC-026-11 (App Attest replay rejection), AC-026-13 (JCS parity),
   AC-026-16 (bearer proof for duplicate register). AC list is in
   SPEC-026 v0.11 §12 lines ~2020-2110.

**OUT (this PR does NOT touch):**

- WS proof-stage `identity_signature` verification (SPEC-026 §4.3).
  Lands in a follow-up PR when `provider_auth_policy` gets its cutover
  seeding populated. Phase 1a migrations create the empty table; the
  seed job is Phase 1b at cutover time.
- Provider payout-address binding (SPEC-016 §3 unchanged; App-track
  UI plug-in is separate).
- Email out-of-band cancellation channel (SPEC-027 owns).
- MALIBU rewards emission ledger (SPEC-028 owns).
- `provider_wallet_swaps` state machine (SPEC-016 §3 addendum owns).
- Any `phase3-binary/app/` Swift changes.

## Audit-loop discipline

Per repo standing rule ([feedback-build-audit-loop]) this PR ships
behind 3-lane codex audit converged to 0/0/0 C/H/M:

1. Write initial implementation per the ordered steps above.
2. Fire `omc ask codex "$(cat AUDIT_SPEC_026_IMPL_STEP_1_CODE_AUDIT_PROMPT.md)"`
   + SECURITY + ARCHITECT lane prompts (write them into
   `specs/AUDIT_SPEC_026_IMPL_STEP_1_*_AUDIT_PROMPT.md` per
   [feedback-audit-prompts-file-not-chat]).
3. Fix findings, re-fire until convergence (skip accepted lanes per
   [feedback-skip-accepted-audit-lanes]).
4. Bundle audit narrative into `specs/SPEC-026-IMPL-STEP-1-audit.md`
   per [feedback-spec-audit-file-convention].

## Key constraints from SPEC-026 v0.11

- **Two-DB atomicity in step 7 mint.** `provider_identities` (Postgres,
  new) and `provider_tokens` (SQLite, existing) are separate DBs. The
  mint transaction can't be a single database transaction. Pattern:
  write to `provider_identities` in Postgres first (TOFU-safe with the
  PRIMARY KEY constraint); if that succeeds, mint into SQLite
  `provider_tokens` with `provider_name = "malibu-app"`. If the SQLite
  step fails, leave the Postgres row (retry-safe: the same
  identity_pubkey will find the same row and proceed to mint). If the
  Postgres row exists with a different identity_pubkey, reject 409
  before touching SQLite. Document this compensating-transaction shape
  in code comments; the AUDIT prompt should ask codex to verify
  no-lost-write scenarios.
- **`current_token_proof` for last_used_at IS NOT NULL rows.** Two
  paths per SPEC-026 §4.1: HTTP `Authorization: Bearer` header OR
  `current_provider_token` field in the JSON body. Coordinator
  SHA-256s the provided cleartext and compares against `token_hash`.
  Do NOT log the cleartext.
- **`provider_name = "malibu-app"`** hardcoded literal for App-track
  mints per SPEC-026 §4.1 step 7 (v0.11 addition, critic-Minor-1
  promoted).
- **Base32 alphabet must match Swift.** `Base32AlphabetLowercase =
  "abcdefghijklmnopqrstuvwxyz234567"`. No padding.

## Reference

- SPEC-026 lock record: PR #339 (`feat/onboarding-v2-provider-identity`,
  target base for this PR)
- Adjacent locked SPECs: SPEC-001 v1.6, SPEC-003, SPEC-015 v0.3.3,
  SPEC-016 v1.0.1, SPEC-023
- Existing SQLite auth store: `phase4-coordinator/internal/auth/tokens.go`
- Existing Postgres stats migrations: `phase4-coordinator/internal/stats/migrations/`
- Existing rate-limit infrastructure: `phase4-coordinator/internal/providerhttp/`
  (grep to confirm)

## Definition of done

- CI green on both `phase4-coordinator (go vet + test)` and
  `phase4-coordinator (stats Postgres AC-9/10/19/20)` and
  `phase4-coordinator (golangci-lint depguard AC-16)`.
- All AC-026-XX tests that touch coord surface pass:
  - AC-026-05 (409 TOFU)
  - AC-026-11 (App Attest replay rejection)
  - AC-026-13 (JCS parity)
  - AC-026-16 (bearer proof duplicate register)
- 3-lane codex audit at 0 CRITICAL / 0 HIGH / 0 MEDIUM per
  [feedback-build-audit-loop].
- SPEC-026 §10 checklist step 1 (Phase 1a schema deploy) can proceed
  in production.
