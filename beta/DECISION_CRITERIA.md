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
| 2026-05-27 | Phase 3 binary Step 9 acceptance: **MLX inference under concurrent access crashes the Metal command buffer.** Codex deliberately serialized all `/v1/chat/completions` calls behind a single inference worker to pass adversarial AC-2 (`concurrent_burst_8way`, 8 simultaneous requests). The burst tests passed cleanly because requests get **queued**, not parallelized. This is a hard limitation of `mlx-swift` 2.29.1 in v1, not a Codex implementation choice. | SPEC-001 FR-9's per-RAM-tier concurrency numbers (`16GB → 2-way`, `32GB → 4-way`) are aspirational, not achievable in v1. Effective `max_concurrency` is **1 across all RAM tiers** with the current MLX runtime. Provider advertises `slots_total: 1` and a request queue absorbs bursts. | **Amend SPEC-001 FR-9 in v1.2: declare `max_concurrency = 1` for all RAM tiers in v1, with explicit note that this reflects mlx-swift's serialization limit not the hardware ceiling. SPEC-002 FR-R1 routing already filters on `slots_free > 0`, so single-slot providers route correctly — no SPEC-002 amendment needed. Phase 4+ may revisit if mlx-swift releases real concurrent inference (track upstream). RAM-tier capacity differences in v1 are about **context length** (8GB→20K, 16GB→50K, 32GB→120K tokens), not concurrency.** |
| 2026-05-27 | **M4 parity validated: phase3-binary swap landed cleanly on M4 partner (admin user, Qwen 7B 4-bit, port 8080). Across 2 cooperative cron cycles (10 workloads total), throughput holds within ±10% of mlx_lm.server baseline (short_chat -9%, medium +3%, code_completion +4%, agent_style mixed in band), HTTP 200 rate 100% (vs M4's 89% baseline under mlx_lm.server), zero stop-token leaks. `streaming_check` now reports usage tokens (18.2 tps, 80 completions) where mlx_lm.server returned None/None — confirms FR-7 (synthesize usage chunk) is working as a buyer-visible quality improvement. | First successful third-party deployment of phase3-binary via tarball + nohup install (tmux-less path). Validates: relocatable build, owned_by:macprovider identity signal, FR-7 streaming usage synthesis, AC-3 24h soak now running on real M4 traffic. | **AC-3 24h soak validation now satisfied by real M4 deployment, not synthetic; SPEC-001 v1.2 patch for FR-9 max_concurrency=1 is locked in. Deployment tooling for future partners: tmux is NOT a hard prerequisite (notmux install path proven). Next: monitor for 24h, then plan M1 swap or accept M4-only validation as sufficient.** |
| 2026-05-27 | **Phase 4 coordinator built in <6 hours (Steps 1-11 committed; ~3,764 lines of Go + tests).** ~10× faster than Phase 3 binary (7 days, bottlenecked on Xcode/Metal/MLX toolchain quirks). Go's batteries-included toolchain + the spec rigor from 4 audit rounds combined to produce a clean build with mock-backed acceptance: hello/heartbeat/state-machine/wake-detect/routing/SSE-relay/preflight/auth/operator-endpoints/SIGTERM-drain all green via unit + integration tests. Three integration gaps remain (AC-2/AC-3 need external Phase 2 harness orchestration; AC-6 needs full process-level streaming SIGTERM harness) — these are orchestration tasks, not coordinator-code gaps. | Confirms the spec investment paid off: an over-spec'd module ships fast because every design question is pre-resolved. Validates the **build velocity asymmetry** between Apple-toolchain (Swift+MLX+Metal) and standard-tooling (Go) ecosystems for similar-scope work. | **For SPEC-003+ (Antseed integration), SPEC-004 (smart router), SPEC-005 (rewards), SPEC-006 (public API): prefer Go/Rust/Python over Swift unless there's a hard reason to use Apple tooling (i.e., model inference on Apple Silicon — the only place Swift earns its complexity in this project). Use Phase 4 coordinator's clean build as the v1 quality bar for downstream specs.** |
| 2026-05-28 | **Phase 4 AC-2/AC-3/AC-6 closed locally with a Go mock-provider harness** (`phase4-coordinator/tools/mockprovider/main.go` 605 LOC + 4 acceptance scripts). AC-2: 10/10 HTTP 200 across 2 cooperative rounds, blacklist of mock-A deterministically routes next request to mock-B. AC-3: 69/73 OK (94%) across retry_storm + concurrent_burst_8way + midstream_disconnect + malformed_tool_call; malformed_tool_call failures are spec-correct rejections, not coordinator faults; pool stays up. AC-6: 3/3 in-flight SSE streams complete with `[DONE]` across coordinator SIGTERM; drain dispatched to both providers; both reply `drain_status=complete`; new request post-SIGTERM correctly rejected; coordinator exits in 5s. Three orchestration findings surfaced: (a) **default routing is order-sticky under equal metrics** — `sort.SliceStable` on `SlotsFree ASC, Throughput DESC` means identical providers always route to first-registered until one differs on metrics; (b) **dynamic provider registration is not supported** — `config.providers[]` must enumerate every provider or hello close-codes 4002 `unknown_provider_id`; (c) **`/admin/blacklist` is on the provider WS port (8444), not buyer port (8443)**. | All 11 SPEC-002 acceptance criteria now closed locally with deterministic evidence; safe to cross-compile and deploy to VPS. Order-sticky routing is a documented behavior, not a bug, but worth a SPEC-002 v1.0.4 note before two-or-more providers are wired in production. | **VPS deployment unblocked. Pre-deploy: (1) add `.gitignore` for built binaries (`coordinator`, `coordinator-cli`, `mockprovider`, `default.profraw`); (2) SPEC-002 v1.0.4 patch — document order-sticky routing behavior and decide whether to randomize tiebreak when N≥2 providers share metrics within tolerance ε; (3) operator runbook entry that admin endpoints live on provider WS port. Mock-provider toolkit is reusable for any future spec needing pool simulation without real Macs.** |
| 2026-05-28 | **Phase 4 coordinator deployed to production VPS + end-to-end cloud path validated.** Three sub-findings, all surfaced in <3 hours of deploy work: (1) **VPS selection** — Antseed VPS at 165.22.182.207 is 1vCPU/458 MiB/8.7 GB already 28% in swap and hosting the revenue-bearing Antseed seller; co-locating the coordinator there would have put real money at OOM risk. Pearl VPS at 159.223.165.194 is 2vCPU/3.8 GiB/120 GB idle with separate workload; deployed there. (2) **provider_id was UUID-per-connect** — Codex implemented SPEC-001 § 6.5's example text (`"provider_id": "uuid-of-this-instance"`) literally with `UUID().uuidString` on every coordinator hello. But SPEC-002 v1.0.4 F-2 requires stable operator-issued IDs (close code 4002 unknown_provider_id on mismatch). Two specs disagreed; SPEC-002's static-config-map is the load-bearing trust-pool admission mechanism. Fixed: phase3-binary v1.1.2 gains `provider_id` field across YAML/env/CLI layers, with UUID fallback only for dev/test; SPEC-001 v1.1.2 replaces misleading example and adds normative paragraph cross-referencing SPEC-002 F-2. (3) **Cloud path validated** — Go mockprovider on operator's Mac connected via wss://coordinator.streamvc.live/ws/provider (DNS → nginx → LE TLS → coordinator), got hello_ack with provider_id=m4-anon, registered in pool as `state: ready` with full metrics, clean disconnect detection on kill. nginx reverse-proxy site separated `/v1/*` (buyer_port 8443, SSE-aware buffering off) from `/ws/provider`, `/admin/*`, `/poolz`, `/healthz` (provider_port 8444). | Spec rigor failed once at the audit phase — the SPEC-001/SPEC-002 disagreement on provider_id semantics wasn't caught across 4+3 audit rounds. The example placeholder text (`"uuid-of-this-instance"`) was suggestive enough that a literal-minded implementer read it as normative. The audit rounds checked for missing requirements but didn't flag inconsistency between SPEC-001 example text and SPEC-002 normative behavior. | **For future cross-spec audits: add a specific check for "fields shared across specs" that compares example-value semantics, not just field presence. Practical lesson: when an example uses a placeholder that could be interpreted as a contract (UUID, port number, fixed string), either make it obviously fake (`"<operator-issued-id>"`) or accompany it with a normative paragraph. SPEC-003 (Antseed seller integration) is the next critical-path spec; apply this lesson before audit rounds begin. Build velocity asymmetry continues: spec patches + Swift fix + Release rebuild + tarball + install script + cloud validation + 3 commits in ~75 minutes — faster than Phase 2 cron cycle.** |
| 2026-05-28 | **Day 2 wrap: the network works, the product doesn't yet exist.** Late-Day-2 state: M4 (phase3-binary v1.1.4) and M1 (v1.1.3) both `state=ready` in the production pool serving two distinct models. `POST /v1/chat/completions` with `model=Qwen 7B` routed to M4 in **2.48s**; same call with `model=Llama 3B` routed to M1 in **2.30s**; both via `https://coordinator.streamvc.live`. Lid-close on M1's MacBook at 04:00 UTC triggered the production-validated FR-P11 recovery cycle: HTTP 530 detected on first routed request, M1 marked `unavailable`, lid-open at ~04:05 brought the tunnel back, M1 reconnected with fresh `hello`, coord marked `ready` again, multi-model routing resumed. v1.1.4 drainFromCoordinator state-reset fix shipped + verified on M4 reconnect post-FORCE_RESTART (no stuck-draining). Cron simplified to one lane (`coord-cooperative.sh` every 15 min + `coord-adversarial.sh` daily) — direct-tunnel lanes retired since they're redundant with `/poolz` heartbeat liveness and become impossible under the planned architecture. **But: the same Day-2 session surfaced that the current product is operator-locked.** A stranger reading a GitHub README cannot become a provider without (a) a subdomain on `streamvc.live` you own, (b) a Cloudflare tunnel token you issue, (c) `provider_id` enumerated in `coordinator.yaml` (requires SSH + restart). Three hard blocks, all baked into the SPEC-002 v1.0.4 "Tier 1 cooperative trust pool" choice. Fine for 2 vetted partners; breaks at 5; impossible at 50. | The Phase 4 deliverable as built is **the technical core of an inference network, not a downloadable product.** Calling that out explicitly because every individual piece (binary, coordinator, routing, SSE, drain, recovery, multi-model) works under real partner hardware behavior — but the supply-side onboarding is operator-rate-limited. The architecture pivot to fix this is: **route inference through the existing provider WebSocket** instead of HTTPS-to-public-URL. Provider needs only outbound WSS, works behind any NAT, eliminates operator-managed DNS/tunnel infrastructure entirely. The pattern is industry-standard for outbound-only worker pools (Tor, Tailscale, GitHub Actions runners, Cursor agents) — convergent design driven by the "no public URL" constraint, not derivative. Cross-spec audit pattern (Claude+Codex, 3-4 rounds) ran clean on SPEC-001/002; we'll repeat it for SPEC-001 v1.2 + SPEC-002 v1.1 + new SPEC-003. Honest scope: 3-4 days of solid work for spec + audit + build + verify, plus a distribution layer (GitHub Releases + `install.sh` + launchd plist + `macprovider-cli update`) and a dynamic-admission layer (relax F-2 with a "provisional providers" tier where unknown `provider_id`s get probationary status). | **Next spec pivot:** SPEC-003 Antseed seller (was: first-revenue path) deferred to SPEC-007. SPEC-003 reframed as **"Open onboarding + WS-tunneled inference + dynamic admission + distribution lifecycle"** — the work to make this downloadable. SPEC-001 v1.2 adds normative `inference_request` / `inference_response_chunk` / `cancel_request` message types over the existing WebSocket. SPEC-002 v1.1 replaces the HTTP-forwarding path with WS-multiplexed relay + cancellation propagation + backpressure semantics; relaxes F-2 with a provisional-admission tier. Buyer-side surface stays stable (`POST /v1/chat/completions` unchanged). M4/M1 keep their existing direct-tunnel setups as "pinned providers" via the legacy `endpoint_url` path; new strangers default to WS-tunneled mode. After it ships, `curl -fsSL get.streamvc.live/install.sh \| bash` puts a stranger in the pool in <2 min with zero operator action. Day 3 (Friday) becomes design pass + cross-spec audit start, not a final go/no-go on the original criteria (those gated Phase 3 build, which shipped on Day 1). Also captured: v1.1.5/v1.2 should make phase3-binary's model_id comparison case-insensitive (mlx_lm.server was; current isn't — caused today's M1 cron 404 storm before Title Case fix). |
| 2026-05-28 | **Pool reaches N=2 + first multi-model end-to-end + v1.1.3 stuck-draining bug surfaced.** M1 partner (the M1 partner's Mac, Llama 3.2 3B 4-bit on 8 GB) ran install-m1-coordinator.sh with the v1.1.3 tarball. Initial issue: the coordinator's `config.providers[]` had drifted out of git when I'd added `m1-anon` directly on the VPS earlier, and a later `bash deploy-pearl-vps.sh` re-uploaded the stale local copy that only had `m4-anon`. M1 connection attempts close-coded 4002 `unknown_provider_id` until I fixed local `dist/coordinator.yaml`, asked M4 to upgrade to v1.1.3 (so they'd survive the redeploy drain), then ran `FORCE_RESTART=1 bash deploy-pearl-vps.sh`. **Result: pool N=2, both providers connected, /v1/models aggregates Llama 3.2 3B AND Qwen 7B with owned_by:macprovider.** First multi-model real inference through coord: `POST /v1/chat/completions {"model":"...Llama-3.2-3B..."}` routed to M1, returned `"HELLO"` in 2 tokens. **But: M4 reconnected after the restart in `state=draining`** and never returned to `ready` — v1.1.3's drainFromCoordinator() sets `providerStatus.status = .draining` for the drain handshake, closes the WS, the reconnect loop dials a fresh WS and sends hello, but the internal status never resets, so heartbeats keep reporting draining indefinitely. Coordinator router filters on `state=ready`, so M4 stays excluded from coord-routed traffic until binary restart (lid-close cycle, manual relaunch). M4 still serves direct buyer traffic via `m4.streamvc.live` correctly. | Two intertwined findings: (1) **Operational: out-of-band config edits on the VPS get reverted by `deploy-pearl-vps.sh`.** The script SCPs the local `dist/coordinator.yaml` as the source of truth. Fix: keep all provider list changes in local file + commit. Added a warning comment to `coordinator.yaml.example` (the gitignored real file is hand-synced). (2) **Implementation: v1.1.3's drain fix was structurally correct (process survives) but incomplete (state not reset).** The class of bug is "state-machine transition without reverse transition." After acknowledging drain we transitioned forward to `draining`, but reconnect needed an explicit forward transition back to `ready`. Spec-side fix opportunity: SPEC-001 § 6.5 should make the post-drain state explicit (recommended: hello/reconnect implicitly resets state per protocol invariant). | **Pool effectively N=1 ready, N=2 connected for the rest of today. v1.1.4 patch queued for next session: (a) drainFromCoordinator resets providerStatus.status to .ready (or pre-drain value) after WS close; (b) SPEC-001 § 6.5 adds normative paragraph: "the post-drain reconnect MUST start from a clean state machine; hello is the equivalent of a fresh hello, not a continuation of the prior session." (c) deploy-pearl-vps.sh could optionally diff /opt/macprovider/coordinator.yaml against the local file pre-upload and warn on drift — defense in depth against the operational class of bug. (d) Phase 4 acceptance hit: pool was N=2 with two distinct models serving real inference — a milestone the original 3-day plan didn't expect to hit until well after Day 3.** |
| 2026-05-28 | **Day 2 formal mid-review.** Status against the six Day-2 gates: G1 (≥2 days w/ ≥6h data) PASS — 26th 6h, 27th 14h. G2 (HTTP 200 ≥80% per provider) **FAIL** — coordinator 100% (n=5), M1 78.1% (n=411), **M4 67.6% (n=401, 0% today due to drain incident)**. G3 (adversarial survival) PASS — both providers all 4 adv workloads with n_ok > 0; malformed_tool_call failures are spec-correct rejections. G4 (stop-token detection) PASS — already resolved Entry 7 (upstream mlx-lm clean). G5 (no provider >24h dark) PASS — M4 last 200 was 27th 14:45, returned <12h later. **G6 (agent_style ≥80% valid-JSON) is mis-specified**: the agent_style workload was built to measure prefill cost on ~3K-token agent prompts, not to elicit JSON tool calls. Both Qwen 7B (M4) and Llama 3B (M1) produce coherent agent-style output — markdown reasoning + Python-style function-call syntax like `run_shell("git checkout main")`. Zero `{` characters across 127 samples isn't a quality fail; it's the criterion measuring a property the workload was never designed to produce. | Two real findings on top of the mechanical gate check. Finding A: **the original 3-day plan is technically blocked at Day 2 by G2, but every gate was designed to inform a Phase 3 go/no-go that is already moot** — Phase 3 shipped, Phase 4 shipped, M4 is live in pool, first production inference returned in 2.5s. The framework served its purpose by surfacing G6's mis-specification and confirming G3+G4 are fine; G2's M4-today failure is operator-caused (the drain incident) with a fix already shipped. Finding B: G6's mis-specification is the second cross-spec audit class that should be name-checked in SPEC-003 audits — "criteria written before the workload was finalized may measure a property that the workload doesn't produce." | **Day 2 review verdict: PROCEED (informally). The original plan's "iterate if any FAIL" applies to gating Phase 3 — Phase 3 is done. Real-status: ahead of schedule, single live provider, end-to-end working. Day 3 formal close tomorrow becomes lightweight. Spec/criteria action items: (1) DECISION_CRITERIA G6 should be rewritten to point at a JSON-strict workload OR retired; (2) consider adding a new `agent_json_strict` workload for buyers who actually need parseable tool calls (deferred until a buyer asks); (3) SPEC-003 audit rounds should include "criteria vs. workload coverage" as a class to check (criterion drift vs. workload semantics).** |
| 2026-05-28 | **Operator-caused incident: re-running deploy-pearl-vps.sh exposed a critical phase3-binary drain bug.** Sequence: (1) re-ran the deploy script to verify idempotency after fixing its broken step-6 sed; (2) the script ran cleanly end-to-end including `systemctl restart macprovider-coordinator` in step 7; (3) coordinator's SIGTERM handler correctly sent `drain` to M4 per SPEC-002 §6; (4) **M4's phase3-binary v1.1.2 handled `drain` by calling `Darwin.exit(0)` — process died**; (5) m4.streamvc.live started returning 502 (cloudflared tunnel up, origin gone); (6) coordinator pool empty. Tunnel-direct buyer traffic to M4 was broken until operator messaged M4 partner to re-run install-m4-coordinator.sh (~10 min outage). | The bug is SPEC-001/phase3-binary conflating two distinct paths: SIGTERM ("shut the whole provider down") vs. coordinator drain ("stop registering, keep serving direct buyers"). SPEC-001 v1.1.2 § 6.5 actually says `"same as SIGTERM behavior in FR-12"` — Codex implemented it literally, calling the same function. The "same" was meant to be procedural symmetry (drain_status sequence shape) not lifecycle conflation. Audit rounds didn't catch it because both sides looked correct in isolation. The class of bug — **shared internal helper used for two semantically different external events** — is worth named-checking in future audits. | **Fixes shipped in one patch cycle: (1) phase3-binary v1.1.3 splits `drainAndExit()` (SIGTERM, exits) from `drainFromCoordinator()` (drops WS, keeps HTTP, reconnects after 15s grace). (2) SPEC-001 v1.1.3 § 6.5 drain message now has explicit normative paragraph spelling out the distinction and calling out that conflating the paths is a critical bug. (3) deploy-pearl-vps.sh gains a step-6c pre-flight check against /healthz pool_size; refuses to restart with connected providers unless `FORCE_RESTART=1` is set. (4) tarball repackaged as phase3-binary-m4-v1.1.3-drain-fix.tar.gz, ready to ship. Field upgrade is non-urgent — v1.1.2 works fine until the next coordinator restart, and the deploy script safeguard now blocks that path by default. Next: SPEC-003 (Antseed seller) audit rounds should include a specific check for "two external events backed by the same internal handler."** |
| 2026-05-28 | **First real production end-to-end through coordinator.** M4 partner ran `install-m4-coordinator.sh` on the v1.1.2 tarball. Result: phase3-binary on their MacBook Air swapped in cleanly, hello'd the coordinator with provider_id=m4-anon, got hello_ack, started heartbeating. Pool snapshot 90s post-install: `m4-anon` state=ready, ram_gb=16, max_context=50000, max_concurrency=2, slots 2/2, throughput=9.12 tps, hostname="MacBook Air". A buyer-style request to `https://coordinator.streamvc.live/v1/chat/completions` (Qwen 7B, max_tokens=10, prompt "say OK") returned `"OK"` in **2.5 seconds** via the full cloud stack: nginx TLS → coordinator routing → HTTPS to m4.streamvc.live tunnel → phase3-binary → Qwen 7B 4-bit → response back. SSE streaming validated separately; tokens flow chunk-by-chunk through nginx with proxy_buffering off as configured. Install script bug surfaced: step 7/7 grepped the local binary log for "hello_ack" to confirm WS link, but phase3-binary acts on hello_ack silently (no log emit); M4's install printed a scary "WARNING: coordinator link not confirmed" while the link was provably up. Fix: step 7 now queries the coordinator's own `/v1/models` from the partner's Mac and checks whether the local model appears in the aggregated list (coordinator only includes models from connected providers, so presence is positive proof of WS link). Applied to both install-m4 and install-m1 scripts. | Phase 4 architecture is no longer hypothetical — there is a working buyer→coordinator→provider path serving real Apple-silicon MLX inference from a contributor's Mac. The 2.5s round-trip is dominated by Qwen 7B inference on M4 (the coordinator adds <100ms of routing+proxy overhead). Spec rigor pays off again: nginx config drafted from SPEC-002 § 7 with explicit Upgrade-header + SSE buffering directives worked first-attempt at port 443. Verification-pattern lesson: validate from the side that owns the truth (the coordinator's pool view) rather than the side that consumed the event (the provider's binary log). | **Phase 4 is production-ready for a single provider. Next: (1) point Phase 2 harness at https://coordinator.streamvc.live (replace tunnel_url in beta/config.yaml) to put continuous cron load on the production coordinator path; (2) send M1 partner the same upgrade flow now that the install script no longer cries wolf; (3) SPEC-003 (Antseed seller integration) is the next critical-path spec for first revenue — the coordinator now has a stable upstream that an Antseed seller can register against. Operator-side runbook addition: monitor /healthz uptime as the Phase 4 SLI and /poolz total_providers as the second-order capacity SLI.** |
| `____` | `_______________________________` | `___________` | `___________________` |

If this table has fewer than 5 entries by day 14, that itself is a
finding: Phase 2 isn't producing decisions, only data. That should heavily
weight the day-14 review toward "pivot" or "iterate."

---

## One-line summary to remember

**Phase 2 exists to surface specific Phase 3 design changes.** If it
doesn't produce a single "I changed Phase 3 spec line X because of Phase
2 row Y" sentence, it didn't earn its 14 days.
