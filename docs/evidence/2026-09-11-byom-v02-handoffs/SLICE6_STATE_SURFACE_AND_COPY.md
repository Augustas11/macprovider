# BYOM v0.2 slice 6 — admission-state surface + disclosure copy (operator deliverable)

**For:** #1485 (slice 6, @erikHtoo). **Author/owner:** @Augustas11. **Grounding:**
SPEC-001 §6.14a (earning-verdict-first), SPEC-046-R003 (closed enums, localization
keys), SPEC-047-R004 (no earning implication), SPEC-044-R006/R007 (action gating).

This is the piece the slice-6 brief said the contributor must NOT invent. It resolves
every `provider_guidance.state_label_key` / `state_meaning_key` to concrete display
copy and pins the surfacing rule. Erik implements against these strings; he does not
choose them.

## Surfacing rule (honest state, nothing hidden)
- **Every discovered candidate is shown**, whatever its `admission_state`. Non-earning
  rows are displayed with their honest state, never hidden or silently dropped.
- The human/Malibu row **leads with exactly one earning-verdict line** (below),
  mapped from `provider_guidance.earning_path_class`, BEFORE any machine-state,
  capability, or price detail (SPEC-001 §6.14a).
- The **verdict is read from `earning_path_class` on the wire** — never re-derived
  from runtime model names, provider-proposed prices, or `admission_state` alone
  (§6.14a, SPEC-047-R004).
- All 12 machine `admission_state` values stay in `--json` unchanged; this table is
  the HUMAN/Malibu presentation layer only.
- **Actions** (Switch/Prepare/Evaluate/Adopt/Offer/Withdraw) obey SPEC-044-R006/R007:
  exposed only when the CLI returns a typed transaction for that exact row; a row with
  `action_model_id: null` is non-actionable. Surfacing a row ≠ enabling its actions.

## Earning-verdict headers (fixed by SPEC-001 §6.14a — verbatim, do not reword)
| earning_path_class | verdict line |
|---|---|
| `settlement_capable` | **Eligible to earn on qualifying settled requests** |
| `not_earning_yet_catalog_or_receipt_path_exists` | **Not earning yet — ** + the one concrete `provider_guidance.next_action` |
| `no_earning_path_in_v0_1` | **Can't earn in this release** |
| `local_inventory_only` | **Local only — not offered to the network** |

## State label + meaning copy (resolves `state_label_key` / `state_meaning_key`)
`source` = `admission_state_source`. The `expected earning_path_class` column is for
test reference only — the wire value is authoritative and is what the verdict uses.

| admission_state | source | Label | One-line meaning | expected earning_path_class |
|---|---|---|---|---|
| `local_only` | local_default | Local only | Retained as local inventory only; this admission state does not claim the model is prepared, installed, ready, reachable, or usable. | local_inventory_only |
| `not_offered` | local_default | Not offered | Coordinator offer state is unavailable or has not been queried. | local_inventory_only |
| `not_offered` | coordinator | Not offered | Coordinator reports no active network offer for this model. | local_inventory_only |
| `offerable` | local_default | Ready to offer | Passes local checks; you can submit an offer to the network. | local_inventory_only |
| `offer_submitted` | coordinator | Offer submitted | The coordinator has your offer and is deciding. | not_earning_yet_catalog_or_receipt_path_exists |
| `offer_rejected` | coordinator | Offer rejected | The coordinator declined this offer; revise and re-offer. | not_earning_yet_catalog_or_receipt_path_exists |
| `sandbox_probe_only` | coordinator | Sandbox probe only | Accepted for synthetic probing only; not buyer-visible and not earning. | not_earning_yet_catalog_or_receipt_path_exists |
| `network_visible_unpriced` | coordinator | Network-visible (unpriced) | Buyers can see it, but it carries no price and does not earn yet. | not_earning_yet_catalog_or_receipt_path_exists |
| `network_admitted_unsettled` | coordinator | Admitted (not settling) | Admitted to the network but not settlement-capable; no earnings yet. | not_earning_yet_catalog_or_receipt_path_exists |
| `catalog_priced` | coordinator | Catalog-priced | Carries a catalog price but is not yet settlement-capable; not earning yet. | not_earning_yet_catalog_or_receipt_path_exists |
| `settlement_capable` | coordinator | Eligible to earn | Eligible to earn only on qualifying settled requests; this does not state current income. | settlement_capable |
| `withdrawn` | coordinator | Withdrawn | You withdrew this offer; re-offer with fresh evidence to earn. | local_inventory_only |
| `revoked` | coordinator | Revoked | The coordinator revoked admission (identity or policy drift); re-offer with fresh evidence. | not_earning_yet_catalog_or_receipt_path_exists |

## Non-earning disclosure lines (secondary line under the verdict)
- `no_earning_path_in_v0_1`: "This candidate can't earn in this release. It's shown so
  its state is honest, not hidden."
- `local_inventory_only`: "Local only — not offered to the network, so it isn't earning."
- `not_earning_yet_catalog_or_receipt_path_exists`: no separate disclosure; the verdict
  line already names the next action, so the row reads "Not earning yet — <next_action>".

## Guardrails (SPEC-047-R004 / SPEC-046-R003)
- Never imply earning for `no_earning_path_in_v0_1` or `local_inventory_only`.
- For `settlement_capable`, preserve conditional eligibility: never imply the
  model is prepared, currently serving, receiving demand, currently earning, or
  guaranteed to receive or settle a request.
- `local_only` is an admission disclosure only. Render installed, usable,
  readiness, reachability, or preparation claims solely from independently
  validated readiness/runtime evidence for the same candidate and projection.
- The table has 12 distinct admission-state values and 13 source/state
  presentation combinations because `not_offered` has two authoritative source
  meanings. `local_default:not_offered` MUST NOT assert that an offer never
  existed; only `coordinator:not_offered` reports current coordinator offer
  state.
- `state_label_key` / `state_meaning_key` are localization-safe keys; the strings above
  are the en source values. They MUST NOT carry raw prompts, completions, paths,
  endpoints, or secrets.
- If a state's real wire `earning_path_class` disagrees with the "expected" column here,
  trust the wire and flag it to @Augustas11 — do not hard-code the mapping in Malibu.
- Localization and accessibility tests cover every earning verdict and both
  source-aware `not_offered` meanings in every shipped locale. They reject
  current-income, current-serving, guaranteed-demand, and guaranteed-settlement
  meanings for `settlement_capable`, and reject any offer-history assertion for
  `local_default:not_offered`.
