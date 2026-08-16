# BUILD_SPEC_020_PROMPT — Provider Autoupdate

You are drafting a normative SPEC for `macprovider-poc`. House style:
`specs/SPEC-NNN-<short-name>.md` with `Version: vX.Y.Z` on line 3, sections
for **Goal**, **Non-goals**, **Normative requirements (numbered R-N.M)**,
**Acceptance criteria (numbered AC-V0.1-N)**, **Threat model**, **Open
questions**, **Deferred to vX.Y.Z**, and a **Change log**.

Output: a single file `specs/SPEC-020-provider-autoupdate.md` at
version `v0.1.0`. No code edits.

## Context — what already exists

The provider binary already implements a manual self-update flow at
`phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`. Operators
invoke it via `macprovider-cli update`. The IMPL is mature:

- Fetches `https://api.github.com/repos/Augustas11/macprovider/releases/latest`
- Discovers tarball (`*-darwin-arm64.tar.gz`) + `checksums.txt` + `checksums.txt.sig`
- Verifies `checksums.txt.sig` with a baked-in ECDSA P-256 pinned pubkey
  (`SelfUpdate.checksumPublicKeyPEM`).
- Verifies tarball SHA-256 against the signed `checksums.txt`.
- Validates download URLs are HTTPS + GitHub-hosted only.
- Validates tarball entries are not absolute or path-traversal.
- Extracts to a temp dir, invokes the new binary's `self-test`
  subcommand, and only swaps if `self-test` succeeds.
- Atomic rename via POSIX `rename(2)`.
- `launchctl bootout` + `launchctl bootstrap` to restart the LaunchAgent.
- Caches the latest version for 1 hour at `~/.cache/macprovider/latest-release.json`.

The coordinator already advertises `recommended_binary_version` in the
auth payload. The provider currently does notify-only:
`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1232-1236`
prints `"A newer version is available... Run 'macprovider-cli update'
to upgrade."` and continues. Operators must manually run the update.

A `live.malibu.provider-watchdog` LaunchAgent already exists at
`ops/macprovider-watchdog/` and probes the provider's WS-to-coord
state every 10 minutes. It can serve as a rollback observer.

## Goal — what this SPEC normatively defines

The provider auto-invokes the existing `SelfUpdate` flow when the
coordinator advertises a newer `recommended_binary_version`, subject to
explicit safety, throttling, drain, and opt-out invariants such that an
operator's machine can update without manual intervention but cannot be
silently downgraded, hijacked, or knocked offline by a bad release.

## Non-goals (defer to later versions)

- Operator-side staging / canary / opt-in-to-prerelease channels.
- Auto-rollback past more than one prior version.
- Cross-architecture (only `darwin-arm64`).
- Provider capability advertising (operator's stance: autoupdate is the
  version-skew fix, not capability flags — out of scope for this SPEC).
- Coordinator-side changes to how `recommended_binary_version` is set
  (operator sets it; this SPEC only defines provider behavior).

## Specific normative requirements to design

Address each of these explicitly with R-N.M numbering. Codex MUST cover
all of them; flag any genuine ambiguity in Open Questions rather than
silently picking.

**Trigger and detection (R-1.x):**
- When the provider learns about a newer recommended version.
- Detection sources: coord auth-payload field, periodic GitHub Releases
  poll, both? If both, which is primary and what's the fallback?
- Throttling: at most one update attempt per coord session? Per N
  minutes? Backoff after failure?

**Safety invariants (R-2.x):**
- Refuse downgrades (recommended < current → no-op).
- Refuse anything other than ECDSA-P256-signed checksums (existing IMPL
  already enforces; SPEC must make this a normative invariant).
- Refuse if `self-test` on the new binary fails (existing IMPL enforces;
  normative).
- Refuse if free disk space below some threshold for the temp
  extraction directory.
- Refuse mid-inference: provider MUST drain before swap. Define drain
  precisely — what counts as "in-flight," and what's the maximum wait
  before forcing the swap.

**Drain semantics (R-3.x):**
- On autoupdate decision: refuse new admissions at the coord (how does
  the provider signal this? `state_update` with `draining` state?
  WebSocket close with reason?).
- Wait for in-flight HTTP requests to complete or hit a maximum drain
  timeout (propose: 120s soft, 30s hard after notice).
- Only then invoke `applyValidatedUpdate`.

**Failure and rollback (R-4.x):**
- If download / signature / checksum / `self-test` fails: log structured
  event, do not attempt update again until cooldown expires (propose:
  exponential backoff capped at 1 hour).
- If post-swap restart fails (process crash within 60s of new binary
  start): watchdog rolls back to the prior binary, disables autoupdate
  for the rest of the session, and surfaces a structured failure event.
- Define how the prior binary is preserved (existing IMPL uses
  POSIX rename; the OLD binary is overwritten — needs change to preserve
  rollback target).

**Opt-out (R-5.x):**
- Operator opt-out mechanism: env var, config-file flag, or both.
- Opt-out MUST be respected even when coord advertises a newer version.
- Default policy: opt-IN (autoupdate is on by default — operator's
  stated preference).

**Observability (R-6.x):**
- Structured event log for each decision point (detection, eligibility
  check, download, verify, self-test, drain, swap, restart, rollback).
- Coordinator-visible signal: a `last_autoupdate_event` field in
  heartbeats or `state_update` payload so the operator can see
  fleet-wide autoupdate status from the coordinator side.

## Threat model — explicit section required

This is downloading + executing code from the internet on operator
machines. SPEC MUST include a numbered threat model covering at
minimum:

- T-1: Attacker controls the GitHub release pipeline (signing key
  compromise). What survives? What doesn't?
- T-2: Attacker MITMs the GitHub Releases response. What survives?
- T-3: Attacker controls the coordinator and lies about
  `recommended_binary_version`. What survives?
- T-4: Attacker controls a coordinator that advertises a malicious
  binary version that DID legitimately exist in GitHub releases history
  (e.g., a prior version with a known vuln, attempting downgrade).
- T-5: Attacker controls a coordinator that advertises a version they
  also published in GitHub releases history before discovery (race).
- T-6: Malicious local user with write access to the provider config /
  state dir / binary path.
- T-7: Provider's update process race with launchctl / watchdog (the
  rollback observer becomes the attack surface).

For each threat, state what the SPEC's invariants defend against and
what's accepted residual risk.

## Open questions to flag

Flag these explicitly under "Open Questions" rather than picking:
- Q-1: Should autoupdate respect a quiet window (e.g., don't update
  between 09:00–18:00 local time to avoid disrupting active sessions),
  or always update immediately on detection?
- Q-2: Should the prior-binary backup be kept across restarts (so
  rollback survives a reboot), or is single-session rollback enough?
- Q-3: When coord advertises a version and GitHub doesn't yet have it
  (release-coord-drift race), what's the right behavior — silent
  retry-with-backoff, or surface to logs immediately?
- Q-4: For a hard-drain timeout, what's the right value? 60s? 5min?
  Per-stream rather than global?

## Acceptance criteria

Number them `AC-V0.1-N`. Cover at minimum:
- End-to-end: coord advertises v(current+1), provider detects,
  downloads, verifies, drains, swaps, restarts, rejoins pool, reports
  new binary_version to coord.
- Downgrade attempt rejected.
- Signature mismatch rejected; no swap occurs.
- self-test failure rejected; no swap occurs.
- Drain timeout exceeded; force-swap or skip-update (whichever the SPEC
  decides) with documented reasoning.
- Opt-out env var honored — no autoupdate even when coord advertises.
- Post-swap crash within 60s → watchdog rolls back; autoupdate disabled
  for rest of session.

## Deferred to v0.x

Document what we're explicitly punting to v0.2 / v0.3 / later (don't
silently skip). Example candidates: per-machine stagger, canary cohort,
custom release feed.

## Inputs to reference

Read these before writing:
- `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` (existing
  update implementation — the SPEC is wiring this up, not reinventing).
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  (recommended_binary_version notify path at line ~1232,
  binaryVersion constant at line 168, registration handshake at line
  ~1640).
- `ops/macprovider-watchdog/watchdog.sh` (rollback observer candidate).
- `OPS.md` (operational context).
- Recent SPEC headers (`specs/SPEC-018-*.md`, `specs/SPEC-019-*.md`)
  for house style.

## Output

A single file `specs/SPEC-020-provider-autoupdate.md` at version
`v0.1.0` with sections in the order listed above. No other file edits.
