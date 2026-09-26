@testable import macprovider_cli
import XCTest

final class IsolationProbePairSelectionTests: XCTestCase {
    private func result(proven: Bool, distinguishing: Bool, divergences: Int = 0) -> PagedKVRuntimeMoEProbeResult {
        PagedKVRuntimeMoEProbeResult(
            proven: proven,
            rowsDecodedInSharedForward: 2,
            rowFailures: 0,
            crossRowDivergences: divergences,
            challengeDistinguishing: distinguishing
        )
    }

    func testDistinguishingFailureIsFinalAndLaterPairsNeverRun() async {
        let scripted = [
            result(proven: false, distinguishing: false),
            result(proven: false, distinguishing: true, divergences: 1),
            result(proven: true, distinguishing: true),
        ]
        var ran: [Int] = []
        let chosen = await ModelRuntime.firstDistinguishingIsolationProbe(pairCount: scripted.count) { index in
            ran.append(index)
            return scripted[index]
        }
        XCTAssertEqual(ran, [0, 1], "a real divergence must not be retried away with another pair")
        XCTAssertEqual(chosen, scripted[1])
        XCTAssertEqual(chosen?.proven, false)
    }

    func testFirstDistinguishingPassIsChosen() async {
        let scripted = [
            result(proven: false, distinguishing: false),
            result(proven: true, distinguishing: true),
            result(proven: false, distinguishing: true, divergences: 3),
        ]
        var skipped: [Int] = []
        let chosen = await ModelRuntime.firstDistinguishingIsolationProbe(
            pairCount: scripted.count,
            attempt: { scripted[$0] },
            onIndistinguishable: { skipped.append($0) }
        )
        XCTAssertEqual(chosen, scripted[1])
        XCTAssertEqual(skipped, [0])
    }

    func testProbeFailureIsFinalAndCannotBeRetriedAway() async {
        let scripted = [
            PagedKVRuntimeMoEProbeResult.failClosed,
            result(proven: true, distinguishing: true),
        ]
        var ran: [Int] = []
        let chosen = await ModelRuntime.firstDistinguishingIsolationProbe(pairCount: scripted.count) { index in
            ran.append(index)
            return scripted[index]
        }
        XCTAssertEqual(ran, [0], "a probe exception must fail closed, not fall through to a later passing pair")
        XCTAssertEqual(chosen, .failClosed)
        XCTAssertEqual(chosen?.proven, false)
    }

    func testIncompleteOrFailedIndistinguishableRunIsFinal() async {
        let incomplete = PagedKVRuntimeMoEProbeResult(
            proven: false,
            rowsDecodedInSharedForward: 1,
            rowFailures: 0,
            crossRowDivergences: 0,
            challengeDistinguishing: false
        )
        let rowFailure = PagedKVRuntimeMoEProbeResult(
            proven: false,
            rowsDecodedInSharedForward: 2,
            rowFailures: 1,
            crossRowDivergences: 0,
            challengeDistinguishing: false
        )
        for failing in [incomplete, rowFailure] {
            var ran: [Int] = []
            let chosen = await ModelRuntime.firstDistinguishingIsolationProbe(pairCount: 2) { index in
                ran.append(index)
                return index == 0 ? failing : self.result(proven: true, distinguishing: true)
            }
            XCTAssertEqual(ran, [0])
            XCTAssertEqual(chosen, failing)
        }
    }

    func testNoDistinguishingPairStaysUnproven() async {
        let chosen = await ModelRuntime.firstDistinguishingIsolationProbe(pairCount: 3) { _ in
            self.result(proven: false, distinguishing: false)
        }
        XCTAssertEqual(chosen?.proven, false)
        XCTAssertEqual(chosen?.challengeDistinguishing, false)
    }
}
