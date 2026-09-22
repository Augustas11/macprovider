# Build 1 Session Handoff - 2026-09-22

This handoff preserves the Build 1 Lane A state before a local Mac restart.
It is a control note, not Build 1 completion evidence.

## Repository State

- Canonical checkout: `/Users/augstar/macprovider-poc`
- Main at handoff: `c7bb5596` (`origin/main`)
- Recently merged Pearl/coordinator fixes on main include:
  - `32c78fe1` / PR #1667: admission binding survives transient refresh failure.
  - `1c2d54bd` / PR #1671: unsettled legs no longer require settlement receipts.
  - `21276982` / PR #1670: slot reservation drops once the Mac accepts the chat.
  - `c7bb5596` / PR #1668: #1616 recovery-hardening gaps.
- No merge or deploy was in progress when this handoff was written.

## Build 1 Lane A Truth

- Tracker: #1642 is open.
- Execution PR: #1658 is open at `9f75fd2042a7de7fac44bab956fb0697c2b789a1`
  on `feat/build1-lane-a-private-prep-record`.
- PR #1658 is not mergeable at handoff:
  - GitHub reports `mergeStateStatus=DIRTY`.
  - Review is still required.
  - The stale check rollup still includes a failing `spec-index / check`.
- Do not merge #1658 until the full Lane A physical staging stop condition is
  met, full-PR audits and CI are green, and the owner explicitly greenlights
  the merge.

## BYOM Acceptance Correction

The existing #1642 tracker body names
`meta-llama/llama-3.2-3b-instruct` / `mlx-community/Llama-3.2-3B-Instruct-4bit`
as the Lane A tuple. That tuple is already catalog-like and may be useful as a
plumbing control, but it must not be treated as the final Build 1 BYOM product
proof.

Build 1 should require a non-catalog/private BYOM tuple for acceptance evidence:

- prepared from signed measured artifact authority;
- served on physical Apple Silicon;
- admitted through the intended staging coordinator path;
- routed through staging gateway;
- correlated to provider receipt/audit evidence;
- verified through settlement output;
- with production activation, rewards, payout, public earnings claims, and paid
  provider qualification still disabled unless separately authorized.

## Recommended Resume Path

1. Start from a fresh hidden worktree under
   `/Users/augstar/.codex/worktrees/macprovider/` after `git fetch origin`.
2. Re-check PR #1658 and issue #1642 before editing:
   - `gh pr view 1658 --json title,state,isDraft,mergeStateStatus,reviewDecision,statusCheckRollup,headRefOid`
   - `gh issue view 1642 --json title,state,body,comments`
3. Update the tracker/PR language so Llama 3.2 is explicitly a plumbing
   control only, and the final BYOM proof uses a non-catalog/private tuple.
4. Rebase or rebuild #1658 on current `origin/main` only after resolving the
   acceptance tuple wording.
5. Continue the physical Lane A journey against the real network. Do not use a
   local coordinator/gateway as the primary proof unless current deployed Pearl
   binaries are shown not to contain the required BYOM path and the operator
   explicitly accepts local staging as a Build 1 e2e substitute.

## Pearl And Mac Studio Guardrails

- Use the protected Pearl runtime release/updater path for production Pearl
  changes. Do not unsigned-swap coordinator or gateway binaries.
- For physical proof, use Mac Studio on a separate lab/provider port when
  needed; do not disturb live `8080` / `live.malibu.provider` without a new
  operator gate.
- Continuous batching remains guarded by Build 5 issue #1646:
  - Studio signed v1.8.176 canary evidence exists, but fleet promotion is not
    complete.
  - Do not set CB to `on`.
  - Do not promote the fleet off 1.8.123.
  - Do not raise slots or enable KV disk cache unless the relevant Build 5
    blockers are explicitly closed.

## Local Files Not Committed

The canonical checkout had these untracked local files at handoff time. They
were left untouched because they appear to be local artifacts or separate
session prompts/reports, not Build 1 authority for this commit:

- `.playwright-mcp/`
- `audits/_prompts/RUN_1670_PEARL_APPLY_SLOTS_E2E_OPENROUTER.md`
- `docs/reports/2026-09-22-macstudio-throughput-status-ux-bug.md`
- `host-download-e2e-1604.png`

Inspect them before deleting, moving, or committing them.

## Stop Condition

This handoff is complete once this markdown-only commit is pushed or otherwise
made durable. It does not prove Build 1, deploy Pearl, rebase #1658, or run
physical e2e.
