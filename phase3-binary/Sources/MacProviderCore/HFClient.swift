import Foundation

/// Minimal HuggingFace API client used by `macprovider-cli models browse`.
///
/// Surface is intentionally narrow: search `mlx-community/*` models with an
/// optional substring filter and a result cap. The fetcher is injectable so
/// tests don't hit the live HF API.
public struct HFClient: Sendable {
    let fetcher: any HTTPFetcher
    let baseURL: URL
    let token: String?

    public init(
        fetcher: any HTTPFetcher = URLSessionHTTPFetcher(),
        baseURL: URL = URL(string: "https://huggingface.co")!,
        token: String? = nil
    ) {
        self.fetcher = fetcher
        self.baseURL = baseURL
        self.token = token
    }

    /// Convenience constructor that pulls the bearer token from `HF_TOKEN`
    /// (matches the HuggingFace CLI's env-var contract).
    public static func fromEnvironment(
        fetcher: any HTTPFetcher = URLSessionHTTPFetcher()
    ) -> HFClient {
        HFClient(fetcher: fetcher, token: ProcessInfo.processInfo.environment["HF_TOKEN"])
    }

    public func searchMLXCommunity(
        query: String? = nil,
        limit: Int = 30
    ) async throws -> [HFModelSummary] {
        guard limit > 0 else { return [] }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/models"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "author", value: "mlx-community"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
        ]
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "search", value: query))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw HFClientError.badRequest("could not construct HF API URL")
        }

        var headers: [String: String] = ["Accept": "application/json"]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }

        let (data, status) = try await fetcher.fetch(url: url, headers: headers)
        switch status {
        case 200:
            break
        case 401, 403:
            throw HFClientError.unauthorized
        case 429:
            throw HFClientError.rateLimited
        default:
            throw HFClientError.httpStatus(status)
        }

        do {
            return try JSONDecoder().decode([HFModelSummary].self, from: data)
        } catch {
            throw HFClientError.decode("\(error)")
        }
    }
}

/// Subset of the HuggingFace `/api/models` element relevant to `browse`.
/// Other fields (downloads, lastModified, etc.) are decoded as Optional so
/// HF schema additions don't break us.
public struct HFModelSummary: Sendable, Decodable, Equatable {
    public let id: String
    public let tags: [String]?
    public let downloads: Int?
    public let lastModified: String?

    public init(id: String, tags: [String]? = nil, downloads: Int? = nil, lastModified: String? = nil) {
        self.id = id
        self.tags = tags
        self.downloads = downloads
        self.lastModified = lastModified
    }
}

public enum HFClientError: Error, CustomStringConvertible, Equatable {
    case badRequest(String)
    case unauthorized
    case rateLimited
    case httpStatus(Int)
    case badResponse
    case decode(String)

    public var description: String {
        switch self {
        case let .badRequest(msg):
            return "bad request: \(msg)"
        case .unauthorized:
            return "HuggingFace rejected the request (401/403); set HF_TOKEN to access gated content"
        case .rateLimited:
            return "HuggingFace rate-limited the request (429); wait a minute and retry"
        case let .httpStatus(s):
            return "HuggingFace returned unexpected status \(s)"
        case .badResponse:
            return "HuggingFace returned a non-HTTP response"
        case let .decode(msg):
            return "could not decode HuggingFace response: \(msg)"
        }
    }
}

public protocol HTTPFetcher: Sendable {
    func fetch(url: URL, headers: [String: String]) async throws -> (Data, Int)
}

public final class URLSessionHTTPFetcher: NSObject, HTTPFetcher, URLSessionTaskDelegate, @unchecked Sendable {
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    // Lazy so self is fully initialized before URLSession captures it as
    // the delegate. Plain let-init from the initializer body trips
    // "Property not initialized at super.init call" because the delegate
    // self-reference requires super.init() to run first.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = self.requestTimeout
        config.timeoutIntervalForResource = self.resourceTimeout
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(timeoutSeconds: TimeInterval = 15, resourceTimeoutSeconds: TimeInterval = 30) {
        self.requestTimeout = timeoutSeconds
        self.resourceTimeout = resourceTimeoutSeconds
        super.init()
    }

    public func fetch(url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HFClientError.badResponse
        }
        return (data, http.statusCode)
    }

    // MARK: URLSessionTaskDelegate
    //
    // Round-2 hardening (codex security MINOR): URLSession's default behavior
    // forwards the `Authorization` header on cross-origin redirects. If HF
    // (or an HTTPS-terminating edge) returns a 3xx to an attacker-controlled
    // host, the bearer HF_TOKEN would leak. We refuse any redirect whose
    // scheme+host doesn't match the original request — that's the bare
    // minimum that lets HuggingFace's own canonicalization redirects work
    // while blocking the leak.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let newURL = request.url,
              originalURL.scheme == newURL.scheme,
              originalURL.scheme == "https",
              originalURL.host == newURL.host
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
