# macprovider-verify

`macprovider-verify` is the buyer-side verifier module for SPEC-015
receipts. This Step 1 module is intentionally only a scaffold: it exposes the
future CLI surface, version reporting, package layout, CI gate, and build
targets, but it does not verify receipts yet.

The verifier is scoped to SPEC-015 v0.2.4 receipt verification. The locked
CLI contract is described in
[SPEC-015 section 10](../specs/SPEC-015-receipts.md#104-inputs-outputs-exit-codes).

## Current Status

Step 1 includes:

- `cmd/macprovider-verify` CLI entry point
- placeholder internal packages for later implementation steps
- version constants
- tests for `--version`, `--help`, and scaffold exit-code behavior
- zero external Go dependencies
- CI wiring for `go vet`, `go test -race`, and empty `go.sum`

Step 1 does not include:

- receipt parsing
- JCS canonicalization
- ed25519 verification
- cache or coordinator resolver behavior
- JSON verification output

## Build

Build the local platform binary:

```sh
make build
```

The binary is written to:

```sh
./macprovider-verify
```

Build all planned release targets:

```sh
make build-all
```

Artifacts are written to `dist/`:

- `macprovider-verify-darwin-arm64`
- `macprovider-verify-darwin-amd64`
- `macprovider-verify-linux-amd64`

Cross-compilation uses pure Go with `CGO_ENABLED=0`.

## Test

Run tests:

```sh
make test
```

Run vet:

```sh
make vet
```

Clean generated binaries:

```sh
make clean
```

## CLI Surface

The scaffold parses the SPEC-015 v0.2 flags:

```sh
macprovider-verify --bundle receipt-bundle.json
macprovider-verify --receipt "$X_MACPROVIDER_RECEIPT" --prompt-hash <hex> --output-hash <hex> --provider-id <id>
macprovider-verify --offline --pubkey <base64> --bundle receipt-bundle.json
```

`--version` and `--help` are implemented. Any verification invocation currently
prints `TODO: Step 7` to stderr and exits `64` (`EX_USAGE`) until the later
implementation steps land.

`MACPROVIDER_COORDINATOR` is read as the default value for `--coordinator`.
Step 5 will use it for `/v1/receipt-keys` resolution.

## Version Compatibility

| macprovider-verify version | Max SPEC-015 version | Status |
|---|---:|---|
| `0.1.0-step1-scaffold` | `v0.2.4` | Scaffold only; no verification logic |
| `1.0.0` | `v0.2.4` | Planned final Step 10 acceptance binary |

## Dependency Policy

This module is stdlib-only in Step 1. `go.sum` must remain empty. External Go
modules, including `golang.org/x/*`, are explicitly deferred unless a later
audited step approves them.
