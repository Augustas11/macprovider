# Command composition testability r1 — independent Astra gate

**CHANGES REQUIRED — 0 Critical, 0 High, 1 Medium.**

Exact addendum SHA-256: `a1c48b30b48cef47407ed20c656b44ed4247daf824549bec8776f4b13ef93c2c` (verified from disk). Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Reviewed the proposed shared-command context and subprocess design against the current command bodies, owner transaction requirements, static signed-input loader, discovery/admission runtime and approved owner-testability r2.

## CC-M1 — The proposed executable journey has no command to reserve required transactions

**MEDIUM, high confidence.**

Evidence: the addendum's affected command list omits `ModelsCatalogEconomicsCommand`. Its journey starts without any transaction, then directly parses/runs `prepare`, and later directly parses/runs `recommend-prepared`. Both commands require `--transaction-id`, and `ModelCatalogTransactionRunner.run` immediately loads the existing exact UUID/target journal before it can work. The executable action reservation currently happens through `ModelsCatalogEconomicsCommand.run` -> `makeModelCatalogLocalActions` -> `ModelCatalogTransactionStore.reserve`, which reads fresh authenticated input and emits exact target/kind/UUID/confirmation metadata. An arbitrary test UUID does not work; calling `reserve` directly from test code would bypass this executable producer and omit the promised projection/bootstrap composition.

Consequence: steps 1 and 3 cannot execute from the claimed empty initial state using the listed parsed commands. A workaround that pre-seeds or directly constructs transaction records would produce misleading B1-T11 command-composition evidence and fail to test the real executable action boundary.

Required correction: include `catalog-economics --local-activation` in the shared typed execution-context scope. Run it as a parsed real command in a fresh child before preparation and again after durable discovery before recommendation. Consume the emitted action's exact model target, transaction UUID, kind, confirmation/size metadata and timeout, then invoke the corresponding parsed mutation. Preserve ordinary signed-input qualification and configuration/discovery semantics. Do not reserve or seed the transaction directly in the test harness. Include malformed/missing/mismatched projected-action rejection and prove the unconfirmed mutation leaves config/artifacts unchanged.

## Sound design retained

The explicit internal context is a reasonable bounded approach: each `.run()` delegates to the same parsed command body with immutable production defaults, without global replacement handlers or a shipping CLI/environment fixture switch. Existing real `AutotuneStaticInputs` accepts a fixture public keyring and fetch transport while retaining Ed25519 verification; its optional signature-override closure must remain nil in these tests and in production. The actual fixture signer provides isolated metadata authority, not eligible recommendations or admission records.

The separate test-target subprocess entry can exercise process restart without adding a trust backdoor to the shipping command parser. Keep the request-file mechanism entirely in test code; permit only explicitly listed typed command cases and validate canonical temporary-root ownership before parsing/executing. Sanitize the process environment and use explicit config/custody/namespace/cache/HMAC/journal/socket/log paths; HOME alone does not isolate Foundation or credential defaults. The approved real-prober/real-child owner path and original recommendation bytes must be retained through the actual adoption consumer/control protocol.

Verification details to preserve during implementation:

- Default-wiring proof must establish the real factories/keyring/verifier independently of descriptive enum labels that could disagree with the implementation; never open real operator Keychain/secret/network paths merely to test the default wiring.
- `discover` intentionally does not expose local durable paths in its wire rows. Verify the durable source by fixture filesystem inspection and stable canonical candidate identity, not by adding a path to the wire schema.
- A pending retry needs a real pending coordinator state. The initial probe may need to complete or be withheld according to the production endpoint semantics before retry is useful; do not substitute status or signature acceptance to satisfy the test.
- The optional step 6 is an honest explicitly unclosed integration join, not a waiver: CODE-M2/B1-T11 cannot be marked complete until the command-created offer is actually carried through the real service settlement chain or the remaining gap is reported without claiming overall acceptance.

No additional Critical/High/Medium issue was established in the proposed trust/custody boundary. One revised plan is needed for executable reservation/projection composition before implementation.

## Exact scoped snapshot

Manifest SHA-256: `21df6400874928ec72ce0a4f9b5df8b655c29d811506832dff5be88ba5f1b4c9`. Computed over the following lexically path-sorted newline-terminated `SHA256(bytes)  path` manifest:

```text
a1c48b30b48cef47407ed20c656b44ed4247daf824549bec8776f4b13ef93c2c  docs/product-roadmap/build-1/command-composition-testability-addendum-r1.md
905bc308bc1e5cde8ddabea6b0202626a8cc600b98a1859cfb6a67fb9a81e7c2  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
91fd91b8d769a5bd50a7ac3caa80eb30b63f8fbd0fb12081cbdc074bf7684df9  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
c240942ca1a32720c1292ae534b688ec49fb66cd6cbde82e04123d5ab39c8e70  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
ccf517366232ad36787c8542a677b04b83914ea5dc482acb68769935f771bf53  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
b2015aadf1db321861edd1b3e20642b828c9ff665939f347834881717194f913  phase3-binary/Sources/macprovider-cli/ModelsAdmissionRetry.swift
b2fee58b654b9cc0e3f99217dfe8770a1e45547937a1f4333708d5c2f6efe774  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
```

No source/runtime edits, subprocess journey execution, subagents, secrets or external services were used during this design review. No new test pass is claimed. Owner-level tests, CODE-M2, final combined-diff review and physical qualification remain separate obligations.
