# AUDIT R2 — PR #334 ARCHITECT lane

Re-audit after R1 fixes. Confirm each R1 ARCHITECT finding is closed
and no new CRITICAL / HIGH / MEDIUM was introduced. Loop until
0 CRITICAL, 0 HIGH, 0 MEDIUM.

Working tree: `/Users/augstar/macprovider-pr334-audit`
(branch `audit/pr334`, based on `feat/malibu-native-app`).

R1 results file:
`/Users/augstar/macprovider-pr334-audit/.omc/artifacts/ask/codex-audit-pr-334-spec-025-native-mac-app-cli-wire-up-architect-l-2026-07-03T06-50-29-022Z.md`

## R1 findings to verify closed

- **A1 (HIGH)** — Control-socket contract compatible by name, not by
  invariant. The app decoder used to default missing required values
  to authoritative `0` / `false`, which the UI then rendered as truth.
  R1 fix: `AgentSnapshot` now uses `Double?` / `Int?` for earnings /
  metrics; `AgentSnapshotPresenter` renders `—` when nil;
  `metrics_response` still populates because the CLI stub does emit
  the required fields, but the presenter distinguishes "unknown"
  from "$0.00". `MalibuAgent.pause/resume` no longer optimistically
  flip state — they wait for `pauseAck` / `resumeAck` and only apply
  on `accepted: true`.
- **A2 (HIGH)** — App/CLI config collision was silent. R1 fix:
  `ProviderConfig.saveProviderIdentity` throws
  `SaveError.existingConfigNotOwnedByApp` when the shared config
  exists without the `.installed-by-app` marker; onboarding shows
  the error via `presentLinkError`. `isConfigured` additionally
  requires the marker AND a Keychain token for the config's
  provider_id.
- **A3 (HIGH)** — Deep-link unauthenticated. Same fix as SECURITY S1.
- **A4 (MEDIUM)** — Two update authorities without provenance. R1
  fix: `MalibuApp.applicationDidFinishLaunching` logs
  `[malibu] startup app_version=X build=Y managed_by=malibu-app`.
  The CLI-side `managed_by_malibu_app` skip event is emitted in
  `runAutoupdateIfEligible`. Are both signals sufficient? Do we
  need the CLI-bundled version explicitly?
- **A5 (MEDIUM)** — `MalibuAgent` SRP crossed. R1 fix (partial):
  extracted `AgentSnapshot` + `AgentSnapshotPresenter` to a
  separate file; extracted `ReconnectPolicy` struct; reconnect
  policy is now owned by `MalibuAgent` explicitly (not by
  `CLIChildProcess`). MalibuAgent still owns: child lifecycle,
  control socket, metrics polling, ack interpretation. Argument:
  further splitting into `AgentSupervisor` / `ControlClient` /
  `AgentPresenter` is a full refactor scope-creep for a P0
  skeleton PR; the concrete pain points from R1 (formatting mixed
  with data, hard-coded backoff constants) are addressed.
- **A6 (MEDIUM)** — Uninstall completion invariant. R1 fix: same as
  CODE M2 / SECURITY S3 — awaited residue report.
- **A7 (MEDIUM)** — CLI compatibility gate. R1 fix: fast-fail path
  in `MalibuAgent.onUnexpectedExit` — if the CLI exits within 3
  seconds with a non-zero code, we set `snapshot.state = .error`
  and message the user to reinstall instead of scheduling reconnect.
  Rationale: an unknown-flag rejection (`ArgumentParser`) exits
  status 64/78 within microseconds, so `< 3s && code != 0` is
  a reliable "we're the wrong binary" signal.
- **A8 (MEDIUM)** — Test coverage. R1 fix: added `MalibuTests`
  XCTest target with 4 files:
  - `ControlFrameCodecTests` — 6 round-trip parity tests.
  - `PendingLinkStateTests` — 4 nonce state-machine tests.
  - `AgentSnapshotPresenterTests` — 4 rendering tests.
  - `ProviderConfigParserTests` — CRLF parser regression.
- **A9 (LOW)** — SPEC drift ledger. Not fixed; keeping as LOW per
  the "MEDIUM findings may be carried explicitly" rule.

## Focus for this pass

1. Re-evaluate A5 downgrade. `MalibuAgent` is now ~200 lines,
   but the concerns are more separated. Is the remaining coupling
   between child lifecycle and control-socket a real defect, or a
   reasonable coordinator shape for P0?
2. Re-evaluate A1 downgrade. The stub still returns 0 for metrics;
   is the "no data yet" vs "authoritative 0" ambiguity fully
   resolved by the Optional + presenter change, or is there still
   a coupling between the wire's inability to distinguish "unset"
   from "0" and the UI presentation?
3. `PendingLinkState` — new abstraction. Is its API right? Should
   `beginLink` and `consume` live on `URLSchemeHandler` for
   cohesion, or is the separation correct?
4. `ReconnectPolicy` struct — is exposing it as a plain struct on
   MalibuAgent a solid boundary, or should it be an injected
   protocol so tests can drive it? For now it's not tested.
5. Startup provenance log via `NSLog` — is that the right
   observability sink? Should it be a structured event routed to
   the CLI log file so support can see both app-side and CLI-side
   in one place?
6. `SaveError` in ProviderConfig — presenter shows message via
   `NSAlert`. Is the UX correct for a first-time user who has
   an existing CLI install? Does the SPEC handle "import from
   CLI track" as a future migration story?
7. Test target's `BUNDLE_LOADER=$(TEST_HOST)` pattern — verifying
   this is the standard XcodeGen-macOS unit-test wiring; not
   using host-application would fail to link against `@testable
   import Malibu`. Anything off in `project.yml`?
8. New test file structure vs `sources: [path: Tests/MalibuTests]`
   in project.yml — will XcodeGen actually pick these up?

## Skip

- SPEC-025 §11 P2/P3/P4 (release pipeline, Sparkle appcast, portal).
- Style, naming.
- LOW/INFO findings; per the "stop iterating on LOW audits" rule
  we ship those with PR-body documentation.

## Output format

Same as R1 (A1, A2 … with File, Concern, 12-month trajectory, Fix).
Return `0 CRITICAL, 0 HIGH, 0 MEDIUM` on convergence.
