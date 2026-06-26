# SPEC-013 — `macprovider-cli autotune` subcommand

**Version:** 0.3 (round-2 audit response — LOCK candidate)
**Status:** Draft (pre round-3 closure-confirmation audit)
**Date drafted:** 2026-06-18
**Depends on:** SPEC-001 v1.4 (`macprovider-cli serve` flags `--kv-bits`, `--max-context`, `--max-batch` per PR #105), SPEC-010 v1.5 (provider-advertised `supported_models[]` shape, model id semantics)
**Companion to (LOCKED):** SPEC-002 v1.3.5 (no coordinator-side change required), SPEC-003 v0.9.2 (autotune is invoked before / between `macprovider-cli serve` lifetimes; not part of install flow; SPEC-013 v0.2 binds the launchd label and drain sequence to SPEC-003 §FR-C5)
**Related (future):** SPEC-011 v0.5 (warm-swap; opt-in coupling deferred to v2 — see §11)

SPEC-013 is operator-facing CLI surface only. It MUST NOT modify any
SPEC-001 wire protocol, SPEC-002 coordinator behavior, SPEC-005
billing/settlement, or SPEC-006 buyer API surface. With autotune
unused, every provider's serving behavior is byte-identical to
pre-SPEC-013.

---

## Change log

### Triage note 2026-06-26 (no version bump, no normative change)

§9 OQ-A..D marked RESOLVED inline as frozen at v0.3 placeholder defaults; OQ-E's v0.4 trigger condition (5% mismatch on the 10-paired-run sampling protocol) remains conditionally normative if a thermal-bias suspicion surfaces in production. Pointer: `docs/OPEN_QUESTIONS.md` 2026-06-26 triage row for SPEC-013.

### v0.3 (2026-06-18) — round-2 audit response (LOCK candidate)

Codex round 2 (`specs/SPEC-013-audit.md` § Round 2) returned
`17 CLOSED / 1 PARTIAL / 0 NOT CLOSED / 1 OVER-CLOSED` on the
round-1 findings and `0 CRITICAL anti-regression / 1 MAJOR new /
3 MINOR new`. Verdict: LOCK READY; codex recommended a narrow
v0.3 closing the 4 new findings before implementation. v0.3
closes all 4. No architecture change.

- **N-D.1 fix (MAJOR — Shape B vs `models pull`-only wording
  inconsistency):** v0.2 permitted FR-D Shape B (rely on the
  runtime's online fallback during load + measurement
  isolation), but NFR-4's egress carve-out and AC-8 still
  spoke only of `macprovider-cli models pull <id>` failures.
  v0.3 reworords NFR-4's egress exception to "the
  HuggingFace pre-warm fetch path selected by FR-D.1, whether
  explicit `models pull` or runtime online fallback" and
  updates AC-8 to test the implementation's selected pre-warm
  mechanism (with explicit Shape A / Shape B variants).
- **Z-B.1 fix (PARTIAL → CLOSED — `--max-context-axis` parse
  rules were in non-normative §7 but not in binding FR-B.1):**
  v0.3 lifts the parse rules (absolute token caps, sorted
  ascending, each cell ≥ `--target-context`, flag-parse-time
  rejection of invalid cells) into FR-B.1 as a normative
  paragraph.
- **N-OQ-E.1 fix (MINOR — OQ-E thermal threshold lacked a
  repeat protocol):** v0.3 adds a sampling protocol (minimum
  10 paired forward/reverse runs on air5; mismatch rate over
  pairs is the metric).
- **O.1 fix (MINOR — residual v0.1-era wording drift in live
  text):** v0.3 closes four discrete drift sites — the
  `tune_runs.spec_version` SQL comment, FR-H.2's "v0.1
  normative contract" prose, NFR-3's stale `.bak-<unix-ts>`
  pattern, and §7's "MAY change in v0.2" disclaimer.

### v0.2 (2026-06-18) — round-1 audit response

Codex round 1 (`specs/SPEC-013-audit.md`) returned `0 CRITICAL / 7
MAJOR / 11 MINOR / 2 QUESTION`. v0.2 closes all 7 MAJORs, 10 of
11 MINORs, and both QUESTIONs. The product framing (§1) and the
two-stage architecture (§3) are unchanged; the round-1 verdict
explicitly preserved both.

**MAJORs closed:**

- **A.1 fix** (fallbacks contradicted STOP-on-first-feasible):
  FR-F.1 and FR-F.2 no longer emit "fallbacks" as
  metrics-bearing entries (which would have required a
  separate fallback-probing pass that contradicted the
  largest-first STOP rule). The recommendation now emits an
  `alternates` list of NAME-ONLY smaller candidate IDs from
  the input list — operators who want to manually downsize
  invoke a follow-up `autotune --candidate-models <id>`. AC-1
  and AC-2 are updated.
- **D.1 fix** (`models pull` was a bigger missing precondition
  than v0.1 admitted; the current binary has no `pull`
  subcommand and no locked HF-offline contract): FR-D
  rewritten to make the OPERATIVE requirement "candidate
  weights MUST be cache-warm before the feasibility probe
  begins" and to make load-fetch latency normative-excluded
  from the gate-ttft-ms metric. The HOW is implementation
  choice, deferred to the implementing PR. The `models pull`
  subcommand shape is no longer a SPEC-013 v1 normative
  dependency; it remains a recommended mechanism and a
  follow-on SPEC may formalize it.
- **E.1 fix** (launchd label `com.macprovider.cli` was
  wrong): FR-E.1 now binds to SPEC-003 v0.9.2's actual label
  `live.streamvc.macprovider` and plist path
  `~/Library/LaunchAgents/live.streamvc.macprovider.plist`.
  The drain sequence is `launchctl bootout
  gui/$UID/live.streamvc.macprovider` to stop and
  `launchctl bootstrap gui/$UID <plist>` to restore. AC-6 is
  extended to cover the launchd-managed install path.
- **F.1 fix** (`--apply` wrote keys the binary doesn't read):
  FR-F.3 owned-key list updated to match the actual
  `Config.swift` parser
  (`max_context_override` instead of `max_context_tokens`,
  `max_concurrency_override` instead of `max_batch`). The
  FR-F.2 JSON `knobs` object now uses these YAML key names
  so a `--json` output is round-trippable into config.yaml.
  The terminal output's `serve_command` retains the CLI flag
  names per PR #105.
- **F.2 fix** (recipe_hash format ambiguous + canonicalization
  undefined): hash format pinned to
  `sha256:<64-lowercase-hex>` (32 bytes = 64 hex chars). The
  canonicalization profile is pinned to RFC 8785 JSON
  Canonicalization Scheme (JCS). The hash input domain is
  explicitly enumerated (machine, inputs.target_context,
  inputs.candidate_models, recommendation.model,
  recommendation.knobs); timestamps, run_id, and observed
  metrics are explicitly excluded.
- **G.1 fix** (`tune_trials.stage` migration was not valid
  SQLite): migration SQL now spelled out as
  `ALTER TABLE tune_trials ADD COLUMN stage INTEGER NOT NULL
  DEFAULT 1`. New inserts MUST set `stage = 1` (Stage 1
  probe) or `stage = 2` (Stage 2 cell) explicitly. AC-16 is
  unchanged in shape; the migration step is now stated as a
  prerequisite, not an in-test step.
- **J.1 fix** (no AC proved operator-supplied order is
  honored without internal rerank — the load-bearing
  biggest-fit guard had no test): new AC-17 explicitly tests
  `--candidate-models 1B,32B` on a Mac where both fit;
  recommendation MUST be 1B (operator-supplied order wins).

**MINORs closed (10 of 11):**

- B.1: `--max-context-axis` semantics defined (absolute caps,
  each ≥ `--target-context`, sorted ascending, invalid cells
  fail at flag-parse time).
- C.1: §7 CLI summary kv-bits default fixed to `unset,4,8`
  (matching FR-B.1); representation of `unset` defined for
  flags, JSON, SQL, and terminal output.
- F.3: backup naming changed to `bak-<unix-ts>-<counter>` with
  no overwrite (implementation MUST find the lowest available
  counter starting at 0).
- G.2: retention sweep MUST run inside a single SQLite
  transaction after the new `tune_runs` row is created.
- H.1: `--resume` removed from the §7 flag summary (still
  deferred to v2 per §11).
- J.2: new AC-18 covers non-default `--max-context-axis`.
- J.3: new AC-19 covers `--max-model-size` alone trimming the
  default list; `tune_runs.exit_reason` value set is now an
  explicit normative enum.
- K.1: OQ-B and OQ-D get quantitative thresholds (minimum
  discriminable tps gap at n=3; Stage-1 false-fit /
  false-reject rates).
- L.1: §12 prototype migration note rewritten — the prototype
  has no explicit pre-download step; the prototype's "weights
  must already be present or candidate fails during load"
  behavior is what FR-D replaces.
- M.1: companion-spec note added — SPEC-010 §11 and SPEC-011
  §8/§11 still cite "SPEC-013" with the recommended-catalog
  meaning; v0.2 documents the renumber (SPEC-013 = autotune,
  recommended catalog is now provisionally SPEC-014) and
  flags a follow-up docs patch.

**MINOR deferred to v0.3 (post-lock):**

- M.2 documentation checklist (`beta/DECISION_CRITERIA.md`
  entry, SPEC-003 install note, PR #103 disposition): v0.2
  adds a short post-lock checklist to §13, but the
  decision-log entry and SPEC-003 patch are out-of-PR work
  the operator performs at lock time.

**QUESTIONs resolved:**

- D.2 (signature vs network failure handling): v0.2 picks
  asymmetric — transient failures (network down, disk full)
  advance to the next candidate per FR-D.2; integrity
  failures (signature mismatch, hash mismatch) ABORT the
  whole run with a security-relevant exit code. The two
  failure classes are distinguished in the `notes` column
  and in the FR-F.2 JSON.
- K.2 (thermal/order effects): v0.2 adds OQ-E flagging this
  as a v0.2 open question pending the air5 n=3 data. v1's
  current behavior (deterministic axis order, no thermal
  pacing) is preserved; if the data shows heat-soak bias on
  later cells, v0.3 may randomize cell order or add a
  cooldown policy.

### v0.1 (2026-06-18) — initial draft

- First normative draft. Encodes the "biggest-fit model" product
  strategy as a binary `autotune` subcommand that wraps the PR #105
  serving knobs.
- The candidate-list iteration is **largest-first** with a feasibility
  gate (FR-A.1 / FR-A.2 / FR-A.3); the chosen model is the FIRST one
  that passes. This is the load-bearing departure from the PR #103
  Python prototype, whose cartesian max-tps loop would push every Mac
  to the smallest model in the list.
- Knob hill-climb (FR-B) operates within the chosen model only; the
  prototype's `_is_new_best` semantics with `TPS_TIE_EPSILON = 0.02`
  carry over here unchanged.
- Four numerical defaults (`stage1_replicates`, `TPS_TIE_EPSILON`,
  `stage2_replicates`, kv-bits axis-vs-default) are flagged as Open
  Questions pending the in-flight air5 n=3 replication run; v0.2 may
  revise them based on measured trial-to-trial variance.
- v1 picks Swift-native (vs. wrapping the Python prototype) is
  deferred to the implementing PR — §10 lays out the trade-off but
  does not pick.

---

## 0. Operator-paste invocation block

```
Implement SPEC-013. As you work, maintain a running
phase3-binary/implementation-notes.html that captures anything I
should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Mission

MacProvider pools heterogeneous Apple Silicon Macs to serve LLM
inference. The pool's value to buyers is **access to bigger models
than they can run locally** (7B, 14B, 32B+), routed through whichever
Mac in the pool can host them. A 16 GB Mac contributing capacity to
serve a 7B is creating real network value; the same 16 GB Mac serving
a 1B is wasting capacity (the buyer could call any cloud API).

`autotune` encodes this product strategy as a deterministic per-Mac
recommendation. Its job is:

> **Find the BIGGEST model from a ranked candidate list that fits
> this Mac at the operator's target context, and recommend the best
> knob configuration for serving it.**

It is NOT "find the highest-throughput model on this Mac" — that
would push every capable Mac to serve the smallest model. It IS "use
this Mac's capacity to its maximum useful capability." Throughput is
the tiebreaker among knob settings for a chosen model, not the
cross-model objective.

Smaller models still appear in the candidate list as fallbacks: if
32B doesn't fit, try 14B; if that doesn't fit, try 7B; eventually 1B
always fits. The recommendation is the **largest one that survives
the feasibility gate**.

---

## 2. Scope

### In scope

- New `macprovider-cli autotune` subcommand.
- Two-stage pipeline (§3): (1) largest-first feasibility iteration
  across a curated candidate model list; (2) knob hill-climb within
  the chosen model over the PR #105 axes (`--kv-bits`,
  `--max-batch`, optionally a small `--max-context` neighborhood).
- Per-trial SQLite persistence in the additive `tune_trials` table
  (the prototype's schema, slightly extended; FR-G) and a per-run
  `tune_runs` summary row (FR-G.2) capturing inputs and the final
  recommendation for replay/comparison.
- Operator-visible recommendation surface (terminal text + JSON +
  optional `--apply`).
- Pre-download integration via a sibling subcommand (FR-D);
  provider-conflict pre-flight (FR-E); Ctrl-C / crash safety (FR-H).
- A default curated candidate list shipped as a code constant (FR-C).

### Out of scope (v1)

- Cross-model throughput optimization. The product framing in §1
  rules this out; the prototype's max-tps cartesian objective is
  explicitly rejected — see §12 migration note.
- Coordinator-side scheduling, dispatch, or any RPC that triggers
  tuning from the coordinator. Tuning is always operator-initiated
  and always local.
- Automatic model downloads from sources other than HuggingFace
  (signed via the HF transport already used by SPEC-003 v0.9.2 §
  FR-D2.1). Untrusted-source pre-download is out of scope.
- Remote tuning (tuning a different Mac than the one running the
  CLI). Always local.
- Auto-apply without explicit operator confirmation. `--apply` is
  opt-in (FR-F.3).
- Pareto-frontier UX (`"7B is 3× slower but 5× more capable"` style
  charts). v1's recommendation is opinionated and singular.
- Coordinator-side recipe registry (v2 territory; see §11).
- Per-provider recipe attestation, sticky-affinity from recipes,
  automatic re-tune on hardware/binary changes (v2).
- Multi-model serving on one Mac (architectural; not a v1 autotune
  concern).
- Warm-swap-driven tuning (`autotune` could in principle re-use one
  loaded provider process via SPEC-011 warm swap to skip
  load-per-candidate cost; v1 explicitly does NOT do this — see §10).

---

## 3. Architecture

`autotune` runs a two-stage pipeline. Both stages share the same
provider-lifecycle invariants (one provider serving at a time,
`--no-join` to keep the coordinator pool out of tuning candidates,
feasibility gate identical across stages).

```
Stage 1: Model selection (largest-first iteration)
─────────────────────────────────────────────────
candidate_list[0]  (largest)  ──>  feasibility probe
                                   ├─ feasible? ──> chosen = candidate[0]
                                   │                STOP iterating models
                                   │                proceed to Stage 2
                                   └─ infeasible ─> candidate_list[1]
                                                    (next largest)
                                                    ... repeat ...

(if all candidates infeasible) ──> exit with the most-informative
                                   error (smallest candidate's
                                   failure reason, per FR-H.4)

Stage 2: Knob hill-climb within the chosen model
────────────────────────────────────────────────
for each (kv_bits, max_batch, [optional small ctx neighborhood]):
    fire N replicates at the target context  ──>  median tps + p95 ttft
    apply _is_new_best (throughput primary,
                        TTFT tiebreak within TPS_TIE_EPSILON)

best knob cell  ──>  RECOMMENDATION
                     model = chosen
                     knobs = best knob cell
                     alternates = NAME-ONLY list of smaller
                                  candidates from the input list
                                  (not probed; operator may
                                  manually pin via a follow-up
                                  autotune --candidate-models)
```

Stage 1 spends the budget on a **fit decision**, not on
optimization. Stage 2 spends the budget on **optimization within the
chosen model**, not on a fit decision. This separation is what makes
the wall-clock budget bounded per RAM tier (§ NFR-1) and what makes
the recommendation deterministic given a candidate list + target
context.

### Provider lifecycle invariant

At every moment during an `autotune` run, AT MOST ONE
`macprovider-cli serve` process is alive holding the local port
(default 18080). Before evaluating the next candidate, `autotune`
MUST stop the prior provider and wait for the port to free. The
prototype enforces this with `pkill -f "macprovider-cli serve"` +
poll; a Swift-native implementation MAY hold the subprocess handle
directly. Either is acceptable. What is NOT acceptable is overlapping
provider lifetimes.

### Coordinator-pool invariant

During tuning, candidate providers MUST NOT register with the
coordinator pool. Buyer traffic during tuning would (a) pollute
measurements and (b) expose buyers to providers that are about to be
killed. FR-E.2 specifies the `--no-join` semantic; v1 makes this the
DEFAULT and provides no flag to opt out.

---

## 4. User stories

**(a) New provider onboarding: "I just installed macprovider-cli.
What should I serve?"**

```
$ macprovider-cli autotune
autotune: target_context=2000 (use --target-context to change)
autotune: candidates (largest-first):
  1. mlx-community/Qwen2.5-32B-Instruct-4bit
  2. mlx-community/Qwen2.5-14B-Instruct-4bit
  3. mlx-community/Qwen2.5-Coder-7B-Instruct-4bit
  4. mlx-community/Llama-3.2-3B-Instruct-4bit
  5. mlx-community/Llama-3.2-1B-Instruct-4bit
...
RECOMMENDATION
  model:           mlx-community/Llama-3.2-3B-Instruct-4bit
  target_context:  2000
  --kv-bits:       8
  --max-batch:     1
  median tok/s:    4.9  (n=3 replicates)
  p95 TTFT:        4.2s
  alternates (smaller candidates from your input list, not probed):
    - mlx-community/Llama-3.2-1B-Instruct-4bit
  To try a smaller alternate instead:
    macprovider-cli autotune --candidate-models mlx-community/Llama-3.2-1B-Instruct-4bit

To apply this to your config and restart serve:
  macprovider-cli autotune --apply
```

**(b) Existing provider: "macOS / mlx-swift / binary changed. Is my
config still optimal?"**

```
$ macprovider-cli autotune --compare
... runs same pipeline, then prints:
RECOMMENDATION (current run)
  model:           mlx-community/Qwen2.5-Coder-7B-Instruct-4bit
  --kv-bits:       8                            (was 4 in last recipe)
  median tok/s:    2.6                          (was 2.1)
... summary of delta vs. last persisted run, if any.
```

**(c) Operator with a specific use case: "I want to commit to
ctx=16000 — what's the biggest model I can serve?"**

```
$ macprovider-cli autotune --target-context 16000
...
RECOMMENDATION
  model:           mlx-community/Llama-3.2-1B-Instruct-4bit
  target_context:  16000
  --kv-bits:       4
  --max-batch:     1
  median tok/s:    2.5
  note: 3B / 7B / 14B / 32B candidates failed feasibility at
        ctx=16000 (TTFT > 60s gate). Lower --target-context to
        unlock larger models.
```

---

## 5. Functional requirements

### 5.1 Stage 1 — model selection (largest-first iteration)

**FR-A.1. Candidate list is ordered, largest-first.**
The candidate-models input is an ORDERED list sorted by approximate
on-device weight footprint (parameter count × bytes-per-param, with
the operator's chosen quantization), LARGEST first. The operator MAY
override the order entirely (`--candidate-models <ordered,csv>`) or
constrain it (`--max-model-size 16B`). v1 ships a default curated
list described in §6.

The order is the contract. `autotune` MUST iterate the list in the
supplied order with no internal re-ranking and MUST NOT re-sort by
predicted feasibility. If the operator passes a manifestly-wrong
order ("1B first, then 32B"), `autotune` honors it — the candidate
that fits first wins, even if it's the operator's worst choice.

**FR-A.2. Per-candidate feasibility probe; STOP on first pass.**
For each model in the list, in order, `autotune` MUST:

1. Stop any prior candidate provider (provider lifecycle invariant).
2. Pre-download the candidate's weights per FR-D.
3. Start `macprovider-cli serve --model <id> --no-join --port 18080`
   at the **default** knobs for this stage (kv-bits unset,
   max-batch=1, max-context unset — the binary defaults). The intent
   is to probe FIT cheaply; knob hill-climb is Stage 2's job.
4. Wait for the provider to become ready (`/v1/models` returns 200).
5. Fire `stage1_replicates` requests at the operator's
   `--target-context` (default 2000).
6. Stop the provider.
7. Evaluate feasibility per FR-A.3. If feasible: this is the chosen
   model. STOP iterating models. Proceed to Stage 2 with this model
   id.
8. If infeasible: record the failure reason and advance to the next
   candidate.

When the loop selects a model, the model id MUST be the one
`autotune` actually started — not the operator's input string, not
a normalized form. SPEC-010 v1.5 model-id semantics (NFC + ASCII
case-fold for equality) apply.

**FR-A.3. Feasibility is binary, gate-driven.**
A candidate is feasible at the target context IFF all of the
following hold across all `stage1_replicates` replicates:

- Every request returned HTTP 2xx within the request timeout.
- Every request's TTFT p95 ≤ `--gate-ttft-ms` (default 60_000 ms).
  The gate is generous on purpose — TTFT > 60s is "the model
  technically loaded but is unservable on this Mac at this context."
- No stop-token leak in any response (the SPEC-001-defined stop
  token, e.g. `<|im_end|>`, MUST NOT appear in the generated text).
  This is the SPEC-001 §6.6 gate as currently enforced by
  `harness.fire_stream` in the prototype.
- The provider did not exit during the probe (a process exit during
  load is the dominant OOM signal on small-RAM Macs and is recorded
  as infeasible with the binary's stderr tail in `notes`).

Default `stage1_replicates = 1` (cheap probe). The operator MAY raise
it (`--stage1-replicates N`). **OPEN QUESTION OQ-D**: pending air5
n=3 replication data, this default may be revised to N>1 if
single-trial fit determination proves unstable. The spec flags this
as a tunable; the implementation MUST surface the flag so v0.2 can
re-default without a binary change.

**FR-A.4. All-infeasible exit.**
If NO model in the candidate list is feasible at the target context,
`autotune` MUST exit non-zero with an error block that:

- Names the target context.
- Lists each candidate and its failure reason in order
  (most-informative reason taken from the binary's stderr tail or
  the gate-miss summary).
- Suggests both remediations: a smaller `--target-context Y` and a
  longer / different `--candidate-models ...`. The smallest
  candidate's reason MUST be surfaced first (it carries the highest
  information density for "even 1B can't fit my requirements" cases,
  per FR-H.4).

---

### 5.2 Stage 2 — knob hill-climb within the chosen model

**FR-B.1. Knob search space.**
For the chosen model, `autotune` MUST search the cartesian product
of:

- `kv_bits`: `{4, 8}` (the two values PR #105 accepts), plus the
  unset-default as an explicit third cell so the comparison includes
  the unquantized KV-cache baseline.
- `max_batch`: `{1, 2}` by default. The prototype found `max_batch
  > 1` never helps at single-slot throughput; v1 still tests it so
  the loop re-discovers per machine. The operator MAY widen to
  `{1, 2, 4}` via `--max-batch-axis 1,2,4`.
- `max_context`: a SMALL neighborhood around `--target-context`. v1
  defaults to a single value (the target context itself) and the
  operator MAY pass `--max-context-axis` to opt into a neighborhood.
  This axis is OPTIONAL in v1; the recommended `max_context` in the
  output equals `--target-context` unless the operator opted into
  the axis and a different cell won.

  **`--max-context-axis` parse rules (NORMATIVE — round-2 Z-B.1
  closure).** When the operator passes `--max-context-axis <csv>`,
  the implementation MUST:

  - Parse the value as a comma-separated list of positive integers
    interpreted as ABSOLUTE token caps (not deltas relative to
    `--target-context`).
  - Sort the parsed cells in ascending order before evaluation.
  - Reject any cell whose value is strictly less than
    `--target-context` at FLAG-PARSE TIME (before any DB write,
    before any provider spawn), exiting non-zero with
    `tune_runs.exit_reason = 'config_error'` and a stderr message
    naming the offending cell and the `--target-context` floor.
  - Reject duplicate cells (after sort) at flag-parse time with
    the same `config_error` exit.
  - Treat an EMPTY axis (the default) as the single-cell case
    `[--target-context]`; the recommended `max_context_override`
    equals `--target-context` and FR-F.3's `--apply` writes that
    value.

  These parse rules are part of the binding FR-B.1 contract; the
  §7 CLI summary is reference-only and any §7-vs-FR-B.1 conflict
  is resolved in FR-B.1's favor.

Each cell MUST be evaluated with `stage2_replicates` replicates
(default 3 — **OPEN QUESTION OQ-B** pending air5 n=3 data) at the
target context, with median tps and p95 TTFT recorded.

**FR-B.2. Keep-best decision.**
Throughput is the primary criterion; TTFT is the tiebreaker within
`TPS_TIE_EPSILON` (default `0.02`, i.e. 2% relative — **OPEN
QUESTION OQ-A** pending air5 n=3 data). This is the
`_is_new_best()` semantic from the prototype (`beta/autotune.py`),
reused unchanged in v1:

```
new_tps > best_tps * (1 + TPS_TIE_EPSILON)              -> new wins
abs(new_tps - best_tps) / best_tps <= TPS_TIE_EPSILON   -> tie band
    new_ttft < best_ttft                                -> new wins on TTFT
otherwise                                               -> best held
None tps (unmeasurable)                                 -> never wins
```

A cell that fails the feasibility gate (FR-A.3 applied per-cell)
MUST NOT replace `best`, regardless of throughput.

**FR-B.3. Stage-2 output.**
The output of Stage 2 is one tuple `(model, kv_bits, max_batch,
max_context)` plus the recorded median tps + p95 TTFT + the
replicate count actually used. This tuple feeds the recommendation
surface (FR-F).

---

### 5.3 Default candidate list (curated by the network)

**FR-C.1. Default ordered list.**
v1 ships a default ordered list, largest-first by weight footprint
(parameter count × 4 bits/param for 4-bit quants). The list MUST
cover the parameter counts the network wants represented:

```
1. mlx-community/Qwen2.5-32B-Instruct-4bit        (~17 GB)
2. mlx-community/Qwen2.5-14B-Instruct-4bit        (~8 GB)
3. mlx-community/Qwen2.5-Coder-7B-Instruct-4bit   (~4 GB)
4. mlx-community/Llama-3.2-3B-Instruct-4bit       (~1.8 GB)
5. mlx-community/Llama-3.2-1B-Instruct-4bit       (~0.7 GB)
```

These are MLX-community models with proven prior empirical evidence
(see §1's empirical findings). The list is curated, not enumerated
from HuggingFace; v1 does NOT pull the list from the coordinator
(see §11 v2 deferral).

The largest entry (32B) is intentionally over the median operator's
RAM ceiling — the feasibility gate's job is to reject it cleanly so
the iteration reaches a model that fits. A 16 GB Mac will reject
items 1 and 2 quickly (load failure or OOM during probe) and accept
item 3 or 4 depending on target context.

**FR-C.2. Operator override.**
The operator MAY override the entire list:

- `--candidate-models <id1>,<id2>,<id3>...` — explicit ordered list;
  largest-first ordering is the operator's responsibility.
- `--max-model-size <Nb>` — trim the default list to items whose
  parameter count is at most N billion (e.g. `--max-model-size 16B`
  drops the 32B entry).
- `--min-model-size <Nb>` — drop items below N billion (e.g.
  `--min-model-size 7B` skips the 1B/3B fallbacks; useful when an
  operator wants "fail loudly if my Mac can't serve at least 7B").

When both `--candidate-models` and `--max/min-model-size` are
supplied, the explicit list wins and the size flags are ignored
(emit a warning).

**FR-C.3. List source.**
The default list is a code constant in the v1 binary. Pulling the
list from the coordinator (so the network can ship new entrants
without a binary release) is v2 — see §11. v1's choice keeps the
recipe-replay surface deterministic and offline-friendly; the
coordinator-served list introduces a coordinator-availability
dependency on a workflow that is otherwise fully local.

---

### 5.4 Pre-warm (replaces v0.1's "pre-download" framing)

**FR-D.1. Cache-warm prerequisite + measurement isolation.**
`autotune` MUST ensure each candidate's weights are present in the
local HuggingFace cache BEFORE the feasibility probe begins
measuring tps / TTFT. This is the operative requirement: a
candidate evaluated against a cold cache is unmeasurable because
mlx-swift's load path is on the critical path of the first
request, and a slow network fetch would inflate TTFT and falsely
reject feasible models.

There are two implementation shapes; v1 leaves the choice to the
implementing PR and binds only the measurement-isolation
contract:

- **Shape A (preferred): explicit `models pull <id>`.**
  `autotune` invokes a sibling subcommand (e.g.
  `macprovider-cli models pull <id>` if one is added or already
  exists at implementation time) that fetches weights into the
  same HF cache the runtime reads from. The pull subcommand's
  contract — cache target, gated-repo handling, partial-download
  recovery, progress, cancellation, exit codes — is OUT OF SCOPE
  for SPEC-013 v1; the autotune SPEC's only normative requirement
  is "weights are present when the probe begins." Defining
  `models pull` rigorously is a follow-on (potentially SPEC-013
  v0.3 or a sibling SPEC).
- **Shape B: rely on the runtime's online-fallback during load.**
  The current `ModelRuntime` (per
  `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`) first
  checks the local HF snapshot path and falls back to
  `LLMModelFactory.shared.configuration(id:)`, which can fetch
  online. An implementation MAY rely on this fallback **iff** it
  separately tracks the load wall-clock and excludes it from the
  feasibility metrics computed by FR-A.3. Concretely: the autotune
  MUST measure cold-cache load time as a separate metric, MUST
  warm the cache (by running one disposable request to completion,
  or by waiting for the load to finish before starting the
  measurement window), and MUST NOT count load-fetch wall-clock
  inside the gate-ttft-ms decision. The first-measured request
  MUST land on warm weights.

**Normative contract** (regardless of shape):

1. Cold-cache weight fetch latency MUST NOT contribute to the
   gate-ttft-ms feasibility decision (FR-A.3).
2. A weight fetch failure MUST be recorded with a discrete reason
   distinguishable from a load-time runtime error and from a
   gate-miss (operator-visible).
3. The autotune MUST NOT silently switch HF cache locations
   between runs (would invalidate per-machine recipe replay).

`autotune` does NOT, in v1, normatively require any new
subcommand on the binary. Shape A is the recommended ergonomics;
Shape B is permitted with the measurement-isolation guard.

**FR-D.2. Failure classification: transient vs integrity.**
Pre-warm failures split into two classes with asymmetric handling
(round-1 audit QUESTION D.2 resolved here):

- **Transient failures.** Network down, HTTP 5xx from HF, disk
  full, partial download interrupted, gated-repo access denied
  for the current credentials. Record the candidate as infeasible
  with `notes = "pre-warm transient: <reason>"`, advance to the
  next candidate. The autotune run fails only if EVERY candidate
  hits a transient failure (FR-H.4 applies).
- **Integrity failures.** Signature mismatch, weight hash
  mismatch, repository contents inconsistent with the expected
  shape (e.g. missing tokenizer.json), or any tampering signal.
  These are security-relevant and MUST NOT be silently advanced
  past. The autotune MUST ABORT the whole run with a distinct
  non-zero exit code (`exit_reason =
  'pre_warm_integrity_failure'`), write a `tune_runs` row, and
  emit the offending candidate's reason on stderr. Operator must
  investigate before re-running.

The two classes MUST be distinguishable in `tune_trials.notes` and
in the FR-F.2 JSON. An implementation that classifies all
pre-warm failures as transient (the v0.1 wording) is a contract
violation in v0.2.

---

### 5.5 Provider-conflict safety

**FR-E.1. Pre-flight: refuse if `serve` already running.**
Before starting any candidate provider, `autotune` MUST check for
an existing `macprovider-cli serve` process and an existing
listener on the configured `--port` (default 18080). The check MUST
cover BOTH install paths:

- **launchd-managed install** (per SPEC-003 v0.9.2 §FR-C5,
  the dominant operator install path):
  - launchd label: `live.streamvc.macprovider`
  - plist path:
    `~/Library/LaunchAgents/live.streamvc.macprovider.plist`
  - check method: `launchctl list | awk '/live.streamvc.macprovider/'`
    (matches the existing pattern in
    `phase3-binary/dist/install.sh` line ~923)
- **foreground / manually-run process**: PID match on
  `macprovider-cli serve` argv plus port-listener check on
  `127.0.0.1:<--port>`. The argv-match grep MUST exclude the
  autotune process itself (an `autotune` invocation has
  `macprovider-cli autotune ...` in its argv, not
  `macprovider-cli serve ...`; the match SHOULD use
  whole-word `serve` to avoid false positives).

On conflict, the behavior is:

- **Default (no `--drain`):** refuse with a clear error naming
  the conflicting install path (`launchd-managed` or
  `foreground-PID-<n>`) and the suggested remediation: pass
  `--drain` to stop-then-tune (and optionally `--apply` to
  install the new recipe), or manually stop the process
  yourself.
- **With `--drain`:** stop the live serve gracefully, run the
  tune, then either (a) restore the original serve config and
  restart at the end (default behavior — autotune is a
  diagnostic that does not change the operator's serving
  posture) or (b) apply the new recommendation if `--apply`
  was also passed (the recipe-replacement path).

**Drain sequence on the launchd-managed install path** (binding
to SPEC-003 v0.9.2 §FR-C5):

1. `launchctl bootout gui/$UID/live.streamvc.macprovider` to stop
   the live service. SPEC-003's plist has
   `KeepAlive.SuccessfulExit = false`, so bootout reliably stops
   without auto-restart.
2. Poll for `port_is_free(--port)` with a `--drain-grace` timeout
   (default 30s). If the port is not free in time, abort with
   a clear error — do NOT escalate to SIGKILL on a
   launchd-managed install (the operator's launchd state would
   become inconsistent with the SPEC-003 install).
3. Run the full autotune.
4. On exit, restore by either:
   - Default (no `--apply`): `launchctl bootstrap gui/$UID
     ~/Library/LaunchAgents/live.streamvc.macprovider.plist`,
     leaving the operator's pre-tune config in place.
   - `--apply`: write the new config (per FR-F.3), then
     `launchctl bootstrap` to bring the new config live.

**Drain sequence on the foreground process path:**
SIGTERM the foreground PID, poll for port-free (same grace
period), restart the foreground process at exit only if the
operator explicitly opted in via a separate `--restart-foreground`
flag (default: do nothing — the operator ran the foreground
process manually and can restart it manually).

`--drain` is an explicit opt-in. v1 MUST NOT auto-drain — buyer
traffic is on the line and an unconfirmed drain is the wrong
default.

**FR-E.2. `--no-join` is the default tuning mode.**
While autotune is running, candidate providers MUST start with
`--no-join` (or equivalent: a flag that prevents the candidate
binary from registering with the coordinator pool). The pool MUST
NOT see partial-tuning candidates — they would receive buyer
traffic that the autotune is about to interrupt by killing the
process.

`--no-join` semantics:
- The candidate binary does NOT establish a WS session with the
  coordinator.
- The candidate binary's local `/v1/models`, `/v1/chat/completions`
  etc. surfaces remain reachable on `127.0.0.1:<port>` for
  `autotune`'s own probes.
- On exit, no `state_update reason: "shutdown"` flows to the
  coordinator (because no WS session existed).

The `--no-join` flag is an implementation precondition of SPEC-013
v1; if the `macprovider-cli serve` flag does not exist, the
implementing PR MUST add it. v1 of `autotune` ALWAYS passes it; no
operator override.

---

### 5.6 Recommendation surface

**FR-F.1. Terminal output.**
On successful completion, `autotune` MUST print a clearly delimited
RECOMMENDATION block to stdout (NOT stderr — operators should be
able to `tee` it). The block MUST include:

- The recommended model id (full HF path, e.g.
  `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`).
- The recommended knob settings as concrete `--kv-bits`,
  `--max-batch`, `--max-context` values (with `--max-context` set to
  the operator's `--target-context` unless FR-B.1's max-context
  axis was opted into and a different cell won). The `--kv-bits`
  value is printed as `unset` when the unquantized-baseline cell
  wins (no `--kv-bits` flag emitted in the serve command line).
- The target context the recommendation was tuned for.
- The replicated median tps and p95 TTFT, with the replicate count.
- An `alternates` list: NAME-ONLY model IDs from the input
  candidate list that are SMALLER than the chosen model (and were
  not probed, per the FR-A.2 STOP-on-first-feasible rule). No
  metrics. The list provides operators a copy-paste path to
  manually downsize via `autotune --candidate-models <id>`. If the
  chosen model is the smallest in the input list, the alternates
  list is empty.
- The exact `macprovider-cli serve` command line that the
  recommendation reduces to, copy-pasteable. CLI flag names are
  used here (`--kv-bits`, `--max-context`, `--max-batch`) so the
  line is a literal shell command. The YAML config keys
  (`kv_bits`, `max_context_override`, `max_concurrency_override`,
  per FR-F.3) are SEPARATE from these CLI flag names; the
  `serve_command` line is for shell paste, the `knobs` JSON
  object is for `--apply` round-trip.

Round-1 audit A.1 closure: the `alternates` list replaces v0.1's
`fallbacks` (which was contradictory — STOP-on-first-feasible
means no smaller candidate was ever probed, so fallback metrics
were structurally impossible to emit).

**FR-F.2. JSON output (`--json`).**
With `--json`, the recommendation surface MUST also be emitted as
JSON to stdout, with the following schema (frozen for v1; v2 may add
additive fields):

```json
{
  "spec_version": "SPEC-013 v<producing-version>",
  "run_id": "<uuid>",
  "started_at": "2026-06-18T12:34:56Z",
  "ended_at": "2026-06-18T13:01:22Z",
  "machine": {
    "ram_gb": 16,
    "chip": "Apple M2",
    "os_version": "macOS 26.3.1",
    "binary_version": "1.4.0"
  },
  "inputs": {
    "target_context": 4000,
    "candidate_models": [
      "mlx-community/Qwen2.5-32B-Instruct-4bit",
      "mlx-community/Qwen2.5-14B-Instruct-4bit",
      "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
      "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "mlx-community/Llama-3.2-1B-Instruct-4bit"
    ],
    "stage1_replicates": 1,
    "stage2_replicates": 3,
    "gate_ttft_ms": 60000,
    "tps_tie_epsilon": 0.02
  },
  "recommendation": {
    "model": "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
    "target_context": 4000,
    "knobs": {
      "kv_bits": 4,
      "max_concurrency_override": 1,
      "max_context_override": 4000
    },
    "tps_median": 2.1,
    "ttft_p95_ms": 19500,
    "replicates": 3,
    "serve_command":
      "macprovider-cli serve --model mlx-community/Qwen2.5-Coder-7B-Instruct-4bit --kv-bits 4 --max-batch 1 --max-context 4000"
  },
  "alternates": [
    "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "mlx-community/Llama-3.2-1B-Instruct-4bit"
  ],
  "infeasible": [
    {
      "model": "mlx-community/Qwen2.5-32B-Instruct-4bit",
      "rank": 1,
      "reason":
        "provider exited rc=137 during load (likely OOM); log tail: Metal allocation failed"
    },
    {
      "model": "mlx-community/Qwen2.5-14B-Instruct-4bit",
      "rank": 2,
      "reason":
        "ttft p95 95234ms > gate 60000ms"
    }
  ],
  "recipe_hash": "sha256:<64-lowercase-hex>",
  "db_path": "/Users/op/.config/macprovider/autotune.sqlite"
}
```

Schema notes (round-1 audit F.1 + F.2 closures):

- `recommendation.knobs` uses YAML KEY NAMES
  (`kv_bits`, `max_concurrency_override`, `max_context_override`),
  not CLI flag names. This makes the `--json` output
  round-trippable into `~/.config/macprovider/config.yaml` per
  FR-F.3. Two-token name mapping:
  | YAML key                    | CLI flag (in `serve_command`) | mlx-swift wire site            |
  |-----------------------------|-------------------------------|--------------------------------|
  | `kv_bits` (4 \| 8 \| null)  | `--kv-bits {4,8}` (omitted if null) | `GenerateParameters.kvBits` |
  | `max_context_override`      | `--max-context <N>`           | `GenerateParameters.maxKVSize` + 413 gate |
  | `max_concurrency_override`  | `--max-batch <N>`             | `AsyncSemaphore(value: maxBatch)` |
- `kv_bits` is `null` (JSON) / `NULL` (SQL) / omitted (YAML) /
  the literal string `unset` (terminal display) when the
  unquantized-baseline cell wins.
- `alternates` is a flat array of NAME-ONLY HF model IDs, in
  the same order as the input `candidate_models` list, filtered
  to entries SMALLER than the chosen model and not probed (per
  the STOP-on-first-feasible rule in FR-A.2). Empty if the
  chosen model is the smallest in the input list.
- `recipe_hash` is `sha256:<64-lowercase-hex>` — 32 bytes,
  hex-encoded, 64 ASCII chars in `[0-9a-f]`, with the literal
  prefix `sha256:`. The hash input is the **RFC 8785 JSON
  Canonicalization Scheme (JCS)** serialization of:

  ```json
  {
    "binary_version": "<machine.binary_version>",
    "candidate_models": ["<inputs.candidate_models, in input order>"],
    "chip": "<machine.chip>",
    "model": "<recommendation.model>",
    "knobs": {
      "kv_bits": <value or null>,
      "max_concurrency_override": <value>,
      "max_context_override": <value>
    },
    "ram_gb": <machine.ram_gb>,
    "target_context": <inputs.target_context>
  }
  ```

  Keys sorted lexicographically per JCS, no whitespace, integers
  without trailing zeros, `null` for omitted `kv_bits`. Fields
  EXCLUDED from the hash: `run_id`, `started_at`, `ended_at`,
  `os_version`, `stage1_replicates`, `stage2_replicates`,
  `gate_ttft_ms`, `tps_tie_epsilon`, `tps_median`, `ttft_p95_ms`,
  `replicates`, `alternates`, `infeasible`, `db_path`,
  `serve_command`. The hash identifies a "machine + recipe"
  tuple, NOT an observation; two runs that produce the same
  recommendation on the same machine MUST hash identically even
  if their measured tps differs.
- `spec_version` is the canonical identity of the producing
  spec; writers emit their own producing version (e.g. an
  implementation built against SPEC-013 v0.3 emits
  `"SPEC-013 v0.3"`). Future v0.x revisions MAY add fields
  additively but MUST NOT remove or retype existing fields.
- `recommendation` is `null` (not `{}`) when no model was
  selected (all-infeasible, budget-exhausted-pre-Stage-2, or
  pre-warm integrity-aborted). Ingestion contract:
  `recommendation === null` MUST be handled before reading
  inner fields.

**FR-F.3. `--apply`: write to config.**
`--apply` is the only mode in which `autotune` writes to
`~/.config/macprovider/config.yaml`. It MUST:

1. Be opt-in. v1's default is "show the recommendation, do nothing."
2. Atomically write the new config (temp-file + rename). Concurrent
   reads MUST never see a half-written YAML.
3. Save the prior config as
   `~/.config/macprovider/config.yaml.bak-<unix-ts>-<counter>`
   where `<counter>` is the lowest non-negative integer such that
   the resulting path does not exist (start at 0; increment until
   free). The backup write MUST NOT overwrite an existing file —
   if a collision occurs at every counter from 0 to 65535, abort
   with an error. The backup path MUST appear in stdout so the
   operator can revert. (Round-1 audit F.3 closure: nanosecond
   timestamps are race-prone on macOS HFS+; the counter approach
   is collision-safe and deterministic.)
4. Be idempotent: applying the same recommendation twice produces
   the same config and the same (empty) diff against the saved
   backup.
5. Modify ONLY the keys SPEC-013 owns:
   `model`, `kv_bits`, `max_context_override`,
   `max_concurrency_override`. All other YAML keys
   (`coordinator_endpoint`, `provider_token`, log paths, etc.) MUST
   be carried through verbatim with comments + ordering preserved
   where the YAML library allows. `autotune` is not a config
   rewrite tool. (Round-1 audit F.1 closure: the prior v0.1 key
   names `max_context_tokens` and `max_batch` were the CLI FLAG
   names; the actual YAML keys per
   `phase3-binary/Sources/MacProviderCore/Config.swift` lines
   239-241 are `max_context_override` and
   `max_concurrency_override`. An implementation that wrote the
   flag names would leave the recipe unapplied because the
   binary's config parser would not read them.)
6. Print a single line summarizing what changed, e.g.
   `applied: model=Qwen-7B kv_bits=4 max_concurrency_override=1
   max_context_override=4000 (backup at ...)`.

`--apply` does NOT restart the launchd service by itself. If the
operator passed `--drain` alongside `--apply` per FR-E.1, the
drain sequence handles the restart at exit (launchctl bootstrap
brings up the new config). If `--apply` was used WITHOUT
`--drain`, the operator MUST manually restart for the new config
to take effect — `--apply` prints a follow-up hint to stderr in
this case:

```
applied: ... (backup at ~/.config/macprovider/config.yaml.bak-1718712345-0)
hint: to apply the new recipe live, restart the serve process:
  launchctl bootout gui/$UID/live.streamvc.macprovider && \
    launchctl bootstrap gui/$UID ~/Library/LaunchAgents/live.streamvc.macprovider.plist
```

SPEC-013 v1 does NOT depend on or trigger SPEC-011 warm-swap for
this — `--enable-warm-swap` is off by default per SPEC-011 §3.1
and SPEC-013 stays out of that opt-in.

---

### 5.7 State / DB

**FR-G.1. `tune_trials` table.**
Every per-cell evaluation (Stage 1 probes AND Stage 2 cells) MUST
be persisted as one row in the additive `tune_trials` table. The
schema is the prototype's schema (carried over verbatim from
`beta/autotune.py` so the prototype's existing reporting code keeps
working) plus a `stage` column distinguishing Stage 1 probes from
Stage 2 hill-climb cells:

```sql
CREATE TABLE IF NOT EXISTS tune_trials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    run_id TEXT NOT NULL,
    stage INTEGER NOT NULL,                      -- 1 or 2 (v1 addition)
    model TEXT NOT NULL,
    target_context INTEGER NOT NULL,
    measured_prompt_tokens INTEGER,
    max_tokens INTEGER NOT NULL,
    agg_throughput_tps REAL,                     -- median across replicates
    ttft_p95_ms REAL,                            -- median across replicates
    fits INTEGER NOT NULL DEFAULT 0,
    n_err INTEGER NOT NULL DEFAULT 0,
    kept INTEGER NOT NULL DEFAULT 0,             -- Stage 2 only; 0 in Stage 1
    notes TEXT,
    kv_bits INTEGER,
    max_context_cap INTEGER,
    max_batch INTEGER,
    replicates_n INTEGER
);
CREATE INDEX IF NOT EXISTS idx_tune_trials_run_id ON tune_trials(run_id);
CREATE INDEX IF NOT EXISTS idx_tune_trials_ts ON tune_trials(ts_utc);
```

The `stage` column is a SPEC-013 v0.2 addition. v1 implementations
upgrading from a prototype DB MUST run the migration:

```sql
ALTER TABLE tune_trials ADD COLUMN stage INTEGER NOT NULL DEFAULT 1;
```

(Round-1 audit G.1 closure: the v0.1 wording said "ALTER TABLE ADD
COLUMN stage" without the `DEFAULT 1` clause; SQLite rejects
adding a NOT NULL column to a populated table unless a non-NULL
default is supplied, so the v0.1 migration would have failed on
any prototype DB. The migration must be idempotent — implementers
SHOULD wrap in a `try ... ignore "duplicate column"` pattern
matching the prototype's `_ADDITIVE_TUNE_COLUMNS` ALTER loop.)

After migration, ALL new inserts into `tune_trials` MUST set
`stage` explicitly: `stage = 1` for Stage 1 feasibility probes,
`stage = 2` for Stage 2 hill-climb cells. The DEFAULT 1 is for
backfill of existing prototype rows only; relying on the default
in new code is a contract violation (would silently misattribute
Stage 2 cells as Stage 1 probes).

**Retention.** The DB MUST keep AT LEAST the most recent N runs by
default (default `N = 50`; operator-overridable via
`--retain-runs N`). Older runs are dropped at the START of each
new autotune run, AFTER the new `tune_runs` row has been written.
The retention sweep MUST execute as a SINGLE SQLite transaction
covering both `tune_trials` and `tune_runs` deletes (round-1
audit G.2 closure: a non-transactional sweep that crashes between
the `tune_trials` delete and the `tune_runs` delete leaves orphan
trials or orphan runs, breaking report consistency). `N >= 1` MUST
be enforced; setting to 0 or negative is an error at flag-parse
time.

The DB path defaults to `~/.config/macprovider/autotune.sqlite`
(NOT the prototype's `beta/runs.sqlite` location, which is a
repo-development path). Operator-overridable via `--db-path`.

**FR-G.2. `tune_runs` table.**
One row per autotune invocation. Captures inputs and the final
recommendation, providing a single-row replay surface that doesn't
require scanning `tune_trials` to reconstruct what happened:

```sql
CREATE TABLE IF NOT EXISTS tune_runs (
    run_id TEXT PRIMARY KEY,
    started_at_utc TEXT NOT NULL,
    ended_at_utc TEXT,                       -- NULL if interrupted
    spec_version TEXT NOT NULL,              -- e.g. 'SPEC-013 v0.3'; writer emits its own producing version
    binary_version TEXT NOT NULL,
    machine_ram_gb INTEGER NOT NULL,
    machine_chip TEXT NOT NULL,
    machine_os_version TEXT NOT NULL,
    target_context INTEGER NOT NULL,
    candidate_models_json TEXT NOT NULL,     -- the input list
    stage1_replicates INTEGER NOT NULL,
    stage2_replicates INTEGER NOT NULL,
    gate_ttft_ms INTEGER NOT NULL,
    tps_tie_epsilon REAL NOT NULL,
    recommendation_json TEXT,                -- NULL if no feasible recommendation
    recipe_hash TEXT,                        -- NULL if no recommendation
    applied INTEGER NOT NULL DEFAULT 0,      -- 1 iff --apply was used
    exit_reason TEXT NOT NULL                -- normative enum, see below
);
```

The `recipe_hash` is the FR-F.2 hash. Two `tune_runs` rows with the
same `recipe_hash` represent the same machine + recipe; this is the
v2 sticky comparison key.

**`exit_reason` is a normative enum** (round-1 audit J.3 closure
— v0.1's "or error msg" tail was too loose). Valid values:

| value | meaning | recommendation_json |
|---|---|---|
| `ok` | Stage 1 chose a model; Stage 2 produced a recommendation | non-NULL |
| `interrupted` | SIGINT or SIGTERM stopped the run | NULL if pre-Stage-2; non-NULL with `partial=true` if mid-Stage-2 |
| `no_feasible` | every candidate failed Stage 1 feasibility | NULL |
| `budget_exhausted_no_model_selected` | `--max-duration` hit during Stage 1 | NULL |
| `budget_exhausted_with_partial_recommendation` | `--max-duration` hit during Stage 2; best-so-far emitted | non-NULL with `partial=true` |
| `pre_warm_integrity_failure` | FR-D.2 integrity-failure abort | NULL |
| `provider_conflict` | FR-E.1 refused (no `--drain`) | NULL |
| `config_error` | flag-parse error, DB-open error, or other pre-run setup failure | NULL |
| `internal_error` | unexpected exception with stack trace in `notes` of a partial row | NULL |

Free-form error strings are NOT permitted in `exit_reason`. The
operator-visible error message goes to stderr + the last
`tune_trials.notes` row; `exit_reason` is the machine-readable
classification. Wrappers and reports SHOULD switch on this enum.

---

### 5.8 Failure modes + recovery

**FR-H.1. Ctrl-C is safe.**
SIGINT (Ctrl-C) MUST stop the currently-running candidate provider
within `--drain-grace` seconds (default 10s), write a partial row
to `tune_runs` with `exit_reason = 'interrupted'`, write any
in-flight `tune_trials` row, close the DB, and exit cleanly with a
non-zero status. The prototype's signal handler establishes the
pattern; the Swift-native implementation MAY use Swift's task
cancellation primitives. Either way, post-condition: no orphan
provider, port released, DB in a consistent state.

**FR-H.2. Midway crash: rerun is safe.**
A crashed run leaves its `tune_runs.ended_at_utc` as NULL and any
written `tune_trials` rows as-is. Rerun is safe: a fresh `run_id`
opens a fresh `tune_runs` row; the old run's data is preserved and
reusable by reporting. A future `--resume` flag could skip Stage 1
candidates that the prior crashed run already proved infeasible
(best-effort optimization; deferred from v1's normative contract
— see §11). v1 default behavior is full rerun.

**FR-H.3. Network down during pre-warm.**
A failed pre-warm fetch (Shape A `models pull` exit non-zero, or
Shape B's online-fallback HTTP failure) for candidate K is
classified per FR-D.2:
- **Transient class** (network down, HTTP 5xx, disk full): mark K
  infeasible with reason `"pre-warm transient: <error>"`,
  advance to candidate K+1. The run only fails-with-no-feasible
  if EVERY candidate hits a transient pre-warm failure (then
  FR-H.4 applies). This way, an operator running autotune with
  the 2 largest models pre-cached and a flaky network still gets
  a working recommendation from the smaller cached candidates.
- **Integrity class** (signature mismatch, hash mismatch): ABORT
  the whole run with `exit_reason =
  'pre_warm_integrity_failure'` per FR-D.2; do not advance to
  smaller candidates because the security-relevant failure mode
  warrants operator investigation.

**FR-H.4. All-infeasible: surface most-informative reason.**
Per FR-A.4. The error message MUST lead with the SMALLEST candidate
that failed (the most informative case: "even 1B can't fit your
requirements" tells the operator immediately that their
`--target-context` is too aggressive for the hardware) followed by
each larger candidate's failure reason in size order. This is the
opposite of "first failure wins": the smallest is the most
diagnostic.

---

## 6. Non-functional requirements

**NFR-1. Wall-clock budget per RAM tier.**

Approximate expected wall-clock times (target context = 4000,
defaults, single-replicate Stage 1 + 3-replicate Stage 2):

| RAM tier | Stage 1 (largest-first iteration) | Stage 2 (knob hill-climb) | Total |
|---|---|---|---|
|  8 GB | ~10 min (rejects 32B/14B/7B quickly via OOM-during-load; settles at 3B or 1B) | ~10 min (1B/3B knob space is small and loads are fast) | ~20 min |
| 16 GB | ~30 min (32B rejects, 14B may TTFT-gate; settles at 7B or 3B) | ~20 min (7B loads are ~1 min; 6 cells × 3 replicates) | ~50 min |
| 32 GB | ~45 min (32B may TTFT-gate; settles at 14B) | ~30 min (14B loads are ~2 min; 6 cells × 3 replicates) | ~75 min |
| 64 GB+ | ~60 min (32B fits; one big probe is the dominant cost) | ~35 min (32B loads are ~5 min; 6 cells × 3 replicates) | ~95 min |

These are **expectations**, not contracts. The binding contract is:

- `autotune` MUST accept `--max-duration <seconds>` (default 7200s
  = 2 hours total cap covering Stage 1 + Stage 2).
- On budget exhaustion mid-Stage-2, `autotune` MUST emit the
  best-so-far recommendation and exit non-zero (treating it as a
  "partial recommendation" with a warning).
- On budget exhaustion mid-Stage-1, `autotune` MUST exit non-zero
  with a "tuning incomplete: no model selected" error and a
  suggestion to raise `--max-duration` or trim
  `--candidate-models` / `--max-model-size`.

**NFR-2. Resource impact during tuning.**
`autotune` is single-slot: at any moment, exactly one provider
process is alive at single-batch concurrency. CPU/RAM/thermal
impact MUST be at most one `macprovider-cli serve` process's worth.
No concurrent buyers (enforced by FR-E.2 `--no-join`), no
background workers, no spawn of parallel probes.

The wall-clock budget in NFR-1 already accounts for thermal
throttling on small-RAM Macs (the 8 GB tier's larger candidates
fail to load quickly enough that thermal headroom is preserved for
the small candidates that DO load). v1 does NOT include explicit
thermal pacing.

**NFR-3. Reversibility.**
Pre-tune `~/.config/macprovider/config.yaml` is ALWAYS recoverable
via the `.bak-<unix-ts>-<counter>` file written by `--apply` per
FR-F.3 (collision-safe; the counter ensures two `--apply` runs in
the same wall-clock second never overwrite each other's backup).
If `--apply` was not used, the config was not touched. There is no
case in which an autotune run renders the prior config
unrecoverable.

The recipe DB (`autotune.sqlite`) is additive; an autotune run does
not delete the prior run's `tune_runs` or `tune_trials` rows except
through the retention limit (FR-G.1), which defaults to 50 runs
retained.

**NFR-4. Telemetry / privacy.**
**Nothing leaves the machine.** v1 has NO opt-in or opt-out
telemetry — no upload, no analytics, no remote logging. The machine
fingerprint (`ram_gb`, `chip`, `os_version`, `binary_version`)
appears in `tune_runs.machine_*` columns and in the FR-F.2 JSON
output for local consumption by `console.streamvc.live` (when the
operator chooses to share that JSON), but `autotune` itself
performs no network egress except the **HuggingFace pre-warm
fetch path selected by FR-D.1** — i.e. either:

- **Shape A:** explicit `macprovider-cli models pull <id>` (or
  equivalent operator-invoked fetch) per FR-D.1.
- **Shape B:** the runtime's online fallback during model load
  (`LLMModelFactory.shared.configuration(id:)` reaches HuggingFace
  when the local snapshot is not cached) per FR-D.1's
  measurement-isolation contract.

Both shapes egress only to HuggingFace and only for weight
fetches — no telemetry, no observability beacons, no recipe
upload. An implementation that performs ANY other network egress
during a `autotune` run is a contract violation. (Round-2 N-D.1
closure.)

The coordinator-side recipe registry is v2 territory — see §11.
Even when it ships, it MUST be opt-in. The v1 design intentionally
keeps the recipe wholly local so operators can run autotune on
private/air-gapped Macs (which by definition will use Shape A
with pre-staged weights, since Shape B's online fallback would
fail with a transient-class pre-warm error per FR-D.2).

---

## 7. CLI surface (summary)

This is reference, not normative — the normative surface is the FRs
above. The actual flag set is:

```
macprovider-cli autotune
  --target-context <N>           target context in tokens (default 2000)
  --candidate-models <csv>       override default ordered list (operator order is contract)
  --max-model-size <Nb>          trim default list above this size
  --min-model-size <Nb>          trim default list below this size
  --kv-bits-axis <csv>           Stage 2 kv-bits cells (default 'unset,4,8'; 'unset' = no flag)
  --max-batch-axis <csv>         Stage 2 max-batch cells (default '1,2')
  --max-context-axis <csv>       Stage 2 max-context cells; absolute token caps,
                                 sorted ascending, each >= --target-context
                                 (default empty = use target only)
  --stage1-replicates <N>        default 1
  --stage2-replicates <N>        default 3
  --gate-ttft-ms <N>             default 60000
  --tps-tie-epsilon <F>          default 0.02
  --max-duration <seconds>       default 7200
  --drain-grace <seconds>        FR-E.1 drain grace (default 30)
  --port <N>                     local provider port (default 18080)
  --db-path <path>               default ~/.config/macprovider/autotune.sqlite
  --retain-runs <N>              default 50
  --json                         emit recommendation as JSON
  --apply                        write recommendation to config.yaml
  --drain                        if `serve` is running, drain it before tuning
  --restart-foreground           after `--drain` of a foreground process, restart it at exit
                                 (no effect on launchd-managed installs)
  --dry-run                      print the candidate plan and exit
  --report-only                  re-render the latest run's report and exit
  -v / --verbose                 stream per-trial details to stderr
```

Round-1 audit closures: C.1 (kv-bits default now `unset,4,8`
matching FR-B.1), H.1 (`--resume` removed; still deferred to v2
per §11), B.1 (`--max-context-axis` semantics inlined).

The `unset` token in `--kv-bits-axis` means "evaluate a cell with
no `--kv-bits` flag passed to `serve`" (the mlx-swift unquantized
KV-cache baseline). Representation across surfaces:

| surface | `unset` representation |
|---|---|
| `--kv-bits-axis` CSV | the literal string `unset` |
| FR-F.2 JSON `knobs.kv_bits` | `null` |
| `tune_trials.kv_bits` SQL | `NULL` |
| YAML config `kv_bits` (via `--apply`) | key omitted entirely |
| terminal display | the literal string `unset` |
| `serve_command` line | `--kv-bits` flag omitted entirely |

§7 is REFERENCE-ONLY; the SEMANTICS in §5 (especially the FR-B.1
`--max-context-axis` parse rules and the §5.6 / §5.7 owned-key
sets) are the normative surface. Any conflict between §7 and §5
is resolved in §5's favor at implementation time. The flag shape
above MAY be refined in a future v0.x as long as the §5 semantics
are preserved.

---

## 8. Acceptance criteria

Each AC names the specific behavior the test verifies. Tests MUST
NOT use mock providers exclusively — the autotune subcommand's
contract is "drives a real `macprovider-cli serve` process," so the
critical-path ACs require an integration harness that exercises the
real binary on at least one RAM tier (8 GB is the cheapest to
maintain).

**AC-1. Largest-first iteration STOPS on first feasible.**
Configure candidate list `[X, Y, Z]` where X is infeasible (oversized
candidate id pointing at a too-large model) and Y is feasible. The
run MUST select Y, NOT iterate to Z, NOT emit a Z trial row, and the
RECOMMENDATION block MUST name Y. The `alternates` list MUST
contain exactly `[Z]` (the smaller candidate not probed; name only,
no metrics).

**AC-2. Largest-first iteration ITERATES past infeasible.**
Configure candidate list `[X, Y, Z]` where X is infeasible at the
target context, Y is infeasible, Z is feasible. The run MUST emit
infeasibility rows for X and Y (with `notes` populated) and select
Z. RECOMMENDATION names Z; `alternates` is empty (Z is the
smallest in the list).

**AC-3. All-infeasible exits non-zero with smallest-first reason.**
Configure a candidate list where every candidate is infeasible at the
target context. The run MUST exit non-zero. The error message MUST
lead with the SMALLEST candidate's failure reason (per FR-H.4) and
list each larger candidate's failure in size order. The `tune_runs`
row MUST have `exit_reason = 'no_feasible'` and
`recommendation_json IS NULL`.

**AC-4. Stage 2 hill-climb uses median-of-N + strict-all-feasible.**
For the chosen model with `--stage2-replicates 3`, configure a mock
provider whose 3 replicates produce tps `[2.0, 2.1, 2.05]`. The
recorded `agg_throughput_tps` MUST equal `2.05` (median). With one
replicate erroring (`n_err = 1`), the cell MUST be marked `fits = 0`
regardless of the other replicates' median, per FR-B.2's
strict-all-feasible application of FR-A.3.

**AC-5. TPS tiebreak by TTFT.**
For two Stage 2 cells where cell A has tps=10.0 / ttft=4000ms and
cell B has tps=10.05 / ttft=3000ms (within `TPS_TIE_EPSILON = 0.02`),
the run MUST select cell B (lower TTFT). With cell B's ttft=4500ms
(higher), the run MUST select cell A. This reproduces the
prototype's `_is_new_best` semantics verbatim.

**AC-6. Provider-conflict pre-flight refuses by default.**
With a `macprovider-cli serve` already running on the configured
port, `autotune` (no `--drain`) MUST refuse with a clear error
naming the existing install path (`launchd-managed` or
`foreground-PID-<n>`) and the `--drain` opt-in. The
`tune_runs.exit_reason` MUST be `'provider_conflict'`. This AC
MUST cover BOTH install paths:

- **launchd-managed case:** with `live.streamvc.macprovider`
  loaded via `launchctl bootstrap`, autotune detects it via
  `launchctl list` and refuses; with `--drain`, autotune runs
  `launchctl bootout gui/$UID/live.streamvc.macprovider`,
  completes the tune, and either restarts the original config
  (no `--apply`) or applies + restarts (with `--apply`).
- **foreground case:** with `macprovider-cli serve ...`
  running in a separate shell as the operator's PID, autotune
  detects via argv-match-on-`serve` (not `autotune` — the
  argv-match grep MUST NOT match the autotune process itself);
  with `--drain` and `--restart-foreground`, autotune SIGTERMs,
  tunes, and restarts the foreground process via the original
  argv.

**AC-7. `--no-join` is set on every candidate.**
The implementation MUST always pass `--no-join` (or its equivalent
flag) to every candidate `serve` invocation. A test asserts the
spawn argv contains `--no-join` and the coordinator pool MUST NOT
observe any provider connection during the autotune run (verified
via an integration test that watches the coordinator's
`/admin/pool/check` or equivalent).

**AC-8. Pre-warm failure advances to next candidate (shape-neutral).**
The test MUST exercise the implementation's selected pre-warm
mechanism per FR-D.1 — NOT a specific subcommand name (round-2
N-D.1 closure). Both Shape A and Shape B implementations MUST
satisfy this AC; the test harness MUST provide a fixture that
forces a transient-class pre-warm failure for candidate 1
without specifying HOW:

- **Shape A variant** (the implementation invokes
  `macprovider-cli models pull <id>` or equivalent): mock the
  pull subcommand to exit non-zero (e.g. simulated HTTP 503).
- **Shape B variant** (the implementation relies on the runtime
  online-fallback): block egress to HuggingFace at the
  network-mock layer so the runtime's online fetch fails during
  load; the autotune MUST classify this as a Shape-B pre-warm
  failure (not as a load-runtime-error) by inspecting the
  failure mode against FR-D.1's measurement-isolation contract.

In either variant, the run MUST emit an infeasibility row for
candidate 1 with `notes` containing the pre-warm error message
and the transient/integrity classification (per FR-D.2), proceed
to candidate 2, and end with `tune_runs.exit_reason = 'ok'` IFF
some candidate succeeded, otherwise `'no_feasible'`. A separate
test variant MUST force a Shape A INTEGRITY-class failure
(simulated signature mismatch); per FR-D.2, the whole run MUST
abort with `exit_reason = 'pre_warm_integrity_failure'` —
this asymmetric handling distinguishes AC-8 from the simpler
"advance on any pull failure" pattern.

**AC-9. `--apply` is atomic + backs up + idempotent.**
With `--apply`, a successful run MUST:
- Write the new `config.yaml` atomically via a temp-file-rename
  trace (the test asserts the rename target either matches the
  pre-apply contents or the post-apply contents at every
  observable moment, never a partial write).
- Save the prior config as
  `config.yaml.bak-<unix-ts>-<counter>` with file contents
  byte-identical to the pre-apply config. With two `--apply`
  runs in the same wall-clock second, the second backup MUST
  have `<counter>` greater than the first; neither backup is
  overwritten.
- Modify ONLY the four keys SPEC-013 owns (`model`, `kv_bits`,
  `max_context_override`, `max_concurrency_override`). A test
  asserts every non-owned key (e.g. `coordinator_endpoint`,
  `provider_token`) is byte-identical pre/post and that the
  binary's `Config.swift` parser actually reads the four owned
  keys from the post-apply file (catches the v0.1 bug where
  the spec named flag-names instead of YAML-key-names).
- Re-running with the same recommendation produces zero diff
  against the saved backup (idempotence).

**AC-10. Ctrl-C cleanup.**
SIGINT during a candidate probe MUST: stop the provider within
`--drain-grace` seconds, leave the port free, write the partial
`tune_runs.exit_reason = 'interrupted'`, and exit. A subsequent
autotune run MUST be able to open the DB and start a fresh run
without errors. A test asserts the port is free post-SIGINT (with a
small settle window) and that no orphan `macprovider-cli` process
remains.

**AC-11. JSON output schema stability.**
With `--json`, the emitted JSON MUST validate against the FR-F.2
schema. A schema regression test asserts every documented field is
present with the documented type. Additive fields are allowed in
v0.2+; field removal or type change is a SPEC bump.

**AC-12. Recipe hash determinism.**
The `recipe_hash` MUST satisfy three properties simultaneously:

1. **Reproducible same-machine.** Two `autotune` runs on the same
   machine + same `binary_version` + same flags producing the
   same recommendation emit IDENTICAL `recipe_hash`, even though
   observed tps/ttft and run_id/timestamps differ between the
   two runs (the hash input domain excludes observations).
2. **Reproducible cross-implementation.** A reference vector
   (fixed machine + inputs + recommendation, JSON pre-computed)
   is hashed by both an Option-A (Swift) and an Option-B
   (Python) implementation; both produce IDENTICAL hash. This
   tests the RFC 8785 JCS canonicalization.
3. **Sensitive to machine.** Two runs on different RAM tiers
   (e.g. 8 GB vs 16 GB) producing coincidentally-the-same
   recommendation `model + knobs + target_context` emit
   DIFFERENT `recipe_hash` (because `machine.ram_gb` is in the
   hash input).
4. **Sensitive to binary.** Same machine, same recommendation,
   different `machine.binary_version` → DIFFERENT hash. This
   is the v2 sticky's "did this Mac's recipe drift after a
   binary update?" signal.

The format MUST be `sha256:<64-lowercase-hex>`; a test asserts
the prefix is exactly `sha256:`, the suffix matches `^[0-9a-f]{64}$`,
and no upper-case characters appear.

**AC-13. Wall-clock budget enforcement.**
With `--max-duration 60` (very small), the run MUST exit
non-zero within the budget plus a small grace. If the budget exhausts
mid-Stage-2 with a best-so-far recommendation, the run MUST emit
that recommendation with a "partial" warning, write `exit_reason =
'budget_exhausted_with_partial_recommendation'`, and exit non-zero.
If exhausted mid-Stage-1 with no chosen model, `exit_reason =
'budget_exhausted_no_model_selected'` and the JSON output's
`recommendation` MUST be `null`.

**AC-14. Default candidate list is honored.**
With no `--candidate-models` flag, the run MUST iterate the v1
default list (FR-C.1) in the specified order. A test asserts the
first candidate the run probes is `mlx-community/Qwen2.5-32B-Instruct-4bit`
even on hardware that will reject it.

**AC-15. Operator override beats size flags.**
With both `--candidate-models a,b,c` and `--max-model-size 7B`,
the explicit list MUST win and the size flag MUST be ignored with a
stderr warning. A test asserts the warning is emitted and the
iterated candidates are exactly `[a, b, c]`.

**AC-16. `tune_trials.stage` populates correctly.**
Stage 1 probes MUST be recorded with `stage = 1`; Stage 2 cells MUST
be recorded with `stage = 2`. A test asserts the row count per
stage matches the expected: stage 1 count = (candidates iterated
until chosen model); stage 2 count = (kv_bits axis size × max_batch
axis size × max_context axis size). A separate test verifies the
v0.2 migration SQL (`ALTER TABLE tune_trials ADD COLUMN stage
INTEGER NOT NULL DEFAULT 1`) runs successfully against a populated
prototype DB and that existing rows acquire `stage = 1`.

**AC-17. Operator-supplied order is honored verbatim (no internal
rerank).** [round-1 J.1 closure — load-bearing biggest-fit guard]
Configure
`--candidate-models mlx-community/Llama-3.2-1B-Instruct-4bit,mlx-community/Qwen2.5-32B-Instruct-4bit`
on hardware where BOTH models are feasible at the target context.
The recommendation MUST be the 1B model — because the operator's
supplied order put 1B first, even though 32B is the larger model
and would have won under the default-list largest-first ordering.
A test asserts:
- `tune_trials` has exactly ONE stage-1 row (for 1B) — the 32B
  was never probed, because Stage 1 STOPped on first feasible
  per FR-A.2.
- The recommendation's `model` field is the 1B model id.
- `alternates` is empty (no candidates SMALLER than the chosen
  1B in the input list).
- A failure mode this catches: an implementation that
  pre-sorts `--candidate-models` by parameter-count-descending
  before Stage 1 iteration would (wrongly) pick 32B and pass
  AC-14/AC-15 — only AC-17 detects this. The biggest-fit
  guarantee depends entirely on operator-supplied order being
  the contract per FR-A.1.

**AC-18. Optional `--max-context-axis` evaluates extra cells and
can win.** [round-1 J.2 closure]
With `--target-context 4000 --max-context-axis 4000,8000`,
configure a mock provider whose 8000-cell produces higher median
tps than the 4000-cell (within feasibility). The recommendation's
`knobs.max_context_override` MUST be 8000 (the winning cell). A
test asserts: `tune_trials` has 2 Stage-2 cell rows per
(kv_bits, max_batch) combination, and the recommendation reflects
the winning cell. Invalid `--max-context-axis 2000,4000` (the
2000 cell is below `--target-context 4000`) MUST fail at
flag-parse time with a clear error and `exit_reason = 'config_error'`.

**AC-19. `--max-model-size` alone trims the default list.** [round-1
J.3 closure]
With `--max-model-size 8B` and no `--candidate-models`, the
iteration MUST start at the 7B candidate (the 32B and 14B
defaults are trimmed). A test asserts the first probed candidate
is `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` and no probe
of the 14B or 32B occurs (no `tune_trials` row with those model
IDs). Combined with `--min-model-size 3B`, the iteration MUST
also skip the 1B entry.

---

## 9. Open questions

_TRIAGE NOTE 2026-06-26 (`docs/OPEN_QUESTIONS.md`): OQ-A..D below are RESOLVED as **frozen at v0.3 placeholder defaults**. The air5 n=3 replication run that gated the v0.2 confirm/adjust cycle never landed in `beta/DECISION_CRITERIA.md`, and SPEC-013 IMPL shipped (PR #109) without it. Production has not signalled the placeholders are wrong. **OQ-E remains conditionally normative** — the §9 OQ-E decision threshold (5% mismatch on the 10-paired-run sampling protocol) still binds future implementers IF a thermal-bias suspicion ever surfaces in production; the freeze closes the air5-gating only, not the v0.4 trigger condition._

All four open questions below are flagged as **pending the in-flight
air5 n=3 replication run**. Each names the placeholder default and
the decision threshold; v0.2 either confirms the placeholder or
adjusts it via a narrow PR with the air5 data attached.

**OQ-A. `TPS_TIE_EPSILON` default given measured variance.**
v0.1 uses `0.02` (2% relative), inherited from the prototype. The
correct value depends on the measured trial-to-trial tps variance on
air5 at n=3 replicates. If σ(tps)/μ(tps) > 0.02, the placeholder is
too aggressive (real differences will be flattened to "tie"); if
< 0.005, the placeholder is too loose (noise will register as a
real difference). v0.2 picks whichever bound the data supports.

**OQ-B. `stage2_replicates` recommended default.**
v0.1 uses `3`, balancing wall-clock against noise. Quantitative
decision rule (round-1 K.1 closure): at the chosen replicate
count, the **minimum discriminable tps gap** (the smallest delta
that the median-of-N comparison can reliably distinguish from
noise, at 90% confidence) MUST be ≤ `TPS_TIE_EPSILON × measured
median tps`. If air5 n=3 data shows minimum-discriminable-gap >
TPS_TIE_EPSILON × median across the typical Stage 2 cell set,
v0.3 raises the default to 5 (Stage 2 wall-clock grows linearly;
the NFR-1 budget table absorbs the change).

**OQ-C. Should `kv_bits` remain a search axis or become a fixed
default?**
Prior runs showed kv-bits=8 outperformed kv-bits=4 on every air5
model (1B +12%, 3B +58%). If the air5 n=3 replication confirms this
generalizes (i.e. kv-bits=8 wins on every model on every RAM tier
within `TPS_TIE_EPSILON`), v0.2 may drop kv-bits from Stage 2 search
and bake it in as the default. Until then, v0.1 keeps it as an axis
so the loop re-discovers per machine — the risk of premature
fixation (a future MLX-swift version changing the kv-bits trade-off)
is higher than the cost of one extra cell.

**OQ-D. Does Stage 1 fit-determination need N > 1 replicates?**
v0.1 uses `stage1_replicates = 1` (cheap probe). Quantitative
decision rule (round-1 K.1 closure): single-trial Stage 1 fit
determination is "stable enough" iff measured **false-fit rate**
(rules a model feasible at N=1 but infeasible at N=3) ≤ 5% AND
**false-reject rate** (rules infeasible at N=1 but feasible at
N=3) ≤ 5% across the air5 candidate set. If air5 n=3 data shows
either rate > 5%, v0.3 raises the default to N=2 (or to N=3 if
the rate exceeds 15%). The wall-clock cost is meaningful in
Stage 1 (the iteration runs across the whole candidate list), so
the change requires real evidence.

**OQ-E. Thermal / cell-order bias in Stage 2.** [round-1 K.2
closure — new in v0.2]
NFR-2 v1 has no explicit thermal pacing, and Stage 2's deterministic
axis order means later cells run on a hotter machine than earlier
cells. If air5 n=3 data shows the keep-best decision is biased
toward earlier-tested cells (i.e. cell-order rather than cell-quality
drives the recommendation), v0.3 will need ONE of:
- randomized cell order (with the seed recorded in `tune_runs` for
  replay)
- a fixed inter-cell cooldown delay (e.g. 30s idle between cells)
- a thermal-state probe before each cell that pauses until the
  Mac is thermally-quiet

Decision threshold: if the same Stage 2 cell set, evaluated in
reverse order, would produce a DIFFERENT keep-best winner more
than 5% of the time on air5 n=3 data, the bias is load-bearing
and v0.4 must address it.

**Sampling protocol** (round-2 N-OQ-E.1 closure). Measure by
running the same Stage 2 cell set in FORWARD and REVERSE order
for at least **10 paired runs** on air5 (one forward run + one
reverse run = one pair). Between paired runs, idle the machine
for at least 60s to dissipate heat soak from the prior run.
Compare keep-best winners per pair; if `mismatch_pairs / 10 >
0.05` (i.e. ≥ 1 mismatch in 10 pairs), the bias is load-bearing
and v0.4 must add ONE of randomized cell order (with the seed
recorded in `tune_runs` for replay), a fixed inter-cell cooldown
delay, or a thermal-state probe + pause-until-quiet gate. 10
pairs is the minimum; the operator MAY run more pairs to tighten
the confidence interval but the 5% threshold and pair-mismatch
metric are normative.

v1 ships the deterministic order unchanged pending the data;
operators are warned in §6 NFR-2.

---

## 10. Implementation note (Swift-native vs Python-prototype wrapper)

v1 of SPEC-013 does NOT pick between two viable implementation
shapes. The implementing PR makes the call. The trade-off:

**Option A: Swift-native subcommand inside `macprovider-cli`.**
- Pro: consistent with the rest of the CLI; one binary; one
  release pipeline; can directly hold the candidate provider's
  subprocess handle without `pkill`; can opt into SPEC-011
  warm-swap in a future v2 without an FFI boundary; clean install
  story (no Python runtime required).
- Pro: signal handling, drain semantics, and atomic config writes
  match the rest of the Swift binary's patterns.
- Con: Swift-native re-implements the prototype's harness +
  measurement layer (~2 weeks of work to match the prototype's
  parity).
- Con: Loses the prototype's HTML report (or re-implements it in
  Swift, which is more work than its value).

**Option B: Ship the Python prototype as the v1
implementation, invoked as `macprovider-cli autotune` via a Swift
shim that exec's `python3 beta/autotune.py`.**
- Pro: lands faster (prototype is ~1000 lines and works today);
  reuses harness.py + sweep.py + sweep_report.py unchanged.
- Pro: HTML report ships for free.
- Con: requires a working Python 3 environment on every operator
  Mac. macOS ships system Python but `requests` is not in the
  stdlib; either bundle a wheel or `pip install` at install time.
- Con: Two languages in the operator install story.
- Con: SPEC-011 warm-swap integration (v2) is harder across the
  subprocess boundary.
- Con: The `models pull <id>` FR-D.1 dependency still needs a
  Swift-side subcommand; option B requires both surfaces.

v1 SPEC is neutral. The implementing PR justifies the choice in its
description and the audit pass on the implementation calls out any
divergence from the spec's FRs that the choice introduces.

---

## 11. Out of scope for v1 (queued for v2)

| Feature | Why deferred |
|---|---|
| Coordinator-served candidate list (so the network can ship new entrants without a binary release) | FR-C.3 explicitly defers. Requires SPEC-014 (or a SPEC-010 extension) defining the wire surface for the coordinator-served list, plus a freshness / signature contract. Not blocking the v1 product strategy. |
| Per-provider recipe attestation (the coordinator verifies "this provider really ran the recipe it claims") | Coupled to SPEC-008 v0.3 Pillar A. Useful for trust tiers; not load-bearing for "biggest-fit recommendation." |
| Sticky-affinity from recipes (route buyer requests preferentially to providers whose recipe matches a buyer's pin) | Coupled to SPEC-004 routing. Useful for "stable buyer experience across reconnects"; SPEC-013 v1 stays out of routing. |
| Automatic re-tune on hardware/binary changes (cron-style "autotune ran last on binary v1.4.0; you're now on v1.5.0; run again?") | SPEC-013 v2 can add a status check (`macprovider-cli autotune --check-stale`) that recommends a re-tune; v1 leaves this to the operator. |
| Pareto-frontier UX ("here are 3 candidates: biggest, fastest, balanced") | v1 is opinionated and singular per the product framing in §1. v2 can add `--show-pareto` if operators ask for it. |
| Multi-model serving on one Mac (warm-pool of multiple loaded models) | Architectural; out of scope for an autotune subcommand. |
| SPEC-011 warm-swap-driven tuning (load one provider once, swap models via the warm-swap path to avoid load-per-candidate cost) | SPEC-011 v0.5 is opt-in via `--enable-warm-swap`. v1 of autotune stays on the prototype's process-restart model. v2 can opt-in. |
| `--resume` for crashed runs (FR-H.2 mentions; v1 default is full rerun) | Useful, but v1's correct contract is "rerun is safe and produces equivalent results"; the optimization is additive. |

The successor SPEC for items 1, 4, 5 is provisionally SPEC-014 (the
recommended-catalog surface anticipated by SPEC-011 §8). SPEC-013 v2
and SPEC-014 v1 ship together if they ship at all.

**Cross-spec renumber note** (round-1 audit M.1 closure):
SPEC-010 §11 and SPEC-011 §8/§11 still cite "SPEC-013" with the
recommended-catalog meaning, written before SPEC-013 was claimed
for autotune. The renumber assignment is now:

- **SPEC-013** (this spec) = autotune.
- **SPEC-014** (provisional, not yet drafted) = coordinator-served
  recommended catalog (the "future" referenced by SPEC-011 §8).

A follow-up documentation-only patch SHOULD update the
SPEC-010 and SPEC-011 cross-references when convenient (not a
v1 blocker because the locked specs' references are
forward-looking-aspirational, not normative). The patch
candidates are:

- SPEC-010 §11 (line ~1328): rewrite "SPEC-013 (future)" → "SPEC-014 (provisional)"
- SPEC-011 §8 table row "Recommended catalog ... SPEC-013 (future)": same
- SPEC-011 §11 references the same — same.

This SPEC-013 v0.2 takes the number for autotune unambiguously.

### Post-lock documentation checklist

When SPEC-013 v0.2 (or a successor v0.x) reaches LOCK status, the
operator SHOULD complete the following lifecycle updates as
out-of-PR documentation work (round-1 audit M.2 — listed but
deferred from the binding contract):

1. Append a decision-log entry to `beta/DECISION_CRITERIA.md`
   summarizing: the locked biggest-fit decision, the chosen
   implementation shape (Option A Swift-native vs Option B
   Python wrapper), what shipped in v1, what was deferred to v2
   (recommended catalog, recipe attestation,
   sticky-affinity-from-recipes, warm-swap-driven tuning).
2. Add a one-line note to SPEC-003 v0.9.2's onboarding flow:
   "after install, consider running `macprovider-cli autotune`
   to find the best model for your Mac." (SPEC-003 is locked,
   so this is a v0.10 candidate or a CLAUDE.md addition.)
3. Patch the cross-spec renumber per the note above (SPEC-010,
   SPEC-011).
4. Close PR #103 (the Python prototype on
   `spike/provider-model-autotune`) — either by rebasing onto
   the SPEC-013 v1 implementing PR (Option B) or by closing as
   superseded (Option A).
5. Update `specs/README.md` SPEC-013 row to "LOCKED" when
   appropriate.

These steps are not v1 implementation work; they are spec /
project-memory hygiene that the operator performs when the spec
locks.

---

## 12. Migration note from the PR #103 prototype

The PR #103 Python prototype (`beta/autotune.py`,
`spike/provider-model-autotune` branch) is the implementation
reference for everything SPEC-013 reuses. This note enumerates what
survives, what changes, and what is rejected.

### What survives (reuse verbatim)

- **Provider lifecycle.** `start_provider` /
  `wait_for_ready` / `stop_provider` semantics. Including the
  `pkill -f "macprovider-cli serve"` settle pattern (Option B
  implementation) or the equivalent Swift subprocess handle (Option
  A). The invariant "one provider at a time, port released before
  the next candidate" is unchanged.
- **`tune_trials` schema.** The prototype's schema is carried over
  verbatim (FR-G.1) with one additive `stage` column. Existing rows
  upgrade with `stage = 1` default (no data loss).
- **`_is_new_best()` semantics.** The keep-best decision with
  `TPS_TIE_EPSILON = 0.02` TTFT tiebreak is reused unchanged for
  Stage 2 (FR-B.2). This is the part of the prototype that earns
  its keep — it's a small, well-validated piece of decision logic
  the v0.1 SPEC inherits.
- **Cold-cache load classification.** The prototype does NOT have
  an explicit pre-download step — `evaluate_candidate` starts
  `serve`, waits for `/v1/models`, and records load failures
  (offline-mode error, cache miss, OOM) as infeasible trial
  rows via `_tail_log`. SPEC-013 v0.2 FR-D replaces this
  implicit-cold-cache behavior with an explicit pre-warm
  prerequisite + measurement-isolation contract. What survives
  is the failure-classification PATTERN — both spec and
  prototype record load failures with a discriminated reason in
  `notes`; what changes is that the spec REQUIRES weights to be
  cache-warm BEFORE measurement, where the prototype lets the
  load happen during the measurement window.
  (Round-1 audit L.1 closure: v0.1's wording overstated the
  prototype's pre-download surface — the prototype has none.)
- **`--replicates N` aggregation.** Median tps + p95 TTFT,
  strict-all-feasible. SPEC-013 v1 names the two stage-specific
  flags (`--stage1-replicates`, `--stage2-replicates`) but the
  per-cell aggregation logic is the prototype's.
- **Signal handler / Ctrl-C safety.** FR-H.1 inherits the
  prototype's `signal.SIGINT` / `signal.SIGTERM` cleanup pattern.

### What changes (rejected from the prototype)

- **The objective.** The prototype hill-climbs over a cartesian
  `(model × ctx × kv-bits × max-batch)` space and keeps the cell
  with the highest median tps. This produces "find the
  highest-throughput model" — the very anti-pattern SPEC-013 §1
  rejects. SPEC-013 v1 replaces the prototype's single-stage
  cartesian max-tps loop with the two-stage "largest-first
  feasibility iteration → in-model knob hill-climb" pipeline (§3,
  FR-A, FR-B).
- **The candidate list.** The prototype's default
  `DEFAULT_MODELS = [1B, 3B, Phi-3.5-mini]` is rejected. SPEC-013
  v1 defaults to the 5-entry largest-first list (FR-C.1) covering
  32B / 14B / 7B / 3B / 1B. The 32B entry is intentionally over the
  median operator's RAM ceiling — the feasibility gate rejects it
  cleanly.
- **The coordinator-join behavior.** The prototype's docstring
  notes "Joining is a harmless side effect" and lets each candidate
  briefly register. SPEC-013 v1 FR-E.2 REQUIRES `--no-join` for
  candidates so the pool never sees partial-tuning providers.
- **The DB location.** The prototype uses `beta/runs.sqlite` (a
  repo-development path). SPEC-013 v1 uses
  `~/.config/macprovider/autotune.sqlite` (operator-home).
- **The recommendation surface.** The prototype emits a winner line
  and an HTML report. SPEC-013 v1 adds the FR-F.1 terminal
  RECOMMENDATION block, the FR-F.2 JSON schema, and the FR-F.3
  `--apply` flag. The HTML report MAY ship in Option B but is not
  normative.

### What is provisional (depends on the air5 n=3 replication run)

- All four numerical defaults flagged in §9 (`TPS_TIE_EPSILON`,
  `stage1_replicates`, `stage2_replicates`, kv-bits axis).

The prototype branch (`spike/provider-model-autotune`) MUST NOT be
merged as-is. The implementing PR for SPEC-013 v1 either supersedes
it (Option A) or rebases it onto the SPEC-013 design (Option B with
the objective rewrite).

---

## 13. References

- [SPEC-001 v1.4](SPEC-001-phase3-binary.md) — Phase 3 binary
  (PR #105 added `--kv-bits`, `--max-context`, `--max-batch` serve
  flags; SPEC-013 wraps them)
- [SPEC-003 v0.9.2](SPEC-003-open-onboarding.md) — install /
  onboarding (SPEC-013's `autotune` answers the "what should I
  serve?" question the install flow currently leaves open)
- [SPEC-010 v1.5](SPEC-010-model-catalog.md) — provider model
  catalog (SPEC-013 produces a single chosen model; SPEC-010
  defines how that model is advertised to the network)
- [SPEC-011 v0.5](SPEC-011-operator-pushed-warm-swap.md) —
  operator-pushed warm swap (SPEC-013 v1 stays out of warm-swap;
  §11 notes the v2 opt-in)
- [PR #105](https://github.com/Augustas11/macprovider/pull/105) —
  `--kv-bits` / `--max-context` / `--max-batch` serve knobs
- [PR #103](https://github.com/Augustas11/macprovider/pull/103) —
  Python prototype on `spike/provider-model-autotune` branch
  (`beta/autotune.py`)
- `beta/autotune.py` on the `spike/provider-model-autotune` branch
  — the implementation reference for the parts SPEC-013 reuses
  (lifecycle, schema, `_is_new_best`, signal handling)
