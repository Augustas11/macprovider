# SPEC-034 — Independently versioned Malibu releases

Status: DRAFT v0.1 · Owner: release security/provider lifecycle · Target: Issue #585

## 1. Decision

Malibu and `macprovider-cli` are independently versioned components. App marketing
versions and build numbers MUST NOT be compared with provider CLI versions to decide
security, compatibility, discovery, installation, rollback, or UI state. Compatibility
is granted only by a signed `malibu.release-envelope.v1` binding an exact Malibu
artifact to allowlisted provider compatibility sets and capabilities.

The first permitted tuple is:

| Component | Exact identity |
| --- | --- |
| Malibu | version `1.8.41`, build `41`, tag `malibu-v1.8.41` |
| Provider CLI | immutable public `v1.8.40` |
| Provider set | `Augustas11/macprovider:v1.8.40@18638472fe3e885f3534eeac29ab89b4c7ffdd7a` |
| Set envelope SHA-256 | `fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c` |
| Malibu identity | bundle `tech.malibu.app`, Team `YF7XNRJUG4` |
| CLI identity | identifier `live.streamvc.macprovider.cli`, Team `YF7XNRJUG4` |

This exception does not modify, append to, retag, or rebuild v1.8.40. If Malibu
packaging embeds a CLI, its bytes MUST match the published artifact and the app-only
transaction MUST NOT replace the installed provider.

## 2. Envelope and trust

The JSON wrapper contains `schema_version`, exactly one signature, and `signed`.
Duplicate keys are rejected before decoding. The signed payload uses the repository's
CanonicalJSON/JCS contract and binds:

- app tag/namespace, source commit, marketing version, monotonically increasing build,
  publication time, bundle/Team/designated identities, hardened runtime, notarization,
  and stapling;
- exact DMG/package and any embedded CLI SHA-256 values;
- exact supported provider-set IDs and signed-envelope SHA-256 values;
- required CLI identity and local-status, handoff, control-socket, and admission-
  recovery capabilities;
- `provider_mutation: forbidden` for the app-release installation transaction (the
  transaction cannot replace, update, roll back, or retag the provider CLI); and
- any bootstrap bridge as an exact expiring allowlist with source cohort, target
  CLI/set, backend handoff, no downgrade, and no caller-selected target.

The envelope signature is ECDSA P-256/SHA-256 over:

```text
UTF8("malibu.release-envelope.v1") || 0x00 || canonical(signed)
```

The historical bootstrap key ID is `macprovider-release-p256-v1`, pinned by the
app-only transaction's reviewed trust bundle; its SubjectPublicKeyInfo DER SHA-256
is `2cd6171cea8cd7964c12292e3443078c2b3d0cdcc20ae600fe8261090392c7f8`.
The protected release workflow owns the signer through
`MALIBU_RELEASE_ENVELOPE_SIGNING_KEY_PEM`; provider-named signing-secret exposure is
forbidden. Release builds have no unsigned bypass. A production key-separation ceremony
must provision a Malibu-dedicated successor before the historical bootstrap key can be
retired through the signed overlap protocol.

## 3. Separate signed discovery

Provider CLI selection remains SPEC-020's authenticated coordinator target and exact
signed release-by-tag path. Malibu uses only a signed index in the `malibu-v*`
namespace. GitHub `/releases/latest`, `latest.dmg`, and appcasts are never cross-
component authority.

Provider public releases and short-lived private acceptance candidates are provider-
only transactions: neither may build, sign, index, or export a Malibu artifact. App
acceptance uses the same protected `malibu-v*` release transaction described here.

The Malibu index uses the distinct `malibu.release-index.v1` NUL-separated signature
context. It binds repository, channel, envelope digest, tag/commit, artifact IDs and
digests, monotonically increasing index generation and app build, minimum envelope
generation, and issue/expiry times. Normal indexes expire within 604800 seconds and
may be at most 300 seconds future-dated. App-only publication uses
`make_latest=false` and proves generic latest plus the provider index remain v1.8.40.

The schema-validated keyring and revocation documents committed with the implementation
are signed, generation-numbered, and index-bound by digest. Unknown/revoked keys,
revoked or rolled-back keyring generations, expired/future indexes, digest mismatch,
generation rollback, and older otherwise-valid builds fail before mutation.

## 4. Anti-replay and rollback

Malibu atomically persists the highest accepted index generation, build, envelope
generation, digest, active release, rollback grant, and key-transition state in an
authenticated Keychain record scoped to the signed app identity. An absent record
bootstraps only from a currently valid first-install transaction; missing protected
state in the presence of prior Malibu-release evidence and corrupt state are hard errors.
The authenticated package additionally replaces one global, root-owned
`/Library/Application Support/Malibu/AppInstaller/installed-marker.json` after a
successful app transaction. That marker binds the current app version/build and exact
envelope, index, and retained recovery-helper digests. A Keychain reset may therefore
bootstrap only the exact current package-installed release; a restored older app cannot
reuse a retained version-specific helper to reset the release high-water mark.
Before the user transaction begins, the package writes a separate root-owned
`pending-recovery.json` containing the incoming app identity plus exact envelope,
index, helper, validator, keyring, revocation, and public-key digests. It selects the
journal-writing helper after a crash and is also the narrowly scoped bootstrap
authority if the new tuple committed but postinstall died before the final marker.
It is removed only after the final marker is durable.

Rollback requires a separate signed `malibu.release-rollback.v1` authorization naming
current and target generations/builds/digests, incident, issuer, issue/expiry times,
and a one-use nonce. Release security issues it with distinct operator approval. Key
rotation requires an audited keyring update and an overlap index accepted by retiring
and successor policies before retirement. Revocation arrives only in a higher signed
keyring/index generation.

## 5. Runtime ownership

Malibu validates its own envelope and installed CLI/set identity; it never infers
compatibility from equal versions. Unsupported tuples report a precise reason before
mutation. The app may request existing CLI-owned control operations, but Malibu remains
a non-secret observer and does not become the authority for credentials, admission
identity, config, launchd, provider update, rollback, or uninstall.

After a legacy migration failure, observation is allowed only with existing config,
proven launchd ownership, and fresh local health. This mode opens no control socket,
exposes no mutation action, writes no ownership/custody marker, makes no buyer-serving
claim, and displays `Running locally — migration repair required`.

Credential import/verification are CLI Keychain operations. YAML token removal occurs
only after a restarted CLI authenticates and emits
`provider_token_legacy_source_removed_after_admission`. Malibu markers follow fresh-
process CLI verification only.

## 6. Immutable v1.8.40 boundary

New source cannot alter public v1.8.40. Acceptance runs its exact installer,
self-update, recovery, and rollback paths. Supported order is CLI v1.8.40 first, then
the Malibu app-only transaction. Afterwards, provider autoupdate remains disabled,
provider discovery advertises no version beyond v1.8.40, the exact v1.8.40 `update`
path returns no-update/fails before app mutation, and rollback never silently
downgrades Malibu 1.8.41. Any contrary result blocks publication.

## 7. Completion gates

The protected Malibu workflow rebuilds, signs, notarizes, staples, envelopes, and
publishes exact reviewed candidate bytes in one protected job. The supported entrypoint
is a Developer ID Installer signed, notarized, stapled app-only `.pkg`; an unsigned ZIP
or shell script is not a supported installation entrypoint. Promotion binds repository, tag, commit,
release/artifact IDs, artifact and envelope/index digests, signer, and append-only app
build ledger. A rebuild restarts acceptance.

Local completion requires the Malibu suite; canonicalization/signature, duplicate-key,
keyring, expiry, rollback, cross-version, distribution, and exact-v1.8.40 mutation
tests; plus independent code, security, architecture/operations, and UX audits at zero
CRITICAL/HIGH/MEDIUM.

Production additionally requires named Pearl/Mac/auth-requester/distinct-approver/
evidence/rollback roles, confirmed signing and notarization credentials, at least 3600
seconds of the scoped exemption at apply start, durable admission-identity recovery,
exemption removal, restart/logout/reboot and buyer proof, Issue #584, the authorized
second-Mac matrix, and a 24-hour exemption-free 2/2 soak. Local implementation may
advance before these external inputs, but rollout and Issue #585 closure may not.
