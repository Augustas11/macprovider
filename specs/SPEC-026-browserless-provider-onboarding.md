# SPEC-026 — Browserless Provider Onboarding (one-click Launch Provider)

Status: DRAFT v0.1 · Owner: augstar · Target: 2026 Q3

## 0. Terminology

- **App track** — `Malibu.app`, the signed `.dmg` menu-bar wrapper introduced
  by [SPEC-025](./SPEC-025-native-mac-app.md). Brand is Malibu; user-visible
  strings never say "MacProvider", `streamvc.live`, or "node".
- **CLI track** — existing `macprovider-cli` binary launched via `install.sh`
  by developer users. Coexists unchanged.
- **Provider identity key** — Ed25519 keypair generated on first launch of
  the App track. Same key algorithm as the settlement receipt key defined
  in [SPEC-015 §12](./SPEC-015-receipts.md) and matches
  `Curve25519.Signing.PublicKey` in
  `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:226`.
- **provider_id** — `p_` + base32(sha256(pubkey)), deterministic from the
  identity key. Self-verifiable, no coordinator round-trip needed to compute.
- **Provisional tier** — trust bucket a new provider starts in with capped
  emissions, reduced concurrency, and delayed payout, until the trust
  criteria in §5 unlock.
- **Deferred wallet** — the payout wallet is not required at onboarding.
  Earnings accrue as coordinator escrow until first bind.

## 1. Goal

A non-technical Mac user opens `Malibu.app` for the first time and sees a
single primary button: **Launch Provider**. Clicking it makes them a live
marketplace provider within the same window, without a browser tab, without
a GitHub sign-in, without copy-pasting anything, and without entering a
wallet address unless they want to.

### 1.1 Success criteria

- **Zero external surfaces during onboarding.** No browser tab opens. No
  `portal.streamvc.live` URL appears in the UI or logs. No GitHub OAuth
  screen. No wallet-signing prompt.
- **≤ 1 click of user intent.** After launch, a single button starts every
  background step: identity generation, coordinator registration, CLI
  download, model download, agent start, first heartbeat.
- **In-window progress and success.** Every step's progress and the final
  "Provider live · <model> · <USDC/MALIBU counters>" success card render
  inside the same `NSWindow`. No menu-bar-only completion. No secondary
  dashboard window opening automatically.
- **Resumable.** Closing the window mid-download does not cancel the task.
  Reopening rehydrates state from disk + Keychain + partial downloads and
  the progress ring picks up where it left off.
- **Wording.** No user-facing string contains "node". Everywhere it
  currently reads "node", the App track reads "provider".

### 1.2 Non-goals (v0.1)

- Wallet-signing UX. Not in the onboarding flow; landed in a later spec.
- WalletConnect / Rainbow / Rabby deep-link integration.
- In-app wallet creation.
- Retiring the CLI-track `install.sh` path. This spec does not force any
  change on developer users.
- Automated model-selection based on hardware. Model chosen by SPEC-023
  autotune, unchanged.

## 2. What already exists (grounding)

- [SPEC-003 §FR-C9 v0.8](./SPEC-003-open-onboarding.md) — coordinator
  self-mint of `assigned_provider_token` on tokenless admission, with TOFU
  enforcement per FR-C9.4. This spec reuses that path and drops the
  GitHub-portal wrapper that fronts it today.
- [SPEC-015-receipts.md §12.1](./SPEC-015-receipts.md) — provider receipt
  key already an Ed25519 (`Curve25519.Signing.PrivateKey`) generated on
  first CLI launch, stored in the Keychain. This spec **reuses that key**
  as the provider identity key. One key, two purposes: identity and
  receipts.
- [SPEC-022-verified-model-settlement.md](./SPEC-022-verified-model-settlement.md)
  — settlement contract on Base already keys off provider receipt-key
  identity. No settlement-contract change needed.
- [SPEC-025-native-mac-app.md](./SPEC-025-native-mac-app.md) — this spec
  replaces §3.1 "First-run (cold install)" of SPEC-025 with the flow in §6.
- `phase3-binary/Sources/MacProviderCore/ProviderTokenPersist.swift:42-113`
  — atomic write of `provider_token` after mint. Reused as-is.
- `phase3-binary/app/Sources/Malibu/System/ProviderConfig.swift:63-99`
  — `saveProviderIdentity(providerID:token:)` remains the persistence
  entry point. Body unchanged.
- `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift:62-66` —
  CLI child launched with `MACPROVIDER_PROVIDER_TOKEN` env var. Unchanged.
- Landing page marketing copy at `/Users/augstar/projects/malibu/host/index.html`
  promises "One line in your terminal. … Your Mac picks up jobs whenever
  it's idle and online." This spec makes the App-track deliver on that
  promise without the terminal step.

## 3. Identity model — device Ed25519, anonymous now, wallet later

### 3.1 Key generation

On first launch of `Malibu.app`, `LaunchProviderController` (new class,
see §7) generates a fresh Ed25519 keypair via
`Curve25519.Signing.PrivateKey()`. The **32-byte raw representation** is
stored in the macOS Keychain with:

- `kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Service = bundle identifier
- Account = `provider_identity_v1`

The key never leaves the Keychain. All signatures are produced by loading
the private key inside `LaunchProviderController` and signing in-memory.

### 3.2 Reusing the receipt key

The SPEC-015 receipt-key generation path in the CLI-track (invoked when
the CLI comes up with no persisted receipt key) is **skipped** on the App
track. Instead, the App track exports the SPEC-026 provider identity key
to the CLI as an env-var-encoded raw key (`MACPROVIDER_RECEIPT_KEY_RAW`,
base64 of the 32-byte private key), which the CLI picks up on start and
uses as its receipt key.

Rationale: two separate keys would require two separate Keychain items,
two separate rotations, and would decouple provider identity from
settlement signature — which is exactly the coupling SPEC-022 requires.
One key, one Keychain slot, one rotation surface.

### 3.3 provider_id derivation

```
pubkey_bytes = Curve25519.Signing.PublicKey(privkey).rawRepresentation  // 32 bytes
digest        = SHA256(pubkey_bytes)                                     // 32 bytes
provider_id  = "p_" + base32(digest, alphabet=RFC4648-lowercase, no-pad)
```

The `p_` prefix disambiguates App-track providers from CLI-track providers
(which continue to use the coordinator-minted opaque provider_id shape).
It is not sensitive and appears on the success card as a short 8-char
display (`p_abcd1234`) with a "Copy full ID" affordance for support.

### 3.4 Why not Secure Enclave (SEP-P256)

SEP does not implement Ed25519 (only P-256). Using SEP would either force
a second key algorithm split from SPEC-015 receipts, or force us to rewrite
SPEC-015 to accept P-256 signatures. Both cost more than they buy — SEP
protection over a `ThisDeviceOnly` Ed25519 key improves the extraction
threat model by "requires jailbroken macOS + user password + Keychain
access" vs "requires jailbroken macOS + user password + Keychain access
+ physical SEP tampering". The marginal security gain does not justify
splitting the identity key from the receipt key.

App Attest evidence (§5.3) is attached opportunistically as a trust-score
input, but is not the sybil gate and is not required for registration to
succeed.

## 4. Coordinator API changes

Two new endpoints and one additive change to the WS `hello` frame. The
existing FR-C9 self-mint mechanism stays; this spec removes the GitHub
OAuth wrapper that currently front-ends it.

### 4.1 `POST /v1/providers/register`

```
Content-Type: application/json

{
  "provider_id":       "p_abcd…",             // §3.3 derived
  "identity_pubkey":   "<base64-32-byte-ed25519>",
  "hardware_summary":  { "chip": "M3 Max", "unified_memory_gb": 64,
                         "macos_version": "14.5", "app_version": "1.0.3" },
  "app_attest_object": "<base64 CBOR>" | null, // opportunistic; §5.3
  "nonce":             "<32-byte hex>",
  "ts_utc":            "2026-07-03T09:41:00Z",
  "signature":         "<base64-64-byte-ed25519>"
}
```

`signature` is Ed25519 over `JCS(body_without_signature)` (JCS
per RFC 8785). Coordinator MUST:

1. Verify `provider_id == "p_" + base32(sha256(identity_pubkey_bytes))`.
2. Verify Ed25519 signature under `identity_pubkey` over `JCS(body \ signature)`.
3. Reject `|now - ts_utc| > 60s` or a replayed `(provider_id, nonce)` pair.
4. Enforce **per-IP** and **per-ASN** rate limits: 5/min/IP, 30/min/ASN.
   Exceeding either returns `429` with `Retry-After`.
5. If `app_attest_object` is present, verify against Apple App Attest root
   and record `trust.attested = true`. Missing or invalid attestation is
   NOT a rejection — it means `trust.attested = false`.
6. Upsert into `provider_identities` keyed by `provider_id`. TOFU: if a
   row exists with a different `identity_pubkey`, reject `409 CONFLICT`.
7. Mint a `provider_token` via the existing FR-C9 self-mint path
   (`SPEC-003 §FR-C9`, `ProviderTokenPersist.swift:42-113`).
8. Respond:

   ```
   200 OK
   {
     "provider_id":         "p_abcd…",
     "provider_token":      "<opaque bearer>",
     "trust_tier":          "provisional",
     "trust":               { "attested": false,
                              "rate_limit_bucket": "new_ip" },
     "coordinator_ws_url":  "wss://coordinator.streamvc.live/v2/provider",
     "recommended_model":   { "id": "llama-3.3-70b-instruct",
                              "huggingface_repo": "…",
                              "sha256": "…" }
   }
   ```

`recommended_model` is populated by the SPEC-023 autotune subsystem based
on `hardware_summary`. Empty when no recommendation is available; the App
retries with a wider hardware envelope after 10s.

### 4.2 `POST /v1/providers/{provider_id}/payout-address`

```
Content-Type: application/json
Authorization: Bearer <provider_token>

{
  "wallet":       "0xABC…",       // EIP-55 checksummed
  "chain_id":     8453,           // Base
  "nonce":        "<32-byte hex>",
  "ts_utc":       "…",
  "signature":    "<base64-64-byte-ed25519>"
}
```

`signature` is Ed25519 (**provider identity key**) over
`JCS({provider_id, wallet, chain_id, nonce, ts_utc, coordinator_domain})`.
This is **not** a wallet signature — the wallet has no key material at
this point, only an address. The provider identity signature proves the
Mac agrees to bind its earnings to that wallet.

Coordinator MUST:

1. Verify bearer token belongs to `provider_id`.
2. Verify Ed25519 signature under the identity_pubkey stored at registration.
3. Enforce a **24-hour cooling window** for any subsequent re-bind of the
   same `provider_id`. First bind is immediate.
4. Write the binding to the settlement contract on Base as an
   `updatePayoutAddress(provider_id, wallet)` call.
5. Return the settlement tx hash so the App can display "payout wallet
   set on-chain" confirmation.

Un-bound `provider_id`s continue to accrue earnings in coordinator escrow.
`GET /v1/providers/{id}/earnings` reports both `accrued_escrow_usdc` and
`accrued_escrow_malibu`. On first bind, the settlement worker sweeps
escrow to the wallet on its next batch cycle (per SPEC-022 batching).

### 4.3 WS `hello` frame — additive field

The current SPEC-001 `hello` frame carries `Authorization: Bearer <provider_token>`.
No change to that field. This spec **adds** an optional field:

```
{
  "type": "hello",
  "provider_id": "p_…",
  "binary_version": "…",
  "identity_signature": "<base64-64-byte-ed25519>"   // NEW, optional
}
```

`identity_signature` is Ed25519 over
`JCS({auth_attempt_id, provider_id, binary_version, ecdh_pubkey})`, where
`auth_attempt_id` is echoed from the coordinator's `hello_challenge`. When
present, coordinator marks the session `identity_signed = true` and grants
elevated rate limits. When absent, coordinator falls back to bearer-only
auth (current behavior for CLI-track).

This lets us migrate off bearer auth over time without a hard fork.

### 4.4 Retire

The `portal.streamvc.live/onboard` GitHub OAuth flow is retired **for the
App track only** on the release that ships this spec's implementation.
CLI track continues to use it during migration. Portal deletion is out of
scope; portal maintainers should mark the endpoint deprecated in its
public docs.

## 5. Sybil resistance — layered, no single gate

No GitHub gate. No wallet gate. Sybil defense is a layered stack where no
single layer is load-bearing:

### 5.1 Provisional tier (default for every new provider)

| Constraint            | Provisional | Trusted     |
|-----------------------|-------------|-------------|
| Concurrent slots      | 1           | ≥ 4         |
| Daily $MALIBU emit cap| 25 MALIBU   | uncapped    |
| Payout delay          | 7 days      | 24 hours    |
| Rate limit tier       | strict      | normal      |
| Verified-receipt only | REQUIRED    | REQUIRED    |

Rate-limit strict means: `/register` per-IP 5/min, per-ASN 30/min; WS
sessions per provider_id 1; heartbeat interval floor 30s.

### 5.2 Trust unlock criteria (any two of)

1. ≥ 72h uptime with `heartbeat_gap < 5min` throughout
2. ≥ 100 settled receipts (SPEC-022 verified) with `receipt_verify_ok = true`
3. Payout wallet bound (§4.2) AND that wallet holds ≥ 50 USDC on Base
   (queried once, not continuously)
4. Valid App Attest evidence at registration (§5.3)
5. Manual operator promotion (support flow)

Unlock is one-way; downgrade requires abuse-signal detection (out of scope).

### 5.3 App Attest — opportunistic

App-track binary passes `DCAppAttestService.attestKey(_:clientDataHash:)`
result as `app_attest_object` in the `/register` body. Coordinator verifies
against Apple's App Attest CA root. Valid attestation:

- counts as one of §5.2's two unlock criteria
- bumps `/register` and heartbeat rate limits by 3×
- is displayed to buyers as a green "verified Mac hardware" chip

Invalid or missing attestation is NOT a rejection. Reason:
`DCAppAttestService` requires the app be signed by a paid Apple
Developer Program certificate and Apple's attestation service be
reachable. Either can fail transiently in ways that would otherwise block
100% of new providers. See §11 (biggest risk).

### 5.4 Verified-receipt-only earnings

Per SPEC-022, earnings only accrue from receipts that pass
`macprovider-verify`. This layer is not new; it already blocks the naive
"fake work" sybil vector. Called out here so the sybil-resistance stack
reads as an audit.

### 5.5 Behavioral risk score (future)

Placeholder for a later spec: track per-provider distributions of latency,
throughput, and receipt-verify pass rate; flag outliers for slower payout
release. Not required for this spec to ship.

## 6. User flow — click-and-earn

### 6.1 Cold install

1. User double-clicks `Malibu.app` from a downloaded `.dmg`.
2. Menu-bar icon appears. `AppDelegate.applicationDidFinishLaunching` fires.
3. `ProviderIdentity.isReady` returns `false` (no Keychain key yet).
4. `presentOnboarding()` opens the launch window (same NSWindow as today,
   new content — see §7.2).
5. Window contents:

   - Header: brand tile + "Malibu" small caps + "Launch your provider."
   - Sub: "One click and your Mac starts earning USDC + $MALIBU."
   - Optional field: payout wallet (`0x…`) with placeholder "Add later — you can set this anytime"
   - Primary button (coral): **Launch Provider**
   - Secondary link: "How does this work?"

6. User clicks **Launch Provider**. From this moment the button is
   replaced by an in-window progress ring + step label; the state machine
   in §7 owns the flow.
7. Steps happen in the background:

   a. Generate Ed25519 keypair → store in Keychain (~10ms)
   b. Call `POST /v1/providers/register` → receive `provider_token` and
      `recommended_model` (~1s over LAN)
   c. Persist `provider_id` + `provider_token` via existing
      `ProviderConfig.saveProviderIdentity(providerID:token:)`
   d. Download `macprovider-cli` binary if not bundled with `.app`
      (SPEC-025 bundles it, so this is a no-op in v1)
   e. Download model weights per `recommended_model`, resumable partial
      files under `~/Library/Application Support/Malibu/downloads/`
   f. Register SMAppService login item
   g. Start `MalibuAgent` (existing code, unchanged) which spawns CLI child
   h. Wait for first `.serving` control-socket frame
   i. Show success card

8. Success card, in the same window:

   - Big check + "Provider live"
   - Model chip: `llama-3.3-70b-instruct`
   - Two live counters (USDC today, MALIBU today) — animated from 0
   - Payout status row: `Payout wallet: not set — Add wallet` (link opens
     inline wallet field) OR `Payout wallet: 0x…abcd` with change link
   - Trust tier row: `Provisional — earn up to 25 MALIBU/day. Unlock
     Trusted →` (link opens `docs/trust-tiers` in the App, not a
     browser tab)
   - Primary button: "Open Dashboard"
   - Secondary: "Close" (window closes, menu bar keeps running)

### 6.2 Steady state

Menu-bar icon shows live status per SPEC-025 §3.2. Onboarding window
does not auto-reopen unless the provider identity or config is invalidated
(uninstall + reinstall, or Keychain-item deletion detected).

### 6.3 Window closed mid-setup

Any close during steps 7a–7g cancels the window but not the underlying
Task. `LaunchProviderController` continues in the background. Reopening
via the menu bar's "Set up…" item rebinds the SwiftUI view to the same
controller and picks up mid-animation.

### 6.4 Errors

Any step failure sets the controller to `.failed(stage, retryable, message)`.
Window shows:

- Red icon + human copy for the failure (e.g. "Couldn't reach the
  marketplace. Check your connection.")
- **Primary button: Retry** (retries from the failed stage, not from
  scratch)
- Secondary: "Contact support" (opens `mailto:` — no browser tab)

Non-retryable failures (Keychain unusable, disk full for model download)
surface with a "Quit" secondary instead of Retry.

### 6.5 Uninstall

SPEC-025 §3.4 uninstall flow additionally wipes:

- The `provider_identity_v1` Keychain item
- Any partial-download files under `Application Support/Malibu/downloads/`
- The onboarding state JSON at `Application Support/Malibu/onboarding.json`

Uninstall does NOT unbind the payout wallet. Prior earnings, if any,
settle to the bound wallet regardless of the Mac's fate. See §9.

## 7. Swift implementation

### 7.1 New module: `ProviderIdentity`

```swift
// phase3-binary/app/Sources/Malibu/System/ProviderIdentity.swift
enum ProviderIdentity {
    static func isReady() async -> Bool
    static func loadOrGenerate() async throws -> Curve25519.Signing.PrivateKey
    static func providerID(for key: Curve25519.Signing.PrivateKey) -> String
    static func sign(_ payload: Data, using key: Curve25519.Signing.PrivateKey) -> Data
    static func exportRawForCLI(_ key: Curve25519.Signing.PrivateKey) -> Data  // §3.2 env-var handoff
    static func deleteFromKeychain() async throws                              // uninstall
}
```

### 7.2 New controller: `LaunchProviderController`

```swift
// phase3-binary/app/Sources/Malibu/Onboarding/LaunchProviderController.swift
@MainActor
final class LaunchProviderController: ObservableObject {

    enum Stage: Equatable {
        case idle
        case identityReady
        case registering
        case downloadingCLI(progressPct: Double)   // no-op in v1
        case downloadingModel(name: String, progressPct: Double)
        case startingAgent
        case authenticating
        case live(model: String, tier: TrustTier)
        case failed(stage: String, retryable: Bool, message: String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published var walletDraft: String = ""

    func launch() async     // fires the state machine; safe to re-invoke
    func retry() async      // retries from last-failed stage
    func setPayoutWallet(_ address: String) async throws
}
```

Persist non-secret state at `~/Library/Application Support/Malibu/onboarding.json`.
Rehydrate on `init`. See §7.5 for the schema.

### 7.3 Delete: `PendingLinkState`, `URLSchemeHandler.malibu`

Remove `phase3-binary/app/Sources/Malibu/System/PendingLinkState.swift`
entirely. Its purpose (deep-link nonce validation for the browser
callback) is obsolete. Remove the `application(_:open:)` `malibu://`
handler in `MalibuApp.swift:37-45` and the `.consume(.providerLinked)`
branch in `:107-125`.

### 7.4 Rename: "node" → "provider"

Grep and replace across the App-track sources. Notable strings:

- `MalibuAgent.swift:48` — "Not linked yet. Open Set up… and link your node."
  → "Not set up yet. Click Launch Provider to activate."
- `PendingLinkState.swift:60` — "This Mac is already linked to a node."
  (file deleted; no replacement needed)
- Any `MenuBarController` copy — "node status" → "provider status"
- Any `DashboardView` copy — same

### 7.5 Onboarding state persistence

```json
{
  "provider_id": "p_abcd…",
  "created_at":  "2026-07-03T09:41:00Z",
  "last_stage":  "downloadingModel",
  "model_download": {
    "model_id": "llama-3.3-70b-instruct",
    "target_url": "https://…",
    "target_sha256": "…",
    "partial_bytes": 12345678
  }
}
```

File mode 0600. Never contains the private key or bearer token — those
live in Keychain (which handles encryption + ACL).

### 7.6 `MalibuAgent.start()` change

Replace the `guard await ProviderConfig.isConfigured` short-circuit at
`MalibuAgent.swift:46-50` with `guard await ProviderIdentity.isReady()`.
The rest of `start()` — `MACPROVIDER_PROVIDER_TOKEN` env-var injection,
CLI spawn, control socket — is unchanged. Additionally, inject
`MACPROVIDER_RECEIPT_KEY_RAW` (§3.2) alongside the existing token.

## 8. Migration & feature flag

The full SPEC-026 flow ships behind a single flag readable at App launch:

```
MALIBU_ONBOARD_V2=1     // env var (dev), OR
UserDefaults key "onboardingFlow" = "v2"
```

- When flag is **off**, the existing SPEC-025 §3.1 browser-OAuth flow runs.
- When flag is **on**, this spec's flow runs.

Flag defaults to `off` in the release that lands the code. Flip to `on`
after the two coordinator endpoints (§4.1 + §4.2) are deployed and
green on the staging coordinator. Flip via a Sparkle update, not a
per-user setting.

Existing installs that already completed the browser OAuth are treated
as `.live` on next launch regardless of flag; their `provider_id` and
`provider_token` are already persisted and the CLI-track handoff still
works. No forced re-onboarding.

## 9. Recovery, reinstall, wallet swap

### 9.1 Fresh reinstall / Mac wipe

New Keychain → new Ed25519 keypair → new `provider_id` → fresh provisional
tier. Prior unclaimed earnings are lost UNLESS a payout wallet was bound
before the wipe. If bound, earnings settle to that wallet on the normal
SPEC-022 batch cycle regardless of the Mac's presence — they don't need
the Mac to be online.

This is a **feature**, not a bug. No seed phrase means no seed phrase to
lose. The "back up your identity" step every crypto app has is replaced by
"bind a wallet as soon as you're comfortable." That's the recovery path.

### 9.2 Multi-Mac, same wallet

Perfectly fine. Each Mac has its own `provider_id`; all can bind to the
same payout wallet. Coordinator sums escrow per-wallet at settle time.

### 9.3 Wallet swap

`POST /v1/providers/{id}/payout-address` with a new address requires:

1. Ed25519 identity signature over the new binding (as first bind)
2. First bind must be > 24h old (`cooling_window_hours`)
3. Not more than one swap per 30 days

Rate-limits above the swap floor return `429 Too Many Requests` with the
next allowed timestamp. This bounds the "coerce me to swap payout" attack
without preventing legitimate migration.

### 9.4 Lost payout wallet, no swap possible

Out of scope for v0.1. Support-ticket path only. A future spec may
introduce a challenge-response recovery for the case where the user still
has provider identity but has lost the wallet keys.

## 10. Backend deploy checklist (blocking gate for the App-side flag flip)

- [ ] `POST /v1/providers/register` deployed to staging; verified
      end-to-end signature + rate-limit behaviors.
- [ ] `POST /v1/providers/{id}/payout-address` deployed to staging; both
      first-bind and swap paths tested; settlement-contract `updatePayoutAddress`
      confirmed on Base testnet.
- [ ] FR-C9 self-mint TOFU path exercised via the new register endpoint
      (regression check: existing CLI-track providers still mint OK).
- [ ] App Attest verification path implemented with fallback to
      `trust.attested = false` on Apple-service outage.
- [ ] Rate limits observable via `/admin/metrics`:
      `provider_register_rate_limit_hits{scope="ip"}` and
      `..{scope="asn"}`.
- [ ] `provider_identities` schema migration deployed:
      `identity_pubkey BYTEA NOT NULL`, `attested BOOLEAN DEFAULT FALSE`,
      `first_seen_ts TIMESTAMPTZ NOT NULL`.

Only when every box is checked does the App-side ship with
`onboardingFlow = "v2"` as the default.

## 11. Biggest risk and mitigation

**Sybil farming for $MALIBU emissions.** Dropping the GitHub-gated identity
removes one abuse layer. Attacker economics: spin up N Macs (or N VMs
masquerading as Macs without App Attest), earn provisional 25 MALIBU/day
each for 7 days until first payout unlocks, cash out.

Mitigation stack, in effectiveness order:

1. **Provisional tier + 7-day payout delay** — attacker sees no cash for a
   week per identity. Makes the attack expensive up front.
2. **Verified-receipt-only earnings (SPEC-022)** — fake or synthesized
   work earns nothing. The most load-bearing anti-abuse layer.
3. **Per-IP / per-ASN register-endpoint rate limits** (§4.1 step 4). A
   VPS-farm on one ASN caps at 30/min shared across all providers.
4. **App Attest bump** (§5.3) — honest majority get 3× rate limits,
   attackers running unattested bundles are throttled.
5. **Behavioral risk score** (§5.5, future) — outlier providers get
   settlement release deferred beyond the 7-day floor.

Residual risk after this stack: acceptable given the buyer marketplace
already imposes an economic ceiling on how much $MALIBU a fake provider
can extract before settlement stops matching. Revisit when field data
shows a specific attack.

**Second-biggest risk: App Attest dependency.** Apple's attestation
service is an external dependency. If it goes down globally, honest
providers can still register (attestation is opportunistic, not required),
but they lose the trust-tier bump. Mitigation: log
`app_attest_service_error_rate` and alert on sustained > 5% error rate;
during outage, temporarily loosen the alternative unlock criteria in
§5.2 by 25%.

## 12. Acceptance criteria

- **AC-026-01.** Fresh install on a Mac with no prior Malibu state
  completes onboarding to `.live` in ≤ 3 minutes on a residential
  100 Mbps connection, with the model download counted.
- **AC-026-02.** No user-visible string during the fresh-install flow
  contains "node", "GitHub", "streamvc.live", "portal", or "sign in".
- **AC-026-03.** No browser tab, external app, or URL scheme handler is
  invoked during a successful fresh install.
- **AC-026-04.** Closing the onboarding window during `.downloadingModel`
  and reopening it via the menu bar continues from the byte offset it
  had reached, not from 0.
- **AC-026-05.** A second `POST /v1/providers/register` with the same
  `provider_id` but a different `identity_pubkey` returns 409 CONFLICT
  and does not overwrite the row.
- **AC-026-06.** A `POST /v1/providers/{id}/payout-address` swap within
  24 hours of first bind returns 429 with the next-allowed timestamp.
- **AC-026-07.** A settled receipt from an App-track provider passes
  the CLI-track's `macprovider-verify` command with no code change to
  `macprovider-verify`, confirming receipt-key reuse (§3.2) works
  end-to-end.
- **AC-026-08.** Deleting the `provider_identity_v1` Keychain item and
  relaunching the App produces a fresh `provider_id` (not the prior one),
  landing the user back at the launch screen.
- **AC-026-09.** With `MALIBU_ONBOARD_V2=0`, the app runs the current
  SPEC-025 §3.1 browser flow unchanged (byte-for-byte behavior parity).
- **AC-026-10.** Uninstall wipes the Keychain identity item and all
  onboarding artifacts under `Application Support/Malibu/`.

## 13. Open questions

- Should the App Attest attestation object be re-attested periodically
  (e.g. weekly) or only at `/register`? Only-at-register is cheaper and
  matches Apple's documented pattern.
- Trust-tier unlock timing: is 72h uptime + 100 verified receipts too
  strict for honest solo providers? Revisit after two weeks of field data.
- Whether to expose the "Trusted" trust chip to buyers before we have a
  material sample of attested providers. Landing this in a separate spec.
- Should we ship a "recovery bundle" export (private key wrapped by a
  user-chosen passphrase) to give power users a self-hosted seed backup?
  Explicit non-goal here; open for a follow-up spec.
