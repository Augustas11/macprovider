# SPEC-013 v0.1 — Audit Report

**Audited:** SPEC-013 v0.1 (specs/SPEC-013-cli-autotune.md)  
**Auditor model:** Codex / GPT-5  
**Audit round:** 1 of N  
**Date:** 2026-06-18  
**Total findings:** 0 CRITICAL / 7 MAJOR / 11 MINOR / 2 QUESTION

---

## Executive summary

Verdict: **not ready to lock as drafted; v0.2 should close the MAJOR findings and get a narrow round-2 audit.**

SPEC-013 v0.1 preserves the locked product framing. I found no path where the main recommendation intentionally picks a smaller model over a larger feasible model, no cross-model max-tps objective, and no coordinator/billing/buyer-wire scope creep. FR-A.1/FR-A.2 are explicit that candidate-list order is the contract and that the first feasible model wins.

The blockers are contract precision and implementation fit. The largest issues are that fallback reporting contradicts the STOP-on-first-feasible pipeline, `--apply` writes config keys the current binary does not read, the `tune_trials.stage` migration is not SQLite-valid as written, and the recipe hash is not reproducible across implementations. The pre-download and launchd/drain surfaces also need tightening because they are day-one operator workflows, not edge cases.

Recommended next step: keep the two-stage architecture and biggest-fit objective intact, but draft SPEC-013 v0.2 with narrow fixes for the seven MAJOR findings below. The implementation-choice question in §10 can remain deferred to the implementing PR.

## Category A: Product framing preservation

### A.1  Fallback reporting contradicts STOP-on-first-feasible   [MAJOR]
Location: §3 lines 157-168; §5.6 FR-F.1 lines 541-559; AC-1/AC-2 lines 912-924

The main model-selection path correctly stops at the first feasible candidate, but the architecture and FR-F.1 say the recommendation includes every smaller candidate that also passed Stage 1 feasibility. Those smaller candidates are not probed after the chosen model, and AC-1/AC-2 correctly expect empty fallback lists when the loop stops before Z.

Why it matters: an implementer cannot satisfy both "STOP iterating models" and "list every smaller candidate that also passed Stage 1" without adding a second fallback-probing phase. That would change wall-clock, DB rows, and possibly the operator's interpretation of the recommendation.

Recommendation: v0.2 should either define fallbacks as "smaller candidates already evaluated before stop" (usually empty) or add an explicit optional fallback-probing phase that is outside the biggest-fit selection decision.

## Category B: Two-stage pipeline correctness

### B.1  Optional max-context axis lacks cell semantics   [MINOR]
Location: §5.2 FR-B.1 lines 353-358; §7 lines 878-880

FR-B.1 says the operator may pass `--max-context-axis` to opt into a small neighborhood, but it does not define whether values are absolute token caps, relative deltas around `--target-context`, sorted order, or whether cells below the target context are invalid.

Why it matters: the default single-cell path is clear, so this does not block v0.1. The escape hatch is still underspecified enough that two implementations could test different neighborhoods and produce different recipes for the same flags.

Recommendation: define `--max-context-axis` as an ordered comma-separated list of absolute token caps, require each cell to be `>= --target-context`, and state how invalid cells are rejected.

## Category C: Knob-axis correctness vs PR #105

### C.1  CLI summary drops the required unset kv-bits cell   [MINOR]
Location: §5.2 FR-B.1 lines 342-358; §7 lines 872-880; PR #105 body; `MacProviderCLI.swift` lines 67-74

The binding FR says the default kv-bits search is `{4, 8, unset}`, and PR #105 confirms unset maps to no `GenerateParameters.kvBits`. The CLI summary says `--kv-bits-axis <csv>` defaults to `'4,8'`, which omits the unquantized baseline.

Why it matters: §7 is non-normative, but implementers commonly start from the flag summary. If they follow it literally, Stage 2 never tests the PR #105 default path and cannot recommend the baseline.

Recommendation: make the summary match FR-B.1, e.g. default `unset,4,8`, and define how `unset` is represented in flags, JSON, SQL, and terminal output.

## Category D: Pre-download integration (FR-D)

### D.1  `models pull` is a larger missing precondition than the spec admits   [MAJOR]
Location: §5.4 FR-D.1 lines 444-479; §12 lines 1166-1169; `ModelsSubcommand.swift` lines 5-14; `ModelRuntime.swift` lines 559-566 and 622-641

SPEC-013 depends on `macprovider-cli models pull <id>`, but the current `models` subcommand only exposes list/switch/status/browse. The current runtime first checks the local HuggingFace snapshot path, then falls back to `LLMModelFactory.shared.configuration(id:)`; the code does not contain a locked "serve is HF-offline" contract or an existing download subcommand.

Why it matters: FR-D is on the critical path before every candidate. A "one-screen pull subcommand" understates the needed contract: cache target, online/offline behavior, gated repos, progress, cancellation, partial downloads, and exact failure classes all affect autotune correctness and privacy expectations.

Recommendation: either specify `models pull` enough for SPEC-013's needs, or split it into a prerequisite SPEC/FR with its own ACs. Also correct the offline-mode rationale to match the current binary behavior or make the offline requirement explicit.

### D.2  Signature mismatch is treated like a candidate-level miss   [QUESTION]
Location: §5.4 FR-D.2 lines 481-486

FR-D.2 groups network down, missing weights, signature mismatch, and disk full under the same "record candidate infeasible and advance" rule.

Why it matters: transient network and disk failures are plausibly candidate-local; a signature mismatch is security-relevant and may indicate cache corruption or supply-chain trouble. Continuing to smaller candidates could hide the stronger operator action needed.

Recommendation: operator should decide whether signature/hash/integrity failures abort the whole run while ordinary pull failures advance.

## Category E: Provider-conflict safety (FR-E)

### E.1  launchd service identity and restore semantics do not match SPEC-003   [MAJOR]
Location: §5.5 FR-E.1 lines 492-513; SPEC-003 §FR-C5 lines 415-478

SPEC-013 names the launchd-managed install as `com.macprovider.cli` and requires drain to restore plist state on exit. SPEC-003's launchd label/path are `live.malibu.provider` and `~/Library/LaunchAgents/live.malibu.provider.plist`, with `KeepAlive.SuccessfulExit = false`.

Why it matters: the common operator install path is launchd-managed. If the implementation looks for the wrong service label or does not define whether it uses `bootout/bootstrap`, clean SIGTERM, or a direct process handle, `--drain` can fail to stop the live provider or fail to restore it after tuning.

Recommendation: bind FR-E.1 to the SPEC-003 label/path and define the exact launchd drain/restore sequence. Add an AC that exercises the launchd-managed install path.

## Category F: Recommendation surface (FR-F) + JSON schema + recipe_hash

### F.1  `--apply` writes config keys the current binary does not read   [MAJOR]
Location: §5.6 FR-F.3 lines 644-670; SPEC-001 §FR-19 lines 693-705; `Config.swift` lines 229-252; `ServingKnobsConfigTests.swift` lines 61-100

FR-F.3 says SPEC-013 owns `model`, `kv_bits`, `max_context_tokens`, and `max_batch`. The current config loader reads `model` and `kv_bits`, but the PR #105 config keys are `max_context_override` and `max_concurrency_override`; tests confirm YAML uses those names.

Why it matters: `autotune --apply` would appear to succeed while leaving the recommended context and batch knobs unapplied. The next `serve` would read old/default values and run a different recipe than the recommendation block and JSON claim.

Recommendation: change the owned-key list and examples to `model`, `kv_bits`, `max_context_override`, and `max_concurrency_override`, or explicitly add a config-schema migration in the implementing PR.

### F.2  recipe_hash format and canonical JSON are not deterministic enough   [MAJOR]
Location: §5.6 FR-F.2 lines 632-642; AC-12 lines 1001-1007

The schema shows `"recipe_hash": "sha256:<32-byte-hex>"`, which is ambiguous because SHA-256 is 32 bytes but 64 hex characters. It also says the hash covers a "canonical-JSON form" without defining key ordering, whitespace, Unicode normalization, float/integer serialization, timestamp exclusion, or whether omitted/null fields are included.

Why it matters: the hash is explicitly the v2 sticky identifier. Two implementations can produce different hashes for the same machine and recommendation, breaking replay, console ingestion, and future sticky-affinity semantics.

Recommendation: specify the hash as `sha256:<64-lowercase-hex>` and define a canonicalization profile, preferably RFC 8785 JCS or an equivalent local rule set.

### F.3  Backup naming can collide within one second   [MINOR]
Location: §5.6 FR-F.3 lines 648-655; NFR-3 lines 838-848

Backups are named `config.yaml.bak-<unix-ts>`. Two rapid `--apply` runs in the same second can target the same backup path.

Why it matters: the second apply can overwrite the first backup unless the implementation adds a suffix or fails closed. This is rare but directly touches the reversibility invariant.

Recommendation: require collision-safe backup names, e.g. nanosecond timestamp or `bak-<unix-ts>-<counter>` with no overwrite.

## Category G: State / DB (FR-G)

### G.1  `stage` upgrade is not valid SQLite as written   [MAJOR]
Location: §5.7 FR-G.1 lines 684-712; PR #103 `beta/autotune.py` lines 115-151 and 158-166

The new CREATE TABLE includes `stage INTEGER NOT NULL`, then the upgrade text says implementations must `ALTER TABLE ADD COLUMN stage` and default existing rows to `1`. SQLite cannot add a `NOT NULL` column to an existing populated table unless the column has a non-null DEFAULT, and the spec does not give the actual migration SQL.

Why it matters: the first implementation running against a prototype DB can fail migration before any tuning starts, or silently create nullable `stage` values that violate AC-16 and reporting assumptions.

Recommendation: spell the migration as `ALTER TABLE tune_trials ADD COLUMN stage INTEGER NOT NULL DEFAULT 1`, and say new inserts must set `1` or `2` explicitly.

### G.2  Retention deletes are not required to be transactional   [MINOR]
Location: §5.7 FR-G.1 lines 714-723

Retention deletes both `tune_trials` and `tune_runs` rows outside the most recent N run IDs, but the spec does not require the sweep to run in one transaction.

Why it matters: an interrupted retention sweep could delete summary rows without trial rows, or trial rows without their run summary, leaving reports inconsistent.

Recommendation: require retention to run inside a single SQLite transaction after the new `tune_runs` row is created.

## Category H: Failure modes (FR-H)

### H.1  `--resume` appears in the v0.1 CLI despite being out of scope   [MINOR]
Location: §5.8 FR-H.2 lines 771-778; §7 lines 891-895; §11 lines 1134-1135

FR-H.2 and §11 defer `--resume` out of v0.1's normative contract, but the CLI summary lists `--resume` as a flag.

Why it matters: even though §7 is reference-only, a listed flag creates user and implementer expectations. A partial or no-op `--resume` path can make crash recovery appear stronger than the v0.1 contract.

Recommendation: remove `--resume` from the v0.1 flag summary or label it as "reserved; MUST exit unsupported in v0.1."

## Category I: Non-functional requirements

(no findings)

Notes: The NFR-1 estimates are optimistic but still below the 7200s cap as expectations, not contracts. The NFR-4 hidden-egress risk is captured in D.1 because it depends on the unresolved `models pull` / runtime online-mode contract.

## Category J: ACs are deterministically verifiable

AC setup map checked: AC-1/2 use ordered fake candidates and trial-row assertions; AC-3 uses all-infeasible fixtures plus `tune_runs`; AC-4/5 use deterministic Stage-2 metric fixtures; AC-6 uses an existing serve listener; AC-7 watches spawn argv and coordinator non-registration; AC-8 stubs `models pull`; AC-9 observes temp-file/rename and backup content; AC-10 sends SIGINT; AC-11 schema-validates JSON; AC-12 replays same/different machine inputs; AC-13 uses a tiny max-duration; AC-14 checks default first probe; AC-15 checks override precedence; AC-16 checks stage row counts.

### J.1  No AC proves operator-supplied order is honored without rerank   [MAJOR]
Location: §5.1 FR-A.1 lines 263-275; AC-14/AC-15 lines 1019-1029

FR-A.1 makes supplied order the contract and forbids internal feasibility re-ranking. AC-14 covers the default list's first entry, and AC-15 covers explicit-list precedence over size flags, but no AC gives an intentionally "wrong" operator order and proves the implementation honors it verbatim.

Why it matters: this is the load-bearing biggest-fit guard. A well-meaning implementation could sort by estimated fit or size after parsing `--candidate-models` and still pass the current ACs.

Recommendation: add an AC with `--candidate-models 1B,32B` where both fit; the recommendation must be 1B because the operator-supplied order wins.

### J.2  Optional max-context axis has no acceptance coverage   [MINOR]
Location: §5.2 FR-B.1 lines 353-358; AC-16 lines 1031-1036

The ACs count the max-context axis size when present, but none exercises a non-default `--max-context-axis` path or proves the winning cell can change `recommendation.knobs.max_context`.

Why it matters: this is an escape hatch, so the gap is minor. Without one test, the implementation may silently ignore the axis while still passing default-path tests.

Recommendation: add a small fixture where two max-context cells are evaluated and the non-target-context cell wins.

### J.3  Size-flag-only trimming and exit_reason enum need direct coverage   [MINOR]
Location: §5.3 FR-C.2 lines 416-430; §5.7 FR-G.2 lines 730-750; AC-8/AC-13/AC-15 lines 965-1029

AC-15 covers `--candidate-models` winning over `--max-model-size`, but no AC covers `--max-model-size 16B` alone trimming the default list. The `exit_reason` column examples also expand beyond the table's listed values in AC-13 (`budget_exhausted_*`) without a full enum in FR-G.2.

Why it matters: both are low-effort contract locks that wrappers and reports will rely on.

Recommendation: add one size-trim AC and replace the `exit_reason` comment with a normative enum covering `ok`, `interrupted`, `no_feasible`, `budget_exhausted_with_partial_recommendation`, `budget_exhausted_no_model_selected`, and implementation error strings if allowed.

## Category K: Open questions

### K.1  OQ-B and OQ-D thresholds are still qualitative   [MINOR]
Location: §9 OQ-B/OQ-D lines 1055-1080

OQ-A and OQ-C name measurable thresholds. OQ-B says data will show whether n=3 is sufficient, and OQ-D says data will show whether single-trial fit decisions are unstable, but neither states a quantitative decision rule.

Why it matters: v0.2 can end up relitigating the same defaults because "sufficient" and "unstable" are not tied to a threshold.

Recommendation: define concrete thresholds, e.g. allowed false-fit/false-reject rate for Stage 1 and minimum discriminable tps gap at n=3 for Stage 2.

### K.2  Thermal/order effects are not flagged as an open question   [QUESTION]
Location: §6 NFR-2 lines 825-836; §9 lines 1040-1080

NFR-2 says v1 has no explicit thermal pacing, but §9 does not ask whether sequential Stage-2 cell order creates heat-soak bias. The default axis order is deterministic, so later cells may be measured on a hotter machine than earlier cells.

Why it matters: this may or may not be load-bearing depending on the air5 replication data. If heat soak is material, the keep-best decision can favor earlier cells for reasons unrelated to recipe quality.

Recommendation: operator should decide whether v0.2 needs a thermal/order OQ, randomized cell order, cooldown policy, or merely a note that deterministic order is accepted for v1.

## Category L: Migration note correctness vs prototype

### L.1  Prototype "pre-download" wording overstates what beta/autotune.py does   [MINOR]
Location: §12 lines 1166-1169; PR #103 `beta/autotune.py` lines 224-257 and 452-470

§12 says the prototype's pre-download via external install/cache pre-warm is replaced by `models pull`. The prototype code does not implement a pre-download step; it starts `serve`, waits for `/v1/models`, and treats load/offline/cache errors as trial failure notes.

Why it matters: the migration note is informational, but it is meant to tell the implementer what can be reused. This wording makes the prototype look closer to FR-D than it is.

Recommendation: rewrite the item to say the prototype's "weights must already be available or the candidate fails during load" behavior is replaced by explicit `models pull`.

## Category M: Anything else (operator UX, docs drift, etc.)

### M.1  Locked specs still use SPEC-013 for recommended catalog   [MINOR]
Location: SPEC-010 §11 lines ~1328; SPEC-011 §8/§11 lines 242-251, 1162, 1737; SPEC-013 §11 lines 1137-1139

SPEC-013 v0.1 takes the number for autotune and defers recommended catalog to provisionally SPEC-014, but locked SPEC-010 and SPEC-011 still contain references where "SPEC-013" means the future recommended-catalog surface.

Why it matters: this is not a semantic conflict inside autotune, but it creates navigation drift for future BUILD prompts and readers following cross-spec breadcrumbs.

Recommendation: add a companion annotation or follow-up documentation patch stating that the old recommended-catalog placeholder is now SPEC-014 provisional, while SPEC-013 is autotune.

### M.2  SPEC-013 lock/implementation docs need explicit follow-up hooks   [MINOR]
Location: §13 lines 1218-1239; specs/README.md line 17; originating prompt lines 142-147

`specs/README.md` already has a SPEC-013 row. The draft does not mention the remaining lifecycle updates: SPEC-003 install/onboarding docs may need an "run autotune after install" note, `beta/DECISION_CRITERIA.md` needs a lock entry, and PR #103 should be closed or rebased after the implementation option is chosen.

Why it matters: these are not v0.1 lock blockers, but they are exactly the project-memory steps that prevent prototype and spec drift.

Recommendation: add a short "post-lock documentation/update checklist" or capture these in the decision-log entry when the operator locks SPEC-013.

## Out of scope for this audit

- Inspecting d-inference source (NOASSERTION license)
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001 v1.4, SPEC-002 v1.3.5, SPEC-003 v0.9.2, SPEC-010 v1.5, SPEC-011 v0.5 themselves
- Re-litigating the "biggest-fit vs max-tps" framing
- Auditing PR #103's Python prototype as production code
- Designing the v0.2 audit-response
- Picking Option A (Swift-native) vs Option B (Python wrapper)

## Self-verification

- Required inputs were read, including SPEC-013 v0.1, the originating prompt, CLAUDE.md, AGENTS.md, SPEC-001/002/003/010/011, PR #105, PR #103 `beta/autotune.py`, and the requested code spot-checks.
- Every category A-M has a section.
- Every finding includes severity, location, what, why, and recommendation.
- No d-inference source was inspected.

---

## Round 2 audit (Codex on v0.2)

**Audited:** SPEC-013 v0.2 (specs/SPEC-013-cli-autotune.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N
**Date:** 2026-06-18
**Closure summary:** 17 CLOSED / 1 PARTIAL / 0 NOT CLOSED / 1 OVER-CLOSED across 7 MAJOR + 10 MINOR + 2 QUESTION round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 1 MAJOR new / 3 MINOR new

### Executive summary

Verdict: **LOCK READY under the round-2 threshold, with one narrow v0.3 cleanup strongly recommended before implementation.**

v0.2 closes the substance of the round-1 audit. The biggest-fit framing, STOP-on-first-feasible model iteration, in-model Stage 2 hill-climb, operator-supplied order contract, config-key mapping, launchd label, SQLite `stage` migration, and deterministic recipe hash are now implementable. The code spot-checks support the key factual repairs: `Config.swift` reads `max_context_override`, `max_concurrency_override`, and `kv_bits`; the install artifacts use `live.malibu.provider`; `ModelRuntime.configuration(for:)` checks the local HF snapshot before falling back to `LLMModelFactory.shared.configuration(id:)`; and the PR #103 prototype starts `serve` / waits for `/v1/models` rather than pre-downloading weights.

The remaining round-2 issue is a new precision gap introduced by the D.1 closure. FR-D now permits Shape B, where autotune relies on the runtime's online fallback during model load, but NFR-4 and AC-8 still speak as if the only allowed pre-warm network path is `macprovider-cli models pull`. That is not a product or architecture failure, but it is a day-one contract conflict for the implementing PR. The other findings are minor editorial/testability cleanups.

### Round-1 finding closures

A.1 -> CLOSED. v0.2 replaces metrics-bearing `fallbacks` with name-only `alternates` in §3 and FR-F.1/FR-F.2 (lines 292-296, 766-785, 870-874). AC-1 now expects `[Z]` as an unprobed smaller alternate and explicitly forbids a Z trial row (lines 1284-1290), so the STOP-on-first-feasible failure mode is closed.

D.1 -> OVER-CLOSED. The original missing `models pull` precondition is no longer load-bearing: FR-D.1 makes the operative contract "weights are present before measurement" and permits Shape A or Shape B (lines 575-626), matching the current runtime fallback behavior in `ModelRuntime.swift` lines 559-566 and 622-641. However, that Shape B closure introduces the new N-D.1 precision gap below because NFR-4 and AC-8 still assume the only pre-warm network/failure surface is `models pull`.

E.1 -> CLOSED. FR-E.1 now binds to `live.malibu.provider`, `~/Library/LaunchAgents/live.malibu.provider.plist`, `launchctl bootout`, and `launchctl bootstrap` (lines 663-712). The code spot-check matches: `install.sh` renders the same label at lines 748-749, loads the plist via launchctl at lines 728-729, detects it at line 923, and the plist template has `KeepAlive.SuccessfulExit = false` at lines 25-28.

F.1 -> CLOSED. FR-F.2 and FR-F.3 now use YAML key names `kv_bits`, `max_context_override`, and `max_concurrency_override` (lines 857-866, 935-947). `Config.swift` confirms those are parsed at lines 239-241. The JSON surface and CLI `serve_command` keep CLI flag names separate, which closes the "apply writes unread keys" failure mode.

F.2 -> CLOSED. `recipe_hash` is now `sha256:<64-lowercase-hex>`, with RFC 8785 JCS and an explicit input domain that excludes run IDs, timestamps, observations, alternates, infeasible rows, DB path, and serve command (lines 875-905). The hash input fields all exist in the FR-F.2 schema, and AC-12 requires same-machine, cross-implementation, machine-sensitive, and binary-sensitive test vectors (lines 1396-1421).

G.1 -> CLOSED. The migration is now spelled as valid SQLite: `ALTER TABLE tune_trials ADD COLUMN stage INTEGER NOT NULL DEFAULT 1` (lines 1009-1022). New inserts must set `stage` explicitly to 1 or 2 (lines 1024-1029), and AC-16 verifies both row counts and migration against a populated prototype DB (lines 1445-1453).

J.1 -> CLOSED. AC-17 now tests an intentionally wrong operator order, `1B,32B`, on hardware where both are feasible and requires the 1B recommendation with exactly one Stage 1 row (lines 1455-1475). An implementation that internally re-sorts by parameter count would fail this AC.

B.1 -> PARTIAL. v0.2 adds useful semantics for `--max-context-axis`: §7 says values are absolute token caps, sorted ascending, and each must be `>= --target-context` (lines 1231-1233), and AC-18 checks an invalid below-target cell at flag-parse time (lines 1477-1487). The binding FR-B.1 text still only says "small neighborhood" and points to operator opt-in (lines 484-489), while §7 declares itself non-normative (lines 1218-1221). See Z-B.1.

C.1 -> CLOSED. The CLI summary now defaults `--kv-bits-axis` to `unset,4,8` and defines `unset` across flag, JSON, SQL, YAML, terminal, and `serve_command` surfaces (lines 1229, 1257-1268). FR-B.1 also includes the unset-default cell (lines 477-479).

F.3 -> CLOSED. FR-F.3 now requires `config.yaml.bak-<unix-ts>-<counter>`, picks the lowest free counter, forbids overwrite, and aborts after counter exhaustion (lines 922-931). AC-9 directly tests two applies in the same wall-clock second and requires distinct counters (lines 1365-1370).

G.2 -> CLOSED. Retention now keeps at least N runs, enforces `N >= 1`, and requires a single SQLite transaction covering both `tune_trials` and `tune_runs` deletes (lines 1031-1041). This closes the orphan-summary/orphan-trials crash window named in round 1.

H.1 -> CLOSED. `--resume` is removed from the §7 flag summary (lines 1223-1251), and §11 keeps resume deferred as v2 optimization (line 1622). FR-H.2 still mentions the future flag as best-effort/out-of-scope, but the v0.1 issue was the advertised v1 CLI surface.

J.2 -> CLOSED. AC-18 now exercises a non-default `--max-context-axis 4000,8000` path, requires an 8000 winning cell to appear in `recommendation.knobs.max_context_override`, verifies extra Stage 2 rows, and rejects a below-target axis at flag-parse time (lines 1477-1487).

J.3 -> CLOSED. AC-19 covers `--max-model-size` alone trimming the default list (lines 1489-1497), and `tune_runs.exit_reason` is now a closed enum with no free-form strings (lines 1079-1097). The enum covers the budget-exhausted cases used by AC-13.

K.1 -> CLOSED. OQ-B now defines a 90% confidence minimum-discriminable-gap threshold tied to `TPS_TIE_EPSILON` (lines 1516-1525), and OQ-D defines false-fit / false-reject thresholds with concrete default-change outcomes (lines 1538-1548). The thresholds are measurable from the planned air5 replication data.

L.1 -> CLOSED. §12 now correctly says the prototype has no explicit pre-download step; `evaluate_candidate` starts `serve`, waits for `/v1/models`, and records load failures as trial notes (lines 1704-1717). The PR #103 branch confirms this behavior in `beta/autotune.py` lines 294-344 and 880-948.

M.1 -> CLOSED. §11 now explicitly renumbers SPEC-013 as autotune and provisional SPEC-014 as the coordinator-served recommended catalog (lines 1624-1647). A repo search found no existing `SPEC-014-*.md`; the remaining SPEC-010/SPEC-011 references are listed as follow-up documentation patches.

D.2 -> CLOSED. FR-D.2 splits transient failures from integrity failures, advances only on transient pre-warm failures, and aborts the whole run for signature/hash/tampering/shape failures with `exit_reason = 'pre_warm_integrity_failure'` (lines 628-650). FR-H.3 repeats the same split for operational recovery (lines 1122-1137).

K.2 -> CLOSED. v0.2 adds OQ-E for thermal/cell-order bias and preserves deterministic v1 order pending data (lines 1550-1567). The round-1 question was whether the spec should surface the design choice; it now does. See N-OQ-E.1 for a minor measurement-procedure gap inside the new OQ.

### Round-2 new findings

#### Category Z-CLOSURE

##### Z-B.1 `--max-context-axis` semantics are still partly outside the binding FR [MINOR]
Location: §5.2 FR-B.1 lines 484-489; §7 lines 1218-1233; AC-18 lines 1477-1487.

What: v0.2 defines the useful `--max-context-axis` parse rules in §7, but §7 says it is reference-only and "the normative surface is the FRs above." FR-B.1 itself does not say values are absolute caps, sorted ascending, or rejected when below `--target-context`; only AC-18 locks the below-target rejection case.

Why it matters: the main escape hatch now works in tests, but an implementer reading only the binding FR can still choose a different parse/order rule for valid values. This is not a lock blocker because AC-18 catches the highest-risk invalid-cell case, but it leaves the B.1 closure less clean than the change log claims.

Recommendation: Move the §7 parse sentence into FR-B.1: "`--max-context-axis` is a comma-separated list of absolute token caps, sorted ascending after parse, each value MUST be >= `--target-context`; invalid cells fail at flag-parse time with `config_error`."

#### Category R-REGRESSION

(no findings)

Anti-regression spot-checks passed for the unchanged surfaces named in the prompt: FR-A still stops on first feasible and uses input order (lines 394-430); FR-B.2 still uses throughput primary plus TTFT tie-break within `TPS_TIE_EPSILON` (lines 495-511); FR-C still keeps the curated local default list and operator overrides (lines 523-569); FR-E.2 remains an implementation precondition for `--no-join` (lines 725-745); NFR-1/2/3 retain the local, single-provider, reversible tuning posture (lines 1150-1199); NFR-4 still preserves the no-telemetry/no-upload invariant (lines 1201-1214), with the Shape B egress wording gap filed separately as N-D.1; and AC-1 through AC-5, AC-7, AC-8, AC-10, AC-11, AC-13, AC-14, and AC-15 still test the intended v0.1 behavior after the `fallbacks` -> `alternates` edit.

#### Category N-NEWGAPS

##### N-D.1 Shape B pre-warm conflicts with the remaining `models pull`-only wording [MAJOR]
Location: §5.4 FR-D.1 lines 588-626; §5.8 FR-H.3 lines 1122-1125; §6 NFR-4 lines 1201-1209; §8 AC-8 lines 1352-1357.

What: FR-D.1 now permits Shape B: rely on `ModelRuntime`'s online fallback during load, measure load time separately, and start the first measured request only after weights are warm. FR-H.3 also names "Shape B's online-fallback HTTP failure." But NFR-4 still says autotune performs no network egress except `models pull <id>` to HuggingFace, and AC-8 tests only a mocked `macprovider-cli models pull <id>` failure.

Why it matters: D.1's original failure mode is closed, but the closure leaves two inconsistent implementation contracts. A Shape B implementation would satisfy FR-D.1 yet violate the literal NFR-4 egress exception and would not have a matching pre-warm-failure AC. A Shape A implementation is fine, but v0.2 explicitly says Shape B is permitted, so the spec needs to make the egress and test contract shape-neutral.

Recommendation: Reword NFR-4 to allow "the HuggingFace pre-warm fetch path selected by FR-D.1, whether explicit `models pull` or runtime online fallback" and update AC-8 to run against the implementation's selected pre-warm mechanism. If both shapes remain allowed, AC-8 should have Shape A and Shape B variants or a fixture abstraction that fails the pre-warm step before measurement regardless of mechanism.

##### N-OQ-E.1 Thermal/order threshold lacks a repeat protocol [MINOR]
Location: §9 OQ-E lines 1550-1567.

What: OQ-E defines a quantitative threshold: reverse-order evaluation producing a different keep-best winner more than 5% of the time. It does not specify the sampling protocol: how many forward/reverse repeats, whether the same cell set is interleaved or blocked, and how the planned air5 n=3 data can estimate a "more than 5%" event rate.

Why it matters: This does not block v1 because OQ-E is explicitly pending data and deterministic order is preserved. It does affect whether the operator can close the OQ without relitigating methodology.

Recommendation: Add one sentence: "Measure by running the same Stage 2 cell set in forward and reverse order for at least N paired runs on air5; compare keep-best winners per pair; if mismatches / pairs > 0.05, v0.3 must add randomization or cooldown."

#### Category O-OTHER

##### O.1 Residual v0.1 / pre-v0.2 wording drift remains in live normative text [MINOR]
Location: §5.7 FR-G.2 line 1057; §5.8 FR-H.2 lines 1117-1120; §6 NFR-3 line 1191; §7 line 1270.

What: Several live v0.2 sections still carry stale wording: the `tune_runs.spec_version` SQL comment says `'SPEC-013 v0.1'` while FR-F.2 emits `"SPEC-013 v0.2"`; FR-H.2 says `--resume` is "out of scope for v0.1's normative contract" and "v0.1 default behavior"; NFR-3 still names `.bak-<unix-ts>` instead of the new collision-safe `.bak-<unix-ts>-<counter>`; and §7 says "The flag shape MAY change in v0.2" inside the v0.2 draft.

Why it matters: These are not behavioral blockers because the surrounding sections are clear. They do create avoidable audit noise and can mislead implementers copying schema comments or lifecycle prose into tests.

Recommendation: Update the stale comments/prose to v0.2/v1 wording and make NFR-3 reference the exact FR-F.3 backup pattern.

### Lock readiness

**LOCK READY.** Round 2 found no CRITICAL anti-regressions and only one MAJOR new precision gap. Under the prompt's lock-readiness rule, the operator may lock v0.2 or roll a narrow v0.3. I recommend a narrow v0.3 that fixes N-D.1 plus the three MINORs before implementation, because all fixes are localized prose/test-contract edits and do not change the architecture.

### Self-verification

- The new section was appended after the round-1 report; round-1 sections were not edited.
- All 19 round-1 findings have explicit closure verdicts.
- Required code spot-checks were performed: `Config.swift`, install artifacts, `ModelRuntime.swift`, and PR #103 `beta/autotune.py`.
- No d-inference source was inspected.

---

## Round 3 audit (Codex on v0.3 — LOCK confirmation)

**Audited:** SPEC-013 v0.3 (specs/SPEC-013-cli-autotune.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 3 of N (LOCK confirmation)
**Date:** 2026-06-18
**Closure summary:** 4 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED across the 4 round-2 findings
**Round-3 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 1 MINOR new
**Lock verdict:** LOCK

### Executive summary

Verdict: **LOCK.** v0.3 closes the four round-2 cleanup findings without weakening the locked biggest-fit, ordered-candidate, local-only, or backward-compatible surfaces. The Shape A / Shape B pre-warm wording is now shape-neutral across FR-D.1, NFR-4, and AC-8, and the required code spot-check still supports the runtime-online-fallback description: `ModelRuntime.configuration(for:)` first checks a local HF snapshot and then falls back to `LLMModelFactory.shared.configuration(id:)`.

I found one new MINOR version-drift issue in the FR-F.2 JSON/spec-version text: the v0.3 document still shows `"SPEC-013 v0.2"` as the producing spec example in one live recommendation surface. This does not block LOCK because the adjacent v0.3 SQL comment already states that writers emit their own producing version, but it should be corrected in the implementation PR or the next editorial spec touch.

### Round-2 finding closures

**N-D.1 — CLOSED.** v0.3 rewords NFR-4 to allow only the HuggingFace pre-warm fetch path selected by FR-D.1, explicitly covering both Shape A (`models pull` or equivalent) and Shape B (runtime online fallback during model load). The carve-out is scoped to an `autotune` run and to weight fetches only, so it does not reopen telemetry or recipe-upload egress. AC-8 is now shape-neutral and testable: Shape A mocks the pull/equivalent fetch, Shape B blocks HuggingFace egress at the network-mock layer, and both variants must classify the failure as pre-warm rather than measurement or generic load failure.

**Z-B.1 — CLOSED.** FR-B.1 now contains the `--max-context-axis` parse contract directly: positive integer absolute token caps, sorted ascending before evaluation, each cell at least `--target-context`, invalid/duplicate cells rejected at flag-parse time with `config_error`, and the empty default treated as `[--target-context]`. The §7 / §5 conflict rule is explicit: §7 is reference-only and FR-B.1 wins, so the prior non-normative-placement gap is closed.

**N-OQ-E.1 — CLOSED.** OQ-E now defines a measurable repeat protocol: at least 10 paired forward/reverse Stage 2 runs on air5, 60s idle between paired runs, compare keep-best winners per pair, and trigger v0.4 mitigation if `mismatch_pairs / 10 > 0.05` (one or more mismatches in the minimum 10-pair run). Ten pairs has marginal statistical power, but the spec is honest that this is a minimum and permits more pairs to tighten the confidence interval; for a v1 open-question gate, the protocol is sufficiently measurable.

**O.1 — CLOSED.** All four named drift sites were updated: the `tune_runs.spec_version` SQL comment now uses a v0.3 example plus "writer emits its own producing version"; FR-H.2 now says the future `--resume` optimization is deferred from v1 and that v1 defaults to full rerun; NFR-3 now references `.bak-<unix-ts>-<counter>` with the collision-safe counter rationale; and §7 replaces "MAY change in v0.2" with a future-v0.x refinement rule preserving §5 semantics.

### Round-3 new findings

#### Category Z-CLOSURE

(no findings)

#### Category N-NEWGAPS-V03

(no findings)

#### Category R-REGRESSION-V03

(no findings)

Anti-regression spot-checks passed for the prompt's named surfaces. FR-D.1 still defines Shape A and Shape B as implementation choices under one measurement-isolation contract; FR-D.2 still splits transient pre-warm failures from integrity aborts; FR-F.3 still owns exactly `model`, `kv_bits`, `max_context_override`, and `max_concurrency_override`; FR-G.1 still uses the valid SQLite `stage INTEGER NOT NULL DEFAULT 1` migration; and AC-17 still proves operator-supplied order is honored verbatim with no internal rerank.

#### Category O-OTHER-V03

##### O-V03.1 FR-F.2 spec-version example still says v0.2 inside v0.3 [MINOR]

Location: `specs/SPEC-013-cli-autotune.md` §5.6 FR-F.2, JSON example and `spec_version` bullet.

What: The v0.3 document still shows `"spec_version": "SPEC-013 v0.2"` in the recommendation JSON example and says the canonical producing spec is `"SPEC-013 v0.2"`.

Why it matters: v0.3 fixed the SQL comment to say the writer emits its own producing version, but an implementer copying the FR-F.2 JSON block literally could emit stale v0.2 identity from a v0.3 implementation. This is narrow documentation drift, not a behavior or architecture blocker.

Recommendation: Change both FR-F.2 occurrences to either `"SPEC-013 v0.3"` or a placeholder such as `"SPEC-013 v<producing-version>"` with the existing rule that writers emit their own producing version.

### Lock readiness

**LOCK.** SPEC-013 v0.3 may be locked as-is. The four round-2 findings are closed, there are no CRITICAL anti-regressions and no MAJOR new precision gaps, and the single new MINOR is editorial version drift that does not block the implementing PR.
