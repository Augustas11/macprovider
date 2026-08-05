# SPEC-034 — Referral admission, provider invites, and advocacy rewards

Version: v0.4.6
Status: recovery implementation; production activation prohibited except §8 one-time exception
Owner: coordinator admission and referral services
Product parent: https://github.com/MalibuAI/malibu/issues/46

Changelog:

- v0.4.6 (2026-07-29): closes the B6 identity re-registration wash by
  requiring referral admission whenever a coordinator deployment enables a
  fresh provider-token mint surface (`auth.allow_tokenless_provisional_bootstrap`
  or `onboarding.app_track_register_enabled`). Public validation, join links,
  and social rewards remain separately gated.
- v0.4.5 (2026-07-19): adds stable requirement `SPEC-034-R001` for
  fragment-only public referral authority, capability negotiation, immutable
  download gating, and reversible activation.
- v0.4.4 (2026-07-19): adds `referral_fragment_links_v1` as the fail-closed
  negotiation boundary for the breaking URL grammar, makes reviewed Vercel
  source the sole fixed download authority, and removes the obsolete Cloudflare
  path/query edge authority and coordinator `join_download_url`.
- v0.4.3 (2026-07-19): moves invite codes and X challenges into the exact
  `https://malibu.tech/j#/<code>[?c=<challenge>]` fragment grammar, keeps them
  out of website/CDN/referrer request URLs, and requires direct exact-origin
  JSON validation against the coordinator.
- v0.4.2 (2026-07-18): makes `https://malibu.tech/j` the canonical public
  invite origin and requires a referral before any expensive work in a fresh
  private-prebeta Malibu or direct installer journey. Restart-safe incumbents
  remain unaffected.
- v0.4.1 (2026-07-16): defines the authenticated `join_base_url` projection,
  keeps X challenge secrets and composer intents inside the CLI, and bounds
  Malibu referral refresh/staleness behavior.
- v0.4.0 (2026-07-16): recovers the archived referral authority against the
  launchd-managed CLI lifecycle. Removes preflight reservations, Malibu bearer
  custody, App-managed provider children, direct Malibu coordinator calls, and
  dashboard-triggered serving awards. Adds the canonical CLI registration path,
  coordinator-evidence qualification, server-side auditable X verification,
  capability-gated Malibu projection, failure recovery, and the physical
  activation gate.
- v0.3.0 and earlier are archived history. Their App-track registration,
  reservation, App-Keychain bearer, App-managed child, and direct Malibu auth
  contracts are superseded by this version and MUST NOT be restored.

## 1. Objective and authority

A new provider can redeem a referral through the installed CLI, become
buyer-serving, earn invite capacity from coordinator-authoritative serving
evidence, refer another provider, and optionally earn bounded repeat bonuses
for distinct server-verified X posts.

The coordinator is authoritative for code validity, redemption, attribution,
invite balances, serving qualification, social decisions, grants, and audit.
The launchd-managed `macprovider-cli` is authoritative for provider identity,
admission keys, bearer custody, registration, provider process management,
updates, and local lifecycle status. Malibu is an input, interaction, and
monitoring surface. It MUST NOT receive the provider bearer, sign provider
admission, restore `RegisterClient`, pass `--token-fd`, or launch/supervise a
second managed provider process.

SPEC-003 owns open-onboarding admission integration. SPEC-001 owns wire and
local-status shapes. SPEC-025 and SPEC-026 own the native App and browserless
CLI lifecycle. SPEC-022 owns verified settlement receipts. This specification
consumes those authorities and owns only referral and advocacy policy.
`pair_ot`, `claim_url`, and `provider_ownership` are GitHub ownership-binding
surfaces; they MUST NOT be used as referral codes, admission grants, or invite
capacity.

### 1.1 Fresh registration admission invariant

When `auth.allow_tokenless_provisional_bootstrap` or
`onboarding.app_track_register_enabled` is true,
`referrals.require_for_registration` MUST also be true. A deployment that can
mint a provider token for a fresh `provider_id` MUST require operator-issued
referral admission before token disclosure. This is the B6 anti-wash control: a
sanctioned provider identity cannot be bypassed by generating a fresh keypair
and self-registering a new `provider_id` through an open mint path.

The coordinator's WS tokenless bootstrap, credential-bootstrap v2, admission
pair-OT mint, and app-track registration paths MUST redeem referral admission in
the same durable transaction as the fresh provider-token mint whenever this
policy is enabled. Existing-provider recovery and reissue flows may bypass new
referral capacity only when they preserve the same `provider_id` and prove
current credential custody or the exact retained bootstrap receipt key defined
by SPEC-003; they MUST NOT mint an unrelated fresh provider identity.

Open fresh registration is valid only when all fresh provider-token mint
surfaces are disabled, or under a future reviewed normative exception that
supersedes this invariant and names its anti-abuse substitute. Enabling public
validation, join links, or social rewards is not implied by this invariant.

## 2. Canonical provider journey

1. A user obtains a valid operator seed code or canonical provider invite URL
   `https://malibu.tech/j#/<code>`.
2. Malibu accepts the code as untrusted input and performs only bounded syntax
   validation. It does not claim server validity.
3. Malibu invokes a supported signed installed-CLI/install onboarding
   interface with the code.
4. The CLI creates or recovers its provider identity, receipt/admission key, and
   serialized restart-safe registration attempt, then sends the code during tokenless WS
   `credential_bootstrap`.
5. The coordinator atomically validates the campaign, code digest/signature,
   issuer, expiry, revocation, and capacity, and commits attribution,
   redemption, exact receipt-key binding, and bootstrap credential issuance.
   This bootstrap-only connection does not create a routable provider session.
6. A retry with the same provider, campaign, receipt-key custody, and code
   converges on one active credential and one redemption. Before first use the
   coordinator may replace only the unused bootstrap token owned by that exact
   receipt key. A different code for an attributed provider conflicts
   without consuming capacity.
7. The CLI persists the bearer in CLI-owned Keychain before adoption. Malibu
   never receives it.
8. launchd starts or retains the single managed CLI provider. On its later
   bearer-authenticated connection, the coordinator performs the normal
   compatibility, admission-identity, capacity, and pool admission decision.
   Only then is the provider operational; buyer serving follows that lifecycle.
9. A coordinator reconciler observes the first closed, valid, verified
   settlement receipt and idempotently unlocks the provider's base invite.
   Malibu state and referral status reads are never award triggers.
10. The CLI reads coordinator referral status and projects a sanitized,
    versioned invite URL and balance to Malibu. Malibu may copy/share the link.
11. A second provider redeems that invite through the same CLI-owned flow.
12. The inviter may request an X challenge through Malibu's typed local CLI
    boundary; the CLI authenticates to the coordinator. The provider publishes
    the challenged invite post and submits its canonical URL through that same
    CLI-owned boundary.
13. The coordinator verifies the public post, canonical URL, author, challenge,
    invite link, dwell period, and recheck server-side.
14. The coordinator grants bonus capacity exactly once and exposes its
    authoritative state. Malibu renders disabled, locked, pending, failed,
    matured, exhausted, revoked, and unavailable states truthfully.
15. Response loss, retries, restarts, duplicate evidence or submissions,
    expired/exhausted/revoked codes, external X failures, abuse, disabled flags,
    and rollback recover from durable state without deleting a working identity,
    starting another provider process, or duplicating a redemption or award.

`SPEC-034-R001` — Public referral and X-share URLs MUST use the exact
`https://malibu.tech/j#/<code>[?c=<challenge>]` fragment contract. The
coordinator, CLI, and Malibu MUST reject legacy or alternate authorities;
Malibu MUST require `referral_fragment_links_v1`; Vercel production MUST fail
closed until the exact public immutable Malibu release, manifest, checksum, and
DMG bytes agree; and activation or rollback MUST follow §8 without treating the
one-time Air exception as #613 conformance.

## 3. State and authority matrix

| State field | Authoritative writer | Durable source of truth | Reader / consumer | Idempotency key | Recovery behavior | User-visible state | Acceptance test |
|---|---|---|---|---|---|---|---|
| Referral input | User through Malibu; CLI adopts it | Owner-only CLI onboarding journal until terminal result; never Malibu credential storage | CLI registration only | Provider ID + exact receipt public key + campaign/code attribution | Resume the same attempt after App/CLI restart; bounded retention; raw code redacted from logs | `entered`, `validating`, typed error; never `accepted` before coordinator commitment | Restart during onboarding preserves attribution and identity |
| Provider identity | CLI | CLI config and admission-key Keychain items; coordinator stores the public binding | CLI and coordinator proof verifier; Malibu gets redacted provider ID only | Provider ID + admission-key generation | Reuse existing identity; referral failure never replaces it | Existing identity remains operational | Retry retains exact provider ID and key |
| Live CLI registration attempt | CLI creates and serializes; coordinator binds the proven receipt key | Owner-only CLI onboarding journal plus auth SQLite `provider_bootstrap_identities`, token, referral redemption, and mint log rows | CLI retry logic, coordinator admission, operator diagnostics | Provider ID + exact receipt public key + campaign/code attribution | Lost response retries with the same key; only its unused bootstrap token may be replaced, leaving one active token and one redemption | `registering`, `retrying`, or typed terminal failure | Drop the WS response after commit; same-key retry yields one active credential/redemption and different-key retry fails |
| Dormant HTTP compatibility attempt | Dormant `/v1/providers/register` handler | PostgreSQL `provider_register_attempts` from migration 018 plus its auth SQLite saga | Compatibility handler/reconciler only; not the live Malibu/CLI journey | Signed `(provider_id, nonce, ts_utc)` | Reconciles cross-store ambiguous commits without becoming a Malibu authority | No production UI state | Migration forward/backward/reapply and dormant-handler response-loss tests |
| Provider bearer | Coordinator mints; CLI takes custody | Coordinator token store for verification; CLI Keychain for runtime custody | CLI and coordinator only | Provider/token uniqueness within the registration transaction | Persist-before-use; never disclose to Malibu, argv, token-fd, UI, or logs | Redacted credential condition only | Secret scan and process inspection find no Malibu bearer |
| Referral policy | Coordinator/operator | Versioned coordinator configuration | Admission, reconciler, APIs, operator tooling | Config revision + campaign | Flags default false; disabling restores the prior admission policy and preserves committed state | `disabled` or `unavailable`, not zero balance | Missing/false flags leave incumbents unaffected |
| Public code validation | Coordinator/operator deployment | `referrals.enable_public_validation` config, default false | HTTP router and edge/deploy checks | Config revision | False means `/v1/referrals/validate` is not mounted; CLI bootstrap still validates codes authoritatively | Local syntax-only or `unavailable` until activated | Default/off route absent; enabled route is bounded and rate-limited; rollback removes exposure |
| Public join exposure | Coordinator/operator deployment | `referrals.enable_join_links` config, default false, plus reviewed Vercel route and fixed download configuration | Coordinator projection, Vercel `/j` page, status/operator tooling | Config revision | False means no invite URL is projected; rollback suppresses links without deleting issuers | Link unavailable until explicitly activated | Default/off status omits links; enabled page validates through the bounded body-only endpoint; disable rollback removes exposure |
| Issuer and code | Coordinator/operator seed path or serving reconciler | Auth SQLite issuer row plus keyed code digest and policy version | Admission gate, join resolver, status, operator tooling | `(campaign, issuer_id)`; provider issuer additionally `(campaign, provider_id)` | Duplicate qualification is a no-op; raw code is not stored where a digest suffices | `locked`, `available`, `expired`, `revoked`, `exhausted` | Duplicate qualification creates one issuer |
| Code validity | Coordinator | Issuer row, keyed digest, expiry, revocation, campaign, capacity | Admission transaction | Campaign + code digest | Invalid/expired/revoked/exhausted consumes nothing and returns a stable typed reason | Exact truthful failure with retry guidance | Valid, invalid, expired, revoked, exhausted cases have expected side effects |
| Redemption and attribution | Coordinator | Auth SQLite redemption, referral-admission decision, bootstrap identity, token, and mint-log rows | Auth bootstrap, later operational admission, status, operator audit | `(campaign, referred_provider_id)` plus exact receipt key and same-code digest equality | Same code/provider/key is idempotent; different code conflicts; bootstrap commitment leaves no half-state but does not itself create a routable session | `credential_committed`; not yet operational | Concurrent last-capacity redemption produces one bootstrap winner and no pool entry |
| Operational admission | Coordinator WS admission path | Confirmed token/bootstrap identity, provider-admission store, and registered pool session | CLI lifecycle, buyer router, Malibu sanitized lifecycle projection | Bearer/token ID + provider ID + admission-identity generation | Happens only on the later authenticated connection; failed or lost reconnect preserves the credential for safe retry and never creates a second provider process | `admitted`, then `buyer_serving` only from the normal lifecycle | Bootstrap-only connection is unroutable; authenticated reconnect admits once and survives restart |
| CLI lifecycle | launchd-managed CLI | launchd unit, CLI state/config/Keychain, versioned local status | Malibu monitor and operator tooling | Service instance + observation identity | Malibu reattaches after restart; it never creates a child | Installing, reconnecting, admitted, buyer-serving, or recoverable error | At every step exactly one managed provider process exists |
| Buyer-serving display | CLI from its authoritative lifecycle | Versioned local `/v1/status` projection | Malibu | Status contract/capability + observation identity | Local-ready alone never implies reward qualification | `buyer_serving` only when CLI reports it | Malibu/CLI restart does not invent eligibility |
| First-serving evidence | Buyer/coordinator settlement system | Closed `settlement_receipt_verdicts` row with verified outcome and valid receipt per SPEC-022 | Coordinator referral reconciler; status reads are observational | Receipt/request identity; qualification `(campaign, provider_id)` | Pending, invalid, or duplicate evidence grants nothing; reconciler retries safely | `locked_until_first_serving` until durable qualification | No invite before evidence; one invite after first verified receipt; replay no-op |
| First-serving qualification | Coordinator reconciler | Issuer/qualification row with evidence reference and earliest qualifying time | Status, operator audit, invite service | `(campaign, provider_id)` conditional insert/update | Preserve earliest authoritative evidence under duplicates/out-of-order delivery | `eligible` with evidence-derived timestamp | Two reconcilers and duplicate evidence create one base grant |
| Invite balance and link | Coordinator | Issuer base/bonus capacity minus committed redemptions plus configured HTTPS `join_base_url` | Authenticated CLI API, Malibu sanitized projection, `/j#/<code>` landing page | Issuer/campaign and redemption IDs | Read is side-effect free; CLI and Malibu accept only the exact `join_base_url#/<code>` projection; retry never decrements twice | Available, exhausted, disabled, or unavailable with exact remaining count | A public join origin distinct from the coordinator is accepted only when coordinator status declares it; redemption decrements exactly once |
| X challenge | Coordinator | Hashed challenge, expiry, provider/campaign binding, issued/consumed times; CLI-owned 0600 pending-challenge journal holds the raw challenge, exact invite URL, and composer intent | CLI and verification service; Malibu sees expiry/state only | One active `(campaign, provider_id)` challenge + random digest | Replacement/expiry is explicit; CLI restores or reopens only after a fresh status read confirms social rewards and the exact invite binding; raw challenge, share URL, and composer intent never cross into Malibu | `challenge_ready`, `expired`, or retryable failure | Duplicate request and restart respect challenge and rate limits; flag disable or join/code rotation clears local pending state; local frames contain no nonce or intent URL |
| X submission | Coordinator | Positively verified canonical post ID/URL digest and provider/campaign/challenge binding; terminal failures use a separate provider-scoped failure row | Verification/recheck worker, audit, status | Verified post ID is globally unique; terminal failure uses `(campaign, provider_id, challenge_digest, post_id)` without reserving the post globally | Duplicate same submission converges; a positively verified reused post or author mismatch rejects; an unverified rejected post cannot deny another provider's later legitimate verification | `pending`, `failed`, or `matured` with truthful reason | Success, bad URL, wrong author, wrong link, replay, cross-provider rejected-post reuse, and rate-limit cases |
| X verification decision | Coordinator server-side verifier | Current verification or terminal-failure row plus append-only social decision audit | Bonus transaction, status, security/operator review | Verification attempt/event UUID and expected prior state | External transient failure is retryable; terminal failure is stable and response-loss safe without claiming global ownership of unverified evidence; redirects and untrusted origins fail closed | Pending/retryable/terminal failure separated | Audit records challenge, submit, recheck, decision, and redacted cause |
| X observed-author binding | Coordinator records the positive X API result | Numeric `author_id` in the pending verification and immutable history/audit | Recheck worker and security/operator review | Globally unique positively verified post ID + initial numeric author ID | This is continuity of the observed post author, not proof the provider owns an X account; recheck must return the same nonempty numeric author or fail terminally | No ownership badge; only pending/failed/matured reward state | Empty/non-numeric author rejects; changed author on recheck fails; exact author continuity may mature |
| Bonus grant | Coordinator | Conditional verification `granted_at` plus issuer bonus or dedicated grant row and audit event | Status and operator audit | `(campaign, provider_id, bonus_kind)` where repeatable grants bind `bonus_kind` to the positive post digest | Transactional conditional grant makes parallel rechecks no-ops after one winner; configured provider/campaign max-grant cap prevents unbounded minting | `matured` and exact bonus/remaining counts, plus repeat grants remaining when social bonus is enabled | Concurrent promotion grants capacity once per distinct verified post and never above the provider cap |
| Operator mutation | Coordinator CLI/admin path | Append-only audit with actor, reason, target, expected prior state, result | Operators/security review | Audit event UUID + compare-and-swap expectation | Dry-run and expected-value checks prevent stale writes; rollback is explicit | Not exposed as provider success until committed | Seed, adjust, replace, revoke, and raced mutation audit tests |
| Malibu referral projection | CLI writes sanitized status from coordinator authority | Versioned local status/control response; no App-side policy database | Malibu only | Capability name + schema version + coordinator revision | Unsupported older/newer CLI renders unavailable and suppresses actions | Truthful disabled/locked/pending/failed/matured/exhausted/revoked/unavailable states | Independent Malibu/CLI marketing versions negotiate by capability, not equality |

## 4. Admission atomicity and replay

Codes use the recovered typed `MAL1-<S|P>-...` form. The coordinator stores
normalized issuers and keyed digests; HMAC authenticates encoding while database
state remains authoritative for campaign, existence, expiry, revocation, and
capacity. Comparison is constant-time and unknown versions, keys, types,
campaigns, or malformed tags fail closed.

Referral enforcement applies only to a fresh public credential/bootstrap when
`referrals.require_for_registration=true`. It MUST NOT retroactively reject a
valid incumbent bearer, identity rotation/recovery, pinned/operator issuance, or
other explicitly authenticated reconnect. The flag defaults false.

Fresh admission reserves no preflight capacity. The live CLI path performs code
validation, capacity consumption, one-provider/one-campaign attribution,
receipt-key binding, and bootstrap token mint in one auth SQLite transaction.
A serialized same-key response-loss retry may replace only the exact unused
bootstrap token; it cannot consume a second use, change attribution, claim an
ordinary principal, or leave two active credentials. The migration-018
PostgreSQL commitment ledger remains the recovery authority only for the dormant
cross-store HTTP compatibility handler. It is not the live Malibu/CLI attempt
journal and MUST NOT be represented as one.

Bootstrap commitment and operational admission are separate decisions. The
bootstrap-only socket closes after credential delivery and MUST NOT reserve a
provider-admission slot or register a pool entry. After the CLI has persisted the
bearer, its later authenticated WS connection executes the existing
compatibility, admission-identity, capacity-reservation, token-confirmation, and
pool-registration sequence. Failure or response loss between those decisions is
recovered by reconnecting with the same CLI-owned credential; it MUST NOT undo
the referral redemption or mint another identity.

## 5. Serving qualification and invites

Only coordinator/buyer evidence qualifies serving: a closed settlement receipt
whose settlement outcome is `verified` and receipt result is `valid` under
SPEC-022. Malibu reports and local provider claims are never qualification
evidence. Qualification is processed by an event consumer or durable periodic
reconciler; a status GET MUST be read-only and MUST NOT be the action that creates
an issuer or awards capacity.

The first qualifying evidence creates/unlocks the provider issuer with the
configured base capacity exactly once. An invite link is projected only when the
independent `referrals.enable_join_links` flag is true. The flag defaults false.
The Vercel `/j` document is inert without a valid fragment, contains no
third-party runtime, clears the fragment before coordinator or other
credential-dependent network activity, and validates the code by direct
exact-origin JSON POST to the coordinator. Static same-origin CSS/module
requests may precede the scrub because browser fragments are not part of those
HTTP requests. The coordinator
MUST NOT mount the legacy credential-bearing `/j/<code>` route. Rollback
suppresses link projection without deleting referral state. The download target
is a fixed reviewed release owned by reviewed Vercel source, never a moving
`latest` URL, and deployment MUST fail until that exact signed/notarized public
asset exists. The coordinator has no second download-URL authority. Operator seed creation,
replacement, adjustment, and revocation require actor/reason, dry-run where
applicable, compare-and-swap protection, and append-only audit.

## 6. Advocacy and X reward

Social rewards never change admission tier, routing trust, reward trust, payout
eligibility, or provider operational state. `enable_social_invite_bonus` defaults
false and cannot activate unless referral admission/status policy is coherent.

The coordinator issues a random expiring challenge, stores only its digest where
possible, and binds it to provider, campaign, and expected invite. Verification
uses a fixed configured X API origin, refuses redirects, bounds response bodies,
accepts only canonical `x.com` post URLs, requires an exact author binding and
invite reference, and rechecks after the configured dwell. Application and edge
rate limits bound challenge, submission, and recheck abuse; the durable decision
audit survives process restarts and multi-replica execution.

The CLI alone receives the raw challenge, share URL, and X composer intent. It
validates the exact HTTPS intent shape, durably stores the pending challenge in
an owner-only 0600 journal bound to the exact current invite URL, and opens the
composer. Before restoring or reopening it, the CLI refreshes coordinator status
and requires social rewards plus that exact invite binding to remain current;
disablement or join/code rotation clears the journal. Malibu receives only the
pending expiry and coordinator-authored referral state. Reopen, cancel, restart,
response-loss recovery, and terminal verification therefore never require the
App to possess the nonce or an authenticated coordinator secret.

The initial X API lookup records the post's nonempty numeric `author_id`; every
recheck must observe that exact author. This is post-author continuity only. It
does not assert that the provider controls the X account and MUST NOT be rendered
as account ownership. A future ownership claim requires a separate proof flow.

Every challenge issuance, submission, external response classification, recheck,
terminal decision, and grant writes an append-only redacted audit event. A post
ID becomes globally replay-protected only after the initial server-side lookup
positively verifies the exact invite URL and a numeric author. Terminally
rejected, unverified post IDs remain provider/challenge-scoped failure evidence
and MUST NOT reserve the global replay key or deny another provider's later
legitimate verification. Bonus promotion and `granted_at` commit atomically with
the issuer balance using the grant identity
`(campaign, provider_id, bonus_kind)`. Parallel workers therefore produce one
grant and any number of idempotent observations.

## 7. CLI/Malibu boundary and compatibility

Malibu passes referral input only through SPEC-025/026's concrete
`referral_bootstrap_v1` contract: sanitized one-shot install environment,
CLI-owned 0600 digest-only attempt journal, and
`bootstrap-auth --referral-code-file`. For a fresh bundled install, Malibu relies
on its compiled-in v1 install handoff and
hashes the exact regular-file `Contents/Resources/install.sh` bytes it is about
to execute. Those bytes MUST equal the existing signed manifest's
`components.launchd.install_contract.sha256` for
`compatibility-set-local/install.sh`; missing, symlinked, unreadable, or
mismatched resources fail unavailable before execution. Compatibility-set v1
has no capability field and MUST NOT be extended in place. Because Malibu always
executes that bundled installer, its compiled handoff gate applies to existing
installs as well. An existing installed CLI additionally requires
`referral_bootstrap_v1` in the CLI-authored local status contract before offering
input. It invokes later typed referral actions over an owner-only local
interface. The CLI owns all authenticated coordinator calls and exposes only a
sanitized owner-only control-socket projection under `referral_status_v1`.
Typed challenge/verify/cancel/reopen actions additionally require
`referral_advocacy_v1`; a status-capable CLI without that capability remains
read-only for advocacy. Repeat actions after an already matured X bonus
additionally require `referral_repeatable_advocacy_v1` and coordinator status
field `social_bonus_grants_remaining > 0`; without that repeatable capability,
Malibu MUST suppress post-maturity X actions even when the old advocacy
capability is present. A repeatable grant is bounded by
`social_bonus_max_grants_per_provider` for the campaign and is keyed by the
verified post digest, so a distinct post can grant once and the campaign cap
prevents unbounded invite minting. The share/challenge invite URL is a canonical
binding target and may remain present even when `remaining == 0`; Malibu MUST
separately gate copyable invites on positive remaining capacity.
All referral projection and actions additionally require
`referral_fragment_links_v1`; its absence suppresses referral UI rather than
falling back to the legacy path/query grammar. Malibu and CLI marketing versions are independent;
compatibility is negotiated by advertised protocol capabilities and schema
versions. Missing or unknown capability means unavailable, never an inferred
zero balance or eligibility decision.

During private-prebeta referral enforcement, a genuinely fresh public
installation MUST obtain a nonblank referral before release download, autotune,
model download, or provider mutation. Malibu renders the invite field as
required and returns the typed `required` correction without starting its
installer. The direct interactive installer prompts once and writes the input
only to the same owner-only 0600 regular source-file contract; a noninteractive
fresh invocation without that file exits 20. A restart-safe incumbent provider
with durable identity plus credential or committed install evidence bypasses
this fresh-only prompt and continues its existing update/recovery path.

Authenticated referral status includes a credential-free HTTPS
`join_base_url` ending in `/j`; it may intentionally use a public host different
from the coordinator API. The CLI validates the coordinator's invite URL as the
exact `join_base_url#/<code>` value and Malibu repeats that fail-closed binding on
the sanitized projection. Malibu refreshes status no faster than once per 60
seconds, stops presenting it as current after 90 seconds, and clears it when the
owner-only control connection closes. Social-only rollback suppresses advocacy
actions without erasing a still-valid base invite projection.

On registration error, the CLI preserves any working provider identity and
credential, records a bounded recoverable attempt, and returns a typed error.
Malibu presents retry or correction without deleting state. After success Malibu
attaches to the existing launchd provider.

## 8. Activation, rollback, and acceptance

Production public-validation, join-link, and social-reward flags remain disabled
until all server and client PRs are merged and the exact signed artifacts pass
the following physical journey. `referrals.require_for_registration` may be
enabled independently as the §1.1 anti-wash admission gate when fresh
provider-token mint surfaces are enabled; that setting alone is not public
referral activation. Public configuration activation is a separate reviewed
change with an explicit rollback. Rollback restores the prior public exposure
policy, removes public validation/join and new social-reward exposure, and
preserves committed attribution, tokens, invites, grants, and audit.

Required automated evidence:

- migration 018 forward, backward, reapply, and idempotent upgrade;
- valid, invalid, expired, revoked, exhausted, replayed, and concurrently
  redeemed codes, including response loss after commit;
- incumbents unaffected with flags off/on as policy permits; fresh admission and
  CLI-owned credential persistence;
- restart during onboarding and exactly one launchd-managed provider process;
- no invite before authoritative evidence; one invite after first verified
  serving; duplicate and concurrent evidence no-op;
- invite-link redemption exactly once;
- X success, transient/terminal failure, author/link mismatch, replay,
  cross-provider reuse after an unverified rejection, rate limiting, audit,
  concurrent recheck, and exactly-once bonus;
- referral admission required whenever fresh provider-token mint surfaces are
  enabled, public validation, social reward, and public join flags absent/false
  by default, safe route/config rollback, and retained durable state;
- older/newer independent Malibu and CLI capability combinations with truthful
  unavailable states; and
- fresh-bundle exact installer-digest match plus missing, symlinked, and
  tampered/mismatched resource rejection before execution; and
- targeted, affected full-suite, race, static, and security review evidence.

Physical acceptance uses two Macs and production-equivalent coordinator/buyer
services with flags still disabled outside the controlled cohort. One provider
enters a code through Malibu, registers through the CLI-owned lifecycle, retains
its credential across restart, becomes buyer-serving, earns its base invite from
verified settlement evidence, and refers the second provider. The first provider
then submits an X post and receives the bonus exactly once after server-side
verification. Process inspection proves one provider process per Mac and secret
inspection proves Malibu never holds the bearer. Only this complete result may
authorize a later activation PR.

One narrow exception applies only to the owner-authorized 2026-07-19
fragment-link activation recorded in Decision Entry 172. Because the second
acceptance Mac is unavailable, the controlled order is: deploy the exact signed
client assets, coordinator, and Vercel source while flags remain off; keep the
existing sponsor buyer-serving; enable public validation and join links; prove
hostile-origin rejection, fragment-free edge requests, and Copy → Download →
Paste; enable the social flag only for the sponsor test; then prove one real X
initial-plus-dwell exactly-once reward. Passing that sequence may keep the
reversible private-prebeta public flags live. Any failure or expiry restores the
prior values of `enable_public_validation`, `enable_join_links`, and
`enable_social_invite_bonus` immediately. The `require_for_registration` flag
remains governed by §1.1 after the exception expires: if a fresh provider-token
mint surface is enabled, it stays required. This exception MUST NOT close #613,
mark the two-Mac journey conformant, claim fresh-provider redemption evidence,
or become precedent for another release. The first available fresh referred
provider MUST complete the missing redemption journey. This exception expires
at `2026-07-26T23:59:59Z`, on terminal success or failure of that first fresh
referred-provider journey, or on any earlier controlled-sequence failure,
whichever occurs first; keeping or re-enabling public flags afterward requires
the complete #613 journey or a new reviewed normative decision.

## 9. Recovery stack

1. Registration commitment ledger (recovered #573).
2. Coordinator referral admission (recovered #574).
3. Join links and operator controls (extracted #576).
4. Coordinator advocacy/X rewards (server replacement for #578).
5. CLI/Malibu onboarding from merged #618 (replacement for #575).
6. Malibu referral/advocacy UI (client replacement for #578).
7. End-to-end physical acceptance and activation/configuration change.

The old five-level stack is historical evidence only. It MUST NOT be mechanically
rebased because its client layers violate the current lifecycle architecture.
