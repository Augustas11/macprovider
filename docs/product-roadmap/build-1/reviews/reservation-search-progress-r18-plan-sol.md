# Build 1 reservation search progress R18/R24 — independent adversarial plan review

Date: 2026-09-11. Reviewer lane: native GPT-5.6 Sol, high reasoning.
Scope: exact R18 plan and R24 test specification, inspected independently
against the failed R17 review, the retained R16 transition graph, current
SPEC-001/SPEC-044 requirements, current Swift reservation/artifact code, and
`origin/main`. No source or test implementation was authorized or changed by
this review.

## Verdict

**REQUEST CHANGES / FAIL — 0 Critical, 9 High, 1 Medium, 0 Low.**

R18 closes the literal R17 bootstrap arithmetic mismatch and makes the SHA
split workload finite. It also removes the fresh-receipt/custody self-cycle in
the abstract graph and gives changed-to-empty roots an explicit branch. The
implementation gate nevertheless remains closed. The seven-state lease
machine cannot be reconciled with the four mutation kinds or three-mutation
capacity formula; the prescribed two-carrier split cannot hold multiple
changed-root tops; bootstrap records have no legal lease/control encoding; and
the proposed codec still requires implementers to invent types, null rules,
and digest preimages. The custody and GC graphs are not durably addressable
enough to support the promised crash recovery. The final adoption check also
relies on a user-immutable flag that the same file owner is allowed to clear,
leaving the acknowledged after-check race open on the stated macOS threat
boundary.

## Frozen inputs and repository evidence

The requested inputs were recomputed and match:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r18.md` | `0926f4408fdf9f8287021d7b029858da01a83705b6f286fb6d707c2df8a5fc2b` |
| `test-spec-r24-reservation-r18-corrections.md` | `9cb6eaf9d272d0ef8ed179a5b4b7e156d2b1351351a7dcb277aa8cf45415aaec` |
| Failed R17 review | `9e2c64488905f6e112fdd14583c2d9727a0dda040aaa1bee7e516fb135b5a9f4` |

`origin/main` independently resolves to
`1d2c930bad81704dd0acc0322226725d8b64aceb`, matching R18/R24. The worktree
HEAD is the historical Build 1 base
`914f7cafcdbcfc1805a10f4f34167218341d5587`; the dirty working source remains
the R4 array/scan implementation. A search of `phase3-binary/Sources` and
`phase3-binary/Tests` found no `model_catalog_selector.v9`,
`lease_authorization.v4`, `lease_state.v6`,
`artifact_custody_record.v2`, `fresh_artifact_verification_receipt.v2`,
`adoption_recapture_head.v1`, `gc_head.v1`, or `V9CodecRegistry`.

Relevant current source digests are:

| Current source | SHA-256 |
|---|---|
| `ModelCatalogTransactionReservationMigration.swift` | `c8505d5d5ae92209aecc961362ac95386eb3bc9242674b61b1ae898fd0861261` |
| `ModelCatalogTransactionRetention.swift` | `0a6b4873d5d3e711299ae5f3d17090349a65f061338e94b8d3bbf723b97545e3` |
| `ModelCatalogTransactionStorage.swift` | `33cf08501a9d0e8509e8433d1cde7537bf9f660b814da0bf26fa1287a104916e` |
| `ModelCatalogTransactionEvidence.swift` | `b49c13fa9a7a673a856d565235e21acdad5f64c39bd04342cfd517122033ea36` |
| `ModelCatalogTransactionBindings.swift` | `60abe2946b204ac05a27ae19ec29b26e222948bc286959fdd473046629f8dfd7` |
| `ModelCatalogTransactions.swift` | `65cbb0e987e0012bbbb6716877adfed010c48d9deef29ca4f797f675ae576822` |
| `DurableModelArtifactStore.swift` | `0e0745c05c681895dbc8b18c0898259bb92c31ea4e55de536bc3c5de2696fa0b` |

The current artifact GC remains a recursive `contentsOfDirectory` /
`removeItem` walk (`DurableModelArtifactStore.swift:211-250`), and the current
reservation authority remains the bounded active-index/sidecar design
(`ModelCatalogTransactionRetention.swift:132-220`). R18 is therefore a large
replacement architecture, not a small completion of already executable v9
code.

The R18 SHA boundary generator was reproduced independently. Across the ten
listed lengths it yields 1,676 unique split completions and approximately
43.8678 GiB of aggregate suffix compression, below the stated 4,096-completion
and 96-GiB ceilings. This closes the former R17 M2 finite-work finding, subject
to the continuation codec corrections below.

## Critical (0)

None.

## High (9)

### R18-PLAN-H1 — the lease state machine requires five mutations while capacity funds three

**Severity:** High. **Confidence:** High.

**Evidence.** R18 says every post-bootstrap mutation is exactly one of
`reserve|progress|close-commit|close-abort` (`R18:100-104`). Its closed
transition matrix separately requires `reserve-open` after `reserve` and
`terminal-commit|terminal-abort` after the close transition, and every one of
those transitions advances the budget-entry generation with its own selected
authorization (`R18:167-188`). A successful transition with one payload edge
therefore needs `reserve -> reserve-open -> progress -> close-commit ->
terminal-commit`, not the three mutations used by the capacity formula
(`R18:561-588`). R24 tests all seven transitions in section 03, but section 08
again expands each R16 transition to only
`reserve/payload/terminal-close` (`R24:41-45,112-127`).

**Consequence.** Either `reserve-open` and terminal state removal occur without
the mandatory receipt/activation/checkpoint and budget debit, or the graph
uses at least two unbudgeted mutations per R16 transition. All printed unit,
carrier, byte, quota, `Rmax`, and first-over-limit claims then describe a
different graph from the one the decoder must accept.

**Required correction.** Freeze one executable transition trace. Name the
carrier mutation used by every row in the seven-transition matrix, including
whether reserve/open and closing/terminal are combined or separate. If they
remain separate, expand every R16 transition to the actual five-mutation trace
and regenerate units, carriers, bytes, quotas, inode limits, `Rmax`, bootstrap
allowances, and R24 vectors from literal emitted records.

### R18-PLAN-H2 — the prescribed two-carrier split cannot encode multiple changed roots

**Severity:** High. **Confidence:** High.

**Evidence.** Whenever `T+3>16`, carrier zero must contain the first `T-1`
targets and the terminal carrier must contain only the final target plus the
three control records (`R18:100-106`). The same paragraph requires every
changed nonempty root's top record to be among terminal-carrier targets and
explicitly permits several such roots (`R18:106-109`). Section 4 permits local
root promotion only from a lower slot of that same terminal carrier and
forbids promotion from carrier zero (`R18:203-224`). Thus any two-carrier
mutation changing two or more nonempty roots needs at least two terminal target
slots but is assigned exactly one. R24 requires one- and two-carrier fixtures
for every subset of the six changed roots (`R24:54-63`).

**Consequence.** A legal R24 fixture cannot be produced for multi-root,
two-carrier mutations. An implementation must violate the split, place a root
top in carrier zero, or invent an unreviewed cross-carrier promotion rule.

**Required correction.** Define a packing algorithm that reserves enough of
the terminal carrier's 13 target slots for all changed nonempty root tops and
puts only the overflow prefix in carrier zero, or define and review a safe
carrier-addressable cross-carrier promotion. Regenerate exact slot-order
vectors and re-prove the two-carrier and 20-unit bounds.

### R18-PLAN-H3 — bootstrap genesis records have no legal lease/control form

**Severity:** High. **Confidence:** High.

**Evidence.** The bootstrap ledger requires genesis `edge_receipt.v6`,
`activation_record.v5`, and `checkpoint_record.v5` records (`R18:58-70`). All
three replacement schemas carry the new lease-state/control fields, with the
receipt explicitly following section 3 (`R18:326-341`). Section 3 says no
phase permits null control authorization or a null projected-entry digest
(`R18:161-184`), while the only transition kinds are the seven ordinary lease
transitions (`R18:252-262`). No bootstrap transition, bootstrap lease
authorization, bootstrap projected-entry rule, or genesis null exception is
defined. The inherited common-record rule also makes transaction/edge fields
null for bootstrap, whereas `lease_authorization.v4` requires a transaction
UUID (`R18:133-150`; R17:396-399). R24 nonetheless requires independent bytes
for all six genesis records (`R24:21-37`).

**Consequence.** The first selected activation/checkpoint/receipt triple cannot
satisfy the closed schemas. The v9 fence can never reach a byte-valid complete
bootstrap, so the corrected numeric ledger is not executable.

**Required correction.** Define exact bootstrap-specific record versions, or
an explicit genesis null/authorization matrix and transition kind, including
the selected budget root and digest rules. Freeze the per-row bootstrap-prefix
publication and crash sequence as well as the final genesis bytes; do not make
an independent encoder infer ordinary-lease exceptions.

### R18-PLAN-H4 — `pending_transaction.v4` is not a closed or reachable state machine

**Severity:** High. **Confidence:** High.

**Evidence.** The exact pending keys introduce `openLease`, but R18 defines no
schema, union, or digest rule for that object (`R18:301-317`). The phase set
includes `between-edges`, while the prose says edge and control fields have no
phase-specific omission even though section 3 authorizes control only for a
specific lease-state mutation (`R18:311-317`). The continuation is non-null
only when carrier zero is durable and the terminal carrier is absent
(`R18:314-317`), but the only publication trace selects pending at P1, writes
both carriers at P2, and does not advance selected authority again until P5
(`R18:115-128`). No selected step can publish that mid-edge continuation
state. R24 asks for frozen pending and continuation vectors without specifying
which reachable selector revision selects them (`R24:65-81`).

**Consequence.** Production and independent decoders must invent the
`openLease` type and phase/null matrix. Crash recovery cannot distinguish a
selected continuation from an unselected carrier candidate using the promised
state graph, so byte-identical resume versus protection is implementation
dependent.

**Required correction.** Publish the full reachable selector-state table for
P0...P6, with exact nulls and object types for every pending field. Either add
and account for a durable selector/CAS step after carrier zero, or remove the
unreachable continuation field and define deterministic, authenticated
candidate discovery/replay from the P1 intent.

### R18-PLAN-H5 — the v9 codec still requires human inference

**Severity:** High. **Confidence:** High.

**Evidence.** R18 promises that a future `V9CodecRegistry` will assign each key
one type, enum, null rule, and digest rule, and declares a plan failure if a
human default is required (`R18:343-352`). The governing documents do not
supply those assignments. Concrete gaps include integer fields such as
`deviceID`, `fileID`, and `fileTypeCode`, which match neither numeric registry
(`R18:237-250`); `openLease`, whose type is absent; many inherited arrays whose
element/reference union is not literal; and inherited state/role/pass/phase
strings missing from the R18 closed enum table (`R18:252-274`; R17:386-534).
The digest table maps a “JCS object identity” to JCS “with that identity field
null” without specifying the target object or behavior when the referenced
object has no self-identity field, as for `checkpointSHA256`, `recordSHA256`,
or `freshVerificationReceiptSHA256` (`R18:374-397`). `chunkSHA256` is also not
one of the stated raw-SHA exceptions even though the inherited verification
record treats it as the hash of raw chunk bytes (`R18:376-395`; R17:653-675).
R24 explicitly says registry construction must fail on any such gap
(`R24:65-81`).

**Consequence.** The first required implementation slice must either fail its
own registry-build gate or silently choose types and digest preimages that were
never independently reviewed. Production and independent codecs can produce
different bytes while each follows the prose.

**Required correction.** Put the complete declarative registry in the reviewed
plan artifacts before approval. Enumerate every schema key, scalar width,
array/map element type, enum, null/union branch, reference context, digest
target, literal domain, and exact preimage. Generate a static completeness
report from that artifact and include its digest in the next plan gate; do not
defer normative closure to implementation.

### R18-PLAN-H6 — the SHA continuation codec accepts states that are not SHA-256 states

**Severity:** High. **Confidence:** High.

**Evidence.** R17 correctly constrained continuation words `h0...h7` to u32
(`R17:653-666`). R18 replaces R17 sections 2 through 6 and explicitly assigns
all eight words the broader `u53` range (`R18:15-25,237-249`). It also carries
forward the continuation structure without stating the mandatory invariant
`decodedTail.count == totalByteCount mod 64`, whether `totalByteCount` includes
the tail, or the only legal standard-IV zero state. R24 mutates words and total
count but does not require rejection at `2^32`, invalid count/tail congruence,
or a non-IV zero state (`R24:152-163`).

**Consequence.** Values from `2^32` through `2^53-1` cannot be SHA-256 chaining
words. Implementations may truncate, reject, or hash differently. An attacker
or corrupt checkpoint can also pair a valid-looking word vector with an
inconsistent byte count/tail and obtain implementation-dependent resumed
digests.

**Required correction.** Restore exact u32 bounds for `h0...h7`; define byte
order, total-count meaning, tail/count congruence, standard initial state, and
finalization legality. Add explicit `2^32-1`/`2^32` and invalid
tail/count/IV vectors to R24 before relying on the otherwise finite oracle.

### R18-PLAN-H7 — the acyclic fresh receipt is not durably addressable for recovery or serving

**Severity:** High. **Confidence:** High.

**Evidence.** The abstract order `C(n) -> H(k) -> C(n+1) -> F -> C(n+2)` removes
the old digest cycle (`R18:403-436`). The v2 custody record still stores only
`freshVerificationReceiptSHA256`, not a receipt reference, path, or immutable
identity; R18 adds addressability fields to the custody and verification heads
but defines no corresponding head/path/publication location for F
(`R18:416-460`; R17:575-603,696-704). The evidence-reference union can describe
a fresh receipt, but no custody field selects such a reference. Yet recovery
must find an orphaned F after its fsync and publish only the byte-identical
missing C(n+2), and adoption/serving must direct-open F (`R18:434-436,486-504`;
`R24:83-91`).

**Consequence.** After death between F durability and C(n+2), a digest alone
does not identify a safe pathname or immutable file instance. Directory
enumeration, a guessed name, or accepting any file with matching bytes would
be an unreviewed recovery authority and can violate the no-follow/identity and
bounded-call contracts.

**Required correction.** Give F a canonical direct path and immutable
publication protocol, and make C(n+2) select an exact
`protocol_evidence_reference` including path, length, digest, and immutable
identity. Freeze candidate/selected crash states for every receipt write,
rename, file fsync, head/CAS, and directory fsync boundary.

### R18-PLAN-H8 — user-immutable flags do not close the acknowledged after-check freshness race

**Severity:** High. **Confidence:** High.

**Evidence.** R18 acknowledges that a mutation after an entry's final check but
before pending selection remains a platform threat and relies on a physical
test of root-and-descendant user-immutable flags to qualify the profile
(`R18:486-501`). The local macOS `chflags(2)` contract states that
`UF_IMMUTABLE` may be set **or unset by the file owner**. The threat explicitly
includes an external same-user writer (`R18:493-498`), which can clear the flag
after its entry was checked, mutate or replace the entry, and leave it
unrechecked before the pending custody/catalog publications. R24 requires this
after-check and immediately-before-fsync mutation matrix to reject or be
prevented (`R24:93-108`), but the plan names no kernel snapshot, retained file
descriptors, privilege boundary, or other mechanism that prevents it. Current
SPEC-001 requires post-capture mutation to fail fresh verification before use
(`SPEC-001:4324`).

**Consequence.** On the stated same-owner macOS boundary, the physical negative
test is expected to demonstrate the bypass and leave adoption permanently
feature-gated. The plan therefore does not provide a feasible path to the
required physical preparation/adoption journey; enabling it despite that test
would select a stale artifact identity.

**Required correction.** Define a concrete kernel-enforced custody mechanism
that the same-user adversary cannot revoke during the final check-to-CAS
interval, such as a separately privileged ownership/immutable boundary or an
atomic read-only snapshot with reviewed lifecycle and no secret leakage. If no
such mechanism is available, make the inability a named Build 1 qualification
blocker in the plan rather than presenting user immutability as a candidate
closure, and do not implement an enableable adoption path.

### R18-PLAN-H9 — the GC “index” is neither atomically selected nor boundedly verifiable

**Severity:** High. **Confidence:** High.

**Evidence.** The GC head selects a checkpoint containing only
`nextCandidateSHA256`, an undefined `candidateIndexTranscriptSHA256`, and a
prior checkpoint digest (`R18:518-530`). Candidate state and deletion cursor
are kept in mutable fixed-name files
`candidates/<artifactSHA256>.json`; the head/checkpoint contains no immutable
candidate reference, candidate generation, index-root reference, or exact
candidate-file identity. Sorted insertion requires publishing a new candidate
and changing at least one predecessor/successor link, but “CAS-appends” has no
multi-file intent or crash sequence (`R18:527-539`). Changing a candidate from
queued to checking/deleting/done likewise changes bytes outside the immutable
checkpoint without a defined binding update. Validating a bare transcript and
cycle-free sorted list can require traversing all 10,000 candidates, contrary
to the one-candidate/1,024-syscall quantum (`R18:542-557`; R24:135-150).

**Consequence.** A crash can leave a forked, lost, or rewritten candidate while
the head appears current. A bounded invocation cannot prove membership,
fairness, or that its deletion cursor is the selected successor. The claimed
failed-CAS convergence may repeat deletion work or accept stale queue state.

**Required correction.** Replace the mutable linked files with a selected,
versioned index root and immutable candidate-state records, or define an
equivalent fully transactional intent/successor graph. Freeze insertion,
state-advance, fairness-epoch, deletion-cursor, and CAS-conflict bytes and show
that validating the selected candidate and successor is O(log N) or otherwise
within the fixed quantum without scanning the index.

## Medium (1)

### R18-PLAN-M1 — blocked filesystem calls cannot obey the promised six/eight-second lock bound

**Severity:** Medium. **Confidence:** High.

**Evidence.** R18 states that a GC call stops at six seconds, releases custody
between quanta, and turns blocked filesystem calls into deadline/protection
rather than continued lock ownership (`R18:542-552`). The prescribed work uses
synchronous metadata, flag, unlink, and fsync operations while the custody lock
is held. Neither R18 nor R24 defines an interruptible subprocess, cancellable
I/O primitive, per-filesystem timeout, or watchdog ownership model capable of
releasing that process-held flock while a syscall is blocked. A heartbeat in a
separate task does not release a lock held by the blocked task. Current Swift
storage code likewise calls synchronous Darwin/Foundation filesystem APIs
directly (`DurableModelArtifactStore.swift:211-250`). R24's generic
“blocked-I/O cases” assertion does not distinguish an injected pre-call delay
from a real non-returning kernel call (`R24:135-150`).

**Consequence.** The GC path can monopolize the global custody lock past the
six/eight-second bound and block adoption/replacement control despite passing a
mocked timing test. This leaves the former R17 M1 availability finding open.

**Required correction.** Define an execution boundary that can actually shed
the lock on blocked I/O, including process ownership, kill/reap behavior,
durable cursor semantics, and provider-heartbeat isolation, or narrow the
guarantee to operations proven nonblocking and keep unsupported filesystems
feature-gated. R24 must include a real blocked-call harness that proves lock
release, not only clock checks around cooperating callbacks.

## Low (0)

None.

## R17 finding disposition

| Prior finding | R18 result |
|---|---|
| H1 bootstrap outside limit | Numeric ledger mismatch corrected, but bootstrap record encoding remains blocked by H3. |
| H2 ordinary progress unauthorized | Mandatory authorization is directionally corrected, but the executable lifecycle and pending codec remain blocked by H1/H4/H5. |
| H3 illegal changed-root refs | The three-branch snapshot is corrected, but terminal-carrier packing remains impossible for multi-root cases under H2. |
| H4 incomplete codec | Open under H4/H5/H6/H7/H9. |
| H5 custody/receipt cycle | Digest direction corrected; durable addressability/recovery remains open under H7. |
| H6 stale batched recapture | Batching no longer grants authority, but the same-owner final interval remains unclosed under H8. |
| H7 20/21 conflict | The receipt count is singular, but lifecycle mutation count and packing remain contradictory under H1/H2. |
| M1 unbounded GC | Open under H9 and M1. |
| M2 infeasible SHA oracle | Closed as a finite workload: 1,676 completions and ~43.8678 GiB aggregate suffix compression. |

## Required disposition

The implementation gate remains closed. Revise both the plan and test
specification to resolve every High and Medium finding, then submit the exact
new file digests to a fresh independent native GPT-5.6 Sol review. Do not
implement the v9 reservation/custody/GC design from R18/R24.
