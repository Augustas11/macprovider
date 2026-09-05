# SPEC-020 - Provider autoupdate

Version: v0.1.18
Status: Normative; coordinator-independent recovery is reconciled and
implementation remains nonconformant under issue #610. The production path ran
the 2026-07-10 incident-recovery
autoupdate to CLI 1.8.21. Trust-table drift remains resolved as documented in
v0.1.5. v0.1.6 added the complete-payload, shared-mutation-ownership, and
then-required coordinator-authoritative buyer-serving commit gates from Entry
133; v0.1.8 supersedes only that commit-authority choice.
v0.1.7 (runbook item 23) closes the tokenless race-loser residual: the
coordinator propagates its `auth_state` admission verdict on the accept ack so
the bearerless-duplicate notify-only row is client-enforceable.
v0.1.8 makes the signed release and compatibility manifest—not coordinator
admission—the update authority, and separates local update success from network
readiness.
v0.1.9 makes the launchd provider reload explicitly one-shot, fences legacy
reload helpers before mutation or rollback, bridges the already-public v1.8.53
helper through an exact update/handoff-authorized first-hop fence, and requires
a 20-second continuous listener-bound local-health observation before update
commit.
v0.1.10 defines append-only immutable GitHub prereleases named from the signed
discovery sequence. The bounded GitHub release listing is an untrusted locator
only; the signed head, transport-sequence binding, exact numeric target binding,
and persisted monotonic sequence remain update authority. It also records the
one-time supported bridge required for v1.8.55, whose shipped fixed discovery
release is permanently immutable.
v0.1.11 adds the protected recurring renewal signer and the anonymous v1.8.55
bridge proof required before treating discovery as continuously renewable under
immutable releases (Partial #658 until the physical journey closes).
v0.1.12 names SPEC-026's SSH-only `headless_fleet` profile as an explicit
autoupdate boundary. The existing `consumer_user` LaunchAgent and Keychain track
is unchanged; system-domain headless autoupdate/rollback remains a future
extension until this spec adds a corresponding implementation and acceptance
journey.
v0.1.13 removes watchdog rollback ownership. The companion watchdog remains a
local liveness monitor only; installer, Malibu repair, and CLI startup recovery
are the only transaction owners allowed to mutate pending markers, rollback
backups, live release bytes, watchdog scripts, plists, or Malibu app artifacts.

## Goal

SPEC-020 v0.1.11 defines provider-side autoupdate for `macprovider-cli`.
When the coordinator advertises a newer `recommended_binary_version`, the
provider auto-invokes the existing `SelfUpdate` validation and replacement
flow, subject to explicit throttling, opt-out, drain, rollback, and
observability invariants.

The v0.1.8 recovery amendment also covers a provider that cannot establish an
accepted coordinator session. A valid signed release remains discoverable and
installable under the local pinned release trust root. Coordinator policy may
recommend a target but cannot make coordinator connectivity a prerequisite for
repairing an outdated or rejected provider. SPEC-020-R005 (v0.1.14) extends this:
a provider that *is* admitted but whose coordinator-recommended target cannot make
forward progress may also invoke the signed recovery rail, so an accepted-but-stuck
session is not left without a self-heal path.

The baseline implementation already has a mature manual update path in
`phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`: GitHub Releases
lookup, GitHub-host URL validation, ECDSA P-256 signature verification for
`checksums.txt`, SHA-256 tarball verification, tar path-traversal rejection,
new-binary `self-test`, POSIX `rename(2)` replacement, launchd restart, and a
one-hour latest-release cache. SPEC-020 wires that path into the provider
session lifecycle; it does not replace the cryptographic update mechanism.

## Non-goals

- Operator-side staging, canary cohorts, or prerelease channels.
- Auto-rollback past one prior binary.
- Cross-architecture updates; v0.1.0 is `darwin-arm64` only.
- Provider-side capability advertising. Autoupdate is the version-skew
  mitigation; provider-advertised capability flags remain out of scope for this
  SPEC. The coordinator-side drain-extension capability in R-3.3 is the only
  v0.1.0 wire-compatibility exception.
- Coordinator-side policy for choosing
  `coordinator_advertised_version.latest_binary_version`. The operator sets
  it; this SPEC defines only provider behavior after observing it.
- Replacing the existing manual `malibu-cli update` command.

Convergence boundary: SPEC-020 guarantees convergence to latest only for
default-installed, launchd-managed providers with autoupdate enabled and CLI
startup recovery available. Providers with explicit opt-out or unsupported
install topology are outside the latest-assumption population. A missing or
disabled companion watchdog affects local liveness supervision, not rollback
authority. Future features that depend on latest-provider behavior MUST exclude
old binaries via the existing `required_binary_version` admission gate or an
equivalent explicit gate.

### macOS execution profiles and path notation

SPEC-020 v0.1.12 applies to the `consumer_user` profile defined by SPEC-026
§2.1 and records the `headless_fleet` profile as an unsupported autoupdate
topology in this release:

| Profile | `$PROVIDER_CONFIG_ROOT` | `$PROVIDER_STATE_ROOT` | Canonical provider service |
|---|---|---|---|
| `consumer_user` | `$HOME/.config/macprovider` | `$HOME/.local/share/macprovider` | `gui/<uid>/live.malibu.provider` LaunchAgent |
| `headless_fleet` | `$FLEET_HOME/.config/macprovider` | `$FLEET_HOME/.local/share/macprovider` | `system/live.malibu.provider` LaunchDaemon |

The literal `$HOME/.config/macprovider` and
`$HOME/.local/share/macprovider` paths in the requirements below specify the
selected `consumer_user` profile owner. A provider installed as
`headless_fleet` MUST NOT be updated by the v0.1.12 consumer LaunchAgent
autoupdate path, because that path cannot safely prove or recover a system-domain
service. When the consumer autoupdate path recognizes such a provider (v0.1.16:
`protected_file` credential custody, an install manifest declaring the
`headless_fleet` profile or `system` launchd domain, or a managed system-domain
provider LaunchDaemon present on disk / loaded / in an indeterminate launchd
state — full parity with the mutating-update gate), it MUST report the
actionable, terminal skip `reason:"headless_operator_update_required"` with
`outcome:"skipped"`, directing the operator to the separately specified signed
installer acceptance flow. This skip is NOT a forward-progress failure for
SPEC-020-R005 accounting (see R-4.13).
A proven consumer-user topology continues on the normal path; an invalid or
indeterminate topology fails closed to the headless handoff (R-4.13), while a
topology that is unrecognized and non-headless MUST still fail closed as
`unsupported_install_topology`. A user-domain helper MUST NOT bootout,
bootstrap, prove absence of, or authorize rollback for a system-domain provider.

## Cross-spec amendment and trust state

The following trust-state table is normative for autoupdate eligibility:

| Wire path | Tier | Encrypted-leg | Attestation (if required) | Token validation (if configured) | Verdict |
|---|---|---|---|---|---|
| Legacy `hello_ack` | — | — | — | — | notify-only |
| Unauthenticated / token-rejected | — | — | — | — | notify-only |
| v2 `auth_response` rejected | — | — | — | — | notify-only |
| v2 accepted | provisional (`accept_provisional` set — default true) | failed | * | * | notify-only |
| v2 accepted | provisional (`accept_provisional` set — default true) | succeeded with matching AEAD/KID | failed | * | notify-only |
| v2 accepted | provisional (`accept_provisional` set — default true) | succeeded with matching AEAD/KID | satisfied or not-required | rejected | notify-only |
| v2 accepted | provisional (`accept_provisional` set — default true; bearer-validated OR no token configured — see "Eligible does not always mean bearer-validated" below) | succeeded with matching AEAD/KID | satisfied or not-required | validated or not-configured | **eligible** |
| v2 accepted | provisional (`accept_provisional` opted out via `auto_update_accept_provisional: false`) | * | * | * | notify-only |
| v2 accepted | provisional (self-minted; first-time token issuance pending validation — `server.go:834,866`) | * | * | * | notify-only |
| v2 accepted | provisional (bearerless-duplicate; race-loser, no token issued — `server.go:838,851`) | * | * | * | notify-only |
| v2 accepted | pinned | failed | * | * | notify-only |
| v2 accepted | pinned | succeeded with matching AEAD/KID | failed | * | notify-only |
| v2 accepted | pinned | succeeded with matching AEAD/KID | satisfied or not-required | rejected | notify-only |
| v2 accepted | pinned | succeeded with matching AEAD/KID | satisfied or not-required | validated or not-configured | **eligible** |

**Rationale for provisional eligibility.** 100% of the production fleet is
provisional by design: the coordinator ships with an empty `providers: []`
pin list, so every self-service `curl | bash` install is admitted at
`tier: provisional`, including the production `mac` provider (bearer-validated
via `provider_token`, with no operator opt-in). Restricting autoupdate to the
`pinned` tier would therefore exclude the entire fleet and defeat this SPEC's
purpose of delivering signed fixes to self-service providers without operator
SSH. Binary replacement is independently crypto-gated by the pre-existing
`SelfUpdate` path (GitHub-host URL validation, ECDSA P-256 signature
verification of `checksums.txt`, SHA-256 tarball verification, tar
path-traversal rejection, new-binary `self-test`, drain, and single-step
rollback — see Goal). Per threat model T-3, a hostile or compromised
coordinator can therefore at most *accelerate* delivery of a legitimately
signed, newer GitHub release, subject to opt-out, drain, and cooldown; it
cannot substitute unsigned, non-GitHub, downgrade, or arbitrary code. A
bearer-validated provisional session (validated `provider_token` plus a
successful encrypted leg and, where required, satisfied Tier2 attestation) is
a materially stronger trust signal than raw first-contact TOFU. Operators opt
an individual provider OUT of provisional autoupdate with
`auto_update_accept_provisional: false`; opted-out and bearerless-duplicate
provisional sessions remain notify-only.

**Eligible does not always mean bearer-validated.** The eligible row's own
Token-validation column reads "validated or not-configured," so a provisional
session with no token configured at all can also reach `.eligible` once tier,
encrypted-leg, and attestation otherwise qualify; bearer-validation is not an
inherent requirement of the tier gate itself. Two distinct coordinator-side
paths produce a provisional session with `tokenConfigured=false`: (a) an
issuer-less coordinator deployment, where `s.issuer == nil` and
`resolveProvisionalToken` returns `provisionalTokenSkip` with an empty auth
state before any token logic runs
(`phase4-coordinator/internal/ws/server.go:810-811`) — an explicit operator
deployment choice, not an attack corner; and (b) the tokenless race-loser
corner described immediately below, which WAS a residual gap and is RESOLVED in
v0.1.7 (the coordinator now propagates `auth_state` so the notify-only floor is
client-enforceable). The production `mac` provider holds a validated
`provider_token` and reaches `.eligible` via the bearer-validated path.

**Tokenless race-loser corner (RESOLVED v0.1.7, runbook item 23).** The
bearerless-duplicate notify-only row is now a client-enforceable guarantee. When
two tokenless connects race for the same `provider_id`, `resolveProvisionalToken`
marks the loser `pool.AuthBearerlessDuplicate` at the auth layer
(`phase4-coordinator/internal/ws/server.go`); the registry admits that session
into the pool only if it registers before any existing session for the same
`provider_id` — `RegisterAtDetailed` refuses registration for an
`AuthBearerlessDuplicate` connection when an existing session is present
(`phase4-coordinator/internal/pool/provider.go`), closing the pool-slot-capture
vector. In the admitted (registers-first) case, the coordinator now propagates
its admission verdict on the accept ack via the OPTIONAL `auth_state` field —
field shape/domain owned by SPEC-001 §6.5.1, emission by SPEC-003 FR-C9.2a; the
ack values are `bearer_validated` / `self_minted` / `bearerless_duplicate`
(`mint_failed` and rejects close the connection and never ride an ack). SPEC-020
owns only the autoupdate INTERPRETATION of that field, defined here.
Client-side, `AutoUpdateTrustState.fromCoordinatorPayload` reads `auth_state`
authoritatively: `auth_state == "bearerless_duplicate"` sets
`bearerlessDuplicate=true` regardless of the (tokenless) heuristic, so the
verdict is `.bearerlessDuplicate` (notify-only), not `.eligible`. An
UNRECOGNIZED non-empty `auth_state` (enum evolution / malformed) is handled
FAIL-CLOSED — treated as the notify-only floor, never relaxed to `.eligible`. A
coordinator that omits `auth_state` (legacy, or no token issuer configured) falls
back to the pre-existing inference, so behavior against old coordinators is
unchanged. The client uses `auth_state` only to hold a MORE restrictive floor;
it never relaxes a verdict on a coordinator claim (e.g. `tokenValidated` is
unchanged and still requires a genuinely held or adopted token). This corner never affected the production `mac` provider, which
holds a validated `provider_token` and is genuinely bearer-validated.

Implementations MUST store an explicit current `autoupdate_trust_state` field
per coordinator session and MUST NOT derive eligibility from
`recommended_binary_version` alone.

**Two update-authority modes.** Coordinator session trust authorizes only the
coordinator's target recommendation. Signed recovery discovery is a separate
authority and never derives eligibility from coordinator admission.

- `coordinator_recommendation`: before accepting the recommended target and
  before accepting its signed discovery metadata, the provider MUST
  re-evaluate the live `autoupdate_trust_state`. A transition from `eligible`
  to notify-only before signed metadata acceptance aborts that recommendation
  attempt, emits `failure_class:"trust_state_lost"` with a stable structured
  reason, and cleans up temporary downloads and locks. The independent signed
  recovery-discovery loop MAY subsequently select the same release.
- `signed_release`: after the provider verifies the signed monotonic discovery
  head, compatibility artifact index, complete target payload, and signed
  compatibility manifest, local pinned release trust owns the transaction.
  Coordinator disconnect, rejection, tier change, token state, or attestation
  state MUST be reported as network readiness and MUST NOT abort, roll back, or
  prevent starting that locally authorized target.

The provider MUST persist the selected authority mode and signed discovery-head
identity in the pending transaction before drain. No transition from
`signed_release` back to coordinator-session authority is permitted for that
transaction.

v2 encrypted-leg negotiation is REQUIRED for eligibility regardless of whether
Tier2 attestation is configured. Tier2-attestation-not-required deployments are
eligible only when encrypted-leg succeeded with matching AEAD/KID.

SPEC-020 names `coordinator_advertised_version.latest_binary_version` as the
authoritative coordinator-side source for the binary version advertised through
`recommended_binary_version`; that value is operator-set, and the coordinator
policy for choosing it is out of scope for this SPEC.

SPEC-020 supersedes the notify-only treatment of `recommended_binary_version`
in legacy `hello_ack` `specs/SPEC-001-phase3-binary.md` §6.5 and v2
`auth_response` `specs/SPEC-008-tier2.md` §10.5 ONLY for SPEC-020-capable
providers AND ONLY when the normative table above returns `eligible`.

All notify-only rows in the normative table MUST NOT use a coordinator
recommendation to trigger download, drain, swap, marker creation, or cooldown.
They do not disable independent signed-release discovery under
SPEC-020-R001.

`required_binary_version` enforcement, the existing admission gate, is
unchanged.

## Normative requirements

### R-1. Trigger and detection

R-1.1. The coordinator auth payload field `recommended_binary_version`, sourced
from `coordinator_advertised_version.latest_binary_version`, is the primary
autoupdate trigger while the provider is connected to a coordinator in the trust
state required by the "Cross-spec amendment and trust state" section. When the
provider accepts such a coordinator session and the recommended version is
strictly greater than the running `CoordinatorClient.binaryVersion`, the
provider MUST evaluate autoupdate eligibility. The provider MUST use
`SelfUpdate.compareSemver` or a single shared implementation byte-for-byte
behavior-equivalent. Manual update, coordinator recommendation handling,
downgrade refusal, and status display MUST all use that same comparator.

**SPEC-020-R001 — Discover signed recovery releases without coordinator
admission.** The provider MUST periodically discover newer signed releases when
no accepted coordinator session exists, including when the coordinator rejects
the installed version. Discovery MUST be bounded, jittered, enabled by default,
and subject to the same downgrade, revocation, compatibility-manifest,
mutation-lock, rollback, and explicit opt-out controls as a
coordinator-recommended update.

Discovery MUST begin from a signature-authenticated monotonic discovery head
under the pinned release trust root, not from mutable GitHub `latest` ordering.
The client MAY use a bounded GitHub public-release listing only to locate
append-only transports whose tags match
`release-discovery-v1-<positive-decimal-sequence>`. It MUST select the greatest
well-formed sequence in that bounded response and require that release to be
public, prerelease, and immutable. It MUST require the selected transport tag
sequence to equal the verified signed-head sequence. The unsigned listing,
release timestamp, and GitHub ordering MUST NOT authorize a target, policy,
downgrade, or mutation.
The head MUST bind a schema version, monotonically increasing unsigned
`release_sequence`, target compatibility-set ID, target artifact-index SHA-256,
signed-policy minimum and revocation set, `issued_at`, and `expires_at`.
`expires_at` MUST be no more than seven days after `issued_at`. The provider
MUST persist the highest accepted sequence and head digest before mutation,
reject a lower sequence as `failure_class:"discovery_head_replay"`, reject a
different digest at the same sequence as
`failure_class:"discovery_head_equivocation"`, and reject an expired or
not-yet-valid head as `failure_class:"discovery_head_expired"`. A newer head
may only raise the effective minimum and add revocations under R-2.2a.

A trusted coordinator recommendation remains the preferred target while an
accepted session exists; otherwise this signed discovery head is sufficient
update authority. This requirement supersedes the v0.1.7 R-1.2 prohibition on
disconnected automatic application.

Each protected stable promotion MUST validate the candidate head signature,
exact numeric target tag/commit/set binding, artifact-index digest, and active
validity window before publication. Its sequence MUST be greater than the head
in the prior public stable immutable release. After publishing the numeric
release, promotion MUST create exactly one public immutable prerelease named
`release-discovery-v1-<verified-sequence>` containing exactly the signed head,
signature, and bound artifact index. It MUST reject a pre-existing tag or
release and MUST NOT overwrite, delete, or recreate a discovery asset or tag.
After publication, an anonymous verifier MUST download the public transport,
reproduce those checks, and prove both the new CLI and—except for the bridge
below—the prior CLI discover the exact new version. Failure of any check blocks
promotion or reports the already-public release as unfit for rollout.

A head renewal MUST use a newly signed, strictly greater sequence and append a
new immutable transport even when the numeric target is unchanged. No existing
transport may be refreshed in place. The protected
`renew-release-discovery-head.yml` workflow is the recurring signer for that
append-only renewal path. It is freshness-only: it binds the exact immutable
stable target that the current signed head already points at — resolved from the
live transport head, never from mutable GitHub `latest` ordering, which the
separate coordinator-gated rollout (`verify-live-coordinator-release-rollout.yml`)
advances — so a renewal keeps the head fresh without advancing the target. It
mints the smallest sequence strictly greater than every existing append-only
transport, so the renewal never leapfrogs a newer target's earlier-signed,
lower-sequence discovery head and thereby blocks a later rollout. It publishes
exactly one new immutable prerelease and anonymously proves the same-target CLI
still discovers the renewed head. The client MUST fail closed
when the greatest located transport is mutable, malformed, expired, incorrectly
signed, or inconsistent with its sequence-bound tag; it MUST NOT silently fall
back to an older located transport.

**Frozen v1.8.55 bridge.** CLI v1.8.55 shipped with discovery fixed to the
`release-discovery` tag. GitHub made that release immutable, so neither its
assets nor tag can advance, and deletion would permanently tombstone the tag.
Therefore ordinary coordinator-independent `malibu-cli update` from
v1.8.55 cannot discover the first append-only transport release. Exactly one
supported trust-preserving bridge is required: either an already-authenticated
coordinator recommendation resolving the exact signed numeric release, or an
operator-installed exact signed acceptance candidate through the supported
installer. No unsigned URL, mutable asset, recreated tag, or validation bypass
is permitted. Once the bridged CLI is running, all later stable releases MUST
pass the prior-client anonymous proof above.

R-1.3. Before accepting a coordinator-recommended target, the provider MUST
validate `recommended_binary_version` against
`^[vV]?[0-9]+\.[0-9]+\.[0-9]+$`. Missing or empty coordinator values are no
coordinator trigger; they do not suppress SPEC-020-R001 discovery. The signed
discovery head's target component version MUST pass the same validation.
Malformed values MUST fail eligibility with
`failure_class:"recommended_version_invalid"` and MUST NOT mutate autoupdate
state. Each source value MUST be no more than 32 UTF-8 bytes, and each numeric
component MUST be no more than 8 digits. Oversized values MUST fail eligibility with
`failure_class:"recommended_version_invalid"` and `reason:"version_too_long"`
or `reason:"version_component_too_long"`.

**Oversized version redaction.** When the raw `recommended_binary_version`
value exceeds 32 UTF-8 bytes, coordinator-visible payloads MUST omit the raw
value and instead include a separate field:
`recommended_binary_version_sha256: "<lowercase 64-hex digits>"` containing
the full SHA-256 of the raw UTF-8 value. v0.1.0 uses full 64-hex digests;
prefix truncation is forbidden. The provider MUST NOT log the full
attacker-controlled string.

**Normalization.** Define `NORMALIZED_TARGET` as the target version with
exactly one leading `v` or `V` character stripped if present. All downstream
uses MUST use the normalized form:

- Release lookup: try `v<NORMALIZED_TARGET>` first, then
  `<NORMALIZED_TARGET>` (R-1.4).
- Marker `target_version` field: `<NORMALIZED_TARGET>`.
- Drain reason: `state_update.reason = "autoupdate_to_<NORMALIZED_TARGET>"`.
- Cooldown key: `(NORMALIZED_TARGET, failure_class)`.

R-1.4. For coordinator-triggered autoupdate, the provider MUST resolve the
target via the GitHub release-by-tag endpoint, trying
`v<NORMALIZED_TARGET>` first then `<NORMALIZED_TARGET>` when the tag omits
`v`. It MUST NOT use `/releases/latest` for coordinator-triggered
installation. On miss, the provider MUST emit
`failure_class:"target_release_not_found"`, perform no download, and enter
cooldown for that normalized target. When the release tag exists but the required
tarball, checksum, or signature asset is missing, the provider MUST emit
`failure_class:"release_asset_missing"`, perform no download, and enter
cooldown for that normalized target.

R-1.5. The provider MUST attempt at most one autoupdate per coordinator session
per target version. A reconnect that repeats the same target version MUST honor
the persisted cooldown state in R-4.2.

R-1.6. After an autoupdate failure, the provider MUST back off before retrying
the same target version using
`cooldown = min(300s * 2^(attempt-1), 3600s)`. The 3600s cap is fixed for
v0.1.0.

**SPEC-020-R002 — Keep manual recovery independent of coordinator state.** The
manual `malibu-cli update` command MUST work without a live, accepted, or
cached coordinator compatibility admission. It MAY ignore the automatic-update
session-attempt throttle, but it MUST enforce every cryptographic, archive,
signed compatibility-manifest, downgrade, revocation, mutation-lock, activation,
local-health, and rollback requirement in R-2 through R-4. Explicit automatic
update opt-out MUST NOT block this manual command. Its release discovery MUST
use the same signed monotonic discovery head and anti-replay state as
SPEC-020-R001.

**SPEC-020-R005 — Recover an accepted-but-stuck session via the signed rail.**
v0.1.8 scoped coordinator-independent recovery to a provider that *cannot
establish* an accepted session, which leaves a real gap: a provider that holds an
accepted session but whose coordinator-recommended autoupdate cannot make forward
progress — because the coordinator advertises a `recommended_binary_version` with
no accompanying `recommended_compatibility_set_id` (a target-missing or
unconfigured-policy coordinator), or because the recommended target is
repeatedly unusable by the installed set — has no self-heal path and strands
while still serving. Eligibility MUST require a *persistent*, not transient,
failure: the provider MUST count consecutive coordinator-recommendation
forward-progress failures for the current recommendation identity, where a single
failure cycle is EITHER one recorded cooldown/failure for a recommended target OR
one observation that the recommendation yields no installable compatibility-set
target (a missing `recommended_compatibility_set_id`). Both kinds increment the
same counter; a single or momentary target-missing observation (for example a
transient coordinator payload omission during a rollout) MUST NOT by itself grant
eligibility. Only when this consecutive-failure count reaches
`accepted_session_recovery_failure_threshold` (default 3) for the current
recommendation does the provider become eligible to invoke the SPEC-020-R001
signed recovery discovery rail, gated by the same signed monotonic discovery
head, anti-replay state, discovery cooldown/backoff, and every R-2 through R-4
safety invariant. The counter MUST reset to zero when the coordinator
recommendation identity changes or the coordinator-recommendation path next makes
forward progress (a successful detection→prepare past the compatibility-target
gate), so recovery eligibility never persists past the stuck condition.

This fallback MUST be strictly additive to recovery reach and MUST NOT: (a) change
the provider's buyer-serving, routing, trust, or admission state; (b) run the
coordinator-recommendation rail and the signed-recovery rail concurrently for the
same target (the mutation lock in R-2 remains the single serialization point); or
(c) take precedence over a coordinator recommendation that is still making forward
progress. When the coordinator later advertises a target the provider can install,
the counter resets and the coordinator-recommendation path resumes as the primary
rail. The fallback is a recovery-reach change only, never a routing or authority
change. Eligibility, the consecutive-failure count, the current recommendation
identity, and each reset MUST be observable per R-6.8, and R005 behavior MUST be
covered by the acceptance criteria AC-V0.1-R005-1 through AC-V0.1-R005-4.

### R-2. Safety invariants

R-2.1. The provider MUST refuse downgrades. If the recommended target version is
less than or equal to the current binary version, autoupdate MUST be a no-op and
MUST emit an observability event explaining the no-op.

R-2.2. Autoupdate MUST fail closed for target versions below
`effective_minimum_safe_binary_version` or in
`effective_revoked_binary_versions`. The effective minimum safe binary version
MUST be:
`max(compiled_in_minimum, local_operator_minimum, persisted_signed_policy_minimum)`.
The effective revoked binary versions MUST be:
`union(compiled_in_revoked, local_operator_revoked, persisted_signed_policy_revoked)`.
Coordinator-advertised fields and recommendations MUST NEVER lower the
effective floor or remove versions from the effective revoked set. This is a
monotonic invariant. v0.1.0 MAY ship compiled-in and persisted empty defaults;
those empty defaults are a hook, NOT active protection until a non-empty local
baseline or signed policy ships. The hook, event, and precedence are normative.
Failure MUST emit
`failure_class:"target_revoked_or_below_minimum"`.

R-2.2a. Persisted monotonic signed-policy state. The trusted state root at
`$HOME/.local/share/macprovider/autoupdate/` MUST persist:

- `persisted_signed_policy_minimum`: `max(observed signed_policy_minimum across all valid signed releases ever installed)`.
- `persisted_signed_policy_revoked`: `union(observed signed_policy_revoked across all valid signed releases ever installed)`.

Both are write-once-grow-only. Signed releases MAY only raise the persisted
minimum and ADD revoked versions. A signed release that attempts to lower
`signed_policy_minimum` or remove versions from `signed_policy_revoked` MUST
NOT clear or shrink the persisted values; the autoupdate path applies the
maximum/union of persisted + new-signed-content. Clearing requires
operator-initiated repair/reinstall, not ordinary signed content.

When computing eligibility:
`effective_minimum_safe_binary_version = max(compiled_in_minimum, local_operator_minimum, persisted_signed_policy_minimum)`.
`effective_revoked_binary_versions = union(compiled_in_revoked, local_operator_revoked, persisted_signed_policy_revoked)`.

R-2.3. The provider MUST refuse update artifacts unless `checksums.txt.sig`
validates as an ECDSA P-256 signature over `checksums.txt` under the pinned
public key baked into the binary. Other signature algorithms, unsigned
checksums, changed keys, or signature parse failures MUST fail closed.

R-2.4. The checksum verification key set is a binary-baked trust root. Planned
rotation MUST ship a transition release trusted by the old key and carrying the
new key before releases require the new key; transition assets SHOULD publish
signatures under both keys. If old key is suspected compromised, providers
trusting only that key MUST be recovered by out-of-band reinstall or other
operator-controlled trust-root replacement, not by ordinary autoupdate.

R-2.5. The provider MUST refuse release assets whose download URLs are not
HTTPS and GitHub-hosted according to the existing SelfUpdate trust boundary.

R-2.6. The provider MUST refuse archives containing absolute paths,
path-traversal entries, symlink replacement of `macprovider-cli`, missing
`macprovider-cli`, multiple candidate binaries, or a non-executable candidate
binary.

R-2.7. The provider MUST refuse the update if the downloaded tarball SHA-256
does not match the signed checksum entry for the selected `darwin-arm64`
tarball.

R-2.8. The provider MUST run the candidate binary's `self-test` subcommand
before replacement and MUST refuse the update if `self-test` exits non-zero,
times out, crashes, or cannot be executed.

R-2.9. The provider MUST check free space on the filesystem backing the
temporary extraction directory before downloading the tarball and again before
preserving the rollback backup. Free space MUST be at least the larger of
512 MiB or three times the tarball size when the tarball size is known. If this
threshold is not met, the provider MUST refuse the update before mutating the
current binary.

R-2.10. The provider MUST NOT replace the running binary while buyer inference
is in-flight. Autoupdate MUST enter the drain protocol in R-3 and may replace
the binary only after the provider has no in-flight requests.

R-2.11. The provider MUST preserve a complete rollback target before replacing
the live release. It contains the exact current executable bytes plus every
owned adjacent release resource, stored on the same filesystem as the live
release under the same effective trust boundary, and recorded by path and
digest in an atomic pending autoupdate marker before launchd restart. Legacy
binary-only pending markers remain recoverable, but a v0.1.6 writer MUST create
the complete release snapshot.

R-2.12. The atomic replacement operation MUST remain all-or-nothing for the
live binary path. If staging, backup preservation, rename, launchd restart, or
marker write fails, the provider MUST leave either the old live binary or a
rollback-complete old live binary at the executable path; it MUST NOT leave a
missing or partially written executable.

R-2.13. The installable release is a complete payload, not a standalone
executable. Before drain or live mutation, the updater MUST stage and verify the
exact versioned provider executable plus every adjacent runtime resource that
the executable expects, including the signed autotune candidate and demand
feeds, their detached sidecars, the release manifest, and the trusted verifier
keyring. The manifest MUST bind the payload filenames and SHA-256 values to the
same release identity as the selected binary. Missing, extra security-critical,
unmanifested, wrong-version, signature-invalid, or hash-mismatched payload
members MUST fail with `failure_class:"release_payload_incomplete"` before
drain. The updater MUST activate and roll back the executable and its payload as
one transaction; mixing a new executable with old catalog resources, or the
reverse, is forbidden.

### R-3. Drain semantics

R-3.1. On an autoupdate decision, the provider MUST refuse new coordinator
admissions before downloading or swapping. It MUST send `state_update` with
`state:"draining"` and mandatory machine-readable discriminator
`state_update.reason = "autoupdate_to_<NORMALIZED_TARGET>"`, where
`<NORMALIZED_TARGET>` is the normalized target version from R-1.3. This format
is stable and MUST NOT vary by implementation. Subsequent preflight handling MUST reject with
`reason:"draining"`.

R-3.2. Provider-initiated autoupdate drain is distinct from
coordinator-initiated drain in `specs/SPEC-001-phase3-binary.md`.
Autoupdate drain is initiated by the provider after a trusted autoupdate
decision, terminates with a launchd restart after successful staging, and MUST
NOT inherit coordinator-initiated drain requirements that assume the same
process remains alive and reconnects without replacement. No new
attestation/preflight/inference admission may be represented as `ready` once
autoupdate drain begins.

R-3.3. The provider MUST send the existing `drain_status` sequence for
autoupdate: `starting`, `in_progress`, and either `complete` or
`timeout_skipped`. This extends the SPEC-001 §6.5 `drain_status.phase` enum
for SPEC-020-capable coordinators; coordinators implementing SPEC-020 MUST
accept `timeout_skipped` without rejecting the frame. Each drain status MUST
include the current in-flight request count.

**Coordinator capability gate.** The `drain_status.phase:"timeout_skipped"`
value extends SPEC-001 §6.5's enum. Current coordinator code
(`ParseDrainStatus`) rejects any phase outside
`starting|in_progress|complete`. Therefore SPEC-020-capable providers MUST
gate the emission of `timeout_skipped` on an explicit coordinator capability
signal: the coordinator MUST advertise `autoupdate_drain_extensions:true` in
the `hello_ack` or v2 `auth_response` payload. Providers that do not see this
capability MUST emit `drain_status.phase:"complete"` instead of
`timeout_skipped` (sacrificing observability for backward compatibility).
Additionally, after a timeout-skipped swap, if the provider remains healthy and
ready to serve, it MUST emit `state_update state:"ready"` so the coordinator's
readiness accounting recovers.

R-3.4. In-flight means every accepted buyer request for which provider-side
inference has begun or a streaming/non-streaming HTTP response is still open.
This includes requests counted by `ProviderStatus.requestsInFlight`, active
request IDs, and any active relay request owned by `InferenceRelay`. Queued
requests that have not begun inference MUST be rejected or cancelled at drain
entry and MUST NOT block the drain timer.

R-3.5. The soft drain timeout for v0.1.0 is 120 seconds. If in-flight requests
remain at the soft timeout, the provider MUST emit an autoupdate drain warning
event and continue draining for one hard-extension window.

R-3.6. The hard-extension window for v0.1.0 is 30 seconds after the soft drain
timeout. If in-flight requests still remain after 150 total seconds, the
provider MUST skip the autoupdate attempt, return to normal readiness if the
process is otherwise healthy, and enter cooldown for that target version. The
provider MUST NOT force-swap over active inference in v0.1.0.

R-3.7. After drain completes with zero in-flight requests, the provider MAY
close the coordinator WebSocket with a normal going-away reason and invoke the
validated update apply path. The provider MUST restart through launchd only
after the rollback marker and rollback target have been durably staged.

R-3.8. A launchd-managed provider restart MUST use an explicitly one-shot
helper with `RunAtLoad:true`, `KeepAlive:false`, and `LaunchOnlyOnce:true`.
The updater MUST own the shared provider-mutation lock before fencing any
helper. The helper MUST issue at most one bootout of the canonical provider
job, boundedly poll until `launchctl print` positively reports that exact
service absent, then issue at most one bootstrap and remove its transient
plist. A timeout or any unrecognized inspection result MUST fail closed
without bootstrap. Before drain or live mutation, before rollback restoration,
and before arming a new helper, the updater MUST boot out the stable helper
label and every exact legacy
`live.malibu.provider-compatibility-reload.<lowercase-UUID>` label. A
prefix-confusable or malformed label MUST NOT be touched. Failure to prove a
matching loaded helper absent MUST fail closed before mutation or restoration.
`launchctl submit` is forbidden for this restart because its inferred retry
lifecycle is not a one-shot contract.

### R-4. Failure and rollback

R-4.1. Download, release lookup, URL validation, signature verification,
checksum verification, archive validation, free-space check, self-test, drain,
backup preservation, rename, and launchd restart failures MUST emit structured
events and MUST NOT be silent.

R-4.2. A failed autoupdate attempt MUST record cooldown state keyed by target
version and failure class. The target-version component of the key MUST be
`NORMALIZED_TARGET` from R-1.3. The provider MUST NOT retry the same target
until cooldown expires, even if a reconnect repeats the coordinator
recommendation.

R-4.3. The provider MUST preserve exactly one prior-release rollback target for
the currently pending autoupdate. The existing manual update behavior that
overwrites only the old binary by POSIX rename is insufficient until the
complete executable-plus-resources rollback target is staged.

R-4.4. Autoupdate eligibility MUST NOT depend on the companion watchdog as a
rollback observer. The rollback observer is the CLI startup recovery path that
shares the provider mutation locks and `pending.json` state machine. If CLI
startup recovery is disabled, unavailable, or cannot share the transaction
state, autoupdate MUST fail closed with
`failure_class:"rollback_observer_unavailable"` before download, drain, swap,
or marker creation.

R-4.5. Every provider release mutator and recovery observer MUST share one
kernel-held ownership boundary. The outer lock is
`$HOME/.config/macprovider/install.lock`; installer, manual CLI update,
coordinator autoupdate, Malibu repair, and CLI startup/install recovery MUST
acquire it before inspecting or mutating live binary, resource, config, plist,
recommendation, service, or recovery state. The companion watchdog MUST NOT
acquire this lock for rollback, write pending markers, restore release bytes,
rewrite plists, or restart the provider as part of update recovery. Autoupdate
and its recovery owners MUST then acquire the inner
`$HOME/.local/share/macprovider/autoupdate/update.lock`. Acquisition order is
always outer `install.lock`, then inner `update.lock`; release order is the
reverse. No path may wait for the outer lock while holding the inner lock.

Both files MUST be opened with `O_CREAT|O_NOFOLLOW` mode 0600, and the
implementation MUST take an advisory `flock(LOCK_EX|LOCK_NB)` or
`fcntl(F_SETLK)` before state mutation. A stale lockfile without a live process
holding the lock is NOT contention. The installer/recovery owner record MUST
durably bind its PID, process-start identity, boot identity, operation, and
transaction ID; Swift mutators and recovery observers MUST validate any such
record rather than trusting PID reuse. All other owners remain authoritative
through the kernel-held outer lock and their durable pending marker. An
installer or updater MUST treat a durable pending transaction as owned until
the exact local signed-set/health commit or its recovery completes, even if the
original writer exited. Network-readiness observation does not extend mutation
ownership after local commit. On contention, an autoupdate path MUST emit
`failure_class:"autoupdate_already_pending"`; other writers MUST report
`failure_class:"provider_mutation_pending"`. No contender may create or mutate
a pending marker, rollback backup, or live release graph.

R-4.6. The pending autoupdate marker path MUST be
`$HOME/.local/share/macprovider/autoupdate/pending.json`. The marker MUST be
UTF-8 JSON, written atomically by temp-file write, `fsync()` of the file,
`fsync()` of the parent directory, and rename, and have mode 0600.
`pending.json` temp files MUST use `O_CREAT|O_EXCL|O_NOFOLLOW` on create,
`fsync()` file plus parent directory, then atomic rename. The marker schema
MUST include:

| Field | JSON type and validation |
|---|---|
| `update_id` | string; lowercase UUIDv4 (RFC 4122 §3, 36-char canonical form) |
| `target_version` | string; normalized semver string matching the validation regex, with no leading `v` or `V` |
| `target_path` | string; absolute path, no trailing slash |
| `backup_path` | string; absolute path, no trailing slash |
| `size` | integer; bytes |
| `mode` | integer; decimal int of the octal mode value; e.g., `0o755` is serialized as `493` |
| `sha256` | string; lowercase 64-hex |
| `marker_deadline` | string; RFC 3339 UTC string, e.g., `2026-06-29T15:00:00Z`; see semantics below |
| `release_backup_path` | string; required for v0.1.6 writers; absolute path to the complete release snapshot, no trailing slash |
| `release_backup_sha256` | string; required with `release_backup_path`; lowercase 64-hex deterministic release-tree digest |
| `commit_owner` | string; required for v0.1.6 writers; stable enum identifying the updater/recovery authority |
| `target_compatibility_set_id` | string; required for v0.1.8 writers; immutable signed compatibility-set identity |
| `target_compatibility_set_sha256` | string; required with target set ID; lowercase 64-hex digest of the signed compatibility-set manifest |
| `previous_version` | string; required for v0.1.8 writers; normalized prior CLI component version |
| `previous_compatibility_set_id` | string; required for v0.1.8 writers; immutable prior signed compatibility-set identity |
| `previous_compatibility_set_sha256` | string; required with previous set ID; lowercase 64-hex digest of the prior signed compatibility-set manifest |
| `discovery_head_sequence` | integer; required for automatic-discovery writers; accepted unsigned monotonic release sequence |
| `discovery_head_sha256` | string; required with discovery sequence; lowercase 64-hex signed discovery-head digest |
| `update_authority_mode` | string; required for v0.1.8 writers; `coordinator_recommendation` or `signed_release` |
| `install_profile` | string; optional future binding when written; `consumer_user` or `headless_fleet` |
| `launchd_domain` | string; optional future binding when written; `gui/<uid>` or `system`, and MUST match `install_profile` |
| `service_label` | string; optional future binding when written; exact canonical provider label without a domain prefix |
| `provider_config_root` | string; optional future binding when written; exact absolute selected-profile config root |
| `provider_state_root` | string; optional future binding when written; exact absolute selected-profile state root |

**`marker_deadline` semantics.** Writer: the autoupdate process at marker-write
time. Basis: `marker_write_time + post_start_window + 5 min safety margin`.
The post-start window is 60s per R-4.11 default; safety margin is 5 min to
absorb local clock skew. Comparison rule: provider's local wall-clock
(`Date()` / equivalent). Tolerance: +/-5 minutes; deadlines outside this
window are treated as malformed.

Behavior:

- **Missing or malformed**: treat marker as invalid; trigger orphaned-marker
  recovery (R-4.10) with `failure_class:"orphaned_pending_marker"`.
- **Expired (now > marker_deadline + 5 min)**: trigger orphaned-marker
  recovery same as above (R-4.10).
- **Future beyond tolerance** (marker_deadline > now + post_start_window + 30
  min): treat as evidence of clock manipulation or a malformed writer. Trigger
  orphan-marker recovery per R-4.10. After recovery completes, the provider
  MUST:
  - Record a cooldown entry keyed by
    `(NORMALIZED_TARGET, "orphaned_pending_marker")` with the standard backoff
    formula (300s × 2^(attempt-1), max 3600s).
  - Disable autoupdate for the remainder of the current coordinator session.
    Re-evaluation occurs only on the next coordinator session start AND after
    the cooldown clears.
  - Emit `failure_class:"orphaned_pending_marker"` with structured reason
    `marker_deadline_future_beyond_tolerance` for forensic correlation.

R-4.7. The binary rollback backup path MUST be
`<binary-dir>/.macprovider-cli.rollback-<update_id>`. Directory ancestry for
the backup MUST have mode 0700 and MUST be owned by the provider UID. The
backup MUST be the exact current executable bytes, stored on the same
filesystem as the live binary, and its SHA-256 MUST match the `sha256` recorded
in the pending marker. Rollback-backup temp files MUST use
`O_CREAT|O_EXCL|O_NOFOLLOW` on create, `fsync()` file plus parent directory,
then atomic rename. The adjacent-resource snapshot MUST use
`<binary-dir>/.macprovider-cli.release-rollback-<update_id>` and its
deterministic tree digest MUST match `release_backup_sha256` before restore.

R-4.8. Marker, binary backup, and release snapshot entries MUST be opened with
symlink-following disabled. The CLI startup recovery owner MUST `lstat` every
path, reject symlinks, reject unexpected hard links, reject malformed JSON, and
reject any path outside the trusted state and binary directories before copying,
renaming, or restoring. It MUST verify the binary SHA-256 and release-tree
SHA-256 before restore. The companion watchdog MUST NOT perform these restore
checks because it is not a rollback owner.

R-4.9. Trusted state root. `$HOME/.local/share/macprovider` and
`$HOME/.local/share/macprovider/autoupdate` MUST be created or repaired as
provider-UID-owned, mode 0700. Implementations MUST reject if any path
component is a symlink, is not owned by the provider UID, has group/world
write, has non-owner-write ACLs, or crosses an unexpected device/mount
boundary.

R-4.10. CLI startup recovery MUST handle invalid pending markers as a state
machine. If `pending.json` exists but neither the outer provider mutation lock
nor `update.lock` has a live holder and no CLI recovery process is running, the
marker is orphaned. CLI startup recovery MUST emit
`failure_class:"orphaned_pending_marker"` and delete the marker after restoring
from backup if the backup is valid by size and hash. If the backup is not
valid, it MUST quarantine the marker by renaming it to
`pending-quarantined-<timestamp>.json` and disable autoupdate until an operator
clears the quarantine. If `pending.json` references a `backup_path` that is
missing or hash-mismatched, CLI startup recovery MUST emit
`failure_class:"rollback_backup_corrupt"`, MUST NOT delete the live binary
because no rollback is possible, MUST disable autoupdate for the session, and
MUST surface a structured event. The companion watchdog may log that a pending
marker exists, but MUST leave all marker, backup, release, plist, watchdog, and
Malibu app bytes untouched.

**SPEC-020-R003 — Separate local update integrity from network readiness.**
After activation, the updater MUST first decide local update success from the
signed target identity, successful launch, and local provider health.
Coordinator connectivity and network admission MUST be reported as a
separate readiness result. Coordinator unavailability or rejection MUST NOT by
itself roll a locally healthy, strictly newer signed release back to an older
or already-rejected release. Activation, launch, self-test, local-health, or
signed-set identity failure MUST still enter the rollback decision in R-4.11.
Model selection, model warmth, and continuity of the prior serving model remain
owned by SPEC-023/#612 and are not local update-commit criteria here.

R-4.10a. Success-state cleanup.

**Success-state cleanup sequence and crash recovery.**

**Success-state cleanup sequence.** Local update observation succeeds when the
new binary passes local health, reports `binary_version == NORMALIZED_TARGET`,
and proves the activated signed compatibility-set identity. When an
authenticated, non-redirected exact-provider readiness response is available,
the updater MUST separately record whether it reports `buyer_serving:true`,
`catalog_admission_mode:current|previous`, and the activated catalog release,
digest, signer, and selected-row identity. A mismatch is a network-readiness
failure and MUST remain visible, but it is not local release-integrity failure.
A busy provider with no free slot MAY satisfy network readiness. After local
success, the observer executes the following ordered sequence. Each step MUST
complete, or its absence MUST be safely recoverable, before the next:

1. **Write success sentinel.** Atomically create
   `<binary-dir>/.macprovider-cli.success-<update_id>` with
   `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600, containing the JSON
   `{"update_id":"<uuid>","binary_version":"<NORMALIZED_TARGET>","target_compatibility_set_id":"<set-id>","target_compatibility_set_sha256":"<64-hex>","success_at":"<RFC3339>"}`.
   `fsync()` the file and parent directory, then atomic rename to final name.
2. **Unlink `pending.json`** via `unlink()`.
3. **Delete rollback backup** at
   `<binary-dir>/.macprovider-cli.rollback-<update_id>` via `unlink()`.
4. **Release mutation ownership** by closing the inner `update.lock` fd, then
   closing the outer `install.lock` fd. Lockfile cleanup MUST NOT create an
   unlocked-inode race; implementations MAY retain stable lock inodes.
5. **Emit `outcome:"success"` event** with `phase:"post_start"`.

**Crash recovery semantics.** On every provider startup (before coordinator
handshake), the observer MUST scan for a success sentinel:

- If `<binary-dir>/.macprovider-cli.success-<update_id>` exists AND its
  embedded `binary_version`, `target_compatibility_set_id`, and
  `target_compatibility_set_sha256` match the current binary component version
  and the reverified local signed compatibility-set manifest: this is a delayed
  success cleanup path.
  The observer MUST unlink any matching `pending.json` (without triggering
  orphan recovery), delete any matching rollback backup, release any held
  inner `update.lock` and outer `install.lock`, then delete the success sentinel.
  Treat as
  `outcome:"success"`, NOT as orphan recovery.
- If a success sentinel exists but any bound binary/set field does not match,
  or the local set cannot be reverified, emit
  `failure_class:"orphaned_success_sentinel"`, retain `pending.json` and the
  rollback backup for recovery, delete only the invalid sentinel, and continue.
- If `pending.json` is absent BUT a rollback backup exists with a stale
  `update_id` (no matching pending marker), delete the backup without
  attempting restore.

v0.1.0 deletes the rollback backup on success. Multi-version rollback
retention is deferred to v0.3.0.

R-4.11. If the new binary crashes, fails to start, fails local provider health,
or fails exact signed-set identity verification within 60 seconds of the new
process start, the CLI recovery owner MUST evaluate the preserved prior
release's signed compatibility-set ID/digest and CLI component version against
the preserved rollback record, then evaluate it against
`effective_minimum_safe_binary_version` and
`effective_revoked_binary_versions` before restoration. If the prior release is
allowed, CLI recovery restores the complete payload and restarts the canonical
launchd provider service in the selected profile.
If the prior release is revoked or below the effective minimum, CLI recovery
MUST NOT restore or restart it; it MUST stop the failed target, retain the
validated recovery material and pending marker, emit
`failure_class:"rollback_target_disallowed"`, and require the separately
authorized emergency recovery path. Each trigger maps to exactly one failure
class:

- `post_start_crash`: the new binary fails to start or exits within the
  post-start window.
- `post_start_health_failed`: the new binary started but local health check
  (e.g., `/healthz` probe) failed within the post-start window.
- `post_start_network_unavailable`: local activation succeeded but no
  authoritative readiness response arrived; report without rollback.
- `post_start_network_not_ready`: local activation succeeded but the
  coordinator did not report current/previous network readiness or returned
  different catalog identity; report without rollback.

R-4.12. After CLI startup recovery performs rollback, autoupdate MUST be
disabled for the rest of the provider session and the provider MUST emit a
structured rollback failure event. The next provider process start MAY re-enable
autoupdate unless disabled by configuration or cooldown state. A
`rollback_target_disallowed` stop remains fenced across restart until emergency
recovery supplies an allowed signed set.

R-4.13. Reserved for future headless system-domain update and rollback
semantics. Until that version lands, `headless_fleet` is outside the autoupdate
convergence population and MUST NOT be driven by the consumer-user reload helper.
v0.1.16: when the coordinator-recommendation path or the SPEC-020-R005
signed-recovery path evaluates a recognized `headless_fleet` / system-domain
provider, it MUST divert to `reason:"headless_operator_update_required"`
(`outcome:"skipped"`) BEFORE the install-topology gate and every later mutating
gate (cooldown, download, swap), so the consumer path never drives the node even
when a stale or loaded consumer LaunchAgent would otherwise make it appear
installable. The divert is placed AFTER the non-mutating `target_revoked` /
below-minimum policy check, which still wins (a revoked or below-minimum target
is refused for every profile). The diverted cycle MUST NOT record a
forward-progress failure, and R005 accepted-session re-observation MUST NOT count
such a provider as stuck (it never accrues toward the recovery threshold).
Recognition MUST use the same authorities as the mutating-update gate
(`MacProviderCLI.validateHeadlessUpdateMode`): `protected_file` credential
custody; an install manifest declaring the `headless_fleet` profile or `system`
launchd domain; or a managed system-domain provider LaunchDaemon that is present
on disk, loaded in launchd, or in an indeterminate launchd state. An invalid or
indeterminate topology MUST fail closed to the headless handoff rather than the
consumer path. This keeps a healthy operator-managed node from looping
`failure → R005 → failure` and gives the operator one stable, actionable reason
instead of a repeated `unsupported_install_topology` failure. The determination
MUST NOT relax any R-2 safety invariant, mutate the live service, or authorize
rollback; it only changes eligibility diversion, the reported reason, and failure
accounting. A proven consumer topology continues on the normal path; a genuinely
unrecognized topology still fails closed as `unsupported_install_topology`.

R-4.14. The companion watchdog MUST NOT restart the provider on process exit or
on a missing/unvalidated launchd PID. Exit and crash restart of the provider
service is owned solely by the launchd **provider service** `KeepAlive`, the
single exit-restart owner: `consumer_user` uses `KeepAlive{SuccessfulExit:false}`
plus `ThrottleInterval` (restarting **crash/nonzero** exits), and `headless_fleet`
uses `KeepAlive{true}`. Because `KeepAlive{SuccessfulExit:false}` does not restart
a clean (exit 0) termination, a `consumer_user` serve process MUST reach exit 0
only under a validated **local** stop intent (uninstall, launchd/operator-disable,
or a local `stop`/maintenance transaction — SPEC-001 FR-12); an unsolicited
SIGTERM/SIGINT with no such stop intent (a stray or memory-pressure/jetsam
SIGTERM) MUST exit **nonzero** so launchd restarts it. A coordinator `drain`
message is registration-only and never causes process exit, so it is not a stop
intent. This leaves no accidental clean-exit gap when the watchdog exit-restart is
removed.

The watchdog's only permitted mutating action is its existing bounded,
current-boot-gated **wedge** restart (unchanged by this version): a
`launchctl kickstart` only after current-boot local health has been observed, a
later local `/v1/health` failure is paired with a restart-worthy `/v1/status`
state, it is outside cooldown, the provider is not operator-paused, and no valid
startup/maintenance lifecycle lease grants grace. Consuming the SPEC-025 §5.2
`model_liveness_token_v1` to additionally catch the listener-alive/model-dead
wedge — and a domain-aware wedge target for headless/system-domain (RFC-001 F3) —
are deferred follow-ups that must first define the stall threshold and its owner,
a persisted operator-pause signal readable without the HTTP surface, and the
pre-first-token / process-wide hard-freeze cases before they may authorize a
restart.

Beyond its own boot-arm and cooldown markers, and its own private
supervisor-telemetry state files (`supervisor-beacon.json` plus its seq/counter/
sticky sidecars — non-executable, non-config diagnostic markers; SPEC-025 §5.4),
the watchdog MUST NOT write, restore, rename, or delete any
provider **or supervisor** artifact — provider binary, resources, config, or
plist, or the watchdog script, its plist/LaunchAgent/LaunchDaemon, or any current
or legacy supervisor label (including `live.streamvc.macprovider-watchdog`) — MUST
be installer-owned and non-self-restoring (RFC-001 §5.1), and MUST NOT own or
perform update or rollback (R-4.4, R-4.5). This makes launchd the single exit-restart owner and removes the
second, mutable exit-restart authority whose stale form caused the #1189
stranding (the removed code path is the CLI watchdog `missing_validated_pid`
kickstart). For the avoidance of doubt this supersedes any residual wording (e.g.
SPEC-026) that the companion watchdog "force-restarts" the provider during
auto-update rollback recovery: rollback authority was removed in v0.1.13 and the
watchdog performs no rollback-driven restart.

Headless liveness is separate from headless updates: **headless system-domain
autoupdate and rollback remain gated by R-4.13's reserved boundary**, while
**headless system-domain wedge/liveness restart is governed by SPEC-026** and,
once RFC-001 follow-up F3 lands, MUST target the correct launchd domain
(`system/live.malibu.provider`) rather than a hardcoded GUI-domain service.
Headless liveness supervision MUST NOT be deferred merely because headless
autoupdate is unsupported.

### R-5. Opt-out

R-5.1. Autoupdate is enabled by default in v0.1.0.

R-5.2. Operators MUST be able to opt out with configuration and environment.
The config-file keys `autoupdate.enabled: false` and
`auto_update_enabled: false` MUST both be accepted. The environment variables
`MACPROVIDER_AUTOUPDATE=0` and `MACPROVIDER_AUTO_UPDATE_ENABLED=0` MUST both be
accepted. Implementations SHOULD also treat `false`, `no`, and `off`
case-insensitively as disabled values.

R-5.3. Any explicit opt-out source MUST disable autoupdate. If either the
config file or environment disables autoupdate, the provider MUST NOT attempt
autoupdate, even when the coordinator advertises a newer version. Explicit
disabled wins over any enabled value from another source.

R-5.4. Opt-out MUST NOT disable manual `malibu-cli update`; manual update
remains an explicit operator action.

R-5.5. When autoupdate is disabled by opt-out, the provider MAY continue to log
or print that a newer version is available, but the message MUST say that
autoupdate is disabled.

### R-6. Observability

R-6.1. The provider MUST emit structured JSON events for every autoupdate
decision point: detection, opt-out, eligibility, cooldown, free-space check,
download start/finish, signature verification, checksum verification, archive
validation, self-test, drain start/progress/timeout/complete, backup
preservation, swap, launchd restart, post-start observation, success, failure,
and rollback.

R-6.2. Each event MUST include at least: `event`, `update_id`,
`current_version`, `target_version`, `source`, `phase`, `outcome`, `reason`,
`attempt`, and an RFC 3339 timestamp. Events that concern drain MUST also
include `inflight_requests`; events that concern failure MUST include
`failure_class`.

R-6.3. `last_autoupdate_event` is a SPEC-001 wire-schema extension on
heartbeat and `state_update` payloads. Coordinators implementing SPEC-020 MUST
accept it. Providers MUST tolerate older coordinators ignoring the field. The
value MUST be a structured object, not a free text log line. The
`last_autoupdate_event` value MUST serialize to ≤4096 UTF-8 bytes when
JSON-minified (no whitespace), measured AS THE EVENT OBJECT ALONE, before
embedding in any wrapping heartbeat or `state_update` payload. Implementations
MUST drop optional fields in this priority order: `extra_metadata`,
`attempt_history`, `release_url`, free-text `reason`. Implementations MUST NOT
truncate JSON strings. If the bound is unreachable after dropping all optional
fields, emit `failure_class:"event_payload_too_large"` with a minimal stable
payload.

R-6.4. `source` MUST be one of: `coordinator`, `github_poll`, `manual`.
`outcome` MUST be one of: `success`, `failure`, `skipped`, `noop`,
`in_progress`. `phase` MUST be one of: `detection`, `eligibility`, `cooldown`,
`free_space`, `download`, `signature`, `checksum`, `archive`, `self_test`,
`drain`, `backup`, `swap`, `restart`, `post_start`, `rollback`.

R-6.5. `failure_class` MUST be one of:
`rollback_observer_unavailable`, `target_release_not_found`,
`release_asset_missing`, `recommended_version_invalid`, `version_too_long`,
`version_component_too_long`, `autoupdate_already_pending`,
`provider_mutation_pending`,
`orphaned_pending_marker`, `orphaned_success_sentinel`,
`rollback_backup_corrupt`,
`target_revoked_or_below_minimum`, `signature_invalid`, `checksum_mismatch`,
`release_payload_incomplete`, `self_test_failed`, `drain_timeout`,
`trust_state_lost`,
`post_start_crash`, `post_start_health_failed`,
`post_start_network_unavailable`, `post_start_network_not_ready`,
`rollback_target_disallowed`, `discovery_head_replay`,
`discovery_head_equivocation`, `discovery_head_expired`,
`insufficient_disk_space`,
`event_payload_too_large`, `other`.

R-6.6. Coordinator-visible payloads MUST NOT include provider tokens,
Authorization headers, credentials, signing private key material, raw
checksum/signature contents, full redirect URLs with query strings, or absolute
local paths/usernames. Free-text error strings MUST be redacted or mapped to
stable reason/failure enums before inclusion in coordinator-visible payloads.

R-6.7. The provider's local status endpoint SHOULD expose the current
autoupdate state, including `enabled`, `last_event`, `cooldown_until`, and
`pending_target_version`.

R-6.8. Accepted-session recovery (SPEC-020-R005) MUST be observable. Each
consecutive-failure increment and each counter reset MUST emit an observability
event carrying the current recommendation identity, the consecutive-failure
count, and the reason for the increment (a recorded target failure vs a
missing-compatibility-target observation). Becoming eligible MUST emit a distinct
event naming the threshold and recommendation identity; the subsequent invocation
of the signed recovery rail on an accepted session MUST be attributable to R005
via a reason/metadata marker (the `source` stays `github_poll` per R-6.4;
attribution MUST NOT add a new `source` value) so an accepted-session recovery is
never indistinguishable from an ordinary non-accepted signed-recovery poll. All
R-6.8 payloads remain subject to the R-6.6 redaction rules.

## Acceptance criteria

AC-V0.1-1. End-to-end autoupdate: given a running provider at version `N` and
either a trusted coordinator recommendation or disconnected signed-release
discovery identifying `N+1`, the provider detects the target, resolves the
matching GitHub release,
downloads the `darwin-arm64` tarball plus checksum assets, verifies signature
and checksum, validates the complete manifest-bound binary-plus-catalog payload,
runs `self-test`, drains to zero in-flight requests, preserves the prior release,
atomically writes the pending marker, atomically swaps, restarts through
launchd, proves local signed-set and runtime health, and reports network
readiness separately at `binary_version: N+1`.

AC-V0.1-2. Downgrade rejected: given current version `N` and coordinator
recommendation `< N`, the provider emits a no-op event, does not download
artifacts, does not enter drain, and does not mutate the binary.

AC-V0.1-3. Signature mismatch rejected: given a release whose
`checksums.txt.sig` does not validate under the pinned ECDSA P-256 key, the
provider emits `failure_class:"signature_invalid"`, does not run `self-test`,
does not drain, and does not swap.

AC-V0.1-4. Checksum mismatch rejected: given a tarball whose SHA-256 does not
match the signed `checksums.txt` entry, the provider emits
`failure_class:"checksum_mismatch"` and leaves the live binary unchanged.

AC-V0.1-5. Self-test failure rejected: given a candidate binary whose
`self-test` exits non-zero or times out, the provider emits
`failure_class:"self_test_failed"` and no swap occurs.

AC-V0.1-6. Free-space refusal: given free space below `max(512 MiB, 3x tarball
size)` on the temp extraction filesystem, the provider refuses before mutating
the live binary, emits `failure_class:"insufficient_disk_space"`, and records a
cooldown event.

AC-V0.1-7. Drain success: given one in-flight request that completes within the
120-second soft timeout, the provider sends `state_update` `draining`, rejects
new preflights with `reason:"draining"`, sends `drain_status` progress, waits
for the request to finish, then swaps only after in-flight count reaches zero.

AC-V0.1-8. Drain timeout exceeded: given an in-flight request that remains
active past 150 seconds, the provider skips autoupdate, emits
`failure_class:"drain_timeout"`, returns to normal readiness if healthy, enters
cooldown, and does not force-swap over active inference.

AC-V0.1-9. Opt-out honored: given `MACPROVIDER_AUTOUPDATE=0`,
`MACPROVIDER_AUTO_UPDATE_ENABLED=0`, `autoupdate.enabled: false`, or
`auto_update_enabled: false`, a newer coordinator recommendation produces an
opt-out event and optional notify-only message, but no download, drain, swap,
or restart occurs.

AC-V0.1-10. Post-swap rollback classification: given a new binary that fails to
start or exits within 60 seconds, CLI startup recovery emits
`failure_class:"post_start_crash"`. Given a new binary that starts but fails
local provider health or exact signed-set verification, it emits
`failure_class:"post_start_health_failed"`. An allowed prior release is restored
only after `lstat`, complete-release digest, minimum-version, and revocation
checks. A revoked or below-minimum prior release is not restarted and emits
`rollback_target_disallowed`. Given no authoritative readiness answer, the
monitor records `post_start_network_unavailable` without rollback; given an
authoritative answer that is not current-or-previous network-ready, it records
`post_start_network_not_ready` without rollback.

AC-V0.1-11. Coordinator-visible observability: after each major decision point,
the next heartbeat or state update includes `last_autoupdate_event` with a
bounded structured object reflecting the latest phase and outcome.

AC-V0.1-12. Manual update recovery: with the coordinator unreachable or
rejecting the installed version, `malibu-cli update` discovers and
installs a strictly newer signed release using its signed compatibility
manifest without fresh or cached coordinator admission. Opt-out configuration
does not prevent the manual update.

AC-V0.1-13. Untrusted recommendation remains notify-only: given legacy
hello_ack-only, unauthenticated, a notify-only provisional sub-state
(self-minted/bearerless-duplicate, or explicitly opted out via
`auto_update_accept_provisional: false` — a provisional session with
`accept_provisional` set that also passes the encrypted-leg, attestation, and
token guards is eligible per the normative trust-state table, not
notify-only, whether or not it holds a validated token), failed
encrypted-leg, failed
attestation, rejected token, or otherwise notify-only coordinator state from
the normative trust-state table, a newer `recommended_binary_version` does not
trigger download, drain, swap, marker creation, or cooldown. The provider
records the current table result in an explicit `autoupdate_trust_state` field
for the coordinator session and re-evaluates that field before each
irreversible autoupdate phase.

AC-V0.1-14. Malformed recommendation rejected: given a malformed non-empty
`recommended_binary_version`, the provider emits
`failure_class:"recommended_version_invalid"` and does not mutate autoupdate
state. Given an oversized value or oversized numeric component, the provider
emits `failure_class:"recommended_version_invalid"` with
`reason:"version_too_long"` or `reason:"version_component_too_long"`, omits the
raw oversized value from coordinator-visible payloads, includes
`recommended_binary_version_sha256` as the full lowercase 64-hex SHA-256 of the
raw UTF-8 value when reporting the oversized value, and does not log the full
attacker-controlled string.

AC-V0.1-15. Target release miss rejected: given a syntactically valid
coordinator recommendation that has neither `v<NORMALIZED_TARGET>` nor
`<NORMALIZED_TARGET>` GitHub release tag, the provider emits
`failure_class:"target_release_not_found"`, does not download, and enters
cooldown keyed by `(NORMALIZED_TARGET, failure_class)`.

AC-V0.1-16. Rollback observer unavailable rejected: given missing or disabled
CLI startup recovery/equivalent transaction-owned rollback observation,
autoupdate fails eligibility with
`failure_class:"rollback_observer_unavailable"` before download, drain, swap,
or marker creation. Missing companion watchdog alone MUST NOT be treated as
missing rollback authority.

AC-V0.1-17. Coordinator-visible event redaction: heartbeat and `state_update`
payloads containing `last_autoupdate_event` carry an event object that
serializes to no more than 4096 UTF-8 bytes when JSON-minified and measured
before embedding in the wrapping wire payload. The provider drops optional
fields in the required priority order rather than truncating JSON strings, emits
`failure_class:"event_payload_too_large"` if the minimal stable payload still
exceeds the bound, and excludes provider tokens, Authorization headers,
credentials, raw checksum/signature contents, full redirect URLs with query
strings, and absolute local paths/usernames.

AC-V0.1-18. Release asset missing rejected: given a syntactically valid
coordinator recommendation whose GitHub release tag exists but lacks the
required tarball, checksum, or signature asset, the provider emits
`failure_class:"release_asset_missing"`, does not download, and enters cooldown
for that target.

AC-V0.1-19. Orphaned pending marker recovered: given `pending.json` exists,
both the outer `install.lock` and inner `update.lock` are unheld, no CLI
recovery process is running, and the referenced binary plus release backups are
valid by size and hash, CLI startup recovery emits
`failure_class:"orphaned_pending_marker"`, restores from backup, deletes the
marker, and surfaces a structured event. If the backup is not valid, CLI
recovery quarantines the marker as `pending-quarantined-<timestamp>.json` and
disables autoupdate until operator repair. A watchdog tick over the same
expired marker MUST leave the live binary/release bytes, marker, backup,
watchdog script, launchd plists, and Malibu app untouched.

AC-V0.1-20. Corrupt rollback backup blocks rollback: given `pending.json`
references a missing or hash-mismatched `backup_path`, CLI startup recovery
emits `failure_class:"rollback_backup_corrupt"`, does not delete the live
binary, disables autoupdate for the session, and surfaces a structured event.
The watchdog MUST NOT quarantine or repair the marker because it is not the
transaction owner.

AC-V0.1-21. Trusted state root hardened: startup creates or repairs
`$HOME/.local/share/macprovider` and
`$HOME/.local/share/macprovider/autoupdate` as provider-UID-owned mode 0700,
rejects symlinked, non-provider-owned, group/world-writable,
non-owner-write-ACL, or unexpected-mount path components, opens `update.lock`
and the outer `install.lock` with `O_CREAT|O_NOFOLLOW` mode 0600, validates the
outer durable owner record, treats only a live advisory lock holder or a
durable pending transaction as contention, and creates marker and backup temp
files with `O_CREAT|O_EXCL|O_NOFOLLOW`.

AC-V0.1-22. Coordinator recommendation trust loss: provider becomes eligible at
v2 `auth_response`, begins resolving the recommendation, and then the encrypted
leg is invalidated before the signed discovery head and target index are
accepted. No coordinator-triggered swap occurs; the provider emits
`failure_class:"trust_state_lost"` with reason
`encrypted_leg_invalidated`, cleans up partial state, and refuses autoupdate
from that recommendation for the remainder of the session. The independent
signed-release loop remains eligible. If the same disconnect occurs after the
signed metadata transition, the local transaction continues and records
network readiness separately.

AC-V0.1-23. Success-state cleanup. Post-start success completes the ordered
cleanup sequence. Subsequent provider startup finds no orphan state, emits no
rollback events, and reports `outcome:"success"` (or `outcome:"noop"` if
cleanup completed during the prior session). The success sentinel binds the
target CLI component version plus exact compatibility-set ID and manifest
digest; crash recovery reverifies all three before deleting pending/rollback
state. Crash between any pair of steps 1–5 is recoverable on next startup
without rollback of the successful update.

AC-V0.1-24. Complete release payload: a candidate archive whose executable is
correctly signed but whose manifest-bound catalog sidecar is absent or whose
catalog digest belongs to the previous release fails before drain with
`failure_class:"release_payload_incomplete"`; no live executable or resource is
changed. Activation and forced rollback tests prove executable, manifest,
catalog bytes, sidecars, and keyring move together.

AC-V0.1-25. Split local and network commit: local success clears the update
transaction only after the running binary reports the target version, the
activated signed compatibility-set identity matches, and local provider health
passes. The exact provider's authenticated `details=readiness` response,
when available, separately records `buyer_serving`,
`catalog_admission_mode:current|previous`, and the release/digest/signer/row
identity. A timeout records `post_start_network_unavailable`; an authoritative
mismatch records `post_start_network_not_ready`. Neither network-only result
rolls a locally healthy strictly newer signed release back.

AC-V0.1-26. Busy capacity is network-ready capacity: an admitted exact provider
in the coordinator's busy state with zero free slots reports
`buyer_serving:true` even though it is not immediately `RoutingEligible`. A
degraded, draining, legacy, incompatible, or sanctioned provider reports
`buyer_serving:false` and cannot satisfy network readiness, but that result does
not prevent or undo an independently proven local signed-set/health commit.

AC-V0.1-27. Shared mutation ownership: installer, manual update, coordinator
autoupdate, Malibu repair, CLI startup recovery, and install recovery contend
on the same outer `~/.config/macprovider/install.lock`; autoupdate owners then take
`~/.local/share/macprovider/autoupdate/update.lock`. Cross-writer tests prove
the fixed outer-then-inner order, live-owner refusal, stale-file recovery,
installer-record PID-reuse/start-identity rejection, boot-change recovery,
pending-transaction fencing, reverse-order release, and SIGKILL recovery
without mixed release components or deadlock. Watchdog tests prove its
compatibility recovery entry point is non-mutating and cannot restore rollback
bytes or launchd state from stale markers.

AC-V0.1-28. Signed discovery replay resistance: after accepting discovery head
sequence `N` and digest `D`, a lower sequence is rejected with
`discovery_head_replay`, a different digest at sequence `N` is rejected with
`discovery_head_equivocation`, and an expired head is rejected with
`discovery_head_expired`. No rejected head causes download, drain, marker
creation, or mutation.

AC-V0.1-29. Revoked rollback target remains stopped: when local target health
fails but the preserved prior release is below the effective signed minimum or
revoked, recovery emits `rollback_target_disallowed`, restarts neither release,
retains fenced recovery material, and requires an independently authorized
emergency recovery target.

AC-V0.1-30. Exactly-once launchd reload: a running launchd-managed provider
updates through a plist-backed helper whose decoded policy has
`RunAtLoad:true`, `KeepAlive:false`, and `LaunchOnlyOnce:true`, with no
`SuccessfulExit`, demand, or throttle trigger. A nonzero helper exit does not
run a second time after more than the historical ten-second retry cadence.
Exact legacy UUID helper labels are fenced before any canonical job mutation;
malformed and prefix-confusable labels are untouched. A delayed canonical
bootout is polled until exact absence before the one bootstrap; timeout and
unknown inspection errors perform no bootstrap. Manual and automatic update
paths own the shared mutation lock before fencing, and rollback fences before
restoration. Post-start commit requires eleven matching two-second
target-version, compatibility-set, process, and instance samples, so a
ten-second stop/restart loop cannot satisfy local health. Those samples MUST
come from the live local HTTP listener and coordinator startup MUST begin only
after that listener has bound; an in-memory status object or a process that
failed to bind cannot commit recovery. The local commit gate MUST bind the
exact compatibility-set digest when one is declared. Model warmth is not an
update-integrity field: a target that reports the exact release and
compatibility identity MAY commit before `model_loaded` becomes true, while
model preparation remains governed by the ordinary serving/admission
lifecycle.

The first v1.8.54 target launched by the immutable public v1.8.53 updater MAY
fence the recurring legacy helper before configuration or model work only when
both durable authorities identify that exact executable: the pending marker
has `commit_owner:"self_update"` or `commit_owner:"coordinator"` and the target
version/path, while an unexpired same-boot prepared or adopted startup handoff
binds the canonical service identity, target path, and target executable
SHA-256. The current process MUST also be the positive PID reported by launchd
for that exact service identity; an interactive or otherwise non-launchd
process cannot consume the handoff. The pending marker's `sha256` continues to
identify the preserved rollback binary and MUST NOT be compared to the new
executable. Missing, expired, cross-boot, malformed, path-mismatched,
hash-mismatched, owner-mismatched, or launchd-PID-mismatched authority fails
closed without fencing.

After an authorized launchd target adopts the startup handoff, it MUST retain
that authority while the exact pending marker remains armed. A crash, logout,
or reboot before commit MAY recover the adopted authority only when the same
provider and operation, target path and executable SHA-256, pending owner, and
current positive launchd PID all revalidate. The listener MUST remove the
adopted handoff promptly after the exact pending marker disappears, changes, or
expires; it MUST NOT retain a maintenance exclusion for the handoff's original
maximum lifetime after commit.

Every rollback entry point, including coordinator orphan recovery and CLI
startup recovery, MUST fence the stable helper and exact lowercase-UUID legacy
helpers before restoring bytes. Only bounded positive launchd absence proof
permits helper-plist removal and restoration; unknown inspection results retain
the marker, backup, and current bytes for a later bounded retry. The watchdog
copy embedded in the installer MUST NOT restore bytes, fence helpers, rewrite
plists, or bootstrap/kickstart the provider as update recovery.

When rollback retains a marker in `restoring_previous` or
`awaiting_previous_readiness`, the restored previous binary MAY start only when
the marker owner is authorized and its previous version, installed target path,
rollback SHA-256, and current positive launchd PID all identify that exact
process. It MUST fence stale reload helpers, but MUST NOT adopt or recover the
failed target's startup handoff. Wrong previous bytes, version, path, owner, or
PID fail closed without fencing.

All Swift `launchctl` list, print, bootout, and bootstrap operations used by
this transaction MUST share a hard-bounded runner that drains process output
concurrently and escalates from termination to kill when the bound expires.
Timeout is a distinct fail-closed error even for otherwise allowed bootout
failure; it cannot authorize helper-plist removal, binary restoration, or
first-hop fencing. The generated one-shot helper MUST independently bound each
of its `bootout`, `print`, and `bootstrap` subprocesses with the same
terminate-then-kill behavior. A service-loaded probe that times out or returns
an unknown result MUST throw or otherwise stop the restart transaction; it
MUST NOT be interpreted as service absence.

After CLI startup recovery restores the preserved release, its bootstrap and
kickstart operations MUST also be bounded. Bootstrap success is accepted; a
nonzero bootstrap is accepted only when a bounded exact-service print proves
the canonical provider is already loaded. Kickstart MUST succeed. A timeout,
unknown bootstrap state, or failed kickstart MUST retain the pending marker and
rollback backup, emit a sanitized deferred-restart event, and leave recovery
for a later bounded attempt rather than claiming rollback completion.

Signed-policy persistence before mutation is side-effect-free with respect to
pending markers, backups, and live release bytes. If signed-policy persistence
fails after a release swap, only the updater orchestrator that still owns the
shared mutation lock and has already fenced reload helpers MAY restore the
preserved release.

AC-V0.1-R005-1. Threshold counting, not transience: an accepted-session provider
whose coordinator recommendation records fewer than
`accepted_session_recovery_failure_threshold` consecutive forward-progress
failures (including a single missing-compatibility-target observation) MUST NOT
invoke the signed recovery rail; once the threshold is reached for the current
recommendation, it MUST become eligible.

AC-V0.1-R005-2. Target-missing is stuck only when persistent: a coordinator that
advertises a `recommended_binary_version` with no `recommended_compatibility_set_id`
across at least the threshold of consecutive observations makes the accepted
provider eligible; a single such observation followed by a valid target (rollout
transient) resets the counter and grants no eligibility.

AC-V0.1-R005-3. Primary-rail precedence and reset: while the
coordinator-recommendation path is making forward progress it takes precedence and
the signed-recovery rail is not invoked; when the coordinator later advertises an
installable target (or the recommendation identity changes), the counter resets to
zero and the coordinator path resumes as primary.

AC-V0.1-R005-4. Additive, serialized, attributable: an accepted-session recovery
invocation changes no buyer-serving, routing, trust, or admission state; never
runs concurrently with the coordinator-recommendation rail for the same target
(shared mutation lock); and emits R-6.8 observability that attributes the
invocation to R005 with the recommendation identity and consecutive-failure count.

## Threat model

T-1. Attacker controls the GitHub release pipeline through signing-key
compromise. The ECDSA P-256 checksum signature no longer protects code
integrity because the attacker can sign malicious checksums. The remaining
SPEC-020 invariants still protect against downgrades, non-GitHub URLs, unsafe
archives, insufficient disk, mid-inference swaps, and post-start rollback for
crashing binaries. Residual risk accepted in v0.1.0: a malicious binary signed
by the trusted release key and passing `self-test` can execute on operator
machines.

T-2. Attacker MITMs GitHub Releases responses or asset downloads. HTTPS,
GitHub-host validation, signed checksums, SHA-256 tarball verification, and
archive validation defend against asset substitution, URL hijack, and tarball
tampering. The signed, expiring monotonic discovery head plus persisted highest
sequence prevents mutable-listing replay and equivocation after a trusted
checkpoint. Residual risk: the attacker can cause denial of update by blocking
or corrupting responses.

T-3. Attacker controls the coordinator and lies about
`recommended_binary_version`. The coordinator cannot make the provider install
an unsigned, non-GitHub, missing, checksum-mismatched, or downgrade artifact.
It can cause the provider to install a legitimately signed newer release sooner
than the operator intended, subject to opt-out, drain, and cooldown. Residual
risk accepted in v0.1.0: coordinator compromise remains a fleet-policy
compromise for signed newer releases.

T-4. Attacker controls a coordinator that advertises a malicious binary version
that legitimately existed in GitHub release history but is older than the
current provider. R-2.1 defends against this downgrade attempt: lower and equal
versions are no-ops. Residual risk: if the provider is already running an older
vulnerable version, SPEC-020 cannot make that current binary safe.

T-5. Attacker controls a coordinator and also publishes a malicious signed
newer GitHub release before discovery. The provider's cryptographic checks
will accept the release if it is legitimately signed, newer, archive-safe, and
passes `self-test`. Drain and rollback reduce availability damage but do not
prove semantic safety. Residual risk accepted in v0.1.0: release governance and
signing-key custody are outside provider-side enforcement.

T-6. Malicious local user has write access to provider config, state
directory, or binary path. A user who can write config can disable autoupdate or
tamper with local state; a user who can write the binary path can replace the
program directly. SPEC-020 requires trusted-path checks and executable-file
validation for rollback markers, but it does not defend against a local account
with write authority to the trusted binary directory. Residual risk: local
write access to provider-owned executable or state paths is inside the trust
boundary and must be controlled by filesystem permissions.

T-7. Provider installer/update processes race with each other, launchctl, or
liveness supervision, making mutation ownership and rollback observation an
attack surface. The shared outer lock, fixed outer-then-inner ordering, durable
PID/start/boot ownership, pending-transaction fencing, atomic markers,
same-directory rollback targets, trusted-path validation, executable-file
validation, and a single pending update ID defend against mixed releases,
deadlock, stale-marker rollback, path injection, and rollback to
attacker-chosen files. The companion watchdog is outside mutation ownership and
therefore cannot restore a stale binary, release set, plist, watchdog script, or
Malibu app artifact. Residual risk: launchd/watchdog liveness bugs can still
create availability failures; v0.1.0 limits rollback to one prior release and
disables autoupdate for the session after rollback.

T-8. Attacker replays a signed historical release that is higher than the
provider's current version but below the operator's current safe floor, or
known revoked after signing. Downgrade refusal alone does not block this if the
historical release is still semantically newer than the running binary.
`effective_minimum_safe_binary_version` and
`effective_revoked_binary_versions` defend against signed historical-release
replay, while the signed expiring discovery head rejects stale discovery state
and persists the highest accepted sequence/digest. Ordinary coordinator
recommendations MUST NOT lower the effective floor or remove versions from the
effective revoked set. The persisted monotonic signed-policy invariant also
protects against attacker-controlled release listings attempting to
retroactively clear revocations or lower previously observed signed-policy
minimums. A provider with no prior checkpoint still requires a currently valid
signed head; its bounded validity window is the bootstrap freshness limit.

## Open questions

Q-1. Should autoupdate respect a quiet window, such as avoiding local
09:00-18:00, or should it always update immediately on detection after drain?

Q-2. Should the complete prior-release backup be retained after a successful
local signed-set/health commit across reboots and arbitrary process restarts,
or is the single pending-update observation window enough?

Q-3. When the coordinator advertises a version and GitHub does not yet have a
matching release, should the provider silently retry with backoff, or should it
surface the release/coordinator drift loudly on first observation?

Q-4. Is the v0.1.0 hard drain policy correct at 120 seconds plus 30 seconds, or
should the timeout be 60 seconds, 5 minutes, or per-stream rather than global?

## Deferred to v0.x

Deferred to v0.2.0:

- Per-machine randomized stagger to avoid a whole fleet draining at once.
- Canary cohorts, staged rollout percentages, and prerelease channel opt-in.
- A custom transport for the mandatory signed monotonic discovery head and
  compatibility artifact index, independent of GitHub Releases hosting.
- Coordinator UI/API aggregation for fleet-wide autoupdate status beyond the
  provider-sent `last_autoupdate_event`.

Deferred to v0.3.0 or later:

- Rollback retention beyond one prior complete release.
- Multi-architecture update selection.
- Quiet-window policy, if Q-1 resolves in favor of time-windowed updates.
- An authenticated synthetic buyer request as optional network-readiness
  evidence beyond local update integrity.

## Change log

- v0.1.18 (2026-09-05): R-4.14 write-fence carve-out for supervisor telemetry
  (RFC-001 §7 / F5, #1386). The watchdog may additionally write its own private
  single `supervisor-beacon.json` (a non-executable, non-config diagnostic
  marker; SPEC-025 §5.4) — not a provider/supervisor artifact and carrying no
  update/rollback authority. No other fence weakened.
- v0.1.17 (2026-09-05): Added R-4.14 fencing provider exit-restart to the
  launchd provider-service `KeepAlive` as the single exit-restart owner; the
  companion watchdog is now normatively wedge-restart-only and MUST NOT restart
  on process exit or a missing/unvalidated launchd PID, nor mutate provider or
  supervisor artifacts, and MUST be installer-owned/non-self-restoring. To close
  the clean-exit gap that removing the watchdog exit-restart would otherwise open,
  a `consumer_user` serve process reaches exit 0 only under a validated stop
  intent; an unsolicited SIGTERM/SIGINT exits nonzero so launchd restarts it
  (SPEC-001 FR-12). The existing wedge predicate is unchanged; consuming the new
  SPEC-025 §5.2 `model_liveness_token_v1` in the wedge-prober restart decision and
  a domain-aware headless wedge target (RFC-001 F3) are deferred follow-ups.
  Explicitly supersedes stale SPEC-026 wording that the watchdog "force-restarts"
  during rollback (rollback authority was removed in v0.1.13). Locks in RFC-001
  §5.1/§3 (#1203 / follow-ups #1382/#1383) and removes the second, mutable
  exit-restart authority behind #1189. No existing requirement weakened; behavior
  lands via the cited code follow-ups.
- v0.1.16 (2026-09-02): Consumer and R005 autoupdate paths now divert a
  recognized `headless_fleet` / system-domain provider to the actionable terminal
  skip `reason:"headless_operator_update_required"` (`outcome:"skipped"`) before
  the install-topology gate and every later mutating gate — but after the
  non-mutating `target_revoked` / below-minimum check, which still wins — instead
  of a bare `unsupported_install_topology` forward-progress failure. Recognition
  matches the mutating-update gate `validateHeadlessUpdateMode` at full parity:
  `protected_file` custody, an install manifest declaring the `headless_fleet`
  profile or `system` launchd domain, or a managed system-domain provider
  LaunchDaemon present on disk, loaded in launchd, or in an indeterminate launchd
  state; an invalid/indeterminate topology fails closed to the headless handoff.
  Diverting before the topology gate closes the R-4.13 safety hole where a
  headless node with a stale/loaded consumer LaunchAgent could still be driven
  into consumer autoupdate mutation. The skip is not counted for SPEC-020-R005
  accounting, and accepted-session re-observation also treats such a provider as
  not-stuck, so a healthy operator-managed node no longer loops
  `failure → R005 → failure` into the signed-recovery rail that hits the same
  operator boundary. A proven consumer topology continues normally; a genuinely
  unrecognized topology still fails closed as `unsupported_install_topology`. No
  R-2 safety invariant, live-service mutation, or rollback authority changed.
  Addresses issue #1324 (updater actionable-reason gap left open by the
  installer-side repair rail).
- v0.1.15 (2026-08-31): Corrected the append-only head renewal description to
  freshness-only. The `renew-release-discovery-head.yml` signer binds the target
  the current signed head already points at (resolved from the live transport
  head), never mutable GitHub `latest`; advancing to a newer stable target
  remains the separate coordinator-gated rollout's job. The renewal mints the
  smallest sequence strictly greater than every existing transport so it never
  leapfrogs a newer target's earlier-signed, lower-sequence prebuilt head and
  blocks a later rollout. This reconciles the renewal prose with SPEC-020-R001
  (discovery MUST NOT derive its target from mutable `latest` ordering); no
  requirement, conformance, or authority binding changed.
- v0.1.14 (2026-08-28): Added SPEC-020-R005, accepted-but-stuck session recovery.
  v0.1.8 scoped coordinator-independent recovery to providers that cannot
  establish a session; R005 closes the residual gap where an admitted provider
  whose coordinator-recommended target makes no forward progress (target-missing
  or unconfigured coordinator policy, or a recommended target unusable by the
  installed set) had no self-heal path while still serving. The fallback is
  additive recovery reach only — bounded by a failure threshold, gated by the
  same signed discovery head and every R-2..R-4 invariant, never running both
  rails concurrently for the same target, and never a routing/trust/admission
  change. Normative behavior extended; no existing requirement weakened.
- v0.1.13 (2026-08-27): Removed companion-watchdog rollback authority. The
  watchdog remains a current-boot-gated liveness monitor; pending marker,
  rollback backup, release-byte, plist, watchdog-script, and Malibu app
  mutations belong only to installer/Malibu repair and CLI startup/install
  recovery owners.
- v0.1.12 (2026-08-25): Named SPEC-026's SSH-only `headless_fleet` mode as an
  explicit unsupported autoupdate topology for this version. The existing
  per-user LaunchAgent topology is retained as `consumer_user`; system-domain
  update, one-shot reload, rollback, and reboot recovery remain future work.
- v0.1.11 (2026-07-21): Adds the protected `renew-release-discovery-head.yml`
  recurring signer and the anonymous v1.8.55 bridge verifier. Renewal appends a
  greater sequence-bound transport for the unchanged latest stable target;
  promotion proves the fixed-tag bridge instead of skipping prior-client checks.
  Physical update/rollback/buyer-serving evidence remains open under Partial #658.
- v0.1.10 (2026-07-21): Replaced the fixed mutable discovery-release
  assumption with append-only immutable prerelease transports named from each
  signed sequence. The bounded GitHub release listing is only a locator; the
  signed head, sequence-bound transport tag, exact numeric target-set binding,
  and persisted monotonic sequence remain authority. Protected publication
  rejects non-advancing heads before draft creation, forbids tag/asset reuse,
  and anonymously verifies the public target afterward. Records the unavoidable
  one-time supported bridge from v1.8.55, whose shipped fixed discovery tag is
  permanently immutable.
- v0.1.9 (2026-07-20): Replaced the incident-producing `launchctl submit`
  provider reload with an explicit one-shot LaunchAgent. Exact legacy UUID
  helpers and the stable helper are fenced before mutation, rollback, and each
  reload; the helper plist is mode 0600, atomically installed, self-removing,
  and declares `KeepAlive:false` plus `LaunchOnlyOnce:true`. After bootout it
  positively confirms canonical-service absence before its one bootstrap.
  Manual and automatic paths own the mutation lock before fencing; rollback
  fences before restoration. Local update commit now requires 20 seconds of
  continuous exact-version/set/process-instance health, exceeding the observed
  ten-second legacy retry cadence. The corrected provider CLI advances to
  1.8.54 so its bytes cannot collide with the already-public 1.8.53 component.
  Both automatic marker owners (`self_update` and `coordinator`) may consume
  the first-hop bridge, but only from the exact launchd-owned service PID.
  Swift launchctl operations are hard-bounded and drain output concurrently.
  Signed-policy persistence cannot restore release bytes outside the
  updater-owned lock-and-fence transaction.
  This is the narrow implementation contract for issue #651; whole-set
  convergence remains owned by #616.
- v0.1.8 (2026-07-17): Reconciled the `provider-autoupdate` authority against
  #610. A signed expiring monotonic discovery head plus exact artifact index and
  compatibility manifest are the update authority; live or cached coordinator
  admission is not required for manual recovery or default disconnected
  discovery. Local signed-set/launch/provider-health success is distinct from
  network readiness. Pending and success markers bind the exact target set,
  while rollback refuses a prior set that is revoked or below the effective
  minimum. SPEC-025 v0.18 consumes this split instead of repeating the prior
  admission-commit gate. The implementation remains nonconformant and requires
  code plus physical disconnected/rejected-provider evidence. #612, #616, and
  #617 remain separate authority-domain reconciliations.
- v0.1.7 (2026-07-15, runbook item 23): Closed the tokenless race-loser residual
  (the "Tokenless race-loser corner" note above). The coordinator propagates its
  admission verdict via the OPTIONAL `auth_state` ack field — wire shape/domain
  owned by **SPEC-001 §6.5.1 (v1.8.4)**, emission by **SPEC-003 FR-C9.2a
  (v0.10.3)**; SPEC-020 v0.1.7 owns only the autoupdate INTERPRETATION here. The
  CLI's `AutoUpdateTrustState.fromCoordinatorPayload` reads it authoritatively so
  a bearerless-duplicate race-loser is client-enforceable notify-only rather than
  heuristically inferred (and reachably `.eligible`); an unrecognized value is
  FAIL-CLOSED to the notify-only floor. Legacy coordinators that omit `auth_state`
  fall back to the prior inference (no behavior change). The client uses the
  signal only to hold a more-restrictive floor, never to relax a verdict.
  Coordinator: `internal/ws/messages.go` / `internal/ws/server.go` (both accept
  sites). Binary: `AutoUpdateTrustState.swift`. Two-module code + docs; no
  production behavior change for bearer-validated providers (prod `mac`
  unaffected).
- v0.1.6 (2026-07-11): Bound autoupdate to the complete manifest-backed binary
  plus catalog payload; replaced local-health/WebSocket-rejoin success with the
  coordinator-authoritative exact-provider `buyer_serving:true` and
  `catalog_admission_mode:current|previous` verdict; separated busy serving
  capacity from instantaneous `RoutingEligible`; and required complete-payload
  rollback on readiness failure. Shared mutation-lock ownership is normative
  in R-4.5 and AC-V0.1-27.
- v0.1.5 (2026-07-11): Reconciled the normative trust-state table with shipped
  behavior (Wave B decision gate G2, disposition (c)). Split the single
  `provisional → notify-only` row by auth sub-state: a provisional provider
  that passes encrypted-leg, attestation (where required), and token guards is
  autoupdate-**eligible** when `accept_provisional` is set (default true;
  `AutoUpdateTrustState.swift` tier gate) — whether or not it holds a
  validated token, since the eligible row's token column allows "validated or
  not-configured" — while explicitly opted-out, self-minted, and
  bearerless-duplicate provisional sessions remain notify-only; added explicit
  failed-guard rows (encrypted-leg failed, attestation failed, token rejected)
  so every provisional sub-state has a defined verdict, mirroring the
  pre-existing pinned rows. Added a provisional-eligibility rationale (the
  fleet is 100% provisional by design; binary replacement is independently
  crypto-gated, so per T-3 a coordinator can at most accelerate a legitimately
  signed newer release). Qualified AC-V0.1-13 so its notify-only enumeration
  no longer contradicts the new eligible row. Added an "Eligible does not
  always mean bearer-validated" note distinguishing the issuer-less-deployment
  path (`internal/ws/server.go:810-811`, operator-chosen, not a gap) from the
  tokenless race-loser corner (a residual gap). Documented that residual: a
  tokenless race-loser session (coordinator-internal `AuthBearerlessDuplicate`,
  `internal/ws/server.go:838,851`) is admitted into the pool only if it
  registers before an existing session for the same `provider_id`
  (`internal/pool/provider.go:658-668` refuses registration otherwise), and in
  the admitted case is not currently distinguishable by the client because the
  coordinator does not propagate `auth_state` for that outcome, so that
  corner's notify-only verdict is coordinator-side intent only, not yet
  client-enforceable; the production `mac` provider is unaffected (holds a
  validated token). Closing that gap needs a coordinator-side `auth_state`
  propagation change, carried as a follow-up and out of scope here. Split the
  single "self-minted, bearerless-duplicate" row into two rows to distinguish
  first-time token issuance (pending validation) from the race-loser
  (never-validated) case; both remain notify-only. Spec-and-comments only: no
  behavior change — the shipped code was already correct and flipping the
  default was rejected because it would break prod auto-update.
- v0.1.4 (2026-06-29): Absorbed r4 audit findings:
  - B-r4-M-1: success-state cleanup ordered sequence, success sentinel crash
    recovery, `orphaned_success_sentinel` failure class, and acceptance
    coverage.
  - B-r4-M-2: corrected `marker_deadline` recovery citations to R-4.10 and
    pinned future-beyond-tolerance cooldown/session retry state.
- v0.1.3 (2026-06-29): Absorbed r3 audit findings:
  - A-r3-H-1 and C-r3-M-1: live `autoupdate_trust_state` invariant,
    `trust_state_lost` failure class, partial-state cleanup, and acceptance
    coverage.
  - A-r3-M-1: `timeout_skipped` drain phase capability gate and readiness
    recovery requirement.
  - B-r3-M-1 and B-r3-M-2: success-state cleanup and `marker_deadline`
    writer/basis/tolerance/recovery semantics.
  - B-r3-M-3: `NORMALIZED_TARGET` definition and downstream release lookup,
    marker, drain reason, and cooldown-key binding.
  - B-r3-M-4: post-start rollback failure-class split for crash, health
    failure, and coordinator rejoin timeout.
  - C-r3-M-2 and C-r3-M-3: persisted monotonic signed-policy state and full
    64-hex SHA-256 oversized-version redaction.
- v0.1.2 (2026-06-29): Absorbed r2 audit findings:
  - A-r2-H-1 and C-r2-H-1: normative trust-state table, explicit
    `autoupdate_trust_state`, and encrypted-leg eligibility requirement.
  - B-r2-M-1, B-r2-M-2, and C-r2-M-2: trusted state root, lock semantics,
    temp-file creation, fsync/rename requirements, and marker schema types.
  - A-r2-M-1: corrected v2 `auth_response` citation to SPEC-008 §10.5 while
    retaining SPEC-001 §6.5 for legacy `hello_ack`.
  - A-r2-M-2: stable autoupdate drain discriminator and
    `drain_status.phase:"timeout_skipped"` wire extension.
  - B-r2-M-3: orphaned pending marker and corrupt rollback backup recovery
    state machine.
  - B-r2-M-4: `release_asset_missing` failure class and acceptance coverage.
  - B-r2-M-5: 4096-byte `last_autoupdate_event` bound clarification and
    `event_payload_too_large` fallback.
  - C-r2-M-1: revocation provenance, monotonic precedence, and v0.1.0 empty
    default clarification.
  - C-r2-M-3: version-string and numeric-component length bounds, oversized
    reason codes, and raw-value redaction.
- v0.1.1 (2026-06-29): Absorbed r1 audit findings:
  - A-r1-H-1 and C-r1-H-1: cross-spec amendment, authoritative coordinator
    source, and trusted-auth trigger boundary.
  - A-r1-H-2: convergence boundary for latest-assumption consumers.
  - A-r1-H-3, B-r1-M-4, and C-r1-M-3: rollback observer eligibility,
    pending-marker, lock, backup, symlink/hardlink, and restore-hash
    hardening.
  - A-r1-M-1: provider-initiated autoupdate drain distinction.
  - A-r1-M-2, B-r1-M-6, and C-r1-M-4: SPEC-001 observability extension,
    enums, size bound, and redaction invariant.
  - A-r1-M-3: shared `SelfUpdate.compareSemver` comparator binding.
  - B-r1-M-1, B-r1-M-2, and B-r1-M-3: release-by-tag resolution,
    recommendation regex validation, and fixed cooldown backoff math.
  - B-r1-M-5: backward-compatible opt-out keys and environment variables.
  - C-r1-M-1 and C-r1-M-2: minimum-safe/revoked-version hook, historical
    replay threat, and checksum-signing key rotation policy.
- v0.1.0 (2026-06-29): Initial normative draft for provider autoupdate wiring
  around the existing manual `SelfUpdate` flow.
