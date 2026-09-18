# CLI Release Train — control surface

**This file is the single source of truth for provider CLI releases.** Work happens
across many sessions and agents; before cutting, testing, or promoting a CLI
build, read this file, and after any release-affecting action update it in the
same commit/PR. If reality and this file disagree, fix this file.

## How to track the next CLI

This table is the net change vs fleet **1.8.123**.

1. A PR that changes `phase3-binary/` (CLI, Malibu.app, installer) **merges** →
   add one row the same day. Status `merged`.
2. A PR is open but not merged → status `in progress`. It is **not** in the
   next candidate.
3. Cut a candidate off `main` → every `merged` row is in that build. If a row
   is still `in progress`, wait or leave it out of scope.
4. Promote that candidate to the fleet → bump “Current promoted stable”, delete
   the shipped rows, start a new table.

Do not put spec-only or CONFORMANCE-only PRs here. They do not change the
binary the Mac runs.

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

## Next CLI — net changes vs 1.8.123

All rows except the last are **already on `main`**. Next candidate = current
`main`. Last built candidate `v1.8.163` is old — do not promote it.

| Net change in CLI / Malibu / installer | Status | PR |
|---|---|---|
| Serve stays connected while BYOM admission is pending | merged | #1557 |
| MLX `models offer` sends snapshot hash (catalog-match works) | merged | #1548 |
| Malibu shows BYOM admission states | merged | #1497 |
| Discover OpenAI-compatible loopback models | merged | #1457 |
| Discover LM Studio and llama.cpp loopback models | merged | #1480 |
| CLI uses catalog artifact feed (baked fallback) | merged | #1468 |
| GGUF file identity hash (does not make Ollama earn) | merged | #1469 |
| BYOM offer-submit can be disabled | merged | #1448 |
| 16 GB Macs get Llama 3.1 8B, not 3B, from recommend | merged | #1488 |
| Headless Mini install + system-domain uninstall | merged | #1494 |
| First-install no longer false `rollback_failed` | merged | #1443 |
| Sparkle public key only on the v1.8.39 bridge build | merged | #1450 |
| Prepare/stage catalog artifacts without turning them on | merged | #1525 #1530 #1533 |
| Storage / Build 1 prep stays private until activation | merged | #1504 #1507 #1525 |
| SPEC-038 attach needs measured runtime evidence | merged | #1502 |
| SPEC-039 attach without sticky reattach | merged | #1475 |
| FR-PKV10 extract exists; serving still off | merged | #1476 |
| Paged KV sticky billing parity | merged | #1489 |
| Reward eligibility not claimed from the wrong state | merged | (Malibu rewards, `422fc2f1`) |
| Buyer prompt/content not leaked on relays | merged | #1467 |
| Pricing metadata only from validated endpoints | merged | #1455 |
| OpenRouter slot-delta / stale-capacity routing on CLI path | merged | #1571 #1535 |
| Installer 404 fix: paginate latest-release lookup, de-quadratic parser | merged | #1582 (#1574) |
| Live Ollama serve + Gemma tokens (non-earning) | in progress | #1569 #1576 |

#1453 closes when a candidate that includes the **merged** rows is promoted to
the fleet. #1569 is a later CLI. Spec promotion #1583 is not a CLI change.

## Active candidate

| Field | Value |
|---|---|
| Last built candidate | `v1.8.163` @ `8c0c51d2` |
| Status | **Do not promote.** Older than current `main`. |
| Next candidate | cut off current `main` |

## E2E tracks (independent gates)

A release is promotable only when **every in-scope track is GREEN on the same
combined candidate**.

### Track A — OpenRouter readiness

- **Owner / tracker:** #1570
- **Harness:** `scripts/openrouter_readiness_probe.py` · runbook
  `docs/runbooks/openrouter-provider-apply.md`
- **Gate:** benchmark success ≥ 0.95, TTFT p95 ≤ 5000ms, output tps ≥ 10, 0
  502/non-capacity failures; saturation sheds cleanly (early 429, no upstream
  errors); chat (paid+free), models, privacy, health/provenance, wholesale
  statement all pass. `--filing-mode` for the final application (prod URLs +
  benchmark ≥ 100).
- **Last run:** 2026-09-18, candidate `v1.8.163`. Provider-side OK. TTFT p95 /
  saturation still fleet-scale. Re-run on the next candidate.

### Track B — BYOM Ollama / Gemma

- **Owner / tracker:** #1569 (not #1453)
- **Harness:** `test/e2e/byom/run-cli-onboarding-e2e.py` · runbook
  `test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md`
- **Gate:** Ollama actually serving, probe returns tokens, marked non-earning.
- **Last run:** in progress. Skip this track unless this promotion is shipping
  #1569.

## Promotion gate (checklist)

1. All in-scope CLI rows above are `merged`.
2. Cut one candidate off `main` (`acceptance-candidate.yml`).
3. In-scope e2e green on **that** candidate (Track A this cut; Track B only if
   shipping #1569).
4. Physical acceptance (`promote-acceptance-candidate.yml`) — this is what
   bumps `binaryVersion` and moves the fleet.
5. `verify-live-coordinator-release-rollout` before publishing discovery.
6. Byte-identity check: `docs/runbooks/provider-cli-release-verification.md`.

## Session protocol

- Merge a CLI change, cut a candidate, or run an e2e track → update this file
  in the same PR/commit.
- Live-coordinator candidate test: add its `compatibility_set_id` to
  `accepted_ids` (keep `target_id`), restart coordinator, revert after.
