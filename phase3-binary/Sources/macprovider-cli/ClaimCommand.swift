import ArgumentParser
import Foundation
import MacProviderCore

struct ClaimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claim",
        abstract: "Link this Mac to a GitHub account."
    )

    @Flag(help: "Print the claim URL instead of opening a browser.")
    var noBrowser = false

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        try await ClaimCommandRunner(config: resolved, noBrowser: noBrowser).run()
    }
}

struct ClaimRefreshResponse: Equatable, Sendable {
    let pairOT: String
    let claimURL: String
    let expiresIn: Int
}

enum ClaimRefreshError: Error, Equatable {
    case unauthorized
    case rateLimited(seconds: Int)
    case httpStatus(Int)
    case invalidResponse
    case invalidCoordinatorURL
    case missingProviderToken
    case network(String)
}

struct ClaimRefresher: Sendable {
    let refresh: @Sendable (AppConfig) async throws -> ClaimRefreshResponse

    static let live = ClaimRefresher { config in
        guard let token = config.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ClaimRefreshError.missingProviderToken
        }
        guard let url = ClaimCommandRunner.refreshURL(from: config.coordinatorURL) else {
            throw ClaimRefreshError.invalidCoordinatorURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaimRefreshError.network(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaimRefreshError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pairOT = object["pair_ot"] as? String,
                  let claimURL = object["claim_url"] as? String,
                  let expiresIn = object["expires_in"] as? Int
            else {
                throw ClaimRefreshError.invalidResponse
            }
            return ClaimRefreshResponse(pairOT: pairOT, claimURL: claimURL, expiresIn: expiresIn)
        case 401:
            throw ClaimRefreshError.unauthorized
        case 429:
            let retryAfter = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
            throw ClaimRefreshError.rateLimited(seconds: retryAfter)
        default:
            throw ClaimRefreshError.httpStatus(http.statusCode)
        }
    }
}

struct ClaimCommandRunner: Sendable {
    typealias Output = @Sendable (String) -> Void

    let config: AppConfig
    let noBrowser: Bool
    let claimURLFile: ClaimURLFile
    let browserOpener: BrowserOpener
    let refresher: ClaimRefresher
    let now: @Sendable () -> Date
    let environment: @Sendable (String) -> String?
    let stdout: Output
    let stderr: Output

    init(
        config: AppConfig,
        noBrowser: Bool,
        claimURLFile: ClaimURLFile? = nil,
        browserOpener: BrowserOpener = BrowserOpener(),
        refresher: ClaimRefresher = .live,
        now: @escaping @Sendable () -> Date = { Date() },
        environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] },
        stdout: @escaping Output = { print($0) },
        stderr: @escaping Output = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.config = config
        self.noBrowser = noBrowser
        self.claimURLFile = claimURLFile ?? ClaimURLFile(configPath: config.configPath)
        self.browserOpener = browserOpener
        self.refresher = refresher
        self.now = now
        self.environment = environment
        self.stdout = stdout
        self.stderr = stderr
    }

    func run() async throws {
        let record = try localFreshRecord()
        if let record {
            try openOrPrint(record.claimURL)
            return
        }

        let response: ClaimRefreshResponse
        do {
            response = try await refresher.refresh(config)
        } catch let error as ClaimRefreshError {
            try mapRefreshError(error)
            return
        } catch {
            stderr("error: failed to refresh claim URL")
            throw ExitCode(3)
        }
        guard response.expiresIn > 0,
              Self.isValidPairOT(response.pairOT),
              BrowserOpener.isValidClaimURL(response.claimURL, expectedPairOT: response.pairOT)
        else {
            stderr("error: failed to refresh claim URL")
            throw ExitCode(3)
        }

        try claimURLFile.write(
            pairOT: response.pairOT,
            claimURL: response.claimURL,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn))
        )
        try openOrPrint(response.claimURL)
    }

    private func localFreshRecord() throws -> ClaimURLRecord? {
        let record: ClaimURLRecord?
        do {
            record = try claimURLFile.read()
        } catch ClaimURLFileError.invalidBody {
            return nil
        }
        guard let record,
              record.expiresAt > now(),
              Self.isValidPairOT(record.pairOT),
              BrowserOpener.isValidClaimURL(record.claimURL, expectedPairOT: record.pairOT)
        else {
            return nil
        }
        return record
    }

    private func openOrPrint(_ claimURL: String) throws {
        if noBrowser || (environment("SSH_TTY")?.isEmpty == false) {
            stdout(claimURL)
            return
        }
        let decision = try browserOpener.openIfAllowed(claimURL)
        if decision != .opened {
            stdout(claimURL)
        }
    }

    private func mapRefreshError(_ error: ClaimRefreshError) throws {
        switch error {
        case .unauthorized:
            stderr("error: provider token rejected by coordinator — has this Mac been unbound?")
            throw ExitCode(1)
        case .rateLimited(let seconds):
            stderr("error: rate limit exceeded; retry in \(seconds) seconds")
            throw ExitCode(2)
        case .httpStatus, .invalidResponse, .invalidCoordinatorURL, .missingProviderToken, .network:
            stderr("error: failed to refresh claim URL")
            throw ExitCode(3)
        }
    }

    static func refreshURL(from coordinatorURL: String?) -> URL? {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL)
        else {
            return nil
        }
        switch components.scheme {
        case "wss":
            components.scheme = "https"
        case "https":
            break
        default:
            return nil
        }
        components.path = "/v1/install/pair/refresh"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isValidPairOT(_ pairOT: String) -> Bool {
        guard (1...256).contains(pairOT.utf8.count) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return pairOT.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
