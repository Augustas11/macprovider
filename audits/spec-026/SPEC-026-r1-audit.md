# SPEC-026 R1 — 3-lane codex audit results and R2 dispositions

Round 1 fired three independent codex lanes against `specs/SPEC-026-browserless-provider-onboarding.md`
v0.1 (commit `340d5db`) with prompt files:

- `SPEC-026-r1-code-audit-prompt.md`
- `SPEC-026-r1-security-audit-prompt.md`
- `SPEC-026-r1-architect-audit-prompt.md`

## R1 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | 0 | 2 | 7 | 0 | 0 |
| SECURITY  | 1 | 5 | 3 | 1 | 2 |
| ARCHITECT | 0 | 2 | 6 | 2 | 1 |
| **Combined** | **1** | **9** | **16** | **3** | **3** |

Merge gate is 0 CRITICAL / 0 HIGH / 0 MEDIUM. v0.2 rewrites the spec to
close every C/H/M finding.

## Convergent themes across lanes (all three flagged the same thing)

1. **Payout binding contradicts SPEC-016.** Architect ARCH-1 (HIGH) +
   Code M9 (Entry 102 drift) + Security SEC-5 (HIGH). SPEC-016 §3
   already defines `POST /providers/{provider_id}/payout-address` with
   EIP-712 wallet proof-of-possession + `provider_payout_addresses`
   table + hot-wallet reconfirm semantics. SPEC-026 v0.1 §4.2 invented a
   parallel Ed25519 identity-signed endpoint that has the same URL but
   incompatible semantics and skips the wallet-owner-consent proof.
   **v0.2 fix:** §4.2 delegates entirely to SPEC-016 §3 unchanged. The
   Ed25519 identity signature only proves the App-track Mac authored the
   wallet-binding request; the wallet EIP-712 signature remains the
   money-path authority per SPEC-016.

2. **Receipt-key reuse strands identity on rotation.** Architect ARCH-2
   (HIGH) + Code M4. SPEC-015 v0.1.3 already ships `macprovider rotate-key`
   with reconnect-based rotation, `receipt_pubkey_prev`, and 60s +
   grace-window semantics. SPEC-026 v0.1 §3.2 derives `provider_id` from
   the same pubkey — every receipt-key rotation would ALSO rotate
   `provider_id`, orphaning FR-C9 tokens, SPEC-016 payout bindings, and
   `settled_receipts` history. **v0.2 fix:** identity key becomes a
   SEPARATE Ed25519 keypair in Keychain slot `provider_identity_v1`
   that is stable-across-migration. Receipt key remains SPEC-015's
   `receipt_key_v1` slot with its existing rotation model.
   `MACPROVIDER_RECEIPT_KEY_RAW` handoff is deleted; the App and CLI
   generate/manage receipt keys via existing SPEC-015 code paths.

3. **`identity_signature` on wrong protocol stage.** Architect ARCH-3
   (MEDIUM). SPEC-001 v1.6 §6.7 puts fresh-connect auth on the v2
   `auth_request` initial-stage frame; legacy `hello` is reconnect /
   backwards-compat only. SPEC-026 v0.1 §4.3 added the field to legacy
   `hello`. **v0.2 fix:** move to v2 `auth_request` initial-stage frame
   as an OPTIONAL field with a stated "required for `p_`-prefixed
   provider_ids from binary v1.9.0" cutover.

4. **App Attest replay across N identities.** Security SEC-2 (CRITICAL).
   v0.1 said "coordinator verifies against Apple root" but never bound
   `clientDataHash` to `provider_id` / `identity_pubkey` / nonce, so one
   captured attestation object replays across unlimited fake identities.
   **v0.2 fix:** normative
   `clientDataHash = SHA256(JCS({provider_id, identity_pubkey, register_nonce, coordinator_domain, bundle_id, team_id, ts_utc}))`;
   coordinator stores `app_attest_key_id` and rejects reuse across
   `provider_id`s; added AC-026-11 for replay rejection.

5. **Bearer-token downgrade attack.** Security SEC-3 (HIGH). Optional
   `identity_signature` means a stolen bearer token grants full
   billable-session authority. **v0.2 fix:** the field is REQUIRED for
   any provider_id starting with `p_`. Coordinator MUST reject
   `p_`-prefixed sessions that omit or invalidate the signature.
   CLI-track (opaque `provider_id`s from FR-C9 legacy) unchanged.

6. **Raw private key exported via env var.** Security SEC-7 (HIGH).
   `MACPROVIDER_RECEIPT_KEY_RAW` in child-process environment is
   visible to `ps eww`, core dumps, and any child spawned by the CLI.
   **v0.2 fix:** dropped entirely (see convergent theme #2). CLI reads
   receipt key from its own Keychain slot as it does today. Identity key
   never leaves the App target's process.

7. **Coordinator "escrow" language.** Architect ARCH-6 (MEDIUM). SPEC-005
   / SPEC-016 already model unpaid earnings as `ledger_payout_ready`
   rows against a `provider_id`, not a per-provider custodial escrow.
   **v0.2 fix:** §9.1 renames "escrow" → "unpaid ledger backlog";
   binds sweep-on-first-bind to SPEC-016's existing batch cycle
   without inventing new accounting.

## Non-convergent but confirmed findings

- **CODE-1 (HIGH):** §7.6 gate weakened from
  `ProviderConfig.isConfigured` → `ProviderIdentity.isReady()`.
  Existing browser-OAuth installs would fall out. **v0.2 fix:** gate is
  `ProviderIdentity.isReady() OR ProviderConfig.isConfigured` — either
  path is a valid launch precondition, matching §8's migration
  invariant.
- **CODE-4 (MEDIUM):** `Curve25519.Signing.PublicKey(privkey)` is not a
  valid CryptoKit initializer. **v0.2 fix:** replaced with
  `privkey.publicKey.rawRepresentation` throughout.
- **CODE-5 (MEDIUM):** RFC 4648 base32 has no lowercase variant.
  **v0.2 fix:** alphabet pinned to
  `abcdefghijklmnopqrstuvwxyz234567` (lowercased RFC 4648 §6 alphabet),
  no padding. Full ID = `p_` + 52 chars = 54 chars total. UI display is
  `p_` + first 8 payload chars = 10 visible chars.
- **CODE-6 (MEDIUM):** JCS library plan. **v0.2 fix:** normative pointer
  to existing `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift`
  (Swift) and `phase4-coordinator/internal/billing/CanonicalJSON` (Go)
  with a required parity-fixture gate in the deploy checklist.
- **CODE-7 (MEDIUM):** `PendingLinkState` deletion misses call sites.
  **v0.2 fix:** §7.3 now enumerates each call site to delete or rewire
  (`OnboardingWindow.swift:55`, `MalibuApp.swift:163`,
  `PendingLinkStateTests.swift`).
- **CODE-8 (MEDIUM):** flag precedence. **v0.2 fix:** env var
  `MALIBU_ONBOARD_V2` wins over `UserDefaults` when both set; §8 pins
  this precedence.
- **CODE-9 (MEDIUM) / ARCH-11 (INFO) / SEC-LOW:** Entry 102 says
  "EIP-712-shaped Ed25519 identity signature" — nonsense phrase, EIP-712
  is a wallet-signature standard, not an Ed25519 encoding. **v0.2 fix:**
  Entry 102 restated: "JCS-canonical Ed25519 identity signature (for
  Mac consent) + SPEC-016 EIP-712 wallet signature (for wallet
  proof-of-possession) at binding time."
- **SEC-1 (HIGH):** sybil economics arithmetic. **v0.2 fix:** provisional
  $MALIBU emissions are NON-WITHDRAWABLE until Trusted unlock; §11
  states the attacker break-even inequality; per-wallet emission cap
  added.
- **SEC-4 (MEDIUM):** nonce replay cache TTL. **v0.2 fix:**
  `(provider_id, nonce)` replay cache TTL ≥ `ts_window + max_skew`
  = 60s + 5s = 65s floor, atomic insert-if-absent, shared-cache-required
  for multi-instance coordinator. Also added `(source_ip, nonce)` cache
  for spam-registration variants.
- **SEC-6 (HIGH):** payout coercion. **v0.2 fix:** §9.3 defers wholly to
  SPEC-016's existing wallet swap flow (which already carries EIP-712
  proof-of-possession + hot-wallet reconfirm). App-track adds an
  out-of-band notification requirement + `pending_wallet_swap` visible
  in menu-bar UI during the cooling window.
- **SEC-8 (MEDIUM):** attestation object DoS. **v0.2 fix:** normative
  8 KiB max body size for `/register`, 4 KiB max for
  `app_attest_object`, bounded CBOR parse, 2s timeout, malformed = 400
  (not `trust.attested=false`).
- **ARCH-3 (MEDIUM):** FR-C9 HTTP caller semantics. **v0.2 fix:** §4.1
  step 7 recasts as "new HTTP token-issuance primitive that shares the
  `provider_tokens` table + one-active-token invariant with FR-C9, but
  runs in its own DB transaction with explicit TOFU-key-conflict `409`
  semantics." No longer claims "reuse FR-C9 as-is."
- **ARCH-5 (MEDIUM):** migration matrix. **v0.2 fix:** §8 gains a
  4×2 state matrix (`v1-complete`, `v2-partial`, `v2-complete`, `fresh`)
  × (`flag-on`, `flag-off`) with the launch-gate behavior for each
  cell. Rollback path documented.
- **ARCH-7 (MEDIUM):** SPEC-023 stays on-device. **v0.2 fix:** §4.1
  response drops `recommended_model`; §6.1 step 7b runs local
  `macprovider-cli autotune --recommend --json` per SPEC-023 after
  identity is minted. Preserves SPEC-023 signed-catalog + rate-card
  integrity + HMAC-local-identity privacy guarantees.
- **ARCH-8 (MEDIUM):** wallet-balance criterion becomes drainable
  Trusted unlock. **v0.2 fix:** §5.2 criterion #3 requires the balance
  check to pass CONTINUOUSLY (re-queried every 24h); dropping below the
  floor demotes back to Provisional. Also raises the floor from 50 USDC
  to 100 USDC to align with SPEC-016 hot-wallet minimums.
- **ARCH-9 (LOW):** deploy checklist ordering. **v0.2 fix:** §10 is now
  a numbered ordered list, migration → mint → wallet → Attest → metrics
  → App flag.
- **ARCH-10 (LOW):** CLI-track OAuth retirement observability. **v0.2
  fix:** §4.4 adds `provider_register_source{track="app"|"cli"|"portal"}`
  counter and defines retirement trigger at
  `portal.streamvc.live/onboard` traffic < 10 req/day for 14 days.

## LOW/INFO carried forward (documented in v0.2 PR body, not blocking)

- SEC-9 (INFO): buyer-facing provider label homoglyphs — base32 alphabet
  is safe; v0.2 §3.3 adds a note stating buyer UI MUST NOT accept
  user-controlled display names.
- SEC-10 (INFO): ASN rate-limit ceiling. v0.2 §5.1 reframes ASN limits
  as backpressure / abuse-telemetry, not sybil defense.
- ARCH-12 (INFO): "node" appears in §7.4 as replacement targets — fine,
  that's the point. Verified no "node" remains in normative prose.

## R2 plan

- Re-fire all three lanes against SPEC-026 v0.2.
- Skip re-firing any lane that stayed PASS 0/0/0 (per repo rule
  [feedback-skip-accepted-audit-lanes]) — but at R1 no lane cleared, so
  R2 fires all three.
- If R2 lands 0 C/H/M across all three → freeze v0.2 → push → PR ready
  to merge.
- If R2 surfaces new C/H/M (regression from v0.2's larger surface area
  vs v0.1) → R3.
