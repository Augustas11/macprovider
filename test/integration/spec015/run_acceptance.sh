#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

run() {
  printf '\n== %s ==\n' "$1"
  shift
  (cd "$ROOT" && "$@")
}

if [ "$(uname -m)" != "arm64" ]; then
  echo "SPEC-015 AC-16 requires an arm64 Apple Silicon runner for p95 latency acceptance" >&2
  exit 1
fi

run "SPEC-015 AC-01 AC-02 AC-03 AC-04 AC-05 AC-06 AC-07 AC-08 AC-09 AC-10 AC-11 AC-12 AC-13 AC-14 AC-15 AC-16 AC-17 AC-18 AC-19 AC-20 AC-21 AC-22 AC-23 AC-24 AC-25 AC-26 AC-27 manifest report" bash -lc 'cd test/integration && go test -v -race -count=1 -timeout 5m ./spec015'
run "SPEC-015 AC-04 AC-05 AC-06 AC-07 receipt-enabled cross-service gateway path" bash -lc 'cd test/integration && go test -race -count=1 -timeout 5m . -run TestSpec015ReceiptEnabledCrossServiceHeaderVerifies'
run "SPEC-015 AC-09 Python/Node SDKs against real local gateway" bash -lc 'cd test/integration && SPEC015_SDK_COMPAT_GATEWAY=1 go test -race -count=1 -timeout 10m . -run TestSpec015SDKCompatAgainstGateway'
run "SPEC-015 AC-14 pre-v1.6 cross-service receipt omission" bash -lc 'cd test/integration && go test -race -count=1 -timeout 5m . -run TestHappyPathChatCompletion'
run "SPEC-015 AC-04 AC-08 AC-12 AC-13 gateway header policy" bash -lc 'cd phase5-gateway && go test ./internal/router -count=1 -run "TestReceiptHeaderForwardedAndSiblingMacProviderHeadersStripped|TestNullUsageErrorReceiptHeaderForwarded|TestStreamingReceiptHeaderStripped|TestGatewayAuthFailureDoesNotExposeReceiptHeader|TestQuotaExhaustedDoesNotExposeReceiptHeader|TestKillSwitchRejectDoesNotExposeReceiptHeader"'
run "SPEC-015 AC-02 AC-03 AC-10 AC-11 AC-17 coordinator receipt key lifecycle" bash -lc 'cd phase4-coordinator && go test ./internal/ws -count=1 -run "TestProviderAuthV2InitialReceiptPublicKeyPublishesAfterStateUpdate|TestPoolzReceiptPubkeyNullForPreV16Provider|TestPoolzReceiptPubkeyPrevShape|TestProviderAuthV2ReceiptRotationMovesPriorPubkeyToPrevious|TestProviderAuthV2ReceiptRotationPurgesPreviousAfterGraceWindow|TestProviderAuthV2ReceiptKeyOmissionClearsLiveReceiptTrustState"'
run "SPEC-015 AC-01 AC-04 AC-05 AC-06 AC-07 AC-08 AC-10 AC-12 AC-15 AC-16 AC-17 Swift provider receipts" bash -lc 'cd phase3-binary && swift test --parallel --filter "ReceiptKeyStoreTests|HTTPServerReceiptTests|ReceiptBuilderTests|PromptCanonicalizerTests|OutputCanonicalizerTests|RotateKeyCommandTests|CoordinatorClientTests|ReceiptPerfTests"'
run "SPEC-015 AC-15 nginx receipt header deployment buffers" make test-dist
