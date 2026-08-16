# HANDOFF PROMPT — Beta pricing v2 + token-incentivized rollout

You are picking up an in-flight beta-launch package for the
**macprovider** distributed inference network. The prior session
(2026-06-30, augstar) completed 5 codex research memos, drafted
`DECISION_CRITERIA.md` Entry 92 (the LOCKED v2 pricing + token-design
decision), and produced a benchmark tracking file. The work below is
what needs to land before the network can serve paid buyer traffic
under v2 economics with token-incentivized providers.

**Your goal**: take the locked decision through to deployed
implementation across 3 waves, while keeping every operator-only
decision explicitly flagged for the human operator (don't guess on
financial / token-design / external-comms calls).

---

## Step 0 — set up cleanly

1. Always work in a **fresh worktree**, never in the canonical checkout:
   ```bash
   cd /Users/<you>/macprovider-poc  # or wherever you cloned
   git fetch origin
   git worktree add ../macprovider-<topic> -b fix/<topic> origin/main
   cd ../macprovider-<topic>
   ```
2. This repo has a **per-repo credential helper** that routes pushes to
   `Augustas11` automatically (see `CLAUDE.md`). Plain `git push origin <branch>`
   works; you don't need to switch `gh` accounts.
3. Merging PRs requires the Augustas11 token explicitly: 
   `GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge ...`.
4. Per-repo rule: every PR needs **1 approving review** from `antfleet-ops`, 
   then `Augustas11` squash-merges (user-authorized — confirm with the operator 
   before merging anything you didn't write).

---

## Step 1 — read these in order (full context)

The decision is locked; do not re-litigate it. Read to understand
the *why* before writing code.

1. [beta/DECISION_CRITERIA.md](beta/DECISION_CRITERIA.md) — **Entry 92** at the tail
   is the locked v2 pricing + token design. Everything below implements it.
2. [specs/RESEARCH_222_PRICING_PROMPT.md](specs/RESEARCH_222_PRICING_PROMPT.md) +
   [specs/RESEARCH_222_PRICING_MEMO.md](specs/RESEARCH_222_PRICING_MEMO.md) —
   v1 (rejected). Skim only; it's the strawman we replaced.
3. [specs/RESEARCH_223_MLX_THROUGHPUT_ROADMAP_PROMPT.md](specs/RESEARCH_223_MLX_THROUGHPUT_ROADMAP_PROMPT.md) +
   [specs/RESEARCH_223_MLX_THROUGHPUT_ROADMAP_MEMO.md](specs/RESEARCH_223_MLX_THROUGHPUT_ROADMAP_MEMO.md) —
   12-month MLX engineering roadmap; per-cell tok/s targets.
4. [specs/RESEARCH_224_PRICING_V2_PROMPT.md](specs/RESEARCH_224_PRICING_V2_PROMPT.md) +
   [specs/RESEARCH_224_PRICING_V2_MEMO.md](specs/RESEARCH_224_PRICING_V2_MEMO.md) —
   the primary v2 memo with hardware-tier design + token-ledger design + per-model rate-card YAML.
5. [specs/RESEARCH_225_DARKBLOOM_COMPARISON_PROMPT.md](specs/RESEARCH_225_DARKBLOOM_COMPARISON_PROMPT.md) +
   [specs/RESEARCH_225_DARKBLOOM_COMPARISON_MEMO.md](specs/RESEARCH_225_DARKBLOOM_COMPARISON_MEMO.md) —
   competitor analysis. **CRITICAL**: darkbloom.dev = `Layr-Labs/d-inference`
   which is **clean-room restricted** per `CLAUDE.md`. NEVER inspect their source.
6. [specs/RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_PROMPT.md](specs/RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_PROMPT.md) +
   [specs/RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_MEMO.md](specs/RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_MEMO.md) —
   MoE rows that landed in Entry 92; OpenRouter market demand table.
7. [specs/BENCHMARKS_226_TODO.md](specs/BENCHMARKS_226_TODO.md) — re-ranked
   benchmark queue with P0/P1/P2 priority bands. **This is your TODO file.**

---

## Step 2 — the 3-wave rollout (from Entry 92)

| Wave | Scope | Hot-reloadable? | Gate |
|---|---|---|---|
| **Wave 1** | Rate-card hot reload of 6 rows (3 dense + 3 MoE) on Pearl `/opt/macprovider/coordinator.yaml` via SIGHUP | Yes | 4 P0 benches green |
| **Wave 2** | Per-model admission + bandwidth-tier filter + AutotuneRuntimeSupport bandwidth probe; ~350-600 LOC across `phase4-coordinator/internal/{config,pool,buyer}` + `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift` | No (restart required) | Wave 1 green + SCN-226-01/02 green |
| **Wave 3** | Off-chain `TOKEN_NAME` ledger (Option α: append-only CSV/SQLite/Postgres, mint at TGE later) | n/a | Wave 2 green + SCN-NEW-04 green |

**These waves are ordered — do not start Wave 2 before Wave 1 lands,
do not start Wave 3 before Wave 2 lands.** Each wave's failure modes
are independent and easier to debug in isolation.

---

## Step 3 — deliverables, ordered by what unblocks what

### TRACK 0 — land Entry 92 (~30 min, operator confirmation required)

The branch `docs/decision-entry-92` (created in the prior session) holds
Entry 92 as a single 1-row diff to `beta/DECISION_CRITERIA.md`. The
worktree is `../macprovider-decision-entry-92`. To land:

1. `cd ../macprovider-decision-entry-92 && git diff` — review
2. `git add beta/DECISION_CRITERIA.md && git commit -m "decision: Entry 92 — beta pricing v2 + MoE rate-card rows + token ledger design"`
3. `git push -u origin docs/decision-entry-92`
4. `gh pr create --title "..." --body "..."` 
5. Get antfleet-ops approval, then `GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge <pr#> --squash --delete-branch`
6. **Confirm with operator before merging** — Entry 92 commits the operator to a 3-wave plan.

This handoff prompt itself (`specs/HANDOFF_BETA_PRICING_TOKEN_ROLLOUT_PROMPT.md`)
is also in that worktree so it lands with Entry 92.

---

### TRACK 1 — Wave 1 unblock: the 4 P0 benches (~1-2 days)

Read [specs/BENCHMARKS_226_TODO.md](specs/BENCHMARKS_226_TODO.md)
Priority band "P0 — Gating Track B v2 launch".

#### SCN-223-01 — M4 Air dense-32B re-attribution
- **Why**: the original 14 tok/s number is 2× the theoretical 6-7 ceiling. Either the bench was wrong (pollution from a 7B provider in the pool), or there's a hidden efficiency win we don't understand. Until this reconciles, every per-cell number in RESEARCH_223 is suspect.
- **How**: isolated single-provider test, single M4 Air 24GB, Qwen3-32B-4bit (MLX format), 4K prompt, 512 completion, 3 runs, report median sustained tok/s. Verify model hash matches HF `mlx-community/Qwen3-32B-4bit` exactly.
- **Threshold**: 6-10 tok/s expected. >12 needs explanation (open SCN-223-01 investigation issue).

#### SCN-NEW-01 — per-model rate-card key normalization test
- **Why**: silent overcharge hazard. If a buyer hits with `Qwen/Qwen3-32B-Instruct-MLX-4bit` and the rate-card row is keyed `qwen3-32b`, the coordinator falls back to `default` ($1.00/M instead of $0.220/M). RESEARCH_224 flagged but didn't fix.
- **How**: read [phase4-coordinator/internal/billing/formula.go](phase4-coordinator/internal/billing/formula.go) for the model-string normalization logic. Write a test in `phase4-coordinator/internal/billing/formula_test.go` that tries 10 realistic buyer model strings against each of the 6 new rate-card rows and asserts the correct row is picked. If normalization is class-aware enough → test stays green and Wave 1 unblocks. If not → either patch the row keys or open SPEC-005 v0.3 delta for class-level lookup (see TRACK 4).
- **Threshold**: 100% match rate, no `default`-fallback for any realistic-shape model string.

#### SCN-NEW-02 — hardware-tier rejection telemetry
- **Why**: silently accepting an out-of-tier provider for 32B-dense at $0.220/M = provider earns electricity-only and quietly leaves the network.
- **How**: this depends on Wave 2 (tier filter) actually existing. So this bench writes the **test harness** that will exercise Wave 2 once it lands; meanwhile, it currently passes vacuously. Document the assertions: out-of-tier provider gets rejected with a specific error code (define one — e.g., `provider_tier_below_model_requirement`), the rejection is logged in audit-log with `{provider_id, requested_model, provider_tier, required_tier}`, and the provider receives a useful error string they can act on (not a stack trace).
- **Threshold**: harness lands now, becomes a real test gate in Wave 2.

#### SCN-NEW-03 — end-to-end billing smoke at new rates
- **How**: spin up 1 coordinator with `rewards.rate_card.qwen3-32b.completion_credits_per_mtok: 220000` + 1 M-Max provider + 1 test buyer; route 1000 completions; assert billing rows in coordinator DB show `gross_usd` consistent with $0.220/M (not $1.00/M default, not zero).
- **Threshold**: 100% of rows at expected rate; any default-fallback row = block Wave 1.

**When all 4 P0 benches green** → flip `rewards.rate_card` rows in
`/opt/macprovider/coordinator.yaml` on Pearl VPS, send SIGHUP, monitor.
**Operator must confirm Pearl deploy** — don't `ssh root@pearl` autonomously.

---

### TRACK 2 — Wave 2 implementation (~1-2 weeks, money-path)

This is the bulk of the engineering work. **Money-path code.** Per
`CLAUDE.md` and memory [[feedback-three-lane-codex-audits]], every
significant change needs 3 codex audit lanes (code, security, architect)
before PR.

#### 2a — bandwidth probe in provider binary
Edit [phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift](phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift)
(`MachineFingerprinter` struct at line 56). Add a normalized `memoryBandwidthGBps` 
field derived from chip family (e.g., M4 Max → 410-546, M2 Ultra → 800).
This is the value the coordinator routes on. Sources: Apple newsroom + 
tech specs pages (RESEARCH_226 cited live URLs). Estimated 80-120 LOC.

#### 2b — coordinator config schema + tier definitions
Edit [phase4-coordinator/internal/config/config.go](phase4-coordinator/internal/config/config.go).
Add `HardwareTiers` struct + `ModelAdmission` struct. Tier thresholds 
from Entry 92: S ≥700 GB/s, A ≥350, B ≥150, C <150 / unknown. Per-model 
admission from RESEARCH_226 Part 5 (3 MoE rows have `min_ram_gb` + 
`bench_gate`). Wire defaults; wire SIGHUP reload path (mirror existing 
`Rewards` config reload at [main.go:908](phase4-coordinator/cmd/coordinator/main.go:908)). 
Estimated 80-120 LOC.

#### 2c — per-model admission enforcement
Edit [phase4-coordinator/internal/buyer/server.go](phase4-coordinator/internal/buyer/server.go)
`selectProviderExcluding` at line 4228. For each candidate provider, check:
1. Does provider's `min_ram_gb` meet the row's requirement?
2. Does provider's bandwidth tier meet the row's `min_bandwidth_tier`?
3. (Future) has the provider passed the row's `bench_gate`?
If any fail → exclude + emit audit-log row per SCN-NEW-02 schema.
Estimated 80-150 LOC plus tests.

#### 2d — pool/provider hardware reporting
Edit [phase4-coordinator/internal/pool/provider.go](phase4-coordinator/internal/pool/provider.go) 
(and the WS provider registration/status structs) to persist the bandwidth + 
tier on every provider snapshot. Estimated 80-150 LOC.

#### 2e — pinned-provider bypass guard
Same `buyer/server.go` selection path. Ensure pinned-provider routing 
honors tier filter (a pinned Tier-C provider can't take a 32B-dense job 
just because they're pinned). Estimated 20-40 LOC.

#### 2f — audit-log + metrics
Buyer selection path + existing logger/metrics packages. Log every 
admission rejection with full context for ops debugging. Add metric 
counters keyed by `(model, tier, decision)`. Estimated 50-100 LOC.

#### 2g — provider portal copy
Update [portal repo / page] (operator: confirm portal source location;
RESEARCH_224 named `portal.malibu.tech` but didn't locate the source).
New page explaining tier eligibility. Must run before tier filter goes live
so M4 Air owners aren't surprised they can't take 32B-dense.

**Audit loop per [[feedback-build-audit-loop]]**: write SCN-226 + 
implementation changes → write narrow IMPL audit prompt to 
`specs/AUDIT_BETA_PRICING_V2_WAVE2_IMPL_PROMPT.md` → run 3 codex lanes 
(code, security, architect) → fix → re-audit → push PR only when all 
3 lanes return 0 CRITICAL/HIGH/MEDIUM.

**Bundle as ONE PR** per [[feedback-bundle-multi-phase-impl-prs]] — 
don't ship Wave 2 as 7 separate PRs.

---

### TRACK 3 — Wave 3 token ledger (~1 week)

Off-chain Option α per Entry 92. **Do not deploy any on-chain contract 
for beta.** This is operator bookkeeping that mints tokens at TGE.

Concrete deliverable: a small service or operator-runnable script that:
1. Polls coordinator stats endpoint daily.
2. Computes per-provider per-tier emissions: online floor (`4 base 
   MPROV/hr × tier_mult`) + served-token reward (`50 base MPROV/M × 
   tier_mult`) + benchmark-pass bonus (`2,500 × tier_mult`).
3. Appends rows to an append-only ledger (CSV/SQLite/Postgres — operator 
   picks; recommend SQLite for beta scale 120 providers × 180 days).
4. Tracks vesting state per row (90-day cliff + 12-month linear).
5. Exports a daily signed artifact (SHA256 + operator gpg key).
6. Provides a query interface: "what does provider X have vested as of 
   today?" — used by the provider portal earnings page.
7. Slashing hooks: operator manual flag for sybil/fraud/quality violations 
   forfeits unvested balance.

**No contract code, no token minting code, no on-chain anything.** Just 
operator bookkeeping that can be replayed deterministically at TGE.

**Operator decisions required before this can ship** (flag as a 
separate "OPERATOR NEEDED" file in the PR):
- Token name (currently `TOKEN_NAME` / `MPROV` placeholder)
- Planning supply (currently 1B; revisit if real)
- 6-month beta reserve % (currently 2%; revisit)
- 120-provider cohort cap split (currently 20S / 50A / 30B / 20C; revisit)
- Vesting cliff/linear (currently 90 days + 12 months; revisit)
- Whether to grandfather any existing providers into a tier

---

### TRACK 4 — class-level rate-card lookup SPEC delta (parallel to Wave 2)

Per Entry 92, exact-model rate-card rows are a known fragility. A SPEC-005 v0.3 
delta should add class-level matching (`32b:`, `70b:` regex-rooted) as a 
secondary lookup after exact-model fails, before falling back to `default`. 
This is a SPEC change requiring the full audit loop per 
[[feedback-spec-audit-loop-before-pr]] — write the SPEC delta, run codex 
audit lanes, fix until 0 C/H/M, then bundle with the IMPL per 
[[feedback-bundle-spec-impl-one-pr]]. Estimated 1-2 days SPEC + 1 day IMPL.

---

### TRACK 5 — MoE bench scenarios as Wave 2 gates (~3-5 days, parallel to TRACK 2)

Read [specs/BENCHMARKS_226_TODO.md](specs/BENCHMARKS_226_TODO.md) 
"SCN-226-NN" section.

- **SCN-226-01** — M4 Air 24/32GB × `gpt-oss-20b` ≥30 tok/s
- **SCN-226-02** — M4 Air 32GB × `gemma-4-26b-a4b-it` ≥30 tok/s
- These two gate MoE-row promotion from listed-but-not-admissible → 
  listed-and-admissible (Wave 2 effective).
- SCN-226-03/04/05 are P2 — capability expansion beyond v2 launch.

Operator likely has access to test hardware via M4 contributors 
(see memory `[[m4-contributor-day0-reaction]]`). Coordinate.

---

### TRACK 6 — operator-only decisions (block Track 3, do not guess)

Compile a single `specs/OPERATOR_DECISIONS_BETA_PRICING_V2.md` file 
listing every decision the operator must make before Wave 3 ships:

1. **Token name** — replace `TOKEN_NAME` / `MPROV` everywhere
2. **Planning supply** — confirm 1B or change
3. **6-month beta reserve %** — confirm 2% or change
4. **Cohort cap split** — confirm 20S/50A/30B/20C or change
5. **Vesting** — confirm 90-day cliff + 12-month linear or change
6. **Grandfathering** — any existing providers get a tier boost?
7. **Bench gate thresholds** — RESEARCH_226 set 30 tok/s + 2500-3000ms
   TTFT; confirm or change
8. **Portal source location** — where does `portal.malibu.tech` source
   live (Vercel repo? in-tree?), needed for TRACK 2g
9. **Pearl deploy mechanics** — who clicks `systemctl reload coordinator`
   for Wave 1 hot-reload
10. **PR review pattern for money-path** — 3-lane codex audit is the
    automation; do you also want a human pre-merge review beyond 
    antfleet-ops auto-approve?

Do not start Wave 3 implementation until items 1-6 have answers. Items 
7-10 can be deferred per-deliverable.

---

## Step 4 — suggested order of operations

```
Week 1
├─ Day 1-2  : TRACK 0 (land Entry 92) + TRACK 1 P0 benches
├─ Day 2-3  : TRACK 6 operator-decisions file (block Wave 3 cleanly)
├─ Day 3-5  : TRACK 2a-2c (bandwidth probe + config + admission core)

Week 2
├─ Day 6-7  : TRACK 2d-2f (pool/provider, pinned guard, telemetry)
├─ Day 7-9  : 3-lane codex audit on Wave 2 IMPL
├─ Day 9-10 : Fix audit findings, re-audit until 0 C/H/M
├─ Day 10   : TRACK 5 SCN-226-01/02 on test hardware
├─ Day 10   : TRACK 2 PR open, antfleet-ops approve, squash-merge
├─ Day 11+  : Wave 2 deploy, operator-only

Week 3
├─ Day 12-14 : TRACK 4 SPEC-005 v0.3 class-level lookup (parallel-feasible)
├─ Day 14-18 : TRACK 3 token ledger Wave 3 (gated on TRACK 6 operator decisions)
├─ Day 18-20 : SCN-NEW-04 cohort onboarding dry-run
├─ Day 20+   : Wave 3 ledger live, beta cohort onboarding can begin

Week 4+      : Beta cohort onboarding under tier-filtered + token-incentivized v2
```

This is aggressive. Realistic timeline is probably 4-6 weeks with 
operator decisions on the critical path.

---

## Step 5 — repo conventions you MUST follow

| Rule | Source |
|---|---|
| Always fresh worktree, never edit canonical | [[feedback-always-fresh-worktree-for-code-work]] |
| Per-repo gh token routing (push to Augustas11) | `CLAUDE.md` |
| `gh pr merge` needs `GH_TOKEN=$(gh auth token -u Augustas11)` prefix | [[gh-pr-merge-augustas11-token-prefix]] |
| Required-review merge: antfleet-ops approves, Augustas11 squash-merges (user-authorized) | [[macprovider-no-required-reviewers-merge-pattern]] |
| Codex-only audits (not internal subagents) | [[feedback-codex-only-audits]] |
| 3-lane audits (code/security/architect) for money-path | [[feedback-three-lane-codex-audits]] |
| Audit prompts written to file + `omc ask codex "$(cat ...)"` in loop | [[feedback-audit-prompts-file-not-chat]] |
| SPEC audit loop before PR (0 C/H/M required) | [[feedback-spec-audit-loop-before-pr]] |
| BUILD/IMPL audit loop before PR | [[feedback-build-audit-loop]] |
| Bundle multi-phase IMPL PRs (not one per phase) | [[feedback-bundle-multi-phase-impl-prs]] |
| Skip audit lanes that returned 0/0/0/0 unless next fix-pass touched their scope | [[feedback-skip-accepted-audit-lanes]] |
| Bundle SPEC + IMPL for incremental v0.x versions | [[feedback-bundle-spec-impl-one-pr]] |
| Never `git push --force` to main | `CLAUDE.md` |
| Money-path PRs go through PR review, not direct push to main | `CLAUDE.md` |
| No `spawn_task` chips (inline copy-pasteable prompts only) | [[feedback-no-spawn-task-chips]] |

Memory notes referenced as `[[name]]` live in 
`/Users/<you>/.claude/projects/-Users-<you>-macprovider-poc/memory/` 
on the prior session's machine. The operator can share them if needed.

---

## Step 6 — what "done" looks like

Beta phase proposal is **shipped** when:

- [ ] Entry 92 committed and merged to `main` (TRACK 0)
- [ ] 4 P0 benches green (TRACK 1)
- [ ] Pearl coordinator running new rate-card rows under SIGHUP hot-reload (Wave 1)
- [ ] Per-model admission + tier filter in coordinator + provider binary, 3-lane audited, merged (Wave 2)
- [ ] SCN-226-01 + SCN-226-02 green; MoE rows promoted to listed-and-admissible (Wave 2)
- [ ] `OPERATOR_DECISIONS_BETA_PRICING_V2.md` items 1-6 answered (TRACK 6)
- [ ] Off-chain token ledger live with daily signed export (Wave 3)
- [ ] SCN-NEW-04 cohort onboarding dry-run green (TRACK 1 follow-up)
- [ ] Provider portal page explaining tier eligibility published (TRACK 2g)
- [ ] First beta cohort provider onboarded under v2 economics

Re-trigger conditions (per Entry 92) automatically fire revisit of 
this whole thing on: first $500 paying buyer gross revenue, first 50M 
paid completion tokens, fleet sustained p50 Tier-A 32B ≥40 tok/s or 
Tier-S 70B ≥30 tok/s for 7 days, MoE-row p50 ≥120 tok/s for 7 days, 
token planning price outside $0.10-$10.00 for 30 days, Tier-A/S 
monthly churn >15% or all-tier >25%, cohort cap reached, or 90 days 
elapsed.

---

## Step 7 — signs you're going off-rails

Stop and ask the operator if you find yourself:

- **Inspecting `Layr-Labs/d-inference` source code** — clean-room rule, 
  hard stop. Public docs/API only.
- **Deploying any on-chain token contract** — Option β explicitly 
  rejected for beta in Entry 92.
- **Editing `rewards.global_multiplier` or `usd_per_million_credits`** — 
  Entry 92 locks both at 1.0; per-model rate-card rows are the only price knob.
- **Adding MoE rows beyond the 3 in Entry 92** without re-running 
  RESEARCH_226 against current OpenRouter rankings.
- **Letting M4 Air providers take dense-32B traffic** at the new rates — 
  this is the whole point of the tier filter, don't add escape hatches.
- **Mocking the billing DB in tests** — per `[[feedback-money-path-...]]`, 
  use real DB integration. Pattern is in 
  `phase4-coordinator/internal/billing/formula_test.go` already.
- **Pushing to main without PR + antfleet-ops approval** for any 
  money-path change.
- **Setting up grandfathering or special-case routing** for existing 
  providers without explicit operator sign-off.

---

## Step 8 — useful context not in the memos

1. **Provider runtime is Swift MLX, not Python sidecar** — older docs 
   may mention a Python sidecar; current `ModelRuntime.swift` uses Swift 
   MLX APIs with semaphore concurrency. RESEARCH_223 caught this.
2. **darkbloom uses mlx-swift in production**, same direction we went. 
   Their 30-day public stats showed $264 work revenue vs $1,946 reward 
   subsidy across 398 providers — empirical proof that token subsidy is 
   structurally required (not optional).
3. **MoE-with-small-active-params is the architectural unlock for M4 
   Air-class hardware** — bandwidth math is over active params, not
   nominal. GPT-OSS-20B (3.6B active) runs at 30-50 tok/s on M4 Air vs
   ~8 tok/s for dense Qwen-32B on same hardware.
4. **Production coordinator** is `coordinator.malibu.tech` (Pearl VPS).
   Public installer redirect is `get.malibu.tech/install.sh`.
5. **The decision log (`beta/DECISION_CRITERIA.md`) is the source of
   truth** for what was decided and why. If you find yourself making 
   a decision that isn't in there, write the entry first, then ship 
   the code.

---

## Final instruction

Start by:
1. Reading the 7 documents in Step 1.
2. Then come back to this prompt.
3. Then engage the operator with: "I've read the 5 research memos + 
   Entry 92 + the benchmark TODO. What's our top priority — landing 
   Entry 92 first, or are we in parallel mode where I should pick up 
   TRACK 1 P0 benches while you confirm operator-decisions for TRACK 6?"

Good luck. The decision is locked; the execution is craft.
