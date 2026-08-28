import AppKit
import CryptoKit
import Foundation
import Security

enum CLIUpdateRunner {
    // Legacy repair pins exactly the CLI version this app shipped as. The
    // 1.8.40 arming is a cohort-bound recovery exception (Decision Entry 160)
    // for the stranded 1.8.30/1.8.32/1.8.39 test cohort. Later releases MUST
    // leave this constant unchanged — the exact-match interlock in
    // `strategy(...)` then disarms the bridge automatically — unless a new
    // decision entry authorizes re-arming with release-specific proof.
    static let legacyBootstrapTarget = "1.8.40"

    enum Strategy: Equatable {
        case installedCompatibilityCLI
        case pinnedInstaller(version: String)
    }

    struct RunningAppSnapshot: Equatable {
        let bundleURL: URL
        let version: String?
        let build: String?
    }

    struct UpdatedAppRelaunchPlan: Equatable {
        let bundleURL: URL
        let previousVersion: String?
        let previousBuild: String?
        let installedVersion: String
        let installedBuild: String?
        let expectedVersion: String
    }

    struct ExpectedAppIdentity: Equatable {
        let version: String
        let compatibilitySetID: String?
        let compatibilityManifestBytes: Data?

        init(
            version: String,
            compatibilitySetID: String? = nil,
            compatibilityManifestBytes: Data? = nil
        ) {
            self.version = version
            self.compatibilitySetID = compatibilitySetID
            self.compatibilityManifestBytes = compatibilityManifestBytes
        }
    }

    enum Error: Swift.Error, LocalizedError {
        case cliNotFound
        case invalidInstalledVersion(String?)
        case legacyBootstrapUnavailable(appVersion: String?)
        case legacyBootstrapWouldDowngrade(installedVersion: String)
        case appBundleDidNotUpdate(expectedVersion: String, installedVersion: String?)
        case appBundleSignatureInvalid
        case appUpdateProofUnavailable
        case nonZeroExit(Int32)
        case rollbackRestored(Int32)
        case rollbackFailed(Int32)
        case readinessFailed
        case launchFailed(String)
        case appRelaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "Provider software was not found at the expected install path."
            case let .invalidInstalledVersion(version):
                return "Installed provider software version is invalid: \(version ?? "unknown")."
            case let .legacyBootstrapUnavailable(appVersion):
                return "This provider requires Malibu v\(legacyBootstrapTarget) to install the required provider software (running \(appVersion.map { "v\($0)" } ?? "an unknown app version"))."
            case let .legacyBootstrapWouldDowngrade(installedVersion):
                return "Malibu v\(legacyBootstrapTarget) will not downgrade provider software v\(installedVersion)."
            case let .appBundleDidNotUpdate(expectedVersion, installedVersion):
                return "Provider software update completed, but Malibu.app did not update to v\(expectedVersion) (installed \(installedVersion.map { "v\($0)" } ?? "version unknown")). Reopen Malibu from Applications and run Update again."
            case .appBundleSignatureInvalid:
                return "Provider software update completed, but the updated Malibu.app could not be verified. Reopen Malibu from Applications and run Update again."
            case .appUpdateProofUnavailable:
                return "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            case let .nonZeroExit(code):
                return "Provider software update failed (exit \(code))."
            case let .rollbackRestored(code):
                return "Provider update failed; the previous release was restored (rollback_restored, exit \(code))."
            case let .rollbackFailed(code):
                return "Provider update and rollback both failed (rollback_failed, exit \(code))."
            case .readinessFailed:
                return "Provider update installed but did not become ready for customer work."
            case let .launchFailed(message):
                return "Could not start provider software update: \(message)"
            case let .appRelaunchFailed(message):
                return "Malibu updated, but could not reopen the new app: \(message)"
            }
        }
    }

    static func installedCLIPath() -> String {
        NSHomeDirectory() + "/macprovider/malibu-cli"
    }

    static func resolveExecutableURL() throws -> URL {
        let installed = URL(fileURLWithPath: installedCLIPath())
        if FileManager.default.isExecutableFile(atPath: installed.path) {
            return installed
        }
        if let override = ProcessInfo.processInfo.environment["MALIBU_CLI_PATH"], !override.isEmpty {
            #if DEBUG
            return URL(fileURLWithPath: override)
            #endif
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/malibu-cli")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        throw Error.cliNotFound
    }

    static func strategy(
        installedVersion: String?,
        compatibilitySetID: String?,
        bundledAppVersion: String?
    ) throws -> Strategy {
        guard let installedVersion,
              let normalizedInstalled = ProviderCLIVersion.strictNormalize(installedVersion) else {
            throw Error.invalidInstalledVersion(installedVersion)
        }
        let hasCompatibilitySet = compatibilitySetID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false
        let predatesCompatibilityUpdater = ProviderCLIVersion.compare(
            normalizedInstalled,
            ProviderCLIVersion.compatibilitySetReleaseFloor
        ) == .ascending
        guard predatesCompatibilityUpdater || !hasCompatibilitySet else {
            return .installedCompatibilityCLI
        }

        guard ProviderCLIVersion.compare(normalizedInstalled, legacyBootstrapTarget) != .descending else {
            throw Error.legacyBootstrapWouldDowngrade(installedVersion: normalizedInstalled)
        }
        guard let bundledAppVersion,
              ProviderCLIVersion.strictNormalize(bundledAppVersion) == legacyBootstrapTarget else {
            throw Error.legacyBootstrapUnavailable(appVersion: bundledAppVersion)
        }
        return .pinnedInstaller(version: "v\(legacyBootstrapTarget)")
    }

    static func run(
        installedVersion: String?,
        compatibilitySetID: String?,
        relaunchUpdatedApp: @escaping @Sendable @MainActor (UpdatedAppRelaunchPlan) async throws -> Void = { plan in
            try await defaultRelaunchUpdatedApp(plan)
        },
        onLogLine: @escaping @Sendable @MainActor (String) -> Void
    ) async throws {
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let runningApp = runningAppSnapshot()
        try await runForTest(
            installedVersion: installedVersion,
            compatibilitySetID: compatibilitySetID,
            bundledAppVersion: appVersion,
            runningApp: runningApp,
            installedUpdate: {
                let executable = try resolveExecutableURL()
                try await runCommand(
                    executableURL: executable,
                    arguments: ["update"],
                    onLogLine: onLogLine
                )
            },
            pinnedInstall: { version in
                await onLogLine(
                    "[Malibu] Repairing the complete provider installation with signed \(version)."
                )
                try await CLIInstallRunner.run(
                    pinnedVersion: version,
                    onLogLine: onLogLine
                )
            },
            readinessCheck: { await waitForBuyerServing() },
            expectedAppIdentityAfterUpdate: { strategy, runningApp in
                try CLIUpdateRunner.expectedAppIdentityAfterUpdate(
                    strategy: strategy,
                    runningApp: runningApp
                )
            },
            isUpdaterOwnedInstall: { url in
                isUpdaterOwnedMalibuInstall(url)
            },
            validateAppSignature: { url in
                validateMalibuAppCodeSignature(at: url)
            },
            relaunchUpdatedApp: relaunchUpdatedApp,
            onLogLine: onLogLine
        )
    }

    static func runForTest(
        installedVersion: String?,
        compatibilitySetID: String?,
        bundledAppVersion: String?,
        runningApp: RunningAppSnapshot?,
        installedUpdate: @escaping @Sendable () async throws -> Void,
        pinnedInstall: @escaping @Sendable (String) async throws -> Void,
        readinessCheck: @escaping @Sendable () async -> Bool,
        expectedAppIdentityAfterUpdate: @escaping @Sendable (Strategy, RunningAppSnapshot?) throws -> ExpectedAppIdentity?,
        isUpdaterOwnedInstall: @escaping @Sendable (URL) -> Bool = { _ in true },
        validateAppSignature: @escaping @Sendable (URL) -> Bool = { _ in true },
        relaunchUpdatedApp: @escaping @Sendable @MainActor (UpdatedAppRelaunchPlan) async throws -> Void,
        onLogLine: @escaping @Sendable @MainActor (String) -> Void
    ) async throws {
        let selectedStrategy = try strategy(
            installedVersion: installedVersion,
            compatibilitySetID: compatibilitySetID,
            bundledAppVersion: bundledAppVersion
        )
        try await runStrategyForTest(
            strategy: selectedStrategy,
            installedUpdate: installedUpdate,
            pinnedInstall: pinnedInstall,
            readinessCheck: readinessCheck
        )
        let expectedAppIdentity = try expectedAppIdentityAfterUpdate(
            selectedStrategy,
            runningApp
        )
        try validatePostUpdateCompatibilitySetAdvanced(
            strategy: selectedStrategy,
            previousCompatibilitySetID: compatibilitySetID,
            expectedIdentity: expectedAppIdentity
        )
        if let relaunchPlan = try updatedAppRelaunchPlan(
            runningApp: runningApp,
            expectedIdentity: expectedAppIdentity,
            isUpdaterOwnedInstall: isUpdaterOwnedInstall,
            validateAppSignature: validateAppSignature
        ) {
            await onLogLine(
                "[Malibu] Malibu.app v\(relaunchPlan.installedVersion) build \(relaunchPlan.installedBuild ?? "unknown") installed; reopening the updated app."
            )
            try await relaunchUpdatedApp(relaunchPlan)
        }
    }

    static func runStrategyForTest(
        strategy: Strategy,
        installedUpdate: @escaping @Sendable () async throws -> Void,
        pinnedInstall: @escaping @Sendable (String) async throws -> Void,
        readinessCheck: @escaping @Sendable () async -> Bool
    ) async throws {
        switch strategy {
        case .installedCompatibilityCLI:
            try await installedUpdate()
        case let .pinnedInstaller(version):
            try await pinnedInstall(version)
        }
        guard await readinessCheck() else {
            throw Error.readinessFailed
        }
    }

    static func runForTest(
        executableURL: URL,
        arguments: [String],
        onLogLine: @escaping @Sendable @MainActor (String) -> Void,
        readinessCheck: @escaping @Sendable () async -> Bool
    ) async throws {
        try await runCommand(
            executableURL: executableURL,
            arguments: arguments,
            onLogLine: onLogLine
        )
        guard await readinessCheck() else {
            throw Error.readinessFailed
        }
    }

    private static func runCommand(
        executableURL: URL,
        arguments: [String],
        onLogLine: @escaping @Sendable @MainActor (String) -> Void
    ) async throws {
        let environment = try updaterEnvironment(
            parentEnvironment: ProcessInfo.processInfo.environment
        )
        let outputState = CLIUpdateOutputState()
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr

                process.environment = environment

                let emit: (Pipe) -> Void = { pipe in
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        let text = String(decoding: chunk, as: UTF8.self)
                        outputState.append(text)
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
                } catch {
                    continuation.resume(throwing: Error.launchFailed(error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                for pipe in [stdout, stderr] {
                    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !tail.isEmpty {
                        let text = String(decoding: tail, as: UTF8.self)
                        outputState.append(text)
                        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                            Task { @MainActor in onLogLine(String(line)) }
                        }
                    }
                }
                continuation.resume(returning: process.terminationStatus)
            }
        }
        if exitCode != 0 {
            if outputState.containsRollbackRestored {
                throw Error.rollbackRestored(exitCode)
            }
            if outputState.containsRollbackFailed {
                throw Error.rollbackFailed(exitCode)
            }
            throw Error.nonZeroExit(exitCode)
        }
    }

    static func updaterEnvironment(
        parentEnvironment: [String: String]
    ) throws -> [String: String] {
        // The installed updater owns release selection and mutation. Do not
        // forward app-launch tokens, repository/key overrides, shell startup,
        // dynamic-loader configuration, or test hooks into that authority.
        _ = parentEnvironment
        return try ProcessEnvironmentSanitizer.sanitized(
            from: [:],
            extraEnvironment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "TMPDIR": "/tmp",
                "LC_ALL": "C",
            ]
        )
    }

    static func expectedAppIdentityFromManifestForTest(
        manifestURL: URL,
        publicKeyPEM: String
    ) throws -> ExpectedAppIdentity {
        try signedCompatibilitySetMalibuIdentity(from: manifestURL, publicKeyPEM: publicKeyPEM)
    }

    static func expectedAppIdentityFromInstalledProviderManifestForTest(
        executableURL: URL,
        publicKeyPEM: String
    ) throws -> ExpectedAppIdentity {
        try expectedAppIdentityFromInstalledProviderManifest(
            executableURL: executableURL,
            publicKeyPEM: publicKeyPEM
        )
    }

    static func runningAppSnapshot(bundle: Bundle = .main) -> RunningAppSnapshot? {
        guard bundle.bundleIdentifier == "tech.malibu.app",
              bundle.bundleURL.lastPathComponent == "Malibu.app" else {
            return nil
        }
        return RunningAppSnapshot(
            bundleURL: bundle.bundleURL,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func updatedAppRelaunchPlanForTest(
        runningApp: RunningAppSnapshot?,
        expectedIdentity: ExpectedAppIdentity?,
        isUpdaterOwnedInstall: @escaping @Sendable (URL) -> Bool = { _ in true },
        validateAppSignature: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) throws -> UpdatedAppRelaunchPlan? {
        try updatedAppRelaunchPlan(
            runningApp: runningApp,
            expectedIdentity: expectedIdentity,
            isUpdaterOwnedInstall: isUpdaterOwnedInstall,
            validateAppSignature: validateAppSignature
        )
    }

    private static func updatedAppRelaunchPlan(
        runningApp: RunningAppSnapshot?,
        expectedIdentity: ExpectedAppIdentity?,
        isUpdaterOwnedInstall: @escaping @Sendable (URL) -> Bool = { url in
            isUpdaterOwnedMalibuInstall(url)
        },
        validateAppSignature: @escaping @Sendable (URL) -> Bool = { url in
            validateMalibuAppCodeSignature(at: url)
        }
    ) throws -> UpdatedAppRelaunchPlan? {
        guard let runningApp else { return nil }
        guard isUpdaterOwnedInstall(runningApp.bundleURL) else { return nil }
        guard let expectedIdentity,
              let expectedVersion = ProviderCLIVersion.strictNormalize(expectedIdentity.version) else {
            return nil
        }
        guard let installed = readInstalledMalibuAppIdentity(at: runningApp.bundleURL) else {
            throw Error.appBundleDidNotUpdate(
                expectedVersion: expectedVersion,
                installedVersion: nil
            )
        }
        guard validateAppSignature(runningApp.bundleURL) else {
            throw Error.appBundleSignatureInvalid
        }
        guard let normalizedInstalled = ProviderCLIVersion.strictNormalize(installed.version),
              normalizedInstalled == expectedVersion else {
            throw Error.appBundleDidNotUpdate(
                expectedVersion: expectedVersion,
                installedVersion: ProviderCLIVersion.strictNormalize(installed.version) ?? installed.version
            )
        }
        try validateEmbeddedCompatibilityManifest(
            in: runningApp.bundleURL,
            expectedIdentity: expectedIdentity
        )

        let normalizedRunning = runningApp.version.flatMap(ProviderCLIVersion.strictNormalize)
        let installedIsNewer = normalizedRunning.map {
            ProviderCLIVersion.compare($0, normalizedInstalled) == .ascending
        } ?? true
        let buildIsNewer = normalizedRunning == normalizedInstalled && buildIsNewerOrChanged(
            installed: installed.build,
            running: runningApp.build
        )
        guard installedIsNewer || buildIsNewer else { return nil }
        return UpdatedAppRelaunchPlan(
            bundleURL: runningApp.bundleURL,
            previousVersion: normalizedRunning ?? runningApp.version,
            previousBuild: runningApp.build,
            installedVersion: normalizedInstalled,
            installedBuild: installed.build,
            expectedVersion: expectedVersion
        )
    }

    private static func readInstalledMalibuAppIdentity(
        at bundleURL: URL,
        fileManager: FileManager = .default
    ) -> (version: String, build: String?)? {
        let standardized = bundleURL.standardizedFileURL
        guard standardized.lastPathComponent == "Malibu.app" else { return nil }
        var info = stat()
        guard lstat(standardized.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        let infoURL = standardized.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoURL.path),
              let plistData = try? readRegularFile(infoURL, maximumBytes: 64 * 1_024),
              let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                format: nil
              ) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "tech.malibu.app",
              let version = plist["CFBundleShortVersionString"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (version, plist["CFBundleVersion"] as? String)
    }

    private static func validateEmbeddedCompatibilityManifest(
        in bundleURL: URL,
        expectedIdentity: ExpectedAppIdentity
    ) throws {
        guard let expectedBytes = expectedIdentity.compatibilityManifestBytes else { return }
        let embeddedManifestURL = bundleURL.standardizedFileURL
            .appendingPathComponent("Contents/Resources/compatibility-set.json")
        let embeddedBytes = try readRegularFile(
            embeddedManifestURL,
            maximumBytes: 1_048_576
        )
        guard embeddedBytes == expectedBytes else {
            throw Error.appUpdateProofUnavailable
        }
    }

    private static func expectedAppIdentityAfterUpdate(
        strategy: Strategy,
        runningApp: RunningAppSnapshot?
    ) throws -> ExpectedAppIdentity? {
        guard case .installedCompatibilityCLI = strategy,
              let runningApp,
              isUpdaterOwnedMalibuInstall(runningApp.bundleURL) else {
            return nil
        }
        do {
            let installedExecutable = try installedProviderExecutableForAppProof()
            return try expectedAppIdentityFromInstalledProviderManifest(
                executableURL: installedExecutable
            )
        } catch let error as Error {
            throw error
        } catch {
            throw Error.appUpdateProofUnavailable
        }
    }

    private static func expectedAppIdentityFromInstalledProviderManifest(
        executableURL: URL,
        publicKeyPEM: String = releasePublicKeyPEM
    ) throws -> ExpectedAppIdentity {
        let payloadDirectory = try installedProviderPayloadDirectory(for: executableURL)
        return try signedCompatibilitySetMalibuIdentity(
            from: payloadDirectory.appendingPathComponent("compatibility-set.json"),
            publicKeyPEM: publicKeyPEM
        )
    }

    private static func installedProviderExecutableForAppProof() throws -> URL {
        let executable = URL(fileURLWithPath: installedCLIPath()).standardizedFileURL
        _ = try installedProviderPayloadDirectory(for: executable)
        return executable
    }

    private static func installedProviderPayloadDirectory(for executableURL: URL) throws -> URL {
        let executable = executableURL.standardizedFileURL
        guard executable.lastPathComponent == "malibu-cli" else {
            throw Error.appUpdateProofUnavailable
        }
        var info = stat()
        guard lstat(executable.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0,
              access(executable.path, X_OK) == 0 else {
            throw Error.appUpdateProofUnavailable
        }
        return executable.deletingLastPathComponent()
    }

    private static func signedCompatibilitySetMalibuIdentity(
        from manifestURL: URL,
        publicKeyPEM: String = releasePublicKeyPEM
    ) throws -> ExpectedAppIdentity {
        let data = try readRegularFile(manifestURL, maximumBytes: 1_048_576)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.appUpdateProofUnavailable
        }
        guard Set(envelope.keys) == Set(["schema_version", "signatures", "signed"]),
              envelope["schema_version"] as? String == "macprovider.compatibility-set-envelope.v1",
              canonicalEnvelopeBytes(envelope) == data else {
            throw Error.appUpdateProofUnavailable
        }
        guard let signatures = envelope["signatures"] as? [Any],
              signatures.count == 1,
              let signature = signatures.first as? [String: Any],
              Set(signature.keys) == Set(["algorithm", "key_id", "signature"]),
              signature["algorithm"] as? String == "ecdsa-p256-sha256",
              signature["key_id"] as? String == "macprovider-release-p256-v1",
              let encodedSignature = signature["signature"] as? String,
              let signatureData = Data(base64Encoded: encodedSignature),
              signatureData.base64EncodedString() == encodedSignature,
              (64...80).contains(signatureData.count),
              let signed = envelope["signed"] as? [String: Any],
              let signedBytes = signedCanonicalBytes(signed),
              signatureIsValid(
                signatureData: signatureData,
                signedBytes: signedBytes,
                publicKeyPEM: publicKeyPEM
              ) else {
            throw Error.appUpdateProofUnavailable
        }
        guard signed["schema_version"] as? String == "macprovider.compatibility-set.v1",
              let compatibilitySetID = signed["compatibility_set_id"] as? String,
              isValidCompatibilitySetID(compatibilitySetID),
              let components = signed["components"] as? [String: Any],
              let malibuApp = components["malibu_app"] as? [String: Any],
              Set(malibuApp.keys) == Set([
                "activation", "bundle_id", "compatibility_handoff",
                "minimum_status_reader", "version",
              ]),
              malibuApp["activation"] as? String == "cli_owned_if_installed",
              malibuApp["bundle_id"] as? String == "tech.malibu.app",
              (malibuApp["minimum_status_reader"] as? NSNumber)?.intValue == 1,
              let handoff = malibuApp["compatibility_handoff"] as? [String: Any],
              Set(handoff.keys) == Set([
                "delivery", "embedded_manifest_path", "provider_mutation", "reader_compatibility",
              ]),
              handoff["delivery"] as? String == "signed_dmg_transaction_member",
              handoff["embedded_manifest_path"] as? String == "Contents/Resources/compatibility-set.json",
              handoff["provider_mutation"] as? String == "forbidden",
              handoff["reader_compatibility"] as? String == "backward_compatible",
              let version = malibuApp["version"] as? String,
              ProviderCLIVersion.strictNormalize(version) == version else {
            throw Error.appUpdateProofUnavailable
        }
        return ExpectedAppIdentity(
            version: version,
            compatibilitySetID: compatibilitySetID,
            compatibilityManifestBytes: data
        )
    }

    private static func validatePostUpdateCompatibilitySetAdvanced(
        strategy: Strategy,
        previousCompatibilitySetID: String?,
        expectedIdentity: ExpectedAppIdentity?
    ) throws {
        guard case .installedCompatibilityCLI = strategy else { return }
        guard let previous = previousCompatibilitySetID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !previous.isEmpty else {
            return
        }
        guard let next = expectedIdentity?.compatibilitySetID,
              isValidCompatibilitySetID(next),
              next != previous else {
            throw Error.appUpdateProofUnavailable
        }
    }

    private static func isValidCompatibilitySetID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value,
              !value.isEmpty,
              value.utf8.count <= 512 else {
            return false
        }
        return value.range(
            of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:v[0-9]+\.[0-9]+\.[0-9]+@[0-9a-f]{40}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw Error.appUpdateProofUnavailable
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Error.appUpdateProofUnavailable }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == info.st_dev,
              opened.st_ino == info.st_ino,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_size >= 0,
              opened.st_size <= maximumBytes else {
            throw Error.appUpdateProofUnavailable
        }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Error.appUpdateProofUnavailable }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else {
                throw Error.appUpdateProofUnavailable
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func signedCanonicalBytes(_ signed: [String: Any]) -> Data? {
        guard var signedBytes = canonicalJSON(signed) else { return nil }
        signedBytes.append(0x0a)
        return signedBytes
    }

    private static func canonicalEnvelopeBytes(_ envelope: [String: Any]) -> Data? {
        guard var envelopeBytes = canonicalJSON(envelope) else { return nil }
        envelopeBytes.append(0x0a)
        return envelopeBytes
    }

    private static func canonicalJSON(_ object: Any) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static let releasePublicKeyPEM = """
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwwd0Vzj35OP8DlZU+0lUa8vI9gHK
        09J48LDizWScsH6rutnZLkKnGQ4X5Q8lT9L5mglF8Ba0DDoUXKrFfSAX4Q==
        -----END PUBLIC KEY-----
        """

    private static func signatureIsValid(
        signatureData: Data,
        signedBytes: Data,
        publicKeyPEM: String
    ) -> Bool {
        do {
            let publicKey = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            return publicKey.isValidSignature(signature, for: SHA256.hash(data: signedBytes))
        } catch {
            return false
        }
    }

    private static func isUpdaterOwnedMalibuInstall(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let perUser = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Malibu.app", isDirectory: true)
            .standardizedFileURL
        let system = URL(fileURLWithPath: "/Applications/Malibu.app", isDirectory: true)
            .standardizedFileURL
        return standardized == system || standardized == perUser
    }

    private static func validateMalibuAppCodeSignature(at appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        let requirementText = "identifier \"tech.malibu.app\" and anchor apple generic and certificate leaf[subject.OU] = \"YF7XNRJUG4\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            requirement
        ) == errSecSuccess
    }

    private static func buildIsNewerOrChanged(installed: String?, running: String?) -> Bool {
        guard let installed = installed?.trimmingCharacters(in: .whitespacesAndNewlines),
              !installed.isEmpty else {
            return false
        }
        guard let running = running?.trimmingCharacters(in: .whitespacesAndNewlines),
              !running.isEmpty else {
            return true
        }
        if let installedNumber = Int(installed), let runningNumber = Int(running) {
            return installedNumber > runningNumber
        }
        return installed != running
    }

    @MainActor
    private static func defaultRelaunchUpdatedApp(_ plan: UpdatedAppRelaunchPlan) async throws {
        guard validateMalibuAppCodeSignature(at: plan.bundleURL) else {
            throw Error.appBundleSignatureInvalid
        }
        try await openUpdatedApp(at: plan.bundleURL)
        NSApp.terminate(nil)
    }

    private static func openUpdatedApp(at bundleURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-n", bundleURL.path]
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Error.appRelaunchFailed(error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(
                        throwing: Error.appRelaunchFailed("open exited \(process.terminationStatus)")
                    )
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private static func waitForBuyerServing(timeout: TimeInterval = 90) async -> Bool {
        guard let port = ProviderConfig.readHTTPPort() else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            async let health = InstalledProviderMonitor.fetchHealth(port: port)
            async let status = InstalledProviderMonitor.fetchStatus(port: port)
            if await health?.ready == true, await status?.networkState == "buyer_serving" {
                return true
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                try await Task.sleep(nanoseconds: UInt64(min(2, remaining) * 1_000_000_000))
            } catch {
                return false
            }
        }
        return false
    }
}

private final class CLIUpdateOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""

    func append(_ text: String) {
        lock.lock()
        output.append(text)
        lock.unlock()
    }

    var containsRollbackRestored: Bool {
        lock.lock()
        defer { lock.unlock() }
        return output.contains("rollback_restored")
    }

    var containsRollbackFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return output.contains("rollback_failed")
    }
}
