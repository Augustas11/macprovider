# Context binding — preliminary independent security review

Result: **0 Critical, 0 High, 0 Medium, 2 Low.** This is a bounded preliminary review, not the final combined Build 1 security gate. Root has queued the L1 correction after the current Swift freeze; neither Low finding is marked fixed in this snapshot.

Reviewer: independent native GPT-6 Astra, high reasoning. Base/HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Main scope: `ModelTransactionContext.swift`, protocol2 encoding in `ModelCatalogEconomics.swift`, and context-projection/adoption-core changes in `ModelsSubcommand.swift`. Store/context dependencies were read to trace the boundary; this report does not replace their full implementation audits.

## L1 — Projection and bound commands use different home-directory lookup sources

**Evidence.** `ModelCommandExecutionContext.swift:24` initializes production `projectionHome` with `FileManager.default.homeDirectoryForCurrentUser`. `ModelsSubcommand.swift:497–500` passes it directly to preparation. Bound owner/control invocation and lease validation use `ModelTransactionContextLoader.kernelHomeDirectory()`, backed by `getpwuid(geteuid())`. Control-r4 Section E requires kernel-derived home for the namespace.

**Consequence.** The two paths needlessly depend on distinct home-resolution behavior. If those sources diverge, projection can produce a context that bound invocation rejects. No wrong-journal authorization or demonstrated production divergence is claimed; the bound loader still compares the expected home/config/root digest and fails closed.

**Correction.** Use the kernel-home helper for production projection and retain explicit home injection only as a test dependency. Kernel-home lookup failure must not fall back to an alternative directory. Root has acknowledged and queued this correction.

**Verification needed.** Production lookup parity, explicit fixture-home override, and lookup-failure fail-closed behavior.

## L2 — Lease check proves the inode is locked, not that the supplied description holds it

**Evidence.** `ModelTransactionControlLease.start` validates the inherited FD's regular private owned-file metadata, compares its inode against the fixed control-lock path, and requires a separately opened FD's nonblocking exclusive flock to fail with `EWOULDBLOCK` (`ModelTransactionContext.swift:358–382`). A different open-file description for that same inode can satisfy these checks while another process/description owns the lock. The supplied inherited descriptor itself is never checked for exclusive-lock ownership.

**Consequence.** A malformed dispatch can be accepted as retaining the parent's lock even though its supplied FD would not preserve that lock after the actual holder exits. The trusted production parent is expected to pass its real holder, and standalone controls already exist, so this is a defensive validation gap rather than an established control-authority bypass.

**Correction.** Validate that a nonblocking exclusive flock on the supplied inherited descriptor succeeds, which is idempotent for the correctly inherited locked description and fails against an unrelated holder. Retain the separately opened comparison check; do not unlock or close the inherited holder before helper exit.

**Verification needed.** A child with the real inherited holder passes and keeps exclusivity after parent descriptor closure. A same-inode independently opened descriptor fails while another description holds the lock. Preserve wrong-inode/type/mode, missing/duplicate descriptor, parent-loss, lifetime-EOF and self-deadline cases.

## Evidence supporting the preliminary zero-C/H/M result

- **Same consumed config bytes.** Capture opens the fixed file once, validates private regular ownership/ACL/link/size metadata, performs a bounded UTF-8 read, compares before/after file metadata, and supplies only that captured text to every ConfigLoader callback. The config digest is computed from those same bytes. Expectation fields are closed, duplicate keys rejected, numeric/hash/home/config identities checked, and failures occur before bound store construction. Continuing with captured A after atomic replacement never decodes B.
- **Namespace and root identity.** Bound load requires the sanitized namespace, existing safe roots, and exact context digest. Projection separates read-only prepare, authorized store setup/reservations, and read-only finalization. The opaque store receipt is constructed in the store-owned boundary; finalization independently checks durable/journal identities. Store operations additionally compare the bound journal identity with their descriptor. Missing/replaced roots cannot silently create or select another bound store.
- **Filesystem scope.** The inspected storage dependency uses descriptor-relative traversal, no-follow directory/file checks, pinned scope descriptors and post-opening identity checks. This corroborates the context integration but is not a final audit of every retention/cleanup filesystem operation.
- **Output and error minimization.** The public source exposes only `transaction_context_sha256`. Private config paths, inode identities, home and config contents remain in the internal digest/expectation path. Context failures use a fixed sanitized message. This inspection did not read operator secrets or dump the environment.
- **Helper lifetime.** The dedicated timer is started before config/journal work for app control options, enforces the ten-second deadline, parent identity and lifetime-pipe events independently of synchronous work, and is retained by the control command through exit. FD types/access, distinct descriptor numbers, and the fixed lock inode are checked. The helper never targets an owner PID in this code.
- **Protocol1 compatibility.** Source context digest and top-level recoveries are emitted only for protocol2. Row action generation fields are explicitly enabled for protocol2, and recovery actions encode generation explicitly. The builder discards actionable local controls/recoveries when a valid bound context digest is absent. Protocol1's encoded additions remain absent in the inspected production builder path.
- **Adoption authority.** The runtime command uses explicit production dependencies, removes the former environment/process-name test bypass, and requires current signed feed versions/digest, nonstale warnings, catalog binding and hardware checks. Historical parsing with freshness disabled is confined to evidence validation callers; normal adoption still defaults to freshness enforcement. The config ownership correction compares the complete signed recommendation binding rather than conflating a catalog key with its canonical artifact model ID.

## Snapshot

SHA-256 hashes captured for the reviewed slice, corroborating dependencies/tests and approved contracts:

```text
b7071ad2e3245e34c3ef0a0a1287906379c812f03a81164e38768603c6ca1307  phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift
397817cebf43cd56b6c6e007d679e8ea22b9de3bc4b61a840b6845040aff06b7  phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
0107c91c2b57ae0d6954e6298d866d4bd1dbdfb2f59ac5ba3c8194191bf6080e  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
7c25fe1ca3ca4ca21059e786143719aa108343cb282b94d74258049ac33529f4  phase3-binary/Sources/macprovider-cli/ModelCommandExecutionContext.swift
eee2d11a4942ce270322e755118bed424b1d2687025295487f68439eb38b1607  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift
82a2f0c46f04a20bcf93161c518454bea00edd8de017cd5fcc64888cd40cef41  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
36b5984f964de4799e96478caee80472697280359ba92320c9ffe5d39816bdac  phase3-binary/Tests/macprovider-cliTests/ModelTransactionContextTests.swift
ba5b7b981d2c4c45f37dfdf22b5c41e53b1b6cbf31f424847613a25317e77a54  phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift
3bd808b21557a22a979446f300b22a2013f1717f06670c616ee9c858877679e3  docs/product-roadmap/build-1/transaction-control-addendum-r4.md
83841b4278d93eeaa7f64160699dc7874a592e2a0fd534a35b57c7eea04e6193  docs/product-roadmap/build-1/cleanup-recovery-addendum-r3.md
```

## Validation limits

Performed source/diff/contract tracing and inspected targeted context/encoding tests. No runtime test was started alongside the ongoing joint Swift run, and that run is not counted as independently executed evidence. Parent/lease process tests, the complete app dispatch/pin boundary, all downstream transaction writes and final post-fix source hashes still belong to the later full combined audit. No runtime source was edited.
