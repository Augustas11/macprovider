# SPEC-025 — Native Mac App (signed `.dmg`, native Mac app with menu-bar presence)

Status: DRAFT v0.46.0 · Owner: @Augustas11 · Target: 2026 Q3

**Change log v0.46.0 (2026-10-26, Related: #2164):**
Adds SPEC-025-R021 Create for provider-local SDXL-Turbo images, capability
and memory gating, creative-hold progress and a local PNG gallery. R001 and
R020 place Create after Terminal in the sidebar. Existing requirement IDs
remain stable. App tests do not establish real-weights generation or released
provider acceptance; those gates remain pending.

**Change log v0.45.0 (2026-10-26, Related: #2164):**
Adds SPEC-025-R017 named Agents, SPEC-025-R018 bounded stdio MCP clients,
SPEC-025-R019 app-owned scheduled Tasks, and SPEC-025-R020 navigation and
selection migration. Existing R001–R016 retain their identifiers. The sidebar
order becomes Chat, Terminal, Agents, Tasks, Models, Earn, then Settings and
Diagnostics. Agents reuse R011 workspace tools and R012 buyer credentials and
model eligibility; unattended MCP execution requires an explicit task allow-list.
Implementation and release acceptance remain pending.

**Change log v0.44.0 (2026-10-26, Related: #2157):**
R012 managed launches and gateway-funded Terminal harnesses use the SPEC-045
privacy consumer by default. The buyer key stays with the consumer; launched
agents receive only its local token. Missing trusted configuration fails closed.
Only verified served assurance may be displayed after an authenticated response;
requested assurance is not a served label. Prior removal of pre-setup privacy
warnings remains in force. Actual production agent acceptance remains pending.

**Change log v0.43.0 (2026-10-26, Related: #2054):**
User-first navigation opens on Chat; Earn combines Dashboard and Provider;
Models merges discovery, installed models and downloads; Terminal embeds
bounded, ephemeral shell and gateway harness sessions. R016 clarifies login-PATH
propagation and session-wide terminal cleanup; project-config disabling applies
to OpenCode, while Crush retains its visible warning. The first-run menu command
is Open Malibu. Terminal output cannot write the clipboard; deliberate user Copy
remains available. The Connected apps / Terminal privacy warnings were removed
by operator decision, and no privacy claim replaces them. R012 and R016 remove
the persistent privacy warning, gateway privacy status, Details privacy text,
Cursor transit note and Malibu Chat privacy redirect. The buyer-key
credential-safety sentence remains required. Existing copy, catalog, preparation
and client configuration rules remain normative.
The Terminal requirement is SPEC-025-R016. This change does not implement
the local-provider path of SPEC-025-R015; Terminal harness tabs target the gateway.

**Change log v0.42.0 (2026-10-26, Related: #2160):**
Adds SPEC-025-R015's local Terminal compatibility contract: Claude Code uses
provider-local `/v1/messages` only when the provider explicitly advertises the
adapter, with SPEC-001-R011 local-work marking and customer-first behavior.
Terminal implementation and actual client acceptance remain pending.

**Change log v0.41.0 (2026-10-26, Related: #2155):**
§3.3 adds SPEC-025-R013 single-instance handoff and SPEC-025-R014 bounded
quit. The successor removes stale app processes after an update, including
instances predating this protocol. A rollback launch preserves a newer running
app, and hung app shutdown cannot retain duplicate menu-bar items indefinitely.

**Change log v0.40.0 (2026-10-22, Related: #2107):**
- SPEC-025-R012: the Connected apps model picker lists only models whose
  gateway `/v1/models` entry publishes `capabilities.tools: true` and at least
  32,768 tokens of context (coding agents send long system prompts and tool
  schemas); no capability is inferred when the metadata is absent. The
  endpoint test is a bounded tool round trip on the selected API and model:
  the model must call the declared `get_magic_number` tool, then answer after
  the call and its result are sent back. It remains a gateway test, not
  evidence that the external client works.

**Change log v0.39.0 (2026-10-21):**
Exact Qwen OpenCode model options carry the full recommended sampling profile
(R012): both use top_k 20; only Coder uses repetition_penalty 1.05. Acceptance
checks the actual outbound fields, not merely saved configuration.

**Change log v0.38.0 (2026-10-21):**
Connected apps installs a guarded model-scoped OpenCode system-prompt plugin
as a protected, reversible managed asset (R012). Custom agent prompts,
workspace instructions and permissions remain unchanged. The Coder-only
worked example demonstrates native tool calls and read display metadata;
launchers require OpenCode 1.17.9 for the exact managed Qwen identities.
Client acceptance remains separate from production-gateway verification.

**Change log v0.37.0 (2026-10-21):**
Connected apps uses model-scoped OpenCode sampling for the two exact Qwen
gateway/artifact identities (R012), preserving stock agent prompts and
automatic tool selection. Sampling configuration is not client qualification.

**Change log v0.36.0 (2026-10-20, Related: #2054):**
Provider presents the observed KV disk tier and bounded recent lifecycle
restarts (R007). Settings persists and applies menu-bar and Dock preferences
live, preserving a visible way to reopen Malibu, and names only the stable
update channel supported by the CLI updater (R009). Connected apps names
Cursor's manual base-URL override and keeps unverified automatic tool use
distinct from guaranteed required/named tool selection (R012).

**Change log v0.35.0 (2026-10-20, Related: #2059):**
Models and Discover name each model by a readable title (family, size and
quantization read from the model identifier) with the exact identifier as a
caption, without middle truncation (R004). A row with a SPEC-044-R014
download offers Download with its size and a confirmation, the
`Needs preparation` section reads **Not downloaded**, and Discover lists every
signed catalog model with fit inline and the first row selected (R006).
Connected apps shorten the R012 disclosures: one **Not private** banner that
says these apps' requests are not encrypted by Malibu, so private mode does
not apply, and that private requests work through Malibu Chat; one required
buyer-key sentence with the rest behind Details. The gateway model list loads
only with a saved buyer key, loads after saving one, shows its errors beside
the button, and says when no models are served.

**Change log v0.34.1 (2026-10-19, Related: #2054):**
Local Chat marks its loopback requests `X-MacProvider-Origin: local-app`, the
only marker SPEC-001-R011 treats as local. Connected apps hand the buyer key
from Keychain to the client launcher through a one-time 0600 file in a 0700
directory that is read once and deleted, and export it to the client
environment; the interface discloses that repository configuration and agent
commands can read it and recommends a dedicated, spend-limited buyer key.
OpenCode project configuration is disabled for launched sessions and Crush
users are warned.

**Change log v0.34.0 (2026-10-19, Related: #2054 Phase 3):**
Replaces the Chat placeholder with capability-gated local Chat, bounded
read-only workspace tools, and Connected apps. Adds SPEC-025-R010–R012 in
§3.2.2. Local use follows SPEC-001-R011 and is never earnings. Connected
apps use buyer credentials and a remote gateway with explicit privacy
limits, protected reversible configuration, and endpoint-specific tests.

**Change log v0.33.0 (2026-10-18, #2054 Phase 2 sidebar shell):**
Adds §3.2.1 with the first R-numbered requirements of this spec,
SPEC-025-R001 to R009: the main window is one sidebar shell (Dashboard, Chat,
Models, Discover, Provider, then Settings and Diagnostics) with the status
pill in the sidebar header and the loaded model and health in its footer.
The Dashboard keeps the Phase 1 status pill and Earnings card and gains a
"Your model" card; Advanced diagnostics moves to Diagnostics; the invite
panel and the Settings window move into the Settings section (Cmd-, opens
it). Models replaces the Change Model sheet with the SPEC-044-R008 library,
the switch confirmation states the SPEC-011 customer impact (HTTP 503 while
loading and draining, no cancel, no download) and follows switch progress.
Discover follows SPEC-044-R013. Provider shows reported serving, slot,
continuous batching and native MTP state. Chat is a placeholder until the
local-use requirements land. Quantization, architecture, parameter and
capability columns stay off until the signed catalog carries them.
This revision also covers the catalog refresh and the brand mark: (1) Models,
Discover and the Dashboard model row keep the last good catalog projection on
screen while a refresh runs and after a failed refresh, with a "Showing the
last catalog update" notice and Retry, until the projection's SPEC-044-R003
freshness deadline; "unavailable" needs a failed read and no usable
projection (SPEC-044-R008). The catalog read bound is 15 s, above the CLI's
own coordinator bound (SPEC-044-R002). (2) The menu-bar glyph, Dock icon and
in-app tile draw the brand kit's Construction mark: a cut-out dome in a band,
seven tapered rays and two side beams on the baseline.

**Change log v0.32.0 (2026-10-18, #2029 Phase 1 truthful dashboard):**
§3.1 and §3.2: the app launches as a menu-bar agent (`LSUIElement=true`) and
switches to `.regular` activation (Dock icon, Cmd-Tab, main menu) while any
Malibu window is open, returning to `.accessory` when the last one closes; a
Dock click with no window reopens the dashboard. The menu-bar item is the
re-cut icon-only glyph with state badges (no USDC text). The dashboard is one
status pill, an Earnings card, a Mac health line and a collapsed Advanced
diagnostics section; it shows no raw log tail and follows the copy contract in
§3.2 (SPEC-021-R011/R012, SPEC-005 §11.4, SPEC-044-R004). Model-switching
text is reconciled with the shipped Change Model flow.

**Change log v0.31.0 (2026-10-18, tag-stamped app version + self-relaunch after update).** Normative, §3.3: (1) the Malibu.app component version is stamped from the release tag at build time (`CFBundleShortVersionString` = tag version, `CFBundleVersion` = its positive patch `Z`). `project.yml` carries only a `0.0.0` development default, and the candidate build, the acceptance signer and published-release verification all check both values. This supersedes the v0.17 allowance for an independently versioned Malibu component, which let a stale `1.8.224` stamp ship inside release 1.8.251. (2) After the CLI-owned update swaps the installed bundle, the running Malibu process relaunches itself onto the installed bundle, once the bundle is proven to be the installed signed set's Malibu member. The CLI still never signals, quits, or launches the app process. A pre-v0.31 process picks up the first such update at its next launch.

**Change log v0.30.2 (2026-10-17):** Editorial, no normative change: §5.2 notes that SPEC-020 R-4.14 v0.1.28 now defines the persisted operator-pause signal; the stall threshold, its owner and the hard-freeze cases stay deferred.

**Change log v0.30.1 (2026-10-14, public-repo cleanup):** Editorial, no normative change: owner is the GitHub handle.

**Change log v0.30 (2026-10-04, issue #1842 signed provider code identity).**
Adds §6.2.1: a release that ships the provider CLI signs the CLI's code
identity (`code_cdhash`, `team_id`, `signing_identifier`) into
`pearl-release.json` as `provider_code_identity`, derived from the shipped
tarball bytes, so SPEC-049 `privacy_class.approved_code_identities` can be
filled from signed release metadata instead of by hand. `compatibility-set.json`
and the `compatibility-artifact-index.json` role set are unchanged.
Verifiers are present-then-strict: they fully validate the field when present
and accept its absence, with an explicit notice, only for provider CLI versions
at or below 1.8.213, so already-signed candidates and rollback targets stay
verifiable; 1.8.214 and later fail without it. A present field always binds the
shipped tarball, including in the GitHub download path.

**Change log v0.29 (2026-09-08, issue #1445 frozen-Sparkle-bridge confinement).**
Restores the code and this spec to DECISION_CRITERIA Entry 156/158: the frozen
Malibu 1.8.32 `SUPublicEDKey` trust anchor is **confined to the one-time v1.8.39
bridge**, and the source app plus every signed build after v1.8.39 ship key-free.
`scripts/prepare-malibu-bootstrap-trust-anchor.py` now injects the anchor only for
`v1.8.39` and its `verify` requires the anchor's absence on every other version,
so the unconditional anchor `prepare`/`verify` calls in `release.yml` and
`malibu-release.yml` are correct for all tags and the mirror-publish gate
(`verify-malibu-release-artifacts.sh`) stops rejecting keyless
acceptance-promoted releases. This changes only the Sparkle trust-anchor
posture; the independent `malibu-release.yml` Pearl publication path is
unchanged and still frozen-bridge-only (its `verify-malibu-bootstrap-publication.sh`
gate requires the committed frozen bridge appcast for every tag other than
v1.8.39), so dispatching that workflow for a later tag remains an unsupported,
pre-existing limitation tracked with the bridge-removal follow-up. This removes
the earlier v0.14/v0.18 generalization
that had every signed target retain the key — a drift from Entry 156 that never
carried its own decision entry and that froze `download.malibu.tech` at v1.8.117.
The immutable v1.8.39 bridge, its frozen appcast, and the live download endpoint
are unchanged; retiring that now-inert machinery is tracked separately.

**Change log v0.28 (2026-09-05, F5 §5.4 dwell-state enumeration correction from
the Opus pre-merge review).** Corrects the `last_restart_dwell_state` enumeration
to match the IMPL: `flap` is **not** a persisted dwell-state value. In the
single-row model the beacon that supersedes a prior pending restart is the same
beacon that starts the next restart, so the column always reflects the current
restart; a flap is recorded by incrementing `flaps_total` and setting
`last_flap_observed_at`. The enum is {`unknown`, `correlated_pending`, `held`,
`artifact_confounded`}; flap-loop queries use the two flap counter columns.
Documentation-only clarification; no behavior change.

**Change log v0.27 (2026-09-05, F5 §5.4 hardening reconciliation from the
adversarial pre-merge review).** Reconciles §5.4 with the IMPL hardening: the
beacon file/dir ownership rule now defines BOTH topologies (consumer
provider-UID `0700`/`0600`; headless root-owned `0755` dir / `0644` file — root
stays sole writer, never chowned to the provider) and the reader enforces
"owned by reader-uid or root, not group/other-writable" in place of the old
uid-`0600`-only text; adds the internal-consistency rule
(`restarts_total + deferrals_total ≤ seq`), scopes the anti-pinning step ceiling
to subsequent beacons (a first insert / long-uptime first contact is bounded only
by the absolute cap + the ratio), and adds the state-reset carve-out (the one
permitted `seq` regression, for a mid-boot watchdog-state wipe). No behavior added
beyond the F5 IMPL; observability-only and redaction non-negotiables unchanged.

**Change log v0.26 (2026-09-05, supervisor telemetry contract — RFC-001 §7 / F5,
#1386).** Adds §5.4: a **separate** supervisor telemetry contract
(`macprovider.supervisor-event.v1`) so provider liveness recovery is observable
coordinator-side (the #1189 blind spot). The companion watchdog publishes a
**best-effort latest-state beacon** to a single overwrite-OK trusted-root file
`supervisor-beacon.json`: `kind` ∈ {`restart`,`deferral`,`beacon`} naming the
latest event, always-present topology (allowlisted `supervisor_label` class +
version) and **monotonic recovery counters** (`restarts_total`/`deferrals_total`),
plus **sticky** `last_restart`/`last_deferral` detail subobjects (reason=wedge,
targeted service_instance, cooldown_state, §5.2 model-liveness / deferral_reason)
carried on **every** beacon so a topology tick never erases restart evidence. There
is no append-log and no acknowledgement protocol: the fire-and-forget heartbeat has
no coordinator ack, so recovery observability rides the counters (a jump >1 shows
missed events without losing the signal). The CLI is **strictly read-only** (writes
nothing, owns no cursor) and, after hardened reads, **projects the beacon to the
allowlisted schema locally** (dropping unknown keys before uplink) into a heartbeat
field **`last_supervisor_event`**, distinct from `last_autoupdate_event`. The
coordinator ingests best-effort/non-blocking, orders by `seq` alone per
`(provider_id, boot_id)` (provider `ts` is diagnostic-only, never gates/orders, so
a stepped-back Mac clock cannot suppress telemetry), upserts one row (with explicit
derived-state columns incl. `last_restart_observed_at`) into a separate
`provider_supervisor_events` store, and **derives** sustained-serving dwell as its
own wall-clock observation of the post-restart new-`service_instance_id` instance
staying serving-eligible in its pool view (reset on staleness/disconnect/
replacement; no new heartbeat `serving` field). The acceptance signal keys on the
**sticky `last_restart`** advancing (not on observing a `kind=restart` beacon) and
requires both old/new instance ids known, with the window anchored on the
coordinator-derived `last_restart_observed_at`. MUST NOT overload the SPEC-020
autoupdate event model. Redaction non-negotiables apply.
Behavior lands via cited follow-up code (watchdog emit + CLI uplink + coordinator
ingest).

**Change log v0.25 (2026-09-05, watchdog exit-restart fence + model-liveness token).**
Locks in RFC-001 §5.1/§3 (#1203; follow-ups #1382/#1383). Aligns with SPEC-020
v0.1.17: the companion watchdog is normatively **wedge-restart-only** — the launchd
provider-service `KeepAlive` is the single exit-restart owner, and the watchdog
MUST NOT restart on process exit or a missing/unvalidated launchd PID, MUST NOT
write provider **or supervisor** artifacts, and MUST be
installer-owned/non-self-restoring (§5.3, §8). To close the clean-exit gap that
removing the watchdog exit-restart would otherwise open, a `consumer_user` serve
process reaches exit 0 only under a validated stop intent; an unsolicited
SIGTERM/SIGINT exits nonzero so launchd restarts it (SPEC-001 FR-12). Adds a
schema-complete **model-thread liveness token** to the `/v1/status` contract
(§5.2, capability `model_liveness_token_v1`; monotonic-clock age, idle-safe via
`active_inference`) as an **observability signal only** — the watchdog wedge
predicate is unchanged, and wiring the token into a wedge-prober restart decision
(plus a domain-aware headless wedge target and coordinator telemetry export) is a
deferred follow-up. Behavior lands only via the cited code follow-ups.

**Change log v0.24 (2026-08-27, watchdog authority reduction).** Aligns with
SPEC-020 v0.1.13: the companion watchdog is a current-boot-gated local liveness
monitor only. It no longer owns auto-update rollback, release-byte restore,
launchd plist restore, watchdog script restore, Malibu app restore, or
rollback-driven provider bootstrap/kickstart. Installer/Malibu repair and CLI
startup/install recovery remain the transaction owners.

**Change log v0.23 (2026-08-25, headless fleet boundary).** SPEC-026 v0.27
defines a separate SSH-only `headless_fleet` profile for the existing CLI, with
system LaunchDaemons and protected-file credential custody. This spec keeps the
consumer Malibu path intact: `consumer_user` remains the default, uses the
existing per-user CLI Keychain stores and LaunchAgents, and registers Malibu
itself through `SMAppService`. Malibu MUST neither attach to nor import from a
system-domain headless provider. A bounded profile-conflict UI for detected
opposite-profile evidence remains a follow-up app task and is not automatic
migration authority.

**Change log v0.22 (2026-07-25, landing page download authority).** §10 pins the
public **Download for Mac** button to the immutable versioned GitHub release asset
for the accepted release, matching §6 step 11 and the v0.13 removal of `latest.dmg`
authority. §10 previously still specified `https://download.malibu.tech/latest.dmg`,
which is retained only for old-client compatibility and retired as the primary
landing-page download authority; the shipped page combined that stale button with a
version and SHA-256 fetched live from the GitHub API, so it advertised the current
release's digest while serving v1.8.53 bytes. The tag, digest, and link MUST now all
resolve from one pinned accepted release. P4 in §11 is reconciled to match.

**Change log v0.21 (2026-07-19, fragment capability negotiation).** Malibu
requires `referral_fragment_links_v1` in addition to the referral status/action
capabilities before rendering any referral UI. This fails closed for already
shipped CLIs that accept only the superseded path/query grammar. Malibu advances
independently to 1.8.43; the fragment-aware CLI advances independently to
1.8.49.

**Change log v0.20 (2026-07-19, fragment-only referral links).** Malibu accepts
only the exact `https://malibu.tech/j#/<code>[?c=<challenge>]` grammar, strips
an optional X challenge before onboarding, and rejects the legacy
credential-bearing path/query shape.

**Change log v0.19 (2026-07-18, private-prebeta referral intake).** Fresh
Malibu onboarding exposes the signed bundled referral handoff, accepts the
canonical `https://malibu.tech/j#/<code>` origin, and requires a nonblank invite
before starting the 10–30 minute installer/model path. A healthy incumbent still
attaches without referral intake. Signed release assembly retains the bundled
capability only after the exact installer bytes match the signed compatibility
manifest.

**Change log v0.18 (2026-07-17, provider-update authority reconciliation).**
SPEC-020 owns update authorization and commit semantics. The signed monotonic
discovery head and exact compatibility artifact index authorize recovery
without coordinator admission. Exact signed-set identity, launch, and local
provider health commit the local transaction; coordinator admission and
buyer-serving are separate network-readiness evidence and cannot roll a locally
healthy newer signed set back. Malibu remains a typed caller/observer of the
CLI-owned transaction.

**Change log v0.17 (2026-07-17, compatibility-set component versions).**
The signed compatibility-set release identity and each member's marketing
version are separate version domains. Private acceptance candidates may bind a
reviewed release tag to independently versioned Malibu and provider CLI
components, while the manifest, updater, rollback marker, and candidate checks
must validate the exact declared component tuple. An acceptance set may keep the
provider CLI at the installed version or advance it, but may not downgrade it;
only the separately gated emergency rollback path may move the CLI backward.
Installed payload discovery resolves the normal CLI symlink to the canonical
support-directory executable before reading adjacent signed resources. Private
Pearl metadata derives its advertised provider version from the same signed
tuple and is rejected unless Pearl's bounded private-acceptance flag is
explicitly enabled. Public production releases retain the stricter
tag-to-provider-CLI equality gate unless a separate reviewed release change
explicitly replaces it.

**Change log v0.16 (2026-07-16, referral projection hardening).** The CLI
projects the coordinator-authenticated public `join_base_url` and Malibu accepts
only its exact `/j#/<code>` invite, even when that public origin differs from the
coordinator API host. Raw X challenges, share URLs, composer intents, and the
provider bearer remain CLI-only. Malibu refreshes referral status at a bounded
60-second cadence, expires it after 90 seconds, and clears it on control-channel
disconnect. CLI restore/reopen refreshes coordinator status and discards pending
X material if social rewards or the exact invite binding changed.

**Change log v0.15 (2026-07-16, SPEC-034 referral recovery).** Malibu may
collect bounded referral input and pass it to the signed installed CLI through a
supported versioned onboarding request. The CLI performs registration and all
authenticated coordinator referral operations, retains identity and bearer
custody, and projects sanitized coordinator-authored referral state under a
`referral_status_v1` capability; typed social actions additionally require
`referral_advocacy_v1`. All referral UI additionally requires
`referral_fragment_links_v1`; its absence means unavailable rather than a
legacy-link fallback. Malibu never receives the bearer, calls
referral coordinator APIs directly, infers serving/invite eligibility, or starts
a provider child. Malibu and CLI marketing versions are independent; local
protocol capabilities and schema versions, not marketing-version equality,
govern referral UI availability.

**Change log v0.14 (2026-07-15, issue #585 bootstrap trust continuity).**
Malibu 1.8.39 was the first CLI-owned build whose signed app bundle retained the
exact `SUPublicEDKey` shipped by Malibu 1.8.32. Sparkle 2.6.4 rejects an
otherwise valid update when the target bundle removes that key, so protected
Malibu releases inject the frozen public key after unsigned app construction,
before protected bundle writes, and re-verify it after bundling before
codesigning. The target still contains no Sparkle package/framework, feed URL,
automatic-check setting, or updater runtime; the key is inert trust metadata for
old-client compatibility. Final-DMG verification requires that exact posture.

**Change log v0.13 (2026-07-14, issue #585 Option 2 completion).** The
launchd-managed CLI is the sole provider lifecycle, credential, admission-identity,
state, update, rollback, and uninstall authority. Malibu is a non-secret observer: it
reads the versioned local HTTP lifecycle contract, reads the same-user owner-only
control-socket projection for CLI-authenticated earnings, and invokes only the signed
installed CLI's typed repair/update/uninstall transactions. A legacy App-Keychain
bearer may be read once as migration input, but is deleted only after fresh CLI custody
is proven; production Malibu cannot create a provider bearer, register an identity, or
sign coordinator admission. Sparkle runtime/feed ownership and independent App update
ownership are removed; later old-client compatibility publication may still use a
signed appcast/`latest.dmg` surface as distribution metadata, not as Malibu-owned update
authority. The signed compatibility set binds Malibu.app, the CLI, launchd definitions,
watchdog, catalog/resources, coordinator admission metadata, and rollback plan. v0.18
supersedes v0.13's target-admission commit gate with
SPEC-020's local signed-set/health commit and separate network-readiness result.
Auto-update opt-out applies to the entire set while explicit user update remains
available. **Every older statement below that assigns credentials, identity,
or update ownership to Malibu/Sparkle is historical and superseded by v0.13.** Physical
two-Mac, reboot/logout/locked-Keychain, interruption, #584 canary, and 24-hour soak
evidence remain rollout gates rather than claims of this repository change.

**Change log v0.12 (2026-07-14, issue #585 versioned-status and recovery slice).**
Malibu now reads a capability-gated v1 local status contract from the launchd CLI,
including bounded observation identity, exact service-instance identity, CLI-authored
lifecycle transitions, and the typed redacted credential condition. It preserves the
legacy unversioned reader path and suppresses incompatible or unadvertised typed
fields. When the CLI reports the exact `repair_from_protected_source` action, the
dashboard may invoke the validated installed CLI's `credentials repair` transaction
and wait for launchd health; Malibu never writes provider custody itself. The existing
App-Keychain compatibility bearer remains solely for shipped authenticated earnings
calls and is not justified by the new status reader; removing it requires replacing
those calls with a CLI/coordinator-owned versioned earnings surface.

**Change log v0.11 (2026-07-14, issue #585 Option 2 credential-custody
slice).** The launchd CLI, not Malibu, is now the provider-bearer authority. Malibu
invokes the installed CLI once to import the credential and a second time to verify
that a fresh CLI process reads the exact value, but keeps the live YAML source intact.
A restarted Keychain-backed CLI removes YAML only after coordinator admission.
Failure preserves the original private config and leaves the setup importable.
Existing token-bearing migrations retain a temporary App-Keychain compatibility copy
for shipped Malibu earnings calls; fresh tokenless bootstrap does not expose the CLI
credential to Malibu. A provider-ID-bound `.cli-credential-custody-v1` marker records
that the installed CLI freshly verified custody whenever that compatibility copy
exists. The exact shipped tokenless-YAML/App-only incident state is repaired by first
restoring its App bearer to private YAML, then running the ordinary installed-CLI
handoff. Secret snapshot deletion is confirmed before its journal is retired. Removing
the residual App credential dependency belongs to a later versioned earnings
replacement in issue #585; the v0.12 status reader alone does not remove it.
This v0.11 rule supersedes historical v0.4/v0.5 best-effort backup-cleanup notes.

**Change log v0.10 (2026-07-13, R9 audit-loop convergence — code source of truth).** R9
code/architect caught that the v0.9 watchdog routine/rollback boundary was fixed in §8 +
grounding table but NOT swept through the live §5 prose. v0.10 sweeps the last three
sites: the §5.2 architecture diagram, the §5.3 lifecycle sentence, and the §5.2 recovery
line now all state the boundary — the companion watchdog is a no-op on **routine** health
failures (provider-service `KeepAlive` restarts those) but **force-restarts** the provider
service during **auto-update rollback recovery** (`install.sh:4086,4113`).


**Change log v0.9 (2026-07-13, R8 audit-loop convergence — code source of truth).** R8
code caught that the R7 "watchdog never restarts" was too absolute: the companion
watchdog is a no-op for **routine** health failures (KeepAlive restarts those), but it
DOES force-restart the provider service during **auto-update rollback recovery**
(`launchctl kickstart`, `install.sh:4086,4113`). §8 + grounding table now state the
routine/rollback boundary.

**Change log v0.8 (2026-07-13, R7 audit-loop convergence — code source of truth).** R7
architect/code caught the watchdog-ownership tail and a bundle-layout invention: the
companion watchdog `live.malibu.provider-watchdog` **does not restart the CLI for
routine health failures** — its routine restart request is a no-op
(`note_provider_restart_request`, `install.sh:3575`); the launchd **provider service**
`live.malibu.provider` (`KeepAlive`) performs routine restarts (v0.8 further nuanced
in v0.9: the watchdog CAN force-restart during auto-update rollback recovery,
`install.sh:4086,4113`). Swept §0/§2/§5/§8 topology + ASCII diagram + lifecycle +
grounding table; §5.1 bundle tree lists **only** `Sparkle.framework` as embedded (the
app depends solely on Sparkle — `project.yml:21-24`; MLX runs in the CLI, `mlx.metallib`
sits in `MacOS/` beside the executable, not as an embedded framework).

**Change log v0.7 (2026-07-13, R6 audit-loop convergence — code source of truth).** R6
architect/code caught the last app-side twins: **§8 now documents THREE launchd
registrations** — the KeepAlive provider service `live.malibu.provider` (the plist
the app's evidence gate checks), the SEPARATE companion watchdog
`live.malibu.provider-watchdog` (`StartInterval=60`, `install.sh:47,4264`), and
`SMAppService` — previously "two" with the provider-service plist mislabeled as the
watchdog (grounding table + §0 CLI-track def aligned); §12 CLI self-update authority is
the coordinator-driven `AutoUpdater` (`CoordinatorClient.swift:2756`), NOT
`install.sh`/watchdog (matches §3.3); §4 `.pkg` build uses `pkgbuild` + `productsign`
(not `productbuild`/component plist, `release.yml:635`).

**Change log v0.6 (2026-07-13, R5 audit-loop convergence — code source of truth).** R5
architect/code caught remaining app-side twins: §3.3 BSDiff **delta updates marked
design-intent only** (shipped generator stages one full DMG, `generate-malibu-appcast.sh:67`,
consistent with §9); §7 receipt/admission Keychain services spelled out in full with
lifetimes — `com.malibu.provider.receipt-key` (rotatable), `.receipt-key.prev`
(grace), `.bootstrap-identity-key` (current CLI admission identity; legacy service name),
`.admission-identity-key.pending`, and `.admission-identity-key.prev`, account
`<provider_id>` (`ReceiptKeyStore.swift:22-25,58-92`); §4 distribution facts corrected —
`hdiutil` DMG (not `create-dmg`) and the optional signed App `.pkg` (`tech.malibu.app.installer`)
is already emitted, not a backlog item (`release.yml:599,616`); §13 backlog narrowed to
broader MDM/enterprise packaging.

**Change log v0.5 (2026-07-13, R4 audit-loop convergence — code source of truth).** R4
architect/code caught app-side build/distribution twins: §2 token-backup documented as
best-effort/may-persist (aligned to §7); §4 `.dmg` table — post-install runs `install.sh`
(SMAppService only registers the app login item, §8), and the pipeline already emits an
optional signed App `.pkg`; §5.1 bundle tree adds the **required** `macprovider-cli` +
`mlx.metallib` under `Contents/MacOS/` (`release.yml:556`,
`verify-tier2-provider-release.sh:405`); §6.2 CI recipe bannered as design-intent
(`release.yml` authoritative — archive-copy + `hdiutil`, not `-exportArchive`/`create-dmg`);
§7 receipt-key Keychain coordinates corrected to `com.malibu.provider.receipt-key`
(+`.prev`/`.bootstrap-identity-key`), account `<provider_id>`; §9 Sparkle trust anchor is
`SUPublicEDKey` in `Info.plist` (no `appcast-key.pub`), with deltas/phased-rollout marked
design-not-shipped (`generate-malibu-appcast.sh:67`).

**Change log v0.4 (2026-07-13, R3 audit-loop deep-tail convergence — code source of
truth).** R3 architect/code caught remaining "two live definitions" contradictions: §1
coexistence "unchanged" now carries the post-import token-custody caveat (launchd CLI
bearerless on restart); §2 config table corrected — the wrapper DOES rewrite the live
`config.yaml` to strip the token (`ProviderConfig.swift:312`); §3.3 states there ARE two
update authorities (Sparkle for `.app`; the CLI's own coordinator-driven `AutoUpdater`,
enabled by default — `AutoUpdateTrustState.swift:148`), not "no second authority"; §5.1
bundle layout — the bundled `macprovider-cli` in `Contents/MacOS/` is **required** by
the release pipeline (`release.yml:544`, `verify-tier2-provider-release.sh:405`), not
optional; §7 token backup documented as not-guaranteed-transient (best-effort delete,
recovery retains).

**Change log v0.3 (2026-07-13, R2 audit-loop straggler sweep — code source of truth).**
The v0.2 reconciliation left live sections asserting the pre-#418 model that the R2
codex 3-lane audit (code / security / architect) surfaced. v0.3 sweeps them to match
shipped code: §2 token custody nuanced (transient 0600 import-backup, not "never on
disk"); §3.1 normal stage order is `.idle→.runningCLIInstall→.startingAgent→.live`
(`.importingProviderIdentity` is deferred-retry-only), the installer env is inherited
(NOT sanitized; `PATH` set only when empty), and finalize gates on
`ProviderConfig.isConfigured` (bearer), NOT an App Ed25519 identity; §3.2 removes the
unshipped popover / earnings chart / "Copy diagnostics" / "Quit and Uninstall" (menu is
plain Quit; left-click opens Dashboard), and refines "Reconnecting" (diagnosed failures
+ attach timeout → `.error`); §7 states the markerless-CLI-owned first-precedence
`.showImportDialog` route; §12 corrects #2 (the app does NOT invoke `CLIUpdateRunner` —
`.updateCLI` maps to Sparkle); per-gate launch-error messages distinguished.

**Change log v0.2 (2026-07-13, CLI-wrapper architecture reconciliation — spec matched
to shipped code; code is source of truth):** The **CLI-wrapper refactor (PR #418,
2026-07-06)** inverted the v0.1 architecture. v0.1's §3.1 `malibu://` portal deep-link
onboarding and §5 "wrapper spawns a bundled CLI child; `MalibuAgent` owns the child
lifecycle; the App track does NOT install the watchdog" were **superseded**. Shipped
reality (`phase3-binary/app/Sources/Malibu/`): **Malibu is a monitor-only wrapper.**
Onboarding runs the bundled CLI-track `install.sh` (which registers the provider,
autotunes, downloads the model, and installs the launchd watchdog); the app then
**adopts and monitors** the launchd-managed `macprovider-cli` over local HTTP
(`/v1/health` + `/v1/status`) — it does **not** spawn a CLI child, and the
control-socket / in-app-register / in-app-autotune machinery still compiles but has
**no production caller** (retained only as test/legacy surface). The `malibu://`
scheme, `RegisterClient.postRegister` in-app registration, and the in-app
register→autotune→spawn path are gone from the live flow. v0.2 rewrites §3.1 and §5 to
the shipped monitor-only model, reconciles §2/§7/§8, and marks the compiled-but-dead
paths as legacy. No code change. **See the paired SPEC-026 v0.14** (same PR #418
reconciliation, client-onboarding side).

Earlier honesty note (v0.1, 2026-07-10): flagged the same supersession and pointed at
SPEC-026 §6/§7 + the Malibu sources as source of truth pending this v0.2 revision.

## 0. Terminology

- **CLI track** — existing `macprovider-cli` binary + `install.sh` + the launchd **provider service** `live.malibu.provider` and its separate companion watchdog `live.malibu.provider-watchdog` (§8). Developer-facing.
- **App track** — new `Malibu.app` (this spec). Non-developer-facing; brand is Malibu (see [malibu-branding memory]). User-visible strings never say "MacProvider" or `malibu.tech`.
- **Wrapper** — the Swift/SwiftUI code added by this spec (`Malibu.app`).
- **Managed CLI** — the existing `macprovider-cli` binary, installed and run by the
  **launchd provider service** `live.malibu.provider` (`KeepAlive`) that `install.sh`
  sets up (plus a companion health watchdog, §8). The wrapper
  **adopts and monitors** it; it does **not** launch it. (Reconciled v0.2 — v0.1
  called this the "CLI child" spawned by the wrapper; that spawn path is gone,
  §5.)
- **Consumer user profile** — `install_profile:"consumer_user"`, the unchanged
  App/CLI track defined by this spec: per-user config, CLI Keychain custody,
  provider/watchdog LaunchAgents in `gui/<uid>`, and Malibu's separate
  `SMAppService` login item.
- **Headless fleet profile** — `install_profile:"headless_fleet"`, the
  SSH-operated system-domain CLI profile defined by SPEC-026 §2.1. It has no
  Malibu process, App login item, user LaunchAgent, or Keychain dependency.

The consumer App and per-user CLI tracks must coexist and produce identical
on-chain behavior. A headless system-domain installation is mutually exclusive
with those tracks on the same Mac under SPEC-026 §2.1.

## 1. Goal

Ship a **click-and-forget provider experience** for non-developer Mac users. Replace the terminal-only path (`curl … | bash` at `malibu.tech/host/`) with a signed, notarized `.dmg` containing `Malibu.app` — a menu bar wrapper around the existing `macprovider-cli` binary.

### Success criteria

- Non-technical Apple Silicon user goes from `malibu.tech/host` → running provider in **≤ 3 minutes**, zero terminal.
- Same coordinator behavior, same receipts as the CLI track (the shipped app onboards a **CLI-track** provider via `install.sh` — SPEC-026 §6.1; no separate App-track registration).
- Signed compatibility-set updates are validated, installed, locally committed,
  and, on local failure, safely rolled back by the launchd CLI as one exact
  transaction under SPEC-020. Coordinator admission is a separate
  network-readiness result. Malibu can request the transaction but cannot
  update itself independently. "Quit and Uninstall" invokes the
  CLI transaction and reports any residue; dragging the app to Trash alone is not the
  supported uninstall path (§3.4).
- The CLI track coexists via the shared `config.yaml` + `.installed-by-app` marker (§7),
  with CLI-owned config routed to the import dialog (SPEC-026 §8). The installed CLI
  imports and fresh-process-verifies its own Keychain copy. A restarted CLI removes the
  matching YAML bearer only after coordinator admission and first state publication;
  Malibu then deletes any legacy App bearer and cannot recreate it.

### Non-goals (v1)

- Mac App Store distribution (sandbox conflicts with `mlx-swift` + long-running WS daemon).
- Windows / Linux / Intel Mac.
- In-app wallet UX beyond linking an address issued by portal.
- Fleet dashboard, orchestration, or remote management across multiple Macs
  from Malibu. The SSH-only per-host CLI installation profile in SPEC-026 §2.1
  is in scope there and does not add fleet-management UI to this App.

## 2. What already exists (grounding)

From reading `phase3-binary/`:

| Component | Where | What we reuse |
|---|---|---|
| Provider daemon | `Sources/macprovider-cli/MacProviderCLI.swift` | Ship the compiled binary inside `Malibu.app/Contents/MacOS/` |
| Local HTTP | `Sources/macprovider-cli/HTTPServer.swift` on `127.0.0.1:<port>` | Authoritative versioned lifecycle/status channel. Malibu polls `GET /v1/health` + `GET /v1/status`; unsupported older contracts degrade without false failure. |
| Control-plane IPC | `Sources/macprovider-cli/ControlSocket.swift` — typed JSON frames on an owner-only Unix socket | Read-only CLI-authenticated earnings/status projection. It never transfers a bearer or lifecycle ownership to Malibu. |
| Runtime | `mlx-swift-examples` (MLXLLM, MLXLMCommon) — pure Swift, no Python | Runs inside the **managed CLI** process, not the app; the app is a thin monitor wrapper. |
| Auth model | `provider_id` + `provider_token` bearer, per SPEC-001 / XSEC-1 | The CLI alone obtains, stores, and consumes the bearer. Malibu may read a legacy App item only long enough to migrate it into CLI custody, then deletes it. |
| Config | `~/.config/macprovider/config.yaml`, initially containing `provider_token` | A restarted CLI removes the exact matching migration source transactionally only after Keychain-backed coordinator admission. The fixed 0600 backup is the handoff snapshot; deletion is confirmed before journal retirement. |
| Provider service + watchdog LaunchAgents | `install.sh` installs BOTH the KeepAlive **provider service** `live.malibu.provider` (plist `live.malibu.provider.plist` — **this is the evidence the app checks**) and a SEPARATE **companion watchdog** `live.malibu.provider-watchdog` (`StartInterval=60`, `install.sh:47,4264`) that health-observes the daemon. The watchdog is a liveness monitor only; auto-update rollback and recovery mutation are owned by installer/Malibu repair and CLI startup/install recovery (SPEC-020 v0.1.13, §8 — the evidence plist is the provider service, NOT the watchdog). Evidence: `install_manifest.json` or the provider-service plist. | **The App track installs and relies on both** (via `install.sh`). `SMAppService.mainApp.register()` is a **separate** concern — it registers `Malibu.app` itself as a login item (`AppLoginItem.swift`), not the CLI daemon. |
| Portal | `portal.malibu.tech` (SPEC-014) — installer catalog | **Reconciled v0.2:** the wrapper does **not** open a portal URL for token issuance (removed with `malibu://`). App-track registration happens inside `install.sh` / the CLI track. |
| Release manifest / checksum | `scripts/sign-catalog.go`, `compatibility-set-manifest.py`, `compatibility-artifact-index.py`, tier2 release scripts | Binds the exact signed provider compatibility set and typed rollback plan. |
| Signing + notarization pipeline | `.github/workflows/release.yml` "Sign + notarize binary" step + `phase3-binary/dist/release-signing-runbook.md` | Reuse the existing keychain-import / codesign / `notarytool submit --wait` / `stapler` pattern verbatim; extend to sign the `.app` and `.dmg` |
| Signed `.pkg` delivery container | Same workflow, `pkgbuild` + `productsign` with **Developer ID Installer** cert, identifier `live.malibu.provider.cli`, preinstall blocks direct GUI install | Do **not** confuse with the App-track `.pkg`, which the pipeline **already emits** as an OPTIONAL scriptless flat package, identifier `tech.malibu.app.installer` (reconciled v0.5, `release.yml:616,635,641`) — this CLI one is a delivery container for `install.sh`, not a user-facing installer |

**README is stale.** `README.md` says signing is "planned for a future release." The actual state (as of `release.yml`): full pipeline exists, activates conditionally on secret presence — driven by the macOS 26.3.1+ launchd/AMFI change that rejects adhoc-signed binaries (see memory `macprovider-launchd-amfi-blocker-macos-26`). This spec **extends** that pipeline; it does not build it from scratch. README needs a follow-up correction.

## 3. User flows

### 3.1 First-run (cold install) — reconciled v0.2 to the shipped CLI-wrapper flow

1. `malibu.tech/host` → **Download for Mac** → `Malibu.dmg`.
2. Open `.dmg` → drag `Malibu.app` to `Applications`. Standard Finder UX.
3. Launch `Malibu.app`. Gatekeeper checks the stapled notarization ticket, no scary dialog.
4. Menu bar icon appears (`NSStatusItem`). The app launches as a menu-bar
   agent (`LSUIElement=true`, `Info.plist:25-26`), so no Dock icon shows until a
   window opens: while any Malibu window (dashboard, onboarding, settings) is
   open the app switches to `.regular` activation (Dock icon, Cmd-Tab entry,
   main menu with Settings…, Open Malibu, Edit, Window, Quit) and returns to
   `.accessory` when the last window closes (`MenuBar/DockPresence.swift`),
   unless the saved Dock preference keeps it visible (R009). The menu-bar
   icon may be hidden only while the Dock remains enabled. On launch, `applicationDidFinishLaunching` runs
   `handleStartup()`, which routes on disk state via `StartupState.detect().route()`
   → `.startAgent` / `.showOnboarding` / `.showImportDialog` / `.quit`
   (`MalibuApp.swift:30-140`, `LaunchProviderController.swift:302-372`). A fresh Mac
   (no config, no launchd evidence) routes to onboarding: a single window with a
   coral **Launch Provider** button (no wallet field, no node-link step, no browser).
   When SPEC-034 private-prebeta referral admission is enabled, the same window
   MUST collect a referral code or canonical `https://malibu.tech/j#/<code>`
   invite and syntax-check it as untrusted input before starting installation.
   It MUST label validation as local until the coordinator accepts the CLI
   registration attempt.
5. User clicks **Launch Provider** → `LaunchProviderController.launch()` drives a
   stage machine whose normal-success order is
   `.idle → .runningCLIInstall → .startingAgent → .live(model, tier)`
   (or `.failed`); `.importingProviderIdentity` is a **deferred
   missing-token retry** stage entered only after `.startingAgent`, NOT
   on the happy path (reconciled v0.3 —
   `LaunchProviderController.swift:14-21,117,165`). There is **no** in-app
   register / autotune / spawn step. The stages are:
   - **Short-circuit:** if a local provider is already healthy, skip the installer
     and just attach (`:79-87,144-163`).
   - **Run the bundled `install.sh`** (`runCLIInstall`). The installer
     is bundled at `Contents/Resources/install.sh` (copied from
     `phase3-binary/dist/install.sh` at build time). Malibu first authenticates
     the exact regular-file bytes against the signed compatibility manifest,
     then supplies those already-authenticated bytes to `/bin/bash -s --` over
     stdin with **no script-path or installer CLI args**. Current
     `CLIInstallRunner.installerEnvironment` does **not** inherit the parent
     environment: it constructs a sanitized allowlist containing fixed
     `PATH`/`HOME`/`TMPDIR`/`LC_ALL`, `MACPROVIDER_NO_PROMPT=1`, and only its
     validated port/version values.

     Referral onboarding extends that exact boundary as
     `CLIInstallRunner.run(referralCode:)`. After bounded syntax validation it
     creates an owner-only 0600, single-link, no-ACL regular source file with an
     unpredictable name and adds only its path as
     `MACPROVIDER_REFERRAL_CODE_FILE` to the sanitized install environment.
     `install.sh` captures and unsets that path before launching any child; it
     never reads, logs, copies, or persists the code. It invokes
     `malibu-cli bootstrap-auth --referral-code-file <source>`, and the CLI
     reopens the source with no-follow identity checks before reading it. The
     durable CLI journal
     `~/.config/macprovider/onboarding/referral-attempt-v1.json` stores only the
     provider ID, receipt-key digest, referral-code digest, attempt ID, and typed
     state; plaintext referral material is never journaled. The CLI sends the
     code only on the bootstrap initial/proof frames, persists the returned bearer
     to CLI Keychain, marks the digest journal committed, and removes the source
     file only after reopening it no-follow and proving the full stat identity and
     byte digest are unchanged. Malibu also best-effort removes its source file
     after installer exit. Exit 0 is the non-secret acknowledgement Malibu
     observes; the bearer never crosses back.

     Compatibility-set manifest v1 is exact-key and has no capability field; it
     MUST NOT be extended in place. For the fresh bundled path, the replacement
     Malibu build enables this UI only for its compiled-in v1 handoff. Before
     execution it hashes the exact `Contents/Resources/install.sh` regular-file
     bytes it is about to supply over stdin and requires equality with the signed
     manifest's `components.launchd.install_contract.sha256`, whose declared
     member is `compatibility-set-local/install.sh`. A missing, unreadable,
     symlinked, or mismatched top-level resource renders referral onboarding
     unavailable and executes nothing. Because Malibu executes that bundled
     installer for both fresh and existing-install onboarding, the compiled
     `MalibuBundledReferralBootstrapV1` gate MUST be true on every referral path.
     An existing installation additionally requires `referral_bootstrap_v1` in
     the installed CLI's versioned local status contract. Either missing gate
     renders referral onboarding unavailable while retaining ordinary
     attach/monitor behavior. No marketing-version equality check substitutes for
     either gate.
     `install.sh` performs the register + autotune (`autotune --recommend`) + model
     download + **launchd provider-service + watchdog install**; the app surfaces
     onboarding autotune progress both from the bounded `ps` stage probe
     (`CLIInstallRunner.swift:513-566`) and from `paid-yield` installer log lines
     that identify the current model and action (`:570-607`). A non-zero installer exit
     throws (installer rollback semantics).
   - **Verify CLI credential custody** (`importCLIConfigAfterInstall` →
     `ProviderConfig.importExistingCLIConfig()`, `:128`) — for an existing YAML bearer,
     save/verify the temporary App-Keychain compatibility copy, run installed-CLI
     credential import, then run a distinct fresh-process verify against one immutable
     0600 snapshot. Fresh bootstrap is already tokenless and runs verify-only against
     CLI Keychain. Malibu retains any existing YAML `provider_token`; CLI-owned
     admission cleanup removes it later. An absent CLI credential or incompatible
     installed CLI is retriable and preserves rollback state.
   - **Finalize** (`finalizeInstall`, `:165-199`): wait for the launchd provider's
     `GET /v1/health`, retry the Keychain import, then check `appIdentityConfigured`
     — which is actually `ProviderConfig.isConfigured` (config + `.installed-by-app`
     marker + provider ID, plus a matching `.cli-credential-custody-v1` marker when an
     App compatibility bearer remains, `:65`, `ProviderConfig.swift`), **NOT** the
     app Ed25519 identity (reconciled v0.3) — attach the `MalibuAgent` monitor, then
     `SMAppService.mainApp.register()` the login item and mark
     `.live(…, tier: .provisional)`. The login item is registered **only after** a
     successful attach (`testAttachFailureDoesNotRegisterLoginItemOrMarkLive`).

Time budget: a few seconds of UI + `install.sh`'s own register/autotune/download
time (60–240 s for the first model) in the background.

### 3.2 Steady state

- Menu bar icon: icon-only (#664), no USDC text. The glyph is the brand
  Construction mark re-cut for the status bar (cut-out dome in a band, seven
  rays, and the two side beams on the baseline): ink at least 14 pt tall in an
  18 pt tall canvas, strokes at least 1.5 pt, nothing touching the canvas edge, `NSStatusItem.variableLength`,
  `imageScaling = .scaleNone`, template image. State badges: serving or idle
  is the plain template; paused adds a hollow ring (still template); needs
  attention (error, a provider issue, or serious thermal state) is a
  non-template image with a red dot. Each state has its own VoiceOver label
  ("Malibu", "Malibu — paused", "Malibu — needs attention"); colour is never
  the only signal. A snapshot test renders the glyph at 1x and 2x and asserts
  the ink height and feature width. "Serving" requires BOTH the managed CLI's
  local `/v1/health` readiness AND `network_state == "buyer_serving"` from
  `/v1/status`; a bare local-ready state is shown as "Reconnecting"
  (`MalibuAgent.swift:307-355`). Steady-state health poll
  every 15 s (`:381-407`); first-attach polls every 2 s up to 600 s (`:188-226`).
- Menu (reconciled v0.3): the shipped menu-bar left-click opens the Malibu
  window on Chat directly — there is **no popover** with USDC/MALIBU/uptime/GPU/latency in
  the shipped build (`MenuBarController.swift:56`); the menu exposes a plain **Quit**
  only, with **no "Quit and Uninstall"** item (`MenuBarController.swift:108`).
- Earn (the Earn section of the main window, §3.2.1): one **status pill** (Serving, Paused,
  Setting up, Not receiving work, Needs attention, Not running) describing
  customer serving only; a status notice with one action appears only when the
  Mac is not serving, and Reset/Export appear on the main surface only in an
  error state. Below it: an **Earnings card**, a **Your model** card and a
  **This Mac** health card (SPEC-025-R003). Diagnostics, the invite panel and
  logs live in their own sections (§3.2.1).
  Copy contract:
  - USDC: lifetime, this week and today, with "today" the UTC day for both
    requests and USDC; "Payouts are not enabled yet in beta." while a fresh
    earnings read reports `payouts_enabled` false (SPEC-005 §11.4). No amount
    is labelled unpaid, since the pending figure is not net of past payouts.
    The header shows the model and "last credited job <relative time>".
  - MALIBU: "paused network-wide" while `emission.active` is false; the balance
    split into held and not held; held MALIBU is "not released and not
    withdrawable" with no implied release (SPEC-021-R012); trust progress only
    from `trust_progress` (SPEC-021-R011), never "in progress" or "review"
    inferred from hold reasons.
  - Values that are not reported render as absent, never as an invented zero
    (no "0 queued", "0 declined" or "7d uptime n/a"); latency is labelled
    average; requests/minute is a request rate; restarts show the 7-day count
    and the lifetime count labelled as lifetime; resolved setup failures and
    superseded update records are not shown; machine reason codes are never
    rendered; repeated diagnostic lines are shown once.
  - Rates only: no $/time earnings projections (SPEC-044-R004).
  - Changing the payout wallet lives in Settings, with the cooling-off rule
    stated before the signer opens.
  Models (SPEC-025-R004) switches through the CLI's warm-swap path when the
  provider advertises it, and a model list read is bounded so "Checking…"
  always ends in a result or a retryable "unavailable". A refresh runs behind
  the last good catalog projection instead of returning to "Checking…", and a
  failed refresh keeps that projection, with Retry, until its freshness
  deadline (SPEC-044-R008); "unavailable" means a failed read with no usable
  projection. Malibu attaches to the owner-only socket for typed status and
  referral projections (§5.2).
- Referral UI is likewise capability-gated: Malibu renders the sanitized CLI
  control-socket projection only when the CLI advertises `referral_status_v1`
  and `referral_fragment_links_v1`.
  Typed challenge/verify/cancel/reopen actions additionally require
  `referral_advocacy_v1`; a status-capable CLI without that capability remains
  read-only. Malibu does not persist referral policy, read credentials, call
  coordinator referral endpoints, or award capacity. It
  validates invite links against the coordinator-authenticated `join_base_url`,
  presents status for at most 90 seconds, and clears it when the owner-only
  control connection closes. X challenge nonces, share URLs, and composer
  intents remain in CLI custody; Malibu receives only pending expiry/state.
- The Diagnostics section (SPEC-025-R008) renders the compatible local status-contract version, exact
  process instance (role/PID/short instance ID), last CLI-authored lifecycle state and
  reason, and typed credential recovery guidance. A repair button is shown only for
  `recovery_action=repair_from_protected_source`; it invokes the signature-validated
  installed CLI, accepts bounded version-1 JSON stdout, discards stderr, and waits for
  launchd health after success. Locked, permission-denied, conflict, unavailable, and
  unknown/future contracts never trigger automatic mutation.
- On login: `SMAppService.mainApp.register()` starts `Malibu.app` in the background.
  Login launch shows no Dock icon until a window is opened. (This registers the **app** as a login item; the **CLI daemon** is
  owned by the launchd **provider service** `live.malibu.provider` (`KeepAlive`)
  that `install.sh` set up — a separate mechanism from the app login item, §8.)

### 3.2.1 Main window: sidebar shell (#2054 Phase 2)

These requirements govern the main window. Copy rules from §3.2 apply to
every section: reported values only, no machine reason codes, no $/time
projections (SPEC-044-R004), colour never the only signal.

- **SPEC-025-R001 Shell.** Malibu MUST present one main window titled
  "Malibu": a sidebar with, in order, Chat, Terminal, Create, Agents, Tasks, Models, Earn,
  then a separate utility group with Settings and Diagnostics, and a detail
  pane showing the selected section. It opens on Chat. "Open Malibu"
  opens it on Chat; the menu-bar "Earnings" item opens Earn; "Settings…" (Cmd-,) and the menu-bar Settings item
  open the same window on Settings; there is no separate settings window.
  The minimum content size is 820 × 560 pt, and no section may grow the
  window past its frame. Chat follows the capability-gated local-use requirements in §3.2.2.
- **SPEC-025-R002 Sidebar header and footer.** The sidebar header MUST show
  the brand tile, "Malibu" and the §3.2 status pill. The footer MUST show the
  model the provider reports in its local status (last path component; the
  full id as help text), never a model only named in the config, and, when
  reported, the slot count and thermal state; it shows "No model loaded"
  rather than a guess. Text that comes from the provider (model ids, reasons,
  log lines) is shown as one plain line with control, format and separator
  characters removed and its length capped.
- **SPEC-025-R003 Earn.** Earn MUST keep the Phase 1 status
  pill, status notice and Earnings card (§3.2) and add: a **Your model** card
  with the served model, the switching line (R004), and, for a trusted current
  row, its provider share rate and demand rank with the SPEC-044-R004
  disclosure beside them, plus links to the Models On this Mac and Browse tabs; a **This Mac**
  card with the health line and a link to Diagnostics; a recommendation tip
  only for an actionable recommendation; and an invite nudge only while a
  current invite link can be copied. Reset and Export appear on Earn
  only in an error state, except the Export action that accompanies the
  hardware-evidence blocker in the Earnings card (§3.2).
  Below this content Earn MUST host a "Provider details" disclosure,
  collapsed by default, containing all R007 details. Pause/Resume MUST remain
  visible at the top of Earn, outside the disclosure.
- **SPEC-025-R004 Models.** One Models section MUST offer a segmented control
  in this order: Recommended, Browse, On this Mac, Downloads. Recommended
  shows the pinned recommendation and signed catalog rows fitting this Mac
  (the former Discover default); Browse shows the full catalog and bounded
  explicit provider search from R006. On this Mac hosts the existing Models
  table, sections, columns, switching line, footer and disclosure. Downloads
  shows active/recent R014 prepare_model transactions, progress and Cancel,
  or an empty state when none exist. This is a presentation merge only:
  projection logic does not change, and every R004/R005/R006 and SPEC-044
  rule applies wherever rows render. On this Mac MUST render the SPEC-044 projection in the
  SPEC-044-R008 sections as a table with Model, Size, Fit, Status, provider
  completion rate per 1M tokens and Action, one reason line per row saying
  why the model can or cannot be served here, the SPEC-044-R004 disclosure in
  the same scroll container, a header with the count and approximate size of
  models whose weights are on this Mac, and a filter. The switching line MUST
  be exactly one of: checking, "Switching available.", "Switching off: warm
  swap is not running on this Mac.", or "Switching unavailable right now."
  with Retry; available and off follow whether the provider runs with warm
  swap, not whether some row currently offers an action. A footer MUST state that switching pauses new customer work
  while the new model loads (HTTP 503) and never downloads. Each row MUST
  name the model by a readable title read from its identifier (family, size,
  and quantization tokens such as "Qwen3 8B · 4-bit") with the exact
  identifier as a selectable caption, never truncated in the middle; the
  title is display text, not a verified attribute. A row with a SPEC-044-R014
  `prepare_model` transaction MUST offer Download with the download size and
  the R014 confirmation, progress and Cancel; the `Needs preparation` section
  reads **Not downloaded**. Quantization, architecture, parameter count and
  capability columns or badges MUST NOT be shown until the signed catalog row
  and the SPEC-044 projection carry them.
- **SPEC-025-R005 Switch confirmation and progress.** Before a switch or
  revert, Malibu MUST state: the from and to models; that customers get a
  "provider loading" response (HTTP 503) while the new model loads and
  running requests drain (SPEC-011 R-3.2.3); that a switch cannot be
  cancelled once it starts; that it uses weights already on this Mac and
  downloads nothing; that a failed load leaves the current model serving; and,
  for a trusted row, its provider share rate and demand rank with the
  SPEC-044-R004 disclosure and any non-earning caveat. After confirmation it
  MUST show the CLI's switch phases (requested, loading, draining, loaded)
  with elapsed time and MUST report success only after the provider confirms
  the new model; a failure states that the Mac keeps serving the model it
  reports. Closing the sheet does not cancel the switch.
- **SPEC-025-R006 Models discovery.** Recommended and Browse MUST follow SPEC-044-R013, with the
  fit filter on by default in Recommended and off by default in Browse, every signed catalog model listed under its
  readable R004 title with its fit inline, the first visible row selected, and
  Download offered as in R004. The recommendation (Adopt, Not now, Stop) is
  pinned above the list and shown only when it names a row Discover lists, so
  its rates never appear for a model outside the signed catalog. A `models browse` search runs only on an explicit
  provider search, in its own subprocess bounded to 20 s, with the search term
  limited to letters, digits, space, dot, dash and underscore, never starting
  with a dash.
- **SPEC-025-R007 Provider.** Provider details inside Earn MUST show the status pill, the
  lifecycle line, customer slots, continuous batching state (on with free rows
  and waiting requests, off, or not active), native MTP state (on with mean
  accepted tokens per step, ready, paused after a fallback, off, or not
  available), the current queue/thermal/GPU/latency chips, requests, tokens,
  the current run and restarts, and the loopback endpoints with a note that
  they answer only on this Mac. Values come from the provider's local
  status, health and metrics reports and the Mac's thermal state; CB and MTP
  modes are accepted only from the CLI's closed enums (an unknown mode is not
  shown), they are cleared when the status observation is invalidated, and
  absent fields are omitted. Pause asks for confirmation and says running
  requests finish; Resume appears only while paused.
  The KV disk tier MUST distinguish enabled configuration from activation
  for the current model, report unsupported models with a plain reason,
  and show observed used bytes against the configured cap. Missing status
  MUST remain unknown, never inferred as disabled or zero usage.
  Recent restarts MUST be a bounded, newest-first list drawn from existing
  lifecycle records with time, reason and recorded software version.
  A missing recorded version MUST remain unknown rather than borrowing the
  current version. Historical records MUST NOT imply current health.
- **SPEC-025-R008 Diagnostics.** Diagnostics MUST always offer Export
  diagnostics and Reset provider service, and show Findings (humanised, once
  each), Events & identity (last restart, current setup failure, current
  update, last recovery, provider access, network verification and their
  repair state), Logs (the redacted recent provider log tail, at most 300
  lines of at most 500 characters each, with idle-warm-up lines collapsed into
  a count and a Problems filter) and Status (app and provider software
  versions, status contract, lifecycle, slots).
- **SPEC-025-R009 Settings.** Settings MUST host the payout wallet with the
  cooling-off rule (§3.2), the invite panel (§3.2), an "Open Malibu at login"
  toggle backed by `SMAppService.mainApp`, persisted menu-bar visibility and
  Dock presence controls that apply immediately without restarting the app,
  provider software update status with the
  install action when an update is available, the model settings (local
  runtimes, background recommendations) and About (app and provider software
  versions).
  Defaults retain the menu-bar icon and show Dock/Cmd-Tab while a window is
  open. Keeping Malibu in the Dock MAY be enabled. Hiding the menu-bar icon
  MUST keep Dock presence enabled, so closing the last window cannot hide
  both entry points. Update-channel selection MUST contain only `Stable`:
  SPEC-020 does not support user prerelease channels, and private acceptance
  release metadata is not a user channel. Saving this choice MUST NOT create
  an independent app feed or change the CLI's signed-set update authority.

### 3.2.2 Local Chat, Terminal and Other apps

- **SPEC-025-R010 Local Chat.** Chat MUST use the provider's loopback HTTP
  endpoint on the configured local port. It MUST NOT redirect or fall back
  to a gateway. Before sending, it MUST verify `local_chat_priority_v1`
  and the actual loaded model from fresh provider capability/status data.
  Missing capability, model, or provider readiness MUST produce an actionable
  unavailable state, never inferred support. Show the loaded model and
  explain that conversation content stays on this Mac and customers keep
  priority. Stream incremental text and provide Stop. Cancellation, provider
  disconnect, malformed/oversized streams, model changes and
  `local_preempted` MUST end the current turn without accepting stale output
  from an earlier task. History MUST be bounded, remain in memory, and never
  enter logs/diagnostics. Local activity may be shown only from `local_usage`
  and never folded into paid counters or earnings. Every Chat request MUST carry exactly one
  `X-MacProvider-Origin: local-app`, the marker that makes it local work under
  SPEC-001-R011. Do not send buyer keys,
  settlement metadata or privacy headers to the loopback endpoint. The
  loopback trust policy is SPEC-001-R009, not an authentication assertion.
- **SPEC-025-R011 Bounded Agent mode.** Agent mode MUST be explicit and
  available only when the current loaded runtime advertises guaranteed tool
  selection under SPEC-018. Tools MUST come from a fixed app-owned registry
  of read-only workspace operations. The user selects the workspace root;
  a model cannot select or widen it. No shell, file mutation, arbitrary
  network access or executable tool registration is permitted. Validate
  names and argument schemas before execution. Root and intermediate file
  access MUST use descriptor-relative no-follow checks at open time, so
  symlink replacement cannot escape the selected root. Bound bytes while
  reading, tool-output bytes, calls, rounds, elapsed time and conversation
  size; Stop cancels inference and tool processing. Unknown/malformed tools,
  unavailable capability and exceeded bounds MUST fail visibly without
  executing extra operations. Tool results are untrusted conversation data,
  never permission to alter the registry, root or limits.
- **SPEC-025-R012 Connected apps.** Terminal’s "Other apps" sub-view is the
  existing Connected apps screen, unchanged. All rules below remain normative
  for it. Connected apps MUST distinguish local
  Chat from buyer-funded requests to the Malibu gateway. Offer automated
  setup only for documented supported client configuration formats. Cursor
  uses a documented manual Settings handoff until a supported configuration
  API exists; do not mutate undocumented stores or claim that a handoff is
  a tested client connection. The interface MUST distinguish configured,
  endpoint-tested and actual client compatibility. Codex uses Responses;
  each other adapter uses its documented endpoint semantics. Never infer
  model capabilities or context limits not provided by trusted metadata.
  Protect the user's buyer key in a dedicated Keychain service or protected
  user-owned files outside repositories (directories 0700, files 0600).
  Never display secrets in previews, logs, diagnostics, subprocess arguments
  or errors. Supply a working documented credential mechanism, not an
  unresolved environment placeholder. A managed launched client receives only the SPEC-045 consumer's local
  token through a one-time file (0600, in a 0700 directory) that the launcher
  reads once and deletes. The upstream buyer key goes only from Keychain to
  the local consumer through a protected handoff, never to agent configuration,
  arguments or environment. Gateway-funded Terminal harnesses and supported
  managed Connected apps use SPEC-049-R036 by default, preserving original
  endpoint families and failing closed if directory trust or privacy admission
  is unavailable. Existing managed profiles must be safely migrated or refused;
  they cannot silently retain the ordinary production URL. The interface MUST disclose that repository configuration and
  agent commands run by the client can read that environment, and recommend a
  dedicated, spend-limited buyer key. OpenCode sessions MUST be launched with
  project configuration disabled (`OPENCODE_DISABLE_PROJECT_CONFIG=1` and
  `OPENCODE_CONFIG_PROJECT_DISABLE=1`); Crush, which has no such switch, MUST
  carry a visible warning. Setup requires an explicit app action
  after a preview. Before changing config, protect an exact-byte original
  backup (which may itself contain secrets), refuse symlinks/nonregular
  files, bound input, preserve unrelated fields, and compare the file with
  the preview before atomic replacement. Restore MUST compare with the
  installed bytes and refuse conflicting subsequent edits; absent originals
  may be removed only when this comparison succeeds. Never recreate unsafe
  file permissions on restore. Unsupported or ambiguous formats MUST remain
  unchanged. A connection test MUST exercise the selected API/model with
  bounded cost/time/response size and reject credential-bearing redirects;
  a models-list fetch alone is not a connection test. Connected apps MUST NOT show pre-setup privacy warnings, ordinary gateway
  status as privacy evidence, or an unverified privacy claim. After an actual
  authenticated privacy response, the interface MAY display only its verified
  served assurance and the exact SPEC-049 non-claims. Manual Cursor setup is
  not evidence of a privacy-class managed launch. The buyer-key disclosure above is one
  persistently visible sentence that names repository configuration and
  agent commands and recommends a dedicated, spend-limited key; the handoff
  mechanics, managed-profile scope and override caveats MAY sit behind a
  Details disclosure. Loading gateway models MUST require a saved buyer key,
  MUST run after a key is saved, MUST show its error beside the load action,
  and MUST say when the gateway serves no models. The picker MUST list only
  models whose published metadata declares `capabilities.tools: true` and at
  least 32,768 context tokens (v0.40.0). The endpoint test MUST be a bounded
  tool round trip: one request declaring a tool the model must call, then one
  sending that call and its result back, which must end in a non-empty answer. Do not claim relay-blind Responses or
  Messages. A gateway test is not evidence that an external client works.
  The coordinator's authoritative no-self-routing contract applies to buyer
  requests independently of any client configuration or exclusion hint.
  Cursor's manual handoff MUST name Settings → Models → API Keys, the OpenAI
  API key enable control, Override OpenAI Base URL set to
  `https://api.malibu.tech/v1`, and selection of the exact gateway model ID.
  Automatic tool use MUST NOT be inferred from the provider's guaranteed
  required/named tool-selection profiles. If actual client acceptance is
  unresolved or the model is unavailable on the gateway, disclose that
  limitation without labelling the client compatible.
  For the exact model IDs `qwen3-coder-30b-a3b-instruct`,
  `qwen3-30b-a3b-instruct-2507`,
  `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`, and
  `mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit`, generated OpenCode model
  entries MUST declare the `temperature: true` capability and model-scoped
  `options` with wire fields `temperature: 0.7`, `top_p: 0.8` and `top_k: 20`.
  Only the exact Coder alias and artifact identity MUST additionally declare
  `repetition_penalty: 1.05`; the Instruct-2507 identities MUST NOT inherit it.
  These snake-case model options use the pinned compatible adapter's extra
  request fields, not its unsupported standardized `topK` setting. Acceptance
  MUST verify the complete profile on actual outbound requests, including
  absence of Coder's repetition penalty on Instruct-2507.
  These client sampling settings MUST NOT replace agent prompts, change tool
  selection or permissions, or apply to other model identities by substring
  matching. They do not establish automatic-tool-use compatibility.
  For those exact identities under the `malibu` provider, setup MUST append
  a local managed OpenCode plugin without replacing existing plugin entries
  or configuring a global/named agent prompt. At request time, the plugin
  MAY replace only the exact pinned OpenCode 1.17.9 stock-default prompt
  prefix with the concise workspace-tool prompt. For the exact Coder alias
  and artifact identity only, it MAY append an illustrative native XML tool
  call and read-result example that distinguishes tool-added display metadata
  from file content; this MUST NOT inject real tool results or alter the user
  task, tool choice, or the Instruct model's prompt. It MUST preserve the
  remaining system instructions and sibling messages, and MUST leave other
  providers/models, custom agent prompts, tools and permissions unchanged.
  A custom prompt matching that prefix, failed agent lookup, malformed lookup
  response, or stock-prefix mismatch MUST leave the request unchanged. The
  plugin MUST use the same protected preview, receipt, launch-integrity and
  restore lifecycle as the managed configuration; setup MUST NOT overwrite
  an unowned plugin file. A legacy OpenCode setup with unchanged owned config
  and launcher receipts, no plugin declaration, and no plugin file or receipt
  MUST show an explicit Restore setup, then Preview setup and Set up recovery
  instruction before buyer-key handoff. This MUST NOT overwrite receipts or
  weaken conflict checks for missing or edited assets in a newer setup.
  The acceptance recorder MUST load the same plugin
  bytes with isolated client state, without OpenCode's plugin-disabling
  `--pure` flag. Launchers for these exact model identities MUST require
  OpenCode 1.17.9 and refuse another version after consuming and deleting the
  one-time key handoff; other models MUST NOT acquire this version guard.
  The interface MUST name the managed client/model scope, preserve custom
  agent prompts, and direct users to verify actual session tool activity.
  Installing the plugin is not automatic-tool-use acceptance, and isolated
  client acceptance MUST NOT imply production-gateway verification.

- **SPEC-025-R015 Terminal local-provider compatibility.** A Terminal launcher
  that offers Claude Code on this Mac's loaded model MUST require fresh provider
  status advertising `local_anthropic_messages_v1` and a currently available
  `messages` capability for `/v1/messages` (SPEC-001-R009). Missing capability,
  model or readiness MUST produce an unavailable state. It MUST configure
  `ANTHROPIC_BASE_URL` to the provider's loopback base URL and `ANTHROPIC_MODEL`
  to the observed model identity. Every generated request MUST carry exactly one
  `X-MacProvider-Origin: local-app`; a base URL or dummy
  `ANTHROPIC_AUTH_TOKEN` alone is insufficient to mark local work. Do not send
  buyer keys or settlement metadata to the local endpoint. Local sessions are
  unbilled, never earnings, and yield to customers under SPEC-001-R011.
  `local_preempted` MUST end the current turn cleanly; Stop or client exit MUST
  cancel its outstanding inference. Endpoint support is distinct from loaded
  model tool capability and actual client acceptance. Claim Claude Code
  compatibility only after a real multi-turn task with tools, streaming, Stop
  and customer preemption passes on the designated lab Mac. This requirement
  does not itself establish that the Terminal launcher is implemented.

- **SPEC-025-R016 Terminal.** Terminal MUST embed a terminal with tabs,
  capped at eight; output MUST never be persisted. The tab "+" menu lists
  Shell, Claude Code, Codex, OpenCode, Crush and other R012 adapters with a
  launcher. Harness entries are enabled only when the executable is found on
  the login-shell PATH, resolved once using `/bin/zsh -lc 'command -v <name>'`
  with a five-second bound. The resolved login-shell PATH MUST contain only
  absolute, nonempty entries (no `.` or relative entries), and MUST be carried
  into every harness launch environment, including managed launchers, so
  env-based interpreters resolve consistently. Missing entries say "Not installed". Shell runs
  `$SHELL -l` (fallback `/bin/zsh`) in the home directory; users may choose
  a working folder per tab.
  Harnesses MUST use the Malibu gateway and saved R012 Keychain buyer key,
  never the loopback provider. Terminal MUST make no privacy claim and MUST
  NOT show a privacy warning. The R012 buyer-key disclosure sentence remains
  persistently visible. Without a saved key, show
  "Add a buyer key in Other apps" and a button opening that sub-view; start
  no process. Codex, OpenCode and Crush use the existing managed launchers,
  including one-time key handoff. OpenCode disables project configuration;
  Crush retains its visible project-configuration warning because disabling
  is unavailable. Missing setup
  MUST explain the prerequisite and link to Other apps.
  Claude Code is an env-only adapter that writes nothing in `~/.claude`.
  Launch `claude --model <id>` with `ANTHROPIC_BASE_URL=https://api.malibu.tech`;
  deliver `ANTHROPIC_AUTH_TOKEN` through the existing R012 one-time 0600 file
  inside a 0700 directory. A small launcher reads once, deletes, exports,
  then execs Claude. Set `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`,
  `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` and
  `ANTHROPIC_SMALL_FAST_MODEL` to the selected gateway model ID;
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`; `CLAUDE_CONFIG_DIR` to a
  Malibu-owned 0700 directory under
  `~/Library/Application Support/Malibu/clients/claude-code/`.
  The picker reuses R012 tools capability and minimum 32,768 context tokens.
  The gateway serves `/v1/messages` (unauthenticated POST returns 401
  `authentication_error`); this does not establish client compatibility.
  Label setup "Configured" until the user runs it; preserve R012's configured,
  endpoint-tested and compatible distinction.
  Keys MUST never appear in argv, Malibu-written scrollback, logs, diagnostics
  or errors. Build child environments using `ProcessEnvironmentSanitizer`
  plus only the documented adapter variables above and `TERM=xterm-256color`.
  Closing a tab MUST SIGHUP every process group in the terminal shell's
  session, retaining PID and start-time-checked ownership until all members
  are gone, and SIGKILL survivors after three seconds. App quit MUST terminate
  all terminal children under the same rule. Output-triggered clipboard writes
  (including OSC 52) MUST be ignored; deliberate user Copy remains available. Earn, Models
  and Terminal follow §3.2 copy rules, with no $/time projections or machine
  reason codes.

### 3.2.3 Agents and Tasks

The §3.2 copy rules apply to Agents, Tasks, their editors, transcripts and
errors. These surfaces MUST NOT introduce privacy claims.

- **SPEC-025-R017 Named Agents.** Agents MUST offer a list, an editor and
  an in-memory conversation. Each named agent stores its name, instructions
  (system prompt), model target, optional user-chosen workspace folder, tools
  and sampling defaults. The only model targets are **This Mac** and
  **Malibu network**. This Mac MUST reuse the loaded provider model through
  loopback `/v1/chat/completions`, with exactly one
  `X-MacProvider-Origin: local-app` and all SPEC-001-R011 customer-priority
  semantics. It is available only while the loaded runtime advertises
  guaranteed tool selection as R011 requires; `local_preempted` ends the turn.
  This work MUST never count as earnings. Malibu network MUST use
  `https://api.malibu.tech/v1` and the saved buyer key from the R012 Keychain
  service. Its model picker MUST apply R012's published
  `capabilities.tools: true` and minimum 32,768-token context filter, without
  inferring missing metadata. Model-target transports MUST reuse the existing
  Chat transport and gateway client rather than fork their protocol logic.
  Tools are limited to the existing read-only workspace registry with all
  R011 descriptor-relative no-follow, byte, call, round and time bounds,
  plus user-configured R018 MCP servers. There are no app-provided shell,
  file-mutation or arbitrary-network tools. Tool results are untrusted data,
  never instructions or permission. Stop MUST cancel inference and tools;
  conversations remain bounded in memory like Chat and MUST NOT enter logs
  or diagnostics. Agent definitions MUST be stored in Application Support
  in a `0700` directory with `0600` files; the buyer key MUST NOT be stored
  in agent definitions.
- **SPEC-025-R018 MCP client.** User-configured MCP servers MUST use stdio
  only, with user-entered command and arguments. Their environment MUST be
  built with `ProcessEnvironmentSanitizer` plus user-entered environment
  variables; inherited credentials MUST NOT be forwarded implicitly. The
  in-house JSON-RPC 2.0 client supports `initialize`,
  `notifications/initialized`, `tools/list` and `tools/call`, without adding a
  package dependency. It MUST bound message size, request time and server
  lifetime, namespace tool names per server, validate argument schemas before
  executing calls, and terminate the server's process group when the agent
  session ends or the app quits. Each interactive MCP call MUST visibly show
  the server, tool and arguments and require **Allow once**, **Allow for this
  session**, or **Deny**. Session permission is scoped to that server/tool in
  the current session and MUST NOT survive session end. Denial executes no
  call. Tool results MUST never grant permission. Failure to start, timeout,
  oversized messages, malformed JSON-RPC or server exit MUST show a visible
  error and stop further execution for that session. Regression tests MUST
  exercise the protocol and lifecycle against a fake stdio server in a
  temporary directory, including process-group termination and approval gates.
- **SPEC-025-R019 Tasks.** A task stores an agent reference, prompt, schedule,
  enabled flag and explicit pre-approved MCP tool allow-list chosen at task
  creation. Supported schedules are once at a date and time, hourly, daily
  at a time, and weekdays at a time, interpreted in the device-local timezone.
  Schedule computation MUST accept an injected clock and timezone for tests,
  including DST transitions. Tasks run only while Malibu is running; they
  MUST NOT add a LaunchAgent. At launch, any missed schedule runs at most
  once and is durably advanced so repeated launches cannot replay it.
  **Run now** MUST be available. There is at most one active run per task
  and global task concurrency is one. Each run MUST cap inference/tool rounds,
  wall time and total requested output tokens. Unattended runs may call only
  their task's explicit pre-approved MCP tools; any other MCP call visibly
  fails the run without execution or an interactive approval prompt. Quitting
  MUST cancel active inference and tool processing and terminate owned MCP
  process groups cleanly. Each run records start, end, status (**succeeded**,
  **failed** with a reason, **preempted**, or **skipped**) and transcript.
  Run history and transcripts are local `0600` files in a `0700` directory,
  bounded to the last 20 runs per task; users can view history and transcripts.
  Transcripts MUST NOT enter logs or diagnostics exports. The task editor
  MUST state in one plain line that Malibu network runs are billed to the
  buyer key. This Mac runs are local work and MUST never count as earnings.
- **SPEC-025-R020 Agent and Task navigation.** The sidebar MUST list **Chat,
  Terminal, Create, Agents, Tasks, Models, Earn**, followed by the separate **Settings**
  and **Diagnostics** utility group. Persisted Agents and Tasks selections
  MUST restore their destinations; existing selection migration and the
  default Chat destination MUST remain functional. Create MUST restore its
  own persisted destination. Navigation tests MUST verify order, labels and
  persisted selection migration.

### 3.2.4 Create

- **SPEC-025-R021 Create.** Create MUST generate images through the provider's
  loopback `POST /v1/images/generations` only when local status advertises
  `local_image_generation_v1` (SPEC-001-R014). Every generation and cancel
  request MUST carry exactly one `X-MacProvider-Origin: local-app`. No image
  generation or gallery result may be sent to a remote inference endpoint.
  An older provider without the capability, an unavailable provider, or
  insufficient physical memory MUST render an unavailable state with a plain
  reason rather than an active Generate action.

  Create MUST offer a required bounded prompt, a size picker for `512x512`
  and `1024x1024`, steps 1–4 with default 4, an optional seed and Generate.
  `1024x1024` MUST be unavailable below 32 GiB physical RAM. The selected
  preset is SDXL-Turbo and `n=1`, `response_format=b64_json` are fixed. While
  work is active, the app MUST prevent duplicate submissions and offer Stop
  through provider cancellation. It MUST mirror the provider's `idle`,
  `downloading`, `holding_customers`, `generating`, `warm` and `restoring`
  states: show download size and measured progress, describe pausing earning
  while creating, generation and restoration without inventing progress or
  completion estimates. Provider errors MUST end in a clear retryable result
  or unavailable reason; the app MUST NOT imply customer serving resumed
  before the provider reports restoration.

  Create MUST show exactly this plain explanatory line: "Creating pauses
  earning on this Mac while it runs." The §3.2 copy contract applies: no
  earnings or time projections and no privacy claims. The gallery MUST save
  generated PNGs under `~/Pictures/Malibu/`, with `0700` for the created
  directory and `0600` for image files, and provide deliberate Show in Finder
  and Copy actions. Images MUST never be uploaded. Tests MUST cover sidebar
  order and labels, every provider image state, RAM-based size gating,
  unavailable states, gallery path and file permissions. Real-weights image
  quality and generation acceptance on the lab Air remain separate pending
  gates.

### 3.3 Updates — CLI-owned signed compatibility set

- The release artifact index binds one exact version of Malibu.app, macprovider-cli,
  launchd definitions, watchdog, catalog/resources, coordinator admission metadata,
  and rollback schema. Every compatibility-set member is hash-bound and release-role
  checked before mutation.
- The compatibility-set release version names the immutable signed set and remains
  equal to its `v<release-version>` tag. `components.malibu_app.version` and
  `components.provider_cli.version` name the actual members. The provider CLI
  component is a valid semantic version that need not equal the set release
  version for a private acceptance candidate. The Malibu component MUST equal
  the set release version (v0.31). Every compatibility-set build (release and
  acceptance candidate) stamps Malibu.app from the tag `vX.Y.Z` through one
  helper (`scripts/malibu-app-version.sh`): `CFBundleShortVersionString` =
  `X.Y.Z` and `CFBundleVersion` = `Z`, the positive-patch contract that the
  release trust-anchor preflight already enforces (a `vX.Y.0` tag stays
  unreleasable until a reviewed change replaces that contract). The checked-in project carries only a `0.0.0`/`0`
  development default, which a release-version guard keeps unchanged. The
  candidate build, the protected acceptance signer, and published-release
  verification each fail when the app's version or build differs from the
  helper's values for the tag. The protected signer also binds the signed
  manifest's `components.malibu_app.version` to the tag. Acceptance cases: a
  stale project stamp, a wrong build with the right version, and a
  rejected `vX.Y.0` tag.
  `malibu-release.yml` (the legacy independent publication surface for
  already-installed Sparkle clients) stamps the app from its own
  `v<version>` tag with the same helper. It embeds a named CLI release's set
  manifest, so its app version can differ from that manifest's Malibu
  component. That surface is not a compatibility-set activation, and the
  frozen v1.8.39 Sparkle bridge stays a separate one-time legacy artifact. Coordinator admission remains bound to
  the set release version. The set ID remains
  `<repository>:<release-tag>@<commit>`; component versions do not create parallel set
  identities.
- Candidate generation derives the Malibu and provider CLI component versions from
  the built sources, verifies them against the built artifacts in the unprivileged
  build job, and signs the resulting exact tuple. The protected signing job must not
  execute candidate code. Update and rollback marker fields that describe a binary
  version use `components.provider_cli.version`; Malibu bundle activation uses
  `components.malibu_app.version`. Acceptance upgrade freshness compares signed set
  release identities, not the provider CLI component version. Independently, the
  acceptance updater and installer require the signed provider CLI component to
  be greater than or equal to the installed CLI; equality supports a newer set
  that reuses reviewed CLI bytes, while a lower component is rejected outside
  the existing emergency rollback transaction.
- Every installed-payload reader resolves the launchd/PATH symlink to the
  canonical executable before selecting its adjacent manifest and resources.
  Candidate preflight, freshness, admission, update activation, and startup
  recovery therefore use one payload directory and cannot accidentally inspect
  `~/.local/bin` as though it contained the signed release set.
- Private acceptance Pearl metadata declares `channel: private_acceptance` and
  derives `provider_advertised_version` from the production-key-validated
  compatibility manifest's provider CLI component. Pearl rejects that channel
  by default; the bounded acceptance environment must explicitly set
  `PEARL_UPDATER_ALLOW_PRIVATE_ACCEPTANCE=1`. Missing or production channels
  continue to require the advertised provider version to equal the release tag,
  even when the private flag is enabled.
- Public production release workflows continue to require the provider CLI version
  to equal the release tag. Independent component versions are private-acceptance
  authority only until a separately reviewed production release contract says
  otherwise.
- The launchd CLI owns both scheduled and user-requested updates. Malibu's menu and
  dashboard invoke `malibu-cli update`; they do not download or replace artifacts.
- Running-app continuity (v0.31). The CLI replaces the installed Malibu.app with an
  atomic swap and MUST NOT signal, quit, or launch the Malibu process. Malibu
  MUST notice that its installed bundle's `CFBundleShortVersionString` or
  `CFBundleVersion` differs from the values it launched with, and relaunch onto
  the installed bundle. Before relaunching, Malibu MUST:
  - run from the updater-owned install path (`/Applications/Malibu.app` or
    `~/Applications/Malibu.app`) with bundle identifier `tech.malibu.app`, so
    development and test builds never relaunch;
  - prove that the installed bundle matches the Malibu member of the installed
    CLI's release-signed compatibility set: the app version equals the set's
    `components.malibu_app.version`, its build equals that version's patch,
    and the embedded set manifest is
    byte-identical to the installed one. Without that proof the change is
    mid-transaction or out-of-band, and Malibu MUST NOT relaunch;
  - see the new identity unchanged for 60 s with a validated lifecycle record
    (`record_state` `valid`), or for 15 minutes when the provider status is
    unavailable or its lifecycle record is missing or invalid, because the
    transaction may still be restarting or rolling back;
  - defer while any of these is in flight: an `update_in_progress` or
    `rollback_in_progress` lifecycle state, a maintenance lease, a
    Malibu-driven update or repair, onboarding, quit, uninstall, or a modal
    prompt;
  - verify the installed bundle's code signature against the Malibu
    designated requirement (the running bundle must satisfy it too, so a
    development build copied into the install path never relaunches).
  The relaunch opens the installed bundle as a new process and quits through
  the ordinary quit path only after the new process is running (bounded
  wait). The ordinary quit keeps the launchd provider service running. If the
  new process does not start, the old process keeps running and its watcher
  retries within the attempt bound.
  Attempts are persisted and bounded across all targets: at least 10 minutes
  apart and at most 3 in any 6 hours. A bundle that cannot start, or one that
  is swapped repeatedly, therefore never loops. A rollback that restores the
  launched version cancels the pending relaunch.
  First hop: a Malibu process older than v0.31 has no watcher. The first update
  onto a v0.31 app takes effect when that process next launches, either at the
  next login (login item) or when the user reopens Malibu. The release notes of
  the first release that ships v0.31 MUST tell operators to reopen Malibu once.
  The release-train entry for that cut (`docs/releases/cli-release-train.md`)
  carries the notice for the operator announcement.
  Removing the Sparkle dependency/runtime and feed settings eliminates the prior
  second update authority. Independent Malibu release publication still emits a signed
  public appcast and `latest.dmg` compatibility surface for already-installed Sparkle
  clients. The frozen 1.8.32 `SUPublicEDKey` trust anchor is confined to the
  one-time v1.8.39 bridge, where Sparkle 2.6.4 requires key continuity after
  extraction for the stranded 1.8.32 cohort; the source app and every signed build
  after v1.8.39 ship key-free (DECISION_CRITERIA Entry 156/158). Even on the
  bridge, without Sparkle code or a feed URL in the target bundle, the public key
  cannot initiate future updates.
- **SPEC-025-R013 Single-instance handoff.** Malibu MUST converge to one app
  process and one menu-bar item after a launch or update. Before starting its
  provider observers or creating its menu-bar item, an installed, signed Malibu
  instance MUST identify other running `tech.malibu.app` instances for the same
  user and elect a single winner. A newer running release wins over an older
  rollback launch; equal versions select the latest launch, with a deterministic
  PID tie-break. Version comparisons MUST use the identity of the running code,
  captured at launch, rather than the mutable installed bundle's current plist.
  A process MUST NOT terminate a peer with a newer running version. The elected
  successor MUST ask superseded peers to quit, check that their original process
  identities actually exit, and escalate to `terminate()` and then
  `forceTerminate()` after bounded grace periods. This MUST also clean up peers
  shipped before the handoff protocol. Escalation MUST target only verified
  Malibu peers, never the CLI or launchd provider, and MUST avoid a reused PID.
  Relaunch remains start-new-then-quit-old: observing a successor start is not
  proof that the old process exited. The surviving instance owns that exit
  verification and escalation. An older rollback launch MUST leave the newer
  app running and quit itself. Tests MUST cover a second launch, a relaunch
  whose predecessor's quit drain hangs, and a rollback launch.
- **SPEC-025-R014 Bounded app quit.** Every app termination request MUST bound
  the asynchronous shutdown drain by 35 seconds, including its 15-second
  graceful provider-detach allowance. The deadline MUST run independently of
  shutdown and uninstall completion; a hung or cancelled await, uninstall,
  repeated quit request, or modal state MUST NOT extend it. On expiry Malibu
  MUST log that the termination drain timed out and reply `true` to the pending
  application termination request. Completion before the deadline MUST cancel
  the deadline and reply only once. Ordinary and relaunch-driven quit MUST keep
  the launchd provider service running; app termination is not uninstall. Tests
  MUST cover a hung drain, timely completion, and repeated termination requests.
- The updater acquires the maintenance lease, persists a phase journal and exact
  typed rollback plan, stages and validates the target, drains buyer work,
  installs the whole set, restarts launchd, and commits only after exact signed
  target-set identity, target CLI component version, and local provider health
  are proven under SPEC-020. Coordinator admission and buyer-serving are
  reported separately and do not undo local commit. Local failure restores the
  prior exact set only when it remains above the effective minimum and is not
  revoked; otherwise recovery stops fail-closed for the separately authorized
  emergency path.
- `auto_update_enabled: false` suppresses scheduled mutation of every set member. It
  does not disable the explicit user action. Model caches remain outside the set unless
  a signed target explicitly declares a compatible model/catalog migration.

### 3.4 Uninstall

- **Quit and Uninstall…** is a reachable, confirmed menu action. Malibu first invokes
  the installed CLI's typed `uninstall --yes` transaction, waits for exact launchd job
  absence, unregisters its login item, removes App-owned configuration/support data,
  and reports any residue before terminating. Drag-to-trash alone is not the supported
  provider uninstall because the launchd service intentionally outlives the UI process.
- Routine uninstall preserves the CLI-Keychain provider bearer and admission identity
  so reinstall can recover the same provider and billing history. App-owned legacy
  Keychain items are removed, receipt/admission custody is not silently reset, and model
  caches remain unless a separate explicit data-reset operation is introduced.
  Routine CLI uninstall validates the managed label set, stops the watchdog before the
  provider, then proves both jobs remain absent after the complete stop phase
  (`launchctl print` service-not-found status 113; every other nonzero status is
  indeterminate and fails closed). It preserves the provider's CLI-Keychain bearer so a
  retained principal can reinstall safely; this action is not a full cryptographic
  identity reset.

The CLI track's `uninstall.sh` is unaffected and remains the developer-facing path.

## 4. Distribution — `.dmg` (not `.pkg`)

Recommendation: **`.dmg`**.

| Concern | `.dmg` (chosen) | `.pkg` |
|---|---|---|
| Non-dev familiarity | High (Slack, Signal, Tailscale) | Medium |
| Requires elevation | No | Yes (or user-scope pkgs, clunky) |
| Post-install steps | App runs the bundled `install.sh` on first Launch (installs the launchd CLI); `SMAppService` only registers the app's own login item after attach (reconciled v0.4, §8) | Installer scripts (extra attack surface) |
| Update path | Sparkle replaces `.app` in place | Works but clunkier |
| CI complexity | `hdiutil` DMG build (reconciled v0.5, `release.yml:599`; the earlier `create-dmg` framing is superseded) | `pkgbuild` + `productsign` (reconciled v0.6 — the shipped optional App `.pkg` uses this, NOT `productbuild`/component plist; `release.yml:635`) |
| MDM/enterprise | Weaker | Stronger |

Ship `.dmg` for v1. **Reconciled v0.4:** the pipeline already emits an **optional signed App `.pkg`** alongside the `.dmg` (`release.yml:599,616`); the earlier "later, enterprise/MDM only" framing is superseded — content is the same `.app`.

## 5. Wrapper ↔ CLI: architecture (reconciled v0.2 — monitor-only)

**Shipped model:** `Malibu.app` is a **thin monitor wrapper**. `install.sh` (bundled
in `Contents/Resources/`) sets up a **launchd provider-service-managed** `macprovider-cli`
(`live.malibu.provider`, `KeepAlive`) plus a companion health watchdog (§8);
the app then adopts and **observes** it over local HTTP plus a capability-gated,
owner-only control socket. The app never spawns the CLI; the socket carries typed,
sanitized CLI-authenticated projections and never transfers provider credentials.

```
┌───────────────────────────── Malibu.app ─────────────────────────────┐
│  MenuBarController (NSStatusItem)  ◄──►  DashboardWindow (SwiftUI)    │
│                    │                          │                       │
│                    └──────────┬───────────────┘                       │
│                               ▼                                       │
│   LaunchProviderController (onboarding)   MalibuAgent (steady state)  │
│    · runs Contents/Resources/install.sh    · HTTP health/status poll  │
│                                             · typed control projection │
│    · invokes CLI-owned registration         · never spawns a child     │
│    · registers SMAppService (APP login item)                         │
│                               │ GET /v1/health + /v1/status           │
│                               ▼ (127.0.0.1:<port from config.yaml>)   │
│   ┌── launchd provider service live.malibu.provider (KeepAlive) ─┐ │
│   │   macprovider-cli   ← owned/restarted by launchd KeepAlive, NOT the │ │
│   │   app (+ health watchdog: local liveness monitor only — §8)         │ │
│   └──────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
  MalibuAgent.start() gate (in order, MalibuAgent.swift:64-87):
    provider_id present  AND  launchd install evidence exists  AND  Keychain token
  → monitorInstalledProviderIfPresent()   (never instantiates CLIChildProcess)
```

`MalibuAgent.start()` **refuses to poll** unless `provider_id` is set, launchd
install evidence exists (`install_manifest.json` or
`live.malibu.provider.plist`, `LaunchProviderController.swift:374-380`), and a
Keychain token is bound. **Reconciled v0.3 — the message is per-gate**
(`MalibuAgent.swift:64-87`): a missing `provider_id` or a failed `isConfigured` shows
"Not set up yet. Click Launch Provider to activate."; only missing launchd evidence
shows "…to run the installer." A legacy app-marker config with no launchd
evidence routes to onboarding, not a reconnect loop (`route()`
`LaunchProviderController.swift:352-372`; `StartupRouteTests.swift:9`).

### 5.1 Bundle layout

```
Malibu.app/Contents/
  Info.plist                       # LSUIElement=true (runtime switches to .regular while a window is open, §3.1); no update feed or URL scheme
  MacOS/
    Malibu                         # Swift binary (wrapper)
    macprovider-cli                # REQUIRED — signed CLI copied in by release.yml:556; verify-tier2-provider-release.sh:405 rejects a bundle without it
    mlx.metallib                   # REQUIRED — MLX Metal shader library (release.yml)
  Resources/
    install.sh                     # bundled CLI-track installer (mode 755, project.yml:72-75)
    Assets.car
  _CodeSignature/
```

Note (reconciled v0.3): the **running** provider is the `macprovider-cli` that
`install.sh` installs into `~/macprovider/` (the launchd-managed location). Separately,
the release pipeline **REQUIRES** a `macprovider-cli` binary bundled in
`Contents/MacOS/`: `release.yml:544` copies it in and
`verify-tier2-provider-release.sh:405` **rejects an App bundle without it** (reconciled
v0.3 — required, not optional). The bundled copy is the signed transaction invoker and
installation source; the live daemon remains the launchd install. `Info.plist` carries **no**
`malibu://` URL scheme (removed by PR #418; tombstone at `MalibuApp.swift:35-38`).

### 5.2 IPC: HTTP lifecycle monitoring plus a bounded control projection

Steady-state lifecycle monitoring uses
`GET http://127.0.0.1:<port>/v1/health` + `GET /v1/status` against the
launchd-managed CLI (`InstalledProviderMonitor.swift`; port from `config.yaml`).
Health readiness = `status ∈ {ready, busy}`; "serving" additionally requires
`/v1/status.network_state == "buyer_serving"`.

**Model-thread liveness token (capability `model_liveness_token_v1`).** A bare
`/v1/health` 200 does not prove the model thread is alive: the HTTP listener can
answer while the inference/model thread is dead (the listener-alive / model-dead
wedge). To make this **observable**, when the CLI advertises
`model_liveness_token_v1` in `local_status_contract.capabilities`, `/v1/status`
MUST surface a `model_liveness` object with exactly this shape (this extends the
SPEC-001 local-status contract capability set, which SPEC-001 enumerates):

```
"model_liveness": {
  "token": <uint64>,                  // monotonically non-decreasing; advances ONLY on model/inference
                                      // forward progress (per generated token / generation step). Scoped
                                      // to service_instance.instance_id: resets to 0 on process/service-
                                      // instance restart; MUST NOT be compared across differing instance_id.
  "token_age_ms": <uint64|null>,      // elapsed since the token last advanced, measured on a process-local
                                      // MONOTONIC clock (immune to wall-clock jumps); null before first advance.
  "active_inference": <bool>,         // true iff accepted/in-flight model work SHOULD be advancing the token
                                      // now (e.g. requests_in_flight > 0).
  "active_inference_age_ms": <uint64|null>,  // monotonic elapsed since active_inference last became true with no
                                      // subsequent token advance; null when active_inference is false.
  "last_advanced_at": <RFC3339|null>  // diagnostic wall-clock time of last advance; null before first advance.
                                      // Diagnostic ONLY — MUST NOT be used for staleness math.
}
```

The token MUST be readable without blocking on or synchronizing with the model
thread — a reader observes the last-published values, never a live call into the
model — so a wedged model thread cannot wedge the status endpoint.
**Interpretation:** a rising `token_age_ms` is a liveness concern **only while
`active_inference` is true** (tracked continuously from when active inference
begins via `active_inference_age_ms`, so a wedge that occurs before the first
token still shows a rising age); a healthy *idle* provider legitimately has a
non-advancing token and MUST NOT be read as wedged. All staleness math MUST use
the monotonic `*_age_ms` fields, never `last_advanced_at`. The token carries no
buyer-serving authority and does not gate admission. Readers older than
`model_liveness_token_v1` degrade without false failure (legacy-reader fallback),
treating an absent `model_liveness` object as "unknown", never as unhealthy.

**Scope of this version.** The token is a **local `/v1/status` observability
signal only**. It is NOT yet an input to the watchdog restart predicate (§5.3),
which is unchanged. Wiring the token into an out-of-process wedge-prober restart
decision (the listener-alive/model-dead recovery path) is an explicit deferred
follow-up that must first define the stall threshold and its owner and the
pre-first-token / process-wide hard-freeze cases before it may authorize a
restart. The persisted operator-pause signal readable without the HTTP surface
is now defined by SPEC-020 R-4.14 (v0.1.28): the lifecycle record's durable
pause fence. Coordinator export of the signal (heartbeat action events, dwell,
token-age, topology beacon) is the separate supervisor telemetry contract
deferred to RFC-001 §7 / follow-up F5, and MUST NOT be smuggled into
`last_autoupdate_event`.

Malibu also attaches to the launchd-owned CLI's owner-only control socket when
the CLI advertises compatible typed capabilities. That socket supplies bounded
status, metrics, earnings, and referral projections and accepts supported
operator/UI requests. It does not make Malibu a lifecycle owner: Malibu never
receives the provider bearer, never talks directly to the coordinator, and
never launches or supervises a second provider process. Unknown or malformed
frames terminate the local connection and are recovered by capability
negotiation and reattachment.

### 5.3 CLI lifecycle: launchd owns it, the app monitors

**Reconciled v0.2/v0.7 — the wrapper does NOT spawn, restart, or SIGTERM a CLI child.**
The launchd **provider service** `live.malibu.provider` (`KeepAlive`) that
`install.sh` installs owns the CLI's lifecycle and routine restarts. The companion
watchdog remains a current-boot-gated local liveness monitor and does not own
auto-update rollback or recovery mutation (§8).

**Exit-restart is launchd's alone; the watchdog is wedge-restart-only (SPEC-020
R-4.14).** launchd is the **single** exit-restart owner. For `consumer_user`,
`KeepAlive{SuccessfulExit:false}` + `ThrottleInterval` restarts **crash/nonzero**
exits; for `headless_fleet`, `KeepAlive{true}` restarts every exit. Because
`KeepAlive{SuccessfulExit:false}` does not restart a clean (exit 0) termination, a
`consumer_user` serve process MUST reach exit 0 only under a validated **local**
stop intent (uninstall, launchd/operator-disable, or a local `stop`/maintenance
transaction); an unsolicited SIGTERM/SIGINT with no such stop intent (a stray or
memory-pressure/jetsam SIGTERM) MUST exit **nonzero** so launchd restarts it
(SPEC-001 FR-12). A coordinator `drain` message is registration-only and never
causes process exit, so it is not a stop intent. This leaves no accidental
clean-exit gap when the watchdog's exit-restart is removed. The companion watchdog MUST NOT restart the provider on
process exit or on a missing/unvalidated launchd PID.

The watchdog's only permitted mutating action is its existing bounded,
current-boot-gated **wedge** restart (unchanged by this version): a
`launchctl kickstart` when, after observing local health in the current boot, a
later local `/v1/health` failure is paired with a restart-worthy `/v1/status`
state, outside cooldown, with no valid lifecycle lease and not operator-paused. It
writes only its own boot-arm and cooldown markers. Consuming the new §5.2
`model_liveness_token_v1` to also catch the listener-alive/model-dead wedge is a
deferred follow-up, not part of this version.

The watchdog is **installer-owned and non-self-restoring** (RFC-001 §5.1): beyond
its boot-arm/cooldown markers and its own private supervisor-telemetry state files
(§5.4 — non-executable, non-config diagnostic markers, never a provider or
supervisor artifact and never update/rollback authority) it MUST NOT write,
restore, rename, or delete any provider **or supervisor** artifact — provider
binary/resources/config/plist, or the watchdog script, its
plist/LaunchAgent/LaunchDaemon, or any current or legacy supervisor label
(including `live.streamvc.macprovider-watchdog`) — and MUST NOT own or perform
update or rollback. Only the installer/Malibu-repair/CLI
transaction owner writes the supervisor. This removes the second, mutable
exit-restart authority whose stale, self-restoring form caused the #1189
stranding, so a stale watchdog can no longer resurrect or fight the provider.
`MalibuAgent` holds a `var child: CLIChildProcess?` but **never instantiates it** in
shipped code — `CLIChildProcess(` has no call site in `Sources` or `Tests`; the field
is only read to defensively release a child left by an *older* build
(`releaseSpawnedChildForLaunchdMonitor`, `MalibuAgent.swift:231-245`). The
`--managed-by malibu-app` / `--enable-warm-swap` argv is not exercised.

What the app actually does around lifecycle:
- **Attach/monitor:** poll `/v1/health` + the capability-gated `/v1/status`; attach to
  the owner-only control socket for CLI-authenticated earnings/status projection;
  first-attach every 2 s up to 600 s, steady every 15 s. **Reconciled v0.13:**
  a locally-ready but non-`buyer_serving` provider (or an undiagnosed connection loss)
  is surfaced as "Reconnecting" (`MalibuAgent.swift:307`); **diagnosed**
  startup/health failures and the first-attach timeout transition to **`.error`**, not
  "Reconnecting" (`MalibuAgent.swift:89,391`). Routine recovery of the daemon is the
  launchd provider service's `KeepAlive` job plus the watchdog's current-boot-gated
  liveness checks (§8), not an in-app restart loop.
- **Quit:** `agent.shutdown(gracefulSeconds:)` stops only Malibu monitoring; it never
  drains or signals the launchd provider. Update/uninstall drain is owned by the CLI
  transaction.
- **Uninstall:** delegate to `malibu-cli uninstall --yes` (§3.4).

### 5.4 Supervisor telemetry (RFC-001 §7 / F5)

Provider liveness recovery must be observable from the coordinator, not only by
SSH — the #1189 blind spot. This defines a **supervisor telemetry contract** that
is **separate** from the SPEC-020 autoupdate-event model: supervisor/liveness
signals MUST NOT be smuggled into `last_autoupdate_event` (SPEC-020's event model
is autoupdate-specific and its coordinator aggregation was explicitly deferred,
`specs/SPEC-020-provider-autoupdate.md`). Supervisor telemetry is its own event
type, its own heartbeat field, and its own coordinator store.

**Observability-only invariant (MUST).** Supervisor telemetry — the
`last_supervisor_event` wire field and the coordinator `provider_supervisor_events`
store — is **diagnostic only**. It MUST NOT gate or change admission, trust tier,
buyer routing/serving, rewards, sanctions, autoupdate eligibility, rollback, or any
local mutation authority. It records what the supervisor did; it never decides
anything (mirrors the §5.2 model-liveness no-authority rule).

**Event schema — a single latest-state beacon, not a delivery queue.** Supervisor
telemetry is a **best-effort latest-state beacon**, not a guaranteed event stream.
This is deliberate: the provider heartbeat is fire-and-forget with no
coordinator→CLI acknowledgement, so a per-event at-least-once channel cannot be
built on it honestly. Recovery observability — "is this node's watchdog
restarting it, and how often" — is instead carried by **monotonic counters** in
the beacon, so it survives dropped heartbeats without any replay/ack machinery: a
counter that advances by more than one between two observed beacons tells the
coordinator events occurred even when individual beacons were missed.

The value of the heartbeat field `last_supervisor_event` is exactly this object
(no wrapper), a single JSON object size-bounded ≤ 4096 wire bytes (matching the
autoupdate-event cap; because it is always exactly one object, the CLI's
whole-file size check below is well-defined). `kind` names the **latest**
supervisory event the beacon reflects; the counters, topology fields, and the
**sticky last-action detail subobjects** (below) are present on every beacon
regardless of `kind`. Unknown keys are dropped by readers.

Common (every beacon): `schema` = `"macprovider.supervisor-event.v1"`; `ts`
(RFC3339, the wall-clock of this beacon write); `kind` ∈
{`"restart"`,`"deferral"`,`"beacon"`}; `boot_id` (string, current
`kern.bootsessionuuid`); `seq` (uint64, monotonic within a boot, bumped on every
beacon write, for ordering/latest-wins); `supervisor_version` (string, ≤64); and
the recovery-observability counters `restarts_total` and `deferrals_total` (uint64,
monotonic-nondecreasing within a `boot_id`, reset only on reboot) — the count of
wedge restarts and autoupdate deferrals the watchdog has performed this boot.

`supervisor_label` (string, ≤64) is topology and always present, but is **not** a
free-form launchd label: to satisfy redaction it MUST be one of an explicit public
allowlist — `"provider-watchdog"` (current, from `live.malibu.provider-watchdog`)
or `"legacy-watchdog"` (from the legacy `live.streamvc.macprovider-watchdog`) — and
any unrecognized label is emitted as `"unknown"`. The raw launchd label is never
stored or forwarded. A stale legacy watchdog is therefore visible fleet-wide as
`"legacy-watchdog"` without leaking operator/host naming.

**`kind`** names the latest event *type* for this write, but the authoritative
per-action detail lives in two **sticky** subobjects that are carried on **every**
beacon (including a topology-only `kind:"beacon"`) once the action has occurred
this boot, and are cleared only on reboot (new `boot_id`). This is the fix for the
overwrite hazard: a topology tick can never erase restart evidence before the
coordinator observes it.

- `last_restart` (object|null; null until the first wedge restart this boot) — the
  most recent wedge restart: `seq` (the `seq` at which it was recorded), `ts`
  (RFC3339 of the restart), `reason` = `"wedge"` (the only watchdog-owned restart
  reason post-F1; SPEC-020 R-4.14 — exit-restart is launchd's, never reported
  here), `cooldown_state` (enum: `"armed"` | `"cooldown_active"`),
  `service_instance` (string|null; the **old** provider instance the kick
  targeted), and `model_liveness` (object|null; see below).
- `last_deferral` (object|null; null until the first deferral this boot) — the most
  recent deferral (watchdog observed a pending autoupdate marker and deferred to the
  transaction owner, R-4.14, **no restart performed**): `seq`, `ts`, and
  `deferral_reason` = `"pending_autoupdate_marker"`.

`kind:"restart"` means `last_restart` was just (re)written this tick;
`kind:"deferral"` means `last_deferral` was; `kind:"beacon"` means neither changed
(topology + counters + whatever sticky detail already exists). `restart`-only
`reason`/`cooldown_state`/`model_liveness` live **inside** `last_restart`, never at
top level; `deferral_reason` lives **inside** `last_deferral`.

`model_liveness` (inside `last_restart`, from §5.2, so a stalled token is
interpretable and idle providers are never mis-read as wedged):
`{ "token_age_ms": <uint64|null>, "active_inference": <bool>,
"active_inference_age_ms": <uint64|null> }`. A rising `token_age_ms` is
wedge evidence **only while `active_inference` is true** (§5.2); the coordinator
MUST NOT read token age alone as a wedge.

**Redaction (non-negotiable, RFC-001 §Non-Negotiables).** No field may carry
provider names, hostnames, full provider ids, wallet details, local home paths, or
raw diagnostics. Every string is bounded and redacted with the same rules the
autoupdate event uses; `service_instance` is an opaque CLI instance identifier and
`supervisor_label` is the allowlisted class above — never a path or PII.

**Watchdog → CLI bridge — storage & ownership.** The companion watchdog is the
**sole writer** of the published beacon and its private supervisor-telemetry
state files (the sticky/counter sidecars from which the beacon is regenerated),
kept in a supervisor-telemetry directory under the watchdog's provider state root
with the ancestry hardening SPEC-020 R-4.9 applies to autoupdate state. Ownership
depends on the install topology, and both are enforced by the reader:
- **Consumer (GUI):** the watchdog and provider share the uid, so the directory
  is provider-UID-owned `0700` (symlink-free, no non-owner-write ACLs) and the
  beacon file is `0600`.
- **Headless (system LaunchDaemon):** the watchdog runs as root (it needs
  `/bin/launchctl` in the system domain) while the provider runs as the fleet
  user, so the directory is root-owned `0755` (world-traversable but
  not-others-writable) and the beacon is root-owned `0644` (world-readable so the
  provider can read it; **never chowned to the provider** — root stays the sole
  writer). The beacon carries only redacted/allowlisted, non-sensitive fields.
The invariant the reader enforces (below) is that the containing directory and
the file are owned by the reader's uid or root and are not group/other-writable;
a failed ancestry check is fail-closed (the telemetry is skipped, never the
heartbeat). Writes are exclusive-create-temp + `rename` + `sync`:
- `$STATE_DIR/supervisor-beacon.json` — the single latest beacon object
  (**overwrite-OK**). On every tick, and immediately after any wedge restart or
  deferral, the watchdog bumps `seq`, updates the counters and `kind`/detail
  fields for the latest event, and rewrites this one file. There is no append-log,
  no per-event retention, and no acknowledgement protocol: losing an intermediate
  beacon only means the coordinator sees the counters advance by more than one on
  the next beacon it does observe, which is still a faithful recovery signal.

**Delivery — CLI is strictly read-only.** The CLI **writes nothing** for
supervisor telemetry; it owns no cursor or ack file (the earlier ack-cursor design
is removed — it could not be honest without a coordinator ack, and it forced the
watchdog into an unbounded append-log). When the CLI builds a heartbeat it reads
`supervisor-beacon.json` with hardened I/O: it first `stat`s the containing
directory and requires it be a directory owned by the reader's uid or root with
no group/other write; then opens the file `O_NOFOLLOW` and `fstat`s it, requiring
a single-link regular file, size ≤ the wire cap, and **either** owner = the
reader's uid with mode `0600` (consumer) **or** owner = root with no group/other
write bit (headless root-owned `0644`) — so the file is never writable by a
non-owner in either topology. It then parses fail-closed. The CLI does **not** forward raw JSON: it **projects the parsed
object to the allowlisted `macprovider.supervisor-event.v1` schema before uplink**
— unknown keys are dropped **locally**, string lengths are capped, and
`supervisor_label` is mapped to the allowlisted class — and carries only that
validated projection as `last_supervisor_event`. (Relying on the coordinator to
drop unknown keys is too late for the redaction invariant.) A missing, malformed,
oversized, wrong-owner, symlinked, or wrong-boot (`boot_id` ≠ the current
`kern.bootsessionuuid`) file is ignored: absence never blocks a heartbeat and never
fabricates a restart signal.

**Sustained-serving dwell is coordinator-derived; correlation needs a
coordinator-visible instance id.** The watchdog cannot know at restart time
whether the restart held, so dwell is not a watchdog field. To correlate soundly,
the provider heartbeat/`state_update` carries a bounded `service_instance_id`
(the opaque `/v1/status` `service_instance.instance_id`; SPEC-001 §6.15.2). The
`last_restart.service_instance` names the **old** targeted instance; the
coordinator measures dwell only after it observes heartbeats from a **new**
instance whose `service_instance_id` differs from the one the restart targeted —
proving a new process, not a reconnect. **Dwell is coordinator wall-clock, not a
provider field:** it is the duration the coordinator itself observes the new
`service_instance_id` as continuously **serving-eligible in its own pool view** —
using the coordinator's existing per-provider serving/liveness status, not any new
`serving` heartbeat field (the heartbeat carries `status`, not a `serving` flag;
`network_state` lives only on local `/v1/status`, so F5 adds no serving field and
reuses the coordinator's own serving determination). Dwell accrues only while the
coordinator keeps receiving fresh heartbeats (within its own staleness threshold)
from that `service_instance_id` **and** its pool view of the provider stays
serving-eligible; it **resets to zero / is marked unknown** on any heartbeat-miss
past the staleness threshold, disconnect, session replacement, absent
`service_instance_id`, or any non-serving state — a later heartbeat after silence
never back-fills dwell across the gap. It does **not** read the provider's
`uptime_s` (whose producer/semantics F5 does not extend).

**Correlation requires both instances be known.** The acceptance signal (below)
requires **both** the old targeted `last_restart.service_instance` **and** the new
heartbeat `service_instance_id` to be non-null and to differ; a new id merely
differing from `null` does not prove a new process replaced the targeted one. If
`last_restart.service_instance` is null, the coordinator still stores and counts the
restart, but classifies dwell correlation as **unknown / non-accepting** — it does
not assert recovery-held. A restart followed by a correlated new instance whose
serving dwell stays below a coordinator-owned threshold before another restart is a
**flap**; a correlated dwell above threshold with no artifact-write event (below) is
the recovery-held signal.

**Coordinator ingest & store.** The coordinator ingests `last_supervisor_event` on
heartbeat and state-update **best-effort and non-blocking**: a rejected value is
**discarded while the heartbeat/state_update is still accepted** (it MUST NOT reject
the frame the way the autoupdate parser rejects a bad `last_autoupdate_event`), and
the coordinator MUST NOT synthesize a restart event from absent or invalid
telemetry. Whole-beacon discard at the coordinator is limited to: a
malformed/missing required field, an oversized payload, a wrong `schema`, or a
`seq`/counter sanity violation (below). **Wrong-boot rejection is CLI-side, not
coordinator-side:** the coordinator receives `boot_id` only *inside* the beacon and
has no independent current-boot signal (the heartbeat carries `service_instance_id`,
not a boot id), so it cannot and does not re-verify "is this the current boot" — it
treats `boot_id` as a **declared partition key** for the `(provider_id, boot_id)`
row. Staleness across boots is already fully defended at the CLI, which drops any
beacon file whose `boot_id` ≠ the live `kern.bootsessionuuid` before uplink (above);
after reboot the watchdog writes a fresh `boot_id` with `seq` reset, so a new row is
created and prior-boot rows are retained as history. Timestamp skew is likewise
**never** a whole-beacon discard — provider `ts` is diagnostic-only and is
normalized at the field level (below), so a stepped clock can never suppress a valid
higher-`seq` counter advance.

*Ordering — `seq` is the sole same-boot authority; `ts` never gates.* Because the
beacon is latest-state (not a replay queue), ordering is **latest-wins by `seq`,
not dedup and not time**: per `(provider_id, boot_id)` the coordinator keeps the
beacon with the highest `seq`. Provider `ts` (and `last_restart.ts`/
`last_deferral.ts`) are **diagnostic display fields only** — they never gate
acceptance, never order beacons, and never bound the acceptance window (which is
anchored on the coordinator-derived `last_restart_observed_at`, below). This is
deliberate: a Mac wall clock can step backward across sleep/NTP/manual correction,
so a `ts`-based anti-backdating rule would wrongly drop real higher-`seq` beacons
and suppress exactly the counter advance the contract relies on. A `ts` (or nested
action `ts`) more than `5m` in the future is not used to reject the beacon; the
offending timestamp field is nulled/flagged, the rest of the beacon is still
ingested by `seq`. A beacon is discarded (frame still accepted) only if a required
field is malformed. Every accepted beacon MUST be internally consistent:
`restarts_total + deferrals_total ≤ seq` and each nested action `seq ≤` the top
`seq` (the watchdog bumps `seq` once per tick and once per event), else it is
dropped non-blockingly. A `seq` **≤** the stored `seq` is a **full no-op** — it
neither replaces detail nor advances counters — **except** the state-reset
carve-out below. For a `seq` **>** the stored `seq`, the counters MUST be **≥** the
stored counters (monotonic within a boot); a higher-`seq` beacon that regresses a
counter, or whose `seq`/counters jump beyond a coordinator-owned per-boot sanity
ceiling, is treated as malformed and is **quarantined/discarded non-blockingly**
rather than adopted, so a single corrupt/forged write cannot pin state. The step
ceiling applies to **subsequent** beacons only, **not** to a first insert or a
reset: a legitimate first contact (a long-uptime Mac, or a row pruned while still
up) can carry a large `seq`, bounded only by an absolute cap and the
internal-consistency ratio. The ceiling and cap are **implementation-owned
constants**; the normative contract is only that they exist, apply non-blockingly,
and never adopt an over-limit beacon as high-water.

*State-reset carve-out (the one permitted `seq` regression).* If the watchdog's
state directory is wiped mid-boot (the `uninstall.sh`→`install.sh` repair flow, or
an operator `rm`), it re-emits a low `seq` with counters restarted at 0 under the
**same** `boot_id`. Without a carve-out the latest-wins no-op would discard every
beacon for the rest of the boot — a blind spot exactly during repair. So a
regressing beacon that is a **plausible fresh state** — `seq` at or below a small
implementation-owned bound AND internally consistent (`restarts_total +
deferrals_total ≤ seq`) AND both counters at or below the stored high-water — is
**adopted** as a new baseline (resetting `seq`/counters/sticky/dwell) while
`flaps_total` and `first_seen_at` are preserved. This is safe against a stale
replay: if it was not a genuine reset, the real watchdog's next higher-`seq`
beacon re-advances the row.

*Store.* Valid beacons upsert into a **separate** `provider_supervisor_events`
table (never merged into `provider_autoupdate_events`), **one row per
`(provider_id, boot_id)`**, with an **allowlisted, bounded** column set (schema
fields only; unknown keys dropped; string lengths capped), operator/analytics-only
grants (no buyer/provider-portal read), and pruning/retention parallel to
`provider_autoupdate_events` (migration 026). To make frequency and flap history
reconstructable without a per-event log, the row carries explicit
coordinator-derived state, not just current totals: `first_seen_at`,
`last_observed_at`, `last_seq`, the high-water `restarts_total`/`deferrals_total`
**and** the `prev_restarts_total`/`prev_deferrals_total` **with** `prev_observed_at`
(the counters and observation time of the prior accepted beacon) — so the
single-step delta `restarts_total − prev_restarts_total` over the interval
`last_observed_at − prev_observed_at` is a real observation-time rate, not just a
count — `supervisor_label`/`supervisor_version`, the sticky
`last_restart`/`last_deferral` detail, and — the acceptance-window anchor —
`last_restart_observed_at`: the coordinator wall-clock time at which it **first**
accepted a beacon whose `last_restart.seq` advanced beyond the stored value (i.e.
first observation of a new restart). Longer-horizon frequency across boots is a
query over retained rows.

*Flap history is a coordinator-derived rollup (not a per-event log).* Because
`last_restart` is overwritten by the next restart, raw `restarts_total` alone
cannot show which restarts were flaps (a restart whose correlated instance never
held past the dwell threshold before the next restart) — and RFC-001 §7 requires
restart-loop flaps to be observable, not just total restart frequency. The row
therefore also carries coordinator-derived rollup columns: `flaps_total` (uint64),
`last_flap_observed_at`, and `last_restart_dwell_state` ∈ {`unknown`,
`correlated_pending`, `held`, `artifact_confounded`}. Note that `flap` is **not** a
`last_restart_dwell_state` value: in the single-row model the beacon that supersedes
a prior pending restart is the same beacon that starts the next restart, so the
column always reflects the current restart's state; a flap is recorded instead by
incrementing `flaps_total` and setting `last_flap_observed_at`. Query flap loops on
those two columns, not on `last_restart_dwell_state`. Update rule: when a new
`last_restart.seq` advances, the coordinator finalizes the **prior** restart — if
its correlated new instance reached the dwell threshold with no artifact-write event
the prior restart was `held`; if it did not, that is a flap (increment `flaps_total`,
set `last_flap_observed_at`); if an artifact-write event fell in its window the prior
restart is `artifact_confounded` (so a flap is not misattributed to a wedge loop when
an update/rollback was actually in play); correlation that was never established
(null old/new instance id) stays `unknown`. The new restart's own
`last_restart_dwell_state` then begins at `correlated_pending` (or `unknown`). This
preserves flap observability durably without reintroducing an event queue.

**Acceptance signal.** The signal keys on the **sticky `last_restart` state, not on
observing a `kind=restart` beacon** — since `kind` names only the latest write, the
coordinator may first observe the restart via a later `kind:"beacon"` (or
`kind:"deferral"`) beacon that still carries the sticky `last_restart`, and that
MUST count. Concretely: for a `(provider_id, boot_id)` the coordinator has observed
`last_restart != null` with `last_restart.reason = "wedge"`, an advanced
`last_restart.seq` (and correspondingly advanced high-water `restarts_total`)
setting `last_restart_observed_at`; then a **correlated** new `service_instance_id`
instance (both old `last_restart.service_instance` and new id non-null and
differing, per correlation above) whose coordinator-derived sustained-serving dwell
exceeds threshold, and **no coordinator-visible artifact-write event** in the window
`[last_restart_observed_at, last_restart_observed_at + dwell_threshold]`, evaluated
against the autoupdate table's **`provider_autoupdate_events.observed_at`**
(migration 026) — the coordinator-observation timestamp that ingest populates — as
the authoritative time column for the window (not `recorded_at`, and not any
provider-reported time). The window start is the **coordinator-derived**
`last_restart_observed_at` above, never the provider's self-reported `ts` (which
cannot narrow the window). An artifact-write event is precisely a
`provider_autoupdate_events` row whose `phase` ∈ {`backup`, `swap`, `rollback`} (the
SPEC-020 R-6.4 phases that mutate the on-disk provider binary) with `outcome` ∈
{`success`, `in_progress`}. **`outcome=failure` is deliberately excluded, matching
producer ground truth:** the existing autoupdate producer emits a
`phase:rollback`/`backup`/`swap` + `outcome:failure` event on a *pre-mutation*
abort — e.g. `reason:"reload_helper_fence_failed"` is recorded when the reload-helper
fence throws *before* any rollback/marker mutation runs
(`CoordinatorClient.swift`) — so a `failure` does **not** imply the artifact was
touched, and counting it would falsely mark a clean supervisor-recovery window as
`artifact_confounded`. `skipped`/`noop` (no mutation) and the non-artifact phases
(`detection`…`self_test`, `restart`, `post_start`) likewise never count. (If a
producer-backed "mutation actually began" signal is ever added to the autoupdate
event schema, the predicate can be widened to it then; until such a field exists,
`{success, in_progress}` is the only sound artifact-mutation evidence.) This proves
liveness recovery happened, held, and involved no rollback/update authority
(R-4.14). Absence is asserted against that exactly defined coordinator-visible
stream, not an undefined signal.

Behavior lands only via the cited follow-up code (watchdog emit + CLI uplink +
coordinator ingest/store); this section defines the contract. The new
`last_supervisor_event` provider-wire field is also recorded in the SPEC-001
provider-wire protocol.

## 6. Signing & notarization

**Extending, not building.** The CI job "Sign + notarize binary" in `.github/workflows/release.yml` already:

- imports a Developer ID Application `.p12` into a transient keychain (`security create-keychain build.keychain` → deleted on exit),
- codesigns `macprovider-cli` with `--options runtime --timestamp`,
- verifies with `codesign --verify --strict --verbose=2`,
- wraps in a transient `.zip` (Apple's rule for bare Mach-O), submits via `xcrun notarytool submit --wait`,
- re-tars the signed binary back into `phase3-binary-m4-<tag>.tar.gz`,
- if the Installer cert is present: `pkgbuild` + `productsign` → `notarytool submit --wait` → `stapler staple` → `stapler validate` → outputs signed `.pkg` (identifier `live.malibu.provider.cli`, preinstall script blocks direct GUI install).

This spec **adds** an App-track job to the same workflow (or a separate `release-app.yml`) that reuses the exact same keychain-setup pattern and secrets. Do not invent new secret names — piggyback.

### 6.1 CI secrets (already defined; reuse)

| Secret | Purpose | Already used by |
|---|---|---|
| `APPLE_DEVELOPER_ID_CERT_P12_BASE64` | Developer ID **Application** cert — signs binaries + `.app` | CLI binary signing |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | .p12 password | Same |
| `APPLE_DEVELOPER_ID_INSTALLER_CERT_P12_BASE64` | Developer ID **Installer** cert — signs `.pkg` | Existing signed `.pkg` delivery container |
| `APPLE_DEVELOPER_ID_INSTALLER_CERT_PASSWORD` | .p12 password | Same |
| `APPLE_NOTARY_APPLE_ID` | Apple ID for notarytool | Notarizing CLI + `.pkg` |
| `APPLE_NOTARY_PASSWORD` | App-specific password | Same |
| `APPLE_NOTARY_TEAM_ID` | Team ID | Same |
No App-specific update-signing secret exists. Compatibility metadata is signed through
the release trust path already used by the provider catalog and artifact index.

### 6.2 App and compatibility-set CI steps

> **Reconciled v0.4 — `release.yml` is authoritative.** The shipped pipeline differs in
> mechanics from the recipe below: it copies the archive product directly rather than
> running `-exportArchive` (`release.yml:184,194`), builds the `.dmg` with `hdiutil`
> (not `create-dmg`), and additionally emits an **optional signed App `.pkg`**
> (`release.yml:599,616`). Treat the steps below as design intent; the exact commands
> live in `.github/workflows/release.yml`.

Runs on the same macOS runner as the existing job, after the CLI binary is signed and notarized. The signed CLI binary from the existing step is the input.

1. `xcodebuild -scheme Malibu -configuration Release archive -archivePath Malibu.xcarchive` (new Xcode project lives at `phase3-binary/app/Malibu.xcodeproj`).
2. `xcodebuild -exportArchive -archivePath Malibu.xcarchive -exportPath build/Malibu -exportOptionsPlist app/ExportOptions.plist` → `Malibu.app` (already signed by Xcode).
3. Copy the already-signed `macprovider-cli` into `Malibu.app/Contents/MacOS/`.
4. Re-sign the whole bundle bottom-up in one pass so the outer signature covers the newly-embedded CLI:
   `codesign --force --options runtime --timestamp --entitlements phase3-binary/app/Malibu.entitlements --sign "$SIGNING_ID" --deep Malibu.app`
5. `codesign --verify --strict --verbose=2 --deep Malibu.app`
6. `hdiutil` → `Malibu-<version>.dmg`.
7. `codesign --sign "$SIGNING_ID" --timestamp Malibu-<version>.dmg`.
8. `xcrun notarytool submit Malibu-<version>.dmg --apple-id $APPLE_NOTARY_APPLE_ID --password $APPLE_NOTARY_PASSWORD --team-id $APPLE_NOTARY_TEAM_ID --wait` (this one **is** staplable — unlike the bare CLI).
9. `xcrun stapler staple Malibu-<version>.dmg` and `stapler validate`.
10. Build the exact compatibility-set manifest and typed rollback plan, then place the
    DMG and every provider runtime/policy artifact in the signed
    `compatibility-artifact-index.json`.
11. Publish immutable versioned GitHub release artifacts, including `appcast.xml` for
    old-client compatibility, then atomically publish the exact DMG, SHA-256 sidecar,
    and appcast bytes to `download.malibu.tech`. The updater discovers signed provider
    sets through the coordinator/catalog trust path; the appcast is not a second CLI
    update authority.

Reuse `cleanup_signing_material` trap from the existing job.

### 6.2.1 Signed provider code identity (issue #1842)

A release whose signed `pearl-release.json` ships the provider CLI (release
lane `pearl_runtime_catalog`, from `release.yml` or the acceptance signer) MUST
carry a top-level `provider_code_identity` object with exactly these fields:
`asset` (`macprovider-cli-<tag>-darwin-arm64.tar.gz`), `member`
(`macprovider-cli`), `binary_version` (the provider CLI version the same
metadata advertises), `binary_sha256` (64 lowercase hex of the extracted CLI
bytes), `team_id` (`^[A-Z0-9]{10}$`), `signing_identifier`
(`live.malibu.provider.cli`), and `slices` (exactly
`[{"arch": "arm64", "code_cdhash": <40 lowercase hex>}]`). The producer
(`scripts/provider-code-identity.py`) MUST derive it from the final shipped
tarball before `pearl-release.json` is signed, read `CDHash=`,
`TeamIdentifier=`, and `Identifier=` from `codesign -d --arch arm64 -vvv`
(never from designated-requirement display text), and fail closed unless the
binary is exact arm64, the Identifier is `live.malibu.provider.cli`, and the
TeamIdentifier equals the release Team ID. The runtime-only lane
(`pearl_runtime`) ships no CLI and MUST NOT carry the field. Every
CLI-shipping release with provider CLI version 1.8.214 or later MUST carry the
field; producers never omit it. Verifiers (`scripts/verify-pearl-runtime-release.sh`,
`scripts/verify-acceptance-promotion.py`) are present-then-strict: when the
field is present they MUST reject it if malformed, if `checksums.txt` does not
hold exactly one well-formed row for its `asset` (shared helper
`require_checksum_row()`), if the bound tarball is missing (the GitHub path MUST
download it), if its bytes differ from `checksums.txt`, or if `binary_sha256`
differs from the `macprovider-cli` extracted from it. They MUST accept its
absence only when the provider CLI version they already hold from signed
metadata (the verified release tag, or the signed compatibility manifest's
`provider_cli.version`) is at or below 1.8.213, using the single cutoff
predicate `identity_required()` in `scripts/provider-code-identity.py`; they
MUST then print the explicit notice
`provider_code_identity: absent (pre-#1842 release)` so a missing field is
never silent. For 1.8.214 and later, or any version that does not parse as
X.Y.Z, a missing field MUST fail. An absent field cannot be used to fill SPEC-049 approvals. Operators fill
SPEC-049 `privacy_class.approved_code_identities` from this verified field
(`scripts/provider-code-identity.py --emit-approved-identity`); the field is
not a new release asset and does not change `compatibility-set.json` or the
`compatibility-artifact-index.json` role set.

### 6.3 Entitlements (`Malibu.entitlements`)

> **The shipped `Malibu.entitlements` is an EMPTY dictionary (reconciled v0.2).** The
> build points `CODE_SIGN_ENTITLEMENTS` at `Malibu.entitlements` (`project.yml:46-68`),
> whose plist has **no keys** (`Malibu.entitlements:1-5`). None of the five entitlements
> below are in the shipped file. This is consistent with the monitor-only architecture
> (the app no longer runs MLX inference or spawns/loads the signed CLI in-process — the
> managed CLI is launchd-owned), so most of the v0.1 rationale is moot. The block below
> is the v0.1 proposal, retained for provenance; the shipped entitlement set is empty.

```xml
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
```

Rationale:

- `allow-jit` + `allow-unsigned-executable-memory` — retained for any in-app MLX use;
  note the heavy MLX inference now runs in the **managed CLI** process, not the app
  (reconciled v0.2).
- `network.client` — the app polls the managed CLI's `127.0.0.1` HTTP endpoints
  (`/v1/health`, `/v1/status`) and reaches the Sparkle appcast / GitHub release feed.
- `disable-library-validation` — retained for embedded frameworks; the app spawns
  `/bin/bash` to run the bundled `install.sh` during onboarding (not a signed child
  CLI daemon — that is launchd-owned). Verify at P0 whether same-TeamID signing lets
  this be dropped.
- `network.server` — retained; note the provider's `HTTPServer` binds `127.0.0.1`
  inside the **managed CLI**, and the app is its client.

**Not requested (would be trust-drops):** Accessibility, Full Disk Access, Screen Recording, Camera, Microphone. If any of these surface as required during P0, escalate immediately.

## 7. Storage, config, and CLI-track coexistence

The single biggest risk in this spec is stomping a config that a developer previously created via `install.sh`. Resolution:

| Data | Location | Owned by |
|---|---|---|
| Provider daemon config | `~/.config/macprovider/config.yaml` | **Shared** with CLI track |
| Wrapper preferences (window sizes, opt-ins) | `~/Library/Application Support/Malibu/prefs.json` | App track only |
| App-track marker | `~/Library/Application Support/Malibu/.installed-by-app` (**empty file**, reconciled v0.2 — not dated; `ProviderConfig.swift:513-518`) | App track only |
| CLI custody marker | `~/Library/Application Support/Malibu/.cli-credential-custody-v1` containing the exact provider ID | App-local migration evidence that an installed CLI freshly verified custody; never credential authority |
| Logs (rolling, 100 MB cap) | `~/Library/Logs/malibu/` | Shared, app tags its own lines |
| `provider_token` | Authoritative CLI Keychain service `live.malibu.provider.provider-token.v1`, account `<provider_id>`; private YAML is a degraded transition fallback until admission-gated cleanup | CLI owns runtime credential. A legacy App item is migration input only and is deleted after CLI custody is proven. |
| Session receipt / admission keys | Keychain (CLI store), services `com.malibu.provider.receipt-key` (current, rotatable — signs receipts), `com.malibu.provider.receipt-key.prev` (receipt rotation grace), `com.malibu.provider.bootstrap-identity-key` (current admission identity; legacy name), `com.malibu.provider.admission-identity-key.pending`, and `.prev`, all account `<provider_id>`. Admission identity rotates/recoveries by SPEC-026 §4.3 without Malibu key custody. | Unchanged from CLI track (reuses the existing CLI key store) |

Rules (reconciled v0.2 to the shipped `StartupState.route()` + `ProviderConfig`):

- **On first run of the app:** if `config.yaml` exists AND the `.installed-by-app`
  marker does NOT → route to `.showImportDialog` ("We found a MacProvider config.
  Import it into Malibu?"). On import, `ProviderConfig.importExistingCLIConfig()`
  reads an existing YAML `provider_token`, then runs installed-CLI
  `credentials import --config` followed
  by a distinct `credentials verify --config` against one immutable snapshot. A
  tokenless config normally runs verify-only and requires the provider's CLI-Keychain
  item. The exact legacy tokenless-YAML/App-Keychain-only state first restores its
  bearer to private live YAML so launchd retains rollback custody, then follows the
  token-bearing transaction.
  After fresh CLI custody is proven, Malibu deletes and verifies deletion of any
  legacy App bearer. The CLI keeps the live migration source until launchd admission.
  A missing/old CLI or failed proof preserves the original private YAML. Never
  silent-migrate.
  (`StartupRouteTests.swift:10-12`.)
- **On Quit-and-Uninstall:** `ProviderConfig.wipeAppOwnedState()` deletes
  `config.yaml` **only if the marker is present** (`ProviderConfig.swift:478-501`).
- **`isConfigured`** = `config.yaml` present AND `.installed-by-app` marker present,
  a top-level `provider_id`, and the provider-ID-bound
  `.cli-credential-custody-v1` marker. Credential readiness is reported by the launchd CLI's
  redacted `/v1/status.credential` contract, not inferred from Malibu's Keychain.
  **Route precedence (reconciled v0.3):** a *markerless* CLI-owned `config.yaml` takes
  FIRST precedence and routes to `.showImportDialog` — even when the launchd provider is
  healthy (`LaunchProviderController.swift:352`), per the first bullet above; only when
  the marker IS present but the config identity or required custody evidence is
  incomplete does a failed `isConfigured` route to onboarding, and a fully-absent config also routes to
  onboarding. **Token custody (reconciled v0.13 — nuanced, not "never
  on disk"):** the CLI deliberately retains the live YAML `provider_token` as rollback
  state after staging Keychain custody. A restarted provider reports
  `migration_pending=true`; only its authenticated coordinator admission and first
  state update permit locked exact-value removal. The one fixed 0600 backup is also
  the immutable handoff snapshot. The importer must confirm its deletion before deleting
  `.import_pending`; a cleanup failure keeps the journal for deterministic recovery. Until
  launchd admission, the App track therefore makes no "token never on disk" claim.
- **CLI track never touches** `~/Library/Application Support/Malibu/` or the app's
  Keychain entries; it owns only its separate CLI-Keychain service.

## 8. LaunchAgent — three distinct mechanisms (reconciled v0.2/v0.6)

There are **three** launchd-adjacent registrations in the shipped App track (v0.1
conflated them; v0.6 splits the provider service from its watchdog):

1. **The provider service — `live.malibu.provider`** (plist
   `~/Library/LaunchAgents/live.malibu.provider.plist`). The KeepAlive launchd job
   that runs the CLI daemon itself (`serve --config`, `install.sh:3423`). **This is the
   plist the app's evidence gate checks** (`launchdInstallEvidenceExists` — that plist OR
   `install_manifest.json`, `LaunchProviderController.swift:374-380`); the app refuses to
   monitor without it (§5).

2. **The companion watchdog — `live.malibu.provider-watchdog`** (a SEPARATE
   `StartInterval=60` launchd job that runs the watchdog binary, `install.sh:47,4264`).
   Distinct from the provider service. **Reconciled v0.24 — it is not a rollback
   owner:** the watchdog may request a launchd kick only after it has observed local
   health in the current boot and a later local `/v1/health` failure is paired with a
   restart-worthy `/v1/status` state. It may log that an autoupdate `pending.json`
   exists, but it MUST NOT restore CLI bytes, release resources, launchd plists, the
   watchdog script, or Malibu.app; it also MUST NOT bootstrap/kickstart the provider as
   update recovery. **Reconciled v0.25 (SPEC-020 R-4.14):** the watchdog also MUST NOT
   restart the provider on process exit or on a missing/unvalidated launchd PID —
   launchd `KeepAlive` is the single exit-restart owner — and MUST NOT write or restore
   any supervisor artifact (its own script, plist/LaunchAgent/LaunchDaemon, or any
   current/legacy label); it is installer-owned and non-self-restoring.
   Auto-update rollback and stale-marker quarantine are owned by
   installer/Malibu repair and CLI startup/install recovery under SPEC-020 v0.1.13.
   `install.sh` (run by the app during onboarding) installs **both** the provider
   service and this watchdog — v0.1's claim that the App track does NOT install the
   watchdog was false.

3. **The app login item — `SMAppService.mainApp`.** Registers `Malibu.app` itself to
   launch at login (`AppLoginItem.swift:6-30`), called at the end of a successful
   onboarding (`LaunchProviderController.swift:197`). About the **app UI** auto-starting,
   not the CLI daemon.

```swift
try SMAppService.mainApp.register()   // the APP login item, not the CLI daemon
```

- Apple surfaces the login item in **System Settings → Login Items**.
- `SMAppService` authors no `.plist`; the app's presence/status is
  `SMAppService.mainApp.status == .enabled` (`AppLoginItem.swift`). The **CLI**
  watchdog's plist is authored by `install.sh`, separately.
- Because the App track installs the same launchd CLI as the CLI track, coexistence
  is by the shared `config.yaml` + `.installed-by-app` marker (§7), not by "only one
  track installs a daemon."

### 8.1 System-domain headless profile is not an App runtime

SPEC-026 §2.1 defines `headless_fleet` as a separate installation profile, not
a fourth App-track launchd mechanism. Malibu MUST create, discover, import,
monitor, update, repair, or uninstall only `consumer_user` state. Its launchd
evidence checks MUST resolve the exact `gui/<uid>/live.malibu.provider` service
and per-user manifest; a loaded `system/live.malibu.provider`, a plist under
`/Library/LaunchDaemons`, or protected files under a fleet user's
`.config/macprovider/protected-credentials` root MUST NOT satisfy App
configuration or custody gates.

If Malibu detects headless system-domain installation evidence, it SHOULD report
a bounded profile-conflict state. Whether or not that UI is present, it MUST
offer no automatic takeover, import, or credential migration. Removal or
explicit migration is an administrator CLI transaction outside Malibu. These
rules do not alter any consumer path in §7-§8: provider bearer and
receipt/admission private keys remain in the existing CLI Keychain services, the
provider and watchdog remain LaunchAgents, and Malibu remains a separate
`SMAppService` login item.

## 9. Compatibility-set trust and discovery

- A signature-authenticated, expiring monotonic discovery head defined by
  SPEC-020 is the release root for update discovery. It binds the release
  sequence, exact set identity, signed-policy floor/revocations, and
  compatibility artifact-index digest. The compatibility artifact index binds
  immutable GitHub release artifact names, SHA-256 digests, required release
  roles, the compatibility-set manifest, and rollback-plan schema.
- The CLI verifies the catalog/release trust chain, artifact-index signature, exact set
  identity, per-role uniqueness, hashes, Developer ID identity/team where applicable,
  launchd labels, and target coordinator policy before any drain or replacement.
- Malibu carries no feed URL or independent in-app discovery channel. Only the
  one-time v1.8.39 bridge target carries the frozen v1.8.32 public key as inert
  trust-continuity metadata for the stranded 1.8.32 cohort; the source app and
  every signed build after v1.8.39 ship key-free. No signed target has a Sparkle
  runtime or feed URL.
  Failure to verify or fetch any required member leaves the current set running and
  emits a typed redacted update state. A staged target that fails exact signed-set
  identity, launch, or local provider health enters SPEC-020 rollback recovery.
  Coordinator admission or buyer-serving failure remains network-readiness
  evidence and does not independently roll back local success.

## 10. Landing page changes (`malibu.tech/host/`)

- Above the fold: big coral **Download for Mac** button → the immutable versioned
  GitHub release asset for the accepted release
  (`https://github.com/Augustas11/macprovider/releases/download/<tag>/Malibu-<tag>.dmg`),
  never a mutable `latest.dmg`. Same button also emits the SHA-256 next to it for the
  paranoid; the tag and digest MUST come from the same pinned accepted release the
  button links, so the page can never advertise a digest it does not serve
  (reconciled v0.22 — see §6 step 11).
- Below the button: disclosure toggle "**Prefer terminal?**" → reveals current `curl -fsSL https://get.malibu.tech/install.sh | bash` block. Devs keep their flow; the surface area for non-devs is a single button.
- Step section rewritten: "Download → Open → Earn." **There is no GitHub sign-in
  (reconciled v0.2):** onboarding is browserless — one **Launch Provider** click runs
  `install.sh` (SPEC-026 is explicit that no browser/GitHub step exists). v0.1's
  "GitHub sign-in is now inside the app" is removed.
- Requirements card unchanged.
- New troubleshoot page at `malibu.tech/host/troubleshoot` covering: Gatekeeper block (very rare post-notarization), `SMAppService` denied, first-model-download stuck, uninstall.

This landing page change is **file-level small** (`host/index.html` in the malibu repo) and non-blocking on the app itself.

## 11. Rollout plan

**Historical (reconciled v0.2).** This table is the original pre-#418 build plan and
is retained for provenance. It shipped, but the architecture inverted: P0's "spawns
bundled `macprovider-cli`" + the P0 `metrics_request`/`shutdown_request` control-socket
frames and P1's `malibu://` portal deep-link were **superseded** by the CLI-wrapper
model (run `install.sh`, monitor over HTTP). See §3.1 and §5 for the shipped flow.

| Phase | Scope | Exit criteria |
|---|---|---|
| **P0 — Skeleton** (1 wk) | Swift menu bar app in a new Xcode project, spawns bundled `macprovider-cli`, no onboarding, hardcoded `config.yaml` copied by hand. Add `metrics_request` + `shutdown_request` frames to `ControlSocket`. | End-to-end job served through `.app` on a dev Mac. |
| **P1 — Onboarding** (1 wk) | `malibu://` URL scheme; portal deep-link flow; wallet paste; hardware autotune call; `SMAppService.register()`; dashboard read-only. | 5 friendly testers install by drag-drop and start earning without CLI. |
| **P2 — `.app`/`.dmg` signing** (0.5 wk) | **Extend** existing `release.yml` "Sign + notarize binary" step with the App-track substeps in §6.2. Verify entitlements + hardened runtime. No new secrets except `SPARKLE_EDDSA_PRIVATE_KEY`. | Gatekeeper accepts `.dmg` on a fresh macOS 14 install (no `xattr -d`); `stapler validate` passes. |
| **P3 — Sparkle + updates** (0.5 wk) | Appcast, EdDSA signing key, delta patches, phased rollout. | Live `v0.1 → v0.2` update on 5 test Macs, one via delta patch. |
| **P4 — Landing page swap** (0.5 wk) | Redesigned `host/index.html` pinned to immutable release assets so the landing-page primary download no longer depends on mutable `latest.dmg`; `download.malibu.tech` remains the old-client compatibility appcast/DMG surface. | 50/50 A/B against current curl page for 1 wk on `malibu.tech/host`. |
| **P5 — WalletConnect** (1 wk) | Alongside paste flow; opens Rainbow / MetaMask / Coinbase Wallet via deep link; nonce signature bound to provider_id server-side. | 3 wallets verified round-trip. |
| **P6 — Homebrew Cask** (0.5 wk) | `brew install --cask malibu` pulls the same signed `.dmg`. | `brew audit --cask malibu` clean, install / uninstall round-trip. |

Total: ~5 focused weeks + review. One Swift engineer + part-time CI/infra + landing-page dev.

## 12. Conflicts to resolve before coding

**Historical + reconciled v0.2.** These were pre-P0 open questions. How PR #418
resolved them: **#1 CLI/App collision** — resolved by making the App track *use the
same* launchd install (`install.sh`) and coexist via the shared `config.yaml` +
`.installed-by-app` marker (§7); the app adopts an existing healthy provider rather
than running a second one. **#2 auto-update fights** — MOOT: the app never spawns a
child with `--managed-by malibu-app`; instead Sparkle updates the `.app`
(`.updateCLI` also maps to Sparkle — `MalibuApp.swift:90`), while the launchd CLI
self-updates via its own coordinator-driven `AutoUpdater` (`CoordinatorClient.swift:2756`,
enabled by default — §3.3), NOT via `install.sh`/the watchdog. **Reconciled v0.3:**
`CLIUpdateRunner` / `MalibuAgent.updateCLINow()` compile but have **no production caller**
(§3.3) — the app
does NOT invoke `malibu-cli update` at runtime. **#5 portal deep-link
handshake** — MOOT: the `malibu://` scheme and portal token handoff were removed;
registration happens inside `install.sh`. **#4/#3 (library validation / linking)** and
**#6/#7 (weights path / login-item rejection)** remain as build details. The list
below is the original text.

These are the things I'd flag as **must-decide before P0**, in priority order:

1. **CLI-track vs App-track collision on one Mac.** If a dev already ran `install.sh`, then installs `Malibu.app`, we now have two candidate CLI processes and two LaunchAgents. Use the existing `ProviderConflictDetector.swift` — on wrapper launch, detect an active CLI daemon (probe unix socket + LaunchAgent bootstate). If found, offer: (a) migrate (uninstall watchdog LaunchAgent + adopt config, see §7), (b) run side-by-side under a distinct `provider_id` suffix, or (c) abort. Default: (a). No silent takeovers.
2. **Auto-update fights.** `AutoUpdater.swift` in the CLI self-updates the binary from a signed catalog. In the App track, Sparkle updates the whole `.app` (which includes the CLI). Solution: the wrapper launches the child with `--managed-by malibu-app`; the CLI must treat this flag as a signal to **disable its own AutoUpdater** and defer to Sparkle. New CLI-side ticket.
3. **`mlx-swift` static vs dynamic linking.** If dynamic, both binaries in the bundle should share one copy in `Frameworks/` (smaller download, correct code signature). If static, each binary carries its own — larger but simpler. Decision drives the entitlements section (`disable-library-validation` may become unnecessary).
4. **`disable-library-validation` — can we drop it?** If wrapper and CLI are both signed with the same TeamID and hardened runtime, loading the child shouldn't need this. Verify empirically at P0; dropping it is a clean security win.
5. **Portal deep-link handshake for the app.** Portal today (SPEC-014) issues `provider_token` for a browser user. We need a small addition: `?client=mac&state=<nonce>` → redirect to `malibu://link?state=<nonce>&…`. State validation prevents drive-by token injection. Cross-team ticket with portal owner.
6. **Model weight storage location.** CLI track today writes to `~/.cache/…` (verify path). Wrapper should share this — model downloads are multi-GB, we don't want two copies. Confirm exact path in `ModelRuntime.swift` before P0 and either standardize on it or add a config option.
7. **`SMAppService` user rejection.** If user declines the "run at login" prompt, do we still run when the app is open? Yes — treat it as a soft state; nudge in dashboard once, then respect the choice.
8. **Sparkle key custody.** Whoever holds the EdDSA private key can push to every installed Mac. Store in 1Password shared vault, read by CI via short-lived deploy token, rotate quarterly, keep previous key valid one release.

## 13. Out of scope (backlog)

- Broader MDM/enterprise packaging. **Reconciled v0.5:** a basic optional signed App `.pkg` (`tech.malibu.app.installer`) is **already emitted** by the pipeline (`release.yml:616`); only fuller MDM/enterprise packaging (config profiles, managed deployment) remains backlog.
- Windows/Linux/Intel Mac builds.
- Multi-node fleet management.
- Fully in-app wallet (send/receive).
- iCloud-synced config between the user's Macs.
- Sparkle-based *downgrade* on rollback (Sparkle 2 supports it; not v1).

## 14. What this SPEC does NOT change

- Coordinator protocol — **except** the additive, observability-only
  `last_supervisor_event` provider-wire extension and the separate
  `provider_supervisor_events` store defined in §5.4 (F5). No routing, admission,
  billing, or existing-frame semantics change.
- Receipt shape, signing, or verification (`macprovider-verify` still works against both tracks).
- On-chain flows, payout logic, $MALIBU emissions, staking.
- CLI-track `install.sh` / `uninstall.sh` — unchanged except for the watchdog's
  SPEC-020 v0.1.13 authority reduction and the single §5.4
  `supervisor-beacon.json` it writes to its own trusted state dir.
- Existing CLI signing/notarization pipeline in `release.yml`. This spec **adds** steps that consume its output; it does not modify the CLI substeps or their secrets.
- Existing signed `.pkg` delivery container (`live.malibu.provider.cli`, preinstall blocks GUI install). The App-track `.dmg` is a completely separate artifact.
- Portal (SPEC-014) surface — **unchanged (reconciled v0.2).** v0.1 proposed a
  `client=mac` query param + `malibu://` redirect target; PR #418 removed the
  `malibu://` onboarding entirely, so the App track requires **no** portal-side
  change.

## 15. README correction (follow-up ticket)

`README.md`:

> The binary is checksum-verified against a signed release manifest. macOS quarantine (`xattr`) is cleared with your approval during install. Developer ID signing and notarization are planned for a future release.

Last clause is false as of `release.yml`'s "Sign + notarize binary" step. Update to describe the actual state (conditional signing when operator secrets are populated, driven by macOS 26.3.1+ AMFI requirement) and cross-link `phase3-binary/dist/release-signing-runbook.md`.
