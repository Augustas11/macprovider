# Build 1 catalog read completeness addendum r2

Date: 2026-09-10. Status: **AUTHOR PROPOSAL — NOT APPROVED FOR IMPLEMENTATION**.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.

This is a bounded proposed correction to the approved catalog read lifecycle r2
contract, SHA-256
`e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`.
It addresses all four Medium findings in the preliminary native Astra CLI review,
`reviews/catalog-read-cli-preliminary-r1-astra.md`, SHA-256
`fb0ffa38641044059113efffd6f546739db37436a79c0d3b54832bfa8c0edb70`.

Revision r2 resolves all three Medium findings in the independent Sol review of
r1, `reviews/catalog-read-completeness-r1-sol.md`, SHA-256
`6e6028e0bb168f67c201570af857e8c035116622aae879c6c47c86e22c03f33f`.
The rejected r1 remains immutable. This revision replaces projection-plus-margin
sizing with a fully framed production completed-event preflight, closes both
suppressed completed-evaluation index paths and every pointer publication failure
class, and makes CC-01–CC-10 explicitly additive to lifecycle CR-01–CR-13 with
closed fresh-evidence requirements.

Independent review of this exact r2 proposal must return zero Critical/High/Medium
before these runtime corrections. The preliminary review, the r1 review and any
existing green tests do not constitute implementation acceptance. The existing
final combined code/security/architecture gate remains required.

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
  unbudgeted `load`/binding/result helper paths. Both the recovered-success and
  terminal-commit paths suppress `indexCompletedEvaluation` errors. A top-level
  read-budget check does not cover these nested reads or commits (CR-CLI-M3).
- `ModelCatalogReadOutput.preflight` currently inflates actions in a projection
  built with empty admission statuses. Actual current admissions are obtained
  only after hashing. The builder can then populate variable admission strings
  and economics omitted from the preview. The preview also does not encode the
  completed event's repeated `target_model_id` and `model_key` fields (CR-CLI-M4).

Preserve the exact option/FD protocol, read request ownership, same captured
config, 10/1,800-second total and phase/stall limits, one exact-target hash,
64 KiB stderr/8 MiB stdout/1 MiB JSONL/4,096-event limits, 2 KiB conservative
capacity reserve, independent deadline monitor and final full output check. No
new dependencies, private-key handling, service deployment, admission grant,
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

## 3. Original budget and index truth through the whole call chain (CR-CLI-M3)

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

Both current `indexCompletedEvaluation` suppression sites are in scope: the call
after `recoverBoundEvaluationSuccess`, and the call after a new successful
terminal commit. For an owned projection, neither may catch, print a diagnostic
and return a recommendation-absent result. Each must propagate failure after the
ordinary durable state has been left intact. This applies to every publication
class: active primary/index/result/provenance or previous-pointer read failure;
missing bytes; closed-decode or semantic/binding failure; pointer-directory
metadata, safe-open or creation failure; active-receipt/index/provenance/result/
previous-pointer validation or source change before write; budget/cancellation
expiry at the pre-write boundary; atomic pointer write, rename or durability
failure; readback/closed validation failure; and expiry or injected failure after
the exact pointer becomes durable but before this read acknowledges it.

The publication helper must expose enough outcome to distinguish **no pointer was
durably published** from **the exact pointer may or did become durable but this
read could not validate/acknowledge it**. In both cases the current owned read
fails incomplete and emits no completed projection. It must not report nil
recommendation, `measured_recommendation_required`, false pointer absence or a
false empty recovery. If the exact pointer became durable, do not delete or roll
it back to manufacture pre-write state; preserve that durable truth for the
ordinary bounded pointer validation/recovery path on a later request. A retry may
accept it only after complete validation under that later request's own original
budget. This adds no new pointer trust or persisted read cache.

For projection use, nil recommendation means a complete validated lookup found
no current eligible recommendation, for example no context pointer established
by a complete safe observation, or an existing fully observed nonterminal live
owner. It must not mean failure to read/decode/reconcile an active record or to
publish/validate a pointer. Remove projection-mode `try?` and catches that merely
check the budget then continue on arbitrary errors. A lock held by a positively
observed live owner can retain the existing unavailable-action policy when its
record is readable and no reconciliation is authorized. Missing or corrupt
evidence, unexplained contention/change, cancellation, time/IO limits and indexing
failures propagate incomplete. Preserve specific stable semantic ineligibility
where already defined; do not collapse all exceptions into it. The independent
process deadline remains a second boundary, not a substitute for these cooperative
checks or proof that post-expiry mutations are permitted.

## 4. Recovery remains complete after optional action work (CR-CLI-M2)

Use this order for quick/final verified publication, under the original budget:

1. Finish the existing recommendation reconciliation/index preparation that the
   eventual action lookup may need for every signed primary target that can enter
   the projection. This is journal evidence recovery using original bindings,
   not an available action, model hash, recommendation execution, or new mutation
   owner. The verify preflight must also account for a selected target that will
   become evaluable only after hashing; do not postpone its deterministic
   abandoned-evaluation reconciliation merely because quick inspection is
   currently unverified.
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
to revalidate every active primary, including excluded nonterminal/non-cleanup
entries, exact active membership and applicable provenance. Retain compact
placement/metadata/digest witnesses, not all 1,024 maximum-size primary JSON
bodies or decoded event histories. Reuse existing receipt/descriptor identity
rules and bounded metadata checks; no persisted readiness or recovery cache.
Transient decoding may release each body before the next entry. Final locked
uses validate the actual pinned index and compact evidence metadata only; no
bulk reads/decodes under the lock. If a necessary witness cannot be retained or
validated within existing limits, the read is incomplete. This proposal does not
promise that 1,024 four-MiB primaries finish inside ten seconds.

For publication, no journal-mutating helper runs after the final inventory/action
witness check. Index/primary/provenance changes invalidate the applicable evidence;
a stable index alone is insufficient because primary updates need not change
index membership. Source-changed recapture is bounded by the original deadline
and existing contention policy, not a new per-entry retry budget. Final output
size and config/artifact placement checks remain mandatory. These are coherent
observations within a finite window, not a guarantee that another owner can
never change state after emission.

## 5. Fully framed event preflight and signed-input binding (CR-CLI-M4)

### Observed field constraints

`BYOMModelAdmissionClient.maxStatusResponseBytes` is 64 KiB for a complete status
response. `BYOMAdmissionStatusValidator` closes the object/enums and checks
provider/candidate/guidance relationships, but imposes no individual length
limit on `coordinator_event_id` or `state_observed_at`; the economics builder
copies both strings. Therefore neither a short timestamp assumption nor a fixed
margin bounds all accepted admission shapes. A valid status below its existing
total transport cap can contain a long/escaped projected string.

`RateCardProjection.validated` restricts rate model keys to at most 128 ASCII
scalars and requires the rate version to equal its projection hash; its numbers
are checked for the existing nonnegative/finite/share rules. The candidate
validator requires exact 40/64-character revision/artifact hashes for applicable
rows, but these rules do not impose the same cap on all model IDs, catalog
versions, display strings or historical cleanup targets. The active index limit
is 1,024; a primary can be up to 4 MiB with up to 2,048 events. These are input
and work limits, not proof that any particular projection fits the 1 MiB line.

No new wire string/row limit is proposed. In particular, do not allocate 64 KiB
of hypothetical admission padding to every row, clip strings, reject formerly
valid names by an invented limit, or omit economics/recoveries to fit. Count the
actual accepted strings with the actual encoder. Existing parser/transport bounds
remain intact. Because some accepted signed strings are not individually bounded,
acceptance evidence uses finite boundary-constructed valid inputs and reports
their actual encoded sizes; it does not claim a nonexistent finite “maximum
accepted signed shape.”

### Pre-hash preparation

Load the actual current discovery, runtime and admission observations before
hashing, using the same captured config and same request budget. Use a budgeted
owned admission fetch path with checks before/after each await; a request budget
failure must not disappear inside the current best-effort `try?` loop. Existing
explicit local-only absence of configured provider/coordinator/credentials can
remain unavailable admission under its approved local-default rules. An actual
accepted coordinator status must be included, not replaced by `[:]` for sizing.

Prepare reconciliation as section 4 describes and capture complete current
cleanup identities without reserving actions for an estimate. Build a sizing-only
complete projection from the real production row/field constructors, including
actual admission strings, exact bound model/display/action IDs, current full
warnings, all current recovery identities and all economics fields that can
appear for the eventual verified target. For optional economics that can become
populated, calculate their concrete values with the same bound rate/demand/
candidate inputs and builder conversion rules even when the current admission
does not expose them. This is an in-memory size template, never a wire permission/
admission/readiness assertion. Do not synthesize trusted status for publication
or bypass its validation to produce the estimate.

Take the real encoded maximum among eligible closed state/action/nullable-field
variants. The projection template must cover exact fixed UUID/generation lengths,
longest applicable closed reason/runtime/verification strings, booleans, numeric
values, rate keys/version/time, known demand/supply values, warning collections
and every captured variable string. All feed-derived numeric values use the
actual converters/encoder. Do not rely on a guessed number of bytes per row or
assume filling a field is always larger than its unavailable representation.

The preflight then constructs and encodes the full prospective
`model_catalog_read_event.v1` **completed** line through the same production event
encoder and newline framing used by emission. It includes the exact read request
UUID; exact selected outer `target_model_id` and `model_key`; schema and completed
kind; maximum applicable completed `event_sequence` under the 4,096-event cap;
maximum-width applicable `bytes_completed`; null `error_code`; and the sizing
projection. This deliberately counts the outer escaped target/key copies in
addition to every occurrence inside projection rows, actions, recoveries or
economics. The terminating newline is one byte of the measured line. The raw
wire rule remains `encoded completed event + newline <= 1,048,576` bytes.

Retain the lifecycle r2 2 KiB conservative capacity reserve as an **additional**
pre-hash growth allowance: the already fully framed sizing line must be at most
`1,048,576 - 2,048` bytes. The reserve is never a proxy for an omitted event
field, repeated identifier, escaping, sequence/byte width, timestamp, nullable
variant or newline. Final publication encodes the actual full event again and
enforces the raw 1 MiB line limit plus the existing 8 MiB total stdout limit.
No arithmetic may wrap when calculating either threshold.

The static-input binding must include selected candidate, artifact, rate and
demand **bytes, signer identity, effective version and trust/fallback class**,
not only the chosen candidate/artifact identity. Re-fetch all four after hashing
as already required for final current authority. Require those bindings and
current freshness/validity to match before using the template/result; changed
or expired signed inputs fail `authority_changed`, even when an unchanged model
hash would otherwise permit a target match. No repeated hash or silent
substitution of a new feed occurs in the same read. Compare every authorization-
relevant warning/trust classification, including integrity/update-required
fallback distinctions that can share the same baked bytes.

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

## 6. Required additive acceptance evidence

CC-01–CC-10 are mandatory additions to, and do not replace, any part of lifecycle
r2 CR-01–CR-13 at SHA-256
`e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`.
Implementation is incomplete unless every CC and every CR has passing evidence
against the same final landing diff and source manifest. One test may satisfy
multiple mapped IDs; do not duplicate unchanged test logic merely to create a
new name. A prior log from a different source manifest is historical evidence,
not a passing result for this gate.

| ID | Actual exercised behavior and required result |
|---|---|
| CC-01 | Valid active index with missing primary; deletion after initialization and before evidence; malformed/unsafe/unreadable active primary; undecidable required generation/provenance. Actual owned quick and verify-preflight emit no complete projection and no false empty recovery. Verify measures zero artifact bytes. A complete valid no-obligation control still emits `[]`. |
| CC-02 | Abandoned started evaluation with valid original evidence and real retained staging. Actual verified action lookup/reconciliation discovers the obligation. Final document contains its exact recovery, or the read explicitly fails; never a completed empty list. Include a transition after initial inventory, not only a preterminal fixture. |
| CC-03 | During the last optional reservation/recommendation lookup, introduce a cleanup obligation or change an excluded active primary without changing active-index membership. Final witness invalidates/recollects under the same deadline or fails. Verify no old/new recovery merge and no automatic journal rollback. |
| CC-04 | Exercise both `indexCompletedEvaluation` call sites: after recovered committed success and after new terminal commit. At each site inject, separately, result/provenance/active-primary/index/previous-pointer read or closed-decode/semantic failure; pointer-directory metadata/safe-open/create failure; pre-write source validation/change and budget expiry; pointer atomic write/rename/durability failure; post-write readback/validation failure; and expiry/failure after the exact pointer is durable but before acknowledgement. No case emits a completed projection, absent recommendation, `measured_recommendation_required` caused by the failure, or false empty recovery. A durable exact pointer remains present for a later ordinary bounded validation/recovery; it is not rolled back or trusted without validation. Count original request, phase and incoming helper deadlines at every boundary and prove none was renewed. |
| CC-05 | Positive actual action/recovery lookup with shared budget, live-owner stable unavailability, completely observed absent pointer and valid original committed recommendation. Existing standalone result/reconcile tests remain passing with their documented defaults. No relaxed original binding or lineage checks. Nil recommendation occurs only for the specified complete semantic absence/ineligibility cases. |
| CC-06 | Actual accepted coordinator statuses with long and escaped event/time fields below 64 KiB each response, coordinator-authorized trusted economics, and long/escaped signed target/key values. Include a stable case whose projection-plus-2-KiB estimate fits but whose fully framed completed line exceeds the preflight ceiling; it fails before hashing with measured artifact bytes zero. Near-limit accepted full-event cases use actual status validation and production field/event construction. |
| CC-07 | Full production encoder matrix using finite boundary-constructed valid signed inputs: current catalog; 1,024 active entries with same-target dedup and representable distinct cleanup targets; escaping-heavy closed action/admission/feed fields; outer target/key repeated inside the projection; maximum applicable sequence/byte widths; and newline framing. Record rows, recoveries, projection bytes, full framed line bytes, reserve calculation, final bytes and wall time. Exercise one byte below, exactly at and one byte above both the `1,048,576 - 2,048` preflight ceiling and raw 1,048,576-byte line limit without arithmetic wrap. At least one high-count complete positive below the preflight ceiling is mandatory; overflow-only evidence is insufficient. |
| CC-08 | Change candidate/artifact/rate/demand bytes, signer, version or trust/freshness independently during hashing while retaining the exact model hash where possible. Change authorization-relevant warning/fallback classification independently as well. Each invalid binding fails without a second hash/ready completion. Unchanged signed inputs with current accepted admissions succeed. |
| CC-09 | Actual status/recovery shape grows only after successful preflight. Final output fails closed or remains inside the validated fully framed template bound, retaining pending custody. Distinguish this from stable oversized-state rejection before hashing. Inject expiry before final full-event encoding and after encoding before emission acknowledgement. No repeated hash or stale-template publication. |
| CC-10 | The actual app/CLI bridge proves parsed quick/verify/result argv, distinct clean-install/missing-target/recovery cases, prepare/evaluate terminal plus >20-second verification, and pending retention/clear gates. Execute the closed CR/CC evidence matrix in section 7 against the final source manifest, including every named fresh rerun and final independent combined audits at zero Critical/High/Medium. No “relevant suite” substitution or omitted lifecycle CR is permitted. |

Report measured accepted capacity, not a universal row count or disk guarantee.
A supported input whose required complete scan cannot finish remains explicit
unavailable under the finite budget. Do not shrink fixtures, truncate records,
skip recommendation/recovery lookups, remove accepted signed authority, or
lengthen limits to manufacture success. If a required release shape cannot meet
its supported outcome, reopen the capacity/representation contract explicitly.

## 7. Closed lifecycle/addendum evidence and fresh reruns

The final implementation report must contain one row for every CR-01–CR-13 and
CC-01–CC-10. Each row records: exact ID; test name or physical scenario; exact
command; exit status; selected/executed/skipped counts; sanitized log path and
SHA-256; produced artifact path and SHA-256 when applicable; tested commit/tree
and source-manifest digest; and the assertion/result. Zero-selected, skipped,
interrupted, stale-manifest and historical-only rows fail the gate.

The corrected read orchestration, event framing, recovery witnesses and shared
budget/index publication paths directly impact lifecycle CR-01, CR-03, CR-07,
CR-08, CR-09, CR-11 and CR-12. Run those seven cases fresh after the last
completeness implementation edit, in addition to CC-01–CC-10. CR-10's targeted,
full-suite and three-lane audit evidence must also be fresh against the complete
landing diff. CR-02, CR-04, CR-05, CR-06 and CR-13 remain mandatory regression
cases and must run once against that same final source manifest; their existing
test bodies need not be duplicated. Thus all thirteen lifecycle cases have fresh
final-manifest evidence, with the directly impacted seven explicitly rerun after
the last completeness edit rather than satisfied by an earlier lifecycle run.

| Lifecycle ID | Additive CC coverage | Required final-manifest evidence and rerun reason |
|---|---|---|
| CR-01 | CC-01, CC-02, CC-05, CC-10 | Fresh impacted rerun of the actual app argv → parsed CLI → owned quick/verify path, including complete recovery/action output and no false absence. Preserve the unchanged argv artifact. |
| CR-02 | CC-10 | Fresh final-manifest compatibility/parser regression for every supported/unsupported matrix row and forbidden override. No helper is spawned on unsupported branches. |
| CR-03 | CC-01, CC-05, CC-07 | Fresh impacted verifier-read accounting: quick/preflight failure reads zero artifact bytes, verified target hashes once, and shared projection/action consumers do not rehash. |
| CR-04 | CC-10 | Fresh final-manifest owned-child timeout/reap/late-output regression. Completeness work must not loosen single-flight or child ownership. |
| CR-05 | CC-04, CC-09, CC-10 | Fresh final-manifest progress/stall/slow-read regression with original total deadline; publication checks cannot renew it. |
| CR-06 | CC-10 | Fresh final-manifest parent-death/read-lock/transaction-control independence regression for supported and unsupported matrix branches. |
| CR-07 | CC-03, CC-08, CC-09 | Fresh impacted mutation/placement/config and all-four-signed-input authority binding rerun through final observation and emission. |
| CR-08 | CC-06, CC-07, CC-09 | Fresh impacted production JSONL encoder/parser boundary rerun, including fully framed completed line, newline, raw per-line/total limits, trailing data and final overflow. |
| CR-09 | CC-01, CC-02, CC-03, CC-04, CC-05, CC-09, CC-10 | Fresh impacted prepare/evaluate/cancel/cleanup terminal and pending-clear journey with pre-action and final complete inventories plus both successful-index publication paths. |
| CR-10 | CC-10 | Fresh targeted Swift/Xcode commands, full Swift/app suites, and final combined code/security/architecture reviews over the complete landing diff; record exact command/status/count/log hashes and require zero C/H/M. |
| CR-11 | CC-01, CC-06, CC-07, CC-09 | Fresh impacted finite encoder-capacity matrix with high-count positive, full-event preflight boundary, raw line boundary, zero-byte early rejection and pending preservation. |
| CR-12 | CC-01, CC-02, CC-03, CC-04, CC-05, CC-09 | Fresh impacted single-budget matrix across complete inventory, action/recommendation reconciliation, both index-publication sites, post-action recapture and final emission. |
| CR-13 | CC-10 | Fresh final-manifest real status advertisement/manifest capability/no-spawn regression; no version-only authorization or fabricated release identity. |

The final report must also give the reverse CC mapping below so no new case can
be declared complete by citing an unrelated broad suite:

| Addendum ID | Lifecycle cases that remain jointly required |
|---|---|
| CC-01 | CR-01, CR-03, CR-09, CR-11, CR-12 |
| CC-02 | CR-01, CR-09, CR-12 |
| CC-03 | CR-07, CR-09, CR-12 |
| CC-04 | CR-05, CR-09, CR-12 |
| CC-05 | CR-01, CR-03, CR-09, CR-12 |
| CC-06 | CR-08, CR-11 |
| CC-07 | CR-03, CR-08, CR-11 |
| CC-08 | CR-07 |
| CC-09 | CR-05, CR-07, CR-08, CR-09, CR-11, CR-12 |
| CC-10 | CR-01, CR-02, CR-04, CR-05, CR-06, CR-09, CR-10, CR-13 |

This mapping supplements test-spec-r4, SHA-256
`20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be`.
B1-T01–B1-T14 remain mandatory and unchanged. The catalog completeness work does
not qualify production identity, physical MLX execution, remote admission,
routing or settlement. The physical B1-T10 journey and its stated hardware/
signing blockers remain separate release evidence and cannot be replaced by the
CC/CR fixture matrix.

## 8. Ownership and normative amendment

Root owns `ModelCatalogReadCommand`, request/phase orchestration, actual admission
preflight fetch, fully framed production event sizing, final signed-input
comparisons, normative SPEC-001/SPEC-044 amendments and integrated verification.
The retention owner owns complete inventory evidence/witnesses, recommendation/
reconcile budget plumbing, both `indexCompletedEvaluation` suppression removals,
durable-publication outcome handling and strict error propagation, coordinated
with root for `ModelCatalogTransactions.swift`. No retention scheduling/capacity
change is included. The inspection owner changes only a needed shared-check
interface if root assigns it; the single descriptor-backed hash remains intact.
The app/bridge owners provide pending/actual argv and long-read acceptance evidence.

After independent plan approval, explicitly clarify SPEC-044's existing
all-or-error recovery wording to require every active primary to be decidable and
final recovery evidence to remain valid after action-side reconciliation. Clarify
its shared-budget wording to cover the complete nested chain and both completed-
evaluation index sites. Clarify its preflight wording to require the actual fully
framed completed event, repeated outer identifiers and newline, with the 2 KiB
reserve additional to measured content. Explicitly extend the applicable signed
feed binding to all four signed selections and preserve final current observation
and output checks. SPEC-001 refers to this refined owned-read contract.

These are material normative clarifications/strengthening for the unpublished
protocol-2 implementation, requiring review before code. There is no wire version
bump, new field/enum, new arbitrary string/capacity limit, longer timeout,
production authorization change or weakened operator compatibility. Authoring
this proposal is the only change in this lane; no runtime edit, spec edit, test
execution, service action or independent approval is claimed.
