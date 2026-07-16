# Issue #585 implementation and rollout handoff

> **HISTORICAL SNAPSHOT — superseded later the same day (2026-07-15).**
> This document describes the repository and host state at commit `71eb927a`
> (v1.8.39 source) BEFORE the v1.8.40 Phase-1 work on branch
> `fix/585-malibu-bootstrap-bridge`. In particular, the statements that
> v1.8.40 is uncommitted, that the real-model candidate test was skipped,
> that the lifecycle transition fix is unverified, and that lifecycle
> rollback restoration is unimplemented are NO LONGER TRUE on this branch.
> The operative release gate is `RELEASE_GATE_V1_8_40.md` in this directory,
> which preserves and supersedes the "Proposed no-release proof gate" below.

**Date:** 2026-07-15  
**Status:** Work stopped at the user's request. No further release, deployment, installer run, or live mutation is authorized by this handoff.  
**Audience:** Claude/Fable or the next engineer investigating whether the intended end state is achievable without another release-first loop.

## Executive verdict

Issue [#585](https://github.com/Augustas11/macprovider/issues/585) is **not complete**. A substantial lifecycle architecture and acceptance framework has been merged, and the reachable provider is currently healthy on the preserved v1.8.30 CLI. However, the end-user goal has not been achieved:

> Malibu, macprovider-cli, autotune, credentials, identity, catalog, and update behavior must work together so a Mac can be onboarded and remain connected without manual recovery.

The latest immutable release, v1.8.39, did not install successfully on the reachable provider. Its installer reached the real autotune candidate and exposed a lifecycle state-machine defect. Rollback worked and preserved the provider, token, model, configuration, and service availability. That is an important safety result, but it is not functional completion.

An uncommitted v1.8.40 hotfix exists in an isolated worktree and passes its current automated tests. It is **not sufficient to declare Issue #585 fixed** because:

1. it has not passed the required final audit loop;
2. it has not been physically installed and verified;
3. it does not fix a newly discovered stale lifecycle-state defect after rollback;
4. the frozen v1.8.39 Malibu bridge cannot automatically deliver a later CLI installer to already stranded legacy hosts; and
5. the second physical Mac is unreachable from this machine, so the required two-provider acceptance matrix cannot be completed here.

The repeated releases happened because integration defects were being discovered only after immutable publication on the real Mac. Tests proved individual components and rollback safety, but did not prove the exact signed app + installer + coordinator + real model + launchd + lifecycle path before each release. The validation order was therefore wrong for this system.

The next owner should first decide what recovery capability is actually required for the legacy v1.8.32 cohort. No additional release should be published until an exact signed release candidate has passed the full real-Mac transition offline, including failure and rollback cases.

## Stop boundary

At the time this handoff was written:

- no build, release, tag, PR, merge, deployment, or installer was in progress;
- the failed Pearl updater transaction had finished and rolled back cleanly;
- the reachable provider was running its previous v1.8.30 CLI and was coordinator-connected;
- no files, credentials, models, provider identity, or installation were deleted;
- the v1.8.40 changes remained uncommitted in the isolated worktree;
- no attempt was made to alter the unreachable second Mac; and
- no manual deletion of the stale lifecycle file was performed.

Do not interpret this document as authorization to publish v1.8.40 or mutate production. Its purpose is to preserve evidence and prevent the next investigation from repeating the same release-first sequence.

## Desired outcome versus current outcome

| Area | Required outcome | Current verified outcome |
|---|---|---|
| Malibu | Accurate read-only view of CLI-owned lifecycle and working repair/update transaction | Reachable Mac runs Malibu 1.8.39, but it displays a misleading Sync/rollback state after a completed rollback |
| CLI | Current signed CLI installs, starts under launchd, autotunes, joins coordinator, and survives restart | Reachable Mac remains healthy on restored CLI 1.8.30; v1.8.39 failed before cutover |
| Autotune | Candidate uses installed model and reaches the intended ready/degraded state within admission deadline | v1.8.39 candidate exited on an invalid lifecycle transition after the model became ready |
| Credentials/auth | CLI owns Keychain/token use and retains stable provider identity | Existing reachable provider retained its token and identity through rollback; clean onboarding was not re-proved end to end |
| Catalog | Signed catalog and demand rank pass trust/admission checks across backend and provider | Backend-first v1.8.39 handoff resolved the initial catalog rejection; the next lifecycle defect then blocked installation |
| Updates | Exact signed compatibility set rolls forward or rolls back without manual repair | Rollback is safe, but rollout did not complete and legacy app authority cannot automatically rescue the stranded cohort with a later CLI |
| Two-provider network | Both physical Macs pass install, restart, reboot, interruption, rollback, and soak acceptance | Coordinator reports two providers ready, but only one Mac is physically reachable and neither was verified on v1.8.39 CLI |
| Issue #585 acceptance | Full matrix plus 24-hour soak | Not run to completion |

## Current live state

### Pearl coordinator/backend

The v1.8.39 updater transaction ended at `2026-07-15T17:33:53Z` with:

- outcome: `rolled_back`
- rollback error: empty
- deadman error: empty
- no active transaction journal remaining

The current public health response after rollback was:

```json
{"status":"ok","pool_size":2,"pool_ready":2,"pool_policy_ready":2,"version":"v1.8.30","recommended_binary_version":"1.8.30"}
```

The release pointer was restored to:

- tag: `v1.8.30`
- commit: `15da2a533c1a540f16c4b0e286deda55d6cf6e7f`

### Reachable Mac

- Malibu: `/Applications/Malibu.app`, version 1.8.39
- active CLI: `/Users/augstar/macprovider/macprovider-cli`, version 1.8.30
- launchd service: `live.streamvc.macprovider`, running at the final check
- local health: ready
- model: Qwen3-Coder-30B loaded
- coordinator: connected
- provider ID: `mac`
- compatibility-set ID: absent because the restored CLI is legacy
- config permissions: `0600`
- config SHA-256 remained unchanged: `7364112a62250ba3d48a484232e5a8cd26467b72b4f46cda4bc2350944c647ee`
- health counters at the final check: restart count 132, errors total 273

The high counters are historical signals and were not reset. The final health/readiness checks, not the counters alone, establish that the incumbent provider was restored.

### Second Mac

The second physical Mac could not be reached from this machine. Malibu on that Mac was reported as version 1.8.32 and up to date, while its UI reported that the provider was not connected to the coordinator and that CLI v1.8.30 had v1.8.38 available. No physical state, installer behavior, Keychain state, or upgrade outcome was independently verified there during the final session.

Coordinator pool readiness is not a substitute for physical acceptance of that host.

## What is already merged and shipped

The implementation is not zero. Issue #585 produced a large architecture and acceptance body, including these merged PRs:

- [#589 — Make provider lifecycle recover as one signed system](https://github.com/Augustas11/macprovider/pull/589)
- [#593 — Protect Issue 585 acceptance signing behind main-owned workflow](https://github.com/Augustas11/macprovider/pull/593)
- [#595 — Keep acceptance version checks reliable under pipefail](https://github.com/Augustas11/macprovider/pull/595)
- [#596 — Bind acceptance ledger checks to reviewed main control](https://github.com/Augustas11/macprovider/pull/596)
- [#597 — Keep acceptance Malibu builds compatible with dependency-free candidates](https://github.com/Augustas11/macprovider/pull/597)
- [#598 — Keep dependency-free acceptance builds valid on macOS Bash](https://github.com/Augustas11/macprovider/pull/598)
- [#599 — Keep acceptance signing in an owned user keychain](https://github.com/Augustas11/macprovider/pull/599)
- [#601 — Make acceptance verification main-owned](https://github.com/Augustas11/macprovider/pull/601)
- [#602 — Make v1.8.35 activation durable and rollback-safe](https://github.com/Augustas11/macprovider/pull/602)

The selected architecture was Issue #585 Option 2:

- launchd and the CLI own the provider process;
- the CLI owns credentials, identity, update transactions, and lifecycle state;
- Malibu is a read-only client and invokes CLI-owned transactions rather than independently owning the process or secrets.

This direction remains coherent. The failure was not that the architecture had no useful implementation; the failure was treating incremental implementation and safety proofs as if they proved the complete physical upgrade path.

## Release chronology and what each iteration exposed

| Version | Intended increment | Physical/operational result |
|---|---|---|
| 1.8.30 | Known-working containment baseline | Remains the working CLI on the reachable Mac |
| 1.8.32 | Earlier signed update | Failed catalog admission and rolled back; exposed catalog compatibility problems |
| 1.8.33 | Broad lifecycle, credential, identity, and acceptance implementation | Added the main Option 2 implementation and physical acceptance tooling, but did not close the real rollout |
| 1.8.34 | Signed-release boundary and acceptance follow-up | Needed after a burned tag/release-boundary problem |
| 1.8.35 | Durable activation and rollback proof | Improved transaction safety and activation durability |
| 1.8.36 | Private acceptance deployability and canary runtime access | Rollout remained blocked by runtime/sandbox/canary access and model acquisition behavior |
| 1.8.37 | Prefetch exact installed model before cutover | Avoided attempting a large fresh model acquisition during the critical upgrade window |
| 1.8.38 | Skip redundant startup inference measurement for the candidate | Allowed the autotune candidate to bind before its readiness deadline; also adjusted canary gate runtime access |
| 1.8.39 | Canonical signed rollback plan plus one-time Malibu 1.8.32 Sparkle bridge | Release publication succeeded, catalog handoff succeeded, but the real candidate hit a lifecycle state-machine defect and rolled back |
| 1.8.40 | Proposed lifecycle transition hotfix | Uncommitted, partially tested, not audited, not released, and does not address stale lifecycle restoration |

The sequence from 1.8.32 through 1.8.39 was therefore not eight independent product releases delivering user-visible progress. It was a serial discovery process across tightly coupled release boundaries. Each release repaired the immediately observed blocker and then exposed the next untested contract.

## Immutable v1.8.39 release facts

The stable v1.8.39 release is already public and immutable:

- [release page](https://github.com/Augustas11/macprovider/releases/tag/v1.8.39)
- GitHub release ID: `354589320`
- release workflow run: `29433600318`
- source commit: `71eb927a56011f00143b2989cb2bc455b86d4d7c`
- signed tag object: `d3e17540be411d56dedd3cae2a6e1d4da2ead6fe`
- DMG SHA-256: `28416bada6f4be09f0ceea16af62e6faf96df4b3d7e737d06a7ec449b322093d`
- appcast SHA-256: `94ecf57584a2a203336d3219ea42dec1945bae2e123cfce0b1b39f8e0231d83c`
- publication ID: `0f787704513e010952bd85dd6cc83d95c75bca5904c4cab35907fc6745a22c8f`

Do not delete, retag, replace, or mutate v1.8.39. Its contents and hashes are now part of the update trust history.

v1.8.39 is a deliberately frozen, one-time Sparkle bridge for Malibu 1.8.32. This creates an important recovery constraint:

- Malibu 1.8.32 can Sparkle-hop to Malibu 1.8.39.
- Malibu 1.8.39 has no continuing Sparkle feed/runtime.
- Its legacy repair action pins the full installer to v1.8.39.
- The immutable v1.8.39 installer fails on the observed stale-autotune lifecycle path.
- Publishing v1.8.40 alone would therefore **not** give an already-upgraded 1.8.39 Malibu host a zero-touch path to the v1.8.40 CLI.

That is the central product decision the next investigation must confront.

## Final v1.8.39 rollout attempt

### Attempt 1: backend trust was not handed off first

The first v1.8.39 installer attempt failed safely with:

```text
catalog_trust_blocked: candidate_catalog_update_required, demand_rank_update_required
```

Pearl still served July 7 catalog material while v1.8.39 embedded signed July 10 catalogs. The installer correctly refused to cut over, and the incumbent provider remained running.

### Backend-first handoff

The Pearl updater was then allowed to apply the compatible backend catalog and demand-rank state. It reached `provider_install_ready` at `2026-07-15T17:17:39Z`.

This proved that the earlier catalog failure was a deployment-order problem, not the final blocking defect.

### Attempt 2: exact v1.8.39 installer

On the retry:

- checksum signature verification passed;
- package notarization, Gatekeeper, and stapling checks passed;
- catalog validation passed;
- the installed Qwen model artifact was found/prefetched and verified;
- the autotune candidate was launched; and
- the candidate exited on:

```text
invalid lifecycle transition from loading_model to degraded_serving
```

The installer restored the previous provider. Pearl waited 900 seconds for exact provider proof, timed out at `2026-07-15T17:32:39Z`, and rolled the backend back cleanly.

### Root cause of the candidate exit

`CandidateProviderRunner` invokes the candidate as:

```text
serve --no-join --autotune-candidate
```

During that path:

1. `serve` writes `loading_model`;
2. the no-join HTTP-ready state is intentionally represented as `degraded_serving`; but
3. `ProviderLifecycleState.swift` did not allow `loading_model -> degraded_serving`.

An adjacent startup path also needed `loading_model -> paused_by_operator` when restoring a durable operator pause, with `operator_command` as the writer.

This is a lifecycle-graph defect. It is not evidence that the Qwen model was too slow, that autotune itself failed, or that the provider lacked resources.

## Newly discovered defect: rollback leaves Malibu in a false Sync state

After the transaction had fully rolled back and the provider was healthy, the lifecycle file still contained:

```json
{"state":"rollback_in_progress","reason_code":"install_admission_failed","writer":"installer","operation_id":"install:39638","sequence":183,"transition_at":"2026-07-15T17:20:39.777Z"}
```

File:

```text
~/Library/Application Support/macprovider/lifecycle/state-v1.json
```

The installer function `rollback_install_transaction()` writes `rollback_in_progress` with reason `install_admission_failed`. Recovery restores the incumbent provider but does not restore the previous lifecycle file, restore the fact that it was previously absent, or write a terminal restored state.

The restored CLI is v1.8.30, which predates the lifecycle-state contract and cannot clear the newer file. Malibu 1.8.39 reads `rollback_in_progress` and presents “Rollback in progress” / “No action required while this completes.” This explains the user-visible Sync state even though local health and coordinator connectivity are good.

The safe product fix is to make lifecycle state part of the installer transaction:

- snapshot the prior file contents and metadata, or record that the file was absent;
- write transactional intermediate states;
- on rollback, restore the exact prior contents or prior absence atomically; and
- cover successful rollback, interrupted rollback, and old-incumbent compatibility in regression tests.

Do not treat manually deleting the lifecycle file as the product fix. It would remove the symptom on one machine without correcting transaction semantics and could discard useful state on a different failure path.

## Uncommitted v1.8.40 work

### Location and base

- isolated worktree: `/Users/augstar/macprovider-malibu-bootstrap-bridge`
- branch: `fix/585-malibu-bootstrap-bridge`
- worktree HEAD/base: `71eb927a56011f00143b2989cb2bc455b86d4d7c`
- upstream at the final check: `origin/main`

No v1.8.40 commit, PR, tag, release, or deployment exists.

### Modified files

```text
beta/DECISION_CRITERIA.md
phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
phase3-binary/Sources/macprovider-cli/ProviderLifecycleState.swift
phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift
phase3-binary/Tests/macprovider-cliTests/ProviderLifecycleStateTests.swift
phase3-binary/app/project.yml
phase3-binary/app/release-builds.tsv
phase4-coordinator/coordinator.yaml.example
phase4-coordinator/dist/coordinator.yaml
phase4-coordinator/dist/coordinator.yaml.example
```

At the final check the diff contained 104 insertions and 14 deletions.

### Intended changes

- allow `loading_model -> degraded_serving`;
- allow `loading_model -> paused_by_operator`;
- use the `operator_command` writer when startup restores a durable pause;
- add lifecycle regression tests for both transitions;
- bump CLI, app, release ledger, and coordinator-advertised version to 1.8.40; and
- append decision-log evidence/rationale entries 157 and 158.

### What this patch does not do

- It does not transactionally restore the lifecycle file after installer rollback.
- It does not provide v1.8.39 Malibu with authority to fetch or invoke a v1.8.40 CLI installer.
- It does not prove a clean onboarding path.
- It does not prove the exact signed, notarized physical upgrade.
- It does not cover the unreachable second Mac.
- It has not passed the repository-required final three-lane code/security/architecture audit after all edits.
- Xcode/Malibu app tests were not rerun after the hotfix.

The next owner should review the diff as evidence, not inherit the version bump or release intent as a foregone conclusion. It may be better to revert the version-only changes temporarily, widen the lifecycle transaction fix, and build a non-published signed acceptance candidate first.

## Verification already performed on the uncommitted patch

- Full Swift suite before the final version bump: 1,355 tests passed, exit 0.
- Targeted post-bump Swift suite: 64 tests passed, 0 failures; one opt-in real-model test skipped.
- Targeted suites included lifecycle state, serve command, candidate runner, and version handshake coverage.
- `bash scripts/test-coordinator-advertised-version.sh v1.8.40`: passed.
- `git diff --check`: passed.
- `make test-dist`: completed with exit 0.

`make test-dist` intentionally exercises simulated rollback faults, so its log contains error-looking fixture output. The final exit code and named suite results passed; those fixture messages are not evidence of another live failure.

The most important gap is that the opt-in real candidate lifecycle was skipped. The exact behavior that failed physically was therefore still not exercised by the required pre-release test path.

## Why the plan failed repeatedly

### 1. Validation happened after immutable publication

The system was fixed one observed failure at a time, then a new immutable release was built to discover the next failure on the physical host. That made the release channel function as an integration test harness.

For this architecture, the correct release gate is the reverse: assemble the exact signed candidate set, exercise it on real hardware against a staged backend and real installed model, force rollback/restart/interruption cases, and publish only after the whole transition passes.

### 2. Component tests did not model the exact real transition

Hermetic and stub-based tests covered many individual rules. They did not execute the precise chain:

```text
signed app -> pinned full installer -> signed catalogs -> real model prefetch ->
launchd incumbent handoff -> serve --no-join autotune candidate -> lifecycle state ->
coordinator exact-version proof -> durable activation/rollback -> Malibu projection
```

The lifecycle transition omission was simple in code but invisible until the complete candidate path ran.

### 3. The acceptance system itself was still under construction

Several PRs hardened signing ownership, version checks, ledger control, Bash compatibility, keychain use, and verifier ownership. Those were legitimate controls, but they consumed the implementation sequence before the product path was physically proven.

The presence of acceptance tooling was repeatedly mistaken for completed acceptance.

### 4. Backend, app, CLI, catalog, model, and identity are tightly coupled

Each isolated fix moved execution far enough to expose another hidden cross-component contract:

- catalog date/trust alignment;
- backend-first deployment order;
- model availability inside the admission deadline;
- candidate port/readiness behavior;
- signed rollback-plan canonicalization;
- lifecycle transition legality; and
- lifecycle file restoration after rollback.

The work lacked a single executable compatibility-set specification that exercised all of these together before release.

### 5. Only one physical host was reachable

Issue #585 requires a two-provider lifecycle and interruption matrix plus soak. The second Mac could not be inspected or controlled from the current machine. Coordinator readiness was used as partial evidence, but it cannot validate the second Mac's Malibu version, CLI binary, Keychain state, launchd ownership, local lifecycle file, or update UI.

This should have been treated as an explicit acceptance blocker rather than allowing release iteration to continue as if two-host closure were possible.

### 6. Rollback safety concealed the lack of forward progress

The installer and Pearl updater repeatedly failed safely. That prevented an outage and preserved credentials/models, which is correct. But each safe rollback returned the user to the same v1.8.30 functional state. Engineering evidence increased while user-visible completion remained effectively unchanged.

The project reported safety progress without making equally clear that the primary success condition—successful current-version onboarding and operation—was still at zero.

### 7. The frozen legacy bridge closed its own future rescue path

The security decision to make v1.8.39 a one-time Sparkle bridge and keep ongoing update authority in the CLI reduced app-owned update risk. But once the pinned v1.8.39 full installer failed, the upgraded app had no automatic route to a corrected later CLI.

That tradeoff was not fully resolved before freezing the bridge. The result is an architectural dead end for zero-touch recovery of affected legacy hosts unless update authority is deliberately redesigned.

### 8. Goal and session state became stale

The durable goal metadata still referred to earlier PR #589 / v1.8.33–1.8.34 closure. A later attempt to create a new goal failed because the old goal remained unfinished/blocked. This did not cause the lifecycle code defect, but it contributed to session confusion: “Issue #585 implemented,” “release published,” and “physical goal achieved” were not represented as separate states.

Future tracking should have three explicit gates:

1. implementation merged;
2. exact compatibility-set candidate accepted; and
3. physical two-provider rollout and soak complete.

## What is realistically achievable from here

### Branch A: preserve the frozen bridge and use operator-assisted recovery

Keep the current security boundary. Fix both lifecycle defects, build an independently verified signed installer candidate, and use an explicitly authorized operator/manual path to install it on stranded hosts.

Implications:

- does not require mutating v1.8.39;
- does not silently extend Malibu's update authority;
- can recover the reachable Mac once the candidate is proven;
- cannot be called zero-touch onboarding/update for the legacy cohort; and
- requires physical or remote operator access to the second Mac.

This is the lowest-security-risk recovery branch.

### Branch B: require zero-touch recovery for the legacy cohort

Design a new, narrowly constrained app-owned bridge capable of obtaining or invoking a later signed CLI compatibility set. This conflicts with the current frozen-bridge decisions and increases the authority held by Malibu.

Before implementation, this branch needs an explicit threat model and decision covering:

- who chooses the CLI version;
- how the app authenticates the release and compatibility set;
- downgrade/replay resistance;
- coordinator/backend ordering;
- transaction ownership and rollback;
- how update authority is retired after recovery; and
- whether already-installed Malibu 1.8.39 contains enough code to participate at all.

If Malibu 1.8.39 does not already contain a viable signed invocation surface, a new release cannot retroactively give that capability to an unreachable host without some operator action. That is a hard distribution constraint, not a coding estimate.

### Branch C: wipe and fresh-onboard the two test Macs

The user clarified that these are the first macprovider test machines and that billing/legacy continuity is not required. A clean-room re-onboarding experiment may therefore be a valid test branch—but “delete everything” is not automatically necessary and is not a fix for the product defects.

Before wiping, export or document:

- provider identity and coordinator ownership records;
- Keychain credential labels/ownership, without exposing secret values;
- launchd plist and active binary path;
- config and model inventory;
- lifecycle/update journals; and
- logs needed to reproduce the failure.

Then define what “fresh” means on both backend and Mac. Deleting only local files while retaining the coordinator identity could create a different auth failure. Deleting backend ownership without a documented re-onboarding path could erase the evidence needed to validate Issue #585.

A successful fresh install would prove clean onboarding but would **not** prove upgrade recovery for the v1.8.30/v1.8.32 legacy path. Those should be separate acceptance claims.

## Recommended investigation sequence for Claude/Fable

Do not start by assigning another version number. Resolve these questions first:

1. Is zero-touch recovery of already-installed Malibu 1.8.32/1.8.39 hosts a hard product requirement, or is an operator-assisted signed installer acceptable for this test cohort?
2. Is the v1.8.39 candidate failure unconditional for stale recommendations, or can its immutable installer succeed with a safely generated fresh recommendation without changing release assets?
3. Does Malibu 1.8.39 contain any existing, sufficiently constrained path to invoke a newer CLI-owned updater, or is manual/remote operator access mathematically unavoidable?
4. What is the minimum correct installer transaction boundary? It must include prior lifecycle-file contents **and prior absence**, not only binaries/config/launchd state.
5. How can the exact signed app + installer + catalog + real model + coordinator candidate be tested on a disposable/staged Mac before immutable publication?
6. Which Issue #585 acceptance statements are implemented product behavior, which are only tooling, and which remain physically untested?
7. Should the unreachable second Mac be declared outside the current acceptance scope until remote access is restored, instead of using coordinator pool readiness as a proxy?
8. Should the v1.8.40 version/release edits be discarded until the broader lifecycle transaction fix and real-candidate gate exist?

## Proposed no-release proof gate

Before any v1.8.40 or later publication, require one reproducible candidate run that proves all of the following using the exact prospective release artifacts:

1. Verify signatures, notarization, stapling, release ledger, and compatibility-set identity.
2. Start from the same v1.8.30 CLI and Malibu 1.8.32/1.8.39 states found on the real machines.
3. Exercise backend-first catalog/demand-rank handoff.
4. Use the already-installed real Qwen artifact.
5. Run the exact `serve --no-join --autotune-candidate` path, not a stub.
6. Prove every lifecycle transition and writer contract.
7. Prove launchd incumbent ownership before, during, and after cutover.
8. Force admission failure and prove byte-for-byte restoration of binaries, config, launchd state, credentials, identity, model inventory, and lifecycle file/absence.
9. Prove Malibu reflects the restored healthy state rather than an intermediate transaction state.
10. Prove successful activation, restart, reboot, coordinator reconnect, and durable pause semantics.
11. Repeat on both physical Macs or explicitly limit the claim to one reachable Mac.
12. Complete the required soak before calling Issue #585 complete.

If this gate cannot be run before publication, another immutable release should be considered exploratory rather than a completion release and should not be presented as closing the goal.

## Repository entry point for the next owner

Start read-only:

```bash
cd /Users/augstar/macprovider-malibu-bootstrap-bridge
git status -sb
git diff --stat
git diff
```

Then inspect these areas:

- `phase3-binary/Sources/macprovider-cli/ProviderLifecycleState.swift`
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- `phase3-binary/Tests/macprovider-cliTests/ProviderLifecycleStateTests.swift`
- `phase3-binary/dist/install.sh`, especially `rollback_install_transaction()`
- Malibu lifecycle projection in `AgentSnapshot.swift`
- `phase3-binary/app/release-builds.tsv`
- `beta/DECISION_CRITERIA.md`, especially Issue #585 and release entries 155–158

Do not initially run the installer, Pearl updater, release workflow, tag commands, or destructive cleanup. First decide whether to keep, widen, or discard the uncommitted hotfix and which recovery branch is intended.

## Known evidence gaps

- No final three-lane code/security/architecture audit exists for the complete uncommitted v1.8.40 diff.
- No Xcode/Malibu post-hotfix test was run.
- The opt-in real-model candidate test was skipped.
- No v1.8.40 signed/notarized candidate artifact exists.
- No physical v1.8.40 install was attempted.
- No second-Mac local evidence was collected.
- No reboot or 24-hour soak completed on the intended compatibility set.
- Clean onboarding from an actually wiped test Mac was not performed.
- The stale lifecycle rollback restoration fix has not been implemented or regression-tested.

## Completion assessment

It is not responsible to express Issue #585 as a single high completion percentage. Different layers are at materially different stages:

- architecture and implementation scaffolding: substantial and merged;
- release/acceptance infrastructure: substantial, but developed reactively;
- rollback/data-preservation safety on the reachable Mac: demonstrated;
- exact current-version forward install: failed;
- accurate Malibu state after rollback: failed;
- zero-touch legacy recovery: unresolved by design;
- second-provider physical acceptance: unavailable;
- full Issue #585 matrix and soak: incomplete.

For the user's actual goal—two Macs onboarded and working with Malibu, current CLI, autotune, auth, coordinator connection, and reliable updates—the final result is **not achieved**. The correct next milestone is not “publish v1.8.40.” It is “prove a complete recovery/onboarding route with an exact non-public candidate, or establish that the desired zero-touch route is impossible under the frozen v1.8.39 authority model.”

