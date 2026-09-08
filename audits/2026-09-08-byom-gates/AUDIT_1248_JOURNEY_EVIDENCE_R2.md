# AUDIT 1248 — BYOM signed-journey evidence tooling — R2

**Date:** 2026-09-08 · **Branch:** `feat/1248-byom-journey-evidence` ·
**Issue:** #1248 (parent epic #1240) · **Specs:** SPEC-046, SPEC-047

Prompt: `audits/2026-09-08-byom-gates/AUDIT_1248_JOURNEY_EVIDENCE_PROMPT.md`.
R1 record: `audits/2026-09-08-byom-gates/AUDIT_1248_JOURNEY_EVIDENCE_R1.md`.
Scope: the full branch diff `origin/main...HEAD` (five commits, rebased onto
`3d97de18`), re-run after the R1 fixes.

## Lane verdicts on R2 input

| Lane | Verdict |
|---|---|
| architecture | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 0 INFO |
| security | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 0 INFO |
| code review | 0 CRITICAL / 0 HIGH / 2 MEDIUM / 0 LOW / 0 INFO |

All three lanes verified the R1 resolutions (shared `validate_evidence_steps()`
used by capture and both builders, the full redaction scan over captured
documents before digesting, and the runbook signing/promote commands) and did not
re-report them. All three lanes also confirmed there is no unsigned-promotion
bypass: the builders emit unsigned payloads only, and promotion still requires a
verified acceptance signature.

The three lanes converge on two distinct findings. The architecture lane's LOW is
the same defect as MEDIUM B, so closing B closes it.

## MEDIUM A — Redaction scanner was narrower than its advertised fail-closed contract

**Finding.** The module comment and the runbook both promise the evidence fails
closed on *any* hostname and on anything shaped like a credential. Two rules did
not hold up:

- Hostname detection was a fixed suffix allowlist —
  `com|net|org|io|ai|app|dev|cloud|tech|local|internal`. A DNS-looking hostname
  with any other suffix (`provider-mac.xyz`, `pool.example.co.uk`,
  `provider-mac.lan`, `mac-mini.home`, `provider-mac.corp`) passed both
  `assert_redacted()` and the captured-document scan in `_digest_document()`.
- The credential patterns were narrower than the sibling governance scanner in
  `scripts/check_spec_governance.py`. Most concretely, the BYOM `sk-` shape was
  `\bsk-[A-Za-z0-9]{20,}\b` while the sibling already covered
  `\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b`, so `sk-proj-…` and any `sk-` token
  carrying `_` or `-` passed. The sibling also applied its whole pattern set
  case-insensitively; BYOM did not.
- Only the IPv6 *loopback* literal `::1` was detected; other IPv6 literals were not.

**Resolution — one shape-based rule plus one explicit, tested allowlist.**

*Single source of truth for credential shapes.*
`scripts/check_spec_governance.py:271` now defines
`CREDENTIAL_SHAPE_PATTERN_FRAGMENTS`, the shapes credential material takes
independent of the field carrying it.
`LOCAL_CONSUMER_ENDPOINT_FORBIDDEN_METADATA_RE`
(`scripts/check_spec_governance.py:291`) is recomposed from its own
credential-bearing field-name fragments
(`scripts/check_spec_governance.py:281`) plus that shared tuple, so its behaviour
is unchanged. `scripts/byom_journey_evidence.py:128` compiles the same fragments
(case-insensitively) and appends only the two BYOM-specific extras that have no
sibling counterpart (`authorization: bearer …` at the tighter 8-character
threshold, and `provider-token-…`). The BYOM scanner can no longer drift narrower
than the sibling.

*Hostname rule.* `scripts/byom_journey_evidence.py:83` replaces the suffix list
with `DNS_HOSTNAME_RE`: one or more `label.` groups followed by a purely
alphabetic final label of 2–63 characters, with lookarounds that stop a match from
starting or ending mid-token. Any TLD is rejected.
`scripts/byom_journey_evidence.py:338` applies it per match through
`reject_hostname_like_text()`, which is reached from `reject_unredacted_text()`
(`scripts/byom_journey_evidence.py:345`) and therefore from both
`assert_redacted()` and the captured-document scan.

*IP literals.* `scripts/byom_journey_evidence.py:89` adds `IPV6_LITERAL_RE`
covering the full and compressed IPv6 forms (the previous `::1`-only rule is a
subset of it); the IPv4 rule is unchanged. URLs, absolute paths and `~/` paths
were already covered and remain so
(`scripts/byom_journey_evidence.py:117`).

**Allowlist decision — exactly one value shape, applied per match.**
`HOSTNAME_ALLOWLISTED_VALUE_SHAPES` (`scripts/byom_journey_evidence.py:111`)
admits a repository source **file name**, `<name>.<known-extension>`. That is the
only DNS-shaped value the contract legitimately emits: the evidence records
`harness.name` verbatim (`test/e2e/byom/run-cli-onboarding-e2e.py` in the golden
fixtures), and a file name is indistinguishable from a two-label hostname by
shape. An unlisted extension still fails closed
(`scripts/tests/test_byom_journey_evidence.py:898`).

Every other value shape the audit called out needs no allowlist entry, because it
is not DNS-shaped under the new rule and never reaches the allowlist: schema ids
end in `v1`/`v<N>` (`macprovider.provider-byom-discovery-evidence.v1`,
`provider_byom_discovery.v1`), step ids and requirement ids carry no dot
(`step-01-discover-mlx-cache`, `SPEC-046-R008`), `SnapshotManifestV1` carries no
dot, and semantic and CLI versions end in a numeric label (`1.8.117`, `v1.2.3`,
`0.0.0-fixture`). This was verified empirically over the committed golden
fixtures before the rule was chosen, and is now pinned by
`scripts/tests/test_byom_journey_evidence.py:865`.

**Rejection tests** (all fail against the pre-fix module):
`scripts/tests/test_byom_journey_evidence.py:257` and `:266` — the six hostname
suffixes outside the old fixed list, in a manifest assertion and in captured
document bytes; `:275` — IPv6 literals in captured documents; `:293` and `:302` —
the six token shapes the governance sibling covered and BYOM did not, in an
assertion and in captured document bytes; `:807` and `:821` — the direct scanner
sweep over hostnames, URLs, paths and IP literals; `:848` — the token-shape
sweep; `:898` — an unlisted file extension.

**Positive tests:** `scripts/tests/test_byom_journey_evidence.py:310` proves the
legitimate shapes survive a real capture end to end; `:865` asserts the full list
of legitimate value shapes is accepted by the scanner; `:836`/`:846` assert
structurally that the BYOM credential set is a superset of
`CREDENTIAL_SHAPE_PATTERN_FRAGMENTS` and that the governance sibling composes the
same fragments, so the two cannot drift apart silently.

## MEDIUM B — Governance verifier did not re-validate the referenced evidence artifact

**Finding.** The builder validated committed redacted evidence deeply, but the
BYOM governance validators checked only the signed payload's own fields plus the
artifact id and source prefix. The generic artifact loop bound the artifact bytes
to the declared `sha256`, and nothing re-opened the artifact. Since
`scripts/sign-journey-result.py` signs whatever payload it is handed, a
hand-authored BYOM payload with a valid acceptance signature could reach promotion
without ever passing the builder's checks — unlike the prebeta and local-consumer
journeys, which both re-open their hash-bound source.

**Resolution.** `_validate_byom_journey_source()` at
`scripts/check_spec_governance.py:2729`, the BYOM counterpart of
`_validate_local_consumer_endpoint_source()`. It re-opens the referenced
`*.redacted.json`, then re-runs the **shared** contract rather than
reimplementing it:

- `assert_redacted()` — the full redaction scan over the artifact.
- schema version, journey id, execution mode, and `environment.class` against the
  journey contract.
- `validate_evidence_steps()` — the same validator capture and the builders use,
  which recomputes the requirement union from the per-step ids.
- `validate_evidence_observations()` — the required-true / required-false names
  and the money-path zero-row rule. (This helper was previously named
  `_require_manifest_observations`; it is renamed and documented at
  `scripts/byom_journey_evidence.py:642` because governance is now a third
  caller. No behaviour changed.)
- the artifact's declared `requirement_ids` must be unique and equal the
  recomputed step union.

It then compares the signed payload against the validated source: the signed
requirement ids must all be covered by the recomputed union; the signed step
projection (`id`, `status`, `assertion`, `artifacts`) must equal the source's;
and `observations`, `run_id`, `captured_at`, `expires_at`, `repository`,
`operator`, `environment`, `result` and `redaction` must match the source
exactly.

The circular-import problem — `scripts/byom_journey_evidence.py` imports the
journey constants from `scripts/check_spec_governance.py` — is handled by the
lazy loader `_byom_evidence_module()` at
`scripts/check_spec_governance.py:2702`, which resolves the sibling by file
location and binds the child to this exact module object rather than executing a
second copy.

**Callers.** `_validate_byom_journey_artifacts()`
(`scripts/check_spec_governance.py:2819`) invokes it for the artifact whose id is
the journey's reviewed artifact, and now takes `journey_id`, `signed`, and a
keyword-only `root`. Both BYOM validators pass them
(`scripts/check_spec_governance.py:2896` discovery,
`scripts/check_spec_governance.py:2947` admission), and
`_validate_signed_journey_result()` threads `root=root` into both at
`scripts/check_spec_governance.py:3282` and `:3293`. `root` defaults to `None`
so direct unit calls that only exercise the payload rules keep working, exactly
as `_validate_local_consumer_endpoint_journey_result()` already does.

**Rejection tests** (`scripts/tests/test_byom_journey_evidence.py:902`,
`BYOMJourneyGovernanceSourceTests` — each builds real evidence from the golden
discovery fixture, writes it under a scratch `journeys/evidence/`, and projects
the signed payload from it):

- `:983` — a payload projected honestly from its source passes with no errors.
- `:986` — a signed requirement id the source does not cover is rejected.
- `:992` — source `requirement_ids` padded beyond the step union is rejected.
- `:999` and `:1005` — a signed step whose assertion disagrees with the source,
  and a dropped step, are both rejected.
- `:1011` — a tampered signed observation is rejected.
- `:1017` — a tampered source observation is rejected by the shared rule.
- `:1024` — a source step id outside the contract is rejected.
- `:1031` — source evidence that is no longer redacted is rejected.
- `:1038` — a signed operator role that disagrees with the source is rejected.
- `:1044` — an absent source artifact is rejected.

**End-to-end proof.** The two real builder outputs produced from the golden
fixtures (see Verification) were passed through both BYOM governance validators
with `root` set: both returned zero errors, and mutating one step's assertion in
the signed payload produced
`evidence[0].signed.artifacts[0].source.steps: signed steps must match the source
evidence steps`.

## LOW (architecture lane) — governance does not re-open BYOM redacted evidence

Same defect as MEDIUM B, and closed by the same change.

## Verification

| Gate | Result |
|---|---|
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_byom_journey_evidence` | 70 tests, OK (47 → 70) |
| `python3 scripts/check_spec_governance.py` | SPEC governance validation passed |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_spec_governance scripts.tests.test_journey_result_tools scripts.tests.test_provider_prebeta_journey_result scripts.tests.test_local_consumer_endpoint_journey_result scripts.tests.test_byom_contract_lock` | 127 tests, OK |
| `python3 scripts/gen_spec_index.py --lint` | ok: specs/ root is canonical-only (51 tracked) |

**Runbook operator sequence against the golden fixtures** (non-signing steps, in a
scratch repository; nothing promoted). This is the check that the tightened
scanner does not reject the committed goldens:

- Step 3 capture, both journeys — both wrote their redacted artifact; no hostname,
  IP, path or credential rejection.
- Step 4 build, both builders — discovery covered `SPEC-046-R001..R008` across 10
  steps; admission covered `SPEC-047-R001..R008` across 12 steps.
- Step 5 preflight — `2 requirement(s) match current selectors at 51f855a4`.
- Governance re-validation of both builder outputs with `root` set — zero errors;
  a tampered step is rejected.

No SPEC file and no `specs/CONFORMANCE.json` row was touched by this pass.

## Verdict

VERDICT: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 0 INFO (R2 findings resolved)

R3 re-run: pending
