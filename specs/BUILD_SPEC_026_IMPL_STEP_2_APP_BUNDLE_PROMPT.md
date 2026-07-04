# BUILD_SPEC — SPEC-026 IMPL Step 2: App-track bundle (identity + controller + PendingLinkState retire + rename)

Bundle PR implementing SPEC-026 v0.12 App-track §7.1-§7.6 plus the
required §6, §8, and §12 App-surface acceptance work in one merge unit
per repo standing rule
[feedback-bundle-multi-phase-impl-prs]. Companion coord PR:
`feat/spec-026-coord-register-impl`.

## Source of truth

- `specs/SPEC-026-browserless-provider-onboarding.md` v0.12 (v0.11 plus
  Step-2 prompt-audit corrections)
- §7.1 — `ProviderIdentity` module contract
- §7.2 — `LaunchProviderController` state machine
- §7.3 — `PendingLinkState` + `URLSchemeHandler.malibu` + `malibu://`
  retirement (some deletions applied in this scaffold; remaining call
  sites/project docs are explicit implementation touchpoints below)
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
- §8.1 migration matrix (5 states × 2 flag positions)
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
    actor or NSLock to prevent double-generate races. Keychain attributes:
    `kSecClassGenericPassword`, service `Bundle.main.bundleIdentifier ??
    "tech.malibu.app"`, account `provider_identity_v1`,
    `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, raw 32-byte
    `Curve25519.Signing.PrivateKey.rawRepresentation` as the value.
12. `ProviderIdentity.base32LowercaseNoPad()` bit-level encoder.
    Tested against explicit RFC 4648 lowercase/no-pad vectors and the
    SPEC-026 provider_id fixture bytes. Do not use the register JCS fixture
    as a base32 test substitute.
13. `ProviderIdentity.providerID(for:)` returns 54-char string; UI display
    truncates to first 10 chars per §3.3 + designer critique.
14. Add an App-track `RegisterClient` used by
    `LaunchProviderController.launch()`:
    - Build the §4.1 `/v1/providers/register` body with
      exactly `provider_id`, `identity_pubkey`, `hardware_summary`,
      `app_attest_object`, `app_attest_key_id`, `nonce`, `ts_utc`, and
      `signature`. `ts_utc` is an RFC3339 UTC string matching §4.1 and
      the §5.3 App Attest `clientDataHash` binding.
    - Sign exactly `JCS(body_without_signature)` with
      `ProviderIdentity.sign`; never sign ad hoc `JSONEncoder` output.
    - Use base64/base64url encodings exactly as §4.1 specifies; do not add
      `binary_version`, `provider_name`, `signature_alg`, or other fields
      to the signed request body unless SPEC-026 §4.1 is amended first.
      `provider_name = "malibu-app"` is coordinator-side token mint
      metadata, not an App request field.
    - On duplicate-register recovery, prefer
      `Authorization: Bearer <current_provider_token>` loaded from the
      provider-token Keychain slot; never write the bearer into
      `onboarding.json`, config YAML, logs, or crash text.
    - Add `phase4-coordinator/test/jcs_fixtures/spec026_register.json`
      if absent, and make Swift + Go tests consume the same fixture for
      canonical request bytes.
15. `LaunchProviderController.launch()` state machine per §6.1 step 7
    sub-steps a-j. Persist non-secret state at
    `~/Library/Application Support/Malibu/onboarding.json` (file mode
    0600) per §7.5. Use explicit `CodingKeys` matching snake_case
    (`provider_id`, `created_at`, `last_stage`, `first_serving_at`,
    `model_download`). `first_serving_at` is the persisted v2-complete
    marker; null/absent means v2-partial.
16. `LaunchProviderController.retry()` resumes from `.failed` stage.
17. `LaunchProviderController.setPayoutWallet(_:)` is scoped to a
    post-success/dashboard CTA handoff in this PR. Do not invent a new
    wallet connector or in-App EIP-712 stack. If no concrete SPEC-016 App
    route exists, render the Add-wallet CTA and leave `setPayoutWallet`
    as a guarded integration point that cannot be invoked during
    onboarding; the actual wallet-signing UX remains SPEC-016/SPEC-027
    follow-up surface.
18. `LaunchProviderController.isOnboardingV2Enabled` feature-flag helper:
    env `MALIBU_ONBOARD_V2` wins over UserDefaults `onboardingFlow`.
    Default/unset is OFF. `MALIBU_ONBOARD_V2=0` overrides a UserDefaults
    `"v2"` value. This PR must not set production Sparkle defaults or
    otherwise flip v2 on before the §10 deploy checklist passes.
19. Add an explicit startup router/state classifier for all §8.1 cells.
    Inputs: config exists, App marker exists, provider token exists in
    Keychain, identity exists, onboarding.json exists, `first_serving_at`,
    env flag, UserDefaults flag. Test all 5 install states × 2 flag
    positions plus all §8.4 dialog outcomes.
20. New SwiftUI onboarding view backing `LaunchProviderController`.
    Replaces the current `OnboardingWindow.swift` content (which was
    scoped to the retired SPEC-025 §3.1 browser-OAuth/deep-link flow and
    still references `PendingLinkState`). Includes:
    - Success card copy per §6.1 step 8 v0.11 (Add-wallet CTA at
      **equal visual weight to counters** when unbound; MALIBU counter
      lock icon + "unlocks at Trusted" microcopy in Provisional).
    - **§8.4 import/migration dialog** for the CLI-owned-config
      no-App-marker state. Import must be atomic: parse `provider_id` +
      top-level `provider_token`, save token to Keychain, rewrite YAML
      without the bearer, create marker, verify `ProviderConfig.isConfigured`,
      and roll back all touched state on failure. Start-fresh moves the
      old config aside with a UTC backup suffix and displays the reclaim
      command. Cancel touches no files.
21. **§6.2 steady-state UI invariants:**
    - Unclaimed-earnings menu-bar badge with $1 / $10 / $100 re-surface
      thresholds after dismissal.
    - Persistent MALIBU-locked display anywhere a MALIBU balance is
      rendered while in Provisional.
    - Fetch the SPEC-026-extended
      `GET /providers/{provider_id}/earnings` response as the
      steady-state source of truth for `wallet_bound`, `trust_tier`,
      `unpaid_ledger_backlog_usdc`, and
      `unpaid_ledger_backlog_malibu`; reflect those into the App
      snapshot/presenter alongside badge dismissal thresholds. Tests must
      not fake these invariants with hard-coded view strings only.
    - Before SPEC-027 ships, pending-swap UI may be read-only only. Do
      not add a Cancel affordance or cancellation action.
22. Wire `try await ProviderIdentity.deleteFromKeychain()` into the
    uninstall path in `MalibuApp.performUninstall` before
    `ProviderConfig.wipeAppOwnedState()`.
23. Remove remaining retired deep-link/browser-flow surface:
    `OnboardingWindow.swift` `PendingLinkState.beginLink()`, old browser
    copy, `phase3-binary/app/project.yml` `CFBundleURLTypes`, README
    references to `URLSchemeHandler.swift` / `malibu://`, and any
    generated Xcode project drift.
24. Grep + rename any residual "node" copy across the App target
    (MenuBarController, DashboardView, README strings). Grep for
    `\bnode\b` (case-insensitive) and audit each hit.
25. Tests:
    - `ProviderIdentityTests` for keypair generation, provider_id
      derivation, base32 encoder parity, sign/verify roundtrip.
    - `LaunchProviderControllerTests` for state-transition happy path
      + retryable failure + close-window-mid-download resume.
    - `OnboardingStateTests` for JSON round-trip + schema version
      handling, including `first_serving_at`.
    - `MigrationMatrixTests` for all ten §8.1 cells + §8.4 dialog
      outcomes (Import / Start fresh / Cancel).
    - AC-026-01, -02, -03, -04, -07, -08, -09, -10, -15 from §12.

## Scope OUT (this PR does NOT touch)

- Coord `/v1/providers/register` — sibling `feat/spec-026-coord-register-impl` PR.
- Any Postgres migrations — coord PR.
- Coordinator-side WS proof-stage `identity_signature` verification and
  proof-stage frame schema enforcement — sibling coord/follow-up work.
  This PR must still provide the App-side signing primitive and integration
  seam needed to produce the §4.3 identity signature without exporting the
  identity key to the CLI: add `identity_signature_request` /
  `identity_signature_response` control-socket frames, compute the exact
  §4.3 JCS payload inside the App, sign with `provider_identity_v1`, return
  only the signature + transcript hash, and test provider_id mismatch,
  refusal, and no-key-export/no-logging behavior. The branch is not
  flag-flippable until both App-side production and coordinator-side
  verification are wired and §10 passes.
- SPEC-016 §3 addendum for `provider_wallet_swaps` — not drafted yet.
- SPEC-027 email out-of-band cancellation channel.
- SPEC-028 MALIBU rewards emission ledger.

## Audit-loop discipline

Per [feedback-build-audit-loop]:

1. Fill in the impl per all "Codex fills in" items above (steps 11-25).
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
- **Base32 alphabet parity with Go coordinator.** Use explicit base32
  vectors. The register JCS fixture is the byte-for-byte contract for
  canonical `/register` payloads, not a substitute for base32 coverage.
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
- **Feature flag is default-off and not a release flip.** Env var
  precedence is testable; this PR must not set production defaults that
  enable v2 before §10 passes.
- **No secret logging.** Raw private keys, provider tokens,
  `Authorization` headers, signed register bodies carrying bearer proof,
  and retired portal/deep-link URLs are not logged.

## Reference

- SPEC-026 lock: PR #339 (`feat/onboarding-v2-provider-identity`,
  target base for this PR)
- Sibling coord PR: `feat/spec-026-coord-register-impl`
- Adjacent locked specs: SPEC-001 v1.6, SPEC-015 v0.3.3, SPEC-016 v1.0.1,
  SPEC-022, SPEC-023, SPEC-025

## Definition of done

- CI green on `phase3-binary (swift test)` and App target tests:
  `cd phase3-binary/app && xcodegen generate && xcodebuild -project Malibu.xcodeproj -scheme Malibu test`.
  If `xcodegen` is unavailable locally, report that gap and run the
  nearest existing generated-project check.
- All the §12 AC-026-XX tests that touch App surface pass.
- 3-lane codex audit at 0 CRITICAL / 0 HIGH / 0 MEDIUM.
- No `PendingLinkState`, `URLSchemeHandler`, `malibu://`, or
  `CFBundleURLSchemes: [malibu]` references in App source, App tests,
  `phase3-binary/app/project.yml`, generated project files, or
  `phase3-binary/app/README.md`. SPEC and audit files may mention the
  retired symbols as history.
- Built App bundle has no `CFBundleURLSchemes` entry for `malibu`.
- Ready to convert from Draft → Ready for review.
