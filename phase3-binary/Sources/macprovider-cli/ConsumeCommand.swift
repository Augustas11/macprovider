import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import Network
import Security
@preconcurrency import NIO
@preconcurrency import NIOHTTP1
import zlib

struct ConsumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "consume",
        abstract: "Start a loopback-only local consumer endpoint.",
        subcommands: [ConsumeRunCommand.self, ConsumeStatusCommand.self, ConsumeBudgetCommand.self],
        defaultSubcommand: ConsumeRunCommand.self
    )
}

struct ConsumeRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the local consumer endpoint shell."
    )

    @Option(help: "Loopback address to bind. Default 127.0.0.1.")
    var bind: String = "127.0.0.1"

    @Option(help: "Local HTTP port to bind. Default 11435; port 0 is rejected.")
    var port: Int = 11435

    @Option(name: .customLong("credential-file"), help: "User-private buyer API key file.")
    var credentialFile: String?

    @Option(name: .customLong("upstream-gateway-url"), help: "HTTPS gateway origin. Default https://api.malibu.tech.")
    var upstreamGatewayURL: String = ConsumeEndpointDefaults.upstreamGatewayOrigin

    @Option(name: .customLong("allow-model"), parsing: .upToNextOption, help: "Allowed model id. Repeat for multiple models.")
    var allowedModels: [String] = []

    @Option(name: .customLong("budget-usd"), help: "Positive local run exposure cap in USD.")
    var budgetUSD: String?

    @Option(name: .customLong("max-request-usd"), help: "Optional positive per-request exposure cap in USD.")
    var maxRequestUSD: String?

    @Flag(name: .customLong("no-budget"), help: "Explicitly run without a local budget cap.")
    var noBudget: Bool = false

    @Option(name: .customLong("ledger"), help: "Budget ledger path. Relative paths resolve against the startup directory.")
    var ledgerPath: String?

    @Flag(name: .customLong("allow-unpriced"), help: "Allow unpriced requests by reserving the full remaining local budget.")
    var allowUnpriced: Bool = false

    var environmentForTesting: [String: String]?
    var homeDirectoryForTesting: URL?
    var startupDirectoryForTesting: URL?
    var skipTrustedPricingLoadForTesting: Bool = false

    func run() async throws {
        try await run(stopAfterListeningForTesting: false)
    }

    func run(stopAfterListeningForTesting: Bool) async throws {
        do {
            let normalizedBind = try ConsumeEndpointConfig.normalizeBindAddress(bind)
            let origin = try ConsumeEndpointConfig.normalizeUpstreamOrigin(upstreamGatewayURL)
            guard port != 0, (1...65_535).contains(port) else {
                throw ConsumeStartupError(code: "local_bind_rejected")
            }
            let launchID = UUID().uuidString.lowercased()
            let token = try ConsumeLocalToken.generate()
            let budgetConfig = try ConsumeBudgetConfig.parse(
                budgetUSD: budgetUSD,
                maxRequestUSD: maxRequestUSD,
                noBudget: noBudget,
                ledgerPath: ledgerPath,
                allowUnpriced: allowUnpriced,
                runID: launchID,
                homeDirectory: homeDirectoryForTesting ?? FileManager.default.homeDirectoryForCurrentUser,
                startupDirectory: startupDirectoryForTesting ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            )
            let trustedPricing: ConsumeTrustedPricingState
            if budgetConfig.mode == .unconfigured || skipTrustedPricingLoadForTesting {
                trustedPricing = .notLoaded
            } else {
                trustedPricing = await ConsumeTrustedPricingLoader().load(from: origin)
            }
            var credential = try ConsumeCredentialLoader.load(
                explicitCredentialFile: credentialFile,
                environment: environmentForTesting ?? ProcessInfo.processInfo.environment,
                homeDirectory: homeDirectoryForTesting ?? FileManager.default.homeDirectoryForCurrentUser
            )
            let credentialSourceClass = credential.sourceClass.rawValue
            let credentialStatus = credential.status
            let credentialCustody = ConsumeCredentialCustody(credential: credential)
            credential.zeroize()
            let descriptorStore = ConsumeActiveEndpointStore(
                homeDirectory: homeDirectoryForTesting ?? FileManager.default.homeDirectoryForCurrentUser
            )
            let descriptorLock = try descriptorStore.acquireLock()
            let boundURL = ConsumeEndpointConfig.localBaseURL(bindAddress: normalizedBind, port: port)
            let descriptor = ConsumeEndpointDescriptor(
                boundURL: boundURL,
                processID: Int(getpid()),
                launchID: launchID,
                startedAt: ConsumeEndpointStatus.iso8601(Date()),
                ledgerPathClass: budgetConfig.ledgerPathClass,
                localToken: token.value
            )
            let runtime = ConsumeEndpointRuntime(
                launchID: launchID,
                boundURL: descriptor.boundURL,
                upstreamOrigin: origin,
                credentialSourceClass: credentialSourceClass,
                credentialStatus: credentialStatus,
                modelAllowlist: allowedModels,
                tokenVerifier: token.verifier,
                credentialCustody: credentialCustody,
                budget: budgetConfig,
                trustedPricing: trustedPricing
            )
            let server = ConsumeLocalServer(
                bindAddress: normalizedBind,
                port: port,
                runtime: runtime,
                onListening: {
                    try descriptorStore.writeDescriptor(descriptor, lock: descriptorLock)
                    ConsumeEndpointStatus.writeStartup(
                        boundURL: descriptor.boundURL,
                        localToken: token.value,
                        upstreamOrigin: origin,
                        modelAllowlist: allowedModels,
                        budget: budgetConfig,
                        credentialSourceClass: credentialSourceClass,
                        credentialState: credentialStatus.state.rawValue
                    )
                }
            )
            defer {
                try? descriptorStore.removeDescriptor(lock: descriptorLock)
            }
            try server.run(stopAfterListening: stopAfterListeningForTesting)
        } catch let error as ConsumeStartupError {
            ConsumeEndpointStatus.writeStderr("\(error.code)\n")
            throw error.exitCode
        } catch let error as ConsumeCredentialError {
            ConsumeEndpointStatus.writeStderr("\(error.redactedCode)\n")
            throw error.exitCode
        } catch let error as ConsumeBudgetError {
            ConsumeEndpointStatus.writeStderr("\(error.code)\n")
            throw error.exitCode
        }
    }
}

struct ConsumeBudgetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "budget",
        abstract: "Inspect or recover the local consumer budget ledger.",
        subcommands: [ConsumeBudgetStatusCommand.self, ConsumeBudgetReleaseHeldCommand.self]
    )
}

struct ConsumeBudgetStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")

    @Option(name: .customLong("ledger"), help: "Budget ledger path or 'default'.")
    var ledgerPath: String = "default"

    var homeDirectoryForTesting: URL?
    var startupDirectoryForTesting: URL?

    func run() async throws {
        do {
            let ledger = try ConsumeBudgetLedger.open(
                ledgerPath: ledgerPath,
                homeDirectory: homeDirectoryForTesting ?? FileManager.default.homeDirectoryForCurrentUser,
                startupDirectory: startupDirectoryForTesting ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            )
            let summary = try ledger.summary()
            try StatusCommand.writeJSON([
                "schema_version": "local_consumer_endpoint.budget_status.v1",
                "ledger_path_class": ledger.pathClass,
                "reserved_micro_usd": "\(summary.reserved.rawValue)",
                "settled_micro_usd": "\(summary.settled.rawValue)",
                "held_micro_usd": "\(summary.held.rawValue)",
                "released_micro_usd": "\(summary.released.rawValue)",
                "estimate_exceeded_micro_usd": "\(summary.estimateExceeded.rawValue)",
                "held_reservation_count": summary.heldReservationCount,
            ])
        } catch let error as ConsumeBudgetError {
            ConsumeEndpointStatus.writeStderr("\(error.code)\n")
            throw error.exitCode
        }
    }
}

struct ConsumeBudgetReleaseHeldCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release-held")

    @Option(name: .customLong("ledger"), help: "Budget ledger path or 'default'.")
    var ledgerPath: String

    @Option(name: .customLong("run-id"), help: "Run id whose held reservations may be released.")
    var runID: String

    @Flag(name: .customLong("confirm-release-held"), help: "Required confirmation for releasing held local reservations.")
    var confirmReleaseHeld: Bool = false

    var homeDirectoryForTesting: URL?
    var startupDirectoryForTesting: URL?

    func run() async throws {
        do {
            guard confirmReleaseHeld else {
                throw ConsumeBudgetError(code: "local_budget_flag_rejected")
            }
            let ledger = try ConsumeBudgetLedger.open(
                ledgerPath: ledgerPath,
                homeDirectory: homeDirectoryForTesting ?? FileManager.default.homeDirectoryForCurrentUser,
                startupDirectory: startupDirectoryForTesting ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            )
            let released = try ledger.releaseHeld(runID: runID)
            guard released > 0 else {
                throw ConsumeBudgetError(code: "local_no_held_reservations", exitCode: ExitCode(4))
            }
            try StatusCommand.writeJSON([
                "schema_version": "local_consumer_endpoint.release_held.v1",
                "run_id": runID,
                "released_reservation_count": released,
            ])
        } catch let error as ConsumeBudgetError {
            ConsumeEndpointStatus.writeStderr("\(error.code)\n")
            throw error.exitCode
        }
    }
}

struct ConsumeStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print redacted local consumer endpoint status."
    )

    var homeDirectoryForTesting: URL?

    func run() async throws {
        let store = ConsumeActiveEndpointStore(
            homeDirectory: homeDirectoryForTesting ?? FileManager.default.homeDirectoryForCurrentUser
        )
        guard let descriptor = try store.readLiveDescriptor() else {
            ConsumeEndpointStatus.writeStderr("local_endpoint_not_running\n")
            throw ExitCode(4)
        }
        do {
            let status = try await ConsumeStatusClient.fetch(descriptor: descriptor)
            try StatusCommand.writeJSON(status)
        } catch {
            ConsumeEndpointStatus.writeStderr("local_endpoint_not_running\n")
            throw ExitCode(4)
        }
    }
}

enum ConsumeEndpointDefaults {
    static let upstreamGatewayOrigin = "https://api.malibu.tech"
}

struct ConsumeBudgetError: Error {
    let code: String
    let exitCode: ExitCode

    init(code: String, exitCode: ExitCode = ExitCode(2)) {
        self.code = code
        self.exitCode = exitCode
    }
}

struct ConsumeMicroUSD: Equatable, Comparable, Sendable {
    let rawValue: Int64

    static let zero = ConsumeMicroUSD(rawValue: 0)

    static func < (lhs: ConsumeMicroUSD, rhs: ConsumeMicroUSD) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func + (lhs: ConsumeMicroUSD, rhs: ConsumeMicroUSD) throws -> ConsumeMicroUSD {
        let (value, overflow) = lhs.rawValue.addingReportingOverflow(rhs.rawValue)
        guard !overflow else { throw ConsumeBudgetError(code: "local_pricing_unavailable") }
        return ConsumeMicroUSD(rawValue: value)
    }

    static func - (lhs: ConsumeMicroUSD, rhs: ConsumeMicroUSD) -> ConsumeMicroUSD {
        ConsumeMicroUSD(rawValue: max(0, lhs.rawValue - rhs.rawValue))
    }

    static func parsePositiveUSD(_ raw: String?) throws -> ConsumeMicroUSD? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[0-9]+(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil else {
            throw ConsumeBudgetError(code: "local_budget_flag_rejected")
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard let dollars = Int64(parts[0]) else {
            throw ConsumeBudgetError(code: "local_budget_flag_rejected")
        }
        let microsText: String
        if parts.count == 2 {
            microsText = String(parts[1]).padding(toLength: 6, withPad: "0", startingAt: 0)
        } else {
            microsText = "000000"
        }
        guard let micros = Int64(microsText.prefix(6)) else {
            throw ConsumeBudgetError(code: "local_budget_flag_rejected")
        }
        let (major, overflowMajor) = dollars.multipliedReportingOverflow(by: 1_000_000)
        let (total, overflowTotal) = major.addingReportingOverflow(micros)
        guard !overflowMajor, !overflowTotal, total > 0 else {
            throw ConsumeBudgetError(code: "local_budget_flag_rejected")
        }
        return ConsumeMicroUSD(rawValue: total)
    }
}

struct ConsumePricedExposureEstimate: Equatable, Sendable {
    let amount: ConsumeMicroUSD
    let promptTokenUpperBound: Int64
    let completionTokenUpperBound: Int64
    let rateCardKey: String
}

enum ConsumePricedExposureEstimator {
    static func estimate(
        bodyByteCount: Int,
        request: JSONValue,
        match: ConsumeTrustedRateCardMatch,
        projection: RateCardProjection
    ) throws -> ConsumePricedExposureEstimate {
        guard bodyByteCount >= 0,
              let promptTokens = Int64(exactly: bodyByteCount),
              let completionTokens = explicitOutputTokenBound(from: request) else {
            throw ConsumeBudgetError(code: "local_pricing_unavailable")
        }
        return try estimate(
            promptTokenUpperBound: promptTokens,
            completionTokenUpperBound: completionTokens,
            match: match,
            projection: projection
        )
    }

    static func estimate(
        promptTokenUpperBound promptTokens: Int64,
        completionTokenUpperBound completionTokens: Int64,
        match: ConsumeTrustedRateCardMatch,
        projection: RateCardProjection
    ) throws -> ConsumePricedExposureEstimate {
        guard promptTokens >= 0, completionTokens > 0 else {
            throw ConsumeBudgetError(code: "local_pricing_unavailable")
        }
        let row = match.row
        let prompt = try componentMicroUSD(
            tokens: promptTokens,
            ratePerMtok: row.promptRatePerMtok,
            globalMultiplierPPM: row.globalMultiplierPPM,
            usdPerMillionCredits: projection.usdPerMillionCredits
        )
        let completion = try componentMicroUSD(
            tokens: completionTokens,
            ratePerMtok: row.completionRatePerMtok,
            globalMultiplierPPM: row.globalMultiplierPPM,
            usdPerMillionCredits: projection.usdPerMillionCredits
        )
        let amount = try prompt + completion
        guard amount > .zero else {
            throw ConsumeBudgetError(code: "local_pricing_unavailable")
        }
        return ConsumePricedExposureEstimate(
            amount: amount,
            promptTokenUpperBound: promptTokens,
            completionTokenUpperBound: completionTokens,
            rateCardKey: match.rateCardKey
        )
    }

    static func actualUsageSettlement(
        promptTokens: Int64,
        completionTokens: Int64,
        match: ConsumeTrustedRateCardMatch,
        projection: RateCardProjection
    ) throws -> ConsumeMicroUSD {
        guard promptTokens >= 0, completionTokens >= 0 else {
            throw ConsumeBudgetError(code: "local_pricing_unavailable")
        }
        let row = match.row
        let prompt = try componentMicroUSD(
            tokens: promptTokens,
            ratePerMtok: row.promptRatePerMtok,
            globalMultiplierPPM: row.globalMultiplierPPM,
            usdPerMillionCredits: projection.usdPerMillionCredits
        )
        let completion = try componentMicroUSD(
            tokens: completionTokens,
            ratePerMtok: row.completionRatePerMtok,
            globalMultiplierPPM: row.globalMultiplierPPM,
            usdPerMillionCredits: projection.usdPerMillionCredits
        )
        return try prompt + completion
    }

    private static func explicitOutputTokenBound(from request: JSONValue) -> Int64? {
        request.objectPositiveInt64("max_tokens")
    }

    private static func componentMicroUSD(
        tokens: Int64,
        ratePerMtok: Int64,
        globalMultiplierPPM: Int64,
        usdPerMillionCredits: Double
    ) throws -> ConsumeMicroUSD {
        guard tokens >= 0,
              ratePerMtok >= 0,
              globalMultiplierPPM >= 0,
              usdPerMillionCredits.isFinite,
              usdPerMillionCredits >= 0 else {
            throw ConsumeBudgetError(code: "local_pricing_unavailable")
        }
        if tokens == 0 || ratePerMtok == 0 || globalMultiplierPPM == 0 || usdPerMillionCredits == 0 {
            return .zero
        }
        guard let creditsDecimal = decimalUSDPerMillionCredits(usdPerMillionCredits) else {
            throw ConsumeBudgetError(code: "local_pricing_unavailable")
        }
        let numerator = Decimal(tokens)
            * Decimal(ratePerMtok)
            * Decimal(globalMultiplierPPM)
            * creditsDecimal
        var quotient = numerator / Decimal(1_000_000_000_000 as Int64)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, 0, .up)
        let number = NSDecimalNumber(decimal: rounded)
        guard number != NSDecimalNumber.notANumber,
              number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
              number.compare(NSDecimalNumber.zero) != .orderedAscending else {
            throw ConsumeBudgetError(code: "local_pricing_unavailable")
        }
        return ConsumeMicroUSD(rawValue: number.int64Value)
    }

    private static func decimalUSDPerMillionCredits(_ value: Double) -> Decimal? {
        guard value == 1.0 else {
            return nil
        }
        return Decimal(1)
    }
}

enum ConsumeBudgetMode: Equatable, Sendable {
    case unconfigured
    case budget(ConsumeMicroUSD)
    case noBudget

    var startupName: String {
        switch self {
        case .unconfigured: return "unconfigured"
        case .budget: return "budget"
        case .noBudget: return "no_budget"
        }
    }
}

struct ConsumeBudgetConfig: @unchecked Sendable {
    let mode: ConsumeBudgetMode
    let maxRequestMicroUSD: ConsumeMicroUSD?
    let allowUnpriced: Bool
    let ledger: ConsumeBudgetLedger?
    let ledgerPathClass: String?

    static let unconfigured = ConsumeBudgetConfig(
        mode: .unconfigured,
        maxRequestMicroUSD: nil,
        allowUnpriced: false,
        ledger: nil,
        ledgerPathClass: nil
    )

    static func parse(
        budgetUSD: String?,
        maxRequestUSD: String?,
        noBudget: Bool,
        ledgerPath: String?,
        allowUnpriced: Bool,
        runID: String,
        homeDirectory: URL,
        startupDirectory: URL
    ) throws -> ConsumeBudgetConfig {
        let budget = try ConsumeMicroUSD.parsePositiveUSD(budgetUSD)
        let maxRequest = try ConsumeMicroUSD.parsePositiveUSD(maxRequestUSD)
        guard !(budget != nil && noBudget) else {
            throw ConsumeBudgetError(code: "local_budget_flag_rejected")
        }
        guard budget != nil || noBudget || ledgerPath == nil else {
            throw ConsumeBudgetError(code: "local_budget_flag_rejected")
        }

        let mode: ConsumeBudgetMode
        if let budget {
            mode = .budget(budget)
        } else if noBudget {
            mode = .noBudget
        } else {
            mode = .unconfigured
        }
        guard mode != .unconfigured else {
            return ConsumeBudgetConfig(
                mode: mode,
                maxRequestMicroUSD: maxRequest,
                allowUnpriced: allowUnpriced,
                ledger: nil,
                ledgerPathClass: nil
            )
        }
        if mode == .noBudget && ledgerPath == nil {
            return ConsumeBudgetConfig(
                mode: mode,
                maxRequestMicroUSD: maxRequest,
                allowUnpriced: allowUnpriced,
                ledger: nil,
                ledgerPathClass: nil
            )
        }
        let ledger = try ConsumeBudgetLedger.open(
            ledgerPath: ledgerPath ?? "default",
            homeDirectory: homeDirectory,
            startupDirectory: startupDirectory
        )
        try ledger.markHeldReservationsForRestart(excludingRunID: runID)
        return ConsumeBudgetConfig(
            mode: mode,
            maxRequestMicroUSD: maxRequest,
            allowUnpriced: allowUnpriced,
            ledger: ledger,
            ledgerPathClass: ledger.pathClass
        )
    }

    func statusFields(
        trustedPricing: ConsumeTrustedPricingState = .notLoaded,
        pricingEstimateExceeded: Bool = false
    ) -> [String: Any] {
        let summary: ConsumeBudgetLedgerSummary?
        if let ledger {
            summary = try? ledger.summary()
        } else {
            summary = .empty
        }
        let committedExposure = try? summary?.committedExposure()
        let ledgerIsHealthy = summary != nil && committedExposure != nil
        let safeSummary = summary ?? .empty
        let configured: Any
        let used: Any
        let held: Any
        let remaining: Any
        let noBudget: Bool
        switch mode {
        case .unconfigured:
            configured = NSNull()
            used = NSNull()
            held = NSNull()
            remaining = NSNull()
            noBudget = false
        case .budget(let budget):
            configured = "\(budget.rawValue)"
            used = ledgerIsHealthy ? "\(safeSummary.settled.rawValue)" : NSNull()
            held = ledgerIsHealthy ? "\(safeSummary.held.rawValue)" : NSNull()
            if ledgerIsHealthy, let committed = committedExposure {
                remaining = budget > committed ? "\(budget.rawValue - committed.rawValue)" : "0"
            } else {
                remaining = NSNull()
            }
            noBudget = false
        case .noBudget:
            configured = NSNull()
            used = NSNull()
            held = NSNull()
            remaining = NSNull()
            noBudget = true
        }
        let ledgerClass: Any = ledgerPathClass ?? NSNull()
        let ledgerState: Any = ledger == nil ? NSNull() : (ledgerIsHealthy ? "available" : "unavailable")
        let pricingState: String
        let pricingWarnings: [String]
        if case .unconfigured = mode {
            pricingState = "unavailable"
            pricingWarnings = []
        } else if pricingEstimateExceeded {
            pricingState = "estimate_exceeded"
            pricingWarnings = []
        } else {
            pricingState = ledgerIsHealthy ? pricingTrustState(trustedPricing: trustedPricing) : "unavailable"
            pricingWarnings = ledgerIsHealthy ? pricingWarningCodes(trustedPricing: trustedPricing) : []
        }
        return [
            "pricing_trust_state": pricingState,
            "pricing_warning_codes": pricingWarnings,
            "unpriced_override": allowUnpriced,
            "no_budget": noBudget,
            "budget_configured_micro_usd": configured,
            "budget_used_micro_usd": used,
            "budget_held_micro_usd": held,
            "budget_remaining_micro_usd": remaining,
            "ledger_path_class": ledgerClass,
            "budget_ledger_state": ledgerState,
        ]
    }

    func pricingTrustState(trustedPricing: ConsumeTrustedPricingState) -> String {
        if case .available = trustedPricing { return trustedPricing.statusState }
        if allowUnpriced, case .budget = mode { return "unpriced_override" }
        return "unavailable"
    }

    func pricingWarningCodes(trustedPricing: ConsumeTrustedPricingState) -> [String] {
        trustedPricing.warningCodes
    }

    var localWarningTokens: [String] {
        var warnings: [String] = []
        if case .noBudget = mode { warnings.append("no_budget") }
        if allowUnpriced { warnings.append("unpriced_override") }
        return warnings
    }
}

struct ConsumeUpstreamRequest: Sendable {
    let origin: String
    let endpoint: String
    let bearerToken: String
    let body: Data
}

struct ConsumeUpstreamResponse: Sendable {
    let statusCode: Int
    let headers: [(String, String)]
    let body: Data
}

enum ConsumeUpstreamForwardError: Error {
    case preDispatchUnavailable
    case dispatchedUnavailable
}

private enum ConsumeUpstreamResponseContentCoding {
    case identity
    case gzip
}

struct ConsumeUpstreamTimeouts: Sendable {
    let connectNanoseconds: UInt64
    let sendNanoseconds: UInt64
    let readNanoseconds: UInt64

    static let `default` = ConsumeUpstreamTimeouts(
        connectNanoseconds: 5_000_000_000,
        sendNanoseconds: 5_000_000_000,
        readNanoseconds: 30_000_000_000
    )
}

private struct ConsumeUpstreamFailureClassification {
    let status: HTTPResponseStatus
    let forwardedUpstream: Bool
}

protocol ConsumeUpstreamClient: Sendable {
    func resolveChatCompletionsEndpoint(
        origin: String,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<String>

    func forwardChatCompletions(
        request: ConsumeUpstreamRequest,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ConsumeUpstreamResponse>
}

final class ConsumePinnedUpstreamClient: ConsumeUpstreamClient, @unchecked Sendable {
    private let maxBodyBytes: Int
    private let timeouts: ConsumeUpstreamTimeouts

    private final class ReceiveState: @unchecked Sendable {
        var received = Data()
    }

    private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func finish(_ result: Result<Value, Error>, continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private final class DeadlineTimer: @unchecked Sendable {
        private let lock = NSLock()
        private var task: DispatchWorkItem?

        func schedule(nanoseconds: UInt64, _ block: @escaping @Sendable () -> Void) {
            let work = DispatchWorkItem(block: block)
            lock.lock()
            task = work
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .nanoseconds(Int(nanoseconds)),
                execute: work
            )
        }

        func cancel() {
            lock.lock()
            let current = task
            task = nil
            lock.unlock()
            current?.cancel()
        }
    }

    init(
        maxBodyBytes: Int = ConsumeLocalLimits.bodyBytes,
        timeouts: ConsumeUpstreamTimeouts = .default
    ) {
        self.maxBodyBytes = maxBodyBytes
        self.timeouts = timeouts
    }

    func resolveChatCompletionsEndpoint(
        origin: String,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<String> {
        let promise = eventLoop.makePromise(of: String.self)
        Task { @Sendable in
            do {
                let endpoint = try await Self.resolveEndpoint(
                    origin: origin,
                    timeoutNanoseconds: timeouts.connectNanoseconds
                )
                promise.succeed(endpoint)
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    func forwardChatCompletions(
        request upstreamRequest: ConsumeUpstreamRequest,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ConsumeUpstreamResponse> {
        let promise = eventLoop.makePromise(of: ConsumeUpstreamResponse.self)
        Task { @Sendable in
            do {
                let response = try await Self.fetch(
                    upstreamRequest: upstreamRequest,
                    maxBodyBytes: maxBodyBytes,
                    timeouts: timeouts
                )
                promise.succeed(response)
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    private static func resolveEndpoint(origin: String, timeoutNanoseconds: UInt64) async throws -> String {
        guard let host = upstreamTarget(origin: origin).host else {
            throw ConsumeStartupError(code: "local_upstream_url_rejected")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let gate = ContinuationGate<String>()
            let deadline = DeadlineTimer()
            @Sendable func finish(_ result: Result<String, Error>) {
                deadline.cancel()
                gate.finish(result, continuation: continuation)
            }
            let resolver = Task.detached(priority: .utility) {
                do {
                    let endpoints = try ConsumeEndpointConfig.validatedGlobalUpstreamEndpoints(host)
                    guard let endpoint = endpoints.first else {
                        throw ConsumeStartupError(code: "local_upstream_url_rejected")
                    }
                    finish(.success(endpoint))
                } catch {
                    finish(.failure(error))
                }
            }
            deadline.schedule(nanoseconds: timeoutNanoseconds) {
                resolver.cancel()
                finish(.failure(ConsumeUpstreamForwardError.preDispatchUnavailable))
            }
        }
    }

    private static func upstreamTarget(origin: String) -> (host: String?, port: Int?) {
        guard let components = URLComponents(string: origin),
              components.scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return (nil, nil)
        }
        return (components.host, components.port ?? 443)
    }

    private static func fetch(
        upstreamRequest: ConsumeUpstreamRequest,
        maxBodyBytes: Int,
        timeouts: ConsumeUpstreamTimeouts
    ) async throws -> ConsumeUpstreamResponse {
        guard var components = URLComponents(string: upstreamRequest.origin),
              components.scheme == "https",
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ConsumeStartupError(code: "local_upstream_url_rejected")
        }
        let portValue = components.port ?? 443
        guard (1...65_535).contains(portValue),
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw ConsumeStartupError(code: "local_upstream_url_rejected")
        }
        guard ConsumeEndpointConfig.isValidatedGlobalEndpoint(upstreamRequest.endpoint) else {
            throw ConsumeStartupError(code: "local_upstream_url_rejected")
        }
        components.path = "/v1/chat/completions"
        let connection = NWConnection(
            host: NWEndpoint.Host(upstreamRequest.endpoint),
            port: port,
            using: tlsParameters(serverName: host)
        )
        let queue = DispatchQueue(label: "macprovider.consume.upstream.\(UUID().uuidString)")
        connection.start(queue: queue)
        do {
            try await waitUntilReady(
                connection,
                timeoutNanoseconds: timeouts.connectNanoseconds
            )
        } catch {
            connection.cancel()
            throw ConsumeUpstreamForwardError.preDispatchUnavailable
        }
        let request = httpRequestBytes(
            host: host,
            port: portValue,
            bearerToken: upstreamRequest.bearerToken,
            body: upstreamRequest.body
        )
        do {
            try await send(
                request,
                on: connection,
                timeoutNanoseconds: timeouts.sendNanoseconds
            )
        } catch {
            connection.cancel()
            throw classifySendFailure(error)
        }
        do {
            let response = try await readHTTPResponse(
                from: connection,
                maxBodyBytes: maxBodyBytes,
                timeoutNanoseconds: timeouts.readNanoseconds
            )
            connection.cancel()
            return response
        } catch {
            connection.cancel()
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
    }

    private static func tlsParameters(serverName: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        let parameters = NWParameters(tls: tls)
        parameters.prohibitExpensivePaths = true
        parameters.prohibitedInterfaceTypes = [.loopback]
        return parameters
    }

    private static func waitUntilReady(_ connection: NWConnection, timeoutNanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>()
            let deadline = DeadlineTimer()
            @Sendable func finish(_ result: Result<Void, Error>) {
                deadline.cancel()
                gate.finish(result, continuation: continuation)
            }
            deadline.schedule(nanoseconds: timeoutNanoseconds) {
                connection.cancel()
                finish(.failure(ConsumeUpstreamForwardError.dispatchedUnavailable))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(ConsumeUpstreamForwardError.preDispatchUnavailable))
                default:
                    break
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection, timeoutNanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>()
            let deadline = DeadlineTimer()
            @Sendable func finish(_ result: Result<Void, Error>) {
                deadline.cancel()
                gate.finish(result, continuation: continuation)
            }
            deadline.schedule(nanoseconds: timeoutNanoseconds) {
                connection.cancel()
                finish(.failure(ConsumeUpstreamForwardError.preDispatchUnavailable))
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(()))
                }
            })
        }
    }

    private static func classifySendFailure(_ error: Error) -> ConsumeUpstreamForwardError {
        .preDispatchUnavailable
    }

    static func sendFailureClassificationForTesting(_ error: Error) -> ConsumeUpstreamForwardError {
        classifySendFailure(error)
    }

    private static func readHTTPResponse(
        from connection: NWConnection,
        maxBodyBytes: Int,
        timeoutNanoseconds: UInt64
    ) async throws -> ConsumeUpstreamResponse {
        try await withCheckedThrowingContinuation { continuation in
            let state = ReceiveState()
            let gate = ContinuationGate<ConsumeUpstreamResponse>()
            let headerTerminator = Data([13, 10, 13, 10])
            let deadline = DeadlineTimer()
            @Sendable func finish(_ result: Result<ConsumeUpstreamResponse, Error>) {
                deadline.cancel()
                gate.finish(result, continuation: continuation)
            }
            deadline.schedule(nanoseconds: timeoutNanoseconds) {
                connection.cancel()
                finish(.failure(ConsumeUpstreamForwardError.dispatchedUnavailable))
            }
            @Sendable func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                    if let error {
                        finish(.failure(error))
                        return
                    }
                    if let data, !data.isEmpty {
                        state.received.append(data)
                    }
                    if let headerRange = state.received.range(of: headerTerminator) {
                        let bodyStart = headerRange.upperBound
                        let rawBodyBytes = state.received.count - bodyStart
                        guard headerRange.lowerBound <= ConsumeLocalLimits.headerBytes,
                              rawBodyBytes <= maxBodyBytes + 64 * 1024 else {
                            finish(.failure(ConsumeUpstreamForwardError.dispatchedUnavailable))
                            return
                        }
                        do {
                            if let response = try parseCompleteHTTPResponseIfAvailable(
                                state.received,
                                maxBodyBytes: maxBodyBytes,
                                allowCloseDelimitedBody: isComplete
                            ) {
                                finish(.success(response))
                                return
                            }
                        } catch {
                            finish(.failure(error))
                            return
                        }
                    } else if state.received.count > ConsumeLocalLimits.headerBytes {
                        finish(.failure(ConsumeUpstreamForwardError.dispatchedUnavailable))
                        return
                    }
                    if isComplete {
                        do {
                            finish(.success(try parseHTTPResponse(state.received, maxBodyBytes: maxBodyBytes)))
                        } catch {
                            finish(.failure(error))
                        }
                    } else {
                        receiveNext()
                    }
                }
            }
            receiveNext()
        }
    }

    private static func parseHTTPResponse(_ data: Data, maxBodyBytes: Int) throws -> ConsumeUpstreamResponse {
        guard let response = try parseCompleteHTTPResponseIfAvailable(
            data,
            maxBodyBytes: maxBodyBytes,
            allowCloseDelimitedBody: true
        ) else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        return response
    }

    static func parseCompleteHTTPResponseForTesting(
        _ data: Data,
        maxBodyBytes: Int,
        allowCloseDelimitedBody: Bool
    ) throws -> ConsumeUpstreamResponse? {
        try parseCompleteHTTPResponseIfAvailable(
            data,
            maxBodyBytes: maxBodyBytes,
            allowCloseDelimitedBody: allowCloseDelimitedBody
        )
    }

    private static func parseCompleteHTTPResponseIfAvailable(
        _ data: Data,
        maxBodyBytes: Int,
        allowCloseDelimitedBody: Bool
    ) throws -> ConsumeUpstreamResponse? {
        let headerTerminator = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: headerTerminator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .isoLatin1) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusParts[1]),
              (200...599).contains(statusCode) else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        var headers: [(String, String)] = []
        var headerBytes = 0
        for line in lines.dropFirst() {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            let name = trimHTTPOptionalWhitespace(line[..<colon])
            let value = trimHTTPOptionalWhitespace(line[line.index(after: colon)...])
            guard validHTTPHeaderName(name),
                  validHTTPHeaderValue(value) else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            headerBytes += name.utf8.count + value.utf8.count + 4
            guard headers.count < ConsumeLocalLimits.headerCount,
                  headerBytes <= ConsumeLocalLimits.headerBytes else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            headers.append((name, value))
        }
        let rawBody = data[headerRange.upperBound...]
        let body: Data
        let usesChunkedTransfer = try chunkedTransferEncoding(headers)
        let declaredContentLength = try contentLength(headers)
        guard !usesChunkedTransfer || declaredContentLength == nil else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        if usesChunkedTransfer {
            guard let decoded = try decodeCompleteChunkedBodyIfAvailable(Data(rawBody), maxBodyBytes: maxBodyBytes) else {
                return nil
            }
            body = decoded
        } else if let contentLength = declaredContentLength {
            guard contentLength <= maxBodyBytes else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            guard rawBody.count >= contentLength else {
                return nil
            }
            guard rawBody.count == contentLength else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            body = Data(rawBody)
        } else {
            guard allowCloseDelimitedBody else {
                return nil
            }
            body = Data(rawBody)
        }
        guard body.count <= maxBodyBytes else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        return ConsumeUpstreamResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private static func validHTTPHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        for byte in name.utf8 {
            switch byte {
            case 0x21, 0x23...0x27, 0x2a, 0x2b, 0x2d, 0x2e, 0x30...0x39, 0x41...0x5a, 0x5e...0x7a, 0x7c, 0x7e:
                continue
            default:
                return false
            }
        }
        return true
    }

    private static func validHTTPHeaderValue(_ value: String) -> Bool {
        for byte in value.utf8 {
            guard byte == 0x09 || (byte >= 0x20 && byte != 0x7f) else {
                return false
            }
        }
        return true
    }

    private static func trimHTTPOptionalWhitespace(_ value: Substring) -> String {
        var start = value.startIndex
        var end = value.endIndex
        while start < end, value[start] == " " || value[start] == "\t" {
            start = value.index(after: start)
        }
        while start < end {
            let previous = value.index(before: end)
            guard value[previous] == " " || value[previous] == "\t" else { break }
            end = previous
        }
        return String(value[start..<end])
    }

    private static func chunkedTransferEncoding(_ headers: [(String, String)]) throws -> Bool {
        let tokens = headers
            .filter { name, _ in name.caseInsensitiveCompare("transfer-encoding") == .orderedSame }
            .flatMap { _, value in
                value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { trimHTTPOptionalWhitespace($0).lowercased() }
            }
        guard tokens.allSatisfy({ !$0.isEmpty }) else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        guard tokens.isEmpty || tokens == ["chunked"] else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        return !tokens.isEmpty
    }

    private static func contentLength(_ headers: [(String, String)]) throws -> Int? {
        let values = headers.compactMap { name, value -> String? in
            guard name.caseInsensitiveCompare("content-length") == .orderedSame else { return nil }
            return trimHTTPOptionalWhitespace(value[...])
        }
        guard values.count <= 1 else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        guard let value = values.first else {
            return nil
        }
        guard value.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              !value.contains(","),
              let length = Int(value) else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        return length
    }

    private static func decodeCompleteChunkedBodyIfAvailable(_ data: Data, maxBodyBytes: Int) throws -> Data? {
        var index = data.startIndex
        var decoded = Data()
        while true {
            guard let lineRange = data[index...].range(of: Data([13, 10])) else {
                return nil
            }
            let line = data[index..<lineRange.lowerBound]
            guard let lineText = String(data: line, encoding: .ascii) else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            let sizeText = lineText.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard let chunkSize = Int(trimHTTPOptionalWhitespace(sizeText[...]), radix: 16),
                  chunkSize >= 0 else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            index = lineRange.upperBound
            if chunkSize == 0 {
                guard data.distance(from: index, to: data.endIndex) >= 2 else {
                    return nil
                }
                guard data[index] == 13,
                      data[data.index(after: index)] == 10,
                      data.index(index, offsetBy: 2) == data.endIndex else {
                    throw ConsumeUpstreamForwardError.dispatchedUnavailable
                }
                return decoded
            }
            guard chunkSize <= maxBodyBytes - decoded.count else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            let available = data.distance(from: index, to: data.endIndex)
            guard chunkSize <= available,
                  available - chunkSize >= 2 else {
                return nil
            }
            decoded.append(data[index..<data.index(index, offsetBy: chunkSize)])
            guard decoded.count <= maxBodyBytes else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            index = data.index(index, offsetBy: chunkSize)
            guard data[index] == 13,
                  data[data.index(after: index)] == 10 else {
                throw ConsumeUpstreamForwardError.dispatchedUnavailable
            }
            index = data.index(index, offsetBy: 2)
        }
    }

    private static func httpRequestBytes(host: String, port: Int, bearerToken: String, body: Data) -> Data {
        let hostHeader = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let authority = port == 443 ? hostHeader : "\(hostHeader):\(port)"
        var request = Data()
        request.append(Data("POST /v1/chat/completions HTTP/1.1\r\n".utf8))
        request.append(Data("Host: \(authority)\r\n".utf8))
        request.append(Data("Authorization: Bearer \(bearerToken)\r\n".utf8))
        request.append(Data("Content-Type: application/json\r\n".utf8))
        request.append(Data("Accept: application/json\r\n".utf8))
        request.append(Data("Accept-Encoding: identity\r\n".utf8))
        request.append(Data("Connection: close\r\n".utf8))
        request.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
        request.append(body)
        return request
    }
}

final class ConsumePricingAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var estimateExceeded = false

    func isEstimateExceeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return estimateExceeded
    }

    func stopForEstimateExceeded() {
        lock.lock()
        estimateExceeded = true
        lock.unlock()
    }
}

private final class ConsumeNIOContextBox: @unchecked Sendable {
    let context: ChannelHandlerContext

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }
}

struct ConsumeBudgetLedgerSummary: Equatable {
    static let empty = ConsumeBudgetLedgerSummary(
        reserved: .zero,
        settled: .zero,
        held: .zero,
        released: .zero,
        estimateExceeded: .zero,
        heldReservationCount: 0
    )

    let reserved: ConsumeMicroUSD
    let settled: ConsumeMicroUSD
    let held: ConsumeMicroUSD
    let released: ConsumeMicroUSD
    let estimateExceeded: ConsumeMicroUSD
    let heldReservationCount: Int

    func committedExposure() throws -> ConsumeMicroUSD {
        try settled + held + reserved + estimateExceeded
    }
}

enum ConsumeBudgetAdmissionResult: Equatable {
    case held(ConsumeMicroUSD)
    case reserved(reservationID: String, amount: ConsumeMicroUSD)
    case budgetExceeded
    case requestCapExceeded
}

final class ConsumeBudgetLedger: @unchecked Sendable {
    static let schemaVersion = "local_consumer_endpoint.ledger.v1"
    static let phase3ALegacySchemaVersion = "local_consumer_endpoint.ledger.phase3a.v1"

    let url: URL
    let lockURL: URL
    let pathClass: String
    private let parentURL: URL
    private let parentFD: Int32
    private let parentIdentity: LedgerFileIdentity
    private let parentChain: [LedgerPathIdentity]
    private let lockFD: Int32
    private let lockIdentity: LedgerFileIdentity
    private let ledgerFD: Int32
    private let ledgerIdentity: LedgerFileIdentity
    private let lock = NSLock()
    private var ledgerHealthy = true

    private init(
        url: URL,
        lockURL: URL,
        pathClass: String,
        parentURL: URL,
        parentFD: Int32,
        parentIdentity: LedgerFileIdentity,
        parentChain: [LedgerPathIdentity],
        lockFD: Int32,
        lockIdentity: LedgerFileIdentity,
        ledgerFD: Int32,
        ledgerIdentity: LedgerFileIdentity
    ) {
        self.url = url
        self.lockURL = lockURL
        self.pathClass = pathClass
        self.parentURL = parentURL
        self.parentFD = parentFD
        self.parentIdentity = parentIdentity
        self.parentChain = parentChain
        self.lockFD = lockFD
        self.lockIdentity = lockIdentity
        self.ledgerFD = ledgerFD
        self.ledgerIdentity = ledgerIdentity
    }

    deinit {
        close(ledgerFD)
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
        close(parentFD)
    }

    static func open(
        ledgerPath: String,
        homeDirectory: URL,
        startupDirectory: URL
    ) throws -> ConsumeBudgetLedger {
        let resolved = try resolve(ledgerPath: ledgerPath, homeDirectory: homeDirectory, startupDirectory: startupDirectory)
        let parentURL = resolved.url.deletingLastPathComponent()
        let parent = try openPrivateDirectoryPath(parentURL)
        let parentFD = parent.fd
        var parentFDTransferred = false
        defer {
            if !parentFDTransferred {
                close(parentFD)
            }
        }
        let parentIdentity = parent.identity
        let parentChain = parent.chain
        let lockURL = URL(fileURLWithPath: resolved.url.path + ".lock")
        let ledgerName = resolved.url.lastPathComponent
        let lockName = ledgerName + ".lock"
        let lockFD = try openPrivateStateFileAt(parentFD: parentFD, name: lockName, accessFlags: O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        var lockFDTransferred = false
        var lockAcquired = false
        defer {
            if !lockFDTransferred {
                if lockAcquired {
                    _ = flock(lockFD, LOCK_UN)
                }
                close(lockFD)
            }
        }
        var flockResult: Int32
        repeat {
            flockResult = flock(lockFD, LOCK_EX | LOCK_NB)
        } while flockResult != 0 && errno == EINTR
        guard flockResult == 0 else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        lockAcquired = true
        guard privateRegularFile(lockFD),
              (try? !ConsumeACL.hasExtendedACLEntry(fd: lockFD)) == true,
              (try? verifyLocalFilesystem(fd: lockFD)) != nil else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        let lockIdentity = try ledgerFileIdentity(fd: lockFD)
        let ledgerFD = try openPrivateStateFileAt(
            parentFD: parentFD,
            name: ledgerName,
            accessFlags: O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        )
        var ledgerFDTransferred = false
        defer {
            if !ledgerFDTransferred {
                close(ledgerFD)
            }
        }
        guard privateRegularFile(ledgerFD),
              (try? !ConsumeACL.hasExtendedACLEntry(fd: ledgerFD)) == true,
              (try? verifyLocalFilesystem(fd: ledgerFD)) != nil else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        let identity = try ledgerFileIdentity(fd: ledgerFD)
        guard identity.device == lockIdentity.device else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        parentFDTransferred = true
        lockFDTransferred = true
        ledgerFDTransferred = true
        return ConsumeBudgetLedger(
            url: resolved.url,
            lockURL: lockURL,
            pathClass: resolved.pathClass,
            parentURL: parentURL,
            parentFD: parentFD,
            parentIdentity: parentIdentity,
            parentChain: parentChain,
            lockFD: lockFD,
            lockIdentity: lockIdentity,
            ledgerFD: ledgerFD,
            ledgerIdentity: identity
        )
    }

    static func resolve(ledgerPath: String, homeDirectory: URL, startupDirectory: URL) throws -> (url: URL, pathClass: String) {
        let trimmed = ledgerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConsumeBudgetError(code: "local_budget_flag_rejected")
        }
        if trimmed == "default" {
            return (
                homeDirectory.appendingPathComponent("Library/Application Support/macprovider/consume/ledgers/default.jsonl"),
                "default_user_state"
            )
        }
        if NSString(string: trimmed).isAbsolutePath {
            return (URL(fileURLWithPath: trimmed).standardizedFileURL, "explicit_absolute")
        }
        return (startupDirectory.appendingPathComponent(trimmed).standardizedFileURL, "explicit_relative")
    }

    func reserve(
        runID: String,
        amount: ConsumeMicroUSD,
        reason: String,
        unpricedOverride: Bool = false,
        noBudget: Bool = false
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        return try reserveUnlocked(
            runID: runID,
            amount: amount,
            reason: reason,
            unpricedOverride: unpricedOverride,
            noBudget: noBudget
        )
    }

    private func reserveUnlocked(
        runID: String,
        amount: ConsumeMicroUSD,
        reason: String,
        unpricedOverride: Bool = false,
        noBudget: Bool = false
    ) throws -> String {
        let reservationID = try Self.randomReservationID()
        try appendRowUnlocked([
            "schema_version": Self.schemaVersion,
            "transition": "reserved",
            "state": "reserved",
            "run_id": runID,
            "reservation_id": reservationID,
            "admission_estimate_micro_usd": "\(amount.rawValue)",
            "unpriced_override": unpricedOverride,
            "no_budget": noBudget,
            "reason": reason,
            "created_at": ConsumeEndpointStatus.iso8601(Date()),
        ])
        return reservationID
    }

    func hold(runID: String, reservationID: String, amount: ConsumeMicroUSD, reason: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        try holdUnlocked(runID: runID, reservationID: reservationID, amount: amount, reason: reason)
    }

    private func holdUnlocked(runID: String, reservationID: String, amount: ConsumeMicroUSD, reason: String) throws {
        try appendRowUnlocked([
            "schema_version": Self.schemaVersion,
            "transition": "held",
            "state": "held",
            "run_id": runID,
            "reservation_id": reservationID,
            "admission_estimate_micro_usd": "\(amount.rawValue)",
            "reason": reason,
            "created_at": ConsumeEndpointStatus.iso8601(Date()),
        ])
    }

    func reserveAndHoldUnpricedRemaining(
        runID: String,
        budget: ConsumeMicroUSD,
        maxRequest: ConsumeMicroUSD?
    ) throws -> ConsumeBudgetAdmissionResult {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        let summary = try summaryUnlocked()
        let committed = try summary.committedExposure()
        let remaining = budget - committed
        guard remaining > .zero else {
            return .budgetExceeded
        }
        if let maxRequest, remaining > maxRequest {
            return .requestCapExceeded
        }
        let reservationID = try reserveUnlocked(
            runID: runID,
            amount: remaining,
            reason: "unpriced_proxy_deferred",
            unpricedOverride: true
        )
        try holdUnlocked(
            runID: runID,
            reservationID: reservationID,
            amount: remaining,
            reason: "upstream_proxy_not_implemented"
        )
        return .held(remaining)
    }

    func previewUnpricedRemaining(
        budget: ConsumeMicroUSD,
        maxRequest: ConsumeMicroUSD?
    ) throws -> ConsumeBudgetAdmissionResult {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        let summary = try summaryUnlocked()
        let committed = try summary.committedExposure()
        let remaining = budget - committed
        guard remaining > .zero else {
            return .budgetExceeded
        }
        if let maxRequest, remaining > maxRequest {
            return .requestCapExceeded
        }
        return .held(remaining)
    }

    func previewPricedEstimateForForwarding(
        budget: ConsumeMicroUSD,
        estimate: ConsumeMicroUSD,
        maxRequest: ConsumeMicroUSD?
    ) throws -> ConsumeBudgetAdmissionResult {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        guard estimate > .zero else {
            return .requestCapExceeded
        }
        if let maxRequest, estimate > maxRequest {
            return .requestCapExceeded
        }
        let summary = try summaryUnlocked()
        let committed = try summary.committedExposure()
        let remaining = budget - committed
        guard estimate <= remaining else {
            return .budgetExceeded
        }
        return .held(estimate)
    }

    func reserveAndHoldPricedEstimate(
        runID: String,
        budget: ConsumeMicroUSD,
        estimate: ConsumeMicroUSD,
        maxRequest: ConsumeMicroUSD?
    ) throws -> ConsumeBudgetAdmissionResult {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        guard estimate > .zero else {
            return .requestCapExceeded
        }
        if let maxRequest, estimate > maxRequest {
            return .requestCapExceeded
        }
        let summary = try summaryUnlocked()
        let committed = try summary.committedExposure()
        let remaining = budget - committed
        guard estimate <= remaining else {
            return .budgetExceeded
        }
        let reservationID = try reserveUnlocked(
            runID: runID,
            amount: estimate,
            reason: "priced_proxy_deferred"
        )
        try holdUnlocked(
            runID: runID,
            reservationID: reservationID,
            amount: estimate,
            reason: "upstream_proxy_not_implemented"
        )
        return .held(estimate)
    }

    func reservePricedEstimateForForwarding(
        runID: String,
        budget: ConsumeMicroUSD,
        estimate: ConsumeMicroUSD,
        maxRequest: ConsumeMicroUSD?
    ) throws -> ConsumeBudgetAdmissionResult {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        guard estimate > .zero else {
            return .requestCapExceeded
        }
        if let maxRequest, estimate > maxRequest {
            return .requestCapExceeded
        }
        let summary = try summaryUnlocked()
        let committed = try summary.committedExposure()
        let remaining = budget - committed
        guard estimate <= remaining else {
            return .budgetExceeded
        }
        let reservationID = try reserveUnlocked(
            runID: runID,
            amount: estimate,
            reason: "priced_proxy_forwarding"
        )
        return .reserved(reservationID: reservationID, amount: estimate)
    }

    func reserveNoBudgetEstimateForForwarding(
        runID: String,
        estimate: ConsumeMicroUSD,
        maxRequest: ConsumeMicroUSD?
    ) throws -> ConsumeBudgetAdmissionResult {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        guard estimate > .zero else {
            return .requestCapExceeded
        }
        if let maxRequest, estimate > maxRequest {
            return .requestCapExceeded
        }
        let reservationID = try reserveUnlocked(
            runID: runID,
            amount: estimate,
            reason: "no_budget_proxy_forwarding",
            noBudget: true
        )
        return .reserved(reservationID: reservationID, amount: estimate)
    }

    func settle(
        runID: String,
        reservationID: String,
        reservedAmount: ConsumeMicroUSD,
        settledAmount: ConsumeMicroUSD,
        reason: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        try appendRowUnlocked([
            "schema_version": Self.schemaVersion,
            "transition": "settled",
            "state": "settled",
            "run_id": runID,
            "reservation_id": reservationID,
            "admission_estimate_micro_usd": "\(reservedAmount.rawValue)",
            "settled_exposure_micro_usd": "\(settledAmount.rawValue)",
            "reason": reason,
            "created_at": ConsumeEndpointStatus.iso8601(Date()),
        ])
    }

    func estimateExceeded(
        runID: String,
        reservationID: String,
        reservedAmount: ConsumeMicroUSD,
        settledAmount: ConsumeMicroUSD,
        reason: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        try appendRowUnlocked([
            "schema_version": Self.schemaVersion,
            "transition": "estimate_exceeded",
            "state": "estimate_exceeded",
            "run_id": runID,
            "reservation_id": reservationID,
            "admission_estimate_micro_usd": "\(reservedAmount.rawValue)",
            "settled_exposure_micro_usd": "\(settledAmount.rawValue)",
            "reason": reason,
            "created_at": ConsumeEndpointStatus.iso8601(Date()),
        ])
    }

    func markHeldReservationsForRestart(excludingRunID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        let states = try reservationStatesUnlocked()
        for state in states.values where state.state == "reserved" && state.runID != excludingRunID {
            try holdUnlocked(runID: state.runID, reservationID: state.reservationID, amount: state.amount, reason: "restart_recovery")
        }
    }

    func releaseHeld(runID: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        let states = try reservationStatesUnlocked()
        var released = 0
        for state in states.values where state.runID == runID && state.state == "held" {
            try appendRowUnlocked([
                "schema_version": Self.schemaVersion,
                "transition": "released",
                "state": "released",
                "run_id": state.runID,
                "reservation_id": state.reservationID,
                "admission_estimate_micro_usd": "\(state.amount.rawValue)",
                "reason": "operator_release_held",
                "created_at": ConsumeEndpointStatus.iso8601(Date()),
            ])
            released += 1
        }
        return released
    }

    func summary() throws -> ConsumeBudgetLedgerSummary {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyUnlocked()
        return try summaryUnlocked()
    }

    private func summaryUnlocked() throws -> ConsumeBudgetLedgerSummary {
        let states = try reservationStatesUnlocked()
        var reserved = ConsumeMicroUSD.zero
        var settled = ConsumeMicroUSD.zero
        var held = ConsumeMicroUSD.zero
        var released = ConsumeMicroUSD.zero
        var estimateExceeded = ConsumeMicroUSD.zero
        var heldCount = 0
        for state in states.values {
            switch state.state {
            case "reserved":
                reserved = try reserved + state.amount
            case "settled":
                settled = try settled + (state.settledAmount ?? state.amount)
            case "held":
                held = try held + state.amount
                heldCount += 1
            case "released":
                released = try released + state.amount
            case "estimate_exceeded":
                estimateExceeded = try estimateExceeded + (state.settledAmount ?? state.amount)
            default:
                throw markLedgerUnavailable()
            }
        }
        return ConsumeBudgetLedgerSummary(
            reserved: reserved,
            settled: settled,
            held: held,
            released: released,
            estimateExceeded: estimateExceeded,
            heldReservationCount: heldCount
        )
    }

    private struct ReservationState {
        let runID: String
        let reservationID: String
        let amount: ConsumeMicroUSD
        let settledAmount: ConsumeMicroUSD?
        let state: String
    }

    private func reservationStatesUnlocked() throws -> [String: ReservationState] {
        let rows = try readRowsUnlocked()
        var states: [String: ReservationState] = [:]
        for row in rows {
            guard let schemaVersion = row["schema_version"] as? String,
                  Self.supportedLedgerSchemaVersion(schemaVersion),
                  let transition = row["transition"] as? String,
                  let state = row["state"] as? String,
                  transition == state,
                  let runID = row["run_id"] as? String,
                  let reservationID = row["reservation_id"] as? String,
                  let amountText = Self.amountText(from: row, schemaVersion: schemaVersion),
                  let amountRaw = Int64(amountText),
                  amountRaw >= 0,
                  Self.allowedLedgerState(state, schemaVersion: schemaVersion),
                  Self.closedRowSchema(row, state: state, schemaVersion: schemaVersion) else {
                throw markLedgerUnavailable()
            }
            let settledAmount = try Self.settledAmount(from: row, state: state, schemaVersion: schemaVersion)
            let current = states[reservationID]
            guard current == nil || (current?.runID == runID && current?.amount == ConsumeMicroUSD(rawValue: amountRaw)),
                  Self.transitionAllowed(from: current?.state, to: state) else {
                throw markLedgerUnavailable()
            }
            states[reservationID] = ReservationState(
                runID: runID,
                reservationID: reservationID,
                amount: ConsumeMicroUSD(rawValue: amountRaw),
                settledAmount: settledAmount,
                state: state
            )
        }
        return states
    }

    private static func supportedLedgerSchemaVersion(_ schemaVersion: String) -> Bool {
        schemaVersion == Self.schemaVersion || schemaVersion == Self.phase3ALegacySchemaVersion
    }

    private static func amountText(from row: [String: Any], schemaVersion: String) -> String? {
        if schemaVersion == Self.phase3ALegacySchemaVersion {
            return row["amount_micro_usd"] as? String
        }
        return row["admission_estimate_micro_usd"] as? String
    }

    private static func settledAmount(
        from row: [String: Any],
        state: String,
        schemaVersion: String
    ) throws -> ConsumeMicroUSD? {
        guard state == "settled" || state == "estimate_exceeded" else {
            return nil
        }
        guard schemaVersion == Self.schemaVersion else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        guard let amountText = row["settled_exposure_micro_usd"] as? String,
              let amountRaw = Int64(amountText),
              amountRaw >= 0 else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        return ConsumeMicroUSD(rawValue: amountRaw)
    }

    private static func transitionAllowed(from current: String?, to next: String) -> Bool {
        guard let current else { return next == "reserved" }
        switch (current, next) {
        case ("reserved", "held"),
             ("reserved", "settled"),
             ("reserved", "estimate_exceeded"),
             ("held", "released"),
             ("held", "settled"):
            return true
        default:
            return false
        }
    }

    private static func allowedLedgerState(_ state: String, schemaVersion: String) -> Bool {
        if schemaVersion == Self.phase3ALegacySchemaVersion {
            return state == "reserved" || state == "held" || state == "released"
        }
        return state == "reserved" || state == "held" || state == "released" || state == "settled" || state == "estimate_exceeded"
    }

    private static func closedRowSchema(_ row: [String: Any], state: String, schemaVersion: String) -> Bool {
        let amountKey: String
        if schemaVersion == Self.phase3ALegacySchemaVersion {
            amountKey = "amount_micro_usd"
        } else {
            amountKey = "admission_estimate_micro_usd"
        }
        let commonKeys: Set<String> = [
            "schema_version", "transition", "state", "run_id",
            "reservation_id", amountKey, "reason", "created_at",
        ]
        let allowedKeys: Set<String>
        if state == "reserved" {
            allowedKeys = commonKeys.union(["unpriced_override", "no_budget"])
        } else if schemaVersion == Self.schemaVersion, state == "settled" || state == "estimate_exceeded" {
            allowedKeys = commonKeys.union(["settled_exposure_micro_usd"])
        } else {
            allowedKeys = commonKeys
        }
        guard Set(row.keys).isSubset(of: allowedKeys),
              row["schema_version"] is String,
              row["transition"] is String,
              row["state"] is String,
              row["run_id"] is String,
              row["reservation_id"] is String,
              row[amountKey] is String,
              row["reason"] is String,
              row["created_at"] is String else {
            return false
        }
        if schemaVersion == Self.schemaVersion, state == "settled" || state == "estimate_exceeded" {
            guard row["settled_exposure_micro_usd"] is String else { return false }
        } else if row["settled_exposure_micro_usd"] != nil {
            return false
        }
        if let value = row["unpriced_override"], !(value is Bool) { return false }
        if let value = row["no_budget"], !(value is Bool) { return false }
        return true
    }

    private func readRowsUnlocked() throws -> [[String: Any]] {
        do {
            try requireHealthyUnlocked()
            try validatePinnedStateFiles()
        } catch {
            throw markLedgerUnavailable()
        }
        var info = stat()
        guard fstat(ledgerFD, &info) == 0,
              info.st_size >= 0,
              info.st_size <= 16 * 1024 * 1024 else {
            throw markLedgerUnavailable()
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        while offset < info.st_size {
            let remaining = Int(min(Int64(buffer.count), Int64(info.st_size - offset)))
            let count = Darwin.pread(ledgerFD, &buffer, remaining, offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw markLedgerUnavailable()
            }
            data.append(buffer, count: count)
            offset += off_t(count)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw markLedgerUnavailable()
        }
        var rows: [[String: Any]] = []
        if text.isEmpty {
            do {
                try validatePinnedStateFiles()
            } catch {
                throw markLedgerUnavailable()
            }
            return rows
        }
        guard text.hasSuffix("\n") else {
            throw markLedgerUnavailable()
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                guard index == lines.count - 1, !rows.isEmpty else {
                    throw markLedgerUnavailable()
                }
                continue
            }
            guard case .object(let object) = try? StrictJSONParser.parse(String(line)) else {
                throw markLedgerUnavailable()
            }
            rows.append(object.mapValues { $0.jsonObject })
        }
        do {
            try validatePinnedStateFiles()
        } catch {
            throw markLedgerUnavailable()
        }
        return rows
    }

    private func appendRowUnlocked(_ row: [String: Any]) throws {
        do {
            try requireHealthyUnlocked()
            try validatePinnedStateFiles()
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            var line = Data()
            line.append(data)
            line.append(0x0a)
            try line.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(ledgerFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw ConsumeBudgetError(code: "local_budget_ledger_unavailable") }
                    offset += written
                }
            }
            guard fsync(ledgerFD) == 0 else {
                throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
            }
            try validatePinnedStateFiles()
        } catch {
            throw markLedgerUnavailable()
        }
    }

    private func requireHealthyUnlocked() throws {
        guard ledgerHealthy else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
    }

    private func markLedgerUnavailable() -> ConsumeBudgetError {
        ledgerHealthy = false
        return ConsumeBudgetError(code: "local_budget_ledger_unavailable")
    }

    private static func randomReservationID() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func openPrivateDirectoryPath(_ directory: URL) throws -> (fd: Int32, identity: LedgerFileIdentity, chain: [LedgerPathIdentity]) {
        let standardized = directory.standardizedFileURL
        let components = standardized.pathComponents
        guard components.first == "/", components.count > 1 else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        var currentFD = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard currentFD >= 0 else { throw ConsumeBudgetError(code: "local_budget_ledger_unavailable") }
        var currentURL = URL(fileURLWithPath: "/")
        var chain: [LedgerPathIdentity] = []
        do {
            try validateAncestorDirectory(fd: currentFD)
            chain.append(LedgerPathIdentity(url: currentURL, identity: try ledgerFileIdentity(fd: currentFD)))
            for component in components.dropFirst() {
                guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                    throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
                }
                var info = stat()
                let statResult = component.withCString {
                    fstatat(currentFD, $0, &info, AT_SYMLINK_NOFOLLOW)
                }
                if statResult != 0 {
                    guard errno == ENOENT else { throw ConsumeBudgetError(code: "local_budget_ledger_unavailable") }
                    let mkdirResult = component.withCString {
                        mkdirat(currentFD, $0, S_IRWXU)
                    }
                    guard mkdirResult == 0 else { throw ConsumeBudgetError(code: "local_budget_ledger_unavailable") }
                    guard fsync(currentFD) == 0 else { throw ConsumeBudgetError(code: "local_budget_ledger_unavailable") }
                } else {
                    guard (info.st_mode & S_IFMT) == S_IFDIR else {
                        throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
                    }
                }
                let nextFD = component.withCString {
                    Darwin.openat(currentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard nextFD >= 0 else { throw ConsumeBudgetError(code: "local_budget_ledger_unavailable") }
                var nextFDTransferred = false
                defer {
                    if !nextFDTransferred {
                        close(nextFD)
                    }
                }
                try validateAncestorDirectory(fd: nextFD)
                currentURL.appendPathComponent(component)
                chain.append(LedgerPathIdentity(url: currentURL, identity: try ledgerFileIdentity(fd: nextFD)))
                close(currentFD)
                currentFD = nextFD
                nextFDTransferred = true
            }
            try validatePrivateDirectory(fd: currentFD)
            return (currentFD, try ledgerFileIdentity(fd: currentFD), chain)
        } catch {
            close(currentFD)
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
    }

    private static func privateRegularFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 &&
            (info.st_mode & S_IFMT) == S_IFREG &&
            info.st_uid == geteuid() &&
            (info.st_mode & (S_IRWXG | S_IRWXO)) == 0 &&
            info.st_nlink == 1
    }

    private static func privateDirectory(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 &&
            (info.st_mode & S_IFMT) == S_IFDIR &&
            info.st_uid == geteuid() &&
            (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
    }

    private static func validateAncestorDirectory(fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_uid == geteuid() || info.st_uid == 0),
              (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              (try? verifyLocalFilesystem(fd: fd)) != nil else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
    }

    private static func validatePrivateDirectory(fd: Int32) throws {
        guard privateDirectory(fd),
              (try? !ConsumeACL.hasExtendedAllowEntry(fd: fd)) == true,
              (try? verifyLocalFilesystem(fd: fd)) != nil else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
    }

    private static func openPrivateStateFileAt(parentFD: Int32, name: String, accessFlags: Int32) throws -> Int32 {
        guard !name.isEmpty, !name.contains("/") else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        let createFD = name.withCString {
            Darwin.openat(parentFD, $0, accessFlags | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        if createFD >= 0 {
            guard fchmod(createFD, S_IRUSR | S_IWUSR) == 0,
                  privateRegularFile(createFD),
                  (try? !ConsumeACL.hasExtendedACLEntry(fd: createFD)) == true else {
                close(createFD)
                throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
            }
            guard fsync(parentFD) == 0 else {
                close(createFD)
                throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
            }
            return createFD
        }
        guard errno == EEXIST else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        let existingFD = name.withCString {
            Darwin.openat(parentFD, $0, accessFlags)
        }
        guard existingFD >= 0 else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        guard privateRegularFile(existingFD),
              (try? !ConsumeACL.hasExtendedACLEntry(fd: existingFD)) == true else {
            close(existingFD)
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        return existingFD
    }

    private static func verifyLocalFilesystem(fd: Int32) throws {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0,
              (fs.f_flags & UInt32(MNT_LOCAL)) != 0 else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
    }

    private struct LedgerFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct LedgerPathIdentity {
        let url: URL
        let identity: LedgerFileIdentity
    }

    private static func ledgerFileIdentity(fd: Int32) throws -> LedgerFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
        return LedgerFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private func validatePinnedLedgerIdentity() throws {
        var opened = stat()
        var named = stat()
        guard fstat(ledgerFD, &opened) == 0,
              lstat(url.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              UInt64(opened.st_dev) == ledgerIdentity.device,
              UInt64(opened.st_ino) == ledgerIdentity.inode,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino,
              Self.privateRegularFile(ledgerFD),
              (try? !ConsumeACL.hasExtendedACLEntry(fd: ledgerFD)) == true,
              (try? Self.verifyLocalFilesystem(fd: ledgerFD)) != nil else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
    }

    private func validatePinnedParentIdentity() throws {
        for entry in parentChain {
            var named = stat()
            guard lstat(entry.url.path, &named) == 0,
                  (named.st_mode & S_IFMT) == S_IFDIR,
                  UInt64(named.st_dev) == entry.identity.device,
                  UInt64(named.st_ino) == entry.identity.inode,
                  (named.st_uid == geteuid() || named.st_uid == 0),
                  (named.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
            }
        }
        var opened = stat()
        var named = stat()
        guard fstat(parentFD, &opened) == 0,
              lstat(parentURL.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              UInt64(opened.st_dev) == parentIdentity.device,
              UInt64(opened.st_ino) == parentIdentity.inode,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino,
              Self.privateDirectory(parentFD),
              (try? !ConsumeACL.hasExtendedAllowEntry(fd: parentFD)) == true,
              (try? Self.verifyLocalFilesystem(fd: parentFD)) != nil else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
    }

    private func validatePinnedLockIdentity() throws {
        var opened = stat()
        var named = stat()
        guard fstat(lockFD, &opened) == 0,
              lstat(lockURL.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              UInt64(opened.st_dev) == lockIdentity.device,
              UInt64(opened.st_ino) == lockIdentity.inode,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino,
              Self.privateRegularFile(lockFD),
              (try? !ConsumeACL.hasExtendedACLEntry(fd: lockFD)) == true,
              (try? Self.verifyLocalFilesystem(fd: lockFD)) != nil else {
            throw ConsumeBudgetError(code: "local_budget_ledger_unavailable")
        }
    }

    private func validatePinnedStateFiles() throws {
        try validatePinnedParentIdentity()
        try validatePinnedLockIdentity()
        try validatePinnedLedgerIdentity()
    }
}

struct ConsumeStartupError: Error {
    let code: String
    var exitCode: ExitCode { ExitCode(2) }
}

enum ConsumeACL {
    static func hasExtendedACLEntry(fd: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return false }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        guard result >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return entry != nil
    }

    static func hasExtendedAllowEntry(fd: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return false }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let rawText = acl_to_text(acl, &length) else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(rawText)) }
        return String(cString: rawText).lowercased().contains("allow")
    }
}

struct ConsumeEndpointConfig {
    static func normalizeBindAddress(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "localhost" { return "127.0.0.1" }
        if value == "::1" { return "::1" }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let first = UInt8(parts[0]),
              first == 127,
              parts.dropFirst().allSatisfy({ UInt8($0) != nil }) else {
            throw ConsumeStartupError(code: "local_bind_rejected")
        }
        return value
    }

    static func normalizeUpstreamOrigin(_ raw: String) throws -> String {
        guard let components = URLComponents(string: raw),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              isGlobalUpstreamHost(host),
              (try? validatedGlobalUpstreamEndpoints(host))?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ConsumeStartupError(code: "local_upstream_url_rejected")
        }
        var normalized = "https://\(host)"
        if let port = components.port {
            normalized += ":\(port)"
        }
        return normalized
    }

    static func requireGloballyResolvingUpstreamHost(_ host: String) throws {
        _ = try validatedGlobalUpstreamEndpoints(host)
    }

    static func validatedGlobalUpstreamEndpoints(_ host: String) throws -> [String] {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard isGlobalUpstreamHost(normalized) else {
            throw ConsumeStartupError(code: "local_upstream_url_rejected")
        }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(normalized, nil, &hints, &result)
        guard status == 0, let result else {
            throw ConsumeStartupError(code: "local_upstream_url_rejected")
        }
        defer { freeaddrinfo(result) }
        var endpoints: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            guard let bytes = globalAddressBytes(from: current.pointee.ai_addr) else {
                throw ConsumeStartupError(code: "local_upstream_url_rejected")
            }
            switch bytes {
            case .ipv4(let address):
                guard isGlobalIPv4(address) else {
                    throw ConsumeStartupError(code: "local_upstream_url_rejected")
                }
            case .ipv6(let address):
                if address[0..<10].allSatisfy({ $0 == 0 }) && address[10] == 0xff && address[11] == 0xff {
                    guard isGlobalIPv4(Array(address[12..<16])) else {
                        throw ConsumeStartupError(code: "local_upstream_url_rejected")
                    }
                } else {
                    guard isGlobalIPv6(address) else {
                        throw ConsumeStartupError(code: "local_upstream_url_rejected")
                    }
                }
            }
            guard let endpoint = numericAddressString(from: current.pointee.ai_addr, length: current.pointee.ai_addrlen) else {
                throw ConsumeStartupError(code: "local_upstream_url_rejected")
            }
            if !endpoints.contains(endpoint) {
                endpoints.append(endpoint)
            }
            cursor = current.pointee.ai_next
        }
        guard !endpoints.isEmpty else {
            throw ConsumeStartupError(code: "local_upstream_url_rejected")
        }
        return endpoints
    }

    static func isValidatedGlobalEndpoint(_ endpoint: String) -> Bool {
        let normalized = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if let bytes = ipv4Bytes(normalized) {
            return isGlobalIPv4(bytes)
        }
        if let bytes = ipv6Bytes(normalized) {
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return isGlobalIPv4(Array(bytes[12..<16]))
            }
            return isGlobalIPv6(bytes)
        }
        return false
    }

    private enum ResolvedAddressBytes {
        case ipv4([UInt8])
        case ipv6([UInt8])
    }

    private static func globalAddressBytes(from sockaddrPointer: UnsafePointer<sockaddr>?) -> ResolvedAddressBytes? {
        guard let sockaddrPointer else { return nil }
        switch Int32(sockaddrPointer.pointee.sa_family) {
        case AF_INET:
            let address = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return .ipv4(withUnsafeBytes(of: address) { Array($0) })
        case AF_INET6:
            let address = sockaddrPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            return .ipv6(withUnsafeBytes(of: address) { Array($0) })
        default:
            return nil
        }
    }

    private static func numericAddressString(from sockaddrPointer: UnsafePointer<sockaddr>?, length: socklen_t) -> String? {
        guard let sockaddrPointer else { return nil }
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            sockaddrPointer,
            length,
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard status == 0 else { return nil }
        return String(cString: hostBuffer)
    }

    private static func isGlobalUpstreamHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !normalized.isEmpty,
              normalized != "localhost",
              !normalized.hasSuffix(".localhost"),
              !normalized.hasSuffix(".local"),
              normalized != "*" else {
            return false
        }
        if let bytes = ipv4Bytes(normalized) {
            return isGlobalIPv4(bytes)
        }
        if let bytes = ipv6Bytes(normalized) {
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return isGlobalIPv4(Array(bytes[12..<16]))
            }
            return isGlobalIPv6(bytes)
        }
        return true
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address.s_addr) { Array($0) }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isGlobalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        switch first {
        case 0, 10, 127:
            return false
        case 100 where (64...127).contains(second):
            return false
        case 169 where second == 254:
            return false
        case 172 where (16...31).contains(second):
            return false
        case 192 where second == 0 || second == 2 || second == 168:
            return false
        case 192 where second == 31 && bytes[2] == 196:
            return false
        case 192 where second == 52 && bytes[2] == 193:
            return false
        case 192 where second == 88 && bytes[2] == 99:
            return false
        case 192 where second == 175 && bytes[2] == 48:
            return false
        case 198 where second == 18 || second == 19 || second == 51:
            return false
        case 203 where second == 0 && bytes[2] == 113:
            return false
        case 224...255:
            return false
        default:
            return true
        }
    }

    private static func isGlobalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        guard (bytes[0] & 0xe0) == 0x20 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }
        if bytes[0] == 0xfc || bytes[0] == 0xfd { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b { return false }
        if bytes[0] == 0x01 && bytes[1] == 0x00 && bytes[2..<8].allSatisfy({ $0 == 0 }) { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && (bytes[2] & 0xfe) == 0x00 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && (bytes[3] & 0xf0) == 0x20 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0] == 0x3f && (bytes[1] & 0xf0) == 0xf0 { return false }
        return true
    }

    static func localBaseURL(bindAddress: String, port: Int) -> String {
        if bindAddress.contains(":") {
            return "http://[\(bindAddress)]:\(port)"
        }
        return "http://\(bindAddress):\(port)"
    }
}

struct ConsumeLocalToken: Equatable {
    let value: String
    let verifier: ConsumeLocalTokenVerifier

    static func generate() throws -> ConsumeLocalToken {
        let tokenBytes = try randomBytes(count: 32)
        let verifierKey = try randomBytes(count: 32)
        let value = base64URL(tokenBytes)
        return ConsumeLocalToken(
            value: value,
            verifier: ConsumeLocalTokenVerifier(expectedToken: value, key: verifierKey)
        )
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ConsumeStartupError(code: "local_random_unavailable")
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct ConsumeLocalTokenVerifier: Equatable, Sendable {
    private let expectedDigest: Data
    private let key: Data

    init(expectedToken: String, key: Data) {
        self.key = key
        self.expectedDigest = Self.digest(token: expectedToken, key: key)
    }

    func verify(headers: HTTPHeaders) -> Bool {
        let candidates = acceptedTokenCandidates(headers: headers)
        guard candidates.count == 1 else { return false }
        let presentedDigest = Self.digest(token: candidates[0], key: key)
        return Self.constantTimeEqual(expectedDigest, presentedDigest)
    }

    private func acceptedTokenCandidates(headers: HTTPHeaders) -> [String] {
        var candidates: [String] = []
        for value in headers[canonicalForm: "authorization"] {
            guard value.hasPrefix("Bearer "), value.dropFirst("Bearer ".count).contains(" ") == false else {
                return ["", ""]
            }
            candidates.append(String(value.dropFirst("Bearer ".count)))
        }
        candidates.append(contentsOf: headers[canonicalForm: "api-key"].map(String.init))
        candidates.append(contentsOf: headers[canonicalForm: "x-api-key"].map(String.init))
        return candidates.filter { !$0.isEmpty }
    }

    private static func digest(token: String, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: symmetricKey)
        return Data(mac)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let count = max(lhs.count, rhs.count)
        var difference = UInt8(lhs.count ^ rhs.count)
        for index in 0..<count {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            difference |= l ^ r
        }
        return difference == 0
    }
}

enum ConsumeCredentialSourceClass: String {
    case explicitFile = "explicit_file"
    case defaultConfigFile = "default_config_file"
    case environment
    case missing
}

enum ConsumeCredentialState: String {
    case missing
    case loaded
}

struct ConsumeCredential: Equatable {
    var bytes: Data
    let sourceClass: ConsumeCredentialSourceClass
    let status: ConsumeCredentialStatus

    mutating func zeroize() {
        bytes.resetBytes(in: 0..<bytes.count)
    }
}

struct ConsumeCredentialStatus: Equatable, Sendable {
    let state: ConsumeCredentialState
    let fileIdentity: ConsumeFileIdentity?

    static let missing = ConsumeCredentialStatus(state: .missing, fileIdentity: nil)
    static let environmentLoaded = ConsumeCredentialStatus(state: .loaded, fileIdentity: nil)

    func currentState() -> ConsumeCredentialState {
        guard let fileIdentity else { return state }
        return fileIdentity.isStillSafe() ? .loaded : .missing
    }
}

struct ConsumeFileIdentity: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let mode: UInt16
    let uid: UInt32

    init(path: String, info: stat) {
        self.path = path
        self.device = UInt64(info.st_dev)
        self.inode = UInt64(info.st_ino)
        self.size = Int64(info.st_size)
        self.modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        self.modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        self.mode = UInt16(info.st_mode & UInt16.max)
        self.uid = UInt32(info.st_uid)
    }

    func isStillSafe() -> Bool {
        do {
            return try ConsumeCredentialLoader.currentFileIdentity(path: path) == self
        } catch {
            return false
        }
    }
}

enum ConsumeCredentialError: Error {
    case unsafeFile(sourceClass: ConsumeCredentialSourceClass, reason: String)
    case readFailed(sourceClass: ConsumeCredentialSourceClass)
    case rawFlagRejected

    var redactedCode: String {
        switch self {
        case .unsafeFile:
            return "local_credential_file_rejected"
        case .readFailed:
            return "local_credential_missing"
        case .rawFlagRejected:
            return "local_credential_flag_rejected"
        }
    }

    var exitCode: ExitCode { ExitCode(3) }
}

struct ConsumeCredentialLoader {
    static func load(
        explicitCredentialFile: String?,
        environment: [String: String],
        homeDirectory: URL
    ) throws -> ConsumeCredential {
        if let explicitCredentialFile {
            guard !looksLikeRawCredentialFlag(explicitCredentialFile) else {
                throw ConsumeCredentialError.rawFlagRejected
            }
            return try loadFile(path: explicitCredentialFile, sourceClass: .explicitFile)
        }
        if let envFile = nonEmpty(environment["MACPROVIDER_HTTP2_API_KEY_FILE"]) {
            return try loadFile(path: envFile, sourceClass: .explicitFile)
        }
        let defaultFile = homeDirectory
            .appendingPathComponent(".config/macprovider/buyer-api-key")
        if FileManager.default.fileExists(atPath: defaultFile.path) {
            return try loadFile(path: defaultFile.path, sourceClass: .defaultConfigFile)
        }
        for key in ["MACPROVIDER_HTTP2_API_KEY", "MP_API_KEY", "BUYER_TOKEN"] {
            if let value = nonEmpty(environment[key]) {
                let data = Data(value.utf8)
                try validateCredentialBytes(data, sourceClass: .environment)
                return ConsumeCredential(bytes: data, sourceClass: .environment, status: .environmentLoaded)
            }
        }
        return ConsumeCredential(bytes: Data(), sourceClass: .missing, status: .missing)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func looksLikeRawCredentialFlag(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return false }
        if trimmed.hasPrefix("sk-") || trimmed.hasPrefix("mp_") || trimmed.hasPrefix("malibu_") {
            return true
        }
        return trimmed.count >= 32 && trimmed.range(of: #"^[A-Za-z0-9_\-=.]+$"#, options: .regularExpression) != nil
    }

    private static func currentFileIdentity(path: String, sourceClass: ConsumeCredentialSourceClass) throws -> ConsumeFileIdentity {
        let opened = try openCredentialFile(path: path, sourceClass: sourceClass)
        close(opened.fd)
        return opened.identity
    }

    static func currentFileIdentity(path: String) throws -> ConsumeFileIdentity {
        try currentFileIdentity(path: path, sourceClass: .explicitFile)
    }

    private static func openCredentialFile(
        path: String,
        sourceClass: ConsumeCredentialSourceClass
    ) throws -> (fd: Int32, identity: ConsumeFileIdentity) {
        try validatePathHasNoSymlinkAndSafeParents(URL(fileURLWithPath: path), sourceClass: sourceClass)
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ConsumeCredentialError.readFailed(sourceClass: sourceClass)
        }

        var opened = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == geteuid(),
              (opened.st_mode & (S_IRWXG | S_IRWXO)) == 0,
              (opened.st_mode & S_IRUSR) != 0 else {
            close(fd)
            throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "permission_class")
        }
        do {
            try rejectExtendedACL(fd: fd, sourceClass: sourceClass, reason: "file_acl")
        } catch {
            close(fd)
            throw error
        }
        var named = stat()
        guard lstat(path, &named) == 0,
              named.st_dev == opened.st_dev,
              named.st_ino == opened.st_ino else {
            close(fd)
            throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "file_identity_changed")
        }
        return (fd, ConsumeFileIdentity(path: path, info: opened))
    }

    private static func loadFile(path: String, sourceClass: ConsumeCredentialSourceClass) throws -> ConsumeCredential {
        let opened = try openCredentialFile(path: path, sourceClass: sourceClass)
        let fd = opened.fd
        defer { close(fd) }

        var data = Data()
        defer { data.resetBytes(in: 0..<data.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        defer {
            for index in buffer.indices {
                buffer[index] = 0
            }
        }
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw ConsumeCredentialError.readFailed(sourceClass: sourceClass)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= 16 * 1024 else {
                throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "too_large")
            }
        }
        trimASCIIWhitespace(&data)
        guard !data.isEmpty else {
            throw ConsumeCredentialError.readFailed(sourceClass: sourceClass)
        }
        try validateCredentialBytes(data, sourceClass: sourceClass)
        var credentialBytes = Data()
        credentialBytes.append(data)
        return ConsumeCredential(
            bytes: credentialBytes,
            sourceClass: sourceClass,
            status: ConsumeCredentialStatus(state: .loaded, fileIdentity: opened.identity)
        )
    }

    private static func trimASCIIWhitespace(_ data: inout Data) {
        while let first = data.first, first == 0x20 || first == 0x09 || first == 0x0a || first == 0x0d {
            data.removeFirst()
        }
        while let last = data.last, last == 0x20 || last == 0x09 || last == 0x0a || last == 0x0d {
            data.removeLast()
        }
    }

    private static func validateCredentialBytes(_ data: Data, sourceClass: ConsumeCredentialSourceClass) throws {
        guard data.allSatisfy({ byte in byte >= 0x21 && byte <= 0x7e }) else {
            switch sourceClass {
            case .explicitFile, .defaultConfigFile:
                throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "credential_control_character")
            case .environment:
                throw ConsumeCredentialError.readFailed(sourceClass: sourceClass)
            case .missing:
                throw ConsumeCredentialError.readFailed(sourceClass: sourceClass)
            }
        }
    }

    private static func validatePathHasNoSymlinkAndSafeParents(_ url: URL, sourceClass: ConsumeCredentialSourceClass) throws {
        let standardized = url.standardizedFileURL
        let components = standardized.pathComponents
        var current = components.first == "/" ? URL(fileURLWithPath: "/") : URL(fileURLWithPath: ".")
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                if current.path == standardized.path { return }
                throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "parent_missing")
            }
            guard (info.st_mode & S_IFMT) != S_IFLNK else {
                throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "symlink_ambiguous")
            }
	            if current.path != standardized.path {
	                guard (info.st_mode & S_IFMT) == S_IFDIR,
	                      (info.st_uid == geteuid() || info.st_uid == 0),
	                      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
	                    throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "unsafe_parent")
	                }
                let fd = open(current.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else {
                    throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "unsafe_parent")
                }
                defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0,
                      opened.st_dev == info.st_dev,
                      opened.st_ino == info.st_ino,
                      (opened.st_mode & S_IFMT) == S_IFDIR,
                      (opened.st_uid == geteuid() || opened.st_uid == 0),
                      (opened.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                      (try? !ConsumeACL.hasExtendedAllowEntry(fd: fd)) == true else {
                    throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "unsafe_parent")
                }
	            }
	        }
	    }

	    private static func rejectExtendedACL(fd: Int32, sourceClass: ConsumeCredentialSourceClass, reason: String) throws {
	        guard (try? !ConsumeACL.hasExtendedACLEntry(fd: fd)) == true else {
	            throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: reason)
	        }
	    }
}

struct ConsumeEndpointDescriptor: Codable, Equatable {
    static let schemaVersion = "local_consumer_endpoint.descriptor.v1"

    let schemaVersion: String
    let boundURL: String
    let processID: Int
    let launchID: String
    let startedAt: String
    let ledgerPathClass: String?
    let localToken: String

    init(
        boundURL: String,
        processID: Int,
        launchID: String,
        startedAt: String,
        ledgerPathClass: String?,
        localToken: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.boundURL = boundURL
        self.processID = processID
        self.launchID = launchID
        self.startedAt = startedAt
        self.ledgerPathClass = ledgerPathClass
        self.localToken = localToken
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case boundURL = "bound_url"
        case processID = "process_id"
        case launchID = "process_launch_id"
        case startedAt = "started_at"
        case ledgerPathClass = "ledger_path_class"
        case localToken = "local_token"
    }
}

final class ConsumeActiveEndpointLock: @unchecked Sendable {
    let fd: Int32
    let rootFD: Int32
    let url: URL

    init(fd: Int32, rootFD: Int32, url: URL) {
        self.fd = fd
        self.rootFD = rootFD
        self.url = url
    }

    deinit {
        _ = flock(fd, LOCK_UN)
        close(fd)
        close(rootFD)
    }
}

struct ConsumeActiveEndpointStore {
    let root: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.root = homeDirectory
            .appendingPathComponent("Library/Application Support/macprovider/consume", isDirectory: true)
    }

    var descriptorURL: URL { root.appendingPathComponent("active-endpoint.json") }
    var lockURL: URL { root.appendingPathComponent("active-endpoint.lock") }

    func acquireLock() throws -> ConsumeActiveEndpointLock {
        try ensurePrivateRoot()
        let rootFD = try openValidatedRootFD()
        let fd = openat(rootFD, "active-endpoint.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            close(rootFD)
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        var result: Int32
        repeat {
            result = flock(fd, LOCK_EX | LOCK_NB)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            close(fd)
            close(rootFD)
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0,
              activeEndpointFileIsPrivate(fd: fd),
              rejectExtendedACL(fd: fd) else {
            close(fd)
            close(rootFD)
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        return ConsumeActiveEndpointLock(fd: fd, rootFD: rootFD, url: lockURL)
    }

    func writeDescriptor(_ descriptor: ConsumeEndpointDescriptor, lock: ConsumeActiveEndpointLock) throws {
        guard lock.url == lockURL else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(descriptor)
        data.append(0x0a)
        let temporaryName = ".active-endpoint.json.tmp-\(UUID().uuidString.lowercased())"
        let fd = openat(lock.rootFD, temporaryName, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        var shouldRemove = true
        defer {
            close(fd)
            if shouldRemove { unlinkat(lock.rootFD, temporaryName, 0) }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw ConsumeStartupError(code: "local_active_endpoint_exists") }
                offset += written
            }
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0,
              activeEndpointFileIsPrivate(fd: fd),
              rejectExtendedACL(fd: fd),
              fsync(fd) == 0 else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        guard renameat(lock.rootFD, temporaryName, lock.rootFD, "active-endpoint.json") == 0 else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        shouldRemove = false
        try fsyncRoot(fd: lock.rootFD)
    }

    func removeDescriptor(lock: ConsumeActiveEndpointLock) throws {
        guard lock.url == lockURL else { return }
        _ = unlinkat(lock.rootFD, "active-endpoint.json", 0)
    }

    func readLiveDescriptor() throws -> ConsumeEndpointDescriptor? {
        guard let descriptor = try readDescriptor() else { return nil }
        guard activeEndpointLockIsHeld() else {
            return nil
        }
        guard processAppearsLive(pid: descriptor.processID) else {
            return nil
        }
        return descriptor
    }

    private func readDescriptor() throws -> ConsumeEndpointDescriptor? {
        try ensurePrivateRoot()
        let rootFD = try openValidatedRootFD()
        defer { close(rootFD) }
        let fd = openat(rootFD, "active-endpoint.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ConsumeStartupError(code: "local_endpoint_not_running")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              activeEndpointFileIsPrivate(fd: fd),
              rejectExtendedACL(fd: fd) else {
            throw ConsumeStartupError(code: "local_endpoint_not_running")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ConsumeStartupError(code: "local_endpoint_not_running") }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= 16 * 1024 else { throw ConsumeStartupError(code: "local_endpoint_not_running") }
        }
        return try JSONDecoder().decode(ConsumeEndpointDescriptor.self, from: data)
    }

    private func ensurePrivateRoot() throws {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validatePrivateRootAncestry()
        let fd = try openValidatedRootFD()
        close(fd)
    }

    private func validatePrivateRootAncestry() throws {
        let standardized = root.standardizedFileURL
        let components = standardized.pathComponents
        var current = components.first == "/" ? URL(fileURLWithPath: "/") : URL(fileURLWithPath: ".")
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  (info.st_mode & S_IFMT) != S_IFLNK,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  (info.st_uid == geteuid() || info.st_uid == 0),
                  (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                throw ConsumeStartupError(code: "local_active_endpoint_exists")
            }
            let fd = open(current.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else {
                throw ConsumeStartupError(code: "local_active_endpoint_exists")
            }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0,
                  opened.st_dev == info.st_dev,
                  opened.st_ino == info.st_ino,
                  (opened.st_mode & S_IFMT) == S_IFDIR,
                  (opened.st_uid == geteuid() || opened.st_uid == 0),
                  (opened.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                  (try? !ConsumeACL.hasExtendedAllowEntry(fd: fd)) == true else {
                throw ConsumeStartupError(code: "local_active_endpoint_exists")
            }
        }
    }

    private func fsyncRoot(fd: Int32) throws {
        guard fsync(fd) == 0 else { throw ConsumeStartupError(code: "local_active_endpoint_exists") }
    }

    private func activeEndpointLockIsHeld() -> Bool {
        guard let rootFD = try? openValidatedRootFD() else { return false }
        defer { close(rootFD) }
        let fd = openat(rootFD, "active-endpoint.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard activeEndpointFileIsPrivate(fd: fd),
              rejectExtendedACL(fd: fd) else {
            return false
        }
        var result: Int32
        repeat {
            result = flock(fd, LOCK_SH | LOCK_NB)
        } while result != 0 && errno == EINTR
        if result == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private func openValidatedRootFD() throws -> Int32 {
        var named = stat()
        guard lstat(root.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              named.st_uid == geteuid(),
              (named.st_mode & 0o777) == S_IRWXU else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        let fd = open(root.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ConsumeStartupError(code: "local_active_endpoint_exists") }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              opened.st_uid == geteuid(),
              (opened.st_mode & 0o777) == S_IRWXU,
              rejectExtendedACL(fd: fd) else {
            close(fd)
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        return fd
    }

    private func activeEndpointFileIsPrivate(fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 &&
            (info.st_mode & S_IFMT) == S_IFREG &&
            info.st_uid == geteuid() &&
            (info.st_mode & (S_IRWXG | S_IRWXO)) == 0 &&
            info.st_nlink == 1
    }

    private func rejectExtendedACL(fd: Int32) -> Bool {
        (try? !ConsumeACL.hasExtendedACLEntry(fd: fd)) == true
    }

    private func processAppearsLive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}

struct ConsumeEndpointRuntime: Sendable {
    let launchID: String
    let boundURL: String
    let upstreamOrigin: String
    let credentialSourceClass: String
    let modelAllowlist: [String]
    let tokenVerifier: ConsumeLocalTokenVerifier
    let credentialCustody: ConsumeCredentialCustody
    let budget: ConsumeBudgetConfig
    let trustedPricing: ConsumeTrustedPricingStore
    let upstreamClient: ConsumeUpstreamClient
    let pricingAdmissionGate: ConsumePricingAdmissionGate
    let now: @Sendable () -> Date
    let requestCounter: ConsumeEndpointRequestCounter

    init(
        launchID: String,
        boundURL: String,
        upstreamOrigin: String,
        credentialSourceClass: String,
        credentialStatus: ConsumeCredentialStatus,
        modelAllowlist: [String],
        tokenVerifier: ConsumeLocalTokenVerifier,
        credentialCustody: ConsumeCredentialCustody? = nil,
        budget: ConsumeBudgetConfig = .unconfigured,
        trustedPricing: ConsumeTrustedPricingState = .notLoaded,
        upstreamClient: ConsumeUpstreamClient = ConsumePinnedUpstreamClient(),
        pricingAdmissionGate: ConsumePricingAdmissionGate = ConsumePricingAdmissionGate(),
        now: @escaping @Sendable () -> Date = { Date() },
        requestCounter: ConsumeEndpointRequestCounter = ConsumeEndpointRequestCounter()
    ) {
        self.launchID = launchID
        self.boundURL = boundURL
        self.upstreamOrigin = upstreamOrigin
        self.credentialSourceClass = credentialSourceClass
        self.modelAllowlist = modelAllowlist
        self.tokenVerifier = tokenVerifier
        self.credentialCustody = credentialCustody ?? ConsumeCredentialCustody(status: credentialStatus)
        self.budget = budget
        self.trustedPricing = ConsumeTrustedPricingStore(trustedPricing)
        self.upstreamClient = upstreamClient
        self.pricingAdmissionGate = pricingAdmissionGate
        self.now = now
        self.requestCounter = requestCounter
    }

    func beginIncompleteConnection() -> Bool {
        requestCounter.beginIncompleteConnection()
    }

    func completePreAuthConnection() {
        requestCounter.completePreAuthConnection()
    }

    func endIncompleteConnection() {
        requestCounter.endIncompleteConnection()
    }

    func beginRequest() -> Bool {
        requestCounter.begin()
    }

    func endRequest() {
        requestCounter.end()
    }

    func reserveBodyBytes(_ count: Int) -> Bool {
        requestCounter.reserveBodyBytes(count)
    }

    func releaseBodyBytes(_ count: Int) {
        requestCounter.releaseBodyBytes(count)
    }

    func reserveUpstreamExchange(responseSpoolBytes: Int) -> ConsumeEndpointResourceReservation? {
        requestCounter.reserveUpstreamExchange(responseSpoolBytes: responseSpoolBytes)
    }

    func releaseUpstreamExchange(_ reservation: ConsumeEndpointResourceReservation) {
        requestCounter.releaseUpstreamExchange(reservation)
    }

    func statusPayload() -> [String: Any] {
        let resourceSnapshot = requestCounter.resourceSnapshot()
        var payload: [String: Any] = [
            "schema_version": "local_consumer_endpoint.status.v1",
            "process_launch_id": launchID,
            "bound_url": boundURL,
            "upstream_gateway_origin": upstreamOrigin,
            "credential_source_class": credentialSourceClass,
            "credential_state": credentialCustody.currentState().rawValue,
            "model_allowlist": modelAllowlist,
            "local_auth_state": "required",
            "active_request_count": requestCounter.current(),
            "buffered_request_body_bytes": resourceSnapshot.bufferedBodyBytes,
            "response_spool_bytes": resourceSnapshot.responseSpoolBytes,
            "upstream_worker_task_count": resourceSnapshot.upstreamWorkerTasks,
            "upstream_socket_descriptor_count": resourceSnapshot.upstreamSocketDescriptors,
            "open_streaming_response_count": resourceSnapshot.openStreamingResponses,
            "last_successful_upstream_contact_at": NSNull(),
            "error_ring": [],
        ]
        for (key, value) in budget.statusFields(
            trustedPricing: trustedPricing.revalidated(now: now()),
            pricingEstimateExceeded: pricingAdmissionGate.isEstimateExceeded()
        ) {
            payload[key] = value
        }
        return payload
    }
}

final class ConsumeTrustedPricingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ConsumeTrustedPricingState

    init(_ state: ConsumeTrustedPricingState) {
        self.state = state
    }

    func revalidated(now: Date) -> ConsumeTrustedPricingState {
        lock.lock()
        defer { lock.unlock() }
        let revalidated = state.revalidated(now: now)
        state = revalidated
        return revalidated
    }
}

final class ConsumeCredentialCustody: @unchecked Sendable {
    private let lock = NSLock()
    private let status: ConsumeCredentialStatus
    private var credentialBytes: Data

    init(credential: ConsumeCredential) {
        self.status = credential.status
        self.credentialBytes = credential.bytes
    }

    init(status: ConsumeCredentialStatus) {
        self.status = status
        self.credentialBytes = Data()
    }

    deinit {
        credentialBytes.resetBytes(in: 0..<credentialBytes.count)
    }

    func currentState() -> ConsumeCredentialState {
        lock.lock()
        defer { lock.unlock() }
        return status.currentState()
    }

    func upstreamBearerToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard status.currentState() == .loaded,
              let token = String(data: credentialBytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}

enum ConsumeLocalLimits {
    static let requestLineBytes = 8 * 1024
    static let requestTargetBytes = 2 * 1024
    static let headerCount = 96
    static let headerBytes = 64 * 1024
    static let bodyBytes = 1 * 1024 * 1024
    static let nonStreamingResponseSpoolBytes = bodyBytes * 2
    static let headerReadTimeout: TimeAmount = .seconds(5)
    static let requestReadTimeout: TimeAmount = .seconds(15)
    static let bodyIdleTimeout: TimeAmount = .seconds(5)

    static var httpDecoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration {
        var configuration = NIOHTTPDecoderLimitConfiguration()
        configuration.maxHeaderFieldSize = headerBytes
        configuration.maxHeaderListSize = headerBytes
        configuration.maxHeaderFieldCount = headerCount
        return configuration
    }
}

enum ConsumeLocalEndpoint: Sendable {
    case status
    case models
    case chatCompletions
}

struct ConsumeValidatedRequest {
    let endpoint: ConsumeLocalEndpoint
}

struct ConsumeEndpointResourceReservation: Sendable {
    let responseSpoolBytes: Int
    let upstreamWorkerTasks: Int
    let upstreamSocketDescriptors: Int
}

struct ConsumeEndpointResourceSnapshot: Sendable {
    let bufferedBodyBytes: Int
    let responseSpoolBytes: Int
    let upstreamWorkerTasks: Int
    let upstreamSocketDescriptors: Int
    let openStreamingResponses: Int
}

final class ConsumeEndpointRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let maxIncompleteConnections: Int
    private let maxActiveRequests: Int
    private let maxBufferedBodyBytes: Int
    private let maxResponseSpoolBytes: Int
    private let maxOpenStreamingResponses: Int
    private let maxUpstreamWorkerTasks: Int
    private let maxUpstreamSocketDescriptors: Int
    private var incompleteConnections = 0
    private var value = 0
    private var bufferedBodyBytes = 0
    private var responseSpoolBytes = 0
    private var openStreamingResponses = 0
    private var upstreamWorkerTasks = 0
    private var upstreamSocketDescriptors = 0

    init(
        maxIncompleteConnections: Int = 16,
        maxActiveRequests: Int = 32,
        maxBufferedBodyBytes: Int = 8 * 1024 * 1024,
        maxResponseSpoolBytes: Int = 8 * 1024 * 1024,
        maxOpenStreamingResponses: Int = 16,
        maxUpstreamWorkerTasks: Int = 32,
        maxUpstreamSocketDescriptors: Int = 32
    ) {
        self.maxIncompleteConnections = maxIncompleteConnections
        self.maxActiveRequests = maxActiveRequests
        self.maxBufferedBodyBytes = maxBufferedBodyBytes
        self.maxResponseSpoolBytes = maxResponseSpoolBytes
        self.maxOpenStreamingResponses = maxOpenStreamingResponses
        self.maxUpstreamWorkerTasks = maxUpstreamWorkerTasks
        self.maxUpstreamSocketDescriptors = maxUpstreamSocketDescriptors
    }

    func beginIncompleteConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard incompleteConnections < maxIncompleteConnections else { return false }
        incompleteConnections += 1
        return true
    }

    func completePreAuthConnection() {
        lock.lock()
        if incompleteConnections > 0 {
            incompleteConnections -= 1
        }
        lock.unlock()
    }

    func endIncompleteConnection() {
        completePreAuthConnection()
    }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value < maxActiveRequests else { return false }
        value += 1
        return true
    }

    func end() {
        lock.lock()
        value = max(0, value - 1)
        lock.unlock()
    }

    func reserveBodyBytes(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count >= 0,
              bufferedBodyBytes <= maxBufferedBodyBytes - count else {
            return false
        }
        bufferedBodyBytes += count
        return true
    }

    func releaseBodyBytes(_ count: Int) {
        lock.lock()
        bufferedBodyBytes = max(0, bufferedBodyBytes - max(0, count))
        lock.unlock()
    }

    func reserveUpstreamExchange(responseSpoolBytes count: Int) -> ConsumeEndpointResourceReservation? {
        lock.lock()
        defer { lock.unlock() }
        guard count >= 0,
              responseSpoolBytes <= maxResponseSpoolBytes - count,
              upstreamWorkerTasks < maxUpstreamWorkerTasks,
              upstreamSocketDescriptors < maxUpstreamSocketDescriptors else {
            return nil
        }
        responseSpoolBytes += count
        upstreamWorkerTasks += 1
        upstreamSocketDescriptors += 1
        return ConsumeEndpointResourceReservation(
            responseSpoolBytes: count,
            upstreamWorkerTasks: 1,
            upstreamSocketDescriptors: 1
        )
    }

    func releaseUpstreamExchange(_ reservation: ConsumeEndpointResourceReservation) {
        lock.lock()
        responseSpoolBytes = max(0, responseSpoolBytes - max(0, reservation.responseSpoolBytes))
        upstreamWorkerTasks = max(0, upstreamWorkerTasks - max(0, reservation.upstreamWorkerTasks))
        upstreamSocketDescriptors = max(0, upstreamSocketDescriptors - max(0, reservation.upstreamSocketDescriptors))
        lock.unlock()
    }

    func beginStreamingResponse() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard openStreamingResponses < maxOpenStreamingResponses else { return false }
        openStreamingResponses += 1
        return true
    }

    func endStreamingResponse() {
        lock.lock()
        openStreamingResponses = max(0, openStreamingResponses - 1)
        lock.unlock()
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func resourceSnapshot() -> ConsumeEndpointResourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ConsumeEndpointResourceSnapshot(
            bufferedBodyBytes: bufferedBodyBytes,
            responseSpoolBytes: responseSpoolBytes,
            upstreamWorkerTasks: upstreamWorkerTasks,
            upstreamSocketDescriptors: upstreamSocketDescriptors,
            openStreamingResponses: openStreamingResponses
        )
    }
}

struct ConsumeEndpointStatus {
    private static let testStderrSink = ConsumeEndpointStatusSink()

    static func writeStartup(
        boundURL: String,
        localToken: String,
        upstreamOrigin: String,
        modelAllowlist: [String],
        budget: ConsumeBudgetConfig = .unconfigured,
        credentialSourceClass: String,
        credentialState: String
    ) {
        let sample = modelAllowlist.prefix(5).joined(separator: ",")
        let allowlistSummary = modelAllowlist.isEmpty
            ? "count=0 warning=empty_model_allowlist"
            : "count=\(modelAllowlist.count) sample=\(sample)"
        var fields = [
            "local_consumer_endpoint=started",
            "base_url=\(boundURL)",
            "local_token=\(localToken)",
            "upstream_gateway_origin=\(upstreamOrigin)",
            "model_allowlist=\(allowlistSummary)",
            "budget_mode=\(budget.mode.startupName)",
            "unpriced_override=\(budget.allowUnpriced)",
        ]
        if !budget.localWarningTokens.isEmpty {
            fields.append("warnings=\(budget.localWarningTokens.joined(separator: ","))")
        }
        fields.append("credential_source_class=\(credentialSourceClass)")
        fields.append("credential_state=\(credentialState)")
        writeStderr(fields.joined(separator: " ") + "\n")
    }

    static func writeStderr(_ text: String) {
        if testStderrSink.write(text) {
            return
        }
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func replaceStderrSinkForTesting(_ sink: ((String) -> Void)?) -> (() -> Void) {
        let previous = testStderrSink.replace(sink)
        return {
            _ = testStderrSink.replace(previous)
        }
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

final class ConsumeEndpointStatusSink: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((String) -> Void)?

    func replace(_ next: ((String) -> Void)?) -> ((String) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let previous = sink
        sink = next
        return previous
    }

    func write(_ text: String) -> Bool {
        lock.lock()
        let current = sink
        lock.unlock()
        guard let current else { return false }
        current(text)
        return true
    }
}

struct ConsumeLocalServer {
    let bindAddress: String
    let port: Int
    let runtime: ConsumeEndpointRuntime
    let onListening: @Sendable () throws -> Void

    func run(stopAfterListening: Bool = false) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 0)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ConsumeStartLineLimitHandler()).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(
                        withDecoderLimitConfiguration: ConsumeLocalLimits.httpDecoderLimitConfiguration
                    )
                }.flatMap {
                    channel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime))
                }
            }
        let channel: Channel
        do {
            channel = try bootstrap.bind(host: bindAddress, port: port).wait()
        } catch {
            throw ConsumeStartupError(code: "local_bind_rejected")
        }
        do {
            try onListening()
        } catch {
            try? channel.close().wait()
            throw error
        }
        if stopAfterListening {
            try channel.close().wait()
            return
        }
        try channel.closeFuture.wait()
    }
}

final class ConsumeStartLineLimitHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var startLineComplete = false
    private var bufferedBytes: [UInt8] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !startLineComplete else {
            context.fireChannelRead(data)
            return
        }
        let bytes = Array(unwrapInboundIn(data).readableBytesView)
        for (index, byte) in bytes.enumerated() {
            bufferedBytes.append(byte)
            guard bufferedBytes.count <= ConsumeLocalLimits.requestLineBytes || byte == 0x0A else {
                context.close(promise: nil)
                return
            }
            if byte == 0x0A {
                var line = bufferedBytes
                line.removeLast()
                if line.last == 0x0D {
                    line.removeLast()
                }
                guard Self.isAllowedStartLine(line) else {
                    context.close(promise: nil)
                    return
                }
                startLineComplete = true
                if index + 1 < bytes.count {
                    bufferedBytes.append(contentsOf: bytes[(index + 1)...])
                }
                var forwarded = context.channel.allocator.buffer(capacity: bufferedBytes.count)
                forwarded.writeBytes(bufferedBytes)
                bufferedBytes.removeAll(keepingCapacity: false)
                context.fireChannelRead(wrapInboundOut(forwarded))
                return
            }
        }
    }

    private static func isAllowedStartLine(_ line: [UInt8]) -> Bool {
        guard line.count <= ConsumeLocalLimits.requestLineBytes,
              let methodEnd = line.firstIndex(of: 0x20) else {
            return false
        }
        let method = line[..<methodEnd]
        guard !method.isEmpty,
              method.allSatisfy(isMethodTokenByte) else {
            return false
        }
        let targetStart = methodEnd + 1
        guard targetStart < line.endIndex,
              let targetEnd = line[targetStart...].firstIndex(of: 0x20),
              targetEnd > targetStart,
              targetEnd - targetStart <= ConsumeLocalLimits.requestTargetBytes else {
            return false
        }
        let versionStart = targetEnd + 1
        guard versionStart < line.endIndex,
              !line[versionStart...].contains(0x20) else {
            return false
        }
        return Array(line[versionStart...]) == Array("HTTP/1.0".utf8)
            || Array(line[versionStart...]) == Array("HTTP/1.1".utf8)
    }

    private static func isMethodTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A:
            return true
        default:
            return false
        }
    }
}

final class ConsumeLocalHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let runtime: ConsumeEndpointRuntime
    private var requestHead: HTTPRequestHead?
    private var validatedRequest: ConsumeValidatedRequest?
    private var requestBody = Data()
    private var connectionIsIncompletePreAuth = false
    private var requestIsActive = false
    private var reservedBodyBytes = 0
    private var upstreamResourceReservation: ConsumeEndpointResourceReservation?
    private var upstreamForwardIsPending = false
    private var upstreamForwardWasDispatched = false
    private var channelInactiveWhileUpstreamPending = false
    private var responseStarted = false
    private var headerDeadlineTask: Scheduled<Void>?
    private var requestDeadlineTask: Scheduled<Void>?
    private var bodyIdleDeadlineTask: Scheduled<Void>?
    private var channelForDeadline: Channel?

    init(runtime: ConsumeEndpointRuntime) {
        self.runtime = runtime
    }

    func channelActive(context: ChannelHandlerContext) {
        guard runtime.beginIncompleteConnection() else {
            context.close(promise: nil)
            return
        }
        connectionIsIncompletePreAuth = true
        channelForDeadline = context.channel
        headerDeadlineTask = context.eventLoop.scheduleTask(in: ConsumeLocalLimits.headerReadTimeout) { [weak self] in
            self?.closeIfHeaderMissing()
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            headerDeadlineTask?.cancel()
            headerDeadlineTask = nil
            requestHead = head
            completeIncompletePreAuthConnection()
            guard runtime.beginRequest() else {
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_endpoint_busy")
                return
            }
            requestIsActive = true
            startRequestDeadline(context: context)
            handleHead(head, context: context)
        case .body(var buffer):
            guard !responseStarted else { return }
            guard requestBody.count + buffer.readableBytes <= ConsumeLocalLimits.bodyBytes else {
                writeLocalError(context: context, status: .payloadTooLarge, code: "local_request_too_large")
                return
            }
            let readableBytes = buffer.readableBytes
            guard runtime.reserveBodyBytes(readableBytes) else {
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_endpoint_busy")
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
                reservedBodyBytes += bytes.count
                refreshBodyIdleDeadline(context: context)
            } else {
                runtime.releaseBodyBytes(readableBytes)
            }
        case .end:
            cancelPostHeaderDeadlines()
            guard let head = requestHead else {
                context.close(promise: nil)
                return
            }
            guard !responseStarted else {
                endRequestIfNeeded()
                return
            }
            handleEnd(head: head, context: context)
            if !upstreamForwardIsPending {
                endRequestIfNeeded()
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        headerDeadlineTask?.cancel()
        headerDeadlineTask = nil
        cancelPostHeaderDeadlines()
        channelForDeadline = nil
        if connectionIsIncompletePreAuth {
            runtime.endIncompleteConnection()
            connectionIsIncompletePreAuth = false
        }
        if upstreamForwardIsPending {
            channelInactiveWhileUpstreamPending = true
            if !upstreamForwardWasDispatched {
                releaseUpstreamResourcesIfNeeded()
                endRequestIfNeeded()
            }
        }
        if !upstreamForwardIsPending {
            endRequestIfNeeded()
        }
    }

    private func handleHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        if head.method == .HEAD {
            writeHeadOnly(context: context, status: .methodNotAllowed)
            return
        }
        if let error = validatePreAuthBoundsAndFraming(head) {
            writeLocalError(context: context, status: error.status, code: error.code)
            return
        }
        if let error = validateBrowserOrigin(head) {
            writeLocalError(context: context, status: error.status, code: error.code)
            return
        }
        let statusNoStore = head.method == .GET && head.uri == "/v1/status"
        guard runtime.tokenVerifier.verify(headers: head.headers) else {
            writeLocalError(
                context: context,
                status: .unauthorized,
                code: "local_auth_required",
                extraHeaders: statusNoStore ? [("cache-control", "no-store")] : []
            )
            return
        }
        do {
            validatedRequest = try validateEndpoint(head)
        } catch let error as ConsumeLocalValidationError {
            writeLocalError(context: context, status: error.status, code: error.code)
        } catch {
            writeLocalError(context: context, status: .badRequest, code: "local_invalid_request")
        }
    }

    private func handleEnd(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard let validatedRequest else {
            return
        }
        switch validatedRequest.endpoint {
        case .status:
            guard requestBody.isEmpty else {
                writeLocalError(context: context, status: .badRequest, code: "local_invalid_request")
                return
            }
            writeJSON(
                context: context,
                status: .ok,
                body: runtime.statusPayload(),
                extraHeaders: [("cache-control", "no-store")]
            )
        case .models:
            guard requestBody.isEmpty else {
                writeLocalError(context: context, status: .badRequest, code: "local_invalid_request")
                return
            }
            writeLocalModels(context: context)
        case .chatCompletions:
            guard let parsed = parseLocalBody(head: head, body: requestBody, requiresJSONObject: true, context: context) else {
                return
            }
            guard let model = parsed.objectString("model"),
                  runtime.modelAllowlist.contains(model) else {
                writeLocalError(context: context, status: .badRequest, code: "local_model_not_allowed")
                return
            }
            writeLocalChatAdmissionFailure(
                model: model,
                request: parsed,
                bodyByteCount: requestBody.count,
                context: context
            )
        }
    }

    private func validatePreAuthBoundsAndFraming(_ head: HTTPRequestHead) -> ConsumeLocalValidationError? {
        let requestLineBytes = "\(head.method.rawValue) \(head.uri) HTTP/\(head.version.major).\(head.version.minor)".utf8.count
        guard requestLineBytes <= ConsumeLocalLimits.requestLineBytes,
              head.uri.utf8.count <= ConsumeLocalLimits.requestTargetBytes else {
            return ConsumeLocalValidationError(status: .payloadTooLarge, code: "local_request_too_large")
        }
        var headerBytes = 0
        var headerCount = 0
        for (name, value) in head.headers {
            headerCount += 1
            headerBytes += name.utf8.count + value.utf8.count + 4
        }
        guard headerCount <= ConsumeLocalLimits.headerCount,
              headerBytes <= ConsumeLocalLimits.headerBytes else {
            return ConsumeLocalValidationError(status: .payloadTooLarge, code: "local_request_too_large")
        }
        let contentLengths = head.headers["content-length"]
        guard contentLengths.count <= 1 else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        for value in contentLengths {
            let normalized = value.trimmingCharacters(in: .whitespaces)
            guard normalized.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                  !value.contains(","),
                  let length = Int(normalized) else {
                return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
            }
            guard length <= ConsumeLocalLimits.bodyBytes else {
                return ConsumeLocalValidationError(status: .payloadTooLarge, code: "local_request_too_large")
            }
        }
        let transferTokens = head.headers["transfer-encoding"]
            .flatMap { value in
                value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            }
        guard transferTokens.allSatisfy({ !$0.isEmpty }) else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        guard contentLengths.isEmpty || transferTokens.isEmpty else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        guard transferTokens.isEmpty || transferTokens == ["chunked"] else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        return nil
    }

    private func validateBrowserOrigin(_ head: HTTPRequestHead) -> ConsumeLocalValidationError? {
        if head.method == .OPTIONS,
           !head.headers[canonicalForm: "access-control-request-method"].isEmpty {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        var origins: [String] = []
        for (name, value) in head.headers where name.caseInsensitiveCompare("origin") == .orderedSame {
            origins.append(value)
        }
        guard origins.count <= 1 else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        if let origin = origins.first {
            let normalized = origin.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized == origin,
                  origin != "null",
                  !origin.contains(","),
                  origin == runtime.boundURL else {
                return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
            }
        }
        for site in head.headers[canonicalForm: "sec-fetch-site"] {
            let normalized = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "same-origin" || normalized == "none" else {
                return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
            }
        }
        return nil
    }

    private func validateEndpoint(_ head: HTTPRequestHead) throws -> ConsumeValidatedRequest {
        let target = try decodeExactRequestTarget(head.uri)
        switch (head.method, target) {
        case (.GET, "/v1/status"):
            return ConsumeValidatedRequest(endpoint: .status)
        case (.GET, "/v1/models"):
            return ConsumeValidatedRequest(endpoint: .models)
        case (.POST, "/v1/chat/completions"):
            return ConsumeValidatedRequest(endpoint: .chatCompletions)
        case (.POST, "/v1/status"), (.POST, "/v1/models"), (.GET, "/v1/chat/completions"):
            throw ConsumeLocalValidationError(status: .methodNotAllowed, code: "local_endpoint_unsupported")
        default:
            throw ConsumeLocalValidationError(status: .notFound, code: "local_endpoint_unsupported")
        }
    }

    private func decodeExactRequestTarget(_ rawTarget: String) throws -> String {
        guard rawTarget.first == "/" else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        if let hash = rawTarget.firstIndex(of: "#"), hash != rawTarget.endIndex {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        if let query = rawTarget.firstIndex(of: "?") {
            let afterQuery = rawTarget.index(after: query)
            guard afterQuery == rawTarget.endIndex else {
                throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
            }
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        guard !rawTarget.contains("\\") else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        let lowercase = rawTarget.lowercased()
        guard !lowercase.contains("%2f"), !lowercase.contains("%5c") else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        let decoded = try percentDecodePath(rawTarget)
        guard decoded == rawTarget else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard !decoded.contains("//"),
              !components.contains("."),
              !components.contains("..") else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        guard decoded == "/v1/status" || decoded == "/v1/models" || decoded == "/v1/chat/completions" else {
            return decoded
        }
        return decoded
    }

    private func percentDecodePath(_ rawPath: String) throws -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rawPath.utf8.count)
        var index = rawPath.utf8.startIndex
        while index < rawPath.utf8.endIndex {
            let byte = rawPath.utf8[index]
            if byte == 0x25 {
                let first = rawPath.utf8.index(after: index)
                guard first < rawPath.utf8.endIndex else {
                    throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
                }
                let second = rawPath.utf8.index(after: first)
                guard second < rawPath.utf8.endIndex,
                      let high = hex(rawPath.utf8[first]),
                      let low = hex(rawPath.utf8[second]) else {
                    throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
                }
                bytes.append(high << 4 | low)
                index = rawPath.utf8.index(after: second)
            } else {
                bytes.append(byte)
                index = rawPath.utf8.index(after: index)
            }
            guard bytes.count <= ConsumeLocalLimits.requestTargetBytes else {
                throw ConsumeLocalValidationError(status: .payloadTooLarge, code: "local_request_too_large")
            }
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        return decoded
    }

    private func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            return byte - 48
        case 65...70:
            return byte - 55
        case 97...102:
            return byte - 87
        default:
            return nil
        }
    }

    private func validateLocalBody(
        head: HTTPRequestHead,
        body: Data,
        requiresJSONObject: Bool,
        context: ChannelHandlerContext
    ) -> Bool {
        parseLocalBody(head: head, body: body, requiresJSONObject: requiresJSONObject, context: context) != nil
    }

    private func parseLocalBody(
        head: HTTPRequestHead,
        body: Data,
        requiresJSONObject: Bool,
        context: ChannelHandlerContext
    ) -> JSONValue? {
        let encodings = head.headers[canonicalForm: "content-encoding"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard encodings.isEmpty || encodings == ["identity"] else {
            writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 415), code: "local_content_encoding_unsupported")
            return nil
        }
        guard body.count <= ConsumeLocalLimits.bodyBytes else {
            writeLocalError(context: context, status: .payloadTooLarge, code: "local_request_too_large")
            return nil
        }
        guard !requiresJSONObject || !body.isEmpty,
              let text = String(data: body, encoding: .utf8),
              let parsed = try? StrictJSONParser.parse(text),
              !requiresJSONObject || parsed.isObject else {
            writeLocalError(context: context, status: .badRequest, code: "local_invalid_request")
            return nil
        }
        return parsed
    }

    private struct ForwardingPricingSnapshot {
        let match: ConsumeTrustedRateCardMatch
        let projection: RateCardProjection
        let estimate: ConsumePricedExposureEstimate
        let warningCodes: [String]
    }

    private func forwardingPricingSnapshot(
        model: String,
        request: JSONValue,
        bodyByteCount: Int
    ) throws -> ForwardingPricingSnapshot? {
        let trustedPricing = runtime.trustedPricing.revalidated(now: runtime.now())
        guard case .available(let rateCard) = trustedPricing,
              let pricingMatch = trustedPricing.match(model: model),
              pricingMatch.source != .defaultFallback else {
            return nil
        }
        let estimate = try ConsumePricedExposureEstimator.estimate(
            bodyByteCount: bodyByteCount,
            request: request,
            match: pricingMatch,
            projection: rateCard.projection
        )
        return ForwardingPricingSnapshot(
            match: pricingMatch,
            projection: rateCard.projection,
            estimate: estimate,
            warningCodes: trustedPricing.warningCodes(match: pricingMatch)
        )
    }

    private func writeLocalChatAdmissionFailure(model: String, request: JSONValue, bodyByteCount: Int, context: ChannelHandlerContext) {
        guard request.objectBool("stream") != true else {
            writeLocalError(context: context, status: .serviceUnavailable, code: "local_pricing_unavailable")
            return
        }
        let trustedPricing = runtime.trustedPricing.revalidated(now: runtime.now())
        let pricingMatch = trustedPricing.match(model: model)
        let trustedPricingWarnings = trustedPricing.warningCodes(match: pricingMatch)
        let pricingAdmitsCurrentRequest: Bool
        if let pricingMatch {
            pricingAdmitsCurrentRequest = pricingMatch.source != .defaultFallback
        } else {
            pricingAdmitsCurrentRequest = false
        }
        switch runtime.budget.mode {
        case .unconfigured:
            writeLocalError(context: context, status: .badRequest, code: "local_budget_required")
        case .noBudget:
            guard !runtime.pricingAdmissionGate.isEstimateExceeded() else {
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_estimate_exceeded")
                return
            }
            guard pricingAdmitsCurrentRequest,
                  let pricingMatch,
                  case .available(let rateCard) = trustedPricing else {
                writeLocalError(
                    context: context,
                    status: .serviceUnavailable,
                    code: "local_pricing_unavailable",
                    extraHeaders: warningHeaders(runtime.budget.localWarningTokens)
                )
                return
            }
            let estimate: ConsumePricedExposureEstimate
            do {
                estimate = try ConsumePricedExposureEstimator.estimate(
                    bodyByteCount: bodyByteCount,
                    request: request,
                    match: pricingMatch,
                    projection: rateCard.projection
                )
            } catch {
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_pricing_unavailable")
                return
            }
            if let maxRequest = runtime.budget.maxRequestMicroUSD, estimate.amount > maxRequest {
                writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                return
            }
            let headers = warningHeaders(runtime.budget.localWarningTokens + trustedPricingWarnings)
            let contextBox = ConsumeNIOContextBox(context)
            resolveUpstreamEndpoint(context: context, extraHeaders: headers) { [weak self] endpoint in
                guard let self else { return false }
                guard !self.channelInactiveWhileUpstreamPending else { return false }
                guard !self.runtime.pricingAdmissionGate.isEstimateExceeded() else {
                    self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_estimate_exceeded")
                    return false
                }
                let currentPricing: ForwardingPricingSnapshot
                do {
                    guard let snapshot = try self.forwardingPricingSnapshot(
                        model: model,
                        request: request,
                        bodyByteCount: bodyByteCount
                    ) else {
                        self.writeLocalError(
                            context: contextBox.context,
                            status: .serviceUnavailable,
                            code: "local_pricing_unavailable",
                            extraHeaders: self.warningHeaders(self.runtime.budget.localWarningTokens)
                        )
                        return false
                    }
                    currentPricing = snapshot
                } catch {
                    self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_pricing_unavailable")
                    return false
                }
                if let maxRequest = self.runtime.budget.maxRequestMicroUSD, currentPricing.estimate.amount > maxRequest {
                    self.writeLocalError(context: contextBox.context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                    return false
                }
                let currentHeaders = self.warningHeaders(self.runtime.budget.localWarningTokens + currentPricing.warningCodes)
                guard let bearerToken = self.runtime.credentialCustody.upstreamBearerToken() else {
                    self.writeLocalError(
                        context: contextBox.context,
                        status: .unauthorized,
                        code: "local_credential_missing",
                        extraHeaders: currentHeaders
                    )
                    return false
                }
                guard !self.runtime.pricingAdmissionGate.isEstimateExceeded() else {
                    self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_estimate_exceeded")
                    return false
                }
                if let ledger = self.runtime.budget.ledger {
                    do {
                        switch try ledger.reserveNoBudgetEstimateForForwarding(
                            runID: self.runtime.launchID,
                            estimate: currentPricing.estimate.amount,
                            maxRequest: self.runtime.budget.maxRequestMicroUSD
                        ) {
                        case .budgetExceeded:
                            self.writeLocalError(context: contextBox.context, status: HTTPResponseStatus(statusCode: 402), code: "local_budget_exceeded")
                        case .requestCapExceeded:
                            self.writeLocalError(context: contextBox.context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                        case .held:
                            self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                        case .reserved(let reservationID, let reservedAmount):
                            self.forwardUpstreamWithLedgerSettlement(
                                body: self.requestBody,
                                context: contextBox.context,
                                endpoint: endpoint,
                                bearerToken: bearerToken,
                                ledger: ledger,
                                reservationID: reservationID,
                                reservedAmount: reservedAmount,
                                estimate: currentPricing.estimate,
                                pricingMatch: currentPricing.match,
                                projection: currentPricing.projection,
                                extraHeaders: currentHeaders
                            )
                            return true
                        }
                    } catch {
                        self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                    }
                    return false
                }
                self.forwardUpstreamWithoutLedger(
                    body: self.requestBody,
                    context: contextBox.context,
                    endpoint: endpoint,
                    bearerToken: bearerToken,
                    extraHeaders: currentHeaders
                )
                return true
            }
            return
        case .budget(let budget):
            guard !runtime.pricingAdmissionGate.isEstimateExceeded() else {
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_estimate_exceeded")
                return
            }
            if pricingAdmitsCurrentRequest,
               let pricingMatch,
               case .available(let rateCard) = trustedPricing {
                let estimate: ConsumePricedExposureEstimate
                do {
                    estimate = try ConsumePricedExposureEstimator.estimate(
                        bodyByteCount: bodyByteCount,
                        request: request,
                        match: pricingMatch,
                        projection: rateCard.projection
                    )
                } catch {
                    if !runtime.budget.allowUnpriced {
                        writeLocalError(context: context, status: .serviceUnavailable, code: "local_pricing_unavailable")
                        return
                    }
                    return writeLocalUnpricedBudgetAdmission(budget: budget, context: context)
                }
                guard estimate.amount > .zero else {
                    writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                    return
                }
                if let maxRequest = runtime.budget.maxRequestMicroUSD, estimate.amount > maxRequest {
                    writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                    return
                }
                guard let ledger = runtime.budget.ledger else {
                    writeLocalError(context: context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                    return
                }
                do {
                    switch try ledger.previewPricedEstimateForForwarding(
                        budget: budget,
                        estimate: estimate.amount,
                        maxRequest: runtime.budget.maxRequestMicroUSD
                    ) {
                    case .budgetExceeded:
                        writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 402), code: "local_budget_exceeded")
                        return
                    case .requestCapExceeded:
                        writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                        return
                    case .held:
                        break
                    case .reserved:
                        writeLocalError(context: context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                        return
                    }
                } catch {
                    writeLocalError(context: context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                    return
                }
                let headers = warningHeaders(runtime.budget.localWarningTokens + trustedPricingWarnings)
                let contextBox = ConsumeNIOContextBox(context)
                resolveUpstreamEndpoint(context: context, extraHeaders: headers) { [weak self] endpoint in
                    guard let self else { return false }
                    guard !self.channelInactiveWhileUpstreamPending else { return false }
                    guard !self.runtime.pricingAdmissionGate.isEstimateExceeded() else {
                        self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_estimate_exceeded")
                        return false
                    }
                    let currentPricing: ForwardingPricingSnapshot
                    do {
                        guard let snapshot = try self.forwardingPricingSnapshot(
                            model: model,
                            request: request,
                            bodyByteCount: bodyByteCount
                        ) else {
                            self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_pricing_unavailable")
                            return false
                        }
                        currentPricing = snapshot
                    } catch {
                        self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_pricing_unavailable")
                        return false
                    }
                    guard currentPricing.estimate.amount > .zero else {
                        self.writeLocalError(context: contextBox.context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                        return false
                    }
                    if let maxRequest = self.runtime.budget.maxRequestMicroUSD, currentPricing.estimate.amount > maxRequest {
                        self.writeLocalError(context: contextBox.context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                        return false
                    }
                    let currentHeaders = self.warningHeaders(self.runtime.budget.localWarningTokens + currentPricing.warningCodes)
                    do {
                        switch try ledger.previewPricedEstimateForForwarding(
                            budget: budget,
                            estimate: currentPricing.estimate.amount,
                            maxRequest: self.runtime.budget.maxRequestMicroUSD
                        ) {
                        case .budgetExceeded:
                            self.writeLocalError(context: contextBox.context, status: HTTPResponseStatus(statusCode: 402), code: "local_budget_exceeded")
                            return false
                        case .requestCapExceeded:
                            self.writeLocalError(context: contextBox.context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                            return false
                        case .held:
                            break
                        case .reserved:
                            self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                            return false
                        }
                    } catch {
                        self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                        return false
                    }
                    guard let bearerToken = self.runtime.credentialCustody.upstreamBearerToken() else {
                        self.writeLocalError(context: contextBox.context, status: .unauthorized, code: "local_credential_missing")
                        return false
                    }
                    guard !self.runtime.pricingAdmissionGate.isEstimateExceeded() else {
                        self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_estimate_exceeded")
                        return false
                    }
                    do {
                        switch try ledger.reservePricedEstimateForForwarding(
                            runID: self.runtime.launchID,
                            budget: budget,
                            estimate: currentPricing.estimate.amount,
                            maxRequest: self.runtime.budget.maxRequestMicroUSD
                        ) {
                        case .budgetExceeded:
                            self.writeLocalError(context: contextBox.context, status: HTTPResponseStatus(statusCode: 402), code: "local_budget_exceeded")
                        case .requestCapExceeded:
                            self.writeLocalError(context: contextBox.context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                        case .held:
                            self.writeLocalError(
                                context: contextBox.context,
                                status: .serviceUnavailable,
                                code: "local_upstream_unavailable",
                                extraHeaders: currentHeaders
                            )
                        case .reserved(let reservationID, let reservedAmount):
                            self.forwardUpstreamWithLedgerSettlement(
                                body: self.requestBody,
                                context: contextBox.context,
                                endpoint: endpoint,
                                bearerToken: bearerToken,
                                ledger: ledger,
                                reservationID: reservationID,
                                reservedAmount: reservedAmount,
                                estimate: currentPricing.estimate,
                                pricingMatch: currentPricing.match,
                                projection: currentPricing.projection,
                                extraHeaders: currentHeaders
                            )
                            return true
                        }
                    } catch {
                        self.writeLocalError(context: contextBox.context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                    }
                    return false
                }
                return
            } else if !runtime.budget.allowUnpriced {
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_pricing_unavailable")
                return
            }
            writeLocalUnpricedBudgetAdmission(budget: budget, context: context)
        }
    }

    private func forwardUpstreamWithoutLedger(
        body: Data,
        context: ChannelHandlerContext,
        endpoint: String,
        bearerToken: String,
        extraHeaders: [(String, String)]
    ) {
        let request = ConsumeUpstreamRequest(
            origin: runtime.upstreamOrigin,
            endpoint: endpoint,
            bearerToken: bearerToken,
            body: body
        )
        let contextBox = ConsumeNIOContextBox(context)
        upstreamForwardIsPending = true
        upstreamForwardWasDispatched = true
        runtime.upstreamClient.forwardChatCompletions(request: request, on: context.eventLoop).whenComplete { [weak self] result in
            guard let self else { return }
            defer {
                self.releaseUpstreamResourcesIfNeeded()
                self.upstreamForwardIsPending = false
                self.upstreamForwardWasDispatched = false
                self.endRequestIfNeeded()
            }
            switch result {
            case .success(let response):
                do {
                    let localResponse = try Self.responseForLocalDelivery(response)
                    self.writeUpstreamResponse(localResponse, context: contextBox.context, extraHeaders: extraHeaders)
                } catch {
                    self.writeLocalError(
                        context: contextBox.context,
                        status: HTTPResponseStatus(statusCode: 502),
                        code: "local_upstream_unavailable",
                        forwardedUpstream: true,
                        extraHeaders: extraHeaders
                    )
                }
            case .failure(let error):
                let failure = Self.classifyUpstreamFailure(error)
                self.writeLocalError(
                    context: contextBox.context,
                    status: failure.status,
                    code: "local_upstream_unavailable",
                    forwardedUpstream: failure.forwardedUpstream,
                    extraHeaders: extraHeaders
                )
            }
        }
    }

    private func forwardUpstreamWithLedgerSettlement(
        body: Data,
        context: ChannelHandlerContext,
        endpoint: String,
        bearerToken: String,
        ledger: ConsumeBudgetLedger,
        reservationID: String,
        reservedAmount: ConsumeMicroUSD,
        estimate: ConsumePricedExposureEstimate,
        pricingMatch: ConsumeTrustedRateCardMatch,
        projection: RateCardProjection,
        extraHeaders: [(String, String)]
    ) {
        let request = ConsumeUpstreamRequest(
            origin: runtime.upstreamOrigin,
            endpoint: endpoint,
            bearerToken: bearerToken,
            body: body
        )
        let contextBox = ConsumeNIOContextBox(context)
        upstreamForwardIsPending = true
        upstreamForwardWasDispatched = true
        runtime.upstreamClient.forwardChatCompletions(request: request, on: context.eventLoop).whenComplete { [weak self] result in
            guard let self else { return }
            defer {
                self.releaseUpstreamResourcesIfNeeded()
                self.upstreamForwardIsPending = false
                self.upstreamForwardWasDispatched = false
                self.endRequestIfNeeded()
            }
            switch result {
            case .success(let response):
                let localResponse: ConsumeUpstreamResponse
                do {
                    localResponse = try Self.responseForLocalDelivery(response)
                    let settlement = try self.settlementAmount(
                        response: localResponse,
                        fallbackEstimate: estimate.amount,
                        pricingMatch: pricingMatch,
                        projection: projection
                    )
                    if settlement.amount > reservedAmount {
                        try ledger.estimateExceeded(
                            runID: self.runtime.launchID,
                            reservationID: reservationID,
                            reservedAmount: reservedAmount,
                            settledAmount: settlement.amount,
                            reason: settlement.reason
                        )
                        self.runtime.pricingAdmissionGate.stopForEstimateExceeded()
                    } else {
                        try ledger.settle(
                            runID: self.runtime.launchID,
                            reservationID: reservationID,
                            reservedAmount: reservedAmount,
                            settledAmount: settlement.amount,
                            reason: settlement.reason
                        )
                    }
                } catch ConsumeUpstreamForwardError.dispatchedUnavailable {
                    do {
                        try ledger.settle(
                            runID: self.runtime.launchID,
                            reservationID: reservationID,
                            reservedAmount: reservedAmount,
                            settledAmount: estimate.amount,
                            reason: "settled_to_admission_estimate"
                        )
                    } catch {
                        self.writeLocalError(
                            context: contextBox.context,
                            status: .serviceUnavailable,
                            code: "local_budget_ledger_unavailable",
                            forwardedUpstream: true,
                            extraHeaders: extraHeaders
                        )
                        return
                    }
                    self.writeLocalError(
                        context: contextBox.context,
                        status: HTTPResponseStatus(statusCode: 502),
                        code: "local_upstream_unavailable",
                        forwardedUpstream: true,
                        extraHeaders: extraHeaders
                    )
                    return
                } catch {
                    self.writeLocalError(
                        context: contextBox.context,
                        status: .serviceUnavailable,
                        code: "local_budget_ledger_unavailable",
                        forwardedUpstream: true,
                        extraHeaders: extraHeaders
                    )
                    return
                }
                self.writeUpstreamResponse(localResponse, context: contextBox.context, extraHeaders: extraHeaders)
            case .failure(let error):
                let failure = Self.classifyUpstreamFailure(error)
                do {
                    if failure.forwardedUpstream {
                        try ledger.hold(
                            runID: self.runtime.launchID,
                            reservationID: reservationID,
                            amount: reservedAmount,
                            reason: "upstream_proxy_failed"
                        )
                    } else {
                        try ledger.settle(
                            runID: self.runtime.launchID,
                            reservationID: reservationID,
                            reservedAmount: reservedAmount,
                            settledAmount: .zero,
                            reason: "upstream_pre_dispatch_failed"
                        )
                    }
                } catch {
                    self.writeLocalError(
                        context: contextBox.context,
                        status: .serviceUnavailable,
                        code: "local_budget_ledger_unavailable",
                        forwardedUpstream: failure.forwardedUpstream,
                        extraHeaders: extraHeaders
                    )
                    return
                }
                self.writeLocalError(
                    context: contextBox.context,
                    status: failure.status,
                    code: "local_upstream_unavailable",
                    forwardedUpstream: failure.forwardedUpstream,
                    extraHeaders: extraHeaders
                )
            }
        }
    }

    private func resolveUpstreamEndpoint(
        context: ChannelHandlerContext,
        extraHeaders: [(String, String)],
        onSuccess: @escaping @Sendable (String) -> Bool
    ) {
        let contextBox = ConsumeNIOContextBox(context)
        guard reserveUpstreamResources(context: contextBox.context, extraHeaders: extraHeaders) else { return }
        upstreamForwardIsPending = true
        upstreamForwardWasDispatched = false
        channelInactiveWhileUpstreamPending = false
        runtime.upstreamClient.resolveChatCompletionsEndpoint(origin: runtime.upstreamOrigin, on: context.eventLoop).whenComplete { [weak self] result in
            guard let self else { return }
            self.upstreamForwardIsPending = false
            switch result {
            case .success(let endpoint):
                self.upstreamForwardIsPending = false
                if !onSuccess(endpoint) {
                    self.upstreamForwardWasDispatched = false
                    self.releaseUpstreamResourcesIfNeeded()
                    self.endRequestIfNeeded()
                }
            case .failure(let error):
                defer {
                    self.releaseUpstreamResourcesIfNeeded()
                    self.upstreamForwardWasDispatched = false
                    self.endRequestIfNeeded()
                }
                self.upstreamForwardIsPending = false
                let failure = Self.classifyUpstreamFailure(error)
                self.writeLocalError(
                    context: contextBox.context,
                    status: failure.status,
                    code: "local_upstream_unavailable",
                    forwardedUpstream: failure.forwardedUpstream,
                    extraHeaders: extraHeaders
                )
            }
        }
    }

    private func reserveUpstreamResources(
        context: ChannelHandlerContext,
        extraHeaders: [(String, String)]
    ) -> Bool {
        guard upstreamResourceReservation == nil,
              let reservation = runtime.reserveUpstreamExchange(
                responseSpoolBytes: ConsumeLocalLimits.nonStreamingResponseSpoolBytes
              ) else {
            writeLocalError(
                context: context,
                status: .serviceUnavailable,
                code: "local_endpoint_busy",
                extraHeaders: extraHeaders
            )
            return false
        }
        upstreamResourceReservation = reservation
        return true
    }

    private func releaseUpstreamResourcesIfNeeded() {
        guard let reservation = upstreamResourceReservation else { return }
        upstreamResourceReservation = nil
        runtime.releaseUpstreamExchange(reservation)
    }

    private static func classifyUpstreamFailure(_ error: Error) -> ConsumeUpstreamFailureClassification {
        if case ConsumeUpstreamForwardError.preDispatchUnavailable = error {
            return ConsumeUpstreamFailureClassification(
                status: .serviceUnavailable,
                forwardedUpstream: false
            )
        }
        if case ConsumeUpstreamForwardError.dispatchedUnavailable = error {
            return ConsumeUpstreamFailureClassification(
                status: HTTPResponseStatus(statusCode: 502),
                forwardedUpstream: true
            )
        }
        return ConsumeUpstreamFailureClassification(
            status: .serviceUnavailable,
            forwardedUpstream: false
        )
    }

    private func settlementAmount(
        response: ConsumeUpstreamResponse,
        fallbackEstimate: ConsumeMicroUSD,
        pricingMatch: ConsumeTrustedRateCardMatch,
        projection: RateCardProjection
    ) throws -> (amount: ConsumeMicroUSD, reason: String) {
        guard let text = String(data: response.body, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text),
              case .object(let usage)? = root["usage"],
              case .int(let promptTokens)? = usage["prompt_tokens"],
              case .int(let completionTokens)? = usage["completion_tokens"] else {
            return (fallbackEstimate, "settled_to_admission_estimate")
        }
        guard let amount = try? ConsumePricedExposureEstimator.actualUsageSettlement(
            promptTokens: Int64(promptTokens),
            completionTokens: Int64(completionTokens),
            match: pricingMatch,
            projection: projection
        ) else {
            return (fallbackEstimate, "settled_to_admission_estimate")
        }
        return (amount, "settled_to_upstream_usage")
    }

    private static func responseForLocalDelivery(_ response: ConsumeUpstreamResponse) throws -> ConsumeUpstreamResponse {
        switch try upstreamResponseContentCoding(response.headers) {
        case .identity:
            return ConsumeUpstreamResponse(
                statusCode: response.statusCode,
                headers: response.headers.filter { name, _ in
                    name.caseInsensitiveCompare("content-encoding") != .orderedSame &&
                        name.caseInsensitiveCompare("content-length") != .orderedSame
                },
                body: response.body
            )
        case .gzip:
            let decodedBody = try gunzip(response.body, maxDecodedBytes: ConsumeLocalLimits.bodyBytes)
            return ConsumeUpstreamResponse(
                statusCode: response.statusCode,
                headers: response.headers.filter { name, _ in
                    name.caseInsensitiveCompare("content-encoding") != .orderedSame &&
                        name.caseInsensitiveCompare("content-length") != .orderedSame
                },
                body: decodedBody
            )
        }
    }

    private static func upstreamResponseContentCoding(_ headers: [(String, String)]) throws -> ConsumeUpstreamResponseContentCoding {
        let tokens = headers
            .filter { name, _ in name.caseInsensitiveCompare("content-encoding") == .orderedSame }
            .flatMap { _, value in
                value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { trimHTTPOptionalWhitespace($0).lowercased() }
            }
        guard tokens.allSatisfy({ !$0.isEmpty }) else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        if tokens.isEmpty || tokens == ["identity"] {
            return .identity
        }
        if tokens == ["gzip"] {
            return .gzip
        }
        throw ConsumeUpstreamForwardError.dispatchedUnavailable
    }

    private static func trimHTTPOptionalWhitespace(_ value: Substring) -> String {
        var start = value.startIndex
        var end = value.endIndex
        while start < end, value[start] == " " || value[start] == "\t" {
            start = value.index(after: start)
        }
        while start < end {
            let previous = value.index(before: end)
            guard value[previous] == " " || value[previous] == "\t" else { break }
            end = previous
        }
        return String(value[start..<end])
    }

    private static func gunzip(_ body: Data, maxDecodedBytes: Int) throws -> Data {
        guard body.count <= Int(UInt32.max), maxDecodedBytes >= 0 else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            16 + MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw ConsumeUpstreamForwardError.dispatchedUnavailable
        }
        defer { inflateEnd(&stream) }

        return try body.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: input.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(body.count)
            var output = Data()
            let chunkSize = 32 * 1024

            while true {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                let status = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
                    stream.next_out = rawBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    guard output.count + produced <= maxDecodedBytes else {
                        throw ConsumeUpstreamForwardError.dispatchedUnavailable
                    }
                    output.append(contentsOf: buffer.prefix(produced))
                }

                switch status {
                case Z_STREAM_END:
                    guard stream.avail_in == 0 else {
                        throw ConsumeUpstreamForwardError.dispatchedUnavailable
                    }
                    return output
                case Z_OK:
                    guard produced > 0 || stream.avail_in > 0 else {
                        throw ConsumeUpstreamForwardError.dispatchedUnavailable
                    }
                default:
                    throw ConsumeUpstreamForwardError.dispatchedUnavailable
                }
            }
        }
    }

    private func writeLocalUnpricedBudgetAdmission(budget: ConsumeMicroUSD, context: ChannelHandlerContext) {
        do {
            guard let ledger = runtime.budget.ledger else {
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                return
            }
            switch try ledger.previewUnpricedRemaining(
                budget: budget,
                maxRequest: runtime.budget.maxRequestMicroUSD
            ) {
            case .budgetExceeded:
                writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 402), code: "local_budget_exceeded")
                return
            case .requestCapExceeded:
                writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
                return
            case .held:
                break
            case .reserved:
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
                return
            }
            guard runtime.credentialCustody.upstreamBearerToken() != nil else {
                writeLocalError(context: context, status: .unauthorized, code: "local_credential_missing")
                return
            }
            switch try ledger.reserveAndHoldUnpricedRemaining(
                runID: runtime.launchID,
                budget: budget,
                maxRequest: runtime.budget.maxRequestMicroUSD
            ) {
            case .budgetExceeded:
                writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 402), code: "local_budget_exceeded")
            case .requestCapExceeded:
                writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 402), code: "local_request_cap_exceeded")
            case .held:
                writeLocalError(
                    context: context,
                    status: .serviceUnavailable,
                    code: "local_upstream_unavailable",
                    extraHeaders: warningHeaders(runtime.budget.localWarningTokens)
                )
            case .reserved:
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
            }
        } catch {
            writeLocalError(context: context, status: .serviceUnavailable, code: "local_budget_ledger_unavailable")
        }
    }

    private func warningHeaders(_ warnings: [String]) -> [(String, String)] {
        guard !warnings.isEmpty else { return [] }
        return [("x-macprovider-warning", warnings.joined(separator: ","))]
    }

    private func writeLocalModels(context: ChannelHandlerContext) {
        let models = runtime.modelAllowlist.map { modelID in
            [
                "id": modelID,
                "object": "model",
                "created": 0,
                "owned_by": "macprovider",
            ] as [String: Any]
        }
        writeJSON(
            context: context,
            status: .ok,
            body: [
                "object": "list",
                "data": models,
            ],
            extraHeaders: [("cache-control", "no-store")]
        )
    }

    private func endRequestIfNeeded() {
        cancelPostHeaderDeadlines()
        if reservedBodyBytes > 0 {
            runtime.releaseBodyBytes(reservedBodyBytes)
            reservedBodyBytes = 0
        }
        guard requestIsActive else { return }
        requestIsActive = false
        runtime.endRequest()
    }

    private func completeIncompletePreAuthConnection() {
        guard connectionIsIncompletePreAuth else { return }
        connectionIsIncompletePreAuth = false
        runtime.completePreAuthConnection()
    }

    private func closeIfHeaderMissing() {
        guard requestHead == nil else { return }
        channelForDeadline?.close(promise: nil)
    }

    private func startRequestDeadline(context: ChannelHandlerContext) {
        requestDeadlineTask?.cancel()
        requestDeadlineTask = context.eventLoop.scheduleTask(in: ConsumeLocalLimits.requestReadTimeout) { [weak self] in
            self?.closeIfRequestIncomplete()
        }
        if shouldReadBody {
            refreshBodyIdleDeadline(context: context)
        }
    }

    private var shouldReadBody: Bool {
        guard let endpoint = validatedRequest?.endpoint else { return true }
        return endpoint == .chatCompletions
    }

    private func refreshBodyIdleDeadline(context: ChannelHandlerContext) {
        bodyIdleDeadlineTask?.cancel()
        bodyIdleDeadlineTask = context.eventLoop.scheduleTask(in: ConsumeLocalLimits.bodyIdleTimeout) { [weak self] in
            self?.closeIfRequestIncomplete()
        }
    }

    private func closeIfRequestIncomplete() {
        guard requestIsActive, !responseStarted else { return }
        channelForDeadline?.close(promise: nil)
    }

    private func cancelPostHeaderDeadlines() {
        requestDeadlineTask?.cancel()
        requestDeadlineTask = nil
        bodyIdleDeadlineTask?.cancel()
        bodyIdleDeadlineTask = nil
    }

    private func writeLocalError(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        code: String,
        forwardedUpstream: Bool = false,
        extraHeaders: [(String, String)] = []
    ) {
        writeJSON(
            context: context,
            status: status,
            body: errorEnvelope(code: code, forwardedUpstream: forwardedUpstream),
            extraHeaders: extraHeaders
        )
    }

    private func writeUpstreamResponse(
        _ response: ConsumeUpstreamResponse,
        context: ChannelHandlerContext,
        extraHeaders: [(String, String)]
    ) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            let normalized = name.lowercased()
            guard Self.allowedUpstreamResponseHeader(normalized) else {
                continue
            }
            headers.add(name: name, value: value)
        }
        headers.replaceOrAdd(name: "content-length", value: "\(response.body.count)")
        headers.replaceOrAdd(name: "connection", value: "close")
        for (name, value) in extraHeaders {
            if name.caseInsensitiveCompare("x-macprovider-warning") == .orderedSame,
               let existing = headers.first(name: name),
               !existing.isEmpty {
                headers.replaceOrAdd(name: name, value: "\(existing),\(value)")
            } else {
                headers.replaceOrAdd(name: name, value: value)
            }
        }
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        responseStarted = true
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    private static func allowedUpstreamResponseHeader(_ normalizedName: String) -> Bool {
        if normalizedName.hasPrefix("x-ratelimit-") { return true }
        return [
            "content-type",
            "cache-control",
            "retry-after",
            "x-request-id",
            "openai-request-id",
            "x-macprovider-request-id",
            "x-macprovider-receipt",
            "x-macprovider-receipt-signature",
            "x-macprovider-streaming-mode",
            "x-macprovider-warning",
        ].contains(normalizedName)
    }

    private func writeJSON(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        body: Any,
        extraHeaders: [(String, String)] = []
    ) {
        do {
            let data = try body is NSNull
                ? Data()
                : JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
            var headers = HTTPHeaders()
            if !(body is NSNull) {
                headers.add(name: "content-type", value: "application/json")
            }
            headers.add(name: "content-length", value: "\(data.count)")
            headers.add(name: "connection", value: "close")
            for (name, value) in extraHeaders {
                headers.add(name: name, value: value)
            }
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            responseStarted = true
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            if !data.isEmpty {
                var buffer = context.channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            context.close(promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    private func writeHeadOnly(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        var headers = HTTPHeaders()
        headers.add(name: "content-length", value: "0")
        headers.add(name: "connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        responseStarted = true
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    private func errorEnvelope(code: String, forwardedUpstream: Bool) -> [String: Any] {
        [
            "error": [
                "message": code,
                "type": "macprovider_local_error",
                "param": NSNull(),
                "code": code,
                "macprovider": ["forwarded_upstream": forwardedUpstream],
            ],
        ]
    }
}

struct ConsumeLocalValidationError: Error {
    let status: HTTPResponseStatus
    let code: String
}

private extension JSONValue {
    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    func objectString(_ key: String) -> String? {
        guard case .object(let object) = self,
              case .string(let value)? = object[key] else {
            return nil
        }
        return value
    }

    func objectPositiveInt64(_ key: String) -> Int64? {
        guard case .object(let object) = self,
              case .int(let value)? = object[key],
              value > 0 else {
            return nil
        }
        return Int64(value)
    }

    func objectBool(_ key: String) -> Bool? {
        guard case .object(let object) = self,
              case .bool(let value)? = object[key] else {
            return nil
        }
        return value
    }
}

struct ConsumeStatusClient {
    static func fetch(descriptor: ConsumeEndpointDescriptor) async throws -> [String: Any] {
        guard let url = statusURL(from: descriptor.boundURL) else {
            throw ConsumeStartupError(code: "local_endpoint_not_running")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(descriptor.localToken)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = directLoopbackSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["process_launch_id"] as? String == descriptor.launchID else {
            throw ConsumeStartupError(code: "local_endpoint_not_running")
        }
        return object
    }

    private static func statusURL(from boundURL: String) -> URL? {
        guard var components = URLComponents(string: boundURL),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host,
              isLoopbackLiteral(host),
              components.port.map({ (1...65535).contains($0) }) ?? false else {
            return nil
        }
        components.path = "/v1/status"
        return components.url
    }

    private static func isLoopbackLiteral(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "::1" { return true }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 &&
            UInt8(parts[0]) == 127 &&
            parts.dropFirst().allSatisfy { UInt8($0) != nil }
    }

    private static func directLoopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }
}
