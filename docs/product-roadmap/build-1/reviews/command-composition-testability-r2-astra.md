# Command composition testability r2 — independent Astra gate

**PASS — 0 Critical, 0 High, 0 Medium.** CC-M1 is closed at the design level. Approval covers the explicit shared-command context and fixture composition described in this revision; it does not close CODE-M2/B1-T11 or approve separate transaction-control behavior.

Reviewed addendum SHA-256: `5e68de58a6835e621f18b06a3091590c5fa56a00dbdbd57d27f796102f123428`, verified from disk. Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.

## Finding disposition

**CC-M1 — CLOSED.** Revision 2 adds `catalog-economics` to the typed shared command scope. Step 1 invokes the actual parsed projection before preparation and consumes its emitted target/transaction UUID/confirmation metadata. Step 3 repeats the parsed projection after durable preparation, consumes its distinct evaluation action and explicitly prohibits direct reservation or reuse of the preparation UUID. This matches the current executable wiring: `ModelsCatalogEconomicsCommand.run` -> `makeModelCatalogLocalActions` -> `store.reserve`; the mutation owner then loads that journal. The fixture no longer requires a seeded transaction or a parallel test implementation of action creation.

The full revision retains the substantive constraints accepted in r1: production `.run()` delegates to the same body with explicit production defaults; no mutable global context or shipping parser/environment fixture switch; actual Ed25519 verification with fixture-only key material; the approved real owner/engine/prober/child; exact original result bytes through real adoption parsing/control protocol; actual file-backed signing custody and admission client; and sanitized independent test subprocesses with explicit temporary roots. No new trust bypass or fabricated eligibility/status/settlement seam is proposed.

## Implementation checks retained

- Catalog projection's input, discovery, control and admission reads must use the same explicitly scoped context; do not fix reservation by injecting a finished action document. Before provider authentication exists, the existing explicit skip-coordinator-status behavior may be used and must be labeled local/default, without assuming coordinator admission.
- Consume the complete emitted action descriptor, including kind, supported target, UUID, confirmation/size disclosure, deadline, and any generation field established by the separately approved control contract. Reject missing or mismatched descriptors and unconfirmed mutations. This review does not invent or authorize generation semantics; follow the independently approved control revision before editing them.
- Observe durable source paths through fixture filesystem checks. Keep local artifact paths out of discovery wire rows.
- Use real parsed commands in fresh child processes and original committed result bytes; context overrides remain test-target calls only. Verify default factories from implementation-backed construction, not merely labels claiming to be production.
- A command-created admission joined to the real receipt/ledger journey is still required for full B1-T11 closure. The explicit unresolved-join reporting option preserves honesty but does not waive this acceptance criterion. The hand-built Go offer fixture cannot be relabeled command-composition proof.

The addendum is implementable with the stated narrow boundaries and approved owner seams, without adding dependencies or accessing operator state. The fixture proves command composition and process persistence, not installed-provider MLX execution or production trust.

## Exact scoped snapshot

Manifest digest: `f81bf7098bc966319b5f10e2b9d622da1042d36fc5221212532dc4d233bc1c1e`. SHA-256 of the lexically sorted newline-terminated manifest below.

```text
5e68de58a6835e621f18b06a3091590c5fa56a00dbdbd57d27f796102f123428  docs/product-roadmap/build-1/command-composition-testability-addendum-r2.md
905bc308bc1e5cde8ddabea6b0202626a8cc600b98a1859cfb6a67fb9a81e7c2  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
91fd91b8d769a5bd50a7ac3caa80eb30b63f8fbd0fb12081cbdc074bf7684df9  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
c240942ca1a32720c1292ae534b688ec49fb66cd6cbde82e04123d5ab39c8e70  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
ccf517366232ad36787c8542a677b04b83914ea5dc482acb68769935f771bf53  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
b2015aadf1db321861edd1b3e20642b828c9ff665939f347834881717194f913  phase3-binary/Sources/macprovider-cli/ModelsAdmissionRetry.swift
b2fee58b654b9cc0e3f99217dfe8770a1e45547937a1f4333708d5c2f6efe774  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
```

Review used the current command/owner source and the full r1/r2 addendum delta. No runtime/source edits, subagents, secret reads, external calls or new tests were performed. Final source audit and fresh complete test evidence remain mandatory; physical B1-T10 remains independently unproven.
