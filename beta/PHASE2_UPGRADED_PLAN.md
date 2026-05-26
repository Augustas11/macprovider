# Phase 2 — Upgraded Plan

**Source:** Premortem on the original Phase 2 plan (transcript at `.omc/reports/premortem-macprovider-phase2-20260526-1351.md`).
**Status:** Pre-kickoff. Replaces the Phase 2 design in `HANDOFF.md` § "The Phase 2 MVP".
**Why this exists:** The original plan was a sample-of-one along five dimensions (one provider, one model, one buyer, one prompt set, one cooperative behavior pattern) being implicitly treated as if it produced population-level claims about Phase 3 readiness. Most expansions to fix this are pure code, not more humans.

---

## Setup changes vs original

| Element | Original | Upgraded |
|---|---|---|
| Providers | 1 (M4 user) | **2: M4 user + new M1 collaborator** |
| Models per provider | 1 (default Qwen2.5-7B) | **2–3 rotated on schedule, tier-matched** |
| Buyer (you, M1) | Fires fixed 6 workloads | Fires **cooperative cron + adversarial cron** (separate profiles) |
| Prompts | Hand-written, fixed | **Sampled from public corpora** (LMSYS, ShareGPT, LongBench) |
| Tunnel | `cloudflared tunnel --url` (ephemeral) | **Named cloudflared tunnel** or ngrok reserved domain (stable URL) |
| Host-side instrumentation | None | **30-line companion script** logs CPU/RAM/foreground-app per minute |
| Decision criterion | "Decide at end of week 1" | **Pre-committed as numbers** in `beta/DECISION_CRITERIA.md` before day 1 |
| Provider commitment | Verbal yes | **Written, $100–200 + weekly 15-min check-in** |
| Stop-token detection | Hardcoded regex from Phase 1 | **Auto-derived from each model's `tokenizer_config.json` at harness startup** |
| Response capture | 300-char truncation | **Full response for last 500 requests** (rotating window) |

---

## The two crons

### Cooperative cron (the original plan)
- Hourly, during each provider's available window
- Standard workloads: short_chat, medium_with_system, long_context, code_completion, agent_style, streaming_check
- Now drawing prompts from public corpora, not hand-written
- Fired at **both** providers; routing mode evolves over the 2 weeks (see below)

### Adversarial cron (NEW)
- Twice per week, never simultaneously against both providers
- Workloads designed to break things:
  - 30K-token RAG-style prompt (probe the Metal OOM ceiling above Phase 1's 26K finding)
  - 8-way concurrent burst on one provider
  - Mid-stream client disconnect, repeated
  - Malformed JSON / tool-call requests
  - Retry storm (50 requests in 5 seconds)
  - Single-token streaming probe (TTFT precision)
- This is the layer that prevents cooperative-data-doesn't-generalize from poisoning Phase 3 spec

---

## Routing mode evolution

You have 2 providers and no coordinator yet. Pick mode deliberately, change it on schedule:

| Days | Mode | Why |
|---|---|---|
| 1–4 | **Mirror** — fire identical prompts to both providers same-minute | Builds differential baseline. Same prompt, same model, two hosts → TTFT delta is pure host/network noise. Cracks Failure B (infrastructure noise) by letting you cancel out the model term. |
| 5–10 | **Specialization** — short/small to M1, long/big to M4 | Tests the routing logic Phase 4 coordinator will need. Capacity numbers come from this phase. |
| 11–14 | **Stress** — adversarial cron + cooperative cron simultaneously on whichever provider is up | Final stress test before Phase 3 spec lock. |

---

## Pre-launch checklist

Before any code runs on a provider's Mac:

1. **Written agreement with each provider** — duration (14 days), model rotation schedule, weekly 15-min check-in slot, what would make either side stop early. Acknowledged in writing (email/Signal screenshot is fine).
2. **`beta/DECISION_CRITERIA.md` committed** — week-1 and week-2 go/iterate/pivot criteria as concrete numbers. Example below.
3. **Stable tunnels per provider** — named cloudflared or ngrok reserved domain. Verified by restarting `mlx_lm.server` and confirming URL persists.
4. **Stop-token derivation tested** — for each model in the rotation, load `tokenizer_config.json`, confirm all special tokens land in the regex, run a known-leaky prompt, confirm flag fires.
5. **Host-side companion script deployed** on both providers — logs CPU%/RAM%/foreground-app to local SQLite every 60s. Pulled to operator weekly via rsync over the tunnel.
6. **Adversarial workload code scaffolded** — even if not run on day 1, the code exists and is scheduled.
7. **Public-corpus prompt sampler wired into `workloads.py`** — sampling seeded for reproducibility but fresh per batch.

---

## Decision criteria template (commit to `beta/DECISION_CRITERIA.md`)

**Week 1 (day 7) — proceed to week 2 only if ALL of:**
- ≥5 days of ≥4 hours each with at least one provider reachable
- ≥80% of cooperative-cron HTTP 200 rate, per provider
- At least 1 successful adversarial-cron run that hit pathological inputs without crashing the provider's Mac
- Stop-token leak rate is *non-zero* on at least one model variant (zero is suspicious, not good — means detection isn't working)

**Week 2 (day 14) — proceed to Phase 3 only if ALL of:**
- All week-1 criteria still hold cumulatively
- Both providers stayed in the program (no full drop-off)
- JSON-mode reliability ≥90% on at least one model
- Differential testing (mirror mode) produced TTFT comparisons that isolate host vs server effects
- Operator can point to ≥1 specific Phase 3 design decision that *changed* because of Phase 2 data (otherwise Phase 2 had no decision value)

**Stop early if any of:**
- Either provider goes dark for >48 hours without explanation
- Operator cannot answer "what % of agent_style responses contain valid parseable tool-call JSON?" by day 5
- Metal OOM crashes a provider's Mac more than once

---

## Hidden assumption being attacked

The operator's measurement apparatus is implicitly treated as more representative than it is. Phase 2 by default is N=1 along five axes simultaneously. Each upgrade above expands one axis without adding new human coordination:

| Axis | Upgrade | Multiplier |
|---|---|---|
| Providers | M4 + M1 | 1 → 2 |
| Models | Rotation | 1 → 3 |
| Prompts | Public corpora | 1 → ~thousands |
| Buyer behavior | Cooperative + adversarial cron | 1 → 2 distinct profiles |
| Host load attribution | Companion script | unobservable → joinable on timestamp |

Net: Phase 2 dataset moves from one data condition to roughly `2 providers × 3 models × ~1000 prompts × 2 behavior profiles = ~12,000 conditions`. Only the providers axis costs human coordination — the other four are pure code.

---

## What this still does NOT do

Real third-party buyers are not in scope. That is structurally a Phase 3 question (requires privacy/auth stack). Phase 2 expansion buys confidence that the *measurement apparatus sees a distribution* — not that *real demand exists*. Don't conflate them. Trying to test real-buyer behavior in Phase 2 burns the Antseed first-mover window and recreates Phase 3 prematurely.

---

## Work ordering before kickoff

1. **Adversarial cron profile** (1 day) — highest single-yield engineering change
2. **Public-corpus prompt sampler** (½ day) — replaces handwritten prompts in `workloads.py`
3. **Model rotation in `config.yaml`** (1 hour)
4. **Companion host-telemetry script** (½ day) — runs on each provider
5. **Tokenizer-config-derived stop-token list** (1 hour)
6. **`beta/DECISION_CRITERIA.md`** (½ hour) — operator writes, not delegated
7. **Provider written agreements** (parallel track, no engineering) — both providers acknowledge before kickoff

Total engineering: ~3 days. Without these, Phase 2 produces telemetry that may look green while being uninformative for Phase 3.

---

## How to use this doc

A future session should read `HANDOFF.md` first for full Phase 1 context and the original Phase 2 design, then read this doc as the **delta** that supersedes the Phase 2 section. The original `beta/` scaffold (harness.py, workloads.py, report.py) stays — these changes are additive, not a rewrite.
