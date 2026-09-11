# Build 1 preparation/reservation adversarial plan gate v10

Date: 2026-09-12
Reviewer: independent native `gpt-5.6-sol` subagent, high reasoning
Disposition: **PASS — 0 Critical, 0 High, 0 Medium**

## Exact review inputs

- Repository/base revision: `f7e584499828b3d16036382848b5caa1a897cdf9`.
- Planning worktree revision: `40421e535e1dbf79a80f0246dd5fb1c0ac085644`.
- Plan: `reservation-rebaseline-plan-v15.md`, SHA-256
  `6181a7646cde522883710283c64fd33a6522408a5a5add74f2eb5d61ba7ada84`.
- Test specification: `reservation-rebaseline-test-spec-v15.md`, SHA-256
  `17bcd6d7ff7ffdc3ed1f4e4230b4c969d19cd4e7645ca5ceae4d1742a167a7f6`.
- Authority candidate reviewed through:
  `922624a7959253aae0581c6e2db22f827925072b`.
- Blocking v9 review input: commit
  `fa71b09c6bdcc0478a211435849cccc8c13b4460`, artifact SHA-256
  `75cec387364175b67559eb81fb4322f97de423befaa5997d066e741dd002e5b8`.

The candidate revision is a child of the v9 review commit. I reviewed authority
only through the candidate revision. I did not treat future implementation,
merge, hardware, signed release, or production evidence as already present.

## Severity counts

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Informational | 0 |

## Blocking findings

None. I found no Critical, High, or Medium defect in the exact v15 plan/test
bytes or in the authority candidate that would make the described implementation
infeasible, weaken a trust boundary, create an unproved economic claim, make the
UX materially false, or leave a required acceptance claim without an adequate
future proof.

## v9 finding disposition

### B1-AUTH-V9-H1 — closed

**Prior evidence.** The v9 review showed that the shipped CLI advertises three
generation-specific economics values, while the then-current plan described an
exclusive two-value pair. The checked-in manifest requires
`model_catalog_economics_v1` in `local_status_capabilities` and both
`models catalog-economics.v1` and `model_catalog_economics.v1` in
`command_schemas`
(`phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json:16-20`).
The CLI's flat status contains the same three values
(`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:238-248`), and current
Malibu checks the union of all tier categories against fresh status
(`phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:64-78`).

**Correction verified.** SPEC-044-R001 now defines distinct categorized
manifest and flat-status grammars, requires the same-generation three-member
trio, prevents the schema companion from selecting alone, permits separate
complete v1 and v2 manifest tiers, scopes unknown-value fatality to three exact
reserved prefixes, tolerates unrelated values, and assigns every negotiation
failure the silent static-card result (`SPEC-044:94-100`). SPEC-001-R003 repeats
the same category placement, flat-status exclusivity, staged upgrade behavior,
and warning boundary (`SPEC-001:3332-3454`). Plan v15's compatibility matrix
matches that authority (`plan-v15:75-89`), and T01/T14/T15/T18 require the real
manifest/status loaders, built CLI boundary, both upgrade orders, byte-level
member removal/addition/misplacement/mixed/stale/disagreement cases, and the
distinction between silent negotiation fallback and a negotiated request that
later fails (`test-v15:35-66, 308-430, 475-488`).

The committed fixture
`scripts/tests/fixtures/catalog_economics_compatibility_v2.json` carries current
v1, combined v1/v2, and v2-only manifests; current v1 and v2 flat statuses; all
four required upgrade-order cases; and 33 one-fault mutations. Its executable
contract test verifies category placement and exact current shipped bytes
(`scripts/tests/test_byom_contract_lock.py:11-181`). That closes the prior
compatibility ambiguity without deleting the shipped companion or silently
changing the public command spelling.

**Consequence after correction.** Current Malibu/current CLI selects v1; new
Malibu/old CLI selects v1; current Malibu/new v2-only CLI performs no call and
shows the static card; and new Malibu/new v2 CLI selects v2. A malformed or
ambiguous advertisement cannot launch a read or mutation. A valid selected read
that subsequently fails produces the one truthful unavailable warning and no
action/economics.

## Cumulative prior-finding dispositions

| Finding(s) | Disposition and evidence |
|---|---|
| B1-AUTH-V8-M1 | **Closed.** The plan ownership table and T18 give a failure-only worker and direct cancel the bounded `failure.lock` then `cancel.lock` pair while keeping their mutation scopes distinct. T01/T03/T12/T14 reject single-lock, inverted, or widened authority. |
| B1-AUTH-V7-H1 | **Closed.** SPEC-044 and the plan have one exhaustive acyclic graph for projection, failed dispatch, normal state/history, startup recovery, cancellation, cleanup, marker polling, and adoption. Cleanup and failure locks never overlap. |
| B1-AUTH-V7-H2 | **Closed.** Every failed-dispatch pending/history writer and every cancel-visible read shares `failure` then `cancel`; copy-before-delete replacement and exact terminal-at-linearization behavior prevent an unseen terminal gap. |
| B1-AUTH-V7-M1 | **Closed.** Dispatch and direct-cancel pair acquisition each use one total `CLOCK_MONOTONIC_RAW` two-second deadline, release partial custody/resources, and make no fairness or starvation-free claim. |
| B1-AUTH-V6-H1 | **Closed.** Negotiation negatives are silent static-card/no-call outcomes. `projection_unavailable` and retry exist only after one valid selected generation launches a read that fails, times out, or returns a malformed envelope. |
| B1-AUTH-V6-H2 | **Closed.** Immutable projected-action identity precedes a fresh prospective attempt. Semantic rejection attaches through one bounded non-live failed-dispatch record before a sequence-1 terminal event; pre-attachment lock timeout instead has exact stderr, empty stdout, no event, exit 5, and no mutation. |
| B1-AUTH-V6-M1 | **Closed.** Forward-current authority is SPEC-001 v1.9.17 and SPEC-044 v0.2.8 across the spec header, CONFORMANCE, generated index, handoff, plan, tests, and contract locks. Older versions occur only in historical change/review context. |
| B1-AUTH-V6-M2 | **Closed.** T09.6/T10/T16 mutate both cleanup action copies independently, every closed field, both copies together, enclosing digest/size, and cross-target identity before confirmation or mutation. |
| B1-AUTH-V5-H1 | **Closed.** The exact `local_only` meaning is admission-only across SPEC-001/046, handoff, plan, and tests; installation/usability requires separate readiness/runtime evidence. |
| B1-AUTH-V5-M1 | **Closed.** A catalog-only sentinel can appear only in `Blocked`; one-fault placement in `Current`, `Ready`, `Network catalog`, or `Needs preparation` fails closed. |
| B1-AUTH-V5-M2 | **Closed.** `local_default:not_offered` means coordinator state is unavailable/unqueried; `coordinator:not_offered` reports no active current offer. Localization/accessibility/source-swap negatives prohibit history claims. |
| B1-AUTH-V5-M3 | **Closed.** Cleanup tests independently bind each nested action to the enclosing target and reject equal-two-copy and cross-target substitutions. |
| B1-AUTH-V4-H1 | **Closed.** SPEC-044-R005 is the sole exact locale-independent row-order oracle; v15 uses the same null directions, exact numeric comparisons, tagged length-prefixed canonical identity, and duplicate predicate. |
| B1-AUTH-V4-M1 | **Closed.** The catalog-only row has one exact `unavailable`/`none`/`local_default:not_offered` null/false/no-action sentinel, and each deviation is rejected. |
| B1-AUTH-V4-M2 | **Closed.** Admission-only local copy no longer asserts installed, ready, reachable, or usable state. |
| B1-AUTH-V4-M3 | **Closed.** RFC 8785 equality compares row action to target nested action; each copy separately binds the enclosing digest and size. |
| B1-AUTH-V4-M4 | **Closed.** All current owner and test surfaces freeze the same 12 admission values and reject a thirteenth; 13 presentation rows arise only because `not_offered` has two sources. |
| B1-AUTH-V3-H1 | **Closed.** Cleanup retains `cancel.lock` continuously from the final marker check through rename, parent barriers, durable `tombstoned`, and readback. Only the explicit post-crash cancel-first/recovery-first race remains. |
| B1-AUTH-V3-H2 | **Closed.** Exact settlement copy is conditional eligibility on qualifying settled requests and explicitly disclaims current income, traffic, demand, accepted work, or a settled receipt. |
| B1-AUTH-V3-H3 | **Closed.** Catalog-only rows have no candidate/guidance binding, trusted economics, rate/payout/demand values, or candidate action and cannot borrow another candidate's admission. |
| B1-AUTH-V3-M1 | **Closed.** New sensitive nodes start as already-open unpublished owner-only temps; inherited ACLs are stripped and verified empty before sensitive bytes, followed by descriptor revalidation. |
| B1-AUTH-V3-M2 | **Closed.** Direct cancel has a closed sixth `busy` outcome with null attempt, exact echo, bounded pair acquisition, no state read, no mutation, and exit 0. |
| B1-AUTH-V3-M3 | **Closed.** R005 and T15/T16 require a total stable order independent of locale, input order, or floating-point comparison. |

### v2 and v1 authority findings

| Finding(s) | Disposition and evidence |
|---|---|
| B1-AUTH-V2-H1 / B1-AUTH-H2 | **Closed.** The v9 correction supplies the exact three-member v1/v2 grammar and all staged app/CLI outcomes; no caller identity, timing, environment, or optimistic decoder selects the response schema. |
| B1-AUTH-V2-H2 / B1-AUTH-M1 | **Closed.** Coordinator `not_offered` supports exact response-bound null-event and event-backed forms, distinct from local-default unknown state, and remains reachable in the local preparation matrix. |
| B1-AUTH-V2-H3 / B1-AUTH-M4 | **Closed.** Direct cancel is marker-only; operation/cleanup/cancel-owning recovery implements reversible intent and durable readback-validated tombstone commit for published and staging cleanup. |
| B1-AUTH-V2-H4 | **Closed.** Root identity authenticates a secret nonce plus schema/version, canonical path, device, and inode; every reopening record saves the complete locator and rejects drift, copy, remount, replacement, and inode reuse. |
| B1-AUTH-V2-M1 | **Closed.** Candidate identity/guidance/binding is exactly all-null for catalog-only and all-non-null for candidate-associated/actionable rows. |
| B1-AUTH-V2-M2 | **Closed.** Every cleanup target retains receipt-bound immutable `event_model_key`, including current-catalog orphans, so existing non-null event correlation remains satisfiable. |
| B1-AUTH-V2-M3 | **Closed.** App-owned prelaunch generations order refreshes across late completion, timeout, CLI restart, and app restart without disturbing attached workers. |
| B1-AUTH-V2-M4 | **Closed.** Partial line, stderr, decoded queue, scheduled MainActor delivery, and aggregate retained process data all have fixed caps and explicit backpressure/terminal preservation tests. |
| B1-AUTH-V2-M5 | **Closed.** Empty extended ACL and descriptor-race policy is normative for every private component and has inherited/raced ACL tests. |
| B1-AUTH-H1 | **Closed.** V2 rows bind verbatim five-field guidance to candidate, exact source bytes/digest/time, sequence or coordinator event, admission source/state, and freshness; Malibu renders that owner verdict before economics. |
| B1-AUTH-M2 | **Closed.** Positive local preparation requires the current primary `mlx_safetensors` artifact and exact `verification_status: verified` at projection and dispatch. |
| B1-AUTH-M3 | **Closed.** Six cancel outcomes have exact first-match precedence, echo/nullability, marker semantics, exit behavior, and resource/mutation limits. |
| B1-AUTH-M5 | **Closed.** One descriptor-relative checked logical-byte algorithm drives managed, legacy, budget, preparation, and cleanup values while copy disclaims physical APFS recovery. |
| B1-AUTH-M6 | **Closed.** Bounded `cleanup_targets` contains every verified managed identity, including catalog orphans, with one protected or reclaimable action. |
| B1-AUTH-M7 | **Closed.** SPEC-001-R003, AUTHORITY consumer registration, CONFORMANCE pending entries, R005 gap, versions, generated indexes, handoff, and contract tests agree. |
| B1-AUTH-M8 | **Closed prospectively.** T14.1/T15/T19 require the built production CLI through Malibu's real manifest/status loaders, process adapter, decoder, refresh logic, and UI. Hand-built sets or `FakeModelCLI` alone do not count. |
| B1-AUTH-M9 | **Closed.** Default budget crossover/rounding, config precedence, invalid overrides, checked overflow, and exact budget/free-space byte boundaries are explicit. |
| B1-AUTH-M10 | **Closed.** Unavailable configured-legacy accounting blocks projected/direct preparation and published cleanup before side effects while incumbent serving continues. |
| B1-AUTH-M11 | **Closed.** CLI raw bytes remain authoritative; locale and accessibility tests cover decimal boundaries and non-Latin digits without recomputing or understating size. |
| B1-AUTH-M12 | **Closed.** The optional two-second cancellation claim has a precise clock start, supported hardware/phase/files/sync profile, 50 ms tolerance, and truthful functional behavior outside the profile. |
| B1-AUTH-M13 | **Closed.** Closed event warning/error enums and adjacent/multifault tables prove exact error, terminal, exit, and side-effect precedence. |
| B1-AUTH-I1 | **Retained as a limitation.** Structural and governance checks are mechanical evidence only; this verdict relies on independent code/spec/test inspection and does not claim implementation acceptance. |

No earlier Critical, High, or Medium finding was downgraded, omitted, or made
irrelevant by weakening an acceptance criterion.

### Earlier reservation-plan findings

| Finding(s) | Disposition and evidence |
|---|---|
| B1-V1-H1 | **Closed.** Slice 6A and hard Dependency Gate 5 require the complete operator-owned SPEC-001/SPEC-044 authority to land and pass exact-byte review before any 6B implementation. New public transaction behavior is no longer introduced under frozen or absent authority. |
| B1-V1-H2 | **Closed.** Custom/default artifact roots share the authenticated canonical locator/identity record; every durable reopening record saves the exact root, and T04/T05/T08/T21 cover config drift, remount, copy, replacement, and recovery. |
| B1-V1-H3 | **Closed.** Publication requires verified files/receipt, bottom-up synchronization, exclusive rename, destination-parent `fsync` plus `F_FULLFSYNC`, durable terminal persistence, and hardware/power qualification before success is claimed. |
| B1-V1-M1 | **Closed.** At most 64 prospective tuples use an exact locale-independent total order and deterministic rotation/eviction; contention and stale tuples fail before work. |
| B1-V1-M2 | **Closed.** The v3 namespace has checked byte and 256-object admission, complete bounded inventory, no automatic GC, and provider-confirmed cleanup for every reclaimable managed identity while legacy data stays protected. |
| B1-V1-M3 | **Closed.** The serial URLSession worker has a 250 ms marker/deadline watchdog, bounded callback acceptance, heartbeats, explicit timing profile, and functional no-premature-terminal rules outside that profile. |
| B1-V2-H1 | **Closed.** The exhaustive R002/R003 matrix now authorizes a reachable, strictly local `Prepare locally` action for verified candidate-associated non-trusted rows without conferring economics or admission. |
| B1-V2-M1 | **Closed.** Durable intent precedes destructive rename, and the readback-validated `tombstoned` phase after parent barriers is the only cleanup commit evidence; every crash/cancel ordering has an exact recovery result. |
| B1-V2-M2 | **Closed.** Unique self-identifying temps and atomic root bootstrap recover complete newer writes, remove validated incomplete temps, bound excess recognized temps, and fail closed on hostile or conflicting objects. |
| B1-V2-M3 | **Closed.** Only `accepted_application_bytes` and `staged_bytes` are normatively capped. Delegate/transport/server counts are explicitly observational and cannot falsely pass the byte-bound claim. |
| B1-V2-M4 | **Closed.** V3 inventory is namespace-only; configured legacy trees are descriptor-measured, protected, separately accounted, preserved across rollback, and never imported or deleted. |
| B1-V2-M5 | **Closed.** The attached worker exclusively sequences public events; direct cancel returns one separate bounded acknowledgement and mutates only an exact attempt marker under the serialized snapshot. |
| B1-V3-M1 | **Closed.** Count admission is a serialized production invariant: an exact existing identity is idempotent, a new 256th identity is allowed, a new 257th is refused before network/staging, and the check is repeated before exclusive rename. |
| B1-V4-M1 | **Closed.** Reading at most 257 entries proves only `count > 256`; current plan/authority call it detected overflow and do not assert the exact external cardinality. |
| B1-V4-M2 | **Closed.** Overflow disables preparation/cleanup for out-of-band diagnosis. No unapproved repair, truncation, guessing, or recovery product surface remains. |
| B1-V4-M3 | **Closed.** T18 pins the exact v15 plan/test digests, authority candidate, review lineage, governance bytes, and strict-ancestor condition; this review uses those exact inputs. |

The earlier informational conclusions also remain valid: the existing adoption
control frame can be retained because its serving handler independently reloads
authority and verifies root/receipt/hash, and no local plan or implementation
test substitutes for the final signed Build 1 qualification journey.

## Adversarial assessment

- **Feasibility and ownership:** the initiating process, same-EUID cancel
  process, fixed private state, prospective/attached attempt boundary, bounded
  history, and exhaustive lock graph form an implementable process model. Every
  nested order is acyclic, all waits with a product-facing liveness claim are
  bounded, and no PID or post-crash worker continuation becomes authority.
- **Trust and economics:** verified signed artifact evidence establishes only
  local preparation. Candidate/source/digest/freshness binding, per-candidate
  admission, signed rate-card authority, and settlement-capable admission remain
  independent. No provider assertion, local readiness state, catalog similarity,
  or preparation result grants pricing, routing, settlement, or credit.
- **UX truthfulness:** the source-aware no-offer meanings, admission-only
  `local_only` text, local preparation copy, conditional settlement eligibility,
  unavailable warning boundary, cleanup logical-byte copy, and accessibility/
  localization negatives prevent current-income, current-demand, readiness,
  physical-space-recovery, or prior-offer claims.
- **Failure recovery and security:** immutable projected identity, bounded
  failed-dispatch publication, copy-before-delete history, authenticated root
  locator, descriptor-relative no-follow traversal, ACL-empty temps, exact-marker
  cancellation, publish barriers, and reversible cleanup intents cover the
  challenged crash, race, substitution, and hostile-filesystem boundaries.
- **Compatibility and rollback:** v1 remains readable by new Malibu; v2-only
  CLI fails safely with old Malibu; dual/partial/mixed advertisements make zero
  calls; v3 state is ignored and preserved by rollback; configured legacy state
  is protected and never imported or deleted.
- **Observability and privacy:** planned records and logs are bounded and use
  redacted codes/counters. Provider identity, credentials, URLs/feed bodies,
  raw errors, prompts, completions, and public filesystem locators are excluded.
- **Proof strength:** T01-T20 separate authority/codec/unit/process/Xcode/full
  diff evidence, require the real built CLI-to-Malibu boundary, and reject
  zero-selected or fixture-only substitution. T21-T24 separately require real
  Apple Silicon/APFS/MLX, abrupt-power recovery, signed discovery/admission,
  routed receipt/settlement/positive credit, final signed/notarized assets,
  first-listed-tier proof, binary byte identity, and prior-stable updater proof.

## Current implementation and qualification boundary

The reviewed code remains the shipped v1 catalog path:
`ModelCatalogEconomics.swift` emits v1,
`HTTPServer.swift` advertises the v1 trio, and Malibu decodes v1. The candidate
does not contain the v2 preparation worker, cancellation acknowledgement,
failed-dispatch engine, v3 storage engine, or new Malibu UX. That is truthful
pre-implementation state rather than a finding.

This PASS approves the exact v15 plan/test and authority candidate for the
pre-implementation plan gate only. It does not satisfy Dependency Gate 5 until
the authority lands, does not satisfy the strict-ancestor check for the first
6B implementation commit, and does not satisfy T01-T24. If merge mechanics
change the authority commit or bytes, T18 must record the landed commit/digests
and the exact-input gate must be rerun before implementation descends from it.

Build 1 remains unqualified until the physical preparation/adoption journey,
signed discovery and network admission, an actually routed and receipted
request with correct settlement and positive provider credit, first-listed-tier
evidence, signed/notarized packaged CLI identity, and prior-stable updater proof
all pass. Preparation, deterministic fixtures, existing v1 tests, or this plan
review cannot substitute for those gates.

## Fresh validation evidence

All commands used authority bytes through candidate revision
`922624a7959253aae0581c6e2db22f827925072b`. Generated Xcode project files were
removed after the run, and Swift's `Package.resolved` rewrite was restored.

```text
git diff --check f7e584499828b3d16036382848b5caa1a897cdf9..922624a7959253aae0581c6e2db22f827925072b
=> exit 0

python3 scripts/gen_spec_index.py --check
python3 scripts/gen_spec_index.py --lint
python3 scripts/check_spec_governance.py
=> all exit 0; 47 canonical specs; index current; governance passed

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_byom_contract_lock
=> Ran 16 tests; OK

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  scripts.tests.test_spec_governance \
  scripts.tests.test_spec_pr_declaration \
  scripts.tests.test_byom_contract_lock
=> Ran 77 tests; OK

cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests|ProviderStatusTests'
=> XCTest: Executed 54 tests, 0 failures
=> Swift Testing separately reported 0 selected tests and is not counted

cd phase3-binary/app && xcodegen generate && xcodebuild test \
  -project Malibu.xcodeproj -scheme Malibu -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -only-testing:MalibuTests/ModelManagementTests
=> Executed 96 tests, 0 failures; TEST SUCCEEDED
=> Xcode also warned that optional CoreSimulator support was out of date; the
   named macOS destination still built and ran successfully

cd phase4-coordinator && go test ./internal/ws \
  -run 'TestModelAdmission(StatusForPreBYOMProviderReturnsNotOffered|OfferSubmitAndStatusStayNonEarning|StatusGuidanceForRejectedAndDemotion)$' \
  -count=1
=> ok
```

These results validate the current authority corpus and existing v1 regression
surface. They are not claimed as future v2 implementation, hardware, release,
admission, or settlement acceptance evidence.

## Gate result

**PASS: 0 Critical, 0 High, 0 Medium.** The exact approved inputs are plan v15
SHA-256 `6181a7646cde522883710283c64fd33a6522408a5a5add74f2eb5d61ba7ada84`,
test spec v15 SHA-256
`17bcd6d7ff7ffdc3ed1f4e4230b4c969d19cd4e7645ca5ceae4d1742a167a7f6`,
and authority candidate revision
`922624a7959253aae0581c6e2db22f827925072b`.
