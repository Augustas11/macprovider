# Build 1 catalog inspection implementation evidence

Date: 2026-09-10. Implementation lane; **not independent audit approval**.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Contract: `catalog-read-lifecycle-addendum-r2.md`, SHA-256
`e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`;
its independent Astra r2 plan approval and amended SPEC-001/SPEC-044.

## Owned scope

- `ModelCatalogLocalInspection.swift`: ephemeral signed key/canonical model ID/
  revision/hash map; missing/unverified/verified/invalid/incomplete observations;
  held descriptor placement and bounded metadata snapshots.
- `AutotuneRecommend.swift`, `ModelArtifactVerifier` only: additional strict
  descriptor-backed canonical inspection and optional shared read budget, without
  changing the canonical manifest hash format. Existing nil-budget callers retain
  their verification policy with entry/path/config-size and overflow bounds.
- `DurableModelDiscovery.swift` and `BYOMDiscovery.swift`: map-consuming durable
  projection, owned throwing discovery path, shared checks across metadata work
  and adapter await boundaries; standalone discovery remains separate.
- `ModelCatalogEconomics.swift`: protocol-2 closed `local_verification.state`,
  truthful readiness/runtime state and defensive action blocking; protocol 1
  omits the field. Economics/admission authority is unchanged.
- Focused tests in `ModelCatalogLocalInspectionTests.swift`,
  `DurableModelDiscoveryTests.swift`, and `ModelCatalogEconomicsTests.swift`.

Root owns read options/lifetime monitor, request/progress/budget, exact authority
selection and final refresh, config/context revalidation, action reservations,
recovery collection, capacity checks, and command composition. This lane did not
edit those files or retention policy, launch SwiftPM, install dependencies, or
perform signing/release/production operations.

## Inspection behavior

Quick inspection streams bounded metadata with zero artifact-content reads.
The owned cache scanner reads only bounded directory names, never weights or
config contents. Exact durable verification streams each regular file in 1 MiB
chunks and reports only actual hashed bytes. A second consumer receives the
same request-local inspection rather than running another hash. Finalization
compares metadata without reading content again; a changed snapshot invalidates
the observation rather than silently refreshing it.

The strict path holds descriptor-relative placement from the filesystem root
through the artifact parent and root. It rejects unsafe ownership/modes,
symlinks/hardlinks, nonregular descendants, invalid/duplicate paths, enumeration
errors, arithmetic overflow, more than 10,000 entries, paths above 4,096 UTF-8
bytes, nesting above 64, and config capture above 8 MiB. It compares opened file
identity, link count, size, mtime and ctime before/after reads, full metadata
before/hash/after, and retained ancestor/root placement again at finalization.
The signed canonical manifest format remains path/newline/size/newline/hash.

A cache-only signed target is unverified and cannot obtain prepare/evaluate/
adopt permission from cached metadata. Exact verification currently selects the
authorized durable artifact location only. Cache-only artifacts therefore cannot
complete this verification until durable bytes exist through an independently
authorized workflow. This is a conservative limitation, not an implicit cache
copy/adoption or overwrite authority. Durable invalid/incomplete observations
continue to shadow cache rows. No persisted seal or completed transaction supplies
current verification.

## Validation evidence and limits

The implementation lane ran `swiftc -frontend -parse` against all five owned
source files and three focused test files;
exit status 0. This is syntax validation only, **not Swift typecheck or test
execution**. Root owns coherent compiled targeted/full tests and final combined
code/security/architecture audits. No local test pass is claimed here until root
records the actual commands/results.

Focused tests cover canonical hash/config equality and actual byte accounting;
same-size content mutation; root/ancestor rename; symlink/hardlink/config limit
failure before bytes; added/deleted/replaced files at finalization; cancellation;
request-local reuse without rehash; missing/cache-only truthfulness; actual owned
discovery, cache shadow and metadata interruption; protocol-2 readiness/action
blocking and protocol-1 field omission.

These fixtures do not qualify production signatures, real model/disk throughput,
app child ownership, final authority refresh, progress transport, response
capacity, remote admission, incumbent lifecycle, or settled credit. Those remain
root/app/integration and final independent audit evidence. A filesystem syscall
can block until the independent owned-read lifetime monitor terminates the
helper; this lane does not claim user-space checks can interrupt kernel I/O.
