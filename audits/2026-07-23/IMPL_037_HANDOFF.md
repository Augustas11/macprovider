# SPEC-037 IMPL — session handoff (2026-07-23, paused before travel)

## State: PARKED at a clean, verified point. Nothing risky merged. Tier is default-off.

- **SPEC-037 v0.1.0** — MERGED to `origin/main` (PR #702), 7-round five-lane audited, LOCK-ready. Done.
- **IMPL** — branch `impl/233-kv-survival` **pushed to origin** (56 commits ahead of main, rebased on latest main). Build green (debug + `-c release`). 239 KV/serve tests, 0 failures, 3 pre-existing env-gated skips (MLX-Metal / Data-Protection-keychain).
- The tier is **default-off** and **synthetic-key-only** (`allow_buyer_keys=true` rejected); nothing is live.

## What the IMPL contains
Encrypted per-provider KV disk tier behind `ConversationCache` (residency-only — no wire/receipt/billing/`cached_prompt_tokens` change, FR-KVP1 verified). Format v1 (JCS-canonical manifest as non-circular AEAD AD, framed AES-256-GCM, `KVCacheSimple`-only allowlist); per-entry Data-Protection-Keychain DEK as the rollback-proof revocation authority; durable fail-closed admission derived from on-disk incomplete-tombstones + rotation journals; serialized owned purge fences (FIFO gate); snapshot-at-commit → promotion into the existing LCP/trim predicate; control-socket + `macprovider-cli kv-cache purge/status`; FR-KVP11 config (YAML/env/CLI, fail-closed); KVS-01a four-arm harness.

## IMPL audit history (five lanes/round: 3 codex + adversarial verificator + product critic)
- R1 2C/14H → R2 1C/8H → R3 2C/4H (recurring purge-fence CRITICALs) → **root-cause concurrency+durability redesign** (durable admission, serialized owned fences, true aggregate budgets, off-actor promotion) → R4 found 2 more (off-actor-promotion TOCTOU rated CRITICAL by architect / MEDIUM by adversarial realist-check — bounded, non-persistent, same-tenant; + purge-all rotation-journal ordering) + 2H + 3M + 1L.
- **R4 fix round: DONE** (commits `be55cd45`, `476257c5`, `0ef70d94`, `27c0ae47`, `ee170f60`, `45c08cca`). All 8 findings fixed + regression-tested, including the mandatory decode-window failpoints (`testPromotionDecodeRaceSingleKeyPurgeYieldsMiss`, `...PurgeAllYieldsMiss`) that make the TOCTOU testable — the missing hook that let it survive four rounds. **Class sweep confirmed**: writes are synchronous-on-actor (no TOCTOU); every await in purge/purgeAll/rotation/read is now durable-before or recheck-after.

## RESUME STEPS (in order)
1. **IMPL R5 verification** — five lanes against the R4-fixed tree. Reuse the R4 prompts pattern (`audits/2026-07-23/AUDIT_IMPL_037_R4_*_PROMPT.md`), bump to R5, add an "R5 certification: verify the 8 R4 fixes closed + class-sweep held; the durable-fence model is confirmed sound by R4 adversarial — look only for a NEW suspension window or a regression from the fixes." Bar: 0 C/H/M.
2. **If R5 certifies clean (or LOW/INFO only):**
   - Open IMPL PR: base `origin/main`, `--head impl/233-kv-survival`, body = `scratchpad/impl037-pr-body.md` (READY — includes governance declaration: behavior_change=yes, contract_change=none, SPEC-037 + R001–R013, domain `kv-cache-persistence`). Author as Augustas11 (`gh pr create` — pushes route to Augustas11 automatically).
   - Approve as antfleet-ops: `GH_TOKEN=$(gh auth token -u antfleet-ops) gh pr review <PR#> --approve`.
   - Merge behind green CI: `GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge <PR#> --squash --admin` (admin flag needed — ruleset requires the aggregation context; used for #702).
   - Post-merge: `git checkout main && git fetch origin && git reset --hard origin/main && git branch -D impl/233-kv-survival` (in the canonical checkout, not the worktree).
3. **Decision-log Entry 190** — merges LAST, own PR, after IMPL merges (reflects shipped state). Row text READY in `scratchpad/impl037-decision-entry.md`; append to `beta/DECISION_CRITERIA.md` (currently ends at Entry 189). It's a governance-only path (behavior_change=none allowed) — but `beta/DECISION_CRITERIA.md` is on the governance-only allowlist, so a simple honest declaration works.
4. **Close-out**: remove the `../macprovider-233` worktree (`git worktree remove`), delete the local branch, brief the user with links + the KVS-01a residual.
5. **If R5 is NOT clean**: same bounded-fix → re-verify discipline. If a THIRD-consecutive CRITICAL appears in the same purge/promotion suspension area, seriously consider reverting the off-actor promotion decode to on-actor (accept FR-KVP9 "immediate disk_miss_busy" as a documented deviation) — it collapses the entire TOCTOU class at the cost of a latency-nicety. R4's class-sweep suggests the current model is now sound, so this is a fallback, not the expectation.

## Carried residual (document at merge, blocking-before-ENABLE not before-merge)
KVS-01a **evidence** requires a controllable >32 GB lab Mac (standing P0 #584) and has never run. Per FR-KVP13 the tier MUST NOT graduate past synthetic-key experiments until KVS-01b passes there. The machinery lands; the tier stays default-off. Also: first-post-restart-turn promotion needs one in-process commit before the geometry template exists (load-time-geometry capture is a documented follow-up; model-hash fencing means a stale template can only miss, never promote wrong).

## Prepared artifacts (in scratchpad — copy into the PRs)
- `scratchpad/impl037-pr-body.md` — IMPL PR body + governance declaration.
- `scratchpad/impl037-decision-entry.md` — Entry 190 decision-log row.
- Audit prompts + codex logs: `audits/2026-07-23/AUDIT_IMPL_037_R{1..4}_*` and the `.omc/artifacts/ask/` logs.
