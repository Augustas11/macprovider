# SPEC-003 — Open Onboarding: Distribution, Lifecycle & Onboarding UX

**Version:** 0.3 (2026-05-28, redistributed from v0.1)
**Depends on:** SPEC-001 v1.2.1, SPEC-002 v1.1.1

**Restructure note (v0.2).** SPEC-003 v0.1 contained four parts in a
single document. v0.2 redistributes them to avoid cross-spec drift:
- **Part A** (WS-tunneled inference wire protocol) → SPEC-001 v1.2.1 § 6.6
- **Part B** (dynamic admission + routing weight) → SPEC-002 v1.1.1
  § 3/§ 5/§ 7.1/§ 7.5
- **Part C** (distribution + lifecycle) → this document (SPEC-003 v0.2 § 4)
- **Part D** (onboarding UX) → this document (SPEC-003 v0.2 § 5)

SPEC-003 v0.2 also provides the **integration narrative** (§ 3) that
explains how SPEC-001 v1.2.1, SPEC-002 v1.1.1, and this spec compose into
the "stranger downloads and joins" experience.

**Change log v0.3:** Resolves audit findings C4, M4, M3, m1, m3.
- AC-1: restored `coordinator connection succeeds` as mandatory pass condition (C4 fix). Added AC-1a for degraded-mode install.
- § 7.3: fixed SPEC-001 clean-room cross-reference from § 8.2 to § 7.2 (M4 fix).
- OQ note: updated for v0.1 OQ-2 split between SPEC-001 OQ-5 (provider-side) and SPEC-002 OQ-10 (coordinator-side) (M3 fix).
- § 8 D8 reference: broadened to SPEC-002 v1.1.1 § 10 D8 + SPEC-001 v1.2.1 FR-30 (m1 fix).
- Added line-count justification note (m3 fix).

**Line-count note (v0.3).** v0.2 final length (752 lines) is below
the 1200-1500 target from the redistribution prompt. Justification:
Parts C (distribution) and D (onboarding) are genuinely smaller than
the WS protocol (Part A) and admission tier (Part B) content that
moved to SPEC-001 v1.2.1 § 6.6 and SPEC-002 v1.1.1 § 3/§ 5/§ 7. The
integration narrative in § 3 adds cross-spec context without inflating
to artificial length.

---

## 0. Operator-paste invocation block

```
Implement SPEC-003 (Parts C + D). The WS-tunneled inference protocol
is in SPEC-001 v1.2.1 § 6.6 and the dynamic admission is in SPEC-002
v1.1.1. This spec covers distribution, lifecycle, and onboarding UX.

As you work, maintain a running
phase5-onboarding/implementation-notes.html that captures anything I
should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Mission

The Mac Provider network works — two providers, two models, real
multi-model routing, ~2.5 s end-to-end inference. SPEC-001 v1.2.1 adds
WS-tunneled inference so providers need zero inbound network.
SPEC-002 v1.1.1 adds dynamic admission so the coordinator accepts
strangers automatically.

But these protocol and coordinator changes are invisible without a
**distribution layer**. A stranger reading a GitHub README still cannot
become a provider unless they:
- Build the binary from source (requires Xcode + Swift toolchain)
- Manually write a config file
- Know the coordinator URL
- Set up a launchd service for reboot survival

SPEC-003 makes Mac Provider a **downloadable product**. After SPEC-003
ships, the user experience for joining the network is:

```bash
curl -fsSL https://get.streamvc.live/install.sh | bash
```

One line. Zero operator action. Provider in the pool within 2 minutes
(excluding the multi-GB model download on first run).

Two parts make this work:

- **Part C — Distribution + lifecycle.** GitHub Releases, curl-pipe-bash
  install script at `get.streamvc.live`, `macprovider-cli update`
  subcommand, launchd plist for reboot survival, log rotation,
  coordinator-advertised version nudge.
- **Part D — Onboarding UX.** The README flow, `install.sh` prompts,
  first-run self-test, status check, uninstall.

Decision log Entry 18 (2026-05-28) is the direct rationale: "the
network works, the product doesn't yet exist."

---

## 2. Scope

### In scope (Parts C + D)

**Part C — Distribution + lifecycle:**
- GitHub Releases with tagged binaries, checksums, release notes
- `install.sh` at `get.streamvc.live`
- `macprovider-cli update` subcommand (self-update)
- `macprovider-cli status` subcommand (local + remote state)
- `macprovider-cli uninstall` subcommand (remove everything)
- launchd plist for reboot survival
- Log rotation
- Coordinator-advertised `recommended_binary_version` in `hello_ack`
  (see SPEC-001 v1.2.1 § 6.5)

**Part D — Onboarding UX:**
- README-driven setup flow
- `install.sh` interactive prompts (model selection, coordinator URL)
- First-run self-test with user-visible output
- `macprovider-cli status` for contributor self-diagnostics
- Graceful degradation on coordinator unavailability

### Companion specs (Parts A + B, shipped together with C + D)

- **SPEC-001 v1.2.1** — Part A: WS-tunneled inference wire protocol
  (§ 6.6 inference message types, FR-21 through FR-32, AC-11 through
  AC-15).
- **SPEC-002 v1.1.1** — Part B: Dynamic admission and WS-tunneled relay
  (three-tier admission, routing weight, provisional rate limits,
  operator endpoints, FR-P14 through FR-P21, AC-11 through AC-14).

All four parts MUST ship together because each fails without the
others: distribution without WS-tunneled inference still requires
Cloudflare tunnels; WS-tunneled inference without dynamic admission
still requires operator config changes; admission without distribution
still requires source builds.

### Out of scope

- **Antseed seller integration** — deferred to SPEC-007.
- **Smart router** — deferred to SPEC-004.
- **Rewards / billing** — deferred to SPEC-005.
- **Tier 2 attestation** — no privacy/attestation features.
- **Buyer-side privacy** — Tier 2 concern.
- **Changes to the buyer-facing HTTP API** — unchanged per SPEC-002
  v1.1.1 § 7.2.
- **Forcing pinned providers to migrate** — M4/M1 continue via
  existing tunnels per SPEC-001 v1.2.1 backward-compatibility statement.

---

## 3. Integration narrative

This section describes how SPEC-001 v1.2.1 (Part A), SPEC-002 v1.1.1
(Part B), and SPEC-003 v0.2 (Parts C + D) compose into the
"stranger downloads and joins" experience.

### End-to-end flow: stranger to serving provider

```
Stranger's Mac                    get.streamvc.live    GitHub Releases
      │                                  │                    │
      │  curl install.sh                 │                    │
      │──────────────────────────────>   │                    │
      │  <── install.sh ────────────────│                    │
      │                                                       │
      │  fetch latest release                                 │
      │──────────────────────────────────────────────────────>│
      │  <── macprovider-cli tarball + checksums ────────────│
      │                                                       │
      │  verify checksum                                      │
      │  extract to ~/.local/bin/                             │
      │  prompt: model selection (based on RAM)               │
      │  prompt: coordinator URL (default: streamvc.live)     │
      │  generate provider_id (UUID v4)                       │
      │  write ~/.config/macprovider/config.yaml              │
      │  optionally install launchd plist                     │
      │                                                       │
      │  macprovider-cli self-test                            │
      │  ├─ load model                                        │
      │  ├─ run inference (FR-20 self-test)                   │
      │  └─ connect to coordinator                            │
      │                                                       │
      │                           Coordinator                 │
      │  WSS hello ──────────────────────>│                   │
      │  (provider_id not in config)      │                   │
      │                                   │ SPEC-002 v1.1.1     │
      │                                   │ FR-P15: tier =    │
      │                                   │   provisional     │
      │                                   │ FR-P16: rate      │
      │                                   │   limit check     │
      │  <────── hello_ack ──────────────│                   │
      │  (tier: "provisional")            │                   │
      │                                   │                   │
      │  heartbeat (every 30s) ──────────>│                   │
      │                                   │                   │
      │              Buyer sends request  │                   │
      │                                   │ SPEC-002 v1.1.1     │
      │                                   │ § 3: mode =       │
      │                                   │   WS_TUNNELED     │
      │  <── inference_request ──────────│                   │
      │  (SPEC-001 v1.2.1 § 6.6)           │                   │
      │                                   │                   │
      │  inference_response_chunk ───────>│                   │
      │  inference_response_chunk ───────>│──> SSE to buyer   │
      │  inference_response_end ─────────>│──> [DONE]         │
      │                                   │                   │
      │  "You're serving inference!"      │                   │
```

### How the specs compose

| Step | Spec | Section |
|---|---|---|
| Download + install binary | SPEC-003 v0.2 | FR-C1 (releases), FR-C2 (install.sh) |
| Model selection | SPEC-003 v0.2 | FR-D2 |
| Config generation | SPEC-003 v0.2 | FR-C2 (install.sh) |
| launchd plist | SPEC-003 v0.2 | FR-C5 |
| Self-test inference | SPEC-001 v1.2.1 | FR-20 |
| WS hello + admission | SPEC-002 v1.1.1 | FR-P2, FR-P15, FR-P16 |
| WS-tunneled inference | SPEC-001 v1.2.1 | § 6.6, FR-21–FR-32 |
| Routing with tier weight | SPEC-002 v1.1.1 | § 5 (tier weight) |
| Self-update | SPEC-003 v0.2 | FR-C3 |
| Status check | SPEC-003 v0.2 | FR-C4 |
| Uninstall | SPEC-003 v0.2 | FR-C6 |

---

## 4. Functional requirements — Part C (Distribution + lifecycle)

**FR-C1. GitHub Releases.**
Each release of `macprovider-cli` is published as a GitHub Release on
the `macprovider-poc` repository (or a dedicated `macprovider-releases`
repo if the operator prefers to separate release artifacts from source).

Release shape:
- **Tag format:** `v{major}.{minor}.{patch}` (e.g., `v1.2.0`).
  Follows semantic versioning. The tag is created on the `main` branch.
- **Asset naming:** `macprovider-cli-{version}-{os}-{arch}.tar.gz`
  (e.g., `macprovider-cli-v1.2.0-darwin-arm64.tar.gz`). Only
  `darwin-arm64` is shipped in v1 (Apple Silicon only).
- **Checksums:** A `checksums.txt` file containing SHA-256 hashes for
  all assets, formatted as `{hash}  {filename}` (GNU coreutils style).
- **Release notes:** Markdown body with: version, date, summary of
  changes, breaking changes (if any), link to spec version this release
  implements.

**FR-C2. install.sh contract.**
The install script at `https://get.streamvc.live/install.sh` is the
primary distribution mechanism for new providers. It is a POSIX-
compatible shell script (no bashisms) that:

1. Detects the platform (`uname -s`, `uname -m`). Exits with error if
   not `Darwin` + `arm64`.
2. Checks for required tools: `curl`, `tar`, `shasum` (or `sha256sum`).
3. Fetches the latest release tag from the GitHub API
   (`GET /repos/{owner}/{repo}/releases/latest`).
4. Downloads the binary tarball and `checksums.txt`.
5. Verifies the SHA-256 checksum. Exits with error on mismatch.
6. Extracts the binary to `~/.local/bin/macprovider-cli` (creates
   directory if needed).
7. Adds `~/.local/bin` to `$PATH` in `~/.zshrc` (if not already
   present) with a comment marker: `# Added by macprovider-cli`.
8. Prompts the user for model selection (FR-D2).
9. Prompts for coordinator URL (default:
   `wss://coordinator.streamvc.live/ws/provider`).
10. Generates a stable `provider_id` (UUID v4, persisted to
    `~/.config/macprovider/provider_id`).
11. Writes `~/.config/macprovider/config.yaml` with the selected model,
    coordinator URL, and generated provider_id.
12. Optionally installs a launchd plist for reboot survival (FR-C5).
    User is prompted: "Install as a background service? [Y/n]"
13. Runs `macprovider-cli self-test` to verify the installation.
14. Prints a summary: binary version, model, coordinator URL,
    provider_id, and a "you're in the pool!" confirmation if the
    coordinator link succeeded.

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Platform not supported |
| 2 | Missing required tool |
| 3 | Download failed |
| 4 | Checksum mismatch |
| 5 | Extraction failed |
| 6 | Self-test failed |
| 7 | User aborted |

**Side effects (files written):**

| Path | Purpose |
|---|---|
| `~/.local/bin/macprovider-cli` | Binary |
| `~/.config/macprovider/config.yaml` | Configuration |
| `~/.config/macprovider/provider_id` | Stable identity |
| `~/Library/LaunchAgents/live.streamvc.macprovider.plist` | launchd plist (if opted in) |
| `~/.local/share/macprovider/logs/` | Log directory (created by binary on first run) |

**Environment variables (override defaults):**

| Variable | Effect |
|---|---|
| `MACPROVIDER_MODEL` | Skip model selection prompt |
| `MACPROVIDER_COORDINATOR_URL` | Skip coordinator URL prompt |
| `MACPROVIDER_INSTALL_DIR` | Override `~/.local/bin` |
| `MACPROVIDER_NO_LAUNCHD` | Skip launchd prompt (no plist) |
| `MACPROVIDER_NO_PROMPT` | Non-interactive mode (uses all defaults) |

**FR-C3. macprovider-cli update subcommand.**
`macprovider-cli update` performs an atomic self-update:

1. Queries the GitHub API for the latest release.
2. Compares the remote version to the running binary's version.
3. If newer: downloads the tarball and checksums, verifies checksum.
4. Extracts the new binary to a temporary path.
5. Runs `macprovider-cli self-test` with the new binary (sanity check
   before swap).
6. Atomically replaces the old binary with the new one (rename on same
   filesystem; if cross-filesystem, copy + rename + remove old).
7. If a launchd plist is installed, runs
   `launchctl bootout gui/$UID/live.streamvc.macprovider` then
   `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/live.streamvc.macprovider.plist`
   to restart the service with the new binary.
8. If no launchd plist, prints "Update complete. Restart macprovider-cli
   to use the new version."

If already at the latest version, prints "Already up to date
(v{version})" and exits 0.

`macprovider-cli update --check` performs only steps 1-2 and prints the
comparison without downloading.

**FR-C4. macprovider-cli status subcommand.**
`macprovider-cli status` displays local and remote state:

```
macprovider-cli v1.2.0

Local:
  Model:       mlx-community/Qwen2.5-7B-Instruct-4bit
  Status:      ready
  Uptime:      2h 34m
  Requests:    142 served, 0 errors
  RAM:         16 GB (M4)
  Context cap: 50,000 tokens

Coordinator:
  URL:         wss://coordinator.streamvc.live/ws/provider
  Connected:   yes (session abc-123)
  Tier:        provisional
  Pool models: Qwen2.5-7B (2 providers), Llama-3.2-3B (1 provider)

Update:
  Current:     v1.2.0
  Latest:      v1.2.1 (run 'macprovider-cli update' to upgrade)
```

Local state comes from the binary's in-process metrics (same data as
`GET /v1/health`). Coordinator state comes from the most recent
`hello_ack` and heartbeat exchange (SPEC-001 v1.2.1 § 6.5 `tier` field).
Update state comes from the GitHub API (cached for 1 hour to avoid rate
limits).

**FR-C5. launchd plist.**
The plist ensures `macprovider-cli` starts on login and restarts on
crash:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>live.streamvc.macprovider</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/.local/bin/macprovider-cli</string>
    <string>serve</string>
    <string>--config</string>
    <string>$HOME/.config/macprovider/config.yaml</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>$HOME/.local/share/macprovider/logs/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/.local/share/macprovider/logs/stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
```

Notes:
- `$HOME` is expanded at install time by `install.sh`, not by launchd.
  The plist contains literal absolute paths.
- `KeepAlive.SuccessfulExit = false` means launchd restarts the binary
  only on crash (non-zero exit), not on clean SIGTERM shutdown.
- `ThrottleInterval = 10` prevents restart storms.
- `ProcessType = Background` reduces scheduling priority and power impact.
- Log rotation is handled by the binary (FR-C8), not launchd.

**FR-C6. macprovider-cli uninstall subcommand.**
`macprovider-cli uninstall` removes all installed artifacts:

1. If launchd plist exists: `launchctl bootout
   gui/$UID/live.streamvc.macprovider` (stop the service).
2. Remove `~/Library/LaunchAgents/live.streamvc.macprovider.plist`.
3. Remove `~/.local/bin/macprovider-cli`.
4. Prompt: "Remove configuration and logs? [y/N]"
   - If yes: remove `~/.config/macprovider/` and
     `~/.local/share/macprovider/`.
   - If no: keep config and logs (allows re-install with same identity).
5. Remove the `PATH` addition from `~/.zshrc` (the line with the
   `# Added by macprovider-cli` marker).
6. Print "macprovider-cli has been uninstalled."

**FR-C7. Coordinator-advertised version nudge.**
The `hello_ack` message includes an optional `recommended_binary_version`
field (SPEC-001 v1.2.1 § 6.5). If the provider's `binary_version` is
older, the provider logs a warning: "A newer version is available
(vX.Y.Z). Run 'macprovider-cli update' to upgrade."

The coordinator does NOT enforce the version — providers running older
binaries continue to function. Enforcement is deferred (see SPEC-002
v1.1.1 OQ-7). The field is configured in `coordinator.yaml`
(`versions.recommended_binary_version`).

**FR-C8. Log rotation.**
The binary's log files (`stdout.log`, `stderr.log`) are rotated on
startup:
1. If a log file exceeds 50 MB, rename it to `{name}.1.log`.
2. If `{name}.1.log` already exists, delete it first (keep only one
   rotated file).
3. Open a fresh log file.

This provides simple 2-file rotation (~100 MB max disk usage for logs).

---

## 5. Functional requirements — Part D (Onboarding UX)

**FR-D1. README-driven setup flow.**
The project README includes a "Join the Network" section:

```markdown
## Join the Network

Run this on any Apple Silicon Mac (M1 or newer, macOS 14+):

\`\`\`bash
curl -fsSL https://get.streamvc.live/install.sh | bash
\`\`\`

The installer will:
1. Download the latest macprovider-cli binary
2. Ask you to choose a model (based on your Mac's RAM)
3. Connect you to the network
4. Optionally set up auto-start on login

**Requirements:**
- Apple Silicon Mac (M1, M2, M3, M4)
- macOS 14 (Sonoma) or later
- ~4-8 GB free disk space (for the model)
- Internet connection

**Check your status:**
\`\`\`bash
macprovider-cli status
\`\`\`

**Update:**
\`\`\`bash
macprovider-cli update
\`\`\`

**Uninstall:**
\`\`\`bash
macprovider-cli uninstall
\`\`\`
```

**FR-D2. install.sh model selection.**
The installer detects available RAM and presents appropriate model
options:

| RAM | Recommended models | Default |
|---|---|---|
| 8 GB | `mlx-community/Llama-3.2-3B-Instruct-4bit` (~2 GB) | Llama 3.2 3B |
| 16 GB | Llama 3.2 3B (~2 GB), `mlx-community/Qwen2.5-7B-Instruct-4bit` (~4 GB) | Qwen 2.5 7B |
| 24 GB+ | Llama 3.2 3B, Qwen 2.5 7B, `mlx-community/Qwen2.5-14B-Instruct-4bit` (~8 GB) | Qwen 2.5 14B |

The installer prints the model name, approximate download size, and
estimated context window. The user selects by number. If the model is
not already downloaded, the installer runs
`huggingface-cli download {model}` (or prints instructions if
`huggingface-cli` is not installed). Model download is the longest
step and is NOT included in the "2 minutes to pool" target.

**FR-D3. First-run self-test.**
On first run (or when invoked via `macprovider-cli self-test`), the
binary:
1. Loads the model (this is the slowest step).
2. Runs the SPEC-001 v1.2.1 FR-20 self-test (short inference, verify
   output).
3. Connects to the coordinator, sends `hello`, waits for `hello_ack`.
4. Prints results:
   ```
   Self-test results:
     Model loaded:     OK (mlx-community/Qwen2.5-7B-Instruct-4bit)
     Inference:        OK (18.3 tok/s)
     Coordinator:      OK (connected as provisional, session abc-123)
     Ready to serve!
   ```
5. If any step fails, prints the failure with a suggested fix:
   ```
   Self-test results:
     Model loaded:     OK
     Inference:        OK (18.3 tok/s)
     Coordinator:      FAILED - connection refused
       -> Check your internet connection
       -> Verify coordinator URL: wss://coordinator.streamvc.live/ws/provider
   ```

**FR-D4. Status check.**
See FR-C4 for the full `macprovider-cli status` output format. The
status subcommand is the primary diagnostic tool for contributors. It
answers: "Is my Mac serving? Am I in the pool? What tier am I?"

**FR-D5. Graceful degradation on coordinator unavailability.**
If the coordinator is unreachable (DNS failure, connection refused,
timeout), the binary:
1. Continues running the local HTTP server (for direct access if
   configured).
2. Logs a warning every 60 seconds: "Coordinator unreachable. Local
   server running. Retrying in {backoff}s."
3. Follows the existing reconnect-with-backoff logic (SPEC-001 v1.2.1
   FR-13).
4. Does NOT exit or stop serving. A contributor whose Mac is behind a
   temporary network outage should not need to manually restart.

---

## 6. Interface contracts

### 6.1. install.sh contract

Defined in FR-C2. Summary:

- **URL:** `https://get.streamvc.live/install.sh`
- **Hosting:** Cloudflare Pages (static site, free tier, global CDN).
  The `get.streamvc.live` subdomain is a CNAME pointing to Cloudflare
  Pages.
- **Arguments:** None (all configuration via interactive prompts or
  env vars).
- **Exit codes:** 0-7 (see FR-C2).
- **Side effects:** See FR-C2 file table.

### 6.2. macprovider-cli new subcommands

| Subcommand | Description | Requires running service |
|---|---|---|
| `serve` | Start the inference server (existing) | N/A (this IS the service) |
| `self-test` | Run model load + inference + coordinator check | No |
| `status` | Show local + remote state (FR-C4) | Yes (reads from running process) |
| `update` | Self-update to latest release (FR-C3) | No (stops service if needed) |
| `update --check` | Check for updates without downloading | No |
| `uninstall` | Remove all artifacts (FR-C6) | No (stops service if running) |

### 6.3. launchd plist schema

Defined in FR-C5. Key properties:

| Property | Value | Rationale |
|---|---|---|
| Label | `live.streamvc.macprovider` | Reverse-domain per Apple convention |
| RunAtLoad | true | Start on login |
| KeepAlive.SuccessfulExit | false | Restart on crash, not on clean stop |
| ThrottleInterval | 10 | Prevent crash-loop restart storms |
| ProcessType | Background | Reduce scheduling priority |

### 6.4. GitHub Releases shape

Defined in FR-C1. Summary:

| Property | Format | Example |
|---|---|---|
| Tag | `v{semver}` | `v1.2.0` |
| Asset | `macprovider-cli-{version}-{os}-{arch}.tar.gz` | `macprovider-cli-v1.2.0-darwin-arm64.tar.gz` |
| Checksums | `checksums.txt` (SHA-256, GNU format) | `a1b2c3...  macprovider-cli-v1.2.0-darwin-arm64.tar.gz` |
| Release notes | Markdown body | Version, date, changes, breaking changes, spec version |

---

## 7. Dependencies

### 7.1. Distribution dependencies

| Dependency | Purpose | License | Notes |
|---|---|---|---|
| GitHub API | Release discovery, download | N/A (public API) | No API key needed for public repos. Rate limit: 60 req/hr unauthenticated. `install.sh` makes 2 API calls; `update` makes 1-2. |
| Cloudflare Pages | Hosting `get.streamvc.live` | Free tier | Static site. Only serves `install.sh` and a landing page. |
| `huggingface-cli` | Model download | Apache-2.0 | NOT a hard dependency. `install.sh` prints manual download instructions if not installed. |
| `shasum` / `sha256sum` | Checksum verification | OS-provided | macOS ships `shasum` (BSD). Fallback to `openssl dgst -sha256` if neither found. |

### 7.2. Binary dependencies (no new additions)

No new Swift dependencies for Part C or Part D. The `update`
subcommand uses `URLSession` for HTTP (already available). The launchd
plist is a static file written by `install.sh`, not by the binary.

### 7.3. Clean-room hygiene

SPEC-003 v0.2 inherits the strict clean-room policy from SPEC-001
v1.2.1 § 7.2 and SPEC-002 v1.1.1 § 8.2. No d-inference source files were
read during spec writing. `cloudflared` is NOT a hard dependency for
SPEC-003 — WS-tunneled providers (SPEC-001 v1.2.1 § 6.6) need only
outbound WSS.

---

## 8. Phase 4 findings encoded in SPEC-003 v0.2

Findings D7-D10 are documented in SPEC-002 v1.1.1 § 10 (where they
belong, since they concern coordinator behavior). This section
cross-references them for completeness:

- **D7** (static config-map relaxed) → SPEC-002 v1.1.1 FR-P15, FR-P16,
  § 7.1 F-2 amendment, § 7.5
- **D8** (drain conflation) → SPEC-002 v1.1.1 § 10 D8 + SPEC-001 v1.2.1 FR-30
- **D9** (model_id case-sensitivity) → SPEC-002 v1.1.1 § 5
- **D10** (coordinator overhead) → SPEC-002 v1.1.1 FR-P14 validation
  method

---

## 9. Acceptance criteria

**AC-1 through AC-3 must ALL pass for SPEC-003 v0.2 to be considered
build-complete. Companion ACs in SPEC-001 v1.2.1 (AC-11 through AC-15)
and SPEC-002 v1.1.1 (AC-11 through AC-14) must also pass.**

---

**AC-1. install.sh from clean Mac.**

**Setup:** A Mac with no previous macprovider-cli installation. Model
already downloaded (to isolate install time from download time).

**Action:** `curl -fsSL https://get.streamvc.live/install.sh | bash`
(or local `bash install.sh` during testing).

**Expected:**
1. Binary installed to `~/.local/bin/macprovider-cli`.
2. Config written to `~/.config/macprovider/config.yaml`.
3. `provider_id` generated and persisted.
4. Self-test passes (model loads, inference works, coordinator
   connection succeeds).
5. Total time from script start to "Ready to serve!" message: <2
   minutes (excluding model download).

**How to verify:** Manual test on a clean user account.

---

**AC-1a. Degraded-mode install (diagnostic only — does NOT satisfy
build-complete).**

**Setup:** A Mac without internet access (or with coordinator
unreachable).

**Action:** `bash install.sh` with `MACPROVIDER_NO_PROMPT=1`.

**Expected:**
1. Binary installed, config written, provider_id generated.
2. Self-test: model loads and inference works.
3. Self-test: coordinator connection FAILS with a clear warning.
4. install.sh exits with code 6 (self-test failed) but prints:
   "Installed locally. Coordinator connection failed — provider will
   join the pool when internet is available."

**Note:** AC-1a is offered for diagnostic purposes. AC-1 (with
coordinator connection success) remains the build-complete gate.

**How to verify:** Manual test on isolated network.

---

**AC-2. macprovider-cli update.**

**Setup:** Install v1.2.0. Publish v1.2.1 to GitHub Releases.

**Action:** `macprovider-cli update`

**Expected:**
1. New version detected and downloaded.
2. Checksum verified.
3. Binary atomically swapped.
4. If launchd plist installed: service restarted with new binary.
5. `macprovider-cli --version` shows `1.2.1`.

**How to verify:** `phase5-onboarding/scripts/test-update.sh`

---

**AC-3. launchd plist reboot survival.**

**Setup:** Install macprovider-cli with launchd plist. Verify service
is running (`launchctl list | grep macprovider`).

**Action:** `sudo reboot` (or `launchctl bootout` + `launchctl
bootstrap` to simulate).

**Expected:**
1. After reboot, `macprovider-cli serve` is running automatically.
2. Provider reconnects to coordinator (visible in `/poolz`).
3. `macprovider-cli status` shows healthy state.

**How to verify:** Manual test.

---

## 10. Open questions

**OQ-1. Code signing strategy.**
Apple Developer ID signing ($99/yr) vs `xattr -d com.apple.quarantine`
workaround. SPEC-001 NFR-6 says "signed with Developer ID, not
notarized." For `install.sh` strangers, the xattr workaround is
acceptable in v1 (the script runs `xattr -d` after extraction).
Long-term, notarization is needed for a true "double-click to install"
experience.

**Current position:** v1.2 ships unsigned. `install.sh` runs
`xattr -d com.apple.quarantine` on the extracted binary. Document this
in the README with a note: "macOS may warn about an unidentified
developer. This is expected for the current release." Apple Developer
ID signing is a Phase 6+ concern.

**Note:** The remaining 6 OQs from SPEC-003 v0.1 have been
redistributed to the specs that own the questions:
- OQ-1 (WS frame size) → SPEC-001 v1.2.1 OQ-4
- OQ-2 (WS write buffer) → split: provider-side → SPEC-001 v1.2.1
  OQ-5; coordinator-side → SPEC-002 v1.1.1 OQ-10. The split reflects
  different tuning constraints for the two buffers.
- OQ-3 (tier visibility to buyers) → SPEC-002 v1.1.1 OQ-6
- OQ-4 (version enforcement) → SPEC-002 v1.1.1 OQ-7
- OQ-6 (promotion persistence) → SPEC-002 v1.1.1 OQ-8
- OQ-7 (provisional identity) → SPEC-002 v1.1.1 OQ-9

---

## 11. Build steps

SPEC-003 v0.2 implementation is split across three build prompts,
corresponding to the three spec updates that ship together:

| Build prompt | Spec | Scope |
|---|---|---|
| `BUILD_SPEC_001_V1_2_PROMPT.md` | SPEC-001 v1.2.1 | phase3-binary v1.2: WS inference handlers, hello endpoint_url, new subcommands (update, status, uninstall, self-test), log rotation |
| `BUILD_SPEC_002_V1_1_PROMPT.md` | SPEC-002 v1.1.1 | coordinator v0.2: WS-tunneled relay, admission tiers, provisional rate limits, new admin endpoints, tier-weighted routing, case-insensitive model match |
| `BUILD_SPEC_003_V0_2_PROMPT.md` | SPEC-003 v0.2 | install.sh, get.streamvc.live hosting, GitHub Releases automation |

These build prompts are authored separately by the operator after the
audit cycle completes.

---

## Appendix A — References

| Source | What was taken |
|---|---|
| `specs/SPEC-001-phase3-binary.md` v1.2.1 | Wire protocol (§ 6.5-6.6), FR-20 self-test, FR-13 reconnect backoff |
| `specs/SPEC-002-coordinator.md` v1.1.1 | Admission tiers (§ 7.5), hello_ack tier field, routing weight |
| `specs/SPEC-003-open-onboarding.md` v0.1 | Source for all Part C and Part D content (redistributed) |
| `beta/DECISION_CRITERIA.md` | Decision log Entry 18 (rationale for SPEC-003) |
| `HANDOFF.md` | Project context, roadmap, VPS details |
| OpenAI API reference | SSE streaming format referenced in integration narrative |

**Clean-room note:** No d-inference source files were read during spec
writing. Distribution and lifecycle design follows standard macOS CLI
patterns (Homebrew, Tailscale CLI, Fly.io CLI).
