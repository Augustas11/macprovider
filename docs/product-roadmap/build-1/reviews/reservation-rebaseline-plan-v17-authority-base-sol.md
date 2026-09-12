# Reservation rebaseline v17 authority-base resolution

Status: durable review-resolution note; implementation remains gated on independent review of the exact v17 plan/test bytes.

## Finding

The independent v16 gate found that v16 still treated historical pre-squash authority candidate `922624a7959253aae0581c6e2db22f827925072b` as current authority in T18, while the landed authority is squash merge `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`. It also required precise event-key sourcing for candidate-associated non-cleanup reservations versus cleanup reservations, and historical review evidence citations for preparation-authority v1 through v9.

## Authority Evidence

- Landed current authority: `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`.
- Historical pre-squash candidate evidence: `922624a7959253aae0581c6e2db22f827925072b`; it is not the current baseline or ancestry gate.
- Historical preparation-authority review artifacts v1 through v9 exist at `fa71b09c:<path>` and are cited with their SHA-256 digests.

## Correction

V17 preserves v16 requirements except for these gate corrections:

- T18 checks landed authority `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f` and requires the first 6B implementation commit to descend from it.
- Candidate-associated non-cleanup actions Prepare, Evaluate, Adopt, and Switch derive the private projected-transaction reservation `event_model_key` from the projected row's non-null `model_key`.
- Published cleanup derives the private reservation `event_model_key` from the enclosing cleanup target plus verified receipt, not from nullable current row `model_key`.
- Tests cover success, direct cancel, stale, `operation_conflict`, `action_unavailable`, and `failed_dispatch` across reservation, active, history, terminal, and event binding for both non-cleanup and cleanup action families.
- Evidence anchors cite preparation-authority v1 through v9 as `fa71b09c:<path>` with known SHA-256 values rather than as current-tree paths.
