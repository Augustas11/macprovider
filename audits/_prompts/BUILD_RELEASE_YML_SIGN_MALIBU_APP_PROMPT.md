# BUILD_SPEC — Extend `release.yml` to sign+notarize+staple `Malibu.app`

Add App-track signed distribution alongside the existing CLI-track
signed distribution. Same tag → one atomic release containing both a
signed+notarized `macprovider-cli` tarball (existing) AND a
signed+notarized+**stapled** `Malibu.app.zip` (new).

Unblocks:
1. Real smoke-testing of SPEC-026 v2 onboarding on the operator's own
   Mac with a full-fidelity signed bundle (no local key material
   required, no SMAppService silent-fail from adhoc signing).
2. Beta-cohort distribution of the App-track provider onboarding.

## Source of truth

- `.github/workflows/release.yml` (current, 510 lines) — existing CLI
  signing pipeline. This BUILD extends it in-place.
- `specs/SPEC-025-*` §3.1 — CLI bundled inside `Malibu.app`.
- `specs/SPEC-026-browserless-provider-onboarding.md` v0.11 — SMAppService
  login-item registration (§6.1 step 7g) requires proper signing to
  succeed on macOS 26.3.1+.
- Memory: `[[macprovider-launchd-amfi-blocker-macos-26]]` — adhoc
  signing fails under `launchd` bootstrap on macOS 26. Same failure
  applies to `SMAppService.register()` from within an adhoc-signed
  Malibu.app. Full Developer ID Application signing + notarization +
  stapling is the fix.
- Memory: `[[amfi-inode-cache-flavor2-macos26]]` — even with proper
  signing, AMFI inode cache can trip on first launch after `.pkg`
  install (FLAVOR 2). Not this PR's concern — install.sh already
  handles the escalation ladder. Signed Malibu.app + notarization
  makes the escalation *unnecessary* in the normal case.
- App-target build system: **XcodeGen** — `phase3-binary/app/project.yml`,
  `phase3-binary/app/Malibu.entitlements`, `phase3-binary/app/Sources/`,
  `phase3-binary/app/Tests/`.
- Team: **Superposition Technologies Pte. Ltd. (YF7XNRJUG4)** — same
  Team ID + Apple ID + notary credentials as the CLI pipeline; no new
  secrets required.

## Scope IN

### 1. Install XcodeGen on the runner

Add to the "Select Xcode" step OR a new step immediately after:

```yaml
- name: Install XcodeGen
  shell: bash
  run: |
    set -euo pipefail
    brew install xcodegen
    xcodegen --version
```

**Pin discipline:** rely on `macos-15` runner's Homebrew XcodeGen
version; do NOT pin to a hash — XcodeGen is a build-only tool with
no supply-chain risk beyond what Homebrew already vets, and pinning
adds maintenance burden. Document this decision in the step comment.

### 2. Generate + build Malibu.app

New step after the existing "Build package" step (which packages the CLI):

```yaml
- name: Build Malibu.app
  shell: bash
  run: |
    set -euo pipefail
    cd phase3-binary/app
    xcodegen generate
    # xcodebuild archive path produces a .xcarchive; we extract the .app.
    # Release configuration wires Hardened Runtime + macOS deployment
    # target per project.yml.
    xcodebuild \
      -project Malibu.xcodeproj \
      -scheme Malibu \
      -configuration Release \
      -destination "generic/platform=macOS" \
      -archivePath "$RUNNER_TEMP/Malibu.xcarchive" \
      archive \
      CODE_SIGNING_ALLOWED=NO
    # Extract the .app from the archive
    cp -R "$RUNNER_TEMP/Malibu.xcarchive/Products/Applications/Malibu.app" \
      "$RUNNER_TEMP/Malibu.app"
```

**Why `CODE_SIGNING_ALLOWED=NO` at archive time.** We sign in the
next step, not during Xcode archive. Xcode's automatic signing
requires provisioning profiles + Apple ID paired with the runner's
keychain, which is not how this workflow authenticates. Manual
codesign after archive is cleaner and matches the CLI pattern.

### 3. Sign + notarize + staple Malibu.app

New step after the existing "Sign + notarize binary" step. Reuses
the ephemeral `build.keychain` created there IF the CLI signing step
imported the cert AND the keychain has not yet been cleaned up.

**Ordering constraint:** the current CLI step's cleanup happens at
line 292 (`cleanup_signing_material; trap - EXIT`). We MUST invoke
the App-signing logic BEFORE that cleanup fires, OR re-import the
cert in a new keychain for the App step. Two impl choices:

- **A. Move CLI cleanup to end of workflow** (single ephemeral
  keychain, both artifacts sign from it). Change: remove
  `cleanup_signing_material` call from CLI step's final lines;
  add a dedicated cleanup step at end of job.
- **B. Re-import cert in a new keychain for App step** (two
  ephemeral keychains, more code but full isolation). Both steps
  fully independent.

**Recommendation: A**, because two independent keychains double the
attack surface for cert-in-CI-runtime exposure and the App step
lands within seconds of the CLI step. Single-keychain lifetime is
already bounded by the job.

Body of the new step (structurally mirrors the CLI signing block):

```yaml
- name: Sign + notarize + staple Malibu.app (conditional on operator secrets)
  shell: bash
  env:
    APPLE_DEVELOPER_ID_CERT_P12_BASE64: ${{ secrets.APPLE_DEVELOPER_ID_CERT_P12_BASE64 }}
    APPLE_NOTARY_APPLE_ID: ${{ secrets.APPLE_NOTARY_APPLE_ID }}
    APPLE_NOTARY_PASSWORD: ${{ secrets.APPLE_NOTARY_PASSWORD }}
    APPLE_NOTARY_TEAM_ID: ${{ secrets.APPLE_NOTARY_TEAM_ID }}
  run: |
    set -euo pipefail
    APP="$RUNNER_TEMP/Malibu.app"
    test -d "$APP"

    if [ -z "$APPLE_DEVELOPER_ID_CERT_P12_BASE64" ]; then
      echo "::warning::APPLE_DEVELOPER_ID_CERT_P12_BASE64 not set;"
      echo "::warning::skipping signed Malibu.app artifact."
      echo "::warning::adhoc-signed Malibu.app cannot register SMAppService"
      echo "::warning::login-items on macOS 26.3.1+."
      exit 0
    fi

    # build.keychain was created by the earlier CLI signing step.
    # Verify it still exists — the CLI step must not have run its
    # cleanup trap yet (refactored in this PR).
    security list-keychains | grep -q build.keychain || {
      echo "::error::build.keychain absent; CLI signing step cleanup ran too early." >&2
      exit 1
    }

    SIGNING_ID=$(security find-identity -v -p codesigning build.keychain \
                | awk -F'"' '/Developer ID Application/ {print $2; exit}')
    [ -n "$SIGNING_ID" ] || {
      echo "::error::No Developer ID Application identity in build.keychain" >&2
      exit 1
    }

    # --deep signs every enclosed binary/framework. Malibu.app bundles
    # macprovider-cli per SPEC-025 §3.1; that child must chain to the
    # same signing identity or SMAppService will reject the login item.
    codesign --force --deep \
      --options runtime \
      --timestamp \
      --entitlements phase3-binary/app/Malibu.entitlements \
      --sign "$SIGNING_ID" \
      "$APP"

    codesign --verify --strict --verbose=2 --deep "$APP"

    # Notarize the .app (Apple accepts .zip submission; staples
    # directly to the .app bundle — unlike raw executables).
    NOTARIZE_ZIP="$RUNNER_TEMP/Malibu-notary.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"

    xcrun notarytool submit "$NOTARIZE_ZIP" \
      --apple-id "$APPLE_NOTARY_APPLE_ID" \
      --password "$APPLE_NOTARY_PASSWORD" \
      --team-id "$APPLE_NOTARY_TEAM_ID" \
      --wait
    rm -f "$NOTARIZE_ZIP"

    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"

    # Package for release delivery: zip that preserves the .app
    # bundle structure with stapled ticket.
    tag="${{ steps.version.outputs.tag }}"
    DIST_ZIP="phase3-binary/app/dist/Malibu-${tag}.zip"
    mkdir -p "phase3-binary/app/dist"
    (cd "$RUNNER_TEMP" && /usr/bin/ditto -c -k --keepParent Malibu.app "$DIST_ZIP")

    echo "  Malibu.app signed by: $SIGNING_ID"
    echo "  Malibu.app notarization: accepted"
    echo "  Malibu.app stapling: validated"
    echo "  Malibu.app.zip: $DIST_ZIP"
```

### 4. Move CLI-step cleanup to end-of-job (refactor of existing code)

Current CLI signing step ends with:
```bash
cleanup_signing_material
trap - EXIT
```

Move both lines to a new dedicated cleanup step that runs AFTER both
CLI signing AND Malibu.app signing. Use `if: always()` so cleanup
fires even on step failures.

```yaml
- name: Clean signing material
  if: always()
  shell: bash
  run: |
    security delete-keychain build.keychain >/dev/null 2>&1 || true
    rm -rf "$SIGNING_TMP" "$WORK" 2>/dev/null || true
```

**Concern:** the existing CLI step uses `WORK` and `SIGNING_TMP` as
shell locals; they don't survive to a subsequent step. Fix by
exporting the paths to `$GITHUB_ENV`:

```bash
# At the top of the CLI signing step, replace:
#   SIGNING_TMP=$(mktemp -d)
#   WORK=$(mktemp -d)
# With:
SIGNING_TMP=$(mktemp -d)
WORK=$(mktemp -d)
echo "SIGNING_TMP=$SIGNING_TMP" >> "$GITHUB_ENV"
echo "WORK=$WORK" >> "$GITHUB_ENV"
```

Then remove the local `cleanup_signing_material` trap from the CLI
step (the end-of-job cleanup step handles it).

### 5. Attach Malibu.app.zip to the release

Existing "Prepare release assets" step at line 419 assembles the
release asset list. Add `Malibu-${tag}.zip` to the list. Existing
"Publish GitHub Release" step at line 472 uploads all assembled
assets; nothing to change there beyond the asset list.

Locate the asset-collection loop and add:
```bash
if [ -f "phase3-binary/app/dist/Malibu-${tag}.zip" ]; then
  cp "phase3-binary/app/dist/Malibu-${tag}.zip" "$release_dir/"
fi
```

Sized appropriately for whatever pattern the existing loop uses.

### 6. Update release-notes step (line 453)

Add a paragraph mentioning the signed+notarized+stapled Malibu.app:

> **Malibu.app (App-track provider onboarding)** — this release also
> ships a Developer ID-signed, notarized, and stapled `Malibu.app`
> for the SPEC-026 browserless one-click provider onboarding flow.
> Download `Malibu-{version}.zip`, unzip, and drag `Malibu.app` to
> `/Applications`. First launch drives the whole registration →
> autotune → download → live flow with no browser and no CLI setup.

Only include this paragraph when the App-signing step actually
produced an artifact. If the App signing was skipped (no cert
secret), omit.

### 7. Add release-verify.yml coverage for the new artifact

`release-verify.yml` (existing workflow) validates released assets.
Add:
- Download `Malibu-{tag}.zip` from the release
- Unzip
- `codesign --verify --strict --deep --verbose=2 Malibu.app` → must pass
- `xcrun stapler validate Malibu.app` → must pass
- `spctl -a -vvv -t exec Malibu.app` → should pass (Gatekeeper)

If any of these fail on a released tag, the release is broken and
release-verify.yml should surface a failing check.

## Scope OUT

- **DMG delivery container.** `.dmg` is nicer UX (drag-to-Applications
  animation, background image) but adds `create-dmg` dependency +
  disk-image build complexity. Defer to a follow-up PR. `.zip` is
  fine for beta cohort.
- **App Store distribution.** Requires an App Store Connect API key
  submission workflow, Sandbox entitlement changes, provisioning
  profile embedding. Not needed for our distribution model
  (direct-download from GitHub Releases).
- **Sparkle auto-update wiring.** Sparkle needs an EdDSA signing key
  and appcast.xml hosted at `get.malibu.tech`. Follow-up.
- **In-App update prompt after release.** No in-App update UI yet;
  users re-download from the Releases page. Follow-up when Sparkle
  lands.
- **Universal binary (x86_64 + arm64).** Current CLI pipeline is
  arm64-only per `macos-15` runner default. Malibu.app inherits the
  same target. x86_64 support is a separate SPEC (Intel Mac
  provider support is not on the roadmap).
- **Malibu.app CI unit tests.** `phase3-binary (swift test)` already
  runs Malibu unit tests in ci.yml. Not re-run here.
- **Adhoc-signing fallback for Malibu.app.** For the CLI, adhoc is
  a partial fallback (works pre-macOS-26). For Malibu.app,
  adhoc-signing is worse than useless: it produces a bundle that
  cannot register SMAppService, cannot pass Gatekeeper for any
  redistribution, and would silently produce a broken experience.
  Better UX: skip artifact entirely with a warning (see step 3).
- **Retry / backoff on notarytool submission.** `--wait` already
  blocks up to 15 min per Apple's docs. If Apple's notary service
  is degraded, the whole release fails — that's the correct
  behavior (don't ship un-notarized). Retry logic is scope creep.

## Key constraints

1. **No new secrets required.** Reuse `APPLE_DEVELOPER_ID_CERT_P12_BASE64`,
   `APPLE_NOTARY_APPLE_ID`, `APPLE_NOTARY_PASSWORD`, `APPLE_NOTARY_TEAM_ID`
   already used by the CLI signing step. Adding secrets is a
   maintenance tax — reuse where the cert chain is identical.
2. **Same Team ID YF7XNRJUG4** for both CLI and App. Simplifies the
   Malibu.app → child-CLI-process chain: both signed by the same
   authority, `spctl` treats the CLI child as a legitimate helper.
3. **`--deep` on codesign is load-bearing.** Malibu.app bundles the
   CLI (SPEC-025 §3.1); without `--deep`, only the outer binary is
   signed and the enclosed CLI stays adhoc. SMAppService register
   would fail.
4. **`--options runtime` (Hardened Runtime) is mandatory for
   notarization.** Apple rejects submissions without it.
5. **`--timestamp` (secure timestamp) is mandatory for notarization.**
   Apple rejects submissions without it.
6. **`--entitlements phase3-binary/app/Malibu.entitlements` on the
   codesign call.** Must match the entitlements declared in
   `project.yml`. Any drift → SMAppService will reject.
7. **`.app` is staplable; `.tarball` is not.** Unlike the CLI (which
   skips stapling per Apple limitation on standalone executables),
   the App bundle CAN and MUST be stapled. This gives offline
   Gatekeeper approval — users can launch the app without an
   internet round-trip to Apple.
8. **`build.keychain` lifetime spans both signing steps** (per the
   refactor in step 4). Cleanup step MUST use `if: always()` so it
   fires on partial failure too.
9. **Warning-not-error on skipped App signing.** If secrets absent,
   the CLI release still ships (warning only). The App just isn't
   in that release. This matches the existing CLI conditional
   pattern.
10. **release-verify.yml is a first-class gate.** Post-release
    validation confirms the artifact users download actually
    verifies + staples. Any drift caught in prod, not in the
    build.
11. **The workflow trigger stays `on: push tags: v*.*.*`** — same
    tag lands both artifacts. No new tag pattern.

## Audit-loop discipline

Per `[[feedback-audit-build-prompts-before-impl]]` +
`[[feedback-three-lane-codex-audits]]`:

1. **This BUILD prompt gets a 3-lane codex audit FIRST**, converge to
   0 CRITICAL / 0 HIGH / 0 MEDIUM. Audit prompt files:
   - `specs/AUDIT_BUILD_RELEASE_YML_SIGN_MALIBU_APP_CODE_AUDIT_PROMPT.md`
   - `specs/AUDIT_BUILD_RELEASE_YML_SIGN_MALIBU_APP_SECURITY_AUDIT_PROMPT.md`
   - `specs/AUDIT_BUILD_RELEASE_YML_SIGN_MALIBU_APP_ARCHITECT_AUDIT_PROMPT.md`
2. Fix + re-fire; narrative in
   `specs/RELEASE_YML_SIGN_MALIBU_APP-BUILD-PROMPT-audit.md`.
3. **Security lane's job is load-bearing** — this touches CI credential
   handling. Explicit lane focus: keychain lifetime, secret leakage
   in logs, ordering hazards, cleanup on failure paths.
4. Codex executes the audited prompt → IMPL diff on this branch
   `feat/release-sign-malibu-app`.
5. 3-lane IMPL audit prompts:
   - `specs/AUDIT_RELEASE_YML_SIGN_MALIBU_APP_IMPL_{CODE,SECURITY,ARCHITECT}_AUDIT_PROMPT.md`
6. Converge 0/0/0; narrative in
   `specs/RELEASE_YML_SIGN_MALIBU_APP-IMPL-audit.md`.
7. DRAFT → Ready → merge.

## Manual verification before Ready-for-review

The workflow only runs on tag push OR workflow_dispatch — cannot be
smoke-tested on every PR commit. Two verification paths:

- **A. `workflow_dispatch` on a throwaway prerelease tag.** After
  impl lands on the PR branch, manually trigger the workflow via
  `gh workflow run release.yml -f version=v99.99.99-test1
  -f prerelease=true`. Verify (a) both CLI tarball AND
  `Malibu.zip` land as release assets; (b)
  `spctl -a -vvv Malibu.app` and `xcrun stapler validate` both
  succeed on a downloaded copy. Delete the prerelease + tag after
  verification.
- **B. `act` (local GH Actions runner).** Faster iteration but
  can't invoke real notarytool without leaking secrets to the local
  environment. Use for structural validation (YAML parse, step
  ordering, arg passing) but NOT for notarization coverage.

Verification path A is mandatory before Ready-for-review; path B
is optional acceleration.

## Definition of done

- New `Malibu-{tag}.zip` asset present on GitHub Release for the
  next tag push.
- `codesign --verify --strict --deep --verbose=2 Malibu.app` passes.
- `xcrun stapler validate Malibu.app` passes.
- `spctl -a -vvv -t exec Malibu.app` passes (Gatekeeper accepts).
- Downloading + unzipping the release asset onto a fresh Mac (or
  a Mac with a fresh `Malibu.app` install) → double-click Malibu.app
  → no "unidentified developer" warning, no Gatekeeper block,
  no launchd bootstrap failure on SMAppService register.
- CLI release path (existing behavior) unchanged: same tarball,
  same signing chain, same warnings if secrets missing.
- release-verify.yml passes on the released tag.
- 3-lane codex audit at 0 CRITICAL / 0 HIGH / 0 MEDIUM.
- CI green.
- Ready to convert DRAFT → Ready.

## Reference

- Parent CI file: `.github/workflows/release.yml`
- Adjacent workflow: `.github/workflows/release-verify.yml`
- Existing CLI pipeline is the template; App pipeline mirrors it
- Base branch for this PR: `main` (dabf188 or later)
- App target build files: `phase3-binary/app/project.yml`,
  `phase3-binary/app/Malibu.entitlements`,
  `phase3-binary/app/Sources/`, `phase3-binary/app/Tests/`
- Memory: `[[macprovider-launchd-amfi-blocker-macos-26]]`,
  `[[amfi-inode-cache-flavor2-macos26]]`
