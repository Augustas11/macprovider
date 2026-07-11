# Release signing + notarization — operator runbook

The release workflow (`.github/workflows/release.yml`) signs the
`macprovider-cli` binary with a Developer ID Application certificate and
notarizes via `xcrun notarytool` so freshly-installed binaries pass
macOS 26.3.1+ launchd's tightened AMFI policy.

The compatibility release artifact is a `.tar.gz` containing a standalone
Mach-O executable. Apple notarization accepts the executable when it is
submitted inside a transient zip, but `xcrun stapler` cannot attach a
notarization ticket directly to that raw executable format. For that
artifact shape, the release gate is `notarytool submit --wait` returning
`Accepted`.

New releases can also publish a signed flat `.pkg` delivery container.
The package carries the same `macprovider-cli` payload as the tarball,
is signed with a Developer ID Installer certificate, is submitted to
notarytool directly, and is stapled after Apple accepts it. `install.sh`
prefers this package when present and falls back to the tarball for older
releases. The package is not a standalone GUI installer; its preinstall
script fails direct Installer.app installs so operators do not bypass
`install.sh`'s user-level config, launchd, and support-file setup.

Production releases fail closed unless the operator-supplied signing,
notarization, Sparkle, checksum-signing, and Pearl publication secrets are
available through the protected `production-release` environment. The release
workflow no longer publishes an adhoc-signed compatibility artifact: fresh
installs on macOS >= 26.3.1 cannot run it through launchd, so such an artifact
is not a production release.

## Why this exists

Discovered 2026-06-12 when v1.3.1 was the first release attempted on a
macOS 26.3.1 client. `launchctl bootstrap` failed with
`5: Input/output error`; AMFI's kernel log surfaced the underlying
cause: `'macprovider-cli' has no CMS blob`. Adhoc-signed binaries
(what Swift's default linker-signing produces) lack the CMS
certificate chain that 26.3.1's launchd policy now requires. Earlier
macOS versions accepted adhoc-signed binaries; the policy was tightened
in this OS release.

Standalone shell launches of an adhoc-signed binary still work — the
kernel's execve path is more permissive than launchd's bootstrap
path. So the workaround until signing is wired up is "run the binary
manually, skip the launchd integration". That breaks the
reboot-survival contract that `install.sh` promises but does not
break the inference path itself.

## One-time operator setup

### 1. Apple Developer Program enrollment

Membership: $99/yr. Apply at <https://developer.apple.com/programs/>.
Approval takes 24-48 hours typically. The Apple ID used to enroll is
the one you will reference as `APPLE_NOTARY_APPLE_ID` below.

### 2. Generate a Developer ID Application certificate

In Keychain Access on a Mac (signed in to the enrolled Apple ID):

```
Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority
```

- User Email Address: the enrolled Apple ID
- Common Name: anything memorable (e.g. "macprovider release signing")
- "Saved to disk"

Upload the `.certSigningRequest` at
<https://developer.apple.com/account/resources/certificates/add> →
**Developer ID Application** (NOT Mac App Distribution).

Download the resulting `.cer`, double-click to install in Keychain
Access. Then export as `.p12`:

```
Keychain Access → Certificates → [find "Developer ID Application: <name>"]
→ right-click → Export → Personal Information Exchange (.p12)
→ set a password you will paste into APPLE_DEVELOPER_ID_CERT_PASSWORD
```

### 3. Generate a Developer ID Installer certificate for `.pkg` releases

Repeat the CSR upload flow from step 2, but choose
**Developer ID Installer**. Download the resulting `.cer`, install it in
Keychain Access, then export it as `.p12`.

Use a separate export password; it becomes
`APPLE_DEVELOPER_ID_INSTALLER_CERT_PASSWORD`.

### 4. Generate an app-specific password for notarytool

At <https://appleid.apple.com/account/manage> → App-Specific Passwords →
Generate. This is **separate** from your Apple ID password — `notarytool`
will not accept the main password. Label it "macprovider notarytool".

### 5. Find your Team ID

<https://developer.apple.com/account> → Membership → Team ID. Looks
like a 10-character alphanumeric string.

### 6. Configure the protected GitHub release boundary

Do not apply these settings while a release is in flight. The commands below
are the exact intended external configuration; this repository change does not
execute them. Use a reviewer other than the account that dispatches releases,
because self-review is disabled.

Resolve the reviewer and repository IDs, then create/update the environment:

```bash
export REPO=Augustas11/macprovider
export RELEASE_REVIEWER=antfleet-ops
export REVIEWER_ID="$(gh api "users/$RELEASE_REVIEWER" --jq .id)"

gh api --method PUT "repos/$REPO/environments/production-release" \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  --input - <<JSON
{
  "wait_timer": 0,
  "prevent_self_review": true,
  "can_admins_bypass": false,
  "reviewers": [{"type": "User", "id": $REVIEWER_ID}],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
JSON

gh api --method POST \
  "repos/$REPO/environments/production-release/deployment-branch-policies" \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  -f name=main -f type=branch
```

Enable immutable releases, then install the active `v*` tag ruleset. GitHub user
ID `28995904` is the `Augustas11` tagger bypass used only for the deliberate tag
creation command in step 8; no role, team, deploy key, or GitHub App/Actions
integration bypass is allowed.

```bash
gh api --method PUT "repos/$REPO/immutable-releases" \
  -H 'X-GitHub-Api-Version: 2026-03-10'

gh api --method POST "repos/$REPO/rulesets" \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  --input - <<'JSON'
{
  "name": "Immutable production release tags",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [
    {"actor_id": 28995904, "actor_type": "User", "bypass_mode": "always"}
  ],
  "conditions": {
    "ref_name": {"include": ["refs/tags/v*"], "exclude": []}
  },
  "rules": [
    {"type": "creation"},
    {"type": "update"},
    {"type": "deletion"}
  ]
}
JSON
```

The workflow requires the sole reviewer to be `antfleet-ops` (GitHub user ID
`285575208`), disables both self-review and admin bypass, and checks all three controls through
`scripts/verify-github-release-posture.sh` before it publishes. GitHub API
references:

- <https://docs.github.com/en/rest/deployments/environments>
- <https://docs.github.com/en/rest/repos/rules>
- <https://docs.github.com/en/rest/repos/repos>

### 7. Populate environment secrets

At <https://github.com/Augustas11/macprovider/settings/secrets/actions>,
select the `production-release` environment and add these environment secrets:

| Secret name | Value |
|---|---|
| `APPLE_DEVELOPER_ID_CERT_P12_BASE64` | `base64 -i path/to/application-cert.p12 \| pbcopy` |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | The Application .p12 export password from step 2 |
| `APPLE_DEVELOPER_ID_INSTALLER_CERT_P12_BASE64` | `base64 -i path/to/installer-cert.p12 \| pbcopy` |
| `APPLE_DEVELOPER_ID_INSTALLER_CERT_PASSWORD` | The Installer .p12 export password from step 3 |
| `APPLE_NOTARY_APPLE_ID` | The enrolled Apple ID email |
| `APPLE_NOTARY_PASSWORD` | The app-specific password from step 4 |
| `APPLE_NOTARY_TEAM_ID` | The Team ID from step 5 |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Sparkle Ed25519 private key matching `SUPublicEDKey` in `phase3-binary/app/project.yml` |
| `MACPROVIDER_RELEASE_SIGNING_KEY_PEM` | P-256 private key matching the public key embedded in `phase3-binary/dist/install.sh` |
| `MALIBU_DOWNLOAD_SSH_KEY` | Root SSH private key for the Pearl publication host |
| `MALIBU_DOWNLOAD_VPS_HOST` | Pearl publication host address |
| `RELEASE_POSTURE_TOKEN` | Fine-grained token with repository Administration read and Actions read access |

Do not duplicate release secrets at repository scope. The unsigned `build` job
has only `contents: read`, does not reference secrets, and uploads a one-day
artifact. Only the reviewed `sign_publish` job can enter the protected
environment and read the release secrets.

The unsigned build is content-pinned as part of the reviewed commit:
`phase3-binary/Package.resolved` and `phase3-binary/app/Package.resolved`
must match the dispatch commit byte-for-byte, Malibu resolves Sparkle at its
reviewed 2.6.4 revision, and XcodeGen 2.45.4 is installed only from its fixed
release archive after SHA-256 verification. The signing job likewise verifies
the fixed Sparkle 2.6.4 tools archive before extraction and deletes the Apple
keychain and imported signing material before invoking `generate_appcast`.

### 8. Build the candidate, cut the release tag, and verify

Merge the release commit to `main`, then dispatch a candidate from the freshly
fetched `origin/main` tip **before** creating the immutable release tag. The
secret-free build job validates, compiles, and uploads the complete unsigned
artifact set. It is the only job allowed to accept an absent tag, and only when
the explicit `candidate` input is true. The one-day artifact retention bounds
the time available to finish the protected release.

```bash
export TAG=vX.Y.Z
git fetch origin main
export RELEASE_COMMIT="$(git rev-parse origin/main)"
test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$RELEASE_COMMIT"
gh workflow run release.yml --repo Augustas11/macprovider --ref main \
  -f version="$TAG" -f prerelease=false -f candidate=true
```

Wait until the unsigned `build` job succeeds and `sign_publish` is waiting for
the independent `production-release` environment review. Do not approve yet.
Recheck that `origin/main` is still the captured commit, create the signed
annotated tag at that exact commit, push it, and verify the peeled remote target:

```bash
git fetch origin main
test "$(git rev-parse origin/main)" = "$RELEASE_COMMIT"
git tag -s "$TAG" "$RELEASE_COMMIT" -m "macprovider-cli $TAG"
git push origin "refs/tags/$TAG"
test "$(git ls-remote origin "refs/tags/$TAG^{}" | awk '{print $1}')" = "$RELEASE_COMMIT"
```

Only then approve `sign_publish` as the required environment reviewer. If
`origin/main` advanced **before the tag was created**, the build failed, the tag
already targets different bytes, or the artifact expired, leave the protected
job unapproved and start a new candidate from the new reviewed tip. After the
exact tag is created, unrelated commits may land on `main`: protected gates
require the captured tagged commit to remain an ancestor of freshly fetched
`origin/main`, so review, signing, and notarization cannot burn an immutable tag
merely because development continued. The protected job explicitly requires
the exact tag before it restores any unsigned inputs, and repeats that check
before draft creation and public transition. Expected duration after approval
is 1-15 minutes for notarization. The workflow:

1. Validates the dispatch version, prerelease flag, and candidate flag before using them
2. Imports the `.p12` into a transient keychain
3. Codesigns the binary with `--options runtime --timestamp`
4. Notarizes via `xcrun notarytool submit --wait`
5. Re-tars with the signed, notarization-accepted binary
6. Builds a signed flat `.pkg` when the Installer certificate secrets exist
7. Notarizes and staples the `.pkg`
8. Deletes the transient keychain before running the digest-pinned Sparkle tool
9. Verifies `checksums.txt.sig` against the canonical public key embedded in
   `install.sh`, then verifies the exact signed provenance/asset set
10. Creates a draft GitHub release and re-fetches every uploaded asset through
    the captured numeric release ID
11. Revalidates `origin/main`, the protected tag, repository release posture,
    checksum signature, numeric ID, and asset digests immediately before the
    numeric API transition from draft to public
12. Re-fetches the published numeric release and requires GitHub immutability
    before producing the Pearl publication manifest

If any draft verification or final gate fails, the workflow does not make the
release public and does not publish to Pearl. Inspect or delete the retained
draft by numeric ID before deliberately retrying; never replace assets on a
public immutable release.

Expected release assets:

- `macprovider-cli-vX.Y.Z-darwin-arm64.tar.gz` — compatibility artifact
- `macprovider-cli-vX.Y.Z-darwin-arm64.pkg` — preferred stapled delivery
  container for `install.sh`
- `checksums.txt`
- `checksums.txt.sig`
- `release-provenance.json` — signed through `checksums.txt`; binds every
  release asset hash to the exact tag, commit, and repository

The tarball remains the canonical `macprovider-cli update` artifact until
the self-update implementation explicitly learns the package path.

Verify on a macOS 26.3.1+ Mac:

```bash
curl -fsSL https://get.streamvc.live/install.sh | bash
# expected: "Install as a background service? [Y/n] y" → success (no I/O error)
launchctl print gui/$(id -u)/live.streamvc.macprovider | head -5
# expected: state = running
```

If `launchctl bootstrap` still fails after signing is set up, check:

```bash
log show --last 1m | grep -iE "macprovider|AMFI"
```

Common follow-up issues:

- **`xcrun stapler` exits with Error 73** — expected if someone tries
  to staple `macprovider-cli` directly. Raw standalone executables are
  not a supported stapler target. Use the signed `.pkg` artifact for a
  stapled release container.
- **`.pkg` asset is missing** — the release workflow did not find
  `APPLE_DEVELOPER_ID_INSTALLER_CERT_P12_BASE64` and skipped package
  creation. The tarball remains published for compatibility.
- **"Notarization request was not found"** — `notarytool submit` was
  invoked without `--wait` (or it timed out), so notarization was not
  accepted before packaging. Re-trigger the workflow.
- **"developer cannot be verified"** — Gatekeeper, not AMFI. Clears
  with `xattr -d com.apple.quarantine <binary>` or accepting the
  Gatekeeper prompt once. Should not happen for signed and accepted
  notarized binaries under normal online verification.

## Cost summary

- $99/year Apple Developer Program
- ~5 minutes added to each release build (notarization wait)
- No per-release fee

## Malibu.app release artifacts (SPEC-025 P2)

When `APPLE_DEVELOPER_ID_CERT_P12_BASE64` is populated, the same release
tag also publishes:

- **`Malibu-{tag}.dmg`** — primary consumer download. Drag `Malibu.app`
  to `/Applications`. Notarized and stapled; validate with:
  `bash scripts/verify-malibu-release-artifacts.sh Malibu-{tag}.dmg`
- **`Malibu-{tag}.pkg`** — optional double-click installer when
  `APPLE_DEVELOPER_ID_INSTALLER_CERT_P12_BASE64` is also present.

Fresh-mac acceptance check after each tagged release:

```bash
bash scripts/verify-malibu-release-artifacts.sh Malibu-vX.Y.Z.dmg
```

Expect `codesign --verify`, `stapler validate`, and `spctl` to pass
without `xattr -d`.

## Numeric-ID-only Pearl recovery

Normal Pearl publication uses files captured in the same protected workflow;
it never redownloads by tag. Manual recovery likewise requires the immutable
numeric release ID and the five numeric asset IDs recorded by GitHub. Do not
substitute tag-based download commands or regenerate `checksums.txt`.

```bash
export GITHUB_REPOSITORY=Augustas11/macprovider
export GH_TOKEN='<fine-grained contents:read token>'
export MALIBU_DOWNLOAD_SSH_KEY="$HOME/.ssh/pearl_operator_ed25519"

# Run from an isolated clean worktree whose HEAD is the exact reviewed commit.
test "$(git rev-parse HEAD)" = '<40-hex reviewed origin/main commit>'

bash scripts/recover-malibu-publication.sh \
  vX.Y.Z '<40-hex reviewed origin/main commit>' \
  '<release ID>' \
  '<Malibu DMG asset ID>' \
  '<appcast.xml asset ID>' \
  '<checksums.txt asset ID>' \
  '<checksums.txt.sig asset ID>' \
  '<release-provenance.json asset ID>'
```

Recovery fails unless the numeric release is immutable and its exact tag,
commit, asset IDs, GitHub SHA-256 digests, signed checksums/provenance, Malibu
DMG Apple signature/notarization/staple, Sparkle Ed25519 signature and appcast
URL/length/version all agree. Pearl receives the verified files in an
unpredictable root-owned `0700` staging directory; the helper publishes a
root-owned `0755`/`0644` immutable graph. A permanent tag manifest rejects
same-tag drift and versioned download pointers are never retargeted.

## Related

- Memory: `macprovider-launchd-amfi-blocker-macos-26` — full
  discovery write-up
- Memory: `macprovider-release-signing-setup` — separate runbook for
  the existing checksums.txt signing key
- SPEC-003 v0.8.2 — references this as a deploy prerequisite
