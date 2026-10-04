# Spike 1840 — App Attest code-bound posture

This spike answers one question for issue #1840: on macOS 27, can a full Mac
app's main bundle in a user session obtain an Apple App Attest key bound to
`<TeamID>.tech.malibu.app`, and can that same app accept a Developer ID
`live.malibu.provider.cli` child while ad-hoc re-signed copies of the app and
of the child are refused?

It is not production code. Everything lives under `spike/1840-app-attest/`
plus `.github/workflows/spike-1840-app-attest.yml`.

## macOS 27 requirement

App Attest on macOS works only on macOS 27 or later, and only from a full Mac
app's main bundle running in the user's graphical session. CLIs, daemons, and
extensions do not get attestations. `DCAppAttestService.isSupported` is the
gate; the app does not call `generateKey` when it is false.

The attested key is bound to the App ID. On macOS Apple uses the code
**signing identifier** in place of the bundle id, so the App ID is
`<TeamID>.<signing identifier>`. `build-and-sign.sh` signs with
`--identifier "$BUNDLE_ID"`, so for this app both are `tech.malibu.app`.

The attestation leaf carries an `aclBlob` extension, OID
`1.2.840.113635.100.8.6`. Apple documents one accepted octet-string value,
meaning SIP and Full Security are both enabled:
`MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB`.

## Layout

| Path | Role |
| --- | --- |
| `app/project.yml` | XcodeGen spec (source of truth). The generated `.xcodeproj` and build products are gitignored. |
| `app/MalibuAttestSpike/` | The app: runs every probe, writes one JSON result, exits. |
| `child/main.swift` | Tiny CLI child. `--spike-sleep N` sleeps N seconds (default 30). |
| `verifier/` | Go module `spike1840verifier` (stdlib only), command `appattest-verify`. |
| `verifier/Apple_App_Attestation_Root_CA.crt` | Pinned Apple App Attestation Root CA. |
| `scripts/build-and-sign.sh` | Entitlements from the profile, unsigned build, embed profile, sign once. |
| `scripts/make-negative-copies.sh` | Ad-hoc copies of the app and the child for the negative cases. |
| `scripts/run-on-target.sh` | Runs every case on the target Mac, collects JSON, runs the verifier. |

Root CA SHA-256 (DER):
`1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932`.
The verifier refuses a root that is not a self-signed CA with this fingerprint.

## Account-owner steps

1. In the Apple Developer account, enable App Attest on the explicit App ID
   `tech.malibu.app` (not a wildcard).
2. Create a **Developer ID** provisioning profile for that App ID. Its
   entitlements must include
   `com.apple.developer.devicecheck.appattest-environment`
   (`production` or `development`), the application identifier
   `<TeamID>.tech.malibu.app`, and `com.apple.developer.team-identifier`.
3. `base64 -i profile.provisionprofile | pbcopy`, then set the repository
   secret `MALIBU_APP_ATTEST_PROFILE_BASE64`.
4. The workflow reuses the release secrets
   `APPLE_DEVELOPER_ID_CERT_P12_BASE64`, `APPLE_DEVELOPER_ID_CERT_PASSWORD`,
   `APPLE_NOTARY_APPLE_ID`, `APPLE_NOTARY_PASSWORD`, `APPLE_NOTARY_TEAM_ID`.
5. Push a `spike/1840-*` branch or run the workflow manually, then download
   the artifact `spike-1840-app-attest`: `MalibuAttestSpike.zip` (notarized,
   stapled), `live.malibu.provider.cli.zip` (Developer ID, hardened runtime,
   notarized), `appattest-verify` (darwin/arm64), `entitlements.plist`, and
   `appattest-environment.txt`. The profile and certificate are never
   uploaded.

`build-and-sign.sh` prints every entitlement key in the profile and fails
closed when no `com.apple.developer.devicecheck.*appattest*` key exists, or
when the profile's application identifier or team does not match. It keeps
only `application-identifier`, `com.apple.application-identifier`,
`com.apple.developer.team-identifier`, every `com.apple.developer.devicecheck.*`
key, and `keychain-access-groups`.

## Run on the target Mac

Use a macOS 27 Mac and a shell inside the logged-in GUI session (Terminal or
Screen Sharing), not a bare SSH session.

```bash
ditto -x -k MalibuAttestSpike.zip .
ditto -x -k live.malibu.provider.cli.zip .
chmod +x appattest-verify

bash spike/1840-app-attest/scripts/make-negative-copies.sh \
  --app ./MalibuAttestSpike.app \
  --child ./live.malibu.provider.cli \
  --out ./negative

bash spike/1840-app-attest/scripts/run-on-target.sh \
  --app ./MalibuAttestSpike.app \
  --adhoc-app ./negative/MalibuAttestSpike-adhoc.app \
  --adhoc-noent-app ./negative/MalibuAttestSpike-adhoc-noent.app \
  --child ./live.malibu.provider.cli \
  --adhoc-child ./negative/child-adhoc \
  --out ./results \
  --team TEAMID --bundle tech.malibu.app --env production \
  --verifier ./appattest-verify
```

Use `--env development` when `appattest-environment.txt` says `development`
(AAGUID `appattestdevelop`, default category 3). Production expects AAGUID
`appattest` + 7 zero bytes and category 6 (Developer ID).

Negative copies:

- `MalibuAttestSpike-adhoc.app` — `codesign --force --sign -` with the signed
  app's entitlements and the profile still embedded. AMFI may refuse to launch
  it because the restricted entitlements are no longer backed by the profile;
  a launch that writes no result is recorded as a refusal.
- `MalibuAttestSpike-adhoc-noent.app` — ad-hoc, no entitlements, no profile.
  It launches and shows what `DCAppAttestService` does for unentitled code.
- `child-adhoc` — the child ad-hoc re-signed with the same identifier, so a
  failing check is about the signature, not the name.

`run-on-target.sh` launches each app through LaunchServices
(`open -W -n --env ...`, 300 s timeout; `--launch exec` runs the binary
directly instead) and writes `results/<case>.json`, the verifier output
`results/<case>.verify.txt`, and `manifest.tsv`:

| Case | Expected |
| --- | --- |
| `signed-app-devid-child` | attestation + assertions verify; child check passes |
| `signed-app-adhoc-child` | attestation verifies; child check fails |
| `adhoc-app-devid-child` | refused: no result, unsupported, an error, or an attestation the verifier rejects |
| `adhoc-noent-app-devid-child` | same as above |

It exits non-zero when a signed result is missing, the signed app reports
`is_supported=false` or writes no attestation, a signed attestation or
assertion fails verification, the child checks do not split as expected, or an
ad-hoc app produces an attestation the verifier accepts. It uses `go run` from
`verifier/` when `--verifier` is not given and Go is installed.

App inputs: `SPIKE_RESULT_PATH`, else the first positional argument, else
`~/Library/Application Support/MalibuAttestSpike/result.json`.
`SPIKE_CHILD_PATH` (or `--child`) launches that executable with
`--spike-sleep 5`. `SPIKE_CHILD_REQUIREMENT` (or `--child-requirement`)
replaces the default requirement:

```text
anchor apple generic and certificate leaf[subject.OU] = "<own team>" and identifier "live.malibu.provider.cli"
```

The team comes from the app's own signature and must be alphanumeric; an
unsigned or ad-hoc app has no team, so its child check is recorded as not run.

## Result fields

| Field | Meaning |
| --- | --- |
| `os_version`, `os_version_string` | `ProcessInfo` version and the full string with build. |
| `bundle_identifier`, `bundle_version` | Running bundle id and short version. |
| `is_supported` | `DCAppAttestService.shared.isSupported`. |
| `secure_enclave_available` | `SecureEnclave.isAvailable`. |
| `identity.team_id`, `.identifier`, `.cdhash` | `SecCodeCopySelf` + `SecCodeCopySigningInformation`; cdhash is lowercase hex. |
| `identity.embedded_provisioning_profile`, `.profile_bytes` | Whether `Contents/embedded.provisionprofile` exists, and its size. |
| `identity.entitlements`, `.os_status`, `.error_description` | Signed entitlements (string form), signing-info status, SecCode error. |
| `nonce_b64` | 32 random bytes. `attestKey` gets `clientDataHash = SHA256(nonce)`. |
| `key_id` | Key identifier from `generateKey` (base64 of SHA-256 of the public key). |
| `attestation_b64` | Attestation object. |
| `assertions[]` | Two assertions in order: `client_data`, `client_data_b64`, `assertion_b64`. |
| `client_data`, `assertion_b64` | Copies of the first assertion. |
| `attest_stage` | `skipped`, `nonce`, `generate_key`, `attest_key`, `assertion_1`, `assertion_2`, `complete`; on failure the stage that threw. |
| `attest_error` | `domain`, `code`, `description` of the `NSError`, or null. |
| `child.pass`, `.os_status`, `.os_status_name` | `SecCodeCheckValidity` of the guest found by PID against `child.requirement`. |
| `child.cdhash`, `.team_id`, `.identifier` | Child signing information. |
| `child.flags`, `.flags_hex`, `.flag_names`, `.unnamed_bits_hex` | `kSecCodeInfoStatus` from `kSecCSDynamicInformation`, with `SecCodeStatus` and xnu `CS_*` names (`CS_RUNTIME` = hardened runtime). |
| `child.audit_token` | Same check through an audit-token guest lookup. Token bytes are never stored. |

The posture document (`client_data`) is compact sorted-key JSON:
`bundle_id`, `challenge` (= `nonce_b64`), `purpose` (`spike-1840-posture`),
`seq` (1, then 2), `team_id`.

## Verifier

```bash
appattest-verify verify-attestation --result r.json --team TEAMID --bundle tech.malibu.app [--env production|development] [--expect-category N|any] [--bundle-version V] [--acl require|record]
appattest-verify verify-assertion   --result r.json --team TEAMID --bundle tech.malibu.app [same flags]
appattest-verify dump --result r.json
```

`verify-attestation` follows Apple's "Validating apps that connect to your
server":

1. CBOR `fmt` = `apple-appattest`, `attStmt` with `x5c` and a non-empty `receipt`.
2. `x5c` = leaf + intermediate, chained by signature to the pinned root only
   (no system roots), with validity periods checked.
3. `nonce = SHA256(authData || clientDataHash)`, where `clientDataHash =
   SHA256(nonce_b64 bytes)`, equals the octet string in leaf extension
   `1.2.840.113635.100.8.2` (`SEQUENCE { [1] OCTET STRING }`).
4. aclBlob `1.2.840.113635.100.8.6`: printed as hex, DER dump, and inner
   base64. With `--acl require` (default) it must equal Apple's documented
   SIP + Full Security value; `--acl record` only reports it.
5. `key_id` = SHA-256 of the uncompressed leaf P-256 point; COSE key = leaf key.
6. `rpIdHash` = SHA-256(`TEAMID.bundle`); counter = 0; AAGUID per `--env`;
   `credentialId` = `key_id`.
7. `apple_validation_category_01` (0, 7, 8, 9 always fail; default 6
   production, 3 development) and `apple_bundle_version_01` in the
   authenticator-data extensions.

The receipt is not sent to Apple's fraud-metric service.

`verify-assertion` re-runs the attestation, then for each assertion: CBOR
`{signature, authenticatorData}`, `nonce = SHA256(authenticatorData ||
SHA256(clientData))`, ECDSA P-256 verification of the DER signature over
`nonce` (ECDSA-SHA256, so the curve digest is SHA-256(nonce)), `rpIdHash`, a
counter that is above 0 and strictly increasing, the `challenge` in the client
data equal to `nonce_b64`, and the extension values when present.

Exit codes: 0 pass, 1 verification failure, 2 usage.

Tests (`go test ./...`) cover the CBOR decoder, a self-made CA chain that must
fail against the Apple root, synthetic attestations and assertions built in
test code, and a known-answer test of Apple's published sample attestation
from the "Attestation Object Validation Guide" against the pinned root.

## Pass criteria

1. The Developer ID app on macOS 27 reports `is_supported=true`, and
   `verify-attestation` passes against the Apple root for
   `<TeamID>.tech.malibu.app`.
2. `verify-assertion` passes and the counter increases.
3. The ad-hoc re-signed app is refused: no result (launch refused),
   `is_supported=false`, or a `generateKey` / `attestKey` error.
4. In the signed app's results the Developer ID child check passes and the
   ad-hoc child check fails.
5. The aclBlob is present and its decoded contents are recorded
   (`acl_blob_inner_b64`, `acl_blob_inner_der`, `acl_blob_full_security`).

An unsigned local build on macOS 26 or earlier writes `is_supported=false` and
`attest_stage=skipped`; that is a compile check, not a pass.
