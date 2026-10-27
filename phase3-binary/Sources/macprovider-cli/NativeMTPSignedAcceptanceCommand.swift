import ArgumentParser
import CoreFoundation
import CryptoKit
import Foundation
import MacProviderCore

struct NativeMTPSignedAcceptanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "acceptance", shouldDisplay: false)
    @Option var root: String
    @Option var modelID: String = "zai-org/glm-5.3-flash"
    @Option var qualifiedSlots: Int = 4
    @Option var maxNativeActiveRows: Int = 1
    @Option var maxPromptTokens: Int = 4096
    @Option var acceptanceCorpus: String
    @Option var acceptancePolicy: String
    @Option var providerCommit: String
    @Option var acceptanceCheckpoint: String?
    @Flag var validateAcceptanceOnly = false
    @Option var identityCache: String?

    func run() async throws {
        try await NativeMTPQualificationScope.run {
            let corpus = try NativeMTPAcceptanceCorpus.load(from: URL(fileURLWithPath: ConfigLoader.expandTilde(acceptanceCorpus)))
            let policy = try NativeMTPAcceptancePolicy.load(from: URL(fileURLWithPath: ConfigLoader.expandTilde(acceptancePolicy)))
            guard corpus.modelID == modelID, corpus.qualifiedSlots == qualifiedSlots,
                  corpus.maxNativeActiveRows == maxNativeActiveRows, corpus.maxPromptTokens == maxPromptTokens,
                  validateAcceptanceOnly == (identityCache != nil) else { throw ValidationError("signed acceptance tuple/preflight differs") }
            let target = URL(fileURLWithPath: ConfigLoader.expandTilde(root)).appendingPathComponent("target")
            let cache = NativeMTPBenchIdentityCache(persistentURL: identityCache.map { URL(fileURLWithPath: ConfigLoader.expandTilde($0)) })
            let identity = try cache.identity(directory: target)
            let tokenizerSHA = SHA256.hash(data: try Data(contentsOf: target.appendingPathComponent("tokenizer.json"))).map { String(format: "%02x", $0) }.joined()
            let environment = NativeMTPBenchEnvironment.capture(providerCommit: providerCommit)
            try policy.validate(corpus: corpus, environment: environment, targetSHA256: identity.digest, mtpSHA256: identity.digest, tokenizerSHA256: tokenizerSHA)
            if validateAcceptanceOnly {
                let data = try JSONSerialization.data(withJSONObject: NativeMTPQualificationScope.bind(["validate_only": "pass", "corpus_sha256": corpus.digestSHA256, "policy_sha256": policy.digestSHA256]), options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data("\n".utf8))
                return
            }
            guard ProcessInfo.processInfo.environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else { throw ValidationError("explicit isolated hardware qualification opt-in required") }
            try NativeMTPHardwareE2ERunner.requireStudioHost()
            NativeMTPHardwareE2ERunner.applyServeProcessSetup(rootPath: root)
            let runner = NativeMTPHardwareE2ERunner(rootPath: root, modelID: modelID, maxBatch: qualifiedSlots,
                maxNativeActiveRows: maxNativeActiveRows, proposalDepth: corpus.proposalDepth,
                maxPromptTokens: maxPromptTokens, maxPhysicalBlocks: NativeMTPHardwareE2ERunner.sizedMaxPhysicalBlocks(slots: qualifiedSlots, promptTokens: 8_960, outputTokens: 512))
            let recorder = NativeMTPHardwareAdmissionRecorder()
            let fixture = try await runner.loadRuntimeFixture(maxContextTokens: 8_960, knownTargetIdentity: identity,
                ordinaryAdmissionRecorder: nil, nativeAdmissionRecorder: recorder)
            let result = try await NativeMTPSignedAcceptanceRunner(acceptancePolicy: policy, acceptanceCheckpointPath: acceptanceCheckpoint)
                .runAcceptanceCorpus(corpus, ordinary: fixture.runtimes.ordinary, native: fixture.runtimes.native, recorder: recorder)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result.document, options: [.sortedKeys]) + Data("\n".utf8))
            if !result.passed { throw ExitCode(1) }
        }
    }
}

private struct NativeMTPSignedAcceptanceRunner {
    let acceptancePolicy: NativeMTPAcceptancePolicy?
    let acceptanceCheckpointPath: String?
    func runAcceptanceCorpus(
        _ corpus: NativeMTPAcceptanceCorpus,
        ordinary: ModelRuntime,
        native: ModelRuntime,
        recorder: NativeMTPHardwareAdmissionRecorder
    ) async throws -> (document: [String: Any], passed: Bool) {
        let oracle = NativeMTPLabNumericalOracle()
        guard await ordinary.installLabNativeMTPNumericalOracle(oracle, role: .ordinary),
              await native.installLabNativeMTPNumericalOracle(oracle, role: .native) else {
            _ = await ordinary.installLabNativeMTPNumericalOracle(nil, role: .ordinary)
            _ = await native.installLabNativeMTPNumericalOracle(nil, role: .native)
            throw NativeMTPHardwareE2EError.assertionFailed("acceptance oracle requires attached schedulers")
        }
        let checkpoint = try acceptanceCheckpointPath.map {
            try SignedAcceptanceCheckpoint(path: $0, policy: acceptancePolicy, corpus: corpus)
        }
        var records = checkpoint?.records ?? []
        var positions = 0
        var accepted: UInt64 = 0
        var rejected: UInt64 = 0
        var terminals = Set<String>()
        var toolBoundary = false
        var reasoningClose = false
        var nearTiedPositions = 0
        for row in records {
            guard let observed = row["checkpoint_observations"] as? [String: Any] else { throw ValidationError("missing checkpoint observations") }
            if row["expected_native"] as? Bool == true {
                let values = row["positions"] as! [[String: Any]]
                positions += values.count
                let addedAccepted = accepted.addingReportingOverflow((observed["accepted"] as! NSNumber).uint64Value)
                let addedRejected = rejected.addingReportingOverflow((observed["rejected"] as! NSNumber).uint64Value)
                guard !addedAccepted.overflow, !addedRejected.overflow,
                      !addedAccepted.partialValue.addingReportingOverflow(addedRejected.partialValue).overflow else {
                    throw ValidationError("checkpoint aggregate counter overflow")
                }
                accepted = addedAccepted.partialValue
                rejected = addedRejected.partialValue
                terminals.insert(row["native_terminal"] as! String)
                toolBoundary = toolBoundary || (observed["tool_call_count"] as! Int) > 0
                reasoningClose = reasoningClose || (observed["reasoning_nonempty"] as! Bool && (observed["content_nonempty"] as! Bool || (observed["tool_call_count"] as! Int) > 0))
                nearTiedPositions += values.filter { ($0["ordinary_gap"] as! Double) <= 0.05 }.count
            }
        }
        for item in corpus.cases.dropFirst(records.count) {
            do {
                guard item.request.conversationKey == nil else { throw ValidationError("checkpoint run requires request-local no-cache requests") }
                try oracle.beginPair(requestID: item.id, maxPositions: item.request.maxTokens ?? 256)
                let expected = try await ordinary.complete(item.request)
                let before = await native.currentSnapshot().nativeMTPStatus
                let actual = try await native.complete(item.request)
                let delta = NativeMTPStatusDelta(before: before, after: await native.currentSnapshot().nativeMTPStatus)
                let comparison = oracle.summary()
                let promptShape = NativeMTPAcceptanceCorpusBuilder.contains(expected.promptTokens, stratum: item.stratum)
                let path = lastPath(recorder, item.id)
                let admission = item.expectedNative ? path == .nativeMTP && delta.proposedTokens > 0 : path == .ordinary && delta.proposedTokens == 0
                let outputParity = same(expected, actual)
                let passed = promptShape && admission && outputParity && comparison.passed && comparison.retainedVectors == 0
                let positionRecords = comparison.positions.map(Self.acceptancePositionDocument)
                records.append([
                    "id": item.id, "stratum": item.stratum.rawValue,
                    "expected_native": item.expectedNative, "passed": passed,
                    "prompt_tokens": expected.promptTokens, "prompt_stratum_passed": promptShape,
                    "admission_passed": admission, "output_parity": outputParity,
                    "ordinary_terminal": Self.jsonOptional(comparison.ordinaryTerminal?.rawValue),
                    "native_terminal": Self.jsonOptional(comparison.nativeTerminal?.rawValue),
                    "finish_reason": actual.finishReason,
                    "completion_tokens": actual.completionTokens,
                    "generated_completion_tokens": actual.generatedCompletionTokens,
                    "oracle_failure": Self.jsonOptional(comparison.firstFailure?.reason),
                    "positions": positionRecords,
                    "selected_positions": comparison.selectedPositions.map(Self.acceptancePositionDocument),
                    "ordinary_selected_count": comparison.ordinarySelectedCount,
                    "native_selected_count": comparison.nativeSelectedCount,
                    "checkpoint_observations": [
                        "accepted": delta.acceptedTokens, "rejected": delta.rejectedTokens, "proposed": delta.proposedTokens,
                        "decode_path": path?.rawValue ?? "unobserved", "tool_call_count": actual.toolCalls?.count ?? 0,
                        "reasoning_nonempty": actual.reasoningContent?.isEmpty == false, "content_nonempty": !actual.content.isEmpty,
                        "conversation_cache_key_absent": item.request.conversationKey == nil,
                    ],
                ])
                try checkpoint?.persist(records)
                FileHandle.standardError.write(Data("native-mtp-acceptance: case=\(item.id) passed=\(passed) positions=\(comparison.positions.count)\n".utf8))
                // A failed row ends this tuple run. Later positions and cases
                // are never claimed after the first observed divergence.
                guard passed else { break }
                if item.expectedNative {
                    positions += comparison.positions.count
                    accepted += delta.acceptedTokens
                    rejected += delta.rejectedTokens
                    if let terminal = comparison.nativeTerminal { terminals.insert(terminal.rawValue) }
                    toolBoundary = toolBoundary || actual.toolCalls?.isEmpty == false
                    reasoningClose = reasoningClose || (
                        actual.reasoningContent?.isEmpty == false
                        && (!actual.content.isEmpty || actual.toolCalls?.isEmpty == false)
                    )
                    nearTiedPositions += comparison.positions.filter { ($0.ordinaryGap ?? .infinity) <= 0.05 }.count
                }
            } catch {
                records.append(["id": item.id, "passed": false, "error": String(describing: error)])
                try checkpoint?.persist(records)
                break
            }
        }
        _ = await ordinary.installLabNativeMTPNumericalOracle(nil, role: .ordinary)
        _ = await native.installLabNativeMTPNumericalOracle(nil, role: .native)
        let checks: [String: Bool] = [
            "all_cases_passed": records.count == corpus.cases.count && records.allSatisfy { $0["passed"] as? Bool == true },
            "native_positions": positions >= corpus.minimumComparedPositions,
            "all_and_none_acceptance": accepted > 0 && rejected > 0,
            "partial_acceptance_inapplicable": corpus.proposalDepth == 1,
            "eos_terminal": terminals.contains(NativeMTPLabNumericalOracle.Terminal.eos.rawValue),
            "stop_sequence_terminal": terminals.contains(NativeMTPLabNumericalOracle.Terminal.stopSequence.rawValue),
            "max_tokens_terminal": terminals.contains(NativeMTPLabNumericalOracle.Terminal.maxTokens.rawValue),
            "generated_tool_boundary": toolBoundary,
            "generated_reasoning_close": reasoningClose,
            "near_tied_positions": nearTiedPositions > 0,
        ]
        let passed = checks.values.allSatisfy { $0 }
        return ([
            "schema": "macprovider.native-mtp-acceptance-result.v1",
            "status": passed ? "pass" : "fail", "journey_complete": false,
            "evidence_class": "lab_isolated_no_join",
            "measurement_identity": NativeMTPQualificationScope.identity!.document, "corpus_sha256": corpus.digestSHA256,
            "policy_sha256": Self.jsonOptional(acceptancePolicy?.digestSHA256),
            "provider_commit": Self.jsonOptional(acceptancePolicy?.providerCommit),
            "target_sha256": Self.jsonOptional(acceptancePolicy?.targetSHA256),
            "mtp_sha256": Self.jsonOptional(acceptancePolicy?.mtpSHA256),
            "tokenizer_sha256": Self.jsonOptional(acceptancePolicy?.tokenizerSHA256),
            "model_id": corpus.modelID, "max_prompt_tokens": corpus.maxPromptTokens,
            "qualified_slots": corpus.qualifiedSlots, "max_native_active_rows": corpus.maxNativeActiveRows,
            "proposal_depth": corpus.proposalDepth, "native_compared_positions": positions,
            "near_tied_positions": nearTiedPositions, "accepted": accepted, "rejected": rejected,
            "checks": checks, "cases": records,
        ], passed)
    }

    private static func acceptancePositionDocument(_ position: NativeMTPLabNumericalOracle.Position) -> [String: Any] {
        [
            "position": position.position,
            "ordinary_token": position.ordinaryToken,
            "native_token": position.nativeToken,
            "token_exact": position.tokenExact,
            "top1_exact": position.top1Exact,
            "finite": position.finite,
            "max_abs_difference": jsonOptional(position.maxAbsDifference),
            "ordinary_top1": jsonOptional(position.ordinaryTop1),
            "native_top1": jsonOptional(position.nativeTop1),
            "ordinary_gap": jsonOptional(position.ordinaryGap),
            "native_gap": jsonOptional(position.nativeGap),
        ]
    }

    private static func jsonOptional<T>(_ value: T?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private func same(_ lhs: CompletionResult, _ rhs: CompletionResult) -> Bool {
        lhs.content == rhs.content
            && lhs.finishReason == rhs.finishReason
            && lhs.promptTokens == rhs.promptTokens
            && lhs.completionTokens == rhs.completionTokens
            && lhs.generatedCompletionTokens == rhs.generatedCompletionTokens
            && lhs.reasoningContent == rhs.reasoningContent
            && lhs.reasoningTokens == rhs.reasoningTokens
            // IDs are parser-generated UUIDs; compare the model's ordered
            // function/argument output and leave metadata identity alone.
            && (lhs.toolCalls ?? []).count == (rhs.toolCalls ?? []).count
            && zip(lhs.toolCalls ?? [], rhs.toolCalls ?? []).allSatisfy { pair in
                pair.0.functionName == pair.1.functionName && pair.0.arguments == pair.1.arguments
            }
    }

    private func lastPath(_ recorder: NativeMTPHardwareAdmissionRecorder, _ id: String) -> DecodePath? {
        recorder.requestSnapshot().last { $0.requestID == id }?.admission.effectivePath
    }

}

final class SignedAcceptanceCheckpoint {
    let url: URL
    let identity: [String: String]
    var records: [[String: Any]] = []
    init(path: String, policy: NativeMTPAcceptancePolicy?, corpus: NativeMTPAcceptanceCorpus) throws {
        guard let policy else { throw ValidationError("checkpoint requires frozen policy") }
        url = URL(fileURLWithPath: ConfigLoader.expandTilde(path))
        guard let measured = NativeMTPQualificationScope.identity else { throw ValidationError("signed checkpoint requires measured identity") }
        identity = ["binary_sha256": measured.binarySHA256, "binary_cdhash": measured.binaryCDHash, "schema": "macprovider.native-mtp-acceptance-checkpoint.v1", "provider_commit": policy.providerCommit,
                    "policy_sha256": policy.digestSHA256, "corpus_sha256": corpus.digestSHA256]
        guard corpus.cases.allSatisfy({ $0.request.conversationKey == nil }) else { throw ValidationError("checkpoint requests must be request-local with no cache key") }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 64 * 1024 * 1024 else { throw ValidationError("checkpoint file type/permissions/size differ") }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 64 * 1024 * 1024 else { throw ValidationError("checkpoint grew while reading") }
        try AutotuneStrictJSON.rejectDuplicateKeys(bytes)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(identity.keys).union(["cases"]),
              identity.allSatisfy({ object[$0.key] as? String == $0.value }),
              let rows = object["cases"] as? [[String: Any]], rows.count <= corpus.cases.count else { throw ValidationError("checkpoint identity/type/permissions differ") }
        for (row, item) in zip(rows, corpus.cases) {
            guard row["id"] as? String == item.id, row["stratum"] as? String == item.stratum.rawValue,
                  row["expected_native"] as? Bool == item.expectedNative,
                  row["passed"] as? Bool == true, row["prompt_stratum_passed"] as? Bool == true,
                  let promptTokens = row["prompt_tokens"] as? Int, NativeMTPAcceptanceCorpusBuilder.contains(promptTokens, stratum: item.stratum),
                  row["admission_passed"] as? Bool == true, row["output_parity"] as? Bool == true,
                  row["oracle_failure"] is NSNull,
                  let terminal = row["native_terminal"] as? String, row["ordinary_terminal"] as? String == terminal,
                  ["eos", "stopSequence", "maxTokens", "toolBoundary", "other"].contains(terminal),
                  let visible = row["positions"] as? [[String: Any]], let selected = row["selected_positions"] as? [[String: Any]], !selected.isEmpty,
                  visible.count == row["completion_tokens"] as? Int, visible.count <= 256,
                  selected.count == row["ordinary_selected_count"] as? Int, selected.count == row["native_selected_count"] as? Int,
                  let observations = row["checkpoint_observations"] as? [String: Any],
                  observations["conversation_cache_key_absent"] as? Bool == true,
                  observations["decode_path"] as? String == (item.expectedNative ? "native_mtp" : "ordinary") else { throw ValidationError("checkpoint case prefix differs") }
            for values in [visible, selected] {
                for (index, value) in values.enumerated() {
                    guard value["position"] as? Int == index, value["token_exact"] as? Bool == true,
                          value["top1_exact"] as? Bool == true, value["finite"] as? Bool == true,
                          let token = value["ordinary_token"] as? Int, value["native_token"] as? Int == token,
                          let top = value["ordinary_top1"] as? Int, value["native_top1"] as? Int == top else { throw ValidationError("checkpoint token/top1 parity") }
                    for key in ["max_abs_difference", "ordinary_gap", "native_gap"] {
                        guard let n = value[key] as? Double, n.isFinite, n >= 0, key != "max_abs_difference" || n <= 0.05 else { throw ValidationError("checkpoint numeric parity") }
                    }
                }
            }
            guard NSArray(array: Array(selected.prefix(visible.count))).isEqual(to: visible) else { throw ValidationError("checkpoint visible prefix") }
            for key in ["accepted", "rejected", "proposed", "tool_call_count"] {
                guard let n = observations[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      let integer = n as? UInt64, integer <= UInt64(Int64.max),
                      n.doubleValue.isFinite, n.doubleValue >= 0,
                      n.doubleValue.rounded(.towardZero) == n.doubleValue else { throw ValidationError("checkpoint observed counter") }
            }
            guard let accepted = observations["accepted"] as? UInt64, let rejected = observations["rejected"] as? UInt64,
                  let proposed = observations["proposed"] as? UInt64, accepted <= proposed, rejected == proposed - accepted,
                  item.expectedNative ? proposed > 0 : proposed == 0,
                  observations["reasoning_nonempty"] is Bool, observations["content_nonempty"] is Bool else { throw ValidationError("checkpoint aggregate observations") }
        }
        records = rows
    }
    func persist(_ rows: [[String: Any]]) throws {
        var object: [String: Any] = identity; object["cases"] = rows
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".acceptance-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ValidationError("checkpoint create failed") }
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) }
        else { try FileManager.default.moveItem(at: temp, to: url) }
    }
}


