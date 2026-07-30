# Provider Onboarding Audit — 2026-07-06

> **Update 2026-07-06:** `feat/malibu-cli-wrapper-only` removes App-track V2 onboarding.
> Malibu is now CLI-wrapper-only: `install.sh` for setup, launchd monitor for runtime.
> Items marked **V2-removed** below are no longer production paths.

Read-only audit of CLI-track vs App-track onboarding in current tree. Code is source of truth; memory items verified where noted.

---

## 1. Executive summary

- **Malibu is a CLI wrapper** (post-refactor): onboarding runs bundled `install.sh`; runtime monitors launchd-managed `macprovider-cli` via `/v1/health`. No in-app register/autotune/spawn-child path.
- **CLI-track** remains the authoritative install path (`install.sh` → LaunchAgent → watchdog).
- **V2 App-track removed** — former defects #1–3, #6, #10 are **V2-removed** (not production). See branch `feat/malibu-cli-wrapper-only`.
- **CLI `install.sh` targets `$HOME/macprovider/macprovider-cli`**, not `/tmp`. Operator plist at `/tmp/macprovider-v1.8.10-run/...` is not produced by current installer (`install.sh:18-20`, `1456-1458`).

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

## 3. Onboarding path B — Malibu wrapper (post-refactor)

Fresh Mac, launch `Malibu.app`:

| Step | Code | Artifacts | Notes |
|------|------|-----------|-------|
| 1. Startup route | `StartupState.route()` | config, marker, launchd manifest/plist | Healthy launchd → `.startAgent`; CLI config without marker → import dialog; else onboarding |
| 2. Migration (if CLI config, no marker) | `importExistingCLIConfig` | Token → Keychain; `.installed-by-app` marker | Same as before |
| 3. Onboarding | `LaunchProviderController.launchViaCLIInstall` | Runs bundled `install.sh` (`MACPROVIDER_NO_PROMPT=1`) | No V2 register/autotune UI |
| 4. Finalize | `finalizeInstall` | Login item + `monitorInstalledProviderIfPresent` | Waits for `/v1/health` |
| 5. Runtime | `MalibuAgent.start()` | Health poll only | **Does not spawn CLI child** |

**Removed (V2-removed):** identity generation, `POST /v1/providers/register`, in-app autotune, model download stage, control-socket child spawn, `resumeOnboarding` / `setupPaused` routes.

---

## 3b. Onboarding path B — App-track V2 (historical, removed)

<details>
<summary>Pre-refactor V2 path (reference only)</summary>

| Step | Code | Status |
|------|------|--------|
| V2 gate / setup paused | `isOnboardingV2Enabled`, `setupPaused` | **V2-removed** |
| Register / autotune / model download | `finishLaunch`, `resumePartialOnboarding` | **V2-removed** |
| Spawn CLI child | `MalibuAgent.start()` spawn path | **V2-removed** |

</details>

---

## 4. Overlap + priority map (post-refactor)

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

| # | Defect | Status |
|---|--------|--------|
| 1 | `serve_config: null` crashes Malibu JSON decode | **V2-removed** |
| 2 | V2 onboarding default-off / setup paused | **Fixed** — CLI install is only path |
| 3 | No identity recovery | **V2-removed** (identity path deferred to SPEC-026 P4) |
| 4 | No launchd coexistence / dual CLI | **Fixed** — monitor-only, no spawn |
| 5 | `/tmp` plist not from installer | Open (ops) |
| 6 | Model download stage is no-op | **V2-removed** |
| 7 | CLI uninstall leaves caches + Malibu state | Open |
| 8 | Malibu uninstall misses CLI launchd | Open |
| 9 | Adhoc CLI + launchd on macOS 26+ | Open |
| 10 | Autotune errors opaque | **V2-removed** |

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
