# Round 3 (final) findings and dispositions (#1355)

Verdicts:
- code: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW, 0 INFO
- security: 0 CRITICAL, 0 HIGH, 1 MEDIUM (NEW), 0 LOW, 0 INFO
- architecture: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 2 LOW, 0 INFO

| Lane | Severity | Finding | Disposition |
|---|---|---|---|
| security | MEDIUM (NEW) | Long-input scoring could be steered by an early content token, because prefill was input over TTFT | Fixed after round 3. Prefill is now input over the whole service time (dispatch done to done) and is sampled only on prefill-dominated attempts (input at least 4x delivered completion). An early token cannot shorten the service time. SPEC-002-R005 updated; TestPerfPrefillUsesServiceTime added. Round cap reached, so this fix has no fourth audit round. |
| architecture | LOW | Engine profile serialized on /poolz through pool.Provider JSON | Fixed: the field is not serialized with the provider; the admin listing exposes it. |
| architecture | LOW | One store lock per candidate lookup | Fixed: PhaseOrder reads all candidates under one read lock (LookupMany). |

Carried: LOW facade-level privacy-mode tests, LOW O(N) eviction when the store is full, INFO duplicated route-trace grammar (pinned by tests on both sides).

Pre-existing, reported to the operator, not in this diff: Go toolchain standard-library advisories (go1.26.6), and the existing X-Provider-Id buyer header.
