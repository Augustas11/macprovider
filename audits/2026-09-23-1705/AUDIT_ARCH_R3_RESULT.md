## Raw output

```text
1. **HIGH — `phase4-coordinator/internal/ws/server.go:3720`**  
   **Defect:** Catalog publication and provider admission are not linearized. The divergence sweep only examines already-registered sessions, while admission can retain a pre-publication catalog decision and register afterward without revalidation.  
   **Failure scenario:** A provider is classified as row-continuity-compatible with catalog C at lines 3194–3195. Divergent catalog D publishes before registration; the sweep snapshots the pool while that provider is absent. The provider then registers at line 2970 using the stale decision and remains buyer-routable, potentially indefinitely, despite no longer being row/policy-equivalent to D.  
   **Suggested fix:** At the registration linearization point, revalidate the catalog generation and row identity/policy against the active catalog. Alternatively, serialize publication plus its sweep against admission through registration. Add deterministic v1/v2 tests that pause admission, publish divergent D, resume registration, and assert rejection or immediate `catalog_incompatible` closure.

2. **LOW — `phase4-coordinator/internal/ws/server.go:547`**  
   **Defect:** `buildCompatibleCatalogSet` stores release IDs and catalog SHA-256 values in one unnamespaced map.  
   **Failure scenario:** An operator-controlled release ID equal to another compatible catalog’s SHA can overwrite its lookup entry, producing an incorrect catalog resolution and false `catalog_incompatible` rejection.  
   **Suggested fix:** Maintain separate release-ID and SHA maps, or namespace the keys explicitly.

VERDICT: C=0 H=1 M=0 L=1
