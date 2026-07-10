# SPEC-018 v0.1.1 → v0.1.2 — Round 2 audit narrative

## Round summary

Four codex audit lanes re-fired against `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`). **Zero CRITICALs and zero HIGHs across all 4 lanes.** Product-design and security both returned READY TO LOCK on r1-absorption fidelity. Architect and code returned FIX REQUIRED with 5 MEDIUMs collectively — all polish/precision tightening, no normative redesign required.

| Lane | CRITICAL | HIGH | MEDIUM | MINOR | QUESTIONS | Verdict |
|---|---|---|---|---|---|---|
| Product-Design | 0 | 0 | 0 | 2 | 2 | READY TO LOCK |
| Security | 0 | 0 | 0 | 2 | 1 | READY TO LOCK |
| Architect | 0 | 0 | 2 | 1 | 0 | FIX REQUIRED |
| Code | 0 | 0 | 3 | 0 | 3 | FIX REQUIRED |
| **Totals** | **0** | **0** | **5** | **5** | **6** | mixed |

## r1-absorption fidelity (round-narrative claim verification)

Every round-1 finding marked absorbed in `specs/SPEC-018-r1-audit.md` was independently confirmed by the corresponding round-2 lane. Per-lane confirmations:

- **PD r1 C-1 + Arch r1 M-3** (Ring-1 overclaim): CONFIRMED across both lanes. §1, §1.1, §10a #1, §12 collectively re-scope honestly; no residual product overclaim.
- **PD r1 H-1, H-2**: CONFIRMED.
- **Sec r1 C-1** (Q6 prompt-injection): CONFIRMED. §3.2 modelID-match-required + §1 buyer-side validation obligation + §10a #2/#3 v0.2 closure together form a coherent v0.1/v0.2 security story. Residual: a tool-call-capable, modelID-matched legitimate provider can still echo hostile content; §1.1 warns users; v0.2 §10a #3 prompt-echo guard closes the residual case.
- **Sec r1 H-1** (commit-on-malformed-delta): CONFIRMED with minor residual — round-2 found that `function.arguments: "[]"` would pass "parseable JSON string" even though §2.3 requires JSON-object. Tightened in v0.1.2 §8.4 + AC-21.
- **Code r1 M-1, M-2, M-3** (citation drift): CONFIRMED — all three citations now accurate.
- **Code r1 Q-1, Q-2, Q-3** (AC scoping): CONFIRMED — AC-15a/AC-15b split is CI-verifiable + deploy-artifact; AC-18 is parametric; AC-4 is observed-unique-in-test.
- **Arch r1 H-1, H-2, M-1, M-2, M-4, m-1, m-2, Q-1**: CONFIRMED.

Two r1 absorptions had round-2 residuals (now resolved in v0.1.2):
- **Arch r1 m-3** (SDK altitude): Arch r2 M-2 found §2.3 still imposed an SDK obligation ("SDKs MUST JSON-parse and schema-validate before execution") inside the response-synthesis core. v0.1.2 removes the RFC-2119 line and points to §1 + AC-20 for buyer-side guidance.
- **PD r1 Q-1** (additive v0.2 invariant): PD r2 Q-1 confirmed the invariant was still absent. v0.1.2 adds §10c "Forward compatibility invariant (additive-only guarantee)" + AC-23.

## Net new findings (v0.1.1 → v0.1.2 absorption)

### Architect M-1 — §3.1 Qwen-row ambiguity
Round-1 §3.1 had two rows whose `modelID` predicate was `qwen2.5` (Qwen2.5/Qwen3 native + Qwen coding-tuned). Round-2 architect found that §3.6 table-order priority + the false parenthetical "no modelID matches more than one row" left the second Qwen row unreachable as a family selection. **Fix: collapse into one "Qwen (2.5 / 3 / Coder variants)" row.**

### Code Q-3 — Qwen3 modelID detection gap (convergent with Arch M-1)
§3.1 named "Qwen2.5 / Qwen3" but predicate was `modelID` substring `qwen2.5`. The production model `Qwen3-32B-4bit` does NOT contain `qwen2.5`. Under §3.2's modelID-match-required rule, Qwen3 models would NOT be detected as tool-call-capable — the product story breaks. **Fix: predicate becomes `qwen2.5` OR `qwen3`** (collapsed in the same row consolidation).

### Architect M-2 — §2.3 SDK obligation leak
v0.1.1 §2.3 line "SDKs MUST JSON-parse and schema-validate before execution" was a normative client/SDK requirement inside the provider response-synthesis contract. Contradicted §10b/§12 position that SDK packaging is downstream. **Fix: remove the RFC-2119 line; reference §1 + AC-20.**

### Code M-1 — §3.6 mixed-sentinel not in IMPL deltas
v0.1.1 §1 named two IMPL deltas (§3.2 modelID-required + §8.4 commit validator). AC-22 mixed-sentinel fallback was normative but not in the as-built parser. **Fix: §1 enumerates three IMPL deltas (§3.2, §3.6, §8.4); §3.6 itself explicitly names the IMPL delta.**

### Code M-2 — §10a #2 citation drift
v0.1.1 cited `phase4-coordinator/internal/pool/provider.go:158-162` for SPEC-008/SPEC-011 `model_hash` infrastructure. That range is actually `SupportedModels`/`PublishesSupportedModels`. ModelHash is at `:132-133`; heartbeat update at `:1001-1052`. **Fix: corrected citations + clarifying language about which fields are which.**

### Code M-3 — §8.4 citation phrasing
v0.1.1 §8.4 `Source:` cited the coordinator commit-signal code path as if proving current behavior, but the cited `hasOpenAIDeltaSignal` accepts any non-empty `tool_calls[]`. **Fix: relabel as "current commit-signal path to patch" with explicit reference to v0.1.2 IMPL prompt absorbing the validator.**

### Architect m-1 — §7 informative voice
§7 was reframed informative but still used "MUST satisfy" RFC-2119 voice. **Fix: lowercase to "need to satisfy."**

### Security m-1 — §8.4 + AC-21 `arguments` JSON-object tightening
v0.1.1 said `function.arguments` must be "present and parseable as a JSON string" — `"[]"` would pass. **Fix: require JSON string whose decoded value is a JSON object.**

### Security m-2 — §5 stale text
v0.1.1 §5 said "§10b reserves both [`max_tool_calls` + `function.arguments` cap] as future-enhancement candidates," but §10a #7 makes `function.arguments` cap v0.2-gating. **Fix: disambiguate — `function.arguments` cap is §10a #7 v0.2; `max_tool_calls` is §10b future.**

### Security Q-1 — v0.2 unknown-hash fail-closed (rolled into §10a #2)
Security r2 Q-1 surfaced that v0.2 model-hash registry design MUST specify fail-closed for unknown/unregistered hash, not fall back to modelID substring. **Fix: §10a #2 explicitly requires fail-closed unknown-hash behavior in v0.2 design.**

### PD m-1 — "certificate" overstates formality
**Fix: §1 narrowly defines "certificate" = AC-16a + AC-16b first-turn-parse evidence only.**

### PD m-2 — §10a #2 buyer-facing sentence
**Fix: added one sentence — "prevents a provider from advertising a tool-call-capable model family while running a different model or grammar."**

### PD Q-1 — additive v0.2 invariant
**Fix: new §10c + AC-23.**

### PD Q-2 — v0.2 framework readiness signal
**Fix: §11 Q1 reframed as a v0.2 product decision with options (a) one primary framework / (b) named compatibility matrix / (c) middle ground.**

## v0.1.2 absorption summary

14 distinct edits across the SPEC body. Five sections see substantive change:
- **§1** narrows "certificate" + enumerates 3 IMPL deltas + adds AC-20 documentation locations
- **§3.1** Qwen row collapse + `qwen3` substring + SKU note
- **§3.6** mixed-sentinel rule references Qwen/Llama family explicitly + names IMPL delta
- **§5** disambiguated stale text on caps
- **§8.4 + AC-21** require JSON-object `arguments`; relabel source as "current commit-signal path to patch"
- **§10a #2** corrected citations + buyer-facing sentence + fail-closed unknown-hash
- **§10c (new)** forward compatibility invariant + AC-23
- **§11 Q1** product-decision framing

## Forward signals for round 3

All four lanes re-fire against v0.1.2 (commit pending) for the **lock confirmation round**. Expected convergence:

- **Architect**: r2's M-1 (Qwen ambiguity) and M-2 (SDK obligation) absorbed; m-1 (§7 voice) absorbed. Expect 0/0/0/≤1m/0Q.
- **Code**: r2's M-1 (mixed-sentinel IMPL-delta naming), M-2 (citation fix), M-3 (relabel) all absorbed; Q-3 (Qwen3 detection) absorbed via §3.1 collapse. Expect 0/0/0/0m/≤1Q.
- **Security**: r2's m-1 (JSON-object), m-2 (§5 disambiguation), Q-1 (unknown-hash fail-closed) all absorbed. Expect 0/0/0/≤1m/0Q.
- **Product-Design**: r2's m-1 (certificate narrow definition), m-2 (buyer-facing sentence), Q-1 (additive invariant), Q-2 (framework signal product decision) all absorbed. Expect 0/0/0/≤1m/0Q.

Lock convergence requires **0 CRITICAL + 0 HIGH + 0 MEDIUM across all 4 lanes**. With r2 already at 0/0/5 and all 5 MEDIUMs targeted in v0.1.2, round 3 should converge to lock. If any new MEDIUM surfaces in r3, it's likely a side-effect of the §3.1/§10c restructure and absorbs in a small v0.1.3 polish.

Round 3 target: **lock v0.1.2 as the final v0.1 family lock**.
