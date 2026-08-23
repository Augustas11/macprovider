import CryptoKit
import Foundation

enum ConsumeTrustedPricingUnavailableReason: String, Sendable {
    case notLoaded = "not_loaded"
    case fetchFailed = "fetch_failed"
    case oversizedRateCard = "oversized_rate_card"
    case oversizedSidecar = "oversized_sidecar"
    case invalidSidecar = "invalid_sidecar"
    case invalidSignature = "invalid_signature"
    case invalidRateCard = "invalid_rate_card"
    case policyMismatch = "policy_mismatch"
    case olderThanBaked = "older_than_baked"
    case futureSkew = "future_skew"
    case expired = "expired"
}

enum ConsumeTrustedPricingState: Equatable, Sendable {
    case unavailable(reason: ConsumeTrustedPricingUnavailableReason)
    case available(ConsumeTrustedRateCard)

    static let notLoaded = ConsumeTrustedPricingState.unavailable(reason: .notLoaded)

    var statusState: String {
        switch self {
        case .available:
            return "trusted"
        case .unavailable:
            return "unavailable"
        }
    }

    var warningCodes: [String] {
        switch self {
        case .available(let rateCard):
            return rateCard.statusWarningCodes
        case .unavailable:
            return []
        }
    }

    func match(model: String) -> ConsumeTrustedRateCardMatch? {
        switch self {
        case .available(let rateCard):
            return rateCard.match(model: model)
        case .unavailable:
            return nil
        }
    }

    func warningCodes(match: ConsumeTrustedRateCardMatch?) -> [String] {
        switch self {
        case .available(let rateCard):
            return rateCard.warningCodes(match: match)
        case .unavailable:
            return []
        }
    }

    func revalidated(now: Date) -> ConsumeTrustedPricingState {
        switch self {
        case .available(let rateCard):
            return rateCard.revalidated(now: now)
        case .unavailable:
            return self
        }
    }
}

struct ConsumeTrustedRateCard: Equatable, Sendable {
    let version: String
    let policyVersion: String
    let generatedAt: Date
    let signerKeyID: String
    let projection: RateCardProjection
    let stale: Bool

    var statusWarningCodes: [String] {
        stale ? ["stale_pricing"] : []
    }

    func match(model: String) -> ConsumeTrustedRateCardMatch? {
        if let row = projection.rows[model] {
            return ConsumeTrustedRateCardMatch(rateCardKey: model, row: row, source: .exact)
        }
        let normalized = AutotuneModelKeyNormalizer.normalize(model)
        if normalized != model, normalized != "default", let row = projection.rows[normalized] {
            return ConsumeTrustedRateCardMatch(rateCardKey: normalized, row: row, source: .normalized)
        }
        guard let row = projection.rows["default"] else {
            return nil
        }
        let source: ConsumeTrustedRateCardMatch.Source = model == "default" ? .exact : .defaultFallback
        return ConsumeTrustedRateCardMatch(rateCardKey: "default", row: row, source: source)
    }

    func warningCodes(match: ConsumeTrustedRateCardMatch?) -> [String] {
        var warnings = statusWarningCodes
        if match?.source == .defaultFallback {
            warnings.append("default_pricing_tier_used")
        }
        return warnings
    }

    func revalidated(now current: Date) -> ConsumeTrustedPricingState {
        guard generatedAt <= current.addingTimeInterval(ConsumeTrustedPricingLoader.maxFutureSkew) else {
            return .unavailable(reason: .futureSkew)
        }
        guard current.timeIntervalSince(generatedAt) <= ConsumeTrustedPricingLoader.maxAge else {
            return .unavailable(reason: .expired)
        }
        let currentlyStale = current.timeIntervalSince(generatedAt) >= ConsumeTrustedPricingLoader.staleAge
        guard currentlyStale != stale else {
            return .available(self)
        }
        return .available(ConsumeTrustedRateCard(
            version: version,
            policyVersion: policyVersion,
            generatedAt: generatedAt,
            signerKeyID: signerKeyID,
            projection: projection,
            stale: currentlyStale
        ))
    }
}

struct ConsumeTrustedRateCardMatch: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case exact
        case normalized
        case defaultFallback
    }

    let rateCardKey: String
    let row: RateCardProjection.Row
    let source: Source
}

struct ConsumeTrustedPricingLoader: Sendable {
    static let maxRateCardBytes = 4 * 1024 * 1024
    static let maxSidecarBytes = 16 * 1024
    static let maxResponseHeaderBytes = 32 * 1024
    static let maxResponseHeaderCount = 64
    static let maxFutureSkew: TimeInterval = 10 * 60
    static let staleAge: TimeInterval = 14 * 24 * 3600
    static let maxAge: TimeInterval = 30 * 24 * 3600

    var fetch: @Sendable (URL) async throws -> Data
    var trustedPublicKeys: [String: String]
    var expectedPolicyVersion: String
    var minimumGeneratedAt: Date
    var now: @Sendable () -> Date

    init(
        fetch: @escaping @Sendable (URL) async throws -> Data = { url in
            try await ConsumeTrustedPricingLoader.defaultFetch(url)
        },
        trustedPublicKeys: [String: String] = AutotuneStaticInputs.defaultTrustedPublicKeys,
        expectedPolicyVersion: String = Self.defaultExpectedPolicyVersion(),
        minimumGeneratedAt: Date = Self.defaultMinimumGeneratedAt(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.trustedPublicKeys = trustedPublicKeys
        self.expectedPolicyVersion = expectedPolicyVersion
        self.minimumGeneratedAt = minimumGeneratedAt
        self.now = now
    }

    func load(from upstreamOrigin: String) async -> ConsumeTrustedPricingState {
        guard let bodyURL = URL(string: "\(upstreamOrigin)/v1/rate-card"),
              let sidecarURL = URL(string: "\(upstreamOrigin)/v1/rate-card.sig")
        else {
            return .unavailable(reason: .fetchFailed)
        }
        do {
            let body = try await fetch(bodyURL)
            guard body.count <= Self.maxRateCardBytes else {
                return .unavailable(reason: .oversizedRateCard)
            }
            let sidecar = try await fetch(sidecarURL)
            guard sidecar.count <= Self.maxSidecarBytes else {
                return .unavailable(reason: .oversizedSidecar)
            }
            return try .available(verify(rateCardBytes: body, sidecarBytes: sidecar))
        } catch let error as ConsumeTrustedPricingError {
            return .unavailable(reason: error.reason)
        } catch {
            return .unavailable(reason: .fetchFailed)
        }
    }

    func verify(rateCardBytes: Data, sidecarBytes: Data) throws -> ConsumeTrustedRateCard {
        guard rateCardBytes.count <= Self.maxRateCardBytes else {
            throw ConsumeTrustedPricingError(.oversizedRateCard)
        }
        guard sidecarBytes.count <= Self.maxSidecarBytes else {
            throw ConsumeTrustedPricingError(.oversizedSidecar)
        }
        let sidecar = try parseSidecar(sidecarBytes)
        guard signatureIsValid(rateCardBytes: rateCardBytes, sidecar: sidecar) else {
            throw ConsumeTrustedPricingError(.invalidSignature)
        }
        let projection: RateCardProjection
        do {
            projection = try AutotuneStaticInputs.decodeRateCard(rateCardBytes)
        } catch {
            throw ConsumeTrustedPricingError(.invalidRateCard)
        }
        guard !expectedPolicyVersion.isEmpty, projection.policyVersion == expectedPolicyVersion else {
            throw ConsumeTrustedPricingError(.policyMismatch)
        }
        guard projection.generatedAt >= minimumGeneratedAt else {
            throw ConsumeTrustedPricingError(.olderThanBaked)
        }
        let current = now()
        guard projection.generatedAt <= current.addingTimeInterval(Self.maxFutureSkew) else {
            throw ConsumeTrustedPricingError(.futureSkew)
        }
        guard current.timeIntervalSince(projection.generatedAt) <= Self.maxAge else {
            throw ConsumeTrustedPricingError(.expired)
        }
        return ConsumeTrustedRateCard(
            version: projection.version,
            policyVersion: projection.policyVersion,
            generatedAt: projection.generatedAt,
            signerKeyID: sidecar.keyID,
            projection: projection,
            stale: current.timeIntervalSince(projection.generatedAt) >= Self.staleAge
        )
    }

    private static func defaultFetch(_ url: URL) async throws -> Data {
        try await fetch(url, session: defaultURLSession())
    }

    static func defaultURLSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.protocolClasses = protocolClasses
        return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }

    static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        defer { session.invalidateAndCancel() }
        let limit = url.path.hasSuffix(".sig") ? Self.maxSidecarBytes : Self.maxRateCardBytes
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConsumeTrustedPricingError(.fetchFailed)
        }
        guard Self.responseHeadersAreBounded(http) else {
            throw ConsumeTrustedPricingError(.fetchFailed)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ConsumeTrustedPricingError(.fetchFailed)
        }
        if response.expectedContentLength > Int64(limit) {
            throw ConsumeTrustedPricingError(url.path.hasSuffix(".sig") ? .oversizedSidecar : .oversizedRateCard)
        }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit {
                throw ConsumeTrustedPricingError(url.path.hasSuffix(".sig") ? .oversizedSidecar : .oversizedRateCard)
            }
        }
        return data
    }

    private static func defaultExpectedPolicyVersion() -> String {
        (try? AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)).policyVersion) ?? ""
    }

    private static func defaultMinimumGeneratedAt() -> Date {
        (try? AutotuneStaticInputs.decodeRateCard(Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)).generatedAt) ?? .distantFuture
    }

    private struct SignatureSidecar: Sendable {
        let keyID: String
        let signature: Data
    }

    private func parseSidecar(_ data: Data) throws -> SignatureSidecar {
        var parser = FlatJSONStringObjectParser(data: data)
        guard let object = try? parser.parse(),
              Set(object.keys) == Set(["key_id", "alg", "signature"]),
              let keyID = object["key_id"],
              keyID == keyID.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
              !keyID.isEmpty,
              trustedPublicKeys[keyID] != nil,
              object["alg"] == "ed25519",
              let encodedSignature = object["signature"],
              let signature = Data(base64Encoded: encodedSignature),
              signature.count == 64,
              signature.base64EncodedString() == encodedSignature
        else {
            throw ConsumeTrustedPricingError(.invalidSidecar)
        }
        return SignatureSidecar(keyID: keyID, signature: signature)
    }

    private static func responseHeadersAreBounded(_ response: HTTPURLResponse) -> Bool {
        guard response.allHeaderFields.count <= maxResponseHeaderCount else {
            return false
        }
        var total = 0
        for (rawName, rawValue) in response.allHeaderFields {
            total += String(describing: rawName).utf8.count
            total += String(describing: rawValue).utf8.count
            if total > maxResponseHeaderBytes {
                return false
            }
        }
        return true
    }

    private func signatureIsValid(rateCardBytes: Data, sidecar: SignatureSidecar) -> Bool {
        guard let encodedPublicKey = trustedPublicKeys[sidecar.keyID],
              let publicKeyBytes = Data(base64Encoded: encodedPublicKey),
              publicKeyBytes.count == 32,
              publicKeyBytes.base64EncodedString() == encodedPublicKey,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        else {
            return false
        }
        return publicKey.isValidSignature(sidecar.signature, for: rateCardBytes)
    }
}

private struct FlatJSONStringObjectParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> [String: String] {
        skipWhitespace()
        guard consume(0x7B) else { throw ConsumeTrustedPricingError(.invalidSidecar) }
        skipWhitespace()
        var object: [String: String] = [:]
        if consume(0x7D) { return object }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ConsumeTrustedPricingError(.invalidSidecar)
            }
            let key = try parseString()
            guard object[key] == nil else {
                throw ConsumeTrustedPricingError(.invalidSidecar)
            }
            skipWhitespace()
            guard consume(0x3A) else { throw ConsumeTrustedPricingError(.invalidSidecar) }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ConsumeTrustedPricingError(.invalidSidecar)
            }
            object[key] = try parseString()
            skipWhitespace()
            if consume(0x7D) { break }
            guard consume(0x2C) else { throw ConsumeTrustedPricingError(.invalidSidecar) }
            skipWhitespace()
        }
        skipWhitespace()
        guard index == bytes.count else {
            throw ConsumeTrustedPricingError(.invalidSidecar)
        }
        return object
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
                continue
            }
            if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let token = Data(bytes[start ..< index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: token) else {
                    throw ConsumeTrustedPricingError(.invalidSidecar)
                }
                return decoded
            } else if byte < 0x20 {
                throw ConsumeTrustedPricingError(.invalidSidecar)
            }
        }
        throw ConsumeTrustedPricingError(.invalidSidecar)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}

struct ConsumeTrustedPricingError: Error {
    let reason: ConsumeTrustedPricingUnavailableReason

    init(_ reason: ConsumeTrustedPricingUnavailableReason) {
        self.reason = reason
    }
}
