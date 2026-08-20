import Darwin
import Foundation

/// Runs the public CLI-track `install.sh` non-interactively from Malibu.app.
/// Option A onboarding: Malibu delegates install/autotune/launchd to the script.
enum CLIInstallRunner {
    enum Error: Swift.Error, LocalizedError {
        case installScriptNotFound
        case compatibilityManifestNotFound
        case invalidPinnedVersion(String)
        case referralFailure(ReferralFailure)
        case repairEvidenceMissing
        case bundledCLINotFound
        case nonZeroExit(Int32)
        case launchFailed(String)

        enum ReferralFailure: Int32, Equatable {
            case required = 20
            case invalid = 21
            case expired = 22
            case revoked = 23
            case exhausted = 24
            case conflict = 25
            case rateLimited = 26
            case unavailable = 27

            var message: String {
                switch self {
                case .required: return "A referral code is required to join right now. Enter an invite and retry."
                case .invalid: return "This referral code is invalid. Check the code or invite link and retry."
                case .expired: return "This referral code has expired. Ask the sender for a current invite."
                case .revoked: return "This referral code was revoked. Ask the sender for a different invite."
                case .exhausted: return "This referral code has no redemptions left. Ask the sender for a different invite."
                case .conflict: return "This provider identity is already bound to a different referral attempt. Retry the original invite or contact support."
                case .rateLimited: return "Too many referral attempts were submitted. Wait before retrying."
                case .unavailable: return "Invite setup is temporarily unavailable. Your provider identity is preserved; retry later."
                }
            }
        }

        var errorDescription: String? {
            switch self {
            case .installScriptNotFound:
                return "The bundled macprovider installer script was not found."
            case .compatibilityManifestNotFound:
                return "The signed provider compatibility manifest was not found."
            case let .invalidPinnedVersion(version):
                return "Provider install version pin is invalid: \(version)."
            case let .referralFailure(failure):
                return failure.message
            case .repairEvidenceMissing:
                return "Provider software could not be verified for repair. Your provider identity was not changed."
            case .bundledCLINotFound:
                return "Provider software for repair was not found in Malibu. Your provider identity was not changed."
            case let .nonZeroExit(code):
                return "Provider install failed (exit \(code)). See the log above for details."
            case let .launchFailed(message):
                return "Could not start the provider installer: \(message)"
            }
        }
    }

    /// Maps installer exits. Repair must never reuse the missing-invite copy:
    /// exit 20 during `MACPROVIDER_REPAIR_EXISTING_INSTALL=1` is missing
    /// trusted incumbent evidence, not a new-join referral requirement.
    static func classifiedInstallError(
        exitCode: Int32,
        repairExistingInstall: Bool
    ) -> Error? {
        if exitCode == 0 {
            return nil
        }
        if repairExistingInstall, exitCode == 20 || exitCode == 28 {
            return Error.repairEvidenceMissing
        }
        if let failure = Error.ReferralFailure(rawValue: exitCode) {
            return Error.referralFailure(failure)
        }
        return Error.nonZeroExit(exitCode)
    }

    /// Repair must install the bundled provider/watchdog, not GitHub "latest"
    /// (currently 1.8.102) or coordinator advertisement. Fresh joins stay
    /// unpinned so they follow signed release discovery.
    static func resolvedPinnedVersion(
        pinnedVersion: String?,
        repairExistingInstall: Bool,
        bundledVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
    ) throws -> String? {
        if let pinnedVersion {
            return pinnedVersion
        }
        guard repairExistingInstall else {
            return nil
        }
        guard let bundledVersion,
              ProviderCLIVersion.strictNormalize(bundledVersion) != nil else {
            throw Error.invalidPinnedVersion(bundledVersion ?? "")
        }
        return bundledVersion
    }

    /// Invokes `install.sh` with `MACPROVIDER_NO_PROMPT=1`. Delivers stdout/stderr
    /// lines to `onLogLine` on the main actor.
    static func run(
        pinnedVersion: String? = nil,
        referralCode: String? = nil,
        replacingIncumbentProvider: Bool = false,
        repairExistingInstall: Bool = false,
        onLogLine: @escaping @Sendable @MainActor (String) -> Void
    ) async throws {
        let scriptURL = try resolveInstallScriptURL()
        let manifestURL = try resolveCompatibilityManifestURL()
        let verifiedScript = try BundledInstallContractVerifier.verify(
            scriptURL: scriptURL,
            manifestURL: manifestURL
        )
        let referralFileURL = try referralCode.map { try ReferralCodeFile.create(code: $0) }
        defer {
            if let referralFileURL { try? FileManager.default.removeItem(at: referralFileURL) }
        }
        let installPort = resolveInstallPort()
        let resolvedPin = try resolvedPinnedVersion(
            pinnedVersion: pinnedVersion,
            repairExistingInstall: repairExistingInstall
        )
        let bundledCLIPath = repairExistingInstall ? try resolveBundledCLI() : nil
        let bundledAppPath = repairExistingInstall ? Bundle.main.bundleURL : nil
        let environment = try installerEnvironment(
            parentEnvironment: ProcessInfo.processInfo.environment,
            installPort: installPort,
            pinnedVersion: resolvedPin,
            referralCodeFile: referralFileURL,
            replacingIncumbentProvider: replacingIncumbentProvider,
            repairExistingInstall: repairExistingInstall,
            bundledCLIPath: bundledCLIPath,
            bundledAppPath: bundledAppPath
        )
        if let installPort {
            await onLogLine("[macprovider-install] Using local HTTP port \(installPort) for provider install.")
        }
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdin = Pipe()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                // Execute the exact authenticated bytes without reopening an
                // owner-writable path between verification and bash parsing.
                process.arguments = ["-s", "--"]
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr

                process.environment = environment

                let emit: (Pipe) -> Void = { pipe in
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        let text = String(decoding: chunk, as: UTF8.self)
                        for line in text.split(whereSeparator: \.isNewline) {
                            let trimmed = String(line)
                            guard !trimmed.isEmpty else { continue }
                            Task { @MainActor in onLogLine(trimmed) }
                        }
                    }
                }
                emit(stdout)
                emit(stderr)

                do {
                    try process.run()
                    try stdin.fileHandleForWriting.write(contentsOf: verifiedScript)
                    try stdin.fileHandleForWriting.close()
                } catch {
                    try? stdin.fileHandleForWriting.close()
                    if process.isRunning { process.terminate() }
                    continuation.resume(throwing: Error.launchFailed(error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: process.terminationStatus)
            }
        }
        if let classified = classifiedInstallError(
            exitCode: exitCode,
            repairExistingInstall: repairExistingInstall
        ) {
            throw classified
        }
    }

    static func installerEnvironment(
        parentEnvironment: [String: String],
        installPort: Int?,
        pinnedVersion: String?,
        referralCodeFile: URL? = nil,
        replacingIncumbentProvider: Bool = false,
        repairExistingInstall: Bool = false,
        bundledCLIPath: URL? = nil,
        bundledAppPath: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> [String: String] {
        // Deliberately do not inherit the parent environment. install.sh has
        // authority-changing knobs for repositories, public keys, acceptance
        // candidates, emergency rollback, paths, and launchd. Malibu supplies
        // only the values this invocation owns, and never forwards parent
        // tokens or dynamic-loader/shell configuration.
        _ = parentEnvironment
        var explicit = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": homeDirectory.path,
            "TMPDIR": "/tmp",
            "LC_ALL": "C",
            "MACPROVIDER_NO_PROMPT": "1",
        ]
        let configuredProgram = InstalledProviderMonitor.configuredProviderProgram(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let defaultProgram = homeDirectory.appendingPathComponent("macprovider/macprovider-cli").standardizedFileURL
        if configuredProgram != defaultProgram {
            explicit["MACPROVIDER_INSTALL_DIR"] = configuredProgram.deletingLastPathComponent().path
        }
        if let installPort {
            explicit["MACPROVIDER_PORT"] = String(installPort)
        }
        if let pinnedVersion {
            guard let normalized = ProviderCLIVersion.strictNormalize(pinnedVersion) else {
                throw Error.invalidPinnedVersion(pinnedVersion)
            }
            explicit["MACPROVIDER_VERSION"] = "v\(normalized)"
        }
        if let referralCodeFile {
            explicit["MACPROVIDER_REFERRAL_CODE_FILE"] = referralCodeFile.path
            if replacingIncumbentProvider {
                explicit["MACPROVIDER_REFERRAL_REPLACE_INCUMBENT"] = "1"
            }
        }
        if repairExistingInstall {
            explicit["MACPROVIDER_REPAIR_EXISTING_INSTALL"] = "1"
            guard let bundledCLIPath, let bundledAppPath else {
                throw Error.bundledCLINotFound
            }
            explicit["MACPROVIDER_BUNDLED_CLI"] = bundledCLIPath.path
            explicit["MACPROVIDER_BUNDLED_APP"] = bundledAppPath.path
        }
        return try ProcessEnvironmentSanitizer.sanitized(
            from: [:],
            extraEnvironment: explicit
        )
    }

    /// Reports whether an already-installed provider is locally healthy. This
    /// is used to resume onboarding, never to override a failed install exit.
    static func localInstallSucceeded() async -> Bool {
        guard let port = ProviderConfig.readHTTPPort(),
              ProviderConfig.readProviderID() != nil else {
            return false
        }
        let manifest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider/install_manifest.json")
        let hasManifest = FileManager.default.isReadableFile(atPath: manifest.path)
        let launchdPlist = FileManager.default.isReadableFile(
            atPath: NSHomeDirectory() + "/Library/LaunchAgents/live.malibu.provider.plist"
        )
        guard hasManifest || launchdPlist else { return false }
        guard InstalledProviderMonitor.launchdServiceRepairState() == .validExecutable else {
            return false
        }
        return await InstalledProviderMonitor.isHealthy(port: port)
    }

    /// Repair copies this Malibu.app CLI through install.sh instead of
    /// downloading a GitHub tag that may not exist yet.
    static func resolveBundledCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) throws -> URL {
        if let override = environment["MALIBU_CLI_PATH"], !override.isEmpty {
            #if DEBUG
            return URL(fileURLWithPath: override)
            #endif
        }
        let bundled = bundleURL.appendingPathComponent("Contents/MacOS/macprovider-cli")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        throw Error.bundledCLINotFound
    }

    /// Visible install stages for onboarding. Tests inject process and log
    /// lines so this does not depend on a live `ps` snapshot.
    struct InstallProgress: Equatable {
        enum Stage: Int, CaseIterable, Comparable {
            case starting
            case downloadingRelease
            case installingCLI
            case downloadingModel
            case autotune
            case registering

            static func < (lhs: Stage, rhs: Stage) -> Bool {
                lhs.rawValue < rhs.rawValue
            }

            var title: String {
                switch self {
                case .starting: return "Starting"
                case .downloadingRelease: return "Provider software"
                case .installingCLI: return "Install software"
                case .downloadingModel: return "Model download"
                case .autotune: return "Mac check"
                case .registering: return "Registering"
                }
            }

            /// Model download is the long wait; weight the bar that way.
            var overallBase: Double {
                switch self {
                case .starting: return 0.04
                case .downloadingRelease: return 0.10
                case .installingCLI: return 0.16
                case .downloadingModel: return 0.20
                case .autotune: return 0.88
                case .registering: return 0.96
                }
            }
        }

        var stage: Stage
        var detail: String
        var downloadFraction: Double?

        var overallFraction: Double {
            if stage == .downloadingModel {
                let span = 0.66
                return min(0.86, stage.overallBase + span * (downloadFraction ?? 0.04))
            }
            return min(0.99, stage.overallBase)
        }

        var percentLabel: String? {
            guard let downloadFraction else { return nil }
            return "\(Int((downloadFraction * 100).rounded()))%"
        }

        static let starting = InstallProgress(
            stage: .starting,
            detail: "Starting installer…",
            downloadFraction: nil
        )
    }

    /// Human-readable hint for onboarding UI while `install.sh` runs long silent phases.
    enum ActivityMonitor {
        static func snapshot(logLines: [String] = []) -> InstallProgress {
            progress(
                processLines: macproviderProcessLines(),
                logLines: logLines,
                cliInstalled: FileManager.default.isExecutableFile(
                    atPath: NSHomeDirectory() + "/macprovider/macprovider-cli"
                )
            )
        }

        static func progress(
            processLines: [String],
            logLines: [String] = [],
            cliInstalled: Bool = false
        ) -> InstallProgress {
            let combined = processLines + logLines
            let downloadFraction = parseDownloadFraction(from: combined)
            let looksLikeModelDownload = processLines.contains(where: {
                $0.contains("models pull") || $0.lowercased().contains("huggingface")
            }) || logLines.contains(where: { line in
                let lower = line.lowercased()
                return lower.contains("huggingface")
                    || lower.contains("safetensors")
                    || lower.contains("models pull")
                    || (lower.contains("downloading") && (line.contains("%") || lower.contains("model")))
            }) || (cliInstalled && downloadFraction != nil)

            if processLines.contains(where: { $0.contains("autotune --recommend") }) {
                return InstallProgress(
                    stage: .autotune,
                    detail: "Checking which model fits this Mac — often 10–30 minutes on first run.",
                    downloadFraction: nil
                )
            }
            if let bench = processLines.first(where: { $0.contains("serve --no-join") }) {
                let model = extractFlag("--model", from: bench).map(shortModelName) ?? "a candidate model"
                return InstallProgress(
                    stage: .autotune,
                    detail: "Testing \(model) performance…",
                    downloadFraction: nil
                )
            }
            if looksLikeModelDownload {
                if let downloadFraction {
                    return InstallProgress(
                        stage: .downloadingModel,
                        detail: "Downloading model weights — \(Int((downloadFraction * 100).rounded()))%",
                        downloadFraction: downloadFraction
                    )
                }
                return InstallProgress(
                    stage: .downloadingModel,
                    detail: "Downloading model weights…",
                    downloadFraction: nil
                )
            }
            if cliInstalled {
                return InstallProgress(
                    stage: .installingCLI,
                    detail: "Provider software installed. Model download and Mac checks are next.",
                    downloadFraction: nil
                )
            }
            if processLines.contains(where: { $0.contains("curl") && $0.lowercased().contains("github") }) {
                return InstallProgress(
                    stage: .downloadingRelease,
                    detail: "Downloading provider software…",
                    downloadFraction: nil
                )
            }
            return InstallProgress(
                stage: .starting,
                detail: "Install in progress…",
                downloadFraction: nil
            )
        }

        static func parseDownloadFraction(from lines: [String]) -> Double? {
            let percent = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s*%"#)
            let bytes = try! NSRegularExpression(
                pattern: #"(\d+(?:\.\d+)?)\s*(GiB|GB|MiB|MB)\s*/\s*(\d+(?:\.\d+)?)\s*(GiB|GB|MiB|MB)"#,
                options: .caseInsensitive
            )
            for line in lines.reversed() {
                let range = NSRange(line.startIndex..., in: line)
                if let match = percent.firstMatch(in: line, range: range),
                   let valueRange = Range(match.range(at: 1), in: line),
                   let value = Double(line[valueRange]),
                   value >= 0,
                   value <= 100 {
                    return value / 100
                }
                if let match = bytes.firstMatch(in: line, range: range),
                   let n1Range = Range(match.range(at: 1), in: line),
                   let u1Range = Range(match.range(at: 2), in: line),
                   let n2Range = Range(match.range(at: 3), in: line),
                   let u2Range = Range(match.range(at: 4), in: line),
                   let n1 = Double(line[n1Range]),
                   let n2 = Double(line[n2Range]),
                   n2 > 0 {
                    let from = n1 * byteUnitMultiplier(String(line[u1Range]))
                    let to = n2 * byteUnitMultiplier(String(line[u2Range]))
                    guard to > 0 else { continue }
                    return min(1, from / to)
                }
            }
            return nil
        }

        private static func byteUnitMultiplier(_ unit: String) -> Double {
            switch unit.uppercased() {
            case "GIB", "GB": return 1_024 * 1_024 * 1_024
            case "MIB", "MB": return 1_024 * 1_024
            default: return 1
            }
        }

        private static func macproviderProcessLines() -> [String] {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-ax", "-o", "command="]
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return []
            }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            return text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.contains("macprovider-cli") && !$0.contains("/bin/ps") }
        }

        private static func extractFlag(_ flag: String, from command: String) -> String? {
            let parts = command.split(separator: " ").map(String.init)
            guard let index = parts.firstIndex(of: flag), index + 1 < parts.count else { return nil }
            return parts[index + 1]
        }

        private static func shortModelName(_ raw: String) -> String {
            if raw.contains("/") {
                return raw.split(separator: "/").last.map(String.init) ?? raw
            }
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw).lastPathComponent
            }
            return raw
        }
    }

    static func resolveInstallScriptURL() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "install", withExtension: "sh") {
            return bundled
        }
        let devRelative = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("dist/install.sh")
        if FileManager.default.isReadableFile(atPath: devRelative.path) {
            return devRelative
        }
        throw Error.installScriptNotFound
    }

    static func resolveCompatibilityManifestURL() throws -> URL {
        guard let bundled = Bundle.main.url(forResource: "compatibility-set", withExtension: "json") else {
            throw Error.compatibilityManifestNotFound
        }
        return bundled
    }

    /// Port for `install.sh`: explicit env override, existing config, else a probed free port.
    /// Avoids exit 6 when the default 8080 is occupied (common on dev Macs running Node).
    static func resolveInstallPort(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        if let raw = environment["MACPROVIDER_PORT"], let port = Int(raw), port > 0 {
            return port
        }
        if let configured = ProviderConfig.readHTTPPort() {
            return configured
        }
        return try? FreePortProbe.probe()
    }

}
