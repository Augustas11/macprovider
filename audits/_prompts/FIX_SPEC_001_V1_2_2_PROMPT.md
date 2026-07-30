# Fix prompt — SPEC-001 v1.2.1 → v1.2.2 + phase3-binary v1.2.3

Operator-paste prompt for the **Swift stream** of the three-stream patch
cycle queued after Decision log Entries 19 + 20. Two other prompts cover
the Go (SPEC-002 v1.1.3) and Distribution (SPEC-003 v0.5) streams in
parallel; run them in three separate Claude Code sessions.

## What this stream owns

| Layer | From | To |
|-------|------|----|
| Spec document | SPEC-001 v1.2.1 | SPEC-001 v1.2.2 |
| Swift implementation | phase3-binary v1.2.2 tag (Swift internal version 1.2.1) | phase3-binary v1.2.3 tag (internal 1.2.3) |

Two normative additions + one behavior fix:

  A. **§ 6.5 reconnect-task lifecycle** — post-drain reconnect MUST fire
     within 15s; failure to reconnect within 3 attempts MUST log WARN.
     Behavior bug, Entry 19: M4 (v1.1.4) and M1 (v1.1.3) both got stuck
     after CoordinatorDrainComplete; the Swift Task that should have
     redialed the WS was either never spawned or dropped before firing.
     Manual `relaunch-m{4,1}.sh` was needed to recover.

  B. **§ 6.4 model field comparison** — model identifier comparison
     against /v1/chat/completions and /v1/models MUST be case-insensitive
     ASCII. Entry 20 + Day-2 note: `mlx_lm.server` was case-insensitive,
     current phase3-binary isn't; caused an M1 cron 404 storm earlier
     until "Title Case" was hand-fixed.

  C. **§ 6.2 /v1/models response encoding** — the `id` field MAY contain
     either `/` or the RFC 8259 `\/` escape. Consumers MUST tolerate
     both. (Entry 20 Bug D: Swift JSONEncoder emits `\/` by default;
     install.sh's `grep -Fq` for `/` never matched; "Local self-test
     failed" was a false negative for two release cycles.)

Run in **Claude Code**. Expected duration: ~90-120 min (Swift + Metal
build is the long pole; spec edits are quick).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are landing two normative spec additions + one behavior fix to the
phase3-binary Swift implementation, then bumping the release tag.

You will edit these files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
  /Users/augstar/macprovider-poc/phase3-binary/Sources/MacProviderCLI/   (one or more .swift files)
  /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html (append "Resolved in v1.2.3" section)

Version bumps:
  SPEC-001 v1.2.1 → v1.2.2
  phase3-binary internal version string 1.2.1 → 1.2.3
    (skip 1.2.2 because that tag already exists as the install.sh-only
    distribution patch; this is the next Swift code change.)

## Cross-spec context (shared verbatim across the three-stream patch cycle)

Today's Day-3 distribution work landed `curl-pipe-bash` for strangers.
The first stranger-shaped install surfaced **four install.sh bugs (A–D,
Entry 20)** and the preceding Day-2 production deploy surfaced **two
silent regressions (Entry 19)**: (1) Swift reconnect-task lifecycle
after CoordinatorDrainComplete didn't fire; (2) Go coordinator's
`WithTokenValidator` was wired unconditionally and `s.close()` did not
log, causing 15 min of silent production rejection.

The audit-pattern lesson from both Entries: **code paths that look
locally correct but fail under real-world resource interactions**. Each
line read fine in isolation; failure modes only emerged when shell
environment / Task lifecycle / config-flag-absent paths were actually
exercised. Per-stream audits caught the design issues; only the
stranger-shaped end-to-end test catches the surface issues.

Three patch streams run in parallel against this context:

  - **SPEC-001 v1.2.2 + phase3-binary v1.2.3** (THIS PROMPT) — Swift
    behavior fix + spec text for reconnect lifecycle, model_id casing,
    JSON-escape tolerance.

  - **SPEC-002 v1.1.3** (sibling prompt FIX_SPEC_002_V1_1_3_PROMPT.md)
    — Go spec-text-only: auth.require_provider_tokens normative,
    log-every-WS-close MUST, anti-pattern audit category entry. The
    Go behavior already shipped in commit 47d6433.

  - **SPEC-003 v0.5** (sibling prompt FIX_SPEC_003_V0_5_PROMPT.md) —
    distribution polish: install.sh prints wire bytes on self-test
    failure; § 5 normative requirement; new audit category for
    "shell-script paths touching real OS resources."

Each stream owns a disjoint codebase. Coordinate via commits to main;
no file-level conflicts expected.

## Critical constraints

**1. Backward-compat invariant.** The verbatim backward-compat
statement at SPEC-001 v1.2.1 lines 20-38 must remain untouched.

**2. Buyer API stability.** Zero observable change to the buyer-facing
endpoints: `POST /v1/chat/completions`, `GET /v1/models`, `GET /healthz`.
The model field becoming case-insensitive is purely permissive —
existing exact-match callers continue to work.

**3. d-inference clean-room.** Do not inspect d-inference source.

**4. Surgical scope.** Three changes total (A, B, C below). Do NOT
make unrelated edits to SPEC-001 or to the Swift sources.

**5. Test the reconnect fix on real hardware before tagging the
release.** The bug only manifests after a real WS close from the
coordinator side (not a unit-test simulation). Use the local
phase4-coordinator with `/admin/drain?provider_id=<id>` to force the
close, then verify the binary rejoins within 30s. If you don't have
this test environment, document the gap and stop — do not tag a
release on a self-attested fix for a production-bite bug.

## Required reading

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   — full document. Note especially:
     - § 6.2 (the /v1/models response schema)
     - § 6.4 (the /v1/chat/completions request — find where model
       identifier matching is normatively specified, or add it if
       absent)
     - § 6.5 (the WS hello / drain message types — where the
       reconnect lifecycle text belongs)
     - The verbatim backward-compat clause at lines 20-38 (must
       remain untouched)

2. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   — read Entry 19 (Day 2 implementation arc) and Entry 20 (install
   bugs A/B/C/D) carefully. Entry 19 contains the production
   evidence for the reconnect bug; Entry 20 contains the wire-format
   evidence for Bug D.

3. `/Users/augstar/macprovider-poc/phase3-binary/Sources/MacProviderCLI/`
   — read the existing Swift sources. Find:
     - The class/actor that owns the coordinator WS connection lifecycle
     - The Task that handles reconnect after drain (search for
       `CoordinatorDrainComplete`, `drainFromCoordinator`, `reconnect`,
       `Task { … }`)
     - The handler for `/v1/chat/completions` model field matching
       (search for `model ==`, `request.model`, `chosenModel`)
     - The version string (search for `1.2.1`)

4. `/Users/augstar/macprovider-poc/phase3-binary/dist/relaunch-m4.sh`
   and `relaunch-m1.sh` — these are the manual workaround scripts
   created today. After your fix lands, they should become unnecessary
   for the v1.2.3+ path; keep them in tree for any v1.1.x binaries
   still in the field but note in the change log that v1.2.3+ doesn't
   need them.

## Findings to fix

### A. § 6.5 — reconnect-task lifecycle normative requirement

**Location:** `specs/SPEC-001-phase3-binary.md` § 6.5

**Problem (Entry 19):** SPEC-001 v1.2.1 § 6.5 specifies the drain
sequence but does not normatively require that the provider re-attempt
the WS connection after `CoordinatorDrainComplete`. The
phase3-binary v1.1.3 + v1.1.4 implementations dropped the WS
correctly but the reconnect Task was either never spawned or was
dropped before it fired. M4 and M1 both got stuck for ~15 minutes
until manual relaunch.

**Fix (spec text):** Add a normative paragraph in § 6.5 immediately
after the drain handshake description:

> After sending `drain_status: complete` and closing the WebSocket,
> the provider MUST re-enter the same reconnect loop used at process
> start. The first reconnect attempt MUST occur within 15 seconds of
> the WS close (matching the coordinator-side grace period defined in
> SPEC-002 § 6). If the first three reconnect attempts fail in a row,
> the provider MUST log at WARN level with the attempt count and the
> last error; it MUST NOT exit the process. The reconnect cadence
> follows the same backoff as the initial-connect path.
>
> This requirement exists because conflating drain with process exit
> was the bug fixed in v1.1.3 (Entry 18); v1.1.3/v1.1.4 then exposed
> a second bug where reconnect was structurally enabled but not
> exercised post-drain. The implementation MUST treat post-drain
> reconnect as a first-class path with its own test coverage, not a
> side effect of the connect loop's natural retry.

**Acceptance criterion (add to § 9):** AC-X (next available number):

> **AC-X: Post-drain reconnect.** With the binary running and joined
> to a local coordinator at `state: ready`, the operator sends a drain
> directive (e.g., `POST /admin/drain?provider_id=<id>` on the
> coordinator's provider port). The binary MUST: (1) reply
> `drain_status: complete` per § 6.5; (2) close the WS; (3) within 30s
> of the close, send a fresh `hello` over a new WS; (4) reach
> `state: ready` again in the coordinator pool within 60s total
> elapsed from drain initiation. Verified by tailing both the binary
> log (look for "reconnect attempt 1") and the coordinator's
> `/poolz` endpoint.

### B. § 6.4 — model field case-insensitive comparison

**Location:** `specs/SPEC-001-phase3-binary.md` § 6.4 (or wherever
the request schema for /v1/chat/completions is normatively defined;
if no explicit normative paragraph exists for model matching, add one)

**Problem (Entry 20 + Day-2 note):** `mlx_lm.server` (the legacy
backend phase3-binary replaced) matched the model field
case-insensitively. phase3-binary v1.2.x matches case-sensitively,
so an M1 cron job sending `mlx-community/llama-3.2-3b-instruct-4bit`
(lowercased) against a server holding `mlx-community/Llama-3.2-3B-Instruct-4bit`
(Title Case) returned 404 in a storm until the cron was hand-fixed.
This is a buyer-visible silent-failure mode.

**Fix (spec text):** Add a normative paragraph in § 6.4:

> The `model` field in `/v1/chat/completions` requests and the `id`
> field returned by `/v1/models` are compared **case-insensitively
> in ASCII** by the provider. A request for `Mlx-Community/Llama-...`
> against a provider hosting `mlx-community/Llama-...` MUST be
> served, not 404'd. This matches `mlx_lm.server` behavior and
> mirrors the existing case-insensitivity of HTTP header field
> names (RFC 9110 § 5.1). Non-ASCII code points in model
> identifiers are out of scope; provider behavior with such
> identifiers is undefined.

**Fix (implementation):** Update the model-matching path in
MacProviderCLI's request handler. Change `lhs == rhs` to
`lhs.lowercased() == rhs.lowercased()` (or equivalent
`compare(_:options:.caseInsensitive)`). Add a unit test that asserts
both case variants match.

### C. § 6.2 — /v1/models response: `/` vs `\/` tolerance

**Location:** `specs/SPEC-001-phase3-binary.md` § 6.2

**Problem (Entry 20 Bug D):** Swift's `JSONEncoder` defaults to
emitting forward-slashes as the legal-but-cosmetic `\/` escape:

```json
{"id":"mlx-community\/Llama-3.2-3B-Instruct-4bit","owned_by":"macprovider"}
```

The install.sh self-test used `grep -Fq "$model"` against the response
and matched the unescaped `mlx-community/Llama-...` — which never
appeared. Two release cycles (v1.2.1, v1.2.2) shipped with "Local
self-test failed" as a false negative.

The install.sh side has been patched today (`sed 's|\\/|/|g'` normalization,
commit 7aae075) and that's the consumer-side fix. The producer-side
clarification belongs in the spec: both encodings are legal per RFC
8259 § 7; consumers MUST tolerate both.

**Fix (spec text):** Add a non-normative example + normative clause
in § 6.2 after the response schema:

> The `id` field MAY contain forward-slash characters in either
> unescaped (`/`) or escaped (`\/`) form. Both are legal JSON per
> RFC 8259 § 7. Consumers MUST tolerate both encodings. Producers
> SHOULD prefer the unescaped form (`/`) for human readability but
> are not required to. Example response (with `\/`):
>
> ```json
> {
>   "object": "list",
>   "data": [
>     {
>       "id": "mlx-community\/Llama-3.2-3B-Instruct-4bit",
>       "object": "model",
>       "owned_by": "macprovider",
>       "created": 0
>     }
>   ]
> }
> ```
>
> Note: the current phase3-binary v1.2.x implementations emit the
> escaped form by Swift's `JSONEncoder` default. A future revision
> MAY switch to the unescaped form by setting
> `outputFormatting.contains(.withoutEscapingSlashes)`; this would be
> a non-breaking change because all conforming consumers already
> tolerate both.

**Fix (implementation, OPTIONAL but RECOMMENDED):** Set
`JSONEncoder.outputFormatting = [.withoutEscapingSlashes]` on the
encoder used by `/v1/models` and `/v1/chat/completions`. This
produces the unescaped form and unbreaks any downstream tooling that
hard-codes the `mlx-community/` literal. Document the change in the
binary change log even though the spec marks both encodings legal.

## Implementation work checklist (Swift side)

1. Find the version constant (search `1.2.1` under `phase3-binary/Sources/`).
   Bump to `1.2.3`. Update wherever it appears (`--version` output,
   user-agent header to coordinator, etc.).

2. Find the WS reconnect logic. Verify the post-drain path actually
   spawns a Task that survives. If it's `Task { try await reconnect() }`
   without being stored in an actor-owned property, the Task is
   eligible for cancellation when the parent goes out of scope. Store
   it on the actor (e.g., `private var reconnectTask: Task<Void,
   Never>?`) and ensure the only thing that cancels it is a deliberate
   shutdown signal.

3. Add a unit test that simulates the post-drain sequence:
   - Start the binary against a mock coordinator
   - Have the mock send drain
   - Assert the binary sends `drain_status: complete` then closes
   - Assert a new `hello` arrives at the mock within 15s
   - Assert the binary state reaches `ready` again

4. Change the model-matching path to case-insensitive (Finding B).
   Add a unit test with mixed-case input.

5. Optional: set `.withoutEscapingSlashes` on the JSONEncoder (Finding C).

6. Run the existing test suite. Run `swift build -c release` and
   verify the binary boots locally.

7. **Hardware verification gate:** do not tag v1.2.3 until you have
   reproduced the original bug on the v1.2.2 binary (drain → never
   reconnects) AND verified your patched binary reconnects within 30s
   against the same scenario. If the test environment for this gate
   is unavailable, document the gap and STOP at "patch ready, untested
   on real hardware."

## Output requirements

1. SPEC-001 updated in place. Version bumped to v1.2.2. Change log
   entry added at the top. Backward-compat clause untouched.

2. Swift sources updated: reconnect-task storage; model case-insensitive
   match; optional `.withoutEscapingSlashes`; version string 1.2.3.

3. New unit tests for reconnect + case-insensitive model match. Both
   pass under `swift test`.

4. `phase3-binary/implementation-notes.html` gains a "Resolved in
   v1.2.3" section listing Findings A/B/C with one-line summaries.

5. If hardware verification passes, tag v1.2.3 via the release flow
   (`phase3-binary/dist/package.sh v1.2.3` then push the tag — the
   GitHub Action handles the rest). If the hardware test environment
   is unavailable, STOP and report — do not tag.

6. Handback summary at the end: 150-200 words covering what changed,
   what was tested where, what regression risk remains, and the next
   commit hash.

## Self-verification checklist

- [ ] SPEC-001 version bumped 1.2.1 → 1.2.2 at the top.
- [ ] Change log entry covers Findings A, B, C in that order.
- [ ] Backward-compat clause at lines 20-38 (or wherever it now lives)
      is byte-for-byte identical to v1.2.1.
- [ ] § 6.5 has the post-drain reconnect normative paragraph + AC-X.
- [ ] § 6.4 has the case-insensitive model-match normative paragraph.
- [ ] § 6.2 has the `/` vs `\/` tolerance paragraph.
- [ ] Swift sources: version 1.2.3 everywhere; reconnect Task stored
      on actor; model match `.lowercased() == .lowercased()`; (optional)
      `.withoutEscapingSlashes` set.
- [ ] `swift test` green. New tests for reconnect + case match present.
- [ ] (If tagged) GitHub Action green; release assets land; binary
      `--version` prints 1.2.3.

If your edits exceed ~250 lines in SPEC-001 or ~400 lines in Swift
total, stop and re-check scope — these are surgical patches, not a
rewrite.

When done, print the handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~10 min):

1. `git diff specs/SPEC-001-phase3-binary.md` — three additions (one per finding) + version bump + change log. No edits to the backward-compat clause.
2. `git diff phase3-binary/Sources/MacProviderCLI/` — reconnect-task lifecycle change + case-insensitive model match + version bump. Optional: `.withoutEscapingSlashes`.
3. Run `swift test` from `phase3-binary/`. Both new tests pass.
4. Run the hardware drain-reconnect test (kill provider WS from coordinator side, verify rejoin within 30s).
5. If v1.2.3 was tagged, fetch the release tarball and verify `macprovider-cli --version` prints `1.2.3`.

Then commit. Suggested message:

```
SPEC-001 v1.2.2 + phase3-binary v1.2.3: reconnect lifecycle + casing + JSON-escape tolerance

Three normative additions + matching Swift behavior fixes.

A. § 6.5  Post-drain reconnect MUST fire within 15s; failure to
          reconnect within 3 attempts MUST log WARN. Fixes Entry 19
          production bug where M4 (v1.1.4) + M1 (v1.1.3) got stuck
          after CoordinatorDrainComplete until manual relaunch.
          AC-X added.

B. § 6.4  /v1/chat/completions model field comparison MUST be
          case-insensitive ASCII. Matches mlx_lm.server. Fixes M1
          cron 404 storm from Entry 17 follow-up.

C. § 6.2  /v1/models id field MAY contain / or \/; consumers MUST
          tolerate both per RFC 8259. (Producer-side: optional
          .withoutEscapingSlashes lands too.)

Backward-compat invariant: unchanged. Buyer API surface: unchanged
(case-insensitive matching is permissive).
```

After commit, decide whether to file a v1.2.3-acceptance regression
prompt (recommended if the hardware drain-reconnect test passed) or
proceed to monitor the v1.2.3 release in the wild for 24h before
declaring the Day-2 + Day-3 follow-ups closed.
