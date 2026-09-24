import ArgumentParser
import Foundation
import MacProviderCore

/// Operator commands that check or change a running provider (#1689).
struct ProviderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provider",
        abstract: "Check or change this Mac's provider settings and prove the network sees them.",
        subcommands: [ProviderVerifyCommand.self, ProviderContextCommand.self]
    )
}

struct ProviderVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Wait until this Mac, the network, and the public feed agree on model, context, and slots.",
        discussion: """
        Read-only: never changes configuration or processes. Exit codes: 0 all agree, \
        2 this Mac is not ready, 3 the network is not routing customers to this Mac, \
        4 the public feed disagrees, 5 timed out waiting for the public feed, \
        6 the network catalog lacks this model, 7 the public feed cannot be checked (the coordinator \
        does not publish it, or the running provider does not report its coordinator).
        """
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Local HTTP port to query. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    @Option(help: "Seconds to wait for all surfaces to agree.")
    var timeout: Int = 180

    @Flag(help: "Print a machine-readable JSON report.")
    var json = false

    func validate() throws {
        try Self.validateTimeout(timeout)
    }

    /// The one `--timeout` bound for every command that ends in a provider
    /// verification (`provider verify`, `provider context set --apply`,
    /// `provider context rollback`). ArgumentParser runs it before `run()`,
    /// so a rejected value never reaches a preflight, backup, or write.
    static func validateTimeout(_ timeout: Int) throws {
        guard (0...3_600).contains(timeout) else {
            throw ValidationError("--timeout must be between 0 and 3600 seconds")
        }
    }

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(port: port, configPath: config))
        let report = await ProviderVerifier(
            port: resolved.port,
            coordinatorURL: resolved.coordinatorURL,
            timeout: TimeInterval(timeout)
        ).run()
        if json {
            var data = ProviderVerifyFormatter.json(report)
            data.append(0x0a)
            FileHandle.standardOutput.write(data)
        } else {
            print(ProviderVerifyFormatter.text(report))
        }
        if report.exitCode != 0 {
            throw ExitCode(report.exitCode)
        }
    }
}

struct ProviderVerifyReport: Equatable {
    enum Outcome: String {
        case agree
        case localNotReady = "local_not_ready"
        case networkNotServing = "network_not_serving"
        case catalogMaterialMissing = "catalog_material_missing"
        case disagreement
        case timeout
        case publicFeedUnavailable = "public_feed_unavailable"
    }

    enum Layer: String {
        case local
        case network
        case publicFeed = "public_feed"

        var label: String {
            switch self {
            case .local: return "Local provider"
            case .network: return "Network"
            case .publicFeed: return "Public feed"
            }
        }
    }

    enum State: String {
        case pass
        case fail
        case pending
        case unverifiable
    }

    struct LayerResult: Equatable {
        var layer: Layer
        var state: State
        var reason: String
    }

    struct Proof: Equatable {
        var providerID: String?
        var model: String?
        var artifactSHA256: String?
        var maxContextTokens: Int?
        var slots: Int?
        var catalogReleaseID: String?
        var feedGeneratedAt: String?
    }

    var outcome: Outcome
    var layers: [LayerResult]
    var proof: Proof
    var feedLagSeconds: Int?
    var unverifiableFields: [String]

    var exitCode: Int32 {
        switch outcome {
        case .agree: return 0
        case .localNotReady: return 2
        case .networkNotServing: return 3
        case .disagreement: return 4
        case .timeout: return 5
        case .catalogMaterialMissing: return 6
        case .publicFeedUnavailable: return 7
        }
    }

    /// Outcomes that waiting cannot change.
    var isTerminal: Bool {
        [.agree, .catalogMaterialMissing, .publicFeedUnavailable].contains(outcome)
    }
}

/// Polls the local provider, its coordinator view, and the public routability
/// feed until they agree or the deadline passes. Read-only.
struct ProviderVerifier {
    typealias Fetch = @Sendable (URL) async throws -> (status: Int, body: Data)

    static let publicFeedPath = "/v1/stats/routability"
    /// The public feed anonymizes provider refs and publishes context only as
    /// a per-model maximum, so these can never be matched to this Mac.
    static let unverifiableFields = ["provider_id", "per_provider_context"]

    var port: Int
    /// The invoking CLI's configured coordinator. Display only: the public
    /// feed is read from the coordinator the running provider reports
    /// (`coordinator_origin`), because this shell's config or environment may
    /// name another one than the launchd service uses.
    var coordinatorURL: String?
    var timeout: TimeInterval
    var fetch: Fetch = ProviderVerifier.urlSessionFetch
    var now: () -> Date = Date.init
    var sleep: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    var initialBackoff: TimeInterval = 2
    var maxBackoff: TimeInterval = 15
    /// The context a change should leave running: exact tokens, and for a
    /// config without an override the source serve reports for the default
    /// (`ram_tier_default` or `draft_clamp`).
    struct ExpectedContext: Equatable {
        var tokens: Int
        var source: MaxContextSource?
    }

    /// After a context change, the local layer passes only once the running
    /// provider serves this context, so a not-yet-restarted process cannot pass.
    var expectedContext: ExpectedContext? = nil
    /// Wall-clock bound for the single pass `timeout == 0` asks for.
    var singlePassBudget: TimeInterval = requestTimeout
    /// When set, no request starts at or after it and an in-flight request is
    /// cancelled at it.
    var requestDeadline: Date? = nil

    static let requestTimeout: TimeInterval = 5

    /// Polls until agreement, a terminal outcome, or the deadline. At the
    /// deadline it returns the last complete evaluation: a pass the deadline
    /// cut short would report the unanswered request (the local status, first)
    /// instead of the layer that was actually holding (#1689 F1).
    func run() async -> ProviderVerifyReport {
        let start = now()
        let deadline = start.addingTimeInterval(timeout)
        var bounded = self
        bounded.requestDeadline = timeout > 0 ? deadline : start.addingTimeInterval(singlePassBudget)
        var backoff = initialBackoff
        var lastComplete: ProviderVerifyReport?
        while true {
            let cut = DeadlineCut()
            bounded.deadlineCut = cut
            let report = await bounded.evaluateOnce()
            if cut.hit, let lastComplete {
                return lastComplete
            }
            let remaining = deadline.timeIntervalSince(now())
            if report.isTerminal || remaining <= 0 {
                return report
            }
            lastComplete = report
            do {
                try await sleep(min(backoff, remaining))
            } catch {
                return report
            }
            // Nothing starts at the deadline; a pass begun there could only
            // report the deadline.
            if deadline.timeIntervalSince(now()) <= 0 {
                return report
            }
            backoff = min(backoff * 2, maxBackoff)
        }
    }

    /// Set by `boundedFetch` when the deadline stopped or cancelled a request
    /// of the current evaluation.
    final class DeadlineCut: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var hit: Bool { lock.withLock { value } }
        func mark() { lock.withLock { value = true } }
    }

    var deadlineCut: DeadlineCut? = nil

    func evaluateOnce() async -> ProviderVerifyReport {
        var proof = ProviderVerifyReport.Proof()
        var feedLag: Int?
        let status = await fetchJSONObject("http://127.0.0.1:\(port)/v1/status")
        let local = await localLayer(status: status)
        let network: ProviderVerifyReport.LayerResult
        let publicFeed: ProviderVerifyReport.LayerResult
        var catalogMaterialMissing = false
        var feedUnavailable = false
        var feedDisagrees = false
        if case let .success(status) = status {
            let capacity = status["capacity"] as? [String: Any] ?? [:]
            let catalog = status["catalog"] as? [String: Any] ?? [:]
            proof.providerID = status["provider_id"] as? String
            proof.model = status["model"] as? String
            proof.artifactSHA256 = (catalog["artifact_sha256"] as? String) ?? (status["model_hash"] as? String)
            proof.maxContextTokens = (capacity["max_context_tokens"] as? NSNumber)?.intValue
            proof.slots = (capacity["max_concurrency"] as? NSNumber)?.intValue
            proof.catalogReleaseID = catalog["release_id"] as? String
            (network, catalogMaterialMissing) = Self.networkLayer(status)
            let feed = await feedLayer(status: status, proof: proof)
            publicFeed = feed.result
            proof.feedGeneratedAt = feed.generatedAt
            feedLag = feed.lagSeconds
            feedUnavailable = feed.unavailable
            feedDisagrees = feed.disagrees
        } else {
            network = .init(layer: .network, state: .pending, reason: "waiting for the local provider status")
            publicFeed = .init(layer: .publicFeed, state: .pending, reason: "waiting for the local provider status")
        }

        // FR-20a pause exception: a loaded serve the operator paused reports
        // `status: unavailable`; that is not-serving (exit 3), not a local fault.
        var localPaused = false
        if case let .success(status) = status {
            localPaused = local.state != .pass && Self.loadedAndOperatorPaused(status)
        }
        let outcome: ProviderVerifyReport.Outcome
        if local.state != .pass && !localPaused {
            outcome = .localNotReady
        } else if catalogMaterialMissing {
            outcome = .catalogMaterialMissing
        } else if network.state != .pass {
            outcome = .networkNotServing
        } else if feedUnavailable {
            outcome = .publicFeedUnavailable
        } else if feedDisagrees {
            outcome = .disagreement
        } else if publicFeed.state != .pass {
            outcome = .timeout
        } else {
            outcome = .agree
        }
        return ProviderVerifyReport(
            outcome: outcome,
            layers: [local, network, publicFeed],
            proof: proof,
            feedLagSeconds: feedLag,
            unverifiableFields: Self.unverifiableFields
        )
    }

    private enum Fetched {
        case success([String: Any])
        case failure(String)
    }

    private struct DeadlineReached: Error {}

    /// `fetch`, bounded by `requestDeadline` and `requestTimeout`: nothing
    /// starts once the deadline has passed, and a request still running when
    /// its bound expires is cancelled.
    private func boundedFetch(_ url: URL) async throws -> (status: Int, body: Data) {
        guard let requestDeadline else { return try await fetch(url) }
        let remaining = requestDeadline.timeIntervalSince(now())
        guard remaining > 0 else {
            deadlineCut?.mark()
            throw DeadlineReached()
        }
        let bound = min(Self.requestTimeout, remaining)
        // Only a bound set by the run deadline cuts the evaluation short; the
        // per-request timeout is an ordinary unanswered request.
        let cut = bound < Self.requestTimeout ? deadlineCut : nil
        let fetch = self.fetch
        return try await withThrowingTaskGroup(of: (status: Int, body: Data).self) { group in
            group.addTask { try await fetch(url) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(bound * 1_000_000_000))
                cut?.mark()
                throw DeadlineReached()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DeadlineReached() }
            return first
        }
    }

    private func fetchJSONObject(_ raw: String) async -> Fetched {
        guard let url = URL(string: raw) else { return .failure("invalid URL") }
        do {
            let (code, body) = try await boundedFetch(url)
            guard (200..<300).contains(code) else { return .failure("HTTP \(code)") }
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return .failure("response is not a JSON object")
            }
            return .success(object)
        } catch is DeadlineReached {
            return .failure("did not answer before the verification deadline")
        } catch {
            return .failure("not reachable")
        }
    }

    private func localLayer(status fetched: Fetched) async -> ProviderVerifyReport.LayerResult {
        let status: [String: Any]
        switch fetched {
        case let .failure(reason):
            return .init(layer: .local, state: .fail, reason: "local status on 127.0.0.1:\(port) \(reason)")
        case let .success(object):
            status = object
        }
        let state = status["status"] as? String ?? "<unknown>"
        let model = status["model"] as? String
        guard status["model_loaded"] as? Bool == true, let model else {
            return .init(layer: .local, state: .fail, reason: "model not loaded (status \(state))")
        }
        guard ["ready", "busy"].contains(state) else {
            if Self.loadedAndOperatorPaused(status) {
                return .init(layer: .local, state: .fail, reason: Self.operatorPausedReason)
            }
            return .init(layer: .local, state: .fail, reason: "\(model) loaded but status is \(state)")
        }
        guard case let .success(models) = await fetchJSONObject("http://127.0.0.1:\(port)/v1/models"),
              let data = models["data"] as? [[String: Any]],
              data.contains(where: { $0["id"] as? String == model })
        else {
            return .init(layer: .local, state: .fail, reason: "/v1/models does not list \(model)")
        }
        if let expected = expectedContext {
            let capacity = status["capacity"] as? [String: Any]
            let serving = (capacity?["max_context_tokens"] as? NSNumber)?.intValue
            guard serving == expected.tokens else {
                return .init(layer: .local, state: .fail, reason: "serving context \(serving.map(String.init) ?? "<unknown>"), waiting for \(expected.tokens) (restart not finished)")
            }
            if let source = expected.source {
                let servingSource = capacity?["max_context_source"] as? String
                guard servingSource == source.rawValue else {
                    return .init(layer: .local, state: .fail, reason: "serving context source \(servingSource ?? "<unknown>"), waiting for \(source.rawValue) (restart not finished)")
                }
            }
        }
        return .init(layer: .local, state: .pass, reason: "\(model) loaded and \(state); /v1/models lists it")
    }

    static let operatorPausedReason = "paused by operator (resume it from Malibu or its control socket)"

    private static func operatorPaused(_ status: [String: Any]) -> Bool {
        (status["lifecycle"] as? [String: Any])?["state"] as? String == ProviderLifecycleState.pausedByOperator.rawValue
    }

    /// A paused serve keeps its model loaded; one that is not loaded is a
    /// local fault whatever its lifecycle record says.
    private static func loadedAndOperatorPaused(_ status: [String: Any]) -> Bool {
        status["model_loaded"] as? Bool == true && operatorPaused(status)
    }

    private static func networkLayer(_ status: [String: Any]) -> (ProviderVerifyReport.LayerResult, catalogMaterialMissing: Bool) {
        let coordinator = status["coordinator"] as? [String: Any] ?? [:]
        let networkState = status["network_state"] as? String ?? "<unknown>"
        // An operator pause explains any not-serving network state, connected
        // or not, and only the operator can clear it.
        if networkState != "buyer_serving", operatorPaused(status) {
            return (.init(layer: .network, state: .fail, reason: operatorPausedReason), false)
        }
        guard coordinator["connected"] as? Bool == true else {
            return (.init(layer: .network, state: .fail, reason: "not connected to the coordinator"), false)
        }
        if networkState == "buyer_serving" {
            return (.init(layer: .network, state: .pass, reason: "connected; available to customers"), false)
        }
        switch status["buyer_serving_hold"] as? String {
        case CoordinatorReadinessClient.BuyerServingHold.catalogMaterialMissing.rawValue:
            return (.init(
                layer: .network,
                state: .fail,
                reason: "catalog material missing: the network catalog does not include this model yet, so customers cannot be routed to it; waiting cannot fix this"
            ), true)
        case CoordinatorReadinessClient.BuyerServingHold.modelAdmissionPending.rawValue:
            return (.init(layer: .network, state: .fail, reason: "connected; waiting for network approval of this model"), false)
        default:
            let label = networkState == "not_buyer_serving" ? "not available to customers" : "network state \(networkState)"
            return (.init(layer: .network, state: .fail, reason: "connected; \(label)"), false)
        }
    }

    private struct FeedCheck {
        var result: ProviderVerifyReport.LayerResult
        var generatedAt: String?
        var lagSeconds: Int?
        var unavailable = false
        var disagrees = false
    }

    private func feedLayer(status: [String: Any], proof: ProviderVerifyReport.Proof) async -> FeedCheck {
        func pending(_ reason: String) -> FeedCheck {
            FeedCheck(result: .init(layer: .publicFeed, state: .pending, reason: reason))
        }
        func unverifiable(_ reason: String) -> FeedCheck {
            var check = pending(reason)
            check.result.state = .unverifiable
            check.unavailable = true
            return check
        }
        let contract = status["local_status_contract"] as? [String: Any]
        guard (contract?["capabilities"] as? [String])?.contains("coordinator_origin_v1") == true else {
            let shell = Self.coordinatorOrigin(coordinatorURL).map { "; this shell's config names \($0), which may not be the coordinator the provider uses" } ?? ""
            return unverifiable("the running provider does not report its coordinator (it predates coordinator_origin_v1), so the public feed cannot be checked\(shell). Restart it with this version of malibu-cli.")
        }
        guard let origin = Self.coordinatorOrigin(status["coordinator_origin"] as? String) else {
            return unverifiable("the running provider reports no coordinator, so the public feed cannot be checked")
        }
        guard let url = Self.publicFeedURL(coordinatorURL: origin) else {
            return unverifiable("the running provider's coordinator \(origin) has no public feed this command may read (https, or http on loopback only)")
        }
        let code: Int
        let body: Data
        do {
            (code, body) = try await boundedFetch(url)
        } catch is DeadlineReached {
            return pending("\(url.absoluteString) did not answer before the verification deadline")
        } catch {
            return pending("\(url.absoluteString) not reachable")
        }
        if code == 404 {
            var check = pending("\(url.host ?? "the coordinator") does not publish the public feed")
            check.result.state = .unverifiable
            check.unavailable = true
            return check
        }
        if code == 503 {
            return pending("public feed is stale (HTTP 503); waiting for the next snapshot")
        }
        guard (200..<300).contains(code),
              let feed = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let generatedAtText = feed["generated_at"] as? String,
              let generatedAt = Self.parseDate(generatedAtText)
        else {
            return pending("public feed returned HTTP \(code) without a readable snapshot")
        }
        var check = FeedCheck(
            result: .init(layer: .publicFeed, state: .pending, reason: ""),
            generatedAt: generatedAtText,
            lagSeconds: max(0, Int(now().timeIntervalSince(generatedAt).rounded()))
        )
        let lag = "generated \(generatedAtText), \(check.lagSeconds ?? 0)s ago"
        if let startedText = (status["service_instance"] as? [String: Any])?["started_at"] as? String,
           let startedAt = Self.parseDate(startedText),
           generatedAt < startedAt {
            check.result.reason = "public feed is stale: snapshot \(generatedAtText) predates this provider's start at \(startedText)"
            return check
        }

        let catalog = status["catalog"] as? [String: Any] ?? [:]
        let modelIDs = Set([proof.model, catalog["model_id"] as? String, catalog["catalog_key"] as? String].compactMap { $0 })
        let models = feed["models"] as? [[String: Any]] ?? []
        let providers = feed["providers"] as? [[String: Any]] ?? []
        let modelName = proof.model ?? "<unknown>"
        guard let row = models.first(where: { modelIDs.contains($0["model_id"] as? String ?? "") }) else {
            check.disagrees = true
            check.result.state = .fail
            check.result.reason = "public feed does not list \(modelName) (\(lag))"
            return check
        }
        let feedContext = (row["max_context_tokens"] as? NSNumber)?.intValue ?? 0
        let localContext = proof.maxContextTokens ?? 0
        if feedContext < localContext {
            check.disagrees = true
            check.result.state = .fail
            check.result.reason = "public feed advertises context \(feedContext) for \(modelName), but this Mac serves \(localContext) (\(lag))"
            return check
        }
        let localSlots = proof.slots ?? 0
        let sameModel = providers.filter { modelIDs.contains($0["model_id"] as? String ?? "") }
        let matching = sameModel.filter { ($0["slots_total"] as? NSNumber)?.intValue == localSlots }
        guard !matching.isEmpty else {
            let seen = sameModel.compactMap { ($0["slots_total"] as? NSNumber)?.intValue }.map(String.init)
            check.disagrees = true
            check.result.state = .fail
            check.result.reason = "public feed has no \(modelName) provider with \(localSlots) slots (seen: \(seen.isEmpty ? "none" : seen.joined(separator: ", "))) (\(lag))"
            return check
        }
        guard matching.contains(where: { $0["serving_capable"] as? Bool == true }) else {
            check.result.reason = "public feed lists a \(localSlots)-slot \(modelName) provider that is not yet serving capable (\(lag))"
            return check
        }
        let contextNote = feedContext == localContext
            ? "context \(feedContext)"
            : "context up to \(feedContext) across providers (this Mac's \(localContext) is not published per provider)"
        check.result.state = .pass
        check.result.reason = "lists \(modelName) with \(contextNote) and a \(localSlots)-slot provider (\(lag))"
        return check
    }

    /// `scheme://host[:port]` of a coordinator URL: lowercased scheme and
    /// host, no userinfo, path, query, or fragment; nil unless the scheme is
    /// ws, wss, http, or https. `/v1/status` reports it as
    /// `coordinator_origin` (capability `coordinator_origin_v1`).
    static func coordinatorOrigin(_ coordinatorURL: String?) -> String? {
        guard let coordinatorURL,
              let components = URLComponents(string: coordinatorURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["ws", "wss", "http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        return origin.string
    }

    static func publicFeedURL(coordinatorURL: String?) -> URL? {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased()
        else {
            return nil
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        switch components.scheme?.lowercased() {
        case "wss", "https":
            components.scheme = "https"
        case "ws" where loopback, "http" where loopback:
            components.scheme = "http"
        default:
            return nil
        }
        components.path = publicFeedPath
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static let urlSessionFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let (data, response) = try await URLSession.shared.data(for: request, delegate: RedirectRefusal())
        return try checkedResponse(requested: url, response: response, body: data)
    }

    /// Verification reads only the URLs it validated, so a 3xx is returned as
    /// the answer instead of being followed.
    final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Accepts a response only for exactly the URL that was requested.
    static func checkedResponse(requested: URL, response: URLResponse, body: Data) throws -> (status: Int, body: Data) {
        guard let http = response as? HTTPURLResponse,
              http.url?.absoluteString == requested.absoluteString else {
            throw URLError(.badServerResponse)
        }
        return (http.statusCode, body)
    }
}

enum ProviderVerifyFormatter {
    static func text(_ report: ProviderVerifyReport) -> String {
        var lines = ["Provider verification"]
        for layer in report.layers {
            lines.append("  \(symbol(layer.state)) \(layer.layer.label): \(layer.reason)")
        }
        lines.append("  ? Not checkable in the public feed: provider ID (anonymized), this Mac's own context (published only as a per-model maximum)")
        let proof = report.proof
        if report.outcome == .agree {
            let artifact = proof.artifactSHA256.map { String($0.prefix(12)) } ?? "<unknown>"
            let lag = report.feedLagSeconds.map { " (lag \($0)s)" } ?? ""
            lines.append(
                "Verified: provider \(proof.providerID ?? "<unknown>") · model \(proof.model ?? "<unknown>") (artifact \(artifact)) · context \(proof.maxContextTokens.map(String.init) ?? "<unknown>") · slots \(proof.slots.map(String.init) ?? "<unknown>") · catalog release \(proof.catalogReleaseID ?? "<unknown>") · public feed \(proof.feedGeneratedAt ?? "<unknown>")\(lag)"
            )
        } else if let failing = report.layers.first(where: { $0.state != .pass }) {
            lines.append("Not verified: \(failing.layer.label) — \(failing.reason)")
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ report: ProviderVerifyReport) -> Data {
        func nullable(_ value: Any?) -> Any { value ?? NSNull() }
        let proof = report.proof
        let object: [String: Any] = [
            "schema_version": "provider_verify.v1",
            "outcome": report.outcome.rawValue,
            "exit_code": Int(report.exitCode),
            "layers": report.layers.map {
                ["layer": $0.layer.rawValue, "state": $0.state.rawValue, "reason": $0.reason]
            },
            "proof": [
                "provider_id": nullable(proof.providerID),
                "model": nullable(proof.model),
                "artifact_sha256": nullable(proof.artifactSHA256),
                "max_context_tokens": nullable(proof.maxContextTokens),
                "slots": nullable(proof.slots),
                "catalog_release_id": nullable(proof.catalogReleaseID),
                "feed_generated_at": nullable(proof.feedGeneratedAt),
                "feed_lag_seconds": nullable(report.feedLagSeconds),
            ],
            "unverifiable_fields": report.unverifiableFields,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func symbol(_ state: ProviderVerifyReport.State) -> String {
        switch state {
        case .pass: return "✓"
        case .fail: return "✗"
        case .pending: return "…"
        case .unverifiable: return "?"
        }
    }
}
