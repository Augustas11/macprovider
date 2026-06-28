# SPEC-019 v0.1.0 round-1 audit — narrative

Round-1 audit of `specs/SPEC-019-structured-output.md` v0.1.0 at commit
`1aa1d74` on branch `spec/019-structured-output`.

## Aggregate tally

| Lane | C | H | M | m | Q | Verdict |
|---|---|---|---|---|---|---|
| codex architect | 2 | 1 | 0 | 0 | 0 | FIX REQUIRED |
| codex code | 0 | 1 | 2 | 0 | 0 | FIX REQUIRED |
| codex security | 0 | 2 | 1 | 0 | 0 | FIX REQUIRED |
| codex product-design | 0 | 3 | 2 | 0 | 1 | FIX REQUIRED |
| claude critic | 1 | 5 | 5 | 2 | 2 | FIX REQUIRED |
| claude narrative | 0 | 2 | 4 | 3 | 2 | FIX REQUIRED |
| **r1 TOTAL** | **3** | **14** | **14** | **5** | **5** | **FIX REQUIRED** |

## The 3 CRITICALs

1. **Architect C-1** — SPEC-001 row for `response_format.type` allows only
   `text` / `json_object`. SPEC-019 either supersedes that row explicitly
   or contradicts it. Fix: add cross-spec amendment note in §1 metadata.

2. **Architect C-2** — SPEC-006 normalizes provider 502 responses to
   `api_error` / `upstream_provider_error` at the gateway. SPEC-019 detail
   codes (`malformed_json_response`, `json_schema_validation_failed`)
   would be collapsed. Fix: either amend SPEC-006 to add SPEC-019 codes to
   the pass-through allow-list OR move detail to log/receipt-only fields
   and surface `api_error/upstream_provider_error` to buyer.

3. **Critic C-1** — OpenAI strict-mode parity break. OpenAI requires
   `required` to enumerate **every** property; SPEC-019 §3 only requires
   the reverse (`required` ⊆ `properties`). Buyer schema with optional
   field passes macprovider but fails Vercel SDK fixture parity. Fix: add
   §3 rule that under `strict:true`, `required` MUST contain every key in
   `properties`; new code `json_schema_strict_requires_all_properties_required`.

## Convergent HIGHs (multi-lane hits)

- **Schema depth cap missing** — security H-1 + critic H-4. Output JSON
  depth capped at 32; schema-side depth uncapped at 16 KiB → stack
  exhaustion at validation.
- **Receipt-vs-validation ordering / money-path leakage** — security H-2 +
  critic H-2 + critic M-1. SPEC silent on whether success receipt MUST
  wait for post-hoc validation; defaulted-`strict` idempotency cliff.
- **Response cap order-of-checks** — critic H-5. §6 wording "cap applies
  after parse+validate" inverts SPEC-018 §10d.7 fail-closed posture.
- **Tool × json_schema composite render** — architect H-1 + code M-2.
  Pre-inference rendering order undefined when both `tools` and
  `response_format: json_schema` present.
- **AC fixture artifacts** — code H-1 + PD H-1. AC-15/AC-16 SDK regression
  fixtures lack concrete artifacts; PD shows AC-16 currently exercises
  `json_object` path not `json_schema`.
- **Error code naming** — PD H-3. Versioned `_in_v0_1` suffixes violate
  §9 forward-compat.

## Single-lane substantive HIGHs

- Security H-3: prompt-injection AC-23 omits `json_schema.name`.
- Critic H-3: empty completion content classification undefined →
  buyers retry forever on deterministic empty output.
- Critic H-6: renderer cross-request contamination — must declare
  stateless renderer in v0.1.0.
- PD H-2: `json_object` enforcement is a breaking change, unlabeled.
- Narrative H-1: §0 "Quick orientation" buries the lead under file:line
  citations.
- Narrative H-2: ACs interleave categories (request-parse / output-validate
  / fixture / SDK shuffled).

## Recommendation

Absorb r1 into v0.1.1. Bump version, address 3 CRITICALs + 14 HIGHs first,
then MEDIUMs. Tight absorption prompt to follow.

After absorption, fire r2 — same 6 lanes, defensive lens against
regression of any fixed finding.
