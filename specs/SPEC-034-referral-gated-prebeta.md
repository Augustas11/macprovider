# SPEC-034 — Referral-gated pre-beta and advocacy invite bonus

Version: v0.2.0
Status: implementation
Product parent: https://github.com/MalibuAI/malibu/issues/46

Changelog:
- v0.2.0 (FIX-570 review round 1): preflight capacity reservation endpoint (H1);
  deferred, dwell-gated, author-bound X social bonus (H3); insert-only seed
  creation with audited capacity adjustment (H5); audited replacement path for a
  revoked provider issuer (H4); permanently mounted `/j/` route that serves an
  open-beta landing when gating is disabled (M5).

## 1. Objective

Gate every new public provider credential behind a valid pre-beta referral while
preserving existing bearer reconnects and explicit operator issuance. After a
provider has verified serving evidence, expose a public invite and optionally
grant additional invite capacity for a verified X post. Social behavior MUST
NOT alter provider admission tier, routing trust, reward trust, payout
eligibility, or operational state.

## 2. State boundaries

The feature owns two orthogonal state axes:

- access: `valid`, `bound`, `expired`, `exhausted`, or `revoked`;
- advocacy: `locked_until_first_serving`, `eligible`,
  `verification_pending`, `verified`, `failed`, or `skipped`.

It does not introduce a generic provider `active` state. Existing
`pinned`/`provisional` admission and `provisional`/`trusted` reward state remain
authoritative for their existing purposes.

## 3. Configuration

The coordinator exposes a top-level `referrals` block:

- `require_for_registration` (default false);
- `enable_social_invite_bonus` (default false);
- `campaign`;
- `policy_version`;
- optional RFC3339 `grandfather_before` cutoff;
- `current_key_id`;
- `hmac_keys` map, whose values support `env:NAME` indirection;
- `provider_base_uses` (default 1);
- `social_bonus_uses` (default 2);
- `challenge_ttl_s` (default 900);
- `join_base_url`, an HTTPS URL ending in `/j`;
- `x_api_bearer_token`, resolved through `env:NAME`.

If either feature flag is enabled, campaign, current key, and the referenced
secret MUST be valid. Social bonus additionally requires an X API bearer token.
Secrets MUST NOT be logged or returned by effective-config surfaces.

## 4. Code contract

Codes are versioned and typed:

`MAL1-<S|P>-<key-id>-<opaque-id>-<base32-tag>`

The tag is the first 16 bytes of HMAC-SHA-256 over a domain-separated canonical
tuple containing version, type, key ID, campaign, and opaque ID. Comparison is
constant-time. Public provider codes use a random opaque issuer ID and never
embed or derive from a stable provider ID. Unknown versions, types, keys,
issuers, campaigns, or malformed/short tags fail closed.

HMAC authenticates a code; SQLite rows remain authoritative for issuer
existence, expiry, revocation, capacity, and attribution.

## 5. Persistence and atomicity

The auth SQLite database stores normalized referral issuers, short-lived
capacity reservations, redemptions, social challenges, and social verification
evidence. A first credential mint
and its referral redemption MUST commit in the same `BEGIN IMMEDIATE`
transaction. A failed transaction produces neither token nor redemption.

One provider may bind at most one referral per campaign. Retrying the same
provider/code pair never consumes additional referral capacity. Receipt-key
credential bootstrap additionally supports safe token replacement after a lost
response; other public mint paths fail closed behind an already-created active
credential. Binding the provider to another issuer is a conflict. Capacity is
checked and consumed transactionally, so N concurrent redeemers against
capacity one produce exactly one new binding.

App-track spans PostgreSQL identity storage and the SQLite credential
authority without holding either database transaction open across the other.
It first claims one expiring SQLite referral reservation, then atomically
converts the owned reservation into redemption plus an undisclosed token. That
same SQLite transaction persists a pending-mint saga containing the token hash,
the exact PostgreSQL nonce attempt, and whether this mint generation created
the referral redemption. Only after the authority transaction succeeds does
the handler atomically prepare nonce plus identity in PostgreSQL, and only after
both commits does it disclose the bearer. A proven PostgreSQL failure invokes
an owner- and token-bound SQLite compensation that deletes the still-unused
token and only referral state created by that generation. Ambiguous commit
results and process crashes remain durable: a startup/minutely reconciler checks
the exact PostgreSQL nonce plus identity attempt, preserves committed tokens,
and compensates attempts that never committed. It ignores saga rows younger
than two minutes so it cannot race a live request. Abandoned pre-mint
reservations expire and are ignored after their TTL. An invalid, revoked,
expired, or exhausted request therefore cannot reach PostgreSQL identity
preparation, and PostgreSQL latency never holds the SQLite writer lock.

Referral attribution survives admission pruning and process restart.
Coordinator persistence and logs do not retain raw codes, HMAC secrets,
cleartext challenges, post bodies, or bearer credentials. Clients may persist a
supplied code in protected local configuration so credential bootstrap can
retry after interruption.

## 6. Enforcement boundary

When `require_for_registration` is true, the following public first-mint paths
MUST supply and redeem a referral:

- legacy v1/v2 tokenless provisional self-mint;
- credential-bootstrap/bootstrap-auth mint;
- App-track `POST /v1/providers/register`.

Existing valid bearer reconnects and reissues proven by the current bearer do
not consume or require another referral. `coordinator-cli issue-token` is an
explicit operator exemption and emits no referral attribution.

The referral is part of the signed App-track request body and the retained
initial/proof WS bootstrap transcript. Referral attribution is immutable after
binding.

## 7. API

- `POST /v1/referrals/validate` accepts a bounded JSON code and returns only
  validity plus a closed reason; it never exposes issuer identity.
- `POST /v1/referrals/reserve` (FIX-570 H1) accepts a bounded JSON `{code,
  provider_id}` and claims one invite use at install PREFLIGHT so a cap-one
  invite cannot be validated-then-wasted by many concurrent installers during a
  10–30 minute install. The reservation is authoritative, idempotent by
  `(campaign, provider_id)` — re-reserving the same code extends the same
  reservation and returns the same `reservation_id`; a different code for the
  same provider returns reason `conflict`. It uses a 30-minute TTL (longer than
  the inline register-time reservation), returns `required:false` when
  enforcement is disabled, and reason-codes failures like validate (missing,
  invalid, expired, revoked, exhausted, conflict) with HTTP 200 except 429 for
  rate limit and 400 for bad request. Same public, unauthenticated, rate- and
  slot-bounded treatment as validate. The App-track register body carries an
  optional advisory `referral_reservation_id`; the register transaction still
  resolves the reservation idempotently by `(provider_id, referral_code)`.
- `GET /v1/provider/referrals` authenticates with the provider bearer and
  returns advocacy eligibility, public invite code when eligible, capacity, and
  usage, including whether the optional social bonus is enabled. A social
  verification awaiting promotion reports advocacy status
  `pending_social_review` and does not yet count the bonus.
- `POST /v1/provider/referrals/x/challenge` authenticates the provider, requires
  serving eligibility, creates one expiring provider/campaign-bound challenge,
  and returns an X intent URL.
- `POST /v1/provider/referrals/x/verify` authenticates the provider, accepts a
  canonical public X post URL, verifies it through the official X API, and
  atomically consumes the challenge while recording the verification PENDING with
  the bound X author id. It does NOT grant the bonus inline (FIX-570 H3); the
  bonus is granted later by the promotion reconciler (§8).

Public validation and reservation are advisory and always mounted: they return
`required:false` when enforcement is disabled. Credential mint always revalidates
and redeems inside the mint transaction. Nginx explicitly forwards the
validation, reservation, provider advocacy, X, and `/j/` landing routes to the
buyer-port handler. The `/j/<code>` route is mounted PERMANENTLY (FIX-570 M5):
when gating is disabled it serves an open-beta landing (download CTA) rather than
404ing invite links already in circulation.

## 8. Serving and social eligibility

Base invite issuance requires at least one verified settlement receipt for the
provider. A social challenge cannot be created before that evidence exists.
X failure, outage, protected/deleted content, or verification failure leaves the
provider live and its base invite unchanged.

Submitted post URLs MUST be canonical HTTPS `x.com/<user>/status/<numeric-id>`
URLs. The verifier sends only the extracted numeric post ID to the fixed
official API origin. A post must contain the provider's invite URL and the
opaque, single-use challenge marker. One post ID may satisfy at most one
challenge. Challenge hashes, expiry, consumption, and minimal post evidence are
durable; post bodies and handles are not retained.

### 8.1 Deferred, dwell-gated social bonus (FIX-570 H3)

A single transient post MUST NOT permanently increase capacity. Verification is
recorded PENDING and binds the post's X author id (requested via the
`author_id` expansion). No capacity bonus is granted at verify time. A
background reconciler promotes matured verifications: after a 30-minute dwell it
re-checks through the official API that the post is STILL public and STILL
authored by the bound account, then grants the configured bonus exactly once
(idempotent, guarded by a durable `granted_at`). A post that is deleted or
protected before the dwell elapses is marked failed and never grants; a failed
verification is not resurrected by a later successful re-check. When the API
omits the author id the binding degrades gracefully to a public-only re-check
(the residual: authorship swaps by the same deletion-and-repost pattern are not
detected in that degraded mode, but the transient-post grant is still gone).
Verifications recorded before this change are treated as already granted and are
never re-granted.

### 8.2 Operator referral administration (FIX-570 H4/H5)

Seed creation is INSERT-only: re-running `create-seed-referral` for an existing
seed fails loudly rather than silently overwriting capacity (which could strand a
live code). Capacity changes go through `adjust-seed-referral`, which previews by
default (current capacity, redeemed count, live reserved count, resulting
remaining), requires `--apply`, `--actor`, and `--reason` to mutate, and refuses
to set capacity below the redeemed-plus-reserved floor. A revoked provider issuer
has a supported successor path via `replace-referral-issuer`, which mints a fresh
usable issuer bound to the same provider (the old issuer stays revoked and is
linked to its replacement) and requires `--actor` and `--reason`. Every applied
seed adjustment and issuer replacement writes an append-only
`referral_admin_audit` row (actor, reason, action, target, detail, timestamp).

### 8.3 Durable attempt-marker retention (FIX-570 L1)

The durable `provider_register_attempts` table (which anchors lost-response
recovery and crash reconciliation, §5) grows one row per successful App-track
registration. Its `prune_provider_register_attempts(retain_for)` maintenance
function is deliberately `REVOKE`d from the runtime `provider_onboarding` role
and rejects a `retain_for` under 7 days, so retention is an OPERATOR/DBA task,
not a runtime path — mirroring `prune_provider_register_nonces`. Operators
schedule it (e.g. a daily cron with an elevated maintenance role and
`retain_for => INTERVAL '30 days'`) alongside the existing nonce-pruner job.
Because the row count is bounded by real successful registrations (a gated,
low-volume pre-beta surface), unbounded growth is not a runtime risk between
maintenance runs.

## 9. Client transport

The installer accepts referral environment/flag input, performs advisory
validation before download for fresh identities, and writes `referral_code` to
provider configuration. A protected existing provider bearer bypasses client
preflight during repair or upgrade. Malibu.app passes only a non-secret repair
signal after confirming the config-bound bearer in Keychain; the installer
also requires the app-ownership marker and provider ID. In app-managed repair
mode the installer commits the verified binary/config transaction without
starting or health-gating credential-less launchd. Malibu.app then starts its
app-managed CLI child with the Keychain bearer through a sanitized environment;
the CLI removes that variable immediately after configuration resolution. The
bearer is never added to argv, config, or the launchd plist. Authoritative
server validation still rejects any genuinely fresh tokenless attempt. Swift
config supports YAML,
`MACPROVIDER_REFERRAL_CODE`, and CLI override precedence. Credential-bootstrap
messages include the referral only during first mint. App-track includes the
referral in its signed registration body. Existing bearer reconnects do not
resend or rebind attribution.

Fresh Malibu.app onboarding follows the coordinator's effective `required`
policy; when gated it requires an explicitly entered or user-pasted code before
invoking the installer. After the first verified serving, the dashboard
offers an explicit private-copy action. When the social bonus is enabled, it
also offers an optional X intent plus a separate public-post verification step.
The UI states that skipping or failing social verification does not affect the
provider's live state.

## 10. Rollout and compatibility

Both flags default off. Disabling referral enforcement restores the existing
admission policy without deleting attribution, and the `/j/` route stays mounted
to serve an open-beta landing so previously-circulated invite links keep
resolving (FIX-570 M5). Disabling social bonus prevents new challenges/bonuses
without rewriting existing verification. Re-enabling a
flag never demotes or re-gates grandfathered providers; the campaign applied at
join remains stored. A grandfather cutoff is not provider-ID proof: it may be
applied only when a retained receipt identity proves cryptographic custody or an
operator explicitly authorizes recovery. Persisted same-campaign grandfather
decisions survive later cutoff changes.

## 11. Acceptance criteria

1. Missing, invalid, expired, revoked, wrong-campaign, and exhausted referrals
   mint no credential and create no identity, admission, or redemption.
2. Cap-one concurrent redemption yields one successful token/redemption.
3. Lost-response retry never consumes twice; receipt-key bootstrap can recover
   a replacement token, while other paths fail closed if the original active
   token was already committed.
4. All public first-mint paths enforce the same policy; bearer reconnect and
   current-bearer App-track reissue remain exempt.
5. Restart and admission pruning do not restore capacity.
6. Provider invite aliases do not reveal provider IDs.
7. Social verification cannot change admission or reward trust.
8. Cross-provider, expired, replayed, duplicate-post, and concurrent social
   verification fail closed. A verification grants its bonus only after the dwell
   window and a re-check confirming the post is still public and still authored
   by the bound account; a post deleted before the dwell grants nothing, and no
   verification is ever granted twice (FIX-570 H3).
9. X outage never blocks registration or serving.
10. Tests and logs prove secrets, codes, challenges, post bodies, and bearer
    credentials are not disclosed.
11. App-track crash recovery preserves a token only when the exact PostgreSQL
    nonce/identity attempt committed; otherwise it restores capacity without
    deleting a historical same-campaign redemption.
12. Preflight reservation claims one use idempotently by `(campaign, provider_id)`,
    surfaces `exhausted`/`conflict` under contention, and returns `required:false`
    when disabled (FIX-570 H1).
13. Seed creation is insert-only; capacity is changed only through an audited
    dry-run-by-default adjustment that refuses to drop below redeemed-plus-reserved,
    and a revoked provider issuer has an audited replacement path. All applied
    admin mutations write an append-only audit row (FIX-570 H4/H5).
14. The `/j/` route stays mounted when gating is disabled and serves an open-beta
    landing instead of 404 (FIX-570 M5).
