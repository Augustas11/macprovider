# #1716 freeze audit — 2026-09-24

Three lanes on the full `origin/main...HEAD` diff (Phase A re-read only where
later commits touch it). Provider: Grok (`omc ask grok`); Codex was out of
quota until 2026-09-26.

| Lane | Round 1 | Round 2 |
| --- | --- | --- |
| Code | PASS, 0/0/0 (2 LOW) | — (not re-run) |
| Security / money path | PASS, 0/0/0 | — (not re-run) |
| Architecture | FAIL 0/0/1: CONFORMANCE.json versions stale | PASS, 0/0/0 (fixed in `db762e12`) |

LOWs: CBTrace deprecated stderr write (fixed `db762e12`); relay collapsed CB
codes without logging the original (fixed `db762e12`); no runnable regression
test for the ragged-row fix `309b8a85` (carried: MLX kernels cannot run under
`swift test` on this host; proof is the Studio serial-vs-batched evidence in
`docs/runbooks/data/cb-frpkv13-m3-2026-09-24/`).

## Round 3 — after folding #1731 (Qwen3.6 hybrid-cache CB) and the probe-pair fix

| Lane | Result |
| --- | --- |
| Code | PASS, 0/0/0 (3 LOW) |
| Security / money path | PASS, 0/0/0 |
| Architecture | PASS, 0/0/0 (1 LOW) |

LOWs: `event=batching_admitted` (and the other batching telemetry writes) used
the aborting `FileHandle.write(_:)`; fixed. The isolation probe-pair loop had
no regression test; extracted into `firstDistinguishingIsolationProbe` and
pinned by `IsolationProbePairSelectionTests`. Hybrid Mamba leave/join packing
tests are Metal-gated and skip here; carried, with Studio isolation-probe and
serial-vs-batched evidence as proof.

## Codex gate (authoritative)

The Grok rounds above are reference evidence only; the audit gate is Codex
(`omc ask codex`), three lanes on the full `origin/main...HEAD` diff. Prompts
and results are in `codex/`.

| Lane | Round 1 (`8c8ab335`) | Round 2 (`30e634eb`, after `217ebfe7` + #1713 merge) |
| --- | --- | --- |
| Code | **PASS** 0/0/0 | not re-run (passed) |
| Security / money path | FAIL 0/0/3 MEDIUM | **PASS** 0/0/0 |
| Architecture | FAIL 0/2 HIGH/1 MEDIUM | **PASS** 0/0/0 |

The round 1 findings are fixed in `217ebfe7`:
- Security M1: a failed isolation probe could be retried away.
- Security M2: the cache limit failed open.
- Security M3: the queue-wait timeout could overflow.
- Architecture H1: acceptance was not bound to the runtime revision.
- Architecture H2: the FR-PKV13 ceiling was not enforced. Its enforcement is
  now revision-bound acceptance (SPEC-038 v0.2.5, SPEC-039 v0.1.5).

Carried, pre-existing and confirmed by both round 2 lanes: `on` has no Gate A5
promotion predicate. `on` fails closed today and the rollout is `canary` only;
add the A5 gate before any production-default promotion.

### Round 3–4: after the gate, a CI-caught race (`b332156b`, `919cf12e`)

After the gate, CI caught an AC-25 race. A request re-queued past its
queue-wait deadline could be admitted before its zero-delay expiry task ran.
The fix is `b332156b`: expire an overdue request synchronously at admission.

| Lane | Round 3 (`b332156b`) | Round 4 (`919cf12e`) |
| --- | --- | --- |
| Code | FAIL 0/0/1: test gap, the stale test could not observe admission | **PASS** (deterministic regression test added; it fails without the fix) |
| Security | **PASS** | not re-run |
| Architecture | **PASS** | not re-run |

Merged as #1716 squash `36946873`.
