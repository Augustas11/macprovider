# SPEC-020 - Provider autoupdate

Version: v0.1.7
Status: Implemented on branch; v1.8.31 rollout pending. The production path ran
the 2026-07-10 incident-recovery
autoupdate to CLI 1.8.21. Trust-table drift remains resolved as documented in
v0.1.5. v0.1.6 adds the complete-payload, shared-mutation-ownership, and
coordinator-authoritative buyer-serving commit gates required by Entry 133.
v0.1.7 (runbook item 23) closes the tokenless race-loser residual: the
coordinator propagates its `auth_state` admission verdict on the accept ack so
the bearerless-duplicate notify-only row is client-enforceable.

## Goal

SPEC-020 v0.1.6 defines provider-side autoupdate for `macprovider-cli`.
When the coordinator advertises a newer `recommended_binary_version`, the
provider auto-invokes the existing `SelfUpdate` validation and replacement
flow, subject to explicit throttling, opt-out, drain, rollback, and
observability invariants.

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
- Replacing the existing manual `macprovider-cli update` command.

Convergence boundary: SPEC-020 guarantees convergence to latest only for
default-installed, launchd-managed providers with autoupdate enabled and
rollback observation available. Providers with explicit opt-out,
missing/disabled watchdog, or unsupported install topology are outside the
latest-assumption population. Future features that depend on latest-provider
behavior MUST exclude old binaries via the existing `required_binary_version`
admission gate or an equivalent explicit gate.

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
corner described immediately below, which is a residual gap. The production
`mac` provider holds a validated `provider_token` and reaches `.eligible` via
the bearer-validated path.

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

**Live trust-state predicate.** `autoupdate_trust_state` is NOT a
handshake-time snapshot; it is a live session predicate. The provider MUST
re-evaluate eligibility immediately before each irreversible autoupdate phase:

1. Before starting download.
2. Before entering drain.
3. Before creating `pending.json` / writing the rollback backup.
4. Before invoking the atomic binary swap.
5. Before invoking `launchctl bootstrap` to start the new binary.

Any transition from `eligible` to a notify-only verdict (per the trust-state
table) between these phases MUST:

- Abort the autoupdate sequence immediately.
- Emit `failure_class:"trust_state_lost"` with a stable structured reason
  naming the trigger (e.g., `encrypted_leg_invalidated`, `tier_demoted`,
  `token_revoked`, `coordinator_disconnected`,
  `attestation_state_degraded`).
- Clean up partial state: release the inner `update.lock` and then the outer
  provider mutation lock, delete any temp downloads,
  delete any partial `pending.json` and rollback backup that have not yet been
  atomically committed.
- If `pending.json`, the rollback backup, or the live binary swap has already
  been atomically committed, restore the prior binary through the rollback path
  before deleting the committed marker/backup and releasing both locks in
  reverse acquisition order; the provider MUST NOT start the newly swapped
  binary after trust is lost.
- Refuse to retry autoupdate for the remainder of the session; cooldown
  re-evaluation is performed on the next coordinator session start.

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

All notify-only rows in the normative table MUST NOT trigger download, drain,
swap, marker creation, or cooldown.

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

R-1.2. The provider MAY poll GitHub Releases periodically as a fallback release
discovery source, but GitHub polling MUST NOT override an active coordinator
recommendation. While connected to a coordinator that supplies
`recommended_binary_version`, the provider MUST only install that target
version, not a newer unrelated GitHub `latest` version. When no coordinator
session is active or the coordinator omits `recommended_binary_version`, a
GitHub poll MAY discover a newer version for notify/status purposes, but it MUST
NOT trigger autoupdate in v0.1.0.

R-1.3. Before attempting an autoupdate, the provider MUST validate
`recommended_binary_version` against `^[vV]?[0-9]+\.[0-9]+\.[0-9]+$`.
Missing or empty values are no trigger. Malformed values MUST fail eligibility
with `failure_class:"recommended_version_invalid"` and MUST NOT mutate
autoupdate state. The entire `recommended_binary_version` value MUST be no
more than 32 UTF-8 bytes, and each numeric component MUST be no more than
8 digits. Oversized values MUST fail eligibility with
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

R-1.7. The manual `macprovider-cli update` command MAY ignore the autoupdate
session-attempt throttle, but it MUST continue to enforce the cryptographic and
archive safety requirements in R-2.

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

R-4.4. Autoupdate eligibility MUST fail closed if the watchdog or an equivalent
rollback observer is absent, disabled, or unavailable, with
`failure_class:"rollback_observer_unavailable"`. Missing rollback observation
MUST prevent download, drain, swap, and marker creation for the target.

R-4.5. Every provider release mutator and recovery observer MUST share one
kernel-held ownership boundary. The outer lock is
`$HOME/.config/macprovider/install.lock`; installer, manual CLI update,
coordinator autoupdate, Malibu update, watchdog, and install/autoupdate recovery
MUST acquire it before inspecting or mutating live binary, resource, config,
plist, recommendation, service, or recovery state. Autoupdate and its observers
MUST then acquire the inner
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
the exact admission commit or its recovery completes, even if the original
writer exited. On contention, an autoupdate path MUST emit
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
symlink-following disabled. The watchdog or equivalent rollback observer MUST
`lstat` every path, reject symlinks, reject unexpected hard links, reject
malformed JSON, and reject any path outside the trusted state and binary
directories before copying, renaming, or restoring. The watchdog MUST verify
the binary SHA-256 and release-tree SHA-256 before restore.

R-4.9. Trusted state root. `$HOME/.local/share/macprovider` and
`$HOME/.local/share/macprovider/autoupdate` MUST be created or repaired as
provider-UID-owned, mode 0700. Implementations MUST reject if any path
component is a symlink, is not owned by the provider UID, has group/world
write, has non-owner-write ACLs, or crosses an unexpected device/mount
boundary.

R-4.10. Startup and watchdog recovery MUST handle invalid pending markers as a
state machine. If `pending.json` exists but neither the outer provider mutation
lock nor `update.lock` has a live holder and no observer process is running,
the marker is orphaned. The provider or watchdog
MUST emit `failure_class:"orphaned_pending_marker"` and delete the marker after
restoring from backup if the backup is valid by size and hash. If the backup is
not valid, it MUST quarantine the marker by renaming it to
`pending-quarantined-<timestamp>.json` and disable autoupdate until an operator
clears the quarantine. If `pending.json` references a `backup_path` that is
missing or hash-mismatched, the provider or watchdog MUST emit
`failure_class:"rollback_backup_corrupt"`, MUST NOT delete the live binary
because no rollback is possible, MUST disable autoupdate for the session, and
MUST surface a structured event.

R-4.10a. Success-state cleanup.

**Success-state cleanup sequence and crash recovery.**

**Success-state cleanup sequence.** Post-start observation succeeds only when
the new binary passes local health, reports
`binary_version == NORMALIZED_TARGET`, and the coordinator's authenticated,
non-redirected exact-provider readiness response reports
`buyer_serving:true` with `catalog_admission_mode` equal to `current` or
`previous` within the post-start window. The returned catalog release, digest,
signer, and selected-row identity MUST equal the activated local payload. A
WebSocket rejoin, process liveness, or local health alone is insufficient. A
busy provider with no free inference slot MAY satisfy `buyer_serving:true`:
serving-capable network membership, not instantaneous `RoutingEligible`, is the
commit authority. Only then may the observer execute the following ordered
sequence. Each step MUST complete (or its absence MUST be safely recoverable)
before proceeding to the next:

1. **Write success sentinel.** Atomically create
   `<binary-dir>/.macprovider-cli.success-<update_id>` with
   `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600, containing the JSON
   `{"update_id":"<uuid>","binary_version":"<NORMALIZED_TARGET>","success_at":"<RFC3339>"}`.
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
  embedded `binary_version` matches the current
  `CoordinatorClient.binaryVersion`: this is a delayed success cleanup path.
  The observer MUST unlink any matching `pending.json` (without triggering
  orphan recovery), delete any matching rollback backup, release any held
  inner `update.lock` and outer `install.lock`, then delete the success sentinel.
  Treat as
  `outcome:"success"`, NOT as orphan recovery.
- If a success sentinel exists but its `binary_version` does NOT match the
  current binary: emit `failure_class:"orphaned_success_sentinel"`, delete the
  sentinel, continue.
- If `pending.json` is absent BUT a rollback backup exists with a stale
  `update_id` (no matching pending marker), delete the backup without
  attempting restore.

v0.1.0 deletes the rollback backup on success. Multi-version rollback
retention is deferred to v0.3.0.

R-4.11. If the new binary crashes, fails to start, fails local health, or fails
to obtain the R-4.10a coordinator-authoritative buyer-serving verdict within
60 seconds of the new process start, the watchdog MUST roll back the complete
payload by restoring the preserved prior release and restarting the
LaunchAgent. Each trigger maps to exactly one failure class:

- `post_start_crash`: the new binary fails to start or exits within the
  post-start window.
- `post_start_health_failed`: the new binary started but local health check
  (e.g., `/healthz` probe) failed within the post-start window.
- `post_start_rejoin_timeout`: the new binary did not obtain an authoritative
  readiness response for the exact provider within the post-start window.
- `post_start_not_buyer_serving`: the coordinator answered authoritatively but
  did not report `buyer_serving:true`, did not admit `current|previous`, or
  returned catalog identity fields different from the activated payload.

R-4.12. After watchdog rollback, autoupdate MUST be disabled for the rest of the
provider session and the provider MUST emit a structured rollback failure event.
The next provider process start MAY re-enable autoupdate unless disabled by
configuration or cooldown state.

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

R-5.4. Opt-out MUST NOT disable manual `macprovider-cli update`; manual update
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
`post_start_rejoin_timeout`, `post_start_not_buyer_serving`,
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

## Acceptance criteria

AC-V0.1-1. End-to-end autoupdate: given a running provider at version `N` and a
trusted coordinator auth payload advertising `recommended_binary_version: N+1`,
the provider detects the target, resolves the matching GitHub release by tag,
downloads the `darwin-arm64` tarball plus checksum assets, verifies signature
and checksum, validates the complete manifest-bound binary-plus-catalog payload,
runs `self-test`, drains to zero in-flight requests, preserves the prior release,
atomically writes the pending marker, atomically swaps, restarts through
launchd, and receives the exact coordinator-authoritative current-or-previous
buyer-serving verdict before reporting success at `binary_version: N+1`.

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
start or exits within 60 seconds, the watchdog restores the prior release and
emits `failure_class:"post_start_crash"`. Given a new binary that starts but
fails local health within the post-start window, the watchdog restores and
emits `failure_class:"post_start_health_failed"`. Given no authoritative
readiness answer within the post-start window, the watchdog restores and emits
`failure_class:"post_start_rejoin_timeout"`; given an authoritative answer that
is not exact current-or-previous buyer serving, it restores and emits
`failure_class:"post_start_not_buyer_serving"`. In all cases rollback uses the
pending marker only after `lstat` checks and binary plus release-tree SHA-256
verification, restarts the LaunchAgent, disables autoupdate for the rest of the
session, and surfaces a structured rollback event.

AC-V0.1-11. Coordinator-visible observability: after each major decision point,
the next heartbeat or state update includes `last_autoupdate_event` with a
bounded structured object reflecting the latest phase and outcome.

AC-V0.1-12. Manual update compatibility: `macprovider-cli update` continues to
perform the existing cryptographic validation and self-test path, and opt-out
configuration does not prevent a manual operator update.

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
watchdog/equivalent rollback observation, autoupdate fails eligibility with
`failure_class:"rollback_observer_unavailable"` before download, drain, swap,
or marker creation.

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
both the outer `install.lock` and inner `update.lock` are unheld, no observer
process is running, and the referenced binary plus release backups are valid by
size and hash, startup or watchdog recovery emits
`failure_class:"orphaned_pending_marker"`, restores from backup, deletes the
marker, and surfaces a structured event. If the backup is not valid, recovery
quarantines the marker as `pending-quarantined-<timestamp>.json` and disables
autoupdate until operator repair.

AC-V0.1-20. Corrupt rollback backup blocks rollback: given `pending.json`
references a missing or hash-mismatched `backup_path`, startup or watchdog
recovery emits `failure_class:"rollback_backup_corrupt"`, does not delete the
live binary, disables autoupdate for the session, and surfaces a structured
event.

AC-V0.1-21. Trusted state root hardened: startup creates or repairs
`$HOME/.local/share/macprovider` and
`$HOME/.local/share/macprovider/autoupdate` as provider-UID-owned mode 0700,
rejects symlinked, non-provider-owned, group/world-writable,
non-owner-write-ACL, or unexpected-mount path components, opens `update.lock`
and the outer `install.lock` with `O_CREAT|O_NOFOLLOW` mode 0600, validates the
outer durable owner record, treats only a live advisory lock holder or a
durable pending transaction as contention, and creates marker and backup temp
files with `O_CREAT|O_EXCL|O_NOFOLLOW`.

AC-V0.1-22. Live trust-state loss aborts autoupdate: provider becomes eligible
at v2 `auth_response`, begins download, and then the encrypted leg is
invalidated mid-download. No swap occurs; the provider emits
`failure_class:"trust_state_lost"` with reason
`encrypted_leg_invalidated`, cleans up partial state, and refuses autoupdate
for the remainder of the session.

AC-V0.1-23. Success-state cleanup. Post-start success completes the ordered
cleanup sequence. Subsequent provider startup finds no orphan state, emits no
rollback events, and reports `outcome:"success"` (or `outcome:"noop"` if
cleanup completed during the prior session). Crash between any pair of steps
1–5 is recoverable on next startup without rollback of the successful update.

AC-V0.1-24. Complete release payload: a candidate archive whose executable is
correctly signed but whose manifest-bound catalog sidecar is absent or whose
catalog digest belongs to the previous release fails before drain with
`failure_class:"release_payload_incomplete"`; no live executable or resource is
changed. Activation and forced rollback tests prove executable, manifest,
catalog bytes, sidecars, and keyring move together.

AC-V0.1-25. Coordinator-authoritative commit: local health and WebSocket rejoin
alone do not clear `pending.json`. Success is committed only after the exact
provider's authenticated `details=readiness` response reports
`buyer_serving:true`, `catalog_admission_mode:current|previous`, and the exact
activated release/digest/signer/row identity. An authoritative mismatch rolls
back with `post_start_not_buyer_serving`; timeout remains
`post_start_rejoin_timeout`.

AC-V0.1-26. Busy capacity is serving capacity: an admitted exact provider in
the coordinator's busy state with zero free slots reports
`buyer_serving:true` and can commit an update even though it is not immediately
`RoutingEligible`. A degraded, draining, legacy, incompatible, or sanctioned
provider reports `buyer_serving:false` and cannot commit.

AC-V0.1-27. Shared mutation ownership: installer, manual update, coordinator
autoupdate, Malibu, watchdog, and both recovery paths contend on the same outer
`~/.config/macprovider/install.lock`; autoupdate owners then take
`~/.local/share/macprovider/autoupdate/update.lock`. Cross-writer tests prove
the fixed outer-then-inner order, live-owner refusal, stale-file recovery,
installer-record PID-reuse/start-identity rejection, boot-change recovery,
pending-transaction fencing, reverse-order release, and SIGKILL recovery
without mixed release components or deadlock.

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
archive validation defend against response substitution, asset URL hijack, and
tarball tampering. Residual risk: the attacker can cause denial of update by
blocking or corrupting responses.

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
the watchdog, making mutation ownership and rollback observation an attack
surface. The shared outer lock, fixed outer-then-inner ordering, durable
PID/start/boot ownership, pending-transaction fencing, atomic markers,
same-directory rollback targets, trusted-path validation, executable-file
validation, and a single pending update ID defend against mixed releases,
deadlock, stale-marker rollback, path injection, and rollback to
attacker-chosen files. Residual risk: launchd/watchdog logic bugs can still
create availability failures; v0.1.0 limits rollback to one prior release and
disables autoupdate for the session after rollback.

T-8. Attacker replays a signed historical release that is higher than the
provider's current version but below the operator's current safe floor, or
known revoked after signing. Downgrade refusal alone does not block this if the
historical release is still semantically newer than the running binary.
`effective_minimum_safe_binary_version` and
`effective_revoked_binary_versions` defend against signed historical-release
replay only once a non-empty local baseline exists; v0.1.0 empty defaults are a
hook, NOT active protection until such a baseline ships. Ordinary coordinator
recommendations MUST NOT lower the effective floor or remove versions from the
effective revoked set. The persisted monotonic signed-policy invariant also
protects against attacker-controlled signed releases attempting to
retroactively clear revocations or lower previously observed signed-policy
minimums.

## Open questions

Q-1. Should autoupdate respect a quiet window, such as avoiding local
09:00-18:00, or should it always update immediately on detection after drain?

Q-2. Should the complete prior-release backup be retained after a successful
admission commit across reboots and arbitrary process restarts, or is the
single pending-update observation window enough?

Q-3. When the coordinator advertises a version and GitHub does not yet have a
matching release, should the provider silently retry with backoff, or should it
surface the release/coordinator drift loudly on first observation?

Q-4. Is the v0.1.0 hard drain policy correct at 120 seconds plus 30 seconds, or
should the timeout be 60 seconds, 5 minutes, or per-stream rather than global?

## Deferred to v0.x

Deferred to v0.2.0:

- Per-machine randomized stagger to avoid a whole fleet draining at once.
- Canary cohorts, staged rollout percentages, and prerelease channel opt-in.
- A custom release feed or signed update manifest independent of GitHub
  Releases `latest`.
- Coordinator UI/API aggregation for fleet-wide autoupdate status beyond the
  provider-sent `last_autoupdate_event`.

Deferred to v0.3.0 or later:

- Rollback retention beyond one prior complete release.
- Multi-architecture update selection.
- Quiet-window policy, if Q-1 resolves in favor of time-windowed updates.
- An authenticated synthetic buyer request as a stronger proof beyond local
  health plus coordinator-authoritative current-or-previous buyer serving.

## Change log

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
