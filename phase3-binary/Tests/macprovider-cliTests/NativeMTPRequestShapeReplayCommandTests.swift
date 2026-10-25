#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import CryptoKit
import XCTest
@testable import macprovider_cli

final class NativeMTPRequestShapeReplayCommandTests: XCTestCase {
    func testCaptureRejectsRawPromptAndRecoverableCacheKeys() throws {
        let rawPrompt = try writeCapture([
            shape("raw", extra: ["prompt": "buyer text"]),
        ])
        XCTAssertThrowsError(try NativeMTPRequestShapeReplayCapture.load(from: rawPrompt)) { error in
            XCTAssertTrue("\(error)".contains("raw_or_recoverable_field"), "\(error)")
        }

        let rawCache = try writeCapture([
            shape("cache", extra: ["cache_group": "recoverable"]),
        ])
        XCTAssertThrowsError(try NativeMTPRequestShapeReplayCapture.load(from: rawCache)) { error in
            XCTAssertTrue("\(error)".contains("raw_or_recoverable_field"), "\(error)")
        }
    }

    func testCacheShapeWithoutAnonymousGroupIsPendingNotPassable() throws {
        let url = try writeCapture([
            shape(
                "cache-miss",
                conversationKey: true,
                cacheOnly: true,
                lease: "miss"
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(plan.pendingReason, "cache_shape_missing_anonymous_group:cache-miss")
    }

    func testCacheMissWithAnonymousGroupRequiresActualLeaseObserverProof() throws {
        let url = try writeCapture([
            shape(
                "cache-miss-proof",
                conversationKey: true,
                cacheOnly: true,
                lease: "miss",
                cachedTokens: 0,
                extra: ["anonymous_cache_group_sha256": String(repeating: "a", count: 64)]
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        let row = plan.blocks[0].rows[0]
        XCTAssertFalse(row.requiresCacheWarmup)
        let projection = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: plan.blocks[0],
            admissions: [],
            requestsByID: [row.requestID: try NativeMTPRequestShapeReplayRunner.makeRequest(
                modelID: "test-model",
                requestID: row.requestID,
                prompt: "synthetic",
                maxTokens: row.requestedMaxCompletionTokens,
                temperature: row.temperature,
                topP: row.topP,
                stream: row.stream
            )],
            actualCachedPromptTokensByID: [row.requestID: 0],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row)]],
            maxContextTokens: row.promptTokens + row.maxCompletionTokens
        )
        XCTAssertEqual(projection.first?["reproduced"] as? Bool, true)
        XCTAssertEqual(projection.first?["actual_conversation_cache_attempted"] as? Bool, true)
        XCTAssertEqual(projection.first?["actual_conversation_cache_lease"] as? String, "miss")
    }

    func testCacheHitWithAnonymousGroupIsRunnableForWarmupProof() throws {
        let url = try writeCapture([
            shape(
                "cache-hit",
                conversationKey: true,
                cacheOnly: true,
                lease: "hit",
                cachedTokens: 128,
                extra: ["anonymous_cache_group_sha256": String(repeating: "a", count: 64)]
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        XCTAssertTrue(plan.blocks[0].rows[0].requiresCacheWarmup)
        XCTAssertEqual(plan.blocks[0].rows[0].expectedCachedPromptTokens, 128)
    }

    func testStickyCacheHitWithAnonymousGroupIsRunnableForWarmupProof() throws {
        let url = try writeCapture([
            shape(
                "sticky-hit",
                conversationKey: true,
                cacheOnly: false,
                lease: "hit",
                cachedTokens: 128,
                extra: ["anonymous_cache_group_sha256": String(repeating: "a", count: 64)]
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        let row = plan.blocks[0].rows[0]
        XCTAssertTrue(row.requiresCacheWarmup)
        XCTAssertFalse(row.conversationCacheOnly)
        XCTAssertEqual(row.expectedCachedPromptTokens, 128)
        let projection = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: plan.blocks[0],
            admissions: [],
            requestsByID: [row.requestID: try NativeMTPRequestShapeReplayRunner.makeRequest(
                modelID: "test-model",
                requestID: row.requestID,
                prompt: "synthetic",
                maxTokens: row.requestedMaxCompletionTokens,
                temperature: row.temperature,
                topP: row.topP,
                stream: row.stream
            ).withConversationKey("conv:sticky", cacheOnly: false)],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row)]],
            maxContextTokens: row.promptTokens + row.maxCompletionTokens
        )
        XCTAssertEqual(projection.first?["reproduced"] as? Bool, true)
        XCTAssertEqual(projection.first?["actual_conversation_key_sticky"] as? Bool, true)
        XCTAssertEqual(projection.first?["actual_conversation_cache_attempted"] as? Bool, true)
        XCTAssertEqual(projection.first?["actual_conversation_cache_lease"] as? String, "hit")
    }

    func testStickyCacheMissWithAnonymousGroupRequiresActualLeaseObserverProof() throws {
        let url = try writeCapture([
            shape(
                "sticky-miss-proof",
                conversationKey: true,
                cacheOnly: false,
                lease: "miss",
                cachedTokens: 0,
                extra: ["anonymous_cache_group_sha256": String(repeating: "a", count: 64)]
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        let row = plan.blocks[0].rows[0]
        XCTAssertFalse(row.requiresCacheWarmup)
        let projection = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: plan.blocks[0],
            admissions: [],
            requestsByID: [row.requestID: try NativeMTPRequestShapeReplayRunner.makeRequest(
                modelID: "test-model",
                requestID: row.requestID,
                prompt: "synthetic",
                maxTokens: row.requestedMaxCompletionTokens,
                temperature: row.temperature,
                topP: row.topP,
                stream: row.stream
            ).withConversationKey("conv:sticky", cacheOnly: false)],
            actualCachedPromptTokensByID: [row.requestID: 0],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row)]],
            maxContextTokens: row.promptTokens + row.maxCompletionTokens
        )
        XCTAssertEqual(projection.first?["reproduced"] as? Bool, true)
        XCTAssertEqual(projection.first?["actual_conversation_key_sticky"] as? Bool, true)
        XCTAssertEqual(projection.first?["actual_conversation_cache_attempted"] as? Bool, true)
        XCTAssertEqual(projection.first?["actual_conversation_cache_lease"] as? String, "miss")
    }

    func testRetainedCacheHandoffRequiresExactRuntimeObserverProof() throws {
        let url = try writeCapture([
            shape(
                "retained-hit",
                conversationKey: true,
                cacheOnly: true,
                lease: "hit",
                cachedTokens: 128,
                extra: [
                    "anonymous_cache_group_sha256": String(repeating: "a", count: 64),
                    "conversation_cache_retained_handoff": true,
                ]
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        let row = plan.blocks[0].rows[0]
        let request = try NativeMTPRequestShapeReplayRunner.makeRequest(
            modelID: "test-model",
            requestID: row.requestID,
            prompt: "synthetic",
            maxTokens: row.requestedMaxCompletionTokens,
            temperature: row.temperature,
            topP: row.topP,
            stream: row.stream
        )
        let pendingProjection = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: plan.blocks[0],
            admissions: [],
            requestsByID: [row.requestID: request],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row, retainedHandoff: false)]],
            maxContextTokens: row.promptTokens + row.maxCompletionTokens
        )
        XCTAssertEqual(pendingProjection.first?["reproduced"] as? Bool, false)
        XCTAssertTrue((pendingProjection.first?["pending_reason"] as? String)?.contains("conversation_cache_observation_mismatch") == true)

        let reproducedProjection = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: plan.blocks[0],
            admissions: [],
            requestsByID: [row.requestID: request],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row)]],
            maxContextTokens: row.promptTokens + row.maxCompletionTokens
        )
        XCTAssertEqual(reproducedProjection.first?["reproduced"] as? Bool, true)
        XCTAssertEqual(reproducedProjection.first?["actual_conversation_cache_retained_handoff"] as? Bool, true)
    }

    func testAnonymousCacheGroupNullLoadsAsNil() throws {
        let url = try writeCapture([
            shape("ordinary-null", extra: ["anonymous_cache_group_sha256": NSNull()]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        XCTAssertNil(capture.shapes.first?.anonymousCacheGroupSHA256)
    }

    func testNonStreamingRowsRemainRunnableWhenTargetMatchesBudget() throws {
        let url = try writeCapture([
            shape("nonstream", extra: ["stream": false]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        XCTAssertFalse(plan.blocks[0].rows[0].stream)
    }

    func testAdmissionProjectionReproductionUsesExplicitOptionalPendingState() throws {
        let url = try writeCapture([
            shape("projection"),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 1, seed: 48015)
        let block = plan.blocks[0]
        let row = try XCTUnwrap(block.runnableRows.first)
        let request = try NativeMTPRequestShapeReplayRunner.makeRequest(
            modelID: "test-model",
            requestID: row.requestID,
            prompt: "synthetic",
            maxTokens: row.requestedMaxCompletionTokens,
            temperature: row.temperature,
            topP: row.topP,
            stream: row.stream
        )
        let matchingRequest = try NativeMTPRequestShapeReplayRunner.applySyntheticStandIn(for: row, to: request)
        let maxContextTokens = row.promptTokens + row.maxCompletionTokens

        let reproduced = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: block,
            admissions: [],
            requestsByID: [row.requestID: matchingRequest],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row)]],
            maxContextTokens: maxContextTokens
        )
        XCTAssertEqual(reproduced.first?["reproduced"] as? Bool, true)
        XCTAssertTrue(reproduced.first?["pending_reason"] is NSNull)

        let changedRequest = try NativeMTPRequestShapeReplayRunner.makeRequest(
            modelID: "test-model",
            requestID: row.requestID,
            prompt: "synthetic",
            maxTokens: row.requestedMaxCompletionTokens,
            temperature: row.temperature,
            topP: row.topP,
            stream: !row.stream
        )
        let changed = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: block,
            admissions: [],
            requestsByID: [row.requestID: changedRequest],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row)]],
            maxContextTokens: maxContextTokens
        )
        XCTAssertEqual(changed.first?["reproduced"] as? Bool, false)
        XCTAssertEqual(changed.first?["pending_reason"] as? String, "stream_flag_mismatch:\(row.requestID)")

        let cacheMismatch = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: block,
            admissions: [],
            requestsByID: [row.requestID: matchingRequest],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens + 1],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row)]],
            maxContextTokens: maxContextTokens
        )
        XCTAssertEqual(cacheMismatch.first?["reproduced"] as? Bool, false)
        XCTAssertTrue((cacheMismatch.first?["pending_reason"] as? String)?.contains("conversation_cache_state_mismatch:") == true)

        let missingCacheObservation = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: block,
            admissions: [],
            requestsByID: [row.requestID: matchingRequest],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
            cacheEventsByRequestID: [:],
            maxContextTokens: maxContextTokens
        )
        XCTAssertEqual(missingCacheObservation.first?["reproduced"] as? Bool, false)
        XCTAssertTrue((missingCacheObservation.first?["pending_reason"] as? String)?.contains("conversation_cache_observation_missing") == true)

        let duplicateCacheObservation = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: block,
            admissions: [],
            requestsByID: [row.requestID: matchingRequest],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row), cacheEvent(row: row)]],
            maxContextTokens: maxContextTokens
        )
        XCTAssertEqual(duplicateCacheObservation.first?["reproduced"] as? Bool, false)
        XCTAssertTrue((duplicateCacheObservation.first?["pending_reason"] as? String)?.contains("conversation_cache_observation_duplicate") == true)

        let missing = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: block,
            admissions: [],
            requestsByID: [:],
            actualCachedPromptTokensByID: [:],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row)]],
            maxContextTokens: maxContextTokens
        )
        XCTAssertEqual(missing.first?["reproduced"] as? Bool, false)
        XCTAssertEqual(missing.first?["pending_reason"] as? String, "request_reproduction_missing_parsed_request:\(row.requestID)")
    }

    func testAttachedToSerialCacheObserverChainUsesTerminalSerialEvent() throws {
        let url = try writeCapture([
            shape(
                "cache-chain",
                conversationKey: true,
                cacheOnly: true,
                lease: "hit",
                cachedTokens: 128,
                extra: ["anonymous_cache_group_sha256": String(repeating: "b", count: 64)]
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 1, seed: 48015)
        let block = plan.blocks[0]
        let row = try XCTUnwrap(block.runnableRows.first)
        let request = try NativeMTPRequestShapeReplayRunner.makeRequest(
            modelID: "test-model",
            requestID: row.requestID,
            prompt: "synthetic",
            maxTokens: row.requestedMaxCompletionTokens,
            temperature: row.temperature,
            topP: row.topP,
            stream: row.stream
        ).withConversationKey("conv:cache", cacheOnly: true)
        let projection = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: block,
            admissions: [],
            requestsByID: [row.requestID: request],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
            cacheEventsByRequestID: [row.requestID: [
                cacheEvent(row: row, state: "miss", cachedTokens: 0, surface: "attached_complete", monotonicNanoseconds: 10),
                cacheEvent(row: row, state: "hit", cachedTokens: row.expectedCachedPromptTokens, surface: "serial_complete", monotonicNanoseconds: 20),
            ]],
            maxContextTokens: row.promptTokens + row.maxCompletionTokens
        )
        XCTAssertEqual(projection.first?["reproduced"] as? Bool, true)
        XCTAssertEqual(projection.first?["actual_conversation_cache_lease"] as? String, "hit")
    }

    func testInvalidCacheObserverChainsStayPending() throws {
        let url = try writeCapture([
            shape(
                "cache-invalid-chain",
                conversationKey: true,
                cacheOnly: true,
                lease: "hit",
                cachedTokens: 128,
                extra: ["anonymous_cache_group_sha256": String(repeating: "b", count: 64)]
            ),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 1, seed: 48015)
        let block = plan.blocks[0]
        let row = try XCTUnwrap(block.runnableRows.first)
        let request = try NativeMTPRequestShapeReplayRunner.makeRequest(
            modelID: "test-model",
            requestID: row.requestID,
            prompt: "synthetic",
            maxTokens: row.requestedMaxCompletionTokens,
            temperature: row.temperature,
            topP: row.topP,
            stream: row.stream
        ).withConversationKey("conv:cache", cacheOnly: true)
        func projection(_ events: [NativeMTPLabConversationCacheObserver.Event]) -> [String: Any] {
            NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
                path: .ordinary,
                block: block,
                admissions: [],
                requestsByID: [row.requestID: request],
                actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
                cacheEventsByRequestID: [row.requestID: events],
                maxContextTokens: row.promptTokens + row.maxCompletionTokens
            )[0]
        }

        let reversed = projection([
            cacheEvent(row: row, surface: "serial_complete", monotonicNanoseconds: 10),
            cacheEvent(row: row, surface: "attached_complete", monotonicNanoseconds: 20),
        ])
        XCTAssertEqual(reversed["reproduced"] as? Bool, false)
        XCTAssertTrue((reversed["pending_reason"] as? String)?.contains("conversation_cache_observation_invalid_chain") == true)

        let mixed = projection([
            cacheEvent(row: row, surface: "attached_complete", monotonicNanoseconds: 10),
            cacheEvent(row: row, surface: "serial_stream", monotonicNanoseconds: 20),
        ])
        XCTAssertEqual(mixed["reproduced"] as? Bool, false)
        XCTAssertTrue((mixed["pending_reason"] as? String)?.contains("conversation_cache_observation_invalid_chain") == true)

        let ambiguous = projection([
            cacheEvent(row: row, surface: "attached_complete", monotonicNanoseconds: 10),
            cacheEvent(row: row, surface: "serial_complete", monotonicNanoseconds: 20),
            cacheEvent(row: row, surface: "serial_complete", monotonicNanoseconds: 30),
        ])
        XCTAssertEqual(ambiguous["reproduced"] as? Bool, false)
        XCTAssertTrue((ambiguous["pending_reason"] as? String)?.contains("conversation_cache_observation_duplicate") == true)
    }


    func testSyntheticStandInPreservesRequestMaxTokensForWarmupCaps() throws {
        let url = try writeCapture([
            shape("warmup-cap", extra: [
                "requested_max_completion_tokens": 512,
                "effective_max_output_tokens": 512,
            ]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 1, seed: 48015)
        let row = try XCTUnwrap(plan.blocks[0].runnableRows.first)
        XCTAssertEqual(row.requestedMaxCompletionTokens, 512)
        let warmupBase = try NativeMTPRequestShapeReplayRunner.makeRequest(
            modelID: "test-model",
            requestID: "warmup-\(row.requestID)",
            prompt: "synthetic",
            maxTokens: 7,
            temperature: row.temperature,
            topP: row.topP,
            stream: row.stream
        )
        let warmupRequest = try NativeMTPRequestShapeReplayRunner.applySyntheticStandIn(for: row, to: warmupBase)
        XCTAssertEqual(warmupRequest.maxTokens, 7)
    }

    func testCombinedSafeFeaturesAreAppliedBeforeReproductionComparison() throws {
        let url = try writeCapture([
            shape("combined-safe", extra: [
                "stop_sequences": 1,
                "stop_sequence_utf8_lengths": [3],
                "stop_sequence_utf8_length_buckets": ["1_4": 1],
                "requested_top_k": 40,
                "top_k_present": true,
                "logit_controls_requested": true,
                "logprobs_requested": true,
                "top_logprobs_requested": true,
                "requested_top_logprobs": 3,
            ]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 1, seed: 48015)
        let block = plan.blocks[0]
        let row = try XCTUnwrap(block.runnableRows.first)
        let baseRequest = try NativeMTPRequestShapeReplayRunner.makeRequest(
            modelID: "test-model",
            requestID: row.requestID,
            prompt: "synthetic",
            maxTokens: row.requestedMaxCompletionTokens,
            temperature: row.temperature,
            topP: row.topP,
            stream: row.stream
        )
        let replayRequest = try NativeMTPRequestShapeReplayRunner.applySyntheticStandIn(for: row, to: baseRequest)
        let projection = NativeMTPRequestShapeReplayRunner.admissionProjectionRows(
            path: .ordinary,
            block: block,
            admissions: [],
            requestsByID: [row.requestID: replayRequest],
            actualCachedPromptTokensByID: [row.requestID: row.expectedCachedPromptTokens],
            cacheEventsByRequestID: [row.requestID: [cacheEvent(row: row)]],
            maxContextTokens: row.promptTokens + row.maxCompletionTokens
        )
        XCTAssertEqual(row.expectedSelectorReason, "logit_controls")
        XCTAssertEqual(projection.first?["reproduced"] as? Bool, true)
        XCTAssertTrue(projection.first?["pending_reason"] is NSNull)
    }
    func testShorterTargetThanAdmissionBudgetRemainsRunnableWithDecodeCapHook() throws {
        let url = try writeCapture([
            shape("short-target", extra: ["completion_tokens": 64, "generated_completion_tokens": 64, "effective_max_output_tokens": 128]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        XCTAssertEqual(plan.blocks[0].rows[0].targetCompletionTokens, 64)
        XCTAssertEqual(plan.blocks[0].rows[0].maxCompletionTokens, 128)
    }

    func testMultiFeatureSelectorRowsRemainRunnableForActualAdmissionProof() throws {
        let url = try writeCapture([
            shape("multi", extra: ["sampling_requested": true, "unknown_top_level_keys_present": true, "requested_temperature": 0.7]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        XCTAssertEqual(plan.blocks[0].rows[0].expectedSelectorReason, "sampling")
    }

    func testSampledProjectionRequiresExplicitCapabilityAndPreservesSampler() throws {
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: writeCapture([
            shape("sampled-a", extra: ["sampling_requested": true, "requested_temperature": 1.0, "requested_top_p": 0.95]),
            shape("sampled-b", extra: ["sampling_requested": true, "requested_temperature": 0.7, "requested_top_p": 0.9]),
        ]))
        let legacy = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(legacy.blocks[0].rows[0].expectedSelectorReason, "sampling")
        let sampled = try NativeMTPRequestShapeReplayPlan.make(
            capture: capture, blocks: 10, seed: 48015,
            qualifiedSlots: 4, maxNativeActiveRows: 1, supportsSampling: true
        )
        XCTAssertTrue(sampled.sampleCoverageComplete)
        XCTAssertEqual(sampled.blocks[0].runnableWaves.map(\.count), [1, 1])
        let row = sampled.blocks[1].rows[0]
        XCTAssertEqual(row.expectedSelectorReason, "eligible")
        guard case .ordinaryBaseline = row.metricsClass else {
            return XCTFail("sampled eligible rows must use ordinary-baseline metrics")
        }
        XCTAssertEqual(row.temperature, 1.0)
        XCTAssertEqual(row.topP, 0.95)
        XCTAssertEqual(row.exportedShape["requested_temperature"] as? Double, 1.0)
        XCTAssertEqual(row.exportedShape["requested_top_p"] as? Double, 0.95)
    }

    func testSampledProjectionRetainsOtherFeatureGates() throws {
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: writeCapture([
            shape("unknown", extra: ["sampling_requested": true, "requested_temperature": 1.0, "unknown_top_level_keys_present": true]),
            shape("unsupported-sampler", extra: ["sampling_requested": true, "requested_top_p": 1.1]),
            shape("reasoning", extra: ["sampling_requested": true, "requested_temperature": 1.0, "reasoning_or_template_model": true]),
            shape("tools", extra: ["sampling_requested": true, "requested_temperature": 1.0, "tools_present": true]),
        ]))
        let plan = try NativeMTPRequestShapeReplayPlan.make(
            capture: capture, blocks: 10, seed: 48015, supportsSampling: true
        )
        XCTAssertEqual(plan.blocks[0].rows.map(\.expectedSelectorReason), [
            "unknown_request_field", "sampling", "reasoning_or_template", "tools",
        ])
        XCTAssertNotNil(plan.blocks[0].rows[2].pendingReason)
    }

    func testCaptureRejectsInconsistentSamplerFlag() throws {
        for extra: [String: Any] in [
            ["sampling_requested": false, "requested_temperature": 1.0],
            ["sampling_requested": true],
        ] {
            XCTAssertThrowsError(try NativeMTPRequestShapeReplayCapture.load(from: writeCapture([
                shape("inconsistent", extra: extra),
            ]))) { error in
                XCTAssertTrue("\(error)".contains("sampling_requested_inconsistent"))
            }
        }
    }

    func testOneTokenOrdinaryRowsStayPendingForITLMetric() throws {
        let url = try writeCapture([
            shape("one-token", extra: ["completion_tokens": 1, "generated_completion_tokens": 1]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(plan.pendingReason, "ordinary_itl_requires_target_completion_at_least_2:one-token")
    }

    func testPlanKeepsFullSampleRowsAndCounterbalancesTenBlocks() throws {
        let url = try writeCapture([
            shape("eligible-a"),
            shape("eligible-b"),
            shape("unknown", extra: ["unknown_top_level_keys_present": true]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        XCTAssertEqual(plan.blocks.count, 10)
        XCTAssertTrue(plan.blocks.allSatisfy { $0.rows.count == 3 })
        XCTAssertEqual(plan.blocks.filter(\.nativeFirst).count, 5)
        XCTAssertEqual(plan.blocks[3].rows[0].requestID, "mixed-b3-r0-eligible-a")
        XCTAssertEqual(Set(plan.blocks[0].rows.map(\.requestID)).count, 3)
    }

    func testCaptureIdentityMismatchReportsShapeWithoutRewritingCapturedHash() throws {
        let url = try writeCapture([
            shape("identity"),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let mismatches = capture.identityMismatches(targetSHA256: String(repeating: "a", count: 64))
        XCTAssertEqual(mismatches.count, 1)
        XCTAssertEqual(mismatches[0]["shape_id"] as? String, "identity")
        XCTAssertEqual(mismatches[0]["served_model_hash_sha256"] as? String, String(repeating: "d", count: 64))
    }

    func testPlanPreservesMoreThanEightSampleRowsForOrderedWaves() throws {
        let url = try writeCapture((0..<11).map { shape("eligible-\($0)") })
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        XCTAssertTrue(plan.sampleCoverageComplete)
        XCTAssertEqual(plan.blocks[0].rows.count, 11)
        XCTAssertEqual(plan.runnableRowsPerBlock, 11)
        XCTAssertEqual(plan.runnableWavesPerBlock, 11)
        XCTAssertTrue(plan.blocks[0].runnableWaves.allSatisfy { $0.count == 1 })
        XCTAssertEqual(plan.sampleCoverageExport["omitted_sample_shape_count"] as? Int, 0)
        XCTAssertEqual(plan.blocks[0].rows.last?.requestID, "mixed-b0-r10-eligible-10")
    }

    func testRunnableWavesLimitEligibleNativeCandidatesToOnePerWave() throws {
        let url = try writeCapture([
            shape("eligible-a"),
            shape("eligible-b"),
            shape("ineligible", extra: ["unknown_top_level_keys_present": true]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(plan.blocks[0].runnableWaves.count, 2)
        XCTAssertEqual(plan.blocks[0].runnableWaves[0].map(\.shapeID), ["eligible-a"])
        XCTAssertEqual(plan.blocks[0].runnableWaves[1].map(\.shapeID), ["eligible-b", "ineligible"])
    }

    func testRunnableWavesUseQualifiedTupleSlotsAndNativeBound() throws {
        let url = try writeCapture((0..<5).map {
            shape("ordinary-\($0)", extra: ["unknown_top_level_keys_present": true])
        })
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(
            capture: capture, blocks: 10, seed: 48015,
            qualifiedSlots: 4, maxNativeActiveRows: 1
        )
        XCTAssertTrue(plan.sampleCoverageComplete)
        XCTAssertEqual(plan.blocks[0].runnableWaves.map(\.count), [4, 1])
        XCTAssertEqual(plan.sampleCoverageExport["max_concurrent_requests"] as? Int, 4)
        XCTAssertEqual(plan.maxNativeRowCount, 1)
        let legacy = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(legacy.blocks[0].runnableWaves.map(\.count), [5])
        XCTAssertEqual(legacy.sampleCoverageExport["max_concurrent_requests"] as? Int, 8)
    }

    func testRunnableWavesRespectConfiguredNativeRowBound() throws {
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: writeCapture([
            shape("eligible-a"), shape("eligible-b"), shape("eligible-c"),
        ]))
        let plan = try NativeMTPRequestShapeReplayPlan.make(
            capture: capture, blocks: 10, seed: 48015,
            qualifiedSlots: 4, maxNativeActiveRows: 2
        )
        XCTAssertEqual(plan.blocks[0].runnableWaves.map(\.count), [2, 1])
    }

    func testPlanRejectsInvalidQualifiedTupleBounds() throws {
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: writeCapture([shape("eligible")]))
        for (slots, nativeRows) in [(1, 1), (9, 1), (4, 0), (4, 5)] {
            XCTAssertThrowsError(try NativeMTPRequestShapeReplayPlan.make(
                capture: capture, blocks: 10, seed: 48015,
                qualifiedSlots: slots, maxNativeActiveRows: nativeRows
            ))
        }
    }

    func testRunnableWavesSerializeRepeatedAnonymousCacheGroups() throws {
        let group = String(repeating: "d", count: 64)
        let url = try writeCapture([
            shape("cache-a", conversationKey: true, cacheOnly: true, lease: "hit", cachedTokens: 128, extra: [
                "anonymous_cache_group_sha256": group,
                "unknown_top_level_keys_present": true,
            ]),
            shape("ordinary"),
            shape("cache-b", conversationKey: true, cacheOnly: true, lease: "hit", cachedTokens: 128, extra: [
                "anonymous_cache_group_sha256": group,
                "unknown_top_level_keys_present": true,
            ]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(plan.blocks[0].runnableWaves.count, 2)
        XCTAssertEqual(plan.blocks[0].runnableWaves[0].map(\.shapeID), ["cache-a", "ordinary"])
        XCTAssertEqual(plan.blocks[0].runnableWaves[1].map(\.shapeID), ["cache-b"])
    }

    func testSanitizedExportDoesNotCarryRawOrRecoverableFields() throws {
        let url = try writeCapture([
            shape("safe", conversationKey: true, lease: "not_applicable", extra: [
                "anonymous_cache_group_sha256": String(repeating: "c", count: 64),
                "unknown_top_level_keys_present": true,
            ]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let exported = try XCTUnwrap(capture.shapes.first?.sanitizedExport)
        XCTAssertNil(exported["prompt"])
        XCTAssertNil(exported["messages"])
        XCTAssertNil(exported["conversation_key"])
        XCTAssertNil(exported["cache_group"])
        XCTAssertEqual(exported["anonymous_cache_group_sha256"] as? String, String(repeating: "c", count: 64))
        XCTAssertEqual(capture.shapes.first?.features["unknown_top_level_keys_present"] as? Bool, true)
    }

    func testNullableRequestedMaxCompletionStaysNilWhileEffectiveBudgetRemainsBound() throws {
        let url = try writeCapture([
            shape("nil-max", extra: ["requested_max_completion_tokens": NSNull(), "effective_max_output_tokens": 96]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.blocks[0].rows[0].requestedMaxCompletionTokens)
        XCTAssertEqual(plan.blocks[0].rows[0].maxCompletionTokens, 96)
        XCTAssertEqual(plan.maxContextTokens, 1536 + 96)
    }

    func testIncoherentNullableMaxCompletionContextsStayPending() throws {
        let url = try writeCapture([
            shape("nil-a", extra: ["requested_max_completion_tokens": NSNull(), "prompt_tokens": 1000, "effective_max_output_tokens": 64]),
            shape("nil-b", extra: ["requested_max_completion_tokens": NSNull(), "prompt_tokens": 1100, "effective_max_output_tokens": 64]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertTrue(plan.pendingSampleReasons.contains("nil_max_replay_requires_single_context_geometry:nil-a"))
        XCTAssertTrue(plan.pendingSampleReasons.contains("nil_max_replay_requires_single_context_geometry:nil-b"))
        XCTAssertEqual(plan.runnableRowsPerBlock, 0)
    }

    func testToolMessagesWithoutMatchingAssistantCallsStayPending() throws {
        let url = try writeCapture([
            shape("orphan-tool", extra: [
                "tools_present": true,
                "tool_count": 1,
                "tool_parameter_schema_geometries": [["byte_count": 80, "max_depth": 2, "object_count": 1, "array_count": 0, "property_count": 1]],
                "tool_turn_state_present": true,
                "tool_message_count": 2,
                "assistant_tool_call_count": 1,
            ]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(plan.pendingReason, "tool_turn_replay_requires_assistant_call_for_each_tool_message:orphan-tool")
    }

    func testCapturedNumericControlsArePreservedAndRunnableWhenExactValuesExist() throws {
        let url = try writeCapture([
            shape("numeric-controls", extra: [
                "requested_top_k": 40,
                "requested_min_p": 0.05,
                "requested_presence_penalty": 0.25,
                "requested_frequency_penalty": -0.25,
                "requested_repetition_penalty": 1.1,
                "top_k_present": true,
                "min_p_nonzero": true,
                "presence_penalty_nonzero": true,
                "frequency_penalty_nonzero": true,
                "repetition_penalty_nondefault": true,
                "logit_controls_requested": true,
            ]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        let row = plan.blocks[0].rows[0]
        XCTAssertEqual(row.expectedSelectorReason, "logit_controls")
        XCTAssertNotNil(row.syntheticStandIn)
        XCTAssertEqual((row.replayFeatures["requested_top_k"] as? NSNumber)?.intValue, 40)
        let exported = try XCTUnwrap(capture.shapes.first?.sanitizedExport)
        XCTAssertEqual((exported["requested_repetition_penalty"] as? NSNumber)?.doubleValue, 1.1)
    }

    func testSafeGeometryControlsAreRunnableAndLogitBiasStaysPending() throws {
        let url = try writeCapture([
            shape("stop", extra: ["stop_sequences": 1, "stop_sequence_utf8_lengths": [8], "stop_sequence_utf8_length_buckets": ["5_16": 1]]),
            shape("bias", extra: ["logit_bias_present": true, "logit_controls_requested": true]),
            shape("tool", extra: [
                "tools_present": true,
                "tool_count": 1,
                "tool_parameter_schema_geometries": [["byte_count": 80, "max_depth": 2, "object_count": 1, "array_count": 0, "property_count": 1]],
            ]),
            shape("schema", extra: [
                "structured_output_requested": true,
                "response_format_kind": "json_schema",
                "response_schema_geometry": ["byte_count": 48, "max_depth": 2, "object_count": 1, "array_count": 0, "property_count": 1],
            ]),
            shape("top-logprobs", extra: [
                "logprobs_requested": true,
                "top_logprobs_requested": true,
                "requested_top_logprobs": 3,
            ]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(plan.runnableRowsPerBlock, 4)
        XCTAssertTrue(plan.blocks[0].runnableRows.contains { $0.shapeID == "stop" })
        XCTAssertTrue(plan.blocks[0].runnableRows.contains { $0.shapeID == "tool" })
        XCTAssertTrue(plan.blocks[0].runnableRows.contains { $0.shapeID == "schema" })
        XCTAssertTrue(plan.blocks[0].runnableRows.contains { $0.shapeID == "top-logprobs" })
        XCTAssertTrue(plan.pendingSampleReasons.contains("logit_bias_replay_requires_safe_token_geometry:bias"))
    }

    func testUnknownRequestShapeRemainsRunnableAsRepresentativeFallbackRow() throws {
        let url = try writeCapture([
            shape("unknown", extra: ["unknown_top_level_keys_present": true]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertNil(plan.pendingReason)
        XCTAssertEqual(plan.runnableRowsPerBlock, 1)
        XCTAssertEqual(plan.blocks[0].rows[0].expectedSelectorReason, "unknown_request_field")
        XCTAssertNotNil(plan.blocks[0].rows[0].syntheticStandIn)
    }

    func testUnsupportedShapeRowsStayPendingWithoutBlockingEligibleFallbackRows() throws {
        let url = try writeCapture([
            shape("eligible"),
            shape("multimodal", extra: ["multimodal_requested": true]),
        ])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: url)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015)
        XCTAssertEqual(plan.pendingReason, "multimodal_shape_requires_sanitized_part_geometry:multimodal")
        XCTAssertGreaterThan(plan.runnableRowsPerBlock, 0)
        XCTAssertLessThan(plan.runnableRowsPerBlock, plan.rowsPerBlock)
        XCTAssertTrue(plan.blocks[0].runnableRows.contains { $0.shapeID == "eligible" })
        XCTAssertFalse(plan.sampleCoverageComplete)
        XCTAssertEqual(plan.sampleCoverageExport["pending_sample_shape_count"] as? Int, 1)
    }

    private func cacheEvent(
        row: NativeMTPRequestShapeReplayRow,
        state: String? = nil,
        cachedTokens: Int? = nil,
        retainedHandoff: Bool? = nil,
        cacheOnly: Bool? = nil,
        surface: String = "unit_test",
        monotonicNanoseconds: UInt64 = 1
    ) -> NativeMTPLabConversationCacheObserver.Event {
        let actualCacheOnly = row.requiresCacheProof ? (cacheOnly ?? row.conversationCacheOnly) : false
        let expectedAttempted = row.requiresCacheProof
            && ["hit", "miss", "missing"].contains(row.conversationCacheLease)
        let actualState = state ?? (expectedAttempted ? row.conversationCacheLease : "not_applicable")
        return NativeMTPLabConversationCacheObserver.Event(
            eventSource: NativeMTPLabConversationCacheObserver.eventSource,
            requestID: row.requestID,
            monotonicNanoseconds: monotonicNanoseconds,
            surface: surface,
            keyPresent: row.requiresCacheProof,
            cacheOnly: actualCacheOnly,
            leaseAllowed: expectedAttempted,
            leaseObserved: actualState == "hit" || actualState == "miss",
            state: actualState,
            cachedTokens: cachedTokens ?? row.expectedCachedPromptTokens,
            lcp: cachedTokens ?? row.expectedCachedPromptTokens,
            trimBy: 0,
            retainedHandoff: retainedHandoff ?? row.conversationCacheRetainedHandoff,
            usableRetainedHandoff: false,
            recurrentCheckpointCount: 0
        )
    }


    func testV2FullTemplateCanonicalDigestMatchesPythonFixture() throws {
        let data = Data(#"[{"anonymous_cache_group_sha256":null,"assistant_tool_call_count":0,"completion_tokens":64,"conversation_cache_cached_prompt_tokens":0,"conversation_cache_lease":"not_applicable","conversation_cache_retained_handoff":false,"conversation_key_cache_only":false,"conversation_key_present":false,"effective_max_output_tokens":96,"effective_reasoning_effort":null,"frequency_penalty_nonzero":false,"generated_completion_tokens":64,"logit_bias_geometry":{"present":false},"logit_bias_present":false,"logit_controls_requested":false,"logprobs_requested":false,"min_p_nonzero":false,"multimodal_requested":false,"multiple_completions_requested":false,"observed_effective_path":"ordinary","observed_selector_eligible":true,"observed_selector_reason":"eligible","parallel_tool_calls_state":"absent","presence_penalty_nonzero":false,"projected_selector_eligible":true,"projected_selector_reason":"eligible","prompt_tokens":256,"reasoning_effort_state":"absent","reasoning_or_template_model":false,"repetition_penalty_nondefault":false,"requested_frequency_penalty":0,"requested_max_completion_tokens":96,"requested_min_p":null,"requested_n":1,"requested_presence_penalty":0,"requested_repetition_penalty":1,"requested_temperature":0.0,"requested_top_k":null,"requested_top_logprobs":null,"requested_top_p":1.0,"response_format_kind":"text","response_schema_geometry":{"kind":"text"},"sampling_requested":false,"served_model_family":"glm5_next_mtp_v1","served_model_hash_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","served_weights_manifest_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","shape_id":"digest-fixture","stop_sequence_utf8_length_buckets":{},"stop_sequence_utf8_lengths":[],"stop_sequences":0,"stream":true,"structured_output_requested":false,"target_completion_tokens":64,"tool_choice_function_index":null,"tool_choice_kind":"absent","tool_choice_present":false,"tool_count":0,"tool_grammar_required":false,"tool_message_count":0,"tool_parameter_schema_geometries":[],"tool_turn_state_present":false,"tools_present":false,"top_k_present":false,"top_logprobs_requested":false,"unknown_request_fields_present":false,"unknown_stream_option_keys_present":false,"unknown_top_level_keys_present":false}]"#.utf8)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(try NativeMTPReplayV2Projection.sampleDigest(rows),
                       "566ecee05d09d92e8ecdfff0d5b8a531962765c0b58c8d4fd5ec79e974d9a698")
    }

    func testV2ObservationDoesNotBecomeCandidateEligibility() throws {
        let observed = v2Shape("observed-native", extra: ["observed_selector_reason": "eligible",
            "observed_selector_eligible": true, "observed_effective_path": "native_mtp"])
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: writeV2Capture([observed]))
        XCTAssertTrue(capture.header.isV2)
        XCTAssertEqual(capture.shapes[0].preCapacitySelectorReason, "eligible")
        // A capture observation without a bound candidate projection is never
        // silently treated as eligible candidate admission.
        XCTAssertEqual(capture.shapes[0].projectedSelectorReason, "unknown_request_field")
        XCTAssertNil(capture.shapes[0].sanitizedExport["pre_capacity_selector_reason"])
        XCTAssertEqual(capture.shapes[0].sanitizedExport["observed_effective_path"] as? String, "native_mtp")
    }

    func testV2RejectsMixedSchemasMissingControlsAndWrongTypes() throws {
        for key in NativeMTPReplayV2Validation.controls {
            var missing = v2Shape("missing")
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try NativeMTPRequestShapeReplayCapture.load(from: writeV2Capture([missing])))
        }
        for extra: [String: Any] in [
            ["unexpected": true], ["observed_selector_eligible": 1],
            ["observed_selector_reason": "invented"], ["parallel_tool_calls_state": "null"],
            ["reasoning_effort_state": "arbitrary buyer value"], ["effective_reasoning_effort": "arbitrary"],
            ["tool_choice_function_index": 0], ["sequence": 2],
            ["schema": NativeMTPRequestShapeCapture.schema],
        ] {
            XCTAssertThrowsError(try NativeMTPRequestShapeReplayCapture.load(from: writeV2Capture([v2Shape("invalid", extra: extra)])))
        }
        XCTAssertThrowsError(try NativeMTPRequestShapeReplayCapture.load(from: writeV2Capture([
            v2Shape("repeated"), v2Shape("repeated", extra: ["sequence": 2]),
        ])))
        XCTAssertThrowsError(try NativeMTPRequestShapeReplayCapture.load(from: writeV2Capture([
            v2Shape("off-native", extra: ["observed_selector_reason": "eligible", "observed_selector_eligible": true,
                                          "observed_effective_path": "native_mtp"]),
        ], mode: "off")))
    }

    func testV2UnknownControlsStayPendingWithoutRemovingWeight() throws {
        let cases: [[String: Any]] = [
            ["served_model_family": "unknown"], ["parallel_tool_calls_state": "unknown"],
            ["reasoning_effort_state": "unknown"], ["unknown_top_level_keys_present": true],
            ["tool_choice_kind": "other", "tool_choice_present": true],
            ["served_model_hash_sha256": "unavailable"],
        ]
        for extra in cases {
            let capture = try NativeMTPRequestShapeReplayCapture.load(from: writeV2Capture([v2Shape("pending", extra: extra)]))
            let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015, qualifiedSlots: 4)
            XCTAssertEqual(plan.sampleShapeCount, 1)
            XCTAssertEqual(plan.omittedSampleShapeCount, 0)
            XCTAssertEqual(plan.pendingSampleShapeCount, 1)
            XCTAssertTrue(plan.pendingReason?.hasPrefix("PENDING_UNREPRODUCIBLE_CAPTURE:") == true)
            XCTAssertEqual(plan.blocks[0].rows[0].targetCompletionTokens, 64)
        }
    }

    func testV2ReconstructsReasoningParallelAndNamedChoiceThroughProductionParser() throws {
        let geometry: [String: Any] = ["byte_count": 2, "max_depth": 1, "object_count": 1, "array_count": 0, "property_count": 0]
        let value = v2Shape("named", extra: ["parallel_tool_calls_state": "false", "reasoning_effort_state": "none",
            "effective_reasoning_effort": "low", "tools_present": true, "tool_count": 2,
            "tool_parameter_schema_geometries": [geometry, geometry], "tool_choice_present": true,
            "tool_choice_kind": "function", "tool_choice_function_index": 1, "tool_grammar_required": true])
        let shape = try NativeMTPRequestShapeReplayShape(value, candidateReason: "tools")
        let row = NativeMTPRequestShapeReplayRow(shape: shape, captureIndex: 0, blockIndex: 0, supportsSampling: true)
        let base = try NativeMTPRequestShapeReplayRunner.makeRequest(modelID: "zai-org/glm-5.3-flash",
            requestID: row.requestID, prompt: "synthetic", maxTokens: 128, temperature: 0, topP: 1, stream: true)
        let request = try NativeMTPRequestShapeReplayRunner.applySyntheticStandIn(for: row, to: base)
        XCTAssertEqual(request.parallelToolCalls, false)
        XCTAssertEqual(request.reasoningEffort, "none")
        XCTAssertEqual(request.templateReasoningEffort(for: request.model), "low")
        XCTAssertTrue(GrammarConstraintState.isRequired(request))
        let choice = try XCTUnwrap(request.promptSource.toolChoice)
        let encoded = try JSONEncoder().encode(choice)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["function"] as? [String: Any])?["name"] as? String, "replay_tool_1")
    }

    func testCapacityFallbackDoesNotRewritePreCapacityEligibility() {
        XCTAssertTrue(NativeMTPRequestShapeReplayRunner.admissionMatches(path: .nativeMTP,
            expectedReason: "eligible", expectedPath: "native_mtp", actualReason: "capacity_above_native_bound", actualPath: "ordinary"))
        for (path, expected, actualPath) in [(NativeMTPRequestShapeReplayPath.ordinary, "eligible", "ordinary"),
                                             (.nativeMTP, "tools", "ordinary"), (.nativeMTP, "eligible", "native_mtp")] {
            XCTAssertFalse(NativeMTPRequestShapeReplayRunner.admissionMatches(path: path,
                expectedReason: expected, expectedPath: "native_mtp", actualReason: "capacity_above_native_bound", actualPath: actualPath))
        }
        XCTAssertFalse(NativeMTPRequestShapeReplayRunner.admissionMatches(path: .ordinary,
            expectedReason: "mode_off", expectedPath: "ordinary", actualReason: "eligible", actualPath: "native_mtp"))
    }

    func testV2ParallelControlReconstructionMatchesProductionStopAfterToolGetter() throws {
        for (state, expected, stopsAfterFirst) in [("absent", nil as Bool?, false), ("true", true, false), ("false", false, true)] {
            let shape = try NativeMTPRequestShapeReplayShape(v2Shape("parallel-\(state)", extra: ["parallel_tool_calls_state": state]), candidateReason: state == "false" ? "tools" : "eligible")
            let row = NativeMTPRequestShapeReplayRow(shape: shape, captureIndex: 0, blockIndex: 0, supportsSampling: true)
            let base = try NativeMTPRequestShapeReplayRunner.makeRequest(modelID: "zai-org/glm-5.3-flash",
                requestID: row.requestID, prompt: "synthetic", maxTokens: 128, temperature: 0, topP: 1, stream: true)
            let request = try NativeMTPRequestShapeReplayRunner.applySyntheticStandIn(for: row, to: base)
            XCTAssertEqual(request.parallelToolCalls, expected, state)
            XCTAssertEqual(request.stopsAfterFirstCompleteToolCall, stopsAfterFirst, state)
            XCTAssertEqual(request.topLevelKeys.contains("parallel_tool_calls"), state != "absent", state)
        }
    }

    func testV2KeepsQualifiedCBSlotsEvenWhenAllShapesAreEligible() throws {
        let shapes = try (0..<4).map { index in
            try NativeMTPRequestShapeReplayShape(v2Shape("slot-\(index)", extra: ["sequence": index + 1]), candidateReason: "eligible")
        }
        let capture = NativeMTPRequestShapeReplayCapture(header: try NativeMTPRequestShapeReplayHeader(v2Header()), shapes: shapes)
        let plan = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015,
            qualifiedSlots: 4, maxNativeActiveRows: 1, supportsSampling: true)
        XCTAssertEqual(plan.blocks[0].runnableWaves.map(\.count), [4])
        let legacyGLM = try NativeMTPRequestShapeReplayPlan.make(capture: capture, blocks: 10, seed: 48015,
            qualifiedSlots: 4, maxNativeActiveRows: 1, preserveTotalSlots: true)
        XCTAssertEqual(legacyGLM.blocks[0].runnableWaves.map(\.count), [4])
    }

    func testV2ProjectionBindsEveryInputAndFullCandidateShape() throws {
        let capture = try NativeMTPRequestShapeReplayCapture.load(from: writeV2Capture([v2Shape("bound")]))
        var template = capture.shapes[0].sanitizedExport
        template["projected_selector_reason"] = "eligible"
        template["projected_selector_eligible"] = true
        let sampleSHA = try NativeMTPReplayV2Projection.sampleDigest([template])
        let tuple: [String: Any] = ["maximum_prompt_tokens": 4096, "maximum_completion_tokens": 256,
            "request_feature_profile": "native_mtp_sampled_text_v1", "supports_stop_sequences": true,
            "supports_streaming": true, "supports_non_streaming": true, "has_qualified_row_mapped_transactions": true,
            "maximum_proposal_depth": 1, "supports_current_processor": true, "supports_current_state_cache": true,
            "tuple_admitted": true, "tuple_revoked": false, "revocation_state_available": true, "family_adapter": "glm5_next_mtp_v1"]
        let tupleURL = try writeV2Object(tuple)
        let tupleSHA = SHA256.hash(data: try Data(contentsOf: tupleURL)).map { String(format: "%02x", $0) }.joined()
        let hash = String(repeating: "a", count: 64)
        let schedule: [String: Any] = ["kind": "modeled_preregistered_staggered_arrivals", "source": "bench_policy.arrival_interval_ms",
            "arrival_interval_ms": 25, "offset_rule": "wave_index_times_interval", "order": "capture_sequence", "identical_across_paths": true]
        var plan: [String: Any] = ["schema": "macprovider.native-mtp-request-shape-replay-plan.v2",
            "qualification_status": "PENDING_REAL_LAB_REPLAY", "policy_sha256": hash, "sample_digest_sha256": sampleSHA,
            "source_capture_sha256": hash, "tuple_bounds_sha256": tupleSHA, "bench_policy_sha256": hash,
            "projection_stage": "offline_sanitized_shape_projection_only", "capture_schema": capture.header.schema,
            "capture_header": capture.header.object,
            "sample_report": ["sampling_plan_id": "bounded", "sample_period_start": "2026-10-26T00:00:00Z",
                "sample_period_end": "2026-10-26T01:00:00Z", "captured_request_count": 1, "captured_completion_tokens": 64,
                "projected_request_count_per_block": 1, "representativeness_claim": "bounded preregistered persistable traffic"],
            "replay_requirements": ["status": "PENDING", "reason": "requires measured paired replay", "must_provide": ["fresh timing"]],
            "arrival_schedule": schedule, "blocks": (0..<10).map { ["block_index": $0, "request_shape_templates": [template], "metrics_status": "PENDING_REAL_REPLAY"] as [String: Any] }]
        func load(_ value: [String: Any]) throws -> NativeMTPReplayV2Projection {
            try NativeMTPReplayV2Projection.load(planURL: writeV2Object(value), tupleURL: tupleURL, capture: capture,
                captureSHA: hash, policySHA: hash, benchPolicySHA: hash, sampleSHA: sampleSHA,
                arrivalIntervalMS: 25, blocks: 10, modelID: "zai-org/glm-5.3-flash")
        }
        let bound = try load(plan)
        XCTAssertEqual(bound.capture.shapes[0].candidateReason, "eligible")
        XCTAssertEqual(bound.capture.shapes[0].preCapacitySelectorReason, "mode_off")
        for key in ["policy_sha256", "source_capture_sha256", "tuple_bounds_sha256", "bench_policy_sha256", "sample_digest_sha256"] {
            var drift = plan
            drift[key] = String(repeating: "b", count: 64)
            XCTAssertThrowsError(try load(drift), key)
        }
        plan["unexpected"] = true
        XCTAssertThrowsError(try load(plan))
    }

    private func writeV2Object(_ object: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-v2-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeV2Capture(_ shapes: [[String: Any]], mode: String = "auto") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-v2-\(UUID().uuidString).jsonl")
        let text = try ([v2Header(mode: mode)] + shapes).map(json).joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func v2Header(mode: String = "auto") -> [String: Any] {
        ["schema": NativeMTPReplayV2Validation.captureSchema, "record_type": "header",
         "captured_at": "2026-10-26T00:00:00Z", "sample_window_started_at": "2026-10-26T00:00:00Z",
         "native_mtp_mode": mode, "capture_requires_native_mtp_off": false,
         "sample_method": "opt_in_successful_persistable_completions_observation", "served_identity": "per_record_sha256",
         "capture_role": "request_shape_observation_only", "build_source_commit": String(repeating: "a", count: 40),
         "build_cdhash": String(repeating: "b", count: 40), "build_identity_complete": true,
         "cli_version": "1.8.999", "max_records": 1000, "max_bytes": 10485760]
    }

    private func v2Shape(_ id: String, extra: [String: Any] = [:]) -> [String: Any] {
        var value = shape(id)
        value.removeValue(forKey: "max_completion_tokens_requested")
        value.removeValue(forKey: "pre_capacity_selector_reason")
        value.removeValue(forKey: "pre_capacity_eligible")
        value.removeValue(forKey: "effective_path")
        value["schema"] = NativeMTPReplayV2Validation.captureSchema
        value["anonymous_cache_group_sha256"] = NSNull()
        value["observed_selector_reason"] = "mode_off"
        value["observed_selector_eligible"] = false
        value["observed_effective_path"] = "ordinary"
        value["served_model_family"] = "glm5_next_mtp_v1"
        value["parallel_tool_calls_state"] = "absent"
        value["reasoning_effort_state"] = "absent"
        value["effective_reasoning_effort"] = NSNull()
        value["tool_choice_function_index"] = NSNull()
        value["tool_grammar_required"] = false
        for (key, item) in extra { value[key] = item }
        return value
    }

    private func writeCapture(_ shapes: [[String: Any]]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-mtp-replay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("capture.jsonl")
        var lines = [try json(header())]
        for shape in shapes {
            lines.append(try json(shape))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func header() -> [String: Any] {
        [
            "schema": NativeMTPRequestShapeCapture.schema,
            "record_type": "header",
            "captured_at": "2026-10-07T00:00:00Z",
            "native_mtp_mode": "off",
            "capture_requires_native_mtp_off": true,
        ]
    }

    private func shape(
        _ id: String,
        conversationKey: Bool = false,
        cacheOnly: Bool = false,
        lease: String = "not_applicable",
        cachedTokens: Int = 0,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "schema": NativeMTPRequestShapeCapture.schema,
            "record_type": "request_shape",
            "sequence": 1,
            "shape_id": id,
            "captured_at": "2026-10-07T00:00:01Z",
            "served_model_hash_sha256": String(repeating: "d", count: 64),
            "served_weights_manifest_sha256": String(repeating: "e", count: 64),
            "native_mtp_tuple_sha256": String(repeating: "f", count: 64),
            "native_mtp_served_snapshot_id_sha256": String(repeating: "1", count: 64),
            "native_mtp_target_generation": 1,
            "stream": true,
            "stop_sequences": 0,
            "stop_sequence_utf8_lengths": [],
            "stop_sequence_utf8_length_buckets": [:],
            "requested_temperature": 0.0,
            "requested_top_p": 1.0,
            "requested_top_k": NSNull(),
            "requested_min_p": NSNull(),
            "requested_presence_penalty": 0.0,
            "requested_frequency_penalty": 0.0,
            "requested_repetition_penalty": NSNull(),
            "requested_n": 1,
            "requested_max_completion_tokens": 128,
            "effective_max_output_tokens": 64,
            "sampling_requested": false,
            "multiple_completions_requested": false,
            "top_k_present": false,
            "min_p_nonzero": false,
            "frequency_penalty_nonzero": false,
            "presence_penalty_nonzero": false,
            "repetition_penalty_nondefault": false,
            "logit_bias_present": false,
            "logit_bias_geometry": ["entry_count": 0, "numeric_value_count": 0, "positive_count": 0, "negative_count": 0, "zero_count": 0, "min_value": NSNull(), "max_value": NSNull(), "max_abs_bucket": "none"],
            "tools_present": false,
            "tool_count": 0,
            "tool_parameter_schema_geometries": [],
            "tool_choice_present": false,
            "tool_choice_kind": "absent",
            "tool_turn_state_present": false,
            "tool_message_count": 0,
            "assistant_tool_call_count": 0,
            "structured_output_requested": false,
            "response_format_kind": "text",
            "response_schema_geometry": ["byte_count": 0, "max_depth": 0, "object_count": 0, "array_count": 0, "property_count": 0],
            "logprobs_requested": false,
            "top_logprobs_requested": false,
            "requested_top_logprobs": NSNull(),
            "logit_controls_requested": false,
            "reasoning_or_template_model": false,
            "multimodal_requested": false,
            "unknown_request_fields_present": false,
            "unknown_top_level_keys_present": false,
            "unknown_stream_option_keys_present": false,
            "conversation_key_present": conversationKey,
            "conversation_key_cache_only": cacheOnly,
            "conversation_cache_lease": lease,
            "conversation_cache_cached_prompt_tokens": cachedTokens,
            "conversation_cache_retained_handoff": false,
            "prompt_tokens": 1536,
            "completion_tokens": 64,
            "generated_completion_tokens": 64,
            "max_completion_tokens_requested": 128,
            "pre_capacity_selector_reason": "mode_off",
            "pre_capacity_eligible": false,
            "effective_path": "ordinary",
        ]
        for (key, value) in extra {
            object[key] = value
        }
        return object
    }

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
