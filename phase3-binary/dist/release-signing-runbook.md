# Release signing + notarization — operator runbook

The release workflow (`.github/workflows/release.yml`) signs the
`macprovider-cli` binary with a Developer ID Application certificate and
notarizes via `xcrun notarytool` so freshly-installed binaries pass
macOS 26.3.1+ launchd's tightened AMFI policy.

The signing step is **conditional on operator-supplied secrets**. If
`APPLE_DEVELOPER_ID_CERT_P12_BASE64` is empty, the step emits a
GitHub Actions warning and ships an adhoc-signed binary (current
behavior). Fresh installs on macOS ≥ 26.3.1 will fail
`launchctl bootstrap` until the secrets are populated. This runbook
documents the one-time operator setup.

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

### 3. Generate an app-specific password for notarytool

At <https://appleid.apple.com/account/manage> → App-Specific Passwords →
Generate. This is **separate** from your Apple ID password — `notarytool`
will not accept the main password. Label it "macprovider notarytool".

### 4. Find your Team ID

<https://developer.apple.com/account> → Membership → Team ID. Looks
like a 10-character alphanumeric string.

### 5. Populate GitHub Secrets

At <https://github.com/Augustas11/macprovider/settings/secrets/actions>,
add these repository secrets:

| Secret name | Value |
|---|---|
| `APPLE_DEVELOPER_ID_CERT_P12_BASE64` | `base64 -i path/to/cert.p12 \| pbcopy` |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | The .p12 export password from step 2 |
| `APPLE_NOTARY_APPLE_ID` | The enrolled Apple ID email |
| `APPLE_NOTARY_PASSWORD` | The app-specific password from step 3 |
| `APPLE_NOTARY_TEAM_ID` | The Team ID from step 4 |

The existing `MACPROVIDER_RELEASE_SIGNING_KEY_PEM` secret
(checksums.txt signing) is unrelated and stays as-is.

### 6. Cut a release and verify

Push a new tag (e.g. `v1.3.2`). The workflow's "Sign + notarize binary"
step now activates. Expected duration: 1-15 minutes for notarization,
on top of the existing ~5-10 minute build. The step:

1. Imports the `.p12` into a transient keychain
2. Codesigns the binary with `--options runtime --timestamp`
3. Notarizes via `xcrun notarytool submit --wait`
4. Staples the notarization ticket to the binary
5. Re-tars with the signed binary
6. Deletes the transient keychain

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

- **"the certificate could not be validated"** — notarization succeeded
  but staple failed. The binary is online-verifiable but launchd's
  offline-only check rejects it. Re-run `xcrun stapler staple` locally
  and republish the tarball.
- **"Notarization request was not found"** — `notarytool submit` was
  invoked without `--wait` (or it timed out), so the ticket never
  attached. Re-trigger the workflow.
- **"developer cannot be verified"** — Gatekeeper, not AMFI. Clears
  with `xattr -d com.apple.quarantine <binary>` or accepting the
  Gatekeeper prompt once. Should not happen for stapled binaries.

## Cost summary

- $99/year Apple Developer Program
- ~5 minutes added to each release build (notarization wait)
- No per-release fee

## Related

- Memory: `macprovider-launchd-amfi-blocker-macos-26` — full
  discovery write-up
- Memory: `macprovider-release-signing-setup` — separate runbook for
  the existing checksums.txt signing key
- SPEC-003 v0.8.2 — references this as a deploy prerequisite
