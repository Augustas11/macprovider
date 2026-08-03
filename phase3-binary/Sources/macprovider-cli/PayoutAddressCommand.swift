import ArgumentParser
import Foundation
import MacProviderCore

/// Hidden CLI surface for Malibu "Add wallet" (SPEC-016 §3).
/// Provider token stays in CLI Keychain custody; Malibu never handles it.
struct PayoutAddressCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "payout-address",
        abstract: "Provider payout-address challenge and registration (Malibu Add wallet).",
        shouldDisplay: false,
        subcommands: [
            PayoutAddressChallengeCommand.self,
            PayoutAddressRegisterCommand.self,
        ]
    )
}

struct PayoutAddressChallengeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "challenge",
        abstract: "GET /providers/{id}/payout-address/challenge"
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        let providerID = try requiredProviderID(resolved)
        let token = try loadBearer(config: resolved, providerID: providerID)
        let client = try PayoutAddressClient(
            coordinatorURL: resolved.coordinatorURL,
            providerID: providerID
        )
        do {
            let challenge = try await client.fetchPayoutChallenge(bearerToken: token)
            try writeJSON([
                "verifying_contract": challenge.verifyingContract,
                "chain_id": challenge.chainID,
                "domain_name": challenge.domainName,
                "domain_version": challenge.domainVersion,
                "chain": challenge.chain,
                "server_ts_utc": challenge.serverTsUTC,
                "registered_address": challenge.registeredAddress as Any,
                "pending_until_utc": challenge.pendingUntilUTC as Any,
                "payout_allowed": challenge.payoutAllowed as Any,
                "provider_id": providerID,
            ])
        } catch let error as PayoutAddressClientError {
            try writeError(error)
            throw ExitCode.failure
        }
    }
}

struct PayoutAddressRegisterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register",
        abstract: "POST /providers/{id}/payout-address"
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "Chain id string (must be base-mainnet).")
    var chain: String = "base-mainnet"

    @Option(help: "EIP-55 payout address being registered.")
    var address: String

    @Option(help: "0x-prefixed 32-byte nonce.")
    var nonce: String

    @Option(help: "Unix seconds timestamp used in the EIP-712 payload.")
    var tsUtc: UInt64

    @Option(help: "0x-prefixed 65-byte EIP-712 signature (r||s||v).")
    var signature: String

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        let providerID = try requiredProviderID(resolved)
        let token = try loadBearer(config: resolved, providerID: providerID)
        let client = try PayoutAddressClient(
            coordinatorURL: resolved.coordinatorURL,
            providerID: providerID
        )
        do {
            let result = try await client.registerPayoutAddress(
                bearerToken: token,
                chain: chain,
                address: address,
                nonce: nonce,
                tsUtc: tsUtc,
                signature: signature
            )
            try writeJSON([
                "chain": result.chain,
                "pending_until_utc": result.pendingUntilUTC,
                "status": result.status,
                "http_status": result.httpStatus,
                "address": address,
                "provider_id": providerID,
            ])
        } catch let error as PayoutAddressClientError {
            try writeError(error)
            throw ExitCode.failure
        }
    }
}

// MARK: - shared helpers

private func requiredProviderID(_ config: AppConfig) throws -> String {
    guard let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
          !providerID.isEmpty
    else {
        throw ValidationError("payout-address requires provider_id in config")
    }
    return providerID
}

private func loadBearer(config: AppConfig, providerID: String) throws -> String {
    // Prefer CLI Keychain (authoritative post-handoff). Fall back to config
    // provider_token only when Keychain has no item (dev / pre-handoff).
    if let fromKeychain = try? KeychainProviderCredentialStore().load(providerID: providerID),
       !fromKeychain.isEmpty {
        return fromKeychain
    }
    if let token = config.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
       !token.isEmpty {
        return token
    }
    throw ValidationError("payout-address requires a provider token in Keychain or config")
}

private func writeJSON(_ payload: [String: Any]) throws {
    var final: [String: Any] = [:]
    for (k, v) in payload {
        if v is NSNull { continue }
        let mirror = Mirror(reflecting: v)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                final[k] = child.value
            }
            continue
        }
        final[k] = v
    }
    var data = try JSONSerialization.data(withJSONObject: final, options: [.sortedKeys])
    data.append(0x0a)
    FileHandle.standardOutput.write(data)
}

private func writeError(_ error: PayoutAddressClientError) throws {
    var payload: [String: Any] = [
        "ok": false,
        "message": PayoutAddressClient.userMessage(for: error),
    ]
    switch error {
    case let .httpStatus(code, errorCode):
        payload["http_status"] = code
        if let errorCode { payload["error"] = errorCode }
    default:
        payload["error"] = String(describing: error)
    }
    var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    data.append(0x0a)
    FileHandle.standardError.write(data)
}
