import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-048-R016 (0.1.125, Related: #2481): the on-device native-MTP
/// self-check admits native MTP only when it beats ordinary decode by the
/// margin at every probe point, against the route an ordinary request takes
/// with native MTP off.
final class NativeMTPSelfCheckWorkloadTests: XCTestCase {
    private typealias Check = NativeMTPOnDeviceSelfCheck

    /// A point measured as the grid reports it: one-row request tok/s
    /// (output tokens over the whole request, prefill included).
    private func point(
        _ name: String,
        ordinaryTPS: Double,
        nativeTPS: Double,
        tokens: [Int] = [1, 2, 3, 4],
        nativeTokens: [Int]? = nil,
        promptTokens: Int = 0
    ) -> Check.PointMeasurement {
        Check.PointMeasurement(
            name: name,
            mtpTokens: nativeTokens ?? tokens,
            mtpSeconds: Double(tokens.count) / nativeTPS,
            referenceTokens: tokens,
            ordinarySeconds: Double(tokens.count) / ordinaryTPS,
            promptTokens: promptTokens
        )
    }

    // MARK: - #2496 prompt ceiling

    /// The live GLM-5.3-Flash uncensored self-check (2026-11-25, CLI
    /// 1.8.299): challenge 1.156, ctx200 1.131 at 341 tokens, ctx4000 1.013 at
    /// 3,673 tokens. Native MTP serves up to the line's 1.03 crossing.
    func testIssue2496LiveGridAdmitsUpToTheMeasuredCeiling() throws {
        let points = [
            point("challenge", ordinaryTPS: 100, nativeTPS: 115.6, promptTokens: 51),
            point("ctx200_out128", ordinaryTPS: 100, nativeTPS: 113.1, promptTokens: 341),
            point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: 101.3, promptTokens: 3673),
        ]
        XCTAssertFalse(Check.admit(points).passed, "the all-points rule alone still refuses")
        let ceiling = try XCTUnwrap(Check.promptCeiling(points))
        // 341 + (3673 - 341) * (1.131 - 1.03) / (1.131 - 1.013) = 3,192.
        XCTAssertEqual(ceiling, 3192)
        XCTAssertLessThan(ceiling, 3673)
    }

    func testAFailingPointSlowerThanOrdinaryCapsAtTheLastPassingPrompt() {
        let points = [
            point("challenge", ordinaryTPS: 100, nativeTPS: 120, promptTokens: 51),
            point("ctx200_out128", ordinaryTPS: 100, nativeTPS: 112, promptTokens: 341),
            point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: 95, promptTokens: 3673),
        ]
        XCTAssertEqual(Check.promptCeiling(points), 341)
    }

    func testNoCeilingWhenTokensDifferAtTheLongPoint() {
        let points = [
            point("challenge", ordinaryTPS: 100, nativeTPS: 120, promptTokens: 51),
            point("ctx200_out128", ordinaryTPS: 100, nativeTPS: 112, promptTokens: 341),
            point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: 102, nativeTokens: [1, 2, 3, 9], promptTokens: 3673),
        ]
        XCTAssertNil(Check.promptCeiling(points))
    }

    func testNoCeilingWhenAShortPointOrTheChallengeFails() {
        // #2481: the short point fails, so nothing is admitted.
        XCTAssertNil(Check.promptCeiling([
            point("challenge", ordinaryTPS: 100, nativeTPS: 111, promptTokens: 51),
            point("ctx200_out128", ordinaryTPS: 125.13, nativeTPS: 122.12, promptTokens: 341),
        ]))
        XCTAssertNil(Check.promptCeiling([
            point("challenge", ordinaryTPS: 100, nativeTPS: 101, promptTokens: 51),
            point("ctx200_out128", ordinaryTPS: 100, nativeTPS: 113, promptTokens: 341),
            point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: 101, promptTokens: 3673),
        ]))
        // The challenge alone passing is not enough: a workload point must pass.
        XCTAssertNil(Check.promptCeiling([
            point("challenge", ordinaryTPS: 100, nativeTPS: 120, promptTokens: 51),
            point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: 101, promptTokens: 3673),
        ]))
    }

    func testTheCappedCapabilityRoutesLongerPromptsToOrdinaryDecode() {
        let signed = NativeMTPCapability(
            admitted: true, revoked: false, revocationStateAvailable: true,
            supportsCurrentProcessor: true, supportsCurrentStateCache: true,
            supportsStreaming: true, supportsNonStreaming: true, supportsStopSequences: true,
            hasQualifiedRowMappedTransactions: true, maximumProposalDepth: 1,
            maximumPromptTokens: 200_000, maximumCompletionTokens: 32_768
        )
        let capped = signed.cappingPromptTokens(at: 3192)
        XCTAssertEqual(capped.maximumPromptTokens, 3192)
        XCTAssertEqual(signed.cappingPromptTokens(at: 500_000).maximumPromptTokens, 200_000, "never raised")
        let expected = NativeMTPCapability(
            admitted: true, revoked: false, revocationStateAvailable: true,
            supportsCurrentProcessor: true, supportsCurrentStateCache: true,
            supportsStreaming: true, supportsNonStreaming: true, supportsStopSequences: true,
            hasQualifiedRowMappedTransactions: true, maximumProposalDepth: 1,
            maximumPromptTokens: 3192, maximumCompletionTokens: 32_768
        )
        XCTAssertEqual(capped, expected, "only the prompt bound changes")
    }

    func testEveryPointWinningPassesWithTheTightestSpeedup() {
        let verdict = Check.admit([
            point("challenge", ordinaryTPS: 100, nativeTPS: 150),
            point("ctx200_out128", ordinaryTPS: 100, nativeTPS: 140),
            point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: 120),
        ])
        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(verdict.reason, "passed")
        XCTAssertEqual(verdict.point, "ctx4000_out256")
        XCTAssertEqual(verdict.speedup, 1.2, accuracy: 1e-9)
    }

    /// The #2481 grid: the challenge passes at 1.11, but one-row native MTP
    /// serves below ordinary decode at ctx 200 and 4000. Native MTP stays off.
    func testIssue2481GridKeepsNativeMTPOff() {
        let challenge = point("challenge", ordinaryTPS: 100, nativeTPS: 111)
        XCTAssertTrue(Check.admit([challenge]).passed)
        let short = point("ctx200_out128", ordinaryTPS: 125.13, nativeTPS: 122.12)
        let long = point("ctx4000_out256", ordinaryTPS: 97.88, nativeTPS: 90.36)
        let verdict = Check.admit([challenge, short, long])
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.reason, "no_net_gain")
        XCTAssertEqual(verdict.point, "ctx200_out128")
        XCTAssertEqual(verdict.speedup, 122.12 / 125.13, accuracy: 1e-9)
        // The long point alone fails too.
        XCTAssertEqual(Check.admit([challenge, long]).point, "ctx4000_out256")
        XCTAssertFalse(Check.admit([challenge, long]).passed)
    }

    func testAWinInsideTheMarginKeepsNativeMTPOff() {
        XCTAssertEqual(Check.minimumSpeedup, 1.03)
        for nativeTPS in [100.0, 102.0, 102.9] {
            let verdict = Check.admit([
                point("challenge", ordinaryTPS: 100, nativeTPS: 150),
                point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: nativeTPS),
            ])
            XCTAssertFalse(verdict.passed, "native \(nativeTPS) tok/s against ordinary 100")
            XCTAssertEqual(verdict.point, "ctx4000_out256")
        }
        XCTAssertTrue(Check.admit([
            point("challenge", ordinaryTPS: 100, nativeTPS: 150),
            point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: 103.5),
        ]).passed)
    }

    func testATokenMismatchAtAWorkloadPointKeepsNativeMTPOff() {
        let verdict = Check.admit([
            point("challenge", ordinaryTPS: 100, nativeTPS: 150),
            point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: 150, nativeTokens: [1, 2, 9, 4]),
        ])
        XCTAssertEqual(verdict, Check.Verdict(passed: false, reason: "token_mismatch", speedup: 0, point: "ctx4000_out256"))
    }

    func testTheFirstFailingPointDecides() {
        let verdict = Check.admit([
            point("challenge", ordinaryTPS: 100, nativeTPS: 90),
            point("ctx4000_out256", ordinaryTPS: 100, nativeTPS: 150, nativeTokens: [9]),
        ])
        XCTAssertEqual(verdict.reason, "no_net_gain")
        XCTAssertEqual(verdict.point, "challenge")
    }

    func testNoPointsKeepsNativeMTPOff() {
        XCTAssertEqual(Check.admit([]), Check.Verdict(passed: false, reason: "no_probe_points", speedup: 0))
    }

    func testAnEmptyReferenceAtAnyPointKeepsNativeMTPOff() {
        let empty = Check.PointMeasurement(
            name: "ctx200_out128", mtpTokens: [], mtpSeconds: 1, referenceTokens: [], ordinarySeconds: 2)
        XCTAssertEqual(Check.admit([point("challenge", ordinaryTPS: 100, nativeTPS: 150), empty]).reason, "empty_output")
    }

    func testWorkloadPointsAreTheGridsShortAndLongContexts() {
        XCTAssertEqual(Check.workloadPoints, [
            Check.ProbePoint(name: "ctx200_out128", contextTokens: 200, outputTokens: 128),
            Check.ProbePoint(name: "ctx4000_out256", contextTokens: 4000, outputTokens: 256),
        ])
    }

    /// The speed reference is the route an ordinary request takes with
    /// native MTP off; the token reference is the native request's route.
    func testOrdinaryRoutes() {
        let mixed = Check.ordinaryRoutes(processRoute: .stockOrder, mixed: true)
        XCTAssertEqual(mixed.speed, .stockOrder)
        XCTAssertEqual(mixed.reference, .rowInvariant)
        for route in [SmallMRoute.rowInvariant, .stockOrder] {
            let plain = Check.ordinaryRoutes(processRoute: route, mixed: false)
            XCTAssertEqual(plain.speed, route)
            XCTAssertEqual(plain.reference, route)
        }
        let speed = ModelRuntime.nativeMTPOrdinaryReferenceRequest(
            id: "speed", promptTokens: [1, 2], maxOutputTokens: 4, nativeAdmitted: false,
            processRoute: .stockOrder, mixed: true)
        XCTAssertEqual(speed.smallMRoute, .stockOrder)
        XCTAssertEqual(speed.decodePath, .ordinary)
        let reference = ModelRuntime.nativeMTPOrdinaryReferenceRequest(
            id: "ref", promptTokens: [1, 2], maxOutputTokens: 4, processRoute: .stockOrder, mixed: true)
        XCTAssertEqual(reference.smallMRoute, .rowInvariant)
    }

    func testPointsAreClampedToTheSignedBounds() {
        let long = Check.workloadPoints[1]
        XCTAssertEqual(
            Check.boundedPoint(long, maxPromptTokens: 4096, maxCompletionTokens: 8192),
            Check.ProbePoint(name: "ctx4000_out256", contextTokens: 4000, outputTokens: 256)
        )
        XCTAssertEqual(
            Check.boundedPoint(long, maxPromptTokens: 2048, maxCompletionTokens: 64),
            Check.ProbePoint(name: "ctx4000_out256", contextTokens: 2048, outputTokens: 64)
        )
        XCTAssertNil(Check.boundedPoint(long, maxPromptTokens: 0, maxCompletionTokens: 64))
        XCTAssertNil(Check.boundedPoint(long, maxPromptTokens: 4096, maxCompletionTokens: 1))
    }

    func testAnOvershootingPromptShrinksBelowTheBound() {
        XCTAssertEqual(Check.shrunkContextTokens(current: 4000, tokenized: 4400, maxPromptTokens: 4096), 3611)
        XCTAssertEqual(Check.shrunkContextTokens(current: 4000, tokenized: 0, maxPromptTokens: 4096), 0)
    }

    /// Byte for byte `prompts.build_messages(ctx, 0)[0]["content"]` of
    /// scripts/lab/parity-grid/prompts.py, the prompt the grid measured.
    func testWorkloadPromptIsTheParityGridPrompt() {
        let expected: [(context: Int, length: Int, digest: String)] = [
            (200, 800, "18bbfbf0d22520f8572d292acabb157a172f860ff7e548119240907d0f4e28d8"),
            (4000, 16000, "3277529e8909a23865569974716331b5e96e3f1c2daa2722088fb54b217ef820"),
        ]
        for (context, length, digest) in expected {
            let text = Check.workloadPromptText(contextTokens: context)
            XCTAssertEqual(text.utf8.count, length)
            XCTAssertTrue(text.hasPrefix("Notebook 0000. Field notes follow.\n\nFalcon falcon lantern cistern"))
            let sha = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(sha, digest, "context \(context)")
        }
    }

    func testPointLogLineCarriesTheVerdict() {
        let line = ModelRuntime.nativeMTPSelfCheckPointLogLine(
            point("ctx4000_out256", ordinaryTPS: 97.88, nativeTPS: 90.36), promptTokens: 3998)
        XCTAssertTrue(line.hasPrefix(
            "event=native_mtp_self_check_point point=ctx4000_out256 result=no_net_gain speedup=0.923 prompt_tokens=3998 output_tokens=4 "
        ), line)
        XCTAssertTrue(line.hasSuffix(" min_speedup=1.03\n"), line)
    }
}
