# Build 1 v22 plan: independent post-rebase authority check

Status: **FAIL — 0 Critical, 0 High, 1 Medium**. Native GPT-5.6 Sol read-only delta review of HEAD `7dbce53e318569766ac7feff70128eeb36c940c5` rebased onto `origin/main` `5ef8da5742e73892cd9f8e6be2e6ca2c5aca1145`. The prior passing SPEC-044/v22 bytes remained identical (SPEC SHA-256 `4e5833017a74165f30210fd891258eade67f0b46e75c9706c3c83fb5c050e763`, plan `799bc5ccbee202abb04bd76a6c4b84fab20f7d81ea29ef0b96cf7ec7a85a4571`, test `1ed71744ca0a46c007b1402049b1ea221e87fd37fa3d24793705f54497b45441`), but the new base landed SPEC-047 v0.1.9 and Pearl release-proof changes.

| Severity | Evidence and consequence | Required correction |
| --- | --- | --- |
| Medium | SPEC-047 v0.1.9:101 reserves coordinator `offer_rejected` as unreachable in v0.2. SPEC-044 v0.2.9:440 still treats `coordinator:offer_rejected` as a locally motivated positive Prepare branch despite its own SPEC-047 inconsistency rule at :102. Inherited v20 plan:51 and T16:457–464 can falsely prove that fabricated coordinator readback is actionable. | Keep the 12-value closed wire decoder for compatibility; explicitly reject current coordinator `offer_rejected` as inconsistent/non-actionable in the normative matrix and v22 override, with a negative fabricated event/readback test. Preserve legitimate `not_offered` cases. |

The newly landed Pearl updater proof changes do not overlap local preparation/storage/economics authority; release qualification remains unproven. The earlier zero-blocker approval remains evidence for its exact older base, not for this rebased corpus. No implementation or dynamic tests were reviewed.
