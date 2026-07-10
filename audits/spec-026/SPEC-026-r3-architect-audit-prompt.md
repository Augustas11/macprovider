# SPEC-026 R3 — ARCHITECT audit lane

You are re-auditing SPEC-026 v0.3 after the R2 rewrite. Read
`specs/SPEC-026-r1-audit.md` and `specs/SPEC-026-r2-audit.md`
first — they list R1 and R2 findings and dispositions. Do NOT
re-flag items already resolved by v0.2 / v0.3.

Your lens is ARCHITECT: does v0.3 compose cleanly with adjacent
SPECs, are the newly-introduced primitives at the right layer, and
do the fixes for R2 findings introduce cross-spec drift?

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.3)
- `beta/DECISION_CRITERIA.md` Entry 102

## Adjacent SPECs to keep in sync

- `specs/SPEC-001-phase3-binary.md` v1.6 §6.7 v2 auth pipeline
- `specs/SPEC-003-open-onboarding.md` FR-C9
- `specs/SPEC-005-billing.md` §11.4 earnings endpoint
- `specs/SPEC-015-receipts.md` receipt-key rotation
- `specs/SPEC-016-payout-pipeline.md` §3 EIP-712 wallet binding,
  batch cadence
- `specs/SPEC-022-verified-model-settlement.md`
- `specs/SPEC-023-installer-autotune-recommend.md`
- `specs/SPEC-025-native-mac-app.md` §3.4 uninstall + import dialog

## What to check in R3

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **v0.3 §4.3 CLI-track hardening.** Extending the proof-stage
   flow to CLI-track providers signed by receipt-key. Verify:
   - This does not require changes to SPEC-001 that aren't
     captured in v0.3's "SPEC-001 v1.7 candidate will absorb"
     note.
   - Does not conflict with SPEC-015's rotation model (receipt key
     rotating implies the CLI-track auth flow needs the new key —
     is the SPEC-015 rotation reconnect path compatible?).
2. **v0.3 §4.1 rotate-on-duplicate.** Verify this doesn't
   conflict with SPEC-003 FR-C9's TOFU semantics. FR-C9 is about
   admission, not registration; SPEC-026 §4.1 is registration.
   But if a WS admission happens between the /register mint and
   /register re-register, does the schema stay consistent?
3. **v0.3 §5.1 enforcement primitives.** The
   `wallet_daily_malibu_emission` aggregate table is a new
   coordinator schema owner. Verify:
   - No conflict with SPEC-005 or SPEC-016 accounting.
   - Is this table owned by SPEC-026 or a coordinator-wide
     abstraction? If the operator wants to add other daily
     per-wallet limits later, is this the right layer?
4. **v0.3 §9.1 earnings alignment.** SPEC-026 says it adds two
   response fields to the existing SPEC-005 endpoint. Verify:
   - SPEC-005 §11.4 endpoint schema is extensible without a
     version bump; adding two OPTIONAL fields is safe under
     JSON forward-compat conventions.
5. **v0.3 §9.3 notification-email + HMAC cancel URL.** New
   coordinator surface. Verify:
   - No conflict with SPEC-016 §3 swap semantics (SPEC-016 owns
     the swap; SPEC-026 owns the notification/cancellation
     side-channel).
   - The HMAC signing secret storage owner is unspecified.
     Coordinator-side, but which config file / rotation policy?
     Flag if too vague.
6. **v0.3 §5.2 dual-RPC + pinned USDC contract.** SPEC-016 already
   defines two independent Base RPCs for its payout pipeline.
   Are those RPCs suitable for balance queries too, or should the
   spec name a separate pair?
7. **v0.3 §8.1 CLI-owned config row.** Depends on SPEC-025 §3.4
   import-migration dialog. Verify that SPEC-025 §3.4 exists.
8. **v0.3 §10 checklist.** Now requires SPEC-016 §3 in
   production. Is SPEC-016 §3 already in production? If not, the
   ordering forces SPEC-016 §3 to ship before SPEC-026 flag can
   flip. Note as INFO (this is intentional per the checklist
   design, but the operator should know).
9. **v0.3 §11 App Attest reframing.** Removing App Attest from
   the economic sybil layer is a substantive change. Verify:
   - The sybil-defense stack after reframing still holds. Without
     App Attest as an economic cost, the load-bearing layers are
     provisional non-withdrawable + 100 USDC time-weighted +
     per-wallet cap. Is that stack sufficient without
     attestation?
10. **v0.3 change log breadth.** Is the change log itself
    consistent with the actual edits made?

## Output format

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <spec §>
Concern: <what breaks or drifts>
Blast radius: <who is affected>
Fix: <concrete change>
```

End:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
