#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

run_swift_test() {
  local specifier="$1"
  run swift test --package-path "$ROOT/phase3-binary" --filter "^${specifier}$"
}

run_go_test() {
  local dir="$1"
  local pkg="$2"
  local pattern="$3"
  run env -C "$ROOT/$dir" go test "$pkg" -run "$pattern" -count=1 -timeout 180s
}

# Provider-side issuance and streaming transport invariants.
run_swift_test "macprovider_cliTests.HTTPServerReceiptTests/testHTTPNonStreamingHandlerWritesV04SettlementReceipt"
run_swift_test "macprovider_cliTests.HTTPServerReceiptTests/testHTTPStreamingHandlerWritesV04SettlementReceiptTrailerWithWarmSwapDisabled"
run_swift_test "macprovider_cliTests.HTTPServerReceiptTests/testStreamingHeadersStayReceiptFreeAndByteStable"
run_swift_test "macprovider_cliTests.InferenceRelayTests/testRelayNonStreamingEndFrameCarriesV04SettlementReceipt"

# Coordinator route snapshot, output-prefix, verdict, and AC-43..AC-71 gate.
run_go_test phase4-coordinator ./internal/billing \
  '^(TestSPEC015V04AcceptanceCriteria|TestSettlementReceiptAuthorizationRejectsLaterOverlapBackfill)$'
run_go_test phase4-coordinator ./internal/buyer \
  '^(TestRouteSnapshotsPersistBeforeDispatchAndRetryAttempts|TestStreamingSettlementOutputPersistsOpenAICompatibleSSE)$'

# Buyer-facing gateway disclosures and header boundary checks.
run_go_test phase5-gateway ./internal/router \
  '^(TestModelsResponseIncludesTier1Disclosure|TestTier1DisclosureMatchesSpecSection16|TestReceiptHeaderForwardedAndSiblingMacProviderHeadersStripped|TestStreamingReceiptHeaderStripped)$'

# Independent verifier fixture contract, negative range fixtures, and v0.3 forward-compat behavior.
run_go_test phase7-verify ./internal/jcs \
  '^(TestV04SettlementFixturesMatchVerifierJCSContract|TestV04SignedTuplesCoverTerminalStateMatrix|TestV04TupleFixturesBindRouteOutputAndUsage|TestV04ReceiptTupleRangesDoNotOverlapWithinRequest|TestV04NegativeRangeScenariosFailExpectedChecks|TestV04NegativeReceiptFixturesFailExpectedChecks)$'
run_go_test phase7-verify ./internal/verify \
  '^(TestVerifySettlementReceiptV04Fixtures|TestV03VerifierReportsV04WireReceiptUnknownVersion|TestVerifySettlementReceiptV04NegativeFixturesQuarantine)$'

printf '\nSPEC-015 v0.4 Step 8 acceptance target passed.\n'
