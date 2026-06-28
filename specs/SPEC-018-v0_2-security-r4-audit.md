# SPEC-018 v0.2.3 -- SECURITY lane round-4 audit

Date: 2026-06-28
Lane: security
Scope: defensive round-4 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.3 after Claude blind-spot absorption, limited to r3 security regression checks, closure of security-relevant blind-spot absorptions, and fresh security findings in the v0.2.3 additions.

## Counts

CRITICAL: 0
HIGH: 0
MEDIUM: 0
minor: 0
Q: 0

## Verdict

READY TO LOCK reconfirmed from the security lane.

v0.2.3 does not regress the r3 security READY TO LOCK verdict. The load-bearing blind-spot absorptions are security-clean: the net-negative minimal prompt-echo guard is deleted rather than shipped as a bypassable/self-DoS defense; the residual same-family echo risk is explicit and deferred to v0.3; Cline terminal-error gating is separated from openai-python and now targets the actual Cline/Vercel AI SDK path; streaming auto-downgrade is scoped to the offending buyer/provider tuple with recovery; request-size and timing additions are validation/evidence gates, not settlement authority.

## R3 security verdict regression check

Status: HOLDS.

Evidence:
- r3 security concluded v0.2.2 was READY TO LOCK because aggregate caps were pre-inference request-validation gates, AC-46 was observation-only, and `prompt_echo_blocked` was no longer buyer-visible (`specs/SPEC-018-v0_2-security-r3-audit.md:15-20`).
- v0.2.3 keeps the money path unchanged: final-close failures remain `FaultBreakerQualifying`, settle zero provider-positive credits, produce no receipt, and do not write sticky-route success (`specs/SPEC-018-agentic-tool-calling.md:498`, `:852`).
- AC-46 remains non-canonicalized and observation-only; it still must not drive parser/profile selection, settlement, or SPEC-015 output binding (`specs/SPEC-018-agentic-tool-calling.md:620`, `:768`).
- v0.2.3 removes the v0.2.1 prompt-echo guard entirely and states there is no `prompt_echo_blocked` buyer-visible or internal guard-trigger path in v0.2.3 (`specs/SPEC-018-agentic-tool-calling.md:740`).

Security conclusion: no r3 security regression. The r3 "internal code only" prompt-echo conclusion is superseded by a cleaner state: there is no active v0.2 prompt-echo guard path to expose, bypass, or self-DoS.

## Blind-spot closure status

### Critic H-1 -- Cline/openai-python mismatch

Status: CLOSED for security.

Evidence:
- AC-48 is split into AC-48a for openai-python and AC-48b for Cline through `@ai-sdk/openai-compatible` at Cline's OpenAI-compatible provider path (`specs/SPEC-018-agentic-tool-calling.md:624`, `:626`).
- Section 10d.4 explicitly states that Cline v4.0.0 uses Vercel AI SDK, not openai-python, and that Cline-specific terminal-SSE-error behavior is gated by AC-48b (`specs/SPEC-018-agentic-tool-calling.md:828`).
- AC-43 is explicitly limited to successful openai-python streaming forward compatibility and says terminal-error streams are expected to raise in the SDK (`specs/SPEC-018-agentic-tool-calling.md:614`, `:858`).

Security conclusion: the Cline money-path question is no longer hidden behind the wrong SDK fixture. Terminal final-close failures cannot be declared release-gated for Cline unless the Cline/Vercel path itself proves no dispatchable tool call reaches `AgentRuntime`.

### Critic H-2 -- Minimal prompt-echo guard bypass and self-DoS

Status: CLOSED by Path (a), with documented residual risk.

Evidence:
- v0.2.3 deletes section 3.9 and AC-49; active references to section 3.9 are historical/amendment references, not normative guard behavior.
- The v0.2.3 change log states that v0.2.3 ships without prompt-echo mitigation, names the residual same-family echo attack, and explains why the deleted minimal guard was worse than no guard (`specs/SPEC-018-agentic-tool-calling.md:23`, `:29`).
- Section 10c carries the in-place `AMENDED v0.2.3` paragraph for the deletion, including residual risk and v0.3 full-guard requirements (`specs/SPEC-018-agentic-tool-calling.md:686`).
- Section 10c.1 Amendment 2 repeats that same-family echo remains unmitigated in v0.2 and is deferred to the v0.3 full guard (`specs/SPEC-018-agentic-tool-calling.md:705`).
- AC-25a now requires a Cline workspace where SPEC-018 itself is a possible `read_file` target and fails if SPEC-018 self-reading breaks a legitimate follow-up tool call (`specs/SPEC-018-agentic-tool-calling.md:574`).

Security conclusion: this is not a hidden lock-blocking gap anymore. v0.2.3 deliberately chooses no prompt-echo mitigation over a bypassable guard with self-DoS behavior, and the accepted residual risk is named at the change log, section 10c amendment site, and section 10c.1 amendment log.

### Critic H-3 -- Provider-global streaming auto-downgrade DoS

Status: CLOSED.

Evidence:
- AC-45 now scopes automatic downgrade to 3 malformed streams from the same buyer to the same provider within 5 minutes, affecting only that buyer's future requests to that provider, with recovery after 10 minutes clean (`specs/SPEC-018-agentic-tool-calling.md:618`).
- AC-45c adds an adversarial-buyer fixture proving other buyers sticky-routed to the same provider continue to receive `incremental` unless their own tuple crosses the threshold (`specs/SPEC-018-agentic-tool-calling.md:618`).
- Section 10d.4 repeats the per-(buyer, provider) attribution and states it is not per-provider for all buyers (`specs/SPEC-018-agentic-tool-calling.md:824`).

Security conclusion: the downgrade surface no longer lets one buyer degrade streaming for other buyers sharing a provider. The diagnostic header remains observation-only and non-negotiating (`specs/SPEC-018-agentic-tool-calling.md:826`).

### Critic M-1/M-2/M-3 -- Timing, prompt aggregate cap, AC-46 verifiability

Status: CLOSED for security.

Evidence:
- AC-44 now requires NTP-anchored skew verification at request start and computes p95 with a measured `clock_skew_offset` (`specs/SPEC-018-agentic-tool-calling.md:616`).
- AC-56 adds a total decoded prompt aggregate cap that rejects over-6 MiB prompt material before prompt rendering or inference with HTTP 413 `prompt_aggregate_too_large` (`specs/SPEC-018-agentic-tool-calling.md:640`).
- The stable error table classifies `prompt_aggregate_too_large` as `invalid_request_error` and non-retryable (`specs/SPEC-018-agentic-tool-calling.md:755`).
- AC-46 is reframed as buyer-visible field-present/type-correct behavior plus provider-side self-test against local hash subsystem state (`specs/SPEC-018-agentic-tool-calling.md:620`, `:768`).

Security conclusion: AC-44 is now an evidence gate with a stated skew assumption; AC-56 is a pre-inference admission guard rather than a provider fault; AC-46 remains diagnostic and does not become trust, parser-selection, settlement, or receipt authority.

### Critic M-4 / Narrative M-2 -- Lock-amendment discipline

Status: CLOSED for security.

Evidence:
- Section 10c.1 defines an amendment rule requiring the amended clause, rationale, replacement mitigation or residual risk, and in-place `AMENDED v<X.Y.Z>` label (`specs/SPEC-018-agentic-tool-calling.md:692-701`).
- The same section says silent scope cuts are non-compliant, requires future invocations to enumerate an amendment-log entry, and states AC numbers are stable across versions (`specs/SPEC-018-agentic-tool-calling.md:701-707`).
- Amendment 1 and Amendment 2 are both enumerated with rationale and mitigation/residual-risk statements (`specs/SPEC-018-agentic-tool-calling.md:703-705`).

Security conclusion: section 10c.1 does not open a new exploit path. It constrains future weakening by requiring in-place historical visibility and explicit risk/mitigation accounting. It is process discipline, not runtime authority.

## Fresh v0.2.3 security sweep

### Section 3.9 deletion and prompt-echo residual risk

Status: CLEAN.

The deletion removes a known-bypassable parser-side defense and the associated self-DoS class. The remaining same-family prompt-echo attack is real, but v0.2.3 does not hide it or claim it is mitigated. Existing security posture still relies on modelID match, buyer-side validation, final-close settlement gating, and v0.3 registry/full-guard deferral. That is a scope choice, not a fresh undisclosed vulnerability.

### AC-48a/AC-48b split and terminal-error dispatch

Status: CLEAN.

The split improves money-path security by requiring the Cline path to prove terminal-error streams do not dispatch successful tool calls to `AgentRuntime`. openai-python coverage remains useful for ecosystem compatibility but is no longer treated as Cline evidence. No new settlement or execution authority is introduced.

### Per-(buyer, provider) auto-downgrade and diagnostic header

Status: CLEAN.

The downgrade threshold and recovery rule bound blast radius and persistence. `X-MacProvider-Streaming-Mode` remains a diagnostic, non-negotiating header, so buyers cannot use it as a public wire-control surface. The remaining risk is per-buyer self-degradation of streaming UX after repeated malformed streams, which is an acceptable protective fallback.

### AC-44 skew correction

Status: CLEAN.

The NTP/heartbeat requirement affects release-evidence validity only. It does not alter request admission, streaming commit, final-close settlement, receipts, or provider-positive credit.

### AC-56 total decoded prompt cap

Status: CLEAN.

The cap rejects before prompt rendering or provider inference and uses a non-retryable request-size error. It composes with AC-50 through AC-55 as request validation and does not create provider fault-breaker credit, inference side effects, receipt output, or sticky-route success.

### AC-46 provider self-test

Status: CLEAN.

The provider-side self-test makes the known/unknown branch auditable where the state exists. Buyer-visible behavior stays type-only, and the field is still barred from parser selection, settlement, and SPEC-015 canonical binding.

## Final lock-readiness reconfirmation

Security lane remains READY TO LOCK for v0.2.3:

- r3 security verdict still holds.
- Blind-spot H-1, H-2, H-3 are closed for the security lane.
- Blind-spot security-relevant medium findings are closed or bounded.
- No fresh CRITICAL/HIGH/MEDIUM security finding found in the v0.2.3 additions.
- Residual prompt-echo risk is explicit, accepted for v0.2, and deferred to v0.3 rather than hidden behind a broken guard.
- Money-path settlement protection remains unchanged: malformed/final-close-failed streams settle zero provider-positive credits and produce no receipt.

## Self-verification

- Read the r3 security audit (`specs/SPEC-018-v0_2-security-r3-audit.md`).
- Read the v0.2.3 SPEC body in the changed areas: top orientation/change log, AC-25a, AC-39, AC-44 through AC-48b, AC-56, section 10a reader note, section 10c/10c.1, section 10d.0/10d.0.1/10d.1/10d.4/10d.8.
- Read the blind-spot narrative, critic blind-spot audit, narrative blind-spot audit, absorption prompt, and v0.2.3 draft notes.
- Searched the SPEC for active section 3.9, AC-49, `prompt_echo_blocked`, downgrade attribution, Cline/openai-python split, prompt aggregate cap, and AC-46 authority surfaces.
