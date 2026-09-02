import Foundation
import os

public enum OwnershipEventKind: String, Sendable {
    case bound
    case unbound
}

public enum PairingControllerError: Error, CustomStringConvertible {
    case invalidPairOT
    case invalidClaimURL
    case invalidGitHubLogin

    public var description: String {
        switch self {
        case .invalidPairOT:
            return "invalid pair_ot"
        case .invalidClaimURL:
            return "invalid claim_url"
        case .invalidGitHubLogin:
            return "invalid github_login"
        }
    }
}

public struct OwnershipEventFrame: Equatable, Sendable {
    public let providerID: String
    public let githubLogin: String
    public let event: OwnershipEventKind

    public init(providerID: String, githubLogin: String, event: OwnershipEventKind) {
        self.providerID = providerID
        self.githubLogin = githubLogin
        self.event = event
    }
}

public final class PairingController: @unchecked Sendable {
    public typealias Output = @Sendable (String) -> Void

    private static let logger = Logger(subsystem: "macprovider", category: "pairing")
    private let claimURLFile: ClaimURLFile
    private let browserOpener: BrowserOpener
    private let now: @Sendable () -> Date
    private let output: Output
    private let logOutput: Output

    public init(
        claimURLFile: ClaimURLFile,
        browserOpener: BrowserOpener = BrowserOpener(),
        now: @escaping @Sendable () -> Date = { Date() },
        output: @escaping Output = { print($0) },
        logOutput: Output? = nil
    ) {
        self.claimURLFile = claimURLFile
        self.browserOpener = browserOpener
        self.now = now
        self.output = output
        self.logOutput = logOutput ?? { message in
            PairingController.logger.info("\(message, privacy: .public)")
        }
    }

    public convenience init(configPath: String) {
        self.init(claimURLFile: ClaimURLFile(configPath: configPath))
    }

    public func handlePairingMaterial(pairOT: String?, claimURL: String?, portalBaseURL: String? = nil) throws {
        guard let pairOT, let claimURL, !pairOT.isEmpty, !claimURL.isEmpty else {
            return
        }
        guard Self.isValidPairOT(pairOT) else {
            throw PairingControllerError.invalidPairOT
        }
        let expectedHost = BrowserOpener.portalHost(fromPortalBaseURL: portalBaseURL)
        guard BrowserOpener.isValidClaimURL(claimURL, expectedPortalHost: expectedHost, expectedPairOT: pairOT) else {
            throw PairingControllerError.invalidClaimURL
        }
        try claimURLFile.write(pairOT: pairOT, claimURL: claimURL, expiresAt: now().addingTimeInterval(600))
        emitUserFacingClaimLine(claimURL: claimURL)
        let decision = try browserOpener.openIfAllowed(claimURL, expectedPortalHost: expectedHost)
        Self.logger.info("claim_url handoff completed decision=\(String(describing: decision), privacy: .public)")
    }

    public func handleOwnershipEvent(_ event: OwnershipEventFrame) throws {
        switch event.event {
        case .bound:
            guard Self.isValidGitHubLogin(event.githubLogin) else {
                throw PairingControllerError.invalidGitHubLogin
            }
            try claimURLFile.delete()
            try claimURLFile.writeOwner(githubLogin: event.githubLogin)
        case .unbound:
            Self.logger.info("ownership unbound event ignored in v0.2 provider_id=\(event.providerID, privacy: .public)")
        }
    }

    public func handleNeedsClaim() throws {
        try claimURLFile.writeMigrationStub()
        Self.logger.info("ownership status needs_claim; run malibu-cli claim")
    }

    private func emitUserFacingClaimLine(claimURL: String) {
        let line = """
        ✓ Provider registered. To link this Mac to your account:
            malibu-cli claim
          (or open: \(claimURL))
        """
        output(line)
        logOutput(Self.redactedClaimLine(line))
    }

    private static func redactedClaimLine(_ line: String) -> String {
        guard let originalURL = line.components(separatedBy: "(or open: ").last?.dropLast().description,
              var components = URLComponents(string: originalURL)
        else {
            return line
        }
        components.queryItems = components.queryItems?.map { item in
            item.name == "ot" ? URLQueryItem(name: item.name, value: "REDACTED") : item
        }
        guard let redactedURL = components.string else {
            return line
        }
        return line.replacingOccurrences(of: originalURL, with: redactedURL)
    }

    private static func isValidPairOT(_ pairOT: String) -> Bool {
        guard (1...256).contains(pairOT.utf8.count) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return pairOT.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isValidGitHubLogin(_ login: String) -> Bool {
        guard (1...39).contains(login.utf8.count),
              !login.hasPrefix("-"),
              !login.hasSuffix("-")
        else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        return login.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
