# Mac Provider — Session Handoff

> **⚠ Phase 2 design superseded.** Read `beta/PHASE2_UPGRADED_PLAN.md` after this doc. It replaces the Phase 2 MVP section below (now 2 providers, two crons, pre-committed decision criteria, stable tunnels, host-side instrumentation). The original beta/ scaffold stays — changes are additive.

**Status:** Phase 1 PoC complete. Phase 2 buyer-harness scaffold built and smoke-tested locally. Awaiting M4 user before going live.
**Last session ended:** 2026-05-26
**Next session entry point:** This document. Read it first, then `beta/README.md` for the harness, then `results/REPORT.md` for Phase 1 evidence.

## What was built this session

The full Phase 2 operator-side harness now lives in `beta/`:

```
beta/
├── README.md                # Contributor manual path + operator section
├── CONTRIBUTOR_PROMPT.md    # Paste-into-Codex/Claude prompt — the recommended onboarding path
├── config.yaml         # tunnel_url placeholder, model, batch list, paths
├── harness.py          # SQLite-logged buyer harness w/ SSE quirks handled
├── workloads.py        # 6 workloads: short_chat, medium_with_system, long_context, code_completion, agent_style, streaming_check
├── report.py           # SQLite -> single-file HTML daily report
├── scripts/run-once.sh         # Smoke test a single workload
├── scripts/run-scheduled.sh    # Cron entrypoint: batch + report
└── .gitignore                  # Excludes runs.sqlite, reports/, cron.log
```

Verified locally against a stub mlx-style SSE server:
- Keepalive comment lines (`: keepalive N/M`) are skipped before JSON parse.
- Stop-token leakage (`<|eot_id|>` etc.) detected in both streamed and non-streamed responses; flagged in `stop_token_leak` column.
- Extra response fields (`system_fingerprint`) tolerated.
- TTFT correctly captured on streamed requests (and left null on non-streamed).
- Connection errors land as SQLite rows with `http_status=NULL` + populated `error`.
- HTML report renders cleanly and color-codes failures + leaks.

**What's not built yet (intentionally):**
- Context-length pre-flight — that's Phase 3 coordinator territory; M4 user is cooperative.
- Tunnel-stability heartbeat job — could add a low-cost ping if drops are common.
- Multi-day rollup report — `report.py --all` exists but only renders per-day.

## What's blocked on the M4 user

Open the conversation with them; the answers determine the cron schedule and model recommendation. See "Pending decisions before MVP kickoff" below — those 6 items are the entire blocker.

---

## What this project is

A pooled Mac inference network where:
- **Contributors** (Mac owners with idle compute) run a hardened CLI that serves MLX inference.
- **Operator** (you) runs a single coordinator on a VPS that:
  - Accepts inbound connections from contributor Macs (outbound WebSocket from their side, no NAT hassles).
  - Routes buyer requests to available Macs.
  - Presents as one seller to Antseed (initial demand source).
  - Eventually exposes a direct OpenAI-compatible API for buyers outside Antseed.
- **Antseed** is the initial billing/demand layer — you already have a seller node ("AntFeed", $7.18 volume, 119 sessions) running from VPS at 165.22.182.207.

**Differentiator vs Darkbloom:**
- Targets ALL Apple Silicon (including 8GB M1) — Darkbloom requires 36GB+.
- Plugs into existing Antseed buyer network instead of building one from scratch.
- Smart router with sticky single-tenant caching (Darkbloom explicitly disabled caching for security).

**Why this is viable:** Antseed has zero local hardware inference today — all 62 providers proxy cloud APIs. First Mac node = first-mover. See conversation discussion of network state.

---

## Phase 1 verdict (definitive)

**PASS with concrete caveats → proceed to Phase 2.**

Full report: `results/REPORT.md` (305 lines). Three sections — original run, continuation run, and the tokenizer-accurate long-context re-run.

### Key findings cheat sheet

| Question | Answer | Source |
|---|---|---|
| Does mlx_lm.server speak OpenAI-compatible HTTP? | Yes, with quirks | Step 4 |
| Does Cloudflare tunnel break the contract? | No — 0.45s median latency | Step 7 |
| Can M1 8GB serve 3 parallel buyers? | Yes — 0.90× parallelism factor | 7.5.1 |
| Cold-start latency? | 1.72s cold, 0.66s warm | 7.5.2 |
| Sustained 5-min load? | 210 requests, no failure, 14 tok/s sustained | 7.5.4 |
| Memory pressure survival? | Survives but 12× slower | 7.5.5 |
| Cross-architecture path (Phi-3.5-mini)? | Works identically | 7.5.6 |
| 8K context viable? | Yes, 47s prefill | 7.5.3 re-run |
| 16K context viable? | Borderline, 76s prefill | 7.5.3 re-run |
| 32K context viable? | **NO — hard Metal GPU OOM at ~26K** | 7.5.3 re-run |
| SSH reverse tunnel to VPS works? | Yes, after SSH config fix | Step 6.7 re-run |
| VPS sshd GatewayPorts? | `no` (default) — irrelevant for Phase 4 design | Step 6.7 |

### The SSE quirks to handle in Phase 3 binary

mlx_lm.server is **not strictly OpenAI-compatible**. Phase 3 binary or coordinator must:
1. Ignore SSE keepalive comment lines (e.g. `: keepalive 9/10`).
2. Strip model-specific stop tokens from output (`<|eot_id|>` for Llama, `<|end|>` for Phi, etc.).
3. Tolerate extra fields (`system_fingerprint`, `tool_calls`, etc.).
4. Pre-flight context length check + reject (or route to bigger Mac) requests exceeding capacity, to avoid Metal OOM crashes.
5. Advertise per-Mac context cap based on RAM at registration time.

---

## What changed in my understanding during Phase 1

**Initial assumption (wrong):** Need to fork or re-implement Darkbloom's full stack including their coordinator protocol.

**Reality after testing:**
- Darkbloom's binary already runs on M1 8GB — full security stack works.
- `--coordinator` flag accepts any URL → could point at your own coordinator.
- BUT: legal/dependency risk on Darkbloom. Need own binary in Phase 3.
- Phase 3 binary is well-scoped — paper is the spec, ~5 Swift files reference what to re-implement, `mlx-swift-lm` is MIT-licensed and usable directly.
- Antseed seller already uses `plugin: "openai"` pattern → can route to any OpenAI-compatible backend (cloudflared tunnel, localtunnel, or coordinator in front of the pool).

---

## The Phase 2 MVP (next session's main work)

**Vision:** Two real Macs, one cooperative tester (M4 owner), real workloads, real data over 2 weeks.

### Players

- **M4 user (cooperative tester)** — runs `mlx_lm.server` + `cloudflared` on their Mac. Shares tunnel URL.
- **You (M1, operator + buyer)** — runs a Python buyer harness that fires varied workloads at the tunnel URL, captures metrics, generates daily reports.

### Why this beats more interviews

| Question | Interview | MVP data |
|---|---|---|
| Would you run it? | "Sure, sounds interesting" | Did they actually keep running it for 2 weeks? |
| Would your Mac get hot? | "I don't know" | Thermal log over sustained use |
| Is the speed acceptable? | Abstract opinion | Actual TTFT/throughput data |
| Does it crash? | "Hopefully not" | Real uptime stats |

### Why Phase 3 is NOT required for this

- M4 user is **cooperative**, not adversarial → no privacy claim needed
- Buyer (you) is the operator → no untrusted-buyer story needed
- Type B user (AI power user) → Terminal-comfortable, doesn't need polished CLI
- Goal is **data**, not product launch

Phase 3 (Swift binary + privacy stack) is needed for:
- Onboarding untrusted strangers as sellers
- Untrusted external buyers
- Customer-facing privacy claim

None of those apply at MVP beta.

### What to build (the only real engineering work)

A **buyer harness** on your M1, ~200 lines Python, lives at `/Users/augstar/macprovider-poc/beta/`:

```
beta/
├── README.md              # M4 user setup instructions (one page)
├── harness.py             # Buyer-side: fires workloads, captures metrics
├── workloads.py           # Workload library (5-6 prompt types)
├── runs.sqlite            # SQLite DB of all runs (created on first run)
├── config.yaml            # Tunnel URL, schedule, target model
├── reports/               # HTML daily reports
│   └── YYYY-MM-DD.html
└── scripts/
    ├── run-once.sh        # Manual single-request test
    └── run-scheduled.sh   # Cron-friendly hourly batch
```

**Workload types (workloads.py):**
- `short_chat` — ~50 tok in, ~100 tok out (basic Q&A)
- `medium_with_system` — ~2K in, ~200 out (chat with system prompt)
- `long_context` — 8K in, ~100 out (push hardware)
- `code_completion` — ~500 in, ~100 out (coder-style task)
- `agent_style` — ~3K in, ~300 out (system + tools + query)
- `streaming_check` — measure TTFT and per-chunk timing

**Metrics per request:**
- TTFT (time to first token, streaming only)
- Total wall time
- Throughput (tok/s)
- Prompt tokens, completion tokens (from response `usage`)
- HTTP status code
- Errors / timeouts
- Stop-token leakage detected (regex check)
- Response content (truncated to 300 chars)

**Storage:** SQLite (`runs.sqlite`) — one `runs` table, easy to query, no infra to manage.

**Schedule:** Cron-driven hourly batch during M4 user's "available" window. 5-10 requests per batch, varied workload types.

**Daily report:** HTML page rendered from SQLite. Shows: total/success counts, median TTFT by workload, throughput trends, errors, tunnel stability (gaps where expected runs failed).

### Setup instructions for the M4 user (one page)

```bash
# One-time — ~10 minutes
brew install python@3.12 cloudflared
python3 -m venv ~/macprovider
source ~/macprovider/bin/activate
pip install mlx-lm

# Each session — two terminals
# Terminal 1
mlx_lm.server --model <MODEL> --port 8080
# Terminal 2
cloudflared tunnel --url http://localhost:8080
# Copy the https://*.trycloudflare.com URL → send to operator
```

**Model recommendation based on M4 RAM** (need to confirm from user):
| RAM | Model | Approx size |
|---|---|---|
| 16GB (M4 base) | `mlx-community/Qwen2.5-7B-Instruct-4bit` | ~4 GB |
| 24GB (M4 Pro) | `mlx-community/Qwen2.5-14B-Instruct-4bit` | ~8 GB |
| 48GB+ (M4 Max) | `mlx-community/Llama-3.3-70B-Instruct-4bit` or `mlx-community/Qwen3.5-35B-A3B-Instruct-4bit` | ~35 GB / ~20 GB |

Without confirmation, default recommendation is Qwen2.5 7B — runs on any M4 with safe margin.

### Pending decisions before MVP kickoff

1. **M4 user's RAM** — ask, decide model.
2. **M4 user's availability window** — when is their Mac on? Cron schedule depends on this.
3. **Tunnel URL exchange method** — Signal / Telegram / plain email. Doesn't matter functionally, pick one.
4. **Report sharing** — do they see the daily report or only you? Either fine, but decide.
5. **Beta duration** — minimum 1 week, target 2 weeks for retention data.
6. **What "stop" means** — explicit checkpoint at end of week 1: do we keep going? What would make us stop?

---

## File map (state at end of last session)

```
/Users/augstar/macprovider-poc/
├── HANDOFF.md                 # ← this file
├── RUNBOOK.md                 # Original Phase 1 runbook (1211 lines, 15 steps)
├── CONTINUE_RUNBOOK.md        # Continuation runbook for missing tests
├── scripts/
│   ├── long_context_test.py   # Tokenizer-accurate 8K/16K/32K test (used in re-run)
│   └── long_context_32k.py    # Focused 32K re-run script after power-off
├── logs/
│   ├── 00-preflight.txt       # Hardware/env state
│   ├── 03-mlx-server.log      # All MLX server runs (last entries show OOM crash)
│   ├── 06-tunnel.log          # Cloudflared
│   ├── 06.5-localtunnel.log   # Localtunnel
│   ├── 06.7-ssh-probe.log     # SSH probe (failed before fix)
│   ├── 06.7-ssh-tunnel.log    # SSH tunnel (clean after fix)
│   └── ...
├── results/
│   ├── REPORT.md              # ★ Full Phase 1 evidence — read this for details
│   ├── 04a-local-nonstream.json
│   ├── 06.5-localtunnel-test.json
│   ├── 06.7-ssh-loopback.json # "Tunneled." response — confirmed
│   ├── 06.7-ssh-latency.txt   # 5-request timings
│   ├── 07a-tunnel-nonstream.json
│   ├── 07b-tunnel-stream.txt
│   ├── 07c-latency.txt
│   ├── 08-cancellation-client.txt
│   ├── 09-sse-format.txt
│   └── stress/
│       ├── 7.5.1-concurrent.txt
│       ├── 7.5.2-coldstart.txt
│       ├── 7.5.3-longcontext-v2-8000.json
│       ├── 7.5.3-longcontext-v2-16000.json
│       ├── 7.5.3-longcontext-v2-32000.json  # OOM evidence
│       ├── 7.5.4-sustained.txt
│       ├── 7.5.5-mempressure.txt
│       └── 7.5.6-multimodel.txt
├── state/
│   ├── tunnel-url.txt         # Last cloudflared URL (now stale)
│   ├── lt-url.txt             # Last localtunnel URL (now stale)
│   ├── ssh-gatewayports.txt   # VPS sshd setting: no (default)
│   └── ...
└── .venv/                     # Python venv with mlx-lm installed
```

**Permanent infrastructure changes made during Phase 1:**
- Added `Host 165.22.182.207` block to `~/.ssh/config` mapping to `antseed_vps_ed25519` key. Non-interactive SSH now works to the VPS.

**No production systems modified.** All Phase 1 testing was siloed in `/Users/augstar/macprovider-poc/`. Existing Antseed seller (VPS), Darkbloom binary, AntFeed node — all untouched.

---

## Updated roadmap (for new session reference)

```
Phase 1   ✅ DONE         PoC: single M1, tunneled MLX, all stress tests
Phase 2   ★ NEXT          Two-Mac beta with M4 user, 2-week real-data run
Phase 2.5 In parallel      Sharpen Phase 3 spec from MVP data
Phase 3   After Phase 2   Swift binary build (4-6 weeks)
Phase 4   After Phase 3   Coordinator on VPS, second contributor
Phase 5+  Later           Smart router, public API, billing layer
```

**Phase 2 success criteria** (define explicitly at start of next session):
- ≥7 days of continuous operation (with M4 user's normal usage interruptions)
- Real performance data across all 5+ workload types
- Stop-token leakage frequency quantified
- Tunnel stability data (drops per day, recovery time)
- M4 user qualitative feedback at end: heat? noise? interference?
- Decision: proceed to Phase 3, iterate Phase 2, or pivot

---

## Key strategic decisions made this session

1. **Pooled model, not individual sellers.** Contributors get rewards, you operate the single seller relationship with Antseed. Quality control + moat + simpler contributor UX (no wallet needed).

2. **Type B beachhead.** AI power users who already run local models. Smaller market than passive earners, but acquisition is free (they find you) and retention is highest.

3. **Smart router as differentiator.** Sticky single-tenant routing enables caching with privacy. Public-prefix cache for common system prompts. Per-request privacy mode opt-in. **Anthropic structurally cannot offer this** — buyer-controlled cache policy.

4. **Antseed as billing layer initially.** Don't build payment infrastructure in months 1-5. Use what already works.

5. **Don't fork Darkbloom.** Proprietary license, patent risk. Build own binary using their paper as spec, `mlx-swift-lm` (MIT) directly, Apple public APIs.

6. **Phase 3 NOT required for the M4 user.** They're cooperative, no privacy claim being made. Phase 2 MVP unblocks the relationship today.

---

## Open architectural questions (for future, not Phase 2 blockers)

1. **Phase 4 coordinator language.** Go (parallels Darkbloom) or Rust (parallels antseed)? Probably Go — simpler concurrency for I/O-bound WebSocket relay.

2. **Contributor reward mechanism.** Periodic USDC distribution from pool earnings? On-chain token? KISS option: simple proportional USDC payout weekly based on tokens served.

3. **Antseed protocol extension for "compute origin."** Currently no way to prove "this seller is real hardware, not API proxy." Worth raising with Antseed network operators eventually.

4. **Buyer-controlled trust tier.** Buyers should be able to demand `hardware`-attested providers vs cheap-and-fast unverified. Wire this through Phase 4 coordinator.

5. **Eventually-needed business layer.** API keys, Stripe billing, contributor portal, dashboard. Defer until Phase 6+ (post-validation).

---

## The single most important Phase 3 finding from Phase 1

**The Mac Provider binary MUST pre-flight context length checks.**

Llama 3.2 3B Q4 on M1 8GB hits a Metal GPU OOM at ~26K tokens. Process dies. Not a Python exception. **Cannot just forward requests and hope.**

Concrete Phase 3 requirements:
- Tokenize incoming prompt before invoking inference
- Compute expected KV+activation memory based on model + context length + concurrency
- Reject with HTTP 413 if it would exceed safe capacity (leave 1GB headroom)
- Advertise per-Mac context cap at registration: 8GB → ~20K, 16GB → ~50K, 32GB+ → much more
- Coordinator routes buyer requests by capacity match

This is the single most expensive bug to discover late. Phase 3 spec must include this from day one.

---

## What to read in the next session, in order

1. **This file (HANDOFF.md)** — the lay of the land
2. **`results/REPORT.md`** — Phase 1 evidence in full detail
3. **The conversation history** (this assistant's prior session) — strategic context, persona analysis, smart router design, Darkbloom deconstruction. Most decisions live there. Search for keywords: "pooled model", "Type B", "smart router", "Darkbloom paper", "Antseed network state".

Then decide: write the buyer harness, or talk to the M4 user first?

---

## Suggested next-session first message

```
Read /Users/augstar/macprovider-poc/HANDOFF.md, then /Users/augstar/macprovider-poc/results/REPORT.md.
Today: [pick one]
  (a) Write the Phase 2 buyer harness in beta/. Target the M4 user setup.
  (b) Decide what to ask the M4 user first — get their RAM, availability, model preference.
  (c) Draft the one-page setup README for the M4 user before any code.
```

That's a clean handoff. The next session should be productive within 5 minutes of reading.

---

## Tasks #10-#15 completed

**Date:** 2026-05-26

### New files
- `beta/workloads_adversarial.py` — 4 new adversarial workloads added: `long_context_oom_probe`, `concurrent_burst_8way`, `midstream_disconnect`, `malformed_tool_call`
- `beta/corpus.py` — Public-corpus prompt sampler with deterministic seeded selection from curated JSONL files
- `beta/corpus/` — 5 curated JSONL files (short, medium, code, long, agent) with 80-101 entries each (~100KB total)
- `beta/stop_tokens.py` — Per-model stop-token derivation from HuggingFace `tokenizer_config.json`, with local caching and fallback
- `beta/companion.py` — Host telemetry script (CPU%, RAM%, foreground app) logging to `~/.macprovider/host.sqlite`
- `beta/.cache/` — Runtime cache directory for model rotation index and tokenizer configs

### Changes to existing files
- `beta/workloads.py` — Each cooperative workload now samples prompts from corpus (falls back to hardcoded on failure)
- `beta/harness.py` — Added: `resolve_model()` for multi-model rotation, `full_responses` table (ring buffer, last 500), per-model leak detection via `stop_tokens.py`, `import stop_tokens`
- `beta/config.yaml` — Added `concurrent_burst_8way`, `midstream_disconnect`, `malformed_tool_call` to active adversarial batch; added commented-out `models:` and `model_select:` examples

### New dependency
- `psutil` — used by `companion.py` for CPU/RAM metrics. Install: `pip install psutil`
