# Build 1 normative contracts implementation

Status: contract amendments complete; runtime completion and full combined-diff
review are separate gates. Recorded 2026-09-10.

Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
Prerequisite HEAD: `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e` (explicit unmerged
PR #1468 dependency). Plan/test authority: approved revision 4 and
`reviews/plan-r4-astra.md` (zero Critical/High/Medium/Low findings).

## Sequence and ownership

The contracts lane read AGENTS.md, CLAUDE.md, plan-r4.md and test-spec-r4.md before
editing. It communicated exact capabilities, command grammar, projection opt-in
and immutable evidence names to the lead for runtime-lane coordination. SPEC-001
and SPEC-044 amendments were made available before their dependent runtime
implementation; SPEC-047 authority/provenance and signed-retry amendments were
then made available before the dependent coordinator implementation. The lead
approved explicit projection protocol negotiation and separate result retrieval.
The independent durable-discovery adapter work did not change admission trust.
This records the contractual ordering; it does not claim a timestamp audit of
every concurrent runtime edit.

This lane changed only the following six contract/index files and made no
runtime changes or commits:

| File | Result |
|---|---|
| `specs/SPEC-001-phase3-binary.md` | Version 1.9.9; command taxonomy, exact transaction grammar, separate recommendation-result retrieval and bounded signed admission retry. |
| `specs/SPEC-044-malibu-model-catalog-economics.md` | Version 0.1.2; explicit non-economic preparation and confirmed local activation exception; measured prepared-only recommendation; transaction, cancellation, cleanup, recovery and reconciliation rules. |
| `specs/SPEC-047-network-model-admission.md` | Version 0.1.4; coordinator-owned promotion predicates, exact pending-offer retry, all-or-none immutable artifact provenance and legacy snapshot preservation. |
| `specs/design/BUILD_SPEC_953_MALIBU_MODEL_SWITCHING.md` | Narrow bootstrap producer/adoption clarification preserving existing signed authority, runtime commit, journal and rollback requirements. |
| `specs/CONFORMANCE.json` | Only SPEC-001, SPEC-044 and SPEC-047 version values changed. |
| `specs/README.md` | Generated index refreshed using the repository generator. |

## Decisions consumed by implementation lanes

- `model_catalog_transactions_v1` covers preparation, status/cancel/result and
  owned-staging cleanup. `model_catalog_local_activation_v1` additionally
  requires those transactions and existing
  `model_recommendation_apply_switch_v1` support.
- `models catalog-economics --local-activation --json` explicitly opts into
  `source.projection_protocol_version: "2"`. The default remains `"1"` with
  conservative legacy gating. The closed `model_catalog_economics.v1` shape,
  action kinds and transaction-event schema remain unchanged.
- Commands are `models prepare TARGET --transaction-id UUID --confirm --json`,
  `models recommend-prepared TARGET --transaction-id UUID --confirm --json`,
  `models transaction status|cancel|result UUID --model TARGET --json`, and
  `models cleanup-staging UUID --model TARGET --confirm --json`.
  TARGET is the exact authenticated primary action model identifier, never a
  caller-provided path or trust override.
- Preparation and evaluation stream existing
  `model_catalog_transaction_event.v1` events. Result retrieval returns the
  complete `autotune_recommend.v1` only for a succeeded matching evaluation;
  recommendation documents never mix into the closed event stream. The app
  passes that document into existing adoption through stdin.
- Cleanup addresses original transaction-owned staging, uses kind
  `cleanup_staging`, and preserves the original transaction outcome. Clients
  compare UUID and kind so cleanup success cannot imply preparation success.
- Bootstrap preparation needs fresh authenticated primary candidate/artifact
  identity. Measured recommendation/adoption retain their existing signed-feed
  freshness, configuration and fit safeguards. Missing economics authority does
  not authorize a synthetic recommendation or block owned-staging cleanup.
  Bootstrap rows suppress numeric rates, payout/share and all demand fields;
  local readiness or activation never grants paid admission.
- `models admission retry TARGET --yes --json` uses
  `POST /v1/provider/model-admission/retry`, an existing closed signed offer
  envelope with fresh nonce/idempotency key and timestamp, the exact pending
  tuple, current admission key, and expected-current-event concurrency checks.
  CLI readback keeps `model_admission_status.v1`. Optional `runtime_source` is
  internal admission evidence, not an added closed status-envelope field.
- Immutable artifact evidence uses all six names:
  `artifact_feed_sha256`, `artifact_id`, `artifact_hash`,
  `artifact_hash_algorithm`, `artifact_feed_signer_key_id`, and
  `candidate_catalog_sha256`. Candidate-catalog digest stays separate from
  Tier2 `CatalogBodyDigest`. Partial or substituted evidence fails closed;
  absence preserves legacy snapshot interpretation but cannot qualify the new
  artifact-derived path. Settlement cannot reconstruct missing captured
  authority from today's feeds.

## Validation evidence

Commands ran from the worktree above. These results apply to the contract lane,
not to concurrent runtime implementation or physical qualification.

| Exact command | Result |
|---|---|
| `python3 scripts/gen_spec_index.py` | Exit 0; found 47 canonical specs and regenerated specs/README.md. |
| `python3 scripts/gen_spec_index.py --check` | Exit 0; 47 canonical specs, index up to date. |
| `python3 scripts/check_spec_governance.py --base-ref f5edeaebfb6c712a2cb6dced9020c8c78ed1053e` | Exit 0; `SPEC governance validation passed`. Repeated after the signed-retry amendment and final contract edits; final run passed. |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_byom_contract_lock` | Exit 0; 6 tests ran in 0.006 seconds, OK. |
| `git diff --check -- specs` | Exit 0; no whitespace errors. |

An additional read-only comparison verified that CONFORMANCE.json differs from
prerequisite HEAD only in the three declared spec version values. The exact
comparison command was:

```bash
python3 - <<'PY'
import json,subprocess
from pathlib import Path
before=json.loads(subprocess.check_output(['git','show','HEAD:specs/CONFORMANCE.json'],text=True))
after=json.loads(Path('specs/CONFORMANCE.json').read_text())
expected={'SPEC-001':'1.9.9','SPEC-044':'0.1.2','SPEC-047':'0.1.4'}
for row in before['specs']:
 if row['spec_id'] in expected: row['version']=expected[row['spec_id']]
assert before==after,'Unexpected conformance mutation'
print('CONFORMANCE: only three spec versions changed; all states and evidence preserved')
PY
```

Result: exit 0, `CONFORMANCE: only three spec versions changed; all states and
evidence preserved`.

No conformance, lifecycle, implementation-status or production-status promotion
was made. No signed journey, physical model execution, production authority or
settlement evidence was invented. Physical Build 1 acceptance and the required
full cumulative code/security/architecture audits remain separate obligations.
