import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class BYOMContractLockTests(unittest.TestCase):
    def test_closed_admission_inventory_and_local_only_copy_are_truthful(self):
        spec001 = read_text("specs/SPEC-001-phase3-binary.md")
        spec046 = read_text("specs/SPEC-046-provider-byom-discovery.md")
        handoff = read_text("audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md")

        exact_enum = (
            "`local_only`, `not_offered`, `offerable`, `offer_submitted`, "
            "`offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, "
            "`network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, "
            "`withdrawn`, and `revoked`"
        )
        self.assertIn(exact_enum, spec046)
        self.assertIn("the 12 machine admission states remain", spec001)
        self.assertIn("All 12 machine `admission_state` values", handoff)
        self.assertNotIn("13 machine admission states", spec001)
        self.assertNotIn("All 13 machine `admission_state` values", handoff)

        self.assertIn(
            "The `local_only` admission state is not readiness evidence and MUST NOT by itself "
            "be rendered as prepared, installed, ready, reachable, or usable.",
            " ".join(spec001.split()),
        )
        self.assertIn(
            "| `local_only` | local_default | Local only | Retained as local inventory only; "
            "this admission state does not claim the model is prepared, installed, ready, "
            "reachable, or usable. | local_inventory_only |",
            " ".join(handoff.split()),
        )
        exact_local_only = (
            "Retained as local inventory only; this admission state does not claim the model "
            "is prepared, installed, ready, reachable, or usable."
        )
        for owner_text in (spec001, spec046, handoff):
            with self.subTest(owner="local_only"):
                self.assertIn(exact_local_only, " ".join(owner_text.split()))
        self.assertNotIn("Installed and usable on this Mac", handoff)

        state_table = handoff.split("## State label + meaning copy", 1)[1].split(
            "## Non-earning disclosure lines", 1
        )[0]
        rows = [line for line in state_table.splitlines() if line.startswith("| `")]
        self.assertEqual(len(rows), 13)
        self.assertEqual(
            len({row.split("|")[1].strip() for row in rows}),
            12,
        )
        for blocker in (
            "`needs_weights`",
            "`needs_runtime`",
            "`requires_preparation`",
            "`unreachable`",
            "fit failure",
            "adapter rejection",
            "policy block",
        ):
            with self.subTest(blocker=blocker):
                self.assertIn(blocker, spec046)

    def test_not_offered_copy_is_exact_and_source_aware(self):
        spec001 = read_text("specs/SPEC-001-phase3-binary.md")
        spec044 = read_text("specs/SPEC-044-malibu-model-catalog-economics.md")
        spec046 = read_text("specs/SPEC-046-provider-byom-discovery.md")
        spec047 = read_text("specs/SPEC-047-network-model-admission.md")
        handoff = read_text(
            "audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md"
        )
        local_default = "Coordinator offer state is unavailable or has not been queried."
        coordinator = "Coordinator reports no active network offer for this model."

        for owner_text in (spec001, spec044, spec046, handoff):
            with self.subTest(source="local_default"):
                self.assertIn(local_default, " ".join(owner_text.split()))
        for owner_text in (spec001, spec044, spec046, spec047, handoff):
            with self.subTest(source="coordinator"):
                self.assertIn(coordinator, " ".join(owner_text.split()))
        self.assertNotIn("Discovered but never offered to the network.", handoff)
        self.assertIn(
            "MUST NOT assert that an offer never existed",
            " ".join(spec046.split()),
        )
        self.assertIn("reject any local-default offer-history assertion", spec044)

    def test_catalog_only_sentinel_is_exact_and_fault_tested(self):
        spec044 = read_text("specs/SPEC-044-malibu-model-catalog-economics.md")
        contract = " ".join(spec044.split())

        for required in (
            '`runtime_state: "catalog"`',
            'null `action_model_id`',
            '`economics_state` to `unavailable`',
            '`rate_source` to `none`',
            '`source: "local_default"`',
            '`state: "not_offered"`',
            'null `coordinator_event_id`',
            'null `state_observed_at`',
            '`catalog_economics_permitted: false`',
            '`settlement_capable: false`',
            'all demand signals to null',
            'Apply one-fault negatives for',
            'every other known or unknown economics state, rate source, admission source or',
            'either authorization boolean set',
            'any non-null money/demand field',
            'non-catalog runtime state, non-null `action_model_id`',
        ):
            with self.subTest(required=required):
                self.assertIn(required, contract)

        self.assertIn(
            "exact catalog-only unavailable sentinel in the `Blocked` section",
            contract,
        )
        self.assertIn(
            "MUST NOT place it in `Network catalog`, `Current`, `Ready`, or `Needs preparation`",
            contract,
        )
        self.assertIn("exact placement in `Blocked`", contract)
        self.assertIn(
            "Reject placement in `Network catalog`, `Current`, `Ready`, or `Needs preparation` "
            "as distinct one-fault section changes",
            contract,
        )

    def test_r005_is_the_single_complete_ranking_oracle(self):
        spec044 = read_text("specs/SPEC-044-malibu-model-catalog-economics.md")
        self.assertEqual(spec044.count("The authoritative total row order"), 1)
        ranking = spec044.split("The authoritative total row order", 1)[1].split(
            "**SPEC-044-R006", 1
        )[0]
        ranking = " ".join(ranking.split())
        ordered = (
            "the R008 section rank",
            "`provider_completion_payout_usd_per_million_tokens`, descending",
            "`demand_rank`, ascending",
            "`supply_deficit_score`, descending",
            "`demand_weight`, descending",
            "`ready_provider_count`, ascending",
            "the unique canonical row identity, ascending",
        )
        positions = [ranking.index(fragment) for fragment in ordered]
        self.assertEqual(positions, sorted(positions))
        for required in (
            "sole row-ordering authority",
            "unsigned UTF-8 bytes",
            "tagged wire tuple (`candidate`, `candidate_id`)",
            "otherwise (`catalog`, `model_key`)",
            "MUST contain no duplicate canonical row identity",
            "Display names and locale-aware comparison APIs MUST NOT participate in this order",
        ):
            with self.subTest(required=required):
                self.assertIn(required, ranking)

    def test_published_cleanup_action_has_canonical_exact_target_binding(self):
        spec044 = read_text("specs/SPEC-044-malibu-model-catalog-economics.md")
        contract = " ".join(spec044.split())
        for required in (
            "`row.cleanup_published`, if retained, MUST be byte-for-byte identical to",
            "`cleanup_targets[i].cleanup`",
            "UTF-8 RFC 8785 JSON Canonicalization Scheme (JCS) bytes",
            "reject duplicate or unknown action-object member names",
            "`row.cleanup_published.artifact_identity_digest`",
            "`cleanup_targets[i].cleanup.artifact_identity_digest`",
            "`cleanup_targets[i].estimated_bytes`",
            "Distinct one-fault fixtures MUST independently change",
            "the enclosing target `artifact_identity_digest`",
            "the enclosing target `estimated_bytes`",
            "`row.cleanup_published.artifact_identity_digest`",
            "`row.cleanup_published.estimated_bytes`",
            "`cleanup_targets[i].cleanup.estimated_bytes`",
            "transaction kind in each nested action copy",
            "transaction id in each nested action copy",
            "every other action field in each nested action copy, one field at a time",
            "otherwise valid action, unchanged, to another target",
            "before provider confirmation, reservation, rename, or deletion",
            "outside-root, protected-object, and legacy sentinels unchanged",
        ):
            with self.subTest(required=required):
                self.assertIn(required, contract)

    def test_legacy_model_command_strings_remain_pinned(self):
        spec001 = read_text("specs/SPEC-001-phase3-binary.md")
        build_spec = read_text("specs/design/BUILD_SPEC_953_MALIBU_MODEL_SWITCHING.md")
        manifest = json.loads(read_text("phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json"))

        for token in (
            "models_list.v1",
            "models_browse.v1",
            "model_catalog_error.v1",
            "model_catalog_json_v1",
            "models list.v1",
            "models browse.v1",
            # Live runtime-mutation commands the oracle must also protect from
            # silent BYOM redefinition (SPEC-001 v1.9.4 / BUILD_SPEC_953).
            "models switch.v1",
            "models adopt-recommendation.v1",
            "model_switch_event.v1",
            "model_adoption_event.v1",
        ):
            with self.subTest(token=token):
                self.assertIn(token, spec001)

        for schema in ("models_list.v1", "models_browse.v1", "model_catalog_error.v1", "model_catalog_json_v1"):
            with self.subTest(schema=schema):
                self.assertIn(schema, build_spec)

        catalog_tier = manifest["tiers"]["model_catalog_json_v1"]
        self.assertEqual(
            catalog_tier["command_schemas"],
            ["models list.v1", "models browse.v1", "model_catalog_error.v1"],
        )
        self.assertIn("model_catalog_json_v1", catalog_tier["local_status_capabilities"])

        # The switch / adopt-recommendation command-schema tokens the §6.14a
        # oracle references MUST remain present in the Malibu capability manifest.
        self.assertIn("models switch.v1", manifest["tiers"]["model_ready_switch_v1"]["command_schemas"])
        adopt_schemas = manifest["tiers"]["model_recommendation_apply_switch_v1"]["command_schemas"]
        self.assertIn("models adopt-recommendation.v1", adopt_schemas)
        # The adoption-event command-schema token is live-advertised alongside
        # the command token; lock it so a manifest edit cannot silently drop it.
        self.assertIn("model_adoption_event.v1", adopt_schemas)

    def test_byom_command_taxonomy_uses_distinct_schema_owners(self):
        spec001 = read_text("specs/SPEC-001-phase3-binary.md")
        spec046 = read_text("specs/SPEC-046-provider-byom-discovery.md")
        spec047 = read_text("specs/SPEC-047-network-model-admission.md")

        expected_taxonomy = (
            "models list",
            "models switch",
            "models adopt-recommendation",
            "models browse",
            "models discover",
            "models evaluate",
            "models offer --dry-run",
            "models offer",
            "models admission status",
            "models admission withdraw",
        )
        for command in expected_taxonomy:
            with self.subTest(command=command):
                self.assertIn(command, spec001)

        self.assertIn('schema: "provider_byom_discovery.v1"', spec001)
        self.assertIn('schema: "model_admission_offer_dry_run.v1"', spec001)
        self.assertIn('schema: "model_admission_status.v1"', spec001)
        self.assertIn('schema: "model_admission_withdraw.v1"', spec001)
        self.assertIn("MUST NOT reuse", spec046)
        self.assertIn("model_admission_withdraw.v1", spec047)

    def test_earning_verdict_first_human_output_contract(self):
        spec001 = read_text("specs/SPEC-001-phase3-binary.md")

        self.assertIn("Earning-verdict-first human output", spec001)
        self.assertIn("provider_guidance.earning_path_class", spec001)

        # Lock the EXACT enum -> verdict mapping as contiguous substrings, so a
        # future edit that reassigns a verdict (e.g. settlement_capable ->
        # "Can't earn in this release") fails the lock even though every enum
        # value and verdict string still appears somewhere in the spec.
        expected_mapping = {
            "settlement_capable": '"Eligible to earn on qualifying settled requests"',
            "not_earning_yet_catalog_or_receipt_path_exists": '"Not earning yet — "',
            "no_earning_path_in_v0_1": '"Can\'t earn in this release"',
            "local_inventory_only": '"Local only — not offered to the network"',
        }
        for enum_value, verdict in expected_mapping.items():
            pairing = f"`{enum_value}` -> **{verdict}**"
            with self.subTest(mapping=pairing):
                self.assertIn(pairing, spec001)

    def test_offer_signing_and_catalog_binding_are_explicit(self):
        spec047 = read_text("specs/SPEC-047-network-model-admission.md")

        for required in (
            "CLI-owned Ed25519 admission identity",
            "coordinator-authoritative current `provider_admission_public_key`",
            "Pending or recovery keys qualify for mutating BYOM offers or withdrawals only after",
            "Previous keys are valid only for the rollback/readback compatibility role",
            "Bearer-token authentication may be required",
            "bearer token alone is never the offer-signing root",
            "Payout keys, wallet private keys",
            "trusted catalog identity/hash binding",
            "exact catalog body digest",
            "never an alternative to the exact catalog body digest",
            "Provider-asserted `catalog_model_key`",
            "served_model_ref",
        ):
            with self.subTest(required=required):
                self.assertIn(required, spec047)

    def test_discovery_redaction_provenance_contract(self):
        spec046 = read_text("specs/SPEC-046-provider-byom-discovery.md")
        for pairing in (
            "`capabilities.family` | `capability_family_redacted`",
            "`capabilities.quantization` | `capability_quantization_redacted`",
            "`capabilities.runtime_version` | `capability_runtime_version_redacted`",
            "Unsafe model reference | `model_reference_redacted`",
        ):
            with self.subTest(pairing=pairing):
                self.assertTrue(pairing in spec046, f"Missing redaction mapping: {pairing}")
        for required in (
            "Missing fields and explicit JSON nulls MUST NOT emit a redaction warning",
            "MUST remain null; a literal redaction sentinel MUST NOT replace it",
            "MUST NOT include the withheld value, its hash, its length, a record index, or a count",
            "Optional-label redaction warnings MUST NOT be admission blockers",
            "MUST NOT be substituted with `adapter_malformed_response`",
            "MUST NOT synthesize a candidate id, display name, or served model reference",
            "MUST deduplicate warning codes within each warning array",
            "MUST NOT add redaction fields to a SPEC-047 offer package",
            "MUST NOT treat the affected projection as actionable, whether or not they display the unknown codes",
            "Signed journey evidence remains pending",
            "current adapters do not collect runtime version labels",
        ):
            with self.subTest(required=required):
                self.assertTrue(required in spec046, f"Missing redaction contract: {required}")

    def test_withdrawal_request_is_current_key_signed_and_idempotent(self):
        spec047 = read_text("specs/SPEC-047-network-model-admission.md")

        for required in (
            'schema: "model_admission_withdraw_request.v1"',
            'schema: "model_admission_withdraw.v1"',
            "MUST NOT include client-provided `previous_admission_state`",
            "macprovider.model_admission.withdraw.v1",
            "bearer token alone is never the withdrawal-signing root",
            "MUST NOT sign withdrawals",
            "idempotency-key reuse whose canonical request digest differs",
            "Exact idempotent retries for the same provider, candidate, idempotency key, and canonical request digest",
            "coordinator MUST derive previous state, event id, acceptance timestamp, and resulting state atomically",
        ):
            with self.subTest(required=required):
                self.assertIn(required, spec047)


if __name__ == "__main__":
    unittest.main()
