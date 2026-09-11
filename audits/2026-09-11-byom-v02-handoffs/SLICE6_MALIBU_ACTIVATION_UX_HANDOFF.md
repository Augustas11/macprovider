# BYOM v0.2 slice 6 — Malibu activation UX (handoff)

**Epic:** #1453 (BYOM v0.2). **Owner:** Erik (@erikHtoo). **Reviewer/operator:** @Augustas11.
**Kind:** client-side implementation over frozen contracts — no coordinator money-path or SPEC-authority change.

## Why this is a clean handoff
Slices 1–5 are merged and their contracts are LOCKED: discovery, catalog identity, the
admission decision path, settlement eligibility, and intake evidence. Slice 6 does not
change any of them. It builds the Malibu-side activation experience over transactions
that already exist and are closed-schema/versioned. You are wiring UX over specified
typed transactions, not designing protocol or security surface.

## Goal
A guided **prepare → evaluate → offer → adopt** flow for a discovered candidate, and
local BYOM rows shown with **honest state** instead of hidden. Every state-changing
action goes through a CLI typed transaction; no ad-hoc local state.

## Frozen contracts to build against (do NOT modify)
- **Discovery** — SPEC-046-R002/R003 `openai_compatible_loopback` adapter, emits
  `identity_state` (`opaque_endpoint`, `catalog_matched`, …). Slice 1.
- **Offer / withdraw / status CLI** — SPEC-047-R002 closed envelopes:
  `model_admission_offer_dry_run.v1`, `model_admission_status.v1`,
  `model_admission_withdraw_request.v1` / `…withdraw.v1`. Slice 4. Decoders reject
  unknown fields — keep that.
- **Coordinator admission states + decision path** — SPEC-047-R001. Slice 4.
- **Catalog / GGUF identity** — SPEC-010 v1.7/v1.8 R007, SPEC-023 catalog. Slices 2–4.
- Epic-cited rules for this slice: **SPEC-044-R006/R007** (economics gating / copy),
  **SPEC-046 copy rules**, **SPEC-001 §6.14a** (earning-verdict-first ordering).

## What to build (phase3-binary, Swift)
1. `malibu-cli` orchestration of the guided flow using the existing typed commands
   (`models discover` → `models evaluate` → `models offer --dry-run` → `models offer`
   → adopt/status), surfacing the dry-run guidance and each transition honestly.
2. Malibu.app presentation: local BYOM rows displayed with their real admission state
   and the non-earning disclosure, earning-verdict-first per SPEC-001 §6.14a. No hidden
   rows.

## Scoped by the operator BEFORE coding (ask @Augustas11; do not invent)
- The exact set of admission states to surface to a provider.
- The non-earning disclosure copy (SPEC-047-R005 / SPEC-046 copy rules). Do not write
  disclosure language yourself — use the operator-provided strings.

## Discipline
- Every transition is a CLI typed transaction; reject unknown fields; no local
  mutation of admission state outside those transactions.
- If honest-state display appears to need a SPEC touch (SPEC-014 portal or
  SPEC-047-R005), STOP and hand the SPEC change to @Augustas11 first — SPEC authority
  is not in scope here.

## Out of scope
Coordinator money-path or SPEC-authority changes; settlement; the signed
`JOURNEY-NETWORK-MODEL-ADMISSION` (slice 7).

## Tests / gates
- `cd phase3-binary && swift test`; Malibu UI via xcodebuild.
- Do not `git add -A` in a phase3 worktree (prunes `Package.resolved` → locked-resolve
  CI red); stage explicit paths.

## Acceptance
- The guided flow drives a discovered candidate prepare→evaluate→offer→adopt using
  ONLY typed transactions.
- Local BYOM rows show honest state + the operator's disclosure copy, earning-verdict-first.
- No new SPEC authority; `swift test` green; closed-schema decoders unchanged.
