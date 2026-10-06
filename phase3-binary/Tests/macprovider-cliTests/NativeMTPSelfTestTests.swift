import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPSelfTestTests: XCTestCase {
    func testChallengeBankParsesExactRecordAndPassingExecutionEvaluatesTupleOnlyPass() throws {
        let fixture = makeBankFixture()
        let bank = try NativeMTPSelfTest.parseChallengeBank(try jsonData(fixture.bank))
        let record = try NativeMTPSelfTest.selectChallenge(bank, challengeID: "challenge-1")

        XCTAssertEqual(record.challengeID, "challenge-1")
        XCTAssertEqual(record.promptTokenIDs, [101, 102, 103])
        XCTAssertEqual(record.fixedProposalDepth, 2)
        XCTAssertEqual(record.expectedTokenIDs, fixture.outputTokens)

        let result = NativeMTPSelfTestExecutionResult(
            runtimeTuple: fixture.runtimeTuple,
            servedSnapshotGeneration: fixture.servedSnapshot.generation,
            proposalDepth: record.fixedProposalDepth,
            outputTokenIDs: fixture.outputTokens,
            terminalReason: record.expectedTerminalReason,
            counters: record.expectedCounters,
            committedStateDigest: record.expectedCommittedStateDigest,
            actualDecodePath: .nativeMTP,
            fallbackUsed: false
        )
        XCTAssertEqual(
            NativeMTPSelfTest.evaluate(challenge: record, servedSnapshot: fixture.servedSnapshot, result: result),
            NativeMTPSelfTestEvaluation(passed: true, reason: .passed)
        )
    }

    func testParserRejectsUnknownDuplicateWrongTypedAndDigestMismatchFields() throws {
        let fixture = makeBankFixture()
        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(
            try jsonData(mutatingEntry(fixture.bank) { $0["unknown"] = "x" })
        )) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .unknownField("unknown"))
        }

        let duplicated = Data("""
        {"schema_version":"macprovider.native-mtp-challenge-bank.v1","schema_version":"macprovider.native-mtp-challenge-bank.v1","release_id":"r","issued_at":"2020-01-01T00:00:00Z","expires_at":"2099-09-29T00:00:00Z","signer_key_id":"k","entries":[]}
        """.utf8)
        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(duplicated)) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .invalidJSON)
        }

        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(
            try jsonData(mutatingEntry(fixture.bank) { $0["fixed_proposal_depth"] = "2" })
        )) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .missingOrInvalidField("fixed_proposal_depth"))
        }

        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(
            try jsonData(mutatingEntry(fixture.bank) { $0["expected_terminal_reason"] = "stop\n" })
        )) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .missingOrInvalidField("expected_terminal_reason"))
        }

        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(
            try jsonData(mutatingEntry(fixture.bank) { $0["expected_token_id_sha256"] = digest("wrong") })
        )) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .missingOrInvalidField("expected_token_id_sha256"))
        }
    }

    /// The scheduler commits one token fewer than it emits (the first token
    /// comes from the prefill forward). A hardware-measured record (64 tokens,
    /// committed 63, depth 1) must parse; the coordinator applies the same bound.
    func testCommittedCountMatchesTheSchedulerCounting() {
        let cases: [(UInt64, UInt64, UInt64, Bool)] = [
            (64, 63, 1, true), (64, 64, 1, true), (64, 65, 1, false), (64, 62, 1, false),
            (1, 0, 1, true), (0, 0, 1, true), (0, 1, 1, false), (8, 10, 3, true), (8, 11, 3, false),
        ]
        for (tokens, committed, depth, ok) in cases {
            XCTAssertEqual(
                NativeMTPSelfTest.committedCountConsistent(tokens: tokens, committed: committed, depth: depth),
                ok, "tokens=\(tokens) committed=\(committed) depth=\(depth)"
            )
        }
    }

    func testParserRejectsInvalidBankTimeBounds() throws {
        let fixture = makeBankFixture()
        var expired = fixture.bank
        expired["expires_at"] = "2020-01-02T00:00:00Z"
        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(try jsonData(expired))) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .missingOrInvalidField("issued_at"))
        }

        var fractional = fixture.bank
        fractional["issued_at"] = "2020-01-01T00:00:00.000Z"
        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(try jsonData(fractional))) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .missingOrInvalidField("issued_at"))
        }
    }

    func testParserRejectsPromptAndCompletionBounds() throws {
        let fixture = makeBankFixture()
        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(
            try jsonData(mutatingEntry(fixture.bank) {
                $0["prompt_token_ids"] = Array(repeating: 1, count: NativeMTPSelfTestChallenge.maxPromptTokens + 1)
            })
        )) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .missingOrInvalidField("prompt_token_ids"))
        }

        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(
            try jsonData(mutatingEntry(fixture.bank) {
                $0["max_completion_tokens"] = NativeMTPSelfTestChallenge.maxCompletionTokens + 1
            })
        )) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .missingOrInvalidField("max_completion_tokens"))
        }

        XCTAssertThrowsError(try NativeMTPSelfTest.parseChallengeBank(
            try jsonData(mutatingEntry(fixture.bank) {
                $0["fixed_proposal_depth"] = NativeMTPSelfTestChallenge.maxProposalDepth + 1
            })
        )) { error in
            XCTAssertEqual(error as? NativeMTPSelfTestError, .missingOrInvalidField("fixed_proposal_depth"))
        }
    }

    func testEvaluatorRejectsEachRuntimeMismatch() throws {
        let fixture = makeBankFixture()
        let record = try NativeMTPSelfTest.parseChallengeBank(try jsonData(fixture.bank)).entries[0]
        let base = NativeMTPSelfTestExecutionResult(
            runtimeTuple: fixture.runtimeTuple,
            servedSnapshotGeneration: fixture.servedSnapshot.generation,
            proposalDepth: record.fixedProposalDepth,
            outputTokenIDs: fixture.outputTokens,
            terminalReason: record.expectedTerminalReason,
            counters: record.expectedCounters,
            committedStateDigest: record.expectedCommittedStateDigest,
            actualDecodePath: .nativeMTP,
            fallbackUsed: false
        )

        assertReason(.tupleMismatch, record, fixture.servedSnapshot, base.with(runtimeTuple: alteredTuple(fixture.runtimeTuple)))
        assertReason(.generationMismatch, record, fixture.servedSnapshot, base.with(servedSnapshotGeneration: fixture.servedSnapshot.generation + 1))
        assertReason(.proposalDepthMismatch, record, fixture.servedSnapshot, base.with(proposalDepth: record.fixedProposalDepth + 1))
        assertReason(.decodePathMismatch, record, fixture.servedSnapshot, base.with(actualDecodePath: .ordinary))
        assertReason(.fallbackUsed, record, fixture.servedSnapshot, base.with(fallbackUsed: true))
        assertReason(.outputDigestMismatch, record, fixture.servedSnapshot, base.with(outputTokenIDs: [999]))
        assertReason(.terminalReasonMismatch, record, fixture.servedSnapshot, base.with(terminalReason: "length"))
        assertReason(.counterMismatch, record, fixture.servedSnapshot, base.with(counters: NativeMTPSelfTestCounters(
            acceptedTokens: 0,
            rejectedTokens: 0,
            bonusTokens: 0,
            committedTokens: 0
        )))
        assertReason(.committedStateMismatch, record, fixture.servedSnapshot, base.with(committedStateDigest: digest("other-state")))
    }

    func testRunnerValidateGroundsReceiptInSelectedBankRecordAndServedSnapshot() async throws {
        let fixture = makeBankFixture()
        let record = try NativeMTPSelfTest.parseChallengeBank(try jsonData(fixture.bank)).entries[0]
        let input = makeInput(fixture: fixture, record: record)
        let receipt = makeReceipt(input: input, challenge: record, servedSnapshot: fixture.servedSnapshot, outputTokens: fixture.outputTokens)
        let runner = NativeMTPSelfTestRunner { received in
            XCTAssertEqual(received.selectedChallenge?.challengeID, record.challengeID)
            return receipt
        }

        let validated = try await runner.validate(input)
        XCTAssertEqual(validated, receipt)
    }

    func testRunnerValidateFailsClosedOnUngroundedOrMismatchedReceipt() async throws {
        let fixture = makeBankFixture()
        let record = try NativeMTPSelfTest.parseChallengeBank(try jsonData(fixture.bank)).entries[0]
        let input = makeInput(fixture: fixture, record: record)
        let receipt = makeReceipt(input: input, challenge: record, servedSnapshot: fixture.servedSnapshot, outputTokens: fixture.outputTokens)

        let noChallenge = NativeMTPSelfTestInput(
            tupleSHA256: input.tupleSHA256,
            modelID: input.modelID,
            modelRevision: input.modelRevision,
            familyAdapter: input.familyAdapter,
            proposalDepth: input.proposalDepth,
            challengeBank: input.challengeBank,
            servedSnapshot: input.servedSnapshot
        )
        try await assertValidateFailure(.failed("missing_challenge_record"), input: noChallenge, receipt: receipt)
        try await assertValidateFailure(
            .failed("expected_output_token_digest_mismatch"),
            input: input,
            receipt: makeReceipt(input: input, challenge: record, servedSnapshot: fixture.servedSnapshot, outputTokens: [999])
        )
        try await assertValidateFailure(
            .failed("terminal_reason_mismatch"),
            input: input,
            receipt: makeReceipt(input: input, challenge: record, servedSnapshot: fixture.servedSnapshot, outputTokens: fixture.outputTokens, terminalReason: .length)
        )
        try await assertValidateFailure(
            .failed("counter_mismatch"),
            input: input,
            receipt: makeReceipt(input: input, challenge: record, servedSnapshot: fixture.servedSnapshot, outputTokens: fixture.outputTokens, committedTokens: 2)
        )
        try await assertValidateFailure(
            .failed("committed_state_digest_mismatch"),
            input: input,
            receipt: makeReceipt(input: input, challenge: record, servedSnapshot: fixture.servedSnapshot, outputTokens: fixture.outputTokens, committedStateDigest: digest("wrong"))
        )
        try await assertValidateFailure(
            .failed("decode_path_mismatch"),
            input: input,
            receipt: makeReceipt(input: input, challenge: record, servedSnapshot: fixture.servedSnapshot, outputTokens: fixture.outputTokens, actualDecodePath: .ordinary)
        )
        try await assertValidateFailure(
            .failed("fallback_used"),
            input: input,
            receipt: makeReceipt(input: input, challenge: record, servedSnapshot: fixture.servedSnapshot, outputTokens: fixture.outputTokens, fallbackUsed: true)
        )
    }

    private func assertReason(
        _ reason: NativeMTPSelfTestEvaluation.Reason,
        _ challenge: NativeMTPSelfTestChallenge,
        _ servedSnapshot: NativeMTPSelfTestServedSnapshot,
        _ result: NativeMTPSelfTestExecutionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            NativeMTPSelfTest.evaluate(challenge: challenge, servedSnapshot: servedSnapshot, result: result),
            NativeMTPSelfTestEvaluation(passed: false, reason: reason),
            file: file,
            line: line
        )
    }

    private func assertValidateFailure(
        _ expected: NativeMTPSelfTestError,
        input: NativeMTPSelfTestInput,
        receipt: NativeMTPSelfTestReceipt,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let runner = NativeMTPSelfTestRunner { _ in receipt }
        do {
            _ = try await runner.validate(input)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? NativeMTPSelfTestError, expected, file: file, line: line)
        }
    }

    private struct BankFixture {
        let bank: [String: Any]
        let runtimeTuple: NativeMTPSelfTestRuntimeTuple
        let servedSnapshot: NativeMTPSelfTestServedSnapshot
        let tupleSHA256: String
        let outputTokens: [Int]
    }

    private func makeBankFixture() -> BankFixture {
        let outputTokens = [201, 202, 203]
        let tuple = NativeMTPSelfTestRuntimeTuple(
            modelID: "qwen-fixture",
            modelHash: digest("model"),
            modelHashAlgorithm: "sha256",
            tokenizerDigest: digest("tokenizer"),
            artifactDigest: digest("artifact"),
            manifestDigest: digest("manifest"),
            sidecarDigest: digest("sidecar"),
            providerBinarySHA256: digest("provider"),
            runtimeCDHash: digest("cdhash"),
            cacheNamespace: "native-mtp-fixture",
            stateDigest: digest("state"),
            proposalDepth: 2
        )
        let tupleSHA256 = (try? NativeMTPSelfTest.runtimeTupleDigest(tuple)) ?? digest("tuple")
        let bank: [String: Any] = [
            "schema_version": NativeMTPSelfTestChallenge.bankSchemaVersion,
            "release_id": "native-mtp-selftest-fixture",
            "issued_at": "2020-01-01T00:00:00Z",
            "expires_at": "2099-09-29T00:00:00Z",
            "signer_key_id": "native-mtp-selftest-release",
            "entries": [[
                "challenge_id": "challenge-1",
                "model_id": tuple.modelID,
                "model_hash": tuple.modelHash,
                "tokenizer_sha256": tuple.tokenizerDigest,
                "artifact_sha256": tuple.artifactDigest,
                "mtp_manifest_sha256": tuple.manifestDigest,
                "prompt_token_ids": [101, 102, 103],
                "max_completion_tokens": 4,
                "fixed_proposal_depth": 2,
                "expected_token_ids": outputTokens,
                "expected_token_id_sha256": NativeMTPSelfTest.tokenDigest(outputTokens),
                "expected_terminal_reason": "stop",
                "expected_counters": [
                    "accepted": 2,
                    "rejected": 1,
                    "bonus": 1,
                    "committed": 3,
                ],
                "expected_committed_state_sha256": digest("committed"),
            ]],
        ]
        return BankFixture(
            bank: bank,
            runtimeTuple: tuple,
            servedSnapshot: NativeMTPSelfTestServedSnapshot(
                tupleSHA256: tupleSHA256,
                runtimeTuple: tuple,
                generation: 9,
                proposalDepth: 2
            ),
            tupleSHA256: tupleSHA256,
            outputTokens: outputTokens
        )
    }

    private func makeInput(
        fixture: BankFixture,
        record: NativeMTPSelfTestChallenge
    ) -> NativeMTPSelfTestInput {
        NativeMTPSelfTestInput(
            tupleSHA256: fixture.tupleSHA256,
            modelID: record.modelID,
            modelRevision: "fixture-revision",
            familyAdapter: "qwen35",
            proposalDepth: record.fixedProposalDepth,
            challengeBank: NativeMTPSelfTestChallengeBank(
                releaseID: "native-mtp-selftest-fixture",
                challengeBankPath: "native-mtp-selftest-bank.json",
                challengeBankSHA256: digest("bank"),
                signaturePath: "native-mtp-selftest-bank.json.sig",
                signerKeyID: "native-mtp-selftest-release",
                signatureSHA256: digest("bank-signature")
            ),
            selectedChallenge: record,
            servedSnapshot: fixture.servedSnapshot
        )
    }

    private func makeReceipt(
        input: NativeMTPSelfTestInput,
        challenge: NativeMTPSelfTestChallenge,
        servedSnapshot: NativeMTPSelfTestServedSnapshot,
        outputTokens: [Int],
        terminalReason: ContinuousBatchSchedulerTerminalStatus = .stop,
        committedTokens: Int = 3,
        committedStateDigest: String? = nil,
        actualDecodePath: NativeMTPSelfTestExecutionResult.DecodePath = .nativeMTP,
        fallbackUsed: Bool = false
    ) -> NativeMTPSelfTestReceipt {
        NativeMTPSelfTestReceipt(
            version: NativeMTPSelfTestRunner.capability,
            tupleSHA256: input.tupleSHA256,
            challengeID: challenge.challengeID,
            challengeBankSHA256: input.challengeBank.challengeBankSHA256,
            servedSnapshotGeneration: servedSnapshot.generation,
            proposalDepth: challenge.fixedProposalDepth,
            maxCompletionTokens: challenge.maxCompletionTokens,
            promptTokenIDs: challenge.promptTokenIDs,
            generatedTokenIDs: outputTokens,
            terminalReason: terminalReason,
            acceptedTokens: Int(challenge.expectedCounters.acceptedTokens),
            rejectedTokens: Int(challenge.expectedCounters.rejectedTokens),
            bonusTokens: Int(challenge.expectedCounters.bonusTokens),
            committedTokens: committedTokens,
            committedStateDigestSHA256: committedStateDigest ?? challenge.expectedCommittedStateDigest,
            actualDecodePath: actualDecodePath,
            fallbackUsed: fallbackUsed
        )
    }

    private func mutatingEntry(_ bank: [String: Any], _ mutate: (inout [String: Any]) -> Void) -> [String: Any] {
        var copy = bank
        var entries = copy["entries"] as! [[String: Any]]
        mutate(&entries[0])
        copy["entries"] = entries
        return copy
    }

    private func alteredTuple(_ tuple: NativeMTPSelfTestRuntimeTuple) -> NativeMTPSelfTestRuntimeTuple {
        NativeMTPSelfTestRuntimeTuple(
            modelID: tuple.modelID + "-other",
            modelHash: tuple.modelHash,
            modelHashAlgorithm: tuple.modelHashAlgorithm,
            tokenizerDigest: tuple.tokenizerDigest,
            artifactDigest: tuple.artifactDigest,
            manifestDigest: tuple.manifestDigest,
            sidecarDigest: tuple.sidecarDigest,
            providerBinarySHA256: tuple.providerBinarySHA256,
            runtimeCDHash: tuple.runtimeCDHash,
            cacheNamespace: tuple.cacheNamespace,
            stateDigest: tuple.stateDigest,
            proposalDepth: tuple.proposalDepth
        )
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private extension NativeMTPSelfTestExecutionResult {
    func with(
        runtimeTuple: NativeMTPSelfTestRuntimeTuple? = nil,
        servedSnapshotGeneration: UInt64? = nil,
        proposalDepth: Int? = nil,
        outputTokenIDs: [Int]? = nil,
        terminalReason: String? = nil,
        counters: NativeMTPSelfTestCounters? = nil,
        committedStateDigest: String? = nil,
        actualDecodePath: DecodePath? = nil,
        fallbackUsed: Bool? = nil
    ) -> NativeMTPSelfTestExecutionResult {
        NativeMTPSelfTestExecutionResult(
            runtimeTuple: runtimeTuple ?? self.runtimeTuple,
            servedSnapshotGeneration: servedSnapshotGeneration ?? self.servedSnapshotGeneration,
            proposalDepth: proposalDepth ?? self.proposalDepth,
            outputTokenIDs: outputTokenIDs ?? self.outputTokenIDs,
            terminalReason: terminalReason ?? self.terminalReason,
            counters: counters ?? self.counters,
            committedStateDigest: committedStateDigest ?? self.committedStateDigest,
            actualDecodePath: actualDecodePath ?? self.actualDecodePath,
            fallbackUsed: fallbackUsed ?? self.fallbackUsed
        )
    }
}
