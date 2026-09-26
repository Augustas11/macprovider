## Lane: ARCHITECTURE (spec conformance, rollout)

Check:
- SPEC-038 v0.2.10 FR-CB2 and SPEC-003 v0.11.4 against the code, plus
  CONFORMANCE and the spec index.
- SPEC-039 paged-KV semantics: block tables, FR-PKV10 retain/reattach, and
  FR-PKV13 overhead after the in-place change.
- Fleet rollout of the plist change: the auto-update template rendering path,
  existing installs, and rollback.
- Whether the decode-window default (8) and the evidence justify it.
