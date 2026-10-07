#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
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
        cacheOnly: Bool? = nil
    ) -> NativeMTPLabConversationCacheObserver.Event {
        let actualCacheOnly = row.requiresCacheProof ? (cacheOnly ?? row.conversationCacheOnly) : false
        let expectedAttempted = row.requiresCacheProof
            && ["hit", "miss", "missing"].contains(row.conversationCacheLease)
        let actualState = state ?? (expectedAttempted ? row.conversationCacheLease : "not_applicable")
        return NativeMTPLabConversationCacheObserver.Event(
            eventSource: NativeMTPLabConversationCacheObserver.eventSource,
            requestID: row.requestID,
            monotonicNanoseconds: 1,
            surface: "unit_test",
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
