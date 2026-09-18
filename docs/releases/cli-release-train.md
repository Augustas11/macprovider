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

CLI-affecting changes tracked toward the next promotion (update as they land):

| Change | Status | Commit / notes |
|---|---|---|
| #1571 OpenRouter request-capacity slot deltas (#1570) | merged | `94c758ea` |
| #1572 heartbeat_miss_threshold for every CLI | merged | `8c0c51d2` |
| #1577 throughput floor keeps admitted sessions | merged | `9b5ddbc1` |
| #1569 BYOM live ollama_loopback serve + Gemma synthetic probe | in progress | pending merge — Track B |
| _(add new in-flight CLI PRs here)_ | | |

## Active candidate

| Field | Value |
|---|---|
| Last built candidate | `v1.8.163` @ `8c0c51d2` (signed, acceptance-candidate.yml run 35294994825) |
| Status | **SUPERSEDED once #1569 / any later in-scope change merges — do not promote.** |
| Next candidate | cut fresh off `main` tip after all in-scope changes merge |

## E2E tracks (independent gates)

A release is promotable only when **every in-scope track is GREEN on the same
combined candidate** (validate the combined build, not each change in isolation).

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

### Track B — BYOM Ollama / Gemma

- **Owner / tracker:** #1569 (epic #1240)
- **Harness:** `test/e2e/byom/run-cli-onboarding-e2e.py` +
  `admission_journey.py` · runbook `test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md`
- **Gate:** real Ollama loopback runtime discovered
  (`runtime_source: ollama_loopback`), real coordinator admission, offer
  dry-run + submit, `health_result: passed`, non-earning disclosure correct, no
  production mutation. Full criteria in the runbook.
- **Last run:** in progress (this track's session / #1569).

## Promotion gate (checklist)

1. All in-scope CLI changes merged to `main`.
2. One candidate cut off the combined `main` tip (`acceptance-candidate.yml`,
   `promotion_ready=false`) and signed.
3. **Every in-scope e2e track GREEN on that combined candidate** (Track A and
   Track B, per scope).
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
