# Relay-blind pilot key and pin custody

This runbook covers the local, default-off SPEC-041 pilot. It does not authorize production activation, provider contact, or conformance promotion. Never place relay-blind private keys, provider journal files, or helper output in a repository root or task worktree.

## Storage boundaries

Use an operator-selected directory outside the repository with mode 0700 and private-key files mode 0600. Keep the durable Ed25519 relay-blind identity key separate from provider admission credentials, receipt keys, SPEC-008 keys, and the rotatable X25519 encryption key. Configure the coordinator with an independent mapping from authenticated provider ID to the Ed25519 public key/fingerprint; provider self-advertisement is not authority.

The buyer pin is public material but is integrity-critical. Prefer `~/.config/macprovider/relay-blind-pins/<provider>.json` beneath 0700 directories, with the pin mode 0600 or 0644. The reference CLI accepts only `--identity-pin /absolute/local/file.json`; it rejects network URLs, TOFU, discovery defaults, symlinks, writable/foreign-owner ancestry, non-regular files, and files larger than 16 KiB. It must not print private material or full signed records.

## Initial provisioning

1. Create the Ed25519 identity and X25519 encryption keys with the implementation's non-printing key command, writing directly to the operator store.
2. Verify permissions and derive the Ed25519 public fingerprint in memory. Record only the public key and fingerprint.
3. Add the public identity mapping to coordinator operator configuration for the intended authenticated provider ID. Restart or reload through the implementation's audited path while relay-blind buyer success remains disabled.
4. Have the provider advertise a signed single-model key record on its authenticated session. Confirm coordinator verification reports the expected provider/session, fingerprint, scope, validity, and `kid` without displaying private bytes.
5. Build the closed `relay-blind-pilot-pin-v1` public pin with the same public key/fingerprint, model, `chat_completions`, validity, and `revoked: false`.
6. Deliver the pin to the buyer through an authenticated operator channel separate from the gateway/coordinator path. Verify its fingerprint at both ends.

## Planned rotation

Create a new identity or encryption key before expiry. An X25519-only renewal may retain `kid` only when immutable framing is byte-identical; changed key material requires a new `kid`. Identity rotation requires a new coordinator provider-ID mapping and a replacement buyer pin. Do not automatically accept old and new identity pins. Disable new reservations during the cut, revoke the old record, invalidate every old reservation/envelope, distribute the replacement pin out of band, then re-enable only after provider/session and buyer-pin checks agree.

## Emergency revocation or custody loss

Disable relay-blind admission first. Revoke the affected `(provider_id,kid)` durably and retain the record through signed expiry plus replay retention. Invalidate all reservations/envelopes bound to the old identity/key/session. If the Ed25519 identity is lost or suspected exposed, create a new identity rather than reconstructing trust from a relay response; update the independent coordinator mapping and distribute a replacement pin through the authenticated operator channel. Offline buyers remain revoked only when they receive the replacement/revocation out of band; do not claim instantaneous global revocation.

## Recovery and verification

Recover only from the designated operator secret store or its controlled backup. Restore directory/file permissions before use. Verify a candidate identity by deriving its public key/fingerprint in memory and matching the independently recorded coordinator mapping and buyer pin. Never print private bytes. If identity cannot be proven, leave relay-blind admission disabled and rotate trust explicitly.

Provider execution journals are state, not key backups. Preserve them across restart for at least replay retention. A recovered `claimed` or `validated` entry is execution-uncertain and must never reexecute. Journal recovery must not expose bodies, ciphertext, keys, or stable buyer identifiers.

## Post-change checks

- Old reservations and envelopes fail and cannot consume or dispatch.
- New records verify only on the intended authenticated provider/session.
- The replacement pin passes no-follow descriptor, ownership, permission, size, fingerprint, time, and model checks.
- Public responses do not expose stable provider IDs.
- Plaintext and SPEC-008 traffic remain unchanged.
- No key, journal, or helper-output file exists under a repository or worktree.

## Local command surfaces

Build the existing Swift package and the reference client in their module directories:

```bash
cd phase3-binary && swift build
cd ../phase5-gateway && go build -o /tmp/relay-blind-client ./cmd/relay-blind-client
```

The provider key command creates private state directly in the selected operator directory and emits public records only. Supply a canonical model supported by the isolated runtime:

```bash
macprovider-cli relay-blind-key describe --state-dir /absolute/operator-store/relay-blind --model MODEL
macprovider-cli relay-blind-key rotate --state-dir /absolute/operator-store/relay-blind --model MODEL
macprovider-cli relay-blind-key revoke --state-dir /absolute/operator-store/relay-blind --model MODEL --kid PUBLIC_KID
```

Opt the isolated provider into `--relay-blind-enabled --relay-blind-state-directory /absolute/operator-store/relay-blind`. The isolated coordinator needs `relay_blind.enabled`, `relay_blind.sqlite_path`, and `relay_blind.identity_public_keys` mapping the authenticated provider ID to its independently provisioned public key; settlement must remain `observe`. The isolated gateway needs `features.relay_blind_requests.enabled`. These are local test settings, not production activation instructions.

With an independently delivered pin and the buyer credential already loaded securely into `MACPROVIDER_API_KEY`, feed the request on stdin so the command line never contains its content:

```bash
/tmp/relay-blind-client --base-url http://127.0.0.1:8080 \
  --identity-pin /absolute/operator-store/buyer-pin.json --model MODEL \
  --max-output-tokens 32 --input-token-upper-bound 1024 --input -
```

The input JSON model, stream flag, and output cap must match the CLI options. Add `--stream` for streaming. Wallet sessions additionally use `--wallet-session-id` and the named `--wallet-session-key-env`; keys remain in the operator environment. The client performs no automatic retries. A predispatch retry needs a fresh invocation/reservation/envelope; postdispatch uncertainty must be resolved through existing settlement recovery, never resubmission.

Run `bash scripts/test-relay-blind-parity.sh` for shared Go framing checks. The integration tests exercise the real gateway/coordinator and Swift provider decryption with a deterministic runtime; this is protocol evidence, not MLX hardware throughput or production readiness.

The pilot revocation file currently has a 16 KiB read ceiling and retains all revoked IDs. Plan capacity before extensive repeated rotation/revocation; exceeding that ceiling fails closed on restart. Do not delete retained IDs to restore availability before signed expiry plus replay retention. Disable pilot admission during operator maintenance. Expired reservation references can also delay same-kid renewal until cleanup fences them; a delay never authorizes reuse of stale material.
