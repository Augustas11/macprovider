# Privacy class beta operations

SPEC-049 `operator_constrained_beta_v1` is default-off. Turn it on only for a provider whose Secure Enclave key and signed release identity are pinned, and only while the gateway and the buyer client are on as well. A request that asks for the class either completes inside the class or fails with a typed error. It does not fall back to ordinary relay-blind or plaintext.

These commands print public material only. Do not print, log, or copy private key bytes.

## Pin the provider

On the provider Mac, print the Secure Enclave public key and the relay-blind identity:

```bash
macprovider-cli privacy-class identity --state-dir /absolute/relay-blind-state --model <model-id>
```

`--config` can replace `--state-dir` and `--model` when the config already names them. Stdout is one JSON object with these keys:

- `se_public_key` (standard base64 of the raw 64-byte P-256 X||Y point)
- `se_key_backend` (`file` or `keychain`)
- `relay_blind_identity_public_key`
- `relay_blind_fingerprint`
- `code_cdhash`
- `team_id`
- `binary_version`

Put `se_public_key` in the coordinator pin for that provider id. Put `relay_blind_identity_public_key` in `relay_blind.identity_public_keys` for the same provider id. The buyer identity pin uses `relay_blind_identity_public_key` and `relay_blind_fingerprint`.

Derive `approved_code_identities` from the signed release binary, not from an unsigned local build:

```bash
scripts/privacy-class-code-identity.sh /path/to/signed/macprovider-cli
```

The script prints one `cdhash=` line per architecture, then `TeamIdentifier=` and `Identifier=`. Those three values are `code_cdhash`, `team_id`, and `signing_identifier`. Set `expires_at` to a future RFC3339 timestamp. Leave `binary_version` empty to accept any binary version of that exact team, identifier, and cdhash, or set it to the release version to pin one build.

The `code_cdhash` from `privacy-class identity` is the binary you just ran. Use the script on the signed release when that is the binary you intend to approve.

## Enable each component

All four have to be on. Each one stays off when its flag is absent.

Provider. Requires relay-blind. Any one of these turns the class on:

- flag `--privacy-class-beta`
- config `privacy_class_beta: true`
- environment `MACPROVIDER_PRIVACY_CLASS_BETA=true`

The flag overrides the environment variable and the config key.

Coordinator. Requires `relay_blind.enabled: true`, at least one `provider_se_public_keys` entry, and one unexpired approved identity:

```yaml
privacy_class:
  enabled: true
  provider_se_public_keys:
    <provider_id>: <se_public_key>
  approved_code_identities:
    - team_id: <TeamIdentifier>
      signing_identifier: <Identifier>
      code_cdhash: <cdhash>
      expires_at: "2026-12-31T00:00:00Z"
  allowed_se_key_backends: [file, keychain]
```

Omitted timing keeps the defaults: challenge interval 60s, response timeout 10s, max age 150s, quarantine 86400s. The provider must be a WebSocket session. Privacy keys are advertised only as `privacy_key_records` and are a separate class from relay-blind keys.

Gateway. Requires `features.relay_blind_requests.enabled: true`:

```yaml
features:
  privacy_class:
    enabled: true
```

Buyer client:

```bash
relay-blind-client --privacy-class --base-url https://gateway.example --identity-pin /absolute/pin.json --model <model-id> --max-output-tokens 256 --input-token-upper-bound 1024 --input request.json
```

A satisfied run prints `privacy class satisfied` on stderr, then the class, assurance, scope, and each residual risk below. Decrypted text goes to stdout.

### Code-bound provider (SPEC-049 v0.2, default off)

Only a Malibu.app that supervises its own embedded `macprovider-cli` can earn `code_bound_attested`. The launchd provider, the standalone CLI, and any Mac older than macOS 27 stay on `device_bound_self_attested_beta`.

1. The release Malibu.app must carry the Developer ID App Attest profile. CI embeds it from the `MALIBU_APP_ATTEST_PROFILE_BASE64` secret (`scripts/prepare-malibu-app-attest-signing.py`). The embedded CLI is signed with no entitlements.
2. Keep `privacy_class_beta: true` and relay-blind on in the provider config.
3. Stop the launchd provider. While it runs, Malibu does not supervise and the provider keeps the Beta label.
4. Turn the app setting on, then restart Malibu: `defaults write tech.malibu.app privacyCodeBound -bool true`.

Malibu then runs `macprovider-cli serve --privacy-code-bound --privacy-supervisor-socket <socket>` itself. The socket lives in `~/Library/Application Support/Malibu/privacy/` (directory 0700, socket 0600). Before every key request, attestation, and assertion, Malibu checks the child by its kernel audit token: PID and PID version, team, `live.malibu.provider.cli`, the cdhash of the CLI sealed in its own bundle, and the code-signing flags. If that check fails, Malibu stops the child and does not start it again until Malibu itself restarts. Only the keyId is stored on disk, in `~/Library/Application Support/Malibu/privacy/app-attest-key-id`. The key stays in the Secure Enclave.

To go back to Beta, run `defaults delete tech.malibu.app privacyCodeBound`, quit Malibu, and start the launchd provider again.

## Incident and revocation

The control plane is the relay-blind SQLite file named by `relay_blind.sqlite_path`. `coordinator-cli` opens that file directly. Do not restart the coordinator for these commands. The next reservation, consume, or dispatch reads the new row.

```bash
coordinator-cli privacy-class status --config /path/to/coordinator.yaml
coordinator-cli privacy-class disable --config /path/to/coordinator.yaml --reason "visible ASCII, 1-128 chars"
coordinator-cli privacy-class enable --config /path/to/coordinator.yaml
coordinator-cli privacy-class quarantine --config /path/to/coordinator.yaml --provider <provider_id> --reason "visible ASCII, 1-128 chars" --seconds 3600
coordinator-cli privacy-class unquarantine --config /path/to/coordinator.yaml --provider <provider_id>
```

`--seconds` is 1 through 2592000 (30 days).

Kill switch. `disable` blocks privacy-class reservation, consume, and dispatch from the next request, and rejects held predispatch privacy reservations. Buyers see `privacy_class_disabled`. Plain SPEC-041 relay-blind and plaintext traffic keep working. `enable` clears the switch.

Quarantine. `quarantine` makes that provider ineligible for the privacy class until the timer expires or `unquarantine` runs. Buyers see `privacy_class_unavailable`. The CLI quarantine command does not itself delete key records.

Key revocation. A failed posture check (unapproved code identity, a mismatched cdhash, a bad Secure Enclave signature, and the other posture failures that quarantine) both quarantines the provider and revokes its outstanding privacy key records. After that, the provider stays ineligible until the quarantine ends and a new posture verifies.

Rotation by restart. The privacy X25519 agreement key is kept in process memory and lives at most 3600 seconds. It is not written to disk. Restart the provider process to mint a new agreement key. The Secure Enclave P-256 key and the Ed25519 relay-blind identity persist across that restart. The provider is ineligible until the next posture challenge verifies. Do not copy private key files to rotate.

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
