# Reservation search progress R26/R32 independent plan review (Sol)

Date: 2026-09-11

Reviewer: independent native GPT-5.6 Sol adversarial plan gate

Verdict: **BLOCK — NOT APPROVED FOR IMPLEMENTATION**

## Gate result

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 7 |
| Medium | 3 |
| Low | 1 |
| Info | 2 |

The pass condition is exactly zero Critical, High, and Medium findings. R26/R32
therefore fails the plan gate. No finding, test outcome, or inherited gate is
downgraded, waived, weakened, or dropped.

## Frozen review inputs

- Exact reviewed commit:
  `96c41e29340906eb0d36b14b525c376f4b7fa929`
- Exact parent:
  `40d159d9b27e2a31b746ea3821f4bf6204081e5e`
- R26: `docs/product-roadmap/build-1/reservation-search-progress-addendum-r26.md`
  - required SHA-256:
    `358e63153db080ee22424e567ab312c1465b2b89e3489519447322aba320c42d`
  - reproduced SHA-256:
    `358e63153db080ee22424e567ab312c1465b2b89e3489519447322aba320c42d`
- R32:
  `docs/product-roadmap/build-1/test-spec-r32-reservation-r26-corrections.md`
  - required SHA-256:
    `80b4b213e81e89c674d450b176d3d3c39ac9d8b0cf15025abdcf1ea9d10cd1a8`
  - reproduced SHA-256:
    `80b4b213e81e89c674d450b176d3d3c39ac9d8b0cf15025abdcf1ea9d10cd1a8`
- Frozen fetched `origin/main`:
  `7128d1206afcf3cc857479e1d776ddc4899b020a`
- Failed predecessor review commit:
  `40d159d9b27e2a31b746ea3821f4bf6204081e5e`
- Failed predecessor artifact:
  `docs/product-roadmap/build-1/reviews/reservation-search-progress-r25-plan-sol.md`
  - required and reproduced SHA-256:
    `b14dcf4546c0208514141d1b1730baef1885219b5840bd7290d8d187232bcb5a`
  - predecessor counts: 0 Critical, 4 High, 1 Medium

Governing accumulated input hashes were independently reproduced:

| Input | SHA-256 |
|---|---|
| R23 | `eb49d8ab8493edfc53527fb9ae2729e56983eeb76cb043d4b0ec959675c344b2` |
| R29 | `77254fbb72d59763b333a219789922e492d32373454a08aa873d333a40c96f38` |
| R24 | `9bbaf6ad3edcfe3cbab33da045914fa5a52f4f209f2dc9ee7cd2cb6589eb5321` |
| R30 | `6d5586836618a5d4b110a4f393e9368c7646141149c6998e87d371027ba0783f` |
| R25 | `75d7ae4cc0dabe7e8f22a6ca1ba4bff4a0338a72fc49a042c59d6a087787d9d2` |
| R31 | `7a3995baa5c5d89653176b3b3598e41d63d2d7d2a4b30b09188ef4818c345641` |

The author diff from `40d159d9` to `96c41e29` contains exactly two added
files: R26 with 535 lines and R32 with 357 lines. `git diff --check` passed.
No Swift, test, SPEC, release, deployment, or unrelated dirty file was changed
by this review. This review did not inspect `d-inference` or operator secrets.

## Findings

### R26-PLAN-H1 — format-v6 cannot canonically represent its admitted generation range

**Severity: High**

**Evidence**

- Schema v26 admits `database_generation` through
  `9223372036854775807`
  (`reservation-search-progress-addendum-r26.md:63-68`). The exact intent uses
  the same positive-u63 range (`:150-160`) and its derived path uses the decimal
  generation (`:123-138`).
- The selected format encodes `databaseGeneration` as a JSON integer under RFC
  8785 JCS and calls its legal range positive u63 (`:342-365`).
- [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785.html) uses the
  I-JSON/IEEE-754 binary64 number model. The repository's own earlier
  interoperability rule rejects `9007199254740992` and larger before
  canonicalization
  (`test-spec-r10-c944-safe-integers.md:7-21`).
- The current Swift emitter instead models an integer as `Int` and emits
  `String(int)` (`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift:5-13,
  25-45`). A live Node oracle produced:

  ~~~text
  9007199254740991 -> 9007199254740991
  9007199254740992 -> 9007199254740992
  9007199254740993 -> 9007199254740992
  9223372036854775807 -> 9223372036854776000
  ~~~

- R32 tests negative, overflow, and noncanonical JSON numbers, but omits the
  `2^53` boundary (`test-spec-r32-reservation-r26-corrections.md:173-181`).
- The 785-byte format vector is only the generation-1 vector. Without changing
  any other field, generation `9007199254740991` is 800 bytes and Int64 maximum
  is 803 bytes. The asserted maximum final/temp pair of 1,570 bytes is therefore
  1,606 bytes under the declared domain
  (`reservation-search-progress-addendum-r26.md:477-487`;
  `test-spec-r32-reservation-r26-corrections.md:254-264`).

**Consequence**

Two purportedly conforming implementations can canonicalize one legal SQL and
intent identity to different format bytes, or collapse distinct u63 values to
one binary64 value. Startup and B8 can then disagree about the selected database
identity. The maximum-shape gate is also arithmetically impossible as written.

**Required correction**

Encode the generation as a canonical fixed-width decimal string, or restrict
the schema, tuple, path, requests, receipts, and format to at most
`9007199254740991`. Regenerate all affected schema/identity/format vectors,
lengths, hashes, and storage limits. Add independent tests at `2^53-1`, `2^53`,
`2^53+1`, and the corrected declared maximum.

### R26-PLAN-H2 — the root-daemon/SQLite worker split has no single executable wire protocol

**Severity: High**

**Evidence**

- R24 inserts `artifact_lock_identity_sha256` into the R23 worker tuple, changes
  its domain from `macprovider-r23/...-v1` to `macprovider-r24/...-v2`, changes
  its schema suffix to `_v2`, and sets the affected codec protocol to 2
  (`reservation-search-progress-addendum-r24.md:196-202,307-341`).
- R26 instead says the R23 `serving_worker_v1` codec remains unchanged while
  moving every publication, heartbeat, terminal successor, quarantine, and
  delete to the daemon
  (`reservation-search-progress-addendum-r26.md:385-393`). It does not publish
  the accumulated worker ordinal table or state which amended version is the
  sole accepted codec.
- After publishing the first worker record, the daemon returns only accepted-
  handoff and worker-record SHAs (`:395-411`). The broker must then populate the
  R23 `serving_slots` running row with worker PID, pidversion, start seconds and
  nanoseconds, cdhash, process group, heartbeat sequence/time, and record SHA
  (`reservation-search-progress-addendum-r23.md:754,986-988`). Those bytes are
  not present in the specified daemon reply.
- Finalize, termination, and deletion require the daemon to
  “direct-validate[] the CAS receipt”
  (`reservation-search-progress-addendum-r26.md:408-422`). Exhaustive search of
  R23-R26/R29-R32 finds no other CAS-receipt occurrence: there is no codec,
  issuer, authentication, database/predecessor binding, persistence, replay
  rule, or restart verification path.
- The daemon cannot independently open SQLite without violating the one-broker,
  one-connection authority (`reservation-search-progress-addendum-r23.md:68-117`).
  R32 exercises outcome SHAs and crash positions but never supplies the missing
  wire objects (`test-spec-r32-reservation-r26-corrections.md:205-233`).

**Consequence**

Implementation must let the broker traverse root records, let the daemon open
SQLite, trust an unauthenticated assertion, or invent an unreviewed protocol.
The SQL row and root recovery record can diverge, and restart cannot safely
finalize or delete either predecessor.

**Required correction**

Publish the exact accumulated worker codec domain/schema/ordinal table and
closed authenticated RPCs for offer, accept, worker publish, heartbeat,
termination, completion, recovery, and deletion. Return signed canonical worker
record bytes or every field required by SQL. Define a signed, durable, replay-
safe broker CAS witness binding database identity, slot/generation, permit,
request, predecessor/successor row digests, record SHA, commit generation, and
broker identity, verifiable without daemon SQLite access. Add mutation, splice,
restart, and maximum-record tests, and account for concurrent handoff and worker
final/prefix records.

### R26-PLAN-H3 — destructive restore and retire decisions rely on undefined broker proofs

**Severity: High**

**Evidence**

- Restore carries only a `maintenance_lease_sha256` token and says the daemon
  independently validates a stopped-authority lease plus the broker's exact
  main/SQL/format proof
  (`reservation-search-progress-addendum-r26.md:203-220,263-273`).
- Retire carries caller-supplied `main_state`, `sql_state`,
  `live_lease_set_sha256`, and successor hashes, then requires daemon validation
  of absence, terminal SQL, live leases, backups, workers, and successor B8
  selection (`:209,222-228,274-315`).
- Across R23-R26/R29-R32 there is no maintenance-lease codec, canonical lease-set
  codec, broker-state proof, signer/key identity, freshness or single-use rule,
  durable close/fsync/journal evidence, or restart construction algorithm. The
  only matches are the assertions in R26 and their requested tests in R32.
- R32 says to compare daemon-direct main/format/lease facts
  (`test-spec-r32-reservation-r26-corrections.md:85-98,114-130`), but the daemon
  cannot directly validate broker-owned SQLite while preserving broker-only
  database authority.

**Consequence**

The root daemon must trust destructive caller assertions or cross the SQLite
ownership boundary. It can otherwise restore into a live authority, retire the
selected intent while SQL or leases remain active, or accept stale successor
state after restart.

**Required correction**

Define exact signed broker-state, maintenance, and lease-set witness codecs,
including issuer/key identity, database and format identities, close/fsync and
journal state, zero-live-lease proof, successor-B8 proof, freshness, single-use,
restart, and replay behavior. Specify which filesystem facts the daemon checks
directly and which authenticated broker facts it consumes. Test every field,
stale/replayed proofs, and every crash around issuance and destructive use.

### R26-PLAN-H4 — the 23-field receipt and backup chain are not constructibly request-bound

**Severity: High**

**Evidence**

- The five exact request tuples carry operation-specific security fields
  (`reservation-search-progress-addendum-r26.md:201-220`).
- The signed 23-field receipt omits a request SHA. In particular, a retire
  receipt omits reason, main/SQL state, lease-set SHA, and successor identities,
  while the prose nevertheless says every receipt is request-bound
  (`:285-299`). A UUID names a request instance but does not commit its bytes.
- Export requests name `backup_envelope_unsigned_sha256`; restore requests name
  `backup_envelope_sha256`; the receipt has one generic, operation-dependent
  “backup-envelope SHA” (`:207-208,258-270,291-293`). The final envelope contains
  the signed export receipt (`:377-378`). No governing document defines the
  unsigned-envelope preimage, final-envelope codec, insertion rule, component
  order/types, or the non-circular hash construction.
- The same receipt field list includes an `authority-root placement SHA`
  (`:285-295`), but exhaustive R22-R26/R28-R32 search finds no domain, tuple,
  field order, root path source, capture lifecycle, replacement rules, or golden
  for that identity.
- R32 demands two independent receipt codecs, same-request comparison, envelope
  splicing rejection, and independent restore verification, but provides no
  unique bytes from which those oracles can be built
  (`test-spec-r32-reservation-r26-corrections.md:85-98,132-170`).

**Consequence**

Signed evidence cannot prove which exact export, restore, or destructive retire
tuple was executed. Independent implementations can hash different envelope or
root-placement preimages. A copied receipt can therefore be paired with a
different asserted operation state, and the requested splice tests have no
single expected result.

**Required correction**

Add `request_sha256` over the exact canonical request tuple to the signed
receipt. Define separate closed unsigned-envelope and final-envelope codecs,
domains, field order/types, component lengths/hashes, receipt insertion, and
restore-time recomputation. Bind the export receipt to the unsigned envelope
and restore to both the final envelope and export receipt. Define the exact
authority-root placement identity and golden. Test same UUID with every changed
request field and every unsigned/final-envelope/root splice.

### R26-PLAN-H5 — the privileged authority has no deployable target or complete trusted-root contract

**Severity: High**

**Evidence**

- R26 calls `TrustedCustodyDaemonV5` the sole privileged intent and worker-file
  actor and relies on two named Mach-facing services, installer-pinned code
  identity, a captured daemon root, and a fixed provider candidate path
  (`reservation-search-progress-addendum-r26.md:109-148,192-220,385-445`).
- The exact package has only `MacProviderCore` and `macprovider-cli` products and
  targets (`phase3-binary/Package.swift:9-18,48-80`). The app project has only
  Malibu and MalibuTests (`phase3-binary/app/project.yml:30-111`).
- The shipped provider plist launches `macprovider-cli serve`
  (`phase3-binary/dist/launchd-plist-template.plist:6-15`). Installer validation
  requires that provider job to run as the provider user; only the watchdog is
  root (`phase3-binary/dist/install.sh:375-397`). No MachServices plist or
  privileged helper target exists.
- R26's implementation order says only “add the five-method root intent service”
  (`reservation-search-progress-addendum-r26.md:489-500`). It does not define the
  executable/source target, XPC and attestation service labels, root launchd
  job, broker/client module, signing and requirement transition, installer-
  created provider-root anchor, upgrade overlap, key migration, failed-upgrade
  recovery, uninstall, or downgrade behavior.
- R32's compiler inventory covers only the CLI and Malibu source roots
  (`test-spec-r32-reservation-r26-corrections.md:266-275`), so a newly placed
  daemon outside them would be omitted from the mandatory bypass inventory.

**Consequence**

The implementation must invent deployment and root-selection security decisions
outside the reviewed plan. The daemon cannot securely locate the provider-owned
candidate root from the closed path-free RPC unless an installer-bound root
anchor is defined. The real root/provider fixture and release upgrade cannot be
constructed from R26/R32.

**Required correction**

Specify the daemon executable and source target, broker/client interface module,
both Mach service labels and launchd plists, UID/ownership/entitlement/signing
requirements, installer-created daemon and provider root anchors, component-wise
capture, signing-key lifecycle, update overlap, rollback, uninstall, and failed-
upgrade recovery. Expand AST/SIL, distribution, signing, package, installer,
upgrade, and uninstall inventories to every new target and artifact.

### R26-PLAN-H6 — the split NSXPC/Mach challenge does not bind the audit token to one process execution

**Severity: High**

**Evidence**

- The inherited design issues a bearer challenge on an NSXPC connection, then
  receives that challenge on a separately named Mach port. It compares only the
  NSXPC public PID/UID to the Mach audit token and derives pidversion/code from
  the Mach sender
  (`reservation-search-progress-addendum-r25.md:360-380`). R26 adopts this
  protocol for every bootstrap RPC
  (`reservation-search-progress-addendum-r26.md:192-199`).
- Public NSXPC exposes PID and effective UID but no peer audit token or
  pidversion. The five-second challenge is bound to the connection object,
  numeric PID/UID, and boot session, not to the NSXPC peer's `(pid,pidversion)`.
- A stale NSXPC connection/queued request across process exit or exec can be
  paired with a Mach message from a later process execution using the same PID.
  Comparing the later sender's pidversion only to itself cannot establish that
  it owns the earlier NSXPC connection. Yet R31/R32 require forwarded, stolen,
  and PID-reuse challenges to deny
  (`test-spec-r31-reservation-r25-corrections.md:181-195`;
  `test-spec-r32-reservation-r26-corrections.md:75-83`).
- The installed public SDK exposes `SecCodeCreateWithXPCMessage`, documented to
  construct code identity from the audit token associated with the exact raw XPC
  message (`Security.framework/Headers/SecCode.h:193-212`). That direct binding
  is not used by the reviewed split transport.

**Consequence**

The root file service cannot prove the asserted same-process-execution property
or implement its mandatory PID-reuse test from the specified evidence. A
forwarded challenge can authenticate a different execution to a stale connection
under the very race the protocol claims to close.

**Required correction**

Use one public transport whose received operation message is directly bound to
its kernel audit identity, such as raw XPC plus `SecCodeCreateWithXPCMessage`, or
define an equally non-forwardable public credential that binds the NSXPC peer's
pidversion before challenge issuance. Publish exact connection/invalidation/
queued-message rules and run real exit, exec, PID-reuse, forwarding, and delayed-
invalidation races. A test fixture assertion is not proof of this property.

### R26-PLAN-H7 — B8 includes a nondurable reopen in the irreversible selection boundary

**Severity: High**

**Evidence**

- B8 writes and fsyncs `format.json.tmp-v6`, renames it over `format.json`,
  fsyncs the parent, reopens format and daemon intent, and only then releases R4
  (`reservation-search-progress-addendum-r26.md:371-378`).
- R26 defines the rollback boundary as the durable parent fsync “plus successful
  reopen” and says R4 is the sole authority before that boundary (`:447-460`).
  A successful reopen is an in-memory observation and cannot be recovered after
  a crash.
- In the reachable crash after parent fsync but before successful reopen, the
  exact v6 final is durable while the stated compound boundary is incomplete.
  R26 nevertheless says exact format-v6 at restart means selected, while exact
  R4 means preselection (`:466-470`).
- R32 crashes before and after parent fsync and reopen, says pre-boundary failure
  keeps R4 authoritative, and also says exact v6 requires the selected proof
  (`test-spec-r32-reservation-r26-corrections.md:183-191,235-252`). It supplies no
  durable bit that distinguishes “parent fsync completed, reopen did not” from
  “parent fsync and reopen completed, later crash.”

**Consequence**

The same durable bytes have two claimed authority successors. Treating the
compound boundary literally can resurrect R4 after durable v6 publication;
treating final v6 as selected contradicts the required successful-reopen half of
the boundary. The R26 closure of predecessor H4 is therefore not complete.

**Required correction**

Make the durable parent fsync the sole selection boundary and treat all reopen
and daemon/SQL validation as postselection fail-closed checks, or introduce a
separately reviewed durable two-phase selector. Rewrite the crash matrix so
every on-disk state has exactly one authority successor and prove zero R4 access
after the selected durable state.

### R26-PLAN-M1 — the first bootstrap temp crash has no deterministic successor

**Severity: Medium**

**Evidence**

- Create opens a derived `.tmp` leaf with `O_CREAT|O_EXCL` and then writes a
  prefix (`reservation-search-progress-addendum-r26.md:230-250`). A crash after
  successful create and before the first write leaves a reachable zero-byte
  temp.
- R26 defines unlink/fresh-nonce recovery only for lengths 1...602, exact resume
  at 603, and protection above 603 (`:243-250`). Length zero is omitted.
- R32 crashes after temp create but again defines the recovery assertion only
  for lengths 1...602
  (`test-spec-r32-reservation-r26-corrections.md:100-108`).
- The final 113-byte path is exact, but the temp is called only a “derived
  `.tmp` leaf”; no exact name, relative path, digest, or collision rule is given.
  Enumeration is forbidden, so restart needs one deterministic spelling.

**Consequence**

The earliest publisher crash can permanently protect or wedge bootstrap before
main creation, and independent implementations cannot agree which direct temp
path to resume or remove.

**Required correction**

Define the exact temporary relative path and digest. Make 0...602 one closed
validated unlink/parent-fsync/fresh-nonce state, retain exact-603 resume, and
retain over-603 protection. Add explicit zero-byte and exact temp-name/path
goldens plus every collision and dual-file case.

### R26-PLAN-M2 — the NSXPC size test observes bytes only after allocation and challenge state is unbounded

**Severity: Medium**

**Evidence**

- R26 caps each request at 3,072 bytes, receipt at 1,024, and containing XPC
  value at 4,096 (`reservation-search-progress-addendum-r26.md:216-220`).
- R32 requires byte 4,097 to reject “before allocation or root access”
  (`test-spec-r32-reservation-r26-corrections.md:85-95`). NSXPC securely decodes
  its `NSData`/`NSFileHandle` arguments before the exported method can inspect
  their length, so that method cannot observe and reject the value before its
  transport allocation.
- The service issues a random five-second challenge before code identity is
  established (`reservation-search-progress-addendum-r25.md:360-374`), but no
  global, per-UID, per-connection, or concurrent RPC/challenge cap appears in
  R23-R26/R29-R32.

**Consequence**

The acceptance test asserts an unavailable observation point, while same-UID
unapproved clients can create unbounded transient decode and challenge state in
the root daemon. The fixed per-object semantic limits do not bound daemon memory
or work under concurrency.

**Required correction**

If NSXPC is retained, require rejection before semantic decoding and root access,
not before transport allocation, and set hard global/per-UID connection,
challenge, RPC, decoded-object, and queued-work limits. Alternatively use a
lower-level bounded framed transport. Add exact-at-limit, first-over, concurrent
exhaustion, cancellation, invalidation, and recovery tests.

### R26-PLAN-M3 — irreversible cutover has no frozen old-product-binary acceptance gate

**Severity: Medium**

**Evidence**

- R26 requires that after B8 every R4 runtime read/write path remain fenced and
  that no downgrade exists
  (`reservation-search-progress-addendum-r26.md:447-473,502-507`).
- R32 tests an old broker's XPC identity and feeds old formats/receipts to the
  new implementation, but does not launch a frozen current Malibu, CLI, or
  headless release against a selected v6 authority or test installer downgrade
  (`test-spec-r32-reservation-r26-corrections.md:75-83,200-203,235-252`).
- The current main retention entry appears to fail closed when it reaches the
  new format: it leaves an existing `.retention-v2` directory in place, requires
  a `schema` key, accepts only retention v2/v3, and then throws on R26's v6
  schema-less object
  (`phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift:35-39,
  118-125,146-152,191-221`;
  `reservation-search-progress-addendum-r26.md:342-368`). This static path does
  not prove every old app/CLI/headless entrypoint reaches that decode before an
  R4 authority effect.

**Consequence**

The no-R4-resurrection claim is verified only inside the future binary. A prior
installed or downgraded product may take a legacy direct path, report stale
readiness/economics, or touch R4 before encountering the unknown format.

**Required correction**

Freeze the supported predecessor release assets and execute every app, CLI,
headless, updater, and installer/downgrade entrypoint against selected format-v6.
Assert zero R4 opens/writes/selection, no readiness/economics/serving, fail-
closed UX, and downgrade rejection. Keep the new-binary malformed-old-format
tests as a separate gate.

### R26-PLAN-L1 — origin reconciliation has file-level inventory overlap

**Severity: Low**

**Evidence**

- R32 says the delta from `7c0aad11` through frozen `origin/main` has no Build 1
  authority path overlap
  (`test-spec-r32-reservation-r26-corrections.md:321-326`).
- Independent `git diff --name-status` finds 17 paths, including six Swift/test
  paths and `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`.
  `ModelRuntime.swift` is in the R31/R32 durable-read and serving inventory and
  still contains three focused authority-related calls.
- The actual origin hunks in that file are limited to the SPEC-038/039 paged-KV
  scheduler bridge around lines 2082-2176, so there is no observed catalog-
  authority call hunk overlap.

**Consequence**

The prose overstates the reconciliation as a path-level fact. Reusing the frozen
191-file AST/SIL evidence after merge could miss changed call edges even though
the observed hunks appear semantically disjoint.

**Required correction**

State that no authority-call hunk overlap was observed, acknowledge the literal
file-level overlap, and regenerate the complete compiler inventory and tests
from the eventual merged base as R32 otherwise requires.

## Informational observations

### R26-PLAN-I1 — exact schema, registry, tuple, path, intent, and format goldens reproduce

Independent extraction and execution produced:

| Oracle | Result |
|---|---|
| R23 schema | 43,652 bytes / `70b34a2bd2c13f5e2bf33f3041c0c5a3372da8f31370d75abbad7ef54c84553c` |
| R25 schema | 44,213 bytes / `2bcde8bc7ff003f6fc89836d2fb6e2bac121eb64394a5000c8002bd29052cf0c` |
| R26 schema | 44,295 bytes / `b8c641a2f6ba8dfa73174c9bc04b5c2e552649a42fa0e09cbfb39b140bb3b86d` |
| SQLite shape | app ID 1297109587; user version 26; 24 tables; 11 explicit indexes |
| registry | 495 records / 68,992 bytes / `d9426bd24c238d9dbd3384dc6fae8b30e010187b81c557c234bcbd3677489f63` |
| dispatch | 1,309 bytes / `af142c9d6f1571381f7ca14b44b4b9343b20ad1d985eae5c859693add7c6d3fb` |
| semantic tuple | 97,959 bytes / `0640f9b43150c237e3c0db27d72e6deb6e0824b4e4ba1f3149fe583925b0eaee` |
| bootstrap preimage | 305 bytes / `7d4fc8547fe7d914363b401991b60446681e7551f546328de5404f798490e39c` |
| database preimage | 344 bytes / `55f0a242ffab0afcdc03474f3d32a230d7e1000013375032561afeea53f3bca0` |
| relative path | 113 bytes / `b72d90e1fa0224f307bad960ed543e2b97b3e3c3d1a7f89f3b5ae78dfe827c75` |
| intent | exactly 603 bytes / `f3ca14bafd5a3f53274068a8cacc5f761e7c55a8acab91a0a7df911e1db8301d` |
| generation-1 format | 785 bytes / `483d1677d7846df3c4e0ff838039226f59925b7a0ae55c9cda14c00a58608c83` |

The independently encoded 603-byte intent consumed exactly 20 fields and was
byte-equal to the complete R26 hex vector. The format was byte-equal to the R26
JSON vector. These results close the predecessor's unreachable-intent finding
for the one legal 603-byte shape, but they do not waive H1's full generation
domain failure.

### R26-PLAN-I2 — public primitives and current inventory are reproducible, not implementation proof

The installed macOS 26.5 SDK exposes public NSXPC PID/UID, audit Mach trailers,
`audit_token_to_pidversion`, `kSecGuestAttributeAudit`,
`SecCodeCopyGuestWithAttributes`, `SecCodeCreateWithXPCMessage`, and
`NSFileHandle: NSSecureCoding`. The pieces compile or are declared publicly; H6
is a protocol-binding defect rather than a missing primitive.

The production Swift manifest reproduced as 191 sorted LF-terminated paths,
SHA-256
`ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`.
All 191 files passed `xcrun swiftc -frontend -parse`. The focused inventory
reproduced as 100 records, SHA-256
`c2ad58e2eb95423ac15d2be8be5467932ab75e61380690d2d9a798c2cc5db917`.
No production `CatalogAuthorityBrokerV5`, `TrustedCustodyDaemonV5`, bootstrap-
intent, NSXPC, or root worker-record implementation exists yet. Direct durable
callers remain implementation work under the retained R31/R32 migration gate.
The plan correctly withholds readiness, pricing, admission, settlement, actual-
MLX, cross-UID, release, deployment, and production claims until those gates
pass.

## Independent commands and results

The following were run from the exact worktree. Author-provided command results
and hashes were treated only as claims until independently reproduced.

~~~text
git rev-parse HEAD HEAD^ origin/main
# 96c41e29340906eb0d36b14b525c376f4b7fa929
# 40d159d9b27e2a31b746ea3821f4bf6204081e5e
# 7128d1206afcf3cc857479e1d776ddc4899b020a

shasum -a 256 <R23...R26,R29...R32,R25-review>
# all values in Frozen review inputs reproduced

git diff --name-status 40d159d9..96c41e29
# exactly R26 and R32, both added

git diff --numstat 40d159d9..96c41e29
# R26 535/0; R32 357/0

git diff --check 40d159d9..96c41e29
# exit 0, no output

python3 <independent Appendix-A extractor/transform/executor>
# R23 43652/70b34a...; R25 44213/2bcde8...;
# R26 44295/b8c641...; SQLite 3.53.4; 24 tables; 11 indexes;
# application_id 1297109587; user_version 26

python3 <independent registry/dispatch/semantic extractor>
# registry 495/68992/d9426b...; dispatch 1309/af142c...;
# semantic 97959/0640f9...

python3 <independent tuple_v1 encoder/decoder>
# bootstrap 305/7d4fc8...; database 344/55f0a2...;
# path 113/b72d90...; intent 603/f3ca14...; exact vector equality

python3 + node <independent format/JCS oracles>
# generation-1 format 785/483d16...; exact vector equality
# 2^53+1 collapsed in Node; Int64.max rendered 9223372036854776000
# format sizes at generation 1 / 2^53-1 / Int64.max: 785 / 800 / 803

find phase3-binary/Sources/macprovider-cli \
     phase3-binary/app/Sources/Malibu \
     -type f -name '*.swift' -print | LC_ALL=C sort
# 191 files; manifest ecddf474...fe73

xcrun swiftc -frontend -parse <each of 191 paths>
# 191 successes; 0 failures

rg -n --no-heading --sort path <R32 focused patterns> <both production roots>
# 100 records; c2ad58e2...b917

rg -n 'CAS receipt|maintenance_lease|live_lease_set|authority-root placement'
      <R23...R26,R29...R32>
# no CAS receipt definition; no maintenance/lease codec; placement appears only
# as the undefined R26 receipt field and narrative same-root predicate

xcrun --sdk macosx --show-sdk-path
rg <public API names> <selected SDK headers>
# public declarations found; no public NSXPC audit-token getter found

git diff --name-status 7c0aad11..7128d120
# 17 paths; ModelRuntime.swift literal inventory overlap; no Build 1 doc change

git status --porcelain=v1 -uall | wc -l
# 372 unrelated dirty paths before this artifact

git status --porcelain=v1 -uall | shasum -a 256
# 94a455ab574dbb473c0a8cb88c79c5d8b7d0a969bb571fa3c9be73499dee365e
~~~

Environment: Darwin 25.5.0 arm64, macOS 26.5 (25F71), Apple Swift 6.3.3,
Python 3.14.7, Node 22.23.2, shell SQLite 3.51.0, and Python SQLite 3.53.4.

No full Swift build/test, real UID-0/provider NSXPC fixture, actual-MLX run,
Xcode app suite, release packaging, deployment, or production qualification was
claimed. This is a plan-shape and current-source feasibility review. R32 keeps
all of those gates mandatory after a corrected plan is approved and implemented.

## Predecessor closure result

| R25 failed-review finding | R26 result |
|---|---|
| H1 root bootstrap authority absent | A narrow daemon API is proposed, but H3-H6 leave its proof, receipt, root, authentication, and deployment contracts incomplete. |
| H2 selected format omits intent SHA | The field is present and the generation-1 vector reproduces, but H1 makes the full admitted JCS selector non-interoperable. |
| H3 broker assigned root worker record | The direct writer is moved to the daemon, but H2 leaves the amended codec, data reply, CAS witness, and lifecycle RPCs undefined. |
| H4 post-B8 R4 rollback | R4 rollback is prohibited, but H7 still assigns two outcomes to the parent-fsync-before-reopen crash state. |
| M1 legal maximum intent unreachable | Closed: one exact legal 603-byte encoding was independently constructed, decoded, and byte-compared. M1 still leaves the zero-byte publisher crash and temp path undefined. |

Because seven High and three Medium findings remain, the required verdict is
**BLOCK — NOT APPROVED FOR IMPLEMENTATION**.
