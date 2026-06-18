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

SPEC-013 names the launchd-managed install as `com.macprovider.cli` and requires drain to restore plist state on exit. SPEC-003's launchd label/path are `live.streamvc.macprovider` and `~/Library/LaunchAgents/live.streamvc.macprovider.plist`, with `KeepAlive.SuccessfulExit = false`.

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
