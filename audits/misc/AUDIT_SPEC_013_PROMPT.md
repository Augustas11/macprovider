# Audit prompt — SPEC-013 v0.1 (`macprovider-cli autotune` subcommand)

Operator-paste prompt to audit SPEC-013 v0.1
(`specs/SPEC-013-cli-autotune.md`).

**Cross-model pattern:** SPEC-013 v0.1 was drafted by Claude (Opus)
on 2026-06-18. For independence, the audit runs in **Codex CLI
first**. After Codex round 1 lands, an optional round 2 in Claude
may be appended; both audit reports go into `specs/SPEC-013-audit.md`
as separate sections, matching the SPEC-010 / SPEC-011 audit history
pattern.

**Expected duration:** ~30–45 min for Codex. SPEC-013 is operator-
facing CLI surface only — no wire protocol changes, no coordinator
behavior changes, no money-path. The audit's highest-leverage
checks are (i) the two-stage pipeline correctness (FR-A → FR-B), (ii)
the knob-axis claims against the actual PR #105 mlx-swift wiring,
(iii) the back-compat-with-prototype migration note. The locked
product framing in §1 is out of scope — see Critical constraint 1.

**Trigger context:** PR #103 (Python prototype, branch
`spike/provider-model-autotune`) hill-climbed over a cartesian
`(model × ctx × kv-bits × max-batch)` max-tps objective, which
under the v1 product framing is the wrong objective — it would push
every capable Mac to serve the smallest model in the candidate list,
destroying the network value SPEC-013 §1 names. PR #105 (merged) is
the foundation: it exposes `--kv-bits`, `--max-context`,
`--max-batch` on `macprovider-cli serve`. SPEC-013 v1 wraps those
flags with the two-stage **largest-first-feasibility → in-model
knob hill-climb** pipeline that encodes the network's "use this
Mac's capacity to maximum useful capability" strategy.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-013 v0.1, the `macprovider-cli autotune`
subcommand spec at /Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md.

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, and let
the operator decide fixes. The operator has read the spec; they want
an independent second opinion on what is missing, wrong, or under-
specified before any implementation work starts.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-013-audit.md

Format: structured audit report. Findings grouped by category below,
each finding tagged with severity (CRITICAL / MAJOR / MINOR / QUESTION)
and location (section number + line range when possible). Match the
rigor and tone of prior audit reports in this repo
(specs/SPEC-010-audit.md, specs/SPEC-011-audit.md,
specs/SPEC-004-smart-router.md audit pattern).

## Severity definitions

- **CRITICAL** — would cause production failure on rollout, silent
  regression of locked spec behavior, scope creep into a locked
  upstream spec (SPEC-001 v1.4, SPEC-002 v1.3.5, SPEC-003 v0.9.2,
  SPEC-010 v1.5, SPEC-011 v0.5), security regression (operator
  config corrupted by `--apply`, candidate provider leaks into the
  coordinator pool, recipe replay vulnerability), or violation of
  the product framing in §1 (the "biggest-fit, not max-tps"
  objective is LOCKED per the originating prompt).

- **MAJOR** — would cause significant implementer confusion,
  predictable v0.2 patch within first month of v1 rollout,
  unjustified numeric thresholds (other than the four OQ-flagged
  ones), ambiguous failure semantics, knob-axis claims that don't
  match the actual PR #105 mlx-swift wiring, JSON schema gaps that
  break `console.malibu.tech` ingestion, or contract precision
  gaps that an implementer would hit on day one.

- **MINOR** — quality issues that don't block v0.1 but should be
  cleaned in v0.2. Naming inconsistencies, missing cross-references,
  edge cases that won't fire frequently, prose drift inside an
  otherwise-precise FR.

- **QUESTION** — genuinely unresolved design choices the spec
  couldn't decide alone. Distinguish from the §9 OQs the spec
  already names — those are not findings unless they hide a
  CRITICAL / MAJOR underneath (e.g. the OQ is actually a
  load-bearing decision the v1 cannot defer).

## Critical constraints to honor while auditing

**1. The "biggest-fit, not max-tps" product framing in §1 is
LOCKED.** This is the operator's product decision (see the
originating prompt at `.omc/prompts/spec-cli-autotune-v1.md`,
which states "Don't relitigate the 'max-tps vs biggest-fit'
debate; it's settled"). Findings that recommend reverting to a
cross-model throughput-maximization objective are REJECTED.
What IS in scope: findings that the two-stage pipeline (§3) does
not faithfully implement the biggest-fit objective, or that it
admits an interpretation under which max-tps wins. Either of those
is CRITICAL.

**2. SPEC-001 v1.4, SPEC-002 v1.3.5, SPEC-003 v0.9.2, SPEC-010
v1.5, SPEC-011 v0.5 are LOCKED.** Any SPEC-013 clause that
requires a normative edit to one of these locked specs is a
CRITICAL finding ("scope creep across spec boundary"). v0.1
explicitly does NOT propose any normative edit to a locked spec;
the implementing PR may add a sibling subcommand (`models pull
<id>`, FR-D.1) and a `--no-join` flag (FR-E.2), but these are
implementation preconditions, not normative edits to existing
specs.

**3. SPEC-only, no code.** SPEC-013 v0.1 must NOT contain
implementation code, test code, or coordinator/binary diffs. If
audit finds embedded code that goes beyond illustrative wire shapes
or schema definitions (FR-F.2 JSON, FR-G SQL), flag as MAJOR
(scope drift). The CLI surface in §7 is reference, not normative
— §5 FRs are the binding semantics.

**4. Additive only / Tier-1 backward compat.** With autotune
unused, every provider's behavior is byte-identical to pre-SPEC-013.
The PR #105 serving knobs were already merged; SPEC-013 wraps them.
If any clause silently changes `macprovider-cli serve` default
behavior (e.g. mutating the binary's HF-offline default, changing
the default kv-bits, modifying the coordinator-join path outside
the `--no-join` opt-in) = CRITICAL.

**5. The product strategy says "candidate list is ordered,
largest-first by weight footprint" — that ordering is the
CONTRACT, not a heuristic.** If §5.1 FR-A.1 / FR-A.2 leave room
for the implementation to internally re-rank by predicted
feasibility (e.g. "we know 32B won't fit on this Mac, let's
skip it"), the biggest-fit guarantee is broken because the
implementation is now making a feasibility prediction the
operator didn't authorize. Re-ranking would also make the
recommendation non-deterministic across hardware tiers. If FR-A
leaves this open = CRITICAL.

**6. The default candidate list in §5.3 FR-C.1 is curated by the
network**, intentionally — listing 32B at position 1 even though
most operators' Macs will reject it. The feasibility gate's job is
to reject 32B cleanly so the iteration reaches the largest model
that fits. If the audit recommends trimming the default list to
fit a "median operator" (e.g. starting at 14B), that's a
MISINTERPRETATION of the product framing — flag as QUESTION not
finding, and the operator decides.

**7. Knob-axis claims must match PR #105 reality.** PR #105
landed three serve flags: `--kv-bits {4,8}` (mapping to
`MLXLMCommon.GenerateParameters.kvBits`), `--max-context <N>`
(mapping to `GenerateParameters.maxKVSize` + 413 prompt-too-long
gate), `--max-batch <N>` (mapping to `AsyncSemaphore(value: maxBatch)`,
default 1). If SPEC-013 §5.2 FR-B.1 claims an axis value PR #105
doesn't actually accept (e.g. `--kv-bits 6`), or claims a default
PR #105 doesn't have, or claims a wiring site that doesn't exist
= MAJOR per discrepancy.

**8. Clean-room boundary.** Do NOT inspect d-inference
(layr-labs) source. NOASSERTION license. Any SPEC-013 clause that
appears to require d-inference inspection is a CRITICAL finding.
(SPEC-013 v0.1 is not expected to reference d-inference at all;
flag any such reference as CRITICAL.)

**9. Telemetry / privacy invariant.** NFR-4 states "Nothing leaves
the machine" in v1, no opt-in/opt-out. If any clause elsewhere
(JSON ingestion via `console.malibu.tech`, recipe_hash sharing,
coordinator-side comparison in v2 references, telemetry-adjacent
log fields) silently violates this = CRITICAL. The recipe_hash
emission to a local file is fine; auto-upload of any kind is not.

## Required reading (in order, fully)

1. `/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md`
   v0.1 — the spec under audit. Read all 13 sections and all 16 ACs
   fully. Bias toward reading §3 (architecture), §5 (FRs), and §8
   (ACs) most carefully — these are the binding surface. §10
   (implementation note) and §12 (migration from prototype) are
   informational; audit them as "do these correctly describe what
   the v1 implementer will face?" not as binding contracts.

2. `/Users/augstar/macprovider-poc/.omc/prompts/spec-cli-autotune-v1.md`
   — the ORIGINATING prompt that commissioned SPEC-013 v0.1. This
   is the source-of-truth for what the operator asked for. The
   biggest-fit objective, the FR-A through FR-H breakdown, the
   four OQs, and the "what the spec must NOT do" list all come
   from this prompt. If SPEC-013 v0.1 contradicts the originating
   prompt or omits a required FR, that is a CRITICAL coverage gap
   (the spec was commissioned with a specific FR list and a
   missing FR is a contract violation).

3. `/Users/augstar/macprovider-poc/CLAUDE.md` and
   `/Users/augstar/macprovider-poc/AGENTS.md` — project conventions,
   especially the PR workflow rule, the Augustas11 git identity
   rule, and the spec naming pattern.

4. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.4 — focus on:
   - The `ServeCommand` CLI flag set (PR #105 additions:
     `--kv-bits`, `--max-context`, `--max-batch`). SPEC-013 §5.2
     FR-B.1 must align with what PR #105 actually accepts.
   - The `--no-join` flag — does it exist in SPEC-001 v1.4? If not,
     SPEC-013 §5.5 FR-E.2 names it as an implementation
     precondition, and the audit should confirm whether v1.4
     ships it or whether SPEC-013 is implicitly proposing a
     SPEC-001 v1.5 candidate.
   - `/v1/models` response shape — SPEC-013's "wait for ready"
     polls this endpoint (FR-A.2 step 4).
   - HF offline-mode default — SPEC-013 §5.4 FR-D.1 picks
     `models pull <id>` over a "temporary online mode" because
     of this default. If v1.4 doesn't actually run HF offline by
     default, the rationale in FR-D.1 is wrong = MAJOR.

5. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.5 — focus on:
   - The provider WS auth path. SPEC-013 v0.1 claims "no
     coordinator-side change required." Verify by walking the auth
     flow: if `--no-join` semantics actually need a coordinator-
     side opt-out (vs. just provider-side abstention from WS
     connect), the claim is wrong = MAJOR.
   - Pool registration timing — when does a provider appear in
     `seenModels` / the routable pool? If a candidate provider
     could leak into the pool during the `wait-for-ready` window
     even with `--no-join`, that's a buyer-traffic exposure =
     CRITICAL.

6. `/Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md`
   v0.9.2 — focus on:
   - `~/.config/macprovider/config.yaml` shape. SPEC-013 §5.6
     FR-F.3 `--apply` modifies this file; the audit must verify
     the YAML key names SPEC-013 names (`model`, `kv_bits`,
     `max_context_tokens`, `max_batch`) actually match the
     SPEC-003 config schema. If any key name is wrong = MAJOR.
   - Install / launchd interaction. SPEC-013 §5.6 FR-F.3 says
     `--apply` does NOT restart launchd — does this match the
     SPEC-003 install pattern? If SPEC-003 expects autotune to
     restart launchd and SPEC-013 punts to the operator, flag as
     QUESTION (operator decides).

7. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 — focus on:
   - Model id semantics (NFC + ASCII case-fold for equality).
     SPEC-013 §5.1 FR-A.2 inherits this — verify the inheritance
     is correctly cited and would not be broken by autotune's
     pick (e.g. if autotune prints the operator's input string
     instead of the canonical form, that's an interop drift) =
     MAJOR.
   - `supported_models[]` shape — SPEC-013 doesn't directly emit
     this, but the FR-F.2 JSON recommendation eventually feeds
     into the operator's config, which feeds into SPEC-010's
     auth-request frame. If there's a path under which autotune's
     recommendation silently violates SPEC-010 id rules = MAJOR.

8. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 — focus on:
   - Warm-swap opt-in semantics. SPEC-013 v1 explicitly stays out
     of warm-swap (§11 deferral). Verify §3 architecture and §5.5
     FR-E.1 `--drain` correctly stay on the non-warm-swap
     "process-restart" model. If `--drain` accidentally invokes
     warm-swap when `--enable-warm-swap=true` is set on the live
     provider = QUESTION (operator decides interaction).
   - `--enable-warm-swap` default (false). Confirm SPEC-013 v1
     does not require this to be true.
   - Successor SPEC numbering: SPEC-011 §8 informally reserved
     "SPEC-013 (future)" for a recommended-catalog feature.
     SPEC-013 v0.1 picks SPEC-013 for autotune and defers the
     recommended-catalog to "provisionally SPEC-014" (§11). Is
     the renumber clean, or does any locked spec reference
     SPEC-013 with a meaning that contradicts this audit's
     subject? Grep specs/ for "SPEC-013" mentions outside the
     SPEC-013 file itself.

9. PR #105 (`feat(provider): expose --kv-bits / --max-context /
   --max-batch serve knobs for autoresearch`, merged commit
   46d2f1e) — read via `gh pr view 105` or by reading the merged
   diff. Focus on:
   - The wiring table in the PR description (mapping flag →
     mlx-swift call site). Verify SPEC-013 §5.2 FR-B.1 axis
     specifications are consistent.
   - The `ServingKnobsConfigTests.swift` test list — these are
     the actual contract surface. SPEC-013 ACs should not
     contradict what these tests already prove.

10. PR #103 (`spike: provider-side model-selection autotune loop
    (autoresearch)`, branch `spike/provider-model-autotune`,
    DRAFT) — read `beta/autotune.py` from that branch. Focus on:
    - The cartesian max-tps objective (the thing SPEC-013 §12
      rejects). Verify §12's account of "what survives / what
      changes" is accurate.
    - The `_is_new_best` function and its `TPS_TIE_EPSILON`
      constant. SPEC-013 §5.2 FR-B.2 reuses these semantics
      verbatim — verify the reuse is faithful and didn't
      accidentally re-spec different semantics.
    - The `tune_trials` SQL schema. SPEC-013 §5.7 FR-G.1 carries
      this over with one additive `stage` column — verify the
      schema match is exact (column types, indexes, additive
      columns from the prototype's `_ADDITIVE_TUNE_COLUMNS`).
    - The provider-lifecycle pattern (pkill + port-poll +
      `start_new_session=True`). SPEC-013 §3 inherits this; verify
      no detail is silently dropped.

11. Code spot-checks (for cross-checking §5 FRs against reality):
    - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
      — the `ServeCommand` flag set (PR #105 additions). Confirm
      `--kv-bits`, `--max-context`, `--max-batch` are present
      with the documented defaults.
    - `phase3-binary/Sources/MacProviderCore/Config.swift` — the
      config YAML key names (`kv_bits`, `max_context_tokens`,
      `max_batch`, `model`). SPEC-013 §5.6 FR-F.3 lists these as
      the four owned keys; spot-check the spelling.
    - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
      — the `kvBits`, `maxKVSize`, semaphore-based batch gate.
      Verify SPEC-013 §5.2 FR-B.1's axis claims align.
    - `phase4-coordinator/internal/ws/server.go` — the
      `handleConn` / `handleV2Conn` auth flow for the
      `--no-join` claim in FR-E.2 (does a provider that simply
      does NOT open the WS connect leave the coordinator side
      truly inert, or is there some side effect?).

12. `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md` and
    `/Users/augstar/macprovider-poc/specs/SPEC-011-audit.md` —
    for tone, severity-bar continuity, and "what does a
    code-grounding pass actually look like."

## Audit categories — work through each

### Category A: Product framing preservation (HIGHEST PRIORITY)

A.1  Walk §1 (Mission) and §3 (Architecture). Confirm the two-stage
     pipeline FAITHFULLY implements "biggest-fit, not max-tps."
     Critical question: is there ANY path through FR-A + FR-B
     under which a smaller model could be recommended over a
     larger feasible model? If yes = CRITICAL.

A.2  FR-A.1 says the candidate list ORDERING is the contract.
     Confirm FR-A.2 step 7 ("If feasible: this is the chosen
     model. STOP iterating models.") is unambiguous. If FR-A.2
     leaves room for the implementation to internally re-rank
     by feasibility prediction (per Critical constraint 5) =
     CRITICAL.

A.3  FR-B is in-model knob hill-climb. Confirm Stage 2 cannot
     produce a recommendation for a DIFFERENT model than Stage 1
     chose. If FR-B.1's optional max-context axis could trigger
     a re-evaluation that swaps the chosen model (e.g. because
     a wider max-context cell fits 3B at higher tps than 7B at
     target) = CRITICAL.

A.4  FR-F.1 RECOMMENDATION block: confirm the operator-visible
     output unambiguously names the biggest-fit model. Fallbacks
     are smaller models; verify §5.6 doesn't accidentally invert
     the framing by sorting fallbacks tps-descending instead of
     size-descending = MAJOR.

A.5  Defaults bias check. The four OQ-flagged defaults
     (TPS_TIE_EPSILON, stage1/2_replicates, kv-bits axis) are
     OK to flag. But other defaults (gate_ttft_ms = 60000,
     candidate list ordering, --no-join always-on, --apply
     opt-in) MUST be load-bearing for the biggest-fit framing.
     If any default silently weakens the framing = MAJOR.

### Category B: Two-stage pipeline correctness

B.1  FR-A.2 step 3: Stage 1 probes at DEFAULT knobs (kv-bits
     unset, max-batch=1). Verify this is the cheapest probe
     that meaningfully predicts Stage 2 feasibility. If Stage 1's
     defaults could declare a model feasible that Stage 2 then
     proves infeasible at every cell, the loop ends with no
     recommendation despite Stage 1 saying yes = MAJOR (the
     biggest-fit guarantee is now conditional on Stage 2's knobs,
     which violates "Stage 1 = fit decision, Stage 2 =
     optimization within fit").

B.2  FR-A.3 feasibility criteria: confirm the four conditions
     (HTTP 2xx, TTFT ≤ gate, no stop-token leak, no process
     exit) are individually testable and collectively exhaustive.
     If any failure mode the prototype handles (e.g. "model
     loads but returns garbage tokens") isn't covered by these
     four = MAJOR.

B.3  FR-B.1 axis sizing: kv-bits cells = `{4, 8, unset}` = 3,
     max-batch cells = `{1, 2}` = 2, optional max-context axis
     defaulting to 1 cell. Cartesian = 6 cells minimum. At
     stage2_replicates=3 + ~1-5min model load per cell, the NFR-1
     wall-clock estimates need to actually fit. Walk the
     arithmetic. If the NFR-1 table overstates feasibility (the
     32GB tier claims ~30 min for Stage 2 but 6 cells × 3
     replicates × 14B-loaded-time exceeds it) = MAJOR (operator
     will be surprised).

B.4  FR-B.2 _is_new_best semantics: verify the prose matches the
     prototype's `_is_new_best` in `beta/autotune.py`. Note: the
     prototype's tie band is symmetric (`abs(rel_gap) <=
     TPS_TIE_EPSILON`); SPEC-013's prose says "throughput
     primary, TTFT tiebreak WITHIN TPS_TIE_EPSILON." If the
     spec's prose admits an interpretation where tps > best *
     (1 + ε) but TTFT-better-than-best still wins, the rule is
     ambiguous = MAJOR.

B.5  Stage 2 "max-context axis is OPTIONAL in v1; the recommended
     max_context equals --target-context unless the operator
     opted into the axis." Confirm the operator's path to opt in
     is documented. If §7 lists `--max-context-axis` but FR-B
     doesn't say what cells the operator should pass, the
     default-cell case is the only practical path = MINOR (most
     operators will accept the default; the axis is escape-hatch
     only).

### Category C: Knob-axis correctness vs PR #105

C.1  FR-B.1 kv-bits axis: PR #105 accepts `{4, 8}` per the
     description, with unset meaning "no KV-cache quantization"
     (mlx-swift's default unquantized). Verify SPEC-013 §5.2
     FR-B.1's "plus the unset-default as an explicit third cell"
     is implementable: can the autotune subcommand express
     "no flag passed" to `serve` as a discrete cell, or does the
     binary's flag parser collapse no-flag to a sentinel?
     Read PR #105's `Config.swift` / `MacProviderCLI.swift`
     diffs and confirm. If unset-as-cell is not expressible =
     MAJOR (recommendation can't include the unquantized
     baseline).

C.2  FR-B.1 max-batch axis: PR #105 default is 1 with a runtime
     bug fix folded in (`maxConcurrencyOverride: 1` was hardcoded;
     now reflects the resolved config). Verify SPEC-013's
     `--max-batch-axis 1,2` actually exercises the fix. If the
     prior bug means `max-batch=2` silently behaves as 1 = MAJOR
     (Stage 2 would never discriminate).

C.3  FR-B.1 max-context: SPEC-013 says the axis defaults to a
     single value (target context itself) and the operator MAY
     opt in. Verify PR #105's max-context semantics:
     `--max-context N` sets `maxKVSize=N` AND triggers the 413
     prompt-too-long gate at N. If the autotune is firing at
     target context = N and the gate fires at the boundary,
     measurement results may be artificially degraded by the
     gate's behavior. If FR-B.1 doesn't account for this = MAJOR.

C.4  Knob-axis defaults that SPEC-013 picks. v0.1 picks 6-cell
     Stage 2 (3 × 2 × 1) as the default. Is this the right
     default given the air5 empirical findings cited in §1 of
     the originating prompt? The originating prompt notes
     "max-batch > 1 never helped" and "kv-bits=8 outperformed
     kv-bits=4 on every model." If the default is too aggressive
     (operators on 8GB Macs running 6 cells × 3 replicates on
     1B/3B are sitting through unnecessary cells), QUESTION
     (operator decides defaults). If the default is too
     conservative (e.g. should be 4 cells skipping the kv-bits=4
     case that consistently loses), flag as such.

### Category D: Pre-download integration (FR-D)

D.1  FR-D.1 picks `macprovider-cli models pull <id>` (option a).
     Verify the rationale is sound:
       (i) "macprovider-cli runs HF Hub in OFFLINE mode
           internally" — confirm by spot-checking
           ModelRuntime.swift HF resolution. If the binary
           actually runs HF in online mode (or operator-
           configurable), the FR-D.1 rationale is wrong =
           MAJOR (the spec is solving a non-problem).
      (ii) The `models pull` subcommand is named as an
           implementation precondition. If it doesn't exist in
           SPEC-001 v1.4, SPEC-013 v1 implicitly depends on
           shipping it. Is the "ships alongside" plan in §5.4
           FR-D.1 realistic (one-screen subcommand) or
           understated = MINOR / MAJOR depending on size.

D.2  FR-D.2 pre-download failure advances. Verify the failure
     classification is correct: network failures (transient)
     should advance to the next candidate; signature-mismatch
     failures (security-relevant) should arguably abort the
     entire run, not advance. If FR-D.2 collapses both =
     QUESTION (operator decides).

D.3  Bandwidth / disk caps. Pre-downloading a 32B-4bit (~17 GB)
     candidate that will then be rejected by Stage 1 wastes a
     lot of bandwidth on operators with limited connections.
     Is there a `--no-prefetch-largest-N` escape? §5.3 FR-C.2
     gives `--max-model-size`, which is sufficient — but the
     spec doesn't connect the dots. If operators are likely to
     get burned by a full 32B download just to discover
     infeasibility = MINOR (callout in §6 NFR or §5.3 prose).

### Category E: Provider-conflict safety (FR-E)

E.1  FR-E.1 pre-flight refusal: verify the PID detection method
     is realistic. `pkill -f "macprovider-cli serve"` (prototype's
     method) MAY match the autotune-spawned candidate itself if
     the autotune process is also invoked via `macprovider-cli
     autotune` (the parent name). If the autotune process's
     command line could ALSO match the grep, the check is
     wrong = MAJOR.

E.2  FR-E.1 `--drain`: the drain semantics defer to SPEC-011
     when warm-swap is enabled, otherwise a clean process stop.
     Verify the SPEC-011 reference is correct (§3.4 drain
     semantics) and that the drain on the launchd-managed
     install path actually works (launchd may auto-restart the
     binary if its KeepAlive is set). If `--drain` could trigger
     a launchd respawn race that brings the serve back up
     mid-tune = CRITICAL.

E.3  FR-E.2 `--no-join` semantics: confirm the three sub-bullets
     (no WS session, local /v1/* surfaces reachable, no
     state_update on exit) are individually testable. Critical
     question: does the binary's normal startup ALWAYS open a WS
     session, or is `--no-join` already supported? Spot-check
     `phase3-binary/Sources/macprovider-cli` for an existing flag.
     If a `--no-join` flag exists with different semantics from
     what SPEC-013 names = MAJOR (rename).

E.4  Pool leakage window. Even with `--no-join`, is there any
     coordinator-side side-channel by which a candidate provider
     could be discovered (e.g. operator-token usage, audit-log
     emissions, M-DNS-style discovery)? If yes = CRITICAL.

### Category F: Recommendation surface (FR-F) + JSON schema + recipe_hash

F.1  FR-F.1 terminal output: verify the seven required elements
     (model id, knobs, target context, replicated median tps + p95
     TTFT + replicate count, fallbacks, serve command line) are
     individually testable. If the "exact serve command line" is
     ambiguous (e.g. `--max-context` may or may not appear if it
     defaults to target context), specify in §5.6.

F.2  FR-F.2 JSON schema completeness:
     - Does the schema include every field needed for v1
       `console.malibu.tech` ingestion? If a field name is
       wrong (e.g. `tps_median` vs `median_tps`), or a unit is
       wrong (`ttft_p95_ms` is milliseconds; recipe_hash format
       is "sha256:<32-byte-hex>" — but SHA-256 is 32 BYTES =
       64 hex chars; spec says "32-byte-hex" which is ambiguous)
       = MAJOR.
     - Is the schema versioned (`spec_version: "SPEC-013 v0.1"`)?
       Confirm v0.2+ additive fields would not break v1 readers.
     - Is `recommendation: null` valid (no feasible) and is the
       ingestion contract clear about it? AC-13 says yes for
       budget-exhausted; FR-F.2 doesn't say explicitly = MINOR.

F.3  recipe_hash determinism: AC-12 says same machine + same
     recommendation → same hash; different machine → different
     hash. Confirm the canonical-JSON form (used as the hash
     input) is precisely defined. If two implementations could
     emit different canonical JSON for the same recommendation
     (key ordering, whitespace, number serialization) = MAJOR
     (the hash is not reproducible across implementations).

F.4  `--apply` safety (FR-F.3):
     - Atomic write: temp-file + rename is named. Confirm the
       lock semantics on the rename (POSIX rename is atomic;
       on macOS the target may exist). If the prior config is
       open by `serve` at the moment of rename, is the swap
       safe = QUESTION.
     - Backup naming: `.bak-<unix-ts>` could collide on the
       same second if `--apply` runs twice fast. If collision
       silently overwrites the prior backup = MINOR.
     - Owned keys: verify the four listed keys (`model`,
       `kv_bits`, `max_context_tokens`, `max_batch`) match
       SPEC-003's config schema names exactly. Cross-check
       `phase3-binary/Sources/MacProviderCore/Config.swift`. If
       the YAML key is actually `max_context` not
       `max_context_tokens`, the spec is wrong = MAJOR.

### Category G: State / DB (FR-G)

G.1  FR-G.1 `tune_trials` schema: verify exact match with
     prototype's schema in `beta/autotune.py`. The additive
     `stage` column claim says "ALTER TABLE ADD COLUMN stage"
     for upgrades; confirm SQLite syntax (`ALTER TABLE ADD
     COLUMN` only adds; doesn't allow NOT NULL without DEFAULT
     on existing rows). If the spec says NOT NULL but the
     ALTER would fail = MAJOR.

G.2  FR-G.1 retention semantics: deleting rows where `run_id`
     is not in the most recent N is OK but should be transactional
     (otherwise an interrupted retention sweep could leave the DB
     in a partial state). If §5.7 doesn't say "in a single
     transaction" = MINOR.

G.3  FR-G.2 `tune_runs` schema: verify completeness. Is there a
     field for whether `--apply` was used? Yes, `applied INTEGER`.
     Is there a field for the `--target-context`? Yes. Is there a
     field for the `--candidate-models` list? Yes, JSON-encoded.
     If any input that affects determinism is missing = MAJOR
     (replay won't be reproducible).

G.4  DB location: `~/.config/macprovider/autotune.sqlite`. Confirm
     this matches SPEC-003 v0.9.2's config-dir convention. If
     SPEC-003 puts state under a different path (e.g. `~/Library/
     Application Support/macprovider/`), the spec is wrong =
     MAJOR.

### Category H: Failure modes (FR-H)

H.1  FR-H.1 Ctrl-C: verify the post-condition list (no orphan
     provider, port released, DB consistent) is enforceable in
     both Option A (Swift task cancellation) and Option B (Python
     signal.SIGINT). If the contract is met by the prototype but
     not by an Option-A Swift implementation that uses async
     tasks = QUESTION (operator picks but should know).

H.2  FR-H.2 midway crash + `--resume`: v0.1 says "v0.1 default
     behavior is full rerun" and defers `--resume` to v2. Is
     "full rerun is safe and produces equivalent results"
     actually true given the DB retention? If a crash leaves the
     DB at retain-50 + 1 partial row, the next run pushes a fresh
     `tune_runs` row and deletes the oldest — does the partial
     row from the crash get carried into the next run's reports?
     If yes = MINOR (operator could be confused).

H.3  FR-H.3 network down during pre-download: see D.2 above.

H.4  FR-H.4 all-infeasible exit: verify the "smallest-first
     reason" claim is actually informative. On a hardware tier
     where the smallest candidate (1B) is infeasible at
     `--target-context 200000`, the reason might be "TTFT 95s >
     gate 60s" — not maximally diagnostic for the operator. If
     the spec doesn't say "the suggested remediation must include
     a recommended lower --target-context" = MINOR.

### Category I: Non-functional requirements

I.1  NFR-1 wall-clock budget per RAM tier: see B.3 above. Walk
     the arithmetic for each tier and confirm the totals fit the
     `--max-duration 7200s` default. If the 32GB tier's actual
     time exceeds 2 hours under realistic conditions (32B model
     load is ~5 min, but loading WITH KV-cache-quantized variants
     is more) = MAJOR.

I.2  NFR-2 single-slot guarantee: verify FR-E.2's `--no-join` is
     sufficient to ensure no buyer traffic during tuning. See
     E.4.

I.3  NFR-3 reversibility: verify the `.bak-<unix-ts>` claim
     against F.4 backup-naming collision concern.

I.4  NFR-4 telemetry / privacy: confirm "nothing leaves the
     machine" actually holds. The `models pull <id>` step
     ARGUABLY violates this — it makes outbound HTTPS to HF.
     Spec acknowledges this exception ("except `models pull
     <id>` to HuggingFace"). Confirm the carve-out is
     well-understood and there isn't a hidden second egress
     (e.g. mlx-swift logging, telemetry-adjacent HTTP that the
     binary makes during load). If yes = CRITICAL.

### Category J: ACs are deterministically verifiable

J.1  Walk each of AC-1 through AC-16. For each, write down (in
     the audit) the exact test setup and assertion that would
     verify it. If you cannot do this in 3-5 lines, the AC is
     ambiguous = MAJOR per ambiguous AC.

J.2  Coverage gap check: walk every FR-A through FR-H sub-rule
     and confirm at least one AC exercises it. Specifically check:
     - FR-A.1 ordering-is-contract: AC-14 covers default list; is
       any AC covering "operator's --candidate-models order is
       honored verbatim, no internal re-rank"? If not = MAJOR.
     - FR-B.1 max-context axis: is any AC covering the optional
       axis path?
     - FR-C.2 size-flag warning: AC-15 covers conflict; what
       about `--max-model-size 16B` alone (no --candidate-models)?
       If unchecked = MINOR.
     - FR-D.2 advance on pre-download failure: AC-8 covers; OK.
     - FR-E.1 launchd interaction: is any AC covering the
       launchd-managed install path? If not = MAJOR (the most
       common operator install per SPEC-003).
     - FR-G.2 `tune_runs.exit_reason` values: AC-3, AC-10, AC-13
       cover three values; AC-8 implies a fourth. Is the full
       value enum spelled out? = MINOR.

J.3  AC-9 atomic config write: the test asserts "either fully
     old or fully new at every observation moment, never
     half-written." Is this realistically testable on macOS
     without an `flock` equivalent? If the AC is unverifiable in
     practice = MAJOR.

J.4  AC-12 recipe hash determinism: verify the test setup is
     specified precisely enough. If the AC says "same machine"
     but the machine fingerprint includes `binary_version`, a
     binary upgrade between two runs would (correctly) produce
     different hashes — but the AC's wording could be
     misinterpreted as "any two runs on the same Mac." Clarify
     = MINOR.

### Category K: Open questions

K.1  The four OQs in §9 (OQ-A through OQ-D) are flagged as
     "pending the in-flight n=3 air5 replication run." Verify
     each OQ:
     - Names a specific placeholder value (yes for all 4)
     - Has a measurable decision threshold (OQ-A names
       "σ(tps)/μ(tps) > 0.02 vs < 0.005"; OQ-B is qualitative;
       OQ-C names "wins on every model on every RAM tier within
       TPS_TIE_EPSILON"; OQ-D is qualitative). If OQ-B and OQ-D
       need quantitative thresholds = MINOR.
     - The placeholder, if wrong, doesn't catastrophically
       break v1. If a wrong OQ-A (TPS_TIE_EPSILON) value would
       silently invert the FR-B.2 keep-best decision in 20% of
       cases = MAJOR (the OQ is load-bearing and should not be
       deferred).

K.2  Are there OPEN QUESTIONS that SPEC-013 v0.1 should have
     flagged but didn't? Examples to check:
     - Behavior on partial RAM disclosure (some Macs return
       wrong `ram_gb` to system APIs)
     - Behavior under thermal throttling (Stage 2 cell N's tps
       affected by Stage 2 cell N-1's heat soak)
     - Behavior when `--target-context` exceeds the largest
       candidate's `max_context_tokens` cap
     If any of these is a load-bearing missing OQ = MAJOR.

### Category L: Migration note correctness vs prototype

L.1  §12 "What survives" list: walk each item against
     `beta/autotune.py` on the `spike/provider-model-autotune`
     branch. Verify each survives-item is in fact reusable as
     described. If `_is_new_best` is described as "reused
     unchanged" but the SPEC-013 v0.1 prose for FR-B.2 actually
     contains a subtle re-spec = MAJOR (caught by category B.4).

L.2  §12 "What changes" list: confirm the rejected items are
     accurately described. The objective, the candidate list,
     the coordinator-join, the DB location, the recommendation
     surface — all named as changes. If any "change" is described
     but the prototype actually already had that behavior =
     MINOR (the prototype gives more for free than the spec
     claims).

L.3  §12 "What is provisional" tied to OQ-A through OQ-D —
     confirm the cross-reference is complete.

L.4  Branch posture: §12 says "the prototype branch MUST NOT be
     merged as-is." Verify the implementing PR for SPEC-013 v1
     would replace or rebase that branch. If the spec is silent
     on which option (A) Swift-native or (B) wrap Python takes
     this disposition, §10 says the implementing PR makes the
     call — OK. Note the open implementation choice in the audit
     summary.

### Category M: Anything else (operator UX, docs drift, etc.)

M.1  Documentation drift. If SPEC-013 v1 ships, what else needs
     to be updated? Examples:
     - SPEC-003 install flow may want to mention autotune as
       "what to run after install"
     - `beta/DECISION_CRITERIA.md` should get a SPEC-013-lock
       entry
     - `specs/README.md` index gets the SPEC-013 row (verify it
       was added)
     - PR #103 (the prototype) should be closed or repurposed
       once SPEC-013 lands
     If the spec doesn't mention these = MINOR.

M.2  Spec numbering: SPEC-011 §8 informally reserved SPEC-013 for
     a "Recommended catalog (`GET /v1/recommended-catalog`)
     future" feature. SPEC-013 v0.1 takes SPEC-013 for autotune
     and defers the recommended-catalog to "provisionally
     SPEC-014" (§11). Is this renumber clean? Verify by:
       - `grep -rn "SPEC-013" specs/` — every reference should
         resolve to autotune semantics under v0.1
       - Confirm SPEC-014 is not already in use
     If a locked spec references SPEC-013 with the
     recommended-catalog meaning, the renumber needs a
     companion-spec annotation = MINOR.

M.3  Operator-facing examples in §4 (User stories): verify the
     example serve commands match the actual binary's flag names.
     If the example uses `--max-context 4000` but the binary
     uses `--max-context-tokens 4000` = MAJOR.

M.4  Anything else the operator should know about that doesn't
     fit A-L.

## Output structure

Write to `/Users/augstar/macprovider-poc/specs/SPEC-013-audit.md`.
Top-of-file frontmatter:

```
# SPEC-013 v0.1 — Audit Report

**Audited:** SPEC-013 v0.1 (specs/SPEC-013-cli-autotune.md)
**Auditor model:** [Codex / GPT-5 / etc.]
**Audit round:** 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

---

## Executive summary

[2-4 paragraphs. State whether SPEC-013 v0.1 is ready to lock as
drafted, ready with the CRITICAL findings addressed, or needs
structural revision. Be specific about what the operator should
do next.]
```

Then for each category A-M, write a section. For each finding:

```
### A.2  [SHORT TITLE]   [CRITICAL | MAJOR | MINOR | QUESTION]
Location: §5.1 FR-A.2, line ~XXX-YYY

[What the spec says or fails to say. 1-3 sentences.]

[Why it matters. 1-3 sentences. Reference a concrete failure
scenario or a specific reader confusion.]

[Recommendation. 1-2 sentences. What v0.2 should do — but don't
rewrite the spec for the operator.]
```

If a category has zero findings, write `(no findings)` under the
category header — don't omit the section.

## Out of scope for this audit

- Inspecting d-inference source (NOASSERTION license)
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001 v1.4, SPEC-002 v1.3.5, SPEC-003 v0.9.2,
  SPEC-010 v1.5, SPEC-011 v0.5 themselves (they are locked;
  SPEC-013 layers on top)
- Re-litigating the "biggest-fit vs max-tps" framing (Critical
  constraint 1)
- Auditing PR #103's Python prototype as production code (it's
  a draft and SPEC-013 §12 already addresses what survives /
  changes / provisional)
- Designing the v0.2 audit-response (separate session after v0.1
  audit closes)
- Picking Option A (Swift-native) vs Option B (Python wrapper)
  — §10 explicitly defers to the implementing PR

## Done criteria

You are done when:

- /Users/augstar/macprovider-poc/specs/SPEC-013-audit.md exists
- Every category A-M has a section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Executive summary states a clear "lock as-is" / "lock with
  these CRITICAL/MAJOR findings closed" / "needs structural
  revision" verdict
- Total CRITICAL count is honest (do not under-report to avoid a
  revision round; do not over-report to seem rigorous)

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: 30-45 min Codex round 1.
- After Codex finishes, the operator decides whether to run a Claude
  round 2 (append, not overwrite). If only one round is needed,
  delete the "Audit round: 1 of N" line in the audit file and bump
  to "Audit round: 1 of 1" so future readers don't expect a round 2.
- If Codex finds zero CRITICAL findings and ≤3 MAJOR findings, the
  operator can choose to lock SPEC-013 v0.1 as-is OR roll a narrow
  v0.2 closing them; matches the SPEC-010 v1.1 / SPEC-011 v0.3
  pattern.
- If Codex finds ≥1 CRITICAL or >3 MAJOR findings, draft SPEC-013
  v0.2 incorporating the fixes, re-audit in Codex round 2.
- After lock, append decision-log entry to `beta/DECISION_CRITERIA.md`
  (next free entry number) summarizing: trigger, the biggest-fit
  decision, what shipped, what was deferred to v2 (recommended
  catalog, recipe attestation, sticky-affinity-from-recipes, etc.).
- After lock, the implementing PR picks Option A (Swift-native) or
  Option B (Python wrapper) per SPEC-013 §10. The PR #103 prototype
  branch (`spike/provider-model-autotune`) is closed or rebased
  onto the chosen option.
