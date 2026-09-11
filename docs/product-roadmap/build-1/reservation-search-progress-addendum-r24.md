# Build 1 reservation search progress addendum R24

Date: 2026-09-11. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.

R24 corrects the exact rejected R23/R29 candidate. R24 and R23 must be read
together: R24 replaces R23 sections 3's `bootstrap_id` derivation, 5.2, the
artifact-lock portions of 6.1/6.2/8/9/10/12, the readiness rows of section 11
and Appendix E, and the R22 disposition cross-references. All other R23
requirements remain mandatory. R30 replaces R29 only where R30 says so and
otherwise carries every R29 test forward. No earlier R22 text becomes authority.

The frozen failed review is
`docs/product-roadmap/build-1/reviews/reservation-search-progress-r23-plan-sol.md`,
SHA-256 `09b93232b98287ce3623e88a877f13c00949a2ec968d7afe741d31f13430c199`,
committed at `a7a13dfe52db450c786ab36d8608cb1a9eeccc70`. It reports exactly
0 Critical, 3 High, 2 Medium, and 1 Low finding. The R23 and R29 inputs are
`eb49d8ab8493edfc53527fb9ae2729e56983eeb76cb043d4b0ec959675c344b2`
and `77254fbb72d59763b333a219789922e492d32373454a08aa873d333a40c96f38`.
This author slice changes only R24 and R30. It changes no Swift, C, test, SPEC,
schema, release, deployment, secret, or d-inference file.

## 1. Closed finding dispositions

| finding | required R24 correction | exact R30 proof |
|---|---|---|
| H1 incomplete registry | Appendix A is a complete generator with all fields supplied; Appendix B is the canonical literal 495-line result; record and semantic digests are fixed | R30-02 |
| H2 database identity missing | one tuple domain, exact 13 fields, first-durable nonce, derivation point, preservation/rotation/crash and external-record rules | R30-03 |
| H3 artifact lock object missing | one root-owned, directly addressable, never-unlinked leaf per artifact; captured-parent/open/identity/lifetime rules; SQL and codec binding | R30-04 |
| M1 readiness authorities omitted | exact files, symbols, direct reads, and four consumers are in the cutover and static/runtime manifest | R30-05 |
| M2 ANALYZE impossible | ANALYZE and PRAGMA optimize are outside qualification and always denied; no statistics object exists | R30-06 |
| L1 stale references | request/channel correction is R29-09/R29-12; generation 50 is R29-05 only | R30-07 |

No finding is downgraded, waived, or answered by reducing acceptance. The
implementation gate remains closed until an independent GPT-5.6 Sol review of
the exact R24/R30 hashes reports zero Critical, High, and Medium findings.

## 2. Canonical complete transition registry

### 2.1 Exact record grammar and authority

The canonical registry is exactly the raw bytes in Appendix B: 495 records,
one record per LF-terminated line, no header, blank line, CR, trailing space,
escape, comment, Unicode, or terminal omission. Every record has exactly these
20 pipe-separated ASCII fields:

~~~text
scope|ordinal|family|local_ordinal|name|coarse_from|coarse_to|fine_from|fine_to|effect_template|external_template|required_evidence_kind|charge_rule|begin_changes|progress_changes_base|progress_changes_with_incumbent|cancel_progress_changes|finish_changes|abort_finish_changes|max_row_changes
~~~

`-` is the only encoding of SQL NULL and is legal only for
`required_evidence_kind`. Decimal integers have no sign or leading zero except
zero itself. No field is inferred from `name`, a prefix, a suffix, another
revision, or a runtime default. Appendix A supplies every field position to
`emit`; Appendix B removes even dependence on that program by publishing the
literal bytes. If the program and literal bytes disagree, author generation
fails.

The SHA-256 of Appendix B's 68,992 raw bytes is
`d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63`.
B3 inserts fields 1...18 and 20 into the R23 `transition_registry`, translating
field 12 `-` to SQL NULL. Field 19 is the exact aborted/protected finish count
bound by `registry_sha256` and the compiled dispatcher. It is four only for
allocation and three otherwise. The selected binary contains Appendix B bytes;
startup hashes them, compares `protocol_meta.registry_sha256`, reconstructs the
SQL projection in primary-key order, and byte-compares all projected fields.
A hash-only comparison is insufficient.

The allocation choice is closed: begin 8; successful progress 11; cancellation
progress 3; committed finish 3; aborted allocation finish 4. The checkpoint
choice is closed: no-incumbent progress 8 and incumbent replacement progress
11. The four special effect names are exactly
`staging-register-progress-full`,
`custody-verified-pending-progress-full`, `checkpoint-progress-choice`, and
`allocation-progress-choice`; their Appendix C branches are selected only by
the exact pre-state named in the record. Generic progress never substitutes
for a special branch. All 128 recovery records have exactly one
`legacy-inspect-readonly` intent. The 16 external row records are one directory,
four A5 files, one staging registration, one custody copy, one replacement
switch, and eight abort receipts. Allocation contributes four intents for each
of eight attempts per slot. Thus the R23 bound remains
`32S + 16R + 128 = 49,280` at S=R=1,024.

The compiler dispatch table is exact:

| effect_template | begin | selected progress | cancel progress | committed finish | aborted/protected finish |
|---|---|---|---|---|---|
| generic-progress | R23 generic-begin with the external-template K below | R23 generic-progress with E below | generic-progress with E=0 | R23 generic-finish | R23 generic-finish |
| allocation-progress-choice | R23 generic-begin K=4 plus allocation-begin-addition, total 8 | allocation-success-progress-full, 11 | allocation-cancel-progress-full, 3 | generic-finish, 3 | allocation-aborted-finish-full, 4 |
| staging-register-progress-full | generic-begin K=1, 4 | staging-register-progress-full, 7 | generic-progress E=0, 4 | generic-finish, 3 | generic-finish, 3 |
| custody-verified-pending-progress-full | generic-begin K=1, 4 | custody-verified-pending-progress-full, 10 | generic-progress E=0, 4 | generic-finish, 3 | generic-finish, 3 |
| checkpoint-progress-choice | generic-begin K=0, 3 | initial-activation-progress-full 8 iff active tuple is all-null; replacement-progress-full 11 iff active tuple is complete | generic-progress E=0, 4 | generic-finish, 3 | generic-finish, 3 |

The external/evidence table supplies K and E without inspecting the transition
name: `none=(0,0)`, `four-existing-source-evidence=(4,4)`,
`create-directory=(1,1)`, `create-regular=(1,1)`,
`staging-register=(1,1)`, `custody-copy=(1,2)`,
`replacement-switch=(0,0)`, and `legacy-inspect-readonly=(1,0)`.
The record's evidence-kind and charge-rule fields are still compared exactly;
K/E never authorize a missing or different value. Any effect/external pair not
present in Appendix B and this table is an author-generation failure.

The R23 Appendix C body remains exactly 27,602 bytes with SHA-256
`c7b3594a76d118dd766082411407e267fa850a6364985422b8a9b0e64eaf6ae6`.
The new semantic manifest preimage is canonical `tuple_v1` domain
`macprovider-r24/semantic-manifest-v1` with exactly three `bytes` fields in order:
(1) those R23 Appendix C body bytes, (2) the R24 Appendix B registry bytes, and
(3) the R24 Appendix C dispatch bytes. The 1,309 dispatch bytes have SHA-256
`af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb`. Its 97,959
bytes hash to
`0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee`.
This replaces the R23 semantic-manifest value. Production generates SQL,
bind types, branch selection, external intents, evidence roles, charges, and
change-count guards only from these three byte strings.

## 3. Exact database instance identity

### 3.1 First-durable bootstrap nonce

R24 changes only R23's claim that no randomness enters `bootstrap_id`. Before
any candidate directory or main file exists, B0 reads exactly 32 bytes from
`SecRandomCopyBytes`. Failure or a short result aborts without a durable write.
The fixed bootstrap-intent path is derived from the frozen R4 source-index SHA,
not the nonce. The first complete durable intent stores the raw nonce and all
other bootstrap operands. Recovery after intent publication must reuse those
bytes; it may never draw a second nonce. A crash before a complete durable
intent leaves no identity. Cleanup of an exact unselected E0/E1 intent retires
that nonce permanently.

`bootstrap_id` is SHA-256 of `tuple_v1` domain
`macprovider-r24/bootstrap-id-v1`, with fields in this exact order and type:

1. `schema:text` literal `bootstrap_id_v1`;
2. `database_instance_nonce:bytes`, exactly 32 bytes;
3. `source_index_sha256:sha`;
4. `source_rows_sha256:sha`;
5. `schema_sha256:sha`, the R23 Appendix A digest;
6. `registry_sha256:sha`, the R24 Appendix B digest;
7. `semantic_manifest_sha256:sha`, the R24 digest above;
8. `application_id:u63`, literal 1297109587;
9. `user_version:u63`, literal 23;
10. `page_size:u63`, literal 4096;
11. `journal_mode:text`, literal `DELETE`;
12. `broker_protocol:u63`, literal 1.

The intent, deterministic candidate path, B3 `protocol_meta.bootstrap_id`, and
all recovery decisions use that one value. A second selected database
replacement must draw a nonce whose resulting bootstrap ID and database
identity both differ from the prior selected values; equality is a hard failure.

### 3.2 Database identity preimage and derivation point

`database_identity_sha256` is SHA-256 of `tuple_v1` domain
`macprovider-r24/database-identity-v1`, with exactly these 13 fields:

1. `schema:text` literal `database_identity_v1`;
2. `bootstrap_id:sha`;
3. `source_index_sha256:sha`;
4. `source_rows_sha256:sha`;
5. `candidate_directory_identity_sha256:sha`;
6. `schema_sha256:sha`;
7. `registry_sha256:sha`;
8. `semantic_manifest_sha256:sha`;
9. `application_id:u63` 1297109587;
10. `user_version:u63` 23;
11. `page_size:u63` 4096;
12. `journal_mode:text` `DELETE`;
13. `broker_protocol:u63` 1.

It is first derivable after the candidate directory identity is captured and
before B3's first database header write. B3 inserts every scalar source into
`protocol_meta`; the immutable bootstrap intent retains the nonce and matching
operands. The identity is recomputed, never accepted as a caller field. Any
post-B3 change to fields 2...13 protects the database before a read or external
operation. Mutable generation, counters, format SHA, selected pathname, current
main inode, wall/continuous time, host, user-visible model data, and SQL page
layout are excluded deliberately.

Crash behavior is exact: B0 before durable intent has no identity; B0 after
intent through B7 recovery retains one identity; candidate rename and B8 format
selection do not rotate it; ordinary transactions and hot-journal recovery do
not rotate it. Removing an exact unselected E0/E1 retires it. A selected
database is never silently reconstructed. Fresh bootstrap, rebootstrap, or
replacement rotates through the required unequal nonce/identity check.

A supported offline backup envelope binds database identity, all 13 operands,
bootstrap intent SHA, exact main-file SHA/length, schema/registry/semantic
bytes, and every artifact-lock identity. Restore preserves the identity only
when the prior selected broker is stopped, the same authority root and
never-replaced artifact-lock directory/leaves remain, the envelope verifies,
and byte/FK/integrity/startup checks pass before atomic selection. A raw copy,
new root, missing/recreated lock leaf, concurrent original, partial envelope, or
changed operand is not a preserving restore; it rejects. Disaster recovery to
a new authority root is a fresh replacement and rotates identity. This rule
keeps inode-bound lock evidence truthful.

The identity is added directly to `serving_pin_v1`, `serving_worker_v1`,
`serving_completion_v1`, `gc_result_v1`, and `gc_first_over_control_v1`; the
existing `request_outcome_v1` field 18 now resolves only to this definition. It
is also included in staging/custody receipts and every replacement/GC operation
authorization. Old records with a different identity reject before process
observation, file access, inference, deletion, or signed outcome. There is no
compatibility decoder for an omitted identity after B8.

Golden vector: nonce bytes `00...1f`; source-index `11` repeated 32 bytes;
source-rows `22` repeated 32; candidate-directory identity `33` repeated 32;
the exact R23 schema, R24 registry, and R24 semantic digests above. The
305-byte bootstrap preimage hashes to
`9e96ec3b9eea6de1bac0bc4699589a1176048a0fb7415b782170f5d0975d56c3`.
The resulting 344-byte database preimage hashes to
`0f9b6f86e77cf781a88b142d95ac50d37efce922dfa7f7fc3d288e6db4b93091`.

## 4. Canonical artifact lock object

### 4.1 Path, parent, creation, and immutable identity

B3 creates and fsyncs one root-owned directory `artifact-locks` beneath the
captured custody-store root. It is mode 0700, link count two while empty, a directory, on
the custody device, with no group/other write, setuid/setgid, user flags, or
system flags. The broker captures its FD using component-wise
`openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` and records its complete
R23 file-identity digest in the bootstrap intent. It revalidates the captured
FD and canonical parent entry before and after every lock-leaf open. Rename,
unlink, replacement, device crossing, or identity change protects all custody,
serving, replacement, and GC operations.

For artifact digest `<64-lowercase-hex>`, the only lock leaf is:

~~~text
artifact-locks/<artifact-hex>.lock-v1
~~~

No other path, artifact directory inode, receipt, temporary file, or caller FD
may be locked. Before first creation a durable custody intent enters literal
phase `lock-create-pending` and binds database identity, artifact digest, parent
identity, and exact relative-path digest. The broker then calls
`openat(parentFD, leaf, O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600)`.
If it crashes after create, recovery may adopt the leaf only from that exact
intent, while holding `LOCK_EX`, after every predicate below passes. Existing
published leaves open with `O_RDWR|O_NOFOLLOW|O_CLOEXEC`, never CREATE or TRUNC.
ENOENT after publication protects; it never recreates the leaf.

Before and after `flock`, the broker byte-compares `fstatat(...,
AT_SYMLINK_NOFOLLOW)` with `fstat(fd)`. Required values are regular file, root
UID, root GID selected at bootstrap, mode exactly 0600, link count one, byte
length zero, same device as the captured parent/custody root, stable device,
inode, birthtime, ctime, mtime, flags, and no ACL/xattr outside the explicit
empty allowlist. The leaf is fsynced and the parent is fsynced before its
identity enters the custody intent/receipt. V5 has no operation, authorizer
transition, cleanup path, rollback, GC branch, or recovery branch that unlinks,
renames, truncates, writes, chmods, chowns, links, or recreates a published lock
leaf. At most one leaf per one of 1,024 artifact slots exists; it survives
artifact GC and is removed only with offline destruction of the entire retired
V5 authority.

`artifact_lock_identity_sha256` is SHA-256 of `tuple_v1` domain
`macprovider-r24/artifact-lock-identity-v1` with exactly seven fields:
`schema:text` literal `artifact_lock_identity_v1`,
`database_identity_sha256:sha`, `artifact_sha256:sha`,
`relative_path:bytes`, `relative_path_sha256:sha`,
`parent_directory_identity_sha256:sha`, and `leaf_file_identity_sha256:sha`.
The last field is the R23 full file-identity digest and therefore binds the
inode and every metadata predicate above.

Golden vector uses database identity from section 3, artifact `ab` repeated 32
bytes, path
`artifact-locks/abababababababababababababababababababababababababababababababab.lock-v1`,
parent identity `44` repeated 32, and leaf identity `55` repeated 32. The path
SHA is `ea55b0d4bf6c4c83771d2971832992a197c41e8a97fce608e952bb5a4816e394`;
the 333-byte tuple hashes to
`199c369d4b9af4c07b9e9c648937bb9009cd07e956969327527d64ec49d40058`.

### 4.2 SQL, worker, completion, replacement, and GC binding

The custody receipt adds database identity, lock path/path SHA, parent identity,
leaf file identity, and artifact-lock identity. Its content SHA is stored in the
direct `evidence_objects` row; `custody_evidence_owners.receipt_evidence_sha256`
binds it; `custody_events` binds that owner and hashes the receipt reference;
`custody_current`, catalog tuples, and `serving_slots` bind the exact custody
event. This is the mandatory SQL chain. Startup expands it and directly reopens
the leaf before accepting custody. A missing link, same path with another inode,
or receipt/SQL splice protects.

`serving_worker_v1` and `serving_completion_v1` carry the exact artifact-lock
identity directly. The worker receives only the validated FD. The broker takes
`LOCK_SH` before opening artifact bytes, uses `posix_spawn` file actions to pass
one child descriptor, closes its own copy after spawn/record handoff, and never
retains another duplicate that could extend lifetime. The worker keeps the FD
until inference, lazy weight reads, terminal frame, and process exit are done.
The provider socket recipient never gets it.

Replacement and GC independently direct-open the canonical leaf, compare
fstatat/fstat/receipt/SQL identity, acquire nonblocking `LOCK_EX`, and revalidate
all identities after acquisition. Their operation authorization includes the
artifact-lock identity and database identity. Replacement proof binds both
incumbent and replacement lock identities; they must be the same for the same
artifact and distinct canonical identities for different artifacts. GC result
and first-over control codecs carry the exact lock identity. Exclusive
acquisition on a same-path replacement inode is a rejection, never absence
proof. Unlink/recreate, rename/new-file, hard link, symlink, wrong owner/mode/
device/flags/size, missing parent, stale receipt, and inode reuse all protect.

The root-owned parent and never-unlink rule are defense in depth; correctness
still depends on the identity comparison after lock acquisition. Physical Mac
acceptance must race a lazy MLX read against GC and show that the canonical old
inode remains excluded until the worker exits.

### 4.3 Exact R24 codec amendments

R24 retains R23 Appendix D field types, null rules, framing, limits, signing,
and relative order except for these closed insertions. In each listed codec,
`database_identity_sha256:sha` is inserted immediately after
`daemon_protocol_version`; every later R23 ordinal increments by one.
`request_outcome_v1` is the exception because its existing field 18 already
occupies the required position and is not duplicated.

- `staging_source_receipt_v1` adds only database identity at that common
  position. `custody_operation_v1` also inserts
  `artifact_lock_identity_sha256:sha-or-null` immediately after
  `artifact_sha256`; it is null only before `lock-create-pending` and non-null
  in that phase and every successor.
- `custody_receipt_v1` inserts, immediately after `artifact_sha256`,
  `artifact_lock_relative_path:bytes`, `artifact_lock_path_sha256:sha`,
  `artifact_lock_parent_identity_sha256:sha`,
  `artifact_lock_leaf_file_identity_sha256:sha`, and
  `artifact_lock_identity_sha256:sha`, in that order.
- `serving_pin_v1` and `serving_worker_v1` insert
  `artifact_lock_identity_sha256:sha` immediately after `artifact_sha256`.
- `serving_completion_v1` inserts `artifact_lock_identity_sha256:sha`
  immediately after `request_sha256`.
- `gc_result_v1` and `gc_first_over_control_v1` insert
  `artifact_lock_identity_sha256:sha` immediately after `artifact_sha256`.

Each affected tuple changes its domain prefix from `macprovider-r23/` to
`macprovider-r24/` and its terminal `-v1` to `-v2`. Signed codecs apply both
substitutions to unsigned and serialized domains, and signatures cover every
inserted field. Schema text changes its terminal `_v1` to `_v2` and daemon
protocol version becomes 2 for these affected codecs. R24 accepts no version-1
instance of an affected codec after B8. The R30 codec oracle expands a complete
ordinal table before source implementation; an insertion at any other position,
unchanged R23 domain, version 1, or signature that omits an inserted field is
invalid.
The external codec version is distinct from the catalog broker protocol field
in section 3, which remains literal 1.

## 5. Complete readiness-authority migration

R23 section 11 and Appendix E are extended by these mandatory rows:

| current file and live symbols | pre-B8 authority | post-B8 owner and prohibition |
|---|---|---|
| `ModelCatalogLocalInspection.swift`: `ModelCatalogLocalInspection`, `inspect`, `DurableModelArtifactStore.artifactURL`, `ModelCatalogVerifiedArtifactObservation`, `ModelArtifactVerifier.inspectCanonicalArtifact`, `validateVerifiedPlacements` | bounded R4/local observation only | `CatalogAuthorityV5.readSnapshot`; no construction, durable/custody URL, directory FD, hashing, or `.verified` minting in CLI/app/economics paths |
| `DurableModelDiscovery.swift`: `DurableModelDiscovery.discover`, `DurableModelArtifactStore.artifactURL`, `validatedContainedDirectory`, `ModelArtifactVerifier.inspectCanonicalArtifact`, `readinessState` | R4 discovery presentation | `BrokerCatalogDiscoveryProjection`; consumes typed broker readiness/config only; no filesystem fallback and no `ready` from path existence or bytes |
| `ModelCatalogReadCommand.swift`: initializer at `run`, `inspectCatalogKeys`, `catalogDiscovery` | creates one bounded R4 inspection | passes one broker snapshot; cannot instantiate local inspection or open durable/custody root |
| `BYOMDiscovery.swift`: `BYOMDiscoveryRunner.localInspection`, both `DurableModelDiscovery` constructions | optional R4 observation | consumes broker projection only; local BYOM preparation may inspect provider-owned staging but cannot mint durable readiness, catalog identity, or economics |
| `ModelCatalogEconomics.swift`: `build(...localInspection:)`, readiness/runtime mapping | presents R4 observation | readiness/economics fields come only from the same generation-bound broker snapshot |
| `ModelCatalogTransactions.swift`: `makeCompleteModelCatalogLocalActions`, local inspection construction/key/inspect | R4 local action preparation | broker action/snapshot RPC only; no direct artifact inspection authority |

The generated Appendix-E target set must include both file paths, every symbol
above, and every call edge into the four consumer files. An AST/call-graph gate
fails on post-B8 production construction of `ModelCatalogLocalInspection` or
`DurableModelDiscovery` with a durable/custody root, or calls from a catalog,
readiness, action, or economics path to `artifactURL`,
`validatedContainedDirectory`, `ModelCatalogVerifiedArtifactObservation`, or
`inspectCanonicalArtifact`. The only post-B8 filesystem verification is inside
the authenticated broker/custody service. Provider-owned staging preparation
may use its separately named `UntrustedPreparationInspection`; its output is
never accepted as readiness or authority.

The broker snapshot binds database identity, protocol generation, catalog
binding, custody event, artifact-lock identity, readiness enum
`ready|needs_preparation|protected`, verified byte count/config digest, and
freshness observation generation. CLI, app, discovery, actions, and economics
must consume the same snapshot generation. On broker unavailable, stale,
invalid, or mismatched data they return a typed unavailable/protected state;
they do not fall back to filesystem inspection or saved readiness.

## 6. Maintenance and physical qualification without ANALYZE

`ANALYZE`, `ANALYZE <table>`, `PRAGMA optimize`, and every direct or indirect
creation/read/write/delete of `sqlite_stat1`, `sqlite_stat2`, `sqlite_stat3`, or
`sqlite_stat4` are outside R24 authority. The permanent authorizer denies
`SQLITE_ANALYZE` and any schema/data action whose object name begins
`sqlite_stat`. Appendix A contains no statistics table and the startup schema
allowlist rejects one. There is no maintenance or qualification phase that
disables or replaces the authorizer.

The reachable maximum fixture uses legal DML only and proves row/count bounds,
`page_count`, main-file `fstat` length, journal high-water measurement,
`integrity_check`, `foreign_key_check`, and golden `EXPLAIN QUERY PLAN` for the
fixed free-slot/GC/catalog queries. R29-11's word `ANALYZE` is deleted from the
required successful sequence and becomes an explicit rejection test. VACUUM
remains denied. Physical qualification remains the as-grown maximum and cannot
use either command to improve size or query shape.

## 7. Compatibility, observability, rollback, and non-goals

R23's B8 fence, single broker/connection, bounded rollback journal, custody,
serving, request framing, generation-50, capacity, rollback, and physical-Mac
acceptance remain unchanged except as tightened here. Metrics may publish only
truncated database/lock identity prefixes, registry/semantic match booleans,
lock-state reason, page/counter headroom, and typed readiness state. They expose
no path, inode, request/model bytes, nonce, token, key, or full digest.

R24 adds no pricing, admission, settlement, reward, enforcement, release,
deployment, production activation, hardware qualification, general privileged
copy, or d-inference authority. Plan approval is not implementation or product
acceptance.

## 8. Corrected prior cross-references

R23's R22-H4 disposition points to **R29-09 and R29-12**. R23's R22-M4
disposition points to **R29-05 only**. R30-07 mechanically checks every R23 and
R24 finding row resolves to a section that contains the named assertion.

## Appendix A — executable complete registry generator

The source is an authoring oracle. Appendix B, not a runtime execution of this
program, is the canonical byte authority. The program supplies every record
field and asserts its closed counts and digest.

~~~python
from dataclasses import dataclass
from hashlib import sha256

FIELDS = ('scope','ordinal','family','local_ordinal','name','coarse_from','coarse_to','fine_from','fine_to','effect_template','external_template','required_evidence_kind','charge_rule','begin_changes','progress_changes_base','progress_changes_with_incumbent','cancel_progress_changes','finish_changes','abort_finish_changes','max_row_changes')
rows=[]
def emit(scope, ordinal, family, local, name, c0, c1, f0, f1, effect, external, evidence, charge, begin, progress, incumbent, cancel, finish, abort_finish, maximum):
    values=(scope,ordinal,family,local,name,c0,c1,f0,f1,effect,external,evidence,charge,begin,progress,incumbent,cancel,finish,abort_finish,maximum)
    assert len(values)==len(FIELDS)
    assert all('|' not in str(x) and '\n' not in str(x) for x in values)
    rows.append('|'.join(map(str,values)))

def row(name, ordinal, c0='A2', c1='A2', f0=None, f1=None, effect='generic-progress', external='none', evidence='-', charge='zero', begin=3, progress=4, incumbent=4, cancel=4, finish=3):
    emit('row',ordinal,'row',ordinal,name,c0,c1,f0 or f'row-normal-{ordinal}',f1 or f'row-normal-{ordinal+1}',effect,external,evidence,charge,begin,progress,incumbent,cancel,finish,3,12)

def fixed(family, global_ordinal, local, name, last, recovery=False):
    emit('fixed',global_ordinal,family,local,name,'active','complete' if last else 'active',f'{family}-{local}',f'{family}-{local+1}','generic-progress','legacy-inspect-readonly' if recovery else 'none','legacy-evidence-reference' if recovery else '-','zero',4 if recovery else 3,4,4,4,3,3,12)

emit('allocation',0,'allocation',0,'allocate-row','free','A2','free','row-normal-76','allocation-progress-choice','four-existing-source-evidence','source-set','allocation',8,11,11,3,3,4,12)

names=[]
for source in ['primary','origin','class','lineage']:
    for verb in ['publish','storage-index','path-index']: names.append(f'source-capture-{source}-{verb}')
names += ['raw-source-close','name-source-close','row-source-close','capture-run-close']
for pass_no in range(7):
    for verb in ['bind-input','publish-row-block','index-row-block','advance-output-sequence']: names.append(f'merge-pass-{pass_no}-{verb}')
names += ['run-open','run-close','merge-root-open','merge-root-close']
for level in range(8):
    for verb in ['emit-page','advance-level-sequence']: names.append(f'tree-level-{level}-{verb}')
for target in ['rows-1','rows-2','storage']:
    for verb in ['open','publish-block','advance-sequence','close']: names.append(f'verify-{target}-{verb}')
names += ['phase-A3-directory-intent','A3-directory-publication-receipt','A3-storage-index','A3-path-index','phase-A4-directory-durable']
for body in ['primary','origin','class','lineage']:
    for suffix in ['intent','publication-receipt','storage-index','path-index','durable']: names.append(f'A5-{body}-{suffix}')
names += ['prepared-adoption-record','prepared-storage-index','prepared-path-index','lifecycle-reserve','lifecycle-bind','binding-publish','phase-A6','activation-record','checkpoint-record']
assert len(names)==110
for o,name in enumerate(names):
    kw={}
    if o==76: kw.update(c0='A2',c1='A3')
    elif 77<=o<=79: kw.update(c0='A3',c1='A3')
    elif o==80: kw.update(c0='A3',c1='A4')
    elif 81<=o<=106: kw.update(c0='A4' if o==81 else 'A5',c1='A5')
    elif 107<=o<=109: kw.update(c0='A5' if o==107 else 'A6',c1='A6')
    if o==77: kw.update(external='create-directory',evidence='a3-directory',charge='a3-directory',begin=4,progress=5,incumbent=5)
    if o in (82,87,92,97):
        body=['primary','origin','class','lineage'][(o-82)//5]
        kw.update(external='create-regular',evidence=f'a5-{body}',charge='a5-evidence',begin=4,progress=5,incumbent=5)
    if o==101: kw.update(effect='staging-register-progress-full',external='staging-register',evidence='staging-source',charge='adoption-lifecycle',begin=4,progress=7,incumbent=7)
    if o==108: kw.update(effect='custody-verified-pending-progress-full',external='custody-copy',evidence='custody-receipt',charge='adoption-lifecycle',begin=4,progress=10,incumbent=10)
    if o==109: kw.update(effect='checkpoint-progress-choice',external='replacement-switch',evidence='catalog-custody',charge='adoption-lifecycle',progress=8,incumbent=11)
    row(name,o,**kw)

slots=['begin-abort-generation','close-sequence','close-work-root','release-lifecycle-if-selected','prepare-budget-abort-close','record-A7-aborting','record-A8-aborted','publish-abort-receipt']
for g in range(8):
    for slot,name0 in enumerate(slots):
        o=110+8*g+slot; name=f'abort-{g}-{name0}'
        if slot==0: c0,c1,f0,f1='A2','A7','row-normal-76',f'row-abort-{g}-1'
        elif slot<7: c0,c1,f0,f1='A7','A7',f'row-abort-{g}-{slot}',f'row-abort-{g}-{slot+1}'
        elif g<7: c0,c1,f0,f1='A7','A2',f'row-abort-{g}-7','row-normal-76'
        else: c0,c1,f0,f1='A7','A8','row-abort-7-7','row-abort-terminal'
        kw={}
        if slot==7: kw.update(external='create-regular',evidence='abort-receipt',charge='a1a2-release',begin=4,progress=5,incumbent=5)
        row(name,o,c0,c1,f0,f1,**kw)
assert len([x for x in rows if x.startswith('row|')])==174

specs=[]
source=[]
for state in ['empty-primary','empty-origin','empty-class','empty-lineage','primary-open','origin-open','class-open','lineage-open','raw-close','name-close','row-close','capture-close','source-verified','source-failed','source-retry','source-protected']:
    for verb in ['prepare','commit']: source.append(f'source-{state}-{verb}')
specs.append(('source',0,source))
merge=[]
for pass_no in range(8):
    for verb in ['open-input','open-output','bind-input','publish-row-block','index-row-block','advance-output','close-run','close-pass']: merge.append(f'merge-{pass_no}-{verb}')
specs.append(('merge',32,merge))
tree=[]
for level in range(8):
    for verb in ['open-level','select-root','advance-sequence','close-level']: tree.append(f'tree-{level}-{verb}')
specs.append(('tree',96,tree))
verification=[]
for target in ['rows-1','rows-2','storage','terminal']:
    for verb in ['open','publish-block','index-block','advance-sequence','close-pass','record-result','retry','protect']: verification.append(f'verification-{target}-{verb}')
specs.append(('verification',128,verification))
materialization=[]
for phase in ['A0','A1','A2','A3','A4','A5','A6','A7']:
    for verb in ['record-phase','bind-root','record-result','close']: materialization.append(f'materialization-{phase}-{verb}')
specs.append(('materialization',160,materialization))
recovery=[]
for state in ['selector-temp','selector-renamed','carrier-temp','carrier-renamed','carrier-durable','external-temp','external-renamed','external-durable','directory-created','directory-durable','phase-recorded','budget-reserving','budget-closing','abort-receipt','terminal-selector','protected']:
    for verb in ['inspect','adopt','resume','compensate','retry','close','record','protect']: recovery.append(f'recovery-{state}-{verb}')
specs.append(('recovery',192,recovery))
for family,base,ns in specs:
    for local,name in enumerate(ns): fixed(family,base+local,local,name,local==len(ns)-1,recovery=family=='recovery')

assert len(rows)==495
assert len(set(rows))==495
assert sum('|legacy-inspect-readonly|' in x for x in rows)==128
assert sum('|four-existing-source-evidence|' in x for x in rows)==1
assert sum('|create-directory|' in x for x in rows)==1
assert sum('|create-regular|' in x for x in rows)==12
assert sum('|staging-register|' in x for x in rows)==1
assert sum('|custody-copy|' in x for x in rows)==1
assert sum('|replacement-switch|' in x for x in rows)==1
blob=('\n'.join(rows)+'\n').encode()
assert sha256(blob).hexdigest() == 'd9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63'
import sys
sys.stdout.buffer.write(blob)
~~~

## Appendix B — canonical 495 expanded registry records

~~~text
allocation|0|allocation|0|allocate-row|free|A2|free|row-normal-76|allocation-progress-choice|four-existing-source-evidence|source-set|allocation|8|11|11|3|3|4|12
row|0|row|0|source-capture-primary-publish|A2|A2|row-normal-0|row-normal-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|1|row|1|source-capture-primary-storage-index|A2|A2|row-normal-1|row-normal-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|2|row|2|source-capture-primary-path-index|A2|A2|row-normal-2|row-normal-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|3|row|3|source-capture-origin-publish|A2|A2|row-normal-3|row-normal-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|4|row|4|source-capture-origin-storage-index|A2|A2|row-normal-4|row-normal-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|5|row|5|source-capture-origin-path-index|A2|A2|row-normal-5|row-normal-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|6|row|6|source-capture-class-publish|A2|A2|row-normal-6|row-normal-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|7|row|7|source-capture-class-storage-index|A2|A2|row-normal-7|row-normal-8|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|8|row|8|source-capture-class-path-index|A2|A2|row-normal-8|row-normal-9|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|9|row|9|source-capture-lineage-publish|A2|A2|row-normal-9|row-normal-10|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|10|row|10|source-capture-lineage-storage-index|A2|A2|row-normal-10|row-normal-11|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|11|row|11|source-capture-lineage-path-index|A2|A2|row-normal-11|row-normal-12|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|12|row|12|raw-source-close|A2|A2|row-normal-12|row-normal-13|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|13|row|13|name-source-close|A2|A2|row-normal-13|row-normal-14|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|14|row|14|row-source-close|A2|A2|row-normal-14|row-normal-15|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|15|row|15|capture-run-close|A2|A2|row-normal-15|row-normal-16|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|16|row|16|merge-pass-0-bind-input|A2|A2|row-normal-16|row-normal-17|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|17|row|17|merge-pass-0-publish-row-block|A2|A2|row-normal-17|row-normal-18|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|18|row|18|merge-pass-0-index-row-block|A2|A2|row-normal-18|row-normal-19|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|19|row|19|merge-pass-0-advance-output-sequence|A2|A2|row-normal-19|row-normal-20|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|20|row|20|merge-pass-1-bind-input|A2|A2|row-normal-20|row-normal-21|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|21|row|21|merge-pass-1-publish-row-block|A2|A2|row-normal-21|row-normal-22|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|22|row|22|merge-pass-1-index-row-block|A2|A2|row-normal-22|row-normal-23|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|23|row|23|merge-pass-1-advance-output-sequence|A2|A2|row-normal-23|row-normal-24|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|24|row|24|merge-pass-2-bind-input|A2|A2|row-normal-24|row-normal-25|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|25|row|25|merge-pass-2-publish-row-block|A2|A2|row-normal-25|row-normal-26|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|26|row|26|merge-pass-2-index-row-block|A2|A2|row-normal-26|row-normal-27|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|27|row|27|merge-pass-2-advance-output-sequence|A2|A2|row-normal-27|row-normal-28|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|28|row|28|merge-pass-3-bind-input|A2|A2|row-normal-28|row-normal-29|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|29|row|29|merge-pass-3-publish-row-block|A2|A2|row-normal-29|row-normal-30|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|30|row|30|merge-pass-3-index-row-block|A2|A2|row-normal-30|row-normal-31|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|31|row|31|merge-pass-3-advance-output-sequence|A2|A2|row-normal-31|row-normal-32|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|32|row|32|merge-pass-4-bind-input|A2|A2|row-normal-32|row-normal-33|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|33|row|33|merge-pass-4-publish-row-block|A2|A2|row-normal-33|row-normal-34|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|34|row|34|merge-pass-4-index-row-block|A2|A2|row-normal-34|row-normal-35|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|35|row|35|merge-pass-4-advance-output-sequence|A2|A2|row-normal-35|row-normal-36|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|36|row|36|merge-pass-5-bind-input|A2|A2|row-normal-36|row-normal-37|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|37|row|37|merge-pass-5-publish-row-block|A2|A2|row-normal-37|row-normal-38|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|38|row|38|merge-pass-5-index-row-block|A2|A2|row-normal-38|row-normal-39|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|39|row|39|merge-pass-5-advance-output-sequence|A2|A2|row-normal-39|row-normal-40|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|40|row|40|merge-pass-6-bind-input|A2|A2|row-normal-40|row-normal-41|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|41|row|41|merge-pass-6-publish-row-block|A2|A2|row-normal-41|row-normal-42|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|42|row|42|merge-pass-6-index-row-block|A2|A2|row-normal-42|row-normal-43|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|43|row|43|merge-pass-6-advance-output-sequence|A2|A2|row-normal-43|row-normal-44|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|44|row|44|run-open|A2|A2|row-normal-44|row-normal-45|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|45|row|45|run-close|A2|A2|row-normal-45|row-normal-46|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|46|row|46|merge-root-open|A2|A2|row-normal-46|row-normal-47|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|47|row|47|merge-root-close|A2|A2|row-normal-47|row-normal-48|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|48|row|48|tree-level-0-emit-page|A2|A2|row-normal-48|row-normal-49|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|49|row|49|tree-level-0-advance-level-sequence|A2|A2|row-normal-49|row-normal-50|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|50|row|50|tree-level-1-emit-page|A2|A2|row-normal-50|row-normal-51|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|51|row|51|tree-level-1-advance-level-sequence|A2|A2|row-normal-51|row-normal-52|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|52|row|52|tree-level-2-emit-page|A2|A2|row-normal-52|row-normal-53|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|53|row|53|tree-level-2-advance-level-sequence|A2|A2|row-normal-53|row-normal-54|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|54|row|54|tree-level-3-emit-page|A2|A2|row-normal-54|row-normal-55|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|55|row|55|tree-level-3-advance-level-sequence|A2|A2|row-normal-55|row-normal-56|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|56|row|56|tree-level-4-emit-page|A2|A2|row-normal-56|row-normal-57|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|57|row|57|tree-level-4-advance-level-sequence|A2|A2|row-normal-57|row-normal-58|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|58|row|58|tree-level-5-emit-page|A2|A2|row-normal-58|row-normal-59|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|59|row|59|tree-level-5-advance-level-sequence|A2|A2|row-normal-59|row-normal-60|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|60|row|60|tree-level-6-emit-page|A2|A2|row-normal-60|row-normal-61|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|61|row|61|tree-level-6-advance-level-sequence|A2|A2|row-normal-61|row-normal-62|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|62|row|62|tree-level-7-emit-page|A2|A2|row-normal-62|row-normal-63|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|63|row|63|tree-level-7-advance-level-sequence|A2|A2|row-normal-63|row-normal-64|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|64|row|64|verify-rows-1-open|A2|A2|row-normal-64|row-normal-65|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|65|row|65|verify-rows-1-publish-block|A2|A2|row-normal-65|row-normal-66|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|66|row|66|verify-rows-1-advance-sequence|A2|A2|row-normal-66|row-normal-67|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|67|row|67|verify-rows-1-close|A2|A2|row-normal-67|row-normal-68|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|68|row|68|verify-rows-2-open|A2|A2|row-normal-68|row-normal-69|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|69|row|69|verify-rows-2-publish-block|A2|A2|row-normal-69|row-normal-70|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|70|row|70|verify-rows-2-advance-sequence|A2|A2|row-normal-70|row-normal-71|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|71|row|71|verify-rows-2-close|A2|A2|row-normal-71|row-normal-72|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|72|row|72|verify-storage-open|A2|A2|row-normal-72|row-normal-73|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|73|row|73|verify-storage-publish-block|A2|A2|row-normal-73|row-normal-74|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|74|row|74|verify-storage-advance-sequence|A2|A2|row-normal-74|row-normal-75|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|75|row|75|verify-storage-close|A2|A2|row-normal-75|row-normal-76|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|76|row|76|phase-A3-directory-intent|A2|A3|row-normal-76|row-normal-77|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|77|row|77|A3-directory-publication-receipt|A3|A3|row-normal-77|row-normal-78|generic-progress|create-directory|a3-directory|a3-directory|4|5|5|4|3|3|12
row|78|row|78|A3-storage-index|A3|A3|row-normal-78|row-normal-79|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|79|row|79|A3-path-index|A3|A3|row-normal-79|row-normal-80|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|80|row|80|phase-A4-directory-durable|A3|A4|row-normal-80|row-normal-81|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|81|row|81|A5-primary-intent|A4|A5|row-normal-81|row-normal-82|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|82|row|82|A5-primary-publication-receipt|A5|A5|row-normal-82|row-normal-83|generic-progress|create-regular|a5-primary|a5-evidence|4|5|5|4|3|3|12
row|83|row|83|A5-primary-storage-index|A5|A5|row-normal-83|row-normal-84|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|84|row|84|A5-primary-path-index|A5|A5|row-normal-84|row-normal-85|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|85|row|85|A5-primary-durable|A5|A5|row-normal-85|row-normal-86|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|86|row|86|A5-origin-intent|A5|A5|row-normal-86|row-normal-87|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|87|row|87|A5-origin-publication-receipt|A5|A5|row-normal-87|row-normal-88|generic-progress|create-regular|a5-origin|a5-evidence|4|5|5|4|3|3|12
row|88|row|88|A5-origin-storage-index|A5|A5|row-normal-88|row-normal-89|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|89|row|89|A5-origin-path-index|A5|A5|row-normal-89|row-normal-90|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|90|row|90|A5-origin-durable|A5|A5|row-normal-90|row-normal-91|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|91|row|91|A5-class-intent|A5|A5|row-normal-91|row-normal-92|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|92|row|92|A5-class-publication-receipt|A5|A5|row-normal-92|row-normal-93|generic-progress|create-regular|a5-class|a5-evidence|4|5|5|4|3|3|12
row|93|row|93|A5-class-storage-index|A5|A5|row-normal-93|row-normal-94|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|94|row|94|A5-class-path-index|A5|A5|row-normal-94|row-normal-95|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|95|row|95|A5-class-durable|A5|A5|row-normal-95|row-normal-96|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|96|row|96|A5-lineage-intent|A5|A5|row-normal-96|row-normal-97|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|97|row|97|A5-lineage-publication-receipt|A5|A5|row-normal-97|row-normal-98|generic-progress|create-regular|a5-lineage|a5-evidence|4|5|5|4|3|3|12
row|98|row|98|A5-lineage-storage-index|A5|A5|row-normal-98|row-normal-99|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|99|row|99|A5-lineage-path-index|A5|A5|row-normal-99|row-normal-100|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|100|row|100|A5-lineage-durable|A5|A5|row-normal-100|row-normal-101|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|101|row|101|prepared-adoption-record|A5|A5|row-normal-101|row-normal-102|staging-register-progress-full|staging-register|staging-source|adoption-lifecycle|4|7|7|4|3|3|12
row|102|row|102|prepared-storage-index|A5|A5|row-normal-102|row-normal-103|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|103|row|103|prepared-path-index|A5|A5|row-normal-103|row-normal-104|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|104|row|104|lifecycle-reserve|A5|A5|row-normal-104|row-normal-105|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|105|row|105|lifecycle-bind|A5|A5|row-normal-105|row-normal-106|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|106|row|106|binding-publish|A5|A5|row-normal-106|row-normal-107|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|107|row|107|phase-A6|A5|A6|row-normal-107|row-normal-108|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|108|row|108|activation-record|A6|A6|row-normal-108|row-normal-109|custody-verified-pending-progress-full|custody-copy|custody-receipt|adoption-lifecycle|4|10|10|4|3|3|12
row|109|row|109|checkpoint-record|A6|A6|row-normal-109|row-normal-110|checkpoint-progress-choice|replacement-switch|catalog-custody|adoption-lifecycle|3|8|11|4|3|3|12
row|110|row|110|abort-0-begin-abort-generation|A2|A7|row-normal-76|row-abort-0-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|111|row|111|abort-0-close-sequence|A7|A7|row-abort-0-1|row-abort-0-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|112|row|112|abort-0-close-work-root|A7|A7|row-abort-0-2|row-abort-0-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|113|row|113|abort-0-release-lifecycle-if-selected|A7|A7|row-abort-0-3|row-abort-0-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|114|row|114|abort-0-prepare-budget-abort-close|A7|A7|row-abort-0-4|row-abort-0-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|115|row|115|abort-0-record-A7-aborting|A7|A7|row-abort-0-5|row-abort-0-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|116|row|116|abort-0-record-A8-aborted|A7|A7|row-abort-0-6|row-abort-0-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|117|row|117|abort-0-publish-abort-receipt|A7|A2|row-abort-0-7|row-normal-76|generic-progress|create-regular|abort-receipt|a1a2-release|4|5|5|4|3|3|12
row|118|row|118|abort-1-begin-abort-generation|A2|A7|row-normal-76|row-abort-1-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|119|row|119|abort-1-close-sequence|A7|A7|row-abort-1-1|row-abort-1-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|120|row|120|abort-1-close-work-root|A7|A7|row-abort-1-2|row-abort-1-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|121|row|121|abort-1-release-lifecycle-if-selected|A7|A7|row-abort-1-3|row-abort-1-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|122|row|122|abort-1-prepare-budget-abort-close|A7|A7|row-abort-1-4|row-abort-1-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|123|row|123|abort-1-record-A7-aborting|A7|A7|row-abort-1-5|row-abort-1-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|124|row|124|abort-1-record-A8-aborted|A7|A7|row-abort-1-6|row-abort-1-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|125|row|125|abort-1-publish-abort-receipt|A7|A2|row-abort-1-7|row-normal-76|generic-progress|create-regular|abort-receipt|a1a2-release|4|5|5|4|3|3|12
row|126|row|126|abort-2-begin-abort-generation|A2|A7|row-normal-76|row-abort-2-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|127|row|127|abort-2-close-sequence|A7|A7|row-abort-2-1|row-abort-2-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|128|row|128|abort-2-close-work-root|A7|A7|row-abort-2-2|row-abort-2-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|129|row|129|abort-2-release-lifecycle-if-selected|A7|A7|row-abort-2-3|row-abort-2-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|130|row|130|abort-2-prepare-budget-abort-close|A7|A7|row-abort-2-4|row-abort-2-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|131|row|131|abort-2-record-A7-aborting|A7|A7|row-abort-2-5|row-abort-2-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|132|row|132|abort-2-record-A8-aborted|A7|A7|row-abort-2-6|row-abort-2-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|133|row|133|abort-2-publish-abort-receipt|A7|A2|row-abort-2-7|row-normal-76|generic-progress|create-regular|abort-receipt|a1a2-release|4|5|5|4|3|3|12
row|134|row|134|abort-3-begin-abort-generation|A2|A7|row-normal-76|row-abort-3-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|135|row|135|abort-3-close-sequence|A7|A7|row-abort-3-1|row-abort-3-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|136|row|136|abort-3-close-work-root|A7|A7|row-abort-3-2|row-abort-3-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|137|row|137|abort-3-release-lifecycle-if-selected|A7|A7|row-abort-3-3|row-abort-3-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|138|row|138|abort-3-prepare-budget-abort-close|A7|A7|row-abort-3-4|row-abort-3-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|139|row|139|abort-3-record-A7-aborting|A7|A7|row-abort-3-5|row-abort-3-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|140|row|140|abort-3-record-A8-aborted|A7|A7|row-abort-3-6|row-abort-3-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|141|row|141|abort-3-publish-abort-receipt|A7|A2|row-abort-3-7|row-normal-76|generic-progress|create-regular|abort-receipt|a1a2-release|4|5|5|4|3|3|12
row|142|row|142|abort-4-begin-abort-generation|A2|A7|row-normal-76|row-abort-4-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|143|row|143|abort-4-close-sequence|A7|A7|row-abort-4-1|row-abort-4-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|144|row|144|abort-4-close-work-root|A7|A7|row-abort-4-2|row-abort-4-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|145|row|145|abort-4-release-lifecycle-if-selected|A7|A7|row-abort-4-3|row-abort-4-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|146|row|146|abort-4-prepare-budget-abort-close|A7|A7|row-abort-4-4|row-abort-4-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|147|row|147|abort-4-record-A7-aborting|A7|A7|row-abort-4-5|row-abort-4-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|148|row|148|abort-4-record-A8-aborted|A7|A7|row-abort-4-6|row-abort-4-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|149|row|149|abort-4-publish-abort-receipt|A7|A2|row-abort-4-7|row-normal-76|generic-progress|create-regular|abort-receipt|a1a2-release|4|5|5|4|3|3|12
row|150|row|150|abort-5-begin-abort-generation|A2|A7|row-normal-76|row-abort-5-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|151|row|151|abort-5-close-sequence|A7|A7|row-abort-5-1|row-abort-5-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|152|row|152|abort-5-close-work-root|A7|A7|row-abort-5-2|row-abort-5-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|153|row|153|abort-5-release-lifecycle-if-selected|A7|A7|row-abort-5-3|row-abort-5-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|154|row|154|abort-5-prepare-budget-abort-close|A7|A7|row-abort-5-4|row-abort-5-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|155|row|155|abort-5-record-A7-aborting|A7|A7|row-abort-5-5|row-abort-5-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|156|row|156|abort-5-record-A8-aborted|A7|A7|row-abort-5-6|row-abort-5-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|157|row|157|abort-5-publish-abort-receipt|A7|A2|row-abort-5-7|row-normal-76|generic-progress|create-regular|abort-receipt|a1a2-release|4|5|5|4|3|3|12
row|158|row|158|abort-6-begin-abort-generation|A2|A7|row-normal-76|row-abort-6-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|159|row|159|abort-6-close-sequence|A7|A7|row-abort-6-1|row-abort-6-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|160|row|160|abort-6-close-work-root|A7|A7|row-abort-6-2|row-abort-6-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|161|row|161|abort-6-release-lifecycle-if-selected|A7|A7|row-abort-6-3|row-abort-6-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|162|row|162|abort-6-prepare-budget-abort-close|A7|A7|row-abort-6-4|row-abort-6-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|163|row|163|abort-6-record-A7-aborting|A7|A7|row-abort-6-5|row-abort-6-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|164|row|164|abort-6-record-A8-aborted|A7|A7|row-abort-6-6|row-abort-6-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|165|row|165|abort-6-publish-abort-receipt|A7|A2|row-abort-6-7|row-normal-76|generic-progress|create-regular|abort-receipt|a1a2-release|4|5|5|4|3|3|12
row|166|row|166|abort-7-begin-abort-generation|A2|A7|row-normal-76|row-abort-7-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|167|row|167|abort-7-close-sequence|A7|A7|row-abort-7-1|row-abort-7-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|168|row|168|abort-7-close-work-root|A7|A7|row-abort-7-2|row-abort-7-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|169|row|169|abort-7-release-lifecycle-if-selected|A7|A7|row-abort-7-3|row-abort-7-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|170|row|170|abort-7-prepare-budget-abort-close|A7|A7|row-abort-7-4|row-abort-7-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|171|row|171|abort-7-record-A7-aborting|A7|A7|row-abort-7-5|row-abort-7-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|172|row|172|abort-7-record-A8-aborted|A7|A7|row-abort-7-6|row-abort-7-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
row|173|row|173|abort-7-publish-abort-receipt|A7|A8|row-abort-7-7|row-abort-terminal|generic-progress|create-regular|abort-receipt|a1a2-release|4|5|5|4|3|3|12
fixed|0|source|0|source-empty-primary-prepare|active|active|source-0|source-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|1|source|1|source-empty-primary-commit|active|active|source-1|source-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|2|source|2|source-empty-origin-prepare|active|active|source-2|source-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|3|source|3|source-empty-origin-commit|active|active|source-3|source-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|4|source|4|source-empty-class-prepare|active|active|source-4|source-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|5|source|5|source-empty-class-commit|active|active|source-5|source-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|6|source|6|source-empty-lineage-prepare|active|active|source-6|source-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|7|source|7|source-empty-lineage-commit|active|active|source-7|source-8|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|8|source|8|source-primary-open-prepare|active|active|source-8|source-9|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|9|source|9|source-primary-open-commit|active|active|source-9|source-10|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|10|source|10|source-origin-open-prepare|active|active|source-10|source-11|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|11|source|11|source-origin-open-commit|active|active|source-11|source-12|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|12|source|12|source-class-open-prepare|active|active|source-12|source-13|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|13|source|13|source-class-open-commit|active|active|source-13|source-14|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|14|source|14|source-lineage-open-prepare|active|active|source-14|source-15|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|15|source|15|source-lineage-open-commit|active|active|source-15|source-16|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|16|source|16|source-raw-close-prepare|active|active|source-16|source-17|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|17|source|17|source-raw-close-commit|active|active|source-17|source-18|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|18|source|18|source-name-close-prepare|active|active|source-18|source-19|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|19|source|19|source-name-close-commit|active|active|source-19|source-20|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|20|source|20|source-row-close-prepare|active|active|source-20|source-21|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|21|source|21|source-row-close-commit|active|active|source-21|source-22|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|22|source|22|source-capture-close-prepare|active|active|source-22|source-23|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|23|source|23|source-capture-close-commit|active|active|source-23|source-24|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|24|source|24|source-source-verified-prepare|active|active|source-24|source-25|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|25|source|25|source-source-verified-commit|active|active|source-25|source-26|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|26|source|26|source-source-failed-prepare|active|active|source-26|source-27|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|27|source|27|source-source-failed-commit|active|active|source-27|source-28|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|28|source|28|source-source-retry-prepare|active|active|source-28|source-29|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|29|source|29|source-source-retry-commit|active|active|source-29|source-30|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|30|source|30|source-source-protected-prepare|active|active|source-30|source-31|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|31|source|31|source-source-protected-commit|active|complete|source-31|source-32|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|32|merge|0|merge-0-open-input|active|active|merge-0|merge-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|33|merge|1|merge-0-open-output|active|active|merge-1|merge-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|34|merge|2|merge-0-bind-input|active|active|merge-2|merge-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|35|merge|3|merge-0-publish-row-block|active|active|merge-3|merge-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|36|merge|4|merge-0-index-row-block|active|active|merge-4|merge-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|37|merge|5|merge-0-advance-output|active|active|merge-5|merge-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|38|merge|6|merge-0-close-run|active|active|merge-6|merge-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|39|merge|7|merge-0-close-pass|active|active|merge-7|merge-8|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|40|merge|8|merge-1-open-input|active|active|merge-8|merge-9|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|41|merge|9|merge-1-open-output|active|active|merge-9|merge-10|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|42|merge|10|merge-1-bind-input|active|active|merge-10|merge-11|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|43|merge|11|merge-1-publish-row-block|active|active|merge-11|merge-12|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|44|merge|12|merge-1-index-row-block|active|active|merge-12|merge-13|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|45|merge|13|merge-1-advance-output|active|active|merge-13|merge-14|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|46|merge|14|merge-1-close-run|active|active|merge-14|merge-15|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|47|merge|15|merge-1-close-pass|active|active|merge-15|merge-16|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|48|merge|16|merge-2-open-input|active|active|merge-16|merge-17|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|49|merge|17|merge-2-open-output|active|active|merge-17|merge-18|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|50|merge|18|merge-2-bind-input|active|active|merge-18|merge-19|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|51|merge|19|merge-2-publish-row-block|active|active|merge-19|merge-20|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|52|merge|20|merge-2-index-row-block|active|active|merge-20|merge-21|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|53|merge|21|merge-2-advance-output|active|active|merge-21|merge-22|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|54|merge|22|merge-2-close-run|active|active|merge-22|merge-23|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|55|merge|23|merge-2-close-pass|active|active|merge-23|merge-24|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|56|merge|24|merge-3-open-input|active|active|merge-24|merge-25|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|57|merge|25|merge-3-open-output|active|active|merge-25|merge-26|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|58|merge|26|merge-3-bind-input|active|active|merge-26|merge-27|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|59|merge|27|merge-3-publish-row-block|active|active|merge-27|merge-28|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|60|merge|28|merge-3-index-row-block|active|active|merge-28|merge-29|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|61|merge|29|merge-3-advance-output|active|active|merge-29|merge-30|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|62|merge|30|merge-3-close-run|active|active|merge-30|merge-31|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|63|merge|31|merge-3-close-pass|active|active|merge-31|merge-32|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|64|merge|32|merge-4-open-input|active|active|merge-32|merge-33|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|65|merge|33|merge-4-open-output|active|active|merge-33|merge-34|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|66|merge|34|merge-4-bind-input|active|active|merge-34|merge-35|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|67|merge|35|merge-4-publish-row-block|active|active|merge-35|merge-36|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|68|merge|36|merge-4-index-row-block|active|active|merge-36|merge-37|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|69|merge|37|merge-4-advance-output|active|active|merge-37|merge-38|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|70|merge|38|merge-4-close-run|active|active|merge-38|merge-39|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|71|merge|39|merge-4-close-pass|active|active|merge-39|merge-40|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|72|merge|40|merge-5-open-input|active|active|merge-40|merge-41|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|73|merge|41|merge-5-open-output|active|active|merge-41|merge-42|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|74|merge|42|merge-5-bind-input|active|active|merge-42|merge-43|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|75|merge|43|merge-5-publish-row-block|active|active|merge-43|merge-44|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|76|merge|44|merge-5-index-row-block|active|active|merge-44|merge-45|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|77|merge|45|merge-5-advance-output|active|active|merge-45|merge-46|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|78|merge|46|merge-5-close-run|active|active|merge-46|merge-47|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|79|merge|47|merge-5-close-pass|active|active|merge-47|merge-48|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|80|merge|48|merge-6-open-input|active|active|merge-48|merge-49|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|81|merge|49|merge-6-open-output|active|active|merge-49|merge-50|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|82|merge|50|merge-6-bind-input|active|active|merge-50|merge-51|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|83|merge|51|merge-6-publish-row-block|active|active|merge-51|merge-52|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|84|merge|52|merge-6-index-row-block|active|active|merge-52|merge-53|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|85|merge|53|merge-6-advance-output|active|active|merge-53|merge-54|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|86|merge|54|merge-6-close-run|active|active|merge-54|merge-55|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|87|merge|55|merge-6-close-pass|active|active|merge-55|merge-56|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|88|merge|56|merge-7-open-input|active|active|merge-56|merge-57|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|89|merge|57|merge-7-open-output|active|active|merge-57|merge-58|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|90|merge|58|merge-7-bind-input|active|active|merge-58|merge-59|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|91|merge|59|merge-7-publish-row-block|active|active|merge-59|merge-60|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|92|merge|60|merge-7-index-row-block|active|active|merge-60|merge-61|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|93|merge|61|merge-7-advance-output|active|active|merge-61|merge-62|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|94|merge|62|merge-7-close-run|active|active|merge-62|merge-63|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|95|merge|63|merge-7-close-pass|active|complete|merge-63|merge-64|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|96|tree|0|tree-0-open-level|active|active|tree-0|tree-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|97|tree|1|tree-0-select-root|active|active|tree-1|tree-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|98|tree|2|tree-0-advance-sequence|active|active|tree-2|tree-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|99|tree|3|tree-0-close-level|active|active|tree-3|tree-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|100|tree|4|tree-1-open-level|active|active|tree-4|tree-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|101|tree|5|tree-1-select-root|active|active|tree-5|tree-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|102|tree|6|tree-1-advance-sequence|active|active|tree-6|tree-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|103|tree|7|tree-1-close-level|active|active|tree-7|tree-8|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|104|tree|8|tree-2-open-level|active|active|tree-8|tree-9|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|105|tree|9|tree-2-select-root|active|active|tree-9|tree-10|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|106|tree|10|tree-2-advance-sequence|active|active|tree-10|tree-11|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|107|tree|11|tree-2-close-level|active|active|tree-11|tree-12|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|108|tree|12|tree-3-open-level|active|active|tree-12|tree-13|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|109|tree|13|tree-3-select-root|active|active|tree-13|tree-14|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|110|tree|14|tree-3-advance-sequence|active|active|tree-14|tree-15|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|111|tree|15|tree-3-close-level|active|active|tree-15|tree-16|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|112|tree|16|tree-4-open-level|active|active|tree-16|tree-17|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|113|tree|17|tree-4-select-root|active|active|tree-17|tree-18|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|114|tree|18|tree-4-advance-sequence|active|active|tree-18|tree-19|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|115|tree|19|tree-4-close-level|active|active|tree-19|tree-20|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|116|tree|20|tree-5-open-level|active|active|tree-20|tree-21|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|117|tree|21|tree-5-select-root|active|active|tree-21|tree-22|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|118|tree|22|tree-5-advance-sequence|active|active|tree-22|tree-23|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|119|tree|23|tree-5-close-level|active|active|tree-23|tree-24|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|120|tree|24|tree-6-open-level|active|active|tree-24|tree-25|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|121|tree|25|tree-6-select-root|active|active|tree-25|tree-26|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|122|tree|26|tree-6-advance-sequence|active|active|tree-26|tree-27|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|123|tree|27|tree-6-close-level|active|active|tree-27|tree-28|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|124|tree|28|tree-7-open-level|active|active|tree-28|tree-29|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|125|tree|29|tree-7-select-root|active|active|tree-29|tree-30|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|126|tree|30|tree-7-advance-sequence|active|active|tree-30|tree-31|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|127|tree|31|tree-7-close-level|active|complete|tree-31|tree-32|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|128|verification|0|verification-rows-1-open|active|active|verification-0|verification-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|129|verification|1|verification-rows-1-publish-block|active|active|verification-1|verification-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|130|verification|2|verification-rows-1-index-block|active|active|verification-2|verification-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|131|verification|3|verification-rows-1-advance-sequence|active|active|verification-3|verification-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|132|verification|4|verification-rows-1-close-pass|active|active|verification-4|verification-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|133|verification|5|verification-rows-1-record-result|active|active|verification-5|verification-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|134|verification|6|verification-rows-1-retry|active|active|verification-6|verification-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|135|verification|7|verification-rows-1-protect|active|active|verification-7|verification-8|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|136|verification|8|verification-rows-2-open|active|active|verification-8|verification-9|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|137|verification|9|verification-rows-2-publish-block|active|active|verification-9|verification-10|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|138|verification|10|verification-rows-2-index-block|active|active|verification-10|verification-11|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|139|verification|11|verification-rows-2-advance-sequence|active|active|verification-11|verification-12|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|140|verification|12|verification-rows-2-close-pass|active|active|verification-12|verification-13|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|141|verification|13|verification-rows-2-record-result|active|active|verification-13|verification-14|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|142|verification|14|verification-rows-2-retry|active|active|verification-14|verification-15|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|143|verification|15|verification-rows-2-protect|active|active|verification-15|verification-16|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|144|verification|16|verification-storage-open|active|active|verification-16|verification-17|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|145|verification|17|verification-storage-publish-block|active|active|verification-17|verification-18|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|146|verification|18|verification-storage-index-block|active|active|verification-18|verification-19|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|147|verification|19|verification-storage-advance-sequence|active|active|verification-19|verification-20|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|148|verification|20|verification-storage-close-pass|active|active|verification-20|verification-21|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|149|verification|21|verification-storage-record-result|active|active|verification-21|verification-22|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|150|verification|22|verification-storage-retry|active|active|verification-22|verification-23|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|151|verification|23|verification-storage-protect|active|active|verification-23|verification-24|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|152|verification|24|verification-terminal-open|active|active|verification-24|verification-25|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|153|verification|25|verification-terminal-publish-block|active|active|verification-25|verification-26|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|154|verification|26|verification-terminal-index-block|active|active|verification-26|verification-27|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|155|verification|27|verification-terminal-advance-sequence|active|active|verification-27|verification-28|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|156|verification|28|verification-terminal-close-pass|active|active|verification-28|verification-29|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|157|verification|29|verification-terminal-record-result|active|active|verification-29|verification-30|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|158|verification|30|verification-terminal-retry|active|active|verification-30|verification-31|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|159|verification|31|verification-terminal-protect|active|complete|verification-31|verification-32|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|160|materialization|0|materialization-A0-record-phase|active|active|materialization-0|materialization-1|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|161|materialization|1|materialization-A0-bind-root|active|active|materialization-1|materialization-2|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|162|materialization|2|materialization-A0-record-result|active|active|materialization-2|materialization-3|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|163|materialization|3|materialization-A0-close|active|active|materialization-3|materialization-4|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|164|materialization|4|materialization-A1-record-phase|active|active|materialization-4|materialization-5|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|165|materialization|5|materialization-A1-bind-root|active|active|materialization-5|materialization-6|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|166|materialization|6|materialization-A1-record-result|active|active|materialization-6|materialization-7|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|167|materialization|7|materialization-A1-close|active|active|materialization-7|materialization-8|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|168|materialization|8|materialization-A2-record-phase|active|active|materialization-8|materialization-9|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|169|materialization|9|materialization-A2-bind-root|active|active|materialization-9|materialization-10|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|170|materialization|10|materialization-A2-record-result|active|active|materialization-10|materialization-11|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|171|materialization|11|materialization-A2-close|active|active|materialization-11|materialization-12|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|172|materialization|12|materialization-A3-record-phase|active|active|materialization-12|materialization-13|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|173|materialization|13|materialization-A3-bind-root|active|active|materialization-13|materialization-14|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|174|materialization|14|materialization-A3-record-result|active|active|materialization-14|materialization-15|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|175|materialization|15|materialization-A3-close|active|active|materialization-15|materialization-16|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|176|materialization|16|materialization-A4-record-phase|active|active|materialization-16|materialization-17|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|177|materialization|17|materialization-A4-bind-root|active|active|materialization-17|materialization-18|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|178|materialization|18|materialization-A4-record-result|active|active|materialization-18|materialization-19|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|179|materialization|19|materialization-A4-close|active|active|materialization-19|materialization-20|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|180|materialization|20|materialization-A5-record-phase|active|active|materialization-20|materialization-21|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|181|materialization|21|materialization-A5-bind-root|active|active|materialization-21|materialization-22|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|182|materialization|22|materialization-A5-record-result|active|active|materialization-22|materialization-23|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|183|materialization|23|materialization-A5-close|active|active|materialization-23|materialization-24|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|184|materialization|24|materialization-A6-record-phase|active|active|materialization-24|materialization-25|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|185|materialization|25|materialization-A6-bind-root|active|active|materialization-25|materialization-26|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|186|materialization|26|materialization-A6-record-result|active|active|materialization-26|materialization-27|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|187|materialization|27|materialization-A6-close|active|active|materialization-27|materialization-28|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|188|materialization|28|materialization-A7-record-phase|active|active|materialization-28|materialization-29|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|189|materialization|29|materialization-A7-bind-root|active|active|materialization-29|materialization-30|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|190|materialization|30|materialization-A7-record-result|active|active|materialization-30|materialization-31|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|191|materialization|31|materialization-A7-close|active|complete|materialization-31|materialization-32|generic-progress|none|-|zero|3|4|4|4|3|3|12
fixed|192|recovery|0|recovery-selector-temp-inspect|active|active|recovery-0|recovery-1|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|193|recovery|1|recovery-selector-temp-adopt|active|active|recovery-1|recovery-2|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|194|recovery|2|recovery-selector-temp-resume|active|active|recovery-2|recovery-3|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|195|recovery|3|recovery-selector-temp-compensate|active|active|recovery-3|recovery-4|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|196|recovery|4|recovery-selector-temp-retry|active|active|recovery-4|recovery-5|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|197|recovery|5|recovery-selector-temp-close|active|active|recovery-5|recovery-6|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|198|recovery|6|recovery-selector-temp-record|active|active|recovery-6|recovery-7|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|199|recovery|7|recovery-selector-temp-protect|active|active|recovery-7|recovery-8|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|200|recovery|8|recovery-selector-renamed-inspect|active|active|recovery-8|recovery-9|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|201|recovery|9|recovery-selector-renamed-adopt|active|active|recovery-9|recovery-10|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|202|recovery|10|recovery-selector-renamed-resume|active|active|recovery-10|recovery-11|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|203|recovery|11|recovery-selector-renamed-compensate|active|active|recovery-11|recovery-12|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|204|recovery|12|recovery-selector-renamed-retry|active|active|recovery-12|recovery-13|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|205|recovery|13|recovery-selector-renamed-close|active|active|recovery-13|recovery-14|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|206|recovery|14|recovery-selector-renamed-record|active|active|recovery-14|recovery-15|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|207|recovery|15|recovery-selector-renamed-protect|active|active|recovery-15|recovery-16|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|208|recovery|16|recovery-carrier-temp-inspect|active|active|recovery-16|recovery-17|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|209|recovery|17|recovery-carrier-temp-adopt|active|active|recovery-17|recovery-18|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|210|recovery|18|recovery-carrier-temp-resume|active|active|recovery-18|recovery-19|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|211|recovery|19|recovery-carrier-temp-compensate|active|active|recovery-19|recovery-20|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|212|recovery|20|recovery-carrier-temp-retry|active|active|recovery-20|recovery-21|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|213|recovery|21|recovery-carrier-temp-close|active|active|recovery-21|recovery-22|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|214|recovery|22|recovery-carrier-temp-record|active|active|recovery-22|recovery-23|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|215|recovery|23|recovery-carrier-temp-protect|active|active|recovery-23|recovery-24|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|216|recovery|24|recovery-carrier-renamed-inspect|active|active|recovery-24|recovery-25|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|217|recovery|25|recovery-carrier-renamed-adopt|active|active|recovery-25|recovery-26|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|218|recovery|26|recovery-carrier-renamed-resume|active|active|recovery-26|recovery-27|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|219|recovery|27|recovery-carrier-renamed-compensate|active|active|recovery-27|recovery-28|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|220|recovery|28|recovery-carrier-renamed-retry|active|active|recovery-28|recovery-29|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|221|recovery|29|recovery-carrier-renamed-close|active|active|recovery-29|recovery-30|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|222|recovery|30|recovery-carrier-renamed-record|active|active|recovery-30|recovery-31|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|223|recovery|31|recovery-carrier-renamed-protect|active|active|recovery-31|recovery-32|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|224|recovery|32|recovery-carrier-durable-inspect|active|active|recovery-32|recovery-33|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|225|recovery|33|recovery-carrier-durable-adopt|active|active|recovery-33|recovery-34|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|226|recovery|34|recovery-carrier-durable-resume|active|active|recovery-34|recovery-35|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|227|recovery|35|recovery-carrier-durable-compensate|active|active|recovery-35|recovery-36|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|228|recovery|36|recovery-carrier-durable-retry|active|active|recovery-36|recovery-37|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|229|recovery|37|recovery-carrier-durable-close|active|active|recovery-37|recovery-38|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|230|recovery|38|recovery-carrier-durable-record|active|active|recovery-38|recovery-39|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|231|recovery|39|recovery-carrier-durable-protect|active|active|recovery-39|recovery-40|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|232|recovery|40|recovery-external-temp-inspect|active|active|recovery-40|recovery-41|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|233|recovery|41|recovery-external-temp-adopt|active|active|recovery-41|recovery-42|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|234|recovery|42|recovery-external-temp-resume|active|active|recovery-42|recovery-43|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|235|recovery|43|recovery-external-temp-compensate|active|active|recovery-43|recovery-44|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|236|recovery|44|recovery-external-temp-retry|active|active|recovery-44|recovery-45|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|237|recovery|45|recovery-external-temp-close|active|active|recovery-45|recovery-46|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|238|recovery|46|recovery-external-temp-record|active|active|recovery-46|recovery-47|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|239|recovery|47|recovery-external-temp-protect|active|active|recovery-47|recovery-48|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|240|recovery|48|recovery-external-renamed-inspect|active|active|recovery-48|recovery-49|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|241|recovery|49|recovery-external-renamed-adopt|active|active|recovery-49|recovery-50|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|242|recovery|50|recovery-external-renamed-resume|active|active|recovery-50|recovery-51|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|243|recovery|51|recovery-external-renamed-compensate|active|active|recovery-51|recovery-52|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|244|recovery|52|recovery-external-renamed-retry|active|active|recovery-52|recovery-53|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|245|recovery|53|recovery-external-renamed-close|active|active|recovery-53|recovery-54|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|246|recovery|54|recovery-external-renamed-record|active|active|recovery-54|recovery-55|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|247|recovery|55|recovery-external-renamed-protect|active|active|recovery-55|recovery-56|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|248|recovery|56|recovery-external-durable-inspect|active|active|recovery-56|recovery-57|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|249|recovery|57|recovery-external-durable-adopt|active|active|recovery-57|recovery-58|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|250|recovery|58|recovery-external-durable-resume|active|active|recovery-58|recovery-59|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|251|recovery|59|recovery-external-durable-compensate|active|active|recovery-59|recovery-60|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|252|recovery|60|recovery-external-durable-retry|active|active|recovery-60|recovery-61|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|253|recovery|61|recovery-external-durable-close|active|active|recovery-61|recovery-62|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|254|recovery|62|recovery-external-durable-record|active|active|recovery-62|recovery-63|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|255|recovery|63|recovery-external-durable-protect|active|active|recovery-63|recovery-64|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|256|recovery|64|recovery-directory-created-inspect|active|active|recovery-64|recovery-65|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|257|recovery|65|recovery-directory-created-adopt|active|active|recovery-65|recovery-66|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|258|recovery|66|recovery-directory-created-resume|active|active|recovery-66|recovery-67|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|259|recovery|67|recovery-directory-created-compensate|active|active|recovery-67|recovery-68|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|260|recovery|68|recovery-directory-created-retry|active|active|recovery-68|recovery-69|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|261|recovery|69|recovery-directory-created-close|active|active|recovery-69|recovery-70|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|262|recovery|70|recovery-directory-created-record|active|active|recovery-70|recovery-71|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|263|recovery|71|recovery-directory-created-protect|active|active|recovery-71|recovery-72|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|264|recovery|72|recovery-directory-durable-inspect|active|active|recovery-72|recovery-73|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|265|recovery|73|recovery-directory-durable-adopt|active|active|recovery-73|recovery-74|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|266|recovery|74|recovery-directory-durable-resume|active|active|recovery-74|recovery-75|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|267|recovery|75|recovery-directory-durable-compensate|active|active|recovery-75|recovery-76|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|268|recovery|76|recovery-directory-durable-retry|active|active|recovery-76|recovery-77|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|269|recovery|77|recovery-directory-durable-close|active|active|recovery-77|recovery-78|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|270|recovery|78|recovery-directory-durable-record|active|active|recovery-78|recovery-79|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|271|recovery|79|recovery-directory-durable-protect|active|active|recovery-79|recovery-80|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|272|recovery|80|recovery-phase-recorded-inspect|active|active|recovery-80|recovery-81|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|273|recovery|81|recovery-phase-recorded-adopt|active|active|recovery-81|recovery-82|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|274|recovery|82|recovery-phase-recorded-resume|active|active|recovery-82|recovery-83|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|275|recovery|83|recovery-phase-recorded-compensate|active|active|recovery-83|recovery-84|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|276|recovery|84|recovery-phase-recorded-retry|active|active|recovery-84|recovery-85|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|277|recovery|85|recovery-phase-recorded-close|active|active|recovery-85|recovery-86|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|278|recovery|86|recovery-phase-recorded-record|active|active|recovery-86|recovery-87|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|279|recovery|87|recovery-phase-recorded-protect|active|active|recovery-87|recovery-88|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|280|recovery|88|recovery-budget-reserving-inspect|active|active|recovery-88|recovery-89|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|281|recovery|89|recovery-budget-reserving-adopt|active|active|recovery-89|recovery-90|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|282|recovery|90|recovery-budget-reserving-resume|active|active|recovery-90|recovery-91|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|283|recovery|91|recovery-budget-reserving-compensate|active|active|recovery-91|recovery-92|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|284|recovery|92|recovery-budget-reserving-retry|active|active|recovery-92|recovery-93|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|285|recovery|93|recovery-budget-reserving-close|active|active|recovery-93|recovery-94|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|286|recovery|94|recovery-budget-reserving-record|active|active|recovery-94|recovery-95|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|287|recovery|95|recovery-budget-reserving-protect|active|active|recovery-95|recovery-96|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|288|recovery|96|recovery-budget-closing-inspect|active|active|recovery-96|recovery-97|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|289|recovery|97|recovery-budget-closing-adopt|active|active|recovery-97|recovery-98|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|290|recovery|98|recovery-budget-closing-resume|active|active|recovery-98|recovery-99|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|291|recovery|99|recovery-budget-closing-compensate|active|active|recovery-99|recovery-100|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|292|recovery|100|recovery-budget-closing-retry|active|active|recovery-100|recovery-101|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|293|recovery|101|recovery-budget-closing-close|active|active|recovery-101|recovery-102|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|294|recovery|102|recovery-budget-closing-record|active|active|recovery-102|recovery-103|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|295|recovery|103|recovery-budget-closing-protect|active|active|recovery-103|recovery-104|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|296|recovery|104|recovery-abort-receipt-inspect|active|active|recovery-104|recovery-105|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|297|recovery|105|recovery-abort-receipt-adopt|active|active|recovery-105|recovery-106|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|298|recovery|106|recovery-abort-receipt-resume|active|active|recovery-106|recovery-107|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|299|recovery|107|recovery-abort-receipt-compensate|active|active|recovery-107|recovery-108|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|300|recovery|108|recovery-abort-receipt-retry|active|active|recovery-108|recovery-109|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|301|recovery|109|recovery-abort-receipt-close|active|active|recovery-109|recovery-110|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|302|recovery|110|recovery-abort-receipt-record|active|active|recovery-110|recovery-111|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|303|recovery|111|recovery-abort-receipt-protect|active|active|recovery-111|recovery-112|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|304|recovery|112|recovery-terminal-selector-inspect|active|active|recovery-112|recovery-113|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|305|recovery|113|recovery-terminal-selector-adopt|active|active|recovery-113|recovery-114|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|306|recovery|114|recovery-terminal-selector-resume|active|active|recovery-114|recovery-115|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|307|recovery|115|recovery-terminal-selector-compensate|active|active|recovery-115|recovery-116|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|308|recovery|116|recovery-terminal-selector-retry|active|active|recovery-116|recovery-117|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|309|recovery|117|recovery-terminal-selector-close|active|active|recovery-117|recovery-118|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|310|recovery|118|recovery-terminal-selector-record|active|active|recovery-118|recovery-119|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|311|recovery|119|recovery-terminal-selector-protect|active|active|recovery-119|recovery-120|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|312|recovery|120|recovery-protected-inspect|active|active|recovery-120|recovery-121|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|313|recovery|121|recovery-protected-adopt|active|active|recovery-121|recovery-122|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|314|recovery|122|recovery-protected-resume|active|active|recovery-122|recovery-123|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|315|recovery|123|recovery-protected-compensate|active|active|recovery-123|recovery-124|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|316|recovery|124|recovery-protected-retry|active|active|recovery-124|recovery-125|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|317|recovery|125|recovery-protected-close|active|active|recovery-125|recovery-126|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|318|recovery|126|recovery-protected-record|active|active|recovery-126|recovery-127|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
fixed|319|recovery|127|recovery-protected-protect|active|complete|recovery-127|recovery-128|generic-progress|legacy-inspect-readonly|legacy-evidence-reference|zero|4|4|4|4|3|3|12
~~~


## Appendix C — canonical effect and external dispatch records

~~~text
effect|generic-progress|begin=generic-begin(K)|selected=generic-progress(E)|cancel=generic-progress(0)|committed=generic-finish(3)|abort=generic-finish(3)
effect|allocation-progress-choice|begin=generic-begin(4)+allocation-begin-addition(8)|selected=allocation-success-progress-full(11)|cancel=allocation-cancel-progress-full(3)|committed=generic-finish(3)|abort=allocation-aborted-finish-full(4)
effect|staging-register-progress-full|begin=generic-begin(1)(4)|selected=staging-register-progress-full(7)|cancel=generic-progress(0)(4)|committed=generic-finish(3)|abort=generic-finish(3)
effect|custody-verified-pending-progress-full|begin=generic-begin(1)(4)|selected=custody-verified-pending-progress-full(10)|cancel=generic-progress(0)(4)|committed=generic-finish(3)|abort=generic-finish(3)
effect|checkpoint-progress-choice|begin=generic-begin(0)(3)|selected-empty=initial-activation-progress-full(8)|selected-complete=replacement-progress-full(11)|cancel=generic-progress(0)(4)|committed=generic-finish(3)|abort=generic-finish(3)
external|none|K=0|E=0
external|four-existing-source-evidence|K=4|E=4
external|create-directory|K=1|E=1
external|create-regular|K=1|E=1
external|staging-register|K=1|E=1
external|custody-copy|K=1|E=2
external|replacement-switch|K=0|E=0
external|legacy-inspect-readonly|K=1|E=0
~~~
