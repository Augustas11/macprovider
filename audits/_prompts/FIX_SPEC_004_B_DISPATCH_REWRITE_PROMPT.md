# Fix prompt — SPEC-004 Pillar B: dispatch-time model rewrite (alias → concrete ID)

Operator-paste prompt to fix the Pillar B (model-class aliases) implementation
gap surfaced by a live deploy test on 2026-05-30, and to close the spec gap
that allowed it.

## Background

SPEC-004 v0.2 Pillar B added model-class aliases (e.g. `mlx-fast`,
`mlx-accurate`). The routing picker correctly resolves aliases to a candidate
set of providers (`classForRequest` → filter by `providerMatchesRequest` →
pick by objective). **But the dispatch path forwards the buyer's request
body verbatim to the chosen provider — including the alias in `body.model`.**
The provider doesn't know what `mlx-accurate` means (it loaded
`mlx-community/Qwen2.5-7B-Instruct-4bit`); it rejects; buyer gets 503.

This wasn't caught by:
- The SPEC-004 v0.2 audit (architect / security / code-review parallel pass)
- The SPEC-004 v0.2 focused re-verify
- The 4 Codex internal audit rounds
- Any unit / integration test in `internal/buyer/server_test.go`

Why? Every test using model classes uses inline mock relays that **ignore the
request body's `model` field entirely** — they just return canned responses
regardless of what was sent. Real providers do not.

The bug was caught in ~30s of live exercise (`curl https://api.streamvc.live/v1/chat/completions
-d '{"model":"mlx-accurate", ...}'` returned 503 instead of routing to air5
who serves Qwen-7B). Pillar B was rolled back (`model_classes: {}`) on the
live coord pending this fix.

## What this stream owns

| Layer | From | To |
|---|---|---|
| Spec document | SPEC-004 v0.2 | SPEC-004 v0.3 (clarification + new FR-SR-7a) |
| Coordinator code | dispatch-time model unchanged from request body | rewrite to chosen provider's `ModelID` before forwarding |
| Tests | mocks ignore `body.model` | new test uses real-shaped mock asserting on `body.model` |
| Pearl live config | `model_classes: {}` (rolled back) | re-flip after audit ACCEPT |

---

```
=== BEGIN PROMPT ===

You are fixing a SPEC-004 Pillar B implementation bug + the spec gap that
allowed it. This is a spec-text + Go code + test patch. Single integrated
commit on a fresh branch `fix/spec004-pillar-b-dispatch-rewrite`. Hand off
for an independent code-review audit before merge to main.

## Locked corpus (read; do NOT modify other than the one delta below)
  SPEC-001 v1.2.4 — provider WS protocol (LOCKED; no wire change)
  SPEC-002 v1.3.3 — coordinator request router (LOCKED in this stream)
  SPEC-003 v0.7   — open onboarding (LOCKED)
  SPEC-004 v0.2   — smart router (YOU PATCH this to v0.3 — single addition + version bump)
  SPEC-006 v0.8.1 — buyer API gateway (LOCKED in this stream)

## Required reading

1. `specs/SPEC-004-smart-router.md` — esp. FR-SR-7 (model-class alias
   resolution), FR-SR-8 (objectives), AC-SR-5/6 (class routing acceptance).
2. `phase4-coordinator/internal/buyer/server.go`:
   - `classForRequest` (~line 1374): resolves alias to ModelClassConfig
   - `providerMatchesRequest` (~line 1383): how a provider matches an alias
     (matches if its ModelID is in class.Models OR class.Members)
   - `selectProviderExcluding` (~line 1270): the picker that calls the
     above + returns a chosen `pool.Provider`
   - The dispatch paths that consume the chosen provider:
     * WS-tunneled streaming (~line 470)
     * WS-tunneled non-streaming (~line 570)
     * HTTP-forwarded (~line 660 and ~line 950 for streaming)
   - The `req.raw` byte buffer captured at `~line 1051` (`req.raw = append(req.raw, body...)`) — this is what gets forwarded
3. `phase4-coordinator/internal/buyer/server_test.go` — esp.
   `TestStickyAffinityDoesNotOverrideOutsideObjectiveEpsilon` (~line 642)
   for the WithRoutingConfig + ModelClassConfig harness pattern, and
   `TestChatCompletionsRoutesModelClassByObjective` for the existing
   (mock-only) Pillar B coverage that DID NOT catch this bug.
4. `beta/DECISION_CRITERIA.md` Entry 34 — bug surface notes from the live
   2026-05-30 deploy.

## Mandatory normative + code changes

### S-1. SPEC-004 v0.2 → v0.3: add **FR-SR-7a Dispatch-time model rewrite**

Bump the version header to v0.3 and add a changelog entry citing this
audit-driven fix. After FR-SR-7's existing text, add:

> **FR-SR-7a. Dispatch-time model field rewrite.** When a model-class alias
> resolves to a chosen provider (FR-SR-7 + FR-SR-8 selection), the coordinator
> MUST rewrite the `model` field of the request body forwarded to the
> provider from the buyer-supplied alias to the chosen provider's actual
> `pool.Provider.ModelID`. The provider never sees the alias — only concrete
> model IDs it has loaded. This MUST apply to every dispatch path (WS-tunneled
> streaming, WS-tunneled non-streaming, HTTP-forwarded streaming,
> HTTP-forwarded non-streaming). Exact concrete model ID requests are
> identity-rewritten (no-op when `req.Model == provider.ModelID`). The
> rewrite MUST preserve all other body fields verbatim (messages,
> max_tokens, temperature, stream, tools, anything else). It MUST happen
> AFTER selection (so failover/retry attempts to a different provider get
> the new chosen provider's concrete ID), NOT once at request entry.
>
> Test discipline: any test verifying class-alias routing MUST assert on
> the exact `model` field in the body delivered to the provider — not just
> the chosen provider identity. Inline mock relays that ignore the body
> field MUST NOT be the sole coverage. (See 2026-05-30 audit-gap notes.)

That last paragraph is normative; SPEC-002's audit-category-I anti-pattern
("test where the gate is in its closed state must exist") is the spirit
this enforces.

### C-1. Code fix in `phase4-coordinator/internal/buyer/server.go`

Implement the rewrite at the dispatch boundary. The simplest correct
implementation:

1. After `selectProvider` / `selectProviderExcluding` returns a chosen
   `pool.Provider`, in every dispatch path (4 sites above), check whether
   `req.Model != provider.ModelID`. If they differ (i.e. a class alias was
   used), rewrite the JSON body's `model` field to `provider.ModelID`
   before forwarding.

2. Implementation choice (executor picks; both acceptable):
   - **Option A (recommended): re-marshal from `req` struct.** Set
     `req.Model = provider.ModelID`, then `json.Marshal(req)` produces a
     fresh body. CON: must ensure `chatRequest` struct preserves all
     buyer-supplied fields (tools, response_format, etc.); may need to
     unmarshal into `map[string]any` instead to preserve unknowns.
   - **Option B: targeted JSON patch on `req.raw`.** Use `gjson`/`sjson`
     or `encoding/json` to mutate just the `model` field while preserving
     all other bytes. CON: more code; PRO: guaranteed no buyer-field loss.

3. Whichever option: the rewrite MUST be idempotent — calling it twice with
   the same provider yields the same bytes. And it MUST NOT mutate `req.raw`
   in place (failover/retry to a different provider needs a fresh rewrite
   off the original body, not a re-rewrite of an already-rewritten body).

4. **DO NOT** rewrite at the picker layer (`selectProviderExcluding`) —
   that breaks the picker's contract of just selecting. Do it in the
   dispatch wrappers right before the actual `DispatchInference` call (or
   the HTTP equivalent).

5. Audit-category-J note (per SPEC-002): a single-candidate set still
   needs the rewrite — don't gate it on candidate count.

### T-1. Regression test using a real-shaped mock that asserts on body.model

Add `TestModelClassAliasRewrittenToConcreteModelOnDispatch` (or similar
name) to `phase4-coordinator/internal/buyer/server_test.go`. It MUST:

1. Configure `routing.model_classes` with `mlx-accurate` →
   `{models: ["mlx-community/Qwen2.5-7B-Instruct-4bit"], objective: accurate}`.
2. Register two providers: one serving the concrete Qwen-7B model, one
   serving a different model.
3. Use a mock relay that **captures the request body bytes** and **asserts
   `parsed_body["model"] == "mlx-community/Qwen2.5-7B-Instruct-4bit"`**
   (the concrete ID), NOT the alias.
4. Send a buyer request with `model: "mlx-accurate"`.
5. Verify: the mock saw the concrete ID, the response came back 200, and
   `selectProviderExcluding` correctly chose the Qwen-serving provider.

Parameterize across both relay types (WS-tunneled via `buyer.WithRelay`,
HTTP-forwarded via httptest.NewServer that inspects the request body) so
both dispatch sites are covered. AC-SR-5 should be amended to mention this.

### T-2. Backward-compat regression: concrete model IDs still work

Add or update a test asserting: a buyer request with the exact concrete
model ID (`mlx-community/Qwen2.5-7B-Instruct-4bit`) is identity-routed
unchanged — the body delivered to the provider has the same `model` field
as the buyer sent. This proves the rewrite is a no-op when the buyer
already sent a concrete ID (Option B's identity check, OR Option A's
re-marshal preserving the field).

### V-1. Verification — prove regression-lock value (fix-stash-test-restore)

After implementing, prove the test actually catches the bug by:

1. Run the new test → expect PASS.
2. Stash JUST the production code fix (revert `server.go` to HEAD; keep
   the spec + test on the branch).
3. Run the test → expect FAIL with the exact diagnostic that mock saw the
   alias instead of the concrete ID.
4. Restore the fix, run again → expect PASS.

If the test passes even without the production fix, it's a tautology and
needs rewriting (see SPEC-002 v1.3.2 audit-driven lesson; SPEC-006 v0.8.1
similarly). DO NOT commit until this fix-stash-test cycle proves the lock.

## Hard rules

- No SPEC-001 / SPEC-002 / SPEC-006 wire-contract change.
- The rewrite MUST NOT touch any other behavior — sticky map, retry,
  tiebreak, breaker, warmup gate. All those compose with the rewritten
  body identically (the body's model field is the only thing that changes).
- Failover (F-4) MUST get a fresh rewrite based on the new chosen provider.
  Don't cache the rewritten body in a way that pins it to the first
  attempt's provider.
- The rewrite MUST preserve buyer-supplied fields the gateway doesn't know
  about (custom OpenAI extensions, tool definitions, response_format).
  Option B (JSON patch) is safer here than Option A (struct re-marshal)
  unless `chatRequest` has a catch-all `extra map[string]json.RawMessage`
  field.
- Don't change the buyer-facing response shape. The rewrite is invisible
  to buyers — they sent `mlx-accurate`, they get back a normal
  ChatCompletion response with `model: "mlx-community/Qwen2.5-7B-Instruct-4bit"`
  (whatever the provider reports; current behavior).
- Clean-room d-inference (NOASSERTION) — don't inspect their source.
- DO NOT live-test against `augustass-macbook-air` (operator's local Mac;
  not in pool by deliberate decision).

## Anti-rules

- Do not propose new SPEC text beyond FR-SR-7a + version bump + changelog.
- Do not change `model_classes` config on Pearl in this PR — that's a
  separate operator flip-flag step after the fix is audited and merged.
- Do not add Pillar A/C/D changes; this PR is Pillar B only.
- Do not re-architect class resolution (it works; the picker is fine —
  only the dispatch boundary is broken).

## Output

- One commit on branch `fix/spec004-pillar-b-dispatch-rewrite`.
- Files expected to change:
  - `specs/SPEC-004-smart-router.md` (FR-SR-7a + v0.3 changelog)
  - `phase4-coordinator/internal/buyer/server.go` (the rewrite)
  - `phase4-coordinator/internal/buyer/server_test.go` (T-1 + T-2)
- Push to `origin/fix/spec004-pillar-b-dispatch-rewrite` (NOT main).
- Augustas11 account for the push (see project CLAUDE.md `gh auth switch`
  rule).

## Self-verification before declaring done

- [ ] `go build ./...` clean both modules
- [ ] `go test ./...` clean both modules
- [ ] `go test -race ./internal/pool ./internal/ws ./internal/buyer ./internal/router` clean
- [ ] V-1 fix-stash-test cycle proves the regression lock (capture the FAIL
      diagnostic in the commit message)
- [ ] FR-SR-7a is the only normative addition to SPEC-004; version bumped
      to v0.3; changelog entry added
- [ ] All four dispatch paths verified to call the rewrite (WS streaming,
      WS non-streaming, HTTP non-streaming, HTTP streaming)
- [ ] Failover (F-4) test re-run still passes — F-4 attempts get fresh
      rewrites per-attempt, not a stale rewrite from the first try

When done: report the branch, the per-file commit diffs (insertions/deletions),
the V-1 FAIL→PASS diagnostic, and any open question that affects public
behavior. Do NOT merge to main; an independent code-review pass MUST run
before merge per the discipline that's been catching bugs every round.

=== END PROMPT ===
```

---

## After the prompt is run

1. **Independent code-review audit** — focused on:
   - Does Option A vs B actually preserve buyer-supplied fields the gateway doesn't know about? (Test with a request containing `tools`, `response_format`, or other extensions.)
   - Does the rewrite fire on EVERY dispatch path, not just the obvious WS-streaming one?
   - Does the failover-after-rewrite case work — F-4 retries on a different provider, the body must be re-rewritten with the new provider's ModelID, not stale-cached?
   - Is the test genuinely real-shaped (asserts on `body.model`) not another body-ignoring mock?

2. **If audit ACCEPT**: merge `fix/spec004-pillar-b-dispatch-rewrite` to main, cross-compile new coord binary, deploy to Pearl, then re-flip `model_classes` config to advertise `mlx-fast` + `mlx-accurate` and verify live.

3. **Live verification after deploy**:
   ```
   curl -X POST https://api.streamvc.live/v1/chat/completions \
     -H "Authorization: Bearer <key>" -H "content-type: application/json" \
     -d '{"model":"mlx-accurate","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
   ```
   Expected: HTTP 200, response `model` field = `mlx-community/Qwen2.5-7B-Instruct-4bit`.

4. **`/v1/models` advertisement returns**: the class aliases reappear alongside the concrete IDs.
