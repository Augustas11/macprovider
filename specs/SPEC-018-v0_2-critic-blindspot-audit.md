# SPEC-018 v0.2.2 — Critic Blind-Spot Audit

**Date:** 2026-06-27
**Reviewer:** Claude critic blind-spot pass (Opus 4.7)
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

- CRITICAL: 0
- HIGH: 3
- MEDIUM: 4
- minor: 3
- Q: 2

Codex 4-lane returned 0/0/0 across 3 rounds. This pass surfaces 3 lock-blocking HIGH issues all four codex lanes missed — repeating the v0.1.5 precedent (3 HIGH after codex 4-lane 0/0/0).

The common failure mode across all four codex lanes was treating the SPEC's own load-bearing claims about external systems (Cline, openai-python, MLX provider clock domain, Vercel AI SDK) as if they were internal consistency facts. Codex audits the SPEC against itself; it does not refute the SPEC against the real world.

---

## CRITICAL findings

None.

---

## HIGH findings

### H-1 — AC-48 / AC-25a "Cline + openai-python" assumes a stack Cline does not use

- **Codex blind-spot category:** CRITIC-4 (Claims-vs-reality) — codex lanes audited the SPEC against itself, not against the real Cline codebase.
- **SPEC location:** AC-48 (line 610), AC-43 (line 600), AC-39 (line 592), AC-25a (line 560), §1 (line 58, by association).
- **The claim:**
  - AC-48: `"A fixture using openai-python v2.44.0+ streaming reader and Cline integration emits a valid incremental-open and partial accumulated arguments, then triggers final-close failure. The terminal-error stream MUST NOT deliver a successful assistant message with dispatchable tool_calls[] to the framework's tool-execution boundary"` (line 610).
  - AC-43: pins `openai==2.44.0` (line 600).
  - AC-39: `"OpenAI SDKs (openai-python v2.44.0+, openai-node, etc.) may surface the terminal SSE error frame as an exception or failed stream. This is the intended behavior."` (line 592).
  - §10d.4 example, AC-25a, AC-44, AC-48 are all built around the assumption that **Cline drives chat completions through an OpenAI SDK** with documented terminal-error semantics.
- **The refutation:** Verified against `github.com/cline/cline` HEAD at `92806c60` (default branch `main`, pushed 2026-06-27T05:16:05Z, VS Code extension v4.0.0, publisher `saoudrizwan`, name `claude-dev` — the exact extension AC-25a pins):
  - `sdk/packages/llms/src/providers/vendors/openai-compatible.ts` (the file that handles every OpenAI-wire-compatible provider in Cline v4) imports and uses `createOpenAICompatible` from `@ai-sdk/openai-compatible` — i.e., **Vercel AI SDK**, not `openai-python` and not `openai-node`. Confirmed at lines 1-9, 125-150.
  - Cline never instantiates the official `openai` Python or Node SDK for the OpenAI-compatible path. The stream is consumed by Vercel AI SDK's `wrapLanguageModel` returning an `AsyncGenerator<ApiStreamChunk>` (`sdk/packages/llms/src/providers/stream.ts`).
  - This is a **category error in the SPEC**. AC-48 says the fixture uses "openai-python v2.44.0+ streaming reader AND Cline integration" — these are two **incompatible** stacks. You can either:
    - (a) Drive openai-python (Python) against macprovider directly, which is NOT a Cline integration; or
    - (b) Drive Cline (Node/Vercel-AI-SDK), which does NOT exercise openai-python.
    You cannot do both in one fixture. The SPEC describes a fixture that cannot exist.
  - This also breaks AC-43: the streaming forward-compat regression pins `openai==2.44.0`. That regression certifies openai-python compatibility against a Python parser — fine in isolation. But the SPEC explicitly cross-references AC-43 to the Cline release gate (§10d.4 line 815: "AC-23s extends AC-23 for streaming forward compatibility"), implying Cline interop. **The real risk is not openai-python's terminal-SSE behavior — it is Vercel AI SDK's terminal-SSE behavior.** Vercel AI SDK has its own error-frame parsing, its own tolerance for unknown SSE event types, and its own retry/abort semantics. Whether `@ai-sdk/openai-compatible` surfaces a terminal `error` SSE event as "throw exception" vs "silent stream end with partial accumulated tool_calls[] dispatched" is **the actual money-path question for Cline** — and the SPEC does not gate it.
- **Severity rationale:** HIGH. This is exactly the v0.1.5 H-2 pattern at higher stakes:
  - v0.1.5 H-2: Cursor/Claude Code claimed as OpenAI-wire targets when they aren't.
  - v0.2.2 H-1: Cline claimed to use openai-python's SSE behavior when it uses a different SDK.
  AC-48 is the **single normative gate** between "incremental-open buyer-visible commit happens" and "tool calls don't slip past final-close failure into Cline's execute-decision boundary." If that AC tests the wrong client stack, the SPEC's money-path-safety claim for Cline is unverified. Codex security lane signed off because the claim is internally consistent ("if your client is openai-python, error frame is an exception"). Codex code/architect/PD signed off because Cline is named as the anchor framework throughout the SPEC. No lane asked "does Cline actually use openai-python?"
- **Recommended fix:**
  1. Split AC-48 into AC-48a (`openai-python v2.44.0 streaming reader` — pure-SDK regression) and AC-48b (`Cline / @ai-sdk/openai-compatible terminal-SSE behavior`). AC-48b must inspect the Vercel AI SDK build that Cline 4.0.0 ships (pinned in `tools/version-pins/cline-spec-018-v0_2_2.txt` — already required by AC-25a) and assert that terminal-error SSE events do NOT yield a successful assistant message into the AgentRuntime tool-execution boundary.
  2. Reword AC-43's first sentence to add: "AC-43 is an OpenAI Python SDK regression and is NOT a Cline-stack regression. Cline-stack streaming behavior is gated by AC-48b."
  3. Reword AC-39 to say "OpenAI-shape SDKs MAY surface ... openai-python v2.44.0+ and openai-node DO. Vercel AI SDK's `@ai-sdk/openai-compatible` behavior on terminal SSE error frames is gated separately by AC-48b."
  4. In §10d.4 add: "The Cline v4.0.0 anchor framework drives chat completions through Vercel AI SDK (`@ai-sdk/openai-compatible`), not openai-python. The §10d.4 terminal-SSE-error invariants apply across SDK families and are independently gated by AC-48b for the Cline path."

### H-2 — §3.9 minimal prompt-echo guard is trivially bypassable AND incomplete in scope

- **Codex blind-spot category:** CRITIC-2 (Threat-model holes hidden in v0.2 additions) — codex security lane signed off on §3.9 because "exact-verbatim full-block defense" sounds defensive; no lane probed how an attacker would actually bypass it.
- **SPEC location:** §3.9 (lines 299-305), AC-49 (line 612), §10d.1 failure-table row (line 773).
- **The claim:** `"For v0.2, parser-side tool-call synthesis MUST fail closed to plain assistant content if a complete native tool-call block in the model output appears verbatim in any request messages[].content string or any role:"tool".content string in the same request. The match is byte-exact, case-sensitive, and normalization-free over the complete native sequence: opening sentinel, body bytes, and closing sentinel. Partial sentinel matches, body-only matches, differently escaped JSON, different whitespace, Unicode-normalized equivalents, or case-changed text do not trigger this minimal v0.2 guard."`
- **The refutation:** Three independent bypass / coverage gaps:

  **(a) Whitespace mutation completely defeats the guard.** A model attacker controlling output emits `<tool_call>\n{"name":"shell","arguments":{...}}\n</tool_call>` (newlines inside the block) while the request `role:"tool".content` contains the unspaced form. Verbatim match fails because "different whitespace" is explicitly excluded from triggering. Result: the guard does NOT fire, the parser synthesizes executable `tool_calls[]`. The SPEC explicitly carves out whitespace as a non-trigger, which means **any model with one extra newline bypasses the entire defense**. For a model the attacker can prompt-influence (the canonical prompt-injection vector this is supposed to defend against), this is a one-token bypass.

  **(b) JSON-string vs prompt-content scope mismatch.** The guard scans `messages[].content` and `role:"tool".content`. Both are buyer-supplied JSON strings; after JSON decode they are unescaped Unicode strings. But the model's input prompt is rendered through the §3.8 family template (Qwen chat-template markup with its own `<tool_call>` framing in tool-history blocks). A buyer-fabricated assistant-history `tool_calls[].function.arguments` containing `<tool_call>...</tool_call>` as a string value lands in the model's prompt as Qwen tool-call markup containing a literal sub-string `<tool_call>...</tool_call>`. The model then echoes that. The guard ONLY scans `messages[].content` and `role:"tool".content` — it does NOT scan `tool_calls[].function.arguments` strings, `tool_calls[].function.name`, `tools[].description`, `tools[].function.parameters`, or `system` (which in OpenAI wire is `messages[0].content` when role is "system", so partially covered). **A prompt-injection vector through `tools[].description` is not covered.**

  **(c) Self-DoS for any session that reads SPEC-018 itself.** Cline's `read_file` returns the file's content verbatim in a `role:"tool"` message. If a user asks Cline to read `specs/SPEC-018-agentic-tool-calling.md` or any other file containing a literal Qwen tool-call block (the SPEC text itself contains examples like `<tool_call>{"name":"foo","arguments":{"a":1}}</tool_call>` in AC-1 at line 506), the next assistant turn that legitimately wants to use a tool call with arguments resembling that example **suppresses the legitimate tool call**. This is the **v0.1.5 H-3 mixed-sentinel DoS pattern repeated**: a content-scan defense whose false-positive cost lands directly on the documented use case (reading code / docs / SPECs).
- **Severity rationale:** HIGH because the guard's stated purpose ("close the residual prompt-injection vector where a tool-call-capable model echoes hostile content from a poisoned user prompt") is achieved against only the narrowest adversary (a model that echoes the exact bytes verbatim with zero whitespace mutation, AND only via `messages[].content` / `role:"tool".content` not through tool descriptions/argument-history). Any sophisticated prompt-injection attack will mutate whitespace by one character; any honest user who asks Cline to read a documentation file containing tool-call examples breaks legitimate tool calling. The guard adds attack surface without closing the attack — exactly the v0.1.5 H-3 pattern. Codex security lane signed off because §3.9 is "narrower and safer than v0.3 full guard"; no lane modeled an attacker who controls model output. Codex code lane signed off because the guard is mechanically expressible. Neither thought about the data-vs-framing boundary.
- **Recommended fix:**
  1. Either drop §3.9 entirely (relying on §3.2 modelID-match-required + §10a #2 v0.3 registry as the layered defense) and update AC-49 to verify the guard's absence; OR
  2. Reframe §3.9 as "whitespace-normalized + sentinel+name match" — i.e., compare the model's emitted `<tool_call>` block against the request's content with whitespace collapsed AND require name-match (the function name in the candidate block must equal a name appearing in the request's `tool_calls[]` or `role:"tool"` mirror), AND explicitly extend the scan to `tools[].description`, `tools[].function.parameters`, and assistant-history `tool_calls[].function.arguments`. Update AC-49 to add four fixtures:
     - whitespace-mutated bypass (model adds `\n` inside the block, request has none) — guard fires;
     - `tools[].description` injection — guard fires;
     - file-content false positive (request reads a file containing a literal tool-call example) — guard does NOT fire because of name-match scoping;
     - assistant-history argument injection — guard fires.

### H-3 — §10d.4 per-provider auto-downgrade creates a buyer-vs-buyer DoS attack surface

- **Codex blind-spot category:** CRITIC-2 (Threat-model holes in v0.2 additions) — codex security lane absorbed the streaming-mode header as "operator transparency"; no lane modeled the auto-downgrade's attack surface.
- **SPEC location:** §10d.4 (line 783), AC-45 (line 604), `X-MacProvider-Streaming-Mode: buffered_provider_downgrade` value definition (line 786).
- **The claim:** `"For Cline-targeted compatible models, v0.2 streaming defaults to token-incremental tool-call streaming. Operator configuration MUST be able to force buffered-to-end behavior as a kill switch. A provider that emits malformed incremental streams MUST be automatically downgraded per provider to buffered-to-end behavior."` AC-45 fail condition: `"one provider's malformed incremental stream disables streaming globally for all providers"` — meaning the SPEC explicitly scopes downgrade to the offending provider, not globally.
- **The refutation:** The trigger condition is "malformed incremental streams from a provider." But malformed streams are a function of (model, prompt, generation sampling) — not of provider identity. The SAME provider serving the SAME modelID can produce a clean stream for one prompt and a malformed stream for another, because the model's output grammar is prompt-conditioned. This creates a buyer-vs-buyer attack:

  - Buyers A, B, C are sticky-routed (per SPEC-002 sticky routing) to Provider X.
  - Attacker Buyer A submits prompts engineered to elicit malformed tool-call output from Provider X's Qwen3-32B: e.g., low-temperature prompts where the model emits a half-formed `<tool_call>` then runs into `max_tokens`, or prompts that exploit known Qwen3 long-tail tokenization quirks to produce mixed-sentinel output, or prompts containing exotic Unicode argument values that the parser's streaming accumulator rejects mid-stream.
  - Each such request marks Provider X's stream history as "malformed" → after the SPEC's (unspecified) threshold, Provider X is auto-downgraded.
  - Buyers B and C — who are routed to Provider X for legitimate Cline work — now see `X-MacProvider-Streaming-Mode: buffered_provider_downgrade`. Their Cline UX degrades from incremental to buffered-to-end. For Cline, that's the difference between "watching `write_to_file` arguments stream in" and "waiting 15-30 seconds for full generation to finish before any tool-call event arrives" — exactly the UX problem §10d.4 is supposed to prevent.
  - Buyer A pays nothing extra to attack — they pay only for their own (failed) inference. The cost lands on B, C, and Provider X.

  The SPEC defines neither (a) the auto-downgrade threshold (one malformed stream? 5%? 50%?), (b) the attribution model (per-buyer? per-provider regardless of buyer?), (c) the recovery path (does the provider ever auto-upgrade? operator-only? after time T?), nor (d) buyer-side awareness beyond the diagnostic header. AC-45 only requires "correlation between header, operator/provider state, and request log" — it does not gate the attack surface.

  This is also asymmetric: Provider X has no defense. There is no per-buyer rate limit on "malformed stream history contributions." A buyer can repeatedly DoS the same provider's streaming UX for the entire sticky pool by sending the same engineered prompt 100 times.
- **Severity rationale:** HIGH because (a) the attack is reachable from any authenticated buyer with no extra privilege; (b) it harms a competitor's Cline UX (the v0.2 release-gate framework) without harming the attacker; (c) it lets a single malicious buyer impose buffered-to-end on a provider's entire sticky pool, which is exactly the failure mode `buffered_kill_switch` exists to gate operator-only; (d) the SPEC's recovery semantics are completely unspecified — a downgraded provider may never auto-recover, making the attack persistent. Codex security lane signed off because the **header** is honest (it tells the truth about the downgrade); no lane asked who gets to cause the downgrade. Codex PD signed off because operator kill-switch + downgrade is a sensible operational pattern; no lane asked about cross-buyer blast radius.
- **Recommended fix:** Add normative §10d.4 sub-section:
  ```
  Auto-downgrade attribution and recovery: auto-downgrade decisions MUST be
  per-(provider, buyer) when buyer attribution is available, and per-provider
  only as a fallback. Per-provider auto-downgrade MUST require at least N
  distinct buyers (N >= 3) to have observed malformed streams from that
  provider within a sliding window W (recommended 10 minutes). Per-buyer
  auto-downgrade fires at the first observed malformed stream from that
  buyer against that provider. Auto-downgrade decisions MUST auto-recover
  after R minutes of clean streams (recommended R = 30). Operator MAY
  pin a downgrade past auto-recovery via the operator kill switch.
  ```
  Update AC-45 to add: malicious-buyer attack fixture (one buyer submits 10 engineered malformed-stream prompts; provider's other buyers continue to see `incremental` mode) and auto-recovery fixture (downgraded provider recovers to `incremental` after R clean streams from a different buyer).

---

## MEDIUM findings

### M-1 — AC-44 timing instrument crosses untrusted clock domains without skew bound

- **Codex blind-spot category:** CRITIC-4 (Mechanical-but-unimplementable AC).
- **SPEC location:** AC-44 (line 602), §10d.4 (lines 783-815).
- **The claim:** `"Provider-side timestamp instrumentation is REQUIRED: t_tool_call_open_detected (provider-internal native opening detected), t_first_forwarded_sse_byte (coordinator-side first forwarded SSE byte for that tool-call argument stream), and t_first_gateway_byte (gateway-side first byte delivered to the buyer connection). ... Per-class hardware target: t_first_gateway_byte - t_tool_call_open_detected p95 ≤ 1500 ms on M4."`
- **The refutation:** `t_tool_call_open_detected` is sampled on the **provider's clock** (provider = Mac, e.g. M4 hardware running the binary, e.g. user's home or office Mac). `t_first_gateway_byte` is sampled on the **gateway's clock** (gateway = Pearl VPS Linux instance per project CLAUDE.md). The subtraction `t_first_gateway_byte - t_tool_call_open_detected` is **cross-machine clock arithmetic with no NTP-sync guarantee, no skew correction, and no monotonic-clock invariant.** A 1500 ms p95 target is meaningless when the clock skew between an arbitrary M4 home Mac and Pearl VPS can be several seconds and can drift between samples. Even if both machines run NTP, NTP is accurate only to ~10-100 ms under good conditions; under cellular tethering or congested home networks, drift is unbounded. The AC's p95 gate is also undefined: p95 over what sample? Per-class M4 hardware spans many physical machines.
- **Severity rationale:** MEDIUM. Not money-path, but a release-gate AC that cannot be passed deterministically. A v0.2 IMPL author will find this AC unimplementable as written and will either (a) silently drop the p95 gate or (b) approximate with single-clock estimation, breaking the AC's claimed precision. Codex code lane signed off because the instrumentation names sound concrete. No lane asked which clock domain owns each timestamp.
- **Recommended fix:** Change the timing definition to use a single clock domain for the p95 budget. Either:
  - (a) Use the **provider's clock** for both `t_tool_call_open_detected` and `t_provider_first_byte_sent_to_relay`, and gate on `t_provider_first_byte_sent_to_relay - t_tool_call_open_detected` (purely provider-internal, no cross-clock arithmetic). Add separate single-direction propagation budgets for relay→gateway hops if needed; OR
  - (b) Add an explicit NTP-skew tolerance (e.g., "all instrumented machines MUST be NTP-synced to drift ≤ 50 ms" with verification fixture) and increase the 1500 ms target to absorb skew; OR
  - (c) Mark AC-44 as evidence-only (release smoke) and remove the mechanical p95 gate.

### M-2 — Aggregate cap composition admits a plausibly-legitimate request that approaches O(MiB) decoded prompt material

- **Codex blind-spot category:** CRITIC-1 (Cross-section consistency at distance) + cap compositionality.
- **SPEC location:** AC-50 (line 614), AC-51 (line 616), AC-52 (line 618), AC-53 (line 620), AC-54 (line 622), §10d.1 cap list (lines 744-750).
- **The claim:** Aggregate caps: raw body 4 MiB, tool-result content aggregate 1 MiB, assistant-history `function.arguments` aggregate 2 MiB, messages 256, tool calls 128.
- **The refutation:** A request can pass every individual cap while pushing the provider's prompt-rendering pipeline into a 6-7 MiB decoded UTF-8 working set:
  - 256 messages × up to 16 KiB user/system content each ≈ 4 MiB (well under raw body cap if base64-free).
  - + 1 MiB aggregate `role:"tool"` content
  - + 2 MiB aggregate assistant-history `function.arguments`
  - = ~7 MiB of decoded prompt material to render through the §3.8 family template.
  - The renderer must process this entirely before model inference (Qwen3 chat-template rendering is single-pass, no streaming). On a phase3-binary Mac with limited RAM, this is non-trivial — Qwen3-32B-4bit already takes ~18 GiB of unified memory; a 7 MiB additional working set is small in absolute terms but compounds with the parser-side accumulator (`max_concurrent_per_buyer × 2 MiB` per §10d.4 line 813).
  - Worse, the SPEC does NOT cap aggregate user/system content. The 4 MiB raw body cap (AC-50) is the only bound on user/system content size. A buyer can fill ~3 MiB of raw body with user/system content (after JSON overhead) and still satisfy all other aggregate caps.
- **Severity rationale:** MEDIUM. Not a security CRITICAL because the raw-body cap eventually bounds total decoded material at ~4 MiB worst case (JSON overhead is small for ASCII text). Not a HIGH because Qwen3-32B-4bit's working set dwarfs the prompt material. But the SPEC's stated "v0.2 request/streaming DoS bounds now include aggregate request caps" (v0.2.1 change-log line 23) is overclaimed — the aggregate caps protect specific fields, not the total decoded prompt size that hits the renderer. A v0.2 IMPL author may believe "aggregate caps protect me from a 7 MiB prompt" when they do not. Codex security signed off because each individual cap is correctly enforced. No lane composed them.
- **Recommended fix:** Add a single explicit aggregate-decoded-prompt cap to §10d.1 (e.g., "Total decoded UTF-8 byte length across messages[].content, role:"tool".content, and assistant-history tool_calls[].function.arguments MUST be ≤ 6 MiB; HTTP 413 `request_decoded_too_large`") OR document explicitly in §10d.1 that the 4 MiB raw-body cap is the binding total bound and that the other aggregate caps are per-channel sub-bounds, NOT additive sub-bounds. Currently the SPEC reads as if the aggregate caps ADD UP to the bound (4 + 1 + 2 = 7 MiB) which they do not.

### M-3 — AC-46 `null` sentinel fail condition is unverifiable in adversarial settings

- **Codex blind-spot category:** CRITIC-4 (Mechanical-but-unimplementable AC).
- **SPEC location:** AC-46 (line 606), §10d.0.1 (line 730).
- **The claim:** `"Fail condition: missing field, non-null non-hex value, null when a provider hash is known, inclusion in SPEC-015 canonical output binding, or v0.2 enforcement based on a registry that §10c has explicitly deferred."`
- **The refutation:** The `null when a provider hash is known` clause is unverifiable from the buyer/test side. The only entity that knows whether the provider has a "known served model hash" is the provider itself (the SPEC-008/SPEC-011 model_hash subsystem on the provider's binary). A test fixture inspecting only the HTTP response cannot distinguish:
  - (a) provider legitimately has no known hash → `null` is correct; from
  - (b) provider has a hash but chose to emit `null` to suppress diagnostic visibility → `null` is non-compliant.
  A malicious or buggy provider can satisfy the AC by always emitting `null`. The AC's only meaningful fixture is one that ALSO has access to the provider's internal `ModelHash` state — i.e., the AC is verifiable only as an in-process unit test on the provider binary, NOT as an end-to-end CI gate from gateway side. Yet AC-25a treats this field as a Cline release gate evidence field (line 560: `"Cline session success whether usage.macprovider_model_hash_observed is a known lowercase hex hash or null"`).
- **Severity rationale:** MEDIUM. The field's stated purpose is "passive evidence to log the served model_hash against the modelID-declared family." That use case works regardless of whether the provider could lie. But the SPEC frames the `null when known` clause as a normative MUST, when in reality it is unenforceable from outside the provider process. PD lane signed off on AC-46 because the field name is honest. No lane probed whether the AC's fail conditions are testable.
- **Recommended fix:** Reword AC-46 fail condition: `"Fail condition: missing field, non-null non-hex value, inclusion in SPEC-015 canonical output binding, or v0.2 enforcement based on a registry that §10c has explicitly deferred. (Note: a provider always emitting null is compliant; the SPEC-018 v0.2 contract does NOT require the provider to expose model_hash through this field — the field is observation-only, and the v0.3 registry is the gate for normative model_hash binding.)"` Update §10d.0.1 to match.

### M-4 — Path B precedent ("locked invariants can be amended via change-log entry") is under-specified for future use

- **Codex blind-spot category:** CRITIC-6 (Locked-content drift) — codex avoids touching v0.1.5; if v0.2 additions weaken v0.1.5 invariants in subtle ways, codex doesn't catch it.
- **SPEC location:** §10c amendment paragraph (line 666), v0.2.1 change-log entry (line 25, "Load-bearing amendment" paragraph).
- **The claim:** `"Locked invariants are NOT immutable, but they require an explicit named amendment with rationale; this is the first such amendment in SPEC-018."` (v0.2.1 change-log) and the actual amendment at line 666 (`"AMENDED v0.2.0/v0.2.1: the v0.1.3-locked clause requiring v0.2 to enforce unknown-model_hash fail-closed via a registry is amended to defer registry to v0.3. Rationale: narrow v0.2 scope (Cline drop-in) made the curation work strategically premature."`).
- **The refutation:** This is the first amendment to a locked invariant in SPEC-018's history. The precedent it sets is governed by two phrases: "explicit named amendment with rationale." Neither phrase specifies:
  - Who can amend? (Any v0.2.x author? Requires a major version bump? Operator-only?)
  - Can amendments **weaken** security invariants or only **defer** them? (The current amendment defers; the SPEC does not foreclose weakening.)
  - What gates approval? (Codex 4-lane 0/0/0? Critic 0/0/0? Both?)
  - Can amendments be made within a patch version (v0.2.1 → v0.2.2 amends locked v0.1.5)? The current example shows yes.
  - Is there a rollback path if the amendment is later judged a mistake? (The amendment is now itself locked; can v0.3 unamend?)
  A future v0.3.7-author wanting to defer a v0.2.x security invariant they find inconvenient now has a textbook precedent: write a change-log entry, name it explicitly, claim narrow scope. The amendment is one paragraph; the rationale is one sentence ("narrow v0.2 scope made it strategically premature").
- **Severity rationale:** MEDIUM. Not a v0.2.2 lock-blocker because the actual amendment (registry deferral) is sound. But the **precedent** is the lock-blocker for future versions, and v0.2.2 is the version that sets it. Codex architect lane signed off because v0.1.5 content is out of audit scope per round-prompt convention. No lane was scoped to evaluate amendment-process governance. The v0.1.5 critic pass surfaced exactly one such cross-version invariant tension (M-4 `call_` prefix), and v0.2.2 ratifies a much more powerful precedent without governance.
- **Recommended fix:** Add to §10c a new subsection:
  ```
  ### 10c.1 Amendment process for locked invariants

  A locked invariant in any v0.X.Y SPEC may be amended by a later
  v0.X+1.0 or v0.X+1.Z draft via an explicit named amendment ONLY if:

  1. The amendment defers, narrows, or removes the invariant — NOT
     weakens a security invariant in a way that creates a new attack
     surface for already-deployed buyers.
  2. The amendment lands in a **minor or major** version bump
     (v0.X+1.0 or v0.Y), not a patch bump (v0.2.1 → v0.2.2).
     v0.2.0/v0.2.1's registry-deferral amendment is grandfathered.
  3. The amendment is named in the change-log with: (a) the invariant
     being amended, (b) the rationale, (c) the alternative that
     replaces the deferred behavior in the same version, and (d) the
     audit gate at which the amendment was reviewed (codex N-lane,
     critic blind-spot, both).
  4. Amendments to money-path or trust-boundary invariants require
     critic blind-spot 0/0/0 and codex security lane READY TO LOCK
     in the same round.
  ```

---

## Minor findings

### m-1 — AC-25a's "Cline v4.0.0 or version pinned in tools/version-pins/cline-spec-018-v0_2_2.txt" creates a non-existent pin-file dependency

AC-25a (line 560) pins Cline at `v4.0.0` OR a version in `tools/version-pins/cline-spec-018-v0_2_2.txt`. The file does not yet exist in the macprovider-poc repo. AC-25a also does not specify which file commits it (cf. v0.1.4's explicit IMPL-prompt obligation in §1.2 for the openai-python pin file). Recommend: add to §1.2 (the IMPL-prompt scope subsection) an explicit obligation to commit `tools/version-pins/cline-spec-018-v0_2_2.txt` AND `tools/version-pins/cline-vercel-ai-sdk-openai-compatible-v0_2_2.txt` (the Vercel AI SDK version Cline 4.0.0 bundles — recommended by H-1).

### m-2 — AC-50 raw-body cap vs SPEC-006 gateway 1 MiB default produces conflicting buyer experience

AC-50 caps raw body at 4 MiB at coordinator/provider boundary; §10d.1 (line 746) notes SPEC-006 gateway defaults to `request_body_bytes: 1048576` (1 MiB). The two are not aligned — a buyer hitting 2 MiB request through the gateway sees `request_body_too_large` from the gateway with SPEC-006's spelling, NOT SPEC-018's `request_body_too_large`. AC-50 says either-or (`"or the SPEC-006 buyer-API aligned request-body-too-large code if SPEC-006 already owns that exact spelling"`). This is fine for tests but inconsistent for buyer documentation. Recommend: clarify in §10d.1 that the **effective** body cap for v0.2 SPEC-018-compliant deployments is `min(SPEC-006-gateway-cap, 4 MiB)` and that buyers must reference SPEC-006 for their actual operational cap.

### m-3 — AC-46's `usage.macprovider_model_hash_observed` field placement is in `usage`, but AC-46 says "additive, non-canonicalized" — this could interact with OpenAI SDK strict-mode schema validators

`usage` is the OpenAI canonical usage object (`prompt_tokens`, `completion_tokens`, `total_tokens`, etc.). Some downstream tooling (especially proxies and observability layers) treats `usage` as a fixed schema and rejects unknown keys. AC-23 forward-compat regression covers parsing-not-raising, but does not cover strict-schema validators downstream of the SDK. Recommend: AC-23 explicitly add a fixture that a strict-mode usage parser (e.g., a Pydantic model with `extra="forbid"`) does NOT silently break — OR document that the field lives in a non-strict scope. Reasonable alternative: place the field at `choices[0].message.macprovider_model_hash_observed` or in a top-level `macprovider` extension key, which buyers' strict-schema parsers won't touch.

---

## Open Questions

### Q-1 — Does Cline 4.0.0 actually use Vercel AI SDK's `@ai-sdk/openai-compatible` for all OpenAI-wire targets, or does it have a fallback path?

This audit confirmed via `sdk/packages/llms/src/providers/vendors/openai-compatible.ts` (Cline main `92806c60`) that the openai-compatible vendor uses `createOpenAICompatible` from `@ai-sdk/openai-compatible`. But Cline also has `openai.ts` (uses `createOpenAI` from `@ai-sdk/openai` — i.e., the official OpenAI vendor). A user pointing Cline at `coordinator.streamvc.live` configures the OpenAI-compatible provider (because macprovider is not "OpenAI"). The H-1 finding stands. But IMPL should also confirm: does Cline have ANY user-selectable mode that routes through openai-python or openai-node? If yes, AC-48 may have a real openai-python path under specific Cline configurations. Codex did not investigate this; this audit did not investigate every Cline provider source. Recommend: IMPL spike to enumerate every Cline 4.0.0 LLM-vendor entry point and confirm SDK family before locking AC-48.

### Q-2 — Should §10c.1 amendment process retroactively re-review the v0.2.0/v0.2.1 registry-deferral amendment?

If §10c.1 is added per M-4, the v0.2.0/v0.2.1 registry-deferral amendment was made under no rule. M-4 grandfathers it. But a stricter reading would re-run the codex security lane on the v0.1.3-locked invariant to confirm the deferral is security-acceptable. Codex security lane signed off in v0.2.1 r2 (READY TO LOCK), but for the deferral mechanism itself, not for the precedent. Recommend: explicit codex security lane re-confirmation cycle on the v0.2.0/v0.2.1 amendment under any §10c.1 rule that adds future amendment process.

---

## Codex blind-spots verified

State per the 9 specific attack vectors in the audit prompt:

1. **AC-46 `usage.macprovider_model_hash_observed`** — PROBLEMATIC. M-3 (fail-condition unverifiable in adversarial settings) and m-3 (placement in `usage` may interact with strict-schema parsers).
2. **AC-25a CI fixture (Cline session determinism)** — PROBLEMATIC. m-1 (missing pin file obligation). The deeper determinism concern (Cline + LLM = non-deterministic model output) is NOT a HIGH finding because AC-25a specifies "≥ N turns / ≥ N tool calls / categories covered" rather than byte-exact transcript reproduction — the AC is a structural-equivalence gate, not a byte-equivalence gate. That's the right design call for a non-deterministic agent. Clean on this axis.
3. **AC-44 1500ms p95** — PROBLEMATIC. M-1 (cross-machine clock domain arithmetic without skew bound).
4. **AC-47/AC-48 §8.4.2/§8.4.3 split + openai-python terminal SSE** — PROBLEMATIC. H-1 (Cline doesn't use openai-python — it uses Vercel AI SDK).
5. **Minimal prompt-echo guard (§3.9)** — PROBLEMATIC. H-2 (whitespace bypass + scope incomplete + self-DoS pattern).
6. **Path B precedent (locked invariants amendment)** — PROBLEMATIC. M-4 (precedent under-specified for future use).
7. **§10d.4 streaming kill switch auto-downgrade** — PROBLEMATIC. H-3 (buyer-vs-buyer DoS).
8. **Aggregate caps composability** — PROBLEMATIC. M-2 (caps don't compose to bound the total decoded prompt; SPEC overclaims protection).
9. **Cline reality check** — CONFIRMED VIA SOURCE (Cline main `92806c60`, `package.json` v4.0.0 publisher `saoudrizwan` name `claude-dev`):
   - Cline uses `@ai-sdk/openai-compatible` (Vercel AI SDK), NOT openai-python or openai-node. → H-1.
   - Cline does not impose a `messages.length` cap (see `sdk/packages/agents/src/agent-runtime.ts` `cloneMessages` accumulating without bound). 256-message cap may bite long sessions. Logged as observation, not a SPEC bug — the SPEC's cap is conservative.
   - Cline `read_file` returns file content verbatim in `role:"tool"` messages. If a user asks Cline to read a file containing tool-call examples (e.g., SPEC-018 itself), §3.9 prompt-echo guard suppresses legitimate follow-up tool calls. → H-2(c).
   - Did NOT independently verify "tolerate the terminal SSE error frame as a non-success" claim against Vercel AI SDK source. H-1 fix recommends adding this gate (AC-48b) before lock.
   - Did NOT independently verify "reach `t_first_gateway_byte` within 1500ms" — this is impossible to verify without a live deployment; M-1 makes the AC unverifiable anyway.

---

## Verdict justification

**FIX REQUIRED.** Codex 4-lane 0/0/0 across 3 rounds is correctly diagnosed as "rare for a v0.X.Y SPEC of this scope and itself suspicious." Three lock-blocking HIGH findings (H-1 Cline+openai-python category error, H-2 prompt-echo guard bypass+self-DoS, H-3 streaming auto-downgrade buyer-vs-buyer DoS) match the v0.1.5 precedent at higher money-path stakes:

- v0.1.5 H-1 (AC-23 tautology) ↔ v0.2.2 H-1 (AC-48 tests wrong client stack)
- v0.1.5 H-2 (Claude Code framework overclaim) ↔ v0.2.2 H-1 (Cline → openai-python overclaim, restated)
- v0.1.5 H-3 (mixed-sentinel DoS) ↔ v0.2.2 H-2 (prompt-echo whitespace bypass + content false-positive DoS — same content-scan-defense anti-pattern)
- New in v0.2.2: H-3 streaming auto-downgrade weaponization — no v0.1.5 analog because there was no streaming-mode-selection surface in v0.1.5.

Mode operated in: started THOROUGH, escalated to ADVERSARIAL upon discovery of H-1 (Cline-vs-openai-python). ADVERSARIAL pass surfaced H-2 (the H-3-shaped content-scan vulnerability) and H-3 (buyer-vs-buyer DoS) — both v0.2-additive vectors that codex's per-lane scoping would not naturally compose.

Realist check applied:
- H-1: confirmed HIGH. Failure mode is "lock the SPEC with AC-48 testing the wrong SDK; v0.2 IMPL ships with no test of the Cline-stack money-path failure mode." Detection time is "until the first real Cline session hits a final-close failure and a tool_call slips past Cline's AgentRuntime, possibly triggering a destructive `execute_command` action." Not downgraded.
- H-2: confirmed HIGH. The whitespace bypass is one-token; the self-DoS pattern is common (any Cline session that reads documentation). Mitigated by "v0.3 has a full guard" but v0.2 ships with a defense that's both bypassable and a false-positive cost on legitimate use. Not downgraded.
- H-3: confirmed HIGH. Reachable from any authenticated buyer. Per-provider downgrade attribution + missing recovery = persistent attack. Cline UX degradation is the explicit thing §10d.4 promises NOT to allow. Not downgraded.

M-1 to M-4 each independently survive Realist Check at MEDIUM (none meet HIGH severity; none are mere style preferences).

Path to ACCEPT: absorb H-1/H-2/H-3 in v0.2.3 round; M-1 to M-4 ideally in the same round; re-fire codex security lane on the H-2/H-3 absorption; re-fire critic blind-spot. The same 4-lane 0/0/0 + critic 0/0/0 bar that v0.1.5 lock used should apply.
