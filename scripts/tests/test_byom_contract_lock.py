import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class BYOMContractLockTests(unittest.TestCase):
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
            "settlement_capable": '"Earning now"',
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
