## Raw output

```text
Findings:

1. **HIGH — `phase4-coordinator/internal/ws/server.go:1473` — Catalog reload can leave an incompatible row-continuity session buyer-routable.**  
   On release publication, `refreshSessionIdentities` revalidates against the session’s stored `ExpectedModelHash`, not the retained row versus the new current row (`server.go:1629-1638, 1673-1703`). When `RequireAutotuneHelloGate=false`, `SetProofOfWeightsConfig` explicitly clears `AdmissionCeilingExcluded` (`server.go:1473-1485`). Consequently, the row-identity and `PolicyEquivalent` checks performed at hello (`server.go:3673-3697`) are not maintained across SIGHUP.  
   **Failure scenario:** A provider is admitted through row continuity. A subsequent signed catalog keeps the same model hash but raises `min_ram_gb` beyond that provider’s admitted ceiling or otherwise changes the row identity. The identity refresh still returns `hash_verified` (`server.go:1768-1770`), the gate-disabled path clears exclusions, and `RoutingEligible` plus buyer selection continue accepting it (`internal/pool/provider.go:560-576`, `internal/buyer/server.go:8450-8451`). This permits buyer dispatch under a row that SPEC-023-R010 would now reject. With the gate enabled, there is also a smaller publication-to-revalidation window because the new release becomes visible before the ceiling sweep.  
   **Suggested fix:** Make live catalog compatibility a release-generation invariant independent of the optional hello/PoW gate. Before or atomically with publication, mark catalog-envelope sessions unroutable; re-resolve their retained document against the new current row and clear the exclusion only after equal row identity and `PolicyEquivalent` succeed. Alternatively, close incompatible sessions. Add SIGHUP routing tests with `RequireAutotuneHelloGate` both disabled and enabled.

2. **LOW — `phase4-coordinator/internal/ws/server.go:547` — Release IDs and catalog digests share one lookup namespace.**  
   `buildCompatibleCatalogSet` stores both `previous.Version` and lowercase `previous.SHA256` in the same map. An operator-controlled 64-hex release ID equal to another retained catalog’s digest can overwrite that digest entry or be overwritten by it. Exact envelope checks make this fail closed rather than widening admission, but valid retained providers can be rejected depending on insertion order.  
   **Failure scenario:** Two authenticated retained releases have a version/digest collision; SHA-first resolution at `server.go:764-783` retrieves the wrong catalog and the subsequent envelope comparison rejects an otherwise valid hello.  
   **Suggested fix:** Use separate maps for release ID and SHA-256, or reject release IDs matching the canonical 64-hex digest syntax.

Requested Go and Swift test selections passed with zero failures; `Package.resolved` was restored after the Swift build.

VERDICT: C=0 H=1 M=0 L=1
