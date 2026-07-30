# Build prompt — Distribution stream (SPEC-003 non-Swift portion)

Operator-paste prompt to implement the shell + YAML + markdown
distribution layer specified in SPEC-003 v0.4 Part C + onboarding
README updates from Part D. This stream **does not touch Swift or
Go code** and is fully parallelizable with the Swift stream
(BUILD_SWIFT) and the Coordinator stream (BUILD_COORDINATOR).

What this stream produces:
  - `install.sh` (the curl-pipe-bash installer hosted at
    `get.streamvc.live`)
  - launchd plist template
  - GitHub Actions workflow for Releases automation
  - README "Join the Network" section
  - Uninstall script

Expected duration: ~3-4 hours. Run in **Codex CLI** rooted at
`/Users/augstar/macprovider-poc/`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`.

---

```
=== BEGIN PROMPT ===

You are implementing the distribution stream of the Mac Provider
project per SPEC-003 v0.4. Your scope is shell scripts, YAML
(GitHub Actions), launchd plist, and markdown — NO Swift, NO Go.

The Swift binary you target (`macprovider-cli` v1.2) is being built
in parallel by a separate session (BUILD_SWIFT). Your install.sh
does NOT need that binary to exist during build — it will pull a
released tarball from GitHub. Assume the binary exists at the URL
your installer constructs.

## Project context (read this first)

Mac Provider is a pooled-inference network where contributor Macs
run MLX inference, a VPS-hosted coordinator routes buyer requests,
and the network is presented as one seller to the Antseed marketplace
(deferred). Production state as of 2026-05-28:

  - `coordinator.streamvc.live` live on Pearl VPS (159.223.165.194)
  - Pool N=2: M4 partner (Qwen 7B, MacBook Air) + M1 partner
    (Llama 3.2 3B, the M1 partner's Mac)
  - Multi-model end-to-end working (2.3-2.5s real inference)
  - Current onboarding is operator-locked: every contributor needs
    a subdomain on streamvc.live + a Cloudflare tunnel token + a
    config edit on the VPS. Three hard blocks. This stream is part
    of removing those blocks.

SPEC-003 v0.4 specifies a curl-pipe-bash installer that a stranger
can run with no operator action: `curl -fsSL get.streamvc.live/
install.sh | bash`. The provider binary they download supports
WS-tunneled inference (no public URL needed), opens an outbound
WebSocket to the coordinator, and joins the pool as a
provisional-tier provider.

## d-inference clean-room

The d-inference codebase (https://github.com/layr-labs/d-inference)
is custom-licensed (NOASSERTION SPDX) and prohibits use to compete.
Do NOT inspect their source code at any point. The architectural
patterns you implement here are standard for curl-install distributions
(Docker, Tailscale, rustup, etc.) and predate d-inference by years.
Reaffirm the clean-room separation if you find yourself reaching for
their patterns.

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   v0.4 — the spec under build. Focus on:
     § 3 Integration narrative
     § 4 FR-C1 through FR-C8 (distribution lifecycle)
     § 4 FR-D1 through FR-D5 (onboarding UX)
     § 5 AC-1, AC-2, AC-3 (your acceptance criteria)
     § 7 Interface contracts (install.sh + launchd plist + GitHub
       Releases shape)
     § 11 OQ-1 (code signing) — operator will resolve later;
       implement with `xattr -dr` workaround as today

2. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.2.1 — read § 0 + § 6.5 hello (to know what your install.sh
   prompts user for). You DO NOT modify SPEC-001 implementation.

3. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.1.2 — read the change-log + § 3 (mode resolution) + § 7.5
   (admin endpoints). Your install.sh produces providers that the
   coordinator will admit as provisional.

4. /Users/augstar/macprovider-poc/phase3-binary/dist/install-m4-coordinator.sh
   /Users/augstar/macprovider-poc/phase3-binary/dist/install-m1-coordinator.sh
   — the existing pinned-provider install scripts. Read them to
   understand the existing install pattern (download tarball,
   xattr -dr, nohup launch). Your new install.sh is the
   provisional-tier equivalent; the existing scripts stay for M4/M1.

5. /Users/augstar/macprovider-poc/phase3-binary/dist/package.sh
   — the operator-side packaging script. Your GitHub Action wraps
   this for automated releases.

6. /Users/augstar/macprovider-poc/HANDOFF.md
   /Users/augstar/macprovider-poc/CONTINUE_RUNBOOK.md
   — project context.

## Scope you OWN (only modify or create these)

Create (new files):
  /Users/augstar/macprovider-poc/phase3-binary/dist/install.sh
    The public install script. Curl-pipe-bash safe. ~200-300 lines.
  /Users/augstar/macprovider-poc/phase3-binary/dist/uninstall.sh
    Removes binary, launchd plist, logs, models. With confirmation.
  /Users/augstar/macprovider-poc/phase3-binary/dist/launchd-plist-template.plist
    Template for `~/Library/LaunchAgents/live.streamvc.macprovider.plist`
    that install.sh fills in per-user.
  /Users/augstar/macprovider-poc/.github/workflows/release.yml
    GitHub Actions workflow for Releases automation. Wraps
    package.sh + uploads tarball + checksums.
  /Users/augstar/macprovider-poc/phase3-binary/README.md
    README with "Join the Network" section (per SPEC-003 v0.4 § 4
    FR-D1). New file; the repo root has its own README left untouched.

Modify (existing):
  /Users/augstar/macprovider-poc/README.md
    Add a "Join the Network" section near the top. Keep existing
    project description intact.

## Scope you MUST NOT modify

  - Anything under /Users/augstar/macprovider-poc/phase3-binary/Sources/
    (Swift package — BUILD_SWIFT owns this)
  - Anything under /Users/augstar/macprovider-poc/phase4-coordinator/
    (Go package — BUILD_COORDINATOR owns this)
  - Anything under /Users/augstar/macprovider-poc/specs/
    (spec corpus is locked)
  - Anything under /Users/augstar/macprovider-poc/beta/
    (Phase 2 harness; out of scope)
  - The existing install-m4-coordinator.sh / install-m1-coordinator.sh
    (pinned-provider path; stays for M4/M1)
  - Anything in phase3-binary/Package.swift, Package.resolved, etc.

If you find yourself wanting to edit any of the above, STOP — you've
crossed a stream boundary. The other build session owns it.

## Implementation plan

### Step 1: install.sh

Build to FR-C1, FR-C2, FR-C3, FR-D1 in SPEC-003 v0.4. Specifically:

Behavior:
  1. Detect macOS + Apple Silicon. Exit early with clear message if
     not satisfied (refer to v0.4 § 5 AC-1's "clean Mac" definition).
  2. Detect RAM tier via `sysctl -n hw.memsize` and pick default
     model per FR-D3:
       8 GB  → mlx-community/Llama-3.2-3B-Instruct-4bit
       16 GB → mlx-community/Qwen2.5-7B-Instruct-4bit
       24 GB+ → mlx-community/Qwen2.5-14B-Instruct-4bit (or ask
                user)
  3. Prompt user for a handle (default: hostname, sanitized). The
     handle becomes their `provider_id` per SPEC-001 v1.2.1 § 6.5.
  4. Query GitHub Releases API for the latest release tag (FR-C1).
     Download the corresponding tarball + SHA256.
  5. Verify SHA256 (FR-C2).
  6. Install to `~/macprovider/` (NOT `/usr/local/` — keep
     user-level for no-sudo install).
  7. Run `xattr -dr com.apple.quarantine` per OQ-5 workaround
     (FR-C7).
  8. Install launchd plist to
     `~/Library/LaunchAgents/live.streamvc.macprovider.plist`
     (FR-C4).
  9. Load via `launchctl bootstrap gui/$UID
     ~/Library/LaunchAgents/live.streamvc.macprovider.plist`.
 10. Run self-test (FR-D4):
       - Wait for binary to bind port (60s timeout)
       - Verify `curl http://127.0.0.1:8080/v1/models` returns the
         expected model with `owned_by:macprovider`
       - Wait up to 30s for coordinator pool to show this
         provider_id (curl
         `https://coordinator.streamvc.live/v1/models` and check
         for the model). This is the SPEC-003 v0.4 AC-1 pass
         condition: model + coord connection both succeed.
       - If pool doesn't reflect the binary within 30s, print
         AC-1a degraded-mode warning + exit non-zero (per the
         v0.3 fix that restored strict AC-1).
 11. On success, print:
       - PID and how to view logs
       - URL of /v1/models on coordinator showing the provider in
         the pool
       - Uninstall command

Safety constraints:
  - `set -euo pipefail` at top
  - Every external command checked
  - No `eval`, no string interpolation into shell commands
  - SHA256 verification BEFORE the tarball is extracted
  - Confirm with user before `xattr -dr` (security tradeoff —
    surface it)
  - The script must be runnable as `curl -fsSL <url> | bash` AND
    `bash install.sh` (idempotent invocation)

Acceptance:
  Producing this matches SPEC-003 v0.4 AC-1 and AC-2.

### Step 2: launchd-plist-template.plist

Build to FR-C4 in SPEC-003 v0.4.

Template variables (replaced by install.sh at install time):
  __USER_HOME__       → `$HOME` of installing user
  __BINARY_PATH__     → `~/macprovider/macprovider-cli` (absolute)
  __PROVIDER_ID__     → user's chosen handle (from prompt)
  __COORDINATOR_URL__ → wss://coordinator.streamvc.live/ws/provider
  __LOG_DIR__         → `~/Library/Logs/macprovider/`

Plist contents (XML):
  - Label: `live.streamvc.macprovider`
  - ProgramArguments: [BINARY_PATH, --port, 8080, --model, <MODEL>,
                       --provider-id, PROVIDER_ID, --coordinator,
                       COORDINATOR_URL]
  - RunAtLoad: true
  - KeepAlive: true (restart on crash)
  - StandardOutPath: LOG_DIR/macprovider.out.log
  - StandardErrorPath: LOG_DIR/macprovider.err.log
  - ProcessType: Adaptive (so macOS doesn't aggressively suspend it)
  - WorkingDirectory: ~/macprovider/

Document the template variable mapping in install.sh comments so the
substitution is obvious.

Acceptance: matches SPEC-003 v0.4 AC-3 (launchd plist survives
reboot, binary auto-restarts after kill -9).

### Step 3: uninstall.sh

Build to FR-D5 in SPEC-003 v0.4.

Behavior:
  1. Confirm with user (yes/no prompt) — list what will be removed
  2. `launchctl bootout gui/$UID
     ~/Library/LaunchAgents/live.streamvc.macprovider.plist`
  3. Remove `~/Library/LaunchAgents/live.streamvc.macprovider.plist`
  4. Remove `~/macprovider/` (binary, models, logs)
  5. Remove `~/Library/Logs/macprovider/`
  6. Print: "If you want to fully uninstall MLX-cached models from
     ~/.cache/huggingface/, do that manually."

DO NOT remove anything outside the ~/macprovider/ + ~/Library/
LaunchAgents/live.streamvc.macprovider.plist + ~/Library/Logs/
macprovider/ paths.

### Step 4: .github/workflows/release.yml

Build to FR-C1 in SPEC-003 v0.4.

Triggers:
  - On tag push matching `v*.*.*` (e.g., v1.2.1, v1.2.2)
  - Optionally manual via workflow_dispatch

Steps:
  1. Checkout
  2. Install Xcode + Metal toolchain (or use a self-hosted runner —
     document the choice + rationale in workflow comments)
  3. Run package.sh with the tag as VERSION_TAG
  4. Compute SHA256 of the produced tarball
  5. Create GitHub Release with:
     - Tarball as asset (phase3-binary-<tag>.tar.gz)
     - SHA256 file as asset
     - Release notes from CHANGELOG.md if present, else placeholder
  6. Set release as latest

Note: GitHub-hosted runners may not have Apple Developer ID
signing. Document this clearly + reference OQ-5. Use unsigned
build for now (xattr workaround handles it).

### Step 5: README.md updates

Add a "Join the Network" section to /Users/augstar/macprovider-poc/README.md.

Content per SPEC-003 v0.4 § 4 FR-D1:
  - One-liner explanation of Mac Provider
  - "Run this on any Apple Silicon Mac (M1+, macOS 14+):"
  - The curl-pipe-bash install command in a fenced bash block
  - What the installer does (5-7 bullets)
  - Link to spec for technical readers
  - Trust caveats (curl-pipe-bash security tradeoff — surface it
    honestly per E.1 from audit)

Keep this section near the top of the README. Existing content
below it stays.

Also create phase3-binary/README.md (separate file, scoped to the
phase3-binary package) with similar but more technical content
appropriate for that subdirectory.

### Step 6: Implementation notes

Append a "Distribution stream build" section to:
  /Users/augstar/macprovider-poc/phase5-onboarding/implementation-notes.html

(The file exists as an empty scaffold from when SPEC-003 was drafted.)

Document:
  - Design choices made where SPEC-003 v0.4 was ambiguous
  - Any deviation from spec + why
  - Any open questions for operator
  - Manual test results (each AC walked through with output)

## Mock dependencies (what to assume since other streams aren't done)

You do NOT have:
  - A v1.2 phase3-binary tarball published to GitHub Releases yet
  - A coordinator v1.1.2 deployed that accepts provisional providers

You DO have:
  - The current phase3-binary v1.1.4 tarball patterns + package.sh
  - The current coordinator v1.0.4 deployed on Pearl VPS (accepts
    only pinned providers via static config) — DO NOT use this to
    test AC-1 fully; document this as expected-failure and verify
    manually post-integration

Test what you CAN test:
  - install.sh syntax (`bash -n install.sh`)
  - install.sh DRY-RUN flag (add this — `--dry-run` prints what it
    would do without executing)
  - launchd plist syntax (`plutil -lint launchd-plist-template.plist`
    after template substitution)
  - GitHub Action YAML syntax (use `actionlint` if available, else
    visual review)
  - README markdown rendering (mental check)

Mark AC-1 (full install on clean Mac) as PENDING in implementation
notes — it requires the other two streams done first. Integration
testing happens post-merge.

## Process

1. Read all required materials.
2. Outline the six artifacts in a scratchpad. Confirm scope
   boundaries (Swift = NOT YOURS; Go = NOT YOURS).
3. Build in order: install.sh, launchd template, uninstall.sh,
   GitHub Action, READMEs.
4. Test each artifact with the tools available.
5. Append the implementation-notes.html section.
6. Print a 300-word handback summary listing:
   - Files created (paths)
   - Files modified (paths)
   - Files touched OUTSIDE your scope: should be NONE
   - Open items for operator (e.g., OQ-5 code-signing strategy)
   - Whether AC-1 was tested (no, deferred to integration)
   - Whether AC-2 (update) is testable yet (no, pending v2 release)
   - Whether AC-3 (launchd survives reboot) was tested (depends on
     whether you reboot during build — typically yes via plutil
     + manual launchctl load/unload)

7. Do NOT commit. Operator commits all three streams as one
   coordinated commit after integration testing.

## What NOT to do

- Do NOT modify any Swift or Go files.
- Do NOT touch the spec corpus.
- Do NOT inspect d-inference source.
- Do NOT add new dependencies beyond standard macOS tools (curl,
  shasum, plutil, launchctl, xattr, tar, sysctl).
- Do NOT commit; operator commits.
- Do NOT enable Apple Developer ID signing — leave OQ-5 unresolved.

When done, print the 300-word handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

The artifact set produced should be reviewable as a unit. Operator's
review checklist:

1. `bash -n install.sh` passes (no syntax errors).
2. `plutil -lint launchd-plist-template.plist` passes after a manual
   variable substitution.
3. `actionlint .github/workflows/release.yml` passes (if available).
4. README "Join the Network" section reads correctly and surfaces
   the curl-pipe-bash security tradeoff honestly.
5. uninstall.sh removes exactly what it should, nothing more.

Hold this stream's deliverables until BUILD_SWIFT and BUILD_COORDINATOR
land, then do integration testing of AC-1 (full clean-Mac install)
against the v1.2 binary + v1.1.2 coordinator running locally.
