import Foundation

enum CreateFailure: Error, LocalizedError, Equatable {
    case unavailable, upgradeRequired, malformed, tooLarge, invalidPrompt, invalidSeed, memory, busy
    case provider(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Start the provider to create images on this Mac."
        case .upgradeRequired: return "Update provider software to use Create."
        case .malformed: return "The provider returned an invalid image response."
        case .tooLarge: return "The image response exceeded the size limit."
        case .invalidPrompt: return "Enter a prompt of up to 4,000 characters."
        case .invalidSeed: return "Enter a whole-number seed, or leave it empty."
        case .memory: return "This Mac does not have enough memory to create images."
        case .busy: return "An image is already being created. Wait for it to finish."
        case .provider(let message): return ShellText.display(message)
        }
    }
}

enum CreatePhase: String, CaseIterable, Sendable {
    case idle, downloading, holdingCustomers = "holding_customers", generating, warm, restoring, recoveryRequired = "recovery_required"
    var label: String {
        switch self {
        case .idle: return "Ready to create"
        case .downloading: return "Downloading image model"
        case .holdingCustomers: return "Pausing earning while creating"
        case .generating: return "Creating image"
        case .warm: return "Image model ready"
        case .restoring: return "Restoring customer work"
        case .recoveryRequired: return "Language model recovery needed"
        }
    }
    var busy: Bool { ![.idle, .warm, .recoveryRequired].contains(self) }
}

struct CreateStatus: Equatable, Sendable {
    let phase: CreatePhase
    let progress: Double?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let physicalMemory: UInt64
    let unavailableReason: String?
    var available: Bool { unavailableReason == nil }
    var supportsLargeImages: Bool { physicalMemory >= 32 * 1_073_741_824 }
    var downloadLabel: String? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        guard let downloadedBytes else { return total }
        return "\(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)) of \(total)"
    }
    static func parse(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contract = object["local_status_contract"] as? [String: Any],
              (contract["capabilities"] as? [String])?.contains("local_image_generation_v1") == true
        else { throw CreateFailure.upgradeRequired }
        guard let image = object["local_image_generation"] as? [String: Any],
              let rawPhase = image["state"] as? String, let phase = CreatePhase(rawValue: rawPhase),
              let physicalMemory = (image["physical_memory_bytes"] as? NSNumber)?.uint64Value,
              let available = image["available"] as? Bool
        else { throw CreateFailure.malformed }
        let progress = (image["progress"] as? NSNumber)?.doubleValue
        guard progress == nil || (progress!.isFinite && (0...1).contains(progress!)) else { throw CreateFailure.malformed }
        let reason: String?
        if available { reason = nil }
        else if image["unavailable_reason"] as? String == "Image generation requires the native MLX provider runtime." {
            reason = "Create requires a provider with the native image generation runtime."
        } else {
            reason = "This Mac does not have enough available memory to create images."
        }
        return Self(phase: phase, progress: progress,
                    downloadedBytes: (image["downloaded_bytes"] as? NSNumber)?.int64Value,
                    totalBytes: (image["total_bytes"] as? NSNumber)?.int64Value,
                    physicalMemory: physicalMemory, unavailableReason: reason)
    }
}

struct CreateRequest: Encodable, Equatable, Sendable {
    let prompt: String
    let size: String
    let steps: Int
    let seed: UInt64?
    let n = 1
    let response_format = "b64_json"
    init(prompt: String, size: String, steps: Int, seed: String, physicalMemory: UInt64) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 4000
        else { throw CreateFailure.invalidPrompt }
        guard (1...4).contains(steps), ["512x512", "1024x1024"].contains(size) else { throw CreateFailure.malformed }
        guard size != "1024x1024" || physicalMemory >= 32 * 1_073_741_824 else { throw CreateFailure.memory }
        let trimmedSeed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSeed.isEmpty || (trimmedSeed.allSatisfy(\.isNumber) && UInt64(trimmedSeed) != nil)
        else { throw CreateFailure.invalidSeed }
        self.prompt = prompt; self.size = size; self.steps = steps; self.seed = UInt64(trimmedSeed)
    }
}

@MainActor
protocol CreateTransport {
    func status(at endpoint: ChatEndpoint) async throws -> CreateStatus
    func generate(at endpoint: ChatEndpoint, request: CreateRequest) async throws -> Data
    func cancel(at endpoint: ChatEndpoint) async throws
}

private final class CreateNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class LocalCreateTransport: CreateTransport {
    private let session: URLSession
    private var operationID: UUID?
    private let redirect = CreateNoRedirect()
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config)
    }
    deinit { session.invalidateAndCancel() }
    static func request(at endpoint: ChatEndpoint, path: String, body: Data?, operationID: UUID? = nil) -> URLRequest {
        var request = URLRequest(url: endpoint.url(path))
        request.httpMethod = "POST"
        request.setValue("local-app", forHTTPHeaderField: "X-MacProvider-Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if path == "/v1/images/generations" { request.timeoutInterval = 3600 }
        if let operationID { request.setValue(operationID.uuidString, forHTTPHeaderField: "X-MacProvider-Image-Operation-ID") }
        request.httpBody = body
        return request
    }
    func status(at endpoint: ChatEndpoint) async throws -> CreateStatus {
        var request = URLRequest(url: endpoint.url("/v1/status")); request.timeoutInterval = 10
        return try CreateStatus.parse(await read(request, limit: 512 * 1024))
    }
    func generate(at endpoint: ChatEndpoint, request: CreateRequest) async throws -> Data {
        let body = try JSONEncoder().encode(request)
        let operationID = UUID()
        self.operationID = operationID
        let data = try await read(Self.request(at: endpoint, path: "/v1/images/generations", body: body, operationID: operationID), limit: 32 * 1024 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = object["data"] as? [[String: Any]], images.count == 1,
              let encoded = images[0]["b64_json"] as? String, let png = Data(base64Encoded: encoded)
        else { throw CreateFailure.malformed }
        return png
    }
    func cancel(at endpoint: ChatEndpoint) async throws {
        guard let operationID else { return }
        _ = try await read(Self.request(at: endpoint, path: "/v1/images/generations/cancel", body: Data("{}".utf8), operationID: operationID), limit: 16 * 1024)
    }
    private func read(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirect)
        guard let http = response as? HTTPURLResponse else { throw CreateFailure.malformed }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < (http.statusCode == 200 ? limit : 16 * 1024) else { throw CreateFailure.tooLarge }
            data.append(byte)
        }
        if http.statusCode == 429 { throw CreateFailure.busy }
        guard http.statusCode == 200 else {
            throw CreateFailure.provider("The local provider could not complete this request (HTTP \(http.statusCode)).")
        }
        return data
    }
}
