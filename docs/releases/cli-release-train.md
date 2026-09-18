# CLI Release Train — control surface

**This file is the single source of truth for provider CLI releases.** Work happens
across many sessions and agents; before cutting, testing, or promoting a CLI
build, read this file, and after any release-affecting action update it in the
same commit/PR. If reality and this file disagree, fix this file.

## Core rule (do not violate)

- **Candidate tags do NOT bump `binaryVersion`.** Every acceptance candidate
  (v1.8.124 … v1.8.16x) was cut with the source
  `binaryVersion` constant unchanged (it is `1.8.123` = the last promoted
  stable). The candidate's identity lives in its signed `compatibility_set_id`
  (`owner/repo:vX.Y.Z@<commit>`), not in `binaryVersion`.
- **The PROMOTED stable release is the only thing that bumps `binaryVersion`**,
  advances the coordinator `latest_binary_version` + `compatibility_set.target_id`,
  and triggers fleet autoupdate.
- Cut the promotable candidate off the **current `main` tip after all in-scope
  changes are merged** — never promote a candidate that predates a merged
  in-scope change.

## Current promoted stable

| Field | Value |
|---|---|
| Version | **1.8.123** |
| Compat-set id | `Augustas11/macprovider:v1.8.123@37e2d232389ba37d94f138b5a7d52a12c2b12106` |
| Coordinator `target_id` / `latest_binary_version` | `1.8.123` |

## Release train — next promoted release

Contents = **everything merged to `main` since `v1.8.123`**. Do not hand-maintain
the full list; regenerate with:

```bash
git fetch origin && git log --oneline v1.8.123..origin/main
```

`main` tip as of this update: `0435e118` (#1583). Tree `binaryVersion` is still
`1.8.123`.

CLI-affecting changes tracked toward the next promotion (update as they land):

| Change | Status | Commit / notes |
|---|---|---|
| #1457 `openai_compatible_loopback` + local-default `not_offered` | merged | `82a42b3e` — SPEC-046-R002/R003 |
| #1468 CLI consumes SPEC-023 artifact feed (compiled-in fallback) | merged | `914f7caf` — slice 2c |
| #1469 GGUF settlement **identity** (`macprovider.gguf-file.v1`) | merged | `c9445561` — identity only; Ollama still does not earn |
| #1480 `lmstudio_loopback` + `llamacpp_loopback` + CLI GGUF hash | merged | `4749e304` — discovery adapters; not #1569 serve |
| #1497 Malibu BYOM activation states | merged | `a0b3a0b2` — slice 6 app surface |
| #1548 MLX snapshot-manifest hash on `mlx_cache` offers | merged | `a5a42284` — unblocks catalog-match / `settlement_capable` |
| #1557 serve-hold through pending BYOM admission | merged | `6c69499a` — keep session bound while `buyer_serving_hold: model_admission_pending` |
| #1571 OpenRouter request-capacity slot deltas (#1570) | merged | `94c758ea` |
| #1572 heartbeat_miss_threshold for every CLI | merged | `8c0c51d2` |
| #1577 throughput floor keeps admitted sessions | merged | `9b5ddbc1` |
| #1453 signed SPEC-046/047 promotion | merged | `0435e118` (#1583) — ledger only; does not bump `binaryVersion` |
| #1569 BYOM live `ollama_loopback` serve + Gemma synthetic probe | in progress | #1576 open — **Track B, follow-on train, not a #1453 close blocker** |

### #1453 CLI payload this promotion must ship

Closing [#1453](https://github.com/Augustas11/macprovider/issues/1453) is the
CLI release cut. The fleet still runs `1.8.123`. The next promoted CLI is what
actually delivers BYOM v0.2 admission on boxes:

- Discover / evaluate / offer catalog-matched **MLX** through the CLI and Malibu.
- `mlx_cache` offers carry `macprovider.snapshot-manifest.v1` so the coordinator
  can catalog-match (#1548).
- Serve **holds** the live session through pending admission instead of treating
  `buyer_serving=false` as fatal (#1557). Binding survives to dual-control
  `settlement_capable` (SPEC-047-R003(iv) / R006).
- Artifact-feed consumption with compiled-in fallback (#1468).
- Honest non-earning disclosure for novel / GGUF / Ollama offers. GGUF identity
  exists (#1469); GGUF/`ollama_loopback` **runtime earning** does not.

Unsigned physical proof: `~/byom-admission-run/run-manifest.json` (`a03a715c`,
12/12, CLI `1.8.123`, money-path zeros). Signed promotion: SPEC-046-R001..R008
and SPEC-047-R001..R008 `conformant` on `main` (#1583). SPEC-047-R009 stays
pending and is not this cut.

## Active candidate

| Field | Value |
|---|---|
| Last built candidate | `v1.8.163` @ `8c0c51d2` (signed, acceptance-candidate.yml run 35294994825) |
| Status | **SUPERSEDED — do not promote.** Predates #1577 (`9b5ddbc1`) and `main` tip `0435e118`. |
| Next candidate | cut fresh off current `main` tip. #1453 CLI is already on `main`; do not wait on #1569. |

## E2E tracks (independent gates)

A release is promotable only when **every in-scope track is GREEN on the same
combined candidate** (validate the combined build, not each change in isolation).

**In scope for the next #1453 close-out promotion:** Track A and Track C.
**Out of scope for that cut:** Track B (#1569) — next train after #1453 closes.

### Track A — OpenRouter readiness

- **Owner / tracker:** #1570
- **Harness:** `scripts/openrouter_readiness_probe.py` · runbook
  `docs/runbooks/openrouter-provider-apply.md`
- **Gate:** benchmark success ≥ 0.95, TTFT p95 ≤ 5000ms, output tps ≥ 10, 0
  502/non-capacity failures; saturation sheds cleanly (early 429, no upstream
  errors); chat (paid+free), models, privacy, health/provenance, wholesale
  statement all pass. `--filing-mode` for the final application (prod URLs +
  benchmark ≥ 100).
- **Last run:** 2026-09-18, candidate `v1.8.163`, live path. Benchmark
  **100/100, 0 shed, success 1.0** (over-shed fixed). FAIL on TTFT p95 (6885ms)
  and saturation-did-not-shed — **fleet-scale, not provider-side code**; needs
  the fix across more fleet providers / real fleet load. Provider-side
  deliverable validated.
- **Re-run:** required on the next combined candidate (v1.8.163 is superseded).

### Track B — BYOM Ollama / Gemma (follow-on)

- **Owner / tracker:** #1569 (PR #1576). **Not required to close #1453.**
- **Harness:** `test/e2e/byom/run-cli-onboarding-e2e.py` +
  `admission_journey.py` · runbook `test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md`
- **Gate:** real Ollama loopback **runtime** discovered
  (`runtime_source: ollama_loopback`), live CLI serve, synthetic probe proves
  tokens, non-earning disclosure correct, no production mutation.
- **Last run:** in progress. The 2026-09-16 admission journey offered
  `ollama:gemma3:270m` as a novel offer only — it did not prove Gemma as a
  runtime.

### Track C — BYOM v0.2 catalog-matched MLX admission (#1453)

- **Owner / tracker:** #1453
- **Harness:** `test/e2e/byom/run-cli-onboarding-e2e.py --journey-evidence` ·
  runbook `test/e2e/byom/ADMISSION-JOURNEY-RUNBOOK.md`
- **Gate:** catalog-matched MLX discover → evaluate → offer → dual-control
  `settlement_capable` on one live serve; serve-hold keeps the session bound
  while `model_admission_pending`; all ten money-path ledgers stay 0. Signed
  SPEC-046-R001..R008 and SPEC-047-R001..R008 already on `main`.
- **Last run:** 2026-09-16 physical 12-step `a03a715c` (unsigned). 2026-09-18
  signed promotion #1583. Re-prove serve-hold + admission on the **next
  candidate** before promoting that candidate (do not promote v1.8.163).

## Promotion gate (checklist)

1. All in-scope CLI changes merged to `main` (#1453 CLI is; #1569 is not in
   scope for this cut).
2. One candidate cut off the combined `main` tip (`acceptance-candidate.yml`,
   `promotion_ready=false`) and signed.
3. **Every in-scope e2e track GREEN on that combined candidate** (Track A and
   Track C for this cut).
4. Physical acceptance (`promote-acceptance-candidate.yml`,
   `physical_acceptance_confirmed=true`) — production-signs, bumps
   `binaryVersion`, advances coordinator recommendation.
5. `verify-live-coordinator-release-rollout` gate before the discovery transport
   is published.
6. Release-asset byte-identity proof per
   `docs/runbooks/provider-cli-release-verification.md`.

## Session protocol

- Any session that merges a CLI change, cuts/signs a candidate, or runs an e2e
  track **updates this file in the same PR/commit** (train table, active
  candidate, track last-run).
- Testing a candidate against the live coordinator requires adding its
  `compatibility_set_id` to `coordinator.compatibility_set.accepted_ids`
  (additive; keep `target_id`) and a coordinator restart; revert after. See the
  #1570 comment thread for the exact live-canary procedure.
