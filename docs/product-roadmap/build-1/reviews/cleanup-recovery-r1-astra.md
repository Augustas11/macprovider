# Cleanup recovery addendum r1 — independent Astra architecture gate

Verdict: CHANGES REQUIRED. 0 Critical, 0 High, 1 Medium, 0 Low.

Reviewed plan: `docs/product-roadmap/build-1/cleanup-recovery-addendum-r1.md`.
Exact SHA-256: `9f4d080d0abe1b0bf947c5b003e8c202367927ea72206145ed8aced485aa8044`.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Scope: the focused journal-only cleanup projection correction for CODE-M1, against current producer, app decoder/row mapping, transaction cleanup and approved Build 1 boundaries. Other agents are editing; this is a plan gate, not implementation acceptance. No source edits or tests run.

## CLEANUP-M1 — The recovery row's closed wire identity and merging contract remain undefined

Severity: MEDIUM. Confidence: high.

Evidence: the addendum says a journal-only row must identify its source as local recovery, but does not specify the field/enum that carries that discriminator. `ModelCatalogEconomicsWire.Row` has no row source; `Admission.source` permits only local_default/coordinator, and the Malibu decoder rejects unknown row keys. The row contract also requires nonnullable `weights_present_locally`, `is_current`, runtime state and admission fields, while the addendum correctly calls for unknown readiness and no historical admission assertion. No exact conservative field mapping or recovery-specific display interpretation is defined.

The addendum permits attaching cleanup to an existing row but does not define matching/deduplication or deterministic selection when several completed transactions for one target have leftovers. Current `MalibuModelRow.id` is `action_model_id` (otherwise model_key), so one row per transaction can duplicate SwiftUI identities. Current app mapping treats the catalog key as an alias for the active model under protocol 2 and prioritizes cleanup over `.current`. A historical key reused by a fresh catalog target can therefore misidentify a recovery row as current or hide the actual current category unless the join and display rules are constrained.

Consequence: implementers must invent a release-contract extension and decide whether historical journal identity participates in current model aliasing. Plausible implementations either fail closed and still hide cleanup, produce duplicate rows/actions, or misrepresent the incumbent. These are directly within the change's truthful recovery and current-model protection goals.

Required correction in r2:

1. Pin the exact protocol-2 recovery discriminator and required conservative values for every existing state/authority field; state any new closed enum/field and the matching SPEC-044 producer/consumer change. Keep protocol 1 bytes and existing admission source meanings unchanged. Do not turn local recovery into an admission tier. Unknown readiness must render as unverified/unknown, never a claim that weights are absent or verified.
2. Define deterministic cleanup selection and stable unique row IDs. Prefer one recovery row per canonical target with a deterministic eligible UUID selection; after cleanup, expose the next eligible leftover on a fresh projection. Alternatively define an equally bounded identity scheme that cannot duplicate current rows. Do not omit valid independent leftovers as malformed conflicts merely because multiple transactions exist.
3. Attach to an existing fresh row only on the exact canonical served/action target binding; never use a historical catalog key alone. Specify safe handling when an old key now denotes a different target and when the same target has a new key. Journal identity cannot authorize current-model aliases.
4. Preserve the independently known current model/category while exposing its cleanup action. A standalone historical recovery row must not change or infer current identity. Tests must cover actual current target plus leftover staging, reused catalog key for a different model, multiple leftovers for one target, and identical stable projection IDs across refresh/restart.

The remaining ownership design is suitable: bounded private no-follow journal validation; exact UUID/target binding; no current feed dependency for cleanup; explicit confirmation; owner-lock exclusion; separate cleanup events; preservation of original terminal/artifact/recommendation/adoption material. Those constraints should remain unchanged in r2.

Approval of this focused addendum will not resolve CODE-M2 or waive physical B1-T10/B1-T11 qualification. Final implementation tests and full diff review remain required.
