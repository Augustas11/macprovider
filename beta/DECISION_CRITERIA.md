# Phase 2 — Decision Criteria

> **Operator must fill the bracketed fields and stamp the header below
> BEFORE day 1.** Once stamped, do not change criteria mid-flight — the
> point of pre-committing is to take judgment out of the moment when
> partial data is most persuasive.

---

## Header (sign before kickoff)

- **Operator:** augstar (augstar@gmail.com)
- **Kickoff date (day 0):** **2026-05-26**
- **Timeline:** **3 days compressed** (was 14). Concept validated on day 0 → Phase 3 unblocked sooner.
- **Day 2 mid-review date:** **2026-05-28**
- **Day 3 final decision date:** **2026-05-29**
- **Providers committed:** M4 user (handle: `m4-anon`) + M1 collaborator (handle: `m1-anon`)
- **Contributor expectation:** signed up for 14 days; compressed timeline means they get off the hook at day 3. They may keep tunnels running past day 3 if they want — operator decision only.
- **Total operator time budgeted:** **~2 hours/day** over 3 days
- **Cash budget:** Domain registration $12/yr (streamvc.live, already paid). Cloudflare Tunnel free. Electricity negligible. **Total: $0 marginal.**
- **What I'm using this data for:** Lock or unlock Phase 3 binary build.
  If criteria fail, Phase 3 timing slips or scope changes.
- **Tradeoff accepted:** retention signal (does contributor still tolerate this at day 11?), diurnal patterns across many days, slow-drift bugs — these can't be measured in 3 days. Compression is justified because core throughput/error/leak/sleep data lands fully in 3 days, and 3 Phase 3 spec changes were already captured on day 0.

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

## Day 2 mid-review — continue / pivot signal (2026-05-28)

**Proceed to day 3 final review only if ALL of the following are true:**

- [ ] **Uptime:** ≥2 days had ≥6 hours each with at least one provider reachable.
      *Query:*
      ```sql
      SELECT substr(ts_utc,1,10) AS day, COUNT(DISTINCT substr(ts_utc,1,13)) AS hours_with_data
      FROM runs WHERE http_status=200 GROUP BY day HAVING hours_with_data >= 6;
      ```
      Count the rows; need ≥ 2.

- [ ] **Cooperative reliability:** HTTP 200 rate per provider ≥ **80%**.
      *Query:* group by `tunnel_url`, expect column `ok_pct >= 80`.

- [ ] **Adversarial survival:** ≥1 successful `adversarial_runs` row per
      provider where `n_ok > 0` AND the provider's `mlx_lm.server` was
      still answering cooperative-cron traffic afterward. (Daily adversarial
      cron means each provider gets ≥2 runs by day 2.)

- [ ] **Stop-token detection diagnosed:** day-0 showed 0% leakage on both
      Qwen and Llama — either upstream mlx-lm now strips correctly, or
      our task-#13 per-model regex regressed. By day 2 we must know which
      (run a deliberate leak probe if needed).

- [ ] **No provider went dark for >24 hours** without explanation.

- [ ] **Operator can answer:** "what % of `agent_style` responses contain
      parseable tool-call JSON?" — at least 80% confidence in the number.

**If any FAIL → enter "iterate" loop:** see "What 'iterate' means" below.
Don't just extend day 2 hoping the next 24h fixes it.

---

## Day 3 final decision — Phase 3 go/no-go (2026-05-29)

**Proceed to Phase 3 (Swift binary build) only if ALL of the following:**

- [ ] All day-2 criteria still hold cumulatively over the 3 days (not just
      day-3 data in isolation).

- [ ] **Provider retention:** both providers reachable on day 3 (lid-close
      cycles OK, full silence not OK). One drop-off mid-experiment =
      downgrade to "iterate;" both gone = pivot.

- [ ] **JSON mode reliability:** ≥**90%** valid-JSON tool-call responses
      on at least one model in the rotation. With ~500 cooperative samples
      per provider over 3 days, this is statistically tight enough.

- [ ] **Cross-model differential exists:** Qwen 7B (M4) vs Llama 3B (M1)
      ran the same corpus-sampled prompts during overlapping hours. SQL
      JOIN should produce ≥**100** prompt-matching pairs to compare
      throughput/quality across models.

- [ ] **Specific Phase 3 design decisions changed:** must name ≥**3**
      Phase 3 binary spec lines that changed *because of* Phase 2 data.
      **Day-0 already captured 3** (502/530 routing, post-wake warm-up,
      capacity/quality tradeoff) — bar is already met. Anything more is
      bonus.

**If any FAIL → "iterate" or "pivot."** Don't ship to Phase 3 on hope.

**Contributor wrap-up:** regardless of go/no-go, send both contributors a
"thanks, you can shut down or keep running" message on day 3. The
cloudflared services keep running if they don't act — no urgency for them.

---

## Hard-stop triggers (any one of these — stop immediately, no review)

- Either provider goes dark for >24 hours **without explanation** (silence,
  not "I'm on vacation, back tomorrow"). Tighter than 14-day version because
  3 days has less buffer for outages.
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
| 2026-05-26 | Day 0 already captured 3 Phase 3 spec changes + clean baseline data across both providers. 14-day plan was paced for retention/diurnal/drift signal we don't need. | Compress to 3 days. Cron: cooperative every 15 min (4×), adversarial daily (vs 2×/week). Contributors stay on if they want (1A) — operator decision only. | **Phase 3 build starts 11 days sooner. Tradeoff: retention data is lost — re-add to Phase 5 pilot when real buyers come on.** |
| 2026-05-27 | Across **372 cooperative rows** spanning days 0-1 (M1 Llama 3B 8GB + M4 Qwen 7B 16GB), stop-token leak rate = **0%**. Two distinct tokenizer families (Llama `<\|eot_id\|>`, Qwen `<\|im_end\|>`) and ~24 hours of varied prompt content. Earlier worry that our task-#13 detection might be broken is dispelled by the sample size — if detection were broken we'd see 0 with any model; we now have positive evidence that mlx-lm's recent releases strip stop tokens cleanly upstream. | Downgrade FR-6 (defensive stop-token stripping) from "critical correctness" to "defense in depth." Still implement, but it is no longer the highest-risk Phase 3 surface. | **Phase 3 binary FR-6 stays as written but stops being a build priority. Run a deliberate leak-injection test during Step 9 acceptance instead of relying on production traffic to surface failures (which now appear vanishingly rare).** |
| 2026-05-27 | M1 first adversarial cron run (Wed 14:00 WITA, 4 workloads): retry_storm 50/50, concurrent_burst_8way 8/8, midstream_disconnect 10/10 ALL clean. **malformed_tool_call only 1/5 ok — 4× HTTP 404 instead of expected HTTP 400.** mlx_lm.server validates model existence BEFORE validating request shape; malformed JSON with bad `model` field falls through to model-not-found rather than invalid-request. | Confirms SPEC-001 § 6.2 validation order (1-5 before 6) is a real Phase 3 quality improvement over `mlx_lm.server`. | **Phase 3 binary must implement validation order strictly per SPEC-001 § 6.2 step 1→6. Add an AC asserting malformed_tool_call returns 400 (not 404). This is a buyer-facing semantic difference that affects error-handling downstream.** |
| 2026-05-27 | M4 reliability data across day-0/day-1: day-0 only 36% HTTP 200 (31/86) because of multiple lid-close cycles; day-1 recovered to 89% (85/95). M1 by contrast: 95% day-0, 100% day-1. Variance between providers is large and driven by hardware usage pattern, not hardware capability. | The Phase 2 D1 routing decision (502 vs 530) is empirically validated in real traffic. Coordinator must handle this variance gracefully — not just architecturally as we'd predicted, but operationally. | **SPEC-002 FR-P11 (502/530 distinction + recovery preflight) and FR-P8 (warm-up dispatch on wake) are not over-engineered — they're load-bearing for real provider hardware behavior. Validate during SPEC-002 build with mock providers that simulate the M4 lid-cycle pattern observed here.** |
| `____` | `_______________________________` | `___________` | `___________________` |

If this table has fewer than 5 entries by day 14, that itself is a
finding: Phase 2 isn't producing decisions, only data. That should heavily
weight the day-14 review toward "pivot" or "iterate."

---

## One-line summary to remember

**Phase 2 exists to surface specific Phase 3 design changes.** If it
doesn't produce a single "I changed Phase 3 spec line X because of Phase
2 row Y" sentence, it didn't earn its 14 days.
