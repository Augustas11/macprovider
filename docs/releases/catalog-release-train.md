# Catalog Release Train — signed SPEC-023 catalog content

> **Current state:** see "Current state — 2026-11-14" below. The older history
> ends at 2026-09-30 and is not rewritten. Per-release activation steps since
> then are recorded in `docs/releases/cli-release-train.md`.

**This file tracks signed catalog-content and pricing rollouts.** It is the
release-train companion to `docs/releases/cli-release-train.md` and
`docs/releases/coordinator-release-train.md`; the operational lane selection
and commands stay in `docs/runbooks/catalog-release-decision-tree.md`.

Update this file when a catalog-content or rows-only pricing PR merges, when a
signed content release goes live, or when a rollout is deliberately held behind
another gate.

## Current state — 2026-11-14

Read from `scripts/ops/catalog-activate.sh status` on 2026-11-14; the Live
entry is updated for the 2026-11-15 MiniMax activation.

- **Live:** `published-2026-11-17-glm53-uncensored-short-challenge-id-v289`
  (activated 2026-11-17 through `scripts/ops/catalog-activate.sh`, no
  coordinator restart, no price change), from
  [PR 2408](https://github.com/Augustas11/macprovider/pull/2408)
  (`1040f2d4d`). It shortens the uncensored GLM-5.3-Flash variant's self-test
  challenge id from 57 to 50 bytes so the released provider CLI 1.8.289
  accepts the coordinator's native-MTP canary request (issue 2404). Evidence
  (a)-(d) passed. Live probe passed: the coordinator logged a canary result
  with outcome pass 3 s after the challenge, the canary provider kept native
  MTP enabled, and the gateway proof request to
  `zai-org/glm-5.3-flash-uncensored` returned HTTP 200 with native-MTP
  forwards and continuous batching active. This is also the live probe for
  the uncensored GLM admission of PR 2394 (issue 2382). The previous live
  release was `published-2026-11-16-qwen27b-native-mtp-v289`, activated
  2026-11-16 on top of `published-2026-11-15-nemotron-3.5-bolt-listed-v289` with the operator's acknowledgement of the
  `minimaxai/minimax-m3.1-flash-abliterated` price row; it carried PR 2392
  (abliterated MiniMax M3.1-Flash listed row), PR 2394 (uncensored GLM
  native-MTP variant) and PR 2400 (Qwen3.6-27B and Qwen3.8-27B native-MTP
  tuples). Not yet done: buyer probes on the Bolt, abliterated MiniMax and
  Qwen 27B rows, which need a provider serving each; `buyer_ux_conformance_owed`
  for `minimaxai/minimax-m3.1-flash`.
- **Merged, not live:** `published-2026-11-15-minimax-m3.1-flash-abliterated-listed-v289` from
  [PR 2392](https://github.com/Augustas11/macprovider/pull/2392) (`cf64b09a6`, Related: #2376):
  a `listed` row for the abliterated MiniMax M3.1-Flash, generated against the live Bolt v289
  release. Activation needs the Pearl runtime carrying its billing alias first; the row serves
  only on the next CLI cut (engine `.71`). Steps are in `docs/releases/cli-release-train.md`.
- **Live since 2026-11-16 as part of the release chain, `published-2026-11-16-glm53-flash-uncensored-native-mtp-v289`
  (#2382, signed with `streamvc-autotune-static-v4`, stacked on the PR 2392
  release):** the native-MTP admission set gains
  `zai-org/glm-5.3-flash-uncensored` (`mlx-oq4e-uncensored-dflash2`, snapshot
  `242f8fcf…`) as an MTP-13 variant of `zai-org/glm-5.3-flash`, with its own
  quantization block and MTP-16 self-check record
  (`docs/evidence/glm53-uncensored-native-mtp-variant-2026-11-16/`). Nothing
  else changes; the Tier-2 catalog is unchanged from the PR 2392 release.
  **Activation order:** (1) the Pearl runtime release carrying the MiniMax
  abliterated billing aliases; (2) the PR 2392 catalog release
  `published-2026-11-15-minimax-m3.1-flash-abliterated-listed-v289`; (3) this
  release. **Live steps for this release:** (1) merge, then
  `scripts/ops/catalog-activate.sh status` and `next --run` once (2) is live;
  (2) the canary serving the uncensored build reports native MTP enabled
  (`live_probe`); (3) one buyer request through the gateway is served with
  native MTP (`gateway_proof`); (4) the next CLI cut bakes the release.
- **Activated 2026-11-16, superseded 2026-11-17, `published-2026-11-16-qwen27b-native-mtp-v289`
  (#2383, signed with `streamvc-autotune-static-v4`, stacked on the PR 2394
  release):** the native-MTP admission set adds two entries,
  `qwen/qwen3.6-27b` (`mlx-4bit`, snapshot `518ef47c…`) and
  `qwen/qwen3.8-27b` (`mlx-4bit`, snapshot `8a8786e9…`). Both run at depth 1
  with one native row, four slots and a 4096-token cap, with the self-test bank
  entries recorded 2026-11-04. R005 and R015 are from 2026-11-04
  (`docs/evidence/qwen27b-native-mtp-2026-11-04/`). Journey, security
  negatives, window bound and quantization are from 2026-11-16
  (`docs/evidence/qwen27b-native-mtp-2026-11-16/`). Nothing else changes.
  **Activation order:** (1) the PR 2392 release
  `published-2026-11-15-minimax-m3.1-flash-abliterated-listed-v289`; (2) the
  PR 2394 release `published-2026-11-16-glm53-flash-uncensored-native-mtp-v289`;
  (3) this release. **Live steps for this release:** (1) merge, then
  `scripts/ops/catalog-activate.sh status` and `next --run` once (2) is live;
  (2) a provider serving either 27B model reports native MTP enabled after its
  self-check; (3) one buyer request on each model through the gateway is
  served with native MTP; (4) the next CLI cut bakes the release.
- **Live since 2026-11-17 (details above), `published-2026-11-17-glm53-uncensored-short-challenge-id-v289`
  (Related: #2404, found in PR 2407; signed with `streamvc-autotune-static-v4`,
  generated on the live `published-2026-11-16-qwen27b-native-mtp-v289`):** the
  self-test bank renames the GLM-5.3-Flash uncensored variant entry
  `native-mtp-selftest-glm53-flash-0001-variant-f4215a95296e` (57 bytes, cache
  namespace 133 bytes) to `native-mtp-selftest-glm53-flash-0001-vf4215a95296e`
  (50 bytes, namespace 126 bytes). CLI 1.8.289 to 1.8.292 refuse a canary
  request whose `cache_namespace` is over 128 bytes with `invalid_message`, so
  every canary for that model disabled its native MTP. `expand_native_mtp_variants`
  in `scripts/catalog-release.py` names variants `<donor id>-v<first 12 hex of
  sha256(model_key)>` and refuses any challenge id over 52 bytes (SPEC-031
  v0.3.10 FR-CAN33). No other bank field changes; the admission entries change
  only in `challenge_bank_sha256` (`9794d0ab…` to `de272f1a…`) and the release
  stamps; the tuple input, projection manifest and rate rows are unchanged.
  `native_mtp_canary_v289_compat_test.go` checks every published entry against
  the 1.8.289 decoder. **Live steps:** (1) merge, then
  `scripts/ops/catalog-activate.sh status` and `next --run`; (2) live probe:
  after the canary provider restarts onto the release, the coordinator logs a
  native-MTP canary result with outcome `pass` for the uncensored build and the
  provider's `/v1/status` reports `native_mtp` enabled past two minutes;
  (3) the next CLI cut bakes the release.
- **`buyer_serving_e2e` owed:** the MiniMax M3.1-Flash artifact (since
  `published-2026-11-13-minimax-m3.1-flash-recommendable-v287`), the
  GLM-5.3-Flash uncensored artifact (since
  `published-2026-11-09-glm53-flash-uncensored-recommendable-v281`) and the
  DeepSeek V4-Flash MXFP4 artifact (since
  `published-2026-10-23-deepseek-v4-flash-recommendable-v1`).
- **Signed release manifest,
  [#2334](https://github.com/Augustas11/macprovider/pull/2334)
  (`d3b136de1`):** a catalog release may ship `release.json.sig`, one Ed25519
  signature over `release.json` (SPEC-023 §3.8). The coordinator code that
  serves it at `/v1/catalog-release`, and its nginx routes, are not live:
  they ride the next Pearl runtime (live is `v1.8.286`). No tracked
  `release.json.sig` exists on `main` at `30fdbe2cf`, so the committed MiniMax
  release carries no manifest signature. #2334 also removes the pre-#2282
  signed-pair, binding-bundle and `signed-pair-plan.py` activation paths.
- **Order:** `scripts/ops/README.md` says catalog activation comes before the
  CLI cut. `cli-release.sh` keeps `candidate_cut` blocked until Pearl serves
  the catalog release on `origin/main`.

## Live on Pearl (2026-09-30, historical)

| Field | Value |
|---|---|
| `autotune/current` | `published-2026-09-25-artifact-hash-correction-v1` |
| Tier-2 catalog | `macprovider-tier2-model-catalog-2026-09-25-artifact-hash-correction-v1` |
| Pricing lane | No post-September-25 rows-only pricing correction is recorded as live in this train. |

Pearl runtime `v1.8.209` was applied through the runtime-only updater on
2026-09-30. The live catalog symlink remained on
`published-2026-09-25-artifact-hash-correction-v1`; #1805 was not activated.

## Pending catalog / pricing rollouts

| Change | Status | Gate |
|---|---|---|
| #1805 pins the OpenRouter-listed Qwen3.6 row behind operator-reviewed advisory market holds: `47,500` prompt, `11,875` cache-hit, and `665,000` completion credits per million tokens. Market evidence may hold the row but must not auto-lower the operator pin. | merged source policy `92d840c3` 2026-09-30; no signed catalog/rate-card rollout yet | **Hold until #1807 completes.** Do not sign or deploy this pricing rollout before the 8 GB / 16 GB fleet demand and catalog-migration issue has completed its acceptance criteria. |

## Rollout rule for #1805

After #1807 is complete, refresh the OpenRouter evidence, review the effective
price diff, and use the catalog-content pricing path in
`docs/runbooks/catalog-release-decision-tree.md`. The signed rollout must be a
reviewed catalog-content/pricing release with the lane's normal preflight,
acknowledgement, journal, SIGHUP, and evidence checks. Do not hand-edit Pearl
pricing, Pearl catalog files, or live provider settings to make #1805 active.

## Evidence

- #1805 merged as `92d840c3472b46ca3525dfcb0e359d26575d5f7f`.
- #1805 validation recorded 551 OpenRouter/catalog Python tests,
  `scripts/test-catalog-release.sh`, `scripts/test-catalog-content-release.sh`,
  and three-lane audit with 0 critical/high/medium findings.
- #1807 is the rollout gate: "Measure model demand and stage the 8GB/16GB
  fleet catalog migration."
