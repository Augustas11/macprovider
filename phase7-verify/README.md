# macprovider-verify

Buyer-side verification for SPEC-015 signed inference receipts.

`macprovider-verify` checks an `X-MacProvider-Receipt` value against the buyer's recorded request and response, resolves the provider receipt key, and returns a deterministic `valid`, `invalid`, or `inconclusive` result.

## Install

Release artifacts are published on tags named `verify-v<version>`, for example `verify-v1.1.0`.

### macOS Apple Silicon

```sh
VERSION=1.1.0
gh release download "verify-v${VERSION}" --repo Augustas11/macprovider \
  --pattern "macprovider-verify-${VERSION}-darwin-arm64" \
  --pattern "macprovider-verify-${VERSION}-darwin-arm64.sha256"
shasum -a 256 -c "macprovider-verify-${VERSION}-darwin-arm64.sha256"
chmod +x "macprovider-verify-${VERSION}-darwin-arm64"
sudo install -m 0755 "macprovider-verify-${VERSION}-darwin-arm64" /usr/local/bin/macprovider-verify
```

### macOS Intel

```sh
VERSION=1.1.0
gh release download "verify-v${VERSION}" --repo Augustas11/macprovider \
  --pattern "macprovider-verify-${VERSION}-darwin-amd64" \
  --pattern "macprovider-verify-${VERSION}-darwin-amd64.sha256"
shasum -a 256 -c "macprovider-verify-${VERSION}-darwin-amd64.sha256"
chmod +x "macprovider-verify-${VERSION}-darwin-amd64"
sudo install -m 0755 "macprovider-verify-${VERSION}-darwin-amd64" /usr/local/bin/macprovider-verify
```

### Linux amd64

```sh
VERSION=1.1.0
gh release download "verify-v${VERSION}" --repo Augustas11/macprovider \
  --pattern "macprovider-verify-${VERSION}-linux-amd64" \
  --pattern "macprovider-verify-${VERSION}-linux-amd64.sha256"
sha256sum -c "macprovider-verify-${VERSION}-linux-amd64.sha256"
chmod +x "macprovider-verify-${VERSION}-linux-amd64"
sudo install -m 0755 "macprovider-verify-${VERSION}-linux-amd64" /usr/local/bin/macprovider-verify
```

## Quickstart

Verify a captured receipt header when you already have the canonical prompt and output hashes:

```sh
macprovider-verify \
  --receipt "$X_MACPROVIDER_RECEIPT" \
  --prompt-hash "$PROMPT_SHA256_HEX" \
  --output-hash "$OUTPUT_SHA256_HEX" \
  --provider-id m1-anon \
  --json
```

To verify raw buyer captures instead, place the receipt, OpenAI request body, OpenAI response body, and `provider_id` in a bundle JSON file and run:

```sh
macprovider-verify --bundle receipt-bundle.json --json
```

## CLI Reference

| Flag | Semantics |
|---|---|
| `--version` | Print `macprovider-verify <binary-version> (verifies up to SPEC-015 v<max-spec-version>)` and exit 0. |
| `--help` | Print usage and all supported flags, then exit 0. |
| `--bundle <path|->` | Verify a bundle JSON file. Use `-` to read the bundle from stdin. Mutually exclusive with `--receipt`. |
| `--receipt <value>` | Verify a raw `X-MacProvider-Receipt` header value in header+hashes mode. Requires `--prompt-hash` and `--output-hash`. Mutually exclusive with `--bundle`. |
| `--prompt-hash <hex>` | Expected canonical prompt SHA-256 hex in header+hashes mode. Required with `--receipt`. Malformed hex is a usage error. |
| `--output-hash <hex>` | Expected canonical output SHA-256 hex in header+hashes mode. Required with `--receipt`. Malformed hex is a usage error. |
| `--pubkey <base64>` | Explicit base64 ed25519 public key. This is the trust root for offline or air-gapped verification. When supplied with `--provider-id` and not `--offline`, the verifier still attempts a live divergence check; an explicit key wins the result. |
| `--provider-id <id>` | Provider identifier used to address `/v1/receipt-keys/<provider_id>`. Required for online header+hashes mode unless `--pubkey` is supplied. Optional in bundle/stdin mode when the bundle carries the same `provider_id`; a mismatch is a usage error. |
| `--json` | Emit exactly one line of JSON conforming to `schemas/output.schema.json`. Warnings remain in the JSON `warnings` array even with `--quiet`. |
| `--offline` | Disable live coordinator fetches. With `--pubkey`, verification can still be `valid`. Without `--pubkey`, cache misses or stale cache entries produce `inconclusive`. |
| `--quiet` | Suppress stderr diagnostics, `warning:` lines, and `--explain` text. Does not suppress JSON `warnings` records and does not change the exit code. |
| `--coordinator <host>` | Coordinator host for `/v1/receipt-keys`. Defaults to `coordinator.malibu.tech` or `MACPROVIDER_COORDINATOR` when that environment variable is set. Non-default hosts emit a `non_default_coordinator` warning. |
| `--explain` | After a `valid` result, print the SPEC-015 trust-boundary text to stderr unless `--quiet` is also set. Does not change the result or exit code. |

### Running against a private coordinator

By default, `--coordinator` rejects literal loopback, RFC1918, link-local, and unspecified IP hosts. This prevents accidental verification against a private or local endpoint when a buyer expected the public coordinator.

For local development or an explicitly private deployment, set `MACPROVIDER_VERIFY_ALLOW_PRIVATE_COORDINATOR=1` before using a private coordinator URL. Hostnames are not blocked by this literal-IP guard; operators remain responsible for choosing trusted DNS names.

Input modes:

| Mode | Required flags and data |
|---|---|
| Header+hashes | `--receipt`, `--prompt-hash`, `--output-hash`, and `--provider-id` unless `--pubkey` is supplied. |
| Bundle file | `--bundle <path>` where the JSON contains `bundle_version`, `receipt`, `request`, `response`, and optionally `provider_id`. |
| Stdin bundle | `--bundle -` or positional `-`, with the same JSON shape as bundle mode. |

Flag interactions follow the SPEC-015 section 10.4.4 matrix: `--bundle` and `--receipt` are mutually exclusive; `--offline` prevents live fetches; `--pubkey` prevents resolver failures from downgrading an otherwise valid explicit-key verification; `--provider-id` must match the bundle field when both are present.

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | `valid` |
| 1 | `invalid` (signature, canonicalization, coordinator-rejected pubkey, or previous-key-outside-grace-window) |
| 2 | `inconclusive` (pubkey unresolvable, provider_id not in pool per `/v1/receipt-keys` 404, cache stale plus live unreachable) |
| 64 | Usage error: unknown CLI flag, missing required CLI argument, mutually exclusive flags, or invalid value format for a CLI flag such as malformed `--pubkey` base64. |
| 65 | Input format error: malformed bundle JSON, missing required bundle field, unknown bundle top-level key, unsupported `bundle_version`, malformed receipt header, tuple/signature base64 decode failure, or tuple JSON with the wrong key set. |

## JSON Output Schema

JSON mode emits one line conforming to the shipped Draft-07 schema:

[schemas/output.schema.json](schemas/output.schema.json)

## Version Compatibility

| macprovider-verify | SPEC-015 receipt versions verified |
|---|---|
| 1.0.x | 0.2.0 through 0.2.4 |
| 1.1.x | 0.2.0 through 0.3.3 (catalog-based model-hash binding per §M) |

**§M.1.2 forward-incompat note.** Locked v1.0.x verifiers report v0.3 receipts as `invalid` per SPEC-015 §M.1.2. Operators rolling out v0.3-emitting providers MUST release v1.1.x to buyers BEFORE that provider rollout reaches them. See `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md`.

## Trust Boundary

Read the locked trust-boundary contract in [SPEC-015 section 10.6](../specs/SPEC-015-receipts.md#106-trust-boundary).

In short, a `valid` result proves that a holder of the provider signing key signed the canonical tuple and that the verifier resolved that key through the configured trust source. It does not prove model honesty, timestamp honesty, response uniqueness, privacy, replay resistance, or absolute trust in the coordinator.

## Reporting Bugs and Security Issues

Report verifier bugs through GitHub Issues with:

- `macprovider-verify --version` output
- the command mode used (`--bundle`, `--receipt`, or stdin)
- exit code
- stdout and stderr
- whether `--offline`, `--pubkey`, or a non-default `--coordinator` was used

Do not attach private prompts, responses, API keys, or receipt bundles to public issues. For security-sensitive reports, use GitHub's private vulnerability reporting for the repository.

Gateway receipt-header forwarding compatibility with the OpenAI Python SDK was verified when PR #123 landed. This Step 10 release does not add a new SDK smoke script; regressions in forwarding should be reported against the gateway path with the SDK version and captured response headers.
