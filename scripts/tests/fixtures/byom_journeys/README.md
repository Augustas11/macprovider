# BYOM journey golden fixtures

These run manifests and captures are the golden inputs for
`scripts/tests/test_byom_journey_evidence.py`. Capture validates every one of
them through the real path in `scripts/byom_journey_evidence.py`, so they have
to be documents the CLI can actually emit — not plausible-looking JSON.

The R4 audit of #1453 slice 1 found the opposite: the captures had been
hand-synthesized, and carried values no CLI ever produced (`identity_state:
declared_local`, `locality: local_weights`, capability results as strings,
`completion_sha256` for `response_body_sha256`, `next_action: serve_traffic`).
Key-set-only validation accepted all of them. The validator now checks wire
types, nullability, the closed SPEC enums, and the state/source cross-field
rules, and these fixtures were regenerated from real CLI output.

## Provenance

### `discovery/` — all captures are real, unedited CLI output

Produced by running the hermetic driver and copying its captures verbatim:

```bash
test/e2e/byom/run-discovery-journey.py --out /tmp/byom-discovery
cp /tmp/byom-discovery/captures/*.json \
   scripts/tests/fixtures/byom_journeys/discovery/captures/
```

`run-manifest.json` is hand-written (it is the contract fixture, not a captured
document), but its `harness.name` is now the driver that actually produces these
captures — the evidence contract binds each journey to exactly one harness.

The driver emits three further captures (`admission-status-state-ladder`,
`discover-state-ladder-unstable`, `catalog-economics-state-ladder`) that this
manifest does not reference; they are omitted rather than committed unused.

### `admission/` — real CLI output where the stub reaches the state

Produced by driving the real CLI against the hermetic coordinator stub in
`test/e2e/byom/run-cli-onboarding-e2e.py` (ollama adapter stub, loopback
coordinator, temporary provider identity and config). Real and unedited:

| Capture | Command that produced it |
|---|---|
| `offer-dry-run.json` | `models offer <ref> --dry-run --json` |
| `admission-status-offer-submitted.json` | `models offer <ref> --yes --json` |
| `admission-withdraw.json` | `models admission withdraw <ref> --yes --json --reason-code provider_requested` |
| `admission-status-reentry.json` | `models admission status <ref> --json` after withdrawal (`withdrawn`, `allowed_next_states: [offer_submitted]` — the re-entry case step 11 asserts) |
| `catalog-economics-unpriced.json` | `models catalog-economics --json` while the offer is `offer_submitted` |

### `admission/` — minimally edited from a real document

The hermetic stub only reaches `not_offered`, `offer_submitted`, and
`withdrawn`. The remaining states are real documents from the table above with
**only** the state and its dependent guidance fields changed, each to a value
from the closed SPEC enums. Nothing else is touched: provider id, candidate id,
served model reference, catalog key, timestamps, `cli_version`, and
`admission_state_source` are all the real CLI's.

Base document: `admission-status-offer-submitted.json` (real).

| Capture | Fields edited | Why |
|---|---|---|
| `admission-status-offer-rejected.json` | `admission_state`, `allowed_next_states`, `provider_guidance.{state_label_key,next_action,earning_path_class,transition_reason_code}` | Step 3 needs a coordinator rejection; SPEC-047-R002 requires a non-null `transition_reason_code` on a rejection. |
| `admission-status-sandbox-probe-only.json` | same set (`transition_reason_code` set to null) | Step 4 needs the bounded-probe state. |
| `admission-status-revoked.json` | same set | Step 7 needs a revocation; SPEC-047-R002 requires a non-null reason code on one. |
| `admission-status-settlement-capable.json` | same set, plus `provider_guidance.state_meaning_key` | Step 9. The meaning key is the one field where keeping the real `byom.admission.not_earning` would assert something false about `settlement_capable`. |
| `admission-status-novel-non-catalog.json` | same set, plus `catalog_model_key` set to null | Step 10 is the novel *non-catalog* presentation case, so the candidate carries no catalog identity. |

`catalog-economics-catalog-priced.json` is `catalog-economics-unpriced.json`
(real) with edits confined to the single BYOM row — the one whose
`admission.state` was `offer_submitted`. The other nine catalog rows are
untouched real output. Edited on that row: `admission.state` →
`catalog_priced`, `admission.catalog_economics_permitted` → true
(`settlement_capable` deliberately stays false: SPEC-047-R001 makes
`catalog_priced` display pricing, never settlement), `economics_state`,
`rate_source`, the three `rate_card_*` fields, the two rates, the two provider
payouts, `provider_share_bps`, `disabled_reason`, and `warning_codes`.

## Regenerating

Re-running the discovery driver and copying its captures is the whole procedure
for `discovery/`. For `admission/`, drive the CLI against the onboarding
harness's stub, then re-apply the edits in the tables above. If a real document
ever trips capture's redaction scanner, that is a CLI bug to report — never a
value to edit out of the fixture.
