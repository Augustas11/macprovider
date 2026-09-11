# Build 1 reservation search progress R21/R27 — independent adversarial plan review

Date: 2026-09-11. Reviewer: native GPT-5.6 Sol, high reasoning.

## Verdict

**REQUEST CHANGES. Architectural status: BLOCK.**

Exact finding count: **0 Critical, 7 High, 3 Medium, 0 Low**.

R21/R27 do not meet the mandatory zero-Critical/High/Medium plan gate. The
SQLite/VFS/custody/GC implementation remains unauthorized. This review changes
no source, test, SPEC, release, deployment, or operator-secret file.

## Frozen inputs and independent checks

- Reviewed commit:
  `3dc680234bbeda68fabf47f731672238984a040f`.
- R21 SHA-256:
  `719d8ce73b3152ba885528fd9ec8edcb2e46e1fd1fd44eb6c12a07fa6035429d`.
- R27 SHA-256:
  `91ac7a9cc2f978261e18d01f3230a7c4e30332d977d82a2c3b6c16f7fde35e8b`.
- Appendix A normalized DDL SHA-256:
  `edf42410f061176e2b3e3a15d9d60c3b47611784ea3207ac2531fafb94acf0c5`.
- Frozen R20 review commit:
  `3a0b5e1011dedc0414c18b8a8c102d01f969f70a`.
- Frozen R20 review SHA-256:
  `a9f0f5258fba1d517f30b7f6d25cca1d2f44d5cf16a79b5481b0dd072e8e3e95`.
- Live local tracking `origin/main` was
  `c123ae2d2d08053612d940b3077994f7c4d709d7`; its delta from
  `1d2c930bad81704dd0acc0322226725d8b64aceb` was confined to two
  SPEC-039 prompt artifacts and did not change Build 1 source.
- The R21 commit changes exactly the R21 plan and R27 test specification.
  `git diff --check` passed.
- Appendix A loaded under SQLite 3.53.4, and the local SQLite CLI was 3.51.0.
  The empty schema returned `integrity_check=ok` and no foreign-key violations.
- An independent registry expander emitted allocation 1, row 174, and fixed
  320 split 32/64/32/32/32/128, for exactly 495 entries. The recovery family
  had exactly 128 entries. The stated 49,280-intent, 186,688-operation, and
  560,064-transition arithmetic matched.
- Live DDL vectors rejected the first-over fixed cursors: 33 for source/tree/
  verification/materialization, 65 for merge, and 129 for recovery.
- A live ownership oracle committed a row-0 `staging_sources` record whose
  receipt evidence belonged to an unrelated evidence object. It also committed
  row-0 custody events using unrelated root/receipt evidence, then selected
  custody generation 2 with the generation-1 event digest. The resulting
  database returned `foreign_key_check=[]` and `integrity_check=ok`.
- With an authorizer denying ATTACH as R21 requires after open, `VACUUM`
  returned `authorization denied` and invoked the ATTACH authorizer action.
- The exact 191-file production Swift file-set hash matched
  `ecddf4741c7d0b24214636429bfe02cb58ac6321eae69521b0fbf2266a0dfe73`.
  One first parser sweep observed a compiler signal on `ModelRuntime.swift`;
  two complete immediate reruns passed all 191 exact `-dump-parse` commands.
  This is recorded as flaky tool evidence, not as a passing generated-manifest
  oracle: R21 still intentionally defers the required generator and normalized
  declaration/target manifest to implementation.
- Production/test search found no `CatalogAuthorityV5`,
  `BoundDirectorySQLiteVFS`, `serving_pin_v1`, `request-outcome-v1`, or R21
  schema implementation. Current R4 `active.json`, direct adoption, and
  enumerating GC call sites remain present as expected before an approved
  cutover. Dirty implementation was inspected only as working-tree evidence.

### Executable counterexamples

The following Python 3 oracle extracts the reviewed DDL rather than copying or
loosening it. Run it from the repository root. It commits unrelated generic
evidence in `staging_sources` and both custody generations, then selects
generation 2 with generation 1's event digest:

```python
from pathlib import Path
import re, sqlite3

text = Path("docs/product-roadmap/build-1/reservation-search-progress-addendum-r21.md").read_text()
ddl = re.search(r"## Appendix A .*?~~~sql\n(.*?)~~~", text, re.S).group(1)
db = sqlite3.connect(":memory:")
db.executescript("PRAGMA foreign_keys=ON;\n" + ddl)
b = lambda byte, count: bytes([byte]) * count

def evidence(byte, kind):
    db.execute(
        "INSERT INTO evidence_objects VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (b(byte,32),kind,"transaction-store",b(byte,1),b(byte+20,32),1,
         b(byte+40,32),byte,byte,"regular",0o600,0,0,1,1,0,1,0,1,0,0,0,
         b(byte+60,32),1))

db.execute("BEGIN")
for i, kind in enumerate(("primary","origin","class","lineage",
        "unrelated-staging","unrelated-root-1","unrelated-receipt-1",
        "unrelated-root-2","unrelated-receipt-2"), start=1):
    evidence(i, kind)
db.execute("INSERT INTO transition_registry VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    ("row",0,"row",0,"seed","A2","A3","seed","seed","none","none",
     None,"zero",3,4,4,3,3,12))
db.execute("INSERT INTO row_slots VALUES(?,?,?,?,?,?)",
    (0,"occupied",None,b(100,16),0,1))
db.execute("INSERT INTO source_rows VALUES(?,?,?,?,?,?,?,?,?)",
    (0,b(100,16),"model","release",b(1,32),b(2,32),b(3,32),b(4,32),1))
db.execute("INSERT INTO operations VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (b(101,16),"row",0,0,None,None,"committed",None,b(102,32),1,0,0,0,0,0,b(105,32)))
db.execute("INSERT INTO transitions VALUES(?,?,?,?,?,?,?,?,?,?)",
    (b(101,16),0,"begin",1,2,None,b(102,32),0,"selected",b(103,32)))
db.execute("INSERT INTO transitions VALUES(?,?,?,?,?,?,?,?,?,?)",
    (b(101,16),1,"progress",2,3,b(103,32),b(102,32),0,"selected",b(104,32)))
db.execute("INSERT INTO transitions VALUES(?,?,?,?,?,?,?,?,?,?)",
    (b(101,16),2,"finish",3,4,b(104,32),b(102,32),0,"committed",b(105,32)))
db.execute("INSERT INTO staging_sources VALUES(?,?,?,?,?,?,?,?,?)",
    (b(100,16),0,"model","release",b(106,32),b(5,32),"registered",1,None))
db.execute("INSERT INTO custody_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (0,b(100,16),"model","release",b(110,32),1,"active",None,b(6,32),
     b(7,32),b(101,16),0,"initial-activation",b(111,32)))
db.execute("INSERT INTO custody_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (0,b(100,16),"model","release",b(110,32),2,"active",b(111,32),
     b(8,32),b(9,32),b(101,16),0,"replacement",b(112,32)))
db.execute("INSERT INTO custody_current VALUES(?,?,?,?,?,?,?)",
    (0,b(100,16),"model","release",b(110,32),2,b(111,32)))
db.commit()
print("foreign_key_check=", db.execute("PRAGMA foreign_key_check").fetchall())
print("integrity_check=", db.execute("PRAGMA integrity_check").fetchone()[0])
print("selected_generation_event=", db.execute(
    "SELECT custody_generation, hex(custody_event_sha256) FROM custody_current").fetchone())
```

Observed output on Python SQLite 3.53.4:

```text
foreign_key_check= []
integrity_check= ok
selected_generation_event= (2, '6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F6F')
```

The authorizer conflict is independently reproducible after loading the same
DDL:

```python
db.set_authorizer(lambda action, *_:
    sqlite3.SQLITE_DENY if action == sqlite3.SQLITE_ATTACH else sqlite3.SQLITE_OK)
db.execute("VACUUM")
```

Observed result: `sqlite3.DatabaseError: authorization denied`; the callback
received `SQLITE_ATTACH`.

## Critical (0)

None.

## High (7)

### R21-PLAN-H1 — the leaf-only VFS contract contradicts SQLite's public VFS ABI and cannot preserve the claimed `openat` binding by delegation

**Evidence.** R21 section 2.1 says every `xOpen`, `xAccess`, `xDelete`, and
`xFullPathname` path accepts only four byte-exact leaf names, rejects absolute
paths and separators, and opens through a captured directory FD with `openat`
(lines 65-97). The linked Xcode SDK's public `sqlite3.h` states that the
filename passed to `xOpen` is the result of `xFullPathname` plus an optional
suffix (lines 1365-1371), and that the `xFullPathname` result is an absolute
pathname (lines 6900-6903). Therefore a conforming SQLite core will not pass
the leaf-only value R21 requires. A wrapper that delegates to the stock unix
VFS must give it a pathname, causing a second pathname open and losing the
captured-directory-FD guarantee. The public ABI exposes no operation that
adopts R21's already-open `openat` FD into the stock unix VFS locking/WAL/SHM
implementation. R21 nevertheless calls this a small shim over the unix VFS
instead of a complete file-method/locking/shared-memory VFS.

**Consequence.** A literal implementation either cannot open the database, is
nonconforming to the SQLite VFS contract, or re-resolves a pathname after the
security check. The last choice reopens the ancestor-substitution race R21
claims to eliminate, while a new full VFS is materially larger and has a
different feasibility and qualification surface than the reviewed plan.

**Required correction.** Publish an ABI-conforming design in which
`xFullPathname` returns one exact absolute/synthetic main identity and every
method maps only that identity and SQLite's documented suffixes to the captured
directory FD. Specify whether all `sqlite3_io_methods`, POSIX locks, WAL shared
memory, mmap/fetch, sync, and error semantics are implemented locally. If the
stock unix VFS remains involved, demonstrate without pathname re-resolution
how it adopts the exact opened FD. Update R27 with a compiling prototype and
upstream VFS tests before treating this boundary as feasible.

### R21-PLAN-H2 — the revised foreign keys still admit cross-evidence substitution and split custody generation from its selected event

**Evidence.** Section 6 claims that substituting any transaction, model,
release, row, artifact, event, or operation fails a foreign-key constraint
(lines 453-467), and R27-06 requires every component splice into staging,
custody, catalog, and GC rows to fail `SQLITE_CONSTRAINT_FOREIGNKEY`.
Appendix A instead gives `staging_sources.receipt_evidence_sha256` and
`custody_events.root_evidence_sha256`/`receipt_evidence_sha256` only scalar
references to the generic `evidence_objects` primary key. No parent key binds
those evidence objects to the source tuple, operation, receipt kind, or
artifact. The live oracle successfully committed unrelated generic evidence
into both tables. Appendix A also gives `custody_current` one composite FK
containing the event digest but not `custody_generation`, plus a separate
`(artifact_sha256,custody_generation)` FK. The oracle selected generation 2
and the generation-1 event digest for the same artifact; both integrity checks
still passed. Catalog bindings do not include custody generation, so the stated
binding recomputation does not close that split.

**Consequence.** R20 H4 remains open. A schema-valid authority database can
associate a source or custody transition with another receipt/root and can
present a current generation that is not the generation of its selected event.
Startup FK/integrity checks cannot detect it, and R27-06's required negative
test cannot pass against the reviewed DDL.

**Required correction.** Give typed evidence/receipt parents composite unique
keys over all semantic owners, or store and constrain the parsed receipt owner
tuple in a dedicated table. Make `custody_current` use one FK containing row,
transaction, model, release, artifact, custody generation, and event digest;
add the matching unique parent key. Bind predecessor generation and creating
operation scope/ordinal as well. Expand R27-06 with the exact successful
counterexamples from this review and require FK plus startup semantic rejection
for every remaining digest relationship.

### R21-PLAN-H3 — every GC quantum derives the same helper UUID, so idempotent replay and multi-quantum progress are mutually exclusive

**Evidence.** Section 8 derives `helper_operation_uuid` only from artifact SHA,
custody-event SHA, and `gc_lifecycle_generation` (lines 580-586). Appendix A
requires `gc_lifecycle_generation=1` for every candidate. Thus all 16 success
quanta, all eight failure attempts, and their recoveries for one artifact use
the same helper UUID. Section 8 simultaneously says duplicate calls with the
same helper UUID are byte-identical and cannot repeat a deleted prefix (lines
588-597), while later quanta must start from different cursors and produce
different result bytes/paths.

**Consequence.** After the first result, a correct idempotency table keyed by
helper UUID must replay the first quantum forever. If the daemon instead accepts
new cursor semantics under the same UUID, a crash/retry can repeat a durably
deleted prefix and the claimed byte-identical recovery contract is false. The
maximum 4,096-entry lifecycle cannot complete under the literal rules.

**Required correction.** Derive a distinct attempt/quantum UUID from immutable
candidate identity plus the selected checking event generation, start phase,
and start cursor, while making exact retries reproduce that UUID. Bind those
inputs into `gc_result_v1`, its deterministic path, the candidate CAS, and the
event row. Model-check all 24 result attempts and first-over control with
duplicate, crash, and stale-cursor calls.

### R21-PLAN-H4 — the advertised 15-minute serving-pin deadline cannot revoke a lock FD held by a live provider

**Evidence.** Section 6 has the root daemon take a shared `flock` and hand a
duplicated lock FD to the provider (lines 474-488). It says the provider closes
the FD on completion, cancellation, or the absolute 15-minute deadline and GC
must obtain an exclusive lock. A recipient process can duplicate or retain that
FD indefinitely; a tuple deadline does not make the kernel close it, and the
daemon cannot close another live process's duplicate. The plan deliberately
requires daemon death not to release the provider's duplicate. R27-08 tests
normal completion/cancellation/process-death cases but has no hung or hostile
live-provider expiry vector.

**Consequence.** A buggy or adversarial provider can pin an artifact forever,
prevent every exclusive GC lock, exhaust the 1,024-artifact capacity, and make
the claimed bounded lifetime and deadline untrue. Reporting the capability as
expired does not recover storage authority.

**Required correction.** Use a lease mechanism whose authority can actually
expire or be revoked without cooperation from the recipient, or explicitly
make process lifetime the bound and design supervised termination/quarantine
around it. Define behavior for a duplicated FD, stopped process, hung process,
deadline race, daemon restart, and PID/audit-token reuse. Add those cases to
R27-08/09 and to capacity qualification.

### R21-PLAN-H5 — the serving and terminal-response trust objects have no complete codec or authentication contract

**Evidence.** Section 4.3 requires canonical `request-outcome-v1` bytes but
does not define its tuple domain, column types, exact order as a codec table,
or digest/signature target (lines 330-338). Section 6 introduces a daemon-issued
`serving_pin_v1` and calls it a signed tuple (lines 474-483), but defines no
serialization, signature algorithm, key origin/trust anchor, signature
coverage, XPC FD-to-message binding, anti-replay rule, or verification failure.
Appendix D declares complete standalone external codecs but lists only custody
receipt, custody entry, GC result, and staging-source receipt. R27-12 golden
tests only tuple_v1 and Appendix D receipts; R27-08 never supplies the missing
pin codec/authentication vectors.

**Consequence.** Independent daemon and Swift implementations can sign or parse
different bytes, attach a valid lock FD to a substituted tuple, or disagree on
terminal replay bytes. The serving trust boundary and R20 M3's byte-stable
terminal outcome are not executable acceptance contracts.

**Required correction.** Add complete `serving_pin_v1` and
`request_outcome_v1` codec tables, exact domains, types/nulls/order, signature
and key contract, FD/message binding, expiry clock semantics, and replay rules.
Golden-test every field, signature mutation, stale generation, FD substitution,
wrong audit identity, and minimum/maximum/null encoding from independent C and
Swift implementations.

### R21-PLAN-H6 — bootstrap import and post-intent lifecycle states are not a closed crash-recovery machine

**Evidence.** B3 creates schema/registry in one transaction, B4 imports up to
1,024 source rows and their evidence, and B5 merely says commit (lines
199-210). Neither Appendix C nor another literal manifest defines whether B4 is
one large transaction or per-row commits, the ordered statements, counter and
cursor CAS, duplicate evidence behavior, or restart selection. The E0-E6 table
classifies schema leaves but does not constrain partial B4 row/counter shapes.
B5 deletes the intent before it says to remove/verify the rollback journal, so
a death between those operations can leave main+journal without intent, which
is not E6. B6 WAL conversion and B7 candidate-to-final rename have no equivalent
exhaustive leaf/header table; after rename the deterministic candidate is gone
while the v5 fence is still absent. R27-03 constructs only E0-E6 and does not
require every B4 row/evidence/cursor commit shape.

**Consequence.** Two compliant implementations can choose incompatible import
atomicity and recovery. A crash can leave a directly found but unclassified
database/journal/final-directory state, forcing either protection of a legal
predecessor or unsafe inference/deletion. The prior bootstrap-recovery finding
is not closed for the complete B0-B8 path.

**Required correction.** Publish literal B4 import DML and a bounded commit
shape with exact counters/cursor, evidence deduplication, and predecessor/
successor predicates. Extend the state table through B5 journal cleanup, WAL
conversion, final-directory rename, ready commit, temp-format publication, and
parent fsync. Reorder destructive intent cleanup so every crash leaves a named
state. Exhaustively construct and kill at every import row and post-rename
boundary in R27-03.

### R21-PLAN-H7 — custody publication has no directly addressable temporary-state or crash-reclamation protocol

**Evidence.** C0 creates a root-owned temporary directory but gives no exact
name or identity-to-operation derivation (lines 503-506). C5 refers to a
deterministic temporary receipt path without defining it, and C6 performs two
separate renames plus parent fsyncs (lines 518-523). Cancellation cleanup is
defined before C6 and final-object replay after C6, but daemon/process death at
C0-C5 or between the two C6 renames has no leaf-state table, direct recovery
key, orphan cap, or reclamation operation. R27-08 asks for drift and
cancellation at C0-C6 but not crash/restart after each temporary write, flag,
rename, and directory fsync.

**Consequence.** A daemon crash can strand mutable root-owned trees or one half
of the root/receipt publication. Retry may enumerate, duplicate a large copy,
or reject a valid partial successor. Repeated failures can consume storage
outside the SQLite counters and invalidate idempotency, cancellation, and the
bounded-capacity claim.

**Required correction.** Derive exact temporary root/receipt paths from the
operation/artifact, define every legal C0-C6 leaf/flag/identity state, and bind
them to a durable daemon operation record before copying. Specify recovery and
bounded reclamation without enumeration or ambiguous deletion. Add kill/reboot
vectors after every copy, chmod/chown/flag, receipt write, rename, and fsync,
including caller death and cancellation races.

## Medium (3)

### R21-PLAN-M1 — R27's required `VACUUM` proof is blocked by R21's own authorizer and leaf policy

**Evidence.** Section 9 requires a maximum-shape `VACUUM` at 4,096-byte pages,
while section 9 also says the installed authorizer denies ATTACH after open and
section 2.1 rejects temporary database leaves. A live SQLite oracle installed
an ATTACH-denying authorizer on the exact Appendix A schema; `VACUUM` invoked
the ATTACH authorizer action and failed with `authorization denied`. R27-11
still requires the VACUUM result without defining a separately governed offline
qualification profile.

**Consequence.** The stated physical-size acceptance test cannot run through
the reviewed production boundary. Disabling the authorizer or using the stock
VFS silently measures a different security and storage profile.

**Required correction.** Either remove VACUUM from the claim and measure a
reachable production state, or define an explicit offline, non-authoritative
qualification profile with exact VFS/authorizer differences and prove its size
is conservative for production. Do not report a stock-VFS VACUUM as evidence
for the directory-bound runtime profile.

### R21-PLAN-M2 — the supposedly complete Swift cutover matrix still omits an active Malibu app catalog-read surface

**Evidence.** Appendix E's 191-file parser input correctly includes all Malibu
app production Swift, but the normative migration matrix lists the CLI
`ModelCatalogReadCommand.swift` and the three previously omitted app transaction
files without listing
`app/Sources/Malibu/ModelManagement/ModelCatalogRead.swift`. That file owns
`MalibuCatalogReadRunner`, acquires its own `catalog-read.lock`, passes read and
lifetime descriptors to a spawned CLI, and directly calls
`MalibuTransactionFiles`. `ModelManagement.swift` consumes the same app cache
and runner. The target-token inventory finds these occurrences, but R21 gives
them no exact pre-B8/post-B8 owner or allowlist disposition.

**Consequence.** The generated token manifest can be reproducible while a live
app read/lock/process path remains semantically unclassified. Implementers can
retain an R4-era authority/lifetime assumption or remove a needed transport
guard, and R27-12 has no expected mapping against which to decide.

**Required correction.** Add the app `ModelCatalogRead.swift` declarations and
its `ModelManagement.swift` callers to the normative matrix. Classify each
lock, lifetime FD, child argument, and cache read as V5 snapshot transport or a
forbidden authority path, and emit that classification in the checked-in
syntax-aware manifest.

### R21-PLAN-M3 — generation-50 GC protection has no literal evidence/counter transaction

**Evidence.** Section 8 reserves generation 50 solely for a first-over
`protected` control event and says it does not increment `result_count` (lines
599-607). Appendix A nevertheless requires every protected `gc_events` row to
have non-null `result_evidence_sha256`. Appendix C's `gc-advance` does not
insert an evidence row; it only increments `evidence_count` by an unspecified
`:result-evidence-count`. No rule says whether generation 50 reuses which prior
result evidence, inserts a new control evidence object, or increments the
protocol evidence counter. R27-09 checks only that result_count is unchanged.

**Consequence.** The final legal event, global 49,280-evidence bound, DML change
count, and replay digest differ across reasonable implementations. The claimed
51,200-event maximum-shape database has no one byte-exact terminal sequence.

**Required correction.** Add a standalone first-over-protection descriptor with
the exact predecessor, evidence reference or insertion, candidate CAS, counter
deltas, changes count, and replay result. Include it in the normalized manifest
and make R27-09/11 compare its exact SQL, binds, counts, and first-over rollback.

## Low (0)

None.

## R20 finding disposition

| R20 finding | R21/R27 result |
|---|---|
| H1 bootstrap recovery | **Open.** Intent-first E0-E6 improves pre-schema recovery, but H6 leaves B4 and post-intent/post-rename crash states incomplete. |
| H2 mutation manifests | **Closed for the listed ready-state special templates**, subject to implementation; H6 finds bootstrap import DML outside that closure. |
| H3 recovery intent mapping | **Closed in plan shape.** Independent expansion confirms all and only 128 recovery entries and the 49,280 formula. |
| H4 persisted ownership | **Open.** H2 demonstrates live FK-valid evidence and custody-generation substitutions. |
| H5 GC event budget | **Partially closed.** The 1+32+16=49 arithmetic is correct, but H3 prevents distinct quanta and M3 leaves event 50 non-executable. |
| H6 serving lifetime pin | **Open.** A shared FD protects active use, but H4 shows its deadline cannot be enforced against a live holder. |
| H7 hard WAL bound | **Open on feasibility.** The proposed `xWrite` cap is stronger than `journal_size_limit`, but H1 shows the reviewed VFS cannot satisfy both the public ABI and directory-FD guarantee as written. |
| M1 fixed cursor caps | **Closed in DDL shape.** Live first-over vectors reject all six family boundaries. |
| M2 full migration inventory | **Open.** The three named app files were added, but M2 identifies the still-unclassified app catalog-read runner and callers. |
| M3 generation-seven terminal | **Partially closed.** A zero-write outcome is selected, but H5 shows its byte/authentication contract is incomplete. |

## Code/security and architecture synthesis

- Code/security recommendation: **REQUEST CHANGES**. The DDL admits forbidden
  ownership states, the GC retry key is not unique per quantum, and the external
  trust codecs are incomplete.
- Architecture status: **BLOCK**. The VFS boundary is incompatible with the
  public SQLite path contract as written, and serving/custody lifetimes are not
  recoverably bounded.
- Final recommendation: **REQUEST CHANGES**.

## Gate decision

The exact R21/R27 revision is rejected. Revise the normative plan and test
specification, recompute exact hashes, and rerun an independent native GPT-5.6
Sol gate. Do not begin the R21 Swift/C/daemon/SPEC implementation until a fresh
review reports zero Critical, High, and Medium findings.
