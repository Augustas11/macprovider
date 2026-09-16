# BYOM slice-7 (#1486) 12-step E2E — handoff (2026-09-16, for the next session)

Goal unchanged: drive the settleable MLX candidate to `settlement_capable` on this Mac via
the CANONICAL runbook (`test/e2e/byom/run-cli-onboarding-e2e.py --journey-evidence`,
procedure `test/e2e/byom/ADMISSION-JOURNEY-RUNBOOK.md`), all 12 steps, capture
`run-manifest.json`. Fix real blockers; never hand-drive the state machine or weaken
harness assertions. Rig = `RIG=/Users/augstar/.byom-slice7-rig` (real coordinator binary
built from this repo + SQLite admission store + Postgres onboarding + v4-signed feeds).

## State of play (what is DONE)

1. **PR #1548 MERGED** (`a5a42284`): mlx_cache offers carry the snapshot-manifest hash.
   Canonical `main` is synced to it.
2. **Blocker B fixed (needs audit + PR)** — branch `fix/1486-serve-hold-byom-admission`,
   worktree `/Users/augstar/macprovider-1486-serve-hold`, pushed (commit `d8ef4b91` +
   uncommitted test-fixture fixups in `CoordinatorClientTests.swift` if the last test run
   was still red — see "Immediate next steps").
   - Coordinator: `phase4-coordinator/internal/buyer/{model_admission.go,server.go}`:
     `/v1/pool/check?details=readiness` adds `buyer_serving_hold: model_admission_pending`
     when the session's registry binding names a candidate whose latest event is
     `offer_submitted|sandbox_probe_only|network_visible_unpriced|network_admitted_unsettled|catalog_priced`.
     Tests: `TestPoolCheckReadinessAppliesBYOMSettlementGate`,
     `TestPoolCheckReadinessHoldNamesOnlyPendingBYOMAdmission` (green; `go test ./internal/buyer` green).
   - CLI: `CoordinatorReadinessClient.Readiness` (`.confirmed | .notServing(hold:) | .indeterminate`,
     Bool/nil-literal compatible), `fetchReadiness`/`readiness`; `CoordinatorClient`
     `acceptCoordinatorSession` holds the accepted session on `.admissionPending`
     (lifecycle `locally_ready_connecting` / reason `byom_admission_pending_buyer_serving`),
     `startAdmissionPendingReadinessWatch` polls every 15s (`admissionPendingReadinessPollNanoseconds`),
     promotes to `serving_buyers` with `coordinator_buyer_serving_confirmed_after_admission`,
     tears down on a hold that ends unconfirmed. Tests added:
     `testCoordinatorSessionHoldsThroughPendingBYOMAdmissionThenPromotes`,
     `testCoordinatorSessionStillFailsClosedWhenReadinessIsUnconfirmedWithoutAdmissionHold`,
     `testCoordinatorHeldSessionReconnectsWhenAdmissionHoldEndsUnconfirmed`,
     `ProviderStatusTests/testCoordinatorReadinessHoldIsCarriedOnlyOnAuthoritativeNotServing`.
   - Built artifacts: release CLI
     `/Users/augstar/macprovider-1486-serve-hold/phase3-binary/.build/release/macprovider-cli`
     (`mlx-swift_Cmlx.bundle` copied beside it; version 1.8.123); hold-aware coordinator
     `$RIG/coordinator.new` (installed by `$RIG/rig-adopt-live-feed.sh`).
3. **Runner branch** `fix/1486-journey-sqlite-ledger-read` (`/Users/augstar/macprovider-1486-runner`)
   rebased on merged main, committed `d557dd4f`, pushed: SQLite ledger read (`sqlite:` DSN) +
   CLI stderr surfaced on non-zero exit. (Step-3 `coordinator:not_offered` acceptance: check
   it is in that diff; the handoff said it was, `git show d557dd4f` to confirm.)
4. **Rig prepared**: `$RIG/provider-config.yaml` now has `ctl_socket_path: $RIG/ctl.sock`
   (rig serve and PROD serve were sharing `$TMPDIR/macprovider-cli/ctl.sock`);
   `$RIG/provider-config.drift.yaml` (Qwen3-8B catalog provenance from the durable store,
   port 61931, own ctl socket); new `$RIG/drift-hook.sh` (replacement-hello drift, below);
   `$RIG/rig-adopt-live-feed.sh` (adopt the LIVE production feed set into the rig, rebuild +
   v4-sign the artifact feed bound to it, sync `model_catalog_hash/version` in both provider
   configs, swap in `coordinator.new`, restart coordinator).

## Blocker A — REAL root cause (production, not rig) — OPERATOR ACTION REQUIRED

Step 6 needs `economics_state == "trusted"`, which the CLI grants ONLY for a `live_signed`
rate card fetched from the hard-coded `https://coordinator.malibu.tech/v1/*`, not
`usedFallback`, younger than 7 days (`ModelCatalogEconomics.swift` `economicsFields`).
A fresh-BAKED CLI can never pass it (fallback => `"fallback"`, and a baked catalog newer
than served makes the serve refuse to join: `rateCardUpdateRequired`). So the handoff's
"fresh-dated release CLI" plan was wrong; ONLY renewing the live feed works.

Production feeds are still `published-2026-09-02` (14d old). The weekly signed renewal
`renew-autotune-static-feed-signed.yml` has NEVER succeeded: its secrets
`AUTOTUNE_STATIC_V4_PRIVATE_KEY_BASE64` and `PEARL_AUTOTUNE_DEPLOY_SSH_KEY` exist in
neither repo nor `production-release` environment secrets, and the environment's required
reviewer auto-rejected the 09-02/09-09 runs. The Tuesday watch alarmed 09-15 (16d left to
the fleet 30-day fail-closed). `scripts/renew-autotune-static-feed.sh` DRY RUN passed on
this Mac (`$RIG/renew-dryrun.log`, release `published-2026-09-16-inband-provenance-v1`).

The operator (augstar) authorized the deploy in chat, but the Claude auto-mode classifier
blocks it. **Operator runs:**
```bash
cd /Users/augstar/macprovider-poc && bash scripts/renew-autotune-static-feed.sh --deploy 2>&1 | tee /Users/augstar/.byom-slice7-rig/renew-deploy.log
```
Then verify `curl -s https://coordinator.malibu.tech/v1/rate-card | jq .generated_at` is today.

Making the weekly job unattended = dropping the reviewer gate on the signing-key
environment (a security-posture change; classifier refused to author it). Proposal if the
operator wants it: new environment `autotune-feed-renewal` (main-only branch policy, no
admin bypass, NO reviewers) + the two secrets scoped there + workflow `environment:` and
`POSTURE_PROFILE=unattended` support in `scripts/verify-github-release-posture.sh` (skip
the reviewer-rule assertion only for that profile) + runbook `docs/runbooks/autotune-feed-renewal.md`.
A dedicated deploy key (not `~/.ssh/pearl_operator_ed25519`) should be generated for CI.
Worktree `/Users/augstar/macprovider-feed-renewal-unattended` (branch
`ci/autotune-feed-renewal-unattended`) exists, EMPTY.

## Blocker C — drift induction design (UNTESTED live)

A one-byte safetensors flip cannot be served (CLI preflight verifies the artifact hash vs
config + durable store), and a restart clears the binding before the next hello (no prior
binding => nothing evaluated, SPEC-047-R006(a)). The coordinator DOES evaluate a
REPLACEMENT hello for the same provider id while the admitted session is still live:
`bindModelAdmissionSessionAtHello` runs `sessionDriftReason` against the prior binding's
candidate; a session serving another model id => `revoked` / `runtime_identity_drift`.
`$RIG/drift-hook.sh` starts a SECOND serve on `provider-config.drift.yaml` (Qwen3-8B, same
provider identity) while the llama serve stays up, waits for
`"event":"model_admission_drift_revoked"` in `$RIG/coordinator.log` (≤90s), then kills only
the drift serve (by its exact config path). The bumped llama serve reconnects on backoff;
after revocation its candidate is terminal => unbound => ordinary catalog session (buyer
serving). Verify this end-to-end before trusting it; adjust if the coordinator closes the
replaced socket in a way the CLI treats as fatal.

## Update 2026-09-16 (later): first --deploy rolled back on a script bug

The operator's first `--deploy` uploaded and hot-reloaded a good release, then the script's own
post-SIGHUP activation check (inline `python3 -c` f-string with backslash-escaped quotes) raised
SyntaxError and the script rolled back (Pearl `current` back on published-2026-09-02, lock released).
Fixed in PR #1552 (`fix/renew-feed-served-check-quoting`, worktree `/Users/augstar/macprovider-renew-verify-fix`)
with `scripts/tests/test_renew_served_feed_check.py`. Re-deploy command (operator):
`cd /Users/augstar/macprovider-renew-verify-fix && bash scripts/renew-autotune-static-feed.sh --deploy 2>&1 | tee /Users/augstar/.byom-slice7-rig/renew-deploy.log`

## Immediate next steps (in order)

1. `cd /Users/augstar/macprovider-1486-serve-hold/phase3-binary && swift test --filter 'CoordinatorClientTests/testCoordinatorSessionHolds|CoordinatorClientTests/testCoordinatorSessionStillFailsClosed|CoordinatorClientTests/testCoordinatorHeldSession|ProviderStatusTests/testCoordinatorReadiness'`
   — last known: lifecycle fixture fixed to seed `locallyReadyConnecting`, and the fail-closed
   test expects 1 readiness call (retry interval is 0 in `makeClient`). If green, commit the
   fixups (`git add` ONLY the 4 Swift/Go files; NEVER `git add -A`: swift build dirties
   `Package.resolved`, `git checkout -- phase3-binary/Package.resolved` first) and push.
   Also run `swift build` of the whole test target once (`swift build --build-tests`) to be
   sure nothing else references the old `Bool?` readiness closure.
2. 3-lane codex audit (code / security / architecture) on the FULL diff
   `git diff origin/main..HEAD` of that branch: write prompt files under
   `audits/2026-09-16/`, run `omc ask codex -p "$(cat file)"`; bar = 0 C/H/M. Then PR with the
   SPEC-governance declaration (`python3 scripts/check_spec_pr_declaration.py --event /tmp/pr-event.json --base origin/main --head HEAD`),
   author as Augustas11 so antfleet-ops reviews. Cite SPEC-047-R003(iv) and R006.
3. Runner branch PR the same way (test/e2e only; declaration validator still required).
4. After the operator's feed deploy lands: `bash $RIG/rig-adopt-live-feed.sh` (REPO defaults
   to the serve-hold worktree for `catalog-release.py`/artifact source), then reset per the
   old procedure: stop ONLY the rig serve (`pkill -f "macprovider-cli serve --config $RIG/provider-config.yaml"`,
   never by binary name — prod serve is `/Users/augstar/macprovider/macprovider-cli serve --config /Users/augstar/.config/macprovider/config.yaml`,
   launchd `live.malibu.provider`), `sqlite3 $RIG/coordinator.db "DELETE FROM model_admission_events; DELETE FROM model_admission_pending_decisions;"`,
   `rm -f ~/Library/Application\ Support/macprovider/lifecycle/lease.json`, restart coordinator
   (the adopt script does), start ONE serve with the serve-hold CLI:
   `env MACPROVIDER_PROTECTED_CREDENTIAL_ROOT=$RIG/protected-credentials MACPROVIDER_BYOM_ALLOW_INSECURE_LOOPBACK_COORDINATOR=1 /Users/augstar/macprovider-1486-serve-hold/phase3-binary/.build/release/macprovider-cli serve --config $RIG/provider-config.yaml > $RIG/provider-serve.log 2>&1 &`
   Confirm hello accepted (coordinator log, no `catalog_incompatible`) and
   `curl 'http://127.0.0.1:18443/v1/pool/check?provider_id=DDC173BC-8BD5-4CF2-B7AF-C6AA8837EF60&assigned_id=<id>&details=readiness'`.
5. Run the runbook from the runner worktree exactly as in the previous handoff (env from
   `$RIG/secrets.env`: `MACPROVIDER_JOURNEY_OPERATOR_A/B`, `MACPROVIDER_JOURNEY_LEDGER_DSN=sqlite:$RIG/coordinator.db`,
   `MACPROVIDER_BYOM_E2E_DETECTED_RAM_GB=64`), `--cli-binary` = serve-hold CLI,
   `--drift-hook $RIG/drift-hook.sh`, `--gguf-ref ollama:gemma3:270m`,
   `--opaque-ref openai_compatible:opaque-journey-model`, discovery args
   `--ollama-origin http://127.0.0.1:11434 --openai-compatible-origin http://127.0.0.1:21435 --skip-lmstudio --skip-llamacpp`.
   Fixtures verified up on 2026-09-16: ollama (gemma3:270m present), opaque origin :21435,
   socat TLS relay :18544, Postgres 55432, coordinator :18443/:18444.
6. Watch step 7 (drift) and step 9 (the serve must be HELD, then promoted after the rig_b
   approval); step 12 redaction: `$RIG/drift-serve.log` is separate from the provider log on
   purpose. Capture `~/byom-admission-run/run-manifest.json`; the signed
   JOURNEY-NETWORK-MODEL-ADMISSION, SPEC-047-R001..R008 promotion and the release cut stay
   operator-only.

## Do-not list
- Do NOT `pkill -f "macprovider-cli serve"`; if prod dies: `bash $RIG/restore-malibu-provider.sh`
  and remove a stale `$TMPDIR/macprovider-cli/ctl.sock`.
- Do NOT edit canonical `/Users/augstar/macprovider-poc`; do NOT `git add -A` in phase3 worktrees.
- Do NOT restamp feed dates locally to fake freshness (breaks version→sha provenance).
- Never print private key bytes (`~/.config/macprovider/keys/autotune-static-v4.private.base64`, `/tmp/v4.pem`).
