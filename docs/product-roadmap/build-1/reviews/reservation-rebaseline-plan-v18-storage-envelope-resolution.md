# Build 1 reservation rebaseline v18 — storage representation correction

Date: 2026-09-12

Status: correction input for independent review; this note does not approve implementation.

## Reopened finding

`B1-STORAGE-V17-H1` — v17 required a unique temp containing kind, target, UUID, generation, payload, and checksum to be renamed over the durable target. It also required `root.identity` to remain an exact closed five-field record. Renaming the envelope bytes would violate the identity schema; renaming only the payload would not be the specified atomic rename and would discard the generation needed for recovery. Partial secure-storage implementation was stopped without commit when this contradiction was identified.

## Required correction

V18 separates the two representations:

- Each of the five replaceable private-state targets stores the same closed `model_catalog_private_state_envelope.v1` bytes as its UUID-named temp. The durable envelope preserves record kind, target leaf, writer UUID, generation, complete payload, and checksum. Readers validate the envelope before decoding the inner lifecycle record.
- `root.identity` never uses that envelope. Its bootstrap temp and final leaf contain byte-identical raw `model_catalog_root_identity.v1` bytes; only the temporary filename carries a UUID.
- Outer envelope and inner payload caps, recovery bounds, filename rules, crash barriers, incompatible-development-state behavior, and negative tests are explicit.

## Gate

The exact v18 plan and test specification must receive an independent native GPT-5.6 Sol review with zero Critical, High, and Medium findings before the frozen contract candidate or secure-storage implementation is changed further.
