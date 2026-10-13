# Round 2 findings and dispositions (#1355)

Verdicts:
- code: 0 CRITICAL, 0 HIGH, 1 MEDIUM, 1 LOW, 0 INFO
- security: 0 CRITICAL, 1 HIGH (PRE-EXISTING), 2 MEDIUM (1 NEW, 1 PRE-EXISTING), 0 LOW, 0 INFO
- architecture: 0 CRITICAL, 0 HIGH, 1 MEDIUM, 1 LOW, 0 INFO

| Lane | Severity | Finding | Disposition |
|---|---|---|---|
| architecture | MEDIUM (NEW) | Sticky epsilon was judged against the phase-selected top | Fixed. applySticky runs on the objective order first; a sticky hit keeps its provider and skips the phase reorder (basis fallback, scope sticky). SPEC-002-R006 updated; test added. |
| code | MEDIUM (NEW) | Buffered and JSON-to-SSE stream paths never mark a first token | Decided: those paths deliver the whole response at once, so a first-token time there would be total service time. They yield no sample by design; SPEC-002-R005 states it. Incremental WS and HTTP streams, the normal path, are measured. |
| security | MEDIUM (NEW) | No per-provider fairness in store eviction | Fixed. At most 64 records per provider; a provider at its budget replaces its own oldest record. Test added. |
| security | HIGH (PRE-EXISTING) | Go toolchain standard-library advisories | Not in this diff; reported to the operator. |
| security | MEDIUM (PRE-EXISTING) | Existing X-Provider-Id buyer header exposes provider identity | Not in this diff; reported to the operator. The new route trace carries classes only. |
| code | LOW | Privacy-mode refusals carry no disclosure headers | SPEC-006-R019 clarified: refusals carry neither header because no mode was served. |
| architecture | LOW | Engine profile not checked against its heartbeat | Fixed. A profile whose context or RAM class disagrees with the heartbeat is dropped. SPEC-001-R006 updated; tests added. |
