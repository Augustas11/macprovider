# SPEC-013 — `macprovider-cli autotune` subcommand

**Version:** 0.1 (initial draft)
**Status:** Draft (pre round-1 audit)
**Date drafted:** 2026-06-18
**Depends on:** SPEC-001 v1.4 (`macprovider-cli serve` flags `--kv-bits`, `--max-context`, `--max-batch` per PR #105), SPEC-010 v1.5 (provider-advertised `supported_models[]` shape, model id semantics)
**Companion to (LOCKED):** SPEC-002 v1.3.5 (no coordinator-side change required), SPEC-003 v0.9.2 (autotune is invoked before / between `macprovider-cli serve` lifetimes; not part of install flow)
**Related (future):** SPEC-011 v0.5 (warm-swap; opt-in coupling deferred to v2 — see §11)

SPEC-013 is operator-facing CLI surface only. It MUST NOT modify any
SPEC-001 wire protocol, SPEC-002 coordinator behavior, SPEC-005
billing/settlement, or SPEC-006 buyer API surface. With autotune
unused, every provider's serving behavior is byte-identical to
pre-SPEC-013.

---

## Change log

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
                     fallbacks = smaller candidates that ALSO fit
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
  fallbacks (if you'd rather serve a smaller model):
    2. mlx-community/Llama-3.2-1B-Instruct-4bit  (9.7 tok/s)

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

### 5.4 Pre-download integration

**FR-D.1. Pre-download via `models pull <id>`.**
`autotune` MUST ensure each candidate's weights are present in the
HuggingFace cache before invoking `macprovider-cli serve` for that
candidate. v1 picks **option (a)** from the prompt: `autotune`
invokes `macprovider-cli models pull <id>` as an explicit
operator-visible step before each candidate's feasibility probe.

The rationale for this over option (b) ("flip the binary into
temporary online mode during tune"):

- **Explicit and observable.** A failed download is a discrete
  failure with a discrete subcommand at the top of the trace, not a
  silent stretch of online-mode behavior buried inside a serve
  process.
- **No new global state on the binary.** Option (b) requires
  `macprovider-cli serve` to grow a "temporarily-online" runtime
  mode and a transition contract for it. That is more surface area
  to test and ship than a sibling subcommand.
- **Composable.** Operators can pre-pull the candidate list manually
  (`macprovider-cli models pull <id>` for each) and then run
  `autotune` in a network-isolated environment. Option (b) makes
  this awkward.
- **Matches existing ergonomics.** `pull` / `download` is the
  conventional CLI shape; SPEC-003 v0.9.2 already exposes a model
  selection prompt at install time and operators expect a
  per-model fetch surface.

**Normative dependency.** SPEC-013 v1 implicitly requires the
`macprovider-cli models pull <id>` subcommand to exist. If it does
not exist at implementation time, the implementing PR MUST add it;
the SPEC for that subcommand is short enough to fit alongside the
autotune work (a one-screen `pull` subcommand that flips HF online
mode for the duration of one fetch and writes weights to the same
HF cache the runtime reads from). The autotune SPEC does NOT
normatively specify the `pull` subcommand's flags beyond the call
shape `macprovider-cli models pull <id>`.

**FR-D.2. Pre-download failure is candidate-level fatal.**
If `models pull <id>` fails for a candidate (network down, weights
missing from HF, signature mismatch, disk full), that candidate is
recorded as infeasible-with-reason and `autotune` advances to the
next candidate. The autotune run does NOT fail unless EVERY
candidate fails pre-download (in which case FR-H.4 applies).

---

### 5.5 Provider-conflict safety

**FR-E.1. Pre-flight: refuse if `serve` already running.**
Before starting any candidate provider, `autotune` MUST check for an
existing `macprovider-cli serve` process and an existing listener on
the configured `--port` (default 18080). If either is present:

- Default: refuse with a clear error, naming the conflicting PID
  and the suggested remediation (`--drain` opt-in, or a manual
  `launchctl unload` for launchd-managed installs, or simply
  killing the process).
- With `--drain`: `autotune` gracefully stops the live serve
  (matching SPEC-011 v0.5 §3.4 drain semantics if warm-swap is
  enabled, otherwise a clean process stop), runs the tune, then
  either (a) restores the original serve config at the end (default
  behavior) or (b) applies the new recommendation if `--apply` was
  also passed.

`--drain` is an explicit opt-in. v1 MUST NOT auto-drain — buyer
traffic is on the line and an unconfirmed drain is the wrong
default. The check MUST cover both the launchd-managed install
(`com.macprovider.cli` plist) and a manually-run foreground
process; the launchd-managed install's drain MUST restore the plist
state on exit (unless `--apply` says otherwise).

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
  axis was opted into and a different cell won).
- The target context the recommendation was tuned for.
- The replicated median tps and p95 TTFT, with the replicate count.
- Fallbacks: every smaller candidate from the candidate list that
  ALSO passed Stage 1 feasibility, with its Stage-1 single-replicate
  tps. Operators who want to manually choose a smaller / faster
  model see what's available without re-running.
- The exact `macprovider-cli serve` command line that the
  recommendation reduces to, copy-pasteable.

**FR-F.2. JSON output (`--json`).**
With `--json`, the recommendation surface MUST also be emitted as
JSON to stdout, with the following schema (frozen for v1; v2 may add
additive fields):

```json
{
  "spec_version": "SPEC-013 v0.1",
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
      "max_batch": 1,
      "max_context": 4000
    },
    "tps_median": 2.1,
    "ttft_p95_ms": 19500,
    "replicates": 3,
    "serve_command":
      "macprovider-cli serve --model mlx-community/Qwen2.5-Coder-7B-Instruct-4bit --kv-bits 4 --max-batch 1 --max-context 4000"
  },
  "fallbacks": [
    {
      "model": "mlx-community/Llama-3.2-3B-Instruct-4bit",
      "tps_stage1": 4.9,
      "rank": 4
    },
    {
      "model": "mlx-community/Llama-3.2-1B-Instruct-4bit",
      "tps_stage1": 9.7,
      "rank": 5
    }
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
        "ttft p95 23500ms > gate 60000ms passed but n_err=1 streaming abort"
    }
  ],
  "recipe_hash": "sha256:<32-byte-hex>",
  "db_path": "/Users/op/.config/macprovider/autotune.sqlite"
}
```

The JSON schema is the canonical format for `console.streamvc.live`
ingestion. The `recipe_hash` is a SHA-256 over the canonical-JSON
form of `{machine, inputs, recommendation.knobs, recommendation.model}`
and is the v2 sticky identifier for "this Mac + this recipe."
v1-side it has no semantic use beyond display; it MUST still be
emitted so v2 ingestion is back-compatible.

**FR-F.3. `--apply`: write to config.**
`--apply` is the only mode in which `autotune` writes to
`~/.config/macprovider/config.yaml`. It MUST:

1. Be opt-in. v1's default is "show the recommendation, do nothing."
2. Atomically write the new config (temp-file + rename). Concurrent
   reads MUST never see a half-written YAML.
3. Save the prior config as `~/.config/macprovider/config.yaml.bak-<unix-ts>`.
   The backup path MUST appear in stdout so the operator can revert.
4. Be idempotent: applying the same recommendation twice produces
   the same config and the same (empty) diff against the saved
   backup.
5. Modify ONLY the keys SPEC-013 owns:
   `model`, `kv_bits`, `max_context_tokens`, `max_batch`. All other
   YAML keys (coordinator_endpoint, provider_token, log paths, etc.)
   MUST be carried through verbatim. `autotune` is not a config
   rewrite tool.
6. Print a single line summarizing what changed, e.g.
   `applied: model=Qwen-7B kv_bits=4 max_batch=1 max_context=4000
   (backup at ...)`.

`--apply` does NOT restart the launchd service. If the operator's
`macprovider-cli serve` was running under launchd, they MUST
manually run `launchctl unload ... && launchctl load ...` (or the
equivalent SPEC-003 v0.9.2 install-script helper if one exists) to
pick up the new config. SPEC-013 v1 does NOT depend on or trigger
SPEC-011 warm-swap for this.

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

The `stage` column is a SPEC-013 v0.1 addition; v1 implementations
MUST `ALTER TABLE ADD COLUMN stage` if upgrading from a prototype
DB. Default value is `1` for existing rows so historical reports
don't crash.

**Retention.** The DB MUST keep AT LEAST the most recent N runs by
default (default `N = 50`; operator-overridable via
`--retain-runs N`). Older runs are dropped on each new run start
(scope: delete `tune_trials` and `tune_runs` rows whose `run_id` is
not in the most recent N). `N >= 1` MUST be enforced; setting to 0
or negative is an error at flag-parse time.

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
    spec_version TEXT NOT NULL,              -- 'SPEC-013 v0.1'
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
    exit_reason TEXT                         -- 'ok' | 'interrupted' | 'no_feasible' | error msg
);
```

The `recipe_hash` is the FR-F.2 hash. Two `tune_runs` rows with the
same `recipe_hash` represent the same machine + recipe; this is the
v2 sticky comparison key.

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
reusable by reporting. The operator MAY pass `--resume` to skip
Stage 1 candidates that the prior crashed run already proved
infeasible (best-effort optimization; out of scope for v0.1's
normative contract — see §11). v0.1 default behavior is full rerun.

**FR-H.3. Network down during pre-download.**
A failed `models pull` for candidate K marks K infeasible with
reason "pre-download failed: <error>" and advances to candidate K+1.
The run only fails if EVERY candidate fails pre-download (then
FR-H.4 applies). This way, an operator running autotune with the
2 largest models pre-cached and a flaky network still gets a
working recommendation from the smaller cached candidates.

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
via the `.bak-<unix-ts>` file written by `--apply` (FR-F.3). If
`--apply` was not used, the config was not touched. There is no
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
performs no network egress except `models pull <id>` to
HuggingFace.

The coordinator-side recipe registry is v2 territory — see §11.
Even when it ships, it MUST be opt-in. The v1 design intentionally
keeps the recipe wholly local so operators can run autotune on
private/air-gapped Macs.

---

## 7. CLI surface (summary)

This is reference, not normative — the normative surface is the FRs
above. The actual flag set is:

```
macprovider-cli autotune
  --target-context <N>           target context in tokens (default 2000)
  --candidate-models <csv>       override default ordered list
  --max-model-size <Nb>          trim default list above this size
  --min-model-size <Nb>          trim default list below this size
  --kv-bits-axis <csv>           Stage 2 kv-bits cells (default '4,8')
  --max-batch-axis <csv>         Stage 2 max-batch cells (default '1,2')
  --max-context-axis <csv>       Stage 2 max-context cells (default '' = target only)
  --stage1-replicates <N>        default 1
  --stage2-replicates <N>        default 3
  --gate-ttft-ms <N>             default 60000
  --tps-tie-epsilon <F>          default 0.02
  --max-duration <seconds>       default 7200
  --port <N>                     local provider port (default 18080)
  --db-path <path>               default ~/.config/macprovider/autotune.sqlite
  --retain-runs <N>              default 50
  --json                         emit recommendation as JSON
  --apply                        write recommendation to config.yaml
  --drain                        if `serve` is running, drain it before tuning
  --resume                       skip candidates known infeasible from a prior crashed run (v2)
  --dry-run                      print the candidate plan and exit
  --report-only                  re-render the latest run's report and exit
  -v / --verbose                 stream per-trial details to stderr
```

The flag shape MAY change in v0.2 based on audit feedback. The
SEMANTICS in §5 are the normative surface.

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
RECOMMENDATION block MUST name Y. The fallbacks list MUST be empty
in this case (only Z would be a fallback, and the iteration didn't
reach it).

**AC-2. Largest-first iteration ITERATES past infeasible.**
Configure candidate list `[X, Y, Z]` where X is infeasible at the
target context, Y is infeasible, Z is feasible. The run MUST emit
infeasibility rows for X and Y (with `notes` populated) and select
Z. RECOMMENDATION names Z; fallbacks list is empty.

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
naming the existing PID and the `--drain` opt-in. The DB MUST NOT
have a `tune_runs` row written. Exit code MUST be non-zero and
distinct from the all-infeasible exit code (so wrappers can
distinguish).

**AC-7. `--no-join` is set on every candidate.**
The implementation MUST always pass `--no-join` (or its equivalent
flag) to every candidate `serve` invocation. A test asserts the
spawn argv contains `--no-join` and the coordinator pool MUST NOT
observe any provider connection during the autotune run (verified
via an integration test that watches the coordinator's
`/admin/pool/check` or equivalent).

**AC-8. Pre-download failure advances to next candidate.**
With `macprovider-cli models pull <id>` mocked to fail for candidate
1, the run MUST emit an infeasibility row for candidate 1 with notes
containing the pull error message and proceed to candidate 2. The
`tune_runs.exit_reason` MUST be `'ok'` IFF some candidate
succeeded, otherwise `'no_feasible'`.

**AC-9. `--apply` is atomic + backs up + idempotent.**
With `--apply`, a successful run MUST:
- Write the new `config.yaml` atomically (test asserts the file is
  either fully old or fully new at every observation moment, never
  half-written, via an `flock`-equivalent or a temp-file-rename
  trace).
- Save the prior config as `config.yaml.bak-<unix-ts>` with file
  contents byte-identical to the pre-apply config.
- Modify ONLY keys SPEC-013 owns. A test asserts every non-owned key
  (e.g. `coordinator_endpoint`, `provider_token`) is byte-identical
  pre/post.
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
Two `autotune` runs on the same machine with the same flags
producing the same recommendation MUST emit the same `recipe_hash`.
A run on a different RAM tier (e.g. 8 GB vs 16 GB) producing
even-coincidentally-the-same recommendation MUST emit a different
`recipe_hash` (because `machine.ram_gb` is part of the canonical
JSON the hash covers).

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
axis size × max_context axis size).

---

## 9. Open questions

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
v0.1 uses `3`, balancing wall-clock against noise. Air5 n=3 data
will tell us whether 3 is sufficient to discriminate cells whose
true tps gap is within `TPS_TIE_EPSILON`. If discrimination is
poor at n=3, v0.2 raises the default to 5 (Stage 2 wall-clock grows
linearly; the NFR-1 budget table absorbs the change).

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
v0.1 uses `stage1_replicates = 1` (cheap probe). If air5 n=3 data
shows that single-trial fit decisions are unstable (one probe rules
a model feasible while the next probe rules the same model
infeasible at the same context), v0.2 raises the default to N=2 or
N=3. The wall-clock cost is meaningful in Stage 1 (the iteration
runs across the whole candidate list), so the change requires real
evidence.

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
- **HF offline-mode handling.** The prototype's pre-download via
  external `pip install` / cache pre-warm is replaced by FR-D.1's
  `macprovider-cli models pull <id>`, but the principle (model
  weights must be on disk before `serve` starts) is the same.
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
