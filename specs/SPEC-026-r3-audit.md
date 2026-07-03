# SPEC-026 R3 — 3-lane codex audit results and R4 dispositions

Round 3 re-fired all three codex lanes against SPEC-026 v0.3.
Prompts told codex to read R1 + R2 audit narratives first and
not to re-flag anything already resolved.

## R3 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | 0 | 0 | 8 | 1 | 0 |
| SECURITY  | 0 | 1 | 8 | 1 | 1 |
| ARCHITECT | 0 | 3 | 2 | 1 | 1 |
| **Combined R3** | **0** | **4** | **18** | **3** | **2** |
| R2 combined | 0 | 5 | 14 | 8 | 2 |
| R1 combined | 1 | 9 | 16 | 3 | 3 |

HIGHs continuing to trend down (9→5→4). MEDIUMs went up as codex
finds deeper detail once the structural issues are resolved. v0.4
targets each.

## HIGHs closed in v0.4

1. **§4.3 proof-stage frame shape.** ARCH + CODE + SEC all flagged
   the same thing: v0.3 named the frame `type: "auth_proof"` and
   embedded the bearer token in the body. SPEC-001 v1.6 §6.7
   defines proof-stage as `type: "auth_request", stage: "proof"`
   and bearer stays in the WS-upgrade HTTP `Authorization` header.
   **v0.4 fix:** rewrite §4.3's proof frame example to match
   SPEC-001 literal; only the two new fields
   (`identity_signature`, `identity_signature_transcript_sha256`)
   are ADDED to the existing proof-stage frame.
2. **§4.3 CLI-track receipt-key rotation conflict with SPEC-015.**
   ARCH HIGH + SEC MEDIUM. Validating the proof against the
   stored `receipt_pubkey` would reject SPEC-015's reconnect-based
   rotation (during rotation the client sends the new key but
   coordinator hasn't committed it yet). **v0.4 fix:** validate
   against the initial-frame-declared `provider_receipt_public_key`
   when it differs from stored; commit rotation after auth
   acceptance. This composes with SPEC-015 §7.5 rotation
   semantics.
3. **§5.1 / §5.2 / §11 sybil stack weaker than claimed.** ARCH
   HIGH. "Any two" allowed 72h uptime + valid App Attest with no
   economic cost. **v0.4 fix:** require at least ONE economic
   criterion (verified receipts OR 100 USDC OR operator
   promotion) plus at least one additional criterion. App Attest
   is bundle-integrity evidence, not an economic layer.
4. **§9.3 payout coercion via same-bearer email compromise.** SEC
   HIGH. Malware with bearer + identity signing capability
   could set its own `notification_email`, self-verify, and get
   the cancel URL. **v0.4 fix:** two-step verified-email flow
   (§4.5): (a) new email confirms via delivery to itself, (b)
   old email notified of pending change with reject link, (c)
   24h cooling window before new email becomes authoritative.
   Wallet swap fails closed on unverified email above 500 USDC
   exposure OR email delivery failure. HMAC signing key rotates
   via `LoadCredential` + `kid` in URL.

## MEDIUMs closed in v0.4

- **CODE-M1/§4.3 frame naming (auth_proof → auth_request+stage:proof).**
  Same fix as HIGH #1 above.
- **CODE-M2/§5.1 emission ledger table.** Named
  `provider_rewards_ledger` at
  `phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql:170`
  with additive MALIBU columns (`amount_malibu`,
  `withdrawal_hold_reason`).
- **CODE-M3/§8.1 SPEC-025 §3.4 was uninstall-only.** Import
  dialog defined inline in new §8.4.
- **CODE-M4/§9.3 API surface not enumerated in §4.** Added §4.5
  (`POST /notification-channel`) and §4.6 (`GET /wallet-swap/cancel`)
  with full schemas.
- **CODE-M5/§4.3 CLI receipt-key source citation.** Renamed to
  actual `/v1/receipt-keys/{provider_id}` backing storage; helper
  location as implementation-required.
- **CODE-M6/Entry 102 stale.** Entry 102 rewritten to v0.4.
- **CODE-M7/AC-026-06 in-band-only.** Rewritten to cover email
  channel, fail-closed, and retries.
- **SEC-M1/§4.3 blanket 30-day exemption too generous.** Tightened
  to 7 days; operator extensions require max_ttl ≤ 30 days,
  reason, and dual-approval for TTL > 7 days.
- **SEC-M2/§4.3 frame shape.** Same as HIGH #1.
- **SEC-M3/§9.3 HMAC secret undefined.** Added `LoadCredential`
  binding, `kid` in URL, rotation policy in §4.6.
- **SEC-M4/§5.1 concurrent emission cap race.** Added
  `SERIALIZABLE` isolation with retry-on-40001 OR
  `SELECT ... FOR UPDATE` under `READ COMMITTED`.
- **SEC-M5/§5.2 sampling distribution.** Poisson process, mean
  60min, floor 15min, ceiling 4h, secret scheduler.
- **SEC-M6/§4.3 CLI rotation.** Same as HIGH #2.
- **SEC-M7/§4.1 rotate-on-duplicate DoS.** Required
  `current_token_proof` field for duplicates against a
  `last_used_at IS NOT NULL` row; per-provider 5-minute cooldown.
- **SEC-M8/§5.5 requalification cooldown.** 72h re-hold after
  demotion.
- **ARCH-M1/§9.3 HMAC storage/config.** Same as SEC-M3.
- **ARCH-M2/§10 checklist gaps.** Rewrote step 1 to enumerate all
  v0.4 schema migrations (provider_auth_policy,
  notification_email columns, provider_rewards_ledger extension,
  wallet_daily_malibu_emission table, HMAC credential).

## LOW/INFO carried forward or fixed in-line

- ARCH-L / CODE-L / SEC-L Entry 102 stale — fixed.
- §8.2 rollback text menu-bar-only inconsistent with §8.1
  auto-present — fixed inline (auto-present is now consistent).
- SEC-L1 (attestation key uniqueness blocks honest re-onboarding
  same Mac) — accepted tradeoff, App drops attestation on wipe
  re-onboard.
- SEC-INFO (notification email PII in logs) — spec adds a note
  requiring redaction in observability logs.
- ARCH-INFO (SPEC-016 §3 not yet in production) — deploy
  checklist step 4 already gates this; kept as-is.

## R4 plan

- Fire all three lanes against v0.4.
- Skip re-firing any lane that R3 landed at 0 C/H/M (CODE R3 had
  0 HIGH but 8 MEDIUM, so still not at PASS — refire).
- All three lanes fire again.
- If R4 lands 0 C/H/M → push v0.4 → PR ready to merge.
- If not, R5.
