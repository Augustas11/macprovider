# Mac Provider Coordinator

Phase 4 coordinator — the hub of the MacProvider network. Provider Macs connect over WebSocket; buyer requests arrive over HTTP (proxied through `phase5-gateway`). The coordinator owns the provider pool, routing and failover, the request log, the billing ledger, and the explorer UI. Money math lives in `internal/billing/`; see `phase5-gateway/README.md` for buyer identity, quotas, and the public API gateway.

## Local Development

```sh
cd phase4-coordinator
cp coordinator.yaml.example coordinator.yaml
export COORDINATOR_OPERATOR_KEY=dev-operator-key
go test ./...
go run ./cmd/coordinator -config=coordinator.yaml
```

By default the coordinator binds two ports on `127.0.0.1`:

- `provider_port: 8444` — WebSocket `/ws/provider` for provider Macs, plus operator endpoints (`/poolz`, `/admin/*`, `/ledger/*`) guarded by the operator key.
- `buyer_port: 8443` — buyer-facing HTTP (`/v1/chat/completions`, `/v1/models`). In production this is reached only through the gateway over loopback.

## Using `mockprovider`

`tools/mockprovider/main.go` is a standalone in-process mock of a Phase 3 provider binary. It connects to the coordinator over WS, behaves like a Tier-1 provider, and serves a local OpenAI-compatible HTTP endpoint the coordinator proxies to. Used by `scripts/run-local-pool.sh` and the AC-2/3/6 shell tests:

```sh
go run ./tools/mockprovider -coordinator ws://127.0.0.1:8444/ws/provider -provider-id mock-1
```

`scripts/run-local-pool.sh` brings up the coordinator plus one or more mockproviders against a temp SQLite DB and is the fastest path to a working local routing setup.

## Critical Test Sets

```sh
go test ./internal/billing/...       # ledger math, settle/refund, idempotency
go test ./internal/requestlog/...    # WriteHotPath atomic tx + quarantine
go test ./internal/ws/...            # admission, hello/auth, frame handling
go test ./internal/pool/...          # registry, routing/failover, breakers
go test ./internal/buyer/...         # the public buyer API + handleChatCompletions
go test ./... -race                  # race-clean is required before deploy
```

The full suite (`go test ./...`) is the only required gate; the named subsets are the ones most often run during money-path edits.

## Cross-Compile For Linux

Production builds run on Apple Silicon and ship to a linux/amd64 VPS. CGO-free `modernc.org/sqlite` makes this a one-liner:

```sh
scripts/build-linux.sh           # version-stamped from an exact vX.Y.Z release tag
```

Output: `dist/coordinator-linux-amd64`. Production builds refuse `main`,
`vX.Y.Z-N-g<hash>`, dirty, and untagged checkouts so deploy provenance cannot
self-confirm a regressing `git describe` string. For local/dev artifacts only,
set `ALLOW_NON_RELEASE_COORDINATOR_BUILD=1`; combine it with `FORCE_DIRTY=1`
only when you deliberately want a dirty dev stamp. The Pearl production deploy
does not accept non-release coordinator versions.

## Deployment

Deployment is operator-driven. See `dist/deploy-pearl-vps.sh` for the scripted path (drift check, snapshot, restart, post-restart provenance assertion) and root [`OPS.md`](../OPS.md) for production topology, safe-restart procedure, settlement, and incident response.

## Layout

| Path | What |
|---|---|
| `cmd/coordinator/` | Composition root, config loading, signal handling |
| `internal/billing/` | Credit ledger math (integer credits, overflow-checked) and persistence |
| `internal/buyer/` | Buyer HTTP API including `handleChatCompletions` and failover |
| `internal/pool/` | Provider registry, routing, breakers, swap audit |
| `internal/ws/` | Provider WS lifecycle, admission, hello/auth, frame routing |
| `internal/requestlog/` | Append-only request log with quarantine fallback |
| `internal/auth/` | Provider-token store, operator-key validation |
| `internal/tier2/` | Tier-2 trust disclosure (encrypted leg, attestation, behavioral safety) |
| `internal/explorer/` | Read-only explorer UI handlers |
| `tools/mockprovider/` | Standalone WS-speaking provider mock for local + CI |
