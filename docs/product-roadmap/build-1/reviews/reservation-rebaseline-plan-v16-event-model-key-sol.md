# Reservation rebaseline v16 event-model-key resolution

Status: durable review-resolution note; implementation of this changed portion remains gated pending independent review of the exact v16 plan/test bytes.

## Finding

Plan/test v15 treated `event_model_key` as if it were carried by each public cleanup action copy. That contradicts the landed SPEC-044 v0.2.8 authority: the public v2 action object has the closed eight-field shape and does not contain `event_model_key`.

## Authority Evidence

- `origin/main` is `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`.
- `specs/SPEC-044-malibu-model-catalog-economics.md` is v0.2.8 at that commit.
- SPEC-044 states `cleanup_targets` carries the required non-null `event_model_key`, `cleanup` uses the v2 action shape, and the historical key comes from the verified managed-object receipt.
- SPEC-044 also states the durable reservation carries that immutable key and worker events emit it through the retained transaction event field `model_key`.

## Correction

V16 preserves v15 requirements except for the authority reconciliation:

- public v2 actions stay the closed eight-field shape and reject `event_model_key` as an unknown action field;
- the enclosing `cleanup_targets` entry and verified receipt source the immutable historical event key;
- projected cleanup reservations and `projection_binding_sha256` carry and bind that key;
- worker events emit the bound key as `model_key`;
- tests remove impossible per-action event-key mutation and instead cover target event-key mutation, receipt-to-target mismatch, target-to-private-reservation mismatch, and orphan dispatch/event correlation.
