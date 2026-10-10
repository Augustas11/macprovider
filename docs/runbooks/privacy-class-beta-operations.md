# Privacy class beta operations

SPEC-049 `operator_constrained_beta_v1`, v0.2.0. The coordinator, gateway, and buyer client keep the class off until you enable it. A provider enters the class on its own when it runs an eligible signed release, and the coordinator enrolls its keys without a per-provider step. A request that asks for the class either completes inside the class or fails with a typed error. It does not fall back to ordinary relay-blind or plaintext.

These commands print public material only. Do not print, log, or copy private key bytes.

Production activation. The v0.1.4 staged canary (SPEC-049 §8.1, Entry 249) covers 0.1.x code with one pinned provider only. Do not run v0.2.0 code with `privacy_class.enabled: true` in production under that exception; automatic enrollment needs its own dated exception or SPEC-049-R023 promotion first (SPEC-049 §8.2).

## What enrollment trusts

The coordinator enrolls a provider ID's Secure Enclave key and relay-blind identity from the first posture that verifies for that provider's live, authenticated session under an approved signed code identity. That record is the pin from then on. A later different key quarantines the provider and is never enrolled on its own.

Enrollment trusts whoever completes that first attested session. Posture is device-bound, not code-bound, so a modified binary or a holder of the provider credential that connects first is enrolled like the real device. The coordinator host also holds the directory signing key, so a compromised coordinator can vouch for an identity of its choice. Buyers who must keep the coordinator out of identity trust use `--identity-pin`. Operators who must pin one device use the configuration pins below.

## Providers

Nothing to do. On `macprovider-cli serve`, with `privacy_class_beta` unset, the provider runs a read-only check: code signature and hardened-runtime flags, team and signing identifier, no debug entitlements, SIP on, not traced, no diagnostic environment variables, native in-process runtime, KV disk tier off, Secure Enclave identity, and the state directory. If every check passes it turns on relay-blind and privacy mode, uses `~/.config/macprovider/relay-blind` unless `relay_blind_state_directory` is set, runs the SPEC-049-R007 hardening, and advertises its privacy keys and enrollment claim.

If a check fails the provider serves ordinary traffic and logs one line:

```text
privacy_class auto_ineligible reasons=<codes>
```

If the hardening itself fails it also serves ordinary traffic and logs `privacy_class auto_hardening_failed reasons=<codes>`. Dev, unsigned, ad-hoc-signed, SIP-off, loopback-runtime, and KV-disk-tier hosts land here. Autotune candidates and `--no-join` runs never try.

Opt out with any one of these:

- flag `--no-privacy-class-beta`
- config `privacy_class_beta: false`
- environment `MACPROVIDER_PRIVACY_CLASS_BETA=false`
- any explicit `relay_blind_enabled` value (flag, environment, or config). `false` turns relay-blind off; `true` keeps plain SPEC-041 relay-blind with its pinned identity instead of the privacy class

Force it on with `--privacy-class-beta`, `privacy_class_beta: true`, or `MACPROVIDER_PRIVACY_CLASS_BETA=true`. Forced mode turns relay-blind on unless it is explicitly off, which is a configuration error, and it exits non-zero with `FATAL privacy_class_hardening_failed` when the hardening fails.

To see what a provider will present, on the provider Mac:

```bash
macprovider-cli privacy-class identity --state-dir ~/.config/macprovider/relay-blind --model <model-id>
```

It prints `se_public_key`, `se_key_backend`, `relay_blind_identity_public_key`, `relay_blind_fingerprint`, `code_cdhash`, `team_id`, and `binary_version`.

## Coordinator

Create the directory signing key once, on the coordinator host, as the coordinator user:

```bash
coordinator-cli privacy-class directory-keygen --out /etc/macprovider/privacy-directory.key
```

It refuses to overwrite a file, writes the 32-byte seed as base64url with mode 0600, and prints `directory_public_key=` and `directory_key_id=`. The coordinator refuses a key file that is a symlink, not mode 0600 or 0400, or not owned by the coordinator user or root. This key is online by design: the directory changes whenever a provider enrolls. Do not reuse the release signing key or any SPEC-023 static-feed key (`streamvc-autotune-static-v4` and the like) here, and never put those offline keys on the coordinator host.

Enable the class. It requires `coordinator.require_gateway_context: true` and `relay_blind.enabled: true` with a `sqlite_path`. Under `settlement.verified_model_settlement_mode: enforce`, relay-blind also requires the SPEC-022 R-14 profile:

```yaml
coordinator:
  require_gateway_context: true
relay_blind:
  enabled: true
  sqlite_path: /var/lib/macprovider/relay-blind.db
  enforce_settlement_profile: relay-blind-settlement-v1
privacy_class:
  enabled: true
  release_code_identities:
    metadata_dir: /opt/macprovider/privacy-release-identities
    public_key_path: /usr/local/share/macprovider/release-signing-public.pem
  directory:
    signing_key_path: /etc/macprovider/privacy-directory.key
    ttl_seconds: 300
  allowed_se_key_backends: [file, keychain]
```

`relay_blind.identity_public_keys` and `privacy_class.provider_se_public_keys` may stay empty. `public_key_path` is the PEM P-256 release signing key, the same bytes as `ops/pearl-updater/release-signing-public.pem` (on Pearl the updater's pinned copy at `/usr/local/share/macprovider/release-signing-public.pem`). Omitted timing keeps the defaults: challenge interval 60s, response timeout 10s, max age 150s, quarantine 86400s.

### Approved code identities

A provider's privacy advertisement is refused as `posture_unapproved_code_identity` (no quarantine, only a coordinator log line and the `relayblind_privacy_posture_rejections_total{reason="posture_unapproved_code_identity"}` counter) until its code identity is approved from one of two sources:

- **Release metadata (hot).** Each `<tag>.json` in `metadata_dir` with a sibling `<tag>.json.sig` is re-verified against `public_key_path` at startup and on every challenge interval (~60 s), and approves `(team_id, signing_identifier, code_cdhash, binary_version)`. Files that fail are skipped and logged by name. An unreadable directory approves nothing until it reads again. `relayblind_privacy_release_identity_loaded{binary_version}` on `/admin/metrics` lists the versions approved this way.
- **`approved_code_identities` (restart-only).** Config entries, read only when the coordinator starts.

Two writers fill `metadata_dir`, because CLI releases and Pearl runtime releases use separate tags:

- **CLI releases:** `scripts/ops/cli-release.sh` step `privacy_release_identity`, right after the candidate's signed bytes are verified and before any canary or fleet provider runs it, copies the verified `pearl-release.json` and signature to `metadata_dir` as `v<ver>.json` and `v<ver>.json.sig` (`root:macprovider`, mode 0640, payload before signature). No restart. The `registrations` gate then refuses the canary, promotion, the recommendation bump and rollout verification until the running coordinator holds the registration: the file verifies and `relayblind_privacy_release_identity_loaded{binary_version="<ver>"}` is 1 on the coordinator, or an `approved_code_identities` entry is in a config whose sha256 equals the running process's boot `coordinator_config_applied` digests.
- **Pearl runtime releases:** the Pearl updater writes the same pair for a runtime tag whose `pearl-release.json` carries `provider_code_identity`.

#### One-time setup (Pearl)

This is the `cli-release.sh` step `privacy_release_setup`; run it with `scripts/ops/cli-release.sh next --run` (it prints the expected downtime, holds the live-ops lock and both Pearl locks, and refuses on a pricing transaction journal). Status reads `privacy_release_metadata_dir` from Pearl itself. The step adds, in place in `/opt/macprovider/coordinator.yaml` (the `privacy_class` block; it refuses when the overlay sets it):

```yaml
privacy_class:
  release_code_identities:
    metadata_dir: /opt/macprovider/privacy-release-identities
    public_key_path: /usr/local/share/macprovider/release-signing-public.pem
```

```bash
install -d -o root -g macprovider -m 0750 /opt/macprovider/privacy-release-identities
```

Before the edit it checks that `/usr/local/share/macprovider/release-signing-public.pem` has the sha256 of `ops/pearl-updater/release-signing-public.pem` and that the coordinator user can read it (a configured key that cannot be read stops startup), and creates the directory (`root:macprovider`, 0750, as the Pearl updater requires). It backs the file up under `/root/macprovider-backups`, validates the edited file with the running coordinator's binary, user and exact environment, replaces it atomically, restarts the coordinator and waits for `/healthz`; on a failed restart it puts back the bytes it read under the same locks. When `accepted_ids` still lacks the candidate it adds it in the same edit, so one restart covers both, and it then stages the candidate's `v<ver>.json`.

Overrides, in this order:

1. `denied_code_cdhashes: [<40 hex>]` refuses that cdhash from any source and quarantines a provider that presents it.
2. An `approved_code_identities` entry for the same team, signing identifier, and cdhash takes over from the release. Set its `expires_at` in the past to withdraw a release.
3. An `approved_code_identities` entry can also approve a build that has no release metadata, as in v0.1.

An identity that is only unapproved (for example a release whose metadata has not reached `metadata_dir` yet) is refused by routing and not quarantined. To fill an entry by hand from a signed release (it carries no `expires_at` unless you pass `--expires-at`):

```bash
scripts/provider-code-identity.py --emit-approved-identity --pearl-release-json pearl-release.json --signature pearl-release.json.sig
```

### Operator pins (optional)

To pin one device instead of trusting its first attested session, set both keys for its provider ID. Configured pins override enrollment, and that provider is never enrolled:

```yaml
relay_blind:
  identity_public_keys:
    <provider_id>: <relay_blind_identity_public_key>
privacy_class:
  provider_se_public_keys:
    <provider_id>: <se_public_key>
```

A Secure Enclave pin without an identity pin for the same provider ID fails validation.

## Gateway

Requires `features.relay_blind_requests.enabled: true`:

```yaml
features:
  privacy_class:
    enabled: true
```

The gateway serves `GET /v1/privacy-class/directory` to API-key buyers and forwards the coordinator's signed body unchanged. It does not verify or cache it. Wallet-session callers get `privacy_class_unavailable` on that route and use `--identity-pin`.

## Buyer client

Give buyers the `directory_public_key` once, through a channel that does not pass through the gateway or coordinator. Then:

```bash
export MACPROVIDER_PRIVACY_DIRECTORY_PUBLIC_KEY=<directory_public_key>
relay-blind-client --privacy-class --base-url https://gateway.example --model <model-id> --max-output-tokens 256 --input-token-upper-bound 1024 --input request.json
```

`--directory-public-key <key>` works instead of the environment variable. The client fetches the directory, checks the signature against that key, refuses it when expired or issued more than 60 seconds in the future, and after the reservation pins the provider whose fingerprint matches the key record. A missing or revoked entry fails before anything is encrypted. A satisfied run prints `privacy class satisfied`, the class, assurance, scope, each residual risk below, and `identity_pin_source: signed_directory directory_key_id=<id>` on stderr. Decrypted text goes to stdout.

`--identity-pin /absolute/pin.json` overrides the directory and is required with a wallet session.

## Incident and revocation

The control plane is the relay-blind SQLite file named by `relay_blind.sqlite_path`. `coordinator-cli` opens that file directly. Do not restart the coordinator for these commands. The next reservation, consume, or dispatch reads the new row.

Use the same base config and overlay as the running coordinator for every
incident or rollback command, including the abbreviated rollback examples in
SPEC-049 §8.1. When startup uses `--config-overlay`, pass that overlay to the
CLI too; otherwise the command can inspect or mutate a different SQLite store.
The examples below show a deployment with an overlay. Omit `--config-overlay`
only when the running coordinator uses no overlay. This flag requires a CLI
release containing the overlay support; older CLIs need an operator-prepared
effective config containing both files' settings.

```bash
coordinator-cli privacy-class status --config /path/to/coordinator.yaml --config-overlay /path/to/overlay.yaml
coordinator-cli privacy-class disable --config /path/to/coordinator.yaml --config-overlay /path/to/overlay.yaml --reason "visible ASCII, 1-128 chars"
coordinator-cli privacy-class enable --config /path/to/coordinator.yaml --config-overlay /path/to/overlay.yaml
coordinator-cli privacy-class quarantine --config /path/to/coordinator.yaml --config-overlay /path/to/overlay.yaml --provider <provider_id> --reason "visible ASCII, 1-128 chars" --seconds 3600
coordinator-cli privacy-class unquarantine --config /path/to/coordinator.yaml --config-overlay /path/to/overlay.yaml --provider <provider_id>
coordinator-cli privacy-class reenroll --config /path/to/coordinator.yaml --config-overlay /path/to/overlay.yaml --provider <provider_id> --reason "visible ASCII, 1-128 chars"
```

`--seconds` is 1 through 2592000 (30 days). `status` also lists active and recently revoked enrollments by fingerprint and cdhash, never key bytes.

Kill switch. `disable` blocks privacy-class reservation, consume, dispatch, and the directory route from the next request, and rejects held predispatch privacy reservations. Buyers see `privacy_class_disabled`. Plain SPEC-041 relay-blind and plaintext traffic keep working. `enable` clears the switch.

Quarantine. `quarantine` makes that provider ineligible until the timer expires or `unquarantine` runs, and its directory entry is published as revoked meanwhile. Buyers see `privacy_class_unavailable`. The CLI quarantine command does not itself delete key records.

Posture failures. A bad Secure Enclave or identity signature, a denied cdhash, a missing required posture value, a sequence regression, a cdhash change within a session, an attestation cdhash mismatch, or a SPEC-008 key mismatch quarantines the provider and revokes its privacy key records. After that it stays ineligible until the quarantine ends and a new posture verifies.

Key change. A provider whose claim or posture uses a different identity or Secure Enclave key than its enrollment is quarantined with reason `privacy_enrollment_key_changed`. The enrollment is not replaced, and the same new key quarantines again after the timer. Confirm the device change with the provider out of band, then run `reenroll`: it revokes the enrollment, revokes its privacy key records, rejects held predispatch reservations, and clears the quarantine. The next verified posture enrolls the current keys. The old identity stays in the directory as revoked for 30 days.

Rotation by restart. The privacy X25519 agreement key lives in process memory for at most 3600 seconds. Restart the provider process to mint a new one. The Secure Enclave key and the Ed25519 relay-blind identity persist across restarts and upgrades, so enrollment is unaffected. Do not copy private key files to rotate.

Directory key rotation or compromise. Generate a new key with `directory-keygen` at a new path, point `privacy_class.directory.signing_key_path` at it, restart the coordinator, and send buyers the new `directory_public_key`. Tell buyers to drop the old key; directories signed by it stop verifying for clients that switched, and old ones expire within `ttl_seconds`.

## Residual risks

Successful responses carry these headers:

```text
X-MacProvider-Privacy-Class: operator_constrained_beta_v1
X-MacProvider-Privacy-Assurance: device_bound_self_attested_beta
X-MacProvider-Response-Encryption: buyer_provider_aead_v1
```

`usage.macprovider.privacy` uses the same class and assurance. The rest of that object is fixed below, in this order. These strings change only when SPEC-049 bumps its version.

`scope`:

```text
request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_self_attested_device_bound_not_code_bound
```

`protects`:

1. `request_content_from_gateway_and_coordinator`
2. `response_content_from_gateway_and_coordinator`
3. `debugger_attach_to_approved_signed_runtime`
4. `core_dumps_of_approved_signed_runtime`
5. `prompt_and_completion_in_provider_logs_traces_receipts_and_telemetry`
6. `prompt_and_completion_in_provider_disk_and_conversation_caches`
7. `plaintext_proxy_or_subprocess_runtime_hop`
8. `dev_debug_unsigned_or_unapproved_builds_refused_by_routing`
9. `sip_disabled_hosts_refused_by_routing`

`does_not_protect`:

1. `provider_runtime_reads_plaintext_to_infer`
2. `operator_running_a_modified_runtime_binary`
3. `request_metadata_visible_to_relays`
4. `confidential_compute_or_hardware_enclave_execution`
5. `end_to_end_encryption_excluding_the_provider`
6. `pool_scoped_requests`

`residual_risks`:

1. `modified_binary_can_forge_posture_se_key_device_bound_not_code_bound`
2. `root_sip_bypass_kernel_or_firmware_compromise`
3. `physical_or_hardware_attack`
4. `gpu_and_unified_memory_residue`
5. `encrypted_swap_and_hibernation_images`
6. `compromise_of_the_live_runtime_process`
7. `malicious_signed_release_or_supply_chain`
8. `crash_report_register_and_stack_residue`
9. `secure_boot_level_not_evaluated`
10. `immutable_prompt_strings_not_zeroized`
11. `relays_observe_sizes_timing_and_token_counts`
12. `provider_identity_enrolled_on_first_attested_session`
13. `coordinator_operator_signs_provider_identity_directory`
