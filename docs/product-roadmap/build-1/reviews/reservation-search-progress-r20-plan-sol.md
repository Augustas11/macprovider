# Build 1 reservation search progress R20/R26 — independent adversarial plan review

Date: 2026-09-11. Reviewer: native GPT-5.6 Sol, high reasoning.

## Verdict

**REQUEST CHANGES. Architectural status: BLOCK.**

Exact finding count: **0 Critical, 7 High, 3 Medium, 0 Low**.

R20/R26 do not meet the mandatory zero-Critical/High/Medium plan gate. The
SQLite/VFS/custody/GC implementation remains unauthorized. This review changes
no source, test, SPEC, release, deployment, or operator-secret file.

## Frozen inputs and independent checks

- Reviewed commit:
  `7e6445e08d4e843040180a76a411ee03ba02b0ca`.
- R20 SHA-256:
  `f11d0a0668df172c4001e0ce5da76eba815ba28cdba26bd11abf1fadcd6690a1`.
- R26 SHA-256:
  `9da8907a304901528d476ff3fb02b82df4e5d83f5c583b78ee0ee70e3966a352`.
- Frozen R19 review SHA-256:
  `fba7ebfb0e2732b0c6b34af05709a4d1b83fc3e54dfde03a823179b22256ce7f`.
- Previous failed-review commit:
  `2c688e5ad1a30b31a79e6c76d7db951c5fe28fc2`.
- The task supplied `1d2c930bad81704dd0acc0322226725d8b64aceb` as
  origin/main. The live local tracking ref during this review was
  `c123ae2d2d08053612d940b3077994f7c4d709d7`; its only delta from the supplied
  baseline was two `audits/_prompts/BUILD_SPEC_039_*` files, not Build 1 source.
  No fetch was performed.
- Appendix A extracted exactly as normalized hashes to its declared
  `3887c7239fb9e2f008cc39795034dfcc1515e585ca0ff7b1b62b2a5e9948b77f`
  and loads successfully into SQLite 3.51.0.
- A live schema oracle inserted a custody event owned by row 0, selected it in
  `custody_current` as row 1, and returned `foreign_key_violations|0`. The same
  run accepted `materialization` cursor 64.
- Independent registry expansion counted 128 recovery entries, 88 entries
  matching the stated keyword rule, and a 40-intent discrepancy from the
  printed `+128` formula.
- The minimum GC event count for enqueue plus 16 checking/result quanta is 33,
  before any claim/recovery failure. That exceeds the stated 25th-nonterminal
  protection point.
- A live WAL oracle used the exact 4,096-page autocheckpoint and 64-MiB
  `journal_size_limit` settings while a reader held an old snapshot. The WAL
  reached 75,330,112 bytes; `journal_size_limit` did not enforce the claimed
  67,108,864-byte maximum.
- `git diff --check` passed for the R20/R26 commit.
- Production/test search found no `CatalogAuthorityV5`,
  `BoundDirectorySQLiteVFS`, R20 schema, or R20 receipt codec implementation.
  Current dirty code remains implementation evidence only and was not changed.

Two additional native GPT-5.6 Sol lanes independently reviewed the same frozen
inputs. The code/security lane returned REQUEST CHANGES with 0C/2H/2M/0L. The
architecture lane returned BLOCK with a catalog/custody ownership finding.
Their overlapping findings are de-duplicated in the counts below.

## Critical (0)

None.

## High (7)

### R20-PLAN-H1 — deterministic bootstrap cannot resume its pre-metadata crash states

**Evidence.** R20 section 3 step B1 requires any existing candidate to match
bootstrap ID, source, schema, registry, semantic manifest, directory identity,
bootstrap phase, and allowed-name state exactly (lines 177-183). B1 may then
create the candidate directory, B2 creates the main database, and B3 is the
first step that creates `protocol_meta` and stores those values (lines 184-187).
R26-03 nevertheless kills before and after mkdir, xOpen, and the DDL group
(lines 55-60).

**Consequence.** A crash after candidate mkdir or main-file creation but before
the B3 metadata transaction leaves the one directly derivable candidate with
no stored metadata capable of satisfying B1. The literal rule requires
protection rather than resume, contradicting the claimed predecessor/successor
recovery for every B0-B8 crash.

**Required correction.** Define a closed pre-B3 candidate state machine. Freeze
the exact legal leaf sets and file/header predicates for empty directory,
created-empty main, committed schema, and rollback recovery; bind the
deterministic path and directory identity before accepting each state. Add
independent crash vectors for each syscall/DDL boundary and reject every other
partial shape without enumeration.

### R20-PLAN-H2 — the manifest cannot produce the advertised allocation and replacement transactions

**Evidence.** Section 5.1 says generic progress always changes one `row_state`
or `fixed_state` and updates meta (lines 325-327). Appendix C repeats that
descriptor (lines 857-863). `allocation-progress-special` then supplies its own
four evidence inserts, new row state, row-slot CAS, and meta CAS (lines
870-875). No grammar rule says which generic statements it replaces. The same
problem is decisive for replacement: generic progress contributes transition,
operation, row-state, and meta changes, while `replacement-progress-special`
adds five changes (lines 885-890), totaling nine. R20 claims eight and omits the
row-state transition (lines 338-343). Initial activation similarly totals seven
under the generic grammar while R20 claims six.

**Consequence.** Allocation can duplicate evidence/state/meta or omit required
transition/accounting statements. More seriously, row ordinal 109 cannot both
advance its authoritative row state and perform the claimed eight-row atomic
switch. R19 H4 and H5 remain open, and independent production/oracle compilers
cannot generate one byte-exact DML sequence.

**Required correction.** Publish one fully expanded statement list for every
special operation. State which generic descriptors are retained or replaced.
For allocation, list exactly transition, operation, four evidence rows,
source row, row state, row slot, and meta. Redesign replacement/activation so
their mandatory row-state transition and all custody/catalog/accounting writes
fit the reviewed ceiling, or revise and rejustify the ceiling. Make R26 compare
the fully expanded sequence rather than composing ambiguous templates.

### R20-PLAN-H3 — recovery effects and lifetime intent accounting have two conflicting authorities

**Evidence.** Section 5.2 says every one of the 128 recovery-family entries uses
`legacy-inspect-readonly` and derives the exact `32S + 16R + 128` intent bound
(lines 390-393). Eight lines later it says only recovery names containing
`external`, `directory`, `carrier`, or `selector` use that template (lines
398-401). Expanding Appendix B produces 128 recovery names but only 88 keyword
matches, so the latter rule yields 49,240 maximum intents while the former and
DDL counter yield 49,280.

**Consequence.** Registry and semantic-manifest digests, operation
authorizations, external-call permissions, and the physical maximum-shape
database depend on which rule an implementation chooses. The purported
machine-readable manifest and M1 table bound are not deterministic.

**Required correction.** Remove name inference. Emit the external template,
intent count, evidence rule, and change counts literally for each fixed line or
define one non-conflicting range rule. Recompute registry/manifest hashes and
all table formulas from that single expansion, with an oracle that fails on an
unassigned or multiply assigned line.

### R20-PLAN-H4 — persisted row ownership is not bound across source, custody, catalog, staging, and GC

**Evidence.** Appendix A stores ownership repeatedly but omits the composite
references that make the values agree. `row_slots.source_transaction_uuid` is
not tied to `source_rows.transaction_uuid`; `staging_sources.transaction_uuid`
is not tied to its selected row; `custody_current.row_ordinal` is not part of
either FK to `custody_events`; catalog active/pending row ordinals are separate
from their custody-current pair; and `gc_candidates.row_ordinal` is separate
from its custody-current pair (lines 755, 758, and 770-775). The independent
SQLite oracle proved an event on row 0 and current head on row 1 pass
`foreign_key_check` with zero violations.

**Consequence.** A database can be schema-valid while serving, replacement,
staging authorization, GC, binding receipts, and settlement evidence name
different source rows for the same artifact. Startup integrity/FK checks do not
detect the substitution, so the direct-reference trust boundary is false.

**Required correction.** Add composite unique keys and foreign keys that carry
row ordinal and transaction UUID through every ownership edge. Bind catalog
operation UUID/binding digest to the selected custody event and source row.
Add persisted mismatch tests at startup, staging copy, activation,
replacement/cancellation, serving, and GC, and require both FK and semantic
integrity checks to reject them.

### R20-PLAN-H5 — the GC event budget prevents the maximum artifact from completing

**Evidence.** Each quantum first appends a checking event (lines 518-520) and
then `gc-advance` inserts the result event (Appendix C lines 912-916). A
4,096-entry artifact needs 16 successful 256-entry quanta (lines 529-530).
Enqueue plus 16 checking/result pairs therefore needs at least 33 events before
any of the allowed eight failures. R20 instead protects at the 25th
nonterminal event and says one terminal event makes 26 (lines 530-532). R26-10
simultaneously demands 16 successful quanta and exercises generations 64/65
(lines 194-198).

**Consequence.** A maximum supported artifact protects after at most twelve
successful quanta and cannot delete all 4,096 entries. Different readings of
"event" also invalidate the 25-result evidence allowance and capacity oracle.

**Required correction.** Define one event-generation equation including
enqueue, every claim/checking event, every result event, failures, blocked I/O,
protection, and terminal completion. Set separate explicit caps for attempts,
successful quanta, results, and total events; reserve the terminal/protection
slot before work. Derive DDL/counters/evidence maxima from that equation and
model-check exactly 4,096 entries plus first-over.

### R20-PLAN-H6 — serving has no lifetime pin against replacement and GC

**Evidence.** Serving reads an active tuple and revalidates root/receipt before
MLX open (lines 418-423 and 460-461). Replacement atomically releases the old
artifact, after which GC uses the daemon per-artifact lock. The plan expressly
permits no lease (line 298) and gives serving no shared daemon lock, open-FD
snapshot, refcount, or generation pin lasting through MLX open/use. R26-08 only
asserts that serving sees no partial catalog pair (lines 147-160).

**Consequence.** A reader can select A, a concurrent replacement can release A,
and GC can clear/unlink A after the reader's validation but before or during
MLX open. Atomic catalog replacement alone does not make the selected artifact
available for the request, and a read transaction in WAL mode does not block
the writer/daemon lifecycle.

**Required correction.** Specify a crash-recoverable serving pin that the
daemon and GC honor through model open/use, or prove an equivalent immutable
open-descriptor snapshot for every MLX file access. Bind the pin to catalog
generation/artifact/custody event; reject stale acquisition; release it on
completion/cancellation/process death; and add replacement-plus-GC races before,
during, and after actual MLX open.

### R20-PLAN-H7 — the 64-MiB WAL claim has no enforcing mechanism

**Evidence.** R20 configures `wal_autocheckpoint=4096` and
`journal_size_limit=67108864` (lines 123-130), then requires WAL at most 64 MiB
(lines 599-607). `journal_size_limit` controls retained size after reset; it is
not a hard append quota while checkpointing is blocked. The independent live
oracle held an old reader using the exact settings and grew the WAL to
75,330,112 bytes. No R20 DML/VFS rule checks WAL bytes before begin, reserves
filesystem bytes for already-open operations, or stops append at a safe limit.

**Consequence.** A legal long reader or failed checkpoint can exceed the
claimed bound, consume the emergency disk budget, and turn required finish,
protection, or GC commits into disk-full failures. The M1 capacity correction
is not closed.

**Required correction.** Define and test an enforced WAL/disk budget: maximum
reader lifetime, checkpoint/restart policy, begin cutoff with worst-case
already-open append reserve, VFS quota/error behavior, and fail-safe handling
when a checkpoint cannot advance. Measure the exact production SQLite/APFS
profile with concurrent readers and crash recovery; do not use
`journal_size_limit` as proof of a hard maximum.

## Medium (3)

### R20-PLAN-M1 — `fixed_state` accepts impossible materialization cursors

**Evidence.** R20 and R26 assign materialization 32 entries, local ordinals
0...31. Appendix A groups materialization with 64-entry merge and accepts
`current_local_ordinal <= 64` (line 754). The live DDL oracle successfully
inserted materialization cursor 64.

**Consequence.** The authoritative table accepts cursors 33...64 with no
registry predecessor or successor. Fixed-state H1 is only partially closed.

**Required correction.** Cap source/tree/verification/materialization at 32,
merge at 64, and recovery at 128. Add first-over DDL and lifecycle vectors for
every family.

### R20-PLAN-M2 — the complete migration inventory omits app control surfaces and has no reproducible normalization

**Evidence.** Section 11 and Appendix E call the inventory complete, but the
dirty app has authority-adjacent transaction state and executable payload
writes in `ModelTransactionControl.swift`, `ModelTransactionPayload.swift`, and
`ModelTransactionRequest.swift`; they are absent from the cutover matrix.
Appendix E also specifies only "whitespace-normalized function declarations"
and "seven section 11 literals" (lines 1063-1099), without an extraction
grammar, whitespace algorithm, exact sidecar leaves, or literal list. The prose
itself names more than seven literal/categories.

**Consequence.** R26-13's 199-declaration and 68-bypass hashes are not
independently reproducible, and a post-B8 app-side authority/cache bypass can
remain outside the static/runtime gate.

**Required correction.** Add every Malibu app transaction control/payload/
request surface with an explicit authority or non-authority classification.
Publish the exact syntax-aware extractor version, file set, declaration rule,
normalization bytes, literal/sidecar list, sorting rule, and expected manifest
artifact. Reopen the plan gate whenever that generated input changes.

### R20-PLAN-M3 — the post-generation-seven abort branch has no registry or DML path

**Evidence.** Generation-seven slot seven consumes row registry ordinal 173 and
sets A8/`row-abort-terminal` (lines 274-290 and Appendix B lines 808-811). R20
then says a further abort request selects protected without a ninth receipt,
and R26-06 requires that result. No row registry entry has A8 as predecessor,
and every mutation must be a manifest-selected three-commit operation (lines
295-303).

**Consequence.** Implementations can silently choose a no-write typed rejection,
an unregistered protection write, reuse ordinal 173, or a forbidden ninth
operation. The terminal retry contract and replay/economic behavior are not
closed.

**Required correction.** State explicitly whether the further request is a
zero-write replay-safe terminal response or add a distinct bounded protection
transition with exact DML, charge, counters, and uniqueness. Add byte-exact
tests for repeated requests after generation seven.

## Low (0)

None.

## R19 finding disposition

| R19 finding | R20/R26 result |
|---|---|
| H1 fixed predecessor | **Partially closed.** Six family rows exist; M1 leaves an impossible accepted cursor. |
| H2 post-bootstrap allocation | **Partially closed.** Indexed slots exist; H2 leaves allocation progress non-executable. |
| H3 abort/retry reachability | **Partially closed.** Eight generations are mapped; M3 leaves the required terminal follow-up undefined. |
| H4 semantic effects | **Open.** H2 and H3 give conflicting/non-executable manifest expansion. |
| H5 atomic replacement ceiling | **Open.** H2 shows required row-state plus switch writes exceed the stated eight-row sequence. |
| H6 candidate rediscovery | **Partially closed.** The path is deterministic; H1 leaves pre-metadata crash states unrecoverable. |
| H7 bootstrap profiles | **Closed in plan shape**, subject to implementation and physical qualification. |
| H8 no-follow SQLite open | **Closed in plan shape**, subject to the unimplemented VFS and physical race suite. |
| H9 GC checking recovery | **Partially closed.** Helper/result recovery is described; H5 makes the maximum lifecycle terminate early. |
| H10 privileged staging source | **Partially closed.** Canonical XPC handoff exists; H4 leaves persisted source-row ownership unbound. |
| M1 lifetime bounds | **Open.** H3, H5, and H7 invalidate intent, event, and WAL bounds. |
| M2 external codecs | **Closed in plan shape**, subject to cross-language and physical daemon tests. |
| M3 callsite migration | **Open.** M2 leaves omitted surfaces and a non-reproducible hash oracle. |

## Gate decision

The exact R20/R26 revision is rejected. Revise the normative plan and test
specification, recompute exact hashes, and rerun an independent native GPT-5.6
Sol gate. Do not begin the R20 Swift/C/daemon/SPEC implementation until a fresh
review reports zero Critical, High, and Medium findings.
