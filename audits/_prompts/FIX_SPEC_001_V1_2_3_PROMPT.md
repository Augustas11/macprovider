# Fix prompt — SPEC-001 v1.2.2 → v1.2.3 + phase3-binary v1.2.4

Operator-paste prompt to apply two queued follow-ups from Entries 21 + 22:

1. **From Entry 22 (cross-spec FIX cycle):** Provider MUST include
   actual completion-token usage in cancel_request response. SPEC-006
   v0.4 D-CROSS-1 currently has the gateway estimate via
   `ceil(bytes_emitted_so_far / 4)`. With this provider-side
   normative addition, SPEC-006 v0.5 can swap estimation for
   provider-reported actuals (small follow-up patch after v1.2.4
   ships).

2. **From Entry 21 (Day-3 close):** Producer-side `withoutEscapingSlashes`
   normative — make unescaped `/` the REQUIRED producer output in
   /v1/models id field. Current SPEC-001 v1.2.2 § 6.2 says MAY emit
   either form; consumers MUST tolerate both. v1.2.3 binary already
   emits unescaped (commit 6a91257). This patch catches the spec up
   to binary behavior + locks producer-side discipline going forward.

Two normative additions + one Swift behavior change (cancel-usage) +
spec catch-up for the encoder setting that already shipped. Hardware
drain test required before tagging v1.2.4, per the Stream 1
verification gate that worked at v1.2.3 release.

This cycle clears two Entry 21/22 follow-ups. M4 + M1 partner
upgrade to v1.2.4 is coordinated separately (operator messages them
when v1.2.4 is published).

Run in **Claude Code**. Expected duration: ~60-90 min (small Swift
patch + hardware test + tag).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are landing two normative spec additions + one Swift behavior
change to phase3-binary, then bumping the release tag from v1.2.3 to
v1.2.4.

You will edit these files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
  /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/   (likely CoordinatorClient.swift and/or InferenceCoordinator.swift)
  /Users/augstar/macprovider-poc/phase3-binary/Tests/macprovider-cliTests/  (new or extended test for cancel-usage)
  /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html (append "Resolved in v1.2.4" section)

Version bumps:
  SPEC-001 v1.2.2 → v1.2.3
  phase3-binary internal version string 1.2.3 → 1.2.4
  Release tag v1.2.3 → v1.2.4 (after hardware verification)

## Critical constraints

**1. Backward-compat invariant.** The verbatim backward-compat
statement at SPEC-001 v1.2.2 (which you should be able to find near
the top of the document) must remain untouched.

**2. Buyer API stability.** Zero observable change to
`POST /v1/chat/completions`, `GET /v1/models`, `GET /healthz`. The
new normative producer-MUST on unescaped slashes is a tightening
of permitted output, not a breaking change — existing buyer SDKs
already tolerate both forms.

**3. d-inference clean-room.** Do not inspect d-inference source.

**4. Surgical scope.** Two normative additions + one behavior fix.
Do NOT make unrelated edits to SPEC-001 or to the Swift sources.

**5. Hardware verification gate.** Do not tag v1.2.4 until you have
verified the cancel-usage behavior against a local
phase4-coordinator. Same pattern as the v1.2.3 release: build, unit
test, build release, then exercise the cancel path end-to-end. If
the local test environment isn't available, document the gap and
STOP at "patch ready, untested on real hardware." Same discipline
that worked at v1.2.3.

**6. SPEC-006 v0.5 follow-up.** A separate FIX prompt
(FIX_SPEC_006_V0_5_PROMPT.md) will swap SPEC-006's byte-estimation
for provider-reported actuals after v1.2.4 ships. That patch is
NOT part of this cycle. Do NOT edit SPEC-006 in this pass.

## Required reading

1. `specs/SPEC-001-phase3-binary.md` v1.2.2 — full document. Note
   especially:
   - § 6.2 (/v1/models response — JSON escape tolerance)
   - § 6.6 (WS-tunneled inference message types, including
     cancel_request and inference_response_end)
   - The verbatim backward-compat clause

2. `beta/DECISION_CRITERIA.md` Entries 21 and 22 — read the
   follow-up paragraphs. Entry 21 (a) is the producer-side
   withoutEscapingSlashes normative. Entry 22 SPEC-001 v1.2.3
   candidate is the cancel-usage normative.

3. `specs/SPEC-006-buyer-api.md` v0.4 — focus on D-CROSS-1 (the
   gateway's current estimation rule) and § 17 refund matrix. Your
   spec text should explicitly note that the new SPEC-001 cancel-
   usage normative enables SPEC-006 v0.5 to switch from estimation
   to actuals; do not edit SPEC-006 here.

4. `phase3-binary/Sources/macprovider-cli/` — read enough to find:
   - The handler for cancel_request WS messages
   - Where inference_response_end is constructed
   - The version string (search `1.2.3`)
   - The `JSONEncoder` initialization (search for
     `JSONEncoder()` and `outputFormatting` — verify
     `.withoutEscapingSlashes` is already set per Entry 22)

5. `specs/FIX_SPEC_001_V1_2_2_PROMPT.md` — the prior cycle's
   prompt that produced v1.2.3 release. Match its house style for
   hardware verification gate, change log format, and AC additions.

6. `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`
   — the existing test pattern for reconnect lifecycle. New
   cancel-usage test should follow the same shape (mock coordinator
   sends cancel_request mid-stream; assert inference_response_end
   includes usage field with non-zero prompt+completion tokens).

## Findings to fix

### A. § 6.6 — cancel_request response MUST include usage tokens

**Location:** `specs/SPEC-001-phase3-binary.md` § 6.6

**Problem (Entry 22 follow-up):** SPEC-001 v1.2.2 § 6.6 defines
inference_response_end but doesn't explicitly require usage tokens
to be present when the response is the result of a cancel_request.
SPEC-006 v0.4 D-CROSS-1 has to estimate completion tokens via byte
division because the provider's cancel-response shape doesn't
guarantee usage. This forces gateway-side estimation and the small
inaccuracy that comes with it.

**Fix (spec text):** Add a normative paragraph in § 6.6
inference_response_end definition:

> When inference_response_end is sent in response to a cancel_request
> (per § 6.6's cancel handling), the provider MUST include a
> `usage` field in the inference_response_end message with:
>
> - `prompt_tokens`: the tokens consumed for the input prompt
> - `completion_tokens`: the actual number of tokens generated
>   before cancellation was honored (may be 0 if cancel arrived
>   before generation started)
> - `total_tokens`: prompt_tokens + completion_tokens
>
> This requirement enables downstream consumers (gateways per
> SPEC-006, accounting systems, billing infrastructure) to settle
> usage exactly rather than estimating. Estimation produces
> small but consistent under- or over-counts that compound across
> high-volume cancellation scenarios.
>
> Pre-v1.2.4 phase3-binaries (v1.2.3 and earlier) MAY omit the
> usage field in cancel-response inference_response_end. Consumers
> SHOULD fall back to estimation when usage is absent (gateway
> example: `ceil(bytes_emitted_so_far / 4)` per SPEC-006 v0.4
> D-CROSS-1).

**Acceptance criterion (add to § 9 or wherever ACs live):** AC-X
(next available number):

> **AC-X: Cancel-usage normative reporting.** With the binary
> running and joined to a local coordinator, the coordinator sends
> a cancel_request mid-stream after `N` tokens of generated output.
> The binary MUST: (1) honor the cancel within the existing
> cancellation latency budget; (2) send inference_response_end with
> `usage.prompt_tokens` > 0, `usage.completion_tokens` == N (the
> actual generated count), `usage.total_tokens` ==
> prompt_tokens + N. Verified by mock coordinator unit test +
> hardware integration test against local coordinator.

### B. § 6.2 — /v1/models response: producer MUST emit unescaped slashes

**Location:** `specs/SPEC-001-phase3-binary.md` § 6.2

**Problem (Entry 21 follow-up):** Current § 6.2 says producers MAY
emit either `/` or `\/` form. v1.2.3 binary already emits unescaped
(commit 6a91257 set `.withoutEscapingSlashes` on the encoder).
Multiple downstream consumers (install.sh's wait_for_local_model,
buyer SDKs, future SPEC-006 gateway forwarding logic) prefer the
unescaped form. Locking producer-side discipline to MUST emit
unescaped is a tightening that costs nothing (existing binaries
already comply) and removes a class of future drift.

**Fix (spec text):** Update § 6.2's existing JSON-escape paragraph:

Current (paraphrasing):

> The `id` field MAY contain forward-slash characters in either
> unescaped (`/`) or escaped (`\/`) form. Both are legal JSON per
> RFC 8259 § 7. Consumers MUST tolerate both encodings.

Replace with:

> The `id` field returned by /v1/models MUST be emitted with
> unescaped forward-slash characters (`/`). Producers MUST set
> their JSON encoder to suppress the legal-but-cosmetic `\/`
> escape — for Swift JSONEncoder, this means
> `outputFormatting.formUnion(.withoutEscapingSlashes)`.
>
> Consumers MUST tolerate the escaped form `\/` for backward-
> compatibility with pre-v1.2.4 phase3-binaries (the v1.2.0..v1.2.2
> series may emit either form depending on encoder defaults).
> RFC 8259 § 7 permits both, so consumer tolerance is required
> by spec.
>
> The producer-side MUST applies to v1.2.4 and later. v1.2.3 binary
> happens to already comply but was not specifically required to;
> this clause catches the spec up to v1.2.3's behavior + locks it
> for v1.2.4+.

This is a producer-tightening, consumer-preserving change. Existing
consumers continue working unchanged.

## Implementation work checklist (Swift side)

1. **Find the version constant** (search `1.2.3` under
   `phase3-binary/Sources/`). Bump to `1.2.4`. Update wherever it
   appears (`--version` output, user-agent header to coordinator,
   etc.).

2. **Verify `.withoutEscapingSlashes` is already set** on the
   JSONEncoder used by /v1/models and /v1/chat/completions response
   construction. Per Entry 22, this shipped in v1.2.3. If for any
   reason it's missing, add it.

3. **Locate the cancel_request handler.** Likely in
   `CoordinatorClient.swift` or `InferenceCoordinator.swift`. The
   handler should:
   - Receive cancel_request from coord
   - Signal the in-flight generation to stop (e.g., set a flag the
     generation loop checks)
   - When generation halts, construct inference_response_end with
     `usage` field populated from the actual prompt + completion
     token counts at cancel time

4. **If usage is currently omitted on cancel path:** add it. The
   token count likely comes from the existing
   `streaming_token_synthesizer` (per Entry 7's FR-7 work — the
   binary already tracks per-stream usage to synthesize the final
   chunk). The cancel path should hook into the same counter; the
   only delta is reporting whatever the count is at the moment of
   cancel rather than at natural completion.

5. **Add a unit test** that simulates cancel mid-stream:
   - Start the binary against a mock coordinator
   - Mock coord sends inference_request, receives a few
     inference_response_chunk messages
   - Mock coord sends cancel_request
   - Assert the binary sends inference_response_end with non-zero
     `usage.completion_tokens` matching the chunks received before
     cancel

6. **Run the existing test suite.** Run `swift build -c release`
   and verify the binary boots locally.

7. **Hardware verification gate:** do NOT tag v1.2.4 until you have:
   - Started a local phase4-coordinator (same setup from
     specs/FIX_SPEC_001_V1_2_2_PROMPT.md drain test)
   - Started the patched binary as a provider against local coord
   - Issued a streaming request via the coord's buyer surface (or
     equivalent)
   - Sent cancel mid-stream
   - Captured the inference_response_end message via coord log
     or buyer-side response
   - Verified `usage` field is present with correct prompt_tokens
     and completion_tokens

   If this test environment is unavailable, document the gap and
   STOP at "patch ready, untested on real hardware" — same
   discipline as Stream 1 v1.2.2/v1.2.3 cycle.

8. **Self-canary on augustass-macbook-air** (optional but
   recommended): same pattern as v1.2.3 release. Swap binary,
   re-bootstrap launchd, observe through production WSS for 10 min,
   then tag.

## Output requirements

1. SPEC-001 updated in place. Version bumped to v1.2.3. Change log
   entry at the top covering both Finding A and Finding B.
   Backward-compat clause untouched.

2. Swift sources: version 1.2.4 everywhere. cancel-usage in
   inference_response_end. `.withoutEscapingSlashes` confirmed in
   place. New unit test for cancel-usage passes.

3. `phase3-binary/implementation-notes.html` gains a "Resolved in
   v1.2.4" section listing Findings A and B with one-line
   summaries.

4. If hardware verification passes (or self-canary clean), tag
   v1.2.4 via the existing release flow (push the tag; GitHub
   Action handles the rest). If verification environment
   unavailable, STOP and report — do not tag.

5. Handback summary at the end: 200 words covering:
   - What changed in SPEC-001 (Finding A + B summary)
   - What changed in Swift (cancel-usage path; version bump)
   - Hardware verification result (passed / not available / failed)
   - Whether v1.2.4 was tagged
   - Filed for SPEC-006 v0.5 follow-up: gateway can now swap
     byte-estimation for provider-reported actuals; this is a
     separate FIX cycle the operator will run next

## Self-verification checklist

- [ ] SPEC-001 version bumped 1.2.2 → 1.2.3 at the top.
- [ ] Change log entry covers Findings A and B.
- [ ] Backward-compat clause is byte-for-byte identical to v1.2.2.
- [ ] § 6.6 has the cancel-usage normative paragraph + new AC.
- [ ] § 6.2 has the unescaped-slashes producer MUST + consumer
      MUST tolerate clause.
- [ ] Swift: version 1.2.4 everywhere; cancel path includes usage;
      `.withoutEscapingSlashes` confirmed.
- [ ] `swift test` green. New cancel-usage test present.
- [ ] (If tagged) v1.2.4 release published; binary `--version`
      reports 1.2.4.

If your edits exceed ~150 lines in SPEC-001 or ~200 lines in Swift
total, stop and re-check scope — this is a small targeted patch.

When done, print the handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~15 min):

1. `git diff specs/SPEC-001-phase3-binary.md` — three additions
   (Finding A normative + AC + Finding B paragraph rewrite) +
   version bump + change log. Backward-compat clause unchanged.
2. `git diff phase3-binary/Sources/` — cancel-usage in
   inference_response_end + version bump. Optionally
   `.withoutEscapingSlashes` confirmation comment.
3. Run `swift test` from `phase3-binary/`. New cancel-usage test
   passes.
4. Run the hardware cancel test (mock coord OR local coord + force
   cancel mid-stream, verify usage in response).
5. If v1.2.4 was tagged, fetch the release tarball and verify
   `macprovider-cli --version` prints `1.2.4`.

Then commit. Suggested message:

```
SPEC-001 v1.2.3 + phase3-binary v1.2.4: cancel-usage + producer-side unescaped slashes

Two normative additions closing Entry 21 + 22 follow-ups.

A. 6.6  Provider MUST include usage tokens in inference_response_end
        when the response is the result of a cancel_request. Enables
        SPEC-006 v0.5 to swap byte-estimation for provider-reported
        actuals.

B. 6.2  Producer MUST emit unescaped forward-slashes in /v1/models
        id field; consumers MUST tolerate both forms per RFC 8259.
        Locks producer discipline; v1.2.3 binary already complied,
        spec catches up.

Swift changes: cancel-usage path in inference_response_end;
.withoutEscapingSlashes confirmed; version 1.2.4. Unit test for
cancel-usage. Hardware drain + cancel verification: clean.

Backward-compat: pre-v1.2.4 binaries (v1.2.0..v1.2.3) may omit
cancel-usage; SPEC-006 v0.5 will fall back to estimation when
absent. v1.2.0..v1.2.2 may emit either / or \/ form.

Filed for SPEC-006 v0.5 follow-up: swap byte-estimation for
provider actuals (small narrow patch).
```

After commit + v1.2.4 release publishes:

1. **Message M4 + M1 partners** asking them to upgrade. The v1.2.4
   binary is backward-compatible with v1.1.3/v1.1.4 coord paths
   (no breaking changes); upgrade is per-Mac and ~30 sec
   (`relaunch-{m4,m1}.sh` equivalent). Optional but worth doing
   while you're in this cycle — it clears the partner-upgrade
   follow-up + brings them current with reconnect lifecycle fixes
   they're still missing from the v1.2.3 release.

2. **Draft `FIX_SPEC_006_V0_5_PROMPT.md`** — small ~150-line patch
   that swaps SPEC-006 v0.4's byte-estimation rule for provider-
   reported actuals (with backward-compat fallback to estimation
   when usage is absent, for pre-v1.2.4 providers). ~30 min draft +
   ~30 min execute. Lock SPEC-006 v0.5.

3. **Then BUILD_PHASE5_PROMPT.md** — gateway implementation against
   the now-fully-clean spec corpus (SPEC-001 v1.2.3, SPEC-002 v1.1.4,
   SPEC-003 v0.6, SPEC-006 v0.5).

The total cost from "spec corpus locked at Entry 22" to "spec corpus
fully cleaned + ready for BUILD_PHASE5" is ~1 day of operator-side
work spread across two narrow FIX cycles. Both follow-ups Entry 22
filed get closed without expanding scope.
