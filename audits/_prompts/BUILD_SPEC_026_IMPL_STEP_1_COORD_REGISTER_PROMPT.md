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
- SPEC-026 §4.3 for `provider_auth_policy` semantics. `/register`
  MUST NOT insert, update, or seed `provider_auth_policy` rows; Phase
  1a creates the empty table only. Future WS auth treats an absent row
  or `signature_exempt_until IS NULL` as `identity_signature_required`.

## Scope in this PR

**IN:**

1. **Migration `006_spec_026_identity.up.sql`** — scaffold committed;
   verify SQL is correct against Postgres 14+. Add the missing
   `provider_register_nonces` replay-cache table/indexes and
   least-privilege onboarding grants. Add a rollback SQL artifact
   `006_spec_026_identity.down.sql` for operator/runbook use; do not
   wire it into the current migration runner unless this PR also adds
   explicit down-runner support.
2. **`phase4-coordinator/internal/onboarding/apptrack.go`** — scaffold
   committed. Fill in `HandleAppTrackRegister` per the 10 ordered steps
   in the file's IMPLEMENTER note. Update the scaffold contract before
   implementing: add `CurrentProviderToken *string
   json:"current_provider_token,omitempty"` and change
   `StatsDB.InsertRegisterNonce` to accept `sourceIP`.
3. **Store implementations** for `StatsDB` and `AuthTokenStore`
   interfaces. Create `phase4-coordinator/internal/onboarding/store_pg.go`
   for the Postgres onboarding store. Keep HTTP orchestration in
   `internal/onboarding`; extend the existing
   `phase4-coordinator/internal/auth/tokens.go` SQLite store with a
   narrow `MintProviderTokenAppTrack` method that satisfies
   `onboarding.AuthTokenStore`, because the token transaction belongs
   beside `provider_tokens`.
4. **JCS parity fixture** at
   `phase4-coordinator/test/jcs_fixtures/spec026_register.json`.
   This coordinator PR owns the fixture schema and Go
   `billing.CanonicalJSON` parity tests. The sibling Swift App-track PR
   owns loading the same fixture and proving Swift parity. AC-026-13 is
   fully closed only when both PRs pass against the same fixture SHA.
   Include ≥ 5 rows: minimal valid HTTP body, app-attest-present valid
   HTTP body, unicode in `hardware_summary.chip`, a JCS-only nested
   object variant that is not sent to the HTTP struct decoder, and a
   signature-stripped variant.
5. **Rate-limit metrics wiring** — `provider_register_rate_limit_hits{scope}`
   and `provider_register_source{track}` per SPEC-026 §10 step 6. The
   metrics live under `phase4-coordinator/internal/stats/metrics` and are
   registered from `cmd/coordinator/main.go`; add these coordinator-owned
   counters there or split a clearly named coordinator metrics package.
   Create the coordinator Prometheus registry before the stats-enabled
   branch and register `provider_register_*` counters unconditionally.
   Mount the registry on the provider/admin mux at SPEC-026's
   `/admin/metrics` path regardless of `stats.enabled`, but wrap it in
   operator auth before `promhttp.HandlerFor`: accept only
   `cfg.Auth.OperatorKey` via `auth.OperatorOnlyBearerMatches`, reject
   missing/empty operator key, and reject `gateway_service_token`.
   Existing nginx proxies `/admin/` publicly and relies on coordinator
   handlers for auth, so `/admin/metrics` MUST NOT be mounted as a bare
   promhttp handler. Keep `/metrics` as a compatibility alias only if
   existing SPEC-017 tests require it; if the alias remains
   unauthenticated, keep it loopback-only and preserve/extend the
   loopback bind guard. SPEC-017 stats metrics/handlers remain
   conditional on `statsPools != nil`. Add tests with
   `stats.enabled=false` and `stats.enabled=true` proving
   unauthenticated `/admin/metrics` = 401, gateway token = 401,
   operator token = 200 and includes the register counters, and stats
   handlers remain gated.
6. **HTTP handler registration** — wire `HandleAppTrackRegister` onto the
   coordinator's public buyer-side router, not `providerhttp`
   (`providerhttp` is an outbound client). Mount
   `POST /v1/providers/register` on the buyer-port public mux
   (`buyer.Server.Handler()` / port 8443 path) or an explicit top-level
   wrapper around it in `cmd/coordinator/main.go`; document the chosen
   shape in code. Update
   `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf` with
   an exact `location = /v1/providers/register` before the generic
   `/v1/` 404 catch-all and add a route/nginx config test.
7. **Feature gate and runtime Postgres writer seam** — introduce
   `onboarding.app_track_register_enabled` (or equivalent) default
   `false` for backward-compatible binary rollout. When false, do not
   mount `/v1/providers/register`, do not require the onboarding DSN, and
   leave nginx route tests asserting the application route remains absent
   unless enabled. When true, require schema/role smoke, onboarding DSN,
   route mount, nginx route, App-track config, and fail closed before
   listeners bind. `/register` writes to the stats
   Postgres database even when the public stats API is disabled. Add a
   dedicated onboarding runtime role/DSN, e.g.
   `provider_onboarding`, with least-privilege `SELECT/INSERT/UPDATE`
   on `provider_identities` and replay-cache tables only. Add role/grant
   DDL, config fields, validation, pool lifecycle, startup smoke, and
   fail-closed behavior if `/register` is enabled without the onboarding
   DSN.
8. **Nonce replay cache** — implement
   `StatsDB.InsertRegisterNonce(ctx, providerID, sourceIP, nonce string,
   tsUTC time.Time)` with true 65s replay semantics. Add
   `provider_register_nonces` (or two explicit tables) so a single
   Postgres transaction atomically rejects both duplicate
   `(provider_id, nonce)` and duplicate `(source_ip, nonce)` for the
   same 65s window. Do not rely only on
   `date_trunc('minute', ts_utc)` uniqueness; minute boundaries can miss
   replays inside 65s unless adjacent buckets are checked transactionally.
   Add TTL cleanup or bounded retention.
9. **App Attest verification** — verify against Apple App Attest CA root
   using the `clientDataHash` binding from SPEC-026 §5.3. Bounded CBOR
   parse (max depth 8, max elements 128) with 2s timeout. Reject
   cross-`provider_id` `app_attest_key_id` reuse with 409. Before adding
   CBOR/COSE/App-Attest dependencies, document selected package(s),
   license, maintenance status, and bounded-decoder controls in the
   implementation notes or audit narrative.
   Add an App-track/App-Attest config block with `bundle_id` defaulting
   to `tech.malibu.app`, required env-indirected `apple_team_id` /
   `team_id` when register is enabled, and `coordinator_domain` used in
   the hash. Validate all values at startup and use the same values in
   Go tests/JCS fixtures.
10. **Tests** — HTTP-level table tests for all 10 ordered steps' happy +
   error paths. Include AC-026-05 (409 CONFLICT on TOFU),
   AC-026-11 (App Attest replay rejection), AC-026-13 (JCS parity),
   AC-026-16 (bearer proof for duplicate register). AC list is in
   SPEC-026 v0.11 §12 lines ~2020-2110.

**OUT (this PR does NOT touch):**

- WS proof-stage `identity_signature` verification (SPEC-026 §4.3).
  Lands in a follow-up PR when `provider_auth_policy` gets its cutover
  seeding populated. Phase 1a migrations create the empty table; the
  seed job is Phase 1b at cutover time. Because §10 Phase 1a production
  readiness requires both `/register` and §4.3 proof-stage auth verify,
  this PR may deploy `/register` to production only with
  `onboarding.app_track_register_enabled=false` until the verifier PR
  lands; staging may enable it for endpoint validation.
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
- **`provider_auth_policy` non-write invariant.** `/register` only
  creates/updates `provider_identities` and replay/cache state. It MUST
  NOT create bearer-only exemptions, future exemption rows, or any other
  `provider_auth_policy` row. Phase 1b seeding and operator exemption
  grants are the only paths that populate exemption state.
- **Source IP trust.** Reuse or extract the existing hardened
  trusted-proxy client-IP derivation (`proxy.trusted_proxies`,
  rightmost-untrusted `X-Forwarded-For`, `X-Real-IP` only from trusted
  proxy hops). Ignore client-supplied ASN values. Add an explicit
  `ASNResolver` seam, e.g. `ResolveASN(ctx, netip.Addr) (asn string, ok
  bool, err error)`, backed by config for a local resolver database or
  static mapping; no outbound network calls on the request path. Derive
  ASN server-side from the trusted source IP, bucket lookup misses as a
  deterministic closed value such as `unknown`, and add fake-resolver
  tests for ASN-hit, unknown-ASN, spoofed-XFF/direct-vs-trusted-proxy,
  and ASN-limiter 429 cases.
- **`current_provider_token` for `last_used_at IS NOT NULL` rows.** Two
  paths per SPEC-026 §4.1: HTTP `Authorization: Bearer` header OR
  `current_provider_token` field in the JSON body. Coordinator
  SHA-256s the provided cleartext and compares against `token_hash`.
  The JSON body path is part of the signed JCS object; signature
  verification removes only `signature`, not `current_provider_token`.
  Do NOT log the cleartext.
- **Duplicate-register cooldown.** For same-identity duplicate register
  against an active `last_used_at IS NOT NULL` row, enforce the SPEC-026
  max 1 successful reissue per provider per 5 minutes inside the same
  SQLite `BEGIN IMMEDIATE` transaction that revokes and mints. Add a
  clock/test seam; test first valid proof succeeds, second within 5
  minutes fails without mutation, and a post-cooldown proof succeeds.
- **`provider_name = "malibu-app"`** hardcoded literal for App-track
  mints per SPEC-026 §4.1 step 7 (v0.11 addition, critic-Minor-1
  promoted).
- **Base32 alphabet must match Swift.** `Base32AlphabetLowercase =
  "abcdefghijklmnopqrstuvwxyz234567"`. No padding.
- **App Attest exact binding and fallback.** Re-derive
  `clientDataHash = SHA256(JCS({provider_id, identity_pubkey,
  register_nonce, coordinator_domain, bundle_id, team_id, ts_utc}))`
  with `register_nonce` equal to `/register` `nonce`,
  `coordinator_domain` as bare lowercase host with no scheme/trailing
  slash, `bundle_id` from config defaulting to `tech.malibu.app`,
  `team_id` from required App-track config, and `ts_utc` as unix seconds
  int. `clientDataHash` mismatch, attestation-object keyId mismatch, and
  cross-provider `app_attest_key_id` reuse are replay/binding failures
  and MUST reject (`409` for cross-provider key reuse; deterministic
  `400` for hash/keyId mismatch). Oversized request/body or app-attest
  object returns `413`; malformed CBOR returns `400`; only Apple
  service/network outage or non-replay verification failure after a
  well-formed correctly-bound object falls back to `trust.attested=false`.
- **Secret log hygiene.** Captured logs must never contain
  `provider_token`, `current_provider_token`, Authorization bearer
  values, token hashes, raw 32-byte/64-hex token material, or raw
  attestation CBOR. Log only stable non-secret identifiers and bounded
  token prefixes/fingerprints when needed.

## Reference

- SPEC-026 lock record: PR #339 (`feat/onboarding-v2-provider-identity`,
  target base for this PR)
- Adjacent locked SPECs: SPEC-001 v1.6, SPEC-003, SPEC-015 v0.3.3,
  SPEC-016 v1.0.1, SPEC-023
- Existing SQLite auth store: `phase4-coordinator/internal/auth/tokens.go`
- Existing Postgres stats migrations: `phase4-coordinator/internal/stats/migrations/`
- Existing metrics registry: `phase4-coordinator/internal/stats/metrics`
  and `cmd/coordinator/main.go`
- Existing trusted-proxy source-IP derivation: `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/providerhttp/` is an outbound client; do
  not use it as a mux or metrics home.

## Definition of done

- CI green on both `phase4-coordinator (go vet + test)` and
  `phase4-coordinator (stats Postgres AC-9/10/19/20)` and
  `phase4-coordinator (golangci-lint depguard AC-16)`.
- All AC-026-XX tests that touch coord surface pass:
  - AC-026-05 (409 TOFU)
  - AC-026-11 (App Attest replay rejection)
  - AC-026-13 coordinator side (fixture format + Go JCS parity; sibling
    Swift PR closes full cross-language parity against the same fixture
    SHA)
  - AC-026-16 (bearer proof duplicate register)
- Migration tests updated for `006_spec_026_identity`, schema-shape
  assertions cover SPEC-026 identity/replay/grant objects, and rollback
  SQL existence/drop-order is checked as a runbook artifact.
- Route verification proves `POST /v1/providers/register` is reachable
  through the chosen public buyer-port/nginx path when
  `onboarding.app_track_register_enabled=true`, remains absent when the
  flag is false, and the generic `/v1/` coordinator catch-all remains
  404.
- `/admin/metrics` is mounted on the provider/admin mux regardless of
  `stats.enabled`, is operator-auth gated, rejects gateway-service
  bearer tokens, includes `provider_register_*` counters for authorized
  operators, and preserves any existing loopback-only `/metrics`
  compatibility behavior required by SPEC-017 tests.
- 3-lane codex audit at 0 CRITICAL / 0 HIGH / 0 MEDIUM per
  [feedback-build-audit-loop].
- SPEC-026 §10 checklist step 1 schema deploy can proceed in production;
  full Phase 1a traffic enablement waits until both `/register` and
  §4.3 proof-stage auth verification are present, or `/register` remains
  deployed disabled.
