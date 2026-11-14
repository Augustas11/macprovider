import ArgumentParser
import CryptoKit
import Foundation

/// Scheduler throughput spans delivered first token through completed submit,
/// including scheduler work and any later row's overlapping prefill.
struct MSBSchedulerRowTiming: Sendable {
    let submittedAt: Date
    let firstTokenAt: Date
    let completedAt: Date

    var ttftSeconds: Double { firstTokenAt.timeIntervalSince(submittedAt) }

    func throughputSample(outputTokens: Int) throws -> MSBAggregateThroughputInput {
        guard outputTokens > 0, firstTokenAt >= submittedAt, completedAt > firstTokenAt else {
            throw MSBAggregateThroughputError.invalidSample
        }
        return MSBAggregateThroughputInput(
            decodedTokens: outputTokens - 1,
            decodeStartedAt: firstTokenAt,
            decodeEndedAt: completedAt
        )
    }

    /// The row from its arrival to its last token, so that
    /// `msbAggregateThroughput` over every row is decoded tokens over the
    /// cohort's makespan (MSB-03, SPEC-038 FR-CB14 v0.3.37).
    func makespanSample(outputTokens: Int) throws -> MSBAggregateThroughputInput {
        guard outputTokens > 0, completedAt > submittedAt else {
            throw MSBAggregateThroughputError.invalidSample
        }
        return MSBAggregateThroughputInput(
            decodedTokens: outputTokens - 1,
            decodeStartedAt: submittedAt,
            decodeEndedAt: completedAt
        )
    }
}

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
    case raggedPrefill = "ragged-prefill"
    case hybridWindow = "hybrid-window"
}

/// `--scenario hybrid-window`: SPEC-038 FR-CB2 hybrid decode-window proof on
/// a fixed greedy batch. `pass` requires window 1 to repeat itself exactly
/// and every row's candidate-window tokens to equal its window-1 tokens.
struct MSBHybridWindowReport: Codable, Sendable {
    let schemaVersion: Int
    let modelID: String
    let modelTag: String
    let mlxSwiftLMPin: String
    let scenario: String
    let rows: Int
    let promptTokenLengths: [Int]
    let promptChunkTokens: Int
    let decodeTokensPerRow: Int
    let blockSizeTokens: Int
    let maxPhysicalBlocks: Int
    let runs: Int
    let referenceWindow: Int
    let candidateWindow: Int
    let referenceWindowCalls: Int
    let candidateWindowCalls: Int
    let referenceRepeatsExactly: Bool
    let rowMatches: [Bool]
    let firstDivergenceIndex: [Int?]
    let referenceTokenSHA256: [String]
    let referenceAggregateTPSRuns: [Double]
    let candidateAggregateTPSRuns: [Double]
    let referenceAggregateTPSp50: Double
    let candidateAggregateTPSp50: Double
    let candidateSpeedup: Double
    let peakRSSMB: Int
    let promptTokenSHA256: [String]
    let timestamp: String
    let pass: Bool
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

struct MSBParityRowEvidence: Codable, Sendable, Equatable {
    let serialTokenCount: Int
    let standaloneTokenCount: Int
    let batchedTokenCount: Int
    let serialTokenSHA256: String
    let standaloneTokenSHA256: String
    let batchedTokenSHA256: String
    /// `--prompt-token-file` only: the prompt's name and the compared tokens,
    /// so an external reference (mlx-vlm) can be checked token by token.
    var name: String? = nil
    var serialTokens: [Int]? = nil
    var standaloneTokens: [Int]? = nil
    var batchedTokens: [Int]? = nil
}

/// `msb-throughput --prompt-token-file`: fixed prompt token ids per row.
struct MSBPromptTokenSet: Decodable, Sendable, Equatable {
    struct Prompt: Decodable, Sendable, Equatable {
        let name: String
        let ids: [Int]
    }

    let prompts: [Prompt]
}

struct MSBParityEvidence: Codable, Sendable, Equatable {
    let comparedTokens: Int
    let oneRowMatch: Bool
    let standaloneRowMatches: [Bool]?
    let batchedRowMatches: [Bool]
    let firstDivergenceIndex: Int?
    let serialTokenSHA256: String
    let batchedTokenSHA256: String
    // Optional so archived reports still decode; absent rows are not new proof.
    let rows: [MSBParityRowEvidence]?
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
    /// Decode-interval aggregate (earliest first token to latest last token)
    /// over the short prompt's serial decode rate. Reported for history;
    /// not a gate since SPEC-038 v0.3.37.
    let aggregateVsSerial: Double
    /// The gating aggregate: decoded tokens over the makespan, from the
    /// first request's arrival to the last row's last token.
    let makespanAggregateTokensPerSecond: Double
    /// The same requests served one after another on the production serial
    /// path: decoded tokens over that whole back-to-back interval.
    let serialMakespanAggregateTokensPerSecond: Double
    let makespanVsSerial: Double
    let shortRequestSerialTTFTp95: Double
    let shortRequestBatchedTTFTp95: Double
    let shortRequestTTFTRatio: Double
    let aggregatePass: Bool
    let ttftPass: Bool
    let pass: Bool
    /// How the backend prefills a group (SPEC-038 v0.3.52 FR-CB14).
    let prefillKind: MSB03PrefillKind
    /// The makespan ratio `aggregatePass` must exceed for that backend.
    let makespanBar: Double
}

/// SPEC-038 v0.3.52 FR-CB14: `perRow` when the backend's flattened prefill
/// cap is below any two-row group of the run's chunks, so every grouped row
/// prefills in its own forward and batching cannot shorten prefill.
enum MSB03PrefillKind: String, Codable, Sendable, Equatable {
    case perRow = "per_row"
    case shared
}

func msb03PrefillKind(prefillForwardTokenCap: Int?, promptChunkTokens: Int) -> MSB03PrefillKind {
    guard let cap = prefillForwardTokenCap else { return .shared }
    let (tokens, overflow) = max(1, promptChunkTokens).multipliedReportingOverflow(by: 2)
    return overflow || tokens > cap ? .perRow : .shared
}

/// Batching must not lose on a per-row-prefill backend; a backend that shares
/// the prefill forward keeps the above-1.2x bar.
func msb03MakespanBar(prefill: MSB03PrefillKind) -> Double {
    prefill == .perRow ? 1.0 : 1.2
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

/// MSB-03 aggregate gate. Since SPEC-038 v0.3.37 the ratio is the makespan
/// aggregate against the serial makespan aggregate (`msb03MakespanVsSerial`);
/// since v0.3.52 the bar depends on the backend's prefill kind.
func msb03AggregatePass(aggregateVsSerial: Double, prefill: MSB03PrefillKind = .shared) -> Bool {
    aggregateVsSerial > msb03MakespanBar(prefill: prefill)
}

/// Batched makespan aggregate over serial makespan aggregate. With the same
/// decoded tokens on both sides this is the serial makespan over the batched
/// one: serving the short request sooner cannot lower it, a longer batched
/// makespan always does. A serial run with no decoded tokens gives 0, which
/// fails the gate (as `runMSB03` does for its percentile ratio).
func msb03MakespanVsSerial(
    batched: [MSBAggregateThroughputInput],
    serial: [MSBAggregateThroughputInput]
) throws -> (batched: MSBAggregateThroughputReport, serial: MSBAggregateThroughputReport, ratio: Double) {
    let batchedReport = try msbAggregateThroughput(batched)
    let serialReport = try msbAggregateThroughput(serial)
    return (
        batchedReport,
        serialReport,
        serialReport.aggregateTokensPerSecond > 0
            ? batchedReport.aggregateTokensPerSecond / serialReport.aggregateTokensPerSecond
            : 0
    )
}

func msb03ShortRequestTTFTPass(ratio: Double) -> Bool {
    ratio > 0 && ratio <= 2.0
}

func msbTemp0ParityMatch(serial: [Int], batched: [Int], comparedTokens: Int) -> (match: Bool, firstDivergence: Int?) {
    guard comparedTokens > 0 else { return (false, 0) }
    let count = min(comparedTokens, serial.count, batched.count)
    for index in 0..<count {
        if serial[index] != batched[index] {
            return (false, index)
        }
    }
    // A matching short prefix does not prove the requested output window.
    // Report the first missing token after preserving any earlier mismatch.
    guard count == comparedTokens else { return (false, count) }
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

/// Completion tokens one msb03 row is asked for and billed: the prefill's
/// sampled token plus `decodeTokens` timed decode steps (the scheduler run's
/// `maxOutputTokens`, and the serial run's `maxTokens`).
func msb03ExpectedCompletionTokens(decodeTokens: Int) -> Int {
    decodeTokens + 1
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
