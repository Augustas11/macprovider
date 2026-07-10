# SPEC-026 R2 — 3-lane codex audit results and R3 dispositions

Round 2 re-fired all three codex lanes against SPEC-026 v0.2 using
the R2 prompts. All three lanes read `SPEC-026-r1-audit.md` first
and were instructed not to re-flag R1 items that v0.2 resolved.

## R2 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | 0 | 1 | 4 | 2 | 0 |
| SECURITY  | 0 | 3 | 6 | 1 | 1 |
| ARCHITECT | 0 | 1 | 4 | 5 | 1 |
| **Combined R2** | **0** | **5** | **14** | **8** | **2** |
| R1 combined (for comparison) | 1 | 9 | 16 | 3 | 3 |

Big drop from R1. Zero CRITICALs. But not at 0/0/0, so v0.3 rewrites
the surfaces below.

## Convergent HIGHs (multi-lane) — must fix in v0.3

1. **§4.3 `identity_signature` timing on `auth_request` is
   unimplementable.** ARCH + SEC both HIGH. SPEC-001 v1.6 §6.7
   issues `auth_attempt_id` in the server's `auth_challenge` frame,
   which is sent AFTER the client's initial `auth_request` frame.
   The client cannot sign a value it hasn't received. **v0.3 fix:**
   move `identity_signature` to the proof-stage frame (client's
   response to `auth_challenge`) with signature over
   `{auth_attempt_id, provider_id, binary_version,
   provider_ecdh_public_key, transcript_hash}`. Update the field
   names to match SPEC-001 v1.6 (`provider_ecdh_public_key`, not
   `ecdh_pubkey`). Bind a transcript hash of the initial frame so
   the proof cannot be replayed against a different initial frame.

## Non-convergent HIGHs

2. **§4.3 client-reported `binary_version` bypass.** SEC HIGH.
   Coordinator trusting a client-declared version to decide auth
   policy means an attacker sends `binary_version="1.7.0"` and gets
   the pre-cutover bearer-only path. **v0.3 fix:** don't gate on
   client-reported version. Introduce a server-side
   `provider_identities.identity_signature_exempt_until` timestamp
   populated ONLY by explicit operator action or by a one-time
   migration for `p_`-prefixed provider_ids that were minted before
   the cutover. Once `now > identity_signature_exempt_until`, or
   for any provider_id not on the exempt list, coordinator MUST
   require `identity_signature`. No client-reported field enters
   the auth policy decision.
3. **§9.3 payout coercion — UNUserNotification is not out-of-band
   from a compromised Mac.** SEC HIGH. If malware has Keychain
   access, it also has UI-notification-suppression capability.
   **v0.3 fix:** OPTIONAL `notification_email` field on
   `provider_identities` (populated by an in-App form after
   onboarding, not required for onboarding to complete). SPEC-016
   swap flow, when originator is App-track, sends a
   coordinator-authored email to that address with a
   time-limited signed cancellation link. Cancel-via-email works
   during the SPEC-016 cooling window regardless of Mac state.
4. **§4.1 step 7 invented state enum.** CODE HIGH. `ACTIVE`,
   `USED`, `REVOKED` do not exist in the `provider_tokens` schema.
   The actual model is
   `revoked_at IS NULL AND last_used_at IS NULL` = active-unused;
   `revoked_at IS NOT NULL` = revoked; `last_used_at IS NOT NULL`
   = already-used-once. **v0.3 fix:** rewrite §4.1 step 7 around
   these actual predicates. Idempotency: if a token row exists
   for `provider_id` with `revoked_at IS NULL`, return that row's
   cleartext token — but the cleartext isn't stored (only
   `token_hash`), so idempotent replay is not buildable as-drafted.
   **Correct approach:** on duplicate `/register` with the same
   `identity_pubkey`, the coordinator MUST revoke the prior active
   row (`revoked_at = now()`) and mint a fresh token. On duplicate
   `/register` with a DIFFERENT `identity_pubkey`, reject `409`
   (TOFU). This is a rotation-on-duplicate model, not a
   return-existing-token model.

## Non-convergent MEDIUMs to fix

- **CODE-M2 (§7.6):** Launch gate `||` is wrong. Identity-only
  (v2-partial) state must be handled by the onboarding-window
  resume path, not by `MalibuAgent.start()`. `start()` requires
  BOTH identity AND a persisted provider_id + Keychain token.
  **v0.3 fix:** gate is `ProviderIdentity.isReady() &&
  ProviderConfig.isConfigured` OR (for v1 back-compat)
  `ProviderConfig.isConfigured && !ProviderIdentity.isReady()`.
  Cleanly: `ProviderConfig.isConfigured` is the gate (which was
  already the case in v0.1). The `ProviderIdentity.isReady()`
  predicate matters for the onboarding-window rehydration flow.
- **CODE-M3 (§3.3):** `phase4-coordinator/internal/util` base32
  helper doesn't exist. **v0.3 fix:** rewrite as implementation
  requirement — Go MUST use `base32.NewEncoding(...)` with
  `.WithPadding(base32.NoPadding)` and lowercase transform, Swift
  MUST add a tested no-pad lowercase RFC 4648 encoder in
  `MacProviderCore`.
- **CODE-M4 (§7.3):** test path corrected to
  `phase3-binary/app/Tests/MalibuTests/PendingLinkStateTests.swift`.
- **CODE-M5 (§8.1):** migration matrix missing "CLI-owned config
  present, no App marker" cell. SPEC-025 §3.4 already requires an
  import/migration dialog for that state.
  `ProviderConfig.saveProviderIdentity` throws
  `existingConfigNotOwnedByApp` when the marker file is absent.
  **v0.3 fix:** add row to §8.1.
- **SEC-M4 (§11 App Attest economics):** attestation-key uniqueness
  only prevents ONE-key sybil replay, not multi-key-per-device
  sybil (an attacker on a real Mac can generate arbitrarily many
  attestation keys via `DCAppAttestService.generateKey`). **v0.3
  fix:** reframe App Attest as bundle-integrity + anti-replay
  evidence, not as a per-device economic sybil cost. Explicitly
  add the caveat to §11 and remove the "$99/year Apple Dev cert
  cost per identity" line from the economics.
- **SEC-M5 (§5.2 continuous re-check):** SPEC-016 payout cadence
  defaults to 6h and is configurable. A predictable check window
  lets an attacker fund around it. **v0.3 fix:** require the
  balance to be present continuously for the full unlock-eligibility
  window (72h floor), with randomized-jitter checks every
  15min–4h. Coordinator MUST use SPEC-016's existing dual-RPC
  redundancy and pin USDC contract `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
  (Base USDC).
- **SEC-M6 (§5.1 provisional non-withdrawable enforcement):** the
  claim is prose-only. **v0.3 fix:** normative schema addition to
  the reward-emission ledger:
  `withdrawal_hold_reason TEXT NULL` with values
  `"trust_tier_provisional"` / `"per_wallet_daily_cap"`. Every
  MALIBU withdrawal runner query MUST include
  `WHERE withdrawal_hold_reason IS NULL`.
- **SEC-M7 (§5.1 per-wallet cap enforcement):** prose-only.
  **v0.3 fix:** normative primitive
  `wallet_daily_malibu_emission (bound_wallet, emission_day, sum_malibu)`
  aggregate table. Coordinator MUST decrement per-request within a
  transaction; on exceed, mark the excess with
  `withdrawal_hold_reason = "per_wallet_daily_cap"` (not reject;
  the emission still credits the provider, just non-withdrawable).
- **SEC-M8 (§5.2 Base RPC):** unspecified RPC endpoint. **v0.3
  fix:** reuse SPEC-016's two-RPC dual-read pattern; both `balanceOf`
  reads must agree; disagreement fails closed (criterion not
  satisfied).
- **SEC-M9 (§9.1 earnings endpoint auth):** `GET
  /v1/providers/{id}/earnings` needs explicit auth. **v0.3 fix:**
  either delete this endpoint mention (use existing SPEC-005
  `/providers/{provider_id}/earnings` unchanged) or explicitly
  require `Authorization: Bearer <provider_token>` whose subject
  equals `{id}`. Return 401/403/404 per SPEC-005 §11.4.
- **ARCH-M2 (§4.3 CLI-track asymmetry):** CLI-track continuing
  bearer-only "forever" is a permanent trust boundary. **v0.3
  fix:** add a normative note that new CLI-track provider_ids
  (issued after the App-track cutover) MUST use a matching
  receipt-key-signed proof-stage flow. Existing CLI-track
  provider_ids remain bearer-only via the exemption list (same
  mechanism as SEC-2 above).
- **ARCH-M5 (§8.1 v2-partial + flag-off UX):** menu-bar-only
  discovery of "Complete Malibu onboarding" is fragile. **v0.3
  fix:** require auto-present of the onboarding window on
  next app foreground for `v2-partial` state regardless of flag.

## LOW/INFO carried forward (documented in PR body, non-blocking)

- **CODE-L1 (§10 checklist step 2/3 ordering):** App Attest handling
  IS part of `/register` semantics; the two steps can be merged.
  Trivial reword — will do in v0.3.
- **CODE-L2 (§2 citation):** `ReceiptBuilder.swift:226` is a public
  key, not private-key generation. **v0.3 fix:** update to
  `ReceiptKeyStore.swift:41` or `RotateKeyCommand.swift:99`.
- **ARCH-L1 (§8.1 v1-complete + flag-on migration):** "Upgrade to
  Malibu identity" affordance without a defined migration invariant.
  **v0.3 fix:** hide the button in v0.2/v0.3 (defer to future spec)
  and state the migration invariant will be old-and-new coexist,
  no automatic ledger transfer, explicit wallet rebinding.
- **ARCH-L2 (§10 step 4 production gate):** step 4 requires
  SPEC-016 §3 deployed IN PRODUCTION, not just staging.
- **ARCH-L3 (§4.4 portal retirement owner):** add owner (operator)
  and 14-day review cadence.
- **ARCH-L4 (§9.1 earnings endpoint drift):** align path with
  SPEC-005/SPEC-016.
- **ARCH-L5 (§9.2 per-wallet cap sizing):** add note that 100/day
  is initial guess pending cohort telemetry.
- **SEC-L1 (§5.3 honest wipe+re-onboard):** App Attest key_id 409
  on legitimate re-onboarding same Mac. **v0.3 fix:** state as
  accepted tradeoff; recovery path is "re-onboard without
  attestation this time" (App drops `app_attest_object` and
  `app_attest_key_id` from the request; provider gets
  `trust.attested = false` and normal Trust unlock via other
  criteria).
- **SEC-INFO / SEC-M-canonical-domain drift:** hardcode the
  canonical `coordinator_domain` value as a shared constant.
  Already implied by v0.2; make it explicit.

## R3 plan

- Apply the fixes above as targeted edits to SPEC-026 (not a full
  rewrite this time — smaller surface area).
- Re-fire all three lanes.
- If R3 lands 0 C/H/M → freeze v0.3 → push → PR ready to merge.
- If R3 surfaces new issues → R4.
