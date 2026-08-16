# SPEC-023 v0.1 — Installer-Integrated Autotune Recommend — KICKSTART PROMPT

Run as: `omc ask codex "$(cat specs/SPEC-023-v0_1-KICKSTART-PROMPT.md)"` in a fresh codex session, OR open a fresh `codex` session manually and paste this file's contents as the first message.

This is a **self-contained SPEC drafting + audit prompt**. The codex session will NOT have prior conversation context, so this file carries everything needed.

---

## Mission

Produce a **locked normative SPEC document** at `specs/SPEC-023-installer-autotune-recommend.md` (version `v0.1`) for the macprovider Wave 0c product surface: installer-integrated `autotune --recommend` that scores rate-card-eligible models against the operator's Mac hardware and recommends the one with the highest expected net `$/hr`, replacing the current donor-default install behavior.

Run the SPEC through a **4-lane codex audit loop** (code / security / architect / product-design) until convergence at **0 CRITICAL / 0 HIGH / 0 MEDIUM** per `[[feedback-three-lane-codex-audits]]` (4 lanes here because this is a product surface, not pure backend money-path — matches the SPEC-018 agentic-tool-calling pattern).

**Do NOT** write any IMPL code, BUILD prompt, or open any PR. The operator will write the BUILD prompt and open the PR after reviewing the locked SPEC.

---

## Required reading (read all before drafting)

### 1. Decision log entries (most recent first)

- `beta/DECISION_CRITERIA.md` Entry 95 — Entry 94 misattribution correction (going-forward gate for "active production bug" claims)
- `beta/DECISION_CRITERIA.md` Entry 94 — Wave 0a/0b shape correction (no per-model registry; settle from provider usage on clean SSE streams) — note that Entry 94's "live buyer traffic" framing was wrong per Entry 95; the bug is real, framing was misattributed
- `beta/DECISION_CRITERIA.md` Entry 93 — 4-wave plan (Wave 0a gateway, 0b coord, 0c provider-side install/autotune defaults, 1 rate-card hot reload)
- `beta/DECISION_CRITERIA.md` Entry 92 — Beta pricing v2 LOCKED (per-model rate-card rows, per-model RAM-first admission, off-chain TOKEN_NAME ledger)

### 2. Research memos (locked inputs)

- `specs/RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_MEMO.md` — MoE model selection + market demand rankings (OpenRouter top-50, ranks for gpt-oss-20b, gemma-4, qwen3-30b-a3b)
- `specs/RESEARCH_227_RATE_CARD_V3_MEMO.md` — Rate-card v3 (5-row deployable subset + RESEARCH_227 Part 5 install/autotune donor-default diagnosis)
- `specs/RESEARCH_229_GOODHART_DEMAND_SIGNAL_PROBE_MEMO.md` — Goodhart probe output: 10 failure modes (FM-1 through FM-10), 20-row mitigation library, 8 v0.1 bake-in set (M1, M3, M4, M7/M8, M12, M16, M18, M20), recommended v0.1 formula shape, demand-signal source = option (b) static JSON. (Memo internally says "SPEC-018"; the preface clarifies it's SPEC-023.) Companion prompt at `specs/RESEARCH_229_GOODHART_DEMAND_SIGNAL_PROBE_PROMPT.md`.
- `specs/RESEARCH_230_COMPETITIVE_INSTALLER_UX_PROBE_MEMO.md` — Competitive UX probe output: vast.ai/RunPod/io.net/Akash/Bittensor/Aethir/Together/Lepton/Modal/Replicate sweep + Darkbloom counter-finding + 7 UX-pattern imports (StakingRewards, Lido, WhatToMine, NiceHash, Yearn/Beefy, AWS/GCP, electricity-plan tools) + proposed JSON schema + install transcripts. (Memo internally says "SPEC-018"; the preface clarifies it's SPEC-023.) Companion prompt at `specs/RESEARCH_230_COMPETITIVE_INSTALLER_UX_PROBE_PROMPT.md`.

### 3. Code surfaces this SPEC affects (read for current state, do NOT modify)

- `phase3-binary/dist/install.sh` lines 649-657 (`choose_model()`) — current donor-default logic that needs replacing
- `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift` lines 84-90 (`defaultCandidates`) — current zero-MoE candidate list
- `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift` (`MachineFingerprinter.sample()`) — current hardware probe
- `phase4-coordinator/internal/billing/formula.go` (`RateFor` + `normalizeModelKey` — Wave 0b shipped 2026-06-30 as `origin/main:a3149e3`)

### 4. Convention references (must follow)

- `CLAUDE.md` — git identity, PR workflow, money-path discipline, Darkbloom clean-room rule
- `specs/SPEC-017-network-stats-api.md` (or whichever version is locked) — exemplar locked SPEC format for product surfaces
- `specs/SPEC-018-agentic-tool-calling.md` v0.1.5 — exemplar locked SPEC that used 4-lane audit (code / security / architect / product-design)

---

## Deliverables

### A. The locked SPEC

`specs/SPEC-023-installer-autotune-recommend.md`

Header (lines 1-5):
```
# SPEC-023 — Installer-Integrated Autotune Recommend
version: v0.1
status: LOCKED
owner: operator (a11)
last-locked: <YYYY-MM-DD>
```

### B. Per-audit-round narrative files

`specs/SPEC-023-v0_1-rN-audit.md` for each round, listing per-lane verdict + findings + fixes applied + accepted LOWs. Match the format used in `specs/SPEC-017-r{1..7}-audit.md` / `specs/SPEC-WAVE-0A-0B-r{1..4}-audit.md`.

### C. Per-audit-lane prompt files

`specs/AUDIT_SPEC_023_v0_1_CODE_PROMPT.md`
`specs/AUDIT_SPEC_023_v0_1_SECURITY_PROMPT.md`
`specs/AUDIT_SPEC_023_v0_1_ARCHITECT_PROMPT.md`
`specs/AUDIT_SPEC_023_v0_1_PRODUCT_DESIGN_PROMPT.md`

Each prompt enumerates what that lane is looking for. See "Audit lane scope" section below.

### D. NO IMPL prompt, NO BUILD prompt, NO PR open

Operator writes the BUILD prompt and opens the PR after reviewing the locked SPEC.

---

## SPEC content requirements

The locked SPEC must contain these sections in this order:

### §1 — Mission

One paragraph: what `autotune --recommend` does, who it serves (every new provider installer + every operator running `autotune --recommend` post-install), and why Wave 0c lands now (beta launch readiness; provider acquisition cohort 120 needs frictionless install + correct first-model choice).

### §2 — Non-goals

Explicit list of what this SPEC does NOT do. At minimum:
- Does not solve "will buyers show up" — recommends model, not market demand
- Does not auto-switch models without operator action (no NiceHash QuickMiner-style behavior in v0.1)
- Does not change rate-card content (Wave 1 owns that)
- Does not change gateway billing or coord settlement (Waves 0a/0b already shipped)
- Does not add provider-side TPS reputation feedback to coord (deferred to v0.2)
- Does not implement live `/v1/demand-signal` coord endpoint (deferred to v0.2)
- Does not implement utilization-adjusted realized-earnings projection (deferred to v0.2 once buyer history exists)

### §3 — Inputs

Three input families:

1. **Hardware properties** — auto-detected by `MachineFingerprinter.sample()`. Includes RAM (GB), bandwidth tier (S/A/B/C), chip family, sustained-TPS-per-candidate (probed locally on each candidate via autotune benchmark). Lists exactly which fields are required vs optional.

2. **Rate card** — fetched from coordinator (`/v1/rate-card` endpoint) OR baked into binary at release time (offline fallback). Lists the schema: `{version, generated_at, rows: {<model_key>: {prompt_rate_per_mtok, completion_rate_per_mtok, provider_share_bps, global_multiplier_ppm}}}`. Note this matches `phase4-coordinator/internal/billing/formula.go::RateCardEntry`. Wave 0b's `normalizeModelKey` lookup applies to the model_key.

3. **Demand signal** — fetched from static URL `get.malibu.tech/demand-rank.json` with baked fallback in binary. Per RESEARCH_229 conclusion: option (b). JSON schema includes `version, generated_at, source, cold_start_floor, top_k_band, rows: {<model_key>: {demand_weight, rank, recommendable, min_provider_target}}`. SPEC must lock the JSON schema verbatim.

### §4 — Formula (locked v0.1)

```
eligible_rows = rows where:
  rate_card_enabled AND
  recommendable == true AND
  hardware_fits(model, mac) AND
  local_autotune_passes(model, mac)

raw_score(row | mac) =
  measured_tps(row, mac)
  × 3600
  × usd_per_million_completion_tok(row)
  × provider_share(row)
  × max(demand_weight(row), cold_start_floor)
  × tier_weight(row, mac.tier)

recommendation_pool =
  top-K eligible rows where raw_score >= 0.85 × max(raw_score)

default_model =
  pool[ stable_hash(provider_id_or_machine_fingerprint) % len(pool) ]
```

Constants locked in v0.1:
- `cold_start_floor = 0.15`
- `top_k_band = 0.85` (i.e., 85% of best score)
- `provider_share = 0.90` (from existing rate-card row)
- `tier_weight` defaults to `1.0` for all (tier interaction is documented as a known v0.2 lever)

### §5 — Eligibility gates (mandatory pre-filter)

A row is eligible ONLY if ALL pass:
- `recommendable == true` in demand-rank JSON (operator can disable broken rows here)
- `hardware_fits(model, mac)` — RAM headroom check: `model.min_ram_gb <= mac.ram_gb - safety_margin` (define safety_margin)
- `local_autotune_passes(model, mac)` — measured TPS, TTFT, no-swap, no-thermal-throttle during probe
- Coord rate-card has a row for the model (verbatim or via `normalizeModelKey`)

If no rows pass all gates: install transcript shows donor-mode-only path (see §7), no recommendation.

### §6 — Output JSON contract (`autotune --recommend`)

Lock the JSON schema verbatim. Use the structure from RESEARCH_230's proposal as the starting point; refine if needed. Required top-level fields:

```json
{
  "schema_version": "autotune_recommend.v1",
  "generated_at": "<RFC3339>",
  "hardware": {...},
  "inputs": {
    "rate_card_version": "...",
    "demand_rank_version": "...",
    "electricity_usd_per_kwh": null|float,
    "assumed_utilization": 0.0..1.0,
    "availability_hours_per_day": 0..24
  },
  "recommended_model": "<model_key>",
  "candidates": [
    {
      "rank": 1,
      "model": "<model_key>",
      "eligible": true,
      "expected_gross_usd_per_hour": float,
      "expected_net_usd_per_hour": float,
      "electricity_usd_per_hour": float,
      "platform_fee_usd_per_hour": float,
      "tokens_per_second": float,
      "memory_headroom_gb": float,
      "confidence": "low|medium|high",
      "why": "<one-line reason>"
    }
  ],
  "comparison": {
    "default_model": "<model_key>",
    "recommended_delta_usd_per_hour": float,
    "recommended_delta_percent": float
  },
  "warnings": [...]
}
```

Lock decisions: ranked array length default = 5; `electricity_usd_per_kwh` default behavior when absent (omit electricity row from net calc, warn); `confidence` derivation rules; deterministic field order for stable diff/test.

### §7 — Install transcript copy (locked text)

Two transcript paths, locked verbatim:

1. **Happy path** — Mac fits ≥1 recommendable model with `expected_net_usd_per_hour > 0`. Show: detected hardware, count of benchmarked candidates, recommended model + expected net, why (delta vs default), assumption disclosure ("estimate, not a guarantee"), `[Y/n]` start prompt.

2. **Donor-tier path** — no recommendable model has `expected_net > minimum_threshold` (lock the threshold value). Show: detected hardware, "no paid model clears the minimum net-yield threshold," best compatible option as donor-only, "Enable donor mode? [y/N]" with default No.

Lock exact wording. Lock the threshold (e.g., `$0.005/hr`). Lock the format string for `$/hr` rendering (4 decimals? 3?).

### §8 — Donor-mode UX

CLI flag: `--donor-mode` (boolean).
YAML config: `donor_mode: true` (boolean).
Install prompt default: No.

Behavior when `donor_mode == true`:
- Skip the eligibility-gate "no rows pass" abort
- Allow any RAM-fits model regardless of `recommendable` status
- Print explicit "$X/hr less than recommended" warning before commit
- `macprovider status` shows "DONOR MODE" badge alongside model

### §9 — Re-tune cadence + UX

Triggers that cause `autotune --recommend` to re-run (or prompt the operator):
1. Manual operator invocation: `macprovider autotune --recommend`
2. `macprovider upgrade` post-install (check if rate-card or demand-rank version changed)
3. NOT: automatic on coord SIGHUP / rate-card reload (deferred to v0.2 — defer the broadcast mechanism)

Stored state: last recommendation result saved to `~/.config/macprovider/last-recommendation.json` with `generated_at, rate_card_version, demand_rank_version, recommended_model`.

Stale-recommendation warning emitted by `macprovider status` when the live rate-card or demand-rank version differs from the stored one.

### §10 — Goodhart mitigations (cite by ID from RESEARCH_229)

For each of the 8 v0.1 bake-in mitigations from RESEARCH_229 (M1 top-K diversification, M3 cold-start floor, M4 row lifecycle states, M7 rate-card version binding, M8 retune hint, M12 hard eligibility gates, M16 deployability gate, M18 full-utilization wording, M20 static JSON), state which §X section of this SPEC implements it. Every mitigation must be traceable to a SPEC section.

### §11 — Acceptance criteria

Numbered list (~15-25 items) of verifiable behaviors. Examples:
- AC-1: `autotune --recommend --json` output validates against `autotune_recommend.v1` schema for any Mac.
- AC-2: When all rows fail eligibility, output emits donor-tier transcript and `recommended_model = null`.
- AC-3: When `demand_rank.json` 404s, installer falls back to baked snapshot and emits warning to stderr.
- AC-4: `stable_hash(provider_id) % len(pool)` produces deterministic recommendation for same provider_id + same pool.
- AC-5: Two distinct provider_ids on identical hardware get distinct recommendations from the same top-K pool (with statistical probability > 50% for K=3+).
- ... (continue through AC-15+)

Each AC is testable by either a unit test in IMPL or an end-to-end install script smoke test.

### §12 — Open questions / v0.2 candidates

Numbered list (Q1, Q2, ...) of decisions deferred to v0.2 or later. At minimum:
- Q1: Live coord `/v1/demand-signal` endpoint and switch trigger (RESEARCH_229: ≥60 days history + ≥50M paid tokens + ≥5 buyer accounts + no single buyer >50%)
- Q2: Tier-specific `tier_weight` calibration (currently 1.0 across the board)
- Q3: Provider TPS reputation downweighting from production traffic
- Q4: Utilization-adjusted realized-earnings projection
- Q5: Coord broadcast of "recommendation changed" on hot-reload (provider auto-prompt)
- Q6: Per-provider quota / coverage allocation policy
- Q7: Collusion detection / cartel monitoring
- Q8: Cross-Mac transfer of recommendation (e.g., operator clones config to second Mac)
- Q9: Donor-mode time-limited grant of token rewards (TOKEN_NAME ledger interaction)

### §13 — Differentiation framing (lift from RESEARCH_230 Part 3)

3-4 paragraph "wedge" framing for the operator to use in beta-launch messaging. Acknowledges Darkbloom as the closest existing surface; positions macprovider as installer-integrated + locally-benchmark-backed + machine-readable JSON output vs Darkbloom's web calculator.

### §14 — Threat model

Enumerate adversary capabilities + what SPEC v0.1 defends:

| Adversary | Capability | v0.1 defense | Deferred to v0.2 |
|---|---|---|---|
| Provider self-reports inflated TPS | Local autotune probes own Mac | Probe is CLI-owned; rejected | Cross-check vs coord-observed TPS |
| Provider tampers with `last-recommendation.json` | Reads/writes local file | None — operator owns their Mac | Sign the recommendation with provider key |
| Adversary serves bogus `demand-rank.json` via DNS hijack | Replaces static URL response | Pin TLS cert + checksum/sig the JSON | — |
| Provider group coordinates to all pick same row | Discord/off-network coordination | M1 top-K diversification limits worst-case | Coord quota policy |
| Provider opts into donor mode then claims earnings later | YAML config flip | Donor mode is logged; coord rejects non-recommendable rows for billing | — |

Lock the v0.1 defenses; defer the v0.2 ones explicitly.

### §15 — Acceptance & success metrics

Post-deployment metrics that mean "v0.1 worked":
- Median new-provider install time to first request served: < N seconds (lock N)
- % of new providers that DON'T pick the donor-class default: > 90%
- % of recommendations whose `expected_net_usd_per_hour` is within ±20% of realized net 7 days post-install: > 75% (assumes buyer demand)
- Operator-visible audit: every `event=rate_card_normalized` log line has a matching `event=recommendation_emitted` for the same model within the 24h preceding install

### §16 — Migration & backwards compatibility

How does this SPEC interact with already-installed providers (currently 2 on the network, both pre-Wave-0c)?

- Existing providers continue serving their currently-configured model; no forced switch.
- `macprovider upgrade` for existing providers prompts to run `autotune --recommend` once, showing potential delta.
- `~/.config/macprovider/config.yaml` `model:` field continues to override any recommendation — operator choice always wins.

### §17 — Audit-trail commitments

Per `[[feedback-spec-audit-file-convention]]`: this SPEC v0.1 ships with per-round audit narrative files (`SPEC-023-v0_1-rN-audit.md`) capturing the codex convergence trajectory.

Per `[[feedback-stop-iterating-on-low-audits]]`: convergence at 0 C/H/M is the stop condition; documented LOWs ship in v0.1.

Per `[[feedback-bundle-spec-impl-one-pr]]`: SPEC v0.1 ships in its own PR; IMPL bundles with v0.2 deltas in a later cycle.

---

## Audit lane scope (4 lanes)

After the SPEC draft is complete, run THREE rounds (minimum) of all 4 lanes via `omc ask codex "$(cat specs/AUDIT_SPEC_023_v0_1_<LANE>_PROMPT.md)"`. Each round's findings → fix-pass → re-audit until ALL lanes return 0 C/H/M.

Per `[[feedback-skip-accepted-audit-lanes]]`: once a lane returns 0 C/H/M, do NOT re-fire it in subsequent rounds UNLESS the next fix-pass touched its scope.

### Code lane

- Are all referenced struct fields, function names, and file paths correct against current `origin/main`?
- Are the JSON schema field names consistent everywhere they appear in the SPEC?
- Are the math expressions (formula, thresholds, defaults) internally consistent and dimensionally correct?
- Are the acceptance criteria (§11) each testable by a single unit test or integration test?
- Are the migration steps (§16) safe wrt the deployed Wave 0a/0b code at `a3149e3`?

### Security lane

- Threat model (§14) — is every realistic adversary capability covered, or are defenses deferred without justification?
- Can a malicious `demand-rank.json` (DNS hijack, MITM, replay of old rank file) cause unsafe recommendations?
- Can a malicious provider game the eligibility gates (e.g., fake autotune probe output)?
- Does any recommended row's billing arithmetic interact with Wave 0a/0b in a way that allows over-billing buyers?
- Are donor-mode rows safely partitioned from rate-card billing (donor providers must not earn on `recommendable=false` rows)?
- Does the SPEC introduce any new authentication, authorization, or trust boundary that needs explicit treatment?

### Architect lane

- Does §4 formula compose cleanly with Wave 0a/0b (rate-card normalization, settlement-from-usage)?
- Is the v0.1 / v0.2 split clean (no v0.2 work is implicitly required for v0.1 to ship)?
- Does the JSON schema have a clean versioning story (`autotune_recommend.v1` — what's v2)?
- Does the static-URL demand-rank approach scale to 120-provider cohort without operator burden?
- Are eligible-gate filtering + scoring + diversification independently testable and replaceable?
- Does the SPEC overlap with any other locked SPEC's surface (SPEC-005 billing, SPEC-017 stats, SPEC-018 agentic, SPEC-021 protocol-hub, etc.)?

### Product-design lane

- Are install transcripts (§7) clear, honest, non-confusing for a new operator?
- Does donor-tier transcript wording avoid implying "you've been rejected" (it's a hardware-tier reality, not a quality judgment)?
- Does the "$/hr" claim avoid over-promising? Does the warning (§7) appear before the `[Y/n]` prompt?
- Is the donor-mode opt-in path explicit enough that an operator can't accidentally enable it?
- Does `macprovider status` (§9) provide a clear "switch now" affordance, or does it bury the upgrade path?
- Does the wedge framing (§13) sound credible vs Darkbloom's existing earnings calculator, or does it overstate the differentiation?
- For operators whose Mac genuinely earns ~$0/hr today (M1 Air 8GB), does the SPEC offer a dignified path (donor mode + token rewards) or push them away?

---

## Process / stop conditions

1. Read all required reading.
2. Draft `specs/SPEC-023-installer-autotune-recommend.md` v0.1 with all 17 sections.
3. Write `specs/AUDIT_SPEC_023_v0_1_CODE_PROMPT.md`, `_SECURITY_PROMPT.md`, `_ARCHITECT_PROMPT.md`, `_PRODUCT_DESIGN_PROMPT.md` — each a self-contained audit prompt for that lane.
4. Fire round 1 audit: 4 lanes in parallel via `omc ask codex "$(cat specs/AUDIT_SPEC_023_v0_1_<LANE>_PROMPT.md)"`. Save each lane's output to a known artifact path.
5. Write `specs/SPEC-023-v0_1-r1-audit.md` summarizing all 4 lane verdicts + findings + fixes applied to SPEC + accepted LOWs.
6. Apply fixes to SPEC for findings rated CRITICAL / HIGH / MEDIUM. Do NOT iterate on LOWs.
7. Re-fire lanes that had C/H/M findings OR whose scope was touched by the fix-pass. Skip lanes that returned 0 C/H/M in round N unless fixed scope overlaps.
8. Write `specs/SPEC-023-v0_1-rN-audit.md` for each subsequent round.
9. Stop when ALL 4 lanes return 0 C/H/M in a single round (LOWs allowed and documented).
10. Print to stdout:
    - Final SPEC path: `specs/SPEC-023-installer-autotune-recommend.md`
    - Final round audit file path
    - Documented LOWs to surface in the PR body
    - Suggested PR title: `spec: SPEC-023 v0.1 LOCK — installer-integrated autotune recommend (Wave 0c)`
    - Suggested PR body summary (3-5 bullets)
11. STOP. Do NOT open a PR, do NOT write IMPL code, do NOT write a BUILD prompt. The operator will review the locked SPEC, open the PR as `Augustas11` per `[[macprovider-no-required-reviewers-merge-pattern]]`, and write the IMPL prompt in a separate cycle.

---

## Constraints

- **Money-path adjacent.** This SPEC affects provider economic routing. Wrong recommendation → wrong revenue → provider churn. Treat with money-path discipline.
- **Clean-room rule (Darkbloom / Layr-Labs/d-inference).** Per `CLAUDE.md`: do NOT inspect their source. Public marketing / docs / earnings calculator UI only. RESEARCH_230 already established what public pages show — use that, do not re-inspect.
- **Append-only audit trail.** Each audit round file is a new file, not an edit of the prior one.
- **Audit prompts go in files.** Per `[[feedback-audit-prompts-file-not-chat]]`: each audit lane prompt lives in `specs/AUDIT_SPEC_023_v0_1_<LANE>_PROMPT.md`, NOT in chat.
- **No spawn_task chips.** Per `[[feedback-no-spawn-task-chips]]`: any follow-up work that should be a separate session gets a recommended-next-step bullet in the SPEC's §12 (open questions), not a background-task chip.
- **Concrete, not aspirational.** Lock decisions. If you cannot decide between two options for a §X section, document both options as Q-N in §12 and pick one for v0.1.
- **No silent caps.** Per `[[feedback-audit-prompts-log-shape-backcompat]]`: if any audit round bounds findings (top-N, no-retry, sampling), surface what was dropped.
- **Three audit-lane convention (CODE / SECURITY / ARCHITECT) is well-known. PRODUCT-DESIGN is the fourth lane.** Per the SPEC-018 v0.1.5 pattern, product-design lane catches UX over-promising, copy-tone issues, and adversary-perspective on user behavior.

---

## Final preflight checklist (codex must verify before declaring done)

- [ ] SPEC has all 17 sections numbered §1 through §17.
- [ ] Every locked decision in §3-§9 is concrete (no "TBD," no "see below" without resolution).
- [ ] Every Goodhart mitigation (M1, M3, M4, M7, M8, M12, M16, M18, M20) is referenced by ID in §10 with a §X back-pointer.
- [ ] JSON schema for `autotune --recommend` is locked verbatim with all field names + types.
- [ ] JSON schema for `demand-rank.json` is locked verbatim with all field names + types.
- [ ] Install transcripts in §7 are locked exact strings (not paraphrases).
- [ ] All 4 audit lanes returned 0 C/H/M in the final round.
- [ ] Each round audit file lists all 4 lane verdicts (even if skipped-because-converged).
- [ ] No IMPL code written. No PR opened. No BUILD prompt written.
- [ ] Final stdout summary printed with SPEC path + audit-round file path + suggested PR title + body bullets.
