## Raw output

```text
- **HIGH — [server.go:3743](/Users/augstar/macprovider-1705/phase4-coordinator/internal/ws/server.go:3743)**
  - **Defect:** An admitted older-catalog session is retained when its exact catalog disappears from the compatible set. The divergence fence returns on `!ok`; subsequent identity refresh trusts the stored expected hash, while `RoutingEligible()` does not require catalog resolvability.
  - **Failure scenario:** A `row_continuity` provider is connected, then a publication changes its row while its A-side release is removed, missing, or no longer verifiable. Resolution fails, comparison is skipped, the stored hash remains `hash_verified`, and the session stays buyer-routable under stale authorization. An existing settlement-capable binding may also survive.
  - **Suggested fix:** For catalog-envelope sessions whose non-current document cannot resolve against a successfully published snapshot, synchronously mark the session unavailable and close it `catalog_incompatible`. Add a regression covering evidence removal plus row divergence.

- **HIGH — [main.go:2020](/Users/augstar/macprovider-1705/phase4-coordinator/cmd/coordinator/main.go:2020)**
  - **Defect:** The full diff against current `origin/main` reverses the #1711 money-path protection: it removes in-flight request tracking and the bounded 100 ms SQLite busy timeout, directly selects `TRUNCATE` from elapsed activity, and uses the full checkpoint timeout at [main.go:2048](/Users/augstar/macprovider-1705/phase4-coordinator/cmd/coordinator/main.go:2048).
  - **Failure scenario:** A buyer inference lasting longer than the idle interval is incorrectly considered idle. WAL maintenance can enter `TRUNCATE` and wait at least 15 seconds on SQLite locks, exceeding the six-second billing/receipt durability budget and turning completed inference into a 502.
  - **Suggested fix:** Rebase onto current `origin/main` and preserve commit `57022da8` and its checkpoint regression tests while integrating #1705.

- **LOW — [server.go:557](/Users/augstar/macprovider-1705/phase4-coordinator/internal/ws/server.go:557)**
  - **Defect:** Compatible catalogs are indexed in one namespace by both release ID and SHA-256.
  - **Failure scenario:** An operator-controlled 64-hex release ID can collide with another catalog’s SHA key and replace its lookup entry. Exact-envelope validation normally converts this into failed admission rather than widened trust.
  - **Suggested fix:** Use separate release-ID and digest maps, or a typed composite key.

- **LOW — [autotune_window.py:369](/Users/augstar/macprovider-1705/scripts/autotune_window.py:369)**
  - **Defect:** R015 coverage treats every validator-reported `row_continuity` release/SHA pair as fully covered without proving the advertised rows remain identity- and policy-equivalent.
  - **Failure scenario:** Pre-activation coverage passes for providers using a changed row; publication then fences them, producing avoidable capacity loss.
  - **Suggested fix:** Exclude `row_continuity` from release-level coverage or require per-row identity and policy-equivalence evidence.

Targeted coordinator, Swift CLI, and autotune-window tests passed. No audit edits remain; `Package.resolved` was restored after the Swift build.

VERDICT: C=0 H=2 M=0 L=2
