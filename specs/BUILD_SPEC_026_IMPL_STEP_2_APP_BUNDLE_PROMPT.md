# BUILD_SPEC — SPEC-026 IMPL Step 2: App-track bundle (identity + controller + PendingLinkState retire + rename)

Bundle PR implementing SPEC-026 v0.11 §7.1 + §7.2 + §7.3 + §7.4 in one
merge unit per repo standing rule
[feedback-bundle-multi-phase-impl-prs]. Companion coord PR:
`feat/spec-026-coord-register-impl`.

## Source of truth

- `specs/SPEC-026-browserless-provider-onboarding.md` v0.11 (audit-loop
  converged R1..R10 + Claude critic + designer passes)
- §7.1 — `ProviderIdentity` module contract
- §7.2 — `LaunchProviderController` state machine
- §7.3 — `PendingLinkState` + `URLSchemeHandler.malibu` + `malibu://`
  retirement (deletions applied in this scaffold; call sites cleared)
- §7.4 — "node" → "provider" rename (MalibuAgent.swift:48 applied in
  this scaffold)
- §7.5 — `onboarding.json` persistence schema
- §7.6 — `MalibuAgent.start()` gate stays `ProviderConfig.isConfigured`
- §6.1 — user-facing flow with success card UX (v0.11 tightened:
  unclaimed-earnings CTA visual weight, MALIBU-locked persistent
  display)
- §6.2 — steady-state invariants (unclaimed-earnings badge,
  persistent MALIBU-locked display)
- §8 — MALIBU_ONBOARD_V2 feature flag; env var wins over UserDefaults
- §8.1 migration matrix (4 states × 2 flag positions)
- §8.4 — CLI-owned config import/migration dialog

## Scope IN

**Already applied by this scaffold PR:**

1. Deleted `phase3-binary/app/Sources/Malibu/System/PendingLinkState.swift`
2. Deleted `phase3-binary/app/Sources/Malibu/System/URLSchemeHandler.swift`
3. Deleted `phase3-binary/app/Tests/MalibuTests/PendingLinkStateTests.swift`
4. Removed `application(_:open:)` handler from
   `phase3-binary/app/Sources/Malibu/MalibuApp.swift` (SPEC-026 §7.3)
5. Removed `consume(_:)` / `presentLinkError(_:)` from `MalibuApp.swift`
6. Removed `PendingLinkState.discard()` from `performUninstall`
7. Removed `malibu://` from `phase3-binary/app/Sources/Malibu/Info.plist`
   `CFBundleURLTypes`
8. Renamed the sole "node" copy string in
   `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift:48` (SPEC-026
   §7.4)
9. Added scaffold `phase3-binary/app/Sources/Malibu/System/ProviderIdentity.swift`
10. Added scaffold `phase3-binary/app/Sources/Malibu/Onboarding/LaunchProviderController.swift`

**Codex fills in via the audit loop:**

11. `ProviderIdentity.isReady()`, `loadOrGenerate()`, `deleteFromKeychain()`
    Keychain integration. Concurrency: serialize `loadOrGenerate()` via an
    actor or NSLock to prevent double-generate races.
12. `ProviderIdentity.base32LowercaseNoPad()` bit-level encoder.
    Tested against `phase4-coordinator/test/jcs_fixtures/spec026_register.json`
    for byte-for-byte parity with Go coordinator side.
13. `ProviderIdentity.providerID(for:)` returns 54-char string; UI display
    truncates to first 10 chars per §3.3 + designer critique.
14. `LaunchProviderController.launch()` state machine per §6.1 step 7
    sub-steps a-j. Persist non-secret state at
    `~/Library/Application Support/Malibu/onboarding.json` (file mode
    0600) per §7.5.
15. `LaunchProviderController.retry()` resumes from `.failed` stage.
16. `LaunchProviderController.setPayoutWallet(_:)` wraps SPEC-016 §3
    EIP-712 signing flow. Wire the existing SPEC-016 §3 EIP-712 UI
    (browser wallet extension); no new SPEC-016 primitives needed.
17. `LaunchProviderController.isOnboardingV2Enabled` feature-flag helper:
    env `MALIBU_ONBOARD_V2` wins over UserDefaults `onboardingFlow`.
18. New SwiftUI onboarding view backing `LaunchProviderController`.
    Replaces the current `OnboardingWindow.swift` content (which was
    scoped to the SPEC-025 §3.1 browser-OAuth flow). Includes:
    - Success card copy per §6.1 step 8 v0.11 (Add-wallet CTA at
      **equal visual weight to counters** when unbound; MALIBU counter
      lock icon + "unlocks at Trusted" microcopy in Provisional).
    - **§8.4 import/migration dialog** for the CLI-owned-config
      no-App-marker state.
19. **§6.2 steady-state UI invariants:**
    - Unclaimed-earnings menu-bar badge with $1 / $10 / $100 re-surface
      thresholds after dismissal.
    - Persistent MALIBU-locked display anywhere a MALIBU balance is
      rendered while in Provisional.
20. Wire `LaunchProviderController.deleteIdentity()` into the uninstall
    path in `MalibuApp.performUninstall`. Current scaffold left a
    comment placeholder; codex adds the call.
21. Grep + rename any residual "node" copy across the App target
    (MenuBarController, DashboardView, README strings). Grep for
    `\bnode\b` (case-insensitive) and audit each hit.
22. Tests:
    - `ProviderIdentityTests` for keypair generation, provider_id
      derivation, base32 encoder parity, sign/verify roundtrip.
    - `LaunchProviderControllerTests` for state-transition happy path
      + retryable failure + close-window-mid-download resume.
    - `OnboardingStateTests` for JSON round-trip + schema version
      handling.
    - `MigrationMatrixTests` for the four §8.1 cells + §8.4 dialog
      outcomes (Import / Start fresh / Cancel).
    - AC-026-01, -02, -03, -04, -07, -08, -09, -10, -15 from §12.

## Scope OUT (this PR does NOT touch)

- Coord `/v1/providers/register` — sibling `feat/spec-026-coord-register-impl` PR.
- Any Postgres migrations — coord PR.
- WS proof-stage `identity_signature` production — App target only signs
  the `/register` body in this PR; the WS proof-stage frame extension
  (SPEC-026 §4.3) lands in a follow-up once the coord Phase 1b seeding
  runs at cutover.
- SPEC-016 §3 addendum for `provider_wallet_swaps` — not drafted yet.
- SPEC-027 email out-of-band cancellation channel.
- SPEC-028 MALIBU rewards emission ledger.

## Audit-loop discipline

Per [feedback-build-audit-loop]:

1. Fill in the impl per steps 11-22 above.
2. Write 3-lane audit prompts at
   `specs/AUDIT_SPEC_026_IMPL_STEP_2_{CODE,SECURITY,ARCHITECT}_AUDIT_PROMPT.md`
   per [feedback-audit-prompts-file-not-chat].
3. Fire `omc ask codex "$(cat <prompt>)"` for each lane in parallel.
4. Fix + re-fire; skip accepted lanes.
5. Narrative in `specs/SPEC-026-IMPL-STEP-2-audit.md`.

## Key constraints

- **Identity key never leaves the Keychain, and never enters any child
  process's environment.** SPEC-026 §3.1. All Ed25519 signing happens
  inside the App target's `ProviderIdentity` module. The CLI reads its
  OWN SPEC-015 receipt key from its OWN Keychain slot; the App does
  NOT export any key material to CLI env.
- **Identity key is DISTINCT from the SPEC-015 receipt key.** Two
  Keychain slots (`provider_identity_v1` vs `receipt_key_v1`), two
  lifetimes. SPEC-015 rotation semantics unchanged.
- **Base32 alphabet parity with Go coordinator.** JCS parity fixture
  at `phase4-coordinator/test/jcs_fixtures/spec026_register.json` is
  the byte-for-byte contract.
- **`MalibuAgent.start()` gate stays `ProviderConfig.isConfigured`**
  per SPEC-026 §7.6. Identity-only (v2-partial) state MUST NOT reach
  `MalibuAgent.start()`; the `LaunchProviderController` resume path
  handles it.
- **v0.11 UX invariants** are load-bearing:
  - Add-wallet CTA at **equal visual weight to counters** when unbound.
  - MALIBU counter has a **persistent lock icon + "unlocks at Trusted"**
    microcopy in Provisional tier.
  - Unclaimed-earnings menu-bar badge re-surfaces at $10 / $100 after
    dismissal.

## Reference

- SPEC-026 lock: PR #339 (`feat/onboarding-v2-provider-identity`,
  target base for this PR)
- Sibling coord PR: `feat/spec-026-coord-register-impl`
- Adjacent locked specs: SPEC-001 v1.6, SPEC-015 v0.3.3, SPEC-016 v1.0.1,
  SPEC-022, SPEC-023, SPEC-025

## Definition of done

- CI green on `phase3-binary (swift test)` and any spec-015-acceptance
  gates that assert the App-track composes cleanly.
- All the §12 AC-026-XX tests that touch App surface pass.
- 3-lane codex audit at 0 CRITICAL / 0 HIGH / 0 MEDIUM.
- No `PendingLinkState` or `URLSchemeHandler` references anywhere in
  the tree (CI grep gate enforces).
- CFBundleURLSchemes empty on the App bundle (or only whatever
  SPEC-025 baseline needs).
- Ready to convert from Draft → Ready for review.
