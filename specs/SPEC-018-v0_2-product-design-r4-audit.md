# SPEC-018 v0.2.3 - Product-design-lane round-4 defensive audit

## Verdict

READY TO LOCK from the product-design lane.

v0.2.3 does not regress the round-3 product-design verdict. The blind-spot absorptions improve the Cline drop-in product path by removing the net-negative prompt-echo self-DoS, splitting Cline evidence from openai-python ecosystem evidence, bounding streaming downgrade blast radius per buyer, and making first-reader orientation explicit.

## Tally

CRITICAL: 0
HIGH: 0
MEDIUM: 0
MINOR: 0
QUESTIONS: 0

## Inputs Reviewed

- `specs/SPEC-018-agentic-tool-calling.md` v0.2.3 working copy.
- `specs/SPEC-018-v0_2-product-design-r3-audit.md`.
- `specs/SPEC-018-v0_2-blindspot-audit.md`.
- `specs/SPEC-018-v0_2-blindspot-absorption-prompt.md`.
- `specs/SPEC-018-v0_2_3-DRAFT-NOTES.md`.

## Round-3 Product-Design Verdict Regression Check

### r3 aggregate-cap UX assessment

Status: STILL HOLDS.

v0.2.3 preserves the r3 cap envelope and adds a total decoded prompt aggregate cap. The existing Cline release gate remains well below normal cap pressure: at least 20 provider turns, at least 30 tool calls/results, at least three file edits, at least two shell runs, and one large-write streaming case of at least 64 KiB. The new 6 MiB total decoded prompt cap fails pre-inference with explicit HTTP 413 `prompt_aggregate_too_large`, so the boundary remains user-actionable rather than silent truncation or provider-side failure. Citations: `specs/SPEC-018-agentic-tool-calling.md:574`, `specs/SPEC-018-agentic-tool-calling.md:640`, `specs/SPEC-018-agentic-tool-calling.md:755`, `specs/SPEC-018-agentic-tool-calling.md:782-809`.

### r3 AC-46 `null` sentinel UX assessment

Status: STILL HOLDS.

v0.2.3 narrows AC-46 in the product-friendly direction: buyers only verify field presence and JSON type, while provider-known-vs-unknown correctness moves to provider-side self-test. Cline is still required to succeed whether the value is known lowercase hex or `null`, and the value remains non-canonicalized and observation-only. Citations: `specs/SPEC-018-agentic-tool-calling.md:574`, `specs/SPEC-018-agentic-tool-calling.md:620`, `specs/SPEC-018-agentic-tool-calling.md:768`.

### r3 prompt-echo fallback UX caveat

Status: SUPERSEDED, NO REGRESSION.

r3 accepted the internal-only `prompt_echo_blocked` fallback as a v0.2 compromise. v0.2.3 deletes the minimal guard entirely after the blind-spot pass showed it was net-negative for Cline, especially when Cline reads SPEC-018 content containing native tool-call examples. Product-design impact is positive for the lock candidate: legitimate Cline self-reading is now a release-gate requirement, and the remaining same-family echo risk is explicitly deferred to v0.3 instead of hidden behind a brittle guard. Citations: `specs/SPEC-018-agentic-tool-calling.md:23`, `specs/SPEC-018-agentic-tool-calling.md:574`, `specs/SPEC-018-agentic-tool-calling.md:686`, `specs/SPEC-018-agentic-tool-calling.md:705`, `specs/SPEC-018-agentic-tool-calling.md:740`.

## v0.2.3 Fresh Product-Design Sweep

### Quick orientation block

No finding.

The new top-of-file orientation gives first-time readers the product thesis before the long change log: v0.1.5 is the locked first-turn certificate, v0.2 is the Cline drop-in release, v0.3 owns deferred registry/echo/diagnostic work, and the money path remains protected. This directly improves product readability and does not alter user-facing scope. Citations: `specs/SPEC-018-agentic-tool-calling.md:7-17`.

### §3.9 deletion and §10c.1 lock-amendment discipline

No finding.

Deleting §3.9 removes a Cline self-DoS path rather than weakening the stated v0.2 product promise. The lock-amendment rule requires named clauses, rationale, mitigation or residual-risk documentation, an `AMENDED` marker, and an amendment-log entry; that is enough product governance for future readers to distinguish deliberate narrow scope from silent regression. Citations: `specs/SPEC-018-agentic-tool-calling.md:29`, `specs/SPEC-018-agentic-tool-calling.md:692-707`.

### AC-48a / AC-48b split

No finding.

The split fixes the product evidence mismatch. openai-python remains a broad ecosystem regression gate, while Cline's money-path terminal-error behavior is now tested through the actual Cline OpenAI-compatible stack using `@ai-sdk/openai-compatible`. That makes the Cline drop-in claim more credible than the r3 wording. Citations: `specs/SPEC-018-agentic-tool-calling.md:606`, `specs/SPEC-018-agentic-tool-calling.md:614`, `specs/SPEC-018-agentic-tool-calling.md:624-626`, `specs/SPEC-018-agentic-tool-calling.md:828`, `specs/SPEC-018-agentic-tool-calling.md:858`.

### §10d.4 per-(buyer, provider) auto-downgrade

No finding.

The per-(buyer, provider) tuple, 3-in-5-minute threshold, and 10-minute clean recovery preserve streaming UX for unrelated buyers while still giving operators a bounded fallback for malformed streams. The diagnostic header remains observation-only and non-negotiating, so clients do not need a new product branch. Citations: `specs/SPEC-018-agentic-tool-calling.md:618`, `specs/SPEC-018-agentic-tool-calling.md:824-828`.

### AC-44 clock-skew bound

No finding.

The NTP-skew correction makes the large-write streaming evidence measurable without changing the user promise. The product requirement remains simple: Cline sees incremental argument deltas for large file edits instead of a buffered final blob. Citations: `specs/SPEC-018-agentic-tool-calling.md:616`.

### AC-56 total decoded prompt aggregate cap

No finding.

The added cap is a defensive admission boundary with explicit HTTP 413 semantics. It does not undercut the Cline release gate and gives long-session clients a clear retry path alongside the existing `messages[]` > 256 guidance to split or summarize. Citations: `specs/SPEC-018-agentic-tool-calling.md:640`, `specs/SPEC-018-agentic-tool-calling.md:787-793`, `specs/SPEC-018-agentic-tool-calling.md:809`.

### §10a reader note and AC-number stability

No finding.

The §10a reader note correctly warns that §10a is historical locked v0.1.5 content and points active v0.2 readers to §10d plus the amendment log. Stable AC numbering avoids downstream archaeology churn and keeps prior audit references usable. Citations: `specs/SPEC-018-agentic-tool-calling.md:646`, `specs/SPEC-018-agentic-tool-calling.md:701`, `specs/SPEC-018-agentic-tool-calling.md:713`.

## Final Lock-Readiness Assessment

LOCK CANDIDATE from product-design: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

The r3 PD verdict remains valid against v0.2.3. The v0.2.3 additions are product-positive for the Cline drop-in release path, and the remaining deferred items are clearly labeled as v0.3 scope rather than hidden gaps in the v0.2 promise.
