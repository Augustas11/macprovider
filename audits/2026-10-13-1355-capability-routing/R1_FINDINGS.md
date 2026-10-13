# Round 1 findings and dispositions (#1355)

Verdicts:
- code: 0 CRITICAL, 1 HIGH, 3 MEDIUM, 3 LOW, 0 INFO
- security: 0 CRITICAL, 2 HIGH (1 NEW, 1 PRE-EXISTING), 0 MEDIUM, 0 LOW, 2 INFO
- architecture: 0 CRITICAL, 0 HIGH, 1 MEDIUM, 3 LOW, 1 INFO

| Lane | Severity | Finding | Disposition |
|---|---|---|---|
| security | HIGH (NEW) | Provider usage counts became routing evidence | Fixed. Rates now use only coordinator quantities: its body token estimate for prefill, its delivered-bytes estimate for decode, its clock for TTFT. A reported cached prefix only withholds a prefill sample. SPEC-002-R005 rewritten. |
| code | HIGH (NEW) | Partial or faulted 200 streams recorded as evidence | Fixed. Observation requires no error, no error code and no fault on the attempt. |
| (found while fixing) | — | The provider sends a role-only opening chunk before prefill, so first byte is not first token | Fixed. New coordinator first-token mark (first delivered event with content or a tool call) drives TTFT and decode. |
| security | HIGH (PRE-EXISTING) | Go toolchain go1.26.6 standard-library advisories | Not in this diff; reported to the operator for a separate toolchain bump. |
| code | MEDIUM | Zero-token completions dropped TTFT evidence | Fixed; only decode needs 8 tokens. |
| code / architecture | MEDIUM / LOW | Pinned and slot-queue traces reported zero candidates | Fixed; operator line has `scope` (ranked, pinned, slot_queue) and real counts. |
| code | MEDIUM | CORS did not allow or expose the new headers | Fixed; preflight allows the privacy header, responses expose the three headers. |
| architecture | MEDIUM | Route trace lost on gateway-written error responses | SPEC clarified: the trace rides responses the coordinator writes and the gateway relays; an error the gateway writes itself may omit it. |
| code | LOW | No facade-level privacy-mode tests | Carried: the facades share the chat handler and the gate runs before translation. |
| code | LOW | SPEC-006 narrative said R004–R018 | Fixed. |
| code | LOW | Long-input latency used total, not uncached, input | SPEC aligned: it uses the coordinator input estimate (cache state is unknown before dispatch). |
| architecture | LOW | Engine profile cross-field invariants unchecked | Fixed; family/MTP and plain-MLX/slots contradictions drop the profile. SPEC-001-R006 updated. |
| architecture | LOW | Store eviction under a global lock is O(N) when full | Carried: only on insert into a full store; 65536 records. |
| architecture | INFO | Route-trace grammar duplicated across modules | Carried; both sides pin it with tests. |
| security | INFO | Coarse evidence/latency classes visible to buyers | Accepted by SPEC-002-R007. |
| security | INFO | Engine profile is self-reported | Cross-field check added; it never feeds scoring. |
