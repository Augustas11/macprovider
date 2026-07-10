# AUDIT R2 — PR #334 SECURITY lane

Re-audit after the R1 fix pass. Confirm each R1 SECURITY finding is
closed and no new CRITICAL / HIGH / MEDIUM was introduced. Loop until
0 CRITICAL, 0 HIGH, 0 MEDIUM.

Working tree: `/Users/augstar/macprovider-pr334-audit`
(branch `audit/pr334`, based on `feat/malibu-native-app`).

R1 audit results file:
`/Users/augstar/macprovider-pr334-audit/.omc/artifacts/ask/codex-audit-pr-334-spec-025-native-mac-app-cli-wire-up-security-la-2026-07-03T06-50-13-979Z.md`

## R1 findings to verify closed

- **S1 (CRITICAL)** — Unauthenticated deep-link identity replay.
  R1 fix: `PendingLinkState` module (32-byte SecRandom nonce, single-
  use, 15-min expiry, refused if already configured);
  `URLSchemeHandler` now REQUIRES `state`; `MalibuApp.consume`
  validates via `PendingLinkState.consume` and surfaces errors via
  NSAlert.
- **S2 (HIGH)** — Provider bearer token exposed via process env.
  R1 fix: CLI now calls `unsetenv("MACPROVIDER_PROVIDER_TOKEN")`
  immediately after `ConfigLoader.load` in `MacProviderCLI.swift`.
  Trade-off: brief window at startup before unsetenv; complete
  solution (CLI reads Keychain directly) still deferred per SPEC-025.
- **S3 (MEDIUM)** — Uninstall race. Same fix as CODE M2 — see there.
- **S4 (MEDIUM)** — CLI wrote `assigned_provider_token` to
  `config.yaml` even when spawned by the app. R1 fix:
  `adoptAssignedProviderTokenIfPresent` in `CoordinatorClient.swift`
  now short-circuits `ProviderTokenPersist.write` when
  `appConfig.managedBy == "malibu-app"`, emits
  `provider_token_persist_skipped_managed_by_malibu_app` event, and
  adopts in-memory only.
- **S5 (MEDIUM)** — Keychain accessible policy too weak. R1 fix:
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` →
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **S6 (MEDIUM)** — Over-scoped entitlements. R1 fix: removed
  `cs.allow-jit`, `cs.allow-unsigned-executable-memory`,
  `cs.disable-library-validation`, and `network.server` from
  `Malibu.entitlements`. Kept `network.client` for future Sparkle.
- **S7 (LOW)** — Login-item unregister failures hidden. R1 fix:
  `AppLoginItem.unregisterReturningError()` returns the error and
  `performUninstall` surfaces it in the residue alert. Only "was
  never registered" (SMAppServiceErrorDomain 108) is swallowed.

## New surfaces to review

Same list as CODE R2 §"New surfaces to audit" — most importantly:
- `phase3-binary/app/Sources/Malibu/System/PendingLinkState.swift`
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` (unsetenv)
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  around `adoptAssignedProviderTokenIfPresent`
- `phase3-binary/app/Malibu.entitlements`

## Focus for this pass

1. `PendingLinkState` nonce:
   - `SecRandomCopyBytes` 32 bytes → 64 hex chars. Sufficient entropy?
   - Fallback loop `UInt8.random(in: 0...255)` if SecRandom fails —
     is that a downgrade path an attacker can trigger? Realistic?
   - Constant-time compare — good.
   - The state file lives at
     `~/Library/Application Support/Malibu/pending-link.state` with
     chmod 0600 applied AFTER `write`. Race window where a same-user
     attacker reads the file at default 0644 permissions during the
     ~microseconds between write and setAttributes? Contents are a
     nonce only, not a secret — but nonce disclosure IS an S1 defeat
     (attacker can craft a matching callback).
2. `URL.query` still carries the bearer token in the malibu:// redirect
   from the portal. Even with a nonce gate, this ends up in NSLog
   diagnostics if the app ever logs the URL. Verify no code path logs
   `url.absoluteString` from the URL handler.
3. `unsetenv("MACPROVIDER_PROVIDER_TOKEN")`:
   - Ordering: `ConfigLoader.load(cli:)` reads env at call time via
     `environment: [String: String] = ProcessInfo.processInfo.environment`
     default parameter. Default parameters are evaluated at call
     site; env dict is snapshotted before `unsetenv`. Confirm.
   - The subcommands `TokenCommand.run()` etc. also load config.
     If any of them run instead of `ServeCommand`, do they get to
     `unsetenv` too? Currently `unsetenv` is only in `ServeCommand.run`.
     Is that a real vector, or are only Serve invocations spawned by
     Malibu.app?
   - `unsetenv` on Swift is `Darwin.unsetenv`. Signature is
     `(UnsafePointer<CChar>) -> Int32`. Swift string literal converts
     implicitly. Verify the return value doesn't matter here.
4. `managed_by` gate in `CoordinatorClient`:
   - Adopting the token in-memory (`self.providerToken = trimmed`)
     without persisting it means a CLI restart under the app path
     will not have the newer token. The app supplies the OLD token
     from Keychain. Is that a correctness/security regression?
     (Note: the CLI wasn't tracking token adoption via Keychain
     before either — this is the pre-existing followup.)
   - Consider: does the FR-C9.3 TOFU brick scenario re-emerge if
     `assigned_provider_token` is sent but never persisted, then
     the process crashes before adopting?
5. Entitlements: verify `network.client` alone is sufficient for a
   menu-bar app that only:
   - Talks to a local Unix socket (no entitlement needed).
   - Opens https://portal.streamvc.live via `NSWorkspace.open` (no
     network entitlement in-app; the browser handles the request).
   - Registers a login item via SMAppService (no entitlement).
   Argument: could we drop `network.client` entirely until Sparkle
   arrives? That's a scope-reduction question but flag if the
   over-broad entitlement is a real risk today.
6. `wipeAppOwnedState` residue reporting: the alert is modal. Could
   `NSAlert.runModal()` be blocked before terminate because the app
   is `LSUIElement: true` (no menu bar in dock)? Verify the alert
   surfaces.
7. `PendingLinkState.discard()` is called during uninstall. Good.
   Also called in `MalibuApp.consume` failure paths? Yes via the
   `defer` inside `consume(state:appAlreadyConfigured:)`.

## Skip

- SPEC-025 follow-ups (P1/P2/P3/P4) that this PR does not touch.
- Style / naming.
- Duplication between app-side and CLI-side codec (P0 known followup).
- Compatibility with Mac App Store (explicit non-goal per SPEC-025).

## Output format

Same as R1 (S1, S2… with File, Risk, Attack scenario, Fix). Return
`0 CRITICAL, 0 HIGH, 0 MEDIUM` on convergence.
