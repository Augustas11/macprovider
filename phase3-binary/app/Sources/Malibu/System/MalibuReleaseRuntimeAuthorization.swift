import CryptoKit
import Darwin
import Dispatch
import Foundation
import Security

/// Runtime boundary for the installer-staged Malibu release sidecars.
///
/// The signed envelope cannot be embedded in the app artifact whose digest it
/// authenticates. The app installer therefore stages the envelope and index
/// under Malibu's Application Support directory. These sidecars are authority,
/// not a cache: Malibu refuses provider attachment and mutation when they are
/// missing or do not describe the running app and installed provider exactly.
enum MalibuReleaseRuntimeAuthorization {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case missingSidecar(String)
        case insecureSidecar(String)
        case missingBootstrapTrust(String)
        case appIdentityUnavailable(String)
        case appVersionMismatch(expected: String, actual: String)
        case appBuildMismatch(expected: Int, actual: Int)
        case appSigningIdentityMismatch
        case installedProviderRequired
        case installedProviderInvalid(String)
        case providerVersionMismatch(expected: String, actual: String)
        case providerDigestMismatch
        case compatibilitySetMismatch
        case protectedStateMissing
        case releaseContract(String)

        var errorDescription: String? {
            switch self {
            case .missingSidecar(let name):
                return "Malibu release authority is missing \(name). Reinstall Malibu from its signed package."
            case .insecureSidecar(let reason):
                return "Malibu release authority is unsafe (\(reason)). Reinstall Malibu from its signed package."
            case .missingBootstrapTrust(let name):
                return "Malibu bootstrap trust resource \(name) is missing. Reinstall the signed app."
            case .appIdentityUnavailable(let field):
                return "Malibu cannot verify its \(field). Reinstall the signed app."
            case let .appVersionMismatch(expected, actual):
                return "Malibu release authority expects app version \(expected), but this app is \(actual)."
            case let .appBuildMismatch(expected, actual):
                return "Malibu release authority expects app build \(expected), but this app is build \(actual)."
            case .appSigningIdentityMismatch:
                return "Malibu's signing identity does not match the signed release authority."
            case .installedProviderRequired:
                return "The installed provider is missing from the signed Malibu release transaction."
            case .installedProviderInvalid(let reason):
                return "The installed provider failed release validation (\(reason))."
            case let .providerVersionMismatch(expected, actual):
                return "Malibu release authority expects provider CLI \(expected), but \(actual) is installed."
            case .providerDigestMismatch:
                return "The installed provider CLI does not match the signed Malibu release authority."
            case .compatibilitySetMismatch:
                return "The installed provider compatibility set does not match the signed Malibu release authority."
            case .protectedStateMissing:
                return "Malibu's protected release state is missing. Reinstall Malibu before using the installed provider."
            case .releaseContract(let reason):
                return "Malibu release authority validation failed: \(reason)"
            }
        }
    }

    struct Paths {
        let activeDirectory: URL
        let transaction: URL
        let envelope: URL
        let index: URL
        let previousEnvelope: URL
        let previousIndex: URL
        let antiReplayState: URL

        init(appSupport: URL) {
            activeDirectory = appSupport
                .appendingPathComponent("Release", isDirectory: true)
                .appendingPathComponent("active", isDirectory: true)
            transaction = activeDirectory.appendingPathComponent("transaction.json")
            envelope = activeDirectory.appendingPathComponent("release-envelope.json")
            index = activeDirectory.appendingPathComponent("release-index.json")
            previousEnvelope = activeDirectory.appendingPathComponent("previous-release-envelope.json")
            previousIndex = activeDirectory.appendingPathComponent("previous-release-index.json")
            antiReplayState = appSupport.appendingPathComponent("release-anti-replay-v1.json")
        }

        static let live = Paths(appSupport: ProviderPaths.current.appSupport)
    }

    struct AppIdentity: Equatable {
        let marketingVersion: String
        let build: Int
        let bundleID: String
        let teamID: String
        let bundlePath: String
        let entryCount: Int
        let rootMode: Int
        let treeSHA256: String

        static func live(
            bundle: Bundle = .main,
            verifyCode: (URL) throws -> Void = { try validateCurrentBundleCode($0) },
            readTree: (URL) throws -> BundleTreeEvidence = { try bundleTreeEvidence($0) }
        ) throws -> AppIdentity {
            guard let marketingVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String else {
                throw Error.appIdentityUnavailable("marketing version")
            }
            guard let buildText = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  let build = Int(buildText), build > 0 else {
                throw Error.appIdentityUnavailable("build number")
            }
            guard let bundleID = bundle.bundleIdentifier else {
                throw Error.appIdentityUnavailable("bundle identifier")
            }
            let bundleURL = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            try verifyCode(bundleURL)
            let evidence = try readTree(bundleURL)
            // A second strict seal check closes the tree-hash mutation window.
            try verifyCode(bundleURL)
            return AppIdentity(
                marketingVersion: marketingVersion,
                build: build,
                bundleID: bundleID,
                teamID: "YF7XNRJUG4",
                bundlePath: bundleURL.path,
                entryCount: evidence.entryCount,
                rootMode: evidence.rootMode,
                treeSHA256: evidence.treeSHA256
            )
        }
    }

    struct InstalledProviderIdentity: Equatable {
        let version: String
        let binarySHA256: String
        let compatibilitySetID: String
        let compatibilityManifestSHA256: String
    }

    struct Receipt: Equatable {
        let envelope: MalibuReleaseEnvelopeIdentity
        let antiReplayState: MalibuReleaseAntiReplayState
        let installedProvider: InstalledProviderIdentity?
        let legacySourceAppVersion: String?
    }

    struct RootInstallMarker: Equatable {
        let appVersion: String
        let appBuild: Int
        let envelopeSHA256: String
        let indexSHA256: String
        let helperSHA256: String
        let validatorSHA256: String
        let keyringSHA256: String
        let revocationsSHA256: String
        let publicKeySHA256: String
        let transactionSHA256: String?
        let legacySourceAppVersion: String?

        init(
            appVersion: String,
            appBuild: Int,
            envelopeSHA256: String,
            indexSHA256: String,
            helperSHA256: String,
            validatorSHA256: String = "",
            keyringSHA256: String = "",
            revocationsSHA256: String = "",
            publicKeySHA256: String = "",
            transactionSHA256: String? = nil,
            legacySourceAppVersion: String? = nil
        ) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.envelopeSHA256 = envelopeSHA256
            self.indexSHA256 = indexSHA256
            self.helperSHA256 = helperSHA256
            self.validatorSHA256 = validatorSHA256
            self.keyringSHA256 = keyringSHA256
            self.revocationsSHA256 = revocationsSHA256
            self.publicKeySHA256 = publicKeySHA256
            self.transactionSHA256 = transactionSHA256
            self.legacySourceAppVersion = legacySourceAppVersion
        }
    }

    static func installedProviderEvidenceExists(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.isReadableFile(
            atPath: home.appendingPathComponent(
                "Library/Application Support/macprovider/install_manifest.json"
            ).path
        ) || fileManager.isExecutableFile(
            atPath: home.appendingPathComponent("macprovider/macprovider-cli").path
        )
    }

    static func authorizeLegacyBootstrapTarget(
        now: Date = Date(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> String {
        let authority = try authorizeLive(
            requireInstalledProvider: false,
            now: now,
            fileManager: fileManager
        )
        guard installedProviderEvidenceExists(home: home, fileManager: fileManager) else {
            return authority.envelope.providerCLIVersion
        }
        let installedVersion = try loadInstalledProviderVersionForBootstrap(
            home: home,
            fileManager: fileManager
        )
        guard authority.envelope.legacyBootstrap.authorizes(
            appVersion: authority.legacySourceAppVersion,
            cliVersion: installedVersion,
            now: now
        ) else {
            throw Error.releaseContract(
                "The installed provider is outside the signed legacy repair cohort or the repair bridge has expired."
            )
        }
        guard ProviderCLIVersion.compare(
            installedVersion,
            authority.envelope.providerCLIVersion
        ) != .descending else {
            throw Error.releaseContract("Signed legacy repair would downgrade the installed provider.")
        }
        return authority.envelope.providerCLIVersion
    }

    /// Persists a signed one-use rollback grant before the external app
    /// transaction swaps the app and current sidecars. The high-water tuple is
    /// immutable; runtime completion changes only the protected active tuple.
    static func prepareRollback(
        authorizationData: Data,
        trust: MalibuReleaseTrustPolicy,
        target: MalibuReleaseAntiReplayState,
        now: Date,
        protectedStore: MalibuReleaseProtectedStateStore = .live
    ) throws {
        guard let protected = try protectedStore.load(),
              protected.activeRelease == protected.highWater else {
            throw MalibuReleaseContractError.insecureState("protected state cannot begin rollback")
        }
        try validateTrust(trust, against: protected)
        let authorizationSHA256 = SHA256.hash(data: authorizationData).hexString
        let validation = try MalibuReleaseRollbackAuthorization.validate(
            authorizationData,
            trust: trust,
            now: now,
            current: protected.activeRelease,
            target: target
        )
        let grant = MalibuReleaseRollbackReceipt(
            authorizationSHA256: authorizationSHA256,
            nonce: validation.nonce,
            issuedAt: validation.issuedAt,
            expiresAt: validation.expiresAt,
            current: protected.highWater,
            target: target,
            keyringGeneration: trust.generation,
            keyringSHA256: trust.keyringSHA256,
            revocationsGeneration: trust.revocationsGeneration,
            revocationsSHA256: trust.revocationsSHA256,
            selectedKeyID: validation.keyID,
            selectedSPKISHA256: validation.spkiSHA256,
            transactionID: nil,
            transactionSHA256: nil,
            status: .pending
        )
        if let existing = protected.rollback {
            guard existing.status == .pending,
                  existing.current == grant.current,
                  existing.target == grant.target else {
                throw MalibuReleaseContractError.authorizationReplay
            }
            if existing == grant { return }
            guard now >= existing.expiresAt,
                  grant.issuedAt > existing.issuedAt else {
                throw MalibuReleaseContractError.authorizationReplay
            }
            let replacement = MalibuReleaseProtectedState(
                schemaVersion: protected.schemaVersion,
                revision: protected.revision + 1,
                highWater: protected.highWater,
                activeRelease: protected.activeRelease,
                keyringGenerationFloor: protected.keyringGenerationFloor,
                keyringSHA256: protected.keyringSHA256,
                revocationsGenerationFloor: protected.revocationsGenerationFloor,
                revocationsSHA256: protected.revocationsSHA256,
                legacySourceAppVersion: protected.legacySourceAppVersion,
                legacySourceTransactionSHA256: protected.legacySourceTransactionSHA256,
                rollback: grant,
                rotation: protected.rotation,
                retirement: protected.retirement
            )
            try protectedStore.save(replacement, expectedRevision: protected.revision)
            return
        }
        let next = MalibuReleaseProtectedState(
            schemaVersion: protected.schemaVersion,
            revision: protected.revision + 1,
            highWater: protected.highWater,
            activeRelease: protected.activeRelease,
            keyringGenerationFloor: protected.keyringGenerationFloor,
            keyringSHA256: protected.keyringSHA256,
            revocationsGenerationFloor: protected.revocationsGenerationFloor,
            revocationsSHA256: protected.revocationsSHA256,
            legacySourceAppVersion: protected.legacySourceAppVersion,
            legacySourceTransactionSHA256: protected.legacySourceTransactionSHA256,
            rollback: grant,
            rotation: protected.rotation,
            retirement: protected.retirement
        )
        try protectedStore.save(next, expectedRevision: protected.revision)
    }

    /// Operator-only rollback entrypoint. The signed authorization is first
    /// committed to protected state, then the retained root-owned transaction
    /// helper swaps the exact previous app/sidecar tuple. Normal startup
    /// validates the completed receipt and advances only the active tuple.
    static func applyLiveRollback(
        authorizationURL: URL,
        now: Date = Date(),
        protectedStore: MalibuReleaseProtectedStateStore = .live,
        paths: Paths = .live
    ) throws {
        _ = try authorizeLive(
            requireInstalledProvider: false,
            now: now,
            protectedStore: protectedStore,
            paths: paths
        )
        let app = try AppIdentity.live()
        guard let protected = try protectedStore.load() else {
            throw Error.protectedStateMissing
        }
        let trust = try runtimeTrust(
            bundledTrust: loadBundledTrust(bundle: .main),
            protectedState: protected
        )
        let transactionData = try readSidecar(
            paths.transaction,
            label: "transaction.json",
            fileManager: .default
        )
        let transaction = try MalibuReleaseStrictJSON.parseCanonicalObject(
            transactionData,
            label: "Malibu app transaction",
            allowFinalNewline: true
        )
        guard let previous = transaction["previous_release_state"] else {
            throw Error.releaseContract("No exact previous Malibu release is available for rollback.")
        }
        let target = try runtimeState(previous)
        let authorizationData = try readSidecar(
            authorizationURL,
            label: "rollback authorization",
            fileManager: .default
        )
        try prepareRollback(
            authorizationData: authorizationData,
            trust: trust,
            target: target,
            now: now,
            protectedStore: protectedStore
        )
        guard let grant = try protectedStore.load()?.rollback,
              grant.status == .pending else {
            throw MalibuReleaseContractError.rollbackStateMismatch
        }
        let releaseDirectory = paths.activeDirectory.deletingLastPathComponent()
        try reconcileRollbackInputs(releaseDirectory: releaseDirectory)
        let stagedAuthorization = try stageRollbackAuthorization(
            authorizationData,
            expectedSHA256: grant.authorizationSHA256,
            releaseDirectory: releaseDirectory
        )
        defer { try? FileManager.default.removeItem(at: stagedAuthorization) }
        let root = URL(
            fileURLWithPath: "/Library/Application Support/Malibu/AppInstaller",
            isDirectory: true
        ).appendingPathComponent("v\(app.marketingVersion)", isDirectory: true)
        let helper = root.appendingPathComponent("malibu-app-transaction.py")
        let keyring = root.appendingPathComponent("malibu-release-keyring.json")
        let revocations = root.appendingPathComponent("malibu-release-revocations.json")
        _ = try loadRootInstallMarker(app: app)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            helper.path,
            "rollback",
            "--destination-app", app.bundlePath,
            "--state-dir", releaseDirectory.path,
            "--expected-owner-uid", String(geteuid()),
            "--authorization", stagedAuthorization.path,
            "--expected-authorization-sha256", grant.authorizationSHA256,
            "--keyring", keyring.path,
            "--revocations", revocations.path,
            "--expected-key-id", grant.selectedKeyID,
            "--minimum-keyring-generation", String(grant.keyringGeneration),
        ]
        let errorURL = stagedAuthorization.deletingLastPathComponent().appendingPathComponent(
            ".helper-\(UUID().uuidString).stderr"
        )
        let errorDescriptor = open(
            errorURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard errorDescriptor >= 0 else {
            throw Error.releaseContract("Rollback helper error capture could not be secured.")
        }
        let errorHandle = FileHandle(fileDescriptor: errorDescriptor, closeOnDealloc: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorURL)
        }
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        do { try process.run() }
        catch { throw Error.releaseContract("Rollback helper could not start.") }
        if completion.wait(timeout: .now() + .seconds(180)) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + .seconds(5)) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + .seconds(5))
            }
            throw Error.releaseContract("Rollback helper timed out; restart Malibu to recover the transaction.")
        }
        try? errorHandle.close()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(
                data: (try? Data(contentsOf: errorURL))?.prefix(2_048) ?? Data(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown rollback failure"
            throw Error.releaseContract("Signed rollback failed: \(detail)")
        }
    }

    /// Removes owner-controlled transient rollback inputs left by a killed app
    /// or helper. Protected state is the durable retry authority; staged bytes
    /// are recreated only from an exact authorization digest on each attempt.
    static func reconcileRollbackInputs(
        releaseDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = releaseDirectory.appendingPathComponent(
            "rollback-inputs",
            isDirectory: true
        )
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 {
            guard errno == ENOENT else {
                throw Error.releaseContract("Rollback authorization staging directory could not be inspected.")
            }
            return
        }
        guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & mode_t(0o077) == 0 else {
            throw Error.releaseContract("Rollback authorization staging directory is unsafe.")
        }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries {
            var info = stat()
            guard lstat(entry.path, &info) == 0,
                  (info.st_mode & S_IFMT) != S_IFDIR else {
                throw Error.releaseContract("Rollback authorization staging entry is unsafe.")
            }
            try fileManager.removeItem(at: entry)
        }
        if rmdir(directory.path) != 0, errno != ENOENT, errno != ENOTEMPTY {
            throw Error.releaseContract("Rollback authorization staging directory could not be reconciled.")
        }
    }

    private static func stageRollbackAuthorization(
        _ data: Data,
        expectedSHA256: String,
        releaseDirectory: URL
    ) throws -> URL {
        guard SHA256.hash(data: data).hexString == expectedSHA256 else {
            throw MalibuReleaseContractError.rollbackStateMismatch
        }
        let directory = releaseDirectory.appendingPathComponent(
            "rollback-inputs",
            isDirectory: true
        )
        if mkdir(directory.path, mode_t(0o700)) != 0, errno != EEXIST {
            throw Error.releaseContract("Rollback authorization staging directory could not be created.")
        }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & mode_t(0o077) == 0 else {
            throw Error.releaseContract("Rollback authorization staging directory is unsafe.")
        }
        let staged = directory.appendingPathComponent("authorization-\(expectedSHA256).json")
        let descriptor = open(
            staged.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        if descriptor < 0 {
            guard errno == EEXIST else {
                throw Error.releaseContract("Rollback authorization could not be staged.")
            }
            let existing = try readSidecar(
                staged,
                label: "staged rollback authorization",
                fileManager: .default
            )
            guard existing == data,
                  SHA256.hash(data: existing).hexString == expectedSHA256 else {
                throw Error.releaseContract("Staged rollback authorization does not match protected state.")
            }
            return staged
        }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw Error.releaseContract("Rollback authorization is empty.")
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else {
                    throw Error.releaseContract("Rollback authorization staging write failed.")
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw Error.releaseContract("Rollback authorization staging was not durable.")
        }
        return staged
    }

    /// Ingests a dual-signed overlap transition into authenticated protected
    /// state. The successor trust is not active until a release index validates
    /// under its exact digests during normal runtime authorization.
    static func prepareRotation(
        authorizationData: Data,
        currentTrust: MalibuReleaseTrustPolicy,
        successorTrustBundle: MalibuReleaseTrustBundle,
        retiringKeyID: String,
        successorKeyID: String,
        overlapIndexData: Data,
        minimumIndexGeneration: Int,
        now: Date,
        protectedStore: MalibuReleaseProtectedStateStore = .live
    ) throws {
        guard let protected = try protectedStore.load(), protected.rotation == nil else {
            throw MalibuReleaseContractError.insecureState("protected state cannot begin key rotation")
        }
        try validateTrust(currentTrust, against: protected)
        let successorTrust = try successorTrustBundle.trustPolicy(
            minimumGeneration: currentTrust.generation + 1
        )
        let validation = try MalibuReleaseKeyRotationAuthorization.validateOverlap(
            authorizationData,
            currentTrust: currentTrust,
            successorTrust: successorTrust,
            retiringKeyID: retiringKeyID,
            successorKeyID: successorKeyID,
            overlapIndexData: overlapIndexData,
            minimumIndexGeneration: minimumIndexGeneration,
            now: now
        )
        let receipt = MalibuReleaseRotationReceipt(
            rotationID: validation.rotationID,
            currentKeyringGeneration: currentTrust.generation,
            currentKeyringSHA256: currentTrust.keyringSHA256,
            successorKeyringGeneration: successorTrust.generation,
            successorKeyringSHA256: successorTrust.keyringSHA256,
            successorRevocationsGeneration: successorTrust.revocationsGeneration,
            successorRevocationsSHA256: successorTrust.revocationsSHA256,
            overlapIndexGeneration: validation.overlapIndexGeneration,
            overlapIndexSHA256: validation.overlapIndexSHA256,
            retiringKeyID: retiringKeyID,
            successorKeyID: successorKeyID,
            successorTrustBundle: successorTrustBundle,
            status: .pending
        )
        let next = MalibuReleaseProtectedState(
            schemaVersion: protected.schemaVersion,
            revision: protected.revision + 1,
            highWater: protected.highWater,
            activeRelease: protected.activeRelease,
            keyringGenerationFloor: protected.keyringGenerationFloor,
            keyringSHA256: protected.keyringSHA256,
            revocationsGenerationFloor: protected.revocationsGenerationFloor,
            revocationsSHA256: protected.revocationsSHA256,
            legacySourceAppVersion: protected.legacySourceAppVersion,
            legacySourceTransactionSHA256: protected.legacySourceTransactionSHA256,
            rollback: protected.rollback,
            rotation: receipt,
            retirement: protected.retirement
        )
        try protectedStore.save(next, expectedRevision: protected.revision)
    }

    /// Validates a separately signed, one-use successor authorization and
    /// persists it before the retirement trust is made active.
    static func prepareRetirement(
        authorizationData: Data,
        overlapTrust: MalibuReleaseTrustPolicy,
        retirementTrustBundle: MalibuReleaseTrustBundle,
        now: Date,
        protectedStore: MalibuReleaseProtectedStateStore = .live
    ) throws {
        guard let protected = try protectedStore.load() else {
            throw MalibuReleaseContractError.rotationPolicyViolation
        }
        if protected.retirement != nil {
            throw MalibuReleaseContractError.authorizationReplay
        }
        guard let rotation = protected.rotation,
              rotation.status == .completed,
              protected.keyringGenerationFloor == overlapTrust.generation,
              protected.keyringSHA256 == overlapTrust.keyringSHA256,
              protected.revocationsGenerationFloor == overlapTrust.revocationsGeneration,
              protected.revocationsSHA256 == overlapTrust.revocationsSHA256 else {
            throw MalibuReleaseContractError.rotationPolicyViolation
        }
        try validateTrust(overlapTrust, against: protected)
        let retirementTrust = try retirementTrustBundle.trustPolicy(
            minimumGeneration: overlapTrust.generation + 1
        )
        let validation = try MalibuReleaseKeyRetirementAuthorization.validate(
            authorizationData,
            activeSuccessorTrust: overlapTrust,
            retirementTrust: retirementTrust,
            rotationID: rotation.rotationID,
            retiringKeyID: rotation.retiringKeyID,
            successorKeyID: rotation.successorKeyID,
            protectedRevision: protected.revision,
            highWater: protected.highWater,
            now: now
        )
        let pending = MalibuReleaseRetirementReceipt(
            authorizationSHA256: SHA256.hash(data: authorizationData).hexString,
            nonce: validation.nonce,
            rotationID: rotation.rotationID,
            protectedRevision: protected.revision,
            highWater: protected.highWater,
            retiringKeyID: rotation.retiringKeyID,
            successorKeyID: rotation.successorKeyID,
            overlapKeyringGeneration: overlapTrust.generation,
            overlapKeyringSHA256: overlapTrust.keyringSHA256,
            overlapRevocationsGeneration: overlapTrust.revocationsGeneration,
            overlapRevocationsSHA256: overlapTrust.revocationsSHA256,
            retirementKeyringGeneration: retirementTrust.generation,
            retirementKeyringSHA256: retirementTrust.keyringSHA256,
            retirementRevocationsGeneration: retirementTrust.revocationsGeneration,
            retirementRevocationsSHA256: retirementTrust.revocationsSHA256,
            retirementTrustBundle: retirementTrustBundle,
            status: .pending
        )
        let next = MalibuReleaseProtectedState(
            schemaVersion: protected.schemaVersion,
            revision: protected.revision + 1,
            highWater: protected.highWater,
            activeRelease: protected.activeRelease,
            keyringGenerationFloor: protected.keyringGenerationFloor,
            keyringSHA256: protected.keyringSHA256,
            revocationsGenerationFloor: protected.revocationsGenerationFloor,
            revocationsSHA256: protected.revocationsSHA256,
            legacySourceAppVersion: protected.legacySourceAppVersion,
            legacySourceTransactionSHA256: protected.legacySourceTransactionSHA256,
            rollback: protected.rollback,
            rotation: rotation,
            retirement: pending
        )
        try protectedStore.save(next, expectedRevision: protected.revision)
    }

    /// Completion consumes only an authenticated pending retirement receipt;
    /// two caller-provided trust objects cannot authorize retirement by themselves.
    static func retireRotation(
        overlapTrust: MalibuReleaseTrustPolicy,
        retirementTrust: MalibuReleaseTrustPolicy,
        protectedStore: MalibuReleaseProtectedStateStore = .live
    ) throws {
        guard let protected = try protectedStore.load(),
              let receipt = protected.rotation,
              receipt.status == .completed,
              let retirement = protected.retirement,
              retirement.status == .pending,
              retirement.protectedRevision + 1 == protected.revision,
              retirement.highWater == protected.highWater,
              retirement.rotationID == receipt.rotationID,
              retirement.retiringKeyID == receipt.retiringKeyID,
              retirement.successorKeyID == receipt.successorKeyID,
              protected.keyringGenerationFloor == overlapTrust.generation,
              protected.keyringSHA256 == overlapTrust.keyringSHA256,
              protected.revocationsGenerationFloor == overlapTrust.revocationsGeneration,
              protected.revocationsSHA256 == overlapTrust.revocationsSHA256,
              retirement.overlapKeyringGeneration == overlapTrust.generation,
              retirement.overlapKeyringSHA256 == overlapTrust.keyringSHA256,
              retirement.overlapRevocationsGeneration == overlapTrust.revocationsGeneration,
              retirement.overlapRevocationsSHA256 == overlapTrust.revocationsSHA256,
              retirement.retirementKeyringGeneration == retirementTrust.generation,
              retirement.retirementKeyringSHA256 == retirementTrust.keyringSHA256,
              retirement.retirementRevocationsGeneration == retirementTrust.revocationsGeneration,
              retirement.retirementRevocationsSHA256 == retirementTrust.revocationsSHA256 else {
            throw MalibuReleaseContractError.rotationPolicyViolation
        }
        try MalibuReleaseKeyRotationAuthorization.validateRetirement(
            overlapTrust: overlapTrust,
            retirementTrust: retirementTrust,
            retiringKeyID: receipt.retiringKeyID,
            successorKeyID: receipt.successorKeyID
        )
        let completed = MalibuReleaseRetirementReceipt(
            authorizationSHA256: retirement.authorizationSHA256,
            nonce: retirement.nonce,
            rotationID: retirement.rotationID,
            protectedRevision: retirement.protectedRevision,
            highWater: retirement.highWater,
            retiringKeyID: retirement.retiringKeyID,
            successorKeyID: retirement.successorKeyID,
            overlapKeyringGeneration: retirement.overlapKeyringGeneration,
            overlapKeyringSHA256: retirement.overlapKeyringSHA256,
            overlapRevocationsGeneration: retirement.overlapRevocationsGeneration,
            overlapRevocationsSHA256: retirement.overlapRevocationsSHA256,
            retirementKeyringGeneration: retirement.retirementKeyringGeneration,
            retirementKeyringSHA256: retirement.retirementKeyringSHA256,
            retirementRevocationsGeneration: retirement.retirementRevocationsGeneration,
            retirementRevocationsSHA256: retirement.retirementRevocationsSHA256,
            retirementTrustBundle: retirement.retirementTrustBundle,
            status: .completed
        )
        let next = MalibuReleaseProtectedState(
            schemaVersion: protected.schemaVersion,
            revision: protected.revision + 1,
            highWater: protected.highWater,
            activeRelease: protected.activeRelease,
            keyringGenerationFloor: retirementTrust.generation,
            keyringSHA256: retirementTrust.keyringSHA256,
            revocationsGenerationFloor: retirementTrust.revocationsGeneration,
            revocationsSHA256: retirementTrust.revocationsSHA256,
            legacySourceAppVersion: protected.legacySourceAppVersion,
            legacySourceTransactionSHA256: protected.legacySourceTransactionSHA256,
            rollback: protected.rollback,
            rotation: receipt,
            retirement: completed
        )
        try protectedStore.save(next, expectedRevision: protected.revision)
    }

    @discardableResult
    static func authorizeLive(
        requireInstalledProvider: Bool,
        now: Date = Date(),
        fileManager: FileManager = .default,
        protectedStore: MalibuReleaseProtectedStateStore = .live,
        verifyApp: () throws -> AppIdentity = { try AppIdentity.live() },
        paths: Paths = .live,
        bundledTrustLoader: () throws -> MalibuReleaseTrustPolicy = {
            try loadBundledTrust(bundle: .main)
        },
        installedProviderLoader: (FileManager) throws -> InstalledProviderIdentity = {
            try loadInstalledProviderIdentity(fileManager: $0)
        },
        rootInstallMarkerLoader: (AppIdentity) throws -> RootInstallMarker = {
            try loadRootInstallMarker(app: $0)
        },
        recoverTransaction: (AppIdentity, Paths) throws -> Void = {
            try reconcileTransactionJournal(app: $0, paths: $1)
        }
    ) throws -> Receipt {
        let protected = try protectedStore.load()
        let trust = try runtimeTrust(
            bundledTrust: bundledTrustLoader(),
            protectedState: protected
        )
        let app = try verifyApp()
        let rootInstallMarker = protected == nil ? try rootInstallMarkerLoader(app) : nil
        // The installer owns the crash journal. Reconcile it before any active
        // sidecar is read so app/tree and transaction evidence cannot be split.
        try recoverTransaction(app, paths)
        let provider = requireInstalledProvider
            ? try installedProviderLoader(fileManager)
            : nil
        let receipt = try authorize(
            paths: paths,
            trust: trust,
            app: app,
            installedProvider: provider,
            requireInstalledProvider: requireInstalledProvider,
            now: now,
            fileManager: fileManager,
            protectedStore: protectedStore,
            rootInstallMarker: rootInstallMarker,
            requireRootInstallMarker: true,
            requireCompletedRollbackReceipt: true
        )
        try reconcileRollbackInputs(
            releaseDirectory: paths.activeDirectory.deletingLastPathComponent(),
            fileManager: fileManager
        )
        return receipt
    }

    /// Validates the complete tuple before writing anti-replay state. Tests use
    /// this entry point with signed hermetic fixtures and synthetic identities.
    @discardableResult
    static func authorize(
        paths: Paths,
        trust: MalibuReleaseTrustPolicy,
        app: AppIdentity,
        installedProvider: InstalledProviderIdentity?,
        requireInstalledProvider: Bool,
        now: Date,
        fileManager: FileManager = .default,
        protectedStore: MalibuReleaseProtectedStateStore? = nil,
        priorReleaseEvidenceExists: Bool? = nil,
        rootInstallMarker: RootInstallMarker? = nil,
        requireRootInstallMarker: Bool = false,
        requireCompletedRollbackReceipt: Bool = false
    ) throws -> Receipt {
        do {
            let hasPreviousRelease = try validateActiveDirectory(paths.activeDirectory, fileManager: fileManager)
            let transactionData = try readSidecar(paths.transaction, label: "transaction.json", fileManager: fileManager)
            let envelopeData = try readSidecar(paths.envelope, label: "release-envelope.json", fileManager: fileManager)
            let indexData = try readSidecar(paths.index, label: "release-index.json", fileManager: fileManager)
            let previousEnvelopeData: Data?
            let previousIndexData: Data?
            if hasPreviousRelease {
                previousEnvelopeData = try readSidecar(
                    paths.previousEnvelope,
                    label: "previous-release-envelope.json",
                    fileManager: fileManager
                )
                previousIndexData = try readSidecar(
                    paths.previousIndex,
                    label: "previous-release-index.json",
                    fileManager: fileManager
                )
            } else {
                previousEnvelopeData = nil
                previousIndexData = nil
            }
            let transactionRoot = try MalibuReleaseStrictJSON.parseCanonicalObject(
                transactionData,
                label: "Malibu app transaction",
                allowFinalNewline: true
            )
            let hasPriorReleaseEvidence = priorReleaseEvidenceExists
                ?? (hasPreviousRelease || transactionRoot["state"] as? String == "rolled_back")
            let protected = try protectedStore?.load()
            if protected == nil, hasPriorReleaseEvidence {
                throw Error.protectedStateMissing
            }
            if let protected {
                try validateTrust(trust, against: protected)
            }
            let validationUse: MalibuReleaseValidationUse =
                protected == nil && rootInstallMarker == nil ? .discovery : .installedTransaction
            let envelope = try MalibuReleaseEnvelopeValidator.validateEnvelope(
                envelopeData,
                trust: trust,
                now: now,
                state: .empty,
                use: validationUse
            )
            let candidate = try MalibuReleaseEnvelopeValidator.validateIndex(
                indexData,
                envelopeData: envelopeData,
                trust: trust,
                now: now,
                state: .empty,
                use: validationUse
            )
            let authenticatedPreviousRelease: AuthenticatedPreviousRelease?
            if let previousEnvelopeData, let previousIndexData {
                let previousEnvelope = try MalibuReleaseEnvelopeValidator.validateEnvelope(
                    previousEnvelopeData,
                    trust: trust,
                    now: now,
                    state: .empty,
                    use: .installedTransaction
                )
                let previousState = try MalibuReleaseEnvelopeValidator.validateIndex(
                    previousIndexData,
                    envelopeData: previousEnvelopeData,
                    trust: trust,
                    now: now,
                    state: .empty,
                    use: .installedTransaction
                )
                authenticatedPreviousRelease = AuthenticatedPreviousRelease(
                    envelope: previousEnvelope,
                    state: previousState,
                    indexSHA256: SHA256.hash(data: previousIndexData).hexString
                )
            } else {
                authenticatedPreviousRelease = nil
            }
            if let rotation = protected?.rotation, rotation.status == .pending {
                guard candidate.highestIndexGeneration == rotation.overlapIndexGeneration,
                      SHA256.hash(data: indexData).hexString == rotation.overlapIndexSHA256 else {
                    throw MalibuReleaseContractError.rotationPolicyViolation
                }
            }

            guard app.bundleID == "tech.malibu.app", app.teamID == "YF7XNRJUG4" else {
                throw Error.appSigningIdentityMismatch
            }
            guard app.marketingVersion == envelope.marketingVersion else {
                throw Error.appVersionMismatch(
                    expected: envelope.marketingVersion,
                    actual: app.marketingVersion
                )
            }
            guard app.build == envelope.build else {
                throw Error.appBuildMismatch(expected: envelope.build, actual: app.build)
            }
            guard app.entryCount == envelope.entryCount,
                  app.rootMode == envelope.rootMode,
                  app.treeSHA256 == envelope.treeSHA256 else {
                throw Error.appIdentityUnavailable("signed bundle tree mismatch")
            }
            if protected == nil, requireRootInstallMarker {
                guard let marker = rootInstallMarker,
                      marker.appVersion == app.marketingVersion,
                      marker.appBuild == app.build,
                      marker.envelopeSHA256 == SHA256.hash(data: envelopeData).hexString,
                      marker.indexSHA256 == SHA256.hash(data: indexData).hexString else {
                    throw Error.protectedStateMissing
                }
            }
            let transaction = try validateTransaction(
                transactionData,
                envelopeData: envelopeData,
                indexData: indexData,
                app: app,
                envelope: envelope,
                nextState: candidate,
                authenticatedPreviousRelease: authenticatedPreviousRelease
            )
            if requireCompletedRollbackReceipt, transaction.state == "rolled_back" {
                guard let protected, let rollback = protected.rollback else {
                    throw MalibuReleaseContractError.rollbackStateMismatch
                }
                try validateCompletedRollbackReceipt(
                    paths: paths,
                    transactionData: transactionData,
                    transaction: transaction,
                    rollback: rollback,
                    trust: trust,
                    fileManager: fileManager
                )
            }

            if requireInstalledProvider, installedProvider == nil {
                throw Error.installedProviderRequired
            }
            if let installedProvider {
                guard installedProvider.version == envelope.providerCLIVersion else {
                    throw Error.providerVersionMismatch(
                        expected: envelope.providerCLIVersion,
                        actual: installedProvider.version
                    )
                }
                guard installedProvider.binarySHA256 == envelope.providerCLISHA256 else {
                    throw Error.providerDigestMismatch
                }
                guard installedProvider.compatibilitySetID == envelope.compatibilitySetID,
                      installedProvider.compatibilityManifestSHA256 == envelope.compatibilityManifestSHA256 else {
                    throw Error.compatibilitySetMismatch
                }
            }

            let accepted: MalibuReleaseAntiReplayState
            if let protected {
                if candidate == protected.highWater {
                    _ = try MalibuReleaseEnvelopeValidator.validateIndex(
                        indexData,
                        envelopeData: envelopeData,
                        trust: trust,
                        now: now,
                        state: protected.highWater,
                        use: .installedTransaction
                    )
                    accepted = candidate
                } else if dominates(candidate, protected.highWater) {
                    accepted = try MalibuReleaseEnvelopeValidator.validateIndex(
                        indexData,
                        envelopeData: envelopeData,
                        trust: trust,
                        now: now,
                        state: protected.highWater,
                        use: .installedTransaction
                    )
                } else {
                    guard transaction.state == "rolled_back",
                          let authorizationSHA256 = transaction.rollbackAuthorizationSHA256,
                          let rollback = protected.rollback,
                          rollback.authorizationSHA256 == authorizationSHA256,
                          rollback.current == protected.highWater,
                          rollback.target == candidate else {
                        throw MalibuReleaseContractError.rollbackStateMismatch
                    }
                    accepted = candidate
                }

                // Retirement is a one-use transition bound to this exact
                // protected revision and high-water state. Ordinary launches
                // may revalidate the already-active release without consuming
                // another revision, but no release/rollback advance may race
                // the pending retirement.
                if let retirement = protected.retirement, retirement.status == .pending {
                    guard accepted == protected.activeRelease,
                          protected.highWater == retirement.highWater else {
                        throw MalibuReleaseContractError.rotationPolicyViolation
                    }
                    return Receipt(
                        envelope: envelope,
                        antiReplayState: accepted,
                        installedProvider: installedProvider,
                        legacySourceAppVersion: transaction.legacySourceAppVersion
                    )
                }

                let completedRollback: MalibuReleaseRollbackReceipt?
                if dominates(accepted, protected.highWater),
                   accepted != protected.highWater {
                    guard protected.rollback?.status != .pending else {
                        throw MalibuReleaseContractError.rollbackStateMismatch
                    }
                    completedRollback = nil
                } else if accepted != protected.highWater {
                    guard let rollback = protected.rollback else {
                        throw MalibuReleaseContractError.rollbackStateMismatch
                    }
                    completedRollback = MalibuReleaseRollbackReceipt(
                        authorizationSHA256: rollback.authorizationSHA256,
                        nonce: rollback.nonce,
                        issuedAt: rollback.issuedAt,
                        expiresAt: rollback.expiresAt,
                        current: rollback.current,
                        target: rollback.target,
                        keyringGeneration: rollback.keyringGeneration,
                        keyringSHA256: rollback.keyringSHA256,
                        revocationsGeneration: rollback.revocationsGeneration,
                        revocationsSHA256: rollback.revocationsSHA256,
                        selectedKeyID: rollback.selectedKeyID,
                        selectedSPKISHA256: rollback.selectedSPKISHA256,
                        transactionID: transaction.transactionID,
                        transactionSHA256: transaction.transactionSHA256,
                        status: .completed
                    )
                } else {
                    completedRollback = protected.rollback
                }
                let completedRotation: MalibuReleaseRotationReceipt?
                if let rotation = protected.rotation,
                   rotation.status == .pending,
                   trust.generation == rotation.successorKeyringGeneration,
                   trust.keyringSHA256 == rotation.successorKeyringSHA256 {
                    completedRotation = MalibuReleaseRotationReceipt(
                        rotationID: rotation.rotationID,
                        currentKeyringGeneration: rotation.currentKeyringGeneration,
                        currentKeyringSHA256: rotation.currentKeyringSHA256,
                        successorKeyringGeneration: rotation.successorKeyringGeneration,
                        successorKeyringSHA256: rotation.successorKeyringSHA256,
                        successorRevocationsGeneration: rotation.successorRevocationsGeneration,
                        successorRevocationsSHA256: rotation.successorRevocationsSHA256,
                        overlapIndexGeneration: rotation.overlapIndexGeneration,
                        overlapIndexSHA256: rotation.overlapIndexSHA256,
                        retiringKeyID: rotation.retiringKeyID,
                        successorKeyID: rotation.successorKeyID,
                        successorTrustBundle: rotation.successorTrustBundle,
                        status: .completed
                    )
                } else {
                    completedRotation = protected.rotation
                }
                let nextProtected = MalibuReleaseProtectedState(
                    schemaVersion: protected.schemaVersion,
                    revision: protected.revision + 1,
                    highWater: dominates(accepted, protected.highWater) ? accepted : protected.highWater,
                    activeRelease: accepted,
                    keyringGenerationFloor: max(protected.keyringGenerationFloor, trust.generation),
                    keyringSHA256: trust.keyringSHA256,
                    revocationsGenerationFloor: max(protected.revocationsGenerationFloor, trust.revocationsGeneration),
                    revocationsSHA256: trust.revocationsSHA256,
                    legacySourceAppVersion: protected.legacySourceAppVersion,
                    legacySourceTransactionSHA256: protected.legacySourceTransactionSHA256,
                    rollback: completedRollback,
                    rotation: completedRotation,
                    retirement: protected.retirement
                )
                // Final side effect: protected state advances only after every
                // code, transaction, provider, and signed metadata check.
                try protectedStore?.save(nextProtected, expectedRevision: protected.revision)
            } else {
                accepted = candidate
                if let protectedStore {
                    try protectedStore.save(
                        .bootstrap(release: accepted, trust: trust),
                        expectedRevision: nil
                    )
                }
            }
            return Receipt(
                envelope: envelope,
                antiReplayState: accepted,
                installedProvider: installedProvider,
                legacySourceAppVersion: transaction.legacySourceAppVersion
            )
        } catch let error as Error {
            throw error
        } catch let error as MalibuReleaseContractError {
            throw Error.releaseContract(error.localizedDescription)
        } catch {
            throw Error.releaseContract(error.localizedDescription)
        }
    }

    private static func validateActiveDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw Error.missingSidecar("active release transaction directory")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o022) == 0 else {
            throw Error.insecureSidecar("active release transaction directory ownership or mode")
        }
        let entries = try Set(fileManager.contentsOfDirectory(atPath: url.path))
        let current: Set<String> = [
            "release-envelope.json", "release-index.json", "transaction.json",
        ]
        let upgraded = current.union([
            "previous-release-envelope.json", "previous-release-index.json",
        ])
        guard entries == current || entries == upgraded else {
            throw Error.insecureSidecar("active release transaction directory has unexpected entries")
        }
        return entries == upgraded
    }

    private static func validateTransaction(
        _ data: Data,
        envelopeData: Data,
        indexData: Data,
        app: AppIdentity,
        envelope: MalibuReleaseEnvelopeIdentity,
        nextState: MalibuReleaseAntiReplayState,
        authenticatedPreviousRelease: AuthenticatedPreviousRelease?
    ) throws -> TransactionIdentity {
        let record: [String: Any]
        do {
            record = try MalibuReleaseStrictJSON.parseCanonicalObject(
                data,
                label: "Malibu app transaction",
                allowFinalNewline: true
            )
        } catch let error as MalibuReleaseContractError {
            throw Error.insecureSidecar("transaction.json: \(error.localizedDescription)")
        }
        let baseKeys: Set<String> = [
            "destination_app", "installed", "installed_release_state", "previous",
            "previous_release", "previous_release_index_sha256", "previous_release_state", "release",
            "release_envelope_sha256", "release_index_sha256", "rollback_backup",
            "schema_version", "state", "transaction_id", "unix_time",
        ]
        let state = record["state"] as? String
        let expectedKeys = baseKeys.union(state == "rolled_back" ? [
            "rollback_authorization_sha256", "rolled_back_from", "rolled_back_from_release_state",
        ] : [])
        guard Set(record.keys) == expectedKeys,
              record["schema_version"] as? String == "malibu.app-transaction.v1",
              state == "installed" || state == "rolled_back",
              let transactionID = record["transaction_id"] as? String,
              transactionID.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              let timestamp = integer(record["unix_time"]), timestamp > 0,
              let destination = record["destination_app"] as? String,
              destination == app.bundlePath else {
            throw Error.insecureSidecar("transaction.json has unsupported identity or state")
        }

        let envelopeDigest = SHA256.hash(data: envelopeData).hexString
        let indexDigest = SHA256.hash(data: indexData).hexString
        guard record["release_envelope_sha256"] as? String == envelopeDigest,
              record["release_index_sha256"] as? String == indexDigest else {
            throw Error.insecureSidecar("transaction.json sidecar digest binding")
        }

        let previousReleaseState = record["previous_release_state"] as? [String: Any]
        let previousRelease = record["previous_release"] as? [String: Any]
        let previousApp = record["previous"] as? [String: Any]
        let previousIndexDigest = record["previous_release_index_sha256"] as? String
        let hasPreviousEvidence = previousReleaseState != nil
        guard hasPreviousEvidence == (previousRelease != nil),
              hasPreviousEvidence == (previousApp != nil),
              hasPreviousEvidence == (previousIndexDigest != nil),
              hasPreviousEvidence == (authenticatedPreviousRelease != nil),
              !hasPreviousEvidence || previousIndexDigest?.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil else {
            throw Error.insecureSidecar("transaction.json previous release evidence")
        }
        if let previousApp, let authenticatedPreviousRelease {
            let signedEnvelope = authenticatedPreviousRelease.envelope
            let signedState = authenticatedPreviousRelease.state
            guard Set(previousApp.keys) == [
                "build", "bundle_id", "entry_count", "marketing_version", "root_mode", "tree_sha256",
            ],
            let version = previousApp["marketing_version"] as? String,
            ProviderCLIVersion.strictNormalize(version) != nil,
            version == signedEnvelope.marketingVersion,
            previousApp["bundle_id"] as? String == app.bundleID,
            integer(previousApp["build"]) == signedEnvelope.build,
            integer(previousApp["entry_count"]) == signedEnvelope.entryCount,
            integer(previousApp["root_mode"]) == signedEnvelope.rootMode,
            previousApp["tree_sha256"] as? String == signedEnvelope.treeSHA256 else {
                throw Error.insecureSidecar("transaction.json previous app evidence")
            }
            guard let previousRelease,
                  Set(previousRelease.keys) == [
                      "app_build", "app_entry_count", "app_root_mode", "app_tree_sha256",
                      "app_version", "envelope_generation", "index_generation",
                  ],
                  integer(previousRelease["app_build"]) == signedEnvelope.build,
                  integer(previousRelease["app_entry_count"]) == signedEnvelope.entryCount,
                  integer(previousRelease["app_root_mode"]) == signedEnvelope.rootMode,
                  previousRelease["app_tree_sha256"] as? String == signedEnvelope.treeSHA256,
                  previousRelease["app_version"] as? String == signedEnvelope.marketingVersion,
                  integer(previousRelease["envelope_generation"]) == signedEnvelope.generation,
                  integer(previousRelease["index_generation"]) == signedState.highestIndexGeneration else {
                throw Error.insecureSidecar("transaction.json previous signed release evidence")
            }
            guard let previousReleaseState,
                  Set(previousReleaseState.keys) == [
                      "build", "envelope_generation", "envelope_sha256", "index_generation",
                  ],
                  integer(previousReleaseState["build"]) == signedState.highestBuild,
                  integer(previousReleaseState["envelope_generation"]) == signedState.highestEnvelopeGeneration,
                  previousReleaseState["envelope_sha256"] as? String == signedState.envelopeSHA256,
                  integer(previousReleaseState["index_generation"]) == signedState.highestIndexGeneration,
                  previousIndexDigest == authenticatedPreviousRelease.indexSHA256 else {
                throw Error.insecureSidecar("transaction.json previous release state")
            }
        }

        guard let installed = record["installed"] as? [String: Any],
              Set(installed.keys) == [
                  "build", "bundle_id", "entry_count", "marketing_version", "root_mode", "tree_sha256",
              ],
              installed["bundle_id"] as? String == app.bundleID,
              installed["marketing_version"] as? String == app.marketingVersion,
              integer(installed["build"]) == app.build,
              integer(installed["entry_count"]) == app.entryCount,
              integer(installed["root_mode"]) == app.rootMode,
              let treeDigest = installed["tree_sha256"] as? String,
              treeDigest == app.treeSHA256 else {
            throw Error.insecureSidecar("transaction.json installed app evidence")
        }

        guard let release = record["release"] as? [String: Any],
              Set(release.keys) == [
                  "app_build", "app_entry_count", "app_root_mode", "app_tree_sha256",
                  "app_version", "envelope_generation", "index_generation",
              ],
              integer(release["app_build"]) == envelope.build,
              integer(release["app_entry_count"]) == envelope.entryCount,
              integer(release["app_root_mode"]) == envelope.rootMode,
              release["app_tree_sha256"] as? String == envelope.treeSHA256,
              release["app_version"] as? String == envelope.marketingVersion,
              integer(release["envelope_generation"]) == envelope.generation,
              integer(release["index_generation"]) == nextState.highestIndexGeneration else {
            throw Error.insecureSidecar("transaction.json signed release evidence")
        }

        guard let installedReleaseState = record["installed_release_state"] as? [String: Any],
              Set(installedReleaseState.keys) == [
                  "build", "envelope_generation", "envelope_sha256", "index_generation",
              ],
              integer(installedReleaseState["build"]) == envelope.build,
              integer(installedReleaseState["envelope_generation"]) == envelope.generation,
              installedReleaseState["envelope_sha256"] as? String == envelopeDigest,
              integer(installedReleaseState["index_generation"]) == nextState.highestIndexGeneration else {
            throw Error.insecureSidecar("transaction.json installed release state")
        }

        if state == "rolled_back" {
            guard record["rollback_backup"] is NSNull,
                  let authorizationDigest = record["rollback_authorization_sha256"] as? String,
                  authorizationDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  record["rolled_back_from"] is [String: Any],
                  record["rolled_back_from_release_state"] is [String: Any] else {
                throw Error.insecureSidecar("transaction.json rollback evidence")
            }
        }
        return TransactionIdentity(
            state: state!,
            rollbackAuthorizationSHA256: record["rollback_authorization_sha256"] as? String,
            transactionID: transactionID,
            transactionSHA256: SHA256.hash(data: data).hexString,
            legacySourceAppVersion: previousApp?["marketing_version"] as? String
        )
    }

    private struct TransactionIdentity {
        let state: String
        let rollbackAuthorizationSHA256: String?
        let transactionID: String
        let transactionSHA256: String
        let legacySourceAppVersion: String?
    }

    private struct AuthenticatedPreviousRelease {
        let envelope: MalibuReleaseEnvelopeIdentity
        let state: MalibuReleaseAntiReplayState
        let indexSHA256: String
    }

    private static func validateCompletedRollbackReceipt(
        paths: Paths,
        transactionData: Data,
        transaction: TransactionIdentity,
        rollback: MalibuReleaseRollbackReceipt,
        trust: MalibuReleaseTrustPolicy,
        fileManager: FileManager
    ) throws {
        guard transaction.rollbackAuthorizationSHA256 == rollback.authorizationSHA256,
              trust.generation == rollback.keyringGeneration,
              trust.keyringSHA256 == rollback.keyringSHA256,
              trust.revocationsGeneration == rollback.revocationsGeneration,
              trust.revocationsSHA256 == rollback.revocationsSHA256,
              trust.keys[rollback.selectedKeyID]?.spkiSHA256 == rollback.selectedSPKISHA256 else {
            throw MalibuReleaseContractError.rollbackStateMismatch
        }
        let receiptDigest = SHA256.hash(
            data: Data("rollback\u{0}\(rollback.nonce)".utf8)
        ).hexString
        let receiptURL = paths.activeDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("rollback-authorizations", isDirectory: true)
            .appendingPathComponent("completed-\(receiptDigest).json")
        let data = try readSidecar(
            receiptURL,
            label: "completed rollback authorization receipt",
            fileManager: fileManager
        )
        let receipt = try MalibuReleaseStrictJSON.parseCanonicalObject(
            data,
            label: "completed rollback authorization receipt",
            allowFinalNewline: true
        )
        try exactRuntimeKeys(
            receipt,
            [
                "authorization_sha256", "current", "nonce", "schema_version", "status", "target",
                "transaction_id", "transaction_sha256", "trust",
            ],
            label: "completed rollback authorization receipt"
        )
        guard receipt["schema_version"] as? String == "malibu.rollback-authorization-receipt.v1",
              receipt["status"] as? String == "completed",
              receipt["authorization_sha256"] as? String == rollback.authorizationSHA256,
              receipt["nonce"] as? String == rollback.nonce,
              receipt["transaction_id"] as? String == transaction.transactionID,
              receipt["transaction_sha256"] as? String == transaction.transactionSHA256,
              SHA256.hash(data: transactionData).hexString == transaction.transactionSHA256,
              try runtimeState(receipt["current"]) == rollback.current,
              try runtimeState(receipt["target"]) == rollback.target,
              let receiptTrust = receipt["trust"] as? [String: Any] else {
            throw MalibuReleaseContractError.rollbackStateMismatch
        }
        try exactRuntimeKeys(
            receiptTrust,
            [
                "key_id", "keyring_generation", "keyring_sha256", "public_key_spki_sha256",
                "revocations_generation", "revocations_sha256",
            ],
            label: "completed rollback trust"
        )
        guard receiptTrust["key_id"] as? String == rollback.selectedKeyID,
              integer(receiptTrust["keyring_generation"]) == rollback.keyringGeneration,
              receiptTrust["keyring_sha256"] as? String == rollback.keyringSHA256,
              receiptTrust["public_key_spki_sha256"] as? String == rollback.selectedSPKISHA256,
              integer(receiptTrust["revocations_generation"]) == rollback.revocationsGeneration,
              receiptTrust["revocations_sha256"] as? String == rollback.revocationsSHA256 else {
            throw MalibuReleaseContractError.rollbackStateMismatch
        }
    }

    private static func exactRuntimeKeys(
        _ value: [String: Any],
        _ expected: Set<String>,
        label: String
    ) throws {
        guard Set(value.keys) == expected else {
            throw Error.insecureSidecar("\(label) fields differ")
        }
    }

    private static func runtimeState(_ raw: Any?) throws -> MalibuReleaseAntiReplayState {
        guard let value = raw as? [String: Any] else {
            throw MalibuReleaseContractError.rollbackStateMismatch
        }
        try exactRuntimeKeys(
            value,
            ["build", "envelope_generation", "envelope_sha256", "index_generation"],
            label: "rollback receipt release state"
        )
        guard let build = integer(value["build"]), build > 0,
              let envelope = integer(value["envelope_generation"]), envelope > 0,
              let index = integer(value["index_generation"]), index > 0,
              let digest = value["envelope_sha256"] as? String,
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw MalibuReleaseContractError.rollbackStateMismatch
        }
        return MalibuReleaseAntiReplayState(
            schemaVersion: "malibu-release-anti-replay.v1",
            highestIndexGeneration: index,
            highestBuild: build,
            highestEnvelopeGeneration: envelope,
            envelopeSHA256: digest
        )
    }

    private static func dominates(
        _ lhs: MalibuReleaseAntiReplayState,
        _ rhs: MalibuReleaseAntiReplayState
    ) -> Bool {
        lhs.highestIndexGeneration >= rhs.highestIndexGeneration
            && lhs.highestBuild >= rhs.highestBuild
            && lhs.highestEnvelopeGeneration >= rhs.highestEnvelopeGeneration
    }

    private static func validateTrust(
        _ trust: MalibuReleaseTrustPolicy,
        against state: MalibuReleaseProtectedState
    ) throws {
        guard trust.generation >= state.keyringGenerationFloor,
              trust.revocationsGeneration >= state.revocationsGenerationFloor else {
            throw MalibuReleaseContractError.keyringRollback
        }
        if trust.generation == state.keyringGenerationFloor {
            guard trust.keyringSHA256 == state.keyringSHA256,
                  trust.revocationsSHA256 == state.revocationsSHA256 else {
                throw MalibuReleaseContractError.digestMismatch
            }
        } else {
            guard let rotation = state.rotation,
                  rotation.successorKeyringGeneration == trust.generation,
                  rotation.successorKeyringSHA256 == trust.keyringSHA256,
                  rotation.successorRevocationsGeneration == trust.revocationsGeneration,
                  rotation.successorRevocationsSHA256 == trust.revocationsSHA256 else {
                throw MalibuReleaseContractError.rotationPolicyViolation
            }
        }
    }

    /// Selects only trust bytes already authenticated inside protected state.
    /// Bundled generation one remains the bootstrap when no accepted transition
    /// exists; pending overlap must be usable so normal authorization can mark it
    /// completed, and completed retirement becomes the new active policy.
    static func runtimeTrust(
        bundledTrust: MalibuReleaseTrustPolicy,
        protectedState: MalibuReleaseProtectedState?
    ) throws -> MalibuReleaseTrustPolicy {
        guard let protectedState else { return bundledTrust }
        let selected: MalibuReleaseTrustPolicy
        if let retirement = protectedState.retirement, retirement.status == .completed {
            selected = try retirement.retirementTrustBundle.trustPolicy(
                minimumGeneration: retirement.retirementKeyringGeneration
            )
        } else if let rotation = protectedState.rotation {
            selected = try rotation.successorTrustBundle.trustPolicy(
                minimumGeneration: rotation.successorKeyringGeneration
            )
        } else {
            selected = bundledTrust
        }
        try validateTrust(selected, against: protectedState)
        return selected
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    private static func loadBundledTrust(bundle: Bundle) throws -> MalibuReleaseTrustPolicy {
        guard let resources = bundle.resourceURL else {
            throw Error.missingBootstrapTrust("ReleaseTrust")
        }
        // Xcode copies resource-group members into Contents/Resources. Their
        // filenames remain fixed and the enclosing app code signature protects
        // all three bootstrap trust objects.
        let keyringURL = resources.appendingPathComponent("malibu-release-keyring.json")
        let revocationsURL = resources.appendingPathComponent("malibu-release-revocations.json")
        let publicKeyURL = resources.appendingPathComponent("release-signing-public.pem")
        for (name, url) in [
            ("malibu-release-keyring.json", keyringURL),
            ("malibu-release-revocations.json", revocationsURL),
            ("release-signing-public.pem", publicKeyURL),
        ] where !FileManager.default.isReadableFile(atPath: url.path) {
            throw Error.missingBootstrapTrust(name)
        }
        let keyringData = try Data(contentsOf: keyringURL)
        let revocationsData = try Data(contentsOf: revocationsURL)
        return try MalibuReleaseTrustPolicy.parse(
            keyringData: keyringData,
            revocationsData: revocationsData,
            minimumGeneration: 1,
            publicKeyLoader: { path in
                guard path == "release-signing-public.pem" else {
                    throw Error.missingBootstrapTrust(path)
                }
                return try Data(contentsOf: publicKeyURL)
            }
        )
    }

    private static func reconcileTransactionJournal(app: AppIdentity, paths: Paths) throws {
        let installerRoot = URL(
            fileURLWithPath: "/Library/Application Support/Malibu/AppInstaller",
            isDirectory: true
        )
        let selectorURL = installerRoot.appendingPathComponent("pending-recovery.json")
        let script: URL
        if FileManager.default.fileExists(atPath: selectorURL.path) {
            let selectorData = try readRootOwnedRegularFile(selectorURL, maximumBytes: 4_096)
            let selector = try MalibuReleaseStrictJSON.parseCanonicalObject(
                selectorData,
                label: "transaction recovery selector",
                allowFinalNewline: true
            )
            try exactRuntimeKeys(
                selector,
                [
                    "app_build", "app_version", "envelope_sha256", "helper_path",
                    "helper_sha256", "index_sha256", "keyring_sha256",
                    "public_key_sha256", "revocations_sha256", "schema_version",
                    "validator_sha256",
                ],
                label: "transaction recovery selector"
            )
            guard selector["schema_version"] as? String == "malibu-recovery-selector.v1",
                  let helperPath = selector["helper_path"] as? String,
                  helperPath.range(
                    of: #"^/Library/Application Support/Malibu/AppInstaller/v[0-9]+\.[0-9]+\.[0-9]+/malibu-app-transaction\.py$"#,
                    options: .regularExpression
                  ) != nil,
                  let helperSHA256 = selector["helper_sha256"] as? String else {
                throw Error.insecureSidecar("transaction recovery selector is invalid")
            }
            script = URL(fileURLWithPath: helperPath)
            let helperData = try readRootOwnedRegularFile(script, maximumBytes: 1_048_576)
            guard SHA256.hash(data: helperData).hexString == helperSHA256 else {
                throw Error.insecureSidecar("transaction recovery selector helper digest differs")
            }
        } else {
            script = installerRoot
                .appendingPathComponent("v\(app.marketingVersion)", isDirectory: true)
                .appendingPathComponent("malibu-app-transaction.py")
            _ = try readRootOwnedRegularFile(script, maximumBytes: 1_048_576)
        }
        _ = try readRootOwnedRegularFile(
            URL(fileURLWithPath: "/usr/bin/python3"),
            maximumBytes: 1_048_576
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            script.path,
            "recover",
            "--destination-app", app.bundlePath,
            "--state-dir", paths.activeDirectory.deletingLastPathComponent().path,
            "--expected-owner-uid", String(geteuid()),
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        do { try process.run() }
        catch { throw Error.insecureSidecar("transaction recovery helper could not start") }
        if completion.wait(timeout: .now() + .seconds(30)) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + .seconds(2)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + .seconds(2))
            }
            throw Error.insecureSidecar("transaction recovery timed out")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile().prefix(1_024),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown recovery failure"
            throw Error.insecureSidecar("transaction recovery failed: \(detail)")
        }
        let resultData = output.fileHandleForReading.readDataToEndOfFile()
        let result = try MalibuReleaseStrictJSON.parseCanonicalObject(
            resultData,
            label: "transaction recovery result",
            allowFinalNewline: true
        )
        try exactRuntimeKeys(
            result,
            [
                "recovered", "rollback_authorization_sha256", "state", "transaction_sha256",
            ],
            label: "transaction recovery result"
        )
        guard ["none", "old", "new"].contains(result["recovered"] as? String),
              result["state"] is NSNull || result["state"] as? String == "installed"
                || result["state"] as? String == "rolled_back" else {
            throw Error.insecureSidecar("transaction recovery result is invalid")
        }
    }

    private static func loadRootInstallMarker(app: AppIdentity) throws -> RootInstallMarker {
        let directory = URL(
            fileURLWithPath: "/Library/Application Support/Malibu/AppInstaller",
            isDirectory: true
        ).appendingPathComponent("v\(app.marketingVersion)", isDirectory: true)
        let helper = directory.appendingPathComponent("malibu-app-transaction.py")
        let validator = directory.appendingPathComponent("malibu-release-envelope.py")
        let keyring = directory.appendingPathComponent("malibu-release-keyring.json")
        let revocations = directory.appendingPathComponent("malibu-release-revocations.json")
        let publicKey = directory.appendingPathComponent("release-signing-public.pem")
        let markerURL = directory.deletingLastPathComponent().appendingPathComponent(
            "installed-marker.json"
        )
        let selectorURL = directory.deletingLastPathComponent().appendingPathComponent(
            "pending-recovery.json"
        )
        let helperData = try readRootOwnedRegularFile(helper, maximumBytes: 1_048_576)
        let validatorData = try readRootOwnedRegularFile(validator, maximumBytes: 1_048_576)
        let keyringData = try readRootOwnedRegularFile(keyring, maximumBytes: 65_536)
        let revocationsData = try readRootOwnedRegularFile(revocations, maximumBytes: 65_536)
        let publicKeyData = try readRootOwnedRegularFile(publicKey, maximumBytes: 16_384)
        var markerInfo = stat()
        let usesInstalledMarker = lstat(markerURL.path, &markerInfo) == 0
        if !usesInstalledMarker && errno != ENOENT {
            throw Error.insecureSidecar("root install marker cannot be inspected")
        }
        let markerData = try readRootOwnedRegularFile(
            usesInstalledMarker ? markerURL : selectorURL,
            maximumBytes: 4_096
        )
        let value = try MalibuReleaseStrictJSON.parseCanonicalObject(
            markerData,
            label: usesInstalledMarker ? "root install marker" : "pending recovery authority",
            allowFinalNewline: true
        )
        let expectedKeys = Set([
            "app_build", "app_version", "envelope_sha256", "helper_sha256",
            "index_sha256", "keyring_sha256", "public_key_sha256",
            "revocations_sha256", "schema_version", "validator_sha256",
        ]).union(usesInstalledMarker
            ? ["legacy_source_app_version", "transaction_sha256"]
            : ["helper_path"])
        try exactRuntimeKeys(
            value,
            expectedKeys,
            label: usesInstalledMarker ? "root install marker" : "pending recovery authority"
        )
        let expectedSchema = usesInstalledMarker
            ? "malibu-root-install-marker.v1"
            : "malibu-recovery-selector.v1"
        guard value["schema_version"] as? String == expectedSchema,
              usesInstalledMarker || value["helper_path"] as? String == helper.path,
              let appVersion = value["app_version"] as? String,
              let appBuild = integer(value["app_build"]), appBuild > 0,
              let envelopeSHA256 = value["envelope_sha256"] as? String,
              let indexSHA256 = value["index_sha256"] as? String,
              let helperSHA256 = value["helper_sha256"] as? String,
              let validatorSHA256 = value["validator_sha256"] as? String,
              let keyringSHA256 = value["keyring_sha256"] as? String,
              let revocationsSHA256 = value["revocations_sha256"] as? String,
              let publicKeySHA256 = value["public_key_sha256"] as? String,
              [envelopeSHA256, indexSHA256, helperSHA256, validatorSHA256,
               keyringSHA256, revocationsSHA256, publicKeySHA256].allSatisfy({
                  $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
              }),
              helperSHA256 == SHA256.hash(data: helperData).hexString,
              validatorSHA256 == SHA256.hash(data: validatorData).hexString,
              keyringSHA256 == SHA256.hash(data: keyringData).hexString,
              revocationsSHA256 == SHA256.hash(data: revocationsData).hexString,
              publicKeySHA256 == SHA256.hash(data: publicKeyData).hexString else {
            throw Error.insecureSidecar("root install marker is invalid")
        }
        let transactionSHA256: String?
        let legacySourceAppVersion: String?
        if usesInstalledMarker {
            guard let digest = value["transaction_sha256"] as? String,
                  digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  value["legacy_source_app_version"] is NSNull
                    || value["legacy_source_app_version"] is String else {
                throw Error.insecureSidecar("root install marker legacy attestation is invalid")
            }
            transactionSHA256 = digest
            legacySourceAppVersion = value["legacy_source_app_version"] as? String
            if let legacySourceAppVersion,
               ProviderCLIVersion.strictNormalize(legacySourceAppVersion) == nil {
                throw Error.insecureSidecar("root install marker legacy version is invalid")
            }
        } else {
            transactionSHA256 = nil
            legacySourceAppVersion = nil
        }
        return RootInstallMarker(
            appVersion: appVersion,
            appBuild: appBuild,
            envelopeSHA256: envelopeSHA256,
            indexSHA256: indexSHA256,
            helperSHA256: helperSHA256,
            validatorSHA256: validatorSHA256,
            keyringSHA256: keyringSHA256,
            revocationsSHA256: revocationsSHA256,
            publicKeySHA256: publicKeySHA256,
            transactionSHA256: transactionSHA256,
            legacySourceAppVersion: legacySourceAppVersion
        )
    }

    private static func readRootOwnedRegularFile(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Error.insecureSidecar("root-owned installer evidence is missing")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0,
              info.st_nlink == 1,
              info.st_mode & mode_t(0o022) == 0,
              info.st_size > 0,
              info.st_size <= maximumBytes else {
            throw Error.insecureSidecar("root-owned installer evidence is unsafe")
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let result = read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if result <= 0 { return -1 }
                offset += result
            }
            return offset
        }
        guard count == data.count else {
            throw Error.insecureSidecar("root-owned installer evidence could not be read")
        }
        return data
    }

    private struct InstallManifest: Decodable {
        let binaryPath: String
        let version: String

        enum CodingKeys: String, CodingKey {
            case binaryPath = "binary_path"
            case version
        }
    }

    private static func loadInstalledProviderVersionForBootstrap(
        home: URL,
        fileManager: FileManager
    ) throws -> String {
        let manifestURL = home.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        guard fileManager.isReadableFile(atPath: manifestURL.path) else {
            throw Error.installedProviderInvalid("install manifest is missing")
        }
        let data = try readLocalProviderFile(
            manifestURL,
            label: "install manifest",
            maximumBytes: 64 * 1024,
            fileManager: fileManager
        )
        let manifest: InstallManifest
        do {
            manifest = try JSONDecoder().decode(InstallManifest.self, from: data)
        } catch {
            throw Error.installedProviderInvalid("install manifest is malformed")
        }
        guard let version = ProviderCLIVersion.strictNormalize(manifest.version) else {
            throw Error.installedProviderInvalid("install manifest version is invalid")
        }
        return version
    }

    private static func loadInstalledProviderIdentity(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager
    ) throws -> InstalledProviderIdentity {
        let manifestURL = home.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        guard fileManager.isReadableFile(atPath: manifestURL.path) else {
            throw Error.installedProviderRequired
        }
        let manifestData = try readLocalProviderFile(
            manifestURL,
            label: "install manifest",
            maximumBytes: 64 * 1024,
            fileManager: fileManager
        )
        let manifest: InstallManifest
        do {
            manifest = try JSONDecoder().decode(InstallManifest.self, from: manifestData)
        } catch {
            throw Error.installedProviderInvalid("install manifest is malformed")
        }
        guard manifest.binaryPath.hasPrefix("/") else {
            throw Error.installedProviderInvalid("binary path is not absolute")
        }
        let executable = URL(fileURLWithPath: manifest.binaryPath).standardizedFileURL
        guard executable.lastPathComponent == "macprovider-cli" else {
            throw Error.installedProviderInvalid("unexpected executable name")
        }
        try validateInstalledProviderSignature(executable)
        let binary = try readLocalProviderFile(
            executable,
            label: "provider CLI",
            maximumBytes: 1024 * 1024 * 1024,
            fileManager: fileManager
        )
        let compatibilityURL = executable.deletingLastPathComponent()
            .appendingPathComponent("compatibility-set.json")
        let compatibilityData = try readLocalProviderFile(
            compatibilityURL,
            label: "compatibility set",
            maximumBytes: 1024 * 1024,
            fileManager: fileManager
        )
        let compatibilitySetID: String
        do {
            let root = try JSONSerialization.jsonObject(with: compatibilityData) as? [String: Any]
            let signed = root?["signed"] as? [String: Any]
            guard let value = signed?["compatibility_set_id"] as? String, !value.isEmpty else {
                throw Error.installedProviderInvalid("compatibility set ID is missing")
            }
            compatibilitySetID = value
        } catch let error as Error {
            throw error
        } catch {
            throw Error.installedProviderInvalid("compatibility set is malformed")
        }
        let version = manifest.version.hasPrefix("v")
            ? String(manifest.version.dropFirst())
            : manifest.version
        return InstalledProviderIdentity(
            version: version,
            binarySHA256: SHA256.hash(data: binary).hexString,
            compatibilitySetID: compatibilitySetID,
            compatibilityManifestSHA256: SHA256.hash(data: compatibilityData).hexString
        )
    }

    private static func validateInstalledProviderSignature(_ executable: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw Error.installedProviderInvalid("code object is unavailable")
        }
        let requirementText = "identifier \"live.streamvc.macprovider.cli\" and anchor apple generic and certificate leaf[subject.OU] = \"YF7XNRJUG4\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  requirement
              ) == errSecSuccess else {
            throw Error.installedProviderInvalid("signature, Team ID, or designated identifier mismatch")
        }
    }

    struct BundleTreeEvidence: Equatable {
        let entryCount: Int
        let rootMode: Int
        let treeSHA256: String
    }

    private static func validateCurrentBundleCode(_ bundleURL: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw Error.appIdentityUnavailable("static code object")
        }
        let requirementText = "identifier \"tech.malibu.app\" and anchor apple generic and certificate leaf[subject.OU] = \"YF7XNRJUG4\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  requirement
              ) == errSecSuccess else {
            throw Error.appSigningIdentityMismatch
        }
    }

    private static func bundleTreeEvidence(_ bundleURL: URL) throws -> BundleTreeEvidence {
        var root = stat()
        guard lstat(bundleURL.path, &root) == 0,
              (root.st_mode & S_IFMT) == S_IFDIR else {
            throw Error.appIdentityUnavailable("bundle tree")
        }
        let rootMode = Int(root.st_mode & mode_t(0o7777))
        var hash = SHA256()
        hash.update(data: Data("d\0.\0\(String(format: "%04o", rootMode))\00\0-\0".utf8))
        var count = 0

        func walk(_ directory: URL, relativeDirectory: String) throws {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            var directories: [(URL, String, stat)] = []
            var files: [(URL, String, stat)] = []
            for child in children {
                let relative = relativeDirectory.isEmpty
                    ? child.lastPathComponent
                    : "\(relativeDirectory)/\(child.lastPathComponent)"
                var metadata = stat()
                guard lstat(child.path, &metadata) == 0 else {
                    throw Error.appIdentityUnavailable("bundle tree entry \(relative)")
                }
                let type = metadata.st_mode & S_IFMT
                if type == S_IFDIR { directories.append((child, relative, metadata)) }
                else if type == S_IFREG { files.append((child, relative, metadata)) }
                else { throw Error.appIdentityUnavailable("unsupported bundle entry \(relative)") }
            }
            directories.sort { $0.1 < $1.1 }
            files.sort { $0.1 < $1.1 }
            for (url, relative, metadata) in directories + files {
                let mode = Int(metadata.st_mode & mode_t(0o7777))
                let isDirectory = (metadata.st_mode & S_IFMT) == S_IFDIR
                let content: String
                let size: Int64
                if isDirectory {
                    content = "-"
                    size = 0
                } else {
                    content = SHA256.hash(data: try Data(contentsOf: url)).hexString
                    size = metadata.st_size
                }
                let record = "\(isDirectory ? "d" : "f")\0\(relative)\0\(String(format: "%04o", mode))\0\(size)\0\(content)\0"
                hash.update(data: Data(record.utf8))
                count += 1
            }
            for (url, relative, _) in directories {
                try walk(url, relativeDirectory: relative)
            }
        }

        try walk(bundleURL, relativeDirectory: "")
        return BundleTreeEvidence(
            entryCount: count,
            rootMode: rootMode,
            treeSHA256: hash.finalize().hexString
        )
    }

    private static func currentSigningTeamID() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw Error.appIdentityUnavailable("signing identity")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw Error.appIdentityUnavailable("static signing identity")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw Error.appIdentityUnavailable("Team ID")
        }
        return teamID
    }

    private static func readSidecar(
        _ url: URL,
        label: String,
        fileManager: FileManager
    ) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else { throw Error.missingSidecar(label) }
        return try readOwnedRegularFile(
            url,
            label: label,
            maximumBytes: 1024 * 1024,
            fileManager: fileManager,
            mapError: { Error.insecureSidecar($0) }
        )
    }

    private static func readLocalProviderFile(
        _ url: URL,
        label: String,
        maximumBytes: Int,
        fileManager: FileManager
    ) throws -> Data {
        try readOwnedRegularFile(
            url,
            label: label,
            maximumBytes: maximumBytes,
            fileManager: fileManager,
            mapError: { Error.installedProviderInvalid($0) }
        )
    }

    private static func readOwnedRegularFile(
        _ url: URL,
        label: String,
        maximumBytes: Int,
        fileManager: FileManager,
        mapError: (String) -> Error
    ) throws -> Data {
        _ = fileManager
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw mapError("\(label) is unreadable") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw mapError("\(label) metadata is unreadable") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw mapError("\(label) is not a regular file") }
        guard info.st_uid == geteuid() else { throw mapError("\(label) is not owned by the current user") }
        guard info.st_mode & mode_t(0o022) == 0 else { throw mapError("\(label) is group- or world-writable") }
        guard info.st_size > 0, info.st_size <= maximumBytes else { throw mapError("\(label) has an invalid size") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.readToEnd(), data.count == Int(info.st_size) else {
            throw mapError("\(label) changed while it was read")
        }
        return data
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
