# RESEARCH PROMPT — Rapid-MLX 0.9 measurement: reproduce the claims on macprovider hardware before designing anything

Run as: `omc ask codex "$(cat specs/RESEARCH_228_RAPID_MLX_MEASUREMENT_PROMPT.md)"`

This is a **measurement-first** research prompt — no SPEC drafts, no
code changes, no port plan. Single codex call (or twice with
different models on Part 5). Follow-up to RESEARCH_223 (MLX
throughput roadmap) and precondition to any SPEC-028 v0.2 / SPEC-029
/ SPEC-030 work motivated by the raullenchai/Rapid-MLX 0.9 release.

Output is a memo: `specs/RESEARCH_228_RAPID_MLX_MEASUREMENT_MEMO.md`,
plus a decision-log entry appended to `beta/DECISION_CRITERIA.md`.

The operator has caught a pattern where implementation planning
gets drafted before benefit is measured. This prompt exists to
break that pattern for Rapid-MLX specifically. **Nothing that
belongs in a SPEC belongs in this memo.** The memo answers "is
there a benefit worth building against?" — and only that.

---

## Task

On 2026-07-05 raullenchai published Rapid-MLX 0.9, advertised as a
drop-in OpenAI-wire replacement for local Apple Silicon inference
with three speculative-decoding paths (DFlash 4.37×, Qwen Native MTP
1.57×, Gemma 4 MTP +28% structured), a default-on TurboQuant K8V4
Metal kernel, and a radix-tree prefix cache. Repo:
`https://github.com/raullenchai/Rapid-MLX` (public, Python, FastAPI,
3,187 stars as of 2026-07-05). Homebrew tap:
`raullenchai/homebrew-rapid-mlx`.

Macprovider's provider runtime is Swift, calling `mlx-swift-lm`
3.31.4 directly from `ModelRuntime.swift` — **not** a Python sidecar
(RESEARCH_223 Part §Background got this wrong; the correct source
of truth is `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
imports at `:1-8` and `phase3-binary/Package.swift:20-23`). Any
adoption of Rapid-MLX would be a runtime substitution or a
technique-by-technique reimplementation in Swift, not a library
swap.

SPEC-028 v0.2-draft already scopes a native speculative-decoding
implementation against `mlx-swift-lm` primitives (target+draft
model, greedy-only v0.1 gate, `spec_decode_acceptance_rate ≥ 0.30`,
`≥ 1.4× baseline` throughput floor). The question this prompt
answers is **not** "should we build SPEC-028?" — that decision is
already made. The question is: **do Rapid-MLX's specific claims
survive on macprovider's actual hardware and workload mix, and if
so which of its techniques warrant a follow-up SPEC beyond
SPEC-028's greedy-target+draft baseline?**

If Rapid-MLX turns out to be mostly a thin wrapper over upstream
`mlx-lm` with the speedups coming from model choice (Qwen 3.5/3.6
native MTP heads) or upstream `mlx-lm` improvements MacProvider
would get by bumping the `mlx-swift-lm` pin, say so clearly and
recommend the pin bump plus a model-catalog amendment instead of a
new SPEC.

---

## Background — current state (verbatim)

**Motivation post** (raullenchai on X, 2026-07-05):
- "Rapid-mlx 0.9 Unleashed: Up to 4.37x Lossless Speed on Apple Silicon"
- "3 Lossless MTP Paths in 1 Server"
  - DFlash: 4.37× lossless on M5 Max Qwen 3.5-9B w4 at 135+ tok/s
  - Qwen Native MTP: 1.57× decode on M4 Pro, no draft model needed
  - Gemma 4 MTP: +28% structured decode via Google's sidecar drafter
- "TurboQuant K8V4 (8/4-bit fused Metal kernel) default-on for hero models"
- "Radix-tree prefix cache for multi-tenant efficiency"
- "Per-model int4 safe fallback profiles"
- New model support: Gemma 4 (E2B → 31B), gpt-oss-20B, Qwen 3.6
  (27B + 35B-A3B MoE + full quant ladder), Kimi K2.6,
  Mistral-Small-4-119B, Whisper.
- Install: `brew install raullenchai/rapid-mlx/rapid-mlx`

**Macprovider provider runtime anchors**:
- Swift generate call: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1-8`, `:667-790`, `:804-930`.
- Pinned dep: `mlx-swift-lm` 3.31.4 (`phase3-binary/Package.swift:20-23`, `Package.resolved:13-19`).
- Static candidate catalog (target models): `phase3-binary/dist/static/autotune-candidates.json` — Qwen3-Coder-30B, gpt-oss-20B, Llama-3.1-8B, Qwen3-32B, Qwen2.5-Coder-32B.
- Beta providers: M1 8 GB (`beta/config-m1.yaml`, Llama-3.2-3B-4bit) and M4 16 GB (`beta/config-m4.yaml`, Qwen2.5-7B-Instruct-4bit).
- Beta workload fixtures: `beta/workloads.py:26-34`, `:88-240` — short/medium/code/agent/long/streaming.
- Existing SPEC-028 AC-10 canary target: Qwen2.5-Coder-7B-Instruct-4bit + Qwen2.5-Coder-1.5B-Instruct-4bit draft, `temperature=0`, `max_tokens=240`, `num_draft_tokens=3`, ratio floor `≥ 1.4 × baseline_tps` over 5 warm runs, thermal window `≥ 1.2 × baseline_tps` over the last minute of a 5-minute continuous run.
- Existing SPEC-024 sticky-conversation KV-cache reuse metering (`cached_prompt_tokens` in OpenAI `usage`).
- Existing SPEC-015 v0.3 nine-field receipt tuple with target `model_hash` binding.

**Macprovider hardware fleet available for this study**:
- Beta M1 Air 8 GB (llama.launchd install per `beta/config-m1.yaml`).
- Beta M4 16 GB provider (`beta/config-m4.yaml`).
- One-off M5 Max access is *not* assumed — replicate the tweet's
  headline number only if we already have that hardware. Otherwise
  measure on M4 Max / M2 Ultra / M3 Ultra if reachable and clearly
  label the substitution.

**Prior clean-room posture**:
- `CLAUDE.md` names d-inference (`layr-labs/d-inference`) as strictly
  clean-room (NOASSERTION). The same posture defaults on for
  Rapid-MLX **until Phase 0 confirms a permissive license**. If
  license is unclear or restrictive, the memo runs the black-box
  measurement plan without inspecting the Python source.

---

## What to produce

Six sequential phases. **Each earlier phase has a stop-condition.
If a stop-condition trips, the memo ends there — do not carry
partial evidence into later phases as if they had run.** The memo
must record which phases ran and which stopped and why.

### Phase 0 — License and posture confirmation (blocking, ~30 min)

Report:

- Rapid-MLX `LICENSE` file contents and OSI classification (MIT /
  Apache-2.0 / BSD / GPL / AGPL / other / none). Cite the URL and
  the commit SHA at read time.
- Homebrew tap license and formula source URL (raullenchai tap or
  fetched tarball).
- Whether the underlying package is pure Python source or contains
  compiled binaries / Metal kernels shipped as opaque artifacts.
- Recommended inspection posture for this memo:
  - Permissive (MIT / Apache / BSD): direct source study allowed;
    Phase 3 may cite specific modules and functions.
  - Copyleft (GPL / AGPL): source may be *read* but no code excerpt
    goes into the memo or into any downstream SPEC.
  - Restrictive / NOASSERTION / no LICENSE: clean-room only; Phase
    3 does black-box attribution via runtime toggles, not source
    reading.

**Stop-condition**: if license posture forbids inspection *and*
Rapid-MLX exposes no per-technique runtime flags to isolate wins,
skip Phase 3 (technique attribution) and mark it explicitly as
"deferred pending clean-room prior-art audit."

### Phase 1 — Reproduce the headline claim on macprovider fleet hardware (~1-2 days)

Install Rapid-MLX 0.9 on the beta M4 16 GB provider via the
Homebrew tap. Do **not** put this Mac back into the coordinator
routing pool during the study. Note whether the install pulls
signed binaries, unsigned binaries, or source-only; note any
`xattr` quarantine bypasses required.

Run the existing `beta/workloads.py` short/medium/code/agent/long/
streaming fixtures against:

1. Rapid-MLX `/v1/chat/completions` local endpoint, with default
   config (whatever it ships as "default-on" — TurboQuant K8V4,
   radix cache, spec-decode where applicable to the loaded model).
2. Macprovider-cli current serve path on the same Mac, same model
   snapshot, same prompts, same params.

Fixed request params for the head-to-head:

- `temperature=0`, `top_p=1.0`, `max_tokens` per fixture default.
- No `tools`, no `response_format`, no `logprobs`, no `logit_bias`.
- Non-streaming for the throughput number; streaming re-runs are
  separate cells.
- Two model choices, run both:
  - Target `mlx-community/Qwen2.5-7B-Instruct-4bit` (the current
    beta M4 config).
  - Target `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` plus draft
    `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit` (the SPEC-028
    AC-10 pair), if Rapid-MLX supports operator-supplied draft model
    configuration.

Report per (workload × model × engine):
- Median tok/s over ≥ 5 warm runs (discard first cold run).
- p50 / p95 TTFT.
- Peak resident memory (from `/usr/bin/time -l` or `footprint`).
- Whether token-ID output matches macprovider-cli's greedy output
  byte-for-byte at the OpenAI-response level (not decoded text —
  compare token IDs where accessible, else compare exact response
  bytes with `content` extracted).

Also report:

- Whether Rapid-MLX's `usage` object populates the same fields
  macprovider-cli's does (`prompt_tokens`, `completion_tokens`,
  `total_tokens`, `cached_prompt_tokens`).
- Whether Rapid-MLX supports `conversation_id` or an equivalent
  prefix-cache handle. If not, prefix cache is not comparable to
  SPEC-024.
- Whether Rapid-MLX preserves greedy `temperature=0` token-ID
  equivalence with `mlx-lm` non-speculative generation on the same
  prompts.

**Stop-condition**: if median speedup on the beta M4 workload mix
is `< 1.4×` and greedy token-ID equivalence fails on any workload,
end the study. Log the null result in the memo Part §Decision and
in `beta/DECISION_CRITERIA.md`. Do not proceed to Phase 2.

### Phase 2 — SPEC-028 native counterfactual on the same Mac (~1-2 days)

Only if Phase 1 cleared its stop-condition.

Bare-minimum Swift spike: extend `ModelRuntime.completeWithServedSnapshot`
to call `mlx-swift-lm`'s `generate(input:cache:parameters:context:draftModel:draftCache:numDraftTokens:)`
with the Qwen2.5-Coder-7B + 1.5B pair when a hidden env var is set.
No config plumbing, no `/v1/status` fields, no receipt changes, no
CLI flags — this is measurement scaffolding, not SPEC-028 v0.1.
Isolate it in a research branch off `main`; **do not merge into
`main` from this phase**.

Run the same Phase 1 fixtures against this Swift native spec-decode
path on the same Mac.

Report per fixture:
- Median tok/s.
- `spec_decode_acceptance_rate` from `GenerateInfo.speculativeDecodingTelemetry`.
- Delta vs. Rapid-MLX (Phase 1 number).
- Delta vs. non-spec-decode macprovider-cli baseline (Phase 1 number).

**Stop-condition**: if the Swift native path lands within `1.2×`
of Rapid-MLX on the beta M4 workload mix (i.e. Rapid-MLX is at most
20% faster), SPEC-028 v0.1 as designed captures the win. Recommend
landing SPEC-028 unchanged, publishing the measurement memo, and
closing the Rapid-MLX exploration. Do not proceed to Phase 3.

### Phase 3 — Technique attribution (~1 day)

Only if Phase 2 cleared its stop-condition (i.e. Rapid-MLX is
materially faster than `mlx-swift-lm` native spec-decode).

Decompose the Rapid-MLX speedup by toggling techniques off one at
a time and re-running the Phase 1 workload mix:

| Technique | How to isolate |
|---|---|
| DFlash draft path | Disable via config flag; else run a non-DFlash model to remove it. |
| Qwen Native MTP | Compare Qwen 3.5-9B (has MTP heads) vs a same-size non-MTP model. |
| Gemma 4 MTP sidecar | Compare Gemma 4 with/without the Google sidecar drafter loaded. |
| TurboQuant K8V4 kernel | Compare `w4` quant against `w4` on stock `mlx-lm` — same model, same weights, different runtime. |
| Radix-tree prefix cache | Run a multi-tenant fixture where two concurrent conversations share ≥ 512 tokens of prefix; measure prefix-hit tok/s vs cold. Compare against SPEC-024's `cached_prompt_tokens` behaviour on macprovider-cli. |

Produce this table:

| Technique | Speedup contribution (of Rapid-MLX total) | Applies to which macprovider fleet tier | Requires new SPEC beyond SPEC-028 |
|---|---:|---|---|
| DFlash draft | ? | ? | ? |
| Qwen Native MTP | ? | ? | ? |
| Gemma 4 MTP | ? | ? | ? |
| TurboQuant K8V4 | ? | ? | ? |
| Radix prefix cache | ? | ? | ? |

If Phase 0 forbade source inspection and Rapid-MLX does not expose
per-technique flags, mark this table's rows "attribution deferred
— clean-room prior-art audit required" and identify the specific
upstream papers a clean-room reimplementation would cite (leyten/
shard block-diffusion 2026-07-03 for DFlash; Qwen 3.5/3.6 model
card for Native MTP; SGLang RadixAttention for radix cache).

**Stop-condition**: if ≥ 80% of Rapid-MLX's speedup comes from a
single technique, narrow the whole downstream track to that
technique — do not port the engine, do not draft SPECs for the
other four. Record which one dominated and move on.

### Phase 4 — Lossless-ness under macprovider request shapes (~1 day)

Only if Phase 3 identified at least one portable win.

Token-ID equivalence tests between Rapid-MLX and macprovider-cli
(baseline non-spec) at `temperature=0` across:

- SPEC-018 tool calling — first-turn `tool_calls[]` emission, then
  second-turn `role: "tool"` message acceptance. Use the Cline
  drop-in fixture. Compare parsed `function.name` and
  `function.arguments` byte-for-byte.
- SPEC-019 structured output — `response_format: {"type":
  "json_schema", "json_schema": {...}}` in OpenAI strict-mode
  subset. Compare parsed JSON structure and key ordering.
- Streaming — `stream: true` SSE deltas. Compare concatenated
  final content.
- Sticky conversation + KV-cache reuse — a second-turn request
  with a stable `conversation_id`. Compare `cached_prompt_tokens`
  populated in `usage`, and second-turn output token IDs.

Report pass/fail per shape. A single fail means the technique
cannot be considered lossless for macprovider's shipped features
unless the SPEC-029/030 draft explicitly gates around it (mirror
SPEC-028 FR-5's request-feature allowlist).

**Stop-condition**: if ≥ 2 request shapes fail lossless-ness and
the failing shapes are SPEC-018 or SPEC-019 (both LOCKED, both
buyer-visible), stop. Recommend against porting. Log why.

### Phase 5 — Air-class capacity and thermal check (~1 day)

Only if Phase 4 cleared its stop-condition.

Repeat Phase 1's shortest workload (`short_chat`) on the beta M1
8 GB Air with the smallest viable Rapid-MLX configuration. If
Rapid-MLX cannot run any config on 8 GB, report the smallest tier
it does run on.

Report:
- Whether Rapid-MLX loads and serves at all on 8 GB.
- Peak resident memory during a `long_context` fixture.
- Whether Metal OOM or process termination occurs.
- Sustained tok/s over 5 minutes of continuous generation; report
  the median tok/s of the final minute vs the first minute (thermal
  window, mirroring SPEC-028 AC-10's 5-minute rule).

**Stop-condition**: if Rapid-MLX cannot run on any hardware tier
below 32 GB and the majority of macprovider's fleet is 8-16 GB
Air-class, downgrade the port priority and record the tier gap in
the memo. SPEC-029 (if drafted) would then be an M-Max/M-Ultra
feature only.

### Phase 6 — Production-shape integration probe (~3-5 days)

Only if all prior phases cleared their stop-conditions.

Stand up one dedicated provider Mac running Rapid-MLX as its local
model server. Modify `macprovider-cli` in a research branch to
forward its `/v1/chat/completions` handler to Rapid-MLX's local
endpoint (proxy, not import). Route a bounded window of real
coordinator traffic through this provider (agree window size with
operator before starting; suggested initial cap 1000 requests or
24 hours, whichever comes first).

Instrument and report:
- Coordinator receipt-verifier verdict rate (`pass`, `fault_breaker`,
  `usage_shape_invalid`, others) vs baseline provider.
- Whether SPEC-015 v0.3 receipts still bind the correct target
  `model_hash` — Rapid-MLX loads models under its own paths, so the
  hash inputs may differ. If they do, quantify the delta.
- Coordinator heartbeat integrity (`macprovider-cli` heartbeat still
  fires with correct fields; no unknown-key rejections).
- Warm-swap semantics under an operator-requested model change
  (SPEC-011): does Rapid-MLX drain in-flight requests? does it
  reload the target model when the coordinator requests it?
- Autoupdate behavior (SPEC-020): does the coordinator's advertised
  `recommended_binary_version` flow still work when the model
  server is external?
- Process-management posture: does Rapid-MLX crash-restart cleanly?
  is there a supervision gap between `macprovider-cli` and the
  Python process it now depends on?

**No stop-condition** at Phase 6 — the deliverable is the full
integration-risk register.

---

## Decision criteria (pre-committed)

Written down before results so post-hoc rationalization is
detectable. The memo's Part §Decision compares measured numbers
against this table.

| Criterion | Threshold to proceed to implementation planning |
|---|---|
| Median speedup on beta workload mix (Phase 1) | `≥ 1.8×` lossless at `temperature=0` |
| Delta over `mlx-swift-lm` native spec-decode (Phase 2) | Rapid-MLX at least `1.4×` faster than the Swift native path |
| Token-ID equivalence under SPEC-018 tool calls, SPEC-019 json_schema, SPEC-024 sticky conversations, streaming (Phase 4) | All four shapes pass — no partial credit |
| Fits ≥ one Air-class tier (8 or 16 GB) (Phase 5) | Yes, without Metal OOM under `long_context` fixture |
| Sustained (5+ min) throughput vs. baseline (Phase 5) | `≥ 1.4×` at end of window |
| Receipt binding preserved under real coordinator traffic (Phase 6) | Verifier `pass_rate` within 2 pp of baseline |
| ≥ 3 techniques contribute independent, ≥ 10% wins (Phase 3) | Yes — else scope-narrow downstream track to the dominant one |

Rule: `≥ 5 / 7` criteria clear → recommend a follow-up SPEC and
name its scope. `< 5 / 7` → recommend closing the exploration and
sticking with SPEC-028 v0.1. In both cases, append a
`beta/DECISION_CRITERIA.md` entry.

---

## Out of scope

- No SPEC drafts. If the recommendation is "draft SPEC-029," the
  memo names the scope in one paragraph and stops.
- No implementation planning. If porting is recommended, the memo
  says which techniques, not how to build them.
- No code changes on `main`. Phase 2 and Phase 6 spikes stay in
  named research branches and are noted in the memo but not merged.
- No coordinator config or routing changes. Phase 6's dedicated
  provider is the only production-adjacent surface.
- No new model catalog rows. If Phase 3 identifies model-choice
  wins (Qwen 3.6, Gemma 4), those go to a separate SPEC-013 amendment
  after this memo lands.
- No public statement about Rapid-MLX until the memo is reviewed —
  the operator will decide external communication posture.

---

## Output format

Two files:

1. `specs/RESEARCH_228_RAPID_MLX_MEASUREMENT_MEMO.md` — markdown
   memo, ~400-800 lines. One section per phase. Every measurement
   cell in a table with hardware / model / fixture / params /
   engine / metric / value / date pulled. Every source-inspection
   claim in Phase 3 (if the license permitted it) cites file path
   and line number in Rapid-MLX at the commit SHA read. Every
   clean-room attribution cites the paper URL and date pulled.
   Part §Decision uses the pre-committed table above and does not
   introduce new criteria.
2. `beta/DECISION_CRITERIA.md` — append one Entry with title
   `Rapid-MLX 0.9 measurement outcome (RESEARCH_228)`, three-line
   what/why/next-step summary, and the memo path.

Conservative > optimistic. Marketing-vs-measured must be labeled
explicitly in every table cell that carries a claim not verified
on our hardware.
