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

- `hermetic-loopback` — a loopback harness: the discovery-journey driver at
  `test/e2e/byom/run-discovery-journey.py` (`make test-byom-discovery-journey`)
  or the onboarding harness at `test/e2e/byom/run-cli-onboarding-e2e.py`
  (`make test-byom-e2e`).
- `physical-provider` — a real Mac run per
  `test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md`.

## Redaction posture

The capture tool fails closed. It refuses to emit evidence that contains a URL, an
absolute or `~/`-relative path, a hostname, an IPv4 or IPv6 literal, a `localhost`
reference, or anything shaped like a credential, in either a key or a value. The
same fail-closed scan runs over every captured CLI document before it is digested,
because the digest is what the signed result binds to. A document that legitimately
contains an endpoint or a local path is one you redact before capture, or capture
refuses the whole run.

The hostname rule is shape-based, not a suffix list: **any** DNS-shaped token —
one or more `label.` groups ending in an alphabetic label — is rejected, whatever
the TLD. Credential shapes are compiled from `CREDENTIAL_SHAPE_PATTERN_FRAGMENTS`
in `scripts/check_spec_governance.py`, so this scanner can never be narrower than
the sibling signed-journey scanner.

There is no global allowlist. A repository source **file name**
(`run-cli-onboarding-e2e.py`, `run-manifest.json`) is `<name>.<ext>` and therefore
DNS-shaped by coincidence; it is accepted only at the structurally validated
`harness.name` field (`REPO_SOURCE_FILE_FIELDS` / `REPO_SOURCE_FILE_NAME_RE` in
`scripts/byom_journey_evidence.py`). The same token in a step assertion or a
captured document value is a hostname and fails closed, and an unlisted
extension fails closed even in `harness.name`. Every other value the contract emits —
evidence and document schema ids, step ids, requirement ids, run ids, CLI and
semantic versions — ends in a label that is not purely alphabetic and so never
reaches the allowlist at all.

Governance does not take the signed payload's word for any of this.
`_validate_byom_journey_source()` in `scripts/check_spec_governance.py` re-opens
the referenced redacted evidence and re-runs the same shared contract — the
redaction scan, `validate_evidence_steps()`, and `validate_evidence_observations()`
(money-path zero rows included) — then compares the signed requirement ids, step
projection, observations, and metadata against it. A hand-authored payload with a
valid acceptance signature is rejected if it disagrees with its own source
artifact.

Captured CLI JSON documents are **never** copied into the repository. Only their
SHA-256 digest, byte count, declared schema, and a short id are recorded. Keep the
raw documents in operator-local storage; the digests are what bind the signed
result to them.

## Step 1 — run the journey and collect CLI documents

### Discovery journey, hermetic: one command

```bash
test/e2e/byom/run-discovery-journey.py --evidence --out ~/byom-run
```

`--evidence` is not optional here. It is what makes the run capturable at all:
only an `--evidence` run writes `run-manifest.json`. A run without it writes
`run-summary.json` — the same content under a name step 3 does not consume — so
a local debugging run cannot be promoted no matter what the operator does next.
That is deliberate: without `--evidence` the driver accepts a
`MACPROVIDER_CLI_BINARY` override and never checks the source tree, so the run
proves nothing about any commit.

The driver runs all ten `JOURNEY-PROVIDER-BYOM-DISCOVERY` steps against
loopback stubs and an on-disk MLX-cache fixture, writes every captured CLI
document to `~/byom-run/captures/`, and writes `~/byom-run/run-manifest.json`
itself — so **steps 1 and 2 are already done** and you can go straight to step 3.
`--out` must be a new or empty directory: reusing one is refused rather than
cleaned, so a failing rerun can never leave an earlier run's passing manifest
sitting there as if it were current. The manifest is published atomically and
only after every step and observation check has passed.

Every observation in that manifest is set from the driver's own assertions. The
two negative observations are read off harness-owned ledgers rather than
declared: a recording coordinator sink is configured as the CLI's coordinator
for the whole run and must finish with zero requests and zero accepted
connections (`provider_credit_created`), and the harness starts no buyer gateway
at all while the only chat request anywhere in the run is the evaluation's
single local probe (`buyer_traffic_sent`). A failed assertion aborts the run, so
a manifest exists only for a run where all ten steps passed.
`make test-byom-discovery-journey` runs the driver and then step 3 and step 4
against its output, which is how CI proves the driver and the governance tables
have not drifted apart.

Step 10 reaches the ladder's local-default `not_offered` row by running `models
admission status <offerable candidate> --json` with no coordinator configured at
all — a harness-owned config with a provider id and no `coordinator_url`, and
`MACPROVIDER_COORDINATOR_URL` removed from that one command's environment — so
the CLI answers from local inventory, the document carries
`admission_state_source: local_default` with the `coordinator_state_unavailable`
warning, and the coordinator sink ledger stays empty.

Captured CLI documents are stored **whole**. Nothing is stripped before hashing,
so the digest binds the CLI's complete closed envelope, including the
SPEC-046-R003 `provider_guidance` localization keys. Those two fields —
`state_label_key` and `state_meaning_key` — are dotted label paths
(`byom.local.offerable`) and therefore DNS-shaped by coincidence, so the shared
scanner validates them against a closed `byom.<segment>.<segment>…` grammar at
exactly those two paths inside a `provider_guidance` object, while still
applying every credential, URL, path, IP, and localhost check to the value.
Anything else at those paths fails closed, and the same string in any other
field is still just a hostname. The driver runs that same scan — the capture
tool's own functions, imported not reimplemented — over every command's real
stdout and stderr, and over every document before writing it, so it cannot emit
a manifest that step 3 would reject. The localization-key exemption applies only
to stdout that is about to receive the structured document scan: plain-text
output such as `--version` gets the full plaintext scan, hostname rule included.

Every captured document is also validated against its **complete** closed
schema, and that validation lives in the shared capture contract
(`scripts/byom_journey_evidence.py`), invoked from the document-digest step. It
therefore covers every discovery capture that reaches evidence — the hermetic
driver's and a hand-authored physical discovery run's alike — not only the
documents this driver produced. The field sets are the SPEC-046-R003 discovery
envelope and candidate fields, the exact SPEC-046-R004 capability object, the
SPEC-046-R005 evaluation envelope and mutation summary, and the SPEC-047-R002
dry-run and status envelopes; `adapters[]` rows and `model_catalog_economics.v1`
rows, which the specs describe without enumerating field names, are frozen at
the shape the CLI emits. A missing field, an unknown field, and an unenumerated
schema all fail closed. Redaction-clean is not the same as complete, and the
signed evidence binds a digest of these documents.

**Scope of typed validation (epic #1453 slice 1b).** Typed closed-enum
validation currently applies to the **discovery** journey's documents only,
because the hermetic driver above is what produces real CLI captures to type the
validators against. The **admission** journey
(`JOURNEY-NETWORK-MODEL-ADMISSION`) keeps the earlier capture boundary — the
full redaction scans plus the check that a document's own top-level `schema`
equals the schema its manifest claims — since that journey cannot be captured
end to end before catalog binding exists. Typed validation of admission captures
lands with the admission-journey slice (epic #1453 slice 7). Both journeys keep
the harness-name binding: a run manifest may only name its own journey's
harness.

`--evidence` binds the run to the commit the evidence names:

- the `MACPROVIDER_CLI_BINARY` override is refused;
- `phase3-binary/Package.resolved` is reconciled with `HEAD` first, and only
  ever in one direction. If the working-tree lockfile already matches `HEAD`,
  nothing happens. If it differs **in an ephemeral CI checkout** (`GITHUB_ACTIONS`
  or `CI` set, and nothing staged for the file), `HEAD`'s bytes are restored with
  a logged notice: that drift is the earlier `swift test` step resolving the
  graph under the runner's default toolchain, and `HEAD`'s lockfile is separately
  proven consistent by the `phase3-binary (locked SwiftPM resolve)` job.
  Anywhere else — a developer machine, or a CI run with the lockfile staged — a
  differing lockfile is uncommitted work, so the run **refuses** rather than
  discarding it; commit the file or restore it yourself and re-run. The CI
  wrapper does no lockfile surgery of its own;
- the tree must then be clean — **tracked and untracked** — across
  `phase3-binary/Sources`, `phase3-binary/Tests`, `phase3-binary/Package.swift`,
  `phase3-binary/Package.resolved`, `scripts/`, and `test/e2e/byom/`. Untracked
  counts: SwiftPM builds every `.swift` file under the executable's source
  directory;
- the CLI is built from that source with locked resolution
  (`--only-use-versions-from-resolved-file`, the same lock the locked-resolve CI
  job applies through xcodebuild), so the build cannot rewrite the lockfile;
- the cleanliness check runs **again after the build**, and the CI wrapper
  records `source_sha` only once that post-build check has passed.

Local exploratory runs may omit `--evidence` and keep the override; they produce
no manifest.

### Everything else: hand-authored

For the admission journey, and for a physical-provider discovery run
(`test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md`), collect the documents and write the
manifest by hand as described below.

```bash
make test-byom-e2e
```

Save each `--json` document the run produced (discovery, evaluation, offer
dry-run, admission status, withdrawal, catalog economics) into one local
directory, e.g. `~/byom-run/captures/`. Redact each document first: a captured
value that carries an endpoint, a local path, a hostname, an IP literal or a
credential makes step 3 refuse the whole run. For the admission journey, also
read the money-path row counts directly from the coordinator's own tables
(ledger, settlement, payout, request log) — not from a quiet API.

## Step 2 — write the run manifest

Skip this step for a hermetic discovery run: the driver already wrote the
manifest.

Otherwise create `~/byom-run/run-manifest.json` using schema
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

`MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM` must already hold the **PEM contents** of
the acceptance signing key — `read_private_key()` reads the variable itself, not a
path to a key file and not the name of another variable. In the
`production-release` environment it comes straight from the repository secret of
the same name, exactly as the sibling `promote-signed-*-journey.yml` workflows set
it.

```bash
python3 scripts/sign-journey-result.py \
  --input /tmp/byom-discovery-journey-result.unsigned.json \
  --output journeys/evidence/provider-byom-discovery-<UTC>.<requirement-slug>.journey-result.signed.json
```

`--input` and `--output` are both required, and `--output` must resolve under
`journeys/evidence/`. The signature is `ecdsa-p256-sha256` under key id
`macprovider-acceptance-p256-v1`, verified against
`security/acceptance-candidate-signing-public.pem`. Never print, echo, copy, or
commit the private key. Prefer running this in the `production-release`
environment the sibling promotion workflows use, so the key never lands on a
laptop.

## Step 7 — promote and reconcile conformance

```bash
python3 scripts/promote-signed-journey-result.py \
  --base-ref origin/main \
  --requirement-ids SPEC-046-R001,... \
  journeys/evidence/provider-byom-discovery-<UTC>.<requirement-slug>.journey-result.signed.json

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
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_discovery_journey_driver
python3 scripts/check_spec_governance.py
make test-byom-e2e
make test-byom-discovery-journey
```

The unit suite also runs inside `make test-dist`.

## Related

- `docs/runbooks/byom-disablement-rollback.md` — promotion checklist and the
  disable switch for every BYOM surface.
- `test/e2e/byom/README.md`, `test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md` — how to
  produce the runs this evidence describes.
