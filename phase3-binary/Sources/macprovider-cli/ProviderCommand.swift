import ArgumentParser
import Foundation
import MacProviderCore

/// Operator commands that check or change a running provider (#1689).
struct ProviderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provider",
        abstract: "Check that this Mac, the network, and the public feed agree after a change.",
        subcommands: [ProviderVerifyCommand.self]
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
        6 the network catalog lacks this model, 7 the coordinator does not publish the public feed.
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
    var coordinatorURL: String?
    var timeout: TimeInterval
    var fetch: Fetch = ProviderVerifier.urlSessionFetch
    var now: () -> Date = Date.init
    var sleep: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    var initialBackoff: TimeInterval = 2
    var maxBackoff: TimeInterval = 15

    func run() async -> ProviderVerifyReport {
        let deadline = now().addingTimeInterval(timeout)
        var backoff = initialBackoff
        while true {
            let report = await evaluateOnce()
            let remaining = deadline.timeIntervalSince(now())
            if report.isTerminal || remaining <= 0 {
                return report
            }
            do {
                try await sleep(min(backoff, remaining))
            } catch {
                return report
            }
            backoff = min(backoff * 2, maxBackoff)
        }
    }

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

        let outcome: ProviderVerifyReport.Outcome
        if local.state != .pass {
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

    private func fetchJSONObject(_ raw: String) async -> Fetched {
        guard let url = URL(string: raw) else { return .failure("invalid URL") }
        do {
            let (code, body) = try await fetch(url)
            guard (200..<300).contains(code) else { return .failure("HTTP \(code)") }
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return .failure("response is not a JSON object")
            }
            return .success(object)
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
            return .init(layer: .local, state: .fail, reason: "\(model) loaded but status is \(state)")
        }
        guard case let .success(models) = await fetchJSONObject("http://127.0.0.1:\(port)/v1/models"),
              let data = models["data"] as? [[String: Any]],
              data.contains(where: { $0["id"] as? String == model })
        else {
            return .init(layer: .local, state: .fail, reason: "/v1/models does not list \(model)")
        }
        return .init(layer: .local, state: .pass, reason: "\(model) loaded and \(state); /v1/models lists it")
    }

    private static func networkLayer(_ status: [String: Any]) -> (ProviderVerifyReport.LayerResult, catalogMaterialMissing: Bool) {
        let coordinator = status["coordinator"] as? [String: Any] ?? [:]
        guard coordinator["connected"] as? Bool == true else {
            return (.init(layer: .network, state: .fail, reason: "not connected to the coordinator"), false)
        }
        let networkState = status["network_state"] as? String ?? "<unknown>"
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
        guard let url = Self.publicFeedURL(coordinatorURL: coordinatorURL) else {
            return pending("no usable coordinator URL in config")
        }
        let code: Int
        let body: Data
        do {
            (code, body) = try await fetch(url)
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
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

enum ProviderVerifyFormatter {
    static func text(_ report: ProviderVerifyReport) -> String {
        var lines = ["Provider verification"]
        for layer in report.layers {
            lines.append("  \(symbol(layer.state)) \(layer.layer.label): \(layer.reason)")
        }
        lines.append("  … Not checkable in the public feed: provider ID (anonymized), this Mac's own context (published only as a per-model maximum)")
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
        case .pending, .unverifiable: return "…"
        }
    }
}
