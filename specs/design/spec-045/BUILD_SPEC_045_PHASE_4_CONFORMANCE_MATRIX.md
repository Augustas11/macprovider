# BUILD_SPEC_045_PHASE_4_CONFORMANCE_MATRIX

This matrix records Phase 4 conformance evidence for SPEC-045 local consumer
endpoint mode. It is intentionally evidence-only: this slice does not expand
the endpoint surface and does not promote `specs/CONFORMANCE.json`.

## Automated Local/Fake-Gateway Evidence

| Area | Evidence |
| --- | --- |
| Local command and descriptor lifecycle | `ConsumeCommandTests.testRunCommandStartsThenStopsWithRedactedSetupOutput`, `testRunCommandPortCollisionUsesRedactedBindError`, `testDescriptorWriteIsUserPrivateAndStatusPayloadIsRedacted`, `testActiveDescriptorLockSerializesInstances`, `testReadLiveDescriptorReturnsNilWhenDescriptorIsMissing`, `testDescriptorWithLivePIDButReleasedLockIsIgnored` |
| Local auth and status redaction | `ConsumeCommandTests.testStatusHandlerRequiresAuthSetsNoStoreAndRedacts`, `testLocalTokenVerifierAcceptsOnlyOneAcceptedHeader`, `testCredentialSourceOrderPrefersExplicitThenEnvFileThenDefaultThenEnvironment`, `testCredentialFileRejectsGroupReadableFileAndSymlink`, `testCredentialFileRejectsExtendedACLAndRevalidatesDeletion` |
| Endpoint subset and parser boundaries | `ConsumeCommandTests.testPhase2RejectsUnsafeTargetsFramingAndBrowserOrigins`, `testPhase2NIOHTTPDecoderLimitsMatchLocalPolicy`, `testPhase2RawPipelineRejectsOversizedStartLineBeforeHTTPDecoder`, `testPhase2EnforcesLocalResourceCapsBeforeBuffering`, `testPhase2ChatValidatesBodyBeforeBudgetRequiredFailure`, `testPhase2ModelsReturnsOnlyLocalAllowlistEntries`, `testPhase2ModelsDefaultEmptyAllowlistReturnsEmptyList` |
| Browser-origin restrictions | `ConsumeCommandTests.testPhase2RejectsUnsafeTargetsFramingAndBrowserOrigins` covers `Origin: null`, comma origins, multiple origins, different-port loopback origins, and accepted bound-loopback origins |
| Upstream target safety | `ConsumeCommandTests.testUpstreamOriginValidationRejectsNonOrigins`, `testPhase3DResolverFailureStopsBeforeReservationAndForwarding`, `testPhase3DResolverSuccessAfterDisconnectReleasesCapacityWithoutReservation`, `testPhase3DUpstreamParserRejectsHeaderControlCharacters`, `testPhase3DUpstreamParserRejectsInformationalResponsesAndHugeChunks` |
| Header and response safety | `ConsumeCommandTests.testPhase4PinnedUpstreamGeneratedHeadersAreClosedAndSanitized`, `testPhase4FakeGatewayRedirectStatusIsPreservedWithoutLocationOrSecondDispatch`, `testPhase3DBudgetedTrustedPricingForwardsAndSettlesToUsageBeforeResponse`, `testPhase3FCompressedUpstreamResponseDecodesBeforeSettlementAndLocalSuccess`, `testPhase3FInvalidCompressedUpstreamResponseFailsBeforeLocalSuccessAndSettlesEstimate`, `testPhase3GCompressedStreamingResponseFailsBeforeLocalSuccessAndSettlesEstimate`, `testPhase3GStreamingRequestRequiresEventStreamUpstreamBeforeLocalSuccess`, `testPhase3GStreamingUpstreamErrorResponseIsPreservedAndSettlesEstimate` |
| Tool calling and structured output pass-through | `testPhase4FakeGatewayNonStreamingSDKPayloadPassesThroughAndSettlesUsage`, `testPhase4FakeGatewayStreamingSDKPayloadEmitsOpenAICompatibleSSE` |
| Budget, pricing, and ledger behavior | `ConsumeCommandTests.testPhase3BudgetFlagsParseAndRejectInvalidCombinations`, `testPhase3BStatusReportsTrustedPricingAvailabilityAndWarnings`, `testPhase3CPricedEstimateUsesGrossRatesAndRoundsUp`, `testPhase3CPricedEstimateCapRejectsBeforeLedgerAppend`, `testPhase3DBudgetedTrustedPricingForwardsAndSettlesToUsageBeforeResponse`, `testPhase3DNoBudgetExplicitLedgerRecordsAndSettlesForwardedRequest`, `testPhase3DEstimateExceededStopsLaterChargeableAdmission`, `testPhase3BudgetedUnpricedRequestIsHeldUntilRelease`, `testPhase3LedgerRejectsMalformedJSONAndUnsupportedTransitions`, `testPhase3LedgerRejectsRunIDAndAmountMutation` |
| Local errors and forwarded-upstream flag | `ConsumeCommandTests.testPhase3DBudgetExceededWinsOverMissingCredentialWithoutMutation`, `testPhase3DResolverFailureStopsBeforeReservationAndForwarding`, `testPhase3FInvalidCompressedUpstreamResponseWithLedgerWriteFailureKeepsForwardedProvenance`, `testPhase3FDispatchedUpstreamFailureWithLedgerWriteFailureKeepsForwardedProvenance`, `testPhase3GStreamingUpstreamErrorResponseIsPreservedAndSettlesEstimate`, `testPhase3GStreamingLedgerWriteFailureKeepsForwardedProvenance` |

## Phase 4 Harness Fixtures

`ConsumeFakeGatewayUpstreamClient` models the OpenAI-compatible fake gateway at
the `ConsumeUpstreamClient` chat-completions boundary:

- non-streaming `/v1/chat/completions` with OpenAI-shaped choices and usage;
- streaming `/v1/chat/completions` with OpenAI-compatible SSE blocks and
  `[DONE]`;
- unsafe upstream response headers that must be stripped before local delivery;
- rate-card and signature fixture constants as harness metadata only.

The fixture constants are not HTTP `/v1/rate-card` or `/v1/rate-card.sig`
endpoint implementations. Pricing trust for these local tests is injected
through existing trusted-rate-card test helpers.

The local `/v1/models` behavior remains local-only by design and is covered by
`testPhase2ModelsReturnsOnlyLocalAllowlistEntries` plus
`testPhase2ModelsDefaultEmptyAllowlistReturnsEmptyList`.

## Pending Signed Journey Evidence

Phase 4B adds the promotion primitives for this evidence class:

- `JOURNEY-LOCAL-CONSUMER-ENDPOINT` is mapped to `SPEC-045-R001..R008` in
  `specs/CONFORMANCE.json` while those rows remain pending;
- `scripts/build-local-consumer-endpoint-journey-result.py` validates one
  committed redacted evidence source before signing;
- `.github/workflows/promote-signed-local-consumer-endpoint-journey.yml`
  builds a short-lived signed promotion artifact from the protected
  `production-release` environment;
- `scripts/tests/test_local_consumer_endpoint_journey_result.py` and
  `scripts/test-signed-local-consumer-endpoint-journey-workflow.sh` pin the
  journey shape, workflow boundaries, and fake-gateway rejection.

Phase 4C adds the local redacted evidence capture primitive:

- `scripts/capture-local-consumer-endpoint-evidence.py` emits one closed
  `macprovider.local-consumer-endpoint-evidence.v1` source under
  `journeys/evidence/local-consumer-endpoint-*.redacted.json`;
- `scripts/tests/test_local_consumer_endpoint_evidence_capture.py` verifies the
  generated source is accepted by the Phase 4B builder once committed, and that
  missing review/support bindings, fake-gateway, wrong-path, wrong-requirement,
  secret-like metadata, non-UTF-8 text, symlink, and transcript-bearing
  captures fail closed;
- `scripts/build-local-consumer-endpoint-journey-result.py` now requires the
  committed redacted evidence source to include closed support-artifact hashes
  plus an explicit review block before it can build the unsigned signer payload.

The following Phase 4 promotion evidence is not produced by the fake-gateway
harness or by the Phase 4B/4C signer and capture primitives and remains
pending:

- staging or production gateway journey using an OpenAI SDK configured with the
  local endpoint base URL and generated local token as `api_key`;
- permitted chat completion through the real gateway;
- over-budget denial through the real gateway;
- restart with an unreconciled held reservation and recovery release;
- signed, redacted logs/status proving no upstream credential, local token,
  prompt, or completion leakage.

Until those artifacts are committed and reconciled, `specs/CONFORMANCE.json`
must remain pending for SPEC-045.
