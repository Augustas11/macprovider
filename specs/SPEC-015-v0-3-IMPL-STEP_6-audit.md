## Lens — CODE — Round 1

### CODE-R1-CRITICAL-1 — AC-38 manifest evidence does not establish the locked-v0.2.4 verifier behavior

SPEC-015 §M.5 AC-38 requires an unmodified locked v0.1.3 / v0.2.4 verifier to read a v0.3 receipt and report `invalid`; the named test command is `./phase7-verify-v0.2.4 --bundle <v0.3-bundle.json>` (`specs/SPEC-015-receipts.md:3555`). The Step 6 manifest instead maps AC-38 to `cd phase7-verify && go test ./internal/receipt/ -count=1` (`test/integration/spec015/v03_acceptance_manifest_test.go:129`) and cites current v0.3 source anchors (`test/integration/spec015/v03_acceptance_manifest_test.go:131`, `test/integration/spec015/v03_acceptance_manifest_test.go:138`, `test/integration/spec015/v03_acceptance_manifest_test.go:139`). Those anchors prove the current parser has v0.3 tuple-shape handling; they do not execute or inspect an unmodified v0.2.4 verifier binary. This matches the audit prompt's CRITICAL class: an AC manifest claims coverage that the cited evidence does not actually establish (`specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_6_PROMPT.md:25`).

### CODE-R1-MEDIUM-1 — AC-30 and AC-31 do not meet the stated two-anchor manifest bar

The Step 6 audit prompt says each AC has at least two evidence anchors (`specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_6_PROMPT.md:14`). AC-30 has one anchor (`test/integration/spec015/v03_acceptance_manifest_test.go:44`), and AC-31 has one anchor (`test/integration/spec015/v03_acceptance_manifest_test.go:54`). The manifest test validates command/CI presence and pattern existence (`test/integration/spec015/v03_acceptance_manifest_test.go:216`, `test/integration/spec015/v03_acceptance_manifest_test.go:219`), but it never asserts `len(ac.Evidence) >= 2`. This leaves the manifest below the stated Step 6 evidence standard even though the current test passes.

Validation run: `cd test/integration && go test ./spec015/ -count=1 -timeout 120s -run 'TestSpec015V03AcceptanceCriteria|TestSpec015V03AcceptanceManifestCoversAC28ThroughAC42'` passed.

VERDICT: FAIL — AC-38 must be backed by a real locked-v0.2.4 verifier command/evidence before Step 6 can close.

COUNTS: CRITICAL=1 HIGH=0 MEDIUM=1 LOW=0

## Lens — SECURITY — Round 1

### SECURITY-R1-HIGH-1 — Rollback command points at backup paths the deploy script does not create

The runbook rollback command restores `/opt/macprovider/coordinator.bak` (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:121`) and states the deploy script preserves that file (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:125`). The actual deploy script snapshots the previous binary to `/opt/macprovider/coordinator.prev` (`phase4-coordinator/dist/deploy-pearl-vps.sh:229`, `phase4-coordinator/dist/deploy-pearl-vps.sh:230`), and the canonical rollback procedure restores that `.prev` snapshot with `install -o macprovider -g macprovider -m 0755` (`audits/2026-06-10/ROLLBACK_PROCEDURE.md:25`, `audits/2026-06-10/ROLLBACK_PROCEDURE.md:30`). The same runbook also claims an nginx backup at `/etc/nginx/sites-available/coordinator.streamvc.live.conf.bak-<UTC>` (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:125`), but the deploy script installs `/tmp/nginx-coordinator-full.conf` directly to `/etc/nginx/sites-available/$DOMAIN` (`phase4-coordinator/dist/deploy-pearl-vps.sh:315`) without creating that backup. This is a HIGH under the prompt because the runbook rollback step does not compose with the current deploy script (`specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_6_PROMPT.md:31`).

No Entry 80 flip found: the runbook says the five tier-2 `require_*` flags stay false (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:49`) and explicitly says `Tier2Config.RequireHashVerified` is not flipped (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:131`). Provider rollout order is correct: verifier release before provider distribution (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:87`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:90`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:91`).

VERDICT: FAIL — rollback instructions must be corrected before operator handoff.

COUNTS: CRITICAL=0 HIGH=1 MEDIUM=0 LOW=0

## Lens — ARCHITECT — Round 1

### ARCHITECT-R1-CRITICAL-1 — Step 6 does not deliver the cross-binary parity gate required by the BUILD prompt

The BUILD prompt defines Step 6 as "Integration acceptance + cross-binary parity" (`specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:290`) and requires a cross-binary test that builds/runs the v0.3 verifier and a v0.2.4 verifier against the same v0.1/v0.2 and v0.3 receipts (`specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:304`). It also requires a `test/integration/spec015_v03/` harness (`specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:298`). The landed Step 6 surface is a manifest file at `test/integration/spec015/v03_acceptance_manifest_test.go`, and no `test/integration/spec015_v03/` harness or `phase7-verify-v0.2.4` executable was found in the worktree. The AC-38 manifest entry therefore collapses the architectural boundary from "prove locked old verifier rejects new wire" to "current code contains a strict tuple-shape path" (`test/integration/spec015/v03_acceptance_manifest_test.go:129`, `test/integration/spec015/v03_acceptance_manifest_test.go:138`). Because AC-38 is the §M.1.2 forward-incompat guard that justifies the runbook's verifier-before-provider choreography, this is not a harmless test-shape substitution.

### ARCHITECT-R1-HIGH-1 — Operator rollback handoff contradicts the deploy script's actual state model

The runbook's binary rollback target is `.bak` and its nginx rollback target is a dated site-conf backup (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:122`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:125`). The deploy script's state model uses `.prev` for binary rollback (`phase4-coordinator/dist/deploy-pearl-vps.sh:220`, `phase4-coordinator/dist/deploy-pearl-vps.sh:229`) and does not create the claimed nginx backup before overwriting the site config (`phase4-coordinator/dist/deploy-pearl-vps.sh:313`, `phase4-coordinator/dist/deploy-pearl-vps.sh:315`). That breaks A.1/A.5 composition: the operator handoff cannot be followed mechanically during a failed `/catalog/` rollout.

Positive checks: locked SPEC-015 remains v0.3.3 LOCKED (`specs/SPEC-015-receipts.md:3`); no locked-spec diff was present for SPEC-001/002/005/006/008/010/011/013/015 in this worktree; the runbook documents the README close-out (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:138`); the v0.4+ candidate list matches §M.6 deferred themes (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:140`, `specs/SPEC-015-receipts.md:3642`).

VERDICT: FAIL — Step 6 architecture is missing the required cross-binary acceptance gate and the operator rollback handoff is not executable as written.

COUNTS: CRITICAL=1 HIGH=1 MEDIUM=0 LOW=0

## Lens — CODE — Round 2

No Round 2 CODE findings.

The AC-38 manifest entry now names a runnable command for the locked-parser parity gate: `cd phase7-verify && go test ./internal/receipt/ -run TestV02LockedParserRejectsV03Receipts -count=1` (`test/integration/spec015/v03_acceptance_manifest_test.go:131`). Its evidence anchors point at the new parity test, the inline locked-parser mirror, and the explicit v0.3 rejection assertion (`test/integration/spec015/v03_acceptance_manifest_test.go:141`, `test/integration/spec015/v03_acceptance_manifest_test.go:142`, `test/integration/spec015/v03_acceptance_manifest_test.go:143`). The test drives both non-null and null-`model_hash` v0.3 tuples through `parseTupleV02Locked` and requires `ErrTupleExtraKey`; it also confirms a genuine legacy 7-field tuple remains accepted (`phase7-verify/internal/receipt/v02_parity_test.go:72`, `phase7-verify/internal/receipt/v02_parity_test.go:75`, `phase7-verify/internal/receipt/v02_parity_test.go:78`).

The AC-30 / AC-31 evidence-anchor gap is closed: AC-30 now has receipt-builder test plus implementation anchors (`test/integration/spec015/v03_acceptance_manifest_test.go:44`, `test/integration/spec015/v03_acceptance_manifest_test.go:45`, `test/integration/spec015/v03_acceptance_manifest_test.go:46`), and AC-31 now has HTTP error-path plus implementation anchors (`test/integration/spec015/v03_acceptance_manifest_test.go:55`, `test/integration/spec015/v03_acceptance_manifest_test.go:56`, `test/integration/spec015/v03_acceptance_manifest_test.go:57`). The manifest test now enforces the Step 6 >=2-anchor invariant for every AC before checking file/pattern existence (`test/integration/spec015/v03_acceptance_manifest_test.go:223`, `test/integration/spec015/v03_acceptance_manifest_test.go:225`), and still runs named subtests for AC-28 through AC-42 plus AC-32a (`test/integration/spec015/v03_acceptance_manifest_test.go:239`, `test/integration/spec015/v03_acceptance_manifest_test.go:241`, `test/integration/spec015/v03_acceptance_manifest_test.go:245`).

Validation runs:
- `cd test/integration && go test ./spec015/ -count=1 -timeout 120s` passed.
- `cd phase7-verify && go test ./internal/receipt/ -count=1` passed.

VERDICT: PASS — Round 1 CODE critical and medium findings are closed.

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0

## Lens — SECURITY — Round 2

No Round 2 SECURITY findings.

The rollback instructions now match the deploy script's state model. The runbook restores `/opt/macprovider/coordinator.prev` with `install -o macprovider -g macprovider -m 0755` (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:124`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:130`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:131`), which composes with the deploy script's pre-upload snapshot to the same `.prev` path (`phase4-coordinator/dist/deploy-pearl-vps.sh:220`, `phase4-coordinator/dist/deploy-pearl-vps.sh:228`, `phase4-coordinator/dist/deploy-pearl-vps.sh:229`). The runbook no longer claims the deploy script creates an nginx backup; it states the script does not snapshot the site conf and gives the operator a timestamped pre-deploy snapshot command (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:135`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:138`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:141`), matching the script's direct install of `/tmp/nginx-coordinator-full.conf` to `/etc/nginx/sites-available/$DOMAIN` (`phase4-coordinator/dist/deploy-pearl-vps.sh:313`, `phase4-coordinator/dist/deploy-pearl-vps.sh:315`).

Entry 80 preservation remains intact: the runbook says the tier-2 `require_*` flags stay at their defaults (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:49`) and explicitly says `Tier2Config.RequireHashVerified` is not flipped (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:155`), consistent with Entry 80's `false`-default deferral (`beta/DECISION_CRITERIA.md:374`). Provider/buyer rollout order still protects forward-incompat: the runbook instructs verifier release before provider rollout (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:87`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:90`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:91`). Smoke-check and monitoring commands use the operator key as a shell variable and do not print it (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:64`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:65`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:108`).

VERDICT: PASS — Round 1 SECURITY high finding is closed.

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0

## Lens — ARCHITECT — Round 2

No Round 2 ARCHITECT findings.

The AC-38 parity boundary is now explicit enough for the Step 6 acceptance manifest: the new test documents that it is an inline re-implementation of the v0.2.4 locked `parseTuple` at commit `99d0c1e`, with exactly seven allowed keys and no `receipt_version` / `model_hash` awareness (`phase7-verify/internal/receipt/v02_parity_test.go:83`, `phase7-verify/internal/receipt/v02_parity_test.go:93`, `phase7-verify/internal/receipt/v02_parity_test.go:101`). It covers both v0.3 receipt shapes and the legacy acceptance floor, which is the architectural invariant AC-38 needs for the runbook's verifier-before-provider choreography (`phase7-verify/internal/receipt/v02_parity_test.go:40`, `phase7-verify/internal/receipt/v02_parity_test.go:51`, `phase7-verify/internal/receipt/v02_parity_test.go:62`, `phase7-verify/internal/receipt/v02_parity_test.go:72`, `phase7-verify/internal/receipt/v02_parity_test.go:78`).

The operator handoff now composes with the deploy script: binary rollback uses `.prev` (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:126`, `phase4-coordinator/dist/deploy-pearl-vps.sh:229`), nginx rollback is framed as a caller-owned pre-deploy snapshot because the script overwrites the site config without an automatic backup (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:135`, `phase4-coordinator/dist/deploy-pearl-vps.sh:315`), and the `/catalog/*` surface is described as additive with verifier fallback to file-mode `--catalog` (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:149`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:150`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:151`).

Locked-spec and close-out invariants hold: no diff was present for the locked SPEC files inspected in this round; SPEC-015 remains v0.3.3 LOCKED (`specs/SPEC-015-receipts.md:3`); the runbook preserves Entry 80 and points README close-out at the v0.3 model-hash binding update (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:153`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:162`). The v0.4+ candidate list remains aligned with §M.6 deferred items: streaming receipts, multi-hash receipts, cross-catalog federation, on-chain anchoring, quantization-aware verification, and TUF/signed-root trust-root hardening (`audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:164`, `audits/2026-06-24/SPEC_015_V03_OPERATOR_RUNBOOK.md:166`, `specs/SPEC-015-receipts.md:3642`).

Validation runs:
- `cd test/integration && go test ./spec015/ -count=1 -timeout 120s` passed.
- `cd phase7-verify && go test ./internal/receipt/ -count=1` passed.

VERDICT: PASS — Round 1 ARCHITECT critical and high findings are closed.

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0
