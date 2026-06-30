# AUDIT — Issue #245 — SECURITY lane

## Goal
Adversarial SECURITY audit on commit `612c186` (R1 fix-pass on `2743679`) (branch `fix/iss245-spec007-v05-untyped-400`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope

- `phase5-gateway/internal/router/explorer.go` — `handleExplorerSessionDetail`, `parseTypedSegment`
- `phase4-coordinator/internal/explorer/handlers.go` — `handleSessionDetail`
- `phase4-coordinator/internal/explorer/static/js/dashboard.js` — `linkFor`
- SPEC-007 §5.6 + §6.4 v0.5 paragraphs
- Test files for both handlers

## Threat model

The path-segment is operator-supplied via the `/admin/explorer/sessions/{id}` URL. Both endpoints are operator-only (bearer-gated). The v0.5 break is about CONTRACT not authentication — a misformed path-segment must be rejected with a predictable envelope rather than accidentally resolving as something else.

Pre-v0.5 the path-segment-overload class was: an untyped value could be interpreted EITHER as a coordinator-internal request_id OR an external_request_id depending on lookup-order. v0.4 added the typed prefix to make the intent explicit. v0.5 closes the deprecation-window so untyped values can no longer revive that ambiguity class.

## Lens — SECURITY

- **400-bypass paths**: is there any path-segment shape that smuggles past `parseTypedSegment` and reaches the SQL lookup without the prefix being stripped? Examples to consider:
  - URL-encoded prefix: `%69%6e%74%5f<id>` — does the Go HTTP mux normalize this before `r.URL.Path` is read?
  - Double prefix: `int_int_<id>` — does the stripped value `int_<id>` reach SQL? Acceptable if it just returns 404, problematic if it's interpreted as a "literal int_-prefixed request_id" with a meaning.
  - Empty `int_` / `ext_` alone — explicitly tested but verify the SPEC matches the code path
  - Whitespace before prefix: `%20int_<id>` — does `strings.HasPrefix` see it?
  - Mixed case `Int_`, `EXT_` — current `strings.HasPrefix` is case-sensitive; SPEC should be explicit
- **Error envelope consistency**: does the 400 carry an `error.code` that the dashboard / runbook can match-on? Could the message field leak attacker-controllable data?
- **Audit-trail loss**: with the v0.4 `payout_explorer_path_segment_untyped` emit deleted, is there ANY signal that a hostile/buggy caller is hammering untyped URLs? The 400 is logged at the HTTP-server level, but operator visibility is now narrower. Acceptable trade-off, but should be a documented INFO.
- **Forensic cap path** (gateway): the 409 ambiguity audit emit (`explorer_matched_account_ids_truncated`) is preserved and reachable only when the request DID pass the typed-prefix gate. Verify the v0.5 flip didn't reorder code such that the forensic emit accidentally fires before validation.
- **dashboard.js**: is there a path where the dashboard emits a bare-id URL that an operator could click and silently hit 400, AND that the operator wouldn't recognize as a v0.5 break (e.g. they see "session lookup failed" without context)? UX-not-security but flag if confusing.
- **Audit-replay risk**: pre-v0.5 audit_events rows of type `payout_explorer_path_segment_untyped` remain in the gateway DB. After this PR ships, can any operator runbook still trigger that event name? No — but verify no test seeds the old event type and asserts emission.

## Specific must-check

1. Path normalization: confirm Go's `net/http` mux does NOT decode `%2F` etc. before path-routing; `strings.Contains(rawSegment, "/")` early-rejects any URL-encoded slash collision.
2. Symmetry: gateway uses `parseTypedSegment` helper; coordinator inlines `strings.CutPrefix`. Different implementations of the same gate — any divergent acceptance shape?
3. SPEC says "the stripped value is empty (`int_` alone)" — does the code actually reject `int_` (the empty-strip case)? Coordinator: yes (`stripped == ""` branch). Gateway: parseTypedSegment returns `(raw, false)` when stripped empty — confirm.

## Out of scope

- Code style (CODE lane)
- Layering / placement (ARCHITECT lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk: <why, cite threat model>
Recommendation: <concrete fix>
```

End summary: `C/H/M/L/INFO = a/b/c/d/e`. If 0 C/H/M: `ACCEPT — 0 C/H/M`.
