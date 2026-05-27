# SPEC-002 v1.0.2 Final Re-audit Report

Auditor: Codex GPT-5.5
Spec audited: SPEC-002 v1.0.2 (commit c024f8c)
Audit completed: 2026-05-27T01:05:39Z
Prior audit: JOINT-SPEC-001-002-audit.md

## TL;DR verdict

PATCH AGAIN. SPEC-002 v1.0.2 resolves most joint-audit findings in the
main functional requirements and interface contracts, but 3 MAJOR and 1
MINOR regressions remain. The build-blocking risk is stale text that
still tells implementers to use coordinator-to-provider `nak`, which
directly contradicts the locked SPEC-001 protocol and SPEC-002's own
FR-P13 close-code patch. Confidence: high, because the remaining issues
are direct text contradictions found by targeted search and section
walkthrough, not inferred architecture concerns.

## Part 1 - Per-finding verification table

| Finding | Severity | Status | SPEC-002 v1.0.2 § ref | One-line justification |
|---|---|---|---|---|
| M-J1 | MAJOR | ADDRESSED | FR-P11 recovery preflight | `purpose` field removed; recovery preflight is `{type, request_id, estimated_tokens}` only and uses `recovery-probe-` as the discriminator. |
| M-J2 | MAJOR | PARTIAL | FR-P13; § 7.1; § 9; § 13 Step 2 | FR-P13 and § 7.1 say close codes/no C->P `nak`, but stale § 7.1, § 9, and § 13 text still says coordinator rejects with or sends `nak`. |
| M-J3 | MAJOR | ADDRESSED | FR-R3; § 5 routing pseudocode; § 7.2 headers | `X-MacProvider-Provider` is stable `provider_id`; `X-MacProvider-Session` is `assigned_id`; routing checks Session before Provider. |
| M-J4 | MAJOR | PARTIAL | FR-P11; § 10 D1; § 12 | FR-P11 makes literal HTTP 530 normative and § 12 has no OQ entries, but § 10 still says Q1 covers whether HTTP 530 is distinct. |
| M-J5 | MAJOR | ADDRESSED | § 13 coordinator.yaml schema | `providers:` map exists with `provider_id`, `endpoint_url`, optional `display_name`, example entries, and startup validation rules. |
| M-J6 | MAJOR | ADDRESSED | § 13 coordinator.yaml schema | Active `routing.retry_on_502` key is gone; `pool.degraded_probe_after_502` exists; old key appears only in rename note. |
| m-J1 | MINOR | ADDRESSED | § 7.2 headers | Request and response header tables enumerate Pref, Provider, Session, and Route in the right directions. |
| m-J2 | MINOR | ADDRESSED | AC-8b | Degraded provider is not routed while degraded; no "ONLY if no other ready" fallback remains. |
| Q-J1 | QUESTION | PARTIAL | FR-P11; § 10 D1; § 12 | The intended answer is normative in FR-P11, but § 10 still presents HTTP 530 distinct handling as Q1/open-question coverage. |

## Part 2 - Regression findings

### CRITICAL (0)

No CRITICAL regressions found. SPEC-001 does not need reopening.

### MAJOR (3)

**M1 - Coordinator-to-provider `nak` still appears in build-facing sections.**

Severity: MAJOR

Subsection: 2.2 WebSocket close codes

Section ref in SPEC-002 v1.0.2: § 7.1, § 9, § 13 Step 2

Quoted text showing the regression:
- § 7.1 hello behavior: "Rejects `tier != 1` with nak (FR-P13)."
- § 9 compatibility matrix: "`nak` | C->P | FR-P2, FR-P13 | Sent on invalid hello or unsupported tier"
- § 13 Step 2: "Reject invalid hello with nak."

What is wrong: The patch correctly added FR-P13 close codes and § 7.1
later says "Coordinator does NOT send `nak` to providers." However, the
stale lines above are in high-value implementation surfaces: the message
schema, compatibility matrix, and build hand-off. A builder following
those sections could implement the exact cross-spec violation M-J2 was
meant to remove.

Fix direction: Replace all coordinator-acting `nak` references with
WebSocket close codes. In § 9, keep only `nak` P->C and remove the C->P
row. In § 13 Step 2, say invalid hello is rejected with close code 4001
and unknown provider/tier/version/token/pool failures use FR-P13 codes.

**M2 - HTTP 530 is normative in FR-P11 but still described as open Q1 in § 10.**

Severity: MAJOR

Subsection: 2.4 HTTP 530 normative

Section ref in SPEC-002 v1.0.2: FR-P11, § 10 D1, § 12

Quoted text showing the regression:
- FR-P11: "**Literal HTTP 530 is normative in v1.**"
- § 10 D1: "Q1 in § 12 covers whether HTTP 530 ... is treated as a distinct signal from WebSocket disconnect. v1 default is yes..."
- § 12: "No open questions remain."

What is wrong: The normative FR-P11 patch landed, and
`grep -c '^\*\*OQ-[0-9]' specs/SPEC-002-coordinator.md` returns 0.
But § 10 still says the choice is covered by
Q1 and phrases the behavior as a "default", not a resolved requirement.
That leaves the prior HTTP 530 ambiguity alive in a less prominent
location.

Fix direction: Rewrite the § 10 D1 bullet to reference FR-P11 directly:
"Literal HTTP 530 is treated as a distinct normative signal..." Remove
the Q1 wording and "default" phrasing.

**M3 - `/admin/blacklist` response shape and identifier semantics conflict between § 7.4 and AC-10.**

Severity: MAJOR

Subsection: 2.8 AC-10

Section ref in SPEC-002 v1.0.2: § 7.4, AC-10

Quoted text showing the regression:
- § 7.4 request: `{ "assigned_id": "abc-123", "reason": "Provider operator requested removal" }`
- § 7.4 response: `{ "status": "blacklisted", "assigned_id": "abc-123", "drain_sent": true }`
- AC-10: "`POST /admin/blacklist` with a valid `provider_id` returns 200 with `{status: "draining", provider_id, assigned_id, drain_sent: true}`."

What is wrong: The two-phase behavior is now clear, but the endpoint
contract is not. § 7.4 uses `assigned_id` as the request key and returns
`status: "blacklisted"` without `provider_id`; AC-10 uses `provider_id`
as the request key and expects `status: "draining"` plus both IDs. The
audit prompt explicitly required the response shape `{status,
provider_id, assigned_id, drain_sent}` to match § 7.4; it does not.

Fix direction: Pick one endpoint contract and make § 7.4 and AC-10
identical. Recommended: accept `provider_id` as the stable operator
identifier, optionally accept `assigned_id` for session debugging, and
return `{status: "draining", provider_id, assigned_id, drain_sent}`.

### MINOR (1)

**m1 - Early buyer-side FR summaries omit the new provider response header.**

Severity: MINOR

Subsection: 2.3 Header tables

Section ref in SPEC-002 v1.0.2: FR-B2, FR-B3, § 7.2

Quoted text showing the regression:
- FR-B2: "The coordinator adds a `X-MacProvider-Route` response header..."
- FR-B3: "Adds `X-MacProvider-Route` response header."
- § 7.2 response table: "`X-MacProvider-Provider` ... `X-MacProvider-Route` ..."

What is wrong: The § 7.2 response-header table is correct and complete,
but the earlier FR-B2/FR-B3 summaries still mention only Route. This is
not a protocol break because the interface contract later lists both
headers, but it is an avoidable implementation drift risk.

Fix direction: Update FR-B2 and FR-B3 to say both
`X-MacProvider-Provider` and `X-MacProvider-Route` are added.

## What this patch round did well

- Recovery preflight is now a strict SPEC-001-compatible message with no
  extra `purpose` field.
- FR-P13's close-code table is complete for the intended rejection cases
  (4001-4005 plus 4429) and gives reason text formats.
- Header semantics are much cleaner in FR-R3, routing pseudocode, and
  the § 7.2 request/response header tables.
- The static provider endpoint configuration is now implementable: YAML
  schema, example entries, and startup validation are all present.
- AC-8b now matches the main routing rule: degraded providers are not
  routed until they return to `ready` or the 60s warm-up fallback exits
  degraded state.

## Final verdict recommendation

PATCH AGAIN in place as v1.0.3. Required patches:

1. Remove all remaining coordinator-to-provider `nak` instructions and
   keep FR-P13 close codes as the only coordinator rejection mechanism.
2. Rewrite § 10 D1 so literal HTTP 530 is described as resolved and
   normative, not Q1/default behavior.
3. Align `/admin/blacklist` § 7.4 and AC-10 on the same request and
   response shape.
4. Add `X-MacProvider-Provider` to the FR-B2/FR-B3 response-header
   summaries.

After those edits, a quick grep-based recheck should be sufficient:
search for coordinator-acting `nak`, `Q1`, `OQ-`, `retry_on_502`, and
`ONLY if no other ready`, then re-read § 7.4 plus AC-10 together.
