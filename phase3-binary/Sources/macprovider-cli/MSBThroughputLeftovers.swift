import ArgumentParser
import CryptoKit
import Foundation

/// FR-CB15 leftover scenarios on top of equal-length MSB-02/04 throughput.
enum MSBThroughputScenario: String, Codable, ExpressibleByArgument, CaseIterable {
    case throughput
    case msb03
    case msb05
    case parity
    case isolation
    case replay
    case drain
    case leftovers
}

struct MSBUsageRow: Codable, Sendable, Equatable {
    let requestID: String
    let promptTokens: Int
    let completionTokens: Int
    let emittedTokens: Int
    let cachedPromptTokens: Int
    let terminalStatus: String
    let settlementDisposition: String
}

struct MSBParityEvidence: Codable, Sendable, Equatable {
    let comparedTokens: Int
    let oneRowMatch: Bool
    let batchedRowMatches: [Bool]
    let firstDivergenceIndex: Int?
    let serialTokenSHA256: String
    let batchedTokenSHA256: String
    let pass: Bool
}

struct MSBIsolationEvidence: Codable, Sendable, Equatable {
    let cancelledRequestID: String
    let healthyRequestID: String
    let cancelledStatus: String
    let healthyStatus: String
    let cancelledCompletionTokens: Int
    let healthyCompletionTokens: Int
    let pass: Bool
}

struct MSBReplayEvidence: Codable, Sendable, Equatable {
    let requestID: String
    let firstDisposition: String
    let replayDisposition: String
    let tokensMatch: Bool
    let pass: Bool
}

struct MSBDrainEvidence: Codable, Sendable, Equatable {
    let queuedRejected: Bool
    let permitIssued: Bool
    let permitValid: Bool
    let postDrainRejected: Bool
    let activeStatuses: [String]
    let activeSettlements: [String]
    let activeRowsCompleted: Bool
    let pass: Bool
}

struct MSB05Evidence: Codable, Sendable, Equatable {
    let nativeParallelRows: Int
    let nativeParallelVsSerial: Double
    let omlxSidecarAvailable: Bool
    let omlxSidecarUnavailableReason: String
}

struct MSB03Evidence: Codable, Sendable, Equatable {
    let promptTokenLengths: [Int]
    let aggregateVsSerial: Double
    let shortRequestSerialTTFTp95: Double
    let shortRequestBatchedTTFTp95: Double
    let shortRequestTTFTRatio: Double
    let aggregatePass: Bool
    let ttftPass: Bool
    let pass: Bool
}

struct MSBLeftoversEvidence: Codable, Sendable, Equatable {
    let usageRows: [MSBUsageRow]?
    let usagePass: Bool?
    let msb03: MSB03Evidence?
    let msb05: MSB05Evidence?
    let parity: MSBParityEvidence?
    let isolation: MSBIsolationEvidence?
    let replay: MSBReplayEvidence?
    let drain: MSBDrainEvidence?
}

func msb03PromptLengths() -> [Int] {
    [512, 1024, 1536, 2048]
}

func msb03AggregatePass(aggregateVsSerial: Double) -> Bool {
    aggregateVsSerial > 1.2
}

func msb03ShortRequestTTFTPass(ratio: Double) -> Bool {
    ratio > 0 && ratio <= 2.0
}

func msbTemp0ParityMatch(serial: [Int], batched: [Int], comparedTokens: Int) -> (match: Bool, firstDivergence: Int?) {
    let count = min(comparedTokens, serial.count, batched.count)
    guard count > 0 else { return (false, 0) }
    for index in 0..<count {
        if serial[index] != batched[index] {
            return (false, index)
        }
    }
    return (true, nil)
}

func msbTokenSequenceSHA256(_ tokens: [Int]) -> String {
    var bytes = Data()
    bytes.reserveCapacity(tokens.count * 8)
    for token in tokens {
        var value = Int64(token).bigEndian
        withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
    }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func msbUsageAttributionPass(
    rows: [MSBUsageRow],
    expectedPromptTokens: [Int],
    expectedCompletionTokens: Int
) -> Bool {
    guard rows.count == expectedPromptTokens.count, !rows.isEmpty else { return false }
    guard Set(rows.map(\.requestID)).count == rows.count else { return false }
    guard Set(rows.map(\.promptTokens)) == Set(expectedPromptTokens) else { return false }
    return rows.allSatisfy {
        $0.cachedPromptTokens == 0
            && $0.completionTokens == expectedCompletionTokens
            && $0.emittedTokens == expectedCompletionTokens
            && $0.promptTokens > 0
            && $0.terminalStatus == ContinuousBatchSchedulerTerminalStatus.length.rawValue
            && $0.settlementDisposition == ContinuousBatchSettlementDisposition.eligibleOwner.rawValue
    }
}

func msbIsolationPass(_ evidence: MSBIsolationEvidence) -> Bool {
    evidence.cancelledRequestID != evidence.healthyRequestID
        && evidence.cancelledStatus == "cancelled"
        && evidence.healthyStatus == "length"
        && evidence.healthyCompletionTokens > evidence.cancelledCompletionTokens
}

func msbReplayPass(_ evidence: MSBReplayEvidence) -> Bool {
    evidence.firstDisposition == ContinuousBatchSettlementDisposition.eligibleOwner.rawValue
        && evidence.replayDisposition == ContinuousBatchSettlementDisposition.nonSettlingReplay.rawValue
        && evidence.tokensMatch
}

func msbDrainPass(_ evidence: MSBDrainEvidence) -> Bool {
    evidence.queuedRejected
        && evidence.permitIssued
        && evidence.permitValid
        && evidence.postDrainRejected
        && evidence.activeRowsCompleted
        && evidence.activeStatuses.allSatisfy({ $0 == ContinuousBatchSchedulerTerminalStatus.length.rawValue })
        && evidence.activeSettlements.allSatisfy({ $0 == ContinuousBatchSettlementDisposition.eligibleOwner.rawValue })
}

func msbOMLXSidecarUnavailableReason() -> String {
    "no pinned oMLX v0.4.4 BatchGenerator sidecar on this host; MSB-05 Q2 is not measured"
}
