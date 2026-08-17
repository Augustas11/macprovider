import AppKit
import Combine
import Darwin
import Foundation
import IOKit.ps
import Security

// MARK: - Capability contract

/// The checked-in JSON resource is the source of truth for feature floors and
/// schema requirements. A model operation is enabled only when that manifest
/// agrees with a fresh, launchd-owned provider observation.
struct MalibuModelCapabilityManifest: Decodable, Sendable {
    struct Tier: Decodable, Sendable {
        let firstSupportingBinaryVersion: String
        let localStatusCapabilities: Set<String>
        let commandSchemas: Set<String>
        let controlFrameSchemas: Set<String>

        enum CodingKeys: String, CodingKey {
            case firstSupportingBinaryVersion = "first_supporting_binary_version"
            case localStatusCapabilities = "local_status_capabilities"
            case commandSchemas = "command_schemas"
            case controlFrameSchemas = "control_frame_schemas"
        }
    }

    static let schemaVersion = "malibu_model_capabilities.v1"
    static let catalogJSON = "model_catalog_json_v1"
    static let readySwitch = "model_ready_switch_v1"
    static let recommendationCheck = "model_recommendation_check_v1"
    static let recommendationAdoption = "model_recommendation_apply_switch_v1"

    let tiers: [String: Tier]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case tiers
    }

    static let checkedIn: MalibuModelCapabilityManifest = {
        let candidates = [
            Bundle.main.url(forResource: "MalibuModelCapabilities", withExtension: "json"),
            Bundle(for: MalibuModelCLI.self).url(forResource: "MalibuModelCapabilities", withExtension: "json"),
        ].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let manifest = try? JSONDecoder().decode(Self.self, from: data),
               manifest.schemaVersion == Self.schemaVersion {
                return manifest
            }
        }
        return MalibuModelCapabilityManifest(schemaVersion: Self.schemaVersion, tiers: [:])
    }()

    private let schemaVersion: String

    init(schemaVersion: String, tiers: [String: Tier]) {
        self.schemaVersion = schemaVersion
        self.tiers = tiers
    }

    func supports(_ capability: String, peer: MalibuModelPeerEvidence) -> Bool {
        guard let tier = tiers[capability],
                  peer.contractCompatible,
                  peer.lifecycleOwner == "macprovider_cli",
                  peer.serviceInstanceID != nil,
                  peer.servicePID != nil,
                  peer.isFresh(),
              peer.capabilities.isSuperset(of: tier.localStatusCapabilities)
                && peer.capabilities.isSuperset(of: tier.commandSchemas)
                && peer.capabilities.isSuperset(of: tier.controlFrameSchemas),
              let binaryVersion = peer.binaryVersion,
              ProviderCLIVersion.strictNormalize(binaryVersion) != nil,
              ProviderCLIVersion.compare(binaryVersion, tier.firstSupportingBinaryVersion) != .ascending
        else { return false }
        return true
    }
}

struct MalibuModelPeerEvidence: Equatable, Sendable {
    let binaryVersion: String?
    let capabilities: Set<String>
    let contractCompatible: Bool
    let lifecycleOwner: String?
    let serviceInstanceID: String?
    let servicePID: Int?
    let observedAt: Date?
    let observationValidForMS: Int?
    let observationFresh: Bool

    init(
        binaryVersion: String?,
        capabilities: Set<String>,
        contractCompatible: Bool,
        lifecycleOwner: String?,
        serviceInstanceID: String?,
        servicePID: Int? = nil,
        observedAt: Date? = nil,
        observationValidForMS: Int? = nil,
        observationFresh: Bool
    ) {
        self.binaryVersion = binaryVersion
        self.capabilities = capabilities
        self.contractCompatible = contractCompatible
        self.lifecycleOwner = lifecycleOwner
        self.serviceInstanceID = serviceInstanceID
        self.servicePID = servicePID
        self.observedAt = observedAt
        self.observationValidForMS = observationValidForMS
        self.observationFresh = observationFresh
    }

    init(snapshot: AgentSnapshot) {
        binaryVersion = snapshot.cliVersion
        capabilities = snapshot.localStatusCapabilities
        contractCompatible = snapshot.localStatusContractCompatible == true
        lifecycleOwner = snapshot.localStatusLifecycleOwner
        serviceInstanceID = snapshot.serviceInstanceID
        servicePID = snapshot.servicePID
        observedAt = snapshot.statusObservedAt
        observationValidForMS = snapshot.statusObservationValidForMS
        observationFresh = snapshot.isLocalStatusObservationCurrent()
    }

    func isFresh(at now: Date = Date()) -> Bool {
        guard observationFresh,
              let observedAt,
              let observationValidForMS,
              (1...60_000).contains(observationValidForMS) else { return false }
        // Model actions use the provider's advertised lease, not the longer
        // UI retention window used for rendering a stale status snapshot.
        // A cached observation must never enable a switch after its lease.
        let validFor = TimeInterval(observationValidForMS) / 1_000
        return observedAt.addingTimeInterval(validFor) >= now
    }

    static let unavailable = MalibuModelPeerEvidence(
        binaryVersion: nil,
        capabilities: [],
        contractCompatible: false,
        lifecycleOwner: nil,
        serviceInstanceID: nil,
        servicePID: nil,
        observedAt: nil,
        observationValidForMS: nil,
        observationFresh: false
    )
}

// MARK: - CLI JSON contracts

struct MalibuModelsListDocument: Decodable, Equatable, Sendable {
    struct Row: Decodable, Equatable, Sendable {
        let modelID: String
        let displayID: String
        let actionModelID: String
        let state: String
        let weightsPresentLocally: Bool
        let source: String
        let fit: String?
        let estimatedGB: Double?

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case displayID = "display_id"
            case actionModelID = "action_model_id"
            case state
            case weightsPresentLocally = "weights_present_locally"
            case source
            case fit
            case estimatedGB = "estimated_gb"
        }

        init(
            modelID: String,
            displayID: String,
            actionModelID: String,
            state: String,
            weightsPresentLocally: Bool,
            source: String,
            fit: String?,
            estimatedGB: Double?
        ) {
            self.modelID = modelID
            self.displayID = displayID
            self.actionModelID = actionModelID
            self.state = state
            self.weightsPresentLocally = weightsPresentLocally
            self.source = source
            self.fit = fit
            self.estimatedGB = estimatedGB
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            modelID = try container.decode(String.self, forKey: .modelID)
            displayID = try container.decode(String.self, forKey: .displayID)
            actionModelID = try container.decode(String.self, forKey: .actionModelID)
            state = try container.decode(String.self, forKey: .state)
            weightsPresentLocally = try container.decode(Bool.self, forKey: .weightsPresentLocally)
            source = try container.decode(String.self, forKey: .source)
            guard container.contains(.fit) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.fit,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "models_list.v1 requires fit, including explicit null")
                )
            }
            guard container.contains(.estimatedGB) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.estimatedGB,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "models_list.v1 requires estimated_gb, including explicit null")
                )
            }
            fit = try container.decodeIfPresent(String.self, forKey: .fit)
            estimatedGB = try container.decodeIfPresent(Double.self, forKey: .estimatedGB)
        }
    }

    let schemaVersion: String
    let generatedAt: String
    let source: String
    let warmSwapAvailable: Bool
    let currentModelID: String?
    let rows: [Row]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case source
        case warmSwapAvailable = "warm_swap_available"
        case currentModelID = "current_model_id"
        case rows
    }

    init(
        schemaVersion: String,
        generatedAt: String,
        source: String,
        warmSwapAvailable: Bool,
        currentModelID: String?,
        rows: [Row]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.source = source
        self.warmSwapAvailable = warmSwapAvailable
        self.currentModelID = currentModelID
        self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        source = try container.decode(String.self, forKey: .source)
        warmSwapAvailable = try container.decode(Bool.self, forKey: .warmSwapAvailable)
        guard container.contains(.currentModelID) else {
            throw DecodingError.keyNotFound(
                CodingKeys.currentModelID,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "models_list.v1 requires current_model_id, including explicit null")
            )
        }
        currentModelID = try container.decodeIfPresent(String.self, forKey: .currentModelID)
        rows = try container.decode([Row].self, forKey: .rows)
    }

    func validated() throws -> MalibuModelsListDocument {
        guard schemaVersion == "models_list.v1",
              ["control_socket", "config_fallback"].contains(source),
              currentModelID == nil || isSafeModelID(currentModelID),
              Self.isValidGeneratedAt(generatedAt),
              rows.filter({ $0.state == "warm" }).count <= 1 else {
            throw ModelManagementError.invalidCatalog
        }
        var seenModelKeys = Set<String>()
        for row in rows {
            guard isSafeModelID(row.modelID),
                  isSafeModelID(row.actionModelID),
                  row.modelID == row.actionModelID,
                  seenModelKeys.insert(row.actionModelID.lowercased(with: nil)).inserted,
                  isSafeDisplayID(row.displayID),
                  ["warm", "idle"].contains(row.state),
                  ["status_response", "supported_models", "config_fallback"].contains(row.source),
                  row.fit == nil || ["fits", "tight", "wont_fit", "unknown"].contains(row.fit!) else {
                throw ModelManagementError.invalidCatalog
            }
        }
        if let currentModelID,
           let warm = rows.first(where: { $0.state == "warm" }),
           warm.modelID != currentModelID {
            throw ModelManagementError.invalidCatalog
        }
        return self
    }

    private static func isValidGeneratedAt(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) != nil
    }
}

struct MalibuModelSwitchEvent: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let type: String
    let transactionID: String
    let fromModelID: String?
    let targetModelID: String
    let phase: String
    let elapsedMS: Int
    let cancellable: Bool
    let reason: String?
    let cooldownSecondsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case transactionID = "transaction_id"
        case fromModelID = "from_model_id"
        case targetModelID = "target_model_id"
        case phase
        case elapsedMS = "elapsed_ms"
        case cancellable
        case reason
        case cooldownSecondsRemaining = "cooldown_seconds_remaining"
    }
}

private func isSafeModelID(_ value: String?) -> Bool {
    guard let value, !value.isEmpty, value.utf8.count <= 256 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
    }
}

private func isSafeDisplayID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 256 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
    }
}

// MARK: - Managed CLI invocation

struct ModelCLIResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ModelCLIWorkPriority: Sendable {
    case interactive
    case background

    var dispatchQoS: DispatchQoS.QoSClass {
        switch self {
        case .interactive: .userInitiated
        case .background: .utility
        }
    }
}

@MainActor
protocol MalibuModelCLIRunning: AnyObject {
    func run(
        arguments: [String],
        peer: MalibuModelPeerEvidence?,
        stdinData: Data?,
        priority: ModelCLIWorkPriority,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ModelCLIResult
    func cancelCurrentOperation()
}

extension MalibuModelCLIRunning {
    func cancelCurrentOperation() {}

    func run(
        arguments: [String],
        peer: MalibuModelPeerEvidence? = nil,
        priority: ModelCLIWorkPriority = .interactive,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ModelCLIResult {
        try await run(
            arguments: arguments,
            peer: peer,
            stdinData: nil,
            priority: priority,
            onLine: onLine
        )
    }
}

private final class ModelCLIOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func append(_ text: String) {
        lock.lock()
        value.append(text)
        lock.unlock()
    }

    func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ModelCLIOutputLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""

    func append(_ text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let combined = partial + text
        let parts = combined.split(separator: "\n", omittingEmptySubsequences: false)
        let endsWithNewline = combined.last == "\n"
        if endsWithNewline {
            partial = ""
        } else {
            partial = parts.last.map(String.init) ?? ""
        }
        let complete = endsWithNewline ? parts : parts.dropLast()
        return complete.compactMap { raw in
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw[...]
            return line.isEmpty ? nil : String(line)
        }
    }

    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !partial.isEmpty else { return [] }
        let line = partial.hasSuffix("\r") ? partial.dropLast() : partial[...]
        partial = ""
        return line.isEmpty ? [] : [String(line)]
    }
}

private final class ModelCLIProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private weak var process: Process?

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
}

@MainActor
final class MalibuModelCLI: MalibuModelCLIRunning {
    enum Error: Swift.Error, LocalizedError {
        case executableUnavailable
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .executableUnavailable:
                return String(localized: "The managed provider CLI is unavailable. Update or repair provider software to enable model controls.", comment: "Model feature CLI unavailable")
            case let .launchFailed(message):
                return String(localized: "The provider model operation could not start: \(message)", comment: "Model feature CLI launch error")
            }
        }
    }

    static let shared = MalibuModelCLI()
    private let cancellation = ModelCLIProcessCancellation()

    func cancelCurrentOperation() {
        cancellation.cancel()
    }

    func run(
        arguments: [String],
        peer: MalibuModelPeerEvidence? = nil,
        stdinData: Data? = nil,
        priority: ModelCLIWorkPriority = .interactive,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ModelCLIResult {
        let executable = try resolveExecutable(peer: peer)
        let environment = try ProcessEnvironmentSanitizer.sanitized()
        let cancellation = self.cancellation
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: priority.dispatchQoS).async {
                let process = Process()
                cancellation.install(process)
                defer { cancellation.clear(process) }
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = stdinData == nil ? nil : Pipe()
                let stdout = ModelCLIOutputBuffer()
                let stderr = ModelCLIOutputBuffer()
                let stdoutLines = ModelCLIOutputLineBuffer()
                let deliveries = DispatchGroup()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = stdinPipe

                func consume(
                    _ pipe: Pipe,
                    into buffer: ModelCLIOutputBuffer,
                    deliverLines: Bool
                ) {
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        let text = String(decoding: data, as: UTF8.self)
                        buffer.append(text)
                        if deliverLines {
                            for value in stdoutLines.append(text) {
                                deliveries.enter()
                                Task { @MainActor in
                                    defer { deliveries.leave() }
                                    onLine(value)
                                }
                            }
                        }
                    }
                }
                consume(stdoutPipe, into: stdout, deliverLines: true)
                consume(stderrPipe, into: stderr, deliverLines: false)

                do {
                    try process.run()
                    if let stdinData, let stdinPipe {
                        stdinPipe.fileHandleForWriting.write(stdinData)
                        stdinPipe.fileHandleForWriting.closeFile()
                    }
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: Error.launchFailed(error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !stdoutTail.isEmpty { stdout.append(String(decoding: stdoutTail, as: UTF8.self)) }
                if !stderrTail.isEmpty { stderr.append(String(decoding: stderrTail, as: UTF8.self)) }
                for value in stdoutLines.append(String(decoding: stdoutTail, as: UTF8.self)) + stdoutLines.flush() {
                    deliveries.enter()
                    Task { @MainActor in
                        defer { deliveries.leave() }
                        onLine(value)
                    }
                }
                deliveries.wait()
                continuation.resume(returning: ModelCLIResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout.read(),
                    stderr: stderr.read()
                ))
            }
        }
    }

    func resolveExecutable(
        peer: MalibuModelPeerEvidence? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) throws -> URL {
        if let peer {
            guard peer.contractCompatible,
                  peer.lifecycleOwner == "macprovider_cli",
                  peer.serviceInstanceID != nil,
                  peer.isFresh(),
                  let binaryVersion = peer.binaryVersion,
                  ProviderCLIVersion.strictNormalize(binaryVersion) != nil
            else { throw Error.executableUnavailable }
        }
        #if DEBUG
        if let override = environment["MALIBU_CLI_PATH"],
           !override.isEmpty,
           InstalledProviderMonitor.isOwnerPrivateExecutable(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        #endif

        // A production model operation must use the exact launchd-managed
        // peer whose status evidence enabled the action.
        if let peer {
            guard let launchdPath = launchdProgramPath(),
                  InstalledProviderMonitor.isOwnerPrivateExecutable(atPath: launchdPath) else {
                throw Error.executableUnavailable
            }
            let url = URL(fileURLWithPath: launchdPath)
            guard Self.isSignedProviderCLI(at: url, runningPID: peer.servicePID) else {
                throw Error.executableUnavailable
            }
            return url
        }
        let configured = InstalledProviderMonitor.configuredProviderProgram()
        if InstalledProviderMonitor.isOwnerPrivateExecutable(atPath: configured.path),
           Self.isSignedProviderCLI(at: configured, runningPID: nil) {
            return configured
        }
        let bundled = bundleURL.appendingPathComponent("Contents/MacOS/macprovider-cli")
        if InstalledProviderMonitor.isOwnerPrivateExecutable(atPath: bundled.path),
           Self.isSignedProviderCLI(at: bundled, runningPID: nil) {
            return bundled
        }
        throw Error.executableUnavailable
    }

    private static func isSignedProviderCLI(at url: URL, runningPID: Int?) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        let requirementText = "identifier \"live.malibu.provider.cli\" and anchor apple generic and certificate leaf[subject.OU] = \"YF7XNRJUG4\""
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return false }

        guard let runningPID else { return true }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: runningPID)] as CFDictionary
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &runningCode) == errSecSuccess,
              let runningCode else { return false }
        var runningStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(runningCode, [], &runningStaticCode) == errSecSuccess,
              let runningStaticCode else { return false }
        var expectedInfo: CFDictionary?
        var runningInfo: CFDictionary?
        let signingFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, signingFlags, &expectedInfo) == errSecSuccess,
              SecCodeCopySigningInformation(runningStaticCode, signingFlags, &runningInfo) == errSecSuccess,
              let expectedHash = (expectedInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let runningHash = (runningInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            return false
        }
        return expectedHash == runningHash
    }

    private func launchdProgramPath() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "print",
            "gui/\(getuid())/\(InstalledProviderMonitor.providerLaunchdLabel)"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readData(ofLength: 64 * 1024)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return InstalledProviderMonitor.parseLaunchdServiceProgramPath(
                String(decoding: data, as: UTF8.self)
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Power and local state

enum MalibuPowerState: Equatable, Sendable {
    case external
    case battery
    case unknown

    var label: String {
        switch self {
        case .external: return String(localized: "On external power", comment: "Power state")
        case .battery: return String(localized: "On battery", comment: "Power state")
        case .unknown: return String(localized: "Power state unavailable", comment: "Power state")
        }
    }
}

struct MalibuPowerSample: Equatable, Sendable {
    let state: MalibuPowerState
    let observedAt: Date
}

struct MalibuPowerMonitor: Sendable {
    private let provider: @Sendable () -> MalibuPowerSample

    init(provider: @escaping @Sendable () -> MalibuPowerSample = { MalibuPowerMonitor.readSample() }) {
        self.provider = provider
    }

    func sample() -> MalibuPowerSample {
        provider()
    }

    private static func readSample() -> MalibuPowerSample {
        let now = Date()
        func result(_ state: MalibuPowerState) -> MalibuPowerSample {
            MalibuPowerSample(state: state, observedAt: now)
        }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return result(.unknown) }
        if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            if type == kIOPMBatteryPowerKey { return result(.battery) }
            if type == kIOPMACPowerKey || type == kIOPMUPSPowerKey { return result(.external) }
        }
        return result(.unknown)
    }
}

struct ModelActivityEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let operation: String
    let fromModelID: String?
    let toModelID: String
    let outcome: String
    let reason: String?
}

private struct ModelManagementPersistedState: Codable {
    var previousModelID: String?
    var previousModelAt: Date?
    var history: [ModelActivityEntry]
    var backgroundRecommendationsEnabled: Bool
    var recommendationSchedule: MalibuRecommendationSchedule?
}

// MARK: - App state and actions

@MainActor
final class ModelManagementStore: ObservableObject {
    static let shared = ModelManagementStore()

    enum ListState: Equatable {
        case checking
        case ready
        case viewOnly
        case unavailable
    }

    enum Operation: Equatable {
        case idle
        case loadingList
        case switching(target: String, phase: String, elapsedMS: Int)
        case reconciling(target: String)
        case runtimeConflict(expected: String, observed: String?)
        case cooldown(target: String, secondsRemaining: Int)
        case checkingRecommendation(phase: String)
        case adoptingRecommendation(target: String, phase: String)
        case failed(String)

        var blocksRefresh: Bool {
            switch self {
            case .loadingList, .switching, .reconciling, .runtimeConflict,
                 .checkingRecommendation, .adoptingRecommendation:
                return true
            case .idle, .cooldown, .failed:
                return false
            }
        }
    }

    private struct PendingSwitch: Equatable {
        let operationName: String
        let fromModelID: String?
        let targetModelID: String
    }

    @Published private(set) var rows: [MalibuModelRow] = []
    @Published private(set) var currentModelID: String?
    @Published private(set) var listState: ListState = .checking
    @Published private(set) var operation: Operation = .idle
    @Published private(set) var cooldownSecondsRemaining: Int? = nil
    @Published private(set) var peerObservationFresh = false
    @Published private(set) var statusLine = String(localized: "Checking model controls…", comment: "Model activity status")
    @Published private(set) var recommendationLine: String?
    @Published private(set) var recommendation: MalibuRecommendationDocument?
    @Published private(set) var previousModelID: String?
    @Published private(set) var history: [ModelActivityEntry] = []
    @Published private(set) var backgroundRecommendationsEnabled: Bool

    private let cli: any MalibuModelCLIRunning
    private let paths: ProviderPaths
    private let defaults: UserDefaults
    private let powerMonitor: MalibuPowerMonitor
    private var previousModelAt: Date?
    private var peerEvidence = MalibuModelPeerEvidence.unavailable
    private var peerLeaseTask: Task<Void, Never>?
    private var activeSwitchTransactionID: String?
    private var terminalSwitchTransactionID: String?
    private var observedTerminalLoaded = false
    private var pendingSwitch: PendingSwitch?
    private var switchWatchdogTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?
    private var lastSwitchEventReason: String?
    private var recommendationSchedule = MalibuRecommendationSchedule()
    private var recommendationJSON: Data?
    private var backgroundCheckSafetyCancelled = false

    init(
        cli: any MalibuModelCLIRunning = MalibuModelCLI.shared,
        paths: ProviderPaths = .current,
        defaults: UserDefaults = .standard,
        powerMonitor: MalibuPowerMonitor = MalibuPowerMonitor()
    ) {
        self.cli = cli
        self.paths = paths
        self.defaults = defaults
        self.powerMonitor = powerMonitor
        if let data = defaults.data(forKey: "malibu.model-management.state"),
           let persisted = try? JSONDecoder().decode(ModelManagementPersistedState.self, from: data) {
            previousModelID = persisted.previousModelID
            previousModelAt = persisted.previousModelAt
            history = Array(persisted.history.suffix(20))
            backgroundRecommendationsEnabled = persisted.backgroundRecommendationsEnabled
            recommendationSchedule = persisted.recommendationSchedule ?? MalibuRecommendationSchedule()
        } else {
            backgroundRecommendationsEnabled = true
        }
    }

    var recommendationCapabilityAvailable: Bool {
        MalibuModelCapabilityManifest.checkedIn.supports(
            MalibuModelCapabilityManifest.recommendationCheck,
            peer: peerEvidence
        )
    }

    var recommendationAdoptionCapabilityAvailable: Bool {
        MalibuModelCapabilityManifest.checkedIn.supports(
            MalibuModelCapabilityManifest.recommendationAdoption,
            peer: peerEvidence
        )
    }

    var canAdoptRecommendation: Bool {
        guard let target = recommendation?.recommendedModel,
              !Self.recommendationTargetIsCurrent(target, currentModelID: currentModelID),
              Self.recommendationTargetIsReadyForAdoption(
                  target,
                  listState: listState,
                  rows: rows
              ),
              recommendation?.isActionable == true,
              recommendationJSON != nil,
              recommendationAdoptionCapabilityAvailable,
              peerObservationFresh,
              peerEvidence.isFresh(),
              operation == .idle else { return false }
        return true
    }

    var recommendationAdoptionUnavailableReason: String? {
        guard let recommendation, let target = recommendation.recommendedModel else { return nil }
        if let advisoryReason = recommendation.adoptionAdvisoryReason {
            return advisoryReason
        }
        if Self.recommendationTargetIsCurrent(target, currentModelID: currentModelID) {
            return String(localized: "This recommended model is already active.", comment: "Recommendation already active")
        }
        if recommendationJSON == nil {
            return String(localized: "Recommendation evidence is unavailable. Run the check again before adopting.", comment: "Recommendation evidence unavailable")
        }
        if !recommendationAdoptionCapabilityAvailable {
            return String(localized: "Adoption requires a compatible provider update; the recommendation remains advisory.", comment: "Adoption capability unavailable")
        }
        if !peerObservationFresh || !peerEvidence.isFresh() {
            return String(localized: "Waiting for fresh provider status before adoption.", comment: "Recommendation waiting for provider status")
        }
        if listState != .ready {
            return String(localized: "Provider model controls are view-only, so this recommendation cannot be adopted right now.", comment: "Recommendation blocked by view-only model controls")
        }
        if !Self.recommendationTargetIsReadyForAdoption(target, listState: listState, rows: rows) {
            return String(localized: "The recommended model is no longer ready for a live switch. Run the check again.", comment: "Recommendation target no longer actionable")
        }
        if operation != .idle {
            return String(localized: "Finish the current model action before adopting this recommendation.", comment: "Recommendation blocked by active model action")
        }
        return nil
    }

    var recommendationStatus: String {
        if !recommendationCapabilityAvailable {
            return String(localized: "Background recommendations require a provider update. Manual model switching remains available.", comment: "Recommendation capability unavailable")
        }
        return recommendationLine ?? String(localized: "Background recommendation checks are ready.", comment: "Recommendation status")
    }

    nonisolated static func recommendationTargetIsCurrent(
        _ target: String,
        currentModelID: String?
    ) -> Bool {
        guard let currentModelID else { return false }
        return modelIdentityKey(target) == modelIdentityKey(currentModelID)
    }

    nonisolated static func recommendationTargetIsReadyForAdoption(
        _ target: String,
        listState: ListState,
        rows: [MalibuModelRow]
    ) -> Bool {
        guard listState == .ready else { return false }
        let targetKey = modelIdentityKey(target)
        return rows.contains { row in
            modelIdentityKey(row.id) == targetKey
                && row.weightsPresentLocally
                && row.action == .switchModel
        }
    }

    func setBackgroundRecommendationsEnabled(_ enabled: Bool) {
        backgroundRecommendationsEnabled = enabled
        saveState()
        recommendationLine = enabled
            ? String(localized: "Background recommendations enabled.", comment: "Recommendation preference enabled")
            : String(localized: "Background recommendations stopped. Manual model switching remains available.", comment: "Recommendation preference disabled")
    }

    func snoozeRecommendation() {
        if let identity = recommendation?.identity(currentModelID: currentModelID) {
            recommendationSchedule.snooze(identity: identity, at: Date())
        }
        recommendation = nil
        recommendationJSON = nil
        recommendationLine = String(localized: "Recommendation hidden for 24 hours.", comment: "Recommendation snoozed")
        saveState()
    }

    func stopBackgroundRecommendations() {
        setBackgroundRecommendationsEnabled(false)
        recommendation = nil
        recommendationJSON = nil
    }

    var readySwitchCapabilityAvailable: Bool {
        MalibuModelCapabilityManifest.checkedIn.supports(
            MalibuModelCapabilityManifest.readySwitch,
            peer: peerEvidence
        )
    }

    var canPerformModelAction: Bool {
        guard readySwitchCapabilityAvailable, peerObservationFresh, peerEvidence.isFresh() else { return false }
        if let cooldownUntil { return cooldownUntil <= Date() }
        return listState == .ready && operation == .idle
    }

    var canRevert: Bool {
        guard let previousModelID,
              let row = rows.first(where: { modelIdentityKey($0.id) == modelIdentityKey(previousModelID) }),
              row.action == .switchModel else { return false }
        return canPerformModelAction
    }

    var revertUnavailableReason: String? {
        guard let previousModelID else { return nil }
        guard let row = rows.first(where: { modelIdentityKey($0.id) == modelIdentityKey(previousModelID) }) else {
            return String(localized: "Revert unavailable: model no longer supported or listed.", comment: "Revert guard")
        }
        guard row.action == .switchModel else {
            return String(localized: "Revert unavailable: the previous model is not currently eligible for a live switch.", comment: "Revert eligibility guard")
        }
        if let seconds = cooldownSecondsRemaining, seconds > 0 {
            return String(localized: "Revert unavailable for \(seconds) seconds while the provider cooldown expires.", comment: "Revert cooldown guard")
        }
        guard readySwitchCapabilityAvailable else {
            return String(localized: "Revert unavailable: this provider does not advertise compatible model switching.", comment: "Revert capability guard")
        }
        guard peerObservationFresh, peerEvidence.isFresh() else {
            return String(localized: "Revert unavailable: provider status is stale. Refresh before switching models.", comment: "Revert stale-status guard")
        }
        guard listState == .ready else {
            return String(localized: "Revert unavailable while the provider model list is unavailable.", comment: "Revert list guard")
        }
        guard operation == .idle else {
            return String(localized: "Revert unavailable while another model operation is in progress.", comment: "Revert operation guard")
        }
        return nil
    }

    private var cooldownUntil: Date?

    func refresh(
        currentModelID: String?,
        peer: MalibuModelPeerEvidence = .unavailable
    ) async {
        updatePeerEvidence(peer)
        if let pendingSwitch {
            switch operation {
            case .reconciling:
                if peerObservationFresh,
                   Self.recommendationTargetIsCurrent(
                       pendingSwitch.targetModelID,
                       currentModelID: currentModelID
                   ) {
                    commitSuccessfulSwitch(pendingSwitch)
                    return
                } else if peerObservationFresh, let currentModelID {
                    self.currentModelID = currentModelID
                    operation = .runtimeConflict(expected: pendingSwitch.targetModelID, observed: currentModelID)
                    statusLine = String(localized: "Runtime state conflict. The provider reports \(currentModelID), not \(pendingSwitch.targetModelID). New model actions remain disabled until the runtime state is reconciled.", comment: "Model runtime conflict")
                } else {
                    statusLine = String(localized: "Reconciling runtime state… New model actions remain disabled until the provider confirms the loaded model.", comment: "Model runtime reconciliation")
                }
                return
            case .runtimeConflict:
                if peerObservationFresh,
                   Self.recommendationTargetIsCurrent(
                       pendingSwitch.targetModelID,
                       currentModelID: currentModelID
                   ) {
                    commitSuccessfulSwitch(pendingSwitch)
                }
                return
            case .switching:
                statusLine = String(localized: "A model switch is in progress. New actions remain disabled until the provider confirms the result.", comment: "Model switch refresh guard")
                return
            default:
                break
            }
        } else if case .switching = operation {
            statusLine = String(localized: "A model switch is in progress. New actions remain disabled until the provider confirms the result.", comment: "Model switch refresh guard")
            return
        }
        if operation.blocksRefresh {
            // Status observations may arrive while a CLI subprocess owns the
            // recommendation/adoption protocol. Preserve that operation until
            // its typed terminal frame is consumed.
            return
        }
        let configuredModel = currentModelID ?? ProviderConfig.readModel(paths: paths)
        self.currentModelID = configuredModel
        guard readySwitchCapabilityAvailable,
              MalibuModelCapabilityManifest.checkedIn.supports(
                MalibuModelCapabilityManifest.catalogJSON,
                peer: peer
              ) else {
            listState = .viewOnly
            operation = .idle
            statusLine = configuredModel == nil
                ? String(localized: "Model controls require a fresh compatible provider update. The current model remains view-only.", comment: "Model capability gate")
                : String(localized: "Configured model: \(configuredModel ?? "unknown"). Live switching is unavailable until the provider is running with warm swap.", comment: "Configured model capability gate")
            return
        }
        listState = .checking
        operation = .loadingList
        do {
            let result = try await cli.run(
                arguments: [
                    "models", "list", "--json",
                    "--config", paths.configFile.path,
                    "--ctl-socket-path", paths.controlSocket.path,
                ],
                peer: peerEvidence,
                onLine: { _ in }
            )
            guard result.exitCode == 0 else { throw ModelManagementError.invalidCatalog }
            let document = try decodeList(result.stdout).validated()
            self.currentModelID = document.currentModelID ?? configuredModel
            self.rows = document.rows.map { MalibuModelRow(row: $0, currentModelID: self.currentModelID, warmSwapAvailable: document.warmSwapAvailable) }
            self.listState = document.warmSwapAvailable ? .ready : .viewOnly
            self.statusLine = document.warmSwapAvailable
                ? String(localized: "Model controls ready.", comment: "Model activity status")
                : String(localized: "Provider is not running with warm swap; model controls are view-only.", comment: "Model activity status")
            self.operation = .idle
        } catch {
            self.listState = .unavailable
            self.operation = .failed(error.localizedDescription)
            self.statusLine = String(localized: "Model controls unavailable. The current model remains visible from provider status.", comment: "Model activity status")
        }
    }

    func switchTo(_ row: MalibuModelRow, operationName: String = "switch") async {
        guard row.action == .switchModel, canPerformModelAction else { return }
        let from = currentModelID
        activeSwitchTransactionID = nil
        terminalSwitchTransactionID = nil
        observedTerminalLoaded = false
        pendingSwitch = nil
        cooldownUntil = nil
        cooldownTask?.cancel()
        operation = .switching(target: row.id, phase: "requested", elapsedMS: 0)
        lastSwitchEventReason = nil
        startSwitchWatchdog()
        let result: ModelCLIResult
        do {
            result = try await cli.run(
                arguments: [
                    "models", "switch", row.id, "--json",
                    "--config", paths.configFile.path,
                    "--ctl-socket-path", paths.controlSocket.path,
                ],
                peer: peerEvidence,
                onLine: { [weak self] line in
                    self?.consumeSwitchEvent(line, target: row.id)
                }
            )
        } catch {
            cancelSwitchWatchdog()
            recordFailure(operation: operationName, from: from, to: row.id, reason: safeOperationError(error))
            return
        }
        cancelSwitchWatchdog()
        guard result.exitCode == 0,
              observedTerminalLoaded,
              case .switching(_, let phase, _) = operation,
              phase == "loaded" else {
            let reason = operationFailureReason(from: result)
            recordFailure(operation: operationName, from: from, to: row.id, reason: reason)
            return
        }
        pendingSwitch = PendingSwitch(operationName: operationName, fromModelID: from, targetModelID: row.id)
        operation = .reconciling(target: row.id)
        statusLine = String(localized: "Reconciling runtime state… New model actions remain disabled until the provider confirms the loaded model.", comment: "Model runtime reconciliation")
    }

    func revert() async {
        guard let previousModelID,
              let row = rows.first(where: { modelIdentityKey($0.id) == modelIdentityKey(previousModelID) }) else {
            statusLine = String(localized: "Revert unavailable: the previous model is no longer supported or listed.", comment: "Revert guard")
            return
        }
        guard canRevert else {
            statusLine = String(localized: "Revert unavailable: the previous model is not currently eligible for a live switch.", comment: "Revert eligibility guard")
            return
        }
        await switchTo(row, operationName: "revert")
    }

    private func updatePeerEvidence(_ peer: MalibuModelPeerEvidence) {
        peerEvidence = peer
        peerObservationFresh = peer.isFresh()
        peerLeaseTask?.cancel()
        guard peerObservationFresh,
              let observedAt = peer.observedAt,
              let validForMS = peer.observationValidForMS else { return }
        let expiry = observedAt.addingTimeInterval(TimeInterval(validForMS) / 1_000)
        let delay = max(0, expiry.timeIntervalSinceNow)
        peerLeaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.peerEvidence.observedAt == observedAt else { return }
            self.peerObservationFresh = false
            if self.operation == .idle, self.listState == .ready {
                self.statusLine = String(localized: "Provider status is stale. Refresh the provider before switching models.", comment: "Stale model peer status")
            }
        }
    }

    private func commitSuccessfulSwitch(_ pending: PendingSwitch) {
        pendingSwitch = nil
        currentModelID = pending.targetModelID
        previousModelID = pending.fromModelID
        previousModelAt = Date()
        statusLine = pending.operationName == "revert"
            ? String(localized: "Model reverted successfully.", comment: "Model activity status")
            : String(localized: "Model switched successfully.", comment: "Model activity status")
        operation = .idle
        appendHistory(ModelActivityEntry(
            id: UUID(),
            timestamp: Date(),
            operation: pending.operationName,
            fromModelID: pending.fromModelID,
            toModelID: pending.targetModelID,
            outcome: "success",
            reason: nil
        ))
        rows = rows.map { $0.reclassified(currentModelID: currentModelID, warmSwapAvailable: true) }
        saveState()
    }

    func startBackgroundCheckIfEligible(thermalState: MalibuThermalState?) async {
        guard backgroundRecommendationsEnabled else {
            recommendationLine = String(localized: "Skipped: background recommendations are stopped in Settings.", comment: "Recommendation skip reason")
            return
        }
        guard recommendationCapabilityAvailable else {
            recommendationLine = recommendationStatus
            return
        }
        guard operation == .idle else {
            recommendationLine = String(localized: "Skipped: another model operation is active.", comment: "Recommendation skip reason")
            return
        }
        guard recommendation == nil else { return }
        let now = Date()
        guard recommendationSchedule.isEligible(at: now) else {
            if let next = [recommendationSchedule.nextEligibleAt, recommendationSchedule.snoozedUntil]
                .compactMap({ $0 }).max() {
                recommendationLine = String(localized: "Next background recommendation check after \(next.formatted(date: .abbreviated, time: .shortened)).", comment: "Recommendation next check")
            }
            return
        }
        let power = powerMonitor.sample()
        guard Self.backgroundSafetyAllows(power: power, thermalState: thermalState, now: now) else {
            let powerAge = now.timeIntervalSince(power.observedAt)
            let powerSafe = power.state == .external && powerAge >= 0 && powerAge <= 10
            recommendationLine = powerSafe
                ? String(localized: "Skipped: thermal pressure is too high for a background check.", comment: "Recommendation skip reason")
                : String(localized: "Skipped: background recommendations require external power.", comment: "Recommendation skip reason")
            return
        }
        operation = .checkingRecommendation(phase: "planning")
        backgroundCheckSafetyCancelled = false
        recommendationLine = String(localized: "Checking installed models for a recommendation…", comment: "Recommendation check status")
        var transcript = MalibuRecommendationCheckTranscript()
        var invalidFrame = false
        var document: MalibuRecommendationDocument?
        var documentData: Data?
        let safetyTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                guard case .checkingRecommendation = self.operation else { return }
                let power = self.powerMonitor.sample()
                let thermal = MalibuThermalState(processInfoState: ProcessInfo.processInfo.thermalState)
                let powerSafe = power.state == .external
                    && power.observedAt.timeIntervalSinceNow <= 0
                    && Date().timeIntervalSince(power.observedAt) <= 10
                guard powerSafe, thermal == .nominal || thermal == .fair else {
                    self.backgroundCheckSafetyCancelled = true
                    self.cli.cancelCurrentOperation()
                    return
                }
            }
        }
        defer { safetyTask.cancel() }
        do {
            let result = try await cli.run(
                arguments: Self.backgroundRecommendationArguments(
                    configURL: paths.configFile,
                    isolatedCacheRoot: paths.appSupport.appendingPathComponent("RecommendationChecks", isDirectory: true)
                ),
                peer: peerEvidence,
                priority: .background,
                onLine: { [weak self] line in
                    guard let self, let data = line.data(using: .utf8) else { return }
                    if let event = try? JSONDecoder().decode(MalibuRecommendationCheckEvent.self, from: data) {
                        do {
                            if event.type == "completed", document == nil {
                                throw MalibuRecommendationError.invalidCheckEvent
                            }
                            try transcript.consume(event)
                            let checked = try event.validatedForBackground()
                            if let phase = checked.phase {
                                self.operation = .checkingRecommendation(phase: phase)
                                self.recommendationLine = self.localizedRecommendationCheckPhase(phase)
                            }
                        } catch {
                            invalidFrame = true
                        }
                        return
                    }
                    if let decoded = try? JSONDecoder().decode(MalibuRecommendationDocument.self, from: data) {
                        do {
                            guard document == nil, transcript.terminalType == nil else {
                                throw MalibuRecommendationError.invalidCheckEvent
                            }
                            document = try decoded.validated()
                            documentData = data
                        } catch {
                            invalidFrame = true
                        }
                        return
                    }
                    invalidFrame = true
                }
            )
            guard result.exitCode == 0,
                  transcript.terminalType == "completed",
                  !invalidFrame,
                  !backgroundCheckSafetyCancelled,
                  let document else {
                throw MalibuRecommendationError.invalidDocument
            }
            recommendationSchedule.recordSuccess(at: now)
            if let target = document.recommendedModel,
               !Self.recommendationTargetIsCurrent(target, currentModelID: currentModelID),
               rows.contains(where: { modelIdentityKey($0.id) == modelIdentityKey(target) && $0.weightsPresentLocally }),
               let identity = document.identity(currentModelID: currentModelID),
               !recommendationSchedule.suppresses(identity: identity, at: now) {
                recommendation = document
                recommendationJSON = documentData
                // Recommendation payloads intentionally remain in memory. Recheck after an
                // app restart instead of suppressing the prompt for a day with no restorable card.
                recommendationSchedule.nextEligibleAt = nil
                recommendationLine = String(localized: "Recommended installed model: \(target)", comment: "Recommendation available")
                MalibuAccessibility.announce(String(localized: "A new installed model recommendation is available for \(target).", comment: "Recommendation VoiceOver announcement"))
            } else {
                recommendation = document.hasVisibleWhyNotFeedback ? document : nil
                recommendationJSON = nil
                if let identity = document.identity(currentModelID: currentModelID),
                   recommendationSchedule.suppresses(identity: identity, at: now) {
                    recommendationLine = String(localized: "The current recommendation is hidden until its inputs change or the 24-hour snooze ends.", comment: "Recommendation identity snoozed")
                } else if document.hasVisibleWhyNotFeedback {
                    recommendationLine = String(localized: "Checked installed models; no installed model is recommended right now.", comment: "No recommendation with explanation result")
                } else {
                    recommendationLine = String(localized: "Checked installed models; no new recommendation is available.", comment: "No recommendation result")
                }
            }
            operation = .idle
            saveState()
        } catch {
            if backgroundCheckSafetyCancelled {
                recommendationSchedule.nextEligibleAt = now.addingTimeInterval(60 * 60)
                recommendation = nil
                recommendationJSON = nil
                operation = .idle
                recommendationLine = String(localized: "Recommendation check deferred because power or thermal conditions changed.", comment: "Recommendation safety deferral")
                saveState()
                return
            }
            recommendationSchedule.recordFailure(at: now)
            recommendation = nil
            recommendationJSON = nil
            operation = .idle
            if let next = recommendationSchedule.nextEligibleAt {
                recommendationLine = String(localized: "Recommendation check failed. Malibu will retry after \(next.formatted(date: .abbreviated, time: .shortened)).", comment: "Recommendation retry status")
            } else {
                recommendationLine = String(localized: "Recommendation check failed.", comment: "Recommendation failure status")
            }
            saveState()
        }
    }

    static func backgroundRecommendationArguments(configURL: URL, isolatedCacheRoot: URL) -> [String] {
        [
            "autotune", "--recommend", "--json", "--check-only", "--progress-json",
            "--installed-only", "--isolated-cache-root", isolatedCacheRoot.path,
            "--no-submit-hardware-evidence", "--config", configURL.path,
        ]
    }

    nonisolated static func backgroundSafetyAllows(
        power: MalibuPowerSample,
        thermalState: MalibuThermalState?,
        now: Date
    ) -> Bool {
        let powerAge = now.timeIntervalSince(power.observedAt)
        return power.state == .external
            && powerAge >= 0
            && powerAge <= 10
            && (thermalState == .nominal || thermalState == .fair)
    }

    func adoptRecommendation() async {
        guard canAdoptRecommendation,
              let recommendation,
              let target = recommendation.recommendedModel,
              let recommendationJSON else { return }
        let from = currentModelID
        var transcript = MalibuModelAdoptionTranscript()
        var invalidFrame = false
        operation = .adoptingRecommendation(target: target, phase: "validating")
        statusLine = String(localized: "Validating recommendation…", comment: "Adoption progress")
        do {
            let result = try await cli.run(
                arguments: [
                    "models", "adopt-recommendation", "--json",
                    "--recommendation-json", "-",
                    "--config", paths.configFile.path,
                    "--ctl-socket-path", paths.controlSocket.path,
                ],
                peer: peerEvidence,
                stdinData: recommendationJSON + Data("\n".utf8),
                priority: .interactive,
                onLine: { [weak self] line in
                    guard let self, let data = line.data(using: .utf8) else {
                        invalidFrame = true
                        return
                    }
                    do {
                        let decoded = try JSONDecoder().decode(MalibuModelAdoptionEvent.self, from: data)
                        try transcript.consume(decoded, target: target)
                        if let phase = decoded.phase {
                            self.operation = .adoptingRecommendation(target: target, phase: phase)
                            self.statusLine = self.localizedAdoptionPhase(phase, rollbackState: decoded.rollbackState)
                            MalibuAccessibility.announce(self.statusLine)
                        }
                    } catch {
                        invalidFrame = true
                    }
                }
            )
            guard result.exitCode == 0,
                  !invalidFrame,
                  transcript.terminalEvent?.type == "completed" else {
                let rollback = transcript.terminalEvent?.rollbackState
                let reason: String
                switch rollback {
                case "rollback_failed":
                    reason = String(localized: "Adoption reached the provider, but configuration recovery needs repair. The recommended model may already be active; Malibu will refresh live status before more model actions.", comment: "Adoption rollback failure")
                case "rolled_back":
                    reason = String(localized: "Recommendation adoption failed; provider configuration was rolled back.", comment: "Adoption rolled back")
                default:
                    reason = String(localized: "Recommendation adoption could not be verified. The provider's current model remains visible.", comment: "Adoption unverified")
                }
                recordFailure(operation: "adopt", from: from, to: target, reason: reason)
                return
            }
            pendingSwitch = PendingSwitch(operationName: "adopt", fromModelID: from, targetModelID: target)
            self.recommendation = nil
            self.recommendationJSON = nil
            operation = .reconciling(target: target)
            statusLine = String(localized: "Recommendation adopted. Confirming the live model…", comment: "Adoption reconciliation")
            saveState()
        } catch {
            recordFailure(operation: "adopt", from: from, to: target, reason: safeOperationError(error))
        }
    }

    private func localizedRecommendationCheckPhase(_ phase: String) -> String {
        switch phase {
        case "benchmarking": return String(localized: "Benchmarking installed models…", comment: "Recommendation progress")
        case "preparing": return String(localized: "Preparing installed model checks…", comment: "Recommendation progress")
        default: return String(localized: "Checking installed models for a recommendation…", comment: "Recommendation progress")
        }
    }

    private func localizedAdoptionPhase(_ phase: String, rollbackState: String?) -> String {
        if rollbackState == "rollback_failed" {
            return String(localized: "Configuration recovery needs repair. The recommended model may already be active; refreshing live status…", comment: "Adoption rollback failure")
        }
        switch phase {
        case "config_backup": return String(localized: "Backing up provider configuration…", comment: "Adoption progress")
        case "config_apply": return String(localized: "Applying recommendation…", comment: "Adoption progress")
        case "switch_loading": return String(localized: "Loading recommended model…", comment: "Adoption progress")
        case "switch_draining": return String(localized: "Finishing current request…", comment: "Adoption progress")
        case "config_verify": return String(localized: "Verifying model and configuration…", comment: "Adoption progress")
        case "rollback": return String(localized: "Restoring previous provider configuration…", comment: "Adoption progress")
        case "completed": return String(localized: "Recommendation adopted.", comment: "Adoption completed")
        default: return String(localized: "Validating recommendation…", comment: "Adoption progress")
        }
    }

    private func consumeSwitchEvent(_ line: String, target: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(MalibuModelSwitchEvent.self, from: data),
              event.schemaVersion == "model_switch_event.v1",
              UUID(uuidString: event.transactionID) != nil,
              isSafeModelID(event.targetModelID),
              event.targetModelID == target,
              event.elapsedMS >= 0,
              event.cancellable == false,
              event.cooldownSecondsRemaining == nil || event.cooldownSecondsRemaining! >= 0,
              ["requested", "loading", "draining", "loaded", "failed"].contains(event.phase)
        else { return }

        guard terminalSwitchTransactionID != event.transactionID else { return }

        if event.type == "accepted" {
            guard event.phase == "requested", activeSwitchTransactionID == nil else { return }
            activeSwitchTransactionID = event.transactionID
        } else if event.type == "terminal",
                  event.phase == "failed",
                  activeSwitchTransactionID == nil {
            observedTerminalLoaded = false
            terminalSwitchTransactionID = event.transactionID
        } else {
            guard ["progress", "terminal"].contains(event.type),
                  activeSwitchTransactionID == event.transactionID else { return }
            if event.type == "terminal" {
                guard event.phase == "loaded" || event.phase == "failed" else { return }
                observedTerminalLoaded = event.phase == "loaded"
                terminalSwitchTransactionID = event.transactionID
            }
        }
        if let seconds = event.cooldownSecondsRemaining, seconds > 0 {
            beginCooldown(seconds: seconds)
        }
        if event.phase == "failed" {
            lastSwitchEventReason = event.reason
        }
        touchSwitchWatchdog()
        operation = .switching(target: target, phase: event.phase, elapsedMS: event.elapsedMS)
        switch event.phase {
        case "loading":
            statusLine = String(localized: "Loading target model…", comment: "Model switch progress")
            MalibuAccessibility.announce(statusLine)
        case "draining":
            statusLine = String(localized: "Finishing current request…", comment: "Model switch progress")
            MalibuAccessibility.announce(statusLine)
        case "loaded":
            statusLine = String(localized: "Model switched.", comment: "Model switch progress")
            MalibuAccessibility.announce(statusLine)
        case "failed":
            statusLine = localizedSwitchReason(event.reason)
            MalibuAccessibility.announce(statusLine)
        default:
            break
        }
    }

    private func startSwitchWatchdog() {
        switchWatchdogTask?.cancel()
        switchWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
            guard let self, case .switching = self.operation else { return }
            self.statusLine = String(localized: "Still working; the provider is finishing this switch. You can close this window and continue monitoring.", comment: "Stalled model switch status")
            MalibuAccessibility.announce(self.statusLine)
        }
    }

    private func touchSwitchWatchdog() {
        guard case .switching = operation else { return }
        startSwitchWatchdog()
    }

    private func cancelSwitchWatchdog() {
        switchWatchdogTask?.cancel()
        switchWatchdogTask = nil
    }

    private func beginCooldown(seconds: Int) {
        cooldownTask?.cancel()
        cooldownUntil = Date().addingTimeInterval(TimeInterval(seconds))
        cooldownSecondsRemaining = seconds
        cooldownTask = Task { @MainActor [weak self] in
            while let self, let until = self.cooldownUntil {
                let remaining = max(0, Int(ceil(until.timeIntervalSinceNow)))
                self.cooldownSecondsRemaining = remaining == 0 ? nil : remaining
                if remaining == 0 {
                    self.cooldownUntil = nil
                    if case .cooldown = self.operation {
                        self.operation = .idle
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func decodeList(_ stdout: String) throws -> MalibuModelsListDocument {
        let lines = stdout.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        guard lines.count == 1,
              let data = lines[0].data(using: .utf8) else {
            throw ModelManagementError.invalidCatalog
        }
        return try JSONDecoder().decode(MalibuModelsListDocument.self, from: data)
    }

    private func operationFailureReason(from result: ModelCLIResult) -> String {
        if let lastSwitchEventReason, !lastSwitchEventReason.isEmpty {
            return localizedSwitchReason(lastSwitchEventReason)
        }
        let reason = result.stderr
            .split(whereSeparator: \.isNewline)
            .last.map(String.init)?.lowercased() ?? ""
        if reason.contains("cooldown") { return localizedSwitchReason("cooldown") }
        if reason.contains("already loading") || reason.contains("in progress") {
            return localizedSwitchReason("loading_in_progress")
        }
        if reason.contains("not in --supported") { return localizedSwitchReason("not_in_supported_models") }
        if reason.contains("ram") || reason.contains("fit") { return localizedSwitchReason("ram_unfit") }
        return localizedSwitchReason(nil)
    }

    private func safeOperationError(_ error: Swift.Error) -> String {
        if case MalibuModelCLI.Error.executableUnavailable = error {
            return String(localized: "The managed provider CLI is unavailable. Update or repair provider software to enable model controls.", comment: "Model feature CLI unavailable")
        }
        return String(localized: "The provider model operation could not start.", comment: "Safe model operation launch failure")
    }

    private func localizedSwitchReason(_ code: String?) -> String {
        switch code {
        case "cooldown": return String(localized: "Switch unavailable while the provider cooldown expires.", comment: "Model switch cooldown reason")
        case "loading_in_progress": return String(localized: "Another model switch is already in progress.", comment: "Model switch busy reason")
        case "not_in_supported_models": return String(localized: "The provider does not support this model.", comment: "Model switch unsupported reason")
        case "ram_unfit": return String(localized: "This model does not pass the current memory fit check.", comment: "Model switch memory reason")
        case "fit_unknown": return String(localized: "The provider could not verify this model's memory fit.", comment: "Model switch unknown fit reason")
        case "invalid_ack": return String(localized: "The provider returned an invalid switch response.", comment: "Model switch protocol reason")
        default: return String(localized: "Provider rejected the model switch.", comment: "Model switch failure")
        }
    }

    private func recordFailure(operation operationName: String, from: String?, to: String, reason: String) {
        cancelSwitchWatchdog()
        let safeReason = String(reason.prefix(240))
        if let seconds = cooldownSecondsRemaining, seconds > 0 {
            self.operation = .cooldown(target: to, secondsRemaining: seconds)
            statusLine = String(localized: "Switch unavailable for \(seconds) seconds while the provider cooldown expires.", comment: "Model switch cooldown")
        } else {
            self.operation = .failed(safeReason)
            statusLine = safeReason
        }
        appendHistory(ModelActivityEntry(
            id: UUID(),
            timestamp: Date(),
            operation: operationName,
            fromModelID: from,
            toModelID: to,
            outcome: "failed",
            reason: safeReason
        ))
        saveState()
    }

    private func appendHistory(_ entry: ModelActivityEntry) {
        history = Array((history + [entry]).suffix(20))
    }

    private func saveState() {
        let state = ModelManagementPersistedState(
            previousModelID: previousModelID,
            previousModelAt: previousModelAt,
            history: history,
            backgroundRecommendationsEnabled: backgroundRecommendationsEnabled,
            recommendationSchedule: recommendationSchedule
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: "malibu.model-management.state")
        }
    }
}

private func modelIdentityKey(_ modelID: String) -> String {
    modelID.lowercased(with: nil)
}

enum ModelManagementError: LocalizedError {
    case invalidCatalog

    var errorDescription: String? {
        String(localized: "The provider returned an invalid model catalog. Model actions are disabled until the provider is updated.", comment: "Invalid model catalog")
    }
}

enum MalibuAccessibility {
    @MainActor
    static func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSNumber(value: 90),
            ]
        )
    }
}

struct MalibuModelRow: Identifiable, Equatable, Sendable {
    enum Category: String, Sendable {
        case current
        case ready
        case needsPreparation
        case blocked
    }

    enum Action: Equatable, Sendable {
        case none
        case switchModel
        case evaluate
    }

    let id: String
    let displayID: String
    var category: Category
    let state: String
    let weightsPresentLocally: Bool
    let fit: String
    let estimatedGB: Double?
    var action: Action
    var blockReason: String?

    init(row: MalibuModelsListDocument.Row, currentModelID: String?, warmSwapAvailable: Bool) {
        id = row.actionModelID
        displayID = row.displayID
        state = row.state
        weightsPresentLocally = row.weightsPresentLocally
        fit = row.fit ?? "unknown"
        estimatedGB = row.estimatedGB
        if row.modelID == currentModelID || row.state == "warm" {
            category = .current
            action = .none
            blockReason = nil
        } else if !warmSwapAvailable {
            category = .blocked
            action = .none
            blockReason = String(localized: "Warm swap is unavailable while the provider is offline.", comment: "Model row guard")
        } else if !row.weightsPresentLocally {
            category = .needsPreparation
            action = .evaluate
            blockReason = String(localized: "Weights are not installed locally. Evaluation requires explicit preparation.", comment: "Model row guard")
        } else if row.fit == "fits" {
            category = .ready
            action = .switchModel
            blockReason = nil
        } else {
            category = .blocked
            action = .none
            blockReason = String(localized: "This model does not pass the current memory fit check.", comment: "Model row guard")
        }
    }

    var categoryLabel: String {
        switch category {
        case .current: return String(localized: "Current", comment: "Model category")
        case .ready: return String(localized: "Ready to switch", comment: "Model category")
        case .needsPreparation: return String(localized: "Needs preparation", comment: "Model category")
        case .blocked: return String(localized: "Blocked", comment: "Model category")
        }
    }

    func reclassified(currentModelID: String?, warmSwapAvailable: Bool) -> MalibuModelRow {
        var copy = self
        if currentModelID.map({ modelIdentityKey(id) == modelIdentityKey($0) }) == true {
            copy.category = .current
            copy.action = .none
            copy.blockReason = nil
        } else if !warmSwapAvailable {
            copy.category = .blocked
            copy.action = .none
            copy.blockReason = String(localized: "Warm swap is unavailable while the provider is offline.", comment: "Model row guard")
        } else if !weightsPresentLocally {
            copy.category = .needsPreparation
            copy.action = .evaluate
            copy.blockReason = String(localized: "Weights are not installed locally. Evaluation requires explicit preparation.", comment: "Model row guard")
        } else if fit == "fits" {
            copy.category = .ready
            copy.action = .switchModel
            copy.blockReason = nil
        } else {
            copy.category = .blocked
            copy.action = .none
            copy.blockReason = String(localized: "This model does not pass the current memory fit check.", comment: "Model row guard")
        }
        return copy
    }
}
