# BUILD_SPEC — Provider accepts its advertised catalog model id as a serve alias

## Problem (root cause, verified against prod 2026-07-09)

The provider serves inference locally under `loadedModelID = config.model` (the
autotune rate-card key, e.g. `qwen3-coder-30b-a3b-instruct`). But when it is
serving that configured model, `CoordinatorClient.coordinatorWireModelID(for:)`
advertises `catalogModelIDForCoordinator = config.modelCatalogModelID`
(e.g. `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`) to the coordinator as
its `model_id`. The coordinator stores that verbatim as `provider.ModelID`,
advertises it to buyers (`/v1/status`, `/v1/models`), and relays buyer requests
carrying that catalog id to the provider.

The provider's request validation (`ChatCompletionRequest.validateModelMatches`)
only accepts a request whose `model` equals the single loaded/served id. So the
provider **advertises `mlx-community/…` but 404s every request for
`mlx-community/…`** → relay NAK → coordinator returns 503 `no_provider_available`
"Selected provider is not reachable" → 100% of billed buyer completions fail,
while the pool still shows the provider `ready` (heartbeat/warmup use the
served id path).

## Fix (provider-side, symmetric): accept the advertised id as an alias

The provider must accept, as a valid request model, the id it advertised for the
currently-served model. Concretely: when serving the configured `loadedModelID`,
also accept `config.modelCatalogModelID` (the `catalogModelIDForCoordinator`
value) as an alias. Do NOT change what is echoed in responses/receipts, do NOT
rewrite the request model — only relax validation. Same underlying weights (same
model hash), so proof-of-weights / settlement are unaffected.

### 1. `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`

Change `validateModelMatches` to accept optional aliases (default empty →
no behavior change for existing callers/tests):

```swift
public func validateModelMatches(_ loadedModel: String?, aliases: [String] = []) throws {
    guard let loadedModel else {
        throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
    }
    if Self.asciiCaseInsensitiveEquals(model, loadedModel) {
        return
    }
    for alias in aliases where !alias.isEmpty && Self.asciiCaseInsensitiveEquals(model, alias) {
        return
    }
    throw APIError(status: 404, message: "Model not found", code: "model_not_found")
}
```

### 2. Thread the alias `config.modelCatalogModelID` (trimmed; nil/empty → no alias)

The alias is the coordinator-advertised catalog id. It must be accepted ONLY
when the currently-served model is the configured `loadedModelID` (mirrors
`coordinatorWireModelID`'s `servedModelID == loadedModelID` guard) so warm-swap
to a different model does not wrongly accept it.

Add a stored optional `catalogModelIDAlias: String?` to each of the three
validation owners, injected from config; pass a gated `aliases:` array:

- **`HTTPServer`** (`Sources/macprovider-cli/HTTPServer.swift`): add init param
  `catalogModelIDAlias: String?`, store it. At the `validateModelMatches(modelID)`
  call (only runs when `!warmSwapEnabled`, so served == configured `modelID`),
  pass `aliases: aliasList(catalogModelIDAlias)`.
- **`InferenceRelay`** (`Sources/macprovider-cli/InferenceRelay.swift`): add init
  param `catalogModelIDAlias: String?`, store it, and thread it into the static
  `process(...)`. At `validateModelMatches(validationModelID)`, pass
  `aliases: warmSwapEnabled ? [] : aliasList(catalogModelIDAlias)`.
- **`ModelRuntime`** (`Sources/macprovider-cli/ModelRuntime.swift`): add init
  param `catalogModelIDAlias: String? = nil` (default nil so benchmark/canary/
  decode-bench constructors are unchanged), store it. In
  `acquireRequestHandle`, at `validateModelMatches(snapshot.modelID)`, pass
  `aliases: (snapshot.modelID != nil && snapshot.modelID == self.modelID) ? aliasList(catalogModelIDAlias) : []`
  (only when the configured model is the one loaded).

Where `aliasList(_ s: String?) -> [String]` is a tiny helper returning
`[trimmed]` when non-empty else `[]` (inline or a small private func; trim
whitespace/newlines to match `catalogModelIDForCoordinator` normalization in
CoordinatorClient.swift:324-327).

### 3. Wiring (pass `config.modelCatalogModelID`, trimmed, at construction)

- `Sources/macprovider-cli/MacProviderCLI.swift:~624` — `HTTPServer(...)`: add
  `catalogModelIDAlias: <trimmed config.modelCatalogModelID>`.
- `Sources/macprovider-cli/MacProviderCLI.swift:~490` — the serve-path
  `ModelRuntime(...)`: add `catalogModelIDAlias: <trimmed config.modelCatalogModelID>`.
  Do NOT set it for decode-bench / canary / non-serve ModelRuntime constructions
  (leave default nil).
- `Sources/macprovider-cli/CoordinatorClient.swift:~845` — `InferenceRelay(...)`:
  add `catalogModelIDAlias: catalogModelIDForCoordinator` (already trimmed there).

## Tests (add, do not weaken existing)

In the ChatCompletionRequest test target:
- `validateModelMatches` with `aliases: []` still 404s a non-matching model
  (regression guard for default behavior).
- request model == loaded id → passes (unchanged).
- request model == an alias entry (case-insensitive) → passes.
- request model matches neither loaded nor any alias → 404 `model_not_found`.
- empty-string alias entries are ignored (no accidental match on "").

Add/adjust InferenceRelay + HTTPServer tests to cover: a WS-relayed / HTTP
request whose `model` is the catalog alias is accepted and served when the
configured model is loaded; and is rejected when warm-swap has loaded a
different model (alias must NOT apply).

## Acceptance

- `swift build` succeeds in `phase3-binary/`.
- `swift test` passes (new + existing).
- No change to response/receipt model echoing or to `coordinatorWireModelID`.
- Default `aliases: []` keeps every non-serve caller behavior-identical.
