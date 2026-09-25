import Foundation
import MacProviderCore

// SPEC-046-R009 / SPEC-010-R007(i) `lmstudio_loopback` (#1690 M9): an LM
// Studio server (the desktop app's server, or headless `llmster`) serving a
// catalog GGUF. The identity the CLI reports is the `macprovider.gguf-file.v1`
// digest of the one file `BYOMLMStudioModelStore` resolves for the model key
// under the operator's LM Studio models root; the runtime never names it.
// LM Studio's REST surface reports no file path, so the runtime is bound to
// that file by its `GET /api/v1/models` entry for the key: an `llm` of format
// `gguf` whose publisher is the file's publisher directory, whose size is the
// file's exact size, and which has a loaded instance whose id is the key
// itself, exposed by no other entry. Chat requests name the key, which is that
// instance's id.

/// Serve-time recognition of an `lmstudio_loopback` model ref
/// (`lmstudio:<model key>`), the discovery vocabulary of `BYOMLMStudioDiscovery`.
enum LMStudioLoopbackServeModel {
    static let servedRefPrefix = BYOMLMStudioModelStore.servedModelRefPrefix
    static let runtimeSource = BYOMLMStudioDiscovery.runtimeSource
    static let defaultOrigin = BYOMLMStudioDiscovery.defaultOrigin
    static let maxModelsBodyBytes = 4 * 1024 * 1024

    /// What the runtime must keep listing for the bound file.
    struct Binding: Equatable, Sendable {
        let modelKey: String
        let publisher: String
        let sizeBytes: Int
    }

    static func isLMStudioLoopbackRef(_ ref: String?) -> Bool {
        guard let ref else { return false }
        return ref.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(servedRefPrefix)
    }

    /// The model key LM Studio serves under (`lmstudio:<key>` -> `<key>`).
    static func modelKey(fromServedRef ref: String) -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(servedRefPrefix) else { return trimmed }
        return String(trimmed.dropFirst(servedRefPrefix.count))
    }

    /// `loopback_origin` config key (or its environment override), else the
    /// LM Studio default 127.0.0.1:1234.
    static func resolveOrigin(configured: String?) -> String {
        LoopbackServeSelection.nonEmpty(configured) ?? defaultOrigin
    }

    /// The binding for the file the locator resolved: the key, the publisher
    /// directory (first component of the `<publisher>/<repo>/<file>.gguf`
    /// locator), and the hashed size.
    static func binding(modelKey: String, locator: String, sizeBytes: Int) -> Binding? {
        let parts = locator.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !modelKey.isEmpty, sizeBytes > 0 else { return nil }
        return Binding(modelKey: modelKey, publisher: String(parts[0]), sizeBytes: sizeBytes)
    }

    enum BindingState: Equatable {
        case notBound
        /// Bound; the smallest context length of its loaded instances, nil
        /// when none reports one.
        case bound(contextWindow: Int?)
    }

    /// Bound when `GET /api/v1/models` lists exactly one entry with the key;
    /// it is an `llm` of format `gguf` with the binding's publisher and exact
    /// size; it has a loaded instance whose id is the key (the name chat
    /// requests use); and no other entry has a loaded instance with that id.
    /// The context window is that instance's. Throws when the runtime is
    /// unreachable or the body is not an LM Studio model list.
    static func bindingState(
        _ client: any BYOMDiscoveryHTTPClient,
        origin: URL,
        binding: Binding
    ) async throws -> BindingState {
        let response = try await client.get(
            origin.appendingPathComponent("api/v1/models"),
            maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
            maxBodyBytes: maxModelsBodyBytes
        )
        guard response.statusCode == 200, let models = models(from: response.body) else {
            throw OpenAICompatibleLoopbackRuntimeError.upstreamNotRecognized(runtimeSource)
        }
        let matching = models.filter { $0.key == binding.modelKey }
        guard matching.count == 1, let model = matching.first,
              model.type == "llm", model.format == "gguf",
              model.publisher == binding.publisher, model.sizeBytes == binding.sizeBytes,
              let instance = model.loadedInstances.first(where: { $0.id == binding.modelKey }),
              model.loadedInstances.filter({ $0.id == binding.modelKey }).count == 1,
              !models.contains(where: { $0.key != binding.modelKey && $0.loadedInstances.contains { $0.id == binding.modelKey } })
        else { return .notBound }
        return .bound(contextWindow: instance.contextLength)
    }

    struct LoadedInstance: Equatable {
        let id: String
        let contextLength: Int?
    }

    struct Model: Equatable {
        let key: String
        let type: String?
        let format: String?
        let publisher: String?
        let sizeBytes: Int?
        /// One entry per loaded instance: its id and `config.context_length`.
        let loadedInstances: [LoadedInstance]
    }

    /// The `models[]` of LM Studio's native `GET /api/v1/models`, or nil when
    /// the body is not one.
    static func models(from data: Data) -> [Model]? {
        guard let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text),
              case .array(let entries)? = root["models"]
        else { return nil }
        var models: [Model] = []
        for entry in entries {
            guard case .object(let object) = entry, case .string(let key)? = object["key"] else { return nil }
            var loaded: [LoadedInstance] = []
            if case .array(let instances)? = object["loaded_instances"] {
                for instance in instances {
                    guard case .object(let fields) = instance, case .string(let id)? = fields["id"] else { return nil }
                    var context: Int?
                    if case .object(let config)? = fields["config"] {
                        context = OpenAICompatibleLoopbackRuntime.intValue(config["context_length"])
                    }
                    loaded.append(LoadedInstance(id: id, contextLength: context))
                }
            }
            models.append(Model(
                key: key,
                type: string(object["type"]),
                format: string(object["format"]),
                publisher: string(object["publisher"]),
                sizeBytes: OpenAICompatibleLoopbackRuntime.intValue(object["size_bytes"]),
                loadedInstances: loaded
            ))
        }
        return models
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }
}
