import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import Security

struct LaunchdRestartFailure: Error, CustomStringConvertible {
    let error: Error
    let recoveryCommand: String

    var description: String {
        String(describing: error)
    }
}

private final class LaunchctlOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

struct LaunchctlCommandResult {
    let terminationStatus: Int32
    let output: String
}

private enum ReleaseSignatureEncoding {
    case der
    case canonicalBase64DER
}

struct SelfUpdate {
    static let defaultReleasesAPIURL = "https://api.github.com/repos/Augustas11/macprovider/releases/latest"
    static let launchdLabel = "live.streamvc.macprovider"
    static let watchdogLaunchdLabel = "live.streamvc.macprovider-watchdog"
    static let providerReloadLaunchdLabel = "\(launchdLabel)-compatibility-reload"
    static let legacyProviderReloadLaunchdLabelPrefix = "\(providerReloadLaunchdLabel)."
    // Eleven samples at the two-second poll interval prove 20 seconds of
    // uninterrupted health, exceeding launchd's observed ten-second retry
    // cadence for legacy `submit` jobs.
    static let localHealthRequiredConsecutiveSamples = 11
    static let stagedCLIPreflightArguments = ["--version"]
    static let currentSigningInformationFlags = SecCSFlags(
        rawValue: kSecCSSigningInformation
    )
    static let currentCodeValidityFlags = SecCSFlags(rawValue: kSecCSStrictValidate)
    static let releaseDiscoveryPageSize = 20
    static let maxReleaseDiscoveryListingBytes = 2 * 1_024 * 1_024
    static let maxReleaseDiscoveryHeadBytes = 64 * 1_024
    static let maxReleaseDiscoverySignatureBytes = 4 * 1_024
    static let checksumPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwwd0Vzj35OP8DlZU+0lUa8vI9gHK
    09J48LDizWScsH6rutnZLkKnGQ4X5Q8lT9L5mglF8Ba0DDoUXKrFfSAX4Q==
    -----END PUBLIC KEY-----
    """

    private let currentVersion: String
    private let releasesAPIURL: String
    private let session: URLSession
    private let drainBeforeReplace: (() async throws -> Void)?
    private let replaceBinary: ((URL) throws -> Void)?
    private let rollbackReplacement: (() throws -> Void)?
    private let restartLaunchd: (() throws -> Void)?
    private let postRestartReadiness: (() async -> Bool)?
    private let providerID: String?
    private let markerStore: AutoUpdateMarkerStore
    private let lifecycleStateStore: ProviderLifecycleStateStore
    private let lifecycleLeaseStore: ProviderLifecycleLeaseStore
    private let malibuBundleStager: ((URL, URL, CompatibilitySetManifest, URL) throws -> URL)?
    private let stagedCLIValidator: ((URL) throws -> Void)?
    private let currentBinaryURL: (() -> URL?)?

    init(
        currentVersion: String,
        releasesAPIURL: String?,
        session: URLSession = .shared,
        markerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore(),
        drainBeforeReplace: (() async throws -> Void)? = nil,
        replaceBinary: ((URL) throws -> Void)? = nil,
        rollbackReplacement: (() throws -> Void)? = nil,
        restartLaunchd: (() throws -> Void)? = nil,
        postRestartReadiness: (() async -> Bool)? = nil,
        providerID: String? = nil,
        lifecycleStateStore: ProviderLifecycleStateStore = ProviderLifecycleStateStore(),
        lifecycleLeaseStore: ProviderLifecycleLeaseStore = ProviderLifecycleLeaseStore(),
        malibuBundleStager: ((URL, URL, CompatibilitySetManifest, URL) throws -> URL)? = nil,
        stagedCLIValidator: ((URL) throws -> Void)? = nil,
        currentBinaryURL: (() -> URL?)? = nil
    ) {
        self.currentVersion = currentVersion
        self.releasesAPIURL = releasesAPIURL ?? Self.defaultReleasesAPIURL
        self.session = session
        self.markerStore = markerStore
        self.drainBeforeReplace = drainBeforeReplace
        self.replaceBinary = replaceBinary
        self.rollbackReplacement = rollbackReplacement
        self.restartLaunchd = restartLaunchd
        self.postRestartReadiness = postRestartReadiness
        self.providerID = providerID
        self.lifecycleStateStore = lifecycleStateStore
        self.lifecycleLeaseStore = lifecycleLeaseStore
        self.malibuBundleStager = malibuBundleStager
        self.stagedCLIValidator = stagedCLIValidator
        self.currentBinaryURL = currentBinaryURL
    }

    func run(checkOnly: Bool) async throws {
        // Repair stale PATH regular-file entrypoints before set discovery so
        // sibling compatibility-set.json is reachable via symlink resolution
        // (#616 / #610 physical matrix J1/J4).
        _ = try markerStore.ensurePathEntrypointMatchesInstallAuthority()
        let head = try await discoverSignedReleaseHead()
        try await markerStore.updateSignedPolicy(
            minimum: head.signedPolicyMinimum,
            revoked: head.signedPolicyRevoked
        )
        let latest = head.targetVersion
        let installedReleaseVersion = (try? installedCompatibilitySetReleaseVersion()) ?? currentVersion
        let comparison = Self.compareSemver(installedReleaseVersion, latest)

        if comparison != .orderedAscending {
            _ = try markerStore.ensurePathEntrypointMatchesInstallAuthority()
            print("Already up to date (v\(installedReleaseVersion))")
            return
        }

        if checkOnly {
            print("Update available: v\(installedReleaseVersion) -> v\(latest)")
            return
        }

        let release = try await resolveReleaseByTags(normalizedTarget: latest)
        let prepared = try await prepareValidatedUpdate(
            from: release,
            expectedArtifactIndexSHA256: head.targetArtifactIndexSHA256
        )
        defer { prepared.cleanup() }
        try Self.requireDiscoveryHead(head, matches: prepared)
        try await applyValidatedUpdate(
            newBinary: prepared.newBinary,
            stagedMalibuApp: prepared.stagedMalibuApp,
            targetVersion: prepared.compatibilityManifest.providerCLIVersion,
            compatibilityManifest: prepared.compatibilityManifest,
            authorityMode: "signed_release",
            discoveryHead: head
        )
        try await persistSignedPolicyIfPresent(prepared.signedPolicy)
        print(
            "Update complete. Restart macprovider-cli to use provider CLI "
                + "v\(prepared.compatibilityManifest.providerCLIVersion)."
        )
    }

    func runByTag(tag: String) async throws {
        let release = try await releaseByTag(tag)
        let prepared = try await prepareValidatedUpdate(from: release)
        defer { prepared.cleanup() }
        try await applyValidatedUpdate(
            newBinary: prepared.newBinary,
            stagedMalibuApp: prepared.stagedMalibuApp,
            targetVersion: prepared.compatibilityManifest.providerCLIVersion,
            compatibilityManifest: prepared.compatibilityManifest,
            authorityMode: nil,
            discoveryHead: nil
        )
        try await persistSignedPolicyIfPresent(prepared.signedPolicy)
    }

    func runAcceptanceCandidate(
        from directory: URL,
        tag: String,
        expectedCommit: String,
        expectedControlCommit: String,
        expectedRunID: String,
        expectedRunAttempt: Int
    ) async throws {
        _ = try markerStore.ensurePathEntrypointMatchesInstallAuthority()
        let target = try Self.validateReleaseTag(tag)
        let installedReleaseVersion = try installedCompatibilitySetReleaseVersion()
        guard Self.compareSemver(installedReleaseVersion, target) == .orderedAscending else {
            _ = try markerStore.ensurePathEntrypointMatchesInstallAuthority()
            throw UpdateError.acceptanceCandidateNotNewer(
                current: installedReleaseVersion,
                target: target
            )
        }
        let prepared = try prepareValidatedUpdate(
            fromAcceptanceDirectory: directory,
            tag: tag,
            expectedCommit: expectedCommit,
            expectedControlCommit: expectedControlCommit,
            expectedRunID: expectedRunID,
            expectedRunAttempt: expectedRunAttempt
        )
        defer { prepared.cleanup() }
        try Self.requireAcceptanceProviderVersion(
            current: currentVersion,
            target: prepared.compatibilityManifest.providerCLIVersion
        )
        let discoveryHead = try await acceptanceDiscoveryHeadIfPresent(
            prepared: prepared
        )
        try await applyValidatedUpdate(
            newBinary: prepared.newBinary,
            stagedMalibuApp: prepared.stagedMalibuApp,
            targetVersion: prepared.compatibilityManifest.providerCLIVersion,
            compatibilityManifest: prepared.compatibilityManifest,
            authorityMode: discoveryHead == nil ? nil : "signed_release",
            discoveryHead: discoveryHead
        )
        print(
            "Acceptance candidate v\(target) applied with provider CLI "
                + "v\(prepared.compatibilityManifest.providerCLIVersion). Restart macprovider-cli."
        )
    }

    private func installedCompatibilitySetReleaseVersion() throws -> String {
        let launched = Bundle.main.executableURL
        let canonical = markerStore.resolveCanonicalInstallBinary(launchedExecutableURL: launched)
        if let installed = CompatibilitySetManifest.loadInstalledPreferringInstallAuthority(
            launchedExecutableURL: launched,
            canonicalBinaryURL: canonical,
            expectedVersion: currentVersion,
            allowProviderVersionMismatch: true
        ) {
            return installed.version
        }
        return currentVersion
    }

    func resolveReleaseByTags(normalizedTarget: String) async throws -> GitHubRelease {
        do {
            return try await releaseByTag("v\(normalizedTarget)")
        } catch UpdateError.releaseNotFound {
            return try await releaseByTag(normalizedTarget)
        }
    }

    func prepareValidatedUpdate(
        from release: GitHubRelease,
        expectedArtifactIndexSHA256: String? = nil
    ) async throws -> PreparedSelfUpdate {
        let targetVersion = try Self.validateReleaseTag(release.tagName)
        let canonicalTarballName = "macprovider-cli-\(release.tagName)-darwin-arm64.tar.gz"
        let canonicalMalibuDMGName = "Malibu-\(release.tagName).dmg"
        guard let tarball = release.assets.first(where: { $0.name == canonicalTarballName }),
              let malibuDMG = release.assets.first(where: { $0.name == canonicalMalibuDMGName }),
              let artifactIndex = release.assets.first(where: { $0.name == CompatibilityArtifactIndex.fileName }),
              let checksums = release.assets.first(where: { $0.name == "checksums.txt" }),
              let checksumsSignature = release.assets.first(where: { $0.name == "checksums.txt.sig" })
        else {
            throw UpdateError.missingAsset
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        do {
            try validateDownloadURL(tarball.browserDownloadURL)
            try validateDownloadURL(malibuDMG.browserDownloadURL)
            try validateDownloadURL(artifactIndex.browserDownloadURL)
            try validateDownloadURL(checksums.browserDownloadURL)
            try validateDownloadURL(checksumsSignature.browserDownloadURL)

            let tarballURL = tempDir.appendingPathComponent(tarball.name)
            let malibuDMGURL = tempDir.appendingPathComponent(malibuDMG.name)
            let artifactIndexURL = tempDir.appendingPathComponent(artifactIndex.name)
            let checksumsURL = tempDir.appendingPathComponent(checksums.name)
            let checksumsSignatureURL = tempDir.appendingPathComponent(checksumsSignature.name)
            try await download(from: checksums.browserDownloadURL, to: checksumsURL)
            try await download(from: checksumsSignature.browserDownloadURL, to: checksumsSignatureURL)
            try verifyChecksumSignature(checksumsURL: checksumsURL, signatureURL: checksumsSignatureURL, tempDir: tempDir)
            let checksumsText = try String(contentsOf: checksumsURL, encoding: .utf8)
            let expectedSHA = try Self.expectedSHA256(for: tarball.name, in: checksumsText)
            let expectedMalibuSHA = try Self.expectedSHA256(for: malibuDMG.name, in: checksumsText)
            let expectedArtifactIndexSHA = try Self.expectedSHA256(for: artifactIndex.name, in: checksumsText)
            try await download(from: artifactIndex.browserDownloadURL, to: artifactIndexURL)
            let actualArtifactIndexSHA = try Self.sha256(file: artifactIndexURL)
            guard actualArtifactIndexSHA.lowercased() == expectedArtifactIndexSHA.lowercased() else {
                throw UpdateError.checksumMismatch(
                    expected: expectedArtifactIndexSHA,
                    actual: actualArtifactIndexSHA
                )
            }
            if let expectedArtifactIndexSHA256,
               actualArtifactIndexSHA.lowercased() != expectedArtifactIndexSHA256.lowercased() {
                throw UpdateError.compatibilityArtifactIndexInvalid("discovery_head_digest_mismatch")
            }
            try await download(from: tarball.browserDownloadURL, to: tarballURL)
            try await download(from: malibuDMG.browserDownloadURL, to: malibuDMGURL)
            return try prepareValidatedUpdateAssets(
                assetNames: release.assets.map(\.name),
                tempDir: tempDir,
                tarballURL: tarballURL,
                malibuDMGURL: malibuDMGURL,
                artifactIndexURL: artifactIndexURL,
                checksumsText: checksumsText,
                expectedTarballSHA: expectedSHA,
                expectedMalibuSHA: expectedMalibuSHA,
                signedPolicy: release.signedPolicy,
                targetVersion: targetVersion,
                actualArtifactIndexSHA256: actualArtifactIndexSHA
            )
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    func prepareValidatedUpdate(
        fromAcceptanceDirectory directory: URL,
        tag: String,
        expectedCommit: String,
        expectedControlCommit: String,
        expectedRunID: String,
        expectedRunAttempt: Int
    ) throws -> PreparedSelfUpdate {
        let targetVersion = try Self.validateReleaseTag(tag)
        let assetNames = try Self.validatedAcceptanceAssetNames(in: directory)
        let tarballName = "macprovider-cli-\(tag)-darwin-arm64.tar.gz"
        let malibuDMGName = "Malibu-\(tag).dmg"
        let requiredNames = [
            tarballName,
            malibuDMGName,
            CompatibilityArtifactIndex.fileName,
            "checksums.txt",
            AcceptanceCandidateMetadata.fileName,
            AcceptanceCandidateMetadata.signatureFileName,
        ]
        guard requiredNames.allSatisfy(assetNames.contains),
              !assetNames.contains("checksums.txt.sig")
        else {
            throw UpdateError.missingAsset
        }
        let hasDiscoveryHead = assetNames.contains(SignedReleaseDiscoveryHead.assetName)
        let hasDiscoverySignature = assetNames.contains(SignedReleaseDiscoveryHead.signatureAssetName)
        guard hasDiscoveryHead == hasDiscoverySignature else {
            throw UpdateError.discoveryHeadInvalid("acceptance_asset_pair")
        }
        var copiedNames = requiredNames
        if hasDiscoveryHead {
            copiedNames.append(SignedReleaseDiscoveryHead.assetName)
            copiedNames.append(SignedReleaseDiscoveryHead.signatureAssetName)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-acceptance-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            for name in copiedNames {
                try FileManager.default.copyItem(
                    at: directory.appendingPathComponent(name),
                    to: tempDir.appendingPathComponent(name)
                )
            }
            let tarballURL = tempDir.appendingPathComponent(tarballName)
            let malibuDMGURL = tempDir.appendingPathComponent(malibuDMGName)
            let artifactIndexURL = tempDir.appendingPathComponent(CompatibilityArtifactIndex.fileName)
            let checksumsURL = tempDir.appendingPathComponent("checksums.txt")
            let metadataURL = tempDir.appendingPathComponent(AcceptanceCandidateMetadata.fileName)
            let metadataSignatureURL = tempDir.appendingPathComponent(AcceptanceCandidateMetadata.signatureFileName)
            let metadataData = try Data(contentsOf: metadataURL)
            try verifyReleaseSignature(
                payload: AcceptanceCandidateMetadata.signaturePayload(metadata: metadataData),
                signatureURL: metadataSignatureURL,
                publicKeyPEM: AcceptanceCandidateMetadata.signingPublicKeyPEM,
                signatureEncoding: .canonicalBase64DER,
                failure: .acceptanceMetadataSignatureInvalid
            )
            let checksumsData = try Data(contentsOf: checksumsURL)
            let acceptanceMetadata = try AcceptanceCandidateMetadata.loadValidated(
                metadata: metadataData,
                checksums: checksumsData,
                expectedTag: tag,
                expectedCandidateCommit: expectedCommit,
                expectedControlCommit: expectedControlCommit,
                expectedRunID: expectedRunID,
                expectedRunAttempt: expectedRunAttempt
            )
            let checksumsText = try String(contentsOf: checksumsURL, encoding: .utf8)
            let expectedArtifactIndexSHA = try Self.expectedSHA256(
                for: CompatibilityArtifactIndex.fileName,
                in: checksumsText
            )
            let actualArtifactIndexSHA = try Self.sha256(file: artifactIndexURL)
            guard actualArtifactIndexSHA.lowercased() == expectedArtifactIndexSHA.lowercased() else {
                throw UpdateError.checksumMismatch(
                    expected: expectedArtifactIndexSHA,
                    actual: actualArtifactIndexSHA
                )
            }
            return try prepareValidatedUpdateAssets(
                assetNames: assetNames,
                tempDir: tempDir,
                tarballURL: tarballURL,
                malibuDMGURL: malibuDMGURL,
                artifactIndexURL: artifactIndexURL,
                checksumsText: checksumsText,
                expectedTarballSHA: Self.expectedSHA256(for: tarballName, in: checksumsText),
                expectedMalibuSHA: Self.expectedSHA256(for: malibuDMGName, in: checksumsText),
                signedPolicy: nil,
                targetVersion: targetVersion,
                actualArtifactIndexSHA256: actualArtifactIndexSHA,
                expectedCompatibilitySetID: acceptanceMetadata.compatibilitySetID,
                allowIndependentProviderVersion: true
            )
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    private func acceptanceDiscoveryHeadIfPresent(
        prepared: PreparedSelfUpdate,
        now: Date = Date()
    ) async throws -> SignedReleaseDiscoveryHead? {
        let headURL = prepared.tempDir.appendingPathComponent(SignedReleaseDiscoveryHead.assetName)
        let signatureURL = prepared.tempDir.appendingPathComponent(SignedReleaseDiscoveryHead.signatureAssetName)
        let hasDiscoveryHead = FileManager.default.fileExists(atPath: headURL.path)
        let hasDiscoverySignature = FileManager.default.fileExists(atPath: signatureURL.path)
        guard hasDiscoveryHead || hasDiscoverySignature else { return nil }
        guard hasDiscoveryHead && hasDiscoverySignature else {
            throw UpdateError.discoveryHeadInvalid("acceptance_asset_pair")
        }
        let head = try SignedReleaseDiscoveryHead.loadVerified(
            headData: Data(contentsOf: headURL),
            signatureData: Data(contentsOf: signatureURL),
            now: now
        )
        try Self.requireDiscoveryHead(head, matches: prepared)
        try markerStore.acceptDiscoveryHead(head)
        try await markerStore.updateSignedPolicy(
            minimum: head.signedPolicyMinimum,
            revoked: head.signedPolicyRevoked
        )
        return head
    }

    private func prepareValidatedUpdateAssets(
        assetNames: [String],
        tempDir: URL,
        tarballURL: URL,
        malibuDMGURL: URL,
        artifactIndexURL: URL,
        checksumsText: String,
        expectedTarballSHA: String,
        expectedMalibuSHA: String,
        signedPolicy: GitHubSignedPolicy?,
        targetVersion: String,
        actualArtifactIndexSHA256: String,
        expectedCompatibilitySetID: String? = nil,
        allowIndependentProviderVersion: Bool = false
    ) throws -> PreparedSelfUpdate {
        try validateFreeSpace(for: tempDir, requiredForKnownTarballAt: tarballURL)
        let actualSHA = try Self.sha256(file: tarballURL)
        guard actualSHA.lowercased() == expectedTarballSHA.lowercased() else {
            throw UpdateError.checksumMismatch(expected: expectedTarballSHA, actual: actualSHA)
        }
        let actualMalibuSHA = try Self.sha256(file: malibuDMGURL)
        guard actualMalibuSHA.lowercased() == expectedMalibuSHA.lowercased() else {
            throw UpdateError.checksumMismatch(expected: expectedMalibuSHA, actual: actualMalibuSHA)
        }

        let extractDir = tempDir.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try validateTarball(tarballURL)
        try runProcess("/usr/bin/tar", arguments: ["-xzf", tarballURL.path, "-C", extractDir.path])
        try Self.validateExtractedTree(extractDir)
        let newBinary = try Self.findBinary(in: extractDir)
        try ProviderReleasePayloadTransaction.validateReleasePayload(
            at: newBinary.deletingLastPathComponent(),
            newBinary: newBinary
        )
        let compatibilityManifest = try CompatibilitySetManifest.loadValidated(
            from: newBinary.deletingLastPathComponent(),
            expectedProviderVersion: allowIndependentProviderVersion ? nil : targetVersion
        )
        let artifactIndex = try CompatibilityArtifactIndex.loadValidated(
            from: artifactIndexURL,
            compatibilityManifest: compatibilityManifest,
            checksumsText: checksumsText,
            releaseAssetNames: assetNames
        )
        if let expectedCompatibilitySetID,
           artifactIndex.compatibilitySetID != expectedCompatibilitySetID
        {
            throw UpdateError.acceptanceMetadataInvalid("artifact_index_identity")
        }

        if let stagedCLIValidator {
            try stagedCLIValidator(newBinary)
        } else {
            try validateStagedCLIIdentity(newBinary)
        }
        let stagedVersionOutput = try processOutput(
            newBinary.path,
            arguments: Self.stagedCLIPreflightArguments
        )
        try Self.requireStagedBinaryVersion(
            stagedVersionOutput,
            targetVersion: compatibilityManifest.providerCLIVersion
        )
        let stagedMalibuApp = if let malibuBundleStager {
            try malibuBundleStager(malibuDMGURL, tempDir, compatibilityManifest, newBinary)
        } else {
            try stageValidatedMalibuApp(
                from: malibuDMGURL,
                in: tempDir,
                compatibilityManifest: compatibilityManifest,
                newBinary: newBinary
            )
        }
        return PreparedSelfUpdate(
            tempDir: tempDir,
            newBinary: newBinary,
            stagedMalibuApp: stagedMalibuApp,
            signedPolicy: signedPolicy,
            compatibilityManifest: compatibilityManifest,
            artifactIndexSHA256: actualArtifactIndexSHA256
        )
    }

    func applyValidatedUpdateForTest(newBinary: URL) async throws {
        try await applyValidatedUpdate(
            newBinary: newBinary,
            stagedMalibuApp: nil,
            targetVersion: "1.2.1",
            compatibilityManifest: nil
        )
    }

    func persistSignedPolicyIfPresent(_ signedPolicy: GitHubSignedPolicy?) async throws {
        guard let signedPolicy else { return }
        try await markerStore.updateSignedPolicy(minimum: signedPolicy.minimum, revoked: signedPolicy.revoked)
    }

    func resolvedReleasesAPIURLForTest() -> String {
        releasesAPIURL
    }

    static func requireDiscoveryHead(
        _ head: SignedReleaseDiscoveryHead,
        matches prepared: PreparedSelfUpdate
    ) throws {
        guard prepared.compatibilityManifest.version == head.targetVersion,
              prepared.compatibilityManifest.compatibilitySetID == head.targetCompatibilitySetID,
              prepared.artifactIndexSHA256.lowercased() == head.targetArtifactIndexSHA256.lowercased(),
              prepared.compatibilityManifest.envelopeSHA256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil
        else {
            throw UpdateError.discoveryHeadInvalid("target_identity_mismatch")
        }
    }

    static func releaseSigningPublicKeyPEMForTest() -> String {
        checksumPublicKeyPEM
    }

    func latestVersionCached() async throws -> String {
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/macprovider/latest-release.json")
        if let cached = try? Data(contentsOf: cacheURL),
           let object = try? JSONSerialization.jsonObject(with: cached) as? [String: Any],
           let fetchedAt = object["fetched_at"] as? TimeInterval,
           Date().timeIntervalSince1970 - fetchedAt < 3600,
           let version = object["version"] as? String
        {
            return version
        }

        let release = try await latestRelease()
        let version = try Self.validateReleaseTag(release.tagName)
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "fetched_at": Date().timeIntervalSince1970,
            "version": version,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return version
    }

    private func latestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: releasesAPIURL) else {
            throw UpdateError.invalidURL(releasesAPIURL)
        }
        try validateReleaseAPIURL(url)
        var request = URLRequest(url: url)
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("macprovider-cli/\(currentVersion)", forHTTPHeaderField: "user-agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    func discoverSignedReleaseHead(now: Date = Date()) async throws -> SignedReleaseDiscoveryHead {
        let releases = try await releaseDiscoveryTransports()
        guard let release = releases.compactMap({ candidate -> (GitHubRelease, UInt64)? in
            guard let sequence = SignedReleaseDiscoveryHead.transportSequence(from: candidate.tagName) else {
                return nil
            }
            return (candidate, sequence)
        }).max(by: { $0.1 < $1.1 }) else {
            throw UpdateError.discoveryHeadInvalid("transport_absent")
        }
        guard release.0.isDraft == false,
              release.0.isPrerelease == true,
              release.0.isImmutable == true
        else {
            throw UpdateError.discoveryHeadInvalid("transport_not_immutable")
        }
        let headAssets = release.0.assets.filter { $0.name == SignedReleaseDiscoveryHead.assetName }
        let signatureAssets = release.0.assets.filter { $0.name == SignedReleaseDiscoveryHead.signatureAssetName }
        guard headAssets.count == 1,
              signatureAssets.count == 1,
              let headAsset = headAssets.first,
              let signatureAsset = signatureAssets.first
        else {
            throw UpdateError.missingAsset
        }
        try validateDownloadURL(headAsset.browserDownloadURL)
        try validateDownloadURL(signatureAsset.browserDownloadURL)
        let (headData, headResponse) = try await session.data(from: headAsset.browserDownloadURL)
        if let http = headResponse as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        guard headData.count <= Self.maxReleaseDiscoveryHeadBytes else {
            throw UpdateError.discoveryHeadInvalid("transport_head_oversized")
        }
        let (signatureData, signatureResponse) = try await session.data(from: signatureAsset.browserDownloadURL)
        if let http = signatureResponse as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        guard signatureData.count <= Self.maxReleaseDiscoverySignatureBytes else {
            throw UpdateError.discoveryHeadInvalid("transport_signature_oversized")
        }
        let head = try SignedReleaseDiscoveryHead.loadVerified(
            headData: headData,
            signatureData: signatureData,
            now: now
        )
        try Self.requireAppendOnlyDiscoveryTransport(
            transportTag: release.0.tagName,
            transportSequence: release.1,
            head: head
        )
        try markerStore.acceptDiscoveryHead(head)
        return head
    }

    static func requireAppendOnlyDiscoveryTransport(
        transportTag: String,
        transportSequence: UInt64,
        head: SignedReleaseDiscoveryHead
    ) throws {
        guard SignedReleaseDiscoveryHead.transportSequence(from: transportTag) == transportSequence,
              transportSequence == head.releaseSequence
        else {
            throw UpdateError.discoveryHeadInvalid("transport_sequence_mismatch")
        }
    }

    private func releaseDiscoveryTransports() async throws -> [GitHubRelease] {
        guard var components = URLComponents(string: releasesAPIURL) else {
            throw UpdateError.invalidURL(releasesAPIURL)
        }
        if components.path.hasSuffix("/releases/latest") {
            components.path = String(components.path.dropLast("/latest".count))
        } else if components.path.contains("/releases/tags/") {
            components.path = String(components.path.split(separator: "/").dropLast(2).joined(separator: "/"))
            if !components.path.hasPrefix("/") { components.path = "/" + components.path }
        }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(Self.releaseDiscoveryPageSize))]
        guard let url = components.url else {
            throw UpdateError.invalidURL(releasesAPIURL)
        }
        try validateReleaseAPIURL(url)
        var request = URLRequest(url: url)
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("macprovider-cli/\(currentVersion)", forHTTPHeaderField: "user-agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maxReleaseDiscoveryListingBytes else {
            throw UpdateError.discoveryHeadInvalid("transport_listing_oversized")
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    private func releaseByTag(_ tag: String) async throws -> GitHubRelease {
        guard let url = releaseTagURL(tag: tag) else {
            throw UpdateError.invalidURL(releasesAPIURL)
        }
        try validateReleaseAPIURL(url)
        var request = URLRequest(url: url)
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("macprovider-cli/\(currentVersion)", forHTTPHeaderField: "user-agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw UpdateError.releaseNotFound
            }
            if !(200 ..< 300).contains(http.statusCode) {
                throw UpdateError.httpStatus(http.statusCode)
            }
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func releaseTagURL(tag: String) -> URL? {
        guard var components = URLComponents(string: releasesAPIURL) else {
            return nil
        }
        let escapedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        if components.path.hasSuffix("/releases/latest") {
            components.path = String(components.path.dropLast("/latest".count)) + "/tags/\(escapedTag)"
        } else if components.path.contains("/releases/tags/") {
            let prefix = components.path.split(separator: "/").dropLast().joined(separator: "/")
            components.path = "/" + prefix + "/\(escapedTag)"
        } else {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/tags/\(escapedTag)"
            if !components.path.hasPrefix("/") {
                components.path = "/" + components.path
            }
        }
        return components.url
    }

    private func fetchText(from url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func download(from url: URL, to destination: URL) async throws {
        let (downloaded, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        try FileManager.default.moveItem(at: downloaded, to: destination)
    }

    private func applyValidatedUpdate(
        newBinary: URL,
        stagedMalibuApp: URL?,
        targetVersion: String,
        compatibilityManifest: CompatibilitySetManifest?,
        authorityMode: String? = nil,
        discoveryHead: SignedReleaseDiscoveryHead? = nil
    ) async throws {
        let lifecycleOperationID = "self-update:\(UUID().uuidString.lowercased())"
        var maintenanceLease: ProviderLifecycleLeaseRecord?
        var startupHandoffPrepared = false
        var updateLock: AutoUpdateLock?
        defer { withExtendedLifetime(updateLock) {} }
        if replaceBinary == nil {
            updateLock = try markerStore.acquireLock()
            try fenceProviderReloadJobsIfLaunchdInstalled()
            if try markerStore.preflightInstalledMalibuAppReplacement() != nil,
               stagedMalibuApp == nil {
                throw UpdateError.missingReleaseResource("signed Malibu.app")
            }
            maintenanceLease = try lifecycleLeaseStore.acquire(
                kind: .maintenance,
                operationID: lifecycleOperationID,
                duration: TimeInterval(compatibilityManifest?.maintenanceLeaseSeconds ?? 10 * 60)
            )
            _ = try lifecycleStateStore.transition(
                to: .updateInProgress,
                reasonCode: "signed_compatibility_set_validated",
                writer: .updater,
                compatibilitySetID: compatibilityManifest?.compatibilitySetID,
                operationID: lifecycleOperationID
            )
        }
        defer {
            if let maintenanceLease, !startupHandoffPrepared {
                _ = try? lifecycleLeaseStore.clear(ifLeaseID: maintenanceLease.leaseID)
            }
        }
        if let drainBeforeReplace {
            try await drainBeforeReplace()
        }

        var pendingMarker: AutoUpdatePendingMarker?
        let current = replaceBinary == nil
            ? (currentBinaryURL?() ?? markerStore.resolveCanonicalInstallBinary(
                launchedExecutableURL: Bundle.main.executableURL
            ))
            : nil
        if replaceBinary == nil {
            guard let current else { throw UpdateError.currentBinaryUnknown }
            let updateID = UUID().uuidString.lowercased()
            let marker = try markerStore.preserveReleaseRollbackBackup(
                binaryURL: current,
                updateID: updateID,
                targetVersion: targetVersion,
                previousVersion: currentVersion,
                commitOwner: "self_update",
                targetCompatibilitySetID: compatibilityManifest?.compatibilitySetID,
                targetCompatibilitySetSHA256: compatibilityManifest?.envelopeSHA256,
                discoveryHeadSequence: discoveryHead?.releaseSequence,
                discoveryHeadSHA256: discoveryHead?.digest,
                updateAuthorityMode: authorityMode,
                readinessTimeoutSeconds: compatibilityManifest?.readinessTimeoutSeconds ?? 300
            )
            do {
                try markerStore.writePending(marker)
                pendingMarker = marker
            } catch {
                markerStore.removeRollbackBackups(marker)
                markerStore.clearPendingAndLock(target: nil)
                throw error
            }
        }

        do {
            if let replaceBinary {
                try replaceBinary(newBinary)
            } else if let current {
                try markerStore.activateReleasePayload(
                    from: newBinary.deletingLastPathComponent(),
                    newBinary: newBinary,
                    to: current,
                    stagedMalibuApp: stagedMalibuApp,
                    rollbackMarker: pendingMarker
                )
            }
        } catch {
            do {
                if replaceBinary == nil {
                    _ = try lifecycleStateStore.transition(
                        to: .rollbackInProgress,
                        reasonCode: "update_activation_failed",
                        writer: .updater,
                        compatibilitySetID: compatibilityManifest?.compatibilitySetID,
                        operationID: lifecycleOperationID
                    )
                }
                try restoreAppliedUpdate(pendingMarker)
            } catch let rollbackError {
                throw UpdateError.activationFailedRollbackFailed(
                    update: String(describing: error),
                    rollback: String(describing: rollbackError)
                )
            }
            throw error
        }
        if let lease = maintenanceLease, let current {
            do {
                guard let providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !providerID.isEmpty else {
                    throw ProviderLifecycleLeaseError.invalidHandoffField("provider_id")
                }
                _ = try lifecycleLeaseStore.prepareStartupHandoff(
                    maintenanceLeaseID: lease.leaseID,
                    operationID: lifecycleOperationID,
                    providerID: providerID,
                    serviceIdentity: Self.launchdLabel,
                    targetExecutablePath: current.path,
                    targetExecutableSHA256: try AutoUpdateMarkerStore.sha256(file: current),
                    handoffDuration: 60,
                    startupLeaseDuration: TimeInterval(compatibilityManifest?.readinessTimeoutSeconds ?? 300)
                )
                startupHandoffPrepared = true
            } catch {
                try restoreAppliedUpdate(pendingMarker)
                throw error
            }
        }
        do {
            if let restartLaunchd {
                try restartLaunchd()
            } else {
                try restartLaunchdIfInstalled()
            }
        } catch let restartError {
            do {
                if replaceBinary == nil {
                    _ = try lifecycleStateStore.transition(
                        to: .rollbackInProgress,
                        reasonCode: "updated_service_restart_failed",
                        writer: .updater,
                        compatibilitySetID: compatibilityManifest?.compatibilitySetID,
                        operationID: lifecycleOperationID
                    )
                }
                try restoreAppliedUpdate(pendingMarker, reloadLaunchdJobs: rollbackReplacement == nil)
                if let maintenanceLease {
                    _ = try? lifecycleLeaseStore.clear(ifLeaseID: maintenanceLease.leaseID)
                }
                startupHandoffPrepared = false
            } catch let rollbackError {
                throw UpdateError.restartFailedRollbackFailed(
                    restart: String(describing: restartError),
                    rollback: String(describing: rollbackError)
                )
            }

            throw UpdateError.restartFailedRollbackRestored(
                restart: String(describing: restartError),
                recoveryCommand: restartRecoveryCommand()
            )
        }
        let ready = if let postRestartReadiness {
            await postRestartReadiness()
        } else {
            await Self.waitForLocalHealthIfManaged(
                targetVersion: targetVersion,
                expectedCompatibilitySetID: compatibilityManifest?.compatibilitySetID,
                expectedCompatibilitySetSHA256: compatibilityManifest?.envelopeSHA256,
                timeout: TimeInterval(compatibilityManifest?.readinessTimeoutSeconds ?? 90)
            )
        }
        guard ready else {
            do {
                if replaceBinary == nil {
                    _ = try lifecycleStateStore.transition(
                        to: .rollbackInProgress,
                        reasonCode: "buyer_serving_readiness_timeout",
                        writer: .updater,
                        compatibilitySetID: compatibilityManifest?.compatibilitySetID,
                        operationID: lifecycleOperationID
                    )
                }
                try restoreAppliedUpdate(pendingMarker, reloadLaunchdJobs: true)
                if let maintenanceLease {
                    _ = try? lifecycleLeaseStore.clear(ifLeaseID: maintenanceLease.leaseID)
                }
                startupHandoffPrepared = false
            } catch let rollbackError {
                throw UpdateError.restartFailedRollbackFailed(
                    restart: "buyer-serving readiness timeout",
                    rollback: String(describing: rollbackError)
                )
            }
            throw UpdateError.restartFailedRollbackRestored(
                restart: "buyer-serving readiness timeout",
                recoveryCommand: restartRecoveryCommand()
            )
        }
        if let pendingMarker {
            try markerStore.completeSuccessfulUpdate(pendingMarker)
            try markerStore.finalizeSuccessfulUpdate(pendingMarker)
        }
        if replaceBinary == nil {
            _ = try lifecycleStateStore.transition(
                to: .servingBuyers,
                reasonCode: "updated_compatibility_set_locally_healthy",
                writer: .updater,
                compatibilitySetID: compatibilityManifest?.compatibilitySetID,
                operationID: lifecycleOperationID
            )
        }
    }

    private func restoreAppliedUpdate(
        _ pendingMarker: AutoUpdatePendingMarker?,
        reloadLaunchdJobs: Bool = false
    ) throws {
        if let rollbackReplacement {
            try rollbackReplacement()
            if reloadLaunchdJobs, let restartLaunchd {
                try restartLaunchd()
            }
            return
        }
        try fenceProviderReloadJobsIfLaunchdInstalled()
        guard let pendingMarker else {
            throw UpdateError.rollbackUnavailable
        }
        let restored = try markerStore.restoreBackupAwaitingPreviousReadiness(pendingMarker)
        if reloadLaunchdJobs {
            if let restartLaunchd {
                try restartLaunchd()
            } else {
                try restartLaunchdIfInstalled()
            }
        }
        if restored.transactionState == nil {
            markerStore.clearPendingAndLock(target: nil)
            markerStore.removeRollbackBackups(pendingMarker)
        }
    }

    private static func waitForLocalHealthIfManaged(
        targetVersion: String,
        expectedCompatibilitySetID: String?,
        expectedCompatibilitySetSHA256: String?,
        timeout: TimeInterval = 90
    ) async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return true }
        let config = try? ConfigLoader.load(cli: CLIOverrides())
        guard let port = config?.port else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        var consecutiveHealthySamples = 0
        var stableInstanceKey: String?
        while Date() < deadline {
            let status = try? await LocalStatusClient.fetch(port: port)
            if let instanceKey = localHealthyTargetInstanceKey(
                status,
                targetVersion: targetVersion,
                expectedCompatibilitySetID: expectedCompatibilitySetID,
                expectedCompatibilitySetSHA256: expectedCompatibilitySetSHA256
            ) {
                if stableInstanceKey == instanceKey {
                    consecutiveHealthySamples += 1
                } else {
                    stableInstanceKey = instanceKey
                    consecutiveHealthySamples = 1
                }
                if consecutiveHealthySamples >= localHealthRequiredConsecutiveSamples {
                    return true
                }
            } else {
                stableInstanceKey = nil
                consecutiveHealthySamples = 0
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    static func localHealthyTargetInstanceKey(
        _ status: [String: Any]?,
        targetVersion: String,
        expectedCompatibilitySetID: String?,
        expectedCompatibilitySetSHA256: String?
    ) -> String? {
        guard let status,
              status["binary_version"] as? String == targetVersion,
              expectedCompatibilitySetID == nil
                || status["compatibility_set_id"] as? String == expectedCompatibilitySetID,
              expectedCompatibilitySetSHA256 == nil
                || status["compatibility_set_sha256"] as? String == expectedCompatibilitySetSHA256,
              let health = status["status"] as? String,
              ["ready", "busy", "degraded"].contains(health),
              let serviceInstance = status["service_instance"] as? [String: Any],
              let instanceID = serviceInstance["instance_id"] as? String,
              !instanceID.isEmpty,
              let pid = serviceInstance["pid"] as? Int,
              pid > 0
        else {
            return nil
        }
        return "\(pid):\(instanceID)"
    }

    private func restartLaunchdIfInstalled() throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let plist = homeDirectory
            .appendingPathComponent("Library/LaunchAgents/\(Self.launchdLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            return
        }
        do {
            try Self.reloadCompatibilityLaunchdJobs(
                homeDirectory: homeDirectory,
                serviceLoaded: launchctlServiceLoaded,
                servicePresent: Self.launchctlServicePresent,
                loadedServiceLabels: Self.launchctlServiceLabels,
                runLaunchctl: { arguments, allowFailure in
                    _ = try Self.runLaunchctlCommand(
                        arguments: arguments,
                        allowFailure: allowFailure
                    )
                }
            )
        } catch {
            throw LaunchdRestartFailure(
                error: error,
                recoveryCommand: Self.launchdRestartRecoveryCommand(homeDirectory: homeDirectory)
            )
        }
    }

    private func fenceProviderReloadJobsIfLaunchdInstalled() throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let providerPlist = homeDirectory.appendingPathComponent(
            "Library/LaunchAgents/\(Self.launchdLabel).plist"
        )
        guard FileManager.default.fileExists(atPath: providerPlist.path) else {
            return
        }
        try Self.fenceProviderReloadLaunchdJobs(
            homeDirectory: homeDirectory,
            servicePresent: Self.launchctlServicePresent,
            loadedServiceLabels: Self.launchctlServiceLabels,
            runLaunchctl: { arguments, allowFailure in
                _ = try Self.runLaunchctlCommand(
                    arguments: arguments,
                    allowFailure: allowFailure
                )
            }
        )
    }

    private func restartRecoveryCommand() -> String {
        Self.launchdRestartRecoveryCommand()
    }

    private func runProcess(_ executable: String, arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            throw UpdateError.processFailed(executable, process.terminationStatus)
        }
    }

    private func launchctlServiceLoaded(label: String) throws -> Bool {
        try Self.launchctlServiceLoadedOrThrow(label: label)
    }

    static func launchdReloadArguments(
        label: String,
        serviceLoaded: Bool,
        uid: uid_t = getuid(),
        plistPath: String
    ) -> [[String]] {
        let domain = "gui/\(uid)"
        if serviceLoaded {
            return [
                ["bootout", "\(domain)/\(label)"],
                ["bootstrap", domain, plistPath],
            ]
        }
        return [["bootstrap", domain, plistPath]]
    }

    static func reloadCompatibilityLaunchdJobs(
        homeDirectory: URL,
        uid: uid_t = getuid(),
        serviceLoaded: (String) throws -> Bool,
        servicePresent: (String) throws -> Bool,
        loadedServiceLabels: () throws -> [String],
        runLaunchctl: ([String], Bool) throws -> Void
    ) throws {
        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let watchdogPlist = launchAgents.appendingPathComponent("\(watchdogLaunchdLabel).plist")
        let providerPlist = launchAgents.appendingPathComponent("\(launchdLabel).plist")
        let providerReloadPlist = launchAgents.appendingPathComponent(
            "\(providerReloadLaunchdLabel).plist"
        )
        let domain = "gui/\(uid)"
        try fenceProviderReloadLaunchdJobs(
            homeDirectory: homeDirectory,
            uid: uid,
            servicePresent: servicePresent,
            loadedServiceLabels: loadedServiceLabels,
            runLaunchctl: runLaunchctl
        )
        for plist in [watchdogPlist, providerPlist]
            where !FileManager.default.fileExists(atPath: plist.path) {
            throw UpdateError.missingReleaseResource(plist.lastPathComponent)
        }
        try writeProviderReloadLaunchAgent(
            to: providerReloadPlist,
            providerPlistPath: providerPlist.path,
            uid: uid
        )

        // Reload the rollback observer synchronously while the provider is
        // still alive. The provider must be reloaded by an independent
        // one-shot launchd job because booting out its own service terminates
        // this process before it can issue the matching bootstrap.
        for arguments in launchdReloadArguments(
            label: watchdogLaunchdLabel,
            serviceLoaded: try serviceLoaded(watchdogLaunchdLabel),
            uid: uid,
            plistPath: watchdogPlist.path
        ) {
            do {
                try runLaunchctl(arguments, false)
            } catch {
                try? removeLaunchdHelperIfPresent(providerReloadPlist)
                throw error
            }
        }
        do {
            try runLaunchctl(["bootstrap", domain, providerReloadPlist.path], false)
        } catch let bootstrapError {
            do {
                try fenceProviderReloadLaunchdJobs(
                    homeDirectory: homeDirectory,
                    uid: uid,
                    servicePresent: servicePresent,
                    loadedServiceLabels: loadedServiceLabels,
                    runLaunchctl: runLaunchctl
                )
            } catch let cleanupError {
                throw UpdateError.launchdReloadHelperCleanupFailed(
                    bootstrap: String(describing: bootstrapError),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw bootstrapError
        }
    }

    static func fenceProviderReloadLaunchdJobs(
        homeDirectory: URL,
        uid: uid_t = getuid(),
        servicePresent: (String) throws -> Bool,
        loadedServiceLabels: () throws -> [String],
        runLaunchctl: ([String], Bool) throws -> Void,
        removalMaxChecks: Int = 100,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        guard removalMaxChecks > 0 else {
            throw UpdateError.processFailed("provider reload helper absence check", EINVAL)
        }
        let domain = "gui/\(uid)"
        let loadedLabels = try loadedServiceLabels()
        let staleReloadLabels = loadedLabels.filter {
            $0 == providerReloadLaunchdLabel || isLegacyProviderReloadLabel($0)
        }
        var labelsToFence = staleReloadLabels
        if !labelsToFence.contains(providerReloadLaunchdLabel) {
            labelsToFence.append(providerReloadLaunchdLabel)
        }
        for label in labelsToFence {
            try runLaunchctl(
                ["bootout", "\(domain)/\(label)"],
                true
            )
            var absent = false
            for attempt in 0 ..< removalMaxChecks {
                if try !servicePresent(label) {
                    absent = true
                    break
                }
                if attempt + 1 < removalMaxChecks {
                    sleep(0.1)
                }
            }
            guard absent else {
                throw UpdateError.processFailed("fence provider reload launch agent", EBUSY)
            }
        }
        let launchAgents = homeDirectory.appendingPathComponent(
            "Library/LaunchAgents",
            isDirectory: true
        )
        try removeLaunchdHelperIfPresent(
            launchAgents.appendingPathComponent("\(providerReloadLaunchdLabel).plist")
        )
    }

    static func providerReloadLaunchAgentData(
        providerPlistPath: String,
        helperPlistPath: String,
        uid: uid_t = getuid(),
        launchctlPath: String = "/bin/launchctl",
        sleepPath: String = "/bin/sleep",
        commandSleepPath: String = "/bin/sleep",
        providerRemovalMaxChecks: Int = 100,
        commandTimeoutChecks: Int = 50,
        commandTerminateGraceChecks: Int = 5
    ) throws -> Data {
        guard providerRemovalMaxChecks > 0,
              commandTimeoutChecks > 0,
              commandTerminateGraceChecks > 0 else {
            throw UpdateError.processFailed("provider reload absence check", EINVAL)
        }
        let domain = "gui/\(uid)"
        let target = "\(domain)/\(launchdLabel)"
        let helperTarget = "\(domain)/\(providerReloadLaunchdLabel)"
        let launchctl = shellQuote(launchctlPath)
        let sleep = shellQuote(sleepPath)
        let commandSleep = shellQuote(commandSleepPath)
        let runBounded = """
        run_bounded() { \
        "$@" & command_pid=$!; command_check=0; \
        while /bin/kill -0 "$command_pid" >/dev/null 2>&1; do \
        if [ "$command_check" -ge \(commandTimeoutChecks) ]; then \
        /bin/kill -TERM "$command_pid" >/dev/null 2>&1 || true; grace_check=0; \
        while /bin/kill -0 "$command_pid" >/dev/null 2>&1 && [ "$grace_check" -lt \(commandTerminateGraceChecks) ]; do \
        \(commandSleep) 0.1; grace_check=$((grace_check + 1)); done; \
        /bin/kill -KILL "$command_pid" >/dev/null 2>&1 || true; \
        wait "$command_pid" >/dev/null 2>&1 || true; return 124; fi; \
        \(commandSleep) 0.1; command_check=$((command_check + 1)); done; \
        if wait "$command_pid"; then return 0; else return $?; fi; }
        """
        let waitForProviderRemoval = """
        provider_absent=0; attempt=0; while [ "$attempt" -lt \(providerRemovalMaxChecks) ]; do \
        if output=$(run_bounded \(launchctl) print \(shellQuote(target)) 2>&1); then status=0; else status=$?; fi; \
        if [ "$status" -eq 113 ]; then \
        case "$output" in *"Could not find service"*) provider_absent=1; break ;; *) exit "$status" ;; esac; \
        elif [ "$status" -ne 0 ]; then exit "$status"; fi; \
        attempt=$((attempt + 1)); \
        if [ "$attempt" -lt \(providerRemovalMaxChecks) ]; then \(sleep) 0.1; fi; \
        done; [ "$provider_absent" -eq 1 ] || exit 75
        """
        let script = [
            "set -eu",
            "cleanup() { /bin/rm -f \(shellQuote(helperPlistPath)) >/dev/null 2>&1 || true; }",
            "trap cleanup EXIT HUP INT TERM",
            runBounded,
            "if run_bounded \(launchctl) bootout \(shellQuote(target)) >/dev/null 2>&1; then :; else status=$?; [ \"$status\" -ne 124 ] || exit \"$status\"; fi",
            waitForProviderRemoval,
            "run_bounded \(launchctl) bootstrap \(shellQuote(domain)) \(shellQuote(providerPlistPath))",
            "/bin/rm -f \(shellQuote(helperPlistPath))",
            "trap - EXIT HUP INT TERM",
            "if run_bounded \(launchctl) bootout \(shellQuote(helperTarget)) >/dev/null 2>&1; then :; else status=$?; [ \"$status\" -ne 124 ] || exit \"$status\"; fi",
        ].joined(separator: "; ")
        let propertyList: [String: Any] = [
            "Label": providerReloadLaunchdLabel,
            "ProgramArguments": ["/bin/sh", "-c", script],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LaunchOnlyOnce": true,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }

    static func launchctlServiceLabels() throws -> [String] {
        let result = try runLaunchctlCommand(arguments: ["list"])
        guard result.terminationStatus == 0 else {
            throw UpdateError.processFailed("/bin/launchctl list", result.terminationStatus)
        }
        return launchctlServiceLabels(from: result.output)
    }

    static func launchctlServicePresent(label: String) throws -> Bool {
        let target = launchdServiceTarget(label: label)
        let result = try runLaunchctlCommand(arguments: ["print", target], allowFailure: true)
        if result.terminationStatus == 0 {
            return true
        }
        if result.terminationStatus == 113,
           result.output.contains("Could not find service") {
            return false
        }
        throw UpdateError.processFailed(
            "/bin/launchctl print \(target)",
            result.terminationStatus
        )
    }

    static func launchctlServiceLoaded(
        label: String,
        executablePath: String = "/bin/launchctl",
        timeout: TimeInterval = 5
    ) -> Bool {
        (try? launchctlServiceLoadedOrThrow(
            label: label,
            executablePath: executablePath,
            timeout: timeout
        )) == true
    }

    static func launchctlServiceLoadedOrThrow(
        label: String,
        executablePath: String = "/bin/launchctl",
        timeout: TimeInterval = 5
    ) throws -> Bool {
        let target = launchdServiceTarget(label: label)
        let result = try runLaunchctlCommand(
            arguments: ["print", target],
            allowFailure: true,
            executablePath: executablePath,
            timeout: timeout
        )
        if result.terminationStatus == 113,
           result.output.contains("Could not find service") {
            return false
        }
        guard result.terminationStatus == 0 else {
            throw UpdateError.processFailed(
                "\(executablePath) print \(target)",
                result.terminationStatus
            )
        }
        return !result.output.lowercased().contains("disabled = true")
    }

    static func runLaunchctlCommand(
        arguments: [String],
        allowFailure: Bool = false,
        executablePath: String = "/bin/launchctl",
        timeout: TimeInterval = 5,
        terminateGrace: TimeInterval = 0.5
    ) throws -> LaunchctlCommandResult {
        guard executablePath.hasPrefix("/"), timeout > 0, timeout.isFinite,
              terminateGrace >= 0, terminateGrace.isFinite else {
            throw UpdateError.processFailed("bounded launchctl runner arguments", EINVAL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let combinedOutput = Pipe()
        process.standardOutput = combinedOutput
        process.standardError = combinedOutput
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        try process.run()

        let accumulator = LaunchctlOutputAccumulator()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drainGroup.leave() }
            let handle = combinedOutput.fileHandleForReading
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 64 * 1024),
                          !chunk.isEmpty else {
                        return
                    }
                    accumulator.append(chunk)
                } catch {
                    return
                }
            }
        }

        let timeoutMilliseconds = max(1, Int((timeout * 1_000).rounded(.up)))
        if termination.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
            process.terminate()
            let graceMilliseconds = max(1, Int((terminateGrace * 1_000).rounded(.up)))
            if termination.wait(timeout: .now() + .milliseconds(graceMilliseconds)) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + .milliseconds(graceMilliseconds))
            }
            combinedOutput.fileHandleForReading.closeFile()
            _ = drainGroup.wait(timeout: .now() + .milliseconds(graceMilliseconds))
            throw UpdateError.processTimedOut(
                "\(executablePath) \(arguments.joined(separator: " "))",
                timeout
            )
        }

        if drainGroup.wait(timeout: .now() + .seconds(1)) == .timedOut {
            combinedOutput.fileHandleForReading.closeFile()
            throw UpdateError.processTimedOut(
                "\(executablePath) \(arguments.joined(separator: " ")) output drain",
                1
            )
        }
        let result = LaunchctlCommandResult(
            terminationStatus: process.terminationStatus,
            output: String(decoding: accumulator.snapshot(), as: UTF8.self)
        )
        if !allowFailure, result.terminationStatus != 0 {
            throw UpdateError.processFailed(
                "\(executablePath) \(arguments.joined(separator: " "))",
                result.terminationStatus
            )
        }
        return result
    }

    static func launchctlServiceLabels(from output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, fields.last != "Label" else { return nil }
            return String(fields.last!)
        }
    }

    static func isLegacyProviderReloadLabel(_ label: String) -> Bool {
        guard label.hasPrefix(legacyProviderReloadLaunchdLabelPrefix) else {
            return false
        }
        let suffix = label.dropFirst(legacyProviderReloadLaunchdLabelPrefix.count)
        let groups = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else {
            return false
        }
        return groups.joined().allSatisfy {
            ("0" ... "9").contains($0) || ("a" ... "f").contains($0)
        }
    }

    private static func writeProviderReloadLaunchAgent(
        to helperPlist: URL,
        providerPlistPath: String,
        uid: uid_t
    ) throws {
        let data = try providerReloadLaunchAgentData(
            providerPlistPath: providerPlistPath,
            helperPlistPath: helperPlist.path,
            uid: uid
        )
        let temporary = helperPlist.deletingLastPathComponent().appendingPathComponent(
            ".\(helperPlist.lastPathComponent).tmp-\(UUID().uuidString.lowercased())"
        )
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw UpdateError.processFailed("create provider reload launch agent", errno)
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen {
                close(fd)
            }
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(
                    fd,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw UpdateError.processFailed(
                        "write provider reload launch agent",
                        errno
                    )
                }
                offset += count
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
            throw UpdateError.processFailed("sync provider reload launch agent", errno)
        }
        guard close(fd) == 0 else {
            descriptorOpen = false
            throw UpdateError.processFailed("close provider reload launch agent", errno)
        }
        descriptorOpen = false
        guard rename(temporary.path, helperPlist.path) == 0 else {
            throw UpdateError.processFailed("activate provider reload launch agent", errno)
        }
        let directoryFD = open(helperPlist.deletingLastPathComponent().path, O_RDONLY)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            close(directoryFD)
        }
    }

    private static func removeLaunchdHelperIfPresent(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT {
            throw UpdateError.processFailed("remove provider reload launch agent", errno)
        }
    }

    static func launchdRestartRecoveryCommand(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: uid_t = getuid()
    ) -> String {
        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let domain = "gui/\(uid)"
        return [watchdogLaunchdLabel, launchdLabel].map { label in
            let plist = launchAgents.appendingPathComponent("\(label).plist").path
            return "launchctl bootout \(domain)/\(label) || true; launchctl bootstrap \(domain) \(plist)"
        }.joined(separator: "; ")
    }

    private static func launchdServiceTarget(label: String = launchdLabel, uid: uid_t = getuid()) -> String {
        "gui/\(uid)/\(label)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func stageValidatedMalibuApp(
        from dmg: URL,
        in tempDirectory: URL,
        compatibilityManifest: CompatibilitySetManifest,
        newBinary: URL
    ) throws -> URL {
        let mountPoint = tempDirectory.appendingPathComponent("malibu-dmg", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mountPoint,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try runProcess(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-readonly", "-nobrowse", "-mountpoint", mountPoint.path, dmg.path]
        )
        defer {
            try? runProcess(
                "/usr/bin/hdiutil",
                arguments: ["detach", "-force", mountPoint.path],
                allowFailure: true
            )
        }

        let source = mountPoint.appendingPathComponent("Malibu.app", isDirectory: true)
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFDIR,
              (sourceInfo.st_mode & S_IFMT) != S_IFLNK
        else {
            throw UpdateError.malibuBundleInvalid("dmg_missing_bundle")
        }
        let staged = tempDirectory.appendingPathComponent("Malibu.app", isDirectory: true)
        try runProcess("/usr/bin/ditto", arguments: [source.path, staged.path])
        try Self.validateStagedMalibuBundle(
            staged,
            compatibilityManifest: compatibilityManifest,
            newBinary: newBinary
        )
        try validateMalibuCodeIdentity(staged)
        try runProcess("/usr/bin/codesign", arguments: ["--verify", "--strict", "--deep", staged.path])
        try runProcess("/usr/bin/xcrun", arguments: ["stapler", "validate", staged.path])
        try runProcess("/usr/sbin/spctl", arguments: ["-a", "-t", "exec", staged.path])
        return staged
    }

    private func validateMalibuCodeIdentity(_ app: URL) throws {
        let teamID: String
        do {
            teamID = try currentSigningTeamID()
        } catch {
            throw UpdateError.malibuBundleInvalid("running_cli_team_id_unavailable")
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw UpdateError.malibuBundleInvalid("code_object_unavailable")
        }
        let requirementText = "identifier \"tech.malibu.app\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                requirement
              ) == errSecSuccess
        else {
            throw UpdateError.malibuBundleInvalid("signature_or_team_id_mismatch")
        }
    }

    private func validateStagedCLIIdentity(_ binary: URL) throws {
        let teamID: String
        do {
            teamID = try currentSigningTeamID()
        } catch {
            throw UpdateError.stagedCLIIdentityInvalid("running_cli_team_id_unavailable")
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw UpdateError.stagedCLIIdentityInvalid("code_object_unavailable")
        }
        let requirementText = "identifier \"live.streamvc.macprovider.cli\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  requirement
              ) == errSecSuccess
        else {
            throw UpdateError.stagedCLIIdentityInvalid("signature_identifier_or_team_id_mismatch")
        }
    }

    typealias CodeValidityChecker = (
        SecCode,
        SecCSFlags,
        SecRequirement?
    ) -> OSStatus
    typealias StaticCodeCopier = (
        SecCode,
        SecCSFlags,
        UnsafeMutablePointer<SecStaticCode?>
    ) -> OSStatus
    typealias SigningInformationCopier = (
        SecStaticCode,
        SecCSFlags,
        UnsafeMutablePointer<CFDictionary?>
    ) -> OSStatus

    static func signingTeamID(
        for currentCode: SecCode,
        checkValidity: CodeValidityChecker = { code, flags, requirement in
            SecCodeCheckValidity(code, flags, requirement)
        },
        copyStaticCode: StaticCodeCopier = { code, flags, staticCode in
            SecCodeCopyStaticCode(code, flags, staticCode)
        },
        copySigningInformation: SigningInformationCopier = { code, flags, information in
            SecCodeCopySigningInformation(code, flags, information)
        }
    ) throws -> String {
        guard checkValidity(
            currentCode,
            Self.currentCodeValidityFlags,
            nil
        ) == errSecSuccess else {
            throw UpdateError.stagedCLIIdentityInvalid("running_cli_signing_identity_invalid")
        }
        var currentStaticCode: SecStaticCode?
        guard copyStaticCode(currentCode, [], &currentStaticCode) == errSecSuccess,
              let currentStaticCode
        else {
            throw UpdateError.stagedCLIIdentityInvalid("running_cli_static_identity_unavailable")
        }
        var signingInfo: CFDictionary?
        guard copySigningInformation(
            currentStaticCode,
            Self.currentSigningInformationFlags,
            &signingInfo
        ) == errSecSuccess,
              let info = signingInfo as? [String: Any],
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
              teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
        else {
            throw UpdateError.stagedCLIIdentityInvalid("running_cli_team_id_unavailable")
        }
        return teamID
    }

    private func currentSigningTeamID() throws -> String {
        var currentCode: SecCode?
        guard SecCodeCopySelf([], &currentCode) == errSecSuccess,
              let currentCode
        else {
            throw UpdateError.stagedCLIIdentityInvalid("running_cli_signing_identity_unavailable")
        }
        return try Self.signingTeamID(for: currentCode)
    }

    static func validateStagedMalibuBundleForTest(
        _ app: URL,
        compatibilityManifest: CompatibilitySetManifest,
        newBinary: URL
    ) throws {
        try validateStagedMalibuBundle(
            app,
            compatibilityManifest: compatibilityManifest,
            newBinary: newBinary
        )
    }

    private static func validateStagedMalibuBundle(
        _ app: URL,
        compatibilityManifest: CompatibilitySetManifest,
        newBinary: URL
    ) throws {
        var rootInfo = stat()
        guard lstat(app.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              (rootInfo.st_mode & S_IFMT) != S_IFLNK,
              rootInfo.st_uid == getuid(),
              (rootInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0
        else {
            throw UpdateError.malibuBundleInvalid("bundle_root_invalid")
        }
        let resolvedRoot = app.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else {
            throw UpdateError.malibuBundleInvalid("bundle_enumeration_failed")
        }
        for case let entry as URL in enumerator {
            var info = stat()
            guard lstat(entry.path, &info) == 0,
                  info.st_uid == getuid(),
                  (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
            else {
                throw UpdateError.malibuBundleInvalid("bundle_entry_invalid")
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                break
            case S_IFREG:
                guard info.st_nlink == 1 else {
                    throw UpdateError.malibuBundleInvalid("bundle_hardlink")
                }
            case S_IFLNK:
                guard entry.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPrefix) else {
                    throw UpdateError.malibuBundleInvalid("bundle_symlink_escape")
                }
            default:
                throw UpdateError.malibuBundleInvalid("bundle_entry_type")
            }
        }

        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL),
            format: nil
        ) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "tech.malibu.app",
              info["CFBundleShortVersionString"] as? String == compatibilityManifest.malibuAppVersion
        else {
            throw UpdateError.malibuBundleInvalid("bundle_identity_or_version_mismatch")
        }
        let embeddedManifest = app.appendingPathComponent(
            "Contents/Resources/\(CompatibilitySetManifest.fileName)"
        )
        let payloadManifest = newBinary.deletingLastPathComponent()
            .appendingPathComponent(CompatibilitySetManifest.fileName)
        guard try Data(contentsOf: embeddedManifest) == Data(contentsOf: payloadManifest) else {
            throw UpdateError.malibuBundleInvalid("embedded_manifest_mismatch")
        }
        let embeddedCLI = app.appendingPathComponent("Contents/MacOS/macprovider-cli")
        guard try sha256(file: embeddedCLI) == sha256(file: newBinary) else {
            throw UpdateError.malibuBundleInvalid("embedded_cli_mismatch")
        }
    }

    private func validateDownloadURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            throw UpdateError.untrustedDownloadURL(url.absoluteString)
        }
        guard host == "github.com" || host.hasSuffix(".github.com") || host == "objects.githubusercontent.com" else {
            throw UpdateError.untrustedDownloadURL(url.absoluteString)
        }
    }

    private func validateReleaseAPIURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host == "api.github.com" else {
            throw UpdateError.untrustedReleaseAPIURL(url.absoluteString)
        }
    }

    private func validateTarball(_ url: URL) throws {
        let listing = try processOutput("/usr/bin/tar", arguments: ["-tzf", url.path])
        let verboseListing = try processOutput("/usr/bin/tar", arguments: ["-tvzf", url.path])
        for line in verboseListing.split(separator: "\n") {
            guard let type = line.utf8.first, type == 0x2D || type == 0x64 else {
                throw UpdateError.unsafeArchiveEntry(String(line))
            }
        }
        var normalizedEntries = Set<String>()
        for rawEntry in listing.split(separator: "\n").map(String.init) {
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            if entry.hasPrefix("/") || entry == ".." || entry.hasPrefix("../") || entry.contains("/../") {
                throw UpdateError.unsafeArchiveEntry(entry)
            }
            let normalized = (entry as NSString).standardizingPath
            guard normalized != ".", !normalized.hasPrefix("../"), normalized != "..",
                  normalizedEntries.insert(normalized).inserted
            else {
                throw UpdateError.unsafeArchiveEntry(entry)
            }
        }
    }

    static func validateExtractedTreeForTest(_ root: URL) throws {
        try validateExtractedTree(root)
    }

    static func validatedAcceptanceAssetNames(in directory: URL) throws -> [String] {
        let canonical = directory.standardizedFileURL
        guard canonical.path.hasPrefix("/"),
              canonical.resolvingSymlinksInPath().standardizedFileURL.path == canonical.path
        else {
            throw UpdateError.unsafeAcceptanceDirectory("path_not_canonical")
        }
        var rootInfo = stat()
        guard lstat(canonical.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              (rootInfo.st_mode & S_IFMT) != S_IFLNK,
              rootInfo.st_uid == getuid(),
              (rootInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0
        else {
            throw UpdateError.unsafeAcceptanceDirectory("directory_permissions_or_owner")
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: canonical,
            includingPropertiesForKeys: nil
        )
        guard !entries.isEmpty, entries.count <= 64 else {
            throw UpdateError.unsafeAcceptanceDirectory("asset_count")
        }
        var names: [String] = []
        var totalBytes: Int64 = 0
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$"#,
                options: .regularExpression
            ) != nil else {
                throw UpdateError.unsafeAcceptanceDirectory("asset_name")
            }
            var info = stat()
            guard lstat(entry.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  (info.st_mode & S_IFMT) != S_IFLNK,
                  info.st_uid == getuid(),
                  info.st_nlink == 1,
                  (info.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                  info.st_size >= 0
            else {
                throw UpdateError.unsafeAcceptanceDirectory("asset_permissions_or_type")
            }
            guard totalBytes <= 8 * 1_024 * 1_024 * 1_024 - info.st_size else {
                throw UpdateError.unsafeAcceptanceDirectory("asset_bytes")
            }
            totalBytes += info.st_size
            names.append(name)
        }
        return names.sorted()
    }

    private static func validateExtractedTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw UpdateError.unsafeArchiveEntry(root.path)
        }
        for case let entry as URL in enumerator {
            var info = stat()
            guard lstat(entry.path, &info) == 0,
                  info.st_uid == getuid(),
                  (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
            else { throw UpdateError.unsafeArchiveEntry(entry.path) }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else {
                throw UpdateError.unsafeArchiveEntry(entry.path)
            }
            if type == S_IFREG, info.st_nlink != 1 {
                throw UpdateError.unsafeArchiveEntry(entry.path)
            }
        }
    }

    private func validateFreeSpace(for directory: URL, requiredForKnownTarballAt tarball: URL?) throws {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let tarballSize = tarball.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value } ?? 0
        let required = max(512 * 1024 * 1024, tarballSize * 3)
        guard free >= required else {
            throw UpdateError.insufficientDiskSpace(required: required, available: free)
        }
    }

    private func verifyChecksumSignature(checksumsURL: URL, signatureURL: URL, tempDir _: URL) throws {
        let checksums: Data
        do {
            checksums = try Data(contentsOf: checksumsURL)
        } catch {
            throw UpdateError.checksumSignatureInvalid
        }
        try verifyReleaseSignature(
            payload: checksums,
            signatureURL: signatureURL,
            publicKeyPEM: Self.checksumPublicKeyPEM,
            signatureEncoding: .der,
            failure: .checksumSignatureInvalid
        )
    }

    private func verifyReleaseSignature(
        payload: Data,
        signatureURL: URL,
        publicKeyPEM: String,
        signatureEncoding: ReleaseSignatureEncoding,
        failure: UpdateError
    ) throws {
        do {
            let publicKey = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
            let signatureBytes: Data
            switch signatureEncoding {
            case .der:
                signatureBytes = try Data(contentsOf: signatureURL)
            case .canonicalBase64DER:
                let encodedWithNewline = try Data(contentsOf: signatureURL)
                guard encodedWithNewline.last == 0x0a else { throw failure }
                let encoded = Data(encodedWithNewline.dropLast())
                guard !encoded.isEmpty,
                      !encoded.contains(0x0a),
                      let decoded = Data(base64Encoded: encoded),
                      decoded.count >= 64,
                      decoded.count <= 80,
                      Data(decoded.base64EncodedString().utf8) == encoded
                else { throw failure }
                signatureBytes = decoded
            }
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureBytes)
            let digest = SHA256.hash(data: payload)
            guard publicKey.isValidSignature(signature, for: digest) else { throw failure }
        } catch {
            throw failure
        }
    }

    private func processOutput(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.processFailed(executable, process.terminationStatus)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    static func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    static func validateReleaseTag(_ tag: String) throws -> String {
        guard tag.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw UpdateError.invalidReleaseVersion(tag)
        }
        do {
            return try AutoUpdateRecommendation.validate(tag).normalized
        } catch {
            throw UpdateError.invalidReleaseVersion(tag)
        }
    }

    static func requireStagedBinaryVersion(_ output: String, targetVersion: String) throws {
        let exact = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged: String
        do {
            staged = try validateReleaseTag(exact)
        } catch {
            throw UpdateError.stagedVersionMismatch(expected: targetVersion, actual: exact)
        }
        guard staged == targetVersion else {
            throw UpdateError.stagedVersionMismatch(expected: targetVersion, actual: staged)
        }
    }

    static func requireAcceptanceProviderVersion(current: String, target: String) throws {
        let normalizedCurrent = try validateReleaseTag(current)
        let normalizedTarget = try validateReleaseTag(target)
        guard compareSemver(normalizedCurrent, normalizedTarget) != .orderedDescending else {
            throw UpdateError.acceptanceProviderDowngrade(
                current: normalizedCurrent,
                target: normalizedTarget
            )
        }
    }

    private static func expectedSHA256(for filename: String, in text: String) throws -> String {
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2, parts[1] == filename, parts[0].range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil {
                return parts[0]
            }
        }
        throw UpdateError.checksumMissing(filename)
    }

    private static func sha256(file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func findBinary(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isExecutableKey]) else {
            throw UpdateError.missingExtractedBinary
        }
        var matches: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "macprovider-cli" {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isExecutableKey])
            if values.isSymbolicLink == false, values.isRegularFile == true, values.isExecutable == true {
                matches.append(url)
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw UpdateError.missingExtractedBinary
        }
        return match
    }
}

struct ProviderReleasePayloadTransaction {
    let currentBinary: URL
    let installDirectory: URL
    let backupDirectory: URL
    let markerStore: AutoUpdateMarkerStore
    private let fileManager: FileManager

    init(
        currentBinary: URL,
        markerStore: AutoUpdateMarkerStore,
        fileManager: FileManager = .default
    ) throws {
        self.currentBinary = currentBinary
        installDirectory = currentBinary.deletingLastPathComponent()
        backupDirectory = installDirectory.appendingPathComponent(
            ".macprovider-cli.manual-rollback-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        self.markerStore = markerStore
        self.fileManager = fileManager

        try markerStore.validateTrustedBinaryDirectory(installDirectory)
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let currentEntries = try Self.ownedEntries(in: installDirectory, fileManager: fileManager)
            guard currentEntries.contains(where: { $0.standardizedFileURL == currentBinary.standardizedFileURL }) else {
                throw UpdateError.missingReleaseResource("installed macprovider-cli")
            }
            for entry in currentEntries {
                try fileManager.copyItem(
                    at: entry,
                    to: backupDirectory.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
                )
            }
        } catch {
            try? fileManager.removeItem(at: backupDirectory)
            throw error
        }
    }

    static func validateReleasePayload(
        at payloadDirectory: URL,
        newBinary: URL,
        fileManager: FileManager = .default
    ) throws {
        _ = try validatedPayloadEntries(
            in: payloadDirectory,
            newBinary: newBinary,
            fileManager: fileManager
        )
    }

    func activate(from payloadDirectory: URL, newBinary: URL) throws {
        let entries = try Self.validatedPayloadEntries(
            in: payloadDirectory,
            newBinary: newBinary,
            fileManager: fileManager
        )

        let stagingDirectory = installDirectory.appendingPathComponent(
            ".macprovider-cli.activation-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        for entry in entries {
            try fileManager.copyItem(
                at: entry,
                to: stagingDirectory.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            )
        }

        try removeCurrentResources()
        for entry in try Self.ownedEntries(in: stagingDirectory, fileManager: fileManager)
            where entry.lastPathComponent != "macprovider-cli"
        {
            try fileManager.moveItem(
                at: entry,
                to: installDirectory.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            )
        }
        try markerStore.atomicCopyNoFollow(
            from: stagingDirectory.appendingPathComponent("macprovider-cli"),
            to: currentBinary,
            mode: 0o755
        )
    }

    func restore() throws {
        try removeCurrentResources()
        let backupEntries = try Self.ownedEntries(in: backupDirectory, fileManager: fileManager)
        for entry in backupEntries where entry.lastPathComponent != "macprovider-cli" {
            try fileManager.copyItem(
                at: entry,
                to: installDirectory.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            )
        }
        let backupBinary = backupDirectory.appendingPathComponent("macprovider-cli")
        guard fileManager.fileExists(atPath: backupBinary.path) else {
            throw UpdateError.missingReleaseResource("rollback macprovider-cli")
        }
        let attributes = try fileManager.attributesOfItem(atPath: backupBinary.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        try markerStore.atomicCopyNoFollow(from: backupBinary, to: currentBinary, mode: mode)
    }

    func cleanup() {
        try? fileManager.removeItem(at: backupDirectory)
    }

    private func removeCurrentResources() throws {
        for entry in try Self.ownedEntries(in: installDirectory, fileManager: fileManager)
            where entry.lastPathComponent != "macprovider-cli"
        {
            try fileManager.removeItem(at: entry)
        }
    }

    private static func validatedPayloadEntries(
        in directory: URL,
        newBinary: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        let entries = try ownedEntries(in: directory, fileManager: fileManager)
        guard entries.contains(where: { $0.standardizedFileURL == newBinary.standardizedFileURL }) else {
            throw UpdateError.missingReleaseResource("macprovider-cli")
        }
        guard entries.contains(where: { $0.lastPathComponent == "mlx.metallib" }) else {
            throw UpdateError.missingReleaseResource("mlx.metallib")
        }
        guard entries.contains(where: { $0.lastPathComponent == CompatibilitySetManifest.fileName }) else {
            throw UpdateError.missingReleaseResource(CompatibilitySetManifest.fileName)
        }
        guard let localArtifacts = entries.first(where: {
            $0.lastPathComponent == CompatibilitySetManifest.localArtifactDirectoryName
        }) else {
            throw UpdateError.missingReleaseResource(CompatibilitySetManifest.localArtifactDirectoryName)
        }
        guard entries.contains(where: { $0.pathExtension == "bundle" }) else {
            throw UpdateError.missingReleaseResource("SwiftPM resource bundle")
        }
        guard let catalogDirectory = entries.first(where: { $0.lastPathComponent == "catalog-release" }) else {
            throw UpdateError.missingReleaseResource("catalog-release")
        }
        for requiredName in [
            "release.json",
            "trusted-keys.json",
            "tier2-catalog.json",
            "autotune-candidates.json",
            "autotune-candidates.json.sig",
            "demand-rank.json",
            "demand-rank.json.sig",
            "rate-card.json",
            "rate-card.json.sig",
        ] {
            let requiredURL = catalogDirectory.appendingPathComponent(requiredName)
            let values = try requiredURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw UpdateError.missingReleaseResource("catalog-release/\(requiredName)")
            }
        }
        let requiredLocalArtifacts = Set([
            "install.sh",
            "provider-launch-agent.plist.template",
            "updater-rollback.json",
            "watchdog-launch-agent.plist.template",
            "watchdog.sh",
        ])
        let actualLocalArtifacts = try Set(fileManager.contentsOfDirectory(atPath: localArtifacts.path))
        guard actualLocalArtifacts == requiredLocalArtifacts else {
            throw UpdateError.missingReleaseResource("compatibility-set-local members")
        }
        return entries
    }

    private static func ownedEntries(in directory: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { entry in
            let name = entry.lastPathComponent
            guard name == "macprovider-cli"
                    || name == "mlx.metallib"
                    || name == "THIRD-PARTY-NOTICES.txt"
                    || name == CompatibilitySetManifest.fileName
                    || name == CompatibilitySetManifest.localArtifactDirectoryName
                    || name == "catalog-release"
                    || entry.pathExtension == "bundle"
            else {
                return false
            }
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true
            else {
                return false
            }
            if entry.pathExtension == "bundle"
                || name == "catalog-release"
                || name == CompatibilitySetManifest.localArtifactDirectoryName
            {
                return values.isDirectory == true
            }
            return values.isRegularFile == true
        }
    }
}

struct PreparedSelfUpdate {
    let tempDir: URL
    let newBinary: URL
    let stagedMalibuApp: URL?
    let signedPolicy: GitHubSignedPolicy?
    let compatibilityManifest: CompatibilitySetManifest
    let artifactIndexSHA256: String

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]
    let body: String?
    let signedPolicy: GitHubSignedPolicy?
    let isDraft: Bool?
    let isPrerelease: Bool?
    let isImmutable: Bool?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case body
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case isImmutable = "immutable"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        assets = try container.decode([GitHubAsset].self, forKey: .assets)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft)
        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease)
        isImmutable = try container.decodeIfPresent(Bool.self, forKey: .isImmutable)
        // Release JSON/body metadata is not covered by checksums.txt.sig.
        // Persisting policy from those unsigned fields would let a tampered
        // release response change local trust state before signature proof.
        // Keep the decoded shape for future signed-policy plumbing, but drop
        // unsigned metadata on read.
        signedPolicy = nil
    }
}

struct GitHubSignedPolicy: Equatable {
    let minimum: String?
    let revoked: [String]
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

enum UpdateError: Error, CustomStringConvertible {
    case invalidURL(String)
    case httpStatus(Int)
    case releaseNotFound
    case missingAsset
    case invalidReleaseVersion(String)
    case stagedVersionMismatch(expected: String, actual: String)
    case checksumMissing(String)
    case checksumMismatch(expected: String, actual: String)
    case checksumSignatureInvalid
    case acceptanceMetadataSignatureInvalid
    case acceptanceMetadataInvalid(String)
    case missingExtractedBinary
    case currentBinaryUnknown
    case processFailed(String, Int32)
    case processTimedOut(String, TimeInterval)
    case renameFailed(Int32)
    case untrustedDownloadURL(String)
    case untrustedReleaseAPIURL(String)
    case unsafeArchiveEntry(String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case missingReleaseResource(String)
    case malibuBundleInvalid(String)
    case compatibilityManifestInvalid(String)
    case compatibilityManifestVersionMismatch(expected: String, actual: String)
    case compatibilityArtifactIndexInvalid(String)
    case discoveryHeadInvalid(String)
    case discoveryHeadReplay
    case discoveryHeadEquivocation
    case discoveryHeadExpired
    case unsafeAcceptanceDirectory(String)
    case acceptanceCandidateNotNewer(current: String, target: String)
    case acceptanceProviderDowngrade(current: String, target: String)
    case stagedCLIIdentityInvalid(String)
    case rollbackUnavailable
    case activationFailedRollbackFailed(update: String, rollback: String)
    case restartFailedRollbackRestored(restart: String, recoveryCommand: String)
    case restartFailedRollbackFailed(restart: String, rollback: String)
    case launchdReloadHelperCleanupFailed(bootstrap: String, cleanup: String)

    var description: String {
        switch self {
        case .invalidURL(let url):
            return "Invalid release API URL: \(url)"
        case .httpStatus(let status):
            return "GitHub API returned HTTP \(status)"
        case .releaseNotFound:
            return "GitHub release tag not found"
        case .missingAsset:
            return "Release is missing the canonical tag-bound darwin-arm64 tarball, Malibu DMG, compatibility artifact index, checksums.txt, or checksums.txt.sig"
        case .invalidReleaseVersion(let version):
            return "Release tag is not strict semantic version: \(version)"
        case let .stagedVersionMismatch(expected, actual):
            return "Signed release payload version mismatch: expected \(expected), staged binary reported \(actual)"
        case .checksumMissing(let filename):
            return "checksums.txt does not contain \(filename)"
        case let .checksumMismatch(expected, actual):
            return "Checksum mismatch: expected \(expected), got \(actual)"
        case .checksumSignatureInvalid:
            return "checksums.txt signature verification failed"
        case .acceptanceMetadataSignatureInvalid:
            return "Acceptance-candidate metadata signature verification failed"
        case .acceptanceMetadataInvalid(let reason):
            return "Acceptance-candidate metadata is invalid: \(reason)"
        case .missingExtractedBinary:
            return "Downloaded archive does not contain macprovider-cli"
        case .currentBinaryUnknown:
            return "Unable to locate the running binary path"
        case let .processFailed(executable, status):
            return "\(executable) exited with status \(status)"
        case let .processTimedOut(executable, timeout):
            return "\(executable) timed out after \(timeout) seconds"
        case .renameFailed(let errnoValue):
            return "Atomic binary replacement failed with errno \(errnoValue)"
        case .untrustedDownloadURL(let url):
            return "Untrusted release asset URL: \(url)"
        case .untrustedReleaseAPIURL(let url):
            return "Untrusted release API URL: \(url)"
        case .unsafeArchiveEntry(let entry):
            return "Release archive contains unsafe entry: \(entry)"
        case let .insufficientDiskSpace(required, available):
            return "Insufficient disk space: required \(required), available \(available)"
        case .missingReleaseResource(let resource):
            return "Release payload is missing required resource: \(resource)"
        case .malibuBundleInvalid(let reason):
            return "Signed Malibu bundle validation failed: \(reason)"
        case .compatibilityManifestInvalid(let reason):
            return "Signed compatibility-set manifest is invalid: \(reason)"
        case let .compatibilityManifestVersionMismatch(expected, actual):
            return "Compatibility-set version mismatch: expected \(expected), got \(actual)"
        case .compatibilityArtifactIndexInvalid(let reason):
            return "Signed compatibility artifact index is invalid: \(reason)"
        case .discoveryHeadInvalid(let reason):
            return "Signed release discovery head is invalid: \(reason)"
        case .discoveryHeadReplay:
            return "Signed release discovery head replayed an older sequence"
        case .discoveryHeadEquivocation:
            return "Signed release discovery head changed digest at the accepted sequence"
        case .discoveryHeadExpired:
            return "Signed release discovery head is expired or not yet valid"
        case .unsafeAcceptanceDirectory(let reason):
            return "Acceptance-candidate directory is unsafe: \(reason)"
        case let .acceptanceCandidateNotNewer(current, target):
            return "Acceptance candidate must advance the installed version: current \(current), target \(target)"
        case let .acceptanceProviderDowngrade(current, target):
            return "Acceptance candidate must not downgrade the provider CLI outside emergency rollback: current \(current), target \(target)"
        case .stagedCLIIdentityInvalid(let reason):
            return "Signed provider CLI validation failed: \(reason)"
        case .rollbackUnavailable:
            return "rollback_failed: no rollback mechanism is available for the applied update"
        case let .activationFailedRollbackFailed(update, rollback):
            return "rollback_failed: update activation failed (\(update)) and rollback failed (\(rollback))"
        case let .restartFailedRollbackRestored(restart, recoveryCommand):
            return "rollback_restored: restart failed (\(restart)); previous provider release restored. If needed, run: \(recoveryCommand)"
        case let .restartFailedRollbackFailed(restart, rollback):
            return "rollback_failed: restart failed (\(restart)) and rollback failed (\(rollback))"
        case let .launchdReloadHelperCleanupFailed(bootstrap, cleanup):
            return "launchd reload helper bootstrap failed (\(bootstrap)) and helper cleanup failed (\(cleanup))"
        }
    }
}

struct LocalStatusClient {
    static func fetch(port: Int) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/status")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.processFailed("status-json", 1)
        }
        return object
    }
}

struct LocalStatusFormatter {
    static func format(
        _ status: [String: Any],
        latestVersion: String? = nil,
        ownerLogin: String? = nil,
        donorMode: Bool = false,
        staleRecommendationSince: Date? = nil,
        configPath: String? = nil,
        advanced: Bool = false
    ) -> String {
        guard advanced else {
            return publicFormat(
                status,
                latestVersion: latestVersion,
                ownerLogin: ownerLogin,
                donorMode: donorMode,
                staleRecommendationSince: staleRecommendationSince
            )
        }
        return advancedFormat(
            status,
            latestVersion: latestVersion,
            ownerLogin: ownerLogin,
            donorMode: donorMode,
            staleRecommendationSince: staleRecommendationSince,
            configPath: configPath
        )
    }

    private static func publicFormat(
        _ status: [String: Any],
        latestVersion: String?,
        ownerLogin: String?,
        donorMode: Bool,
        staleRecommendationSince: Date?
    ) -> String {
        let coordinator = status["coordinator"] as? [String: Any] ?? [:]
        let lifecycle = status["lifecycle"] as? [String: Any] ?? [:]
        let lifecycleState = string(lifecycle["state"])
        let lifecycleReason = string(lifecycle["reason_code"])
        let version = status["binary_version"] as? String ?? CoordinatorClient.binaryVersion
        let providerID = string(status["provider_id"])
        let model = string(status["model"])
        let localState = string(status["status"])
        let networkState = string(status["network_state"])
        let connected = (coordinator["connected"] as? Bool) == true
        let modelLoaded = (status["model_loaded"] as? Bool) ?? ["ready", "busy", "degraded"].contains(localState)
        let title: String
        let nextStep: String?

        if donorMode || networkState == "local_donor" {
            title = "Provider is running locally"
            nextStep = "Open Malibu when you are ready to join the network."
        } else if networkState == "buyer_serving" && connected && modelLoaded && !["draining", "unavailable"].contains(localState) {
            title = "Provider is ready"
            nextStep = nil
        } else if lifecycleReason == "autotune_evidence_required" {
            title = "Pending hardware verification"
            nextStep = "Run `macprovider-cli autotune --recommend --freshness-check --require-hardware-evidence` while online. Recently submitted evidence may still be awaiting operator approval."
        } else if lifecycleReason == "autotune_evidence_invalid"
            || lifecycleReason == "autotune_evidence_binary_version_mismatch"
            || lifecycleReason == "autotune_model_cap_exceeded"
        {
            title = "Not eligible: admission evidence failed"
            nextStep = "Run `macprovider-cli autotune --recommend --recover-hardware-admission` while online."
        } else if lifecycleState == "catalog_incompatible"
            || lifecycleReason == "autotune_model_uncatalogued"
            || ["catalog_update_required", "compatibility_update_required"].contains(networkState) {
            title = "This Mac is not currently eligible"
            nextStep = lifecycleReason == "autotune_model_uncatalogued"
                ? "Run `macprovider-cli autotune --recommend --recover-hardware-admission` while online."
                : "Run `macprovider-cli update`, or choose a catalog-supported model."
        } else if networkState == "not_buyer_serving" {
            title = "This Mac is not currently eligible"
            nextStep = "Open Malibu to review the recommended next step."
        } else if !modelLoaded || ["draining", "unavailable"].contains(localState) {
            title = "Model is preparing"
            nextStep = "Keep this Mac awake while preparation completes."
        } else if !connected {
            title = "Provider is connecting"
            nextStep = "Check this Mac's internet connection."
        } else {
            title = "Waiting for network approval"
            nextStep = "No action is needed while approval completes."
        }

        let owner = ownerLogin.map { "@\($0)" } ?? "Not linked"
        let update: String
        if let latestVersion,
           SelfUpdate.compareSemver(version, latestVersion) == .orderedAscending {
            update = "v\(version) · v\(latestVersion) available"
        } else if latestVersion != nil {
            update = "v\(version) · up to date"
        } else {
            update = "v\(version) · update status unavailable"
        }
        let recommendation = staleRecommendationSince == nil
            ? ""
            : "\nRecommendation: Refresh with `macprovider-cli autotune --recommend`."
        let action = nextStep.map { "\nNext step: \($0)" } ?? ""

        return """
        macprovider-cli v\(version)

        \(title)
        Provider: \(providerID)
        Owner: \(owner)
        Model: \(model)
        Provider software: \(update)
        Requests: \(status["requests_total"] ?? 0) served, \(status["errors_total"] ?? 0) errors\(recommendation)\(action)

        Advanced diagnostics: macprovider-cli status --advanced
        """
    }

    private static func advancedFormat(
        _ status: [String: Any],
        latestVersion: String?,
        ownerLogin: String?,
        donorMode: Bool,
        staleRecommendationSince: Date?,
        configPath: String?
    ) -> String {
        let capacity = status["capacity"] as? [String: Any] ?? [:]
        let coordinator = status["coordinator"] as? [String: Any] ?? [:]
        let catalog = status["catalog"] as? [String: Any] ?? [:]
        let admissionIdentity = status["admission_identity"] as? [String: Any] ?? [:]
        let version = status["binary_version"] as? String ?? CoordinatorClient.binaryVersion
        let uptime = humanDuration(status["uptime_s"] as? Int ?? 0)
        let connected = (coordinator["connected"] as? Bool) == true ? "yes" : "no"
        let ownerLine = ownerLogin.map { "\($0) (github.com/\($0))" } ?? "(unclaimed — run `macprovider-cli claim`)"
        let latestLine: String
        if let latestVersion {
            let comparison = SelfUpdate.compareSemver(version, latestVersion)
            latestLine = comparison == .orderedAscending
                ? "v\(latestVersion) (run 'macprovider-cli update' to upgrade)"
                : "v\(latestVersion)"
        } else {
            latestLine = "unknown (run 'macprovider-cli update --check')"
        }
        let donorBadge = donorMode ? " DONOR MODE" : ""
        let staleBlock = staleRecommendationSince.map {
            "\nRecommendation stale: recommendation inputs changed since \(ISO8601DateFormatter.autotuneInternet.string(from: $0)).\nRun: macprovider-cli autotune --recommend\n"
        } ?? ""
        let providerID = string(status["provider_id"])
        let recoveryCommand: String = {
            guard let configPath else { return "macprovider-cli credentials recover-admission-identity --config <config> --expected-provider-id \(shellQuote(providerID))" }
            return "macprovider-cli credentials recover-admission-identity --config \(shellQuote(configPath)) --expected-provider-id \(shellQuote(providerID))"
        }()
        let admissionState = string(admissionIdentity["state"])
        let admissionAction: String
        switch admissionState {
        case "recovery_pending":
            admissionAction = "Submit POST /admin/provider-admission-identity/recover, obtain second-operator approval, then run: \(recoveryCommand) --activate"
        case "degraded_previous_key", "missing", "recovery_required":
            admissionAction = "Run: \(recoveryCommand) --incident-id <incident_id> --reason <reason>"
        default:
            admissionAction = string(admissionIdentity["recovery_action"])
        }

        return """
        macprovider-cli v\(version)

        Local:
          Provider ID:  \(string(status["provider_id"]))
          Owner: \(ownerLine)
          Model:       \(string(status["model"]))\(donorBadge)
          Status:      \(string(status["status"]))
          Uptime:      \(uptime)
          Requests:    \(status["requests_total"] ?? 0) served, \(status["errors_total"] ?? 0) errors
          Active WS:   \(status["active_request_id_count"] ?? 0) request_ids
          RAM:         \(capacity["ram_gb"] ?? 0) GB (\(string(capacity["ram_tier"])))
          Context cap: \(capacity["max_context_tokens"] ?? 0) tokens

        Coordinator:
          URL:         \(string(coordinator["url"]))
          Connected:   \(connected)
          Session:     \(string(coordinator["session"]))
          Tier:        \(string(coordinator["tier"]))
          Recommended: \(string(coordinator["recommended_binary_version"]))

        Catalog:
          Network:     \(string(status["network_state"]))
          Trust:       \(string(catalog["state"]))
          Release:     \(string(catalog["release_id"]))
          Signer:      \(string(catalog["signer_key_id"]))
          Digest:      \(string(catalog["digest"]))

        Admission identity:
          Source:      \(string(admissionIdentity["source"]))
          State:       \(admissionState)
          Current:     \(string(admissionIdentity["public_key_sha256"]))
          Pending:     \(string(admissionIdentity["pending_public_key_sha256"]))
          Previous:    \(string(admissionIdentity["previous_public_key_sha256"]))
          Previous until: \(string(admissionIdentity["previous_valid_until"]))
          Coordinator: generation=\(string(admissionIdentity["coordinator_generation"])) role=\(string(admissionIdentity["coordinator_key_role"])) key=\(string(admissionIdentity["coordinator_public_key_sha256"]))
          Error:       \(string(admissionIdentity["transition_error"]))
          Action:      \(admissionAction)

        Update:
          Current:     v\(version)
          Latest:      \(latestLine)
        \(staleBlock)
        """
    }

    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<unknown>" }
        return String(describing: value)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func humanDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(seconds % 60)s"
    }
}

enum OwnerFileReader {
    static func githubLogin(configPath: String) -> String? {
        let claimURLFile = ClaimURLFile(configPath: configPath)
        guard let body = try? String(contentsOf: claimURLFile.ownerURL, encoding: .utf8) else {
            return nil
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0] == "github_login" {
                let login = String(parts[1])
                return isValidGitHubLogin(login) ? login : nil
            }
        }
        return nil
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
