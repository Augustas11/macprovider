# Build 1 catalog read completeness addendum r1

Date: 2026-09-10. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.

This is a bounded proposed correction to the approved catalog read lifecycle r2
contract, SHA-256
`e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`.
It addresses all four Medium findings in the preliminary native Astra CLI review,
`reviews/catalog-read-cli-preliminary-r1-astra.md`, SHA-256
`fb0ffa38641044059113efffd6f546739db37436a79c0d3b54832bfa8c0edb70`.
Independent review of this exact proposal must return zero Critical/High/Medium
before these runtime corrections. The preliminary review and any existing green
tests do not constitute implementation acceptance. The existing final combined
code/security/architecture gate remains required.

## 1. Evidence and unchanged boundaries

The preliminary review's call graph is confirmed in the current source:

- `ModelCatalogTransactionRetention.swift`, `cleanupRecordsFromIndex`, skips an
  active entry whose primary evidence has nil bytes before its `requireComplete`
  error handling can run. The decoded active index cannot establish that this
  unobservable primary carried no cleanup obligation (CR-CLI-M1).
- `ModelCatalogReadCommand.swift`, `runLocalRead`, collects recoveries before
  `makeCompleteModelCatalogLocalActions`. Its adoption lookup calls
  `indexedRecommendation` → `prepareRecommendationIndex` → `reconcile`.
  Reconciliation can terminalize an abandoned started evaluation and set
  `cleanupRequired` after the inventory was collected (CR-CLI-M2).
- `prepareRecommendationIndex(target:budget:)` passes no shared budget into
  `try? reconcile(selector)`. Its primary read/decode catch also suppresses
  failures. `reconcile` defaults to a new eight-second deadline and still has
  unbudgeted `load`/binding/result helper paths and suppressed recommendation
  indexing errors. A top-level read-budget check does not cover these nested
  reads or commits (CR-CLI-M3).
- `ModelCatalogReadOutput.preflight` currently inflates actions in a projection
  built with empty admission statuses. Actual current admissions are obtained
  only after hashing. The builder can then populate variable admission strings
  and economics omitted from the preview (CR-CLI-M4).

Preserve the exact option/FD protocol, read request ownership, same captured
config, 10/1,800-second total and phase/stall limits, one exact-target hash,
64 KiB stderr/8 MiB stdout/1 MiB JSONL/4,096-event limits, 2 KiB conservative
outer-envelope margin, independent deadline monitor and final full output check.
No new dependencies, private-key handling, service deployment, admission grant,
mutation-owner spawn, artifact preparation, or persisted verified-read cache is
authorized. Do not change retention capacity/retirement scheduling or weaken
original recommendation/provenance/immutable-binding checks. Protocol-1 and
existing operator control defaults remain supported.

## 2. Complete active evidence (CR-CLI-M1)

For an owned projection, complete inventory means every entry represented as
active by the captured, validated active-index receipt was decidable under the
same request budget. Each entry requires an existing safe primary, successful
bounded read/closed decode, matching UUID/target/kind/generation and applicable
original/provenance evidence. Required original/cleanup evidence that is absent,
unsafe, truncated, undecodable or changes while observed makes the whole read
incomplete. In particular, `primary.bytes == nil` is an error in complete mode,
including deletion between initialization and primary capture.

A successfully decoded nonterminal record, or a terminal record with no cleanup,
can be excluded from the cleanup rows after its evidence is validated. This is
different from an unreadable record. Active entries whose generation/lineage is
not sufficient to decide or safely identify a required recovery fail complete
mode; they are not silently filtered by an optional selector. Valid previously
supported migrated records retain their approved provenance route. This does
not invent a generation or turn legacy uncertainty into cleanup authority.

Allocating/retiring entries must first follow the existing bounded recovery and
receipt rules. If they prevent a stable complete inventory, fail this read.
Do not reclassify interrupted transitions as absent active history. An actual
complete scan with no obligations may still publish `recoveries: []`.

Keep conservative standalone defaults where explicitly required, but select the
strict behavior at every owned projection call. Do not convert complete-mode
errors to empty arrays at a wrapper. Existing atomic journal changes made before
a later failure remain durable and recoverable.

## 3. Original budget through the whole call chain (CR-CLI-M3)

The owned path must thread one explicit request/phase budget view and the current
helper budget through recommendation preparation, reconciliation, original
binding recovery, result/seal/provenance captures, index preparation, reservation
and final commit/validation. Existing standalone overloads may keep defaults;
owned calls must choose the explicit overload. No nested owned call may select
`nil readBudget`, `.init()` or a new default deadline accidentally.

Use either an explicit `ModelCatalogReadBudget` plus the caller's already-created
`ModelTransactionWorkBudget`, or a single equivalent composed view. Its check
must enforce the minimum of the original request remainder, the current phase
remainder and the existing helper's remaining maximum. Passing a work budget
into a callee must preserve that helper deadline as well; it must not create a
fresh eight seconds merely because the read's total deadline remains valid.
New sibling helpers may apply their existing maximum, still bounded by the same
original request/phase. Finalization never replenishes the total request budget.

Concrete required paths include `indexedRecommendation` →
`prepareRecommendationIndex` → `reconcile`; `load(selector)`/original primary
loading; `recoverBoundEvaluationSuccess`; preparation-seal/result capture;
`validateOriginalBindingEvidence`; active receipt capture; staging observation;
`commit`/`commitEvaluationSuccessTerminal`; and `indexCompletedEvaluation`.
Audit transitively called bulk-read, recovery and metadata-check helpers rather
than adding only one parameter at the direct call. Bulk capture/decode/hash stays
outside the global journal lock. Check before/after each bounded read chunk and
at existing evidence/publication boundaries, including immediately before any
journal/pointer write and before acknowledging that write as usable by this read.

For projection use, nil recommendation means a complete validated lookup found
no current eligible recommendation (for example no context pointer, or an
existing fully observed nonterminal live owner). It must not mean failure to
read/decode/reconcile an active record. Remove projection-mode `try?` and catches
that merely check the budget then continue on arbitrary errors. A lock held by
a positively observed live owner can retain the existing unavailable-action
policy when its record is readable and no reconciliation is authorized. Missing
or corrupt evidence, unexplained contention/change, cancellation, time/IO limits
and indexing failures propagate incomplete. Preserve specific stable semantic
ineligibility where already defined; do not collapse all exceptions into it.
The independent process deadline remains a second boundary, not a substitute for
these cooperative checks or proof that post-expiry mutations are permitted.

## 4. Recovery remains complete after optional action work (CR-CLI-M2)

Use this order for quick/final verified publication, under the original budget:

1. Finish the existing recommendation reconciliation/index preparation that the
   eventual action lookup may need for relevant signed primary targets. This is
   journal evidence recovery using original bindings, not an available action,
   model hash, recommendation execution, or new mutation owner. The verify
   preflight must also account for a selected target that will become evaluable
   only after hashing; do not postpone its deterministic abandoned-evaluation
   reconciliation merely because quick inspection is currently unverified.
2. Collect a complete cleanup inventory **before** optional action reservations,
   as lifecycle r2 requires. Reserve cleanup actions only through existing exact
   UUID/generation/evidence APIs. Preflight uses a non-reserving cleanup template.
3. Construct actions/recommendation lookups using those prepared current inputs.
   The original budget and errors propagate through any remaining reconciliation
   or index maintenance. No initial cleanup list may be treated as final merely
   because the first pass succeeded.
4. Perform a final complete inventory capture after the last action-side journal
   work. If a new/changed obligation exists, obtain its proper cleanup reservation
   under the same budget and recapture its final evidence. Revalidate the final
   inventory and action evidence before encoding/emission. A changing or expired
   pass fails incomplete; do not loop indefinitely or silently publish a subset.

The first inventory satisfies cleanup-before-actions; the final capture seals
what is actually published. Pre-reconciliation avoids the known deterministic
optimistic preflight, while final capture handles remaining action-side changes
and concurrent journal writers. An already published reservation is never rolled
back to hide an interrupted projection. Do not revert a valid reconciliation,
blindly reuse the earlier list, or merge old recovery rows into a new document.

Complete inventory capture must retain a request-local observation sufficient
to revalidate every active primary (including excluded nonterminal/non-cleanup
entries), exact active membership and relevant provenance. Retain compact
placement/metadata/digest witnesses, not all 1,024 maximum-size primary JSON
bodies or decoded event histories. Reuse existing receipt/descriptor identity
rules and bounded metadata checks; no persisted readiness or recovery cache.
Transient decoding may release each body before the next entry. Final locked
uses validate the actual pinned index and compact evidence metadata only; no
bulk reads/decodes under the lock. If a necessary witness cannot be retained or
validated within existing limits, the read is incomplete. This proposal does not
promise that 1,024 four-MiB primaries finish inside ten seconds.

For publication, no journal-mutating helper runs after the final inventory/action
witness check. Index/primary/provenance changes invalidate the relevant evidence;
a stable index alone is insufficient because primary updates need not change
index membership. Source-changed recapture is bounded by the original deadline
and existing contention policy, not a new per-entry retry budget. Final output
size and config/artifact placement checks remain mandatory. These are coherent
observations within a finite window, not a guarantee that another owner can
never change state after emission.

## 5. Actual shape preflight and signed-input binding (CR-CLI-M4)

### Observed field constraints

`BYOMModelAdmissionClient.maxStatusResponseBytes` is 64 KiB for a complete status
response. `BYOMAdmissionStatusValidator` closes the object/enums and checks
provider/candidate/guidance relationships, but imposes no individual length
limit on `coordinator_event_id` or `state_observed_at`; the economics builder
copies both strings. Therefore neither a short timestamp assumption nor the
2 KiB margin bounds all accepted admission shapes. A valid status below its
existing total transport cap can contain a long/escaped projected string.

`RateCardProjection.validated` restricts rate model keys to at most 128 ASCII
scalars and requires the rate version to equal its projection hash; its numbers
are checked for the existing nonnegative/finite/share rules. The candidate
validator requires exact 40/64-character revision/artifact hashes for applicable
rows, but these rules do not impose the same cap on all model IDs, catalog
versions, display strings or historical cleanup targets. The active index limit
is 1,024; a primary can be up to 4 MiB with up to 2,048 events. These are input
and work limits, not proof that any particular projection fits the 1 MiB line.

No new wire string/row limit is proposed. In particular, do not allocate 64 KiB
of hypothetical admission padding to every row (which would unnecessarily
shrink accepted capacity), clip strings, reject formerly valid names by an
invented limit, or omit economics/recoveries to fit. Count the actual accepted
strings with the actual encoder. Existing parser/transport bounds remain intact.

### Pre-hash preparation

Load the actual current discovery, runtime and admission observations before
hashing, using the same captured config and same request budget. Use a budgeted
owned admission fetch path with checks before/after each await; a request budget
failure must not disappear inside the current best-effort `try?` loop. Existing
explicit local-only absence of configured provider/coordinator/credentials can
remain unavailable admission under its approved local-default rules. An actual
accepted coordinator status must be included, not replaced by `[:]` for sizing.

Prepare relevant reconciliation as section 4 describes and capture complete
current cleanup identities without reserving actions for an estimate. Build a
sizing-only complete projection from the real production row/field constructors,
including actual admission strings, exact bound model/display/action IDs,
current full warnings, all current recovery identities and all economics fields
that can appear for the eventual verified target. For optional economics that
can become populated, calculate their concrete values with the same bound
rate/demand/candidate inputs and builder conversion rules even when the current
admission does not expose them. This is an in-memory size template, never a wire
permission/admission/readiness assertion. Do not synthesize trusted status for
publication or bypass its validation to produce the estimate.

Take the real encoded maximum among eligible closed state/action/nullable-field
variants. The template must cover exact fixed UUID/generation lengths, longest
applicable closed reason/runtime/verification strings, booleans, numeric values,
rate keys/version/time, known demand/supply values, and warning collections.
All variable strings come from the captured accepted inputs; all feed-derived
numeric values use the actual converters/encoder. Do not rely on a guessed
number of bytes per row or assume filling a field is always larger than its
unavailable representation. Keep the fixed 2 KiB envelope/sequence/timestamp
margin and check the actual final encoded event including newline again.

The static-input binding must include selected candidate, artifact, rate and
demand **bytes, signer identity, effective version and trust/fallback class**,
not only the chosen candidate/artifact identity. Re-fetch all four after hashing
as already required for final current authority. Require those bindings and
current freshness/validity to match before using the template/result; changed
or expired signed inputs fail `authority_changed`, even when an unchanged
model hash would otherwise permit a target match. No repeated hash or silent
substitution of a new feed occurs in the same read. This makes all variable
feed-derived economics/template values traceable to the actual bound inputs.

Actual final runtime/admission/discovery/recovery observations are still refreshed.
They may change while hashing; a newly enlarged shape still fails final size or
identity checks, never readiness publication. Preflight guarantees rejection
before hashing for an oversized **stable already-observable state**, not a
prediction of future coordinator or journal changes. Do not require unstable
status timestamps to remain byte-identical merely to make the proof easier.
If a final shape falls outside the prepared sizing envelope, fail the read
explicitly with the existing capacity/authority/incomplete classification; it
cannot publish a result relying on an obsolete upper bound. No auto-retry loop.
This retains the distinction between deterministic existing overflow and real
state changes during a long observation.

## 6. Required acceptance evidence

| ID | Actual exercised behavior and required result |
|---|---|
| CC-01 | Valid active index with missing primary; deletion after initialization and before evidence; malformed/unsafe/unreadable active primary; undecidable required generation/provenance. Actual owned quick and verify-preflight emit no complete projection and no false empty recovery. Verify measures zero artifact bytes. A complete valid no-obligation control still emits `[]`. |
| CC-02 | Abandoned started evaluation with valid original evidence and real retained staging. Actual verified action lookup/reconciliation discovers the obligation. Final document contains its exact recovery, or the read explicitly fails; never a completed empty list. Include a transition after initial inventory, not only a preterminal fixture. |
| CC-03 | During the last optional reservation/recommendation lookup, introduce a cleanup obligation or change an excluded active primary without changing active-index membership. Final witness invalidates/recollects under the same deadline or fails. Verify no old/new recovery merge and no automatic journal rollback. |
| CC-04 | Inject one monotonic clock/cancellation view into each nested recommendation/reconcile bulk capture, binding recovery, staging check and precommit boundary. Expiry immediately before the commit permits no commit; no later complete document/action. Assert the original request and caller helper deadlines were not renewed. Separate IO/closed-decode failures propagate rather than become absent recommendation. |
| CC-05 | Positive actual action/recovery lookup with shared budget, live-owner stable unavailability, absent pointer and valid original committed recommendation. Existing standalone result/reconcile tests remain passing with their documented defaults. No relaxed original binding or lineage checks. |
| CC-06 | Actual accepted coordinator statuses with long and escaped event/time fields below 64 KiB each response, plus coordinator-authorized trusted economics. Near-limit complete projection succeeds when encoded below the supported bound; stable over-limit projection fails preflight with measured hash bytes zero. Assert actual status fetch/validation and production field construction, not a manually smaller preview. |
| CC-07 | Full encoder matrix: current catalog; maximum accepted signed shapes under current parser rules; 1,024 active entries with same-target dedup and representable distinct cleanup targets; maximum escaping/closed action fields. Record actual row/recovery counts, template/final bytes and wall time. At least one high-count complete positive below 1 MiB is mandatory; overflow-only evidence is insufficient. Include exact line boundary/newline and 2 KiB-margin tests. |
| CC-08 | Change candidate/artifact/rate/demand bytes, signer, version or trust/freshness independently during hashing while retaining the exact model hash where possible. Each invalid binding fails without a second hash/ready completion. Unchanged signed inputs with current accepted admissions succeed. |
| CC-09 | Actual status/recovery shape grows only after successful preflight. Final output fails closed or remains inside the validated template bound, retaining pending custody. Distinguish this from stable oversized-state rejection before hashing. Inject expiry before final encoding as well. |
| CC-10 | Actual app/CLI bridge still proves parsed quick/verify/result argv, distinct clean-install/missing-target/recovery cases, prepare/evaluate terminal plus >20-second verification, and pending retention/clear gates. Repeat relevant targeted/broader suites and final independent combined audits, zero C/H/M. |

Report measured accepted capacity, not a universal row count or disk guarantee.
A supported input whose required complete scan cannot finish remains explicit
unavailable under the finite budget. Do not shrink fixtures, truncate records,
skip recommendation/recovery lookups, remove accepted signed authority, or
lengthen limits to manufacture success. If a required release shape cannot meet
its supported outcome, reopen the capacity/representation contract explicitly.

## 7. Ownership and normative amendment

Root owns `ModelCatalogReadCommand`, request/phase orchestration, actual admission
preflight fetch, full sizing variants, final signed-input comparisons, normative
SPEC-001/SPEC-044 amendments and integrated verification. The retention owner
owns complete inventory evidence/witnesses, recommendation/reconcile budget
plumbing and strict error propagation, coordinated with root for
`ModelCatalogTransactions.swift`. No retention scheduling/capacity change is
included. The inspection owner changes only a needed shared-check interface if
root assigns it; the single descriptor-backed hash remains intact. The app/bridge
owners provide pending/actual argv and long-read acceptance evidence.

After independent plan approval, explicitly clarify SPEC-044's existing
all-or-error recovery wording to require every active primary to be decidable
and final recovery evidence to remain valid after action-side reconciliation.
Clarify its shared-budget wording to cover the complete nested chain and its
preflight wording to include actual current admission/economics fields and
sizing-only future local-action variants. Explicitly extend the relevant signed
feed binding to all four signed selections and preserve final current observation
and output checks. SPEC-001 refers to this refined owned-read contract.

These are material normative clarifications/strengthening for the unpublished
protocol-2 implementation, requiring review before code. There is no wire version
bump, new field/enum, new arbitrary string/capacity limit, longer timeout,
production authorization change or weakened operator compatibility. Authoring
this proposal is the only change in this lane; no runtime edit, test execution,
service action or independent approval is claimed.
