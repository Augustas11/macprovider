# BUILD PROMPT — Gateway upward-correction symmetric clamp (closes #278)

Run as: `omc ask codex "$(cat specs/BUILD_GATEWAY_UPWARD_CLAMP_PROMPT.md)"`

This is an IMPL build prompt, not a research prompt. Single PR. Same
3-lane audit discipline as #262: code / security / architect. Converge
to 0 CRITICAL/HIGH/MEDIUM in every lane before push. Audit prompts go
in `specs/AUDIT_278_*_PROMPT.md` and are fired via
`omc ask codex` in a loop (per memory:
`feedback-audit-prompts-file-not-chat`,
`feedback-three-lane-codex-audits`).

This fix is a **direct mirror of PR #262 on the opposite branch** —
read PR #262's final landed code first, then write the upward-clamp
twin with the same idioms, same log shape, same test style.

## Scope

Fix issue [#278](https://github.com/Augustas11/macprovider/issues/278).
ONE file changed:
`phase5-gateway/internal/router/chat_proxy.go`. Plus tests in
`phase5-gateway/internal/router/server_test.go`. No SPEC changes
required (the clamp shape was already documented for #262 and the
upward fix is a straightforward symmetric extension within the same
contract — but if your audit lane says SPEC needs touching, surface
the case before changing it).

## The bug, one paragraph

`settleReported` in `chat_proxy.go:520` has two branches: upward
(observed > reported → settle at observed) and downward (reported >
observed → maybe-clamp per the #262 window). #262 fixed the downward
direction by introducing a (2, 20] clamp window. The upward direction
was untouched and still settles at the inflated byte-estimate
unconditionally. Empirical data from v0.4 scenario 07 (full repro in
#278) shows the `ceil(content_bytes / 4)` estimator runs ~7-15% higher
than the provider's authoritative tokenizer on English Qwen3-32B
output. Result: gateway DB overbills by 6-9 tokens per request when
the upward branch fires.

## What to build

In `settleReported` (the function at `chat_proxy.go:520`, NOT every
other `estimateStreamingCompletionTokens` call site):

1. Inside the existing `if observedCompletion > usage.CompletionTokens`
   block, compute `overshoot := observedCompletion - usage.CompletionTokens`.

2. Apply the **same `clampFloorTokens` / `clampCeilingTokens` constants**
   (no new constants — reuse `clampFloorTokens = 2`,
   `clampCeilingTokens = 20` from `chat_proxy.go:1076-1078`).

3. If `clampFloorTokens < overshoot <= clampCeilingTokens`:
   - Settle at `usage.PromptTokens` + `usage.CompletionTokens`
     (the provider's reported count).
   - `token_source = "provider_reported"`.
   - Emit a `slog.Info` log line mirroring the downward-clamp log at
     `chat_proxy.go:545-553` — same field names where applicable, swap
     "over-reported" → "under-reported by provider; gateway estimate
     higher" or similar accurate wording. Include `reported`,
     `observed`, `overshoot`, `window_floor`, `window_ceiling`,
     `request_id`, `account_id`, `outcome`. The event-level field name
     for the log message (the message string itself) is the place to
     make the direction explicit so log search can disambiguate
     upward vs downward clamp fires.
   - Return.

4. Otherwise (overshoot ≤ floor OR overshoot > ceiling): preserve
   current behavior — settle at `observedCompletion` with
   `token_source = "gateway_estimated"`. Comment the rationale inline
   matching the downward-clamp comment at `chat_proxy.go:1055-1063`:
   - `overshoot ≤ 2`: benign tokenizer noise (matches downward floor
     rationale by symmetry).
   - `overshoot > 20`: too large to be tokenizer error — likely a
     stream truncation case where the provider's `usage` chunk
     under-reports what was actually generated (or a zero-report fraud
     pattern). The byte estimator is the right answer here. Trust it.

## What NOT to build

- **Do NOT change the downward clamp** (the existing `overshoot >
  clampFloorTokens && overshoot <= clampCeilingTokens` block at
  `chat_proxy.go:544`). That was #262, audited 0/0/0, working.
- **Do NOT change the byte-to-token constant** (`ceil(n/4)` at
  `chat_proxy.go:1093-1095`). That is a separate question with its own
  failure modes (model-specific calibration, dense-content under-bill
  resurrection). Out of scope for this PR; file as a follow-up if you
  see compelling evidence the constant itself needs revisiting.
- **Do NOT touch other call sites** of `estimateStreamingCompletionTokens`
  (e.g. `chat_proxy.go:612`, `:646`, `:735`, `:761`, `:862`). Those are
  fallback paths for stream-malformed / client-disconnect /
  provider-timeout / no-usage-chunk where the provider report is
  unavailable; the byte estimate is the only signal and remains
  correct. The clamp only applies in `settleReported`, where we have
  BOTH a reported usage block AND a byte-derived estimate.
- **Do NOT widen scope** to non-streaming paths. This bug is streaming-
  only; non-streaming uses the provider's `usage` block directly from
  the response body and doesn't go through the byte estimator.

## Tests

Add these to `phase5-gateway/internal/router/server_test.go`. Follow
the style of the existing `TestStreamingProviderReportedOverbillClampedToObserved`
function (downward clamp test) — same fixture pattern, same DB
assertion helper.

1. `TestStreamingProviderReportedUnderbillClampedToReported` — 12+
   subtests:
   - **Exact match**: bytes/4 == reported, no clamp, settled at reported.
   - **Within floor (overshoot=1, 2)**: trust byte estimate (existing
     behavior — bytes/4 is settled).
   - **In window (overshoot=3, 5, 9, 15, 20)**: clamp to reported,
     `token_source = provider_reported`.
   - **The v0.4 scenario-07 patterns** as concrete fixtures:
     - reported=55, bytes ≈ 256 → ceil=64, overshoot=9 → clamp.
     - reported=33, bytes ≈ 168 → ceil=42, overshoot=9 → clamp.
     - reported=34, bytes ≈ 164 → ceil=41, overshoot=7 → clamp.
     - reported=46, bytes ≈ 208 → ceil=52, overshoot=6 → clamp.
   - **At ceiling (overshoot=20)**: clamp (boundary).
   - **Just above ceiling (overshoot=21)**: trust byte estimate
     (token_source=gateway_estimated) — protects against zero-report
     fraud.
   - **Large overshoot (overshoot=100)**: trust byte estimate (this is
     the stream-truncation case where provider's usage chunk
     genuinely under-reports).

2. `TestClampWindowSymmetric` — verify both directions use the same
   `(clampFloorTokens, clampCeilingTokens]` constants. Pin the
   constants by importing `clampWindow()` if helpful.

3. **Regression test for #262**: confirm all existing downward-clamp
   subtests still pass unchanged.

## Audit prompts (3 lanes, written to specs/)

After IMPL is done, write three audit prompts and fire each via
`omc ask codex`:

- `specs/AUDIT_278_CODE_PROMPT.md` — does the implementation match the
  prompt? Are the constants reused, not duplicated? Are existing call
  sites untouched? Is the log line consistent with the downward-clamp
  log shape? Are tests exhaustive on the window boundaries?
- `specs/AUDIT_278_SECURITY_PROMPT.md` — can a hostile provider exploit
  this to under-bill systematically? (E.g. provider deliberately
  reports `usage.completion_tokens = ceil(bytes/4) - 3` on every
  request to slip just into the clamp window and ride the gateway-
  estimate-minus-3 lower number for every request, defrauding the
  network by 3 tokens × every-request × forever.) Is the (2, 20]
  ceiling tight enough? Compare against the symmetric attack surface
  #262 analyzed.
- `specs/AUDIT_278_ARCHITECT_PROMPT.md` — is the contract preserved?
  Does SPEC-006 §17.7 settlement matrix still hold? Does the
  `token_source` field still distinguish meaningfully between
  `provider_reported` (provider's authoritative count) and
  `gateway_estimated` (gateway's byte-derived count)? Are the two
  branches now symmetric in shape, not just in name?

Run each via `omc ask codex "$(cat specs/AUDIT_278_<LANE>_PROMPT.md)"`.
Fix all CRITICAL / HIGH / MEDIUM findings, re-run that specific lane.
LOW findings can ship if the PR body documents them. Skip-accepted-lane
rule applies: once a lane returns 0 C/H/M and the next fix-pass doesn't
touch that lane's scope, don't re-fire it (per
[[feedback-skip-accepted-audit-lanes]]).

## Verification before push

1. Run `go test ./phase5-gateway/internal/router/...` — green.
2. Grep `git show --stat HEAD` to confirm the new clamp code is
   actually in the diff (per
   [[feedback-verify-commit-content-not-just-message]]).
3. Build and deploy the patched gateway to Pearl (after PR merges).
4. Re-run v0.4 scenario 07 against patched gateway: I1 drift should
   drop to 0 or very small (<5 tokens across the full window). If it
   doesn't, the upward path isn't where the bug actually lives —
   investigate before claiming done.

## PR

Branch: `fix/iss-278-gateway-upward-clamp` (per
[[feedback-always-fresh-worktree-for-code-work]] — fresh worktree off
`origin/main`). Single bundled PR. Title format:
`fix(gateway): symmetric upward clamp for streaming estimator inflation (closes #278)`.

In the PR body include:
- The 4-pair reproduction table from #278.
- Pointer to v0.4 scenario 07 artifact bundle and the gateway DB
  confirmation query.
- 3-lane audit trail summary (R1 findings, R2 deltas, terminal 0/0/0/0
  state).
- Confirmation of the post-merge re-run that the I1 drift went to ~0.

## Auth + merge

- Push routes to Augustas11 automatically (per repo's `.git/config`
  helper).
- After 1 approving review (from antfleet-ops), squash-merge as
  Augustas11: `GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge
  <num> --squash --delete-branch`.
- After merge: `git reset --hard origin/main` on local main per
  [[pr-merge-workflow-rule]].
