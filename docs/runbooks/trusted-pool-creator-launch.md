# Trusted Pool creator launch (SPEC-043)

This is the operator runbook for an approved **single-operator Trusted Pool**.
It does not authorize a live external creator launch. Isolated-candidate
CONFORMANCE fill for SPEC-043-R001 through R012 is not a live Trusted Pool
announcement.

Buyer-facing wording is **Trusted Pool**. Do not call this a Privacy Pool,
coordinator-blind, anonymous, ZK, or regulated-compliance product.

Issue: https://github.com/Augustas11/macprovider/issues/1233

Creator-MVP evidence and promotion-gate work on
https://github.com/Augustas11/macprovider/issues/1160 is complete. Isolated-candidate
CONFORMANCE is not a live Trusted Pool launch. Remaining live-readiness before
announce is tracked on issue 1233.

## Pilot policy

Until a live external creator is announced, production coordinators must keep:

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

Candidate journey evidence (isolated-candidate CONFORMANCE fill, not a live launch):
`journeys/JOURNEY-TRUSTED-POOL-CREATOR-MVP.md`

That run covers create → root/manifest → member → buyer grant → candidate
promote → pooled chat → observe-mode route snapshot → member revoke fail-closed
→ reconstruct → operator pause. Creator credentials cannot hit `/promote`.
Unauthorized pool select fails before a second provider dispatch. Payout-ready
rows stay zero.

## Blocked before any live announcement

These journey observations are **true** on the signed same-day recapture from
workflow [`33037491210`](https://github.com/Augustas11/macprovider/actions/runs/33037491210)
(`journeys/evidence/trusted-pool-creator-mvp-20260827T032524Z.*`, `run_id` `1` on
`fd50904396f3f11c2db633c9ed69b28d61a7ef65`, `expires_at` `2026-08-27`). Promoter
consume of sibling [`33039343666`](https://github.com/Augustas11/macprovider/actions/runs/33039343666)
(`authorization_id` `spec043-ppt-20260827T032524Z-1`) filled SPEC-043-R001 through
R012. Isolated-candidate CONFORMANCE is not a live Trusted Pool launch. The signed
envelope from workflow
[`33026618698`](https://github.com/Augustas11/macprovider/actions/runs/33026618698)
was not consumed. The prior signed integer-`run_id`
envelope (workflow [`32936678404`](https://github.com/Augustas11/macprovider/actions/runs/32936678404))
has `expires_at` `2026-08-26`. Do not announce a live creator until remaining
production-readiness items exist.

| Observation | Status |
|---|---|
| `creator_suspension_root_compromise_freeze_verified` | True on signed same-day recapture |
| `descendant_signer_rejection_verified` | True on signed same-day recapture |
| `delegation_revocation_verified` | True on signed same-day recapture via canonical `ProviderPoolDelegationV1` grant/revoke (`member_revoked` is not delegation proof) |
| `pool_existence_oracle_within_threshold` | True on signed same-day recapture via buyer/gateway rejection timing floor + unknown/unauthorized/disabled distribution test (wallet covered at gateway) |

Also still missing before any live announcement:

- a production on-call readiness record stored in the launch environment
  (`POST /admin/trust-pools/on-call-readiness`, CLI
  `coordinator-cli trust-pool-oncall`). Operator HTTP/CLI production promote
  fail-closes without a current row. In-process `Store.PromotePool` still does
  not consult on-call; wiring `validatePromotion` needs a recapture window
  because that function is evidence-mapped.
- a reviewed-artifact lifecycle owner for the live pool
  (`POST /admin/trust-pools/pools/{id}/reviewed-artifact-lifecycle`, CLI
  `coordinator-cli trust-pool-artifact-lifecycle`). This is separate from the
  digest-bound reviewed-artifact upsert. Operator HTTP/CLI production promote
  now fail-closes without a current production lifecycle owner (missing,
  candidate-class, or overdue), the same unmapped-wrapper gate as on-call.
  In-process `Store.PromotePool` still does not consult it; wiring
  `validatePromotion` needs a recapture window because that function is
  evidence-mapped.
- a production timing-floor remeasure. Isolated-candidate oracle proof is not
  that remeasure. Use `scripts/measure-pool-rejection-timing-floor.py`; it
  refuses production hosts unless `--environment production --allow-production`
  and never treats offline `--samples-json` as a production remeasure.

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
coordinator-cli trust-pool-oncall upsert --json-file <signed-oncall.json>
coordinator-cli trust-pool-oncall get --launch-environment-id <env_id>
coordinator-cli trust-pool-artifact-lifecycle upsert --pool-id <pool_id> --owner <owner> ...
```

On-call records are Ed25519-signed by a MacProvider operations authority. The
coordinator allowlists that key as SHA-256 of the 32-byte public key via
`MACPROVIDER_SPEC043_ONCALL_AUTHORITY_KEY_SHA256`. TTL defaults to 90 days and
rejects longer intervals. Missing or expired rows are launch blockers; they are
not yet a `PromotePool` production-gate check.

Reviewed-artifact lifecycle ownership is a separate durable row from
`review-distribution-artifact`. Assign an owner and `environment_class` of
`candidate` or `production` before treating a pool as live-ready. Operator
HTTP/CLI production promote fail-closes (`reviewed_artifact_lifecycle_rejected`,
409) unless the pool has a current production lifecycle owner whose
`next_review_due_utc` is still in the future. This is not yet a
`Store.PromotePool` production-gate check.

Offline timing-floor check (does **not** count as production remeasure):

```bash
python3 scripts/measure-pool-rejection-timing-floor.py --samples-json samples.json
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

## Production-release key (operator-owned)

The registered public key is `security/spec-043-production-release-p256-v1.pem`.
The private half lives only in the GitHub `production-release` environment
secret `MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM`. Do not copy
that private key into a worktree, log, issue, artifact, or commit.

To provision a first key on a still-empty keyring:

```bash
bash scripts/provision-spec043-production-release-key.sh Augustas11/macprovider
```

That command generates P-256 material in a mode-0700 temporary directory, pipes
the private key into the environment secret, and registers only the public
half. Re-running it fails closed once the public key or keyring entry exists.

Dispatch `.github/workflows/build-signed-pool-promotion-transition.yml` from
reviewed `main` to sign a sibling. Signing a sibling does not consume the
ledger or fill CONFORMANCE `evidence[]`.

## Next gates

- Same-day signed recapture is consumed (candidate workflow
  [`33037491210`](https://github.com/Augustas11/macprovider/actions/runs/33037491210),
  sibling workflow
  [`33039343666`](https://github.com/Augustas11/macprovider/actions/runs/33039343666),
  `authorization_id` `spec043-ppt-20260827T032524Z-1`, `run_id` `1` on
  `fd50904396f3f11c2db633c9ed69b28d61a7ef65`, `expires_at` `2026-08-27`).
  SPEC-043-R001 through R012 are conformant. Isolated-candidate CONFORMANCE is
  not a live Trusted Pool launch. The signed `20260827T000309Z` envelope and
  sibling remain unconsumed. The prior signed envelope (workflow
  [`32936678404`](https://github.com/Augustas11/macprovider/actions/runs/32936678404))
  has `expires_at` `2026-08-26`.
- Historical Gate C envelope (workflow
  [`32926445757`](https://github.com/Augustas11/macprovider/actions/runs/32926445757))
  still has a capture-string `run_id`.
- Promoter wiring consumed sibling `spec043-ppt-20260827T032524Z-1` before
  rewriting CONFORMANCE. Governance treats that creator-MVP envelope as
  requirement evidence because a matching `consumed_authorization` exists.
  Isolated-candidate CONFORMANCE is not a live Trusted Pool launch.
- Operator key registration: `security/spec-043-production-release-p256-v1.pem`
  is registered. The sibling signer used
  `MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM` and does not
  consume the ledger or rewrite CONFORMANCE by itself.
- Gate D CONFORMANCE fill for R001-R012 is done through promoter consume.
  Remaining before live announcement: a production on-call readiness row in the
  launch environment (operator HTTP/CLI production promote now consults it;
  `Store.PromotePool` still does not), a reviewed-artifact lifecycle owner for
  the live pool, and a production timing-floor remeasure. Durable admin/CLI
  surfaces and `scripts/measure-pool-rejection-timing-floor.py` exist; they do
  not announce a live Trusted Pool.
