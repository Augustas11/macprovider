# Transaction retention r2 — independent security plan gate

Verdict: **CHANGES REQUIRED — 0 Critical, 0 High, 1 Medium.** The lifetime-cap finding from r1 is resolved at the design level; the discovery ordering below prevents a zero-C/H/M approval of this exact revision.

Reviewer: independent native GPT-6 Astra, high reasoning; not the proposal author. Base/HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`. This is a bounded plan review against the current uncommitted store and architecture-r1 M4, not final implementation acceptance.

Exact proposal SHA-256:

```text
35d288fc5b3952a46d8bffc397cf985d3c44b7fd6e0869e155f68834dfe8f9f3  docs/product-roadmap/build-1/transaction-retention-addendum-r2.md
```

Corroborating store snapshot at report time (other source lanes remain active):

```text
b365b5a5f2fd588cf65c24847ff99aa2e0aed597d591186ba39e979f82a64565  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
```

## M1 — Queued reuse can postpone completed-result discovery until expiration

**Evidence.** Reservation step 1 (addendum line 33) returns an exact fresh queued reservation before the maintenance pass in steps 2–3. Successful evaluation pointers are published by retirement (lines 46–50) and by indexing active results during that maintenance pass (line 64). Adoption projection replaces the existing result scan with a direct pointer lookup (lines 64–68). No independent completion-time or projection-time indexing step is specified.

The current `makeModelCatalogLocalActions` calls `reserve` while building the evaluation action, then asks for the adoption action. Current reservation reuse requires an unstarted record. Therefore a catalog refresh while evaluation A runs can allocate a fresh queued successor B. When A succeeds, subsequent refreshes reuse B and return before maintenance. With one supported target, or all other targets also having fresh reusable reservations, no call indexes A's new result. Projection sees no pointer, or only an older pointer, until B expires or another operation happens to run maintenance.

**Consequence.** The ordinary evaluate-then-adopt journey can hide a valid newly completed measured result for up to 1,800 seconds. An existing older pointer may also remain the selected recommendation despite completion of the newer result. This is an availability and result-selection regression caused by the proposed optimization, not a signature or paid-authority bypass.

**Required correction.** Make successful-result indexing independent of an allocation miss. Either durably index at the appropriate completion boundary with explicit retry/recovery semantics, or run a bounded active-index maintenance/indexing step before adoption projection even when reservation reuse succeeds. Preserve direct historical lookup, original result bytes, owner exclusion, pointer validation, deterministic ordering, and the prohibition on history-wide scans. Do not claim an unindexed successful result is discoverable solely because its direct UUID file remains readable.

**Required test.** Start evaluation A, refresh the catalog while A owns its transaction so successor queued reservation B is created, complete A, then immediately refresh again while B remains fresh. B must remain reusable and projection must discover A's original valid result without waiting for expiry, starting another transaction, or scanning historical files. Cover both an absent pointer and an existing older same-context pointer, plus restart after result/terminal persistence before pointer publication. An invalid A must not replace a valid pointer.

## Resolved findings and accepted design boundaries

- R1's permanent quota is resolved: a bounded active set is separate from retained UUID history, resolved history leaves allocation capacity, and explicit tests exceed 1,024 completed and cancel-before-start transactions while preserving old evidence. Disk capacity remains a truthful physical limit.
- Logical archival avoids an archive-move crash window. Direct original UUID/result reads, active membership checks for every mutation, and pointer-before-retirement publication provide a coherent evidence-preservation design.
- Allocation intent precedes primary creation; allocating-entry recovery protects uncertain sidecars. Missing/corrupt metadata cannot silently rebuild membership from an unbounded history scan.
- Nonblocking owner acquisition under the stable journal lock addresses both start gaps without lock-order deadlock. The proposed deterministic startup, cleanup, cancellation and terminal-write races must prove this in code.
- Bounded one-time migration is explicit and conservative; over-bound/unsafe legacy layouts fail closed without truncation or evidence deletion. Ordinary operations use bounded active metadata or direct lookups.
- Descriptor-relative no-follow operations, private regular-file and bounded-decode checks, only-ENOENT absence, stable lock inodes, exact temporary-file cleanup, generation checks, and fsync error handling are appropriate implementation constraints. The resulting implementation must enforce them across all writers, not only `reserve`.
- Recommendation pointers are discovery metadata, not authority. Exact context/digest checks and unchanged adoption validation remain required; corruption fails closed and explicit older UUID references remain intact.

These conclusions approve design direction only. No new history deletion, schema-authority change, or manual capacity reset is authorized. The listed deterministic acceptance suite and the full combined code/security/architecture gate remain required after implementation.

## Validation

Verified the exact proposal digest and traced current reservation, projection, owner startup and cleanup behavior. No runtime tests were executed for this plan-only review; no source code was changed.
