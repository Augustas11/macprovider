# SPEC-003 — Open Onboarding: Distribution, Lifecycle & Onboarding UX

**Version:** 0.8.2 (2026-06-11, post-re-audit hardening: TOCTOU-safe TOFU + await persist + prune safety)
**Depends on:** SPEC-001 v1.3.1, SPEC-002 v1.3.5

**Change log v0.6:** Resolves cross-spec findings F-603-1 and F-603-2 from `specs/SPEC-CROSS-006-audit.md`: the installer visibility self-test now references SPEC-002 v1.1.4's coordinator-owned `GET /v1/pool/check`, and dependencies align to SPEC-001 v1.2.2 + SPEC-002 v1.1.4.

**Change log v0.7:** Resolves six v1.2.4 partner-upgrade follow-ups from Decision log Entry 22, building on the Entry 20 install.sh bug class: F-603-V7-1 existing config port detection, F-603-V7-2 own-service port holder stop, F-603-V7-4 real binary path in launchd plist for Swift Bundle resolution, F-603-V7-5 cold-cache 20-minute wait, F-603-V7-6 diagnostic self-test timeout messaging, and F-603-V7-7 mixed-state install-dir warning. F-603-V7-3 and F-603-V7-8 were retracted and are not part of v0.7.

**Change log v0.8:** Closes Open Q2 from Decision log Entry 59 (provider-token issuance model for open onboarding). v0.8 picks self-serve provisional token minting and adds the normative contract under § 4 as **FR-C9**. The coordinator MINTs a fresh `provider_token` on every tokenless provisional admission and returns it in both the v1 `hello_ack` and v2 `auth_response` (initial-stage acceptance) frames under a new OPTIONAL field `assigned_provider_token`. The phase3-binary MUST persist the returned token to its on-disk config under the existing top-level `provider_token` YAML key with file mode 0600 via atomic-rename. Pinned-tier token issuance (Entry 59 / M1-1) is unchanged — operator-issued via `coordinator-cli issue-token`. Dependencies bump to SPEC-001 v1.3.1 (M1-1 Bearer-on-WS-connect plumbing) and SPEC-002 v1.3.5 (locked, no coordinator-side schema change required). See Decision log Entry 60 for the full ruling and the rationale for dual-path delivery (the binary's default first frame is v1 `hello`, not v2 `auth_request`, so the v1 `hello_ack` path is the primary delivery channel for the actual target population — provisional strangers).

**Change log v0.8.2:** Post-re-audit hardening from the codex security-reviewer focused pass on commit 4b1c527 in PR #44. **(a)** FR-C9.4 TOFU enforcement moved from a SELECT-then-INSERT pattern (TOCTOU-vulnerable: two concurrent tokenless connects for the same `provider_id` could both pass the gate before either committed) to a DB-layer partial unique index `idx_provider_tokens_one_active_per_provider ON provider_tokens(provider_id) WHERE revoked_at IS NULL`. `IssueToken` now returns `ErrActiveTokenAlreadyExists` on constraint violation; `resolveProvisionalToken` maps that to the TOFU close path. The migration step revokes pre-existing duplicate active rows so the index can be installed on existing databases. **(b)** FR-C9.3 binary-side persist now AWAITs disk I/O completion before in-memory adoption, closing the v0.8.1 brick-mode where a process crash between in-memory adoption and persist flush would strand the token coordinator-side and TOFU-reject the binary on next restart. The await runs on a detached priority-utility Task so the actor suspends but the runtime doesn't, preserving the FR-C9.3 SHOULD-not-block intent. **(c)** `coordinator-cli prune-tokens` refuses cutoffs younger than 24h without `--force`, and the dry-run output now lists candidate `provider_id` + `token_prefix` + `created_at` so the operator can sanity-check before `--apply` (a self-minted token is `last_used_at IS NULL` until the binary reconnects with Bearer, which can be seconds out — naive cutoffs can brick providers mid-onboarding). **(d)** SPEC-003 prose contradictions cleaned: v0.8.1 still contained pre-TOFU "multi-mint by design" passages in FR-C9.1 + FR-C9.4 prose; v0.8.2 rewrites these to match the TOFU contract.

**Change log v0.8.1:** Post-merge audit hardening from three codex auditors (code-reviewer / security-reviewer / architect) on the v0.8 implementation in PR #44. **(a)** FR-C9.4 rewritten from "multi-mint on tokenless reconnect" to **TOFU (trust-on-first-use)**: once an unrevoked token exists for a `provider_id`, the coordinator MUST refuse tokenless admission with `CloseInvalidToken / "invalid_token"`. This closes the security-MAJOR credential-capture exploit where an attacker could declare a victim's `provider_id` on a tokenless connect and harvest a valid bearer for it. Persist-failure self-healing is now an operator-action (revoke + retry), not an automatic re-mint. **(b)** FR-C9.3 binary-side persist relaxed from "MUST NOT block the WS receive loop" by moving from a strict prohibition to a "SHOULD offload" with the implementation using a detached Task. The previous inline implementation violated the contract. **(c)** Config key contract clarified everywhere: the binary writes the **top-level** YAML key `provider_token`, not `auth.provider_token`. Prior prose in v0.8 referenced the nested path; SPEC-001 and the actual `ConfigLoader` use flat. **(d)** Normative interaction with SPEC-002 v1.3.5 FR-P12 / PG-1 spelled out: SPEC-003 v0.8 supersedes those locked clauses for tokenless provisional admission under `require_provider_tokens=true`. **(e)** Operator-side prune is now normative: `coordinator-cli prune-tokens [--apply]` removes never-used unrevoked tokens older than the supplied cutoff. **(f)** Coordinator-side adds a separate `TokenIssuer` interface alongside `TokenValidator` (interface segregation per architect MINOR-2).

**Restructure note (v0.2).** SPEC-003 v0.1 contained four parts in a
single document. v0.2 redistributes them to avoid cross-spec drift:
- **Part A** (WS-tunneled inference wire protocol) → SPEC-001 v1.2.1 § 6.6
- **Part B** (dynamic admission + routing weight) → SPEC-002 v1.1.2
  § 3/§ 5/§ 7.1/§ 7.5
- **Part C** (distribution + lifecycle) → this document (SPEC-003 v0.2 § 4)
- **Part D** (onboarding UX) → this document (SPEC-003 v0.2 § 5)

SPEC-003 v0.2 also provides the **integration narrative** (§ 3) that
explains how SPEC-001 v1.2.1, SPEC-002 v1.1.2, and this spec compose into
the "stranger downloads and joins" experience.

**Change log v0.3:** Resolves audit findings C4, M4, M3, m1, m3.
- AC-1: restored `coordinator connection succeeds` as mandatory pass condition (C4 fix). Added AC-1a for degraded-mode install.
- § 7.3: fixed SPEC-001 clean-room cross-reference from § 8.2 to § 7.2 (M4 fix).
- OQ note: updated for v0.1 OQ-2 split between SPEC-001 OQ-5 (provider-side) and SPEC-002 OQ-10 (coordinator-side) (M3 fix).
- § 8 D8 reference: broadened to SPEC-002 v1.1.2 § 10 D8 + SPEC-001 v1.2.1 FR-30 (m1 fix).
- Added line-count justification note (m3 fix).

**Change log v0.4:** Resolves round-2 audit finding MAJOR-2.2.
- § 2 and § 9: SPEC-002 companion AC range updated from "AC-11 through AC-14" to "AC-11 through AC-15" to include the nak routing-mode fallback test.
- Build-complete label updated to v0.4.

**Change log v0.5:** Resolves Day-3 distribution follow-ups from
Decision log Entry 20.
- § 5: local self-test failures in `install.sh` MUST print the first
  200 bytes of the raw `/v1/models` response, or the stderr path and
  last 200 stderr bytes when the endpoint returns nothing.
- § 4: distribution-channel decoupling is now explicit:
  `install.sh` is served from `main` via `get.streamvc.live` and is
  NOT bundled into the release tarball.
- § 10: new audit category requires integration tests, not code-review
  approval alone, for shell-script paths touching real OS resources.

**Line-count note (v0.3).** v0.2 final length (752 lines) is below
the 1200-1500 target from the redistribution prompt. Justification:
Parts C (distribution) and D (onboarding) are genuinely smaller than
the WS protocol (Part A) and admission tier (Part B) content that
moved to SPEC-001 v1.2.1 § 6.6 and SPEC-002 v1.1.2 § 3/§ 5/§ 7. The
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
SPEC-002 v1.1.2 adds dynamic admission so the coordinator accepts
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
- **SPEC-002 v1.1.2** — Part B: Dynamic admission and WS-tunneled relay
  (three-tier admission, routing weight, provisional rate limits,
  operator endpoints, FR-P14 through FR-P21, AC-11 through AC-15).

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

This section describes how SPEC-001 v1.2.1 (Part A), SPEC-002 v1.1.2
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
      │                                   │ SPEC-002 v1.1.2     │
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
      │                                   │ SPEC-002 v1.1.2     │
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
| WS hello + admission | SPEC-002 v1.1.2 | FR-P2, FR-P15, FR-P16 |
| WS-tunneled inference | SPEC-001 v1.2.1 | § 6.6, FR-21–FR-32 |
| Routing with tier weight | SPEC-002 v1.1.2 | § 5 (tier weight) |
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

**FR-C1a. Distribution channel decoupling.**
`install.sh` is served from `main` via the `get.streamvc.live` ->
`raw.githubusercontent.com/<owner>/<repo>/main/phase3-binary/dist/install.sh`
redirect. It is NOT bundled into the release tarball. This is an
intentional architecture property:

- Installer bugs (parse errors, sed quoting, environment-handling) can
  be fixed by a one-line commit to `main`; the next `curl ... | bash`
  carries the fix in seconds.
- Binary releases are tagged, signed, and immutable; an installer patch
  does not require re-running the GitHub Action or re-signing release
  artifacts.
- Strangers running `curl get.streamvc.live/install.sh | bash` always
  get the latest installer, but the installer fetches a specific signed
  binary release tag and verifies it.

The release tarball MUST NOT contain `install.sh`. Re-bundling it would
reintroduce the slow-iterate path and is explicitly out of scope.

**FR-C2. install.sh contract.**
The install script at `https://get.streamvc.live/install.sh` is the
primary distribution mechanism for new providers. It is a Bash script
that:

1. Detects the platform (`uname -s`, `uname -m`). Exits with error if
   not `Darwin` + `arm64`.
2. Checks for required tools: `curl`, `tar`, `shasum` (or `sha256sum`).
3. Fetches the latest release tag from the GitHub API
   (`GET /repos/{owner}/{repo}/releases/latest`).
4. Downloads the binary tarball and `checksums.txt`.
5. Verifies the SHA-256 checksum. Exits with error on mismatch.
6. Extracts the real binary and adjacent `.bundle` directories to `~/macprovider/`, then creates `~/.local/bin/macprovider-cli` as a symlink for PATH discoverability.
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
| `~/macprovider/macprovider-cli` | Real binary, adjacent to Swift/MLX `.bundle` directories |
| `~/.local/bin/macprovider-cli` | Symlink for PATH discoverability |
| `~/.config/macprovider/config.yaml` | Configuration |
| `~/.config/macprovider/provider_id` | Stable identity |
| `~/Library/LaunchAgents/live.streamvc.macprovider.plist` | launchd plist (if opted in) |
| `~/Library/Logs/macprovider/` | launchd stdout/stderr logs |

**Environment variables (override defaults):**

| Variable | Effect |
|---|---|
| `MACPROVIDER_MODEL` | Skip model selection prompt |
| `MACPROVIDER_COORDINATOR_URL` | Skip coordinator URL prompt |
| `MACPROVIDER_PORT` | Override local HTTP port; otherwise reuses existing config port when present, falling back to 8080 |
| `MACPROVIDER_INSTALL_DIR` | Override `~/macprovider` support directory |
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
    <string>$HOME/macprovider/macprovider-cli</string>
    <string>--port</string>
    <string>8080</string>
    <string>--model</string>
    <string>mlx-community/Qwen2.5-7B-Instruct-4bit</string>
    <string>--provider-id</string>
    <string>example-provider</string>
    <string>--coordinator</string>
    <string>wss://coordinator.streamvc.live/ws/provider</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/macprovider/macprovider.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/macprovider/macprovider.err.log</string>
  <key>WorkingDirectory</key>
  <string>$HOME/macprovider</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin</string>
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
- The plist invokes `$HOME/macprovider/macprovider-cli`, not the
  `~/.local/bin/macprovider-cli` symlink. The symlink remains for shell
  use, but launchd must use the real path so Swift Bundle resolution
  finds adjacent `.bundle` directories.
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

**FR-C9. Self-serve provisional provider token (closes Open Q2 / Entry 60).**
v0.8 closes the long-standing gate on flipping `auth.require_provider_tokens=true` with provisional strangers in the pool. Pinned-tier providers are operator-issued via `coordinator-cli issue-token` (M1-1, unchanged). Provisional providers self-mint on first admission.

**FR-C9.1. Coordinator MUST mint on first tokenless provisional admission, subject to the FR-C9.4 TOFU gate.**
When `prepareProviderAdmission` (`phase4-coordinator/internal/ws/server.go`) returns a non-pinned `*pool.Provider` AND `auth.validated == false` AND the token store is configured (`s.tokens != nil`), the coordinator MUST mint a fresh row in `provider_tokens` via `auth.Store.IssueToken(providerID, providerName)`, BUT only after the FR-C9.4 TOFU gate confirms no unrevoked token already exists for this `provider_id`. The mint MUST happen AFTER admission is approved and BEFORE the corresponding ack frame is written, so that ack-write failure does not leave the operator without a record that a token was promised. v0.8.1 specified the mint MUST NOT be conditional on prior rows (multi-mint by design); v0.8.2 narrows this to "MUST be conditional on FR-C9.4 TOFU" — see FR-C9.4 for the security rationale.

The minting backend MUST enforce the one-active-token-per-provider_id invariant at the database layer (a partial unique index on `provider_tokens(provider_id) WHERE revoked_at IS NULL` is the normative implementation; the v0.8.2 reference store in `phase4-coordinator/internal/auth/tokens.go` installs this index in `migrate()`). The `IssueToken` call MUST surface a constraint failure as a distinct sentinel error (`ErrActiveTokenAlreadyExists` in the reference implementation) so the caller can map it to the TOFU close path without leaking a generic 500 to the wire. This DB-layer enforcement closes the TOCTOU race the codex security re-audit on PR #44 (MAJOR-1) flagged in the v0.8.1 implementation, where two concurrent tokenless connects could both pass the `HasActiveTokenForProvider` check before either insert.

The `providerID` is the value declared in the `hello` or `auth_request` initial frame. The `providerName` is the value declared as `hostname` in the same frame; if `hostname` is empty (unreachable per existing `requireString` parsing, but defensive), the coordinator MAY synthesize a placeholder of the form `provisional:<provider_id>`.

When `auth.validated == true` (provider sent a Bearer that matched), or when admission is rejected, or when the token store is not configured, the coordinator MUST NOT mint and MUST NOT include the field in any ack frame.

**FR-C9.2. Ack frame contract — both v1 and v2.**
The minted token MUST be returned to the binary in BOTH ack frames under the field name `assigned_provider_token` (string, lowercase hex, 64 hex chars matching the existing `IssueToken` output format). The field is OPTIONAL (`omitempty`). Field placement:

- **v1 path:** `HelloAck` struct in `phase4-coordinator/internal/ws/messages.go` gains `AssignedProviderToken string \`json:"assigned_provider_token,omitempty"\``. The v1 path writes this on the existing `hello_ack` emission at `server.go:386`.
- **v2 path:** `AuthResponse` struct in the same file gains the same field. The v2 path writes this on the proof-stage-accepted `auth_response` emission at `server.go:624`. The v2 `auth_challenge` and any rejection-shaped `auth_response` MUST NOT carry the field.

Both ack writes happen AFTER `prepareProviderAdmission` and AFTER `releaseUnauth()`, on the path that also calls `s.tokens.MarkTokenUsed` for already-validated tokens. The mint hook is symmetric: same condition (`s.tokens != nil && !auth.validated`), same call shape, different surrounding struct.

**FR-C9.3. Binary MUST persist atomically with 0600 perms; persist SHOULD NOT block the WS receive loop.**
On receipt of an ack frame carrying `assigned_provider_token`, the phase3-binary MUST:

1. Write the token value to a temporary file in the same directory as the config file, with file mode 0600 set BEFORE writing the secret.
2. Atomically rename the temp file to the final config file path (`rename(2)` semantics — POSIX-atomic on same-filesystem renames).
3. Match a **top-level** YAML key only: `provider_token: <value>`. Indented `provider_token:` entries nested under a parent block (e.g. an `auth:` map) MUST be preserved verbatim; the persist routine owns only the top-level key. If multiple top-level `provider_token:` lines exist (from a prior botched write), ALL such lines MUST be collapsed to a single canonical entry with the new value.
4. **AWAIT the persist completion before adopting the token in memory.** The in-memory token MUST be updated ONLY after the rename(2) returns successfully. v0.8.2 hardening: v0.8.1 adopted in memory FIRST then fired a fire-and-forget persist; the codex security re-audit on PR #44 (MINOR-1) flagged the resulting brick window — a process crash between in-memory adoption and persist flush leaves the coordinator with a valid token row that the binary never persisted, and on next process restart the binary reconnects tokenless and TOFU-rejects. Awaiting closes the window: persist either succeeds (both sides have the token) or fails (neither side has it, current WS session continues with the pre-existing bearer).

The persist write SHOULD execute outside the WS receive loop synchronously (e.g. via `Task.detached(...).value` await) so disk I/O cannot stall the runtime even though the receive-handling actor suspends. The intent is "disk I/O does not block other actors / Tasks", not "disk I/O is fire-and-forget."

On persist failure (disk full, permission denied, parent directory missing) the binary MUST log a JSON-encoded structured-log line with `event=provider_token_persist_failed`, `error=<cause>`, `config_path=<resolved>`, continue serving the current WS session with the previously-configured bearer (or no bearer), and NOT crash. The JSON line MUST be encoded via a JSON encoder, not hand-built string interpolation, so embedded quotes/newlines/backslashes in the error description or path cannot break the JSON envelope.

The persist target is the top-level `provider_token` YAML key (already wired by M1-1 SPEC-001 v1.3.1 § config). If the config file already has a top-level token populated, the new one REPLACES it. Pre-v0.8.1 prose referenced `auth.provider_token` (nested); the correct contract is flat top-level.

**FR-C9.4. TOFU (trust-on-first-use): refuse a second token for a known provider_id.**
When a tokenless connect arrives for a `provider_id` that already has an unrevoked row in `provider_tokens`, the coordinator MUST refuse admission with close code `CloseInvalidToken / "invalid_token"`. The coordinator MUST NOT mint a parallel token for an in-use identity. Implementations evaluate this via `HasActiveTokenForProvider(provider_id)`; on DB error the gate fails CLOSED (reject).

Pre-v0.8.1 this clause specified "multi-mint on tokenless reconnect is intentional" so failed persists could self-heal automatically. The codex security audit on PR #44 (MAJOR-1) demonstrated that this design lets an attacker who declares a victim's `provider_id` on a tokenless connect harvest a valid bearer for it during the settling window. TOFU closes that vector at the cost of automatic self-healing: a binary that suffers a persist failure on its self-mint will reconnect tokenless, hit the TOFU gate, and be rejected with `invalid_token`. The operator notices the `event=provider_token_persist_failed` log and runs:

```
coordinator-cli revoke-token --token-prefix <prefix from list-tokens>
# then restart the provider binary; next connect self-mints cleanly
```

The cost is operator labor in the (rare) persist-failure case; the gain is closing the credential-capture exploit at the (common) attacker-spam case. The trade was made explicit in DECISION_CRITERIA Entry 61.

Operator-side bounded-cleanup is normative: `coordinator-cli prune-tokens [--older-than 168h] [--apply]` removes rows where `last_used_at IS NULL AND revoked_at IS NULL AND created_at < cutoff`. `last_used_at` is maintained by the existing `MarkTokenUsed` call, so live tokens are always distinguishable from stale ones.

**FR-C9.5. Compatibility cutoff at flag flip.**
When the operator flips `auth.require_provider_tokens=true` (Decision log Entry 59 forecast; Entry 60 confirmed), tokenless connects are rejected at `validateProviderToken` BEFORE reaching admission. After the flip, FR-C9.1's mint path is unreachable for new connects — only providers holding a valid token (operator-issued OR previously self-minted) connect.

**Supersedes SPEC-002 v1.3.5 FR-P12 / PG-1 for tokenless provisional admission.** Those locked clauses say provisional providers may continue without tokens under `require_provider_tokens=true`; SPEC-003 v0.8.1 explicitly narrows that to "providers with at least one unrevoked token row." The locked SPEC-002 text is intentionally preserved as-is; this supersede is normative for the open-onboarding tier (per codex architect MAJOR-1, PR #44). A future SPEC-002 revision SHOULD amend FR-P12 / PG-1 to reflect this.

The flag flip is safe AFTER:

1. The new coordinator binary carrying FR-C9.1/FR-C9.2/FR-C9.4 is deployed on Pearl.
2. A new release tag of `macprovider-cli` carrying FR-C9.3 is published and `install.sh`'s `latest_release_tag()` resolves to it.
3. A settling window (≥24h, operator's discretion) has elapsed during which existing provisional providers reconnect at least once and self-mint.

Old binaries that cannot parse `assigned_provider_token` will silently drop the field (Swift's JSON decoder ignores unknown keys) and never persist a token; at flag-flip time they are rejected at the WS handshake — same blast radius as the original M1-1 plan, no worse. Entry 60 records this as the explicit compatibility cutoff. The operator action `coordinator-cli list-tokens` may be used during the settling window to verify that all expected provider IDs have at least one unrevoked token row before flipping the flag.

**FR-C9.6. install.sh is NOT modified.**
The bootstrap pipe `curl https://get.streamvc.live/install.sh | bash` continues to write a tokenless `config.yaml`. Token acquisition happens automatically on the first WS connect after install. This preserves the single-shell-pipe UX that the open-onboarding tier exists to provide; gating provisional token issuance on operator action would re-create the very approval bottleneck Q2 was about removing.

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
2. Runs the SPEC-001 v1.2.3 FR-20 self-test (short inference, verify
   output).
3. Connects to the coordinator, sends `hello`, waits for `hello_ack`.
4. Calls `https://coordinator.streamvc.live/v1/pool/check?provider_id=<sanitized>` after WebSocket connect. This is the canonical post-SPEC-006-deployment verification path defined in SPEC-002 v1.1.4 § 7.4: `/v1/pool/check` stays on coordinator's public operator/health surface, not behind the gateway. The installer MUST NOT attempt to reach this endpoint via `api.streamvc.live`; the gateway does not proxy `/v1/pool/check`.
5. Prints results:
   ```
   Self-test results:
     Model loaded:     OK (mlx-community/Qwen2.5-7B-Instruct-4bit)
     Inference:        OK (18.3 tok/s)
     Coordinator:      OK (connected as provisional, session abc-123)
     Ready to serve!
   ```
6. If any step fails, prints the failure with a suggested fix:
   ```
   Self-test results:
     Model loaded:     OK
     Inference:        OK (18.3 tok/s)
     Coordinator:      FAILED - connection refused
       -> Check your internet connection
       -> Verify coordinator URL: wss://coordinator.streamvc.live/ws/provider
   ```

**FR-D3a. Installer self-test failure diagnostics.**
When `install.sh`'s local self-test (`wait_for_local_model`) times out, the script MUST print a diagnostic block that distinguishes "deadline reached" from "binary failed" and includes commands to check process liveness, Hugging Face cache growth, and stderr logs. This exists because first-time Qwen 7B downloads can exceed 5 minutes and the prior "Local self-test failed" message caused partners to conclude the install was broken while the binary was still loading.

The timeout path MUST also print the first 200 bytes of the actual `/v1/models` response when bytes are available, labelled clearly as "raw response". This requirement exists because wire-format mismatches between the installer's grep patterns and the binary's JSON encoder are the dominant failure mode for self-test false negatives (see Decision log Entry 20 Bug D). The 200-byte cap avoids dumping multi-kilobyte responses while reliably exposing the JSON structure that the grep is checking.

If the `/v1/models` endpoint returned no response (port unbound), the
script MUST instead print the binary's stderr log path and the last 200
bytes of stderr if non-empty. This ensures every failure mode produces
a self-diagnosing message.

**§ 5.X v1.2.4 partner-upgrade lessons.**
Install.sh upgrade-in-place was exercised at scale for the first time during the v1.2.4 partner upgrade, triggered by the SPEC-006 v0.5 launch path and tracked as Decision log Entry 22 follow-ups. Six findings surfaced from operator self-canary plus M4 partner reproduction, all closed in v0.7 (F-603-V7-1 through F-603-V7-7, excluding retracted F-603-V7-3 and F-603-V7-8). The findings clustered around three classes:

1. **Existing-state detection** — install.sh assumed fresh install
   paths; upgrade-in-place required reading prior config (port) and
   stopping the prior service (launchctl bootout).
2. **Swift Bundle resolution edge case** — launchd plist invoked the
   symlink path, which Swift's Bundle.main resolved incorrectly on some
   macOS environments. Fixed by invoking the real binary path from the
   plist.
3. **User-facing failure clarity** — "Local self-test failed" alarmed
   users when the binary was still loading. Diagnostic-rich timeout
   messaging plus cold-cache deadline extension shipped.

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
v1.2.1 § 7.2 and SPEC-002 v1.1.2 § 8.2. No d-inference source files were
read during spec writing. `cloudflared` is NOT a hard dependency for
SPEC-003 — WS-tunneled providers (SPEC-001 v1.2.1 § 6.6) need only
outbound WSS.

---

## 8. Phase 4 findings encoded in SPEC-003 v0.2

Findings D7-D10 are documented in SPEC-002 v1.1.2 § 10 (where they
belong, since they concern coordinator behavior). This section
cross-references them for completeness:

- **D7** (static config-map relaxed) → SPEC-002 v1.1.2 FR-P15, FR-P16,
  § 7.1 F-2 amendment, § 7.5
- **D8** (drain conflation) → SPEC-002 v1.1.2 § 10 D8 + SPEC-001 v1.2.1 FR-30
- **D9** (model_id case-sensitivity) → SPEC-002 v1.1.2 § 5
- **D10** (coordinator overhead) → SPEC-002 v1.1.2 FR-P14 validation
  method

---

## 9. Acceptance criteria

**AC-1 through AC-5 must ALL pass for SPEC-003 v0.7 to be considered
build-complete. Companion ACs in SPEC-001 v1.2.3 (AC-11 through AC-15)
and SPEC-002 v1.1.4 (AC-11 through AC-15) must also pass.**

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

**AC-4. Installer self-test diagnostic output.**

**Setup:** A Mac with `macprovider-cli` installed by `install.sh`, but
with the local self-test forced to fail after the binary binds its local
HTTP port. During testing, this can be done by temporarily changing the
model string expected by `wait_for_local_model` to a non-existent model
and reverting the edit after the check.

**Action:** Run
`curl -fsSL https://get.streamvc.live/install.sh | MACPROVIDER_PORT=18080 MACPROVIDER_NO_PROMPT=1 bash`.

**Expected:**
1. `install.sh` exits with code 6.
2. The failure log includes `Self-test timeout reached. THIS DOES NOT
   NECESSARILY MEAN THE BINARY FAILED.`
3. If `/v1/models` returned bytes, the log includes
   `Raw /v1/models response (first 200 bytes):` followed by the capped
   raw response.
4. If `/v1/models` returned nothing, the log includes the stderr log
   path and the last 200 bytes of stderr if the file is non-empty.
5. The normal green install path does not print the raw-response
   diagnostic.

**How to verify:** Manual curl-pipe-bash failure injection plus a normal
green install retest.

---

**AC-5. Upgrade-in-place installer hardening.**

**Setup/action:** Re-run `install.sh` on an existing v1.2.3+ install, then run a mixed-state directory simulation via `MACPROVIDER_INSTALL_DIR`.

**Expected:** Existing config port is reused; own `macprovider-cli` port holders are stopped while foreign holders still exit 6; launchd invokes the real binary path; warm-cache waits remain 5 minutes; cold-cache waits are 20 minutes with progress; mixed-state directories warn and continue.

**How to verify:** Manual upgrade on existing partner-shaped install plus local mixed-directory simulation.

---

## 10. Audit categories for SPEC-003+ revisions

**Audit category A: Shell-script paths that touch real OS resources
require integration tests, not code review.**

Any shell-script path in the installer or related tooling that touches a
real OS resource MUST have an integration test that actually exercises
the resource. "Real OS resource" includes but is not limited to:

- Controlling tty (`/dev/tty`, `read -p`, prompt redirection)
- File descriptor manipulation (`exec 4</dev/tty`, fd inheritance across
  subshells, `<&-`)
- Port binding (`lsof -iTCP`, `nc -l`, launchd `Sockets`)
- Filesystem layout assumptions (binary-adjacent resource loading,
  bundle co-location, symlink behavior under `cp -L` / `tar -h`)
- JSON parsing over loopback (RFC 8259 escape choices that vary by
  producer)
- Pipe-environment semantics (`A=1 cmd1 | cmd2` environment scoping)
- macOS-specific behavior (`com.apple.quarantine`, launchd plist
  bootstrap, codesign verification)

Audit findings that say "this line looks correct" without an
accompanying integration-test step MUST be downgraded to "needs
integration test" rather than "approved." Reference: Decision log Entry
20 Bugs A/B/C/D, all four of which were independently code-review-clean
and all four of which broke on first stranger-shaped execution.

This category inherits and reinforces the v0.5 rule that shell-script
paths touching real OS resources need integration tests, not code
review. v0.7 specifically adds: **upgrade-in-place paths exercise
different OS-resource interactions than fresh installs and require
their own integration testing.**

---

## 11. Open questions

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
  OQ-5; coordinator-side → SPEC-002 v1.1.2 OQ-10. The split reflects
  different tuning constraints for the two buffers.
- OQ-3 (tier visibility to buyers) → SPEC-002 v1.1.2 OQ-6
- OQ-4 (version enforcement) → SPEC-002 v1.1.2 OQ-7
- OQ-6 (promotion persistence) → SPEC-002 v1.1.2 OQ-8
- OQ-7 (provisional identity) → SPEC-002 v1.1.2 OQ-9

---

## 12. Build steps

SPEC-003 v0.2 implementation is split across three build prompts,
corresponding to the three spec updates that ship together:

| Build prompt | Spec | Scope |
|---|---|---|
| `BUILD_SPEC_001_V1_2_PROMPT.md` | SPEC-001 v1.2.1 | phase3-binary v1.2: WS inference handlers, hello endpoint_url, new subcommands (update, status, uninstall, self-test), log rotation |
| `BUILD_SPEC_002_V1_1_PROMPT.md` | SPEC-002 v1.1.2 | coordinator v0.2: WS-tunneled relay, admission tiers, provisional rate limits, new admin endpoints, tier-weighted routing, case-insensitive model match |
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
