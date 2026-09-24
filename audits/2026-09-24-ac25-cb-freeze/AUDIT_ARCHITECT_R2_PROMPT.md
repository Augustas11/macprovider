## Round 2 — architecture lane only (code and security lanes passed round 1)

Round 1 architecture: 0C/0H/1M. MEDIUM: `specs/CONFORMANCE.json` still
recorded SPEC-001 `1.9.19` and SPEC-038 `v0.2.3`; `check_spec_governance.py`
red; `scripts/tests/test_byom_contract_lock.py` pinned `1.9.19`.

Fixed in `db762e12`, which also addresses two LOWs from the code/architecture
lanes: `CBTrace` now uses `FileHandle.write(contentsOf:)`, and
`InferenceRelay.errorEndFrame` logs the original CB queue-pressure code
(`event=batching_relay_queue_pressure ... code=... request_id=...`) where it
collapses to `error_queue_full`.

Verify the MEDIUM is closed (run `python3 scripts/check_spec_governance.py`,
`python3 scripts/gen_spec_index.py --check`, and
`python3 -m unittest scripts.tests.test_byom_contract_lock`), check that no
other spec-version pin or ledger still names the old versions, and review
whether `db762e12` introduced anything: the relay log line runs inside the
static `errorEndFrame` (called by tests and the relay); it must log ids and
codes only.
