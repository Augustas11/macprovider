# Trusted Pool creator launch (SPEC-043 Gate C)

This is the operator runbook for an approved **single-operator Trusted Pool**.
It does not authorize a live external creator launch. SPEC-043 stays pending
until Gate D promotion: signed candidate evidence plus a sibling
`PoolPromotionTransitionV1` consumed with a registered production-release key.

Buyer-facing wording is **Trusted Pool**. Do not call this a Privacy Pool,
coordinator-blind, anonymous, ZK, or regulated-compliance product.

Issue: https://github.com/Augustas11/macprovider/issues/1160

## Pilot policy

Until Gate D lands, production coordinators must keep:

- `trusted_pools.enabled` off, or any enabled pool in a non-routeable lifecycle
- membership limited to the creator’s own admitted Macs (SPEC-003)
- buyers on dedicated pool-authorized accounts (not wallet-session pool select)
- reviewed distribution artifacts only; no public announcement without a matching
  digest-bound approval
- settlement in observe / labels-only mode (`split_execution_status` remains
  `declared_not_executed`)
- no third-party provider marketplace joins and no creator revenue-split payout

## What is already proven (isolated candidate)

Harness:
`phase4-coordinator/internal/trustpool/spec043_creator_mvp_journey_test.go:TestJourneyTrustedPoolCreatorMVPCandidate`

Signed candidate envelope (evidence-only, not in CONFORMANCE `evidence[]`):
`journeys/JOURNEY-TRUSTED-POOL-CREATOR-MVP.md`

That run covers create → root/manifest → member → buyer grant → candidate
promote → pooled chat → observe-mode route snapshot → member revoke fail-closed
→ reconstruct → operator pause. Creator credentials cannot hit `/promote`.
Unauthorized pool select fails before a second provider dispatch. Payout-ready
rows stay zero.

## Blocked before any live announcement

These journey observations are **true** on the Gate C signed envelope from
workflow [`32926445757`](https://github.com/Augustas11/macprovider/actions/runs/32926445757)
(`journeys/evidence/trusted-pool-creator-mvp-20260826T022522Z.*`). They remain
evidence-only: CONFORMANCE `evidence[]` is empty. Do not announce a live
creator until Gate D exists.

| Observation | Status |
|---|---|
| `creator_suspension_root_compromise_freeze_verified` | True on signed Gate C envelope |
| `descendant_signer_rejection_verified` | True on signed Gate C envelope |
| `delegation_revocation_verified` | True on signed Gate C envelope via canonical `ProviderPoolDelegationV1` grant/revoke (`member_revoked` is not delegation proof) |
| `pool_existence_oracle_within_threshold` | True on signed Gate C envelope via buyer/gateway rejection timing floor + unknown/unauthorized/disabled distribution test (wallet covered at gateway) |

Also still missing for Gate D:

- registered production-release approver key (committed keyring is empty)
- wiring `promote-signed-journey-result.py` to consume a real
  `PoolPromotionTransitionV1`
- production on-call readiness record, reviewed-artifact lifecycle ownership,
  and production timing-floor remeasure

## Fail-closed checks (candidate or staging)

Run from repo root against the isolated harness first:

```bash
cd phase4-coordinator
go test ./internal/trustpool -run TestJourneyTrustedPoolCreatorMVPCandidate -count=1
```

Operator admin (environment key only; never a creator bearer):

```text
coordinator-cli trust-pool-admin set-lifecycle --pool-id <pool_id> ...
coordinator-cli trust-pool-admin revoke-provider --pool-id <pool_id> ...
coordinator-cli trust-pool-admin upsert-creator ...   # suspend / re-enable
```

Expected:

- pool-required chat with a revoked member, paused lifecycle, or unauthorized
  buyer does not reach a global provider
- pause/revoke bumps generation and drops routeable members
- creator token cannot promote or administer another creator’s pool
- policy/status 404s for unknown/unauthorized pools stay non-enumerating and
  `Cache-Control: no-store`

Do not treat a green local test as production promotion.

## Emergency pause and rollback (current surface)

1. Pause the pool: `trust-pool-admin set-lifecycle` to `paused`.
2. Confirm buyer chat for that `pool_id` fails closed and `pool_status.json`
   (authorized) shows the pause.
3. If a provider must leave immediately: `revoke-provider`, then confirm no
   further pooled dispatch to that identity.
4. If the creator account is untrusted: `upsert-creator` with suspended status
   so nonce issuance and expansive mutations fail closed. Report root compromise
   with `POST /creator/trust-pools/emergency/root-compromise` or
   `POST /admin/trust-pools/emergency/root-compromise`; that freeze still works
   while the creator is suspended and keeps descendant signers from mutating.
5. Global (non-pool) traffic must remain unaffected. Do not “fix” a pool
   outage by clearing `X-MacProvider-Pool-Select` or routing pool buyers to
   the global pool.

Root-compromise freeze, descendant-signer rejection,
`ProviderPoolDelegationV1` revocation, and the pool-existence timing oracle
(SPEC-043-R007 floor + distribution bounds) are proven in the isolated
candidate harness on new captures.

## Settlement

Pooled candidate traffic must keep `pool_id` on the route snapshot and must
not write payout-ready rows from `revenue_split_bps`. Duplicate settlement for
the same route snapshot id must fail. Do not enable creator-split execution as
part of this MVP.

## Next gates

- Gate C signed candidate envelope is committed (workflow
  [`32926445757`](https://github.com/Augustas11/macprovider/actions/runs/32926445757)).
  It remains evidence-only: CONFORMANCE `evidence[]` is empty. Its
  capture-string `run_id` is not Gate D consumable.
- Unsigned recapture `journeys/evidence/trusted-pool-creator-mvp-20260826T054329Z.redacted.json`
  has integer `run_id` `1` on `036e9930023f96ee7b66300347c885fc2fc30485`, with
  freeze, descendant-signer, delegation, and pool-existence oracle observations
  true. Re-sign that file from reviewed `main` (`expires_at` is `2026-08-26`).
- Gate D still needs the signed integer-`run_id` envelope, sibling
  `PoolPromotionTransitionV1`, non-empty production-release keyring, promoter
  allowlist, and CONFORMANCE `evidence[]` only through that flow.
