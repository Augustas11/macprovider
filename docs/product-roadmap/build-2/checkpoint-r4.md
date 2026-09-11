# Product Build 2 planning checkpoint

**Checkpoint revision:** R4
**Status:** R4 correction authored; implementation has not started and remains prohibited pending a fresh independent GPT-5.6 Sol gate with zero Critical, High and Medium findings
**MacProvider branch/head before this checkpoint:** `codex/product-build-2` / `a2bbfbc12632cf0c89e449c4db66cdeb82ee8f9a`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, fetched 2026-09-11)
**Malibu inspected base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`origin/main`, fetched and inspected read-only 2026-09-11)

## Exact artifacts submitted to the next gate

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r4.md` | `e5b4cb2c8e4331592f74584fa786fee03aaa491338c4da6fb2bde14ca6634ea2` |
| `test-spec-r4.md` | `5ea48c45e856501876c0788709a67a7dbcbbbc81c0709265ef4f12cc5e5fd929` |
| `finding-dispositions-r4.md` | `bdd69d39d3df16c5dd364ccffdf5fc79b02b0029fe230e84df7266b09dae2e5d` |
| `baseline-assessment-r2.md` | `17abe6f546816929eda655cda7809eb0aa57fad3779c07ea25a2398949f0c3d3` |
| failed predecessor `reviews/plan-r3-sol.md` | `4a2148bce95b74f8f5ad856edf66637d4fa95811fd4c25439a638fe528a924e7` |

Any byte change to the three submitted R4 artifacts invalidates these hashes and requires a new checkpoint/gate input.

## R4 correction scope

R4 retains the accepted Build 2 selection, double-collect, trust bootstrap, refund-proof, wallet-status, no-failover, ordinary-settlement and evidence-boundary contracts. It resolves the ten R3 findings with:

- a complete durable pending profile target, explicit active/revoked state binding, pre-call/send disposition, local-evidence-only recovery, and signed post-revoke watermark upgrade;
- a versioned compaction pointer/manifest/checkpoint with immutable bases, append tails, per-key head witnesses, exact framing and deterministic filesystem/IndexedDB crash recovery;
- separate server wire errors and client journal-derived actions plus exhaustive legacy-runtime mapping;
- scan-epoch recovery ordering, one aggregate persistence transaction and an explicit 255-second last-first-call bound;
- fixed revoke operation/audit slots preallocated at profile creation and disjoint recovery quarantine slots;
- one Go lock and exact feasible old/new descriptor rules around rename;
- a profile-mode UUIDv4 request-ID constraint while preserving headerless legacy printable IDs;
- signed, challenge-bound, monotonic, short-lived revocation preflight state;
- reachable 2,048-head operation/audit capacities with physical SQLite page/index/WAL accounting;
- an executable no-new-dependency Safari/Chrome harness using browser-provided WebDriver/CDP and owned crash controls.

Exact per-finding corrections and proof obligations are recorded in `finding-dispositions-r4.md`.

## Repository evidence refreshed

- MacProvider plan/source evidence remains pinned to the stated base; R4 made documentation changes only.
- Malibu `origin/main` remains `dc7f425ba7d50c86467f31a82f419df6a0904b13`. Its canonical checkout is behind two commits with unrelated `.omc/` and `social/` clutter and was not modified.
- Malibu exposes no browser-test package/command. The current host inventory is Node `v22.23.2`, Safari `26.5` plus `/usr/bin/safaridriver`, Chrome `152.0.7977.85`, and no `chromedriver`.
- No d-inference source or operator secret was inspected.

## Verification performed for this docs-only revision

- `git diff --check` passed.
- The artifact hashes above were computed from the exact files.
- Targeted searches removed the failed 3,968/7,936 capacity contract, shared revoke/recovery emergency partition, universal post-rename descriptor equality, 285-second incomplete recovery formula, action-bearing server wire object, and unstated profile-mode request-ID narrowing.
- No Go, Swift, Node, browser, fixture, MLX, deployed-service or production test was run or claimed. Host browser inventory is not browser acceptance evidence.

## Resumption sequence

1. Give a fresh independent native GPT-5.6 Sol reviewer the exact hashed artifacts, failed R3 review, baseline and both repository revisions.
2. Require structured severity/evidence/consequence/required-correction findings and independent code inspection. Any Critical/High/Medium finding requires R5; do not implement R4.
3. Only after a zero gate, implement Slice 0 normative specs, manifests and shared vectors before runtime changes.
4. Keep MacProvider and Malibu implementation in separate fresh worktrees/branches and identify dependent versus cumulative diffs.
5. Keep browser execution, actual MLX hardware, production bundle/revocation/evidence signer provisioning, deployed services and production qualification as separate evidence gates.

## Blockers and non-claims

R4 has not passed independent review. No runtime/profile/journal/revocation/browser harness implementation exists from this lane. No production signer was created or accessed. No deployment, release, production activation, reward/payout, verified private settlement, Trusted Pool, epoch or payment work is authorized or claimed.
