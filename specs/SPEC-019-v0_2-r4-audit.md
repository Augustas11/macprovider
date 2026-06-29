# SPEC-019 v0.2.3 — Round 4 defensive audit narrative

**Anchor:** `spec/019-v0-2-streaming` @ `568e110`
**Audited SPEC:** `specs/SPEC-019-structured-output.md` v0.2.3 (r3-absorption DRAFT)
**Round:** r4 (defensive)
**Lanes:** 4 codex (architect, code, security, product-design) + 2 Claude blind-spot (critic, narrative)

## Per-lane verdicts — ALL READY TO LOCK

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect (codex) | READY TO LOCK | 0 | 0 | 0 |
| B code (codex) | READY TO LOCK | 0 | 0 | 0 |
| C security (codex) | READY TO LOCK | 0 | 0 | 0 |
| D product-design (codex) | READY TO LOCK | 0 | 0 | 0 |
| E critic (Claude) | READY TO LOCK | 0 | 0 | 0 |
| F narrative (Claude) | READY TO LOCK | 0 | 0 | 0 |

**Totals: 0 CRITICAL, 0 HIGH, 0 MEDIUM across all 6 lanes.**

**Lock convention satisfied.**

## r3 closures verified

All three convergent r3 absorptions confirmed at every cited surface:

- **E-H-1 (SPEC-006 §3221 → §17.5/:2605):** Lane E spot-checked all 4
  surface sites; SPEC-006 §17.5 header at `:2598`, `provider_timeout`
  literal at `:2605`. Grep guard `§3221` returns 0.
- **E-H-2 + E-M-1 + C-r3-M-1 (wall-clock authority rewrite):** Lane A
  + B + C + E independently verified the gateway-owned wall-clock
  authority lands consistently across AC-V2-9, §5, §7, §8. Subject of
  every MUST verb is explicit. Lane C confirms slow-roller DoS is
  closed because gateway emits `provider_timeout` even if provider
  idle watcher never fires.
- **E-H-3 (server.go:1722 → :2386):** Lane B + E spot-checked the
  streaming SSE `writeSSEError` site at `:2386`. Grep guard
  `server.go:1722` returns 0.
- **D-r3-M-1 (NaN/Infinity envelope):** Lane D + E verified AC-V2-10b
  envelope split — HTTP 400 `invalid_json` for the four RFC 8259 §6
  literals; `json_schema_unsupported_keyword` for non-numeric operand
  types. Both buyer-side and provider-side parse layers
  (`server.go:3467-3471`, `ChatCompletionRequest.swift:22-27`) return
  the right code.

## Lock confirmation

**Bar:** 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes.
**Status:** SATISFIED at `568e110` (v0.2.3 audit anchor).

**Lock action:** bump to v0.2.4 LOCKED and tag the change-log entry.

## Per-lane round files

- Lane A codex artifact: `codex-spec-019-v0-2-3-...2026-06-29T08-24-42-481Z.md`
- Lane B codex artifact: `codex-spec-019-v0-2-3-...2026-06-29T08-24-35-850Z.md`
- Lane C codex artifact: `codex-spec-019-v0-2-3-...2026-06-29T08-24-39-458Z.md`
- Lane D codex artifact: `codex-spec-019-v0-2-3-...2026-06-29T08-25-35-874Z.md`
- Lane E Claude agent: `tasks/adc82d8ec3e9fbb2d.output`
- Lane F Claude agent: `tasks/a85232f7590f4f8dc.output`
