# Build 1 reservation rebaseline plan v17 — independent Sol gate

Date: 2026-09-12

Reviewer model: `gpt-5.6-sol`, high reasoning, independent critic lane

Repository authority: landed merge `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`

Reviewed exact artifacts:

- `reservation-rebaseline-plan-v17.md` — SHA-256 `8ba72d27e626f1d3044d5973420c41ecdf0d318eb97665084dbe6d17c756cb95`
- `reservation-rebaseline-test-spec-v17.md` — SHA-256 `acbf19d035f2452dd59664d0da7d703316a357bcf003ac00ded6a70b4664d96b`

Verdict: **PASS**

Findings: **0 Critical, 0 High, 0 Medium**.

The reviewer independently inspected the exact plan and test bytes, repository instructions, and landed SPEC-044 v0.2.8 authority. It confirmed that:

- the public v2 action remains the closed eight-field shape and rejects `event_model_key`;
- cleanup binds the receipt-owned historical `event_model_key` through the enclosing target and private reservation, then emits it as event `model_key`;
- non-cleanup candidate actions derive the private immutable event key from the row `model_key` across reservation, active/history/terminal, failed-dispatch, cancellation, and event paths;
- T18 uses the landed squash merge as current authority and treats `922624a7959253aae0581c6e2db22f827925072b` only as historical pre-squash evidence; and
- historical review anchors use reproducible `fa71b09c:<path>` references.

The preceding v16 gate reported 0 Critical, 1 High, and 2 Medium findings. V17 closed all three without weakening acceptance criteria.
