# Build 1 v21 staging plan: independent adversarial round

Status: **FAIL — 0 Critical, 2 High, 1 Medium**. Native GPT-5.6 Sol read-only review of commit `87facc57`, plan SHA-256 `1818dc488d10db91d26c6579405e0151f5f6a6a83f27ed5b2fd14ca37bbeeec9`, test SHA-256 `c31af116b5896914d5d4ed204336dba1b3ebf933128fc3e8c7a9ddadb07a6622`, against merged SPEC-044 at `c8c97f66` and current contract candidate #1491. Passing v20's earlier exact gate did not prove these newly exposed assumptions.

| Severity | Evidence and consequence | Required correction |
| --- | --- | --- |
| High | V21 retained mandatory publication receipt, receipt SHA, and artifact identity in the staging cleanup branch, but interrupted partial staging has no receipt; v20 creates it only after completed verification (`v21 plan:11`; `ModelPreparationContracts.swift:1528-1599`; `v20 plan:308-314`). | Define a distinct receipt-free staging evidence branch and test incomplete download before receipt. |
| High | V21/v20 published `objects/<tuple_sha256>` contradicts landed SPEC-044's receipt-derived `artifact_identity_digest` object leaf (`v21 plan:14`; `v20 plan:198,306`; `SPEC-044:225-233`). | Supersede the plan path with the SPEC leaf and test unequal tuple/artifact digests; do not move code from wrong draft to production. |
| Medium | V21 source UUID pair/path lack durable provenance after terminal history compaction, and the current projected reservation cannot bind that pair (`v21 plan:15`; `ModelPreparationContracts.swift:785`). | Freeze a durable attempt-owned source record and bounded index retained through cleanup, bind its digest into projection/dispatch/recovery, and test correlated source/path substitution. |

The proposed [v22 reconciliation](../reservation-rebaseline-plan-v22-cleanup-reconciliation.md) responds to these findings but has its own independent gate pending. No staging cleanup implementation or production acceptance is credited from v21.
