# SPEC-034 — Referral-gated pre-beta and advocacy invite bonus

Version: v0.1.0
Status: implementation
Product parent: https://github.com/MalibuAI/malibu/issues/46

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
- `GET /v1/provider/referrals` authenticates with the provider bearer and
  returns advocacy eligibility, public invite code when eligible, capacity, and
  usage, including whether the optional social bonus is enabled.
- `POST /v1/provider/referrals/x/challenge` authenticates the provider, requires
  serving eligibility, creates one expiring provider/campaign-bound challenge,
  and returns an X intent URL.
- `POST /v1/provider/referrals/x/verify` authenticates the provider, accepts a
  canonical public X post URL, verifies it through the official X API, and
  atomically consumes the challenge and grants the configured bonus once.

Public validation is advisory and always mounted: it returns `required:false`
when enforcement is disabled. Credential mint always revalidates and redeems
inside the mint transaction. Nginx explicitly forwards the validation, provider
advocacy, X, and `/j/` landing routes to the buyer-port handler.

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
admission policy without deleting attribution. Disabling social bonus prevents
new challenges/bonuses without rewriting existing verification. Re-enabling a
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
   verification fail closed.
9. X outage never blocks registration or serving.
10. Tests and logs prove secrets, codes, challenges, post bodies, and bearer
    credentials are not disclosed.
11. App-track crash recovery preserves a token only when the exact PostgreSQL
    nonce/identity attempt committed; otherwise it restores capacity without
    deleting a historical same-campaign redemption.
