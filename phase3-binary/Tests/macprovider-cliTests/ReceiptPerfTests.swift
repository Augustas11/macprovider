import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class ReceiptPerfTests: XCTestCase {
    func testReceiptConstructionP95IsUnderFiveMillisecondsFor1024TokenPayload() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: PerfReceiptKeyStore(key: key))
        let request = try parseRequest([
            "model": "fixture-model",
            "messages": [["role": "user", "content": "Summarize the benchmark payload."]],
            "temperature": 0,
        ])
        let payload = Array(repeating: "token", count: 1_024).joined(separator: " ")
        let input = ReceiptInput(
            modelId: "fixture-model",
            request: request,
            outputContent: payload,
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 12,
            tokensOut: 1_024,
            unixTsSeconds: 1_800_000_000
        )

        for _ in 0..<25 {
            _ = try RouterHandler.receiptHeader(
                providerID: nil,
                receiptBuilder: nil,
                request: request,
                outputContent: payload,
                outputToolCalls: nil,
                finishReason: "stop",
                ttftMs: 12,
                tokensOut: 1_024,
                unixTsSeconds: 1_800_000_000
            )
            _ = try builder.build(providerId: "provider-a", input: input)
        }

        let disabledP95 = try measureP95(iterations: 1_000) {
            _ = try RouterHandler.receiptHeader(
                providerID: nil,
                receiptBuilder: nil,
                request: request,
                outputContent: payload,
                outputToolCalls: nil,
                finishReason: "stop",
                ttftMs: 12,
                tokensOut: 1_024,
                unixTsSeconds: 1_800_000_000
            )
        }
        let enabledP95 = try measureP95(iterations: 1_000) {
            _ = try RouterHandler.receiptHeader(
                providerID: "provider-a",
                receiptBuilder: builder,
                request: request,
                outputContent: payload,
                outputToolCalls: nil,
                finishReason: "stop",
                ttftMs: 12,
                tokensOut: 1_024,
                unixTsSeconds: 1_800_000_000
            )
        }
        let deltaP95 = max(0, enabledP95 - disabledP95)
#if arch(arm64)
        XCTAssertLessThan(deltaP95, 5.0, "receipt path p95 delta=\(deltaP95)ms enabled=\(enabledP95)ms disabled=\(disabledP95)ms exceeds SPEC-015 AC-16 5ms limit")
#else
        throw XCTSkip("SPEC-015 AC-16 perf assertion is Apple Silicon/arm64-only; measured delta=\(deltaP95)ms enabled=\(enabledP95)ms disabled=\(disabledP95)ms")
#endif
    }
}

private func measureP95(iterations: Int, _ body: () throws -> Void) throws -> Double {
    var durations: [Double] = []
    durations.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        let end = DispatchTime.now().uptimeNanoseconds
        durations.append(Double(end - start) / 1_000_000.0)
    }
    durations.sort()
    return durations[Int((Double(durations.count) * 0.95).rounded(.up)) - 1]
}

private final class PerfReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey

    init(key: Curve25519.Signing.PrivateKey) {
        self.key = key
    }

    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey { key }
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? { key }
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}
