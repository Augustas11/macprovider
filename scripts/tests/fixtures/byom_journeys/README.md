# BYOM journey golden fixtures

These run manifests and captures are the golden inputs for
`scripts/tests/test_byom_journey_evidence.py`. Capture validates every one of
them through the real path in `scripts/byom_journey_evidence.py`, so they have
to be documents the CLI can actually emit — not plausible-looking JSON.

The R4 audit of #1453 slice 1 found the opposite: the captures had been
hand-synthesized, and carried values no CLI ever produced (`identity_state:
declared_local`, `locality: local_weights`, capability results as strings,
`completion_sha256` for `response_body_sha256`, `next_action: serve_traffic`).
Key-set-only validation accepted all of them. The validator now checks wire
types, nullability, the closed SPEC enums, and the state/source cross-field
rules, and the `discovery/` fixtures were regenerated from real CLI output. That
validator runs for the discovery journey only in this slice; `admission/` is
covered below.

## Provenance

### `discovery/` — all captures are real, unedited CLI output

Produced by running the hermetic driver and copying its captures verbatim:

```bash
test/e2e/byom/run-discovery-journey.py --out /tmp/byom-discovery
cp /tmp/byom-discovery/captures/*.json \
   scripts/tests/fixtures/byom_journeys/discovery/captures/
```

`run-manifest.json` is hand-written (it is the contract fixture, not a captured
document), but its `harness.name` is now the driver that actually produces these
captures — the evidence contract binds each journey to exactly one harness.

The driver emits three further captures (`admission-status-state-ladder`,
`discover-state-ladder-unstable`, `catalog-economics-state-ladder`) that this
manifest does not reference; they are omitted rather than committed unused.

### `admission/` — unchanged in this slice, still hand-authored

The admission captures are exactly as they were before this slice: they are
hand-authored, not real CLI output, and this slice deliberately does not touch
them. Typed closed-enum validation is scoped to the discovery journey here (see
`JourneyContract.typed_capture_validation` in
`scripts/byom_journey_evidence.py`), so these fixtures are still validated only
by the redaction scans and the check that each document's own top-level `schema`
equals the schema its manifest claims — the boundary that applied before this
slice.

The reason is provenance, not appetite: the `JOURNEY-NETWORK-MODEL-ADMISSION`
journey cannot be captured end to end until catalog binding exists, so there is
no real admission run to regenerate these fixtures from or to type the
validators against. Regenerating them and turning typed validation on for the
admission contract lands together with the admission-journey slice (epic #1453
slice 7).

`admission/run-manifest.json` still names `test/e2e/byom/run-cli-onboarding-e2e.py`,
and the harness-name binding introduced in this slice applies to both journeys:
an admission manifest may not claim the discovery driver's provenance, or any
other repository file's.

## Regenerating

Re-running the discovery driver and copying its captures is the whole procedure
for `discovery/`. `admission/` has no regeneration procedure yet — that arrives
with the admission-journey slice. If a real document ever trips capture's
redaction scanner, that is a CLI bug to report — never a value to edit out of
the fixture.
