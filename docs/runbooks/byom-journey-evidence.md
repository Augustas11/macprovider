# BYOM Signed-Journey Evidence

**Epic:** #1240 · **Gate:** #1248 (BYOM v0.1 promotion requires signed journey
evidence, not prose) · **Specs:** SPEC-046, SPEC-047

#1248 requires `JOURNEY-PROVIDER-BYOM-DISCOVERY` evidence for local discovery and
`JOURNEY-NETWORK-MODEL-ADMISSION` evidence before any network-admission claim,
and requires that the evidence reach `specs/CONFORMANCE.json` only through the
repository governance path. This runbook is the exact operator sequence.

Nothing here promotes anything on its own. Capture and build are reproducible and
noninteractive; **signing is the operator step** and needs the acceptance signing
key that only the release operator holds.

## What the two journeys are

| Journey | Spec | Journey contract | Steps | Evidence artifact |
|---|---|---|---|---|
| `JOURNEY-PROVIDER-BYOM-DISCOVERY` | SPEC-046 (R001–R008) | `journeys/JOURNEY-PROVIDER-BYOM-DISCOVERY.md` | `step-01-discover-mlx-cache` … `step-10-local-state-ladder` | `journeys/evidence/provider-byom-discovery-*.redacted.json` |
| `JOURNEY-NETWORK-MODEL-ADMISSION` | SPEC-047 (R001–R008) | `journeys/JOURNEY-NETWORK-MODEL-ADMISSION.md` | `step-01-offer-dry-run` … `step-12-redaction-review` | `journeys/evidence/network-model-admission-*.redacted.json` |

The step ids, the required-`true` / required-`false` observation names, the
evidence schema strings, and the evidence path prefixes are the normative lists in
those two journey contracts. They are mirrored in `scripts/check_spec_governance.py`
(`PROVIDER_BYOM_DISCOVERY_*`, `NETWORK_MODEL_ADMISSION_*`) and enforced on both the
capture side and the governance side. Do not invent a step id: an unlisted step id
is rejected, and a missing one is rejected.

Each step also declares the SPEC requirement ids it exercises. The allowed set per
step comes from the requirement subjects in SPEC-046 §3 / SPEC-047 §3 (plus the
release-evidence requirement, `SPEC-046-R008` / `SPEC-047-R008`, which the journey
proves as a whole). The union across all steps must cover every requirement mapped
to the journey, or capture fails.

`environment.class` records how the run was executed:

- `hermetic-loopback` — the harness at `test/e2e/byom/run-cli-onboarding-e2e.py`
  (`make test-byom-e2e`).
- `physical-provider` — a real Mac run per
  `test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md`.

## Redaction posture

The capture tool fails closed. It refuses to emit evidence that contains a URL, an
absolute or `~/`-relative path, a hostname, an IP literal, a `localhost`
reference, or anything shaped like a credential, in either a key or a value. It
also refuses to record a captured CLI document that still contains a credential.

Captured CLI JSON documents are **never** copied into the repository. Only their
SHA-256 digest, byte count, declared schema, and a short id are recorded. Keep the
raw documents in operator-local storage; the digests are what bind the signed
result to them.

## Step 1 — run the journey and collect CLI documents

Hermetic:

```bash
make test-byom-e2e
```

Physical provider Mac: follow `test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md`.

Save each `--json` document the run produced (discovery, evaluation, offer
dry-run, admission status, withdrawal, catalog economics) into one local
directory, e.g. `~/byom-run/captures/`. For the admission journey, also read the
money-path row counts directly from the coordinator's own tables (ledger,
settlement, payout, request log) — not from a quiet API.

## Step 2 — write the run manifest

Create `~/byom-run/run-manifest.json` using schema
`macprovider.byom-journey-run.v1`. Copy the shape from the committed golden
fixtures:

- `scripts/tests/fixtures/byom_journeys/discovery/run-manifest.json`
- `scripts/tests/fixtures/byom_journeys/admission/run-manifest.json`

Required keys: `schema_version`, `journey_id`, `run_id`, `environment_class`,
`cli_version`, `harness` (`{name, status}`), `steps`, `observations`. Each step is
`{id, status, assertion, requirement_ids, documents}`, and each document is
`{id, schema, path}` where `path` is relative to the manifest file. Document paths
stay local; they are digested, not published.

The admission manifest must additionally carry
`observations.money_path_zero_rows` with every one of these tables set to the
integer `0` (SPEC-047-R003):

```
ledger_operator_credits      ledger_payout_ready        ledger_quarantine_resolutions
ledger_request_credits       payout_attempts            request_log
settlement_attempt_outputs   settlement_receipt_verdicts
settlement_route_snapshots   spec022_payable_request_credits
```

## Step 3 — capture the redacted evidence

```bash
python3 scripts/capture-byom-journey-evidence.py \
  --journey discovery \
  --run-manifest ~/byom-run/run-manifest.json \
  --output journeys/evidence/provider-byom-discovery-<UTC>.redacted.json \
  --source-sha "$(git rev-parse HEAD)" \
  --operator-role release-operator \
  --operator-identity-fingerprint <sha256-hex> \
  --hardware-profile <redacted-profile-label> \
  --candidate <candidate-build-label> \
  --summary "<one line>"
```

Use `--journey admission` and the `network-model-admission-` output prefix for the
admission journey. Add `--run-hermetic-harness` to have the tool run
`test/e2e/byom/run-cli-onboarding-e2e.py` first and refuse to capture unless it
passes.

Review the emitted artifact by eye, then commit it through a normal PR. The
evidence artifact must be committed before the next step, because the builder
verifies its bytes against the commit that contains it.

## Step 4 — build the unsigned journey-result payload

```bash
python3 scripts/build-byom-discovery-journey-result.py \
  journeys/evidence/provider-byom-discovery-<UTC>.redacted.json \
  --output /tmp/byom-discovery-journey-result.unsigned.json \
  --source-sha <candidate-source-commit> \
  --evidence-sha <commit-containing-the-evidence> \
  --requirement-ids SPEC-046-R001,...
```

`scripts/build-network-model-admission-journey-result.py` is the admission
counterpart. Both refuse to promote a requirement that is not mapped to their
journey, not still `pending`, or not covered by the evidence. Omit
`--requirement-ids` to cover everything the evidence covers.

The unsigned payload is runner-temp state. Do not commit it.

## Step 5 — preflight (still no signature)

```bash
python3 scripts/preflight-signed-journey-promotion.py \
  --source-sha <candidate-source-commit> \
  --requirement-ids SPEC-046-R001,... \
  --journey-id JOURNEY-PROVIDER-BYOM-DISCOVERY
```

This rejects a stale promotion: the requirement must still be `pending`, must be
mapped to the journey, and its `implementation`/`tests` selectors must still
resolve at `--source-sha`. Fix drift here rather than after signing.

## Step 6 — sign (operator key required)

**This is the only step that needs the acceptance signing key**, and it is the
only step an agent must not perform on the operator's behalf.

```bash
MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM=<path-or-env-indirect> \
python3 scripts/sign-journey-result.py \
  /tmp/byom-discovery-journey-result.unsigned.json \
  --output journeys/evidence/provider-byom-discovery-<UTC>.<requirement-slug>.journey-result.signed.json
```

The signature is `ecdsa-p256-sha256` under key id
`macprovider-acceptance-p256-v1`, verified against
`security/acceptance-candidate-signing-public.pem`. Never print, echo, copy, or
commit the private key. Prefer running this in the `production-release`
environment the sibling promotion workflows use, so the key never lands on a
laptop.

## Step 7 — promote and reconcile conformance

```bash
python3 scripts/promote-signed-journey-result.py \
  journeys/evidence/provider-byom-discovery-<UTC>.<requirement-slug>.journey-result.signed.json \
  --requirement-ids SPEC-046-R001,...

python3 scripts/check_spec_governance.py --base-ref origin/main
```

Promotion is what writes the `sha256:`/`source` evidence entry into
`specs/CONFORMANCE.json` and moves the requirement out of `pending`. Do not edit
`specs/CONFORMANCE.json` states or evidence by hand — a hand-edited row is exactly
the prose-only promotion #1248 forbids.

Then open a PR containing the redacted evidence, the signed envelope, and the
conformance change, and let `spec-index / check` run.

## Verification while iterating

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_byom_journey_evidence
python3 scripts/check_spec_governance.py
make test-byom-e2e
```

The unit suite also runs inside `make test-dist`.

## Related

- `docs/runbooks/byom-disablement-rollback.md` — promotion checklist and the
  disable switch for every BYOM surface.
- `test/e2e/byom/README.md`, `test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md` — how to
  produce the runs this evidence describes.
