# Provider Onboarding Audit — 2026-07-06

Read-only audit of CLI-track vs App-track onboarding in current tree. Code is source of truth; memory items verified where noted.

---

## 1. Executive summary

- **Two parallel tracks** share `~/.config/macprovider/config.yaml` but diverge on identity (CLI: hostname `provider_id` + YAML token; App: Ed25519 `provider_identity_v1` + Keychain token + `.installed-by-app` marker). SPEC-026 v0.13 is authoritative for App onboarding; SPEC-025 v0.1 for wrapper/CLI-child model.
- **App-track V2 onboarding ships off by default** (`onboardingFlow=v2` or `MALIBU_ONBOARD_V2=1` required). Fresh installs see "Setup paused" unless the flag is set (`LaunchProviderController.swift:232-238`, `MalibuApp.swift:158-163`).
- **M5 32GB Tier C cannot complete Malibu autotune today** when CLI emits `"serve_config": null` — Malibu's decoder requires a non-null object and fails before donor-mode handling (`AutotuneRecommendationRunner.swift:251-247`, `AutotuneRecommend.swift:1150`).
- **CLI `install.sh` targets `$HOME/macprovider/macprovider-cli`**, not `/tmp`. Operator plist at `/tmp/macprovider-v1.8.10-run/...` is not produced by current installer (`install.sh:18-20`, `1456-1458`).
- **Malibu always spawns its own CLI child**; no adopt-mode, no launchd conflict detection in App code. Coexistence with launchd-managed CLI is accidental (different ports possible, same `provider_id`).

---

## 2. Onboarding path A — CLI-track

Fresh Mac, `curl https://get.streamvc.live/install.sh | bash`:

| Step | Code | Artifacts | Coordinator | Failure UX |
|------|------|-----------|-------------|------------|
| 1. Preflight | `install.sh:2526-2543` | — | — | Exit 1/6/7: wrong OS/arch/macOS, port busy (`ensure_port_free:251-297`) |
| 2. Model/provider prompts | `choose_model:746`, `choose_provider_id:804`, `choose_coordinator_url:829` | — | Optional `GET …/catalog/current` (`check_catalog_ram_metadata:630`) | Exit 7: invalid model/HF/RAM |
| 3. Download + verify | `download_release:977`, `verify_sha256:1051`, pkg Gatekeeper (`validate_package:1109`) | Temp staging dir | GitHub Releases API | Exit 3-5: download/checksum/sig failure |
| 4. Install binary | `install_binary:1341-1375` | Real: `$HOME/macprovider/macprovider-cli` + MLX bundles; symlink `~/.local/bin/macprovider-cli` | — | Exit 5 |
| 5. Write config | `write_config:1161-1181` | `~/.config/macprovider/config.yaml`, `provider_id` file; preserves existing `provider_token:` line | — | — |
| 6. Autotune | `run_autotune_recommend_apply:1246` | Updates config (model, artifact paths, `donor_mode`) | Catalog via CLI subprocess | Donor prompt or `SKIP_PROVIDER_START=1`; exit 6 |
| 7. LaunchAgent | `install_plist:1422-1447`, `render_plist:1449-1508` | `~/Library/LaunchAgents/live.streamvc.macprovider.plist`, logs under `~/Library/Logs/macprovider/` | — | Exit 5: launchctl bootstrap fail (AMFI on adhoc, macOS 26+) |
| 8. Watchdog | `install_watchdog:2220-2246` | `~/.local/share/macprovider-watchdog/`, second plist | — | Same |
| 9. Manifest | `write_install_manifest:2249` | `~/Library/Application Support/macprovider/install_manifest.json` | — | — |
| 10. Self-test | `wait_for_local_model:2386`, `wait_for_coordinator:2495` | — | `GET /v1/pool/check?provider_id=…` | Exit 6: timeout diagnostics (`print_local_self_test_diagnostics:2456`) |

**Token issuance:** Installer does not call `POST /v1/providers/register`. CLI connects via WebSocket; coordinator may return `assigned_provider_token` in hello/auth, persisted to YAML by `CoordinatorClient.adoptAssignedProviderTokenIfPresent` (`CoordinatorClient.swift:1298-1340`, `ProviderTokenPersist.swift`). Token stored in `config.yaml` (`provider_token:` line), not Keychain.

**Reboot:** LaunchAgent `RunAtLoad` + `KeepAlive` (`install.sh:1480-1486`) reloads binary at `$INSTALL_DIR/macprovider-cli` — survives reboot if plist path is durable (not `/tmp`).

---

## 3. Onboarding path B — App-track

Fresh Mac, launch `Malibu.app`:

| Step | Code | Artifacts | Coordinator | Failure UX |
|------|------|-----------|-------------|------------|
| 1. Startup route | `MalibuApp.handleStartup:112-114`, `StartupState.route:659-676` | Reads config, marker, Keychain, `onboarding.json` | — | `.setupPaused` alert if V2 off (`MalibuApp.swift:158-163`) |
| 2. Migration (if CLI config, no marker) | `showImportDialog` / `importExistingCLIConfig:276-344` | Token → Keychain `tech.malibu.provider/{provider_id}`; strips YAML token; writes `.installed-by-app` | — | Alert on import error |
| 3. V2 gate | `LaunchProviderController.launch:232-238` | — | — | `.failed(featureFlag)`: "App-track onboarding is not enabled" |
| 4. Identity | `loadOrGenerateIdentity:242`, `ProviderIdentity.swift:64-66` | Keychain `tech.malibu.app` / `provider_identity_v1` | — | Keychain errors → `.failed` |
| 5. Persist state | `saveState:245-252` | `~/Library/Application Support/Malibu/onboarding.json` (0600) | — | — |
| 6. Register | `registerProvider:256`, `RegisterClient.postRegister:158-181` | Config YAML (no token on disk), Keychain token | **`POST /v1/providers/register`** | HTTP error → `.failed(retryable)` |
| 7. Autotune | `finishLaunch` → `runAutotune:403`, `AutotuneRecommendationRunner.run:82-90` | Recommendation fields in config | Catalog via bundled CLI | JSON/decode/timeout → `.failed`; UI shows `error.localizedDescription` (`OnboardingWindow.swift:130-134`) |
| 8. Model download | `downloadModel:418` | **Stub:** returns `plan.state` (always nil in live deps `LaunchProviderController.swift:123`) | — | Cosmetic progress only |
| 9. Login item | `registerLoginItem:427`, `AppLoginItem.swift:10-11` | `SMAppService.mainApp` | — | Throws → `.failed` |
| 10. Start agent | `startAgent:429`, `MalibuAgent.start:53-134` | Spawns bundled CLI with `--ctl-socket-path …/agent.sock`, `--managed-by malibu-app`, token via env | WS auth + identity signature | "Not set up yet" / control socket timeout / CLI exit |
| 11. Live | `waitForFirstServing:432`, `updateState:433` | Sets `first_serving_at` in onboarding.json | — | Timeout: "Timed out waiting for the first serving frame." |

**State machine:** `Stage` enum `LaunchProviderController.swift:19-30`. **Resume:** `ResumePoint` + `lastStage` in onboarding.json (`307-340`). Crash mid-stage: resume from persisted `lastStage`; identity re-used via `loadOrGenerateIdentity` / `loadExistingIdentity` (`342-370`). **Not recovered:** missing Keychain identity when `isConfigured` still true (see §5).

**V2 flag checks:** `LaunchProviderController.isOnboardingV2Enabled` (`157-173`); `StartupState.detect` (`655`); `StartupState.route` (`675`); `applyMigrationDecision` (`696`). Default **off** unless env or `UserDefaults onboardingFlow=v2`. SPEC-026 v0.12: fresh flag-off shows setup-paused, not browser OAuth.

**Reboot:** `SMAppService` re-launches app → `.startAgent` if configured → `MalibuAgent.start()` spawns new CLI child. No launchd plist in App track.

---

## 4. Overlap + priority map

| Artifact | CLI-track | App-track | Source of truth |
|----------|-----------|-----------|-----------------|
| `~/.config/macprovider/config.yaml` | Writes model, port, `provider_id`, **`provider_token` on disk** | Writes `provider_id`, coordinator URL, autotune fields; **token in Keychain only** | Shared file; App requires `.installed-by-app` marker (`ProviderConfig.swift:22-32`) |
| `~/Library/Application Support/Malibu/.installed-by-app` | — | Created on App save/import | App ownership gate |
| `~/Library/Application Support/Malibu/onboarding.json` | — | V2 state machine | App-only |
| Keychain `tech.malibu.provider/{provider_id}` | — (import migrates CLI token here) | Bearer token | App track; CLI reads YAML/env |
| Keychain `tech.malibu.app` / `provider_identity_v1` | — | Ed25519 identity | App-only (SPEC-026 §3.1) |
| LaunchAgent `live.streamvc.macprovider` | `install.sh` | **Not used** (SPEC-025: SMAppService instead) | Independent |
| Control socket `…/Malibu/agent.sock` | Not set by launchd plist | Malibu child only (`CLIChildProcess.swift:57-61`) | App child path only |

**SPEC vs code:** SPEC-026 v0.13 makes App-track register + Keychain authoritative for new providers. SPEC-025 v0.1 §12 describes conflict detection — **`ProviderConflictDetector` exists in CLI** (`ProviderConflictDetector.swift`) but **Malibu app does not invoke it** on startup.

**CLI child ownership:** `MalibuAgent.start:56` guards `child == nil` then always spawns (`92-125`). No probe/adopt of existing socket. Launchd CLI uses default serve args (no `--ctl-socket-path` in `render_plist:1468-1478`) — **no socket collision**, but **two CLI processes** can run (Malibu picks free HTTP port via `FreePortProbe`, `MalibuAgent.swift:90`).

**Inconsistent states:** (1) CLI launchd + Malibu both running same `provider_id`. (2) `isConfigured` true, identity Keychain empty — reachable via `startConfiguredAgent` after manual identity delete (`launch:214-221`, `282-297`). (3) `first_serving_at` set + empty identity — same path; onboarding.json retained while identity gone. (4) Import CLI config without generating identity — serves but `handleIdentitySignatureRequest` fails (`MalibuAgent.swift:391-421`). (5) Partial uninstall residue (`wipeAppOwnedState:466-488`) leaves config/Keychain fragments.

---

## 5. UX defect list (code-evidence only)

| # | Defect | Symptom | Evidence | Sev | Fix |
|---|--------|---------|----------|-----|-----|
| 1 | `serve_config: null` crashes Malibu JSON decode | Autotune spinner → "Needs retry" with opaque error; M5 32GB Tier C donor-only | `AutotuneRecommend.swift:1150`; `AutotuneServeConfigPayload` non-optional `AutotuneRecommendationRunner.swift:251-247`; no donor branch in `finishLaunch` | **Blocker** | M — nullable decode + donor UX like `install.sh:1274-1295` |
| 2 | V2 onboarding default-off | Fresh Malibu install: "Setup paused", no earn path | `LaunchProviderController.swift:172`; `StartupState.route:675` | **Blocker** (product) | S — default `v2` in release build |
| 3 | No identity recovery | Keychain identity missing but config OK: app shows "live"/serving; coordinator identity auth fails silently | `startConfiguredAgent:282-297`; `handleIdentitySignatureRequest:415-421`; no regen UI | **High** | M — detect `!ProviderIdentity.isReady()` + re-register flow |
| 4 | No launchd coexistence handling | launchd CLI running + Malibu open → second CLI, duplicate provider, RAM waste | No `ProviderConflictDetector` in app; `MalibuAgent.start:56`; SPEC-025 §12 unimplemented | **High** | L — adopt-mode or conflict dialog |
| 5 | `/tmp` plist not from installer | Reboot kills provider if plist manually points at `/tmp` | `install.sh:1458` uses `$INSTALL_DIR`; operator plist is out-of-tree | **High** (ops) | S — reinstall via install.sh |
| 6 | Model download stage is no-op | "Preparing recommended" with fake progress | `Dependencies.downloadModel:123` returns `plan.state` | **Medium** | M — wire HF download or skip stage |
| 7 | CLI uninstall leaves caches + Malibu state | HF cache, `~/.config/macprovider/`, Malibu App Support untouched | `uninstall.sh:112-113`, `185-188`; no Malibu paths | **Medium** | M — cross-track cleanup docs/UI |
| 8 | Malibu uninstall misses CLI launchd | CLI LaunchAgent keeps running after "Quit and Uninstall" | `wipeAppOwnedState:466-488` — App Support only | **Medium** | M |
| 9 | Adhoc CLI + launchd on macOS 26+ | `launchctl bootstrap` fails | `install_plist:1445`; pkg path validates Gatekeeper (`1112`) | **High** on unsigned | S — require signed pkg path |
| 10 | Autotune errors opaque | `.failed` shows `localizedDescription`; `AutotuneRecommendationError` has no messages | `LaunchProviderController.swift:262`; `AutotuneRecommendationError:212-216` | **Low** | S |

**Verified:** Backup `Malibu.app.bak-*` is Developer ID + notarized (Superposition YF7XNRJUG4), stapled — enrollment blocker memory superseded.

---

## 6. Adopt-mode design compatibility

**Protocol:** Control socket accepts multiple same-EUID clients concurrently (`ControlSocket.swift:539-581`, backlog 128). Malibu `ControlSocketClient` is a single-connection client — adopt-mode = connect without spawning, no protocol change required.

**Identity handoff:** `identity_signature_request` is pushed to control-socket clients; Malibu signs via `ProviderIdentity.loadExisting()` (`MalibuAgent.swift:302-311`, `373-422`). If CLI was started by **launchd without `--managed-by malibu-app`**, token persists to YAML (`CoordinatorClient.swift:1314-1321`); identity bridge may still fire if warm-swap enabled — but launchd plist **does not pass `--enable-warm-swap`**, so **no control socket on launchd CLI today**. Adopt would require launchd CLI to open same socket path.

**Shutdown:** `MalibuAgent.shutdown:152-168` sends `shutdown_request` and `child?.stop()` — assumes ownership. Adopted CLI: shutdown would **kill a process Malibu didn't spawn**; must gate `stop()` on ownership flag. `markStopping`/`isStopping` only cover spawned child (`CLIChildProcess.swift:35-35`).

**SPEC-025 §5.2:** Spec contemplates conflict detect + migrate (`SPEC-025-native-mac-app.md:321`); additive frames already include `identity_signature_*`. Adopt-mode fits; missing pieces are ownership tracking and launchd plist alignment (`--ctl-socket-path`, `--enable-warm-swap`).

---

## 7. Open questions

1. **Production Malibu build:** Is `onboardingFlow=v2` baked into release `UserDefaults` or only dev manual `defaults write`? Not found in `project.yml`.
2. **Coordinator behavior** when two CLIs connect with same `provider_id` — not fully traceable from phase3-binary alone.
3. **Operator `/tmp` plist origin** — likely manual/dev run, not `install.sh`; label `v1810` vs fixed `live.streamvc.macprovider` in script (`install.sh:26`).
4. **Wallet / USDC earn path** post-onboarding — `setPayoutWallet` throws SPEC-027 stub (`LaunchProviderController.swift:277-279`); earning requires separate wallet flow not audited here.

---

*Word count: ~1,450. All line refs relative to repo root `macprovider-poc`.*
