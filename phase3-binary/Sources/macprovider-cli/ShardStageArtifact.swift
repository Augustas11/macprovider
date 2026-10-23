import Foundation
import MacProviderCore

// Issue #2084 per-stage artifact identity and fit (SPEC-051-R006, R008). A member of a
// group serving a model larger than one Mac holds only its stage's files. It proves
// them against the full snapshot's `macprovider.snapshot-manifest.v1` manifest (the
// bytes whose SHA-256 is the signed artifact hash, as the content-addressed mirror
// serves them): every file it holds is a manifest entry with that size and SHA-256,
// every file its stage needs is present, and nothing outside the artifact is loaded.
// Its fit is the SPEC-023 memory envelope applied to the stage: the stage's own tensor
// bytes plus KV for its share of the layers at the group's concurrency.

enum ShardStageArtifactError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case doesNotFit(String)

    var description: String {
        switch self {
        case .invalid(let detail): return "shard stage artifact: \(detail)"
        case .doesNotFit(let detail): return "shard stage does not fit this Mac: \(detail)"
        }
    }
}

enum ShardStageArtifact {
    static let indexFile = "model.safetensors.index.json"
    /// Weight formats a stage never needs beyond its own safetensors shards.
    static let weightExtensions: Set<String> = ["safetensors", "bin", "pth", "pt", "gguf", "npz", "h5", "msgpack", "onnx", "ckpt"]
    static let maxHeaderBytes: UInt64 = 128 * 1_048_576

    /// The files one stage needs from a snapshot.
    struct Files: Equatable, Sendable {
        /// Every needed file, relative to the snapshot root, sorted.
        let required: [String]
        /// The safetensors shards among them.
        let weightFiles: [String]
        /// Whether the model has its own LM head (not tied to the embedding).
        let hasHead: Bool
    }

    struct Inventory: Equatable, Sendable {
        let files: Files
        /// Tensor bytes this stage loads.
        let stageWeightBytes: Int64
        let configData: Data
        let plan: PipelineStagePlan
    }

    // MARK: Which files a stage needs

    /// The stage's safetensors shards (by the snapshot's weight index, or every
    /// safetensors file of an unindexed snapshot) and every non-weight file of the
    /// snapshot (config, tokenizer, the index itself).
    static func files(snapshotPaths: [String], weightMap: [String: String]?, plan: PipelineStagePlan) throws -> Files {
        let paths = Set(snapshotPaths)
        let nonWeight = paths.filter { !weightExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        guard let weightMap else {
            let weights = paths.filter { ($0 as NSString).pathExtension == "safetensors" }.sorted()
            guard !weights.isEmpty else { throw ShardStageArtifactError.invalid("the snapshot has no safetensors weights") }
            return Files(required: (nonWeight.union(weights)).sorted(), weightFiles: weights, hasHead: true)
        }
        for file in Set(weightMap.values) where !paths.contains(file) {
            throw ShardStageArtifactError.invalid("the weight index names \(file), which is not in the snapshot")
        }
        let hasHead = weightMap.keys.contains { $0.hasPrefix("lm_head.") }
        let weights = Set(weightMap.compactMap { key, file in
            PipelineStageModel.stageKeeps(key: key, plan: plan, hasHead: hasHead) ? file : nil
        })
        guard !weights.isEmpty else { throw ShardStageArtifactError.invalid("no tensor of layers \(plan.layers) is in the weight index") }
        return Files(required: nonWeight.union(weights).sorted(), weightFiles: weights.sorted(), hasHead: hasHead)
    }

    static func weightMap(_ data: Data) throws -> [String: String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = object["weight_map"] as? [String: String]
        else {
            throw ShardStageArtifactError.invalid("\(indexFile) has no weight_map")
        }
        return map
    }

    // MARK: Stage tensor bytes

    /// Bytes of the tensors this stage keeps, from the safetensors headers of its
    /// shards (no tensor data is read).
    static func stageWeightBytes(directory: URL, weightFiles: [String], plan: PipelineStagePlan, hasHead: Bool) throws -> Int64 {
        var total: Int64 = 0
        for file in weightFiles {
            for (key, bytes) in try tensorBytes(url: directory.appendingPathComponent(file))
            where PipelineStageModel.stageKeeps(key: key, plan: plan, hasHead: hasHead) {
                total += bytes
            }
        }
        return total
    }

    /// Byte length of every tensor in one safetensors file, from its header.
    static func tensorBytes(url: URL) throws -> [String: Int64] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
            throw ShardStageArtifactError.invalid("\(url.lastPathComponent) is not a safetensors file")
        }
        let length = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        guard length > 0, length <= maxHeaderBytes, let header = try handle.read(upToCount: Int(length)), header.count == Int(length),
              let object = try JSONSerialization.jsonObject(with: header) as? [String: Any]
        else {
            throw ShardStageArtifactError.invalid("\(url.lastPathComponent) has an unreadable safetensors header")
        }
        var sizes = [String: Int64]()
        for (key, value) in object where key != "__metadata__" {
            guard let tensor = value as? [String: Any], let offsets = tensor["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0]
            else {
                throw ShardStageArtifactError.invalid("\(url.lastPathComponent) tensor \(key) has no data offsets")
            }
            sizes[key] = Int64(offsets[1] - offsets[0])
        }
        return sizes
    }

    // MARK: Verification

    /// Relative paths of the regular files under `directory`, refusing symlinks,
    /// hard links and unsafe paths the way the full-snapshot hash does.
    static func localFiles(_ directory: URL) throws -> [String] {
        let base = directory.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: []) else {
            throw ShardStageArtifactError.invalid("cannot read \(directory.path)")
        }
        var files = [String]()
        for case let url as URL in enumerator {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { throw ShardStageArtifactError.invalid("path escape \(url.lastPathComponent)") }
            let relative = String(path.dropFirst(base.count + 1))
            try ModelArtifactRelativePathPolicy.validate(relative)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw ShardStageArtifactError.invalid("cannot stat \(relative)") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: continue
            case S_IFREG where info.st_nlink <= 1: files.append(relative)
            default: throw ShardStageArtifactError.invalid("\(relative) is not a regular single-link file")
            }
        }
        return files.sorted()
    }

    /// SPEC-051-R008 for a stage directory: the manifest's bytes hash to the signed
    /// artifact hash; every file present is a manifest entry of that size and SHA-256
    /// (nothing outside the artifact is loaded); every file the stage needs is present.
    static func verify(directory: URL, manifestURL: URL, expectedSHA256: String, layers: Range<Int>) throws -> Inventory {
        let entries: [ContentAddressedManifest.Entry]
        do {
            entries = try ContentAddressedManifest.readAndParse(manifestURL, expectedSHA256: expectedSHA256)
        } catch {
            throw ShardStageArtifactError.invalid("snapshot manifest \(manifestURL.path) refused: \(error)")
        }
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let local = try localFiles(directory)
        for relative in local {
            guard let entry = byPath[relative] else {
                throw ShardStageArtifactError.invalid("\(relative) is not part of artifact \(expectedSHA256)")
            }
            let actual = try ModelArtifactVerifier.sizeAndSHA256(of: directory.appendingPathComponent(relative))
            guard actual.size == entry.size, actual.sha256 == entry.sha256 else {
                throw ShardStageArtifactError.invalid("\(relative) does not match its manifest entry")
            }
        }
        return try inventory(directory: directory, snapshotPaths: entries.map(\.path), localPaths: Set(local), layers: layers)
    }

    /// The stage's needs over a full local snapshot (its hash was verified whole).
    static func inventory(directory: URL, layers: Range<Int>) throws -> Inventory {
        let local = try localFiles(directory)
        return try inventory(directory: directory, snapshotPaths: local, localPaths: Set(local), layers: layers)
    }

    private static func inventory(directory: URL, snapshotPaths: [String], localPaths: Set<String>, layers: Range<Int>) throws -> Inventory {
        guard localPaths.contains("config.json") else { throw ShardStageArtifactError.invalid("config.json is missing") }
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw ShardStageArtifactError.invalid("config.json is not an object")
        }
        let plan = try PipelineStagePlan(layers: layers, totalLayers: try PipelineStageModel.totalLayers(config: config))
        var map: [String: String]?
        if snapshotPaths.contains(indexFile) {
            guard localPaths.contains(indexFile) else { throw ShardStageArtifactError.invalid("\(indexFile) is missing") }
            map = try weightMap(try Data(contentsOf: directory.appendingPathComponent(indexFile)))
        }
        let files = try files(snapshotPaths: snapshotPaths, weightMap: map, plan: plan)
        let missing = files.required.filter { !localPaths.contains($0) }
        guard missing.isEmpty else {
            throw ShardStageArtifactError.invalid("layers \(layers.lowerBound):\(layers.upperBound) need \(missing.joined(separator: ", ")), which this Mac does not hold")
        }
        let bytes = try stageWeightBytes(directory: directory, weightFiles: files.weightFiles, plan: plan, hasHead: files.hasHead)
        return Inventory(files: files, stageWeightBytes: bytes, configData: configData, plan: plan)
    }

    // MARK: Fit

    struct Fit: Equatable, Sendable {
        let stageWeightBytes: Int64
        let kvBudgetBytes: UInt64
        /// KV for `slots` sequences of `contextTokens` tokens over the stage's layers;
        /// nil when the config's attention geometry is unreadable.
        let kvDemandBytes: UInt64?

        var fits: Bool { kvDemandBytes.map { $0 <= kvBudgetBytes } ?? false }

        var detail: String {
            guard let kvDemandBytes else { return "the model's KV geometry is unreadable, so the stage's fit cannot be shown" }
            return "stage weights \(stageWeightBytes) bytes, KV demand \(kvDemandBytes) bytes, KV budget \(kvBudgetBytes) bytes"
        }
    }

    /// KV bytes `slots` sequences of `contextTokens` tokens need on a stage of
    /// `stageLayers` of `totalLayers` layers, as the stage runtime allocates it;
    /// nil when the config's attention geometry is unreadable. DeepSeek-V3's
    /// stage attention caches the expanded per-head keys and values, not the
    /// latent the single-Mac estimate counts (R3-C01), so it is sized from the
    /// stage runtime's own geometry.
    static func stageKVDemandBytes(configData: Data, stageLayers: Int, totalLayers: Int, slots: Int, contextTokens: Int) -> UInt64? {
        let perSlot: Double
        if let config = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any],
           config["model_type"] as? String == "deepseek_v3" {
            guard let perLayer = try? ShardBenchPlanInput.kvBytesPerTokenPerLayer(config: config) else { return nil }
            perSlot = Double(perLayer) * Double(stageLayers) * Double(contextTokens)
        } else {
            guard let perToken = AutotuneModelContextCap.kvCacheBytesPerToken(configData: configData), totalLayers > 0 else { return nil }
            let share = Double(stageLayers) / Double(totalLayers)
            let recurrent = Double(AutotuneModelContextCap.recurrentStateBytesPerSequence(configData: configData))
            perSlot = (Double(perToken) * Double(contextTokens) + recurrent) * share
        }
        let demand = (perSlot * Double(max(1, slots))).rounded(.up)
        return demand >= Double(UInt64.max) ? UInt64.max : UInt64(demand)
    }

    /// SPEC-051-R006 under SPEC-023: the stage's weights, its KV for `slots`
    /// sequences of `contextTokens` tokens, and the runtime reserve fit this Mac.
    static func fit(inventory: Inventory, slots: Int, contextTokens: Int = AutotuneModelContextCap.minimumServeContext,
                    hardwareMemoryGB: Int = ModelFit.detectRAMGB()) -> Fit {
        let budget = AutotuneModelContextCap.shardStageKVBudgetBytes(
            hardwareMemoryGB: hardwareMemoryGB, stageWeightBytes: inventory.stageWeightBytes)
        let demand = stageKVDemandBytes(
            configData: inventory.configData, stageLayers: inventory.plan.layers.count, totalLayers: inventory.plan.totalLayers,
            slots: slots, contextTokens: contextTokens)
        return Fit(stageWeightBytes: inventory.stageWeightBytes, kvBudgetBytes: budget, kvDemandBytes: demand)
    }
}
