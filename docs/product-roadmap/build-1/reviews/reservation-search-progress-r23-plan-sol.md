# Build 1 reservation search progress R23/R29 — independent adversarial plan review

Date: 2026-09-11. Reviewer: native GPT-5.6 Sol, high reasoning.

## Verdict

**REQUEST CHANGES. Architectural status: BLOCK.**

Exact finding count: **0 Critical, 3 High, 2 Medium, 1 Low**.

R23/R29 do not meet the mandatory zero-Critical/High/Medium reservation gate.
The SQLite/VFS/custody/serving/GC implementation remains unauthorized. This
review changes no source, test, SPEC, release, deployment, or operator-secret
file.

## Frozen inputs and independent checks

- Reviewed commit:
  `296110e246b2ca48e19dc2a9d41c73c8427d2657`.
- R23 SHA-256:
  `eb49d8ab8493edfc53527fb9ae2729e56983eeb76cb043d4b0ec959675c344b2`.
- R29 SHA-256:
  `77254fbb72d59763b333a219789922e492d32373454a08aa873d333a40c96f38`.
- Frozen failed R22 review SHA-256:
  `b5f316a49005bbc77b573544c40786ee3ecfc561a1414a2dd395d02f5324bed9`.
- Exact raw LF Appendix A SHA-256:
  `70b34abd8229e8a90bd45e0de6c283d33bf1af96a096193d9301e37dba7bf81f`.
- Exact Appendix B/C body SHA-256 values:
  `a8b2ba52cc55c66da33af305c6251308615a132235cf12da7617bcdd7b8e1bb8`
  and
  `c7b3594a76d118dd766082411407e267fa850a6364985422b8a9b0e64eaf6ae6`.
- `git diff --check 296110e2^ 296110e2` passed. The reviewed commit changes
  exactly R23 and R29.
- Python 3.14.7 linked SQLite 3.53.4. The extracted 43,652-byte Appendix A
  created 23 tables and 11 non-auto indexes, with `integrity_check=ok`, no
  foreign-key violations, no triggers or views, application ID 1297109587,
  user version 23, and exactly 32 seeded free serving slots. Slot 32 and a
  partial prepared/quarantined serving tuple failed their DDL constraints.
- The two production Swift roots contained exactly 191 sorted files and
  reproduced R23's file-set SHA-256
  `ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`.
  Dirty source was inspected as requested and was not modified.
- Two bounded supporting review lanes returned zero Critical/High/Medium.
  The controlling independent synthesis below rejects that result because
  executable and code-grounded counterexamples expose five gate-level defects.

### Executable counterexamples

The R23 authorizer was installed over an exact Appendix A in-memory database
and denied schema mutation after bootstrap. R29-11's required `ANALYZE` then
observed:

```text
analyze_result DatabaseError not authorized
analyze_first_denied (SQLITE_CREATE_TABLE, 'sqlite_stat1', null, 'main', null)
```

The lock-identity oracle acquired a shared `flock`, unlinked its pathname,
created a new file at the same pathname, and acquired an exclusive `flock` on
the replacement while the old shared lock remained held:

```text
flock_unlink_recreate old_inode 124806173 new_inode 124806174 exclusive_on_recreated acquired
```

The earlier independent POSIX oracles were also rerun: a traditional `fcntl`
lock became acquirable after closing an unrelated sibling FD; the R23 `flock`
remained blocking after sibling close and became acquirable only after unlock;
a replacement process received `ECHILD` from `waitpid`; and strict R23 VACUUM
authorization rejected at the empty-name ATTACH before any generated schema
mutation. Those results validate the chosen primitive and VACUUM correction but
do not define the missing per-artifact lock identity found below.

## Critical (0)

None.

## High (3)

### R23-PLAN-H1 — the authoritative registry cannot be expanded from R23's bytes

**Evidence.** R23 lines 331-338 require production dispatch and an independent
oracle to expand LF-terminated Appendix B records and compare
`registry_sha256`. Lines 340-357 supply one complete allocation record, row
range counts, four special name/count mappings, recovery intent counts, and
totals. Appendix B lines 794-835 supplies only the 495 transition names. R23
does not assign the remaining record fields for the other 494 entries: coarse
and fine predecessors/successors, effect template, external template, required
evidence kind, charge rule, and all change-count fields. It also publishes the
Appendix B body digest, not the promised digest of expanded registry records;
the only 64-hex values in R23 are the frozen review, Appendix A/B/C, and Swift
file-set hashes. By contrast, the withdrawn R22 lines 363-395 contained literal
per-range mapping rules for these fields. R23 line 12 permits no inherited R22
contract unless R23 restates it. R29-04 lines 70-78 checks counts and graph
reachability but supplies none of the missing record mappings or expected
expanded digest.

**Consequence.** Independent conforming authors can assign different state
edges, effects, evidence roles, charges, and statement-count guards to the same
Appendix B names. They will produce different registry bytes and hashes while
satisfying every literal R23/R29 count. Production dispatch, authorization,
replay, and the semantic-manifest binding therefore have no single executable
authority.

**Required correction.** Restore a complete literal mapping for every field of
all 495 records, covering every row/fixed ordinal and special case without name
inference or defaults. Publish the exact expanded-record grammar and
`registry_sha256`, derive the semantic manifest from those exact records, and
make R29 compare two independently generated full byte streams/digests while
mutating every mapped field.

### R23-PLAN-H2 — `database_identity_sha256` has no canonical preimage or lifecycle

**Evidence.** Appendix D requires `database_identity_sha256` in the root-owned
generation-50 control at R23 line 1185 and the signed retry-exhausted outcome at
line 1341, each referring to “section 10 authority identity.” Section 10 lines
613-650 defines tuple scalars, table-row identities, Appendix hashes, file/path
identities, request/output hashes, and catalog binding, but never defines a
database identity domain, ordered fields, or digest preimage. The only other
database-identity prose is the backup/restore requirement at lines 709-712,
which also does not state whether restore preserves an instance identity or
derives a new one. A repository search finds no other definition in R23/R29.

**Consequence.** The daemon, independent codec oracle, restored database, and
external control verifier can bind different bytes to the same authority.
`gc_first_over_control_v1` cannot prove which catalog instance it protects, and
the signed terminal outcome is not byte-reproducible. Backup/restore cannot
decide whether existing external records remain valid.

**Required correction.** Define one versioned tuple domain with an ordered,
typed, closed field list and exact derivation point. Specify persistence versus
rotation across bootstrap, failed candidate selection, backup, restore, and
database replacement. Add golden vectors and wrong-instance, omitted-field,
reordered-field, restore, and stale-external-record rejection tests to R29.

### R23-PLAN-H3 — the per-artifact `flock` has no canonical lock object contract

**Evidence.** R23 lines 412-429 require a worker-held shared per-artifact
`flock`, replacement-daemon exclusive acquisition, and quarantine on ambiguity;
lines 533-535 make the same exclusive lock gate GC. The directly addressable
custody leaves at lines 455-464 contain no lock leaf. `serving_worker_v1` lines
1271-1280 records only a shared-lock file identity SHA. R23 never defines the
lock pathname, containing root, whether the target is a sidecar or artifact
inode, creation/open flags, owner/mode/link predicates, directory-FD traversal,
publication/recovery semantics, or how custody SQL and the worker record select
the same inode. R29-08/09 says to test “artifact flock” and exclusive exclusion,
but has no path/inode substitution, unlink/recreate, or lock-target vector. The
executable oracle above proves that a stable pathname alone is insufficient:
the old shared and replacement exclusive locks can coexist on distinct inodes.

**Consequence.** Worker, replacement, adoption, and GC implementations can
legally lock different objects. Unlink/recreate or path substitution can let GC
delete an artifact while a worker lazily reads it, or let a replacement free a
slot while the original worker still holds the old inode. The claimed orphan
and worker-held-lock safety invariant is therefore not implementable from R23.

**Required correction.** Define one directly addressable lock leaf or retained
artifact inode with exact path derivation, captured-parent traversal, open/create
flags, ownership/mode/link/type/device identity, publication, lifetime, and
restart rules. Bind that exact identity into SQL, the worker record, completion,
and GC/replacement proof. Add same-path/different-inode, unlink/recreate,
rename/replacement, hard-link, wrong-owner/mode/device, restart, and worker/GC
race vectors.

## Medium (2)

### R23-PLAN-M1 — the complete Swift cutover inventory omits live filesystem readiness authorities

**Evidence.** R23 lines 652-705 calls its cutover matrix normative, and lines
1398-1421 calls the inspected-tree matrix complete. The matching 191-file dirty
production tree contains `ModelCatalogLocalInspection.swift`: lines 44-58 derive
the durable artifact URL, read it directly, call
`ModelArtifactVerifier.inspectCanonicalArtifact`, and mint `.verified`.
`DurableModelDiscovery.swift` lines 23-60 turns that state into wire
`readinessState: "ready"`; its fallback directly validates and inspects the
artifact path. These types are consumed by `ModelCatalogReadCommand.swift`,
`BYOMDiscovery.swift`, `ModelCatalogEconomics.swift`, and
`ModelCatalogTransactions.swift`. Neither file/type, `artifactURL`, nor
`inspectCanonicalArtifact` appears in the migration matrix or Appendix E's
target-identifier list at R23 lines 1372-1385. R29-12 lines 214-225 likewise
does not require these declarations/callsites or a direct artifact-readiness
ban. They are cross-file internal types, so the statement that private helpers
remain behind a named owner does not classify them.

**Consequence.** The declared static manifest can pass while post-B8 CLI and
economics flows still convert direct filesystem bytes into readiness and catalog
output outside the broker snapshot. That violates V5's sole catalog/custody
authority without touching any frozen literal bypass target.

**Required correction.** Add the exact files, types, direct artifact URL and
inspection calls, and every consumer to the pre/post-B8 matrix and Appendix E
target set. State that post-B8 readiness and economics come only from a typed
broker snapshot. Add static and runtime fault tests proving CLI/app/economics
cannot inspect a durable/custody root directly.

### R23-PLAN-M2 — R29 requires `ANALYZE` after R23 permanently denies its schema action

**Evidence.** R23 lines 132-140 denies schema mutation after B3 and says there
is no qualification exception. Appendix A does not create SQLite statistics
tables. R29-11 lines 198-205 requires the fully populated reachable maximum
database to run `ANALYZE` under the governed qualification. On SQLite 3.53.4,
the executable oracle over exact Appendix A bytes returned `SQLITE_AUTH` when
`ANALYZE` attempted `SQLITE_CREATE_TABLE sqlite_stat1` in `main`. This failure
occurs before any physical result can satisfy R29-11.

**Consequence.** A literal implementation cannot complete the mandatory
maximum-shape gate. Temporarily disabling the authorizer or permitting schema
mutation would violate R23, while skipping `ANALYZE` would violate R29.

**Required correction.** Remove `ANALYZE` from R29-11 if statistics are not part
of the authority. If statistics are required, add their exact objects to the
authoritative DDL/count/hash/bounds and define the only permitted analysis
transition and authorizer action sequence. Rerun the restrictive-authorizer
oracle in either case.

## Low (1)

### R23-PLAN-L1 — the R22 disposition table points two corrections at unrelated tests

**Evidence.** R23 line 732 maps the request/channel correction H4 to R29-08/12,
but the byte-exact request protocol is R29-09; R29-08 covers staging, custody,
and worker restart. R23 line 739 maps generation-50 correction M4 to R29-05/09,
but R29-09 is the serving request/MLX test and contains no generation-50
predicate. R29-05 lines 95-102 is the applicable generation-50 test.

**Consequence.** A reviewer following only the disposition table can run the
wrong acceptance section and report a correction covered when its direct test
was skipped.

**Required correction.** Change H4 to R29-09/12 and M4 to R29-05, or add the
missing assertions to the sections currently cited.

## R22 finding disposition

| R22 finding | R23/R29 result |
|---|---|
| H1 `fcntl` sibling-close failure | **Closed for the selected primitive.** The independent oracle confirms `flock` survives an unrelated sibling close. R23-PLAN-H3 separately leaves the artifact lock object undefined. |
| H2 serving records undiscoverable | **Closed in bounded index shape.** Appendix A seeds 32 slots and derives each record path from SQL state. |
| H3 replacement cannot reap | **Closed.** Replacement expects `ECHILD` and uses public process observation plus lock proof. The oracle reproduced `ECHILD`. |
| H4 request bytes/channel unbound | **Closed in codec shape.** Request SHA, one-frame input, bounded output/completion, half-close, cancellation, and replay rejection are explicit. |
| H5 staging traversal unconstrained | **Closed in plan shape.** Captured-root component traversal, two-pass/copy comparison, and final rewalk are explicit. |
| H6 conflicting catalog binding | **Closed.** One nine-field `macprovider-r23/catalog-binding-v1` preimage is authoritative. |
| H7 registry count mismatch | **Partially corrected.** The four special names/counts now agree, but R23-PLAN-H1 finds that the remaining authoritative registry fields and expanded digest were removed. |
| M1 governed VACUUM failure | **Closed.** VACUUM is outside the physical claim and denied without an exception; the strict oracle rejects it at ATTACH. R23-PLAN-M2 finds a separate `ANALYZE` contradiction. |
| M2 Appendix A digest mismatch | **Closed.** Exact extraction reproduces the declared R23/R29 digest. |
| M3 incomplete Swift matrix | **Partially corrected.** The two named R22 omissions are present, but R23-PLAN-M1 finds current direct readiness authorities outside the allegedly complete matrix. |
| M4 generation-50 predicates | **Closed in DML/test shape.** Counts, predecessor, active helper, null fields, and first-over limits are literal. |

## Gate decision

The exact R23/R29 revision is rejected. Revise both normative documents,
recompute every affected document/Appendix/registry/semantic-manifest/inventory
digest, and rerun an independent native Sol gate. Do not begin the R23
Swift/C/daemon/SPEC implementation until a fresh review reports zero Critical,
High, and Medium findings.
