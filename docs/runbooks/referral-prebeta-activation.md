# Referral-Gated Pre-Beta Activation Runbook

This runbook activates pre-beta referral admission and the optional social
invite bonus as two independent gates. It does not authorize either gate by
itself. Both flags stay `false` in checked-in configuration and throughout the
implementation PR stack.

The rollout goals are:

1. admit fresh providers only through referrals while preserving existing
   provider access and recoverable App-track registration; and
2. after admission is stable, let serving providers earn additional invite
   capacity by completing the in-app X sharing flow.

Keep `/j/<code>` permanently mounted, including during rollback. Shared links
must continue to explain their state even while admission enforcement is off.

## Ownership and stop conditions

One named incident commander owns each activation. Stop or roll back when any
of these conditions is observed:

- an existing bearer can no longer reconnect or repair its hardware evidence;
- a valid referral is consumed without a committed provider credential;
- an App-track registration remains pending beyond the reconciler window;
- referral validation or registration returns sustained `503` responses;
- admission rejection reasons do not match the probe used;
- the join page, onboarding app, and coordinator disagree about whether an
  invite is required; or
- social bonus capacity is granted without a completed, matured verification
  bound to the provider's current issuer.

Do not delete referral, redemption, registration-attempt, social-challenge, or
operator-audit records during rollback. They are commitment and investigation
evidence, not disposable feature state.

## Preflight: deploy with both flags off

Before changing policy, deploy the complete referral PR stack with:

```yaml
referrals:
  require_for_registration: false
  enable_social_invite_bonus: false
```

Confirm all of the following:

- the coordinator and Malibu app versions include referral-aware registration,
  client-owned App-track token custody, and inherited-FD evidence repair;
- startup completed all auth-store schema initialization and the App-track
  registration-attempt migration before either reconciler started;
- `referrals.campaign` and `referrals.current_key_id` are stable identifiers
  matching the seed campaign;
- every configured HMAC secret is at least 32 bytes and supplied through
  `env:NAME` indirection, never argv, logs, shell history, or Git;
- `referrals.join_base_url` is the public HTTPS `/j` route;
- `referrals.request_access_url` is empty unless it points to a delivery-tested
  access-request flow; do not relabel the host download or troubleshooting
  pages as access request;
- any support or request-access CTA whose destination is not delivery-tested
  is hidden in the deployed app and join page;
- the grandfather cutoff is recorded, if used, and currently valid provider
  bearers remain exempt from fresh-admission referral requirements; and
- operator database backups and the previous coordinator/app artifacts are
  available.

With enforcement off, the public validation endpoint must report the disabled
policy and must not touch referral capacity:

```bash
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  --data '{"code":"preflight-placeholder"}' \
  https://coordinator.streamvc.live/v1/referrals/validate
```

Expected response fields are `valid: true`, `required: false`, and
`reason: "disabled"`. Also open an old `/j/<code>` link and confirm the page
loads with `Cache-Control: no-store` rather than returning a proxy 404.

Before continuing, exercise one existing provider reconnect and one
app-managed evidence repair. Neither path may ask for or consume an invite.

## Seed the initial cohort

Create a seed once. The command is insert-only: rerunning it for an existing
seed fails and directs the operator to the audited adjustment command.

```bash
export MAL_REFERRAL_SECRET='<redacted-32+-byte-secret>'

coordinator-cli create-seed-referral \
  --db /var/lib/macprovider/coordinator.db \
  --campaign prebeta \
  --key-id k1 \
  --secret-env MAL_REFERRAL_SECRET \
  --seed-id launch \
  --max-uses 100

unset MAL_REFERRAL_SECRET
```

Store the emitted referral code in the approved secret-sharing channel. Do not
paste it into logs or the decision ledger.

Capacity changes require a dry run followed by an audited apply using the same
observed values:

```bash
export MAL_REFERRAL_SECRET='<redacted-32+-byte-secret>'

coordinator-cli adjust-seed-referral \
  --db /var/lib/macprovider/coordinator.db \
  --campaign prebeta \
  --key-id k1 \
  --secret-env MAL_REFERRAL_SECRET \
  --seed-id launch \
  --max-uses 150

coordinator-cli adjust-seed-referral \
  --db /var/lib/macprovider/coordinator.db \
  --campaign prebeta \
  --key-id k1 \
  --secret-env MAL_REFERRAL_SECRET \
  --seed-id launch \
  --max-uses 150 \
  --apply \
  --actor ops@malibu \
  --reason 'approved pre-beta cohort expansion'

unset MAL_REFERRAL_SECRET
```

## Gate A: require referrals for fresh registration

Set only:

```yaml
referrals:
  require_for_registration: true
  enable_social_invite_bonus: false
```

Apply the configuration through the normal coordinator deployment/restart
path. Do not combine this change with a key rotation, campaign change, seed
capacity change, or social activation.

Run these probes immediately after restart:

| Probe | Required result |
|---|---|
| Missing invite, fresh registration | Rejected as `missing`; no credential or redemption committed |
| Malformed invite | Rejected as `invalid` |
| Expired invite | Rejected as `expired` |
| Revoked invite | Rejected as `revoked` |
| Exhausted invite | Rejected as `exhausted` |
| Valid invite | Exactly one provider credential and one redemption committed |
| Retry after lost valid response | Same committed credential recovered; no second redemption |
| Existing valid bearer | Accepted without an invite |
| App-track repair | Existing bearer passed through inherited FD; no invite consumed |

During the observation window, watch structured registration/referral logs,
HTTP status and reason distributions, `429` and `503` rates, active-provider
count, pending App-track registration attempts, referral redemptions, and
operator audit rows. Use bounded read-only database queries and redact code
digests, bearer material, and request signatures from incident notes.

Record a staging/canary baseline window and minimum sample size before the
production flip. The current switch is a global startup boolean, not a
percentage rollout; seed capacity limits admissions but does not create a
selectively enforced cohort. Roll back if valid-invite-to-first-serving
conversion falls by more than 10 percentage points, setup p90 rises by more
than 30 seconds excluding artifact download, or any existing-provider
regression appears.

Accept Gate A only after the full observation window completes with no stop
condition and the seed's remaining capacity equals its configured capacity
minus committed unique redemptions.

## Gate B: enable the X sharing bonus

Gate B is optional and follows a separately reviewed advocacy PR. Do not enable
it until Gate A is accepted and the deployed Malibu version exposes referral
status only after the provider's first successful serving event.

Preconditions:

- the provider has a stable base invite before a social challenge is created;
- `referrals.x_api_bearer_token` is supplied through environment indirection
  and can perform the deployed verification call without appearing in logs;
- challenge creation, expiry, replay rejection, X-post verification, dwell
  time, maturity promotion, and replacement-race tests pass in the deployed
  version;
- the app displays base capacity, pending verification, matured bonus, used
  capacity, and remaining capacity from authoritative server state; and
- the share composer uses the permanent HTTPS `/j/<code>` URL and does not
  claim a bonus before server confirmation.

Then set only:

```yaml
referrals:
  require_for_registration: true
  enable_social_invite_bonus: true
```

Restart through the normal coordinator deployment path. Verify one controlled
provider end to end: first-serving disclosure, invite retrieval, X composer,
challenge verification, dwell period, promotion, and exactly the configured
bonus capacity. Confirm a replay and a challenge bound to a replaced issuer do
not grant capacity.

## Rollback

Rollback is a policy change, not a data purge.

1. If the social path is involved, set
   `enable_social_invite_bonus: false` first and restart.
2. Set `require_for_registration: false` and restart.
3. Confirm `/v1/referrals/validate` again reports `required: false` and
   `reason: "disabled"`.
4. Confirm fresh registration succeeds without an invite and an existing
   provider reconnects with its prior bearer.
5. Keep `/j/` mounted and retain every issuer, redemption, attempt, challenge,
   verification, and admin-audit row.
6. Record the trigger, timestamps, observed counts, rollback result, and any
   quarantined issuer IDs in `beta/DECISION_CRITERIA.md`. Do not record raw
   referral codes, HMAC secrets, provider bearers, or X API credentials.

If one issuer is compromised, prefer the audited `revoke-referral` dry-run and
apply flow over disabling or deleting the entire campaign.

## Completion evidence

Attach these redacted artifacts to the activation decision entry:

- deployed commit or release identifiers for every PR in the stack;
- the two flag values before and after each gate;
- disabled-policy, registration matrix, and existing-provider probe results;
- seed capacity, committed redemption count, and pending-attempt count;
- Gate B challenge/promotion evidence when social activation was attempted;
- observation-window duration and alert/log summary; and
- rollback evidence, if any.

Activation is complete only when the incident commander records an explicit
accept or rollback decision. Merging the implementation with both flags off is
not activation.
