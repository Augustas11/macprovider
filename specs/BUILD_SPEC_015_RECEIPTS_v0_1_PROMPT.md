# BUILD_SPEC_015 — Verifiable inference receipts v0.1 (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing anything.**

Your job is to write `specs/SPEC-015-receipts.md` v0.1 — a normative spec for **per-response signed receipts** the macprovider buyer can verify offline.

## Why this exists (read first)

The `README.md` thesis is: macprovider is the best Mac-native inference network for *long-running personal agents, dev workflows, privacy-sensitive tooling*. The "verifiable" property is currently a vapor claim — `grep -r receipt phase4-coordinator phase5-gateway phase3-binary` returns zero implementation. The README was tightened in M1-3 (DOCS-1/SECU-2 truth sweep) to move receipts to roadmap-tense, but the gap remains: **nothing currently proves to a buyer that the response they got came from the provider who claimed to serve it.**

This SPEC is the v0.1 floor: signed receipts, issuance only. Verification CLI follows as a separate v0.2 work item. Model-hash binding (SPEC-011 territory) follows as a v0.3 work item — explicitly out of scope here.

## Repo conventions you MUST honour

1. **Naming.** `specs/SPEC-NNN-shortname.md`. Receipts is SPEC-015 (SPECs 001–014 exist; verify with `ls specs/SPEC-*.md | sort -u`).
2. **Header format (mandatory, line 3 is version of record):**
   ```
   # SPEC-015 — Verifiable inference receipts

   **Version:** 0.1 (YYYY-MM-DD, initial draft)
   **Depends on:** SPEC-001 vX.Y, SPEC-002 vA.B, SPEC-006 vC.D
   ```
   Use today's date. Look up the current locked versions of the dependency SPECs from their line 3.
3. **Change log section** at the top (newest first). For v0.1 the entry is "Initial draft following design rationale in §2."
4. **Numbered sections** like every other SPEC. Look at `specs/SPEC-006-buyer-api.md` and `specs/SPEC-008-tier2.md` for the house style.
5. **Acceptance criteria** at the bottom: numbered ACs that an implementer can mechanically verify. Existing SPECs use `AC-1`, `AC-2` etc. — match that.
6. **House voice:** terse, normative, MUST/SHOULD/MAY per RFC 2119. No marketing prose. State invariants, not aspirations.

## What v0.1 MUST normatively pin

### Receipt content (the 7-field tuple)

A receipt is a base64-encoded ed25519 signature over the canonical encoding of:

| Field | Type | Source |
|---|---|---|
| `model_id` | string | The buyer-requested model ID as it appeared in the request (e.g. `qwen2.5-7b-instruct-mlx-4bit`) |
| `prompt_hash` | sha256 hex of canonicalized prompt | See "canonicalization" below — this is the central design choice |
| `output_hash` | sha256 hex of canonicalized output | Same canonicalization rules as prompt |
| `provider_pubkey` | base64 ed25519 pubkey | The provider's identity key (see "provider keypair lifecycle") |
| `ttft_ms` | int64 | Time-to-first-token in milliseconds, measured at the provider |
| `tokens_out` | int64 | Output token count per SPEC-005 settlement semantics |
| `unix_ts` | int64 | Provider's response timestamp, Unix seconds UTC |

Specify the exact canonical encoding of this tuple before hashing (suggest: JCS / RFC 8785 — already used in `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` per SPEC-013, so the pattern is in-house). Specify the signature algorithm as ed25519 over the JCS-canonicalized JSON object.

### Wire transport

Returned in the HTTP response as a header. Recommended name: `X-MacProvider-Receipt`. Define:
- Header value format (base64 of the JCS-canonical tuple + base64 of the signature, separated by `.`, or a single base64 JWS-style — pick one and justify)
- Whether the header is present on streaming responses too (it must be, but where — final SSE event? trailer? new trailer header? Be explicit)
- Behaviour when the provider's keypair is not yet available (during first launch before Keychain generation): MUST omit the header rather than send a bogus signature

### Provider keypair lifecycle

- Generated on first launch of `phase3-binary` (the macprovider CLI), stored in macOS Keychain under a fixed service name (define it)
- Pubkey published to coordinator on the WS auth frame (extend SPEC-001 v2 `auth_request` — coordinate the field name with that SPEC; do not invent a redundant name)
- Coordinator stores pubkey on the in-memory provider struct; persists per current operator policy (define whether it survives restart — implies SQLite column or not)
- Key rotation: define how (operator-driven? auto on a fixed interval? buyer can request?). v0.1 can defer auto-rotation but MUST define manual rotation: `macprovider rotate-key` CLI flag, new pubkey re-published on next WS auth frame, old pubkey is also retained on the coordinator side for a grace window so in-flight receipts remain verifiable.

### Pubkey trust root

Buyers need a way to fetch the pubkey for a given provider to verify a receipt. v0.1: expose `/poolz/<provider_id>/pubkey` (or extend the existing `/poolz` JSON to include each provider's `pubkey` field). Explicitly state that v0.1's trust root is the coordinator's `/poolz` response, which is operator-mutable — call out that a stronger root (TUF-style signing on the catalog, or anchor-of-trust via Cluster D-tokens) is a v0.3+ concern.

### Canonicalization — the central design question

You MUST pick and pin exact rules for both prompt and output canonicalization. Multiple unresolved questions:

1. **Prompt canonicalization:** the OpenAI-shape `messages` array has `role`, `content`, `name`, `tool_calls`, `tool_call_id`. Spell out exactly which fields are included, their order, and how stringification handles unicode (NFC normalization? Reject non-NFC?).
2. **Output canonicalization:** for non-streaming, the output is the `choices[0].message.content` (and `tool_calls` if present). For streaming, the receipt MUST hash the *concatenated* output that the buyer would have received from the non-streaming equivalent — define exactly how delta interleaving collapses to canonical form.
3. **Tool calls:** if a model emits a tool call mid-response, the receipt MUST commit to the tool call args. Define whether tool-call deltas are part of `output_hash` or carried as a separate field.
4. **Newline normalization:** decide whether `\r\n` → `\n` (recommend yes) and whether trailing whitespace is stripped (recommend no — would break verification on output that legitimately ends with whitespace).
5. **Empty fields:** if `tokens_out=0` (errored before any output), is a receipt still emitted? If so, what does `output_hash` cover? (Probably: empty string canonicalized).

These are the spec's contentious surface. Be opinionated; the audit loop (below) will challenge weak choices.

## What v0.1 MUST explicitly defer (do not creep)

- **Model-hash binding.** Whether the receipt commits to which *weights* ran is SPEC-011's job. v0.1 binds *which name was requested* and *what content was produced*, not which sha256 of weights served it. Reference SPEC-011 and explicitly state this is v0.3+.
- **Buyer verification CLI.** `macprovider verify <receipt.json>` is a separate work item. v0.1 issues receipts; v0.2 verifies them. State this in §1.
- **On-chain anchoring.** Daily Merkle root of receipts published anywhere durable — gated on the Cluster D-tokens go/no-go decision, which has not been made. v0.1 says nothing about it.
- **Request_id binding for replay-style verification.** Open design question — flag it in an "Open questions" section but do not pin it in v0.1.
- **Multi-segment route binding (which provider handled which streaming chunk).** Only relevant once Cluster F sharding lands. v0.1 assumes one provider per response.

## Files you should read before writing

- `README.md` — the thesis and the current vapor claim
- `audits/2026-06-22/CLUSTER_HANDOFF.md` §"Cluster B — Verifiable inference" — the strategic frame (~lines 105-145)
- `specs/SPEC-006-buyer-api.md` — house style for a public-surface SPEC; also the spec that defines `X-MacProvider-*` headers, so your header name must not collide
- `specs/SPEC-001-phase3-binary.md` — provider WS auth frame (where pubkey publishes); line 3 has current version
- `specs/SPEC-002-coordinator.md` — coordinator-side contract; line 3 has current version
- `specs/SPEC-005-billing.md` — settlement semantics for `tokens_out`; receipts MUST agree with SPEC-005's accounting
- `specs/SPEC-008-tier2.md` — tier-2 attestation seams; reference the relationship (receipts are orthogonal to tier-2 but should not collide on field names or header names)
- `specs/SPEC-011-warm-swap.md` — model-hash design; cite this when explaining the v0.3+ deferral
- `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` — existing JCS implementation; reuse don't rebuild
- `beta/DECISION_CRITERIA.md` — read Entry 81 for the recent operator context; the entries adjacent give you the project's current state

## Audit-loop discipline (NON-NEGOTIABLE)

Per the rule documented in `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-spec-audit-loop-before-pr.md`:

> Freshly-written SPECs go through codex audit → fix → re-audit → loop until 0 CRITICAL/MAJOR BEFORE push/PR.

After writing v0.1, your workflow is:

1. Save `specs/SPEC-015-receipts.md` on a feature branch off `origin/main`. Branch name suggestion: `spec/015-receipts-v0-1`. Do NOT push yet.
2. Author `specs/AUDIT_SPEC_015_V0_1_PROMPT.md` — an audit prompt that asks an external auditor (codex) to find CRITICAL, MAJOR, MINOR findings against your v0.1. Look at `specs/AUDIT_SPEC_006_PROMPT.md` for the format.
3. Run the audit (`omc ask codex` if available, or whatever the project's audit-loop convention is at the time you read this — check `CLAUDE.md` and the `ask` skill for current invocation).
4. Apply fixes. Bump to v0.1.1 / v0.2 per findings. Re-audit.
5. Loop until **0 CRITICAL, 0 MAJOR**. MINORs can be deferred to a follow-up if they're genuinely out of scope but each one must be acknowledged in the change log.
6. ONLY THEN push the branch and open a PR. Do not skip step 5 even if the original spec-writing prompt (this file) feels exhaustive.

Existing SPECs typically went through 3–5 audit rounds. Expect the same.

## Open questions to flag (do not resolve in v0.1)

Surface these in a final §"Open questions" section so the audit loop has a clear target:

- Q1: trust-root strengthening — should `/poolz` pubkey publication eventually be signed by an offline operator key (TUF-style)?
- Q2: replay-resistance — does the receipt need to commit to `request_id`, and if so, where does the buyer get its expected `request_id` from?
- Q3: cross-provider routing — when Cluster F sharding lands, a single response may have multiple provider segments. Receipt-per-segment or receipt-per-response with embedded route list?
- Q4: timestamp trust — `unix_ts` is provider-reported. Should the buyer cross-check against the coordinator's response timestamp? What's the acceptable skew?
- Q5: streaming receipt delivery — final SSE event vs HTTP trailer vs both vs new dedicated `event: receipt`?

## Quality bar

A great v0.1 reads like SPEC-008 or SPEC-013: every section answers "what does code MUST do, what does it MAY do, what happens on the edge." Every claim has a citation (file:line, RFC number, other SPEC §). No "TBD" — defer cleanly with "v0.3+ — out of scope for v0.1, see §X" or push to "Open questions."

A bad v0.1 hand-waves canonicalization, lists features without invariants, or invents header/field names that collide with existing SPECs. The audit loop will catch this; better to catch it yourself first.

## Final deliverables when you're done

1. `specs/SPEC-015-receipts.md` at the version that passed the audit loop with 0 CRITICAL/MAJOR
2. `specs/AUDIT_SPEC_015_V0_1_PROMPT.md` plus the audit transcript or summary file showing the audit rounds
3. A pushed branch and an open PR linking the SPEC, the audit prompt, and the audit results
4. An appended entry to `beta/DECISION_CRITERIA.md` noting SPEC-015 v0.X LOCKED, what landed, why this v ships now, deferred items
5. NO implementation — v0.1 is normative spec only. Implementation is a separate BUILD_SPEC_015 prompt, written after v0.1 locks.

**You're not done when the spec exists. You're done when the audit loop closes and the PR is open.**
