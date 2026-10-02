# #1816 handoff: pool-scoped model admission (PAUSED 2026-10-02)

**Status:** paused by the operator on 2026-10-02. Draft PR #1830 (`feat/1816-pool-scoped-models`), not mergeable.

**Resume condition:** the operator says "resume #1816". Nothing resumes automatically. Each item below says whether it needs a new session's work or an operator action.

**Reading order:** this file, then #1830's body, then `docs/runbooks/vm-e2e-1816-lima.md` (how to drive the VM on this Mac), then `docs/testing/1816-vm-acceptance-plan.md` (harness and findings), then `docs/runbooks/pool-scoped-model-admission.md`.

## Where things stand

- **Specs:** SPEC-042 (v2 extensions `pool_model_entries/v1` and `pool_attested_members/v1`), SPEC-047-R011, SPEC-005-R015, SPEC-022-R013 (`route_snapshot_v2`), SPEC-006-R018, SPEC-043-R006 (policy-terms delegation digest), SPEC-032-R004 and SPEC-023-R026. Every #1816 CONFORMANCE row is `pending` until signed journey evidence exists. SPEC-046 and SPEC-047 R001-R007 were demoted for stale selectors.
- **Code:** coordinator, gateway, phase7-verify, CLI (`models propose --pool`, pool-model serve, live-feed matcher), Malibu.app, Pearl updater (bound artifact feed), deploy canary, lab tooling, and the VM harness `test/e2e-1816/`.
- **Catalog:** signed release `published-2026-10-01-artifact-feed-activation-v1` (first GGUF artifact; rate card unchanged), plus the re-issued Build 1 private authority. It is committed but **not deployed**.
- **Verification so far:**
  - Unit, integration, test-dist and updater suites are green at the PR head.
  - One three-lane freeze audit was run, and all of its findings were fixed or carried. The operator rule is one audit round only, then e2e.
  - A Studio lab e2e ran at `5b9dd014f`.
  - The VM acceptance ran at `1832627e7` (see below).

## VM acceptance at `1832627e7` (2 passes, fake-Pearl VM `macprovider-1690`)

Results: 204 total, 138 PASS, 38 FAIL, 26 INFO, 2 GAP. The merge gate is two consecutive green passes, so it **failed**.

Evidence (local, gitignored): `.omc/e2e-1816/vm-1832627e7/{results-1832627e7.jsonl,evidence-1832627e7.tgz,vm-accept-1832627e7.log}` in the campaign worktree.

The triage below is **unverified**: it is a first sort from the result details only. Reproduce each item before fixing it.

1. **Probably a product bug (top lead): streaming pool-model requests are refunded while non-streaming ones settle.**
   - Seen in: `S3-pool-traffic-gguf`, `S5-rotation-settles`, `S5-entry-removed-inflight-settles`, `S5-future-core-current-price`, `S6-pause-inflight-settles`.
   - Several of these show `routed: 0`, meaning the request never reached a member.
   - Suspects: the A-1a route-snapshot-v2 negotiation on the streaming path, and the final-settlement fence on streams.
2. **Probably a product bug: `S6-step4-coord-preflight-gate` exits 3 with no pool ever created.** The rollback preflight's default tier (v1-only) is too strict when the store holds no extension cores.
3. **Probably a product bug: `S5-rotation-no-gap` still sees one 503 per rotation.** The F3 zero-gap rebind is not complete.
4. **Probably a product bug (money): `S2-new-pair-catalog` pass 2 has a `ns_dc` attempt with buyer debit 8 and provider payable 11** (I3 mismatch), plus an I5 verdict left open past its deadline. Check whether the A-1b/A-3 hold-deadline change caused it.
5. **Needs analysis (S5 attested/delegated members):** `S5-attested-member-binds`, `-paid` and `S5-window-rotation-keeps-delegated-member` fail with `routed: 0` / not bound. Either the A-5 policy-terms grant path or the harness delegate step.
6. **Probably a harness expectation:**
   - `S3-order-coordinator-first-*`: a pool-model request through an old gateway is now refused by design (A-1a, `pool_model_requires_gateway_upgrade`); the harness still expects it to settle.
   - `S1-baseline`: old binaries carry the pre-existing A-3 hold, fixed only in the new gateway.
   - `S2-order-gateway-first-*` / `S2-new-pair-shape`: check against items 1 and 4 first.
7. **Harness bugs:**
   - `S4-catalog-overlap-blocked`: the lab-signed blocked release files are not readable by the coordinator user (`rate-card.json: permission denied`).
   - `S5-member-revoked-inflight` / `S5-attestation-removed-inflight`: a "never in flight" precondition (P0).
   - `S2-guard-*`: a GAP and an empty-detail failure.

## Next steps, in order (when resumed)

1. Reproduce and fix triage items 1-5 in Go tests first. Opus does the coding; Codex is used only for audits, and there are no further audit rounds.
2. Fix the harness items in 6 and 7.
3. Re-run `E2E_NEW_REF=<head> bash test/e2e-1816/run-all.sh 2` until two consecutive passes are green.
   - The host runner hits the 2 h background limit, but the in-VM run continues as `e2e-1816-passes.service`; poll it.
   - If the guest kernel panics at boot (qemu TCG int3 Oops), `limactl stop -f` and start again.
4. A Studio real-engine pass for llama.cpp and native MLX non-catalog models. Coordinate with the MTP session (`macprovider-poc-20`) for Studio time.
5. Mark #1830 ready. Review, CI, merge.
6. Production activation (operator-gated), in order:
   - Pearl runtime cut. The **gateway goes before the coordinator** for pool-model v2 snapshots; the updater stops the gateway first and starts the coordinator first.
   - Add the two `/v1/catalog-artifacts` locations to Pearl nginx by hand, before the apply.
   - Apply the catalog release through the updater.
   - Add the `trusted_pools` config: `enabled`, `pool_model_pricing_bounds` (proposed values are in the runbook) and `provider_owner_account_ids`.
   - First pool and member per `docs/runbooks/trusted-pool-m1-activation-plan.md` plus the pool-model runbook.
   - A signed journey, which moves the pending CONFORMANCE rows to conformant.

## Carried risks (documented, accepted for now)

- S-M4: a canary user can forge the `live_verified` proof. No coordinator record ties a session to the feed bytes it fetched.
- S-M5: rolling back the whole SQLite store defeats manifest and revocation monotonicity. Re-apply revocations after any DB restore.
- Native **catalog** pool routes are not fenced at final settlement. This predates #1816 and is a SPEC-042-R003/R005 policy question.
- Step 4 (global graduation) is narrowed. The pool-proven aggregate and out-of-band `listed` adds are not executable yet (SPEC-023 §16.9).

## Local state

- Campaign worktree: `/Users/augstar/macprovider-1816-pool-models`, the only #1816 worktree. The lane worktrees and branches were removed on 2026-10-02, after checking that each one was merged into the campaign branch.
- Studio: the #1816 lab and build directories (`~/lab-1816-e2e`, `~/build-1816-e2e`, `~/build-1816-cli`) were removed on 2026-10-02. The Studio lab evidence is kept on this Mac under `.omc/e2e-1816/`.
- The VM `macprovider-1690` is stopped.
- Raw audit transcripts are kept outside the repo; they trip the secret preflight on key-marker excerpts.
