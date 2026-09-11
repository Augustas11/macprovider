# Reservation search progress R25/R31 independent plan review (Sol)

Date: 2026-09-11

Reviewer: independent native Sol adversarial plan gate
Verdict: **BLOCK — NOT APPROVED FOR IMPLEMENTATION**

## Gate result

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 4 |
| Medium | 1 |
| Low | 0 |
| Info | 2 |

The pass condition is exactly zero Critical, High, and Medium findings. R25/R31
therefore fails the plan gate. No finding is downgraded or waived.

## Frozen review inputs

- Exact reviewed commit: `94c85d81231a55563172acbbdffbb0466d5f1978`
- R25: `docs/product-roadmap/build-1/reservation-search-progress-addendum-r25.md`
  - required SHA-256: `75d7ae4cc0dabe7e8f22a6ca1ba4bff4a0338a72fc49a042c59d6a087787d9d2`
  - reproduced SHA-256: `75d7ae4cc0dabe7e8f22a6ca1ba4bff4a0338a72fc49a042c59d6a087787d9d2`
- R31: `docs/product-roadmap/build-1/test-spec-r31-reservation-r25-corrections.md`
  - required SHA-256: `7a3995baa5c5d89653176b3b3598e41d63d2d7d2a4b30b09188ef4818c345641`
  - reproduced SHA-256: `7a3995baa5c5d89653176b3b3598e41d63d2d7d2a4b30b09188ef4818c345641`
- Historical base supplied for this review:
  `c123ae2d2d08053612d940b3077994f7c4d709d7`
- Fetched `origin/main`: `7c0aad111e44cb320641bcefae3bf56851e9aaaa`
- The supplied historical base is an ancestor of fetched `origin/main`.
- Parent failed-review commit: `e45f80e6ad3b075e63a3568f2c526faf2272aa27`
- Frozen R24 failed review SHA-256:
  `36fb0a20f3d0f118d244865f2d6904c732631e503bc90c965af7c485cab03e14`

Governing accumulated input hashes were independently reproduced:

| Input | SHA-256 |
|---|---|
| R23 | `eb49d8ab8493edfc53527fb9ae2729e56983eeb76cb043d4b0ec959675c344b2` |
| R29 | `77254fbb72d59763b333a219789922e492d32373454a08aa873d333a40c96f38` |
| R24 | `9bbaf6ad3edcfe3cbab33da045914fa5a52f4f209f2dc9ee7cd2cb6589eb5321` |
| R30 | `6d5586836618a5d4b110a4f393e9368c7646141149c6998e87d371027ba0783f` |

The author diff from `e45f80e6` to `94c85d81` contains only R25 and R31,
with 578 and 363 inserted lines respectively. `git diff --check` passed.
No Swift, test, SPEC, schema source, release, deployment, operator-secret, or
`d-inference` file was read or changed as part of that author diff. This review
did not inspect `d-inference`.

## Findings

### R25-PLAN-H1 — retained bootstrap leaf ownership has no executable authority path

**Severity: High**

**Evidence**

- R25 makes the final bootstrap intent the first durable object written before
  the candidate main and retains it through selection
  (`reservation-search-progress-addendum-r25.md:94-105`).
- Every bootstrap reopen, B7/B8 recovery, and normal startup requires the
  provider broker to direct-read and byte-compare that leaf
  (`reservation-search-progress-addendum-r25.md:107-123`).
- The leaf is newly required to be root-owned
  (`reservation-search-progress-addendum-r25.md:111-112`).
- The inherited publisher is `openat(...O_WRONLY|O_CREAT|O_EXCL..., 0600)`
  (`reservation-search-progress-addendum-r21.md:173-197`), while
  `CatalogAuthorityBrokerV5` is a provider-UID launch agent
  (`reservation-search-progress-addendum-r23.md:68-87`).
- R25 grants `TrustedCustodyDaemonV5` creation/open authority only for
  `artifact-locks` and its leaves; it explicitly exposes no generic path or file
  operation (`reservation-search-progress-addendum-r25.md:348-383`). It defines
  no bootstrap-intent create, chown, read, descriptor-transfer, backup, or
  restore method.
- R31's real cross-UID fixture covers the root daemon's custody parent/lock leaf,
  not bootstrap intent ownership or access
  (`test-spec-r31-reservation-r25-corrections.md:160-195`).

**Consequence**

A provider-UID broker cannot create a UID-0-owned mode-0600 leaf through the
inherited publisher and then direct-read it at startup. An implementation must
either fail the required predicate, silently weaken owner/mode checks, or add an
unreviewed privileged file service. The retained identity and recovery gate is
therefore not implementable as written.

**Required correction**

Choose one complete authority model. Either keep the retained intent
provider-owned/provider-readable under the broker's captured-directory contract,
or define a narrow root-daemon protocol that creates, prefix-publishes, fsyncs,
opens, reads/transfers, retains, backs up, and restores this one registered leaf.
Specify owner/group/mode and close/error behavior, bind every request to audit
identity and exact database/bootstrap operands, and add crash, restart,
cross-UID, substitution, backup, and restore tests.

### R25-PLAN-H2 — selected startup requires an intent SHA absent from the exact format authority

**Severity: High**

**Evidence**

- R25 requires the direct intent SHA to equal the SQL row SHA and the SHA
  “carried by the backup/format authority” at every normal startup
  (`reservation-search-progress-addendum-r25.md:107-119`).
- The inherited v5 `format.json` is an exact closed JCS object whose only keys are
  `bootstrapID`, `databaseDirectoryIdentitySHA256`, `databaseLeaf`,
  `registrySHA256`, `schemaSHA256`, `semanticManifestSHA256`, and `version`
  (`reservation-search-progress-addendum-r21.md:248-255`). It contains no
  bootstrap-intent SHA.
- R25 does define an offline backup envelope carrying component SHA/length data
  (`reservation-search-progress-addendum-r25.md:157-173`), but neither R25 nor
  R31 revises the selected `format.json` schema, exact bytes, hash, B8 writer, or
  startup golden vector to carry `bootstrap_intent_sha256`.

**Consequence**

After B8, a normal selected startup cannot satisfy the mandatory format-side
comparison. Implementations must invent an extra format key, reinterpret an
existing key, ignore the comparison, or depend on an offline backup that is not
selected runtime authority. Each choice violates an exact accumulated contract
and yields incompatible recovery behavior.

**Required correction**

Either remove the format-side intent-SHA requirement and state the complete
row/file/database-identity proof that replaces it, or explicitly revise the
canonical format object. A format revision must define exact JCS keys/bytes and
hash, B8 publication and recovery states, compatibility rejection, backup and
restore binding, and mutation/golden/crash tests.

### R25-PLAN-H3 — the provider broker is assigned publication of a root-owned serving-worker record

**Severity: High**

**Evidence**

- R25's fixed handoff sequence makes the provider-UID broker spawn the worker and
  then “publish[] the matching serving-worker record” before its SQL running CAS
  (`reservation-search-progress-addendum-r25.md:429-447`).
- The accumulated serving contract defines the direct
  `serving-workers/<slot>-<generation>-<permit>.worker-v1` record as root-owned
  and daemon-published (`reservation-search-progress-addendum-r23.md:393-410`).
  R22 likewise says the root custody daemon persists the root-owned worker
  record (`reservation-search-progress-addendum-r22.md:430-463`).
- The broker remains a provider-UID launch agent
  (`reservation-search-progress-addendum-r23.md:68-77`).
- R25 does not distinguish a new SQL-only object from the inherited direct
  record and does not add a privileged publish RPC. R31 explicitly places
  “worker record before SQL running” in direct restart recovery
  (`test-spec-r31-reservation-r25-corrections.md:197-203`).

**Consequence**

The broker cannot create or replace the inherited UID-0-owned direct recovery
record. Implementing the literal sequence either fails permissions or weakens
the root-owned recovery boundary. Crash recovery then cannot safely distinguish
an accepted worker from an unrecorded or attacker-controlled record.

**Required correction**

Keep the direct `serving_worker_v1` publication in the root daemon and have the
broker perform only the SQL CAS after receiving the daemon's durable record SHA,
or define a separately named broker-owned SQL-only object while preserving the
root daemon as sole writer of direct `serving-workers` leaves. Update the exact
five-step sequence, ownership/mode rules, heartbeat successors, restart matrix,
and real cross-UID tests.

### R25-PLAN-H4 — post-B8 rollback resurrects R4 without a downgrade protocol

**Severity: High**

**Evidence**

- R25 says post-selection rollback stops v25 serving and restores R4 through an
  “existing explicit rollback procedure”
  (`reservation-search-progress-addendum-r25.md:535-544`).
- The accumulated governing rule says rollback can remove only the exact
  unselected candidate before B8 and “After B8, no rollback to R4 exists”
  (`reservation-search-progress-addendum-r23.md:707-712`; the same rule is at
  `reservation-search-progress-addendum-r21.md:811-816`).
- A search of the accumulated R19-R25 and R25-R31 test corpus found no post-B8
  R4 downgrade procedure. R29 instead calls V5 selection irreversible
  (`test-spec-r29-reservation-r23-corrections.md:227-240`).
- R31 merely carries inherited rollback tests forward and adds no quiescence,
  export, generation fence, state reconciliation, or downgrade crash matrix
  (`test-spec-r31-reservation-r25-corrections.md:269-291`).

**Consequence**

R4 is retained only as preselection material and becomes stale once v25 catalog,
custody, serving-slot, readiness, and receipt state changes. Restoring it after
selection can rewind authority, expose dual/stale decisions, orphan live worker
locks, and make readiness/economics claims from two different generations.
There is no unique crash/restart successor.

**Required correction**

Retain the accumulated no-post-B8-rollback rule. If product requirements demand
a downgrade, define a complete bounded state machine covering serving
quiescence, exact state export/reconciliation, generation and format fencing,
worker and custody locks, receipts, readiness/economics invalidation, backup,
crash recovery, and adversarial tests before claiming rollback support.

### R25-PLAN-M1 — the 65,536-byte maximum legal intent fixture is unreachable

**Severity: Medium**

**Evidence**

- Schema v25 admits `bootstrap_intent_bytes` lengths 1 through 65,536
  (`reservation-search-progress-addendum-r25.md:51-76`), and R25 budgets a
  65,536-byte row plus a 65,536-byte retained file
  (`reservation-search-progress-addendum-r25.md:557-564`).
- R31 requires B3 with minimum and maximum *legal exact* intent and later requires
  the maximum-shape fixture to contain a 65,536-byte row/file
  (`test-spec-r31-reservation-r25-corrections.md:25-44,269-283`).
- The inherited intent is one canonical `tuple_v1` over a closed ordered field
  set with no optional field (`reservation-search-progress-addendum-r21.md:173-197`).
  R23 adds fixed journal-mode and broker-protocol operands
  (`reservation-search-progress-addendum-r23.md:142-155`), R24 adds one fixed
  32-byte nonce (`reservation-search-progress-addendum-r24.md:115-143`), and R25
  retains those exact operands (`reservation-search-progress-addendum-r25.md:94-100`).
  No revision defines padding, extension bytes, a variable field, or an alternate
  legal encoding.
- R25 separately rejects equivalent decoded values encoded as different bytes
  (`reservation-search-progress-addendum-r25.md:121-123`).

**Consequence**

There is one fixed canonical intent length, so a 65,536-byte legal intent cannot
be constructed without inventing bytes the decoder must reject. The mandated
maximum-shape and external-peak proof cannot exercise a legal bootstrap state,
and the schema admits lengths that are not legal authority objects.

**Required correction**

Set the SQL CHECK, file write limit, storage accounting, and maximum-shape
fixture to the exact canonical retained-intent length, and publish an exact
intent vector. If variable size is intentional, define a canonical bounded
extension field in the tuple, cryptographically bind it, and add independent
codec, boundary, recovery, and backup tests.

## Informational observations

### R25-PLAN-I1 — fetched base advanced beyond the supplied historical base

The review request identified `c123ae2d2d08053612d940b3077994f7c4d709d7`
as current `origin/main`. A required fresh `git fetch --prune origin` resolved
`origin/main` to `7c0aad111e44cb320641bcefae3bf56851e9aaaa`; the supplied commit remains an
ancestor. R23's own frozen source record already names `7c0aad11`
(`reservation-search-progress-addendum-r23.md:25-28`). The exact review commit
and R25/R31 bytes remain pinned, so this is source-baseline drift rather than a
waiver of any finding. R31 correctly says a source/toolchain change reopens the
postimplementation AST/SIL gate.

### R25-PLAN-I2 — the author-only focused grep hash has no reproducible extractor

The 191-path production Swift manifest and its SHA reproduced exactly, and all
191 files parse. The R31 author record also gives a 45-occurrence focused-grep
SHA but does not publish the exact grep expression or result bytes
(`test-spec-r31-reservation-r25-corrections.md:352-357`). That supporting hash
cannot be independently byte-reproduced from the document alone. It is not a
Medium finding because R31 explicitly says grep is supporting evidence only and
requires a checked-in compiler AST/SIL manifest plus a second generator after
implementation (`test-spec-r31-reservation-r25-corrections.md:215-267`). Manual
inspection confirmed the named current MacProviderCLI and Autotune paths are in
that required gate.

## Independent command and oracle results

Environment:

```text
sw_vers => macOS 26.5 (25F71)
uname -mrs => Darwin 25.5.0 arm64
python3 --version => Python 3.14.7
Python sqlite3.sqlite_version => 3.53.4
swiftc --version => swift-driver 1.148.6 / Apple Swift 6.3.3
```

Input and scope commands:

```text
git fetch --prune origin
git rev-parse HEAD origin/main c123ae2d2d08053612d940b3077994f7c4d709d7
git merge-base --is-ancestor c123ae2d... origin/main
shasum -a 256 <R23,R29,R24,R30,R25,R31,R24-review>
git diff --check e45f80e6ad3b075e63a3568f2c526faf2272aa27 94c85d81
git diff --name-only e45f80e6ad3b075e63a3568f2c526faf2272aa27 94c85d81
```

Results: hashes are those recorded above; the ancestor and diff checks returned
zero; the path diff was exactly R25 and R31. The pre-artifact
`git status --porcelain=v1 -uall` snapshot contained 372 unrelated dirty paths,
SHA-256 `94a455ab574dbb473c0a8cb88c79c5d8b7d0a969bb571fa3c9be73499dee365e`.
The exact snapshot is appended below so the review commit can be proven to stage
only this artifact.

Schema/registry/tuple reproductions used independent Python extraction and a
separate tuple encoder over the exact fenced/heading-delimited input bytes:

| Oracle | Reproduced result |
|---|---|
| R23 Appendix A | 43,652 bytes; SHA `70b34abd8229e8a90bd45e0de6c283d33bf1af96a096193d9301e37dba7bf81f` |
| Three exact R25 transformations | each anchor once; 44,213 bytes; SHA `2bcde8dd97fa1cb063ad09b41db8b895ec64cf6fa2fabd38b15c4d1dc671547e` |
| SQLite execution | success; app ID 1297109587; user version 25; 24 non-internal tables; 11 non-auto indexes |
| R24 Appendix B | 495 records; 68,992 bytes; SHA `d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63` |
| R24 Appendix C dispatch | 1,309 bytes; SHA `af142c6eb0a6d4738156e24b7ff0717917aaba0d5307fdc7cf63bd57d320d3fb` |
| R23 semantic body | 27,602 bytes; SHA `c7b3594a76d118dd766082411407e267fa850a6364985422b8a9b0e64eaf6ae6` |
| R24 semantic tuple | 97,959 bytes; SHA `0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee` |
| R25 bootstrap vector | 305 bytes; SHA `64037a80513491ca37860906a07cccc02f0fe820d4f723d436de725fbc65a12c` |
| R25 database vector | 344 bytes; SHA `093b75a7a504aa6aee4cbcf5d7dfe9aff5f945216c48d223aea8af2a6fc25b3f` |
| R25 lock path SHA | `f17dbae407d2b854f2a2714bc52bec0997556d1bab0503dfc1ada974d15fcf64` |
| R25 placement vector | 268 bytes; SHA `a278cc0e972bfa9e4138b67c25b16a4799508b386a87f218b3a5c9bd5aefe207` |
| R25 lock vector | 333 bytes; SHA `42fbdb037c2c1adad5af9f989a2cba31740af29311f4ac8c5cf520ba6762d744` |

The extracted schema was executed in an in-memory SQLite database. This is a
plan-shape oracle, not implementation or migration evidence.

Darwin/APFS placement oracle:

```text
before (dev=16777229, ino=124887392, mode=0700, uid=501, gid=0,
        birth=1789120522.7899892, nlink=2)
after first regular leaf: retained fields unchanged, nlink=3
after second regular leaf: retained fields unchanged, nlink=4
mtime_ns and ctime_ns changed across creation
```

A first Python attempt requested nonexistent `st_birthtime_ns` and failed with
`AttributeError`; it is not acceptance evidence. The corrected oracle used
`st_birthtime` plus nanosecond mtime/ctime. A seconds-only `stat` rendering was
also too coarse to show the timestamp change. Temporary leaves/directories were
removed. This independently supports R25's exclusion of mutable timestamps/link
count from persistent placement identity while retaining operation-local count
checks.

Darwin descriptor/flock oracle used `os.posix_spawn` file actions to duplicate a
read-only shared-locked descriptor to child FD 203 and then closed the parent's
copy:

```text
child mode=O_RDONLY; write errno=EBADF; exit=0
separate LOCK_EX|LOCK_NB while child lived => errno 35/EWOULDBLOCK
LOCK_EX|LOCK_NB after child exit => acquired
fixture limit => same UID; not cross-UID or XPC acceptance evidence
```

An earlier draft called the wrong Python `fcntl` surface and did not prove
exclusion; it was discarded and is not acceptance evidence. Temporary files
were removed.

Public SDK header inspection found:

- `MACH_RCV_TRAILER_AUDIT` in `mach/message.h`;
- `kSecGuestAttributeAudit` in Security `SecCode.h`;
- `NSXPCConnection.processIdentifier` and `effectiveUserIdentifier`;
- `NSFileHandle` conformance to `NSSecureCoding`;
- public `xpc_fd_create`/`xpc_fd_dup`;
- no public `xpc_connection_get_audit_token` declaration.

These results make the explicit Mach audit-trailer design plausible. They do not
prove real cross-UID authentication. R31 correctly requires that physical test.
No additional C/H/M issue was found in the single-use challenge, audit-token/code
identity checks, same-UID threat limit, FD 203 read-only handoff, flock lifetime,
or ambiguity-to-quarantine rule once the ownership findings above are corrected.

Production Swift inventory command/result:

```text
find phase3-binary/Sources/macprovider-cli phase3-binary/app/Sources/Malibu \
  -type f -name '*.swift' -print | LC_ALL=C sort
=> 191 paths; LF manifest SHA
   ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73
xcrun swiftc -frontend -parse <each manifest path>
=> 191/191 parsed; zero failures
```

The current dirty implementation contains no `CatalogAuthorityBrokerV5`,
`TrustedCustodyDaemonV5`, `bootstrap_authority`, `lock_handoff_v1`,
`custody_operation_v3`, or placement-identity implementation. That is expected
for an author proposal and means no implementation test can satisfy this gate.
The current code still contains the direct durable-read surface R31 must remove:

- `MacProviderCLI.swift`: resolver access around lines 523-541; preflights around
  749-1092; direct hash, containment, snapshot, contains, and adoption calls;
  serve startup around 2826; self-test around 3020.
- `AutotuneRecommend.swift`: durable store/resolver around 3565-3782; prefetch and
  benchmark paths around 3931-4067; verifier enumeration/hash implementation
  around 4281 onward.
- Additional production consumers include `ModelsSubcommand.swift`,
  `CoordinatorClient.swift`, `CandidateProviderRunner.swift`,
  `ProviderPreWarmer.swift`, and `Spec028CanaryCommand.swift`.

R31:235-243 requires every caller, indirect wrapper, dynamic edge, and new file,
so these additional consumers are within the postimplementation AST/SIL and
runtime-trap gate. R31 also separates readiness/economics, physical MLX,
cross-UID XPC, app, release, deployment, and production evidence. No readiness
or economics authority is granted by this plan review.

## Independent reviewer validation

After the primary review, two independent native lanes re-read the accumulated
contract and current relevant implementation read-only:

- Code/security lane: confirmed H1, H4, and M1; found no additional C/H/M in
  XPC audit binding, same-UID caveats, FD/flock restart, stable placement,
  backup/restore, or Swift inventory. A focused follow-up independently confirmed
  H2 and H3.
- Architecture lane: independently confirmed H1, H4, and M1 and returned BLOCK;
  it found no additional C/H/M.

The final 0C/4H/1M count is the primary reviewer's judgment over all confirmed
issues, not a majority vote.

## Unrelated dirty-path freeze before this artifact

The following is the exact 372-line pre-artifact
`git status --porcelain=v1 -uall` snapshot. Every entry is outside this review's
write scope and must remain unstaged and unmodified by the review commit.

```text
 M phase3-binary/Package.resolved
 M phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
 M phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
 M phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift
 M phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift
 M phase3-binary/Sources/macprovider-cli/HTTPServer.swift
 M phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
 M phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
 M phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
 M phase3-binary/Sources/macprovider-cli/RecommendationAdoptionJournal.swift
 M phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift
 M phase3-binary/Tests/macprovider-cliTests/BYOMAdmissionTests.swift
 M phase3-binary/Tests/macprovider-cliTests/CandidateProviderRunnerTests.swift
 M phase3-binary/Tests/macprovider-cliTests/DurableModelArtifactStoreTests.swift
 M phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift
 M phase3-binary/Tests/macprovider-cliTests/ModelsSubcommandTests.swift
 M phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift
 M phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagementViews.swift
 M phase3-binary/app/Sources/Malibu/ModelManagement/RecommendationManagement.swift
 M phase3-binary/app/Sources/Malibu/Resources/MalibuFeature.xcstrings
 M phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json
 M phase3-binary/app/Sources/Malibu/System/InstalledProviderMonitor.swift
 M phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift
 M phase4-coordinator/cmd/coordinator/main.go
 M phase4-coordinator/internal/billing/quarantine_test.go
 M phase4-coordinator/internal/billing/recovery.go
 M phase4-coordinator/internal/billing/route_snapshot.go
 M phase4-coordinator/internal/billing/settlement_receipts.go
 M phase4-coordinator/internal/billing/store.go
 M phase4-coordinator/internal/buyer/autotune_feeds.go
 M phase4-coordinator/internal/buyer/billing_recorder.go
 M phase4-coordinator/internal/buyer/model_admission.go
 M phase4-coordinator/internal/buyer/route_snapshot.go
 M phase4-coordinator/internal/buyer/server.go
 M phase4-coordinator/internal/pool/provider.go
 M phase4-coordinator/internal/tier2/catalog.go
 M phase4-coordinator/internal/ws/admin_endpoints.go
 M phase4-coordinator/internal/ws/admin_hardware_trust.go
 M phase4-coordinator/internal/ws/admission_canary_harness_test.go
 M phase4-coordinator/internal/ws/admission_ceiling_drift_test.go
 M phase4-coordinator/internal/ws/model_admission.go
 M phase4-coordinator/internal/ws/model_admission_probe_test.go
 M phase4-coordinator/internal/ws/relay.go
 M phase4-coordinator/internal/ws/server.go
 M phase4-coordinator/internal/ws/spec032_strict_admission_matrix_journey_test.go
 M phase4-coordinator/internal/ws/trust_revalidation.go
 M phase4-coordinator/internal/ws/trust_revalidation_test.go
 M specs/CONFORMANCE.json
 M specs/README.md
 M specs/SPEC-001-phase3-binary.md
 M specs/SPEC-044-malibu-model-catalog-economics.md
 M specs/SPEC-047-network-model-admission.md
 M specs/design/BUILD_SPEC_953_MALIBU_MODEL_SWITCHING.md
 M test/integration/harness_test.go
?? docs/product-roadmap/build-1/acceptance-status.md
?? docs/product-roadmap/build-1/baseline-swift.log
?? docs/product-roadmap/build-1/baseline-validation.md
?? docs/product-roadmap/build-1/baseline-xcode.log
?? docs/product-roadmap/build-1/baseline-xcodegen.log
?? docs/product-roadmap/build-1/catalog-read-completeness-addendum-r1.md
?? docs/product-roadmap/build-1/catalog-read-completeness-addendum-r2.md
?? docs/product-roadmap/build-1/catalog-read-lifecycle-addendum-r1.md
?? docs/product-roadmap/build-1/catalog-read-lifecycle-addendum-r2.md
?? docs/product-roadmap/build-1/cleanup-recovery-addendum-r1.md
?? docs/product-roadmap/build-1/cleanup-recovery-addendum-r2.md
?? docs/product-roadmap/build-1/cleanup-recovery-addendum-r3.md
?? docs/product-roadmap/build-1/command-composition-testability-addendum-r1.md
?? docs/product-roadmap/build-1/command-composition-testability-addendum-r2.md
?? docs/product-roadmap/build-1/command-composition-testability-addendum-r3.md
?? docs/product-roadmap/build-1/evidence/lock-init-descriptor-proof.md
?? docs/product-roadmap/build-1/evidence/promotion-authority-ws-t06-t10-correction-r1-sol.md
?? docs/product-roadmap/build-1/evidence/reservation-max-shape-measurement-result-r3.md
?? docs/product-roadmap/build-1/immutable-retirement-binding-r1.md
?? docs/product-roadmap/build-1/immutable-retirement-binding-r2.md
?? docs/product-roadmap/build-1/immutable-retirement-binding-r3.md
?? docs/product-roadmap/build-1/implementation-S2.md
?? docs/product-roadmap/build-1/implementation-app.md
?? docs/product-roadmap/build-1/implementation-authority-owner-guards.md
?? docs/product-roadmap/build-1/implementation-buyer-authority-tests.md
?? docs/product-roadmap/build-1/implementation-catalog-bridge.md
?? docs/product-roadmap/build-1/implementation-catalog-inspection.md
?? docs/product-roadmap/build-1/implementation-cli-transactions.md
?? docs/product-roadmap/build-1/implementation-contracts.md
?? docs/product-roadmap/build-1/implementation-control-lease.md
?? docs/product-roadmap/build-1/implementation-durable.md
?? docs/product-roadmap/build-1/implementation-integration.md
?? docs/product-roadmap/build-1/implementation-owner-lifetime.md
?? docs/product-roadmap/build-1/implementation-reservation-max-shape-measurement.md
?? docs/product-roadmap/build-1/implementation-reservation-r4.md
?? docs/product-roadmap/build-1/implementation-retention.md
?? docs/product-roadmap/build-1/long-hash-control-addendum-r1.md
?? docs/product-roadmap/build-1/long-hash-control-addendum-r2.md
?? docs/product-roadmap/build-1/long-hash-control-addendum-r3.md
?? docs/product-roadmap/build-1/migration-receipt-budget-r1.md
?? docs/product-roadmap/build-1/mlx-resource-probe-evidence.json
?? docs/product-roadmap/build-1/origin-main-1d2-impact-sol.md
?? docs/product-roadmap/build-1/origin-main-1d2-reconciliation-plan-r1.md
?? docs/product-roadmap/build-1/origin-main-1d2-reconciliation-plan-r2.md
?? docs/product-roadmap/build-1/origin-main-1d2-reconciliation-plan-r3.md
?? docs/product-roadmap/build-1/origin-main-c944-reconciliation-addendum-r1.md
?? docs/product-roadmap/build-1/origin-main-c944-reconciliation-addendum-r2.md
?? docs/product-roadmap/build-1/origin-main-c944-reconciliation-addendum-r3.md
?? docs/product-roadmap/build-1/origin-main-c944-reconciliation-addendum-r4.md
?? docs/product-roadmap/build-1/origin-main-c944-reconciliation-addendum-r5.md
?? docs/product-roadmap/build-1/origin-main-c944-reconciliation-addendum-r6.md
?? docs/product-roadmap/build-1/owner-testability-addendum-r1.md
?? docs/product-roadmap/build-1/owner-testability-addendum-r2.md
?? docs/product-roadmap/build-1/plan-r1.md
?? docs/product-roadmap/build-1/plan-r2.md
?? docs/product-roadmap/build-1/plan-r3.md
?? docs/product-roadmap/build-1/plan-r4.md
?? docs/product-roadmap/build-1/pr-body-draft.md
?? docs/product-roadmap/build-1/promotion-authority-addendum-r1.md
?? docs/product-roadmap/build-1/promotion-authority-addendum-r2.md
?? docs/product-roadmap/build-1/promotion-authority-addendum-r3.md
?? docs/product-roadmap/build-1/public-feed-preflight.json
?? docs/product-roadmap/build-1/qualification-blockers.md
?? docs/product-roadmap/build-1/reservation-max-shape-measurement-r1.md
?? docs/product-roadmap/build-1/reservation-max-shape-measurement-r2.md
?? docs/product-roadmap/build-1/reservation-max-shape-measurement-r3.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r1.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r10.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r11.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r12.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r13.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r14.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r15.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r16.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r17.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r18.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r2.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r3.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r4.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r5.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r6.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r7.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r8.md
?? docs/product-roadmap/build-1/reservation-search-progress-addendum-r9.md
?? docs/product-roadmap/build-1/reservation-search-progress-analysis-r1.md
?? docs/product-roadmap/build-1/retention-active-index-receipt-r1.md
?? docs/product-roadmap/build-1/retention-fd-ownership-evidence.md
?? docs/product-roadmap/build-1/retention-lock-budget-r1.md
?? docs/product-roadmap/build-1/retention-lock-budget-r2.md
?? docs/product-roadmap/build-1/retry-corrupt-recovery-r2.md
?? docs/product-roadmap/build-1/retry-journal-addendum-r1.md
?? docs/product-roadmap/build-1/retry-journal-addendum-r2.md
?? docs/product-roadmap/build-1/reviews/active-byom-slice4-overlap-sol.md
?? docs/product-roadmap/build-1/reviews/admission-discovery.md
?? docs/product-roadmap/build-1/reviews/app-security-current-r1-astra.md
?? docs/product-roadmap/build-1/reviews/app-security-current-r2-astra.md
?? docs/product-roadmap/build-1/reviews/architecture-r1-astra.md
?? docs/product-roadmap/build-1/reviews/catalog-read-cli-preliminary-r1-astra.md
?? docs/product-roadmap/build-1/reviews/catalog-read-completeness-r1-sol.md
?? docs/product-roadmap/build-1/reviews/catalog-read-completeness-r2-sol.md
?? docs/product-roadmap/build-1/reviews/catalog-read-lifecycle-r1-astra.md
?? docs/product-roadmap/build-1/reviews/catalog-read-lifecycle-r2-astra.md
?? docs/product-roadmap/build-1/reviews/cleanup-recovery-r1-astra.md
?? docs/product-roadmap/build-1/reviews/cleanup-recovery-r2-astra.md
?? docs/product-roadmap/build-1/reviews/cleanup-recovery-r3-astra.md
?? docs/product-roadmap/build-1/reviews/code-r1-astra.md
?? docs/product-roadmap/build-1/reviews/command-composition-testability-r1-astra.md
?? docs/product-roadmap/build-1/reviews/command-composition-testability-r2-astra.md
?? docs/product-roadmap/build-1/reviews/command-composition-testability-r3-astra.md
?? docs/product-roadmap/build-1/reviews/context-preliminary-security.md
?? docs/product-roadmap/build-1/reviews/gate-log.md
?? docs/product-roadmap/build-1/reviews/go-security-current-r1-astra.md
?? docs/product-roadmap/build-1/reviews/go-security-s1-r2-astra.md
?? docs/product-roadmap/build-1/reviews/go-security-s1-r3-astra.md
?? docs/product-roadmap/build-1/reviews/immutable-retirement-binding-r1-astra.md
?? docs/product-roadmap/build-1/reviews/immutable-retirement-binding-r2-astra.md
?? docs/product-roadmap/build-1/reviews/immutable-retirement-binding-r3-astra.md
?? docs/product-roadmap/build-1/reviews/long-hash-control-r1-astra.md
?? docs/product-roadmap/build-1/reviews/long-hash-control-r2-astra.md
?? docs/product-roadmap/build-1/reviews/long-hash-control-r3-astra.md
?? docs/product-roadmap/build-1/reviews/migration-receipt-budget-r1-astra.md
?? docs/product-roadmap/build-1/reviews/origin-main-1d2-reconciliation-plan-r1-sol.md
?? docs/product-roadmap/build-1/reviews/origin-main-1d2-reconciliation-plan-r2-sol.md
?? docs/product-roadmap/build-1/reviews/origin-main-1d2-reconciliation-plan-r3-sol.md
?? docs/product-roadmap/build-1/reviews/origin-main-c944-plan-r1-sol.md
?? docs/product-roadmap/build-1/reviews/origin-main-c944-plan-r2-sol.md
?? docs/product-roadmap/build-1/reviews/origin-main-c944-plan-r3-sol.md
?? docs/product-roadmap/build-1/reviews/origin-main-c944-plan-r4-sol.md
?? docs/product-roadmap/build-1/reviews/origin-main-c944-plan-r5-sol.md
?? docs/product-roadmap/build-1/reviews/origin-main-c944-plan-r6-sol.md
?? docs/product-roadmap/build-1/reviews/origin-main-c944-reconciliation-sol.md
?? docs/product-roadmap/build-1/reviews/owner-testability-r1-astra.md
?? docs/product-roadmap/build-1/reviews/owner-testability-r2-astra.md
?? docs/product-roadmap/build-1/reviews/plan-r1-astra.md
?? docs/product-roadmap/build-1/reviews/plan-r2-astra.md
?? docs/product-roadmap/build-1/reviews/plan-r3-astra.md
?? docs/product-roadmap/build-1/reviews/plan-r4-astra.md
?? docs/product-roadmap/build-1/reviews/promotion-authority-r1-astra.md
?? docs/product-roadmap/build-1/reviews/promotion-authority-r2-astra.md
?? docs/product-roadmap/build-1/reviews/promotion-authority-r3-astra.md
?? docs/product-roadmap/build-1/reviews/promotion-authority-test-mapping-r1-astra.md
?? docs/product-roadmap/build-1/reviews/promotion-authority-test-mapping-r1-sol.md
?? docs/product-roadmap/build-1/reviews/promotion-authority-test-mapping-r2-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-max-shape-measurement-r2-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-max-shape-measurement-r3-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-max-shape-result-r3-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-r4-architecture-audit-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-r4-code-audit-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-r4-security-audit-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r1-astra.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r10-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r11-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r12-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r13-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r14-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r15-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r16-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r17-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r18-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r2-astra.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r3-astra.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r4-astra.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r4-current-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r5-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r6-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r7-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r8-plan-sol.md
?? docs/product-roadmap/build-1/reviews/reservation-search-progress-r9-plan-sol.md
?? docs/product-roadmap/build-1/reviews/retention-active-index-receipt-r1-astra.md
?? docs/product-roadmap/build-1/reviews/retention-lock-budget-r1-astra.md
?? docs/product-roadmap/build-1/reviews/retention-lock-budget-r2-astra.md
?? docs/product-roadmap/build-1/reviews/retry-corrupt-recovery-r1-astra.md
?? docs/product-roadmap/build-1/reviews/retry-corrupt-recovery-r2-astra.md
?? docs/product-roadmap/build-1/reviews/retry-journal-r1-astra.md
?? docs/product-roadmap/build-1/reviews/retry-journal-r2-astra.md
?? docs/product-roadmap/build-1/reviews/s2-http-teardown-test-r1-astra.md
?? docs/product-roadmap/build-1/reviews/security-combined-r2-astra.md
?? docs/product-roadmap/build-1/reviews/security-r1-astra.md
?? docs/product-roadmap/build-1/reviews/snapshot-resources-r1-astra.md
?? docs/product-roadmap/build-1/reviews/snapshot-resources-r2-astra.md
?? docs/product-roadmap/build-1/reviews/storage-test-r1-astra.md
?? docs/product-roadmap/build-1/reviews/supply-discovery.md
?? docs/product-roadmap/build-1/reviews/transaction-control-r1-astra.md
?? docs/product-roadmap/build-1/reviews/transaction-control-r2-astra.md
?? docs/product-roadmap/build-1/reviews/transaction-control-r3-astra.md
?? docs/product-roadmap/build-1/reviews/transaction-control-r4-astra.md
?? docs/product-roadmap/build-1/reviews/transaction-retention-r1-astra.md
?? docs/product-roadmap/build-1/reviews/transaction-retention-r2-astra.md
?? docs/product-roadmap/build-1/reviews/transaction-retention-r3-astra.md
?? docs/product-roadmap/build-1/reviews/transaction-retention-r4-astra.md
?? docs/product-roadmap/build-1/s2-http-teardown-test-addendum-r1.md
?? docs/product-roadmap/build-1/s2-http-teardown-test-feasibility.md
?? docs/product-roadmap/build-1/snapshot-resources-r1.md
?? docs/product-roadmap/build-1/snapshot-resources-r2.md
?? docs/product-roadmap/build-1/storage-test-addendum-r1.md
?? docs/product-roadmap/build-1/test-spec-origin-main-1d2-reconciliation-r1.md
?? docs/product-roadmap/build-1/test-spec-origin-main-1d2-reconciliation-r2.md
?? docs/product-roadmap/build-1/test-spec-origin-main-1d2-reconciliation-r3.md
?? docs/product-roadmap/build-1/test-spec-r1.md
?? docs/product-roadmap/build-1/test-spec-r10-c944-safe-integers.md
?? docs/product-roadmap/build-1/test-spec-r11-reservation-r5-corrections.md
?? docs/product-roadmap/build-1/test-spec-r12-reservation-r6-corrections.md
?? docs/product-roadmap/build-1/test-spec-r13-reservation-r7-corrections.md
?? docs/product-roadmap/build-1/test-spec-r14-reservation-r8-corrections.md
?? docs/product-roadmap/build-1/test-spec-r15-reservation-r9-corrections.md
?? docs/product-roadmap/build-1/test-spec-r16-reservation-r10-corrections.md
?? docs/product-roadmap/build-1/test-spec-r17-reservation-r11-corrections.md
?? docs/product-roadmap/build-1/test-spec-r18-reservation-r12-corrections.md
?? docs/product-roadmap/build-1/test-spec-r19-reservation-r13-corrections.md
?? docs/product-roadmap/build-1/test-spec-r2.md
?? docs/product-roadmap/build-1/test-spec-r20-reservation-r14-corrections.md
?? docs/product-roadmap/build-1/test-spec-r21-reservation-r15-corrections.md
?? docs/product-roadmap/build-1/test-spec-r22-reservation-r16-corrections.md
?? docs/product-roadmap/build-1/test-spec-r23-reservation-r17-corrections.md
?? docs/product-roadmap/build-1/test-spec-r24-reservation-r18-corrections.md
?? docs/product-roadmap/build-1/test-spec-r3.md
?? docs/product-roadmap/build-1/test-spec-r4.md
?? docs/product-roadmap/build-1/test-spec-r5-c944-compatibility.md
?? docs/product-roadmap/build-1/test-spec-r6-c944-corrections.md
?? docs/product-roadmap/build-1/test-spec-r7-c944-owner-schema-corrections.md
?? docs/product-roadmap/build-1/test-spec-r8-c944-normative-null-setter.md
?? docs/product-roadmap/build-1/test-spec-r9-c944-integer-grammar.md
?? docs/product-roadmap/build-1/transaction-control-addendum-r1.md
?? docs/product-roadmap/build-1/transaction-control-addendum-r2.md
?? docs/product-roadmap/build-1/transaction-control-addendum-r3.md
?? docs/product-roadmap/build-1/transaction-control-addendum-r4.md
?? docs/product-roadmap/build-1/transaction-retention-addendum-r1.md
?? docs/product-roadmap/build-1/transaction-retention-addendum-r2.md
?? docs/product-roadmap/build-1/transaction-retention-addendum-r3.md
?? docs/product-roadmap/build-1/transaction-retention-addendum-r4.md
?? docs/product-roadmap/build-1/validation-lead.md
?? docs/product-roadmap/checkpoint.md
?? docs/product-roadmap/historical-roadmap.md
?? phase3-binary/Sources/macprovider-cli/BYOMPendingOfferJournal.swift
?? phase3-binary/Sources/macprovider-cli/CandidateParentLifetimeGuard.swift
?? phase3-binary/Sources/macprovider-cli/DurableModelDiscovery.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogArtifactSeal.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogLocalInspection.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogRead.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogReadCommand.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionArchive.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionReservationMigration.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift
?? phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
?? phase3-binary/Sources/macprovider-cli/ModelCommandExecutionContext.swift
?? phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift
?? phase3-binary/Sources/macprovider-cli/ModelTransactionOwnerLifetimeGuard.swift
?? phase3-binary/Sources/macprovider-cli/ModelsAdmissionRetry.swift
?? phase3-binary/Tests/macprovider-cliTests/BYOMPendingOfferJournalTests.swift
?? phase3-binary/Tests/macprovider-cliTests/Build1CommandBootstrapTests.swift
?? phase3-binary/Tests/macprovider-cliTests/Build1CommandFixtureInputs.swift
?? phase3-binary/Tests/macprovider-cliTests/Build1CommandFixtureInputsTests.swift
?? phase3-binary/Tests/macprovider-cliTests/Build1FixtureProvider.swift
?? phase3-binary/Tests/macprovider-cliTests/Build1LocalServiceBridge.swift
?? phase3-binary/Tests/macprovider-cliTests/CandidateParentLifetimeGuardTests.swift
?? phase3-binary/Tests/macprovider-cliTests/DurableModelDiscoveryTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelCatalogArtifactSealTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelCatalogLocalInspectionTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelCatalogReadBridgeTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelCatalogReadTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelCatalogReservationCapacityMeasurementTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionFixtureWrites.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionReservationMigrationTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionsTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelTransactionContextTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelTransactionControlLeaseTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelTransactionOwnerLifetimeGuardTests.swift
?? phase3-binary/Tests/macprovider-cliTests/ModelsAdmissionRetryTests.swift
?? phase3-binary/Tests/macprovider-cliTests/RecommendationAdoptionJournalPathTests.swift
?? phase3-binary/app/Sources/Malibu/ModelManagement/ModelCatalogRead.swift
?? phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionControl.swift
?? phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionPayload.swift
?? phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionRequest.swift
?? phase4-coordinator/internal/billing/artifact_admission.go
?? phase4-coordinator/internal/billing/artifact_admission_test.go
?? phase4-coordinator/internal/billing/settlement_config_guard_test.go
?? phase4-coordinator/internal/buyer/model_admission_authority.go
?? phase4-coordinator/internal/buyer/model_admission_authority_test.go
?? phase4-coordinator/internal/buyer/model_admission_clock_fixture_export_test.go
?? phase4-coordinator/internal/buyer/model_admission_expiry_sources_test.go
?? phase4-coordinator/internal/buyer/model_admission_guard.go
?? phase4-coordinator/internal/buyer/model_admission_guard_additional_test.go
?? phase4-coordinator/internal/buyer/model_admission_route_export_test.go
?? phase4-coordinator/internal/buyer/model_admission_transport_authority_test.go
?? phase4-coordinator/internal/pool/model_admission_guard.go
?? phase4-coordinator/internal/pool/model_admission_guard_test.go
?? phase4-coordinator/internal/tier2/model_admission_guard.go
?? phase4-coordinator/internal/tier2/model_admission_guard_test.go
?? phase4-coordinator/internal/ws/model_admission_authority.go
?? phase4-coordinator/internal/ws/model_admission_authority_matrix_export_test.go
?? phase4-coordinator/internal/ws/model_admission_authority_test.go
?? phase4-coordinator/internal/ws/model_admission_buyer_failure_test.go
?? phase4-coordinator/internal/ws/model_admission_buyer_owner_matrix_test.go
?? phase4-coordinator/internal/ws/model_admission_commit.go
?? phase4-coordinator/internal/ws/model_admission_commit_boundary_test.go
?? phase4-coordinator/internal/ws/model_admission_fixture_export_test.go
?? phase4-coordinator/internal/ws/model_admission_guard_test.go
?? phase4-coordinator/internal/ws/model_admission_http_teardown_matrix_test.go
?? phase4-coordinator/internal/ws/model_admission_owner_stress_test.go
?? phase4-coordinator/internal/ws/model_admission_probe_expiry_test.go
?? phase4-coordinator/internal/ws/model_admission_readback_race_test.go
?? phase4-coordinator/internal/ws/model_admission_retry.go
?? phase4-coordinator/internal/ws/model_admission_signed_owner_fixture_test.go
?? phase4-coordinator/internal/ws/model_admission_sqlite_wait_test.go
?? phase4-coordinator/internal/ws/model_admission_transport.go
?? phase4-coordinator/internal/ws/model_admission_transport_buyer_composition_test.go
?? phase4-coordinator/internal/ws/model_admission_transport_export_test.go
?? phase4-coordinator/internal/ws/model_admission_transport_test.go
?? phase4-coordinator/internal/ws/model_admission_ws_owner_matrix_test.go
?? test/integration/build1_artifact_journey_test.go
?? test/integration/build1_cli_bridge_test.go
?? test/integration/build1_closing_route_test.go
?? test/integration/build1_transport_test.go
```
