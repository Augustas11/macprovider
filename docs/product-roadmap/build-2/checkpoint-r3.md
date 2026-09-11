# Product Build 2 planning checkpoint

**Checkpoint revision:** R3
**Status:** R3 correction authored; implementation has not started and remains prohibited pending a fresh independent GPT-5.6 Sol gate with zero Critical, High, and Medium findings
**MacProvider branch/head before this checkpoint commit:** `codex/product-build-2` / `30c7c3d577b26857db89c45ae4145c248ef0ae35`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, fetched 2026-09-11)
**Malibu inspected base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`origin/main`, fetched and inspected read-only 2026-09-11)

## Exact artifacts submitted to the next gate

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r3.md` | `452a19c87a3dd0dc62a15ee9e6877dbd7d0fce26de4dd92d728fee210aaa98b7` |
| `test-spec-r3.md` | `2e50ed52a935ee3102182f0400d8aedae1be0503148be7f6dd49b8b67afca6b5` |
| `finding-dispositions-r3.md` | `70abf8a8aff4f1168ce6fd3364abfef3080ce5fc048aedb40c6e6f496d3f97db` |
| `baseline-assessment-r2.md` | `17abe6f546816929eda655cda7809eb0aa57fad3779c07ea25a2398949f0c3d3` |
| failed predecessor review `reviews/plan-r2-sol.md` | `c1e327a2ddd0efbe3ed14740cca4111a53cbd3c6c92b279dcab3074ee1e97b4e` |

Any byte change to a submitted R3 artifact invalidates these hashes and requires a new checkpoint/gate input.

## R3 correction scope

R3 retains every Build 2 outcome and the R2 contracts the independent reviewer accepted. It closes the six High and four Medium findings by adding:

- an exact per-schema presence/nullability contract and literal provider-binding locator vectors shared by Go, Swift, and JavaScript;
- a durable account/origin-bound confirmed-profile authority with exact signed-bundle/pin evidence, pending mutation convergence, integrity/generation rules, caps, restart/reload, corruption, rollback, and clearing behavior;
- short-lived challenge-bound Ed25519 coordinator control evidence plus verified production HTTPS as the only refund-authorizing response path;
- exact client journal record/state/locator/MAC/owner semantics and a required descriptor-relative macOS ancestry/device/inode/rename protocol;
- explicit normal/emergency physical capacity partitions and a reachable 128/profile under 512/account reservation limit;
- one fixed monotonic wallet status-authority row created before returning each reservation, avoiding per-poll replay growth while preserving inference replay authority;
- a real 20-worker recovery scheduler contract whose network, database, pass, interpass, cancellation, and 285-second worst-case terms fit the 300-second claim;
- the complete gated Build 2 error code/status/phase/retry/action table and precedence rules.

The exact dispositions and required tests for all ten predecessor findings are in `finding-dispositions-r3.md`.

## Code and repository evidence inspected

- current MacProvider coordinator/gateway relay-blind reservation, consume, status, pool, wallet replay, quota, recovery and config surfaces at the stated base;
- current SPEC-040 replay retention/capacity and signed-route requirements, SPEC-041 relay-blind contracts, and existing gateway representation-byte provider-binding hashing;
- Malibu `origin/main` guidance, `console/api.js` authentication storage, settings/thread local storage, ordinary 502/503 retry transport, console surface, tests and package commands.

The Malibu canonical checkout remains two commits behind its fetched origin with unrelated untracked `.omc/` and `social/`; it was not modified. No d-inference source or operator secrets were inspected.

## Verification performed for this docs-only revision

- `git diff --check` passed for all R3 documentation.
- SHA-256 hashes above were recomputed from the exact submitted files.
- Targeted searches found no stale R2 paired-test reference, old 2,048/profile claim, decoded-binding locator language, or per-poll replay-partition contract in the R3 artifacts.
- No runtime, Go, Swift, Node, browser, fixture, MLX, deployed-service, or production test was run or claimed; R3 is planning only.

## Resumption sequence

1. Give a fresh independent native GPT-5.6 Sol reviewer the exact R3 artifacts/hashes, failed R2 review, baseline, both repository revisions, and full Build 2 mission.
2. Require structured severity/evidence/consequence/correction findings and independent code inspection. Any Critical/High/Medium finding requires R4; do not implement R3.
3. Only after a zero gate, implement Slice 0 normative specs, schema/error manifests, and shared vectors before runtime changes.
4. Keep MacProvider and Malibu changes in separate fresh worktrees/branches and report dependent/cumulative diffs explicitly.
5. Preserve real-browser, actual-MLX hardware, operator evidence-signer/bundle publication, deployed-service, and production qualification as separate gates.

## Blockers and non-claims

R3 has not passed independent review. No coordinator evidence or bundle signing key was created/accessed. No profile/status-authority/recovery/library/CLI/Malibu runtime exists from these docs. Deployment, release, production activation, rewards/payouts, verified private settlement, Trusted Pools, and epoch/payment work remain excluded.
