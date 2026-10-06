# Native MTP production enablement: Phase A plan (#1770)

Status: research and plan only. Nothing here is implemented, signed or enabled.
Branch `mtp/enablement`, based on `origin/mtp/step-overhead` at `93a0fee7d`
(SPEC-048 0.1.25). Line numbers are at that commit unless stated otherwise.
Starting evidence: the R014 rehearsal on signed v1.8.217, branch
`journey/native-mtp-r014` at `02b06d37f`,
`docs/research/spec048-r014/evidence-2026-10-06-v1.8.217-26a434/`.

Tuple: `qwen/qwen3.6-35b-a3b`, `mlx-community/Qwen3.6-35B-A3B-4bit`, artifact
`3fed776d…`, MLX affine 4-bit, Mac Studio M3 Ultra 256 GB, macOS 26A434,
depth 1, `qualified_slots` 8, `max_native_active_rows` 1, `max_prompt_tokens`
4096 (R015 policy in
`docs/research/spec048-r015/evidence-2026-10-06-a3b-amended-gates-quiet-26a434/`).

## 0. Goal and decisions

**Goal (operator decision, 2026-10-06): native MTP live in production for the
qualified tuple.** Phase B runs on this branch in the dependency order of
section 3, one commit per gap, with tests.

Two facts shape the work beyond the R014 rehearsal list:

1. **G7 is required work: production paid traffic is almost entirely
   ineligible today.** The gateway attaches an auto-prefix conversation key
   to every authenticated, non-demo chat request that has a user message
   (`phase5-gateway/internal/router/chat_proxy.go:3549-3573`). The
   coordinator forwards it to the provider as `conversation_key`
   (`phase4-coordinator/internal/buyer/server.go:3828-3832`), and SPEC-048
   R004/R009 route the request ordinary (`NativeMTP.swift:263-264`,
   `SPEC-048:481-487`). R015 requires at least 10% of post-gateway requests
   and completion tokens to be eligible (`SPEC-048:1166-1177`). Without the
   G7 amendment and code, enabling the tuple serves almost no paid traffic.
2. **Continuous batching for the tuple is an input dependency (D-CB), not
   campaign work.** Native rows run only inside the CB scheduler
   (`ModelRuntime.swift:6150-6165`, `NativeMTP.swift:377-395`). The live
   Studio reports `continuous_batching.active=false` with
   `unsupported_reason: tuple_acceptance_coverage_unavailable` and policy
   `decision_reason: tuple_identity_mismatch` (read-only
   `GET 127.0.0.1:8080/v1/status`, 2026-10-06). Per the operator this is a
   catalog-signing bug (the catalog mis-signed the CB tuple for this model),
   fixed separately. This campaign does not edit the catalog CB tuple; it
   consumes the corrected signed CB policy entry. See D-CB below.

### D-CB: corrected CB policy entry (input dependency)

- **Who/what (2026-10-06 12:46Z).** No open PR or issue names it
  (`gh pr list` / `gh issue list` for continuous-batching, catalog,
  tuple_acceptance: only merged #1803, #1808, #1838, #1672). No remote branch
  has touched `phase3-binary/catalog/autotune/continuous-batching-policy*` or
  `scripts/catalog-release.py` since 2026-10-05. The only candidate is the
  local session worktree
  `/Users/augstar/macprovider-poc/.claude/worktrees/agent-a16d9bba3f1ea0e43`
  on branch `ops/cb-activation-gates`, created 2026-10-06 12:44Z, no commits
  yet. ListAgents is not available in this session, so the owner is
  inferred, not confirmed.
- **What the campaign needs from it.** A signed CB policy entry for
  `qwen/qwen3.6-35b-a3b` whose tuple matches the provider's runtime tuple,
  bound (`ContinuousBatchingSignedPolicy.swift:102-109`) to the CLI version
  and `live_executable_cdhash` of **the campaign's CLI cut**. A fix that
  binds only the current 1.8.217 CDHash does not carry over; the entry must
  be re-issued for the cut, in the same catalog release that carries the
  sidecar (section 4).
- **What the campaign does meanwhile.** Every native path is exercised on
  isolated lab builds where CB is authorized locally (as R014 and R015 did).
  The post-cut confirmation (L5/L6) waits on D-CB.

The payoff R015 measured (quiet, 2026-10-06) is decode 1.19–1.28x and end to
end 1.04–1.20x at one active row, 1.00 at two or more rows, Studio tuple only.
Effort is in section 8.

## 1. Verified baseline

| Fact | Source |
|---|---|
| The sidecar and revocation signer is **v4**, not v5. `keyID = bakedCatalogSignerKeyID ?? v5`, and the baked value is `streamvc-autotune-static-v4`. A v5-signed sidecar fails `unexpected_key_id`. | `AutotuneRecommend.swift:1821`, `AutotuneCatalog.generated.swift:22`, `NativeMTPAdmissionSidecar.swift:1205` |
| Live catalog release is `published-2026-10-01-artifact-feed-activation-v1`, signed v4. qwen3.6 4-bit is `verified`. | live status, `phase3-binary/catalog/autotune/release.json` |
| Live Pearl is v1.8.218. It already contains the native-MTP canary code (#1774, since v1.8.207). | `/healthz`, `git ls-tree v1.8.218 phase4-coordinator/internal/ws/` |
| Native accounting is CLI-only. Coordinator and gateway have no `native_mtp`, `decode_path` or `speculative` keys in billing, requestlog, payout or rewards. | grep; SPEC-048 R011 `:824-842` |
| The weekly renewal (`renew-autotune-static-feed-signed.yml`, Wed 16:00 UTC) mints a new `release_id` every run. It already holds the v4 key and a Pearl deploy key in the `autotune-feed-renewal` environment. | `scripts/renew-autotune-static-feed.sh:57-58,137`; workflow `:33,:91-92` |
| Revocation bodies expire at most 1 h after issue. On first install the provider requires `issued_at` to be at most 15 min old. It polls every 15 min. | SPEC-023 `:3371-3429`; `NativeMTPRevocationFeed.swift:219,572` |
| The 1.8.219 #1690 candidate (unreleased bytes) runs live-joined on the M1 pool. | R014 `live-binaries.json` |

## 2. Gap register

"Surface" uses these labels: CLI, COORD (coordinator code), CAT (catalog
artifact), SIGN (signing/workflow), PEARL (Pearl config) and SPEC.

### G1. Mixed-row prefill parity (R014.3 mixed-row FAIL)

- **Requirement.** SPEC-048-R007 `:691-706` requires the mixed fixture to
  match the ordinary batched oracle. R005 `:543-546` adds the multi-row
  oracle. SPEC-038 FR-CB2 `:490-492` requires compatible rows to share one
  prefill forward.
- **Code.** `PagedKVRuntimeBridge.swift:849`. In `canSharePrefillForward`,
  `guard inputs.allSatisfy({ !$0.nativeMTPPromptPrefill })`. The scheduler
  groups rows by offset and chunk only (`ContinuousBatchScheduler.swift:4487-4511`).
- **Root cause.** Only a native row needs the target's prompt hidden states
  to seed the drafter (MTP-6 `:574-583`). The shared path runs with
  `state: nil` and rejects any returned state (`:700-702`). So one native row
  sends its whole equal-length group, ordinary peers included, to serial
  `[1, L]` prefill. Serial prefill is not bit-equal to the `[B, L]` forward
  the MTP-disabled oracle runs (`PagedKVRuntimeParityProbe.swift:89-98`), and
  argmax drifts 40–100 tokens later.
- **Confirmation.** The R014 diag runs show that equal-length prompts fail
  (`diag/journey-diag-1.json`, `-s4.json`). The same fixture with
  unequal-length prompts, where the oracle is serial too, passes 8/8
  (`diag/journey-diag-unequal.json`).
- **Change.** All rows share one forward:
  1. Delete `:849`.
  2. When any row is native, pass an `LMOutput.State` with `mtpEmitFlagKey`,
     the same pattern decode capture uses at `:1553-1590`.
  3. Accept an emit-only state, validated as `[B, ≥L, H]`.
  4. After `syncRowsFromBatch`, seed each native row's drafter from a
     detached `[1, L, H]` slice.
  5. Refactor `prepareNativeMTPDrafterState` (`:1765`) and
     `advanceNativeMTPDrafterOverPromptChunk` (`:1814`) to take the hidden
     array.

  A drafter failure stays request-local. The emitted tokens cannot change,
  because the target decides every token (R005). Batched rather than serial
  hidden states can only move the acceptance rate.

  The alternative, keeping native rows out of ordinary groups, does not fix
  it: the native row still runs serial, and the ordinary group's batch size
  differs from the oracle's.
- **Tests.**
  - Bridge: a `[native, ordinary, ordinary]` group with equal L does one
    forward of B=3, and every row's tokens and KV equal the same group with
    native off.
  - Scheduler: native-enabled versus MTP-disabled equal-length batch, mirroring
    journey steps 07/08.
  - `PagedKVRuntimeBridgeTests.swift:1367` currently hides the bug because
    both rows go serial. Tighten it.
- **Surface.** CLI. No SPEC text change.

### G2. No production sidecar can be generated (R014.1 sidecar FAIL)

- **Requirement.** SPEC-048-R013 `:884-907` and SPEC-023-R024 §12.5
  `:3162-3448`.
- **Code.**
  - `scripts/native_mtp_admission_sidecar.py` requires five non-zero evidence
    digests (`:51`, `:228-231`).
  - The only committed tuple input,
    `docs/research/spec048-r015/evidence-2026-10-02-a3b-formal/admission-tuple-input.json`,
    has all-zero `correctness`, `quality`, `state_rollback`, `batch` and
    `security_negative` digests. It binds the superseded runtime `ef4ff856…`
    and policy `30934c07…`.
  - No `release-input` file exists anywhere.
- **Root cause.** The evidence the digests point to does not exist yet (G10,
  G11). The release-bound fields (`source_commit`,
  `reproducible_build_sha256`, `live_executable_cdhash`, `release_id`) can
  only be known after the final signed CLI exists. The checks are
  `ModelRuntime.swift:9130-9140` and `NativeMTPAdmissionSidecar.swift:709-716,
  1333-1366`.
- **Change.**
  1. Build a new tuple input from the freeze-commit evidence: the pin
     `ca8c384c…` (once its R003 closes) and the new R015 policy digest.
  2. Add a `release-input` builder that reads the signed RC's compat-set id,
     binary SHA-256 and CDHash (`codesign -d -vvv` / `SecCodeCopySigningInformation`
     on the published asset).
  3. Signer is v4, so update the prompt's "v5" assumption.
  4. `challenge_bank_signer_key_id` and `revocation_signer_key_id` are v4 as
     well. They must be in the keyring, and adding a dedicated key would
     need a bridge CLI.
- **Surface.** CAT, SIGN. SPEC-048 §7 and the evidence text only.

### G3. No sidecar delivery path (R014.1, R014.8)

- **Requirement.** SPEC-023 `:3352-3361`, Stage A: the sidecar is "generated,
  signed, served as an external release asset, and ledger-bound" and is never
  a `components.catalog.files` or provider-payload member. SPEC-023
  `:3342-3350` defines ledger v4 with a six-feed set plus
  `native_mtp_admission_sha256`.
- **Code.**
  - `catalog-release.py` stops at the ledger v3 artifact-bound feed set
    (`:90-96`). It has no native-mtp stage.
  - `resign-autotune-static.sh:169-178` does not sign it.
  - The coordinator has no route (`buyer/server.go:926-936`).
  - The CLI only reads `native-mtp-admission.json`, `.sig`,
    `native-mtp-artifact-manifest.json` and `native-mtp-selftest-bank.json`
    + `.sig` from the snapshots directory (`ModelRuntime.swift:8728-8736`,
    `NativeMTPAdmissionSidecar.swift:504-506,1614-1627,1742-1777`,
    `MacProviderCLI.swift:1168-1173`).
  - Nothing writes them: not the installer, the downloader
    (`AutotuneRecommend.swift:4085`), autotune `--apply` or the updater.
- **Root cause.** Stage A was specified but never implemented on either side.
- **Change.**
  - **Catalog.** `catalog-release.py` gains ledger v4 and four signed feed
    members: `native-mtp-admission.json`, `native-mtp-artifact-manifest.json`,
    `native-mtp-selftest-bank.json` and their `.sig` files. They are bound in
    `release.json.feeds` with signer equality, and `verify-directory` checks
    them. `resign-autotune-static.sh` signs them.
  - **Coordinator.** Static-feed routes `/v1/native-mtp-admission(.sig)`,
    `/v1/native-mtp-artifact-manifest` and `/v1/native-mtp-selftest-bank(.sig)`.
    Each is served from `autotune.native_mtp_*_path`, with the same
    release-binding checks as `continuous_batching_policy_feed.go`, and
    returns 404 until configured. Add nginx `location =` blocks.
  - **CLI.** With `native_mtp_mode=auto`, fetch those feeds from the joined
    coordinator origin and verify signer and release binding before writing
    anything. Materialize them atomically, at `0600` in a provider-private
    `0700` directory under Application Support, keyed by `release_id`. Point
    the loader at that directory instead of the snapshots directory. The
    existing `native_mtp_admission_sidecar_path` and
    `native_mtp_admission_signature_path` overrides already decouple the
    location. On any failure, stay ordinary.
- **Surface.** CLI, COORD, CAT, SIGN, PEARL (nginx + `coordinator.yaml`
  paths). SPEC-023 text: name the feed routes and the provider-local
  materialization path for Stage A. Stage B (payload member) stays out.

### G4. Sidecar churn: weekly `release_id` and per-cut CDHash

- **Root cause.** The sidecar binds `release_id`, which must equal the
  provider's live catalog release (`MacProviderCLI.swift:1135-1181`,
  `NativeMTPAdmissionSidecar.swift:1345`). It also binds one CLI CDHash. The
  weekly renewal mints a new `release_id`, so an unchanged sidecar stops
  admitting after one week. Each CLI cut needs a new entry.
- **Change.** `renew-autotune-static-feed.sh` regenerates the sidecar from
  the committed tuple input and release input, with the new `release_id`,
  and signs it with the same v4 secret the workflow already holds. Entries
  for 1..256 tuples, one per admitted CLI CDHash, carry forward until the CLI
  leaves the compatibility set. The sidecar also expires after at most 90
  days (SPEC-023 `:3169-3178`), so the weekly re-sign covers that too.
- **Surface.** SIGN, CAT. No SPEC change.

### G5. No revocation feed (R014.1 revocation FAIL)

- **Requirement.** SPEC-023 `:3371-3429` and SPEC-048-R014 item 1.
- **Code.**
  - The origin is hard-coded to `https://coordinator.malibu.tech/v1/`
    (`NativeMTPRevocationFeed.swift:218`) with no override.
  - A 404 is treated as a transport failure, then `missingFeed`, then
    `revocation_state_unavailable` (`ModelRuntime.swift:8746-8765`).
  - No coordinator or nginx route exists, no signer exists, and nothing
    renews the feed.
- **Root cause.** The serving and renewal side was never built. The 1 h
  expiry plus the rule that keys never sit on Pearl (SPEC-023 `:1566-1576`)
  means a key-holding signer cannot run on Pearl, and an hourly GitHub cron is
  too jittery for a 1 h expiry.
- **Change: pre-signed slots.**
  1. The weekly renewal job signs a 14-day batch of revocation bodies, one
     per 10-minute slot. Each has a strictly increasing `generation`,
     `issued_at` equal to its slot start, `expires_at` one hour later, and the
     current revoked set.
  2. The coordinator route `/v1/native-mtp-revocations.<key>.json(.sig)`
     serves the newest body whose `issued_at <= now` from
     `native_mtp.revocations_dir`, a directory of immutable pairs. This holds
     no key and does no signing.
  3. 10-minute slots keep the age under the 15-minute first-install bound
     (`:572`).
  4. **Emergency revocation:** the operator signs a replacement batch locally
     that includes the tuple. Higher generations and a superset revoked set
     satisfy the monotonic checks. The operator rsyncs it over the directory.
     A missed renewal makes the feed expire, which disables native and keeps
     ordinary decode (fail closed in the safe direction).
  5. **CLI:** derive the feed origin from the joined coordinator origin, not
     a constant. That lets a signed release binary run against an isolated
     coordinator in rehearsal (section 5). The pinned key, the closed schema
     and the Keychain generation anchor still apply.
- **Surface.** CLI, COORD, SIGN, PEARL (nginx + directory). SPEC-023 text:
  the origin is the joined coordinator origin; publication uses a pre-signed
  slot batch; state the emergency procedure.

### G6. CB qualification for the tuple (R014.5 FAIL): input dependency D-CB

- **Requirement.** SPEC-048-R014 item 5 `:937-938`; SPEC-038 FR-CB15
  `:920-952`, FR-CB18 `:1168-1169`; SPEC-039 FR-PKV13 `:725-770`.
- **State.** The live tuple reports `tuple_acceptance_coverage_unavailable`
  / `tuple_identity_mismatch`. Per the operator, the root cause is the
  catalog mis-signing the CB tuple for this model, fixed outside this
  campaign (D-CB, section 0). An entry binds the CLI version and
  `live_executable_cdhash` (`ContinuousBatchingSignedPolicy.swift:102-109,
  346-372`), so the corrected entry must be re-issued for the campaign's CLI
  cut.
- **Campaign work.** None on the catalog CB tuple. The campaign records, in
  the SERVING journey, the FR-CB15/FR-PKV13 evidence the corrected entry
  cites for this tuple, and the R014 runner checks that the release's signed
  policy contains an entry matching the cut. The same catalog release that
  carries the sidecar carries the re-issued entry.
- **Surface.** Consumed CAT input.

### G7. Production eligibility (required work; not in the rehearsal)

- **Requirement.** SPEC-048-R004 `:432-501`, R009 `:755-769`, R015
  `:1166-1177`. SPEC-006-R012/R014 (gateway auto-prefix) and SPEC-024
  (cache billing).
- **Root cause.** Two policies collide. The gateway gives every
  authenticated paid chat request a cache-only auto-prefix key. Native MTP
  refuses any request with a conversation key because MTP state and cache
  reuse are not proven together.
- **Change (single design, needs a SPEC decision).** Admit cache-only keys on
  a cache miss.
  - The coordinator marks cache-only keys on the provider hop. This is a new
    SPEC-001 wire field; today the provider cannot tell
    `Internal-Conv-Cache` from a sticky key.
  - SPEC-048-R009 and SPEC-024 are amended. A native-eligible request with a
    cache-only key and no resident cache entry selects native, acquires no
    lease, and commits no entry. Usage is unchanged because a miss carries no
    discount.
  - Cost: that prefix loses future cache reuse while native serves it. A
    sticky key or a cache hit stays ordinary.
- **Surface.** COORD, CLI, SPEC (SPEC-001, -024, -048).
- **Measurement.** Probe P1 sizes the share before and after the change; the
  R015 post-gateway replay is the gate.

### G8. Native billing/accounting not exercised end to end (R014.3 accounting FAIL)

- **Root cause.** This is downstream of G3 and G5: no released provider could
  admit the tuple. There is no code gap, because accounting is CLI-only and
  invariant by construction (R011).
- **Change.** Journey step 11 on the isolated coordinator plus gateway.
  Compare `ledger_request_credits`, `request_log`, `usage_events` and the
  receipt for native rows against ordinary replays of the same requests, and
  check the null-usage form for a forced post-output failure. Add a harness
  only.
- **Surface.** Harness and evidence.

### G9. Coordinator R033 canary not configured (R014.8 config-enable FAIL)

- **Code.** `pool.native_mtp_canary` (`config.go:887-909`) is default off and
  absent from `dist/coordinator.yaml`. The bank must be the same
  `native-mtp-selftest-bank.json` the sidecar binds by
  `challenge_bank_sha256`.
- **Root cause.** The provider never offered a tuple (G3, G5). The bank has
  never been produced as a signed release member.
- **Change.** Produce the bank from the G3 catalog stage. Add a
  `coordinator.yaml` block pointing at `/opt/macprovider/autotune/current/native-mtp-selftest-bank.json(.sig)`
  with signer v4. This is in-place edit only, applied in the catalog
  activation restart.
- **Surface.** PEARL config. No code.

### G10. No signed serving or release journey (R014.6 FAIL, R014 item 8)

- **Code.**
  - Contracts exist: `journeys/JOURNEY-NATIVE-MTP-SERVING.md` (15 steps,
    schema `macprovider.native-mtp-serving-evidence.v1`) and
    `JOURNEY-NATIVE-MTP-RELEASE.md` (7 steps).
  - No `scripts/build-native-mtp-*-journey-result.py` exists, and no
    `promote-signed-native-mtp-*` workflow.
  - The lab commands are `#if DEBUG || MACPROVIDER_LAB_HARNESS`
    (`NativeMTPJourneyE2ECommand.swift:9`, `MacProviderCLI.swift:57-64`) and
    must stay out of release builds (`scripts/tests/test_native_mtp_lab_flag_guard.py`).
- **Root cause.** The journey tooling was never written. Steps 01–03, 10, 11,
  the coordinator half of 12, 14 and 15 are pending in the harness. Steps
  that need lab hooks (05 forced rejection, 07/08 hold recorder) cannot run
  on a release binary.
- **Change.**
  1. Follow the privacy-class-beta precedent (#1864): signed RC for every
     buyer-path step; a lab build of the same commit, isolated and no-join,
     only for hook-dependent steps. Bind both binaries in the manifest.
  2. Build the result builders and promote workflows (manual dispatch on
     `main`, `production-release` environment), copying
     `promote-signed-privacy-class-beta-journey.yml`.
  3. Implement the pending harness steps: tuple bind, negatives, warm swap,
     accounting (G8), coordinator canary, benchmark import (G11), redaction
     review.
  4. Extend the R014 runner (`scripts/native_mtp_r014_*.py` from
     `journey/native-mtp-r014`) to read the signed results.
- **Surface.** SIGN, harness. No SPEC change.

### G11. R015 must be re-frozen on the campaign binary, plus the post-gateway replay

- **Root cause.** The 2026-10-06 quiet PASS (policy `e24cb7bc…`) binds the
  step-overhead build `e1103712d`. G1 changes the prefill path, so the bound
  provider revision changes and the R015 qualified tuple changes. The
  post-gateway eligibility replay (`:1166-1177`) and the multi-row mixed-load
  ordinary-regression bounds have never run. The candidate pin `ca8c384c…`
  still needs its R003 review closed (`SPEC-048:413-419`).
- **Change.**
  1. Close the `ca8c384c` R003 gate.
  2. Freeze a new R015 policy on the campaign freeze commit and run it in a
     quiet window.
  3. Run the privacy-reviewed post-gateway replay (needs P1's sample).
  4. After the cut, run the renewal-subset on the signed RC: self-test, 30
     min sustained, parity sample and post-gateway sample (`:962-971`).
     Probe P6 decides whether the full matrix must repeat.
- **Surface.** Evidence only. No SPEC change, unless P6 shows the squash
  commit forces a full rerun. In that case, amend R015 to accept "same Swift
  tree hash" reuse.

### G12. Conformance and spec bookkeeping (R014.1 conformance FAIL)

- **Root cause.** 21 requirements are `pending`. Several gap texts are stale:
  SPEC-031-R033 "not implemented", R016 "no canary adapter", and empty
  impl/test lists for R008, R009 and R011. SPEC-048 §6 still lists
  `DECISION_REQUIRED` rows:
  - packed-verify drift at ≥12 tokens: moot at bound 1 and depth 1, where
    packed verify is 2 tokens;
  - depth-1 throughput: answered by the R015 PASS.
- **Change.** Promote each requirement with evidence pointers, but only from
  the signed SERVING result (R014 stays pending until RELEASE). Close the two
  §6 rows with recorded decisions. SPEC-048 status updates.
- **Surface.** SPEC, `CONFORMANCE.json`.

### G13. Release-process items from R014.8 and R014.9

- **Updater path.** v1.8.207 did not see v1.8.217 because the signed
  discovery transport had not yet been published. The cut's post-publication
  rollout must publish the transport before the RELEASE journey runs step 05.
  This is process only.
- **Live unreleased bytes.** The 1.8.219 #1690 candidate runs live-joined on
  the M1 pool. R014 item 9 is fleet-wide. At enablement time every
  live-joined process must run published bytes; #1690 owns that. Record it
  as an activation precondition, not campaign work.

## 3. Dependency order

```text
G7 SPEC amendments + code ────────────────────────────────────────────┐
D-CB corrected CB entry (external) ─────────────────── consumed at catalog release
                                                                       v
ca8c384c R003 close ─> G1 parity fix ─> G3/G5 CLI fetch + origin ─> campaign freeze commit
                       G3/G5 coordinator routes ──────────────────────┘      │
                       G3/G4/G5 catalog-release + renewal + presign ──┘      │
                       G10 journey builders/workflows/harness steps ─┘       │
                                                                             v
         lab: G1 tests, R015 re-freeze (quiet), journey lab steps, G8 isolated accounting
                                                                             │
     off-train signed candidate (acceptance-candidate.yml) ─> full isolated rehearsal (section 5)
                                                                             │
                       three-lane freeze audit (0/0/0) ─> merge campaign PR
                                                                             │
   CLI cut ─> RC CDHash ─> G2 release-input + D-CB entry re-issued for the cut      
                                                                             │
   Pearl runtime apply (routes) ─> catalog release activation (+ nginx, yaml, revocation dir)
                                                                             │
   SERVING journey signed ─> CONFORMANCE promotion ─> operator: live Studio native_mtp_mode=auto
                                                                             │
                                               RELEASE journey signed ─> R014 conformant
```

The CB policy entry and the sidecar both bind the final CDHash, so the catalog
release must follow the CLI cut. Every other step can be rehearsed before
merge (section 5).

## 4. Post-merge shape: one of each

| Step | Forced by | Contents | Downtime |
|---|---|---|---|
| **One CLI cut** | G1 (prefill), G3 (feed fetch and materialize), G5 (origin derivation), any harness-free journey hooks | Signed candidate, release train row, transport publish (G13) | Provider restart per node on update. The live Studio swap is an operator-approved restart of `live.malibu.provider`. |
| **One Pearl runtime apply** | G3 and G5 coordinator feed routes (`/v1/native-mtp-admission*`, `/v1/native-mtp-revocations.*`), plus G7's wire field only if that amendment lands | Tag of merged `main`, signed updater | **15–20 min network down** per `pearl-coordinator-rollout.md:11-15`, unless the short-quiesce updater hotfix is installed (probe P3). Must be stated to the operator before starting. One Pearl actor at a time. |
| **One catalog release** | G2/G3/G4 sidecar, artifact manifest and self-test bank; G6 CB policy entry; ledger v4 | `deploy-pearl-vps.sh` from the running tag, after: nginx locations for the new feeds, in-place `coordinator.yaml` keys (`native_mtp_*_path`, `native_mtp.revocations_dir`, `pool.native_mtp_canary`), revocation slot batch rsynced | **Seconds** (one coordinator restart), plus the canary kickstart procedure (`:153-172`). Use the chained restore (`:141-147`). |

Ordering constraint: the runtime apply must land before the catalog release
binds feeds the old runtime cannot serve. Do them back to back, runtime first.
The weekly renewal (G4) must already carry the sidecar stage on `main` before
the first renewal after activation. Otherwise native silently disables a week
later.

## 5. Pre-merge rehearsal of every post-merge step

The aim is that post-merge steps only confirm.

Rehearsal signing uses a **test key only** (operator rule); the production
v4 key is never used before the cut. A release-built binary trusts only its
baked keyring (`AutotuneCatalog.generated.swift:17-22`), and keyring/build
identity injection exists only under `#if DEBUG || MACPROVIDER_LAB_HARNESS`
(`ModelRuntime.swift:2532-2536`). So the rehearsal splits in two:

- **Positive path on a lab build.** A `-DMACPROVIDER_LAB_HARNESS` build of
  the campaign commit, with a lab-only serve hook that injects the test-key
  keyring and a test build identity, runs the whole chain against the
  isolated coordinator: feed fetch and materialization, revocation from the
  joined origin, admission, tuple offer, canary, billing, config
  enable/disable, and an emergency revocation mid-run. Every artifact
  (catalog, sidecar, manifest, self-test bank, CB policy, revocation slots)
  is generated by the production tooling with `--signer-key-id` set to a
  test key id and signed by a throwaway Ed25519 key created in the
  scratchpad and deleted after the run.
- **Identity and fail-closed path on a signed package.** An off-train signed
  package from `acceptance-candidate.yml` (allowed by
  `lab-campaign-loop.md:77-80`; never promoted, never on :8080) proves that
  `nativeMTPRunningBuildIdentity` resolves the real CDHash, binary SHA-256 and
  compat-set commit, that the CLI fetches and materializes the feeds from the
  isolated coordinator, and that it rejects the test-key-signed sidecar and
  revocation feed (`unexpected_key_id`) while ordinary decode keeps serving.
- **Catalog release.** `catalog-release.py generate` into a scratch
  directory under a rehearsal `release_id`, then `verify-directory` with the
  test key in a scratch trusted-keys file. Never published.
- **Pearl runtime apply.** The isolated coordinator and gateway built from the
  campaign branch on Studio loopback (193xx ports, SQLite, settlement
  observe), as in R014 `raw/isolated-coordinator-*.log`.
  - The rehearsal catalog is served at `autotune.*_path`.
  - The revocation slot directory is presigned for the rehearsal window.
  - Because of G5 origin derivation, the off-train binary fetches revocation
    from the isolated coordinator.
- **Catalog activation.** Run the deploy-script preflight
  (`catalog-content-release.sh --preflight`, `verify-directory`) against the
  rehearsal directory. Also do a `deploy-pearl-vps.sh` dry run against a copy
  of the live `coordinator.yaml` to check the key layout. No Pearl contact.
- **Renewal.** Run `renew-autotune-static-feed.sh` without `--deploy` and
  check the regenerated sidecar's `release_id` and tuple sha.
- **Enablement and journeys.** Run the full R014 runner against the off-train
  package and isolated stack. It must show every pre-release item PASS:
  - native admitted;
  - tuple offered;
  - canary pass;
  - native rows billed identically;
  - config enable and disable;
  - an emergency revocation pushed mid-run disabling only the tuple.

  The SERVING result is built and validated. It is signed only post-merge,
  because the promote workflow runs on `main`.

What cannot be rehearsed pre-merge, and is first exercised after the cut: the
production v4 signature on the sidecar, revocation slots and self-test bank
as accepted by a release binary; the final CDHash binding; the D-CB entry for
that CDHash; the live Pearl downtime; and the canary kickstart. Each is the
same code path the lab build exercised with the test key.

## 6. Studio lab time

All lab work runs under the lab lock (`mkdir ~/.lab-window.lock`) on isolated
193xx ports, `--no-join`, using clones of the model store. Rows marked "pause"
need the live provider quiet, so the operator must approve pausing :8080
first; nothing here pauses it without that approval.

| Window | Content | Duration | Live :8080 |
|---|---|---|---|
| L1 | G1 parity fix iterations, bridge and scheduler tests on hardware, journey 07/08 | ~0.5 day | untouched |
| L2 | `ca8c384c` R003 gate (upstream GDN/MTP tests, fused harness, hardware E2E) | ~0.5 day | untouched |
| L3 | R015 re-freeze: 6 cells × 10 blocks + 1800 s sustained, quiet | ~6–8 h | **pause** |
| L4 | Full isolated rehearsal on the off-train package: R014 runner, SERVING lab steps, G8 accounting, revocation drill | ~0.5 day | untouched |
| L5 | Post-cut: signed RC with the D-CB entry and v4-signed sidecar on isolated loopback; SERVING journey buyer-path steps | ~4 h | untouched |
| L6 | Post-cut RELEASE journey: RC isolated revalidation, renewal subset with 30-min sustained | ~3–4 h | **pause** for the sustained 30 min |
| L7 | Enablement: install the cut on live and set `native_mtp_mode=auto` | ~0.5 h | operator-approved restart |

Total: about 3–4 lab days, including 2 operator-approved pause windows of
roughly 6–8 h (L3) and 1 h (L6).

## 7. Risks and unknowns, each with the probe that resolves it

| ID | Unknown | Probe |
|---|---|---|
| P1 | Real eligible share of post-gateway Studio-tuple traffic (G7). This decides worth. | Read-only Pearl query over 7 days of `request_log` for `qwen/qwen3.6-35b-a3b`, plus gateway `demand_events`. Count conversation-key presence (sticky vs cache-only), sampling params, tools, response format and n. Use the `VACUUM INTO` off-host pattern so live is not touched. Needs operator OK for Pearl read access in a later phase. |
| P2 | Fraction of Studio busy time at exactly one active row, where the 1.2x applies. | Same export: overlap of request intervals per provider gives a concurrency histogram. If time at 1 row is under ~30%, buyer-visible gain is under ~6%. |
| P3 | Whether Pearl has the short-quiesce updater hotfix, which sets the runtime-apply outage. | `ssh pearl '/usr/local/sbin/macprovider-pearl-update --version'`, then compare with `ops/runbooks/pearl-release-updater.md`. |
| P4 | Whether pre-signed 10-minute revocation slots pass every client check (first-install age, generation, superset, expiry, rollback after an emergency batch). | Unit tests in `NativeMTPRevocationFeedTests` with a synthetic slot batch, plus a Studio isolated drill (L4). |
| P5 | Whether the batched prefill forward returns usable per-row hidden states for B>1, and whether `mtpPositionDeltasKey` is ever non-nil for Qwen35. | Bridge test on Studio with the pinned fork (`Qwen35.swift:644-664`). Fall back to serial for the group only if deltas are present. |
| P6 | Whether R015 evidence measured on the freeze commit still binds after the squash merge and cut (provider revision binding). | Read `native_mtp_r015_analyze.py` and the policy fields that bind provider revision. Compare the Swift tree hash of freeze and merge commits. |
| P7 | When D-CB lands and whether its entry tooling can re-issue for a new CDHash without another fix. | Track `ops/cb-activation-gates`; read its diff when committed. |
| P9 | Whether the Keychain generation anchor (`macprovider.native-mtp-revocation-generation`) is writable in the launchd GUI-domain context of the live provider. | Read-only check on Studio of Keychain access for the provider user. Then an isolated run under a GUI-domain LaunchAgent with a private label. |
| P10 | Whether generic SPEC-031 canaries (temperature 0, no key) become native rows once admitted, and whether nonce-echo judging stays correct. | Isolated canary run in L4, checking the selector reason and the canary verdict. |
| P11 | Whether weekly renewal plus a 14-day slot batch survives one missed run without disabling native. | Dry-run renewal and a slot-expiry simulation in the P4 test. |

## 8. Effort, PR count and worth

| Work | Estimate |
|---|---|
| G1 parity fix + tests + hardware verify | 2–3 days |
| G3/G4/G5 CLI fetch, materialize, origin derivation + tests | 4–5 days |
| G3/G5 coordinator routes, config, nginx, tests | 2–3 days |
| G2/G3/G4/G5 catalog-release v4 ledger, members, signing, renewal stage, slot presigner + tests | 4–5 days |
| G10 journey harness steps, result builders, promote workflows | 5–7 days |
| G8 accounting harness, G9 canary config, G12 conformance and spec text | 2–3 days |
| G11 R003 close, R015 re-freeze, post-gateway replay | 2–3 days (mostly lab) |
| G6: consume D-CB entry, re-issue for the cut | 0.5 day |
| Freeze audit (three lanes, one round) + rehearsal + post-merge confirmation | 3–4 days |
| G7 SPEC-001/024/048 amendment + coordinator + CLI | 5–8 days |

**Total: about 29–40 engineer-days.** Calendar time is about 5–7 weeks once
operator pause windows, D-CB, and one-Pearl-actor scheduling are counted.

PRs:
1. One campaign PR: CLI, coordinator, catalog tooling, renewal, presigner,
   journeys, SPEC-001/023/024/048 text, and G7.
2. One CLI-cut staging PR.
3. One catalog-release PR (catalog files, policy source, sidecar inputs).
4. One evidence and conformance PR (signed SERVING result, CONFORMANCE
   promotions; later the RELEASE result).

That is 4 PRs, plus #1862 landing separately first.

**Payoff.** At one active row the gain is 1.19–1.28x decode (1.04–1.20x end
to end); at two or more rows it is 1.00; Studio tuple only; and only for
eligible requests, which G7 is required to make a material share. Standing
operational cost: weekly sidecar re-sign, a revocation slot directory that
must never lapse, 90-day journey renewal, and a sidecar entry per CLI cut.
