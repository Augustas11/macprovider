# RESEARCH_233 RUN — KV-cache survival across restarts (execution wrapper)

**Carry this in a fresh session.** Self-contained. This is the *execution wrapper*
for RESEARCH_233; the research payload it drives is the existing prompt
`audits/_prompts/RESEARCH_233_KV_SURVIVAL_RESTART_PROMPT.md` (Parts 1–7, the
five-approach evaluation, the required threat table). Read that payload in full —
this wrapper only adds what it can't know: current runtime-surface corrections,
the repo's execution discipline, and a live-data hook.

## What this produces

One decision-grade memo, `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md`
(~400–700 lines), picking ONE primary approach (of A–E) for persisting KV cache
across provider restarts, with the Part-4 security/attestation threat table and a
sequencing call vs RESEARCH_232 batching. **Research only — no runtime changes, no
normative SPEC edits in this turn.** The memo may *recommend* a follow-up SPEC; that
SPEC is drafted and codex-audited in a separate later session.

## Why now / the forcing function

`ConversationCache` is in-RAM only (`phase3-binary/Sources/macprovider-cli/ConversationCache.swift`).
Every deploy, crash, watchdog relaunch, or warm-swap destroys all KV state, and
long multi-turn / coding-agent sessions (8–64k tokens) re-pay full prefill —
tens of seconds of buyer TTFT. This is the biggest single buyer-TTFT cliff after
cold model load, and it compounds with the cold-start work in RESEARCH_234.

## Grounding corrections — the payload prompt is dated 2026-07-09 and has drifted

Verify the live surface before trusting the payload's references (repo rule:
verify runtime surface before designing). Known drift as of this wrapper:

1. **SPEC-024 billing moved.** The payload predates SPEC-024 v0.2.1 (2026-07-12) and
   SPEC-005 v0.6 (2026-07-12): prefix-cache **billing arithmetic** now lives in
   **SPEC-005 v0.6** (canonical). SPEC-024 retains only the `cached_prompt_tokens`
   wire field, the buyer-visible mirror, the fraud model, and the **provider-local
   cache-isolation baseline (§11–§16)** — that isolation baseline is the load-bearing
   input for the Part-4 cross-tenant-leakage row; read it, don't re-derive it.
2. **SPEC-015 v0.4.2 receipts are LOCKED** (settlement-capable profile for SPEC-022).
   The memo must NOT casually propose adding KV/cache fields to receipts. If persistent
   KV needs buyer-facing binding, that is a *future* SPEC-015 v0.5 question to name, not
   retrofit — mirror how the losslessness memo (SPEC-030) handled the same LOCK.
3. **In-repo prior art exists — use it.** Branch `origin/spike/kv-cache-hit-detection`
   proved LCP+trim reuse produces correct multi-turn output and staged a KV-cache IMPL
   handoff (the SPEC-024 payoff slice). Also `perf/t3-03-kv-quant-scheme` for kv_bits
   interaction. Consult these for the Part-3 Approach-A/B feasibility instead of
   treating disk-tiering as greenfield.
4. **Verify the prewarm spec number.** The payload cites "B1 idle prewarm (SPEC-017)",
   but SPEC-017 is the Network Stats API — idle-prewarm actually lives in the provider
   CLI (`idle_prewarm.*` config / `--no-idle-prewarm`, telemetry commit `ed2f782`).
   Cite the real surface, not the stale number.
5. **colibri `.coli_kv` caveat still holds:** its ~182 KB/token is GLM **MLA**-compressed
   KV; macprovider catalog models are mostly **GQA** — re-derive bytes/token, never
   transfer the number. colibri validates the append+resume *mechanism*, not the trust
   boundary.

## Live-data hook — consume the RESEARCH_234 campaign for Part 1

RESEARCH_234 is now collecting real restart-cost data on the prod provider; wire it
into Part 1 (problem quantification) instead of relying on oMLX marketing:

- **Preliminary, available now** (buyer-runner log, n≈1492 real round-trips):
  p50 3.9s / p95 16.8s / **p99 51.4s / max 186s**; ~4.2% of requests >20s are
  cold/contention events. That is the current lived restart/cold tail.
- **Accruing:** the 234 warm cells (`~/.local/state/coldwarm-ttft/coldwarm-samples.ndjson`)
  and the post-reboot watcher's cold samples give a measured cold→warm delta per the
  live 30B class. Read whatever is in the store at run time; if post_reboot samples
  exist, use the measured cold-load number as the "restart tax" Part 1 must reduce.
- Keep oMLX's "30–90s → <5s" claim clearly labeled as unreplicated marketing; the
  macprovider Part-1 numbers come from 234, not from oMLX.
- **Future KVS benches (Part 6) can reuse the 234 harness** (`test/e2e/coldwarm-ttft/`,
  now merged to `origin/main`) rather than building a new rig — note this in the
  milestones so the follow-up session doesn't rebuild it.

## Execution discipline (repo conventions — follow exactly)

- **Codex produces the memo, not a Claude subagent.** Research/audit memos in this repo
  are authored via codex (`omc ask codex` / the `/ask` skill). Single call, or twice
  with different models for cross-check. Claude's job here is to prepare the grounded
  prompt, run codex, then review/land the output — not to write the memo itself.
- **Backtick shell-quoting trap:** the payload prompt contains backticks and `$()`-like
  spans. Do NOT hand-assemble `omc ask codex "$(cat …)"` — invoke via the `/ask` skill
  or pass the prompt file path, so backticks in the file aren't shell-evaluated.
- **Fresh worktree off `origin/main`** for the memo; never edit the canonical checkout
  (it is currently mid-merge — leave it alone).
  `git worktree add ../macprovider-233-kv-memo -b research/kv-survival origin/main`
- **The memo file goes in `docs/research/`; the prompt stays in `audits/_prompts/`**
  (a CI gate rejects research prompts outside `audits/_prompts/`). Do not move the
  payload prompt.
- **Conservative > optimistic** on every TTFT-reduction claim; separate replicated
  measurement from vendor marketing. Threat table (Part 4) is required, not optional.
- **Landing:** the memo is docs-only → PR on the docs path (author as Augustas11 so
  antfleet-ops can review; merge with `GH_TOKEN=$(gh auth token -u Augustas11)`).
  A pure-research memo does NOT need the three-lane code/security/architect audit loop
  (that discipline is for IMPL and for SPEC drafts). After squash-merge:
  `git checkout main && git fetch origin && git reset --hard origin/main`.
- **No GitHub issues** from the memo's findings (repo rule). Follow-ups live in the
  memo's milestones and, if warranted, a later SPEC.

## Execution order

1. **Preflight:** read the payload prompt + `ConversationCache.swift` + the SPEC-024
   §11–16 isolation baseline + the `origin/spike/kv-cache-hit-detection` prior art.
   Snapshot the current 234 sample store for Part 1.
2. **Ground the prompt:** produce a short grounding addendum (the five corrections
   above, filled in with verified current values + the 234 numbers) to prepend to the
   codex invocation, so the memo isn't written against stale spec references.
3. **Run codex** (`/ask` skill) with payload + grounding addendum → memo draft.
4. **Review the draft** as Claude: is the Part-4 threat table complete for all five
   approaches? Is the RESEARCH_232 sequencing call explicit (persistence-first vs
   batching-first)? Are TTFT claims sourced (234-measured vs oMLX-marketing)? Is the
   receipt-LOCK respected? If gaps, re-run codex on the specific gap, don't hand-patch.
5. **Land** the memo via docs PR; reset local main after merge.

## Definition of done

- `docs/research/RESEARCH_233_KV_SURVIVAL_RESTART_MEMO.md` merged to `main`
  (~400–700 lines, exec summary ≤10 bullets).
- ONE primary approach recommended + fallback + no-go list.
- Part-4 threat table filled for approaches A–E (stale-cache, cross-tenant leakage,
  prefix-recovery, receipt-mismatch, OPoI-drift), with mandatory invalidation rules
  and an explicit "new attestation field vs provider-local" verdict.
- Explicit sequencing recommendation vs RESEARCH_232 batching.
- Part-1 quantification uses RESEARCH_234 measured data where available, oMLX numbers
  labeled as unreplicated.
- Part-6 KVS bench scenarios defined, noting reuse of the merged
  `test/e2e/coldwarm-ttft/` harness.
- Authored via codex, not a Claude subagent. No GitHub issues filed.
