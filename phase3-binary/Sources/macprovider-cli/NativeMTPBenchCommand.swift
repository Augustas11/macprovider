import ArgumentParser
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import MLXLMCommon

// Measurement helpers are shared with isolated signed qualification.
// Legacy top-level command registration remains LAB-only.
struct NativeMTPBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "native-mtp-bench",
        abstract: "Run the hidden SPEC-048-R015 native MTP throughput bench.",
        shouldDisplay: false
    )

    @Option(name: .customLong("root"), help: "Fixture root containing target/ (and mtp/ unless the target embeds its MTP layer).")
    var root: String

    @Option(name: .customLong("model-id"), help: "Model ID bound into requests/runtime.")
    var modelID: String = nativeMTPHardwareDefaultModelID

    @Option(name: .customLong("policy"), help: "Frozen preregistration policy JSON.")
    var policyPath: String?

    @Option(name: .customLong("policy-list"), parsing: .upToNextOption, help: "Exploratory policy files run sequentially in this process; outputs are --out.policy-N.jsonl.")
    var policyList: [String] = []

    @Option(name: .customLong("out"), help: "Output JSONL path.")
    var outPath: String

    @Option(name: .customLong("requests"), help: "Frozen DeepSeek DSpark natural requests JSON; runs native scheduler token probes, separate from R015 qualification.")
    var requestsPath: String?

    @Option(name: .customLong("requests-sha256"), help: "Required frozen requests file SHA-256 when --requests is used.")
    var requestsSHA256: String?

    @Option(name: .customLong("long-token-ids"), help: "Optional JSON object with 8192/32768 prompt-token arrays exported from the existing oracles.")
    var longTokenIDsPath: String?

    @Option(name: .customLong("only-cell"), help: "Optional cell id for resumable matrix runs.")
    var onlyCell: String?

    @Option(name: .customLong("provider-commit"), help: "Provider git commit for the header.")
    var providerCommit: String

    @Option(
        name: .customLong("phase"),
        help: "all (default): matrix cells then the sustained window; matrix: matrix cells only; sustained: the sustained window only, reusing the matrix records already in --out."
    )
    var phase: NativeMTPBenchPhase = .all

    @Flag(
        name: .customLong("validate-only"),
        help: "Check the fixture layout, identities, frozen policy, environment and --out, then exit without loading the model."
    )
    var validateOnly = false

    @Flag(
        name: .customLong("validate-policy-only"),
        help: "--validate-only without any MLX/Metal use, safe beside a serving provider. Requires --identity-cache."
    )
    var validatePolicyOnly = false

    @Option(
        name: .customLong("identity-cache"),
        help: "--validate-policy-only: per-file SHA-256 cache keyed by the full file stamp (inode, size, mtime, ctime); a miss is read outside the page cache."
    )
    var identityCachePath: String?

    @Option(name: .customLong("lab-cb-inputs"), help: "Isolated lab only: immutable retained CB evidence and authorized identity rebind directory.")
    var labCBInputsPath: String?

    @Option(name: .customLong("lab-campaign"), help: "LAB-only frozen native campaign manifest; keeps target weights resident and creates fresh per-cell runtimes.")
    var labCampaignPath: String?

    private static var isLabBuild: Bool {
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        true
        #else
        false
        #endif
    }

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACPROVIDER_NATIVE_MTP_E2E"] == "1" else {
            FileHandle.standardError.write(Data("native-mtp-bench: set MACPROVIDER_NATIVE_MTP_E2E=1 on the Mac Studio\n".utf8))
            throw ExitCode(2)
        }
        guard validatePolicyOnly == (identityCachePath != nil), !(validatePolicyOnly && validateOnly) else {
            throw ValidationError("--validate-policy-only requires --identity-cache and excludes --validate-only")
        }
        // Before any MLX device use: the family's command-buffer budget and
        // cache limit, as serve and the journey harness set them. The
        // policy-only check never touches MLX, so it skips this.
        try NativeMTPHardwareE2ERunner.requireStudioHost()
        if !validatePolicyOnly {
            NativeMTPHardwareE2ERunner.applyServeProcessSetup(rootPath: root)
        }
        guard providerCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw ValidationError("--provider-commit must be lowercase 40-hex")
        }
        if let labCampaignPath {
            try NativeMTPBenchCampaign.requireScope(labBuild: Self.isLabBuild,
                permitted: NativeMTPQualificationScope.permitsFixtureHooks)
            guard policyPath == nil, policyList.isEmpty, requestsPath == nil,
                  requestsSHA256 == nil, longTokenIDsPath == nil, onlyCell == nil,
                  !validateOnly, !validatePolicyOnly, phase == .all, let labCBInputsPath else {
                throw ValidationError("--lab-campaign excludes other run selectors and requires --lab-cb-inputs")
            }
            let manifest = try NativeMTPBenchCampaign.load(path: labCampaignPath)
            let journalURL = URL(fileURLWithPath: ConfigLoader.expandTilde(outPath)).standardizedFileURL
            guard !FileManager.default.fileExists(atPath: journalURL.path),
                  !manifest.steps.contains(where: { $0.out == journalURL.path || $0.policy == journalURL.path }) else {
                throw ValidationError("campaign --out must be a fresh journal distinct from step outputs and inputs")
            }
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let journal = try NativeMTPJSONLWriter(url: journalURL, append: false)
            defer { try? journal.close() }
            try journal.write(["schema": "macprovider.native-mtp-resident-campaign-run.v1",
                "record_type": "header", "provider_commit": providerCommit,
                "manifest_sha256": NativeMTPLabCBInputs.sha(try Data(contentsOf:
                    URL(fileURLWithPath: ConfigLoader.expandTilde(labCampaignPath))))])
            let resident = NativeMTPBenchResident<NativeMTPBenchResidentWeights>()
            let identities = manifest.identityCache.map {
                NativeMTPBenchIdentityCache(persistentURL: URL(fileURLWithPath: $0))
            } ?? NativeMTPBenchIdentityCache()
            for step in manifest.steps {
                try NativeMTPBenchCampaign.verifyFile(step.policy, sha: step.policySHA256)
                try journal.write(["record_type": "step_start", "kind": step.kind, "depth": step.depth,
                    "out": step.out, "policy_sha256": step.policySHA256])
                let bench = try await NativeMTPBenchRunner(rootPath: root, modelID: modelID,
                    policyPath: step.policy, outPath: step.out, onlyCell: nil,
                    providerCommit: providerCommit, phase: step.kind == "sustained" ? .sustained : .matrix,
                    identityCache: identities,
                    labCBInputs: NativeMTPLabCBInputs(directory: URL(fileURLWithPath: ConfigLoader.expandTilde(labCBInputsPath)),
                        providerCommit: providerCommit), residentTarget: resident)
                if step.kind == "frozen" {
                    let corpus = try NativeMTPFrozenDSparkCorpus.load(from: URL(fileURLWithPath: step.requests!),
                        expectedSHA256: step.requestsSHA256!)
                    try NativeMTPBenchCampaign.verifyFile(step.longTokenIDs!, sha: step.longTokenIDsSHA256!)
                    let prompts = try NativeMTPFrozenDSparkCorpus.loadLongPrompts(from: URL(fileURLWithPath: step.longTokenIDs!))
                    guard Set(prompts.keys) == Set([8192, 32768]) else {
                        throw ValidationError("campaign long prompts must be exactly 8192 and 32768")
                    }
                    try await bench.runFrozenRequests(corpus, longPrompts: prompts,
                        groupIndices: step.frozenGroupIndices)
                } else { try await bench.run() }
                try journal.write(["record_type": "step_complete", "kind": step.kind,
                    "depth": step.depth, "out": step.out, "policy_sha256": step.policySHA256])
            }
            return
        }
        guard (policyPath != nil) != !policyList.isEmpty else {
            throw ValidationError("supply exactly one of --policy or --policy-list")
        }
        guard requestsPath != nil || (requestsSHA256 == nil && longTokenIDsPath == nil) else {
            throw ValidationError("--requests-sha256 and --long-token-ids require --requests")
        }
        guard requestsPath == nil || policyList.isEmpty else {
            throw ValidationError("--requests requires a single --policy")
        }
        let paths = policyPath.map { [$0] } ?? policyList
        let identityCache = identityCachePath.map {
            NativeMTPBenchIdentityCache(persistentURL: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
        } ?? (policyList.isEmpty ? nil : NativeMTPBenchIdentityCache())
        for (index, path) in paths.enumerated() {
            if !policyList.isEmpty {
                let policy = try NativeMTPBenchPolicy.load(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                guard policy.exploratory, phase == .matrix else {
                    throw ValidationError("--policy-list requires exploratory policies and --phase matrix")
                }
            }
            let bench = try await NativeMTPBenchRunner(
                rootPath: root,
                modelID: modelID,
                policyPath: path,
                outPath: policyList.isEmpty ? outPath : "\(outPath).policy-\(index).jsonl",
                onlyCell: onlyCell,
                providerCommit: providerCommit,
                phase: phase,
                identityCache: identityCache,
                labCBInputs: labCBInputsPath.map { NativeMTPLabCBInputs(
                    directory: URL(fileURLWithPath: ConfigLoader.expandTilde($0)), providerCommit: providerCommit) }
            )
            if let requestsPath {
                guard let requestsSHA256 else { throw ValidationError("--requests requires --requests-sha256") }
                let corpus = try NativeMTPFrozenDSparkCorpus.load(
                    from: URL(fileURLWithPath: requestsPath), expectedSHA256: requestsSHA256)
                let longPrompts = try longTokenIDsPath.map {
                    try NativeMTPFrozenDSparkCorpus.loadLongPrompts(from: URL(fileURLWithPath: $0))
                } ?? [:]
                if validateOnly || validatePolicyOnly { try bench.validate() }
                else { try await bench.runFrozenRequests(corpus, longPrompts: longPrompts) }
            } else if validateOnly || validatePolicyOnly { try bench.validate() }
            else { try await bench.run() }
        }
    }
}

/// Explicit isolated campaign plan. Each step delegates to an existing runner;
/// formal policy-list restrictions and measurement rules remain unchanged.
struct NativeMTPBenchCampaign: Decodable {
    struct Step: Decodable {
        let kind: String
        let depth: Int
        let policy: String
        let policySHA256: String
        let out: String
        let requests: String?
        let requestsSHA256: String?
        let longTokenIDs: String?
        let longTokenIDsSHA256: String?
        let frozenGroupIndices: [Int]?
        enum CodingKeys: String, CodingKey {
            case kind, depth, policy, out, requests
            case policySHA256 = "policy_sha256"
            case requestsSHA256 = "requests_sha256"
            case longTokenIDs = "long_token_ids"
            case longTokenIDsSHA256 = "long_token_ids_sha256"
            case frozenGroupIndices = "frozen_group_indices"
        }
    }
    let schema: String
    let steps: [Step]
    let identityCache: String?
    enum CodingKeys: String, CodingKey {
        case schema, steps
        case identityCache = "identity_cache"
    }

    static func requireScope(labBuild: Bool, permitted: Bool) throws {
        guard labBuild && permitted else {
            throw ValidationError("resident native campaign requires isolated lab scope")
        }
    }

    static func load(path: String) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: ConfigLoader.expandTilde(path)))
        guard data.count <= 1_048_576 else { throw ValidationError("campaign manifest too large") }
        try NativeMTPBenchJSON.rejectDuplicateKeys(data, label: "campaign manifest")
        let plan = try JSONDecoder().decode(Self.self, from: data)
        try plan.validateStructure()
        for step in plan.steps {
            try verifyFile(step.policy, sha: step.policySHA256)
            if step.kind != "sustained", FileManager.default.fileExists(atPath: step.out) {
                throw ValidationError("campaign requires fresh frozen and matrix outputs: \(step.out)")
            }
            let policy = try NativeMTPBenchPolicy.load(from: URL(fileURLWithPath: step.policy))
            guard policy.proposalDepth == step.depth, !policy.exploratory,
                  !policy.diagnosticEligibilityBypass, policy.blocks == 10,
                  policy.sustainedSeconds == 1800, policy.slots == [1, 2, 3, 4] else {
                throw ValidationError("campaign requires unchanged formal four-row/ten-block/1800s policy")
            }
            if step.kind == "frozen" {
                try verifyFile(step.requests!, sha: step.requestsSHA256!)
                try verifyFile(step.longTokenIDs!, sha: step.longTokenIDsSHA256!)
                guard (policy.maximumPromptTokens ?? 0) >= 32768 else {
                    throw ValidationError("frozen long contexts require a policy admitting 32768 prompt tokens")
                }
            } else {
                guard policy.matrixCells.count == 16 else {
                    throw ValidationError("campaign R015 requires all sixteen cells per depth")
                }
            }
        }
        return plan
    }

    /// Preserve original group indices while recording missing groups in a fresh output.
    static func selectedFrozenGroupIndices(
        _ requested: [Int]?, totalGroupCount: Int = 19
    ) throws -> [Int] {
        guard totalGroupCount > 0 else {
            throw ValidationError("frozen group count must be positive")
        }
        guard let requested else { return Array(0..<totalGroupCount) }
        guard !requested.isEmpty,
              requested.allSatisfy({ (0..<totalGroupCount).contains($0) }),
              zip(requested, requested.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw ValidationError("frozen_group_indices must be nonempty, strictly ascending, and within the frozen group range")
        }
        return requested
    }

    func validateStructure() throws {
        let depths = [1, 2, 3, 5]
        guard schema == "macprovider.native-mtp-resident-campaign.v1", steps.count == 12,
              steps.map(\.kind) == [String](repeating: "frozen", count: 4)
                + [String](repeating: "matrix", count: 4) + [String](repeating: "sustained", count: 4),
              steps.map(\.depth) == depths + depths + depths else {
            throw ValidationError("campaign order must be frozen, matrix, sustained at depths 1/2/3/5")
        }
        let inputs = steps.flatMap { [$0.policy] + [$0.requests, $0.longTokenIDs].compactMap { $0 } }
            + (identityCache.map { [$0] } ?? [])
        guard inputs.allSatisfy({ $0.hasPrefix("/") && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 }) else {
            throw ValidationError("campaign input paths must be absolute and canonical")
        }
        let inputPaths = Set(inputs)
        var outputs = Set<String>()
        for (index, step) in steps.enumerated() {
            if step.kind == "frozen" {
                _ = try Self.selectedFrozenGroupIndices(step.frozenGroupIndices)
            } else if step.frozenGroupIndices != nil {
                throw ValidationError("frozen_group_indices is allowed only on frozen steps")
            }
            guard step.out.hasPrefix("/"), URL(fileURLWithPath: step.out).standardizedFileURL.path == step.out,
                  !inputPaths.contains(step.out) else {
                throw ValidationError("campaign outputs must be canonical and distinct from every input")
            }
            if index < 8 {
                guard outputs.insert(step.out).inserted else {
                    throw ValidationError("campaign frozen and matrix outputs must be distinct")
                }
            } else {
                let matrix = steps[index - 4]
                guard step.out == matrix.out, step.policy == matrix.policy,
                      step.policySHA256 == matrix.policySHA256 else {
                    throw ValidationError("sustained must reuse its depth's exact matrix policy/output")
                }
            }
            if step.kind == "frozen" {
                guard step.requests?.hasPrefix("/") == true,
                      step.requestsSHA256 == "01bb9294714fcc95c7dc8540b460c309f8c5ff782214d24b3e95d4e4297b9383",
                      step.longTokenIDs?.hasPrefix("/") == true,
                      step.longTokenIDsSHA256 == "1d64f1cd35c336489c5c00edc65fa69740735250300bf26b7c960feaa3d41bc5" else {
                    throw ValidationError("campaign frozen inputs require immutable request and long-token hashes")
                }
            } else if step.requests != nil || step.requestsSHA256 != nil || step.longTokenIDs != nil || step.longTokenIDsSHA256 != nil {
                throw ValidationError("R015 steps cannot supply frozen-request selectors")
            }
        }
    }

    static func verifyFile(_ path: String, sha: String) throws {
        guard sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              NativeMTPLabCBInputs.sha(try Data(contentsOf: URL(fileURLWithPath: path))) == sha else {
            throw ValidationError("campaign immutable input checksum mismatch: \(path)")
        }
    }
}

/// The fixture directories one bench root holds: `target/`, and `mtp/` for a
/// separate drafter artifact; a target that embeds its next-N layer
/// (`checkpoint_mtp`, glm5_next) is its own MTP artifact (SPEC-048 MTP-2).
struct NativeMTPBenchFixtureLayout: Equatable {
    let family: NativeMTPHardwareE2EFamily
    let targetDirectory: URL
    let mtpDirectory: URL

    static func resolve(root: URL) -> NativeMTPBenchFixtureLayout {
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        // As the hardware runner: Qwen3.5 when the config is unreadable, so an
        // unrecognized target fails the family check in the fixture load.
        let family = NativeMTPHardwareE2EFamily.detect(configJSONData: try? Data(
            contentsOf: targetDirectory.appendingPathComponent("config.json")
        )) ?? .qwen35
        return NativeMTPBenchFixtureLayout(
            family: family,
            targetDirectory: targetDirectory,
            mtpDirectory: root.appendingPathComponent(family.mtpDirectoryName, isDirectory: true)
        )
    }
}

/// SPEC-048-R015 bench phases. The sustained window is a separate phase on the
/// same frozen policy and --out: it never re-runs the sustained cell's matrix
/// blocks, which the analyzer pairs with the sustained records.
enum NativeMTPBenchPhase: String, ExpressibleByArgument, Sendable {
    case all
    case matrix
    case sustained
}

/// R015 prompt realization helpers (`deterministic_synthetic_unique_v2`).
enum NativeMTPBenchPrompts {
    /// The fewest salts whose prompt's served count reaches `target`, and
    /// that count. Each salt appends tokens, so the count rises with the salt
    /// count and this bisection returns the text that appending one salt at a
    /// time until the target is reached returns, in a few tokenizations
    /// instead of one per salt.
    /// A count still below the target at `maximumSalts` salts fails instead
    /// of growing the text without bound.
    static func fewestReachingSalts(
        target: Int,
        maximumSalts: Int = 1 << 16,
        count: (Int) async throws -> Int
    ) async throws -> (salts: Int, count: Int) {
        var below = -1
        var reaching = 0
        var reachingCount = try await count(reaching)
        while reachingCount < target {
            guard reaching < maximumSalts else {
                throw NativeMTPBenchError.assertionFailed(
                    "prompt sizing: \(maximumSalts) salts reach \(reachingCount) of \(target) served tokens"
                )
            }
            below = reaching
            reaching = reaching > maximumSalts / 2 ? maximumSalts : max(1, reaching * 2)
            reachingCount = try await count(reaching)
        }
        while reaching - below > 1 {
            let middle = below + (reaching - below) / 2
            let middleCount = try await count(middle)
            if middleCount < target {
                below = middle
            } else {
                reaching = middle
                reachingCount = middleCount
            }
        }
        return (reaching, reachingCount)
    }

    static func forBlock(_ block: Int, in promptsByBlock: [Int: [String]]) throws -> [String] {
        guard let prompts = promptsByBlock[block] else {
            throw NativeMTPBenchError.assertionFailed("no prompts sized for block \(block)")
        }
        return prompts
    }
}

struct NativeMTPFrozenDSparkCorpus: Sendable {
    struct Request: Sendable {
        let name: String
        let stratum: String
        let tokenIDs: [Int]
        let body: Data

        func request(modelID: String, maxTokens: Int) throws -> ChatCompletionRequest {
            guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw NativeMTPBenchError.invalidPolicy("frozen request body is not an object")
            }
            object["model"] = modelID
            object["temperature"] = 0
            object["top_p"] = 1
            object["max_tokens"] = maxTokens
            object["stream"] = true
            return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: object))
        }
    }
    let sha256: String
    let tokenizerSHA256: String
    let requests: [Request]

    static func load(from url: URL, expectedSHA256: String) throws -> Self {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else {
            throw NativeMTPBenchError.invalidPolicy("frozen requests SHA-256 mismatch")
        }
        try NativeMTPBenchJSON.rejectDuplicateKeys(data, label: "frozen requests")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? String == "macprovider.dsv4-dspark-requests.v1",
              let tokenizer = object["tokenizer_sha256"] as? String,
              let entries = object["requests"] as? [[String: Any]], entries.count == 12 else {
            throw NativeMTPBenchError.invalidPolicy("invalid frozen requests schema")
        }
        let requests = try entries.map { entry -> Request in
            guard let name = entry["name"] as? String, !name.isEmpty,
                  let stratum = entry["stratum"] as? String,
                  ["prose", "reasoning", "code"].contains(stratum),
                  let ids = entry["ids"] as? [Int], !ids.isEmpty, ids.allSatisfy({ $0 >= 0 }),
                  let body = entry["request"] as? [String: Any] else {
                throw NativeMTPBenchError.invalidPolicy("invalid frozen request entry")
            }
            return Request(name: name, stratum: stratum, tokenIDs: ids,
                body: try JSONSerialization.data(withJSONObject: body))
        }
        guard Set(requests.map(\.name)).count == 12,
              ["prose", "reasoning", "code"].allSatisfy({ stratum in
                  requests.filter { $0.stratum == stratum }.count == 4
              }) else { throw NativeMTPBenchError.invalidPolicy("frozen request names/strata mismatch") }
        return Self(sha256: digest, tokenizerSHA256: tokenizer, requests: requests)
    }

    static func loadLongPrompts(from url: URL) throws -> [Int: [Int]] {
        let data = try Data(contentsOf: url)
        try NativeMTPBenchJSON.rejectDuplicateKeys(data, label: "long prompt IDs")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: [Int]],
              Set(object.keys) == ["8192", "32768"] else {
            throw NativeMTPBenchError.invalidPolicy("long prompt IDs require exactly 8192 and 32768")
        }
        var result: [Int: [Int]] = [:]
        for (key, ids) in object {
            guard let count = Int(key), ids.count == count, ids.allSatisfy({ $0 >= 0 }) else {
                throw NativeMTPBenchError.invalidPolicy("long prompt IDs length/value mismatch")
            }
            result[count] = ids
        }
        return result
    }
}

/// Same-process reuse: every reuse checks inode/ctime/size/mtime and
/// additions/removals against the exact snapshot just hashed by this command.
/// With `persistentURL` (`--validate-policy-only` only), a file's hash is also
/// reused across processes while its full stamp is unchanged, so the
/// pre-downtime check reads a large snapshot once, not once per window.
final class NativeMTPBenchIdentityCache {
    struct Entry: Codable, Equatable {
        let stamp: MLXSnapshotIdentity.FileStamp
        let sha256: String
    }

    private var identities: [URL: MLXSnapshotIdentity] = [:]
    private let persistentURL: URL?

    init(persistentURL: URL? = nil) {
        self.persistentURL = persistentURL
    }

    func identity(directory: URL) throws -> MLXSnapshotIdentity {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath()
        if let identity = identities[key] {
            guard identity.isCurrent() else {
                throw NativeMTPBenchError.assertionFailed("snapshot changed between diagnostic policies")
            }
            return identity
        }
        let identity = try persistentURL.map { try Self.persistentIdentity(directory: key, store: $0) }
            ?? MLXSnapshotIdentity.compute(directory: directory)
        identities[key] = identity
        return identity
    }

    private static func persistentIdentity(directory: URL, store: URL) throws -> MLXSnapshotIdentity {
        // An unreadable or malformed store is an empty one: every file is read.
        var all = (try? JSONDecoder().decode([String: [Entry]].self, from: Data(contentsOf: store))) ?? [:]
        let known = all[directory.path] ?? []
        var fresh: [Entry] = []
        let identity = try MLXSnapshotIdentity.compute(directory: directory) { stamp, read in
            let sha = try known.first(where: { $0.stamp == stamp })?.sha256 ?? read()
            fresh.append(Entry(stamp: stamp, sha256: sha))
            return sha
        }
        all[directory.path] = fresh
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: store, options: [.atomic])
        chmod(store.path, 0o600)
        return identity
    }
}

final class NativeMTPBenchRunner {
    private let root: URL
    private let modelID: String
    private let policyURL: URL
    private let outURL: URL
    private let onlyCell: String?
    private let providerCommit: String
    private let phase: NativeMTPBenchPhase
    private let policy: NativeMTPBenchPolicy
    private let policySHA256: String
    private let identityCache: NativeMTPBenchIdentityCache?
    private let labCBInputs: NativeMTPLabCBInputs?
    private let residentTarget: NativeMTPBenchResident<NativeMTPBenchResidentWeights>?
    /// The native runtime's scheduler load-gate recorder for the current
    /// cell fixture (SPEC-048-R015 gated-cell evidence).
    private var nativeLoadGateRecorder: NativeMTPLoadGateRecorder?

    init(
        rootPath: String,
        modelID: String,
        policyPath: String,
        outPath: String,
        onlyCell: String?,
        providerCommit: String,
        phase: NativeMTPBenchPhase,
        identityCache: NativeMTPBenchIdentityCache? = nil,
        labCBInputs: NativeMTPLabCBInputs? = nil,
        residentTarget: NativeMTPBenchResident<NativeMTPBenchResidentWeights>? = nil
    ) async throws {
        self.root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        self.modelID = modelID
        self.policyURL = URL(fileURLWithPath: (policyPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        self.outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            .standardizedFileURL
        self.onlyCell = onlyCell
        self.providerCommit = providerCommit
        self.phase = phase
        self.identityCache = identityCache
        self.labCBInputs = labCBInputs
        self.residentTarget = residentTarget
        self.policySHA256 = try Self.sha256(of: self.policyURL)
        self.policy = try NativeMTPBenchPolicy.load(from: self.policyURL)
        self.layout = NativeMTPBenchFixtureLayout.resolve(root: self.root)
        try policy.validateFamily(layout.family)
    }

    private let layout: NativeMTPBenchFixtureLayout
    /// The target identity this process verified at start; the fixture load
    /// re-checks it once more right before loading (no third full hash).
    private var verifiedTargetIdentity: MLXSnapshotIdentity?

    /// `--validate-only`: every check `run()` makes before its first model
    /// load, then a one-line summary. No MLX model is loaded.
    func validate() throws {
        let checked = try preflight()
        // Both request forms a cell builds (prompt sizing, then the run),
        // through the production request parser; no model or tokenizer.
        for cell in policy.matrixCells {
            _ = try NativeMTPBenchRequests.make(
                modelID: modelID, requestID: "prompt-sizing", prompt: "validate", maxTokens: 1,
                temperature: 0, requestShape: policy.requestShape
            )
            _ = try NativeMTPBenchRequests.make(
                modelID: modelID, requestID: "validate-\(cell.id)", prompt: "validate", maxTokens: cell.maxTokens,
                temperature: policy.temperature, topP: policy.topP, requestShape: policy.requestShape
            )
        }
        let summary: [String: Any] = [
            "validate_only": "pass",
            "family": layout.family.modelFamily,
            "mtp_directory": layout.family.mtpDirectoryName,
            "target_sha256": checked.targetIdentity.digest,
            "mtp_sha256": checked.mtpIdentity.digest,
            "tokenizer_sha256": checked.tokenizerSHA256,
            "policy_sha256": policySHA256,
            "cells": policy.matrixCells.map(\.id),
            "sustained_cell_id": policy.sustainedCellID,
            "existing_records": checked.existing.hasRecords,
            "observed_environment": [
                "hw_model": checked.environment.hwModel,
                "chip": checked.environment.chip,
                "ram_gb": checked.environment.ramGB,
                "os_build": checked.environment.osBuild,
                "xcode_build_version": checked.environment.xcodeBuildVersion,
                "swift_version": checked.environment.swiftVersion,
                "provider_commit": checked.environment.providerCommit,
                "mlx_fork_revision": NativeMTPHardwareE2ERunner.upstreamRevision,
            ] as [String: Any],
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private struct Preflight {
        let targetIdentity: MLXSnapshotIdentity
        let mtpIdentity: MLXSnapshotIdentity
        let tokenizerSHA256: String
        let environment: NativeMTPBenchEnvironment
        let existing: NativeMTPExistingEvidence
    }

    private func preflight() throws -> Preflight {
        if let onlyCell, policy.cell(id: onlyCell) == nil {
            throw NativeMTPBenchError.invalidPolicy("--only-cell does not identify a policy matrix cell")
        }
        if phase == .sustained {
            guard policy.sustainedSeconds > 0 else {
                throw NativeMTPBenchError.invalidPolicy("--phase sustained needs sustained_seconds > 0")
            }
            if let onlyCell, onlyCell != policy.sustainedCellID {
                throw NativeMTPBenchError.invalidPolicy("--phase sustained runs only sustained_cell_id")
            }
        }
        let targetDirectory = layout.targetDirectory
        let mtpDirectory = layout.mtpDirectory
        try Self.requireDirectory(targetDirectory)
        try Self.requireDirectory(mtpDirectory)
        let targetIdentity = try identityCache?.identity(directory: targetDirectory) ?? MLXSnapshotIdentity.compute(directory: targetDirectory)
        // An embedded MTP layer is the target artifact: one identity, hashed once.
        let mtpIdentity = layout.family.embeddedMTP
            ? targetIdentity
            : try identityCache?.identity(directory: mtpDirectory) ?? MLXSnapshotIdentity.compute(directory: mtpDirectory)
        let tokenizerSHA = try Self.sha256(of: targetDirectory.appendingPathComponent("tokenizer.json"))
        try policy.validateObserved(modelID: modelID, targetSHA256: targetIdentity.digest, mtpSHA256: mtpIdentity.digest, tokenizerSHA256: tokenizerSHA)
        let environment = NativeMTPBenchEnvironment.capture(providerCommit: providerCommit)
        try policy.validateObserved(environment: environment)

        let parent = outURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let existing = try NativeMTPExistingEvidence.loadIfPresent(
            url: outURL,
            policy: policy,
            policySHA256: policySHA256,
            providerCommit: providerCommit,
            modelID: modelID,
            targetSHA256: targetIdentity.digest,
            mtpSHA256: mtpIdentity.digest,
            tokenizerSHA256: tokenizerSHA,
            environment: environment
        )
        // The sustained phase reuses the sustained cell's matrix records in
        // this --out; it never starts without all of them.
        if phase == .sustained,
           (existing.completedMatrixBlocks[policy.sustainedCellID] ?? []) != Set(0..<policy.blocks) {
            throw NativeMTPBenchError.assertionFailed(
                "--phase sustained needs every matrix block of \(policy.sustainedCellID) in --out first"
            )
        }
        // SPEC-048-R015: an admission sustained window is one continuous run.
        // A partial window is never resumed (a resume would add up separate
        // thermal windows); its records must be moved aside and the window
        // rerun whole.
        if !policy.exploratory, phase != .matrix,
           let done = existing.sustainedSeconds[policy.sustainedCellID],
           done > 0, done < Double(policy.sustainedSeconds) {
            throw NativeMTPBenchError.assertionFailed(
                "--out holds a partial sustained window for \(policy.sustainedCellID); an admission window is never resumed"
            )
        }
        if existing.hasRecords, onlyCell == nil, phase != .sustained {
            throw NativeMTPBenchError.assertionFailed(
                "refusing to append a full matrix to non-empty --out; use --only-cell to resume"
            )
        }
        return Preflight(
            targetIdentity: targetIdentity,
            mtpIdentity: mtpIdentity,
            tokenizerSHA256: tokenizerSHA,
            environment: environment,
            existing: existing
        )
    }

    func run() async throws {
        let checked = try preflight()
        // This command runs no serving listener. Scope the explicit laboratory
        // eligibility override to this exploratory benchmark process only.
        let diagnosticKey = "MACPROVIDER_MTP_BENCH_DIAGNOSTIC_ELIGIBILITY"
        let previousDiagnostic = ProcessInfo.processInfo.environment[diagnosticKey]
        if policy.diagnosticEligibilityBypass { setenv(diagnosticKey, "1", 1) }
        else { unsetenv(diagnosticKey) }
        defer {
            if let previousDiagnostic { setenv(diagnosticKey, previousDiagnostic, 1) }
            else { unsetenv(diagnosticKey) }
        }
        let targetIdentity = checked.targetIdentity
        let mtpIdentity = checked.mtpIdentity
        let tokenizerSHA = checked.tokenizerSHA256
        let environment = checked.environment
        let existing = checked.existing
        verifiedTargetIdentity = targetIdentity
        let writer = try NativeMTPJSONLWriter(url: outURL, append: existing.hasRecords)
        defer { try? writer.close() }

        if !existing.hasRecords {
            var header = baseHeader(
                targetIdentity: targetIdentity,
                mtpIdentity: mtpIdentity,
                tokenizerSHA256: tokenizerSHA,
                environment: environment
            )
            header["unavailable_metrics"] = []
            try writer.write(header)
        }

        if phase != .sustained {
            for cell in policy.matrixCells {
                guard onlyCell == nil || onlyCell == cell.id else { continue }
                try await runCell(
                    cell,
                    writer: writer,
                    completedBlocks: existing.completedMatrixBlocks[cell.id] ?? [],
                    completedWarmups: existing.completedWarmups[cell.id] ?? []
                )
            }
        }
        if phase != .matrix, policy.sustainedSeconds > 0, onlyCell == nil || onlyCell == policy.sustainedCellID {
            try await runSustained(
                writer: writer,
                completedSeconds: existing.sustainedSeconds[policy.sustainedCellID] ?? 0,
                startingBlock: existing.nextSustainedBlock[policy.sustainedCellID] ?? 0
            )
        }
    }

    /// Native scheduler proof on the frozen natural bodies. This records
    /// exact token IDs before decoding text and does not stand in for R015.
    func runFrozenRequests(
        _ corpus: NativeMTPFrozenDSparkCorpus,
        longPrompts: [Int: [Int]],
        groupIndices: [Int]? = nil
    ) async throws {
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        guard layout.family == .deepseekV4, onlyCell == nil, phase != .sustained,
              !FileManager.default.fileExists(atPath: outURL.path) else {
            throw NativeMTPBenchError.invalidPolicy("frozen requests require DeepSeek, a fresh --out, and no sustained/only-cell selection")
        }
        var groups = corpus.requests.map { [$0] }
        for stratum in ["prose", "reasoning", "code"] {
            groups.append(corpus.requests.filter { $0.stratum == stratum })
        }
        for count in longPrompts.keys.sorted() {
            let item = NativeMTPFrozenDSparkCorpus.Request(name: "long-\(count)",
                stratum: "synthetic_long", tokenIDs: longPrompts[count]!, body: Data())
            groups.append([item])
            groups.append((0..<4).map { row in
                .init(name: "long-\(count)-r\(row)", stratum: "synthetic_long",
                    tokenIDs: item.tokenIDs, body: Data())
            })
        }
        let selectedGroups = try NativeMTPBenchCampaign.selectedFrozenGroupIndices(
            groupIndices, totalGroupCount: groups.count
        )
        let checked = try preflight()
        guard corpus.tokenizerSHA256 == checked.tokenizerSHA256 else {
            throw NativeMTPBenchError.assertionFailed("frozen corpus tokenizer identity mismatch")
        }
        verifiedTargetIdentity = checked.targetIdentity
        let longest = max(corpus.requests.map { $0.tokenIDs.count }.max() ?? 1,
            longPrompts.keys.max() ?? 1)
        var mappingFixture: NativeMTPHardwareRuntimeFixture? = try await fixture(
            for: .init(slots: 4, promptTokens: longest, maxTokens: 256))
        // Verify the frozen IDs against the production request mapping, including
        // thinking-mode encoding, before submitting any measured token probe.
        for item in corpus.requests {
            let body = try item.request(modelID: modelID, maxTokens: 256)
            let ids = try await mappingFixture!.runtimes.targetContainer.perform { context in
                let input = try ModelRuntime.userInput(for: body)
                return try await context.processor.prepare(input: input).text.tokens.asArray(Int.self)
            }
            guard ids == item.tokenIDs else {
                throw NativeMTPBenchError.assertionFailed("frozen production prompt IDs differ: \(item.name)")
            }
        }
        let sharedFrozenFixture = residentTarget == nil ? mappingFixture : nil
        mappingFixture = nil
        let writer = try NativeMTPJSONLWriter(url: outURL, append: false)
        defer { try? writer.close() }
        try writer.write([
            "schema": "macprovider.native-dsv4-dspark-run.v1", "record_type": "header",
            "runtime": "native_swift_mlx", "qualifies_r015": false,
            "policy_sha256": policySHA256, "requests_sha256": corpus.sha256,
            "target_sha256": checked.targetIdentity.digest, "tokenizer_sha256": checked.tokenizerSHA256,
            "provider_commit": providerCommit, "mlx_fork_revision": policy.mlxForkRevision,
            "requested_maximum_proposal_depth": policy.proposalDepth,
            "selected_group_indices": selectedGroups,
            "total_group_count": groups.count,
            "long_prompt_token_counts": longPrompts.keys.sorted(),
            "long_prompt_token_sha256": Dictionary(uniqueKeysWithValues: longPrompts.map {
                (String($0.key), NativeMTPSelfTest.tokenDigest($0.value))
            }),
        ])
        for groupIndex in selectedGroups {
            let group = groups[groupIndex]
            let fixture: NativeMTPHardwareRuntimeFixture
            if let sharedFrozenFixture { fixture = sharedFrozenFixture }
            else {
                fixture = try await self.fixture(for: .init(slots: group.count,
                    promptTokens: group.map { $0.tokenIDs.count }.max() ?? 1, maxTokens: 256))
            }
            let ordinary = try await frozenWave(group, groupIndex: groupIndex,
                runtime: fixture.runtimes.ordinary, nativeDepth: nil, roundRecorder: nil)
            let native = try await frozenWave(group, groupIndex: groupIndex,
                runtime: fixture.runtimes.native, nativeDepth: policy.proposalDepth,
                roundRecorder: fixture.dsparkRoundRecorder)
            let equal = ordinary.results.count == native.results.count
                && zip(ordinary.results, native.results).allSatisfy { pair in
                    pair.0.name == pair.1.name
                        && pair.0.result.generatedTokens == pair.1.result.generatedTokens
                        && pair.0.result.terminalStatus == pair.1.result.terminalStatus
                }
            for (path, wave) in [("ordinary", ordinary), ("native_mtp", native)] {
                var record = wave.record
                record["schema"] = "macprovider.native-dsv4-dspark-run.v1"
                record["record_type"] = "run"
                record["path"] = path
                record["requests_sha256"] = corpus.sha256
                record["requested_maximum_proposal_depth"] = policy.proposalDepth
                record["group_index"] = groupIndex
                record["stratum"] = group[0].stratum
                record["parity_pass"] = equal
                try writer.write(record)
            }
            guard equal, native.proposedTokens > 0 else {
                throw NativeMTPBenchError.assertionFailed("native frozen group failed token parity or proposed no drafts: \(groupIndex)")
            }
        }
        #else
        throw NativeMTPBenchError.invalidPolicy("frozen requests require a debug or MACPROVIDER_LAB_HARNESS build")
        #endif
    }

    #if DEBUG || MACPROVIDER_LAB_HARNESS
    private struct FrozenResult: Sendable {
        let name: String
        let result: ContinuousBatchSchedulerResult
        let started: UInt64
        let ended: UInt64
    }

    private struct FrozenWave {
        let results: [FrozenResult]
        let proposedTokens: UInt64
        let record: [String: Any]
    }

    private func frozenWave(
        _ requests: [NativeMTPFrozenDSparkCorpus.Request],
        groupIndex: Int,
        runtime: ModelRuntime,
        nativeDepth: Int?,
        roundRecorder: NativeMTPDSparkRoundRecorder?
    ) async throws -> FrozenWave {
        let ids = requests.map { "frozen-g\(groupIndex)-\($0.name)" }
        let timing = NativeMTPLabCommittedTokenTimingObserver()
        guard await runtime.installLabNativeMTPCommitTimingObserver(timing),
              await runtime.installLabBatchComposition(
                ids, nativeIntegrityProbes: requests.count > 1 && nativeDepth != nil
              ) else {
            throw NativeMTPBenchError.assertionFailed("native frozen timing/composition observer unavailable")
        }
        let before = await runtime.currentSnapshot().nativeMTPStatus
        let memory = NativeMTPMemorySampler()
        memory.start()
        let started = DispatchTime.now().uptimeNanoseconds
        let results: [FrozenResult]
        do {
            results = try await withThrowingTaskGroup(of: FrozenResult.self) { group in
                for (index, item) in requests.enumerated() {
                    group.addTask {
                        let rowStarted = DispatchTime.now().uptimeNanoseconds
                        let result = try await runtime.labTokenProbe(id: ids[index],
                            promptTokenIDs: item.tokenIDs, maxCompletionTokens: 256, nativeDepth: nativeDepth)
                        guard result.errorCode == nil, !result.generatedTokens.isEmpty else {
                            throw NativeMTPBenchError.assertionFailed("frozen native scheduler row failed: \(item.name)")
                        }
                        return FrozenResult(name: item.name, result: result,
                            started: rowStarted, ended: DispatchTime.now().uptimeNanoseconds)
                    }
                }
                var output: [FrozenResult] = []
                for try await result in group { output.append(result) }
                return output.sorted { $0.name < $1.name }
            }
        } catch {
            memory.stop()
            _ = await runtime.installLabNativeMTPCommitTimingObserver(nil)
            _ = await runtime.installLabBatchComposition(nil)
            throw error
        }
        let ended = DispatchTime.now().uptimeNanoseconds
        memory.stop()
        _ = await runtime.installLabNativeMTPCommitTimingObserver(nil)
        _ = await runtime.installLabBatchComposition(nil)
        let delta = NativeMTPStatusDelta(before: before, after: await runtime.currentSnapshot().nativeMTPStatus)
        let events = timing.snapshot()
        let metrics: [[String: Any]] = results.map { row in
            let first = events.filter { $0.requestID == row.result.requestID }
                .map(\.monotonicNanoseconds).min()
            let ttft = first.map { Double($0 - row.started) / 1_000_000_000 }
            let wall = Double(row.ended - row.started) / 1_000_000_000
            var metrics: [String: Any] = ["name": row.name, "prompt_tokens": row.result.promptTokens,
                "completion_tokens": row.result.generatedTokens.count,
                "token_sha256": NativeMTPSelfTest.tokenDigest(row.result.generatedTokens),
                "ttft_seconds": ttft.map { $0 as Any } ?? NSNull(),
                "decode_tps": NativeMTPBenchDecodeThroughput.perRequest(
                    completionTokens: row.result.generatedTokens.count, ttftSeconds: ttft,
                    wallSeconds: wall).map { $0 as Any } ?? NSNull()]
            if let roundRecorder, let nativeDepth {
                metrics.merge(roundRecorder.metrics(requestIDs: [row.result.requestID],
                    maximumDepth: nativeDepth)) { _, actual in actual }
            }
            return metrics
        }
        let first = events.map(\.monotonicNanoseconds).min()
        let count = results.reduce(0) { $0 + $1.result.generatedTokens.count }
        var record: [String: Any] = [
            "runtime": "native_swift_mlx", "qualifies_r015": false,
            "sampling": "greedy", "probe": "scheduler_integrity_maximum_depth",
            "rows": requests.count, "wall_seconds": Double(ended - started) / 1_000_000_000,
            "aggregate_decode_tps": first.flatMap {
                ended > $0 ? Double(max(0, count - results.count)) / (Double(ended - $0) / 1_000_000_000) : nil
            }.map { $0 as Any } ?? NSNull(),
            "request_metrics": metrics, "mtp_proposed_tokens": delta.proposedTokens,
            "mtp_accepted_tokens": delta.acceptedTokens, "mtp_rejected_tokens": delta.rejectedTokens,
            "mtp_accepted_by_position": delta.acceptedByPosition,
            "target_forwards": delta.targetForwards, "mtp_forwards": delta.mtpForwards,
            "peak_phys_footprint_bytes": memory.peakPhysFootprintBytes.map { $0 as Any } ?? NSNull(),
            "min_available_memory_bytes": memory.minAvailableBytes.map { $0 as Any } ?? NSNull(),
        ]
        if let roundRecorder, let nativeDepth {
            record.merge(roundRecorder.metrics(requestIDs: Set(ids), maximumDepth: nativeDepth)) { _, actual in actual }
        }
        return FrozenWave(results: results, proposedTokens: delta.proposedTokens, record: record)
    }
    #endif

    private func runCell(
        _ cell: NativeMTPBenchCell,
        writer: NativeMTPJSONLWriter,
        completedBlocks: Set<Int>,
        completedWarmups: Set<Int>
    ) async throws {
        let fixture = try await fixture(for: cell)
        // Independent ceiling for each short diagnostic cell, including all
        // paired blocks. The outer guarded controller restores live serving
        // when this child exits, including a stalled GPU task.
        let cellWatchdog: DispatchSourceTimer? = policy.diagnosticEligibilityBypass ? DispatchSource.makeTimerSource(queue: .global()) : nil
        cellWatchdog?.schedule(deadline: .now() + 180)
        cellWatchdog?.setEventHandler {
            FileHandle.standardError.write(Data("native-mtp-bench: diagnostic cell exceeded 180 seconds\n".utf8))
            _exit(124)
        }
        cellWatchdog?.resume()
        defer { cellWatchdog?.cancel() }
        // Every block's prompts are sized before the first timed run, so no
        // block starts after an idle GPU gap its partner run did not have.
        // Sized between blocks, the first run of each block measured about
        // 2.4 s more TTFT on both paths at 4096 tokens (GLM-5.3-Flash, window
        // 2026-10-18T13:38Z), and the counterbalanced order turned that into
        // a bimodal paired TTFT ratio.
        let warmupBlocks = (0..<policy.warmupRuns).map { -1 - $0 }.filter { !completedWarmups.contains($0) }
        let matrixBlocks = (0..<policy.blocks).filter { !completedBlocks.contains($0) }
        var promptsByBlock: [Int: [String]] = [:]
        for block in warmupBlocks + matrixBlocks {
            promptsByBlock[block] = try await makePrompts(runtime: fixture.runtimes.ordinary, cell: cell, block: block)
        }
        for block in warmupBlocks {
            let prompts = try NativeMTPBenchPrompts.forBlock(block, in: promptsByBlock)
            _ = try await runPath(.ordinary, cell: cell, block: block, order: 0, prompts: prompts, runtime: fixture.runtimes.ordinary, fixture: fixture, writer: writer, warmup: true)
            _ = try await runPath(.nativeMTP, cell: cell, block: block, order: 1, prompts: prompts, runtime: fixture.runtimes.native, fixture: fixture, writer: writer, warmup: true)
        }
        let nativeFirstByBlock = NativeMTPBenchPolicy.nativeFirstOrder(seed: policy.seed, cell: cell, blocks: policy.blocks)
        for block in matrixBlocks {
            let prompts = try NativeMTPBenchPrompts.forBlock(block, in: promptsByBlock)
            let nativeFirst = nativeFirstByBlock[block]
            var ordinaryResult: NativeMTPBenchRunResult?
            var nativeResult: NativeMTPBenchRunResult?
            for order in 0..<2 {
                let runNative = nativeFirst ? order == 0 : order == 1
                if runNative {
                    nativeResult = try await runPath(.nativeMTP, cell: cell, block: block, order: order, prompts: prompts, runtime: fixture.runtimes.native, fixture: fixture, writer: nil, warmup: false)
                } else {
                    ordinaryResult = try await runPath(.ordinary, cell: cell, block: block, order: order, prompts: prompts, runtime: fixture.runtimes.ordinary, fixture: fixture, writer: nil, warmup: false)
                }
            }
            guard var ordinary = ordinaryResult, var native = nativeResult else {
                throw NativeMTPBenchError.assertionFailed("missing paired block result")
            }
            let mismatch = parityMismatch(ordinary: ordinary, native: native)
            ordinary.parityMismatch = mismatch
            native.parityMismatch = mismatch
            try writer.write(ordinary.record(policySHA256: policySHA256, sustained: false, warmup: false))
            try writer.write(native.record(policySHA256: policySHA256, sustained: false, warmup: false))
        }
    }

    private func runSustained(
        writer: NativeMTPJSONLWriter,
        completedSeconds: Double,
        startingBlock: Int
    ) async throws {
        guard let cell = policy.cell(id: policy.sustainedCellID) else {
            throw NativeMTPBenchError.invalidPolicy("sustained_cell_id does not identify a matrix cell")
        }
        let fixture = try await fixture(for: cell)
        let remainingSeconds = max(0, Double(policy.sustainedSeconds) - completedSeconds)
        // One id per continuous sustained run; the analyzer requires a single
        // id across an admission window (run_metrics_version 5).
        let windowID = UUID().uuidString.lowercased()
        let windowStarted = Date()
        let deadline = Date().addingTimeInterval(remainingSeconds)
        var block = startingBlock
        while Date() < deadline {
            let prompts = try await makePrompts(runtime: fixture.runtimes.ordinary, cell: cell, block: 10_000 + block)
            let nativeFirst = block.isMultiple(of: 2)
            var ordinaryResult: NativeMTPBenchRunResult?
            var nativeResult: NativeMTPBenchRunResult?
            for order in 0..<2 {
                let runNative = nativeFirst ? order == 0 : order == 1
                if runNative {
                    nativeResult = try await runPath(.nativeMTP, cell: cell, block: block, order: order, prompts: prompts, runtime: fixture.runtimes.native, fixture: fixture, writer: nil, warmup: false)
                } else {
                    ordinaryResult = try await runPath(.ordinary, cell: cell, block: block, order: order, prompts: prompts, runtime: fixture.runtimes.ordinary, fixture: fixture, writer: nil, warmup: false)
                }
            }
            guard var ordinary = ordinaryResult, var native = nativeResult else {
                throw NativeMTPBenchError.assertionFailed("missing sustained pair")
            }
            let mismatch = parityMismatch(ordinary: ordinary, native: native)
            ordinary.parityMismatch = mismatch
            native.parityMismatch = mismatch
            let elapsed = completedSeconds + Date().timeIntervalSince(windowStarted)
            try writer.write(ordinary.record(
                policySHA256: policySHA256,
                sustained: true,
                warmup: false,
                sustainedWindowElapsedSeconds: elapsed,
                sustainedWindowID: windowID
            ))
            try writer.write(native.record(
                policySHA256: policySHA256,
                sustained: true,
                warmup: false,
                sustainedWindowElapsedSeconds: elapsed,
                sustainedWindowID: windowID
            ))
            block += 1
        }
    }

    private func fixture(for cell: NativeMTPBenchCell) async throws -> NativeMTPHardwareRuntimeFixture {
        // SPEC-023-R024 qualifies 2...8 slots, so a one-slot cell runs one
        // concurrent request against the smallest qualified two-slot runtime;
        // the ordinary and native runtimes share that shape.
        let qualifiedSlots = policy.qualifiedSlots(for: cell)
        let maxBlocks = NativeMTPHardwareE2ERunner.sizedMaxPhysicalBlocks(
            slots: qualifiedSlots,
            promptTokens: cell.promptTokens,
            outputTokens: cell.maxTokens
        )
        let runner = NativeMTPHardwareE2ERunner(
            rootPath: root.path,
            modelID: modelID,
            maxBatch: qualifiedSlots,
            maxNativeActiveRows: policy.maxNativeActiveRows(for: cell),
            proposalDepth: policy.proposalDepth,
            maxPromptTokens: policy.maximumPromptTokens ?? 1_048_576,
            maxPhysicalBlocks: maxBlocks,
            diagnosticEligibilityBypass: policy.diagnosticEligibilityBypass,
            labCBInputs: labCBInputs, residentTarget: residentTarget
        )
        let fixture = try await runner.loadRuntimeFixture(
            maxContextTokens: cell.promptTokens + cell.maxTokens + 256,
            knownTargetIdentity: verifiedTargetIdentity,
            ordinaryAdmissionRecorder: nil,
            nativeAdmissionRecorder: NativeMTPHardwareAdmissionRecorder()
        )
        let recorder = NativeMTPLoadGateRecorder()
        guard await fixture.runtimes.native.installLabNativeMTPLoadGateRecorder(recorder) else {
            throw NativeMTPBenchError.assertionFailed("native runtime has no continuous-batch scheduler")
        }
        nativeLoadGateRecorder = recorder
        return fixture
    }

    private func runPath(
        _ path: NativeMTPBenchPath,
        cell: NativeMTPBenchCell,
        block: Int,
        order: Int,
        prompts: [String],
        runtime: ModelRuntime,
        fixture: NativeMTPHardwareRuntimeFixture,
        writer: NativeMTPJSONLWriter?,
        warmup: Bool
    ) async throws -> NativeMTPBenchRunResult {
        let tokenObserver = NativeMTPLabCommittedTokenTimingObserver(captureTokenIDs: true)
        guard await runtime.installLabNativeMTPCommitTimingObserver(tokenObserver) else {
            throw NativeMTPBenchError.assertionFailed("token parity observer requires the continuous-batch scheduler")
        }
        let statusBefore = await runtime.currentSnapshot().nativeMTPStatus
        let memorySampler = NativeMTPMemorySampler()
        memorySampler.start()
        let started = Date()
        let thermalStart = ProcessInfo.processInfo.thermalState.label
        let modelID = self.modelID
        let temperature = policy.temperature
        let topP = policy.topP
        let requestShape = policy.requestShape
        let arrivalIntervalNanoseconds = UInt64(policy.arrivalIntervalMS) * 1_000_000
        let results = try await withThrowingTaskGroup(of: NativeMTPBenchRequestResult.self) { group in
            for (index, prompt) in prompts.enumerated() {
                group.addTask {
                    if arrivalIntervalNanoseconds > 0, index > 0 {
                        try await Task.sleep(nanoseconds: UInt64(index) * arrivalIntervalNanoseconds)
                    }
                    // Both paths use the same request ID (separate runtimes),
                    // so a sampled row draws the same seeded stream on each.
                    let requestID = "\(cell.id)-b\(block)-r\(index)"
                    let request = try NativeMTPBenchRequests.make(
                        modelID: modelID,
                        requestID: requestID,
                        prompt: prompt,
                        maxTokens: cell.maxTokens,
                        temperature: temperature,
                        topP: topP,
                        requestShape: requestShape
                    )
                    return try await Self.runStreamingRequest(request, runtime: runtime, tokenObserver: tokenObserver)
                }
            }
            var values: [NativeMTPBenchRequestResult] = []
            for try await value in group {
                values.append(value)
            }
            return values.sorted { $0.requestID < $1.requestID }
        }
        let ended = Date()
        memorySampler.stop()
        let statusAfter = await runtime.currentSnapshot().nativeMTPStatus
        let statusDelta = NativeMTPStatusDelta(before: statusBefore, after: statusAfter)
        let wall = max(ended.timeIntervalSince(started), 0.000_001)
        let committed = results.reduce(0) { $0 + $1.completion.completionTokens }
        let decodeTimings = results.map { result in
            let startOffset = result.startedAt.timeIntervalSince(started)
            return NativeMTPBenchDecodeTiming(
                completionTokens: result.completion.completionTokens,
                firstTokenOffset: result.ttftSeconds.map { startOffset + $0 },
                endOffset: startOffset + result.wallSeconds
            )
        }
        let ttfts = results.compactMap(\.ttftSeconds)
        let allGaps = results.flatMap(\.interTokenGaps)
        let peakFootprint = memorySampler.peakPhysFootprintBytes
        let admissions = path == .nativeMTP
            ? fixture.nativeAdmissionRecorder?.requestSnapshot().filter { item in
                item.requestID.map { Set(results.map(\.requestID)).contains($0) } ?? false
            } ?? []
            : []
        // A SPEC-048-R007 load-gate downgrade is the policy working, not a
        // fallback; every other non-native admission still fails the run.
        let loadGateDowngrades = admissions.filter {
            $0.admission.effectivePath != .nativeMTP
                && $0.admission.selection.nativeMTPReason == .capacityAboveNativeBound
        }.count
        var run = NativeMTPBenchRunResult(
            cell: cell,
            blockIndex: block,
            path: path,
            orderPosition: order,
            wallSeconds: wall,
            requests: results,
            committedCompletionTokens: committed,
            aggregateTPS: Double(committed) / wall,
            perRequestTPS: results.map { Double($0.completion.completionTokens) / max($0.wallSeconds, 0.000_001) },
            aggregateDecodeTPS: NativeMTPBenchDecodeThroughput.aggregate(decodeTimings),
            perRequestDecodeTPS: results.map {
                NativeMTPBenchDecodeThroughput.perRequest(
                    completionTokens: $0.completion.completionTokens,
                    ttftSeconds: $0.ttftSeconds,
                    wallSeconds: $0.wallSeconds
                )
            },
            ttftP50: percentile(ttfts, 0.50),
            ttftP95: percentile(ttfts, 0.95),
            interTokenGapP50: percentile(allGaps, 0.50),
            interTokenGapP95: percentile(allGaps, 0.95),
            rawInterTokenGaps: results.map(\.interTokenGaps),
            finishReasons: results.map(\.completion.finishReason),
            capacityRejections: Int(statusDelta.capacityRejections),
            fallbacks: Int(statusDelta.preoutputFallbacks + statusDelta.postoutputFailures),
            errors: 0,
            nativeAdmissions: admissions.filter { $0.admission.effectivePath == .nativeMTP }.count,
            nativeRequests: path == .nativeMTP ? results.count : 0,
            nonNativeAdmissions: admissions.filter { $0.admission.effectivePath != .nativeMTP }.count - loadGateDowngrades,
            loadGateDowngrades: loadGateDowngrades,
            missingNativeAdmissions: path == .nativeMTP ? max(0, results.count - admissions.count) : 0,
            effectivePaths: admissions.map {
                [
                    "request_id": $0.requestID ?? "",
                    "effective_path": $0.admission.effectivePath.rawValue,
                    "selector_reason": $0.admission.selection.nativeMTPReason?.rawValue ?? "",
                    "other_active_rows": $0.otherActiveRows,
                ] as [String: Any]
            },
            statusDelta: statusDelta,
            loadGate: path == .nativeMTP
                ? nativeLoadGateRecorder?.summary(requestIDs: Set(results.map(\.requestID)))
                : nil,
            targetForwardsPerCommittedToken: path == .nativeMTP && committed > 0
                ? Double(statusDelta.targetForwards) / Double(committed)
                : nil,
            peakPhysFootprintBytes: peakFootprint,
            minAvailableMemoryBytes: memorySampler.minAvailableBytes,
            minAvailableMemoryFraction: memorySampler.minAvailableFraction,
            thermalStart: thermalStart,
            thermalEnd: ProcessInfo.processInfo.thermalState.label,
            parityMismatch: false
        )
        if path == .nativeMTP, run.nonNativeAdmissions > 0 || run.missingNativeAdmissions > 0 {
            run.errors += 1
        }
        if let writer {
            try writer.write(run.record(policySHA256: policySHA256, sustained: false, warmup: warmup))
        }
        return run
    }

    /// SPEC-048-R015 prompt realization (`deterministic_synthetic_unique_v2`):
    /// the stratum is counted on the served prompt, after the chat template
    /// the runtime applies, and lies within ±2% of the nominal stratum. A
    /// stratum at or above the tuple's signed prompt cap is realized at or
    /// below the cap, so its native rows are not selected ordinary by R004.
    private func makePrompts(runtime: ModelRuntime, cell: NativeMTPBenchCell, block: Int) async throws -> [String] {
        let snapshot = await runtime.currentSnapshot()
        guard let container = snapshot.container else {
            throw NativeMTPBenchError.assertionFailed("runtime has no loaded container")
        }
        let thinkingToggle = snapshot.templateSupportsThinkingToggle
        let preserveThinking = snapshot.templateSupportsPreserveThinking
        let modelID = self.modelID
        let requestShape = policy.requestShape
        let lower = Int(ceil(Double(cell.promptTokens) * 0.98))
        var upper = Int(floor(Double(cell.promptTokens) * 1.02))
        var target = cell.promptTokens
        if let cap = policy.maximumPromptTokens, cell.promptTokens >= cap {
            upper = min(upper, cap)
            target = max(lower, cap - 24)
        }
        let finalUpper = upper
        let finalTarget = target
        return try await container.perform { context in
            func servedCount(_ text: String) async throws -> Int {
                let request = try NativeMTPBenchRequests.make(
                    modelID: modelID,
                    requestID: "prompt-sizing",
                    prompt: text,
                    maxTokens: 1,
                    temperature: 0,
                    requestShape: requestShape
                )
                let input = try ModelRuntime.userInput(
                    for: request,
                    templateSupportsThinkingToggle: thinkingToggle,
                    templateSupportsPreserveThinking: preserveThinking
                )
                return try await context.processor.prepare(input: input).text.tokens.size
            }
            var prompts: [String] = []
            for row in 0..<cell.slots {
                func saltedText(_ salts: Int) -> String {
                    (0..<salts).reduce("Native MTP R015 deterministic prompt cell \(cell.id) block \(block) row \(row).") {
                        $0 + " measurement-\(block)-\(row)-\($1) throughput parity tokens"
                    }
                }
                let (salts, count) = try await NativeMTPBenchPrompts.fewestReachingSalts(target: finalTarget) {
                    try await servedCount(saltedText($0))
                }
                let text = saltedText(salts)
                guard (lower...finalUpper).contains(count) else {
                    throw NativeMTPBenchError.assertionFailed(
                        "served prompt token count \(count) outside \(lower)...\(finalUpper) for stratum \(cell.promptTokens)"
                    )
                }
                prompts.append(text)
            }
            return prompts
        }
    }

    private func parityMismatch(ordinary: NativeMTPBenchRunResult, native: NativeMTPBenchRunResult) -> Bool {
        guard ordinary.requests.count == native.requests.count else { return true }
        for (lhs, rhs) in zip(ordinary.requests, native.requests) {
            if lhs.outputTokenIDs.isEmpty || lhs.outputTokenIDs != rhs.outputTokenIDs { return true }
            if lhs.completion.content != rhs.completion.content { return true }
            if lhs.completion.reasoningContent != rhs.completion.reasoningContent { return true }
            if lhs.completion.completionTokens != rhs.completion.completionTokens { return true }
            if !Self.toolCallsHaveParity(lhs.completion.toolCalls, rhs.completion.toolCalls) { return true }
            if lhs.completion.finishReason != rhs.completion.finishReason { return true }
        }
        return false
    }

    static func toolCallsHaveParity(_ lhs: [ToolCall]?, _ rhs: [ToolCall]?) -> Bool {
        // Parser-generated UUIDs are response metadata. The model's ordered
        // function names and exact argument bytes must still match.
        let lhs = lhs ?? []
        let rhs = rhs ?? []
        return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
            pair.0.functionName == pair.1.functionName && pair.0.arguments == pair.1.arguments
        }
    }

    private func baseHeader(
        targetIdentity: MLXSnapshotIdentity,
        mtpIdentity: MLXSnapshotIdentity,
        tokenizerSHA256: String,
        environment: NativeMTPBenchEnvironment
    ) -> [String: Any] {
        return [
            "schema": "macprovider.native-mtp-r015-run.v1",
            "record_type": "header",
            "machine": [
                "hw_model": environment.hwModel,
                "chip": environment.chip,
                "ram_gb": environment.ramGB,
                "os_version": environment.osVersion,
                "os_build": environment.osBuild,
            ],
            "xcode_build_version": environment.xcodeBuildVersion,
            "swift_version": environment.swiftVersion,
            "provider_commit": providerCommit,
            "mlx_fork_revision": NativeMTPHardwareE2ERunner.upstreamRevision,
            "model_id": modelID,
            "target_sha256": targetIdentity.digest,
            "mtp_sha256": mtpIdentity.digest,
            "tokenizer_sha256": tokenizerSHA256,
            "policy_sha256": policySHA256,
            "exploratory": policy.exploratory,
            "max_native_active_rows": policy.maxNativeActiveRows.map { $0 as Any } ?? NSNull(),
            "qualified_slots": policy.qualifiedSlots.map { $0 as Any } ?? NSNull(),
            "maximum_prompt_tokens": policy.maximumPromptTokens.map { $0 as Any } ?? NSNull(),
            "temperature": policy.temperature,
            "top_p": policy.topP,
            "request_shape": policy.requestShape,
            "diagnostic_eligibility_bypass": policy.diagnosticEligibilityBypass,
            "proposal_depth": policy.proposalDepth,
            "arrival_interval_ms": policy.arrivalIntervalMS,
            // 2: run records carry decode-only throughput (SPEC-048-R015).
            // 3: effective_paths carry each admission's other_active_rows.
            // 4: native runs carry the scheduler's gated_* load-gate evidence.
            // 5: sustained records carry sustained_window_id.
            "run_metrics_version": 5,
        ]
    }

    private static func runStreamingRequest(_ request: ChatCompletionRequest, runtime: ModelRuntime, tokenObserver: NativeMTPLabCommittedTokenTimingObserver) async throws -> NativeMTPBenchRequestResult {
        guard let requestID = request.requestID else {
            throw NativeMTPBenchError.assertionFailed("request missing id")
        }
        let start = Date()
        let handle = try await runtime.acquireRequestHandle(request)
        let chunks = NativeMTPChunkTimeRecorder()
        let completion: CompletionResult
        do {
            completion = try await runtime.stream(request, with: handle) { chunk in
                chunks.observe(chunk)
            }
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        await runtime.unregisterInFlight(handle.registrationID)
        let end = Date()
        let timing = chunks.timing(since: start)
        return NativeMTPBenchRequestResult(
            requestID: requestID,
            startedAt: start,
            completion: completion,
            wallSeconds: end.timeIntervalSince(start),
            ttftSeconds: timing.ttftSeconds,
            interTokenGaps: timing.interTokenGaps,
            outputTokenIDs: tokenObserver.snapshot().filter { $0.requestID == requestID }.sorted { $0.ordinal < $1.ordinal }.compactMap(\.tokenID)
        )
    }

    private static func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeMTPBenchError.missingDirectory(url.path)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// The bench's request for one profile. Parsed by the production validator,
/// so a profile the runtime would refuse fails before any model load.
enum NativeMTPBenchRequests {
    static func make(
        modelID: String,
        requestID: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double = 1,
        requestShape: String = "plain_text"
    ) throws -> ChatCompletionRequest {
        var object: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": topP,
            "stream": true,
        ]
        if requestShape == "tools_history_reasoning" {
            object["tools"] = [["type": "function", "function": [
                "name": "read_file", "description": "Read a project source file.",
                "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
            ]]]
            object["messages"] = [
                ["role": "user", "content": "Read the project file before answering."],
                ["role": "assistant", "content": "", "tool_calls": [[
                    "id": "call_baselinereadfile0001", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"main.swift\"}"],
                ]]],
                ["role": "tool", "tool_call_id": "call_baselinereadfile0001", "content": "func main() { print(42) }"],
                ["role": "user", "content": prompt],
            ]
            // Use the production-rendered reasoning control; chat_template_kwargs
            // is not consumed by the request parser and would be a no-op here.
            object["reasoning_effort"] = "high"
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ChatCompletionRequest.parse(data: data).withRequestID(requestID)
    }
}

struct NativeMTPBenchEnvironment {
    let hwModel: String
    let chip: String
    let ramGB: Int
    let osVersion: String
    let osBuild: String
    let xcodeBuildVersion: String
    let swiftVersion: String
    let providerCommit: String

    static func capture(providerCommit: String) -> NativeMTPBenchEnvironment {
        let machine = MachineFingerprinter().sample()
        let xcode = commandOutput("/usr/bin/xcodebuild", ["-version"])
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("Build version ") }
            .map { String($0.dropFirst("Build version ".count)) } ?? "unknown"
        let swift = commandOutput("/usr/bin/xcrun", ["swift", "--version"])
            .split(whereSeparator: \.isNewline)
            .first.map(String.init) ?? "unknown"
        return NativeMTPBenchEnvironment(
            hwModel: sysctlString("hw.model") ?? "unknown",
            chip: machine.chip,
            ramGB: machine.ramGB,
            osVersion: machine.osVersion,
            osBuild: sysctlString("kern.osversion") ?? "unknown",
            xcodeBuildVersion: xcode,
            swiftVersion: swift,
            providerCommit: providerCommit
        )
    }

    private static func commandOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        } catch {
            return ""
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

private enum NativeMTPBenchPath: String {
    case ordinary
    case nativeMTP = "native_mtp"
}

struct NativeMTPBenchCell: Sendable, Equatable {
    let slots: Int
    let promptTokens: Int
    let maxTokens: Int
    var id: String { "s\(slots)-p\(promptTokens)-o\(maxTokens)" }

    init(slots: Int, promptTokens: Int, maxTokens: Int) {
        self.slots = slots
        self.promptTokens = promptTokens
        self.maxTokens = maxTokens
    }

    /// Parses an exact canonical `s<slots>-p<prompt>-o<output>` id.
    init?(id: String) {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].first == "s", parts[1].first == "p", parts[2].first == "o",
              let slots = Int(parts[0].dropFirst()),
              let prompt = Int(parts[1].dropFirst()),
              let output = Int(parts[2].dropFirst()),
              slots > 0, prompt > 0, output > 0 else {
            return nil
        }
        self.init(slots: slots, promptTokens: prompt, maxTokens: output)
        guard self.id == id else { return nil }
    }
}

private struct NativeMTPBenchRequestResult: Sendable {
    let requestID: String
    let startedAt: Date
    let completion: CompletionResult
    let wallSeconds: TimeInterval
    let ttftSeconds: TimeInterval?
    let interTokenGaps: [TimeInterval]
    let outputTokenIDs: [Int]

    /// SPEC-048 parity covers every generated token, so a SPEC-018 §3.12
    /// reasoning split is hashed too: reasoning, a NUL, then content. Without
    /// reasoning this stays the plain content hash.
    var contentSHA256: String {
        var data = Data()
        if let reasoning = completion.reasoningContent, !reasoning.isEmpty {
            data.append(contentsOf: reasoning.utf8)
            data.append(0)
        }
        data.append(contentsOf: completion.content.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct NativeMTPBenchRunResult {
    let cell: NativeMTPBenchCell
    let blockIndex: Int
    let path: NativeMTPBenchPath
    let orderPosition: Int
    let wallSeconds: TimeInterval
    let requests: [NativeMTPBenchRequestResult]
    let committedCompletionTokens: Int
    let aggregateTPS: Double
    let perRequestTPS: [Double]
    let aggregateDecodeTPS: Double?
    let perRequestDecodeTPS: [Double?]
    let ttftP50: Double?
    let ttftP95: Double?
    let interTokenGapP50: Double?
    let interTokenGapP95: Double?
    let rawInterTokenGaps: [[Double]]
    let finishReasons: [String]
    let capacityRejections: Int
    let fallbacks: Int
    var errors: Int
    let nativeAdmissions: Int
    let nativeRequests: Int
    var nonNativeAdmissions: Int
    let loadGateDowngrades: Int
    let missingNativeAdmissions: Int
    let effectivePaths: [[String: Any]]
    let statusDelta: NativeMTPStatusDelta
    /// Scheduler in-flight load-gate evidence; nil on the ordinary path.
    let loadGate: NativeMTPLoadGateRecorder.Summary?
    let targetForwardsPerCommittedToken: Double?
    let peakPhysFootprintBytes: UInt64?
    let minAvailableMemoryBytes: UInt64?
    let minAvailableMemoryFraction: Double?
    let thermalStart: String
    let thermalEnd: String
    var parityMismatch: Bool

    func record(
        policySHA256: String,
        sustained: Bool,
        warmup: Bool,
        sustainedWindowElapsedSeconds: Double? = nil,
        sustainedWindowID: String? = nil
    ) -> [String: Any] {
        [
            "schema": "macprovider.native-mtp-r015-run.v1",
            "record_type": "run",
            "policy_sha256": policySHA256,
            "cell_id": cell.id,
            "slots": cell.slots,
            "prompt_tokens": cell.promptTokens,
            "max_tokens": cell.maxTokens,
            "block_index": blockIndex,
            "path": path.rawValue,
            "order_position": orderPosition,
            "warmup": warmup,
            "sustained": sustained,
            "sustained_window_elapsed_seconds": sustainedWindowElapsedSeconds as Any,
            "sustained_window_id": sustainedWindowID as Any,
            "requests": requests.count,
            "wall_seconds": wallSeconds,
            "committed_completion_tokens": committedCompletionTokens,
            "aggregate_committed_tps": aggregateTPS,
            "per_request_tps": perRequestTPS,
            "aggregate_decode_tps": aggregateDecodeTPS.map { $0 as Any } ?? NSNull(),
            "per_request_decode_tps": perRequestDecodeTPS.map { $0.map { $0 as Any } ?? NSNull() },
            "per_request_ttft_seconds": requests.map { request in
                request.ttftSeconds.map { $0 as Any } ?? NSNull()
            },
            "request_metrics": requests.indices.map { index in
                let request = requests[index]
                return [
                    "request_id": request.requestID,
                    "content_sha256": request.contentSHA256,
                    "output_token_ids": request.outputTokenIDs,
                    "completion_tokens": request.completion.completionTokens,
                    "committed_tps": perRequestTPS[index],
                    "decode_tps": perRequestDecodeTPS[index].map { $0 as Any } ?? NSNull(),
                    "ttft_seconds": request.ttftSeconds.map { $0 as Any } ?? NSNull(),
                    "inter_token_gaps_seconds": request.interTokenGaps,
                    "finish_reason": request.completion.finishReason,
                ] as [String: Any]
            },
            "ttft_p50_seconds": ttftP50 as Any,
            "ttft_p95_seconds": ttftP95 as Any,
            "inter_token_gap_p50_seconds": interTokenGapP50 as Any,
            "inter_token_gap_p95_seconds": interTokenGapP95 as Any,
            "raw_inter_token_gaps_seconds": rawInterTokenGaps,
            "finish_reasons": finishReasons,
            "capacity_rejections": capacityRejections,
            "fallbacks": fallbacks,
            "errors": errors,
            "native_admissions": nativeAdmissions,
            "native_requests": nativeRequests,
            "non_native_admissions": nonNativeAdmissions,
            "load_gate_downgrades": loadGateDowngrades,
            "missing_native_admissions": missingNativeAdmissions,
            "effective_paths": effectivePaths,
            "mtp_proposed_tokens": statusDelta.proposedTokens,
            "mtp_accepted_tokens": statusDelta.acceptedTokens,
            "mtp_rejected_tokens": statusDelta.rejectedTokens,
            "mtp_accepted_by_position": statusDelta.acceptedByPosition,
            "target_forwards": statusDelta.targetForwards,
            "mtp_forwards": statusDelta.mtpForwards,
            "target_forwards_per_committed_token": targetForwardsPerCommittedToken as Any,
            "peak_phys_footprint_bytes": peakPhysFootprintBytes as Any,
            "min_available_memory_bytes": minAvailableMemoryBytes as Any,
            "min_available_memory_fraction": minAvailableMemoryFraction as Any,
            "thermal_state_start": thermalStart,
            "thermal_state_end": thermalEnd,
            "parity_mismatch": parityMismatch,
            "gated_depth_zero_rounds": loadGate.map { $0.depthZeroRounds as Any } ?? NSNull(),
            "gated_hold_episodes": loadGate.map { $0.holdEpisodes as Any } ?? NSNull(),
            "gated_depth_restorations": loadGate.map { $0.depthRestorations as Any } ?? NSNull(),
            "gated_held_finishes_clean": loadGate.map { $0.heldFinishesClean as Any } ?? NSNull(),
            "gated_held_unresolved": loadGate.map { $0.heldUnresolved as Any } ?? NSNull(),
        ]
    }
}

/// One request's decode timing, with offsets from the start of its run.
struct NativeMTPBenchDecodeTiming: Sendable, Equatable {
    let completionTokens: Int
    let firstTokenOffset: TimeInterval?
    let endOffset: TimeInterval
}

/// SPEC-048-R015 decode-only throughput. Prefill (time to first token) is the
/// same work on both paths, so it is excluded here and gated separately as
/// TTFT; end-to-end throughput stays reported as `aggregate_committed_tps`.
/// Every undefined case returns nil so the analyzer fails the record closed
/// instead of reading a defaulted value.
enum NativeMTPBenchDecodeThroughput {
    /// (completion tokens - 1) / (request wall - TTFT).
    static func perRequest(completionTokens: Int, ttftSeconds: TimeInterval?, wallSeconds: TimeInterval) -> Double? {
        guard let ttftSeconds, completionTokens >= 2 else { return nil }
        let window = wallSeconds - ttftSeconds
        guard window > 0, window.isFinite else { return nil }
        return Double(completionTokens - 1) / window
    }

    /// Sum of every request's tokens after its first, over the run's decode
    /// window: earliest first token to latest completion. With concurrent or
    /// staggered rows this window also covers other rows' prefills, which is
    /// the same overlap on both paths. One slot reduces to `perRequest`.
    static func aggregate(_ timings: [NativeMTPBenchDecodeTiming]) -> Double? {
        guard !timings.isEmpty else { return nil }
        var firstToken = TimeInterval.infinity
        var decodeTokens = 0
        for timing in timings {
            guard let offset = timing.firstTokenOffset, timing.completionTokens >= 1 else { return nil }
            firstToken = min(firstToken, offset)
            decodeTokens += timing.completionTokens - 1
        }
        let window = (timings.map(\.endOffset).max() ?? 0) - firstToken
        guard decodeTokens > 0, window > 0, window.isFinite else { return nil }
        return Double(decodeTokens) / window
    }
}

struct NativeMTPStatusDelta {
    let proposedTokens: UInt64
    let acceptedTokens: UInt64
    let rejectedTokens: UInt64
    let acceptedByPosition: [UInt64]
    let targetForwards: UInt64
    let mtpForwards: UInt64
    let preoutputFallbacks: UInt64
    let postoutputFailures: UInt64
    let capacityRejections: UInt64

    init(before: NativeMTPStatusSnapshot, after: NativeMTPStatusSnapshot) {
        self.proposedTokens = after.proposedTokens &- before.proposedTokens
        self.acceptedTokens = after.acceptedTokens &- before.acceptedTokens
        self.rejectedTokens = after.rejectedTokens &- before.rejectedTokens
        self.acceptedByPosition = zip(after.acceptedByPosition, before.acceptedByPosition).map { $0 &- $1 }
        self.targetForwards = after.targetForwards &- before.targetForwards
        self.mtpForwards = after.mtpForwards &- before.mtpForwards
        self.preoutputFallbacks = after.preoutputFallbacks &- before.preoutputFallbacks
        self.postoutputFailures = after.postoutputFailures &- before.postoutputFailures
        self.capacityRejections = after.capacityRejections &- before.capacityRejections
    }
}

final class NativeMTPChunkTimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date] = []

    /// SPEC-048-R015 TTFT, inter-chunk gaps and decode throughput are timed on
    /// generated tokens, so SPEC-018 §3.12 reasoning chunks count like content.
    func observe(_ chunk: StreamChunk, at time: Date = Date()) {
        switch chunk {
        case .content(let text), .reasoning(let text):
            if !text.isEmpty { append(time) }
        case .toolCallDelta:
            break
        }
    }

    func append(_ value: Date) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Date] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func timing(since start: Date) -> (ttftSeconds: TimeInterval?, interTokenGaps: [TimeInterval]) {
        let times = snapshot()
        return (times.first?.timeIntervalSince(start), zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) })
    }
}

private final class NativeMTPMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var sampledMinAvailableBytes: UInt64?
    private var sampledMinAvailableFraction: Double?
    private var sampledPeakPhysFootprintBytes: UInt64?

    var minAvailableBytes: UInt64? { locked { sampledMinAvailableBytes } }
    var minAvailableFraction: Double? { locked { sampledMinAvailableFraction } }
    var peakPhysFootprintBytes: UInt64? { locked { sampledPeakPhysFootprintBytes } }

    func start() {
        recordSample()
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled { self.recordSample() }
            }
        }
    }

    func stop() {
        task?.cancel()
        recordSample()
    }

    private func recordSample() {
        guard let sample = Self.sample() else { return }
        let footprint = NativeMTPBenchRunner.physFootprintBytes()
        lock.lock()
        sampledMinAvailableBytes = min(sampledMinAvailableBytes ?? sample.availableBytes, sample.availableBytes)
        sampledMinAvailableFraction = min(sampledMinAvailableFraction ?? sample.fraction, sample.fraction)
        if footprint > 0 {
            sampledPeakPhysFootprintBytes = max(sampledPeakPhysFootprintBytes ?? footprint, footprint)
        }
        lock.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    deinit {
        task?.cancel()
    }

    private static func sample() -> (availableBytes: UInt64, fraction: Double)? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        let available = pages * UInt64(pageSize)
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0, memsize > 0 else {
            return (available, 0)
        }
        return (available, Double(available) / Double(memsize))
    }
}

struct NativeMTPBenchPolicy {
    /// SPEC-048-R015 native-eligible prompt strata (tokens, realized within
    /// ±2%) before the tuple's signed prompt cap is applied.
    static let nativeEligiblePromptStrata: [Int] = [1536, 4096]
    /// SPEC-048-R015 mandatory fixed short and long output budgets.
    static let mandatoryMaxTokens: Set<Int> = [128, 512]
    /// SPEC-048-R015 gated and sustained cells run at this prompt and output.
    static let gatedPromptTokens = 1536
    static let gatedMaxTokens = 512
    static let minimumSustainedSeconds = 1800

    /// SPEC-048-R015 native-eligible prompt strata for a tuple whose signed
    /// SPEC-023-R024 `max_prompt_tokens` is `cap`: 1536 and 4096 at or below
    /// the cap, plus the cap itself.
    static func mandatoryPromptTokens(cap: Int) -> [Int] {
        Array(Set(nativeEligiblePromptStrata.filter { $0 <= cap } + [cap])).sorted()
    }

    /// SPEC-048-R015 gated cells: slot counts bound + 1 and qualified_slots at
    /// the gated prompt/output (one cell when those coincide; none when the
    /// bound covers every slot).
    static func mandatoryGatedCellIDs(bound: Int, qualifiedSlots: Int) -> [String] {
        guard bound < qualifiedSlots else { return [] }
        return Array(Set([bound + 1, qualifiedSlots])).sorted().map {
            NativeMTPBenchCell(slots: $0, promptTokens: gatedPromptTokens, maxTokens: gatedMaxTokens).id
        }
    }

    let slots: [Int]
    let promptTokens: [Int]
    let maxTokens: [Int]
    /// Cells measured outside the native-eligible cross product (policy
    /// `gated_cells`), in policy order.
    let gatedCells: [NativeMTPBenchCell]
    /// The tuple's signed SPEC-023-R024 `max_prompt_tokens`. Required for an
    /// admission policy; it caps the native-eligible prompt strata.
    let maximumPromptTokens: Int?
    let warmupRuns: Int
    let blocks: Int
    let seed: Int
    let sustainedSeconds: Int
    let sustainedCellID: String
    let memorySafetyMarginBytes: UInt64
    let thresholds: [String: Any]
    let modelID: String
    let targetSHA256: String
    let mtpSHA256: String
    let tokenizerSHA256: String
    let hwModel: String
    let chip: String
    let ramGB: Int
    let osBuild: String
    let xcodeBuildVersion: String
    let swiftVersion: String
    let providerCommit: String
    let mlxForkRevision: String
    /// The tuple's advertised `qualified_slots` (SPEC-023-R024, 2...8).
    /// Required for an admission policy, whose matrix must cover every slot
    /// count from one up to it.
    let qualifiedSlots: Int?
    /// SPEC-048-R007 bound signed into the bench sidecar. Required for an
    /// admission policy; absent in a pilot means the bound equals each cell's
    /// qualified slot count (gate never engages).
    let maxNativeActiveRows: Int?
    let proposalDepth: Int
    /// Request temperature for every row of both paths (default greedy). A
    /// sampled row's seed derives from its request ID, which both paths
    /// share, so seeded parity is still a token-identity comparison.
    let temperature: Double
    let topP: Double
    let requestShape: String
    /// Only the exploratory lab command may bypass admission eligibility;
    /// every record names the bypass and cannot qualify a production tuple.
    let diagnosticEligibilityBypass: Bool
    /// Staggered arrival: row `i` of a block starts `i *` this many
    /// milliseconds after the block, so load crosses the native active-row
    /// bound mid-flight. Zero submits every row at once.
    let arrivalIntervalMS: Int
    /// Exploratory policies relax the R015 minimums for pilots; every record is
    /// stamped `exploratory` and the analyzer refuses an admission verdict.
    let exploratory: Bool
    var quantization: String = "4bit"

    static func load(from url: URL) throws -> NativeMTPBenchPolicy {
        let data = try Data(contentsOf: url)
        try NativeMTPBenchJSON.rejectDuplicateKeys(data, label: "policy")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeMTPBenchError.invalidPolicy("policy must be a JSON object")
        }
        let allowed: Set<String> = [
            "schema", "model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256",
            "slots", "prompt_tokens", "max_tokens", "warmup_runs", "blocks", "seed",
            "sustained_seconds", "sustained_cell_id", "memory_safety_margin_bytes", "thresholds",
            "hw_model", "chip", "ram_gb", "os_build", "xcode_build_version", "swift_version",
            "provider_commit", "mlx_fork_revision", "quantization", "cache_mode", "proposal_depth",
            "run_order", "prompt_corpus", "exclusion_rules", "confidence_method",
            "max_native_active_rows", "qualified_slots", "temperature", "arrival_interval_ms",
            "gated_cells", "maximum_prompt_tokens", "top_p", "request_shape", "diagnostic_eligibility_bypass",
        ]
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw NativeMTPBenchError.invalidPolicy("unknown keys: \(unknown.sorted())") }
        let exploratory: Bool
        switch object["schema"] as? String {
        case "macprovider.native-mtp-r015-policy.v1":
            exploratory = false
        case "macprovider.native-mtp-exploratory-policy.v1":
            exploratory = true
        default:
            throw NativeMTPBenchError.invalidPolicy("bad schema")
        }
        let thresholds = try dictionary(object, "thresholds")
        try requireThresholds(thresholds)
        let policy = NativeMTPBenchPolicy(
            slots: try slotCounts(object, "slots"),
            promptTokens: try positiveIntArray(object, "prompt_tokens"),
            maxTokens: try positiveIntArray(object, "max_tokens"),
            gatedCells: try gatedCellList(object, "gated_cells"),
            maximumPromptTokens: object["maximum_prompt_tokens"] == nil
                ? nil
                : try intAtLeast(object, "maximum_prompt_tokens", 1),
            warmupRuns: try nonnegativeInt(object, "warmup_runs"),
            blocks: try intAtLeast(object, "blocks", exploratory ? 2 : 10),
            seed: try nonnegativeInt(object, "seed"),
            sustainedSeconds: try intAtLeast(object, "sustained_seconds", exploratory ? 0 : minimumSustainedSeconds),
            sustainedCellID: try string(object, "sustained_cell_id"),
            memorySafetyMarginBytes: UInt64(try nonnegativeInt(object, "memory_safety_margin_bytes")),
            thresholds: thresholds,
            modelID: try string(object, "model_id"),
            targetSHA256: try hex64(object, "target_sha256"),
            mtpSHA256: try hex64(object, "mtp_sha256"),
            tokenizerSHA256: try hex64(object, "tokenizer_sha256"),
            hwModel: try string(object, "hw_model"),
            chip: try string(object, "chip"),
            ramGB: try intAtLeast(object, "ram_gb", 1),
            osBuild: try string(object, "os_build"),
            xcodeBuildVersion: try string(object, "xcode_build_version"),
            swiftVersion: try string(object, "swift_version"),
            providerCommit: try hex40(object, "provider_commit"),
            mlxForkRevision: try hex40(object, "mlx_fork_revision"),
            qualifiedSlots: object["qualified_slots"] == nil
                ? nil
                : try intAtLeast(object, "qualified_slots", 2),
            maxNativeActiveRows: object["max_native_active_rows"] == nil
                ? nil
                : try intAtLeast(object, "max_native_active_rows", 1),
            proposalDepth: try intAtLeast(object, "proposal_depth", 1),
            temperature: try samplingTemperature(object, "temperature"),
            topP: try topPValue(object),
            requestShape: try requestShapeValue(object),
            diagnosticEligibilityBypass: try diagnosticBypassValue(object, exploratory: exploratory),
            arrivalIntervalMS: object["arrival_interval_ms"] == nil
                ? 0
                : try nonnegativeInt(object, "arrival_interval_ms"),
            exploratory: exploratory,
            quantization: try string(object, "quantization")
        )
        try policy.validateMatrix()
        guard (1...5).contains(policy.proposalDepth),
              ["4bit", "mlx_mxfp4_mxfp8"].contains(policy.quantization) else {
            throw NativeMTPBenchError.invalidPolicy("unsupported quantization or proposal_depth")
        }
        if policy.quantization == "4bit" {
            guard policy.proposalDepth == 1 || (exploratory && policy.proposalDepth == 2) else {
                throw NativeMTPBenchError.invalidPolicy("proposal_depth must equal 1 outside a depth-2 exploratory policy")
            }
        }
        let fixedMethodology: [String: AnyHashable] = [
            "cache_mode": "paged_kv_mixed",
            "run_order": "seeded_random_counterbalanced",
            "prompt_corpus": "deterministic_synthetic_unique_v2",
            "exclusion_rules": "none",
            "confidence_method": "paired_block_bootstrap_holm_v1",
        ]
        for (key, expected) in fixedMethodology {
            guard let actual = object[key] as? AnyHashable, actual == expected else {
                throw NativeMTPBenchError.invalidPolicy("\(key) must equal \(expected)")
            }
        }
        guard policy.cell(id: policy.sustainedCellID) != nil else {
            throw NativeMTPBenchError.invalidPolicy("sustained_cell_id must match a matrix cell")
        }
        return policy
    }

    private static func topPValue(_ object: [String: Any]) throws -> Double {
        guard let value = object["top_p"] else { return 1 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue <= 1 else {
            throw NativeMTPBenchError.invalidPolicy("top_p must be within (0, 1]")
        }
        return number.doubleValue
    }

    private static func requestShapeValue(_ object: [String: Any]) throws -> String {
        guard let value = object["request_shape"] else { return "plain_text" }
        guard let shape = value as? String, ["plain_text", "tools_history_reasoning"].contains(shape) else {
            throw NativeMTPBenchError.invalidPolicy("request_shape must be plain_text or tools_history_reasoning")
        }
        return shape
    }

    private static func diagnosticBypassValue(_ object: [String: Any], exploratory: Bool) throws -> Bool {
        guard let value = object["diagnostic_eligibility_bypass"] else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw NativeMTPBenchError.invalidPolicy("diagnostic_eligibility_bypass must be boolean")
        }
        guard !number.boolValue || exploratory else {
            throw NativeMTPBenchError.invalidPolicy("diagnostic eligibility bypass requires exploratory schema")
        }
        return number.boolValue
    }

    /// SPEC-048-R015 preregistered, counterbalanced run order: per cell, half
    /// the blocks (rounded up) run native first, shuffled by a Fisher-Yates
    /// permutation seeded from the frozen policy seed and the cell. The
    /// analyzer recomputes this exactly (scripts/native_mtp_r015_analyze.py
    /// `_native_first_order`) and rejects any block run in another order.
    static func nativeFirstOrder(seed: Int, cell: NativeMTPBenchCell, blocks: Int) -> [Bool] {
        guard blocks > 0 else { return [] }
        var order = (0..<blocks).map { $0 < (blocks + 1) / 2 }
        var value = UInt64(truncatingIfNeeded: seed)
        for component in [cell.slots, cell.promptTokens, cell.maxTokens] {
            value ^= UInt64(truncatingIfNeeded: component) &+ 0x9e3779b97f4a7c15 &+ (value << 6) &+ (value >> 2)
        }
        var rng = SeededRandom(seed: value)
        for index in stride(from: blocks - 1, to: 0, by: -1) {
            let swapIndex = Int(rng.next() % UInt64(index + 1))
            order.swapAt(index, swapIndex)
        }
        return order
    }

    func qualifiedSlots(for cell: NativeMTPBenchCell) -> Int {
        max(2, cell.slots)
    }

    /// The fixture family's own tuple limits, checked before any model load:
    /// an unsupported sampled profile routes rows to ordinary decode, and
    /// a family that signs a native active-row bound measures at
    /// most that bound, so either mismatch could only fail after the load.
    func validateFamily(_ family: NativeMTPHardwareE2EFamily) throws {
        guard proposalDepth <= family.maximumProposalDepth,
              quantization == family.quantizationLabel else {
            throw NativeMTPBenchError.invalidPolicy("quantization or proposal_depth does not match \(family.familyAdapter)")
        }
        if family != .deepseekV4, proposalDepth > 1 {
            guard exploratory, family == .glm5Next, let bound = maxNativeActiveRows, bound <= 2 else {
                throw NativeMTPBenchError.invalidPolicy("depth-2 exploration requires glm5_next and max_native_active_rows at most 2")
            }
        }
        if !family.admitsSampledRows, (temperature > 0 || topP != 1), !diagnosticEligibilityBypass {
            throw NativeMTPBenchError.invalidPolicy(
                "temperature must be 0: \(family.familyAdapter) admits greedy rows only"
            )
        }
        if let signed = family.implementationMaxNativeActiveRows, !exploratory {
            guard let bound = maxNativeActiveRows, bound <= signed else {
                throw NativeMTPBenchError.invalidPolicy(
                    "max_native_active_rows must be at most \(signed) for \(family.familyAdapter)"
                )
            }
        }
    }

    /// The runtime bound for one cell. A cell's runtime is qualified at its
    /// own slot count, and a signed bound may not exceed that; a cell at or
    /// below the policy bound never engages the gate either way.
    func maxNativeActiveRows(for cell: NativeMTPBenchCell) -> Int? {
        maxNativeActiveRows.map { min($0, qualifiedSlots(for: cell)) }
    }

    /// Every measured cell: the native-eligible cross product of `slots`,
    /// `prompt_tokens`, and `max_tokens`, then the policy's `gated_cells`.
    var matrixCells: [NativeMTPBenchCell] {
        var cells: [NativeMTPBenchCell] = []
        for slots in slots {
            for prompt in promptTokens {
                for output in maxTokens {
                    cells.append(NativeMTPBenchCell(slots: slots, promptTokens: prompt, maxTokens: output))
                }
            }
        }
        return cells + gatedCells
    }

    /// SPEC-048-R015 / R007: an admission policy measures exactly the
    /// mandatory matrix before any measurement, so a reduced or substituted
    /// matrix can never be analyzed to PASS. Native-eligible cells are every
    /// slot count from one to the bound at every capped prompt stratum and
    /// both output budgets; gated cells are bound + 1 and qualified_slots at
    /// the gated prompt/output; the sustained window runs at qualified_slots.
    func validateMatrix() throws {
        if let qualifiedSlots, qualifiedSlots > 8 {
            throw NativeMTPBenchError.invalidPolicy("qualified_slots must be within 2...8")
        }
        let cells = matrixCells
        guard Set(cells.map(\.id)).count == cells.count else {
            throw NativeMTPBenchError.invalidPolicy("gated_cells duplicate a matrix cell")
        }
        let maximumSlots = qualifiedSlots ?? max(2, cells.map(\.slots).max() ?? 2)
        if let qualifiedSlots, let over = cells.first(where: { $0.slots > qualifiedSlots }) {
            throw NativeMTPBenchError.invalidPolicy("cell \(over.id) exceeds qualified_slots \(qualifiedSlots)")
        }
        if let bound = maxNativeActiveRows, bound > maximumSlots {
            throw NativeMTPBenchError.invalidPolicy(
                "max_native_active_rows \(bound) exceeds qualified slots \(maximumSlots)"
            )
        }
        guard !exploratory else { return }
        guard let qualifiedSlots else {
            throw NativeMTPBenchError.invalidPolicy("qualified_slots is required")
        }
        guard let bound = maxNativeActiveRows else {
            throw NativeMTPBenchError.invalidPolicy("max_native_active_rows is required")
        }
        guard let cap = maximumPromptTokens else {
            throw NativeMTPBenchError.invalidPolicy("maximum_prompt_tokens is required")
        }
        guard (Self.gatedPromptTokens...1_048_576).contains(cap) else {
            throw NativeMTPBenchError.invalidPolicy("maximum_prompt_tokens must be within \(Self.gatedPromptTokens)...1048576 (SPEC-023-R024)")
        }
        // A gated cell must exercise the in-flight hold: the first request
        // admits native before later arrivals cross the bound.
        if cells.contains(where: { $0.slots > bound }), arrivalIntervalMS <= 0 {
            throw NativeMTPBenchError.invalidPolicy("arrival_interval_ms must be > 0 when a cell exceeds max_native_active_rows")
        }
        guard slots.sorted() == Array(1...bound) else {
            throw NativeMTPBenchError.invalidPolicy("slots must be exactly 1...\(bound) (max_native_active_rows)")
        }
        let expectedPrompts = Self.mandatoryPromptTokens(cap: cap)
        guard promptTokens.sorted() == expectedPrompts else {
            throw NativeMTPBenchError.invalidPolicy("prompt_tokens must be exactly \(expectedPrompts) for maximum_prompt_tokens \(cap)")
        }
        guard Set(maxTokens) == Self.mandatoryMaxTokens else {
            throw NativeMTPBenchError.invalidPolicy("max_tokens must be exactly \(Self.mandatoryMaxTokens.sorted())")
        }
        let expectedGated = Self.mandatoryGatedCellIDs(bound: bound, qualifiedSlots: qualifiedSlots)
        guard gatedCells.map(\.id).sorted() == expectedGated else {
            throw NativeMTPBenchError.invalidPolicy("gated_cells must be exactly \(expectedGated)")
        }
        let expectedSustained = NativeMTPBenchCell(
            slots: qualifiedSlots,
            promptTokens: Self.gatedPromptTokens,
            maxTokens: Self.gatedMaxTokens
        ).id
        guard sustainedCellID == expectedSustained else {
            throw NativeMTPBenchError.invalidPolicy("sustained_cell_id must be \(expectedSustained)")
        }
    }

    func validateObserved(modelID observedModelID: String, targetSHA256 observedTarget: String, mtpSHA256 observedMTP: String, tokenizerSHA256 observedTokenizer: String) throws {
        guard modelID == observedModelID else { throw NativeMTPBenchError.invalidPolicy("model_id mismatch") }
        guard targetSHA256 == observedTarget else { throw NativeMTPBenchError.invalidPolicy("target_sha256 mismatch") }
        guard mtpSHA256 == observedMTP else { throw NativeMTPBenchError.invalidPolicy("mtp_sha256 mismatch") }
        guard tokenizerSHA256 == observedTokenizer else { throw NativeMTPBenchError.invalidPolicy("tokenizer_sha256 mismatch") }
    }

    func validateObserved(environment: NativeMTPBenchEnvironment) throws {
        let expected: [(String, AnyHashable, AnyHashable)] = [
            ("hw_model", hwModel, environment.hwModel),
            ("chip", chip, environment.chip),
            ("ram_gb", ramGB, environment.ramGB),
            ("os_build", osBuild, environment.osBuild),
            ("xcode_build_version", xcodeBuildVersion, environment.xcodeBuildVersion),
            ("swift_version", swiftVersion, environment.swiftVersion),
            ("provider_commit", providerCommit, environment.providerCommit),
            ("mlx_fork_revision", mlxForkRevision, NativeMTPHardwareE2ERunner.upstreamRevision),
        ]
        for (key, frozen, observed) in expected where frozen != observed {
            throw NativeMTPBenchError.invalidPolicy("\(key) mismatch: frozen=\(frozen) observed=\(observed)")
        }
    }

    func cell(id: String) -> NativeMTPBenchCell? {
        matrixCells.first { $0.id == id }
    }

    private static func requireThresholds(_ thresholds: [String: Any]) throws {
        let expected: [String: Double] = [
            "throughput_lower_bound_min": 0.15,
            "ttft_p95_upper_bound_max": 0.10,
            // SPEC-048 0.1.25: per-output-token latency and the worst-gap
            // bound (native p99 chunk gap at most proposal_depth + 1 = 2x
            // ordinary's) replace the inter-chunk p95 gate.
            "tpot_p95_upper_bound_max": 0.0,
            "chunk_gap_p99_upper_bound_max": 1.0,
            "rejection_increase_max_pp": 1.0,
            "min_available_memory_fraction": 0.10,
            "bootstrap_draws": 10000,
            "alpha": 0.05,
            // SPEC-048-R015 gated cells (slots above max_native_active_rows):
            // non-inferiority to ordinary at the mixed-load margins.
            "gated_throughput_lower_bound_min": -0.05,
            "gated_ttft_p95_upper_bound_max": 0.05,
            "gated_tpot_p95_upper_bound_max": 0.05,
        ]
        guard Set(thresholds.keys) == Set(expected.keys) else {
            throw NativeMTPBenchError.invalidPolicy("threshold keys mismatch")
        }
        for (key, value) in expected {
            guard let actual = thresholds[key] as? NSNumber,
                  CFGetTypeID(actual) != CFBooleanGetTypeID(),
                  abs(actual.doubleValue - value) < 0.000_000_1 else {
                throw NativeMTPBenchError.invalidPolicy("threshold \(key) mismatch")
            }
        }
    }

    private static func hex40(_ object: [String: Any], _ key: String) throws -> String {
        let value = try string(object, key)
        guard value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw NativeMTPBenchError.invalidPolicy("\(key) must be lowercase 40-hex")
        }
        return value
    }
}

struct NativeMTPExistingEvidence {
    /// A resumed record counts only for the policy cell it names, with that
    /// cell's shape, inside its phase's block range: matrix 0..<blocks,
    /// warmup -1...-warmup_runs, sustained only for the sustained cell.
    static func validateResumedRecord(
        _ record: [String: Any],
        cellID: String,
        block: Int,
        sustained: Bool,
        warmup: Bool,
        policy: NativeMTPBenchPolicy,
        line: Int
    ) throws {
        func reject(_ reason: String) -> NativeMTPBenchError {
            .assertionFailed("existing --out line \(line): \(reason)")
        }
        guard let cell = policy.cell(id: cellID) else { throw reject("cell \(cellID) is not in the policy") }
        guard (record["slots"] as? NSNumber)?.intValue == cell.slots,
              (record["prompt_tokens"] as? NSNumber)?.intValue == cell.promptTokens,
              (record["max_tokens"] as? NSNumber)?.intValue == cell.maxTokens else {
            throw reject("shape does not match cell \(cellID)")
        }
        if let identity = NativeMTPQualificationScope.identity,
           record["measurement_identity"] as? [String: String] != identity.document { throw reject("measurement executable differs") }
        let inRange: Bool
        if sustained {
            inRange = !warmup && cellID == policy.sustainedCellID && block >= 0
        } else if warmup {
            inRange = block <= -1 && block >= -policy.warmupRuns
        } else {
            inRange = (0..<policy.blocks).contains(block)
        }
        guard inRange else { throw reject("block \(block) is outside its phase for \(cellID)") }
    }

    let hasRecords: Bool
    let completedMatrixBlocks: [String: Set<Int>]
    let completedWarmups: [String: Set<Int>]
    let sustainedSeconds: [String: Double]
    let nextSustainedBlock: [String: Int]

    static func loadIfPresent(
        url: URL,
        policy: NativeMTPBenchPolicy,
        policySHA256: String,
        providerCommit: String,
        modelID: String,
        targetSHA256: String,
        mtpSHA256: String,
        tokenizerSHA256: String,
        environment: NativeMTPBenchEnvironment
    ) throws -> NativeMTPExistingEvidence {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return empty
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return empty }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        for (offset, line) in lines.enumerated() {
            try NativeMTPBenchJSON.rejectDuplicateKeys(Data(line.utf8), label: "existing --out line \(offset + 1)")
        }
        guard let first = lines.first,
              let header = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              header["schema"] as? String == "macprovider.native-mtp-r015-run.v1",
              header["record_type"] as? String == "header" else {
            throw NativeMTPBenchError.assertionFailed("existing --out has no valid header")
        }
        let expected: [String: String] = [
            "policy_sha256": policySHA256,
            "provider_commit": providerCommit,
            "model_id": modelID,
            "target_sha256": targetSHA256,
            "mtp_sha256": mtpSHA256,
            "tokenizer_sha256": tokenizerSHA256,
        ]
        for (key, value) in expected where header[key] as? String != value {
            throw NativeMTPBenchError.assertionFailed("existing --out \(key) mismatch")
        }
        guard let machine = header["machine"] as? [String: Any],
              machine["hw_model"] as? String == environment.hwModel,
              machine["chip"] as? String == environment.chip,
              (machine["ram_gb"] as? NSNumber)?.intValue == environment.ramGB,
              machine["os_build"] as? String == environment.osBuild,
              header["xcode_build_version"] as? String == environment.xcodeBuildVersion,
              header["swift_version"] as? String == environment.swiftVersion,
              header["mlx_fork_revision"] as? String == NativeMTPHardwareE2ERunner.upstreamRevision else {
            throw NativeMTPBenchError.assertionFailed("existing --out frozen environment mismatch")
        }

        var pathsByMatrixBlock: [String: [Int: Set<String>]] = [:]
        var pathsByWarmup: [String: [Int: Set<String>]] = [:]
        var pathsBySustainedBlock: [String: [Int: Set<String>]] = [:]
        if let identity = NativeMTPQualificationScope.identity,
           header["measurement_identity"] as? [String: String] != identity.document {
            throw NativeMTPBenchError.assertionFailed("existing --out measurement executable differs")
        }
        var sustainedSeconds: [String: Double] = [:]
        var nextSustainedBlock: [String: Int] = [:]
        var seen: Set<String> = []
        for (offset, line) in lines.dropFirst().enumerated() {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["schema"] as? String == "macprovider.native-mtp-r015-run.v1",
                  record["record_type"] as? String == "run",
                  record["policy_sha256"] as? String == policySHA256,
                  let cellID = record["cell_id"] as? String,
                  let blockNumber = record["block_index"] as? NSNumber,
                  let path = record["path"] as? String,
                  path == "ordinary" || path == "native_mtp",
                  let sustained = record["sustained"] as? Bool,
                  let warmup = record["warmup"] as? Bool else {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out line \(offset + 2) is not a valid run record"
                )
            }
            let block = blockNumber.intValue
            try validateResumedRecord(
                record, cellID: cellID, block: block, sustained: sustained, warmup: warmup,
                policy: policy, line: offset + 2
            )
            let recordKey = "\(cellID)|\(block)|\(path)|\(sustained)|\(warmup)"
            guard seen.insert(recordKey).inserted else {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out contains duplicate run \(recordKey)"
                )
            }
            if sustained {
                pathsBySustainedBlock[cellID, default: [:]][block, default: []].insert(path)
                let elapsed = (record["sustained_window_elapsed_seconds"] as? NSNumber)?.doubleValue
                if let elapsed {
                    sustainedSeconds[cellID] = max(sustainedSeconds[cellID] ?? 0, elapsed)
                } else {
                    sustainedSeconds[cellID, default: 0] += (record["wall_seconds"] as? NSNumber)?.doubleValue ?? 0
                }
                nextSustainedBlock[cellID] = max(nextSustainedBlock[cellID] ?? 0, block + 1)
            } else if warmup {
                pathsByWarmup[cellID, default: [:]][block, default: []].insert(path)
            } else {
                pathsByMatrixBlock[cellID, default: [:]][block, default: []].insert(path)
            }
        }
        var completed: [String: Set<Int>] = [:]
        for (cellID, blocks) in pathsByMatrixBlock {
            if let partial = blocks.first(where: { _, paths in
                !(paths.contains("ordinary") && paths.contains("native_mtp"))
            }) {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out contains partial matrix block \(cellID)/\(partial.key)"
                )
            }
            completed[cellID] = Set(blocks.compactMap { block, paths in
                paths.contains("ordinary") && paths.contains("native_mtp") ? block : nil
            })
        }
        var completedWarmups: [String: Set<Int>] = [:]
        for (cellID, blocks) in pathsByWarmup {
            if let partial = blocks.first(where: { _, paths in
                !(paths.contains("ordinary") && paths.contains("native_mtp"))
            }) {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out contains partial warmup block \(cellID)/\(partial.key)"
                )
            }
            completedWarmups[cellID] = Set(blocks.keys)
        }
        for (cellID, blocks) in pathsBySustainedBlock {
            if let partial = blocks.first(where: { _, paths in
                !(paths.contains("ordinary") && paths.contains("native_mtp"))
            }) {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out contains partial sustained block \(cellID)/\(partial.key)"
                )
            }
            // A resume continues after the highest block; a gap below it would
            // be skipped silently.
            if let highest = blocks.keys.max(), Set(blocks.keys) != Set(0...highest) {
                throw NativeMTPBenchError.assertionFailed(
                    "existing --out sustained blocks of \(cellID) are not contiguous from 0"
                )
            }
        }
        return NativeMTPExistingEvidence(
            hasRecords: true,
            completedMatrixBlocks: completed,
            completedWarmups: completedWarmups,
            sustainedSeconds: sustainedSeconds,
            nextSustainedBlock: nextSustainedBlock
        )
    }

    private static var empty: NativeMTPExistingEvidence {
        NativeMTPExistingEvidence(
            hasRecords: false,
            completedMatrixBlocks: [:],
            completedWarmups: [:],
            sustainedSeconds: [:],
            nextSustainedBlock: [:]
        )
    }
}

final class NativeMTPJSONLWriter {
    private let handle: FileHandle

    init(url: URL, append: Bool) throws {
        if !append {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw NativeMTPBenchError.assertionFailed("could not create --out")
            }
        }
        self.handle = try FileHandle(forWritingTo: url)
        if append { try handle.seekToEnd() }
    }

    func write(_ object: [String: Any]) throws {
        let normalized = NativeMTPQualificationScope.bind(object).mapValues { value -> Any in
            if let optional = value as? OptionalProtocol, optional.isNil { return NSNull() }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .withoutEscapingSlashes])
        handle.write(data)
        handle.write(Data("\n".utf8))
        try handle.synchronize()
    }

    func close() throws {
        try handle.close()
    }
}

private protocol OptionalProtocol {
    var isNil: Bool { get }
}

extension Optional: OptionalProtocol {
    var isNil: Bool { self == nil }
}

private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9e3779b97f4a7c15 : seed }
    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

private func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let ordered = values.sorted()
    if ordered.count == 1 { return ordered[0] }
    let position = Double(ordered.count - 1) * p
    let lower = Int(floor(position))
    let upper = Int(ceil(position))
    if lower == upper { return ordered[lower] }
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - Double(lower))
}

private func string(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
        throw NativeMTPBenchError.invalidPolicy("missing string \(key)")
    }
    return value
}

private func hex64(_ object: [String: Any], _ key: String) throws -> String {
    let value = try string(object, key)
    guard value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be lowercase 64-hex")
    }
    return value
}

private func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] {
    guard let value = object[key] as? [String: Any] else {
        throw NativeMTPBenchError.invalidPolicy("missing dictionary \(key)")
    }
    return value
}

private func samplingTemperature(_ object: [String: Any], _ key: String) throws -> Double {
    guard let raw = object[key] else { return 0 }
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, (0.0 ... 2.0).contains(number.doubleValue) else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be a number in 0...2")
    }
    return number.doubleValue
}

private func positiveIntArray(_ object: [String: Any], _ key: String) throws -> [Int] {
    guard let values = object[key] as? [NSNumber], !values.isEmpty else {
        throw NativeMTPBenchError.invalidPolicy("missing int array \(key)")
    }
    let ints = try values.map { try exactInt($0, key: key) }
    guard ints.allSatisfy({ $0 > 0 }) else {
        throw NativeMTPBenchError.invalidPolicy("\(key) entries must be positive")
    }
    guard Set(ints).count == ints.count else {
        throw NativeMTPBenchError.invalidPolicy("\(key) entries must be unique")
    }
    return ints
}

private func nonnegativeInt(_ object: [String: Any], _ key: String) throws -> Int {
    guard let number = object[key] as? NSNumber else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be nonnegative int")
    }
    let value = try exactInt(number, key: key)
    guard value >= 0 else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be nonnegative int")
    }
    return value
}

private func exactInt(_ number: NSNumber, key: String) throws -> Int {
    let type = String(cString: number.objCType)
    let value = number.doubleValue
    guard type != "c", value.isFinite, value.rounded() == value,
          value >= Double(Int.min), value <= Double(Int.max) else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must contain JSON integers")
    }
    return Int(value)
}

private func slotCounts(_ object: [String: Any], _ key: String) throws -> [Int] {
    let values = try positiveIntArray(object, key)
    // One concurrent request is measured on a two-slot qualified runtime
    // (SPEC-023-R024 admits qualified_slots 2...8 only).
    guard values.allSatisfy({ (1...8).contains($0) }) else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be within 1...8")
    }
    return values
}

private func gatedCellList(_ object: [String: Any], _ key: String) throws -> [NativeMTPBenchCell] {
    guard let raw = object[key] else { return [] }
    guard let ids = raw as? [String] else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be an array of cell ids")
    }
    return try ids.map { id in
        guard let cell = NativeMTPBenchCell(id: id), (1...8).contains(cell.slots) else {
            throw NativeMTPBenchError.invalidPolicy("\(key) entry \(id) is not a cell id within 1...8 slots")
        }
        return cell
    }
}

private func intAtLeast(_ object: [String: Any], _ key: String, _ minimum: Int) throws -> Int {
    let value = try nonnegativeInt(object, key)
    guard value >= minimum else {
        throw NativeMTPBenchError.invalidPolicy("\(key) must be >= \(minimum)")
    }
    return value
}

/// Duplicate-key rejection for the bench's policy and evidence JSON, matching
/// the analyzer's strict loader: Foundation keeps the last duplicate, which
/// would let one hash-bound document mean two things.
enum NativeMTPBenchJSON {
    static func rejectDuplicateKeys(_ data: Data, label: String) throws {
        let bytes = [UInt8](data)
        var index = 0
        // One entry per open container: nil for arrays, the seen keys for objects.
        var stack: [Set<String>?] = []
        var expectingKey = false
        func readString() throws -> String {
            index += 1
            var raw: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\\") {
                    guard index + 1 < bytes.count else { break }
                    raw.append(byte)
                    raw.append(bytes[index + 1])
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    // Decode escapes so "\u0061" and "a" compare equal.
                    let quoted = Data([UInt8(ascii: "\"")] + raw + [UInt8(ascii: "\"")])
                    guard let decoded = try JSONSerialization.jsonObject(with: quoted, options: [.fragmentsAllowed]) as? String else {
                        throw NativeMTPBenchError.invalidPolicy("\(label): invalid JSON string")
                    }
                    return decoded
                }
                raw.append(byte)
                index += 1
            }
            throw NativeMTPBenchError.invalidPolicy("\(label): unterminated JSON string")
        }
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                stack.append(Set<String>())
                expectingKey = true
                index += 1
            case UInt8(ascii: "["):
                stack.append(nil)
                expectingKey = false
                index += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                _ = stack.popLast()
                expectingKey = false
                index += 1
            case UInt8(ascii: ","):
                if let top = stack.last, top != nil { expectingKey = true }
                index += 1
            case UInt8(ascii: "\""):
                let value = try readString()
                if expectingKey, var keys = stack.last ?? nil {
                    guard keys.insert(value).inserted else {
                        throw NativeMTPBenchError.invalidPolicy("\(label): duplicate JSON key \(value)")
                    }
                    stack[stack.count - 1] = keys
                    expectingKey = false
                }
            default:
                index += 1
            }
        }
    }
}

enum NativeMTPBenchError: Error, CustomStringConvertible {
    case missingDirectory(String)
    case invalidPolicy(String)
    case assertionFailed(String)

    var description: String {
        switch self {
        case .missingDirectory(let path): return "missing directory: \(path)"
        case .invalidPolicy(let message): return "invalid policy: \(message)"
        case .assertionFailed(let message): return "assertion failed: \(message)"
        }
    }
}
