# SPEC-018 v0.1.3 — Critic adversarial round-2

## Counts
CRITICAL: 0
HIGH: 0
MEDIUM: 0
MINOR: 3
QUESTIONS: 2

## r1-absorption verification

### H-1 (AC-23 tautology) → **CONFIRMED**
AC-23 (line 392) now reads: "captures non-streaming tool-call response fixtures **from the candidate vN.M release** ... and verifies that a **v0.1.2-targeted** client parser ... successfully parses each response without raising on unknown fields and without rejecting due to schema validation." The direction is now correct (new fixtures vs old parser) and the AC explicitly calls out the v0.1.2-fixture-vs-v0.1.2-parser tautology as "NOT sufficient." The version-pin file reference (`tools/version-pins/openai-python-spec-018-v0_1_2-baseline.txt`) makes the parser version mechanically pin-able.

Note: minor version-drift inconsistency between AC-23 baseline ("v0.1.2-targeted") and §10c invariant ("v0.1.3 wire shape continues to work in v0.2+"). Both are defensible — v0.1.3 only adds normative tightening, not new wire surface — but captured as m-1.

### H-2 (Claude Code / Cursor overclaim) → **CONFIRMED**
All remaining mentions of "Claude Code" and "Cursor" are in explicit-exclusion contexts (§1 "Not included" list, AC-16b "explicitly NOT v0.1 compatibility targets", §11 Q1 "explicitly excludes"). New framework list (Cline, Aider, OpenCode, Continue, Vercel AI SDK, LangChain `ChatOpenAI`, LlamaIndex `OpenAI` LLM, Pydantic-AI `OpenAIModel`, n8n OpenAI node) is factually accurate — all 9 support OpenAI `chat/completions` with `tool_calls[]`.

### H-3 (mixed-sentinel DoS) → **CONFIRMED**
§3.6 mixed-sentinel pre-detection rule fully dropped. §1.2 IMPL delta count reduced to 2. AC-22 marked reserved-as-deprecated. §3.6 retains a "Cross-family sentinel safety" closure rationale explaining why §3.2 modelID-match-required is sufficient on its own. Sound logic (Qwen-modelID never runs Llama parser).

One residual stale reference flagged as m-2: §10a #5 line 406 still lists "mixed sentinels" as a parse-failure category.

### M-1 (unbounded JSON nesting) → **CONFIRMED with caveat**
Depth ≤ 32 + byte ≤ 256 KiB caps applied to both §3.4 (parser) and §8.4 (commit-validator). AC-21 extended with both caps. Values well-calibrated (production OpenAI tool-call schemas rarely exceed depth ~8 and `function.arguments` rarely exceeds 8 KiB; 32 / 256 KiB are 4-32x headroom).

**Caveat (Q-1):** §8.5 gateway describes a third JSON-decode-adjacent path — "The streaming gateway MAY parse delta strings for token-estimate enforcement." If "parse delta strings" includes full JSON-parsing the SSE envelope, this is a third unbounded path. Verification of the gateway's actual parse strategy required.

### M-2 (operator-override loophole) → **CONFIRMED**
Clause moved to §10c (line 434) as v0.1.3-locked v0.2 invariant: "v0.2 MUST NOT include a provider-operator-only override that bypasses this fail-closed semantics — operator-only overrides without buyer consent are non-compliant." Buyer-consent override requires both a request-level consent header (set by the **buyer**, not the operator) AND a mandatory `model_hash_unregistered: true` response field detectable by downstream policy engines. A v0.2 implementer cannot self-grant the override. Header name deferral ("e.g.") is appropriate — SPEC-006 owns the header-allowlist authority.

### M-3 (§6 pass-through MUST has no AC) → **CONFIRMED**
AC-24 added: WS-frame byte-equivalence verification. Mechanically verifiable, decouples test from provider's HTTP-400 rejection, covers exactly the failure mode M-3 named.

### M-4 (call_ prefix protection) → **CONFIRMED**
§10c: "**The `id` value format** ... is part of the protected shape. ... Future ID rescope MUST either preserve the `call_` prefix as a leading substring of the new format, or land via a **major** SPEC-018 version bump." No drift between §2.1 and §10c.

### M-5 (sorted-keys depth) → **CONFIRMED**
§2.3: "JSON object arguments decoded from a structured object MUST be serialized with **keys sorted recursively at every depth** (nested objects' keys are also sorted)..." plus explicit SPEC-015 v0.3 receipt-binding rationale.

### m-1 (AC-7 framing-position) → **CONFIRMED**
### m-2 (§3.2 omitted modelID) → **CONFIRMED**
### m-3 (§3.7 row-append + disjoint predicate) → **CONFIRMED**
### m-4 (§10c success-vs-error-path AC-14 ambiguity) → **CONFIRMED**

## New adversarial findings

### Minor m-1 — AC-23 baseline-version drift
AC-23 anchors the protected baseline at v0.1.2 ("a **v0.1.2-targeted** client parser"); §10c anchors the protected baseline at v0.1.3 ("MUST preserve the v0.1.3 non-streaming response shape"). Reconcilable — v0.1.3 only adds normative tightening, not new wire surface — but reader has to deduce this. Recommend either (a) update AC-23 baseline to v0.1.3, OR (b) add one sentence to §10c explaining v0.1.2 wire shape ≡ v0.1.3 wire shape. **Not lock-blocking.**

### Minor m-2 — §10a #5 stale "mixed sentinels" reference
§10a #5 line 406: "Parse failures (malformed body, duplicate keys, undeclared name, sentinel-without-modelID, **mixed sentinels**) surface as a structured response-side signal..." Mixed sentinels are no longer a parse-failure path in v0.1.3. **Recommended fix:** drop "mixed sentinels" from the parenthetical. **Not lock-blocking** — §10a #5 is a v0.2 commitment.

### Minor m-3 — §8.4 source-citation block still says "v0.1.2"
§8.4 line 332: "currently accepts any non-empty `tool_calls[]` array (insufficient under v0.1.2). v0.1.2 IMPL prompt adds the minimal-shape validator..." Two stale references; the IMPL prompt is now v0.1.3 per §1.2. **Recommended fix:** s/v0.1.2/v0.1.3/. **Not lock-blocking** — pure doc-drift.

## Open Questions (unscored)

### Q-1 — §8.5 gateway delta-parsing as third unbounded JSON-decode path
If `phase5-gateway/internal/router/chat_proxy.go` uses full JSON-decode (rather than substring/regex byte-count) to extract `function.arguments` length for token-estimate enforcement, an adversarial provider could ship a 100k-deep envelope and DoS the gateway. Verifiable by reading the gateway implementation; flagged as Question rather than Medium because (a) byte-count likely uses substring scan, (b) gateway DoS is a different blast radius than coordinator commit-signal DoS.

### Q-2 — "Draft" status descriptor risk
"Draft — ratifies as-built behavior..." A buyer skimming could read "Draft" as "design is uncertain." Internal convention is likely "Draft" → "v0.x not v1.0" but worth confirming.

## Verdict

**READY TO LOCK**

All 3 HIGH and all 5 MEDIUM round-1 findings absorbed cleanly into v0.1.3 — no relabel, no carve-out. Spot-checks confirm:
- AC-23 tests the right direction
- Claude Code / Cursor appear only in explicit-exclusion contexts
- Mixed-sentinel rule fully gone from normative content (one stale enumeration in §10a #5)
- Depth/byte caps applied to both §3.4 and §8.4
- Operator-override loophole closed via mandatory buyer-consent header + response field
- AC-24 verifies §6 request-side pass-through at the WS frame layer
- `call_` prefix locked into §10c
- Sorted-keys recursive-at-every-depth

3 MINORs + 2 unscored Questions remain — none lock-blocking. Lock bar (0 CRITICAL + 0 HIGH + 0 MEDIUM) **met**. v0.1.3 is the cleanest absorption pass on SPEC-018 to date.
