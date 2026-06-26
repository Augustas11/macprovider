CRITICAL (0): None.

HIGH (0): None.

MEDIUM (0): None.

LOW (0): None.

QUESTIONS (0): None.

CODE-1: PASS. `Store.Providers` renders each pool snapshot row through `providerMap`, and `Store.ProviderDetail` renders its `"provider"` object through the same `providerMap`, so the one-line addition covers both `/admin/explorer/providers` and `/admin/explorer/providers/{id}`. The value is emitted as `p.AuthState`; `pool.AuthState` is a `string` alias, so Go JSON encoding serializes it as the underlying string literal.

CODE-2: PASS. Always emitting `"auth_state": ""` for legacy zero-value sessions is consistent with this explorer renderer. `providerMap` already unconditionally emits empty-capable fields such as `binary_version`, `hash_status`, `attestation_status`, timestamp strings, token status fields, and other scalar values; it is not using `pool.Provider` struct tags as the explorer JSON contract. For an authenticated operator admin view, explicit empty legacy state is clearer than omission.

CODE-3: PASS. `Test82Item4_ProviderMapExposesAuthState` covers the four named AuthState constants plus the legacy empty string, and checks both list and detail responses. Seeding by calling `pool.Registry.Register(&pool.Provider{AuthState: tc.authState}, conn)` is the right level for this renderer test: `providerMap` consumes the already-registered in-memory `pool.Provider`, while the raw `provider_tokens` row satisfies the existing explorer token-status join. No full admission-flow test is needed for this one-line rendering surface.

CODE-4: PASS. The field was added at the end of the Go map literal, but `encoding/json` sorts map keys deterministically, so wire ordering remains stable and not insertion-order dependent.

CODE-5: PASS. This is an internal operator explorer surface protected by the operator token path. The underlying `auth_state` contract is already specified for `/poolz`/operator observability, and exposing the same in-memory field in the explorer does not create a new external API or require a SPEC update.

Verification:
- `go test ./internal/explorer -run Test82Item4_ProviderMapExposesAuthState -count=1`
- `go test ./internal/explorer -count=1`

VERDICT: code lane READY TO MERGE
