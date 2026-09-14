# Independent GPT-5.6 Sol review — Build 1 c944 reconciliation plan r2

Date: 2026-09-10  
Reviewer: independent GPT-5.6 Sol plan-verification lane  
Verdict: **FAIL — conflict resolution and implementation remain blocked**  
Finding count: **0 Critical, 3 High, 0 Medium, 0 Low, 3 Info**

## Reviewed inputs

- Old Build 1 base: `914f7cafcdbcfc1805a10f4f34167218341d5587`
- New upstream base: `c9445561e4fe00a073926ff2ab0fdb0536d00e37`
- Reconciliation plan r1, verified SHA-256:
  `353fdb88df209785b44ea3c7358fa46b5e6aca608d19ee5121eb49bdeb020f39`
- Reconciliation plan r2, verified SHA-256:
  `d3093609329f0177318913544fc6d0b351a26d1104b9c8cf43f176e0ff9db44a`
- Compatibility test specification r5, verified SHA-256:
  `75c942bba7bad61297de5a2567eb06ad436e1944522437f647135023136e6576`
- Correction test specification r6, verified SHA-256:
  `69cded9a4aa91c68abccb9bd740f6a78e5c965d571401a8559946cbb9036ffec`
- Prior failed review, verified SHA-256:
  `247eedb98279dc60511f8276d01d8d7810901f073889ee47b9c490f2d5f8f339`

This review inspected the complete r1+r2 and r5+r6 bundles, the unmodified c944
tree through `origin/main`, the dirty Build 1 tree at 914f7, the approved Build 1
promotion/store architecture, and the relevant SPEC-010/SPEC-047 settlement and
economics contracts. It is a plan gate, so implementation tests were not run.
No reviewer output from a model other than GPT-5.6 Sol was used.

## Gate result

The required zero-Critical/High/Medium gate is not met. Prior findings H2 and H4
remain open in the revised bundle, and the revision introduces a separate High
lock-order conflict with the approved and implemented Build 1 store protocol.
The plan and companion tests need another revision and a fresh exact-hash review
before conflict resolution begins.

## Findings

### H2-R — The complete publication graph still omits c944's WS catalog/member-index owner

**Severity:** High  
**Disposition:** Prior H2 remains open; it is not weakened or downgraded.

**Evidence:** R2 says the epoch contains the exact four feeds and derived member
index, then declares a single owner order containing buyer `autotuneFeedsMu` but
no WS catalog/index owner
(`origin-main-c944-reconciliation-addendum-r2.md:33-40,48-59`). R6 repeats the
same owner list and asks only generically for feed/index replacement
(`test-spec-r6-c944-corrections.md:22-36`). C944 has a separate
`autotuneCatalogMu` that owns the active/compatible admission catalogs and
`artifactIdentityIndex`
(`origin/main:phase4-coordinator/internal/ws/server.go:156-167`). Its exported
`SetAutotuneCatalog` clears that index, while exported
`SetArtifactIdentityIndex` installs a replacement in a distinct operation under
the same WS lock (`origin/main:phase4-coordinator/internal/ws/server.go:558-586`).
The runtime feed observer rebuilds the index after buyer feed publication and
calls the WS setter outside `autotuneFeedsMu`
(`origin/main:phase4-coordinator/internal/buyer/autotune_feeds.go:990-1015`;
`origin/main:phase4-coordinator/cmd/coordinator/main.go:954-967`). WS hello,
heartbeat, and refresh identity derive the session's member binding through this
owner (`origin/main:phase4-coordinator/internal/ws/server.go:1492-1519`).

R2's claim that existing component setters “remain package-internal” does not
close this hole. These setters are callable across the repository's `internal`
packages, and the coordinator already calls them. More decisively, the declared
epoch cannot compare or pin an owner/generation that it never names.

**Consequence:** A direct or orchestrated c944 catalog/index clear, rebuild, or
replacement can race the buyer feed epoch and WS preparer. A session can be
admitted or refreshed from one WS member index while positive Build 1 authority
is prepared against another buyer feed generation, or an independently changed
WS owner can evade the promised generation comparison. The plan therefore still
does not prove one coherent member authority at the paid commit boundary.

**Required correction:** Add the c944 WS autotune-catalog/member-index owner and
its generation to the composite epoch and global acquisition graph. Specify the
atomic relationship among `SetAutotuneCatalog`, index clear/rebuild,
`SetArtifactIdentityIndex`, buyer feed publication, session identity refresh,
and final WS preparer installation. Inventory and table-test both WS setters and
all option/test publication seams explicitly. Either make positive-affecting
setters callable only through a coordinator-owned capability, or make every
bypass atomically disable/advance the paid epoch so an installed preparer cannot
remain current. R6 must pause this actual WS owner and exercise each concrete
setter under `-race`.

### H5 — R2's “single acquisition order” conflicts with Build 1's SQLite-first serialization protocol

**Severity:** High  
**Disposition:** New finding.

**Evidence:** R2 declares one acquisition order beginning with WS authority and
ending with “guarded SQLite append/CAS,” with reverse release
(`origin-main-c944-reconciliation-addendum-r2.md:48-63`). The approved Build 1
promotion architecture deliberately does the opposite at the resource-owner
boundary: memory-store serialization, or a reserved SQLite connection plus
successful `BEGIN IMMEDIATE`, precedes all authority pins
(`promotion-authority-addendum-r3.md:51-68`;
`implementation-S2.md:5-13`). The implementation enters
`sqliteutil.Transact` before invoking the authority guard
(`phase4-coordinator/internal/ws/model_admission.go:648-672`), and
`Transact` reserves a connection and obtains the SQLite write lock before its
callback (`phase4-coordinator/internal/sqliteutil/transact.go:45-84`). The
existing regression test holds an external `BEGIN IMMEDIATE` and proves that a
waiting promotion retains no WS/session/publication pin
(`phase4-coordinator/internal/ws/model_admission_sqlite_wait_test.go:14-87`).
That ordering was selected to avoid holding global authority locks through a DB
connection or busy-lock wait.

R2 does not distinguish early store serialization/`BEGIN IMMEDIATE` from the
later event comparison and insert/CAS. If item 10 includes the SQLite write-lock
acquisition, the plan reverses the approved order. If it means only the SQL
comparison/insert after an already-open transaction, the declared “single” graph
omits the transaction owner that actually precedes item 1. R6 likewise pauses
only “SQLite CAS” and does not preserve the connection/BEGIN-wait invariant
(`test-spec-r6-c944-corrections.md:22-36`).

**Consequence:** A literal implementation can hold WS authority, the selected
session writer, the pool registry, feeds, billing, settlement, and Tier2 locks
while waiting for a SQLite connection or write lock. That creates a global
availability convoy and can form a lock cycle with any transaction holder that
later needs one of those owners. Keeping the existing implementation instead
would violate the new normative order, leaving two incompatible acceptance
targets for a money-path commit.

**Required correction:** Define the full order in two explicit phases: acquire
memory-store serialization or SQLite connection plus successful
`BEGIN IMMEDIATE` first; then acquire every source owner with bounded try-locks
in the selected WS-to-Tier2 order; perform replay/head comparison and insert/CAS;
commit or roll back; then release source owners in reverse. If a different order
is desired, it needs a separately justified nonblocking SQLite protocol and a
complete DB-to-authority cycle audit. R6 must retain the real external-BEGIN
wait test, add the memory-store serialization case, and prove no authority pin is
held during connection/BEGIN waits as well as through failure/cancellation.

### H4-R — Canonical v2 defines six keys, but Build 1 settlement authority serializes twenty-four

**Severity:** High  
**Disposition:** Prior H4 remains open; the discriminator is fixed, but the
required closed new-record shape is not.

**Evidence:** R2 defines canonical Build 1 as
`artifact_admission_schema = macprovider.artifact_admission.v2` plus “exactly the
canonical six-key set,” and rejects other artifact-extension keys
(`origin-main-c944-reconciliation-addendum-r2.md:100-129`). R6 golden-tests that
same six-key v2 and rejects unknown artifact keys
(`test-spec-r6-c944-corrections.md:54-71`). The Build 1 object that is flattened
into `RouteSnapshot.Value()` contains twenty-four fields, not six
(`phase4-coordinator/internal/billing/artifact_admission.go:12-40`;
`phase4-coordinator/internal/billing/route_snapshot.go:139-149`). In addition to
the six c944 member fields, it binds artifact/candidate release IDs and signers,
rate-card digest/version/signer, coordinator-resolved model key, persisted
billing snapshot ID and exact rates/share/multiplier/unit, provider session and
receipt-key IDs, and authority/probe expiries. Its validation and immutable
billing lookup consume those values
(`phase4-coordinator/internal/billing/artifact_admission.go:42-86`;
`phase4-coordinator/internal/billing/route_snapshot.go:160-173`). SPEC-047 also
requires effective signed rates, share, multiplier, units, and rate version to
match authority captured for the attempt
(`specs/SPEC-047-network-model-admission.md:217-225`).

The r2/r6 bundle never classifies the additional eighteen fields. Treating them
as artifact-extension keys makes every intended Build 1 snapshot invalid under
the stated exact-six rule. Treating them as another extension leaves its name,
version, closed allowed set, all-or-none groups, duplicate handling, validation,
and canonical preimage unspecified.

**Consequence:** Implementers can either reject valid Build 1 paid snapshots as
future/invalid or omit/accept ambiguous rate, session, expiry, and signer fields
outside the closed schema. Both outcomes defeat the claimed canonical digest
compatibility. The latter can also weaken immutable pricing and session/receipt
binding during settlement and replay.

**Required correction:** Enumerate the complete canonical v2 route-snapshot
shape. State whether the additional eighteen Build 1 authority fields are part
of the same discriminator or a separately named/versioned closed extension; in
either case define exact required/optional key groups, presence/null rules,
duplicate rejection, validation, and the complete `Value()` canonical preimage.
Preserve the exact historical c944 six-key classifier without inventing the new
fields. R6 needs a golden full Build 1 v2 row/digest and independent missing,
extra, duplicate, wrong-type, and cross-group partial cases for every authority
group, plus settlement/restart/replay proof using the captured rate/session/
expiry material.

## Prior-finding disposition

| Prior finding | Result | Evidence |
|---|---|---|
| H1 immutable historical settlement | **Closed in plan/tests** | R2 separates pre-dispatch live freshness from snapshot-only receipt, settlement, reconciliation, and replay; R6 routes under G, publishes G+1, settles/restarts/replays G, rejects mutation, and instruments current accessors (`r2:14-29`; `r6:8-20`). |
| H2 complete owners/setters | **Open as H2-R** | WS `autotuneCatalogMu` and its catalog/index setters remain absent from the supposedly complete epoch, lock graph, and contention matrix. |
| H3 durable retry identity | **Closed in plan/tests** | R2 defines private journal v2 with original descriptor-derived identity and locator digest, fresh no-follow revalidation/full rehash, and non-retryable v1 GGUF; R6 supplies the restart/mutation matrix (`r2:76-98`; `r6:38-52`). |
| H4 canonical schema migration | **Open as H4-R** | The discriminator and c944 legacy classifier are added, but canonical Build 1's complete twenty-four-field authority shape remains undefined. |
| M1 pricing identity | **Closed in plan/tests** | Only the pair-resolved `model_key` may enter signed/effective rate lookup; malicious rows under other identities are tested (`r2:131-144`; `r6:73-83`). |
| M2 durable rollback | **Closed in plan/tests** | Named ref, verified bundle, private manifests, frozen source worktree, and fresh c944 worktree are required and tested (`r2:146-168`; `r6:94-103`). |
| M3 observability | **Closed in plan/tests** | Stable bounded reason codes/counters, redaction rules, no per-member storm, and exact emission assertions are defined (`r2:170-193`; `r6:85-92`). |

## Confirmed scope and safety points

### I1 — Immutable settlement direction is correct

**Severity:** Info

The revised lifecycle correctly preserves already-routed generation G across a
G+1 publication while rejecting stale G before a new dispatch. Settlement uses
stored snapshot/canonical bytes, billing snapshot, and receipt tuple rather than
current feeds or keyrings. This closure must remain unchanged.

### I2 — Journal v2, pricing, recovery, and observability are sufficiently concrete

**Severity:** Info

The revised journal records durable original GGUF file identity only in the
private local store, performs fresh descriptor validation/full hashing, and
fresh-signs retries. Pricing lookup is unambiguous. The recovery ref/bundle and
fresh hidden worktree preserve the frozen original. Runtime signals are bounded
and redact local identity material. These closures should be retained verbatim
except where the complete owner/schema corrections require additive tests.

### I3 — UX/economics qualification and unlanded slice-4 isolation remain bounded

**Severity:** Info

R1 keeps the provider preparation command limited to its supported primary MLX
artifact while preserving coordinator-verified GGUF/member network settlement,
and C944-08 tests that separation (`r1:92-99`; `r5:85-92`). Existing Build 1
economics gates remain additive through r5's retained r4 selections; r1 does not
authorize economic activation (`r1:139-165,204-210`; `r5:114-137`). R1 excludes
`feat/byom-v02-slice4-decision-path` in the trigger, normative contract, and
non-goals (`r1:15-16,38-39,204-207`). No reviewed requirement depends on that
unlanded branch.

## Required disposition

Revise r2 and r6 to close H2-R, H5, and H4-R without weakening the already
closed H1/H3/M1/M2/M3 requirements. The next review must inspect the complete
r1 plus revised-r2 plan and r5 plus revised-r6 test bundles at their new hashes.
Conflict resolution remains blocked until an independent GPT-5.6 Sol review
reports zero Critical, High, and Medium findings.
