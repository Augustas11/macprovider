import Foundation
import MacProviderCore

// SPEC-010-R009 / SPEC-046-R009 `omlx_loopback` (#1690 M9): an external oMLX
// server (github.com/jundot/omlx, `omlx serve --model-dir <dir>`) serving a
// catalog MLX snapshot. The identity the CLI reports is the same
// `macprovider.snapshot-manifest.v1` pair `mlxlm_loopback` reports, computed
// by the CLI over the operator-declared snapshot directory. oMLX discovers
// models from its model directory, so the runtime is bound to the snapshot by
// its `GET /v1/models/status` entry whose `model_path` is that directory, and
// chat requests name that entry's model id.

/// Serve-time recognition of an `omlx_loopback` model ref (`omlx:<name>`).
enum OMLXLoopbackServeModel {
    static let servedRefPrefix = "omlx:"
    static let runtimeSource = "omlx_loopback"
    /// `omlx serve`'s default port.
    static let defaultOrigin = "http://127.0.0.1:8000"
    static let snapshotPathEnvironmentKey = "MACPROVIDER_OMLX_MODEL_PATH"
    static let originEnvironmentKey = "MACPROVIDER_OMLX_ORIGIN"
    static let maxStatusBodyBytes = 4 * 1024 * 1024

    static func isOMLXLoopbackRef(_ ref: String?) -> Bool {
        guard let ref else { return false }
        return ref.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(servedRefPrefix)
    }

    /// `loopback_origin` config key, else `MACPROVIDER_OMLX_ORIGIN`, else the
    /// oMLX default.
    static func resolveOrigin(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        LoopbackServeSelection.nonEmpty(configured)
            ?? LoopbackServeSelection.nonEmpty(environment[originEnvironmentKey])
            ?? defaultOrigin
    }

    /// The operator-declared snapshot directory, resolved and standardized.
    /// Nil when unset: there is then no identity leg, and serving fails closed.
    static func snapshotDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let path = LoopbackServeSelection.nonEmpty(environment[snapshotPathEnvironmentKey]), path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }

    /// The served ref for a snapshot directory: its last path component.
    static func servedModelRef(for directory: URL) -> String {
        servedRefPrefix + directory.lastPathComponent
    }

    /// The model id oMLX serves `directory` under: the one `llm` entry of
    /// `GET /v1/models/status` whose `model_path` resolves to the directory
    /// and that is not a distributed deployment. Nil when no entry, or more
    /// than one, qualifies. Throws when the runtime is unreachable or the body
    /// is not an oMLX status document (an API key set on the server, for
    /// example, answers 401).
    static func servedModelID(
        _ client: any BYOMDiscoveryHTTPClient,
        origin: URL,
        directory: URL
    ) async throws -> String? {
        let response = try await client.get(
            origin.appendingPathComponent("v1/models/status"),
            maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
            maxBodyBytes: maxStatusBodyBytes
        )
        guard response.statusCode == 200, let entries = statusEntries(from: response.body) else {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(runtimeSource)
        }
        let wanted = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let matching = entries.filter { entry in
            entry.modelPath.hasPrefix("/")
                && URL(fileURLWithPath: entry.modelPath).resolvingSymlinksInPath().standardizedFileURL.path == wanted
        }
        guard matching.count == 1, let entry = matching.first,
              entry.modelType == "llm", entry.distributed == false,
              !entry.id.isEmpty, entry.id.count <= 256
        else { return nil }
        return entry.id
    }

    struct StatusEntry: Equatable {
        let id: String
        let modelPath: String
        let modelType: String?
        let distributed: Bool?
    }

    /// The `models[]` of oMLX's `GET /v1/models/status`, or nil when the body
    /// is not one.
    static func statusEntries(from data: Data) -> [StatusEntry]? {
        guard let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text),
              case .array(let models)? = root["models"]
        else { return nil }
        var entries: [StatusEntry] = []
        for model in models {
            guard case .object(let object) = model,
                  case .string(let id)? = object["id"]
            else { return nil }
            var path = ""
            if case .string(let value)? = object["model_path"] { path = value }
            var type: String?
            if case .string(let value)? = object["model_type"] { type = value }
            var distributed: Bool?
            if case .bool(let value)? = object["distributed"] { distributed = value }
            entries.append(StatusEntry(id: id, modelPath: path, modelType: type, distributed: distributed))
        }
        return entries
    }
}

/// The two external MLX-snapshot runtimes (SPEC-010-R009): how the CLI finds
/// each one's declared snapshot and binds the process to it. Discovery,
/// evaluation and the offer path treat both alike (#1690 M9).
enum MLXSnapshotLoopbackKind: CaseIterable, Sendable {
    case mlxLM
    case oMLX

    var runtimeSource: String {
        switch self {
        case .mlxLM: return MLXLMLoopbackServeModel.runtimeSource
        case .oMLX: return OMLXLoopbackServeModel.runtimeSource
        }
    }

    static func kind(forRuntimeSource runtimeSource: String) -> MLXSnapshotLoopbackKind? {
        allCases.first { $0.runtimeSource == runtimeSource }
    }

    func servedModelRef(for directory: URL) -> String {
        switch self {
        case .mlxLM: return MLXLMLoopbackServeModel.servedModelRef(for: directory)
        case .oMLX: return OMLXLoopbackServeModel.servedModelRef(for: directory)
        }
    }

    /// The model name chat requests use when the runtime serves `directory`,
    /// nil when it does not. Throws when the runtime is unreachable or not
    /// this runtime.
    func listedModelName(_ client: any BYOMDiscoveryHTTPClient, origin: URL, directory: URL) async throws -> String? {
        switch self {
        case .mlxLM:
            return try await MLXLMLoopbackServeModel.listsSnapshot(client, origin: origin, directory: directory)
                ? MLXLMLoopbackServeModel.upstreamModelName
                : nil
        case .oMLX:
            return try await OMLXLoopbackServeModel.servedModelID(client, origin: origin, directory: directory)
        }
    }
}
