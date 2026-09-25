# Codex audit: batched sampled rows (SPEC-038 v0.2.6 AC-6b)

Diff `30e634eb..cafcdb80/a7bb1b04` (stacked on the audited #1716 head).

| Lane | Round 1 |
| --- | --- |
| Code | **PASS** 0/0/0 |
| Security / money path | **PASS** 0/0/0 |
| Architecture | **PASS** 0/0/0 |

Carried maintenance note (architecture, INFO): penalties are ignored on both
paths today. If serial generation starts honoring presence/frequency
penalties, batched admission must first serial-route penalized requests (or
add equivalent batched processors), or outputs will diverge.
