Provider catalog actions need to carry a trusted model from preparation through admission and settlement without treating local preparation as pricing authority. This change adds recoverable CLI/app preparation and measured recommendation actions, exact generation/config binding, durable artifact discovery, and coordinator-owned signed artifact admission with captured settlement rates.

Work in progress: final transaction persistence implementation and combined independent audits remain pending. The app Xcode suite passed641tests; the Swift25 parsed fixture completed preparation through valid receipt, exact accounting and restart, with fixture inference. Transaction binding and promotion corrections still need final source regression. Signed production CLI and physical Mac preparation-to-MLX-settlement qualification remain unproven. No deployment or economic activation is included.

Plans, review rounds and evidence: docs/product-roadmap/build-1/. Update this body from final acceptance-status.md before opening the reviewable PR.

SPEC-GOVERNANCE-DECLARATION-BEGIN
{
  "schema_version": "spec-pr-governance-v1",
  "behavior_change": "yes",
  "contract_change": "yes",
  "specs": [
    "SPEC-001",
    "SPEC-032",
    "SPEC-044",
    "SPEC-047"
  ],
  "requirements": [
    "SPEC-032-R002",
    "SPEC-044-R001",
    "SPEC-044-R002",
    "SPEC-044-R006",
    "SPEC-044-R007",
    "SPEC-044-R008",
    "SPEC-044-R010",
    "SPEC-044-R011",
    "SPEC-047-R001",
    "SPEC-047-R002",
    "SPEC-047-R003",
    "SPEC-047-R004",
    "SPEC-047-R006",
    "SPEC-047-R007",
    "SPEC-047-R008"
  ],
  "authority_domains": [
    "malibu-model-economics-ux",
    "hardware-evidence-admission",
    "model-catalog-identity",
    "autotune-recommendation",
    "network-model-admission",
    "billing-settlement-formula",
    "verified-model-settlement"
  ],
  "arbitration": [
    "CODE_BUG",
    "DECISION_REQUIRED"
  ],
  "tests": [
    "docs/product-roadmap/build-1/test-spec-r4.md",
    "docs/product-roadmap/build-1/validation-lead.md",
    "docs/product-roadmap/build-1/acceptance-status.md"
  ],
  "journeys": [
    "JOURNEY-NETWORK-MODEL-ADMISSION"
  ]
}
SPEC-GOVERNANCE-DECLARATION-END
