# Product Build 2 planning checkpoint

**Checkpoint revision:** R2
**Status:** plan correction authored; implementation has not started and remains prohibited pending a fresh independent GPT-5.6 Sol gate with zero Critical, High, and Medium findings
**MacProvider branch/head before this checkpoint commit:** `codex/product-build-2` / `009073af5fd7bceb544ef28a41d1c474be1161f2`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, fetched 2026-09-11)
**Malibu inspected base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13` (`origin/main`, fetched 2026-09-11)

## Exact artifacts submitted to the next gate

| Artifact | SHA-256 |
|---|---|
| `baseline-assessment-r2.md` | `17abe6f546816929eda655cda7809eb0aa57fad3779c07ea25a2398949f0c3d3` |
| `prd-implementation-plan-r2.md` | `b08d9c8e4b38225c21ad96c22266f9ac818ae59cd8ee7e90f775e027b949b5ce` |
| `test-spec-r2.md` | `82368bc0b8fd35d256dcbdd2727b1e0f0a155134a12f076cd4329c2f79c2ceeb` |
| failed predecessor review `reviews/plan-r1-sol.md` | `a0e377960943cac3cdfb17a9d61e49d72f8a1f1d03b3575050dcc9dda623ca49` |

Any byte change invalidates these hashes and requires a new checkpoint/gate input.

## What R2 changes

R2 keeps every R1 requested outcome and closes the submitted design gaps without weakening acceptance:

- v2 recovery status treats a never-consumed reservation as envelope-unbound and does not pretend to verify an unavailable digest;
- exact cross-Go/Swift/JavaScript ASCII/binary framing, safe JSON-number grammar, domains, field order, array framing, and route schemas replace future implementation choices;
- a dedicated release-baked signer verifies offline-signed public provider bundles, while account-scoped invitations bind the supported initial provisioning flow without coordinator profile-read TOFU;
- an epoch/generation double-collect protocol intersects at most 16 operator-mapped approved providers with SQLite profile/key authority, names D/P phases and linearization, and prohibits overlapping pool/DB/network locks;
- consume/final arm specify exact lifecycle barriers and conservative uncertainty after dispatch authorization;
- gateway quota/session admission atomically creates a recoverable join, dispatch intent arms all economic state together, and only authenticated coordinator rejection with dispatch proven absent permits exactly-once refund;
- coordinator evidence retention, gateway scan bounds/convergence, stale-held behavior, and fail-closed configuration inequalities are exact;
- Go and browser journals use monotonic pre-send fencing, no takeover, exact crash/corruption/cap behavior, and cross-process/tab ownership through flock or IndexedDB/Web Locks;
- wallet reservation headers and v2 status route/body/Accept/request-ID replay semantics are exact.

## Code and repository evidence inspected

- coordinator relay-blind closed types, pin validation, `math.MaxInt64` internal pin, SQLite state/consume/arm/status, buyer provider selection, and pool mutex/snapshot/mutation surfaces;
- gateway reservation/consume/quota/wallet-arm/settlement-hold/reconciliation paths, SQLite relay-blind accounting, config retention/batch limits, and SPEC-040 semantic-header profiles;
- SPEC-041 current six-field reservation, v1 response/status, lifecycle, no-failover, accounting, and error contracts plus SPEC-006/SPEC-040 mappings;
- Malibu `origin/main` AGENTS/CLAUDE guidance, `console/api.js` ordinary 502/503 retry and localStorage use, current console mode/settings surface, package scripts/tests, and public security copy.

The Malibu canonical checkout was not modified because it is two commits behind its fetched origin and contains unrelated untracked `.omc/` and `social/`. The R2 plan uses a future fresh isolated Malibu branch after the MacProvider contract gate.

## Verification performed for this docs-only correction

- `git fetch --prune origin` in both repositories confirmed the revisions above.
- `git diff --check` passed for the R2 documentation.
- SHA-256 values were computed from the exact files recorded above.
- No runtime, fixture, browser, Swift, MLX, deployed-service, or production test was run or claimed for R2 plan authorship.

## Resumption sequence

1. Give an independent native GPT-5.6 Sol reviewer the exact three R2 artifacts/hashes, failed R1 review, both repository revisions, and full Build 2 mission.
2. Require structured severity/evidence/consequence/correction findings. If any Critical/High/Medium remains, author R3 and repeat; do not implement R2.
3. Only after a zero gate, implement Slice 0 normative specs/vectors before runtime work.
4. Keep MacProvider and Malibu changes in separate fresh worktrees/branches and report dependent/cumulative diffs explicitly.
5. Preserve actual MLX, browser, operator signer/publication, deployed-service, and production qualification as separate evidence gates.

## Blockers and non-claims

R2 has not passed independent review. No production bundle signing key was created or accessed. No invitation/bundle/profile route, selection binding, recovery join, library, CLI, Malibu UI, or MLX journey is implemented by these docs. Deployment, release, production activation, rewards/payouts, verified private settlement, Trusted Pools, and epoch/payment work remain outside this checkpoint.
