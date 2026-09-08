# AUDIT 1248 — BYOM signed-journey evidence tooling — R1

**Date:** 2026-09-08 · **Branch:** `feat/1248-byom-journey-evidence` ·
**Issue:** #1248 (parent epic #1240) · **Specs:** SPEC-046, SPEC-047

Prompt: `audits/2026-09-08-byom-gates/AUDIT_1248_JOURNEY_EVIDENCE_PROMPT.md`.
Scope: the full branch diff `origin/main...HEAD` for the capture → build →
governance pipeline (`scripts/byom_journey_evidence.py`,
`scripts/capture-byom-journey-evidence.py`, the two builders,
`scripts/check_spec_governance.py` registration, the unit suite and golden
fixtures, and `docs/runbooks/byom-journey-evidence.md`).

Architecture lane verdict on R1 input: **0 CRITICAL / 0 HIGH / 3 MEDIUM / 0 LOW /
0 INFO**. All three MEDIUMs are resolved below.

## MEDIUM 1 — Builder could overclaim from hand-authored redacted evidence

**Finding.** The builder selected promotable requirements from the top-level
`evidence.requirement_ids` and checked only that the named steps existed. It did
not revalidate each step's `requirement_ids` nor recompute the union, so redacted
evidence written by hand (rather than emitted by capture) could declare a
requirement its steps never exercised and still reach the signer.

**Resolution.** One shared evidence-step validator, used by both sides.

- `scripts/byom_journey_evidence.py:468` — `validate_evidence_steps()` is now the
  only step validator. It requires the exact step-key set for the journey
  (unknown id, duplicate id, and missing id all fail), requires `status == "pass"`
  and `artifacts == [artifact_id]`, validates every per-step requirement id
  against `JourneyContract.allowed_step_requirement_ids()`, revalidates the
  captured-document digest entries, recomputes the union of the per-step
  requirement ids, and fails unless that union covers every promotable
  requirement (all eight per journey).
- `scripts/byom_journey_evidence.py:567` — capture's `_require_manifest_steps()`
  now only maps run-manifest steps to evidence steps (digesting the captured
  documents) and delegates every contract check to the shared validator at
  `scripts/byom_journey_evidence.py:597`. No duplicated validation logic remains.
- `scripts/byom_journey_evidence.py:761` — `build_journey_result_payload()` runs
  the same validator over the committed evidence, then requires the top-level
  `evidence.requirement_ids` to be unique and to equal the recomputed union
  (`scripts/byom_journey_evidence.py:768`) before `parse_requirement_ids()` can
  select anything. The signed payload's steps are projected from the validated
  steps at `scripts/byom_journey_evidence.py:809`.

**Rejection tests** (all fail against the pre-fix module):
`scripts/tests/test_byom_journey_evidence.py:469` extra step,
`:477` missing step, `:483` per-step id outside the allowed set,
`:489` top-level ids ≠ union, `:497` top-level ids padded with a foreign id,
`:503` evidence that stops covering every mapped requirement.

## MEDIUM 2 — Captured CLI documents were scanned for credentials only

**Finding.** `_digest_document()` ran only `reject_secret_like_text()` over the
captured CLI JSON, while the module's redaction contract and `assert_redacted()`
fail closed on URLs, absolute and `~/`-relative paths, hostnames, IP literals,
`localhost`, and credentials. The document digest is what the signed result binds
to, so the redaction claim was weaker than advertised for exactly those bytes.

**Resolution.** `scripts/byom_journey_evidence.py:459` now applies the full
`reject_unredacted_text()` scan to every captured document before digesting it.

**Allowlist decision: none — fail closed.** No raw-document field is exempted.
The committed golden fixtures under
`scripts/tests/fixtures/byom_journeys/*/captures/` carry no URL, path, hostname,
or IP, and the CLI documents these journeys capture (discovery listings,
evaluation verdicts, offer dry-runs, admission status, withdrawal, catalog
economics) do not need one. A document that legitimately contains an endpoint or
a local path is a document the operator redacts before capture; capture refuses
the whole run otherwise. This is stated in the code comment at
`scripts/byom_journey_evidence.py:452` and in the runbook's redaction posture at
`docs/runbooks/byom-journey-evidence.md:47`.

**Rejection tests:** `scripts/tests/test_byom_journey_evidence.py:211` URL,
`:217` absolute path, `:223` hostname, `:229` IPv4 literal, `:235` localhost —
alongside the pre-existing credential case at `:192`.

## MEDIUM 3 — Runbook signing command did not match the signer CLI

**Finding.** Step 6 showed a positional unsigned-payload argument and described
`MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM` as `<path-or-env-indirect>`, but
`scripts/sign-journey-result.py:153` requires `--input` and `read_private_key()`
(`scripts/sign-journey-result.py:66`) reads the variable as PEM contents. The
sequence was not executable as written.

**Resolution.** `docs/runbooks/byom-journey-evidence.md:159` now states that the
env var carries the PEM contents — not a path and not the name of another
variable — and matches how the sibling `promote-signed-*-journey.yml` workflows
set it; the command at `docs/runbooks/byom-journey-evidence.md:168` uses `--input`
and notes that `--output` must resolve under `journeys/evidence/`. While checking
the sequence end to end, Step 7 was also found to omit the required `--base-ref`
of `scripts/promote-signed-journey-result.py`; it is added at
`docs/runbooks/byom-journey-evidence.md:184`.

**Executed against the golden fixtures** (non-signing steps, in a scratch
repository; nothing promoted):

- Step 3 capture, discovery and admission — both wrote the redacted artifact.
- Step 4 build, both builders — the discovery payload covered
  `SPEC-046-R001..R008` across all 10 steps.
- Step 5 preflight — `1 requirement(s) match current selectors at ae8c847b`.
- Step 6 argument shape — with the key env var unset the signer parsed
  `--input`/`--output`, validated the payload, and failed only at
  `protected signing key env var is required`.
- Step 7 argument shape — the documented flag set was accepted and failed only on
  the deliberately absent envelope file.

## Verification

| Gate | Result |
|---|---|
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_byom_journey_evidence` | 47 tests, OK (36 → 47) |
| `python3 scripts/check_spec_governance.py` | SPEC governance validation passed |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_spec_governance scripts.tests.test_journey_result_tools scripts.tests.test_provider_prebeta_journey_result scripts.tests.test_local_consumer_endpoint_journey_result` | 121 tests, OK |
| `python3 scripts/gen_spec_index.py --lint` | ok: specs/ root is canonical-only (51 tracked) |

No SPEC file and no `specs/CONFORMANCE.json` row was touched by this pass.

## Verdict

VERDICT: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO (architecture lane, R1
findings resolved)

code-reviewer and security-reviewer lanes: pending
