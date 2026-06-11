# Milestone 1 — handoff

Milestone 1 from `audits/2026-06-10/REPO_AUDIT.md` ships as seven PRs against
`Augustas11/macprovider`. M1-3 was identified as duplicate of Quick Win QW-4
and intentionally skipped per the autopilot brief.

All PRs:

- branched from the latest `origin/main` (post-Milestone 0)
- carry a regression test that **fails on pre-fix code** per the audit's
  "Theme 4 sequencing" rule and AGENTS.md sensitive-paths discipline
- pass the full Go suite (`go test ./...`); the modernc.org/sqlite bump
  additionally passes `-race -count=3` across both modules
- need human review per AGENTS.md before merge (do not self-merge)

## PR list

| # | PR | Branch | Audit refs | Touches |
|---|---|---|---|---|
| M1-2 | [#36](https://github.com/Augustas11/macprovider/pull/36) | `fix/m1-2-failover-divergences` | ARCH-1, CODE-1 | `phase4-coordinator/internal/buyer/server.go`, `…/server_test.go` |
| M1-5 | [#37](https://github.com/Augustas11/macprovider/pull/37) | `fix/m1-5-fail-closed-auth` | SECU-5, TEST-5 | `phase4-coordinator/internal/ws/server.go`, `…/billing/endpoints.go`, `…/auth/tokens.go`, two new tests |
| M1-8 | [#38](https://github.com/Augustas11/macprovider/pull/38) | `fix/m1-8-demo-concurrency-cap` | PERF-6 | `phase5-gateway/internal/router/server.go`, `…/internal/config/config.go`, `gateway.yaml.example`, new test |
| M1-4 | [#39](https://github.com/Augustas11/macprovider/pull/39) | `fix/m1-4-coordinator-ws-rate-limit` | SECU-1 | `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`, `…/internal/ws/server.go`, `…/internal/config/config.go`, new test |
| M1-6 | [#40](https://github.com/Augustas11/macprovider/pull/40) | `fix/m1-6-deploy-gate-hardening` | DEVE-4, DEVE-5, SECU-3 | `phase5-gateway/dist/deploy-pearl-vps.sh` (new), `…/dist/deploy-pearl-vps.md` (rewritten), `phase4-coordinator/dist/check-deploy-config.sh`, `…/dist/deploy-pearl-vps.sh` |
| M1-1 | [#41](https://github.com/Augustas11/macprovider/pull/41) | `feat/m1-1-provider-tokens-pinned-tier` | XSEC-1 | `phase3-binary/Sources/MacProviderCore/Config.swift`, `…/macprovider-cli/MacProviderCLI.swift`, `…/macprovider-cli/CoordinatorClient.swift`, three new tests, `specs/SPEC-001-phase3-binary.md` v1.3.1 |
| M1-7 | [#42](https://github.com/Augustas11/macprovider/pull/42) | `chore/m1-7-modernc-sqlite-bump` | DEPE-1 | `phase4-coordinator/go.mod`, `…/go.sum` |

## Blocked gates (audit Open Questions)

These were intentionally **not** closed in this run. They surface here so the
operator can act in priority order.

### Open Q2 — Provider token issuance model for open onboarding (still open)

> "Pinned providers clearly need operator-issued tokens. For curl|bash strangers
> (provisional tier): operator-issued (friction, but authenticated) or self-serve
> provisional tokens minted at first admission (preserves open onboarding, still
> kills pinned impersonation)? SPEC-003's intent here needs an explicit ruling."

**Impact**: M1-1 ships the **pinned-tier** path only. `phase3-binary/dist/install.sh:464-469`
was not touched. Until Q2 is answered, strangers running `curl … | bash` cannot
authenticate, so flipping `require_provider_tokens=true` would block all new
provisional providers from joining.

**Two branches of the answer**:

- Operator-issued strangers → `install.sh` prompts for a token (or reads
  `MACPROVIDER_PROVIDER_TOKEN` from env), writes to config, no coordinator
  change.
- Self-serve provisional → coordinator mints a provisional token on first
  admission and returns it via the auth_response; `install.sh` writes the
  returned token back to config. Coordinator needs a new code path; SPEC-003
  needs the explicit ruling.

### Open Q3 — Target tier-2 posture for this beta (still open, but with a decision recorded)

> "Which of the five enforcement flags (RequireEncryptedLeg, RequireHashVerified,
> RequireAttestation, BehavioralSafetyEnabled, EncodingValidationEnabled) should
> production assert NOW vs at scale?"

**This autopilot run asked the operator and the answer was "Defer Part C
entirely."** None of the five flags are asserted by the M1-6 deploy gate yet.
When the team picks a target posture, Part C is a ~10-line addition to
`check-deploy-config.sh` (one `g(coord, "<flag>")` check per asserted flag).

### Gate C — operator-driven, by design

M1-1's `require_provider_tokens=true` flip and M1-7's canary day are operator
actions. Code is merged; the deploy is not. See the per-PR description for the
verbatim procedure.

## Operator actions, in execution order

1. **Review and merge the seven PRs** in the order they were opened (Phase 1
   first: #36, #37, #38; Phase 2: #39, #40; Phase 3: #41, #42). The branches
   touch independent files, so there are no merge conflicts.
2. **Decide Open Q2** before completing M1-1. If operator-issued strangers:
   update `install.sh` to accept a token. If self-serve provisional: write the
   coordinator-side code path and SPEC-003 amendment.
3. **M1-1 production migration** (after #41 merges):
    1. Use `coordinator-cli issue-token --provider-id M1` (and same for M4,
       air8gb) against Pearl to mint pinned-tier tokens. Capture each
       show-once value securely on the Mac that will use it.
    2. Update each provider's `macprovider.yaml` with `auth.provider_token:
       <token>` and `chmod 0600 macprovider.yaml`. `systemctl restart` the
       provider service.
    3. Verify all 3 providers heartbeat with a validated token in coordinator
       logs: `grep provider_token_validated`.
    4. Flip `require_provider_tokens=true` in Pearl's `coordinator.yaml`;
       SIGHUP the coordinator. Verify all 3 providers re-auth cleanly; verify
       a fresh tokenless connect attempt is now rejected (curl wss test or
       equivalent).
    5. Old v1.2.x binaries cannot send tokens — the flag flip IS the
       compatibility cutoff. Document this in `beta/DECISION_CRITERIA.md`.
4. **M1-4 nginx rollout** (after #39 merges): copy
   `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf` to Pearl,
   `nginx -t`, `systemctl reload nginx`. Verify rate-limit headers and that no
   legitimate provider trips the 10 req/min cap.
5. **M1-6 first scripted gateway deploy** (after #40 merges): run
   `bash phase5-gateway/dist/deploy-pearl-vps.sh`. The script enforces C2 by
   default and reads gateway config from
   `phase5-gateway/dist/gateway.yaml` (fallback `gateway.yaml.example`).
6. **M1-7 canary** (after #42 merges): deploy the bumped coordinator binary
   during a quiet window using the M1-6 script (`.prev` rollback ready).
   Watch `monitor.py` + `journalctl -u macprovider-coordinator` for 24h for
   `SQLITE_BUSY` / "database is locked" / ledger-write failures. If clean,
   no further driver action needed (gateway already at v1.52.0).
7. **Decide Open Q3** so M1-6 Part C can land as a follow-up.
8. **Decide M1-3** explicitly — Quick Win QW-4 covers it; if QW-4 hasn't been
   done yet, file it as a separate issue.

## M1 complete criteria

Declare Milestone 1 done when:

- All seven PRs are merged
- M1-1 production migration is complete with
  `require_provider_tokens=true` flipped and tokenless connect rejected
- M1-4 nginx conf is live on Pearl with rate-limit headers observed
- M1-7 canary has run for 24h on the bumped coordinator with no
  SQLITE_BUSY/ledger-write failures, and the gateway has been redeployed
  (no driver change for gateway, but cycle to confirm builds are reproducible)
- A new entry in `beta/DECISION_CRITERIA.md` records:
  - the flag-flip date and verification (the compatibility-cutoff record)
  - the M1-7 canary outcome
  - the answers to Open Q2 and Open Q3 (or an explicit "still open" decision)

## Audit refs

- Full audit: `audits/2026-06-10/REPO_AUDIT.md`
- §5 Task Plan: tasks M1-1 through M1-8
- §6 Open Questions: Q2, Q3
- Theme 2 (fail-closed trust boundaries) and Theme 4 (de-risk money-path hot
  spot) — both partially advanced by this milestone
