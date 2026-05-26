# Phase 2 — Decision Criteria

> **Operator must fill the bracketed fields and stamp the header below
> BEFORE day 1.** Once stamped, do not change criteria mid-flight — the
> point of pre-committing is to take judgment out of the moment when
> partial data is most persuasive.

---

## Header (sign before kickoff)

- **Operator:** augstar (augstar@gmail.com)
- **Kickoff date (day 0):** **2026-05-26**
- **Day 7 review date:** **2026-06-02**
- **Day 14 review date:** **2026-06-09**
- **Providers committed:** M4 user (handle: `m4-anon`) + M1 collaborator (handle: `m1-anon`)
- **Total operator time budgeted:** **5 hours/week** over 2 weeks (~10h total)
- **Cash budget:** Domain registration $12/yr (streamvc.live, already paid). Cloudflare Tunnel free. Electricity negligible. **Total: $0 marginal.**
- **What I'm using this data for:** Lock or unlock Phase 3 binary build.
  If criteria fail, Phase 3 timing slips or scope changes.

I commit to **stop or pivot if the day-7 or day-14 criteria below fail**,
regardless of how invested I feel at that moment.

Signed (commit hash on this file is the timestamp): `_______________`

---

## Why this document exists

A premortem on the original Phase 2 plan flagged the cost of *not having*
written criteria. The two failure modes that document is designed to
prevent:

1. **Sunk-cost continuation** — two weeks in, the data is mediocre, but
   you have $X invested and a working harness, so you push to "give it one
   more week." Without pre-committed numbers, this happens by default.
2. **Vague go decisions** — Phase 3 binary build is 4–6 weeks of work. If
   Phase 2 produces "looks fine to me" data, Phase 3 is built on hope.
   Pre-committed numbers force the question: *what specific finding from
   Phase 2 changed my Phase 3 design?*

---

## Pre-launch facts (lock in before day 1)

These are the **measurement baselines** — once kickoff happens, compare
against them. Per-provider table because Phase 2 has two real providers,
not one. Empty cells = TBD when that provider comes online.

| Fact | M4 day-0 | M1 day-0 | Source |
|---|---|---|---|
| Cooperative HTTP 200 rate | **100%** (5/5) | **100%** (6/6) | query A |
| Median tok/s — short_chat | **19.8** | **22.9** | query B |
| Median tok/s — medium_with_system | **17.3** | **22.5** | query B |
| Median tok/s — code_completion | **19.8** | **25.5** | query B |
| Median tok/s — agent_style | **18.3** | **23.8** | query B |
| Streaming TTFT (streaming_check) | **708 ms** | **646 ms** | runs |
| Stop-token leak rate (all workloads) | **0%** | **0%** ← see decision log | query C |
| Adversarial `retry_storm` p95 latency | TBD | TBD | query D |
| `long_context_oom_probe` outcome | TBD | TBD | adversarial_runs |
| `agent_style` valid-JSON parse rate | TBD (manual) | TBD | manual / query E |
| Model serving on day 0 | `Qwen2.5-7B-Instruct-4bit` (16GB tier) | `llama-3.2-3b-instruct-4bit` (8GB tier) | config-mX.yaml |
| Streaming `usage` field present in SSE | **NO** — confirmed Phase 3 spec item | **NO** — same behavior, cross-model | runs |

**M4 baseline captured:** 2026-05-26T09:33Z via `scripts/m4-cooperative.sh`.
Single batch of 5 workloads through https://m4.streamvc.live → Qwen 7B 4-bit
on M4 hardware. Zero failures, zero stop-token leaks, throughput band
17.3-19.8 tps tight across context sizes 37-343 prompt tokens.

**Notable day-0 finding:** `streaming_check` had no `usage` chunk in the SSE
stream from mlx_lm.server — prompt_tokens and completion_tokens both NULL.
Phase 3 binary spec must synthesize usage on streamed responses.

**Reference queries (copy-paste into `sqlite3 runs.sqlite`):**

```sql
-- A. HTTP 200 rate, cooperative cron
SELECT ROUND(100.0 * SUM(http_status=200) / COUNT(*), 1) AS ok_pct
FROM runs;

-- B. Median tok/s per workload
SELECT workload, ROUND(AVG(throughput_tps), 1) AS tps
FROM runs WHERE throughput_tps IS NOT NULL GROUP BY workload;

-- C. Stop-token leak rate per workload
SELECT workload,
       SUM(stop_token_leak) AS leaks,
       COUNT(*) AS n,
       ROUND(100.0 * SUM(stop_token_leak) / COUNT(*), 1) AS leak_pct
FROM runs GROUP BY workload;

-- D. Adversarial retry_storm p95
SELECT model, ROUND(p95_ms) FROM adversarial_runs
WHERE workload='retry_storm' ORDER BY ts_utc DESC LIMIT 5;

-- E. Tool-call JSON parse rate — see "Day 5 hard probe" below
```

---

## Day 7 — go/no-go (week 1 → week 2)

**Proceed to week 2 only if ALL of the following are true:**

- [ ] **Uptime:** ≥5 days had ≥4 hours each with at least one provider reachable.
      *Query:*
      ```sql
      SELECT substr(ts_utc,1,10) AS day, COUNT(DISTINCT substr(ts_utc,1,13)) AS hours_with_data
      FROM runs WHERE http_status=200 GROUP BY day HAVING hours_with_data >= 4;
      ```
      Count the rows; need ≥ 5.

- [ ] **Cooperative reliability:** HTTP 200 rate per provider ≥ `[80]%`.
      *Query:* group by `tunnel_url`, expect column `ok_pct >= 80`.

- [ ] **Adversarial survival:** ≥1 successful `adversarial_runs` row where
      `n_ok > 0` AND the provider's `mlx_lm.server` was still answering
      cooperative-cron traffic afterward.

- [ ] **Stop-token detection works:** `SUM(stop_token_leak) > 0` over the
      whole week. Zero = detection is broken, not "model is clean."

- [ ] **No provider went dark for >48 hours** without explanation.

- [ ] **Operator can answer:** "what % of `agent_style` responses contain
      parseable tool-call JSON?" — at least 80% confidence in the number.

**If any FAIL → enter "iterate" loop:** see "What 'iterate' means" below.
Do NOT just extend week 1 hoping for better data.

---

## Day 14 — go/no-go (week 2 → Phase 3)

**Proceed to Phase 3 (Swift binary build) only if ALL of the following:**

- [ ] All day-7 criteria still hold cumulatively over 14 days (not just
      week 2 in isolation).

- [ ] **Provider retention:** both providers stayed in the program. One
      drop-off = downgrade to "iterate;" both = pivot.

- [ ] **JSON mode reliability:** ≥`[90]%` valid-JSON tool-call responses
      on at least one model in the rotation.

- [ ] **Mirror-mode data exists:** days 1–4 produced TTFT comparisons
      that let you separate host effects from server effects.
      *Query:* same prompt fired same-minute against both `tunnel_url`s
      with `(prompt_tokens, completion_tokens, model)` matching → SQL JOIN
      should produce ≥`[50]` pairs.

- [ ] **Specific Phase 3 design decision changed:** operator writes one
      sentence here naming a Phase 3 binary spec line that changed
      *because of* Phase 2 data. Examples:
      - "Context pre-flight ceiling for 16GB tier is N tokens, not the
        20K I assumed."
      - "Stop-token list for Qwen2.5 family includes [X] which my Phase 1
        regex missed."
      - "Mid-stream disconnect leaves the server in state [Y] — binary
        must add timeout cleanup."
      *If you cannot fill this blank, Phase 2 had no decision value.*
      
      My Phase 3 spec change from Phase 2: `__________________________`

**If any FAIL → "iterate" or "pivot."** Don't ship to Phase 3 on hope.

---

## Hard-stop triggers (any one of these — stop immediately, no review)

- Either provider goes dark for >48 hours **without explanation** (silence,
  not "I'm on vacation, back Monday").
- A provider's Mac **crashes more than once** from Phase 2 workloads
  (Metal OOM kernel panic, hard reboot needed). One is data; two is harm.
- A provider asks to stop. Their decision; no negotiation.
- Operator cannot answer the JSON parse-rate question by day 5 → the
  measurement apparatus is broken; fix or stop.
- Adversarial `concurrent_burst_8way` consistently puts a provider's Mac
  into thermal throttle that persists >30 min after the burst — that's
  past "fans spin" into "we're hurting their hardware."

---

## Soft-stop self-check (day 7 and day 14)

These don't auto-trigger a stop but force a conversation with yourself:

- Am I still finding this interesting, or am I forcing momentum?
- Is the operator-side workload (config tweaks, report reviews,
  contributor pings) under or over the budget I committed to in the
  header?
- Has anything in the **outside world** changed that makes this less
  important? (Anthropic ships local MLX inference, Darkbloom open-sources,
  Antseed changes seller protocol, etc.)
- If I had to **start Phase 2 over today** knowing what I know, would I?

If two or more of these tip negative, treat the day-7/14 review as a
"pivot" by default unless the data is exceptional.

---

## What "iterate" means

Not all failures kill the project — some need a second pass. The iterate
menu, ordered by severity:

| Failure | Iteration |
|---|---|
| Cooperative HTTP 200 rate <80%, root-caused to tunnel instability | Switch tunnel mechanism (named cloudflared ↔ ngrok), extend 1 week |
| Cooperative reliability fine, but one workload type fails reliably | Drop that workload from `batch:`, re-run week with reduced set |
| JSON mode <90% on all models | Add a non-MLX cloud fallback as comparison data point, do NOT pivot |
| Adversarial probes crash one provider's Mac once | Disable that specific adversarial workload, continue beta |
| Day-7 numbers fine but no Phase 3 spec change emerged | Add 1 more week of targeted data collection on the highest-uncertainty Phase 3 question |

**Cap: one iteration cycle.** If iterate-1 also fails its criteria,
pivot.

---

## What "pivot" means (the menu)

Phase 2 isn't load-bearing for anything outside this project — pivot is
real, not theoretical. Options, ordered by reversibility:

1. **Narrow scope:** Drop the second provider, run Phase 2 as N=1.
   Acceptable if the M4 user's data alone is rich enough to inform Phase 3.
2. **Change beachhead:** If Type B (AI power user) data shows poor
   retention, shift the Phase 3 spec target to Type A (passive earner).
   Same code, different pitch.
3. **Defer Phase 3 binary entirely:** Fork Darkbloom under their license
   constraints if the legal/dependency risk is now smaller than the
   re-implementation cost. (Requires re-reading their license.)
4. **Stop and write up findings:** If Phase 2 produces a clear "Mac
   inference at this scale doesn't work" answer, that result is itself
   publishable and informs other people's decisions.

The cost of NOT pivoting when you should: 4–6 weeks of Phase 3 binary
build burned on a foundation you don't trust.

---

## Decision log (fill in as data lands)

Append a row whenever you make a Phase 2 design or operational decision
based on harness data. The point: by day 14, this table is either rich
(go) or thin (no-go).

| Date | Observation (with query/row id) | Decision | Phase 3 implication |
|---|---|---|---|
| 2026-05-26 | M4 sleep transition observed: 502 (cloudflared up, mlx down, persisted ~14 min) → 530 (full disconnect). Tunnel API `conns_active_at` lags actual buyer-visible failure. | Distinguish failure modes in coordinator routing. | **Phase 3 coordinator must route around 502 with short backoff (~30s), remove 530 from pool until cloudflared reconnects. Poll `cfd_tunnel` connection count to predict imminent drops.** |
| 2026-05-26 | M4 post-wake throughput dip: 17.4 tps vs 19.8 pre-sleep (-12%) on identical `short_chat`. mlx weights survived sleep but first request was slower. n=1, needs more cycles to confirm pattern. | Track post-wake performance across 14 days. | **Phase 3 coordinator should fire synthetic warm-up request to a provider after detecting wake (cf. `conns_active_at` resuming after a gap) before routing buyer traffic.** |
| 2026-05-26 | Llama 3.2 3B 4-bit on M1 8GB: **0% stop-token leakage** across 6 cooperative requests, contradicting Phase 1 which observed `<|eot_id|>` on every short response. Response previews fully clean. Same model, same hardware tier, ~17 days apart. Likely mlx-lm update fixed upstream stripping. | Investigate if our per-model regex (task #13) regressed OR upstream fixed it. Either way: lower urgency for Phase 3 stop-token logic. | **Phase 3 binary may NOT need defensive stop-token stripping if upstream mlx-lm is clean. Still implement defensively, but it's not the critical-path bug we feared.** |
| 2026-05-26 | Cross-provider throughput inversion: smaller-model-on-slower-hardware (Llama 3B/M1 8GB → 22-25 tps) beats bigger-model-on-faster-hardware (Qwen 7B/M4 16GB → 17-20 tps). Even TTFT favors M1 (646 vs 708 ms). | Confirms capacity-vs-quality is a real routing tradeoff. | **Phase 3 buyer-facing API must expose model-size choice or auto-route by latency/quality preference. Coordinator cannot assume "newer/bigger Mac = faster" — depends on model.** |
| `____` | `_______________________________` | `___________` | `___________________` |

If this table has fewer than 5 entries by day 14, that itself is a
finding: Phase 2 isn't producing decisions, only data. That should heavily
weight the day-14 review toward "pivot" or "iterate."

---

## One-line summary to remember

**Phase 2 exists to surface specific Phase 3 design changes.** If it
doesn't produce a single "I changed Phase 3 spec line X because of Phase
2 row Y" sentence, it didn't earn its 14 days.
