import CryptoKit
import Darwin
import Foundation

/// SPEC-048 0.1.23 / SPEC-023-R024: the pinned fused A3B MoE path covers rows
/// of at most seven tokens, and a native verification row carries
/// `proposal_depth + 1` target tokens. A deeper proposal would move that row
/// between the fused and stock kernels as the scheduler reduces depth.
let nativeMTPMaximumProposalDepth = 6

struct NativeMTPAdmissionCapability: Equatable, Sendable {
    let tupleSHA256: String
    let sidecarSHA256: String
    let modelID: String
    let modelRevision: String
    let targetArtifactSHA256: String
    let mtpArtifactSHA256: String
    let tokenizerSHA256: String
    let mtpManifestSHA256: String
    let familyAdapter: String
    let sourceLayout: String
    let predictionLayerCount: Int
    let maxProposalDepth: Int
    let completeWindowBytesByDepth: [Int]
    let throughputDeltaPPM: Int
    let maxPromptTokens: Int
    let maxCompletionTokens: Int
    let cacheClass: String
    let stateClass: String
    let quantization: NativeMTPAdmissionSidecar.Quantization
    let providerRevision: String
    let upstreamMLXSwiftLMRevision: String
    let qualifiedSlots: Int
    /// SPEC-048-R007 load gate: native MTP serves a row only while at most
    /// this many decode rows are active; signed, `1...qualifiedSlots`.
    let maxNativeActiveRows: Int
    let spec023ReleaseID: String
    let spec023SourceCommit: String
    let spec023BuildDigestSHA256: String
    let spec023LiveExecutableCDHash: String
    let evidenceArtifactSHA256: [String]
    let challengeBankSignerKeyID: String
    let revocationSignerKeyID: String
    let selfTestChallengeBank: NativeMTPSelfTestChallengeBank
    let capturedArtifacts: NativeMTPAdmissionCapturedArtifacts?
    /// SPEC-023-R024 `request_feature_profile` is the sampled profile: the
    /// tuple qualified target-sample exact-match verification (SPEC-048-R004).
    var supportsSampling: Bool = false
}

struct NativeMTPSelfTestChallengeBank: Equatable, Sendable {
    let releaseID: String
    let challengeBankPath: String
    let challengeBankSHA256: String
    let signaturePath: String
    let signerKeyID: String
    let signatureSHA256: String
}

struct NativeMTPResolvedArtifactAuthority: Equatable, Sendable {
    static let nativeMTPHashAlgorithm = "macprovider.snapshot-manifest.v1"

    let releaseID: String
    let signerKeyID: String
    let feedSHA256: String
    let modelKey: String
    let artifactID: String
    let hashAlgorithm: String
    let hash: String
    let verificationStatus: String
    let targetURLPath: String
    let targetSHA256: String

    private init(
        releaseID: String,
        signerKeyID: String,
        feedSHA256: String,
        modelKey: String,
        artifactID: String,
        hashAlgorithm: String,
        hash: String,
        verificationStatus: String,
        targetURLPath: String,
        targetSHA256: String
    ) {
        self.releaseID = releaseID
        self.signerKeyID = signerKeyID
        self.feedSHA256 = feedSHA256
        self.modelKey = modelKey
        self.artifactID = artifactID
        self.hashAlgorithm = hashAlgorithm
        self.hash = hash
        self.verificationStatus = verificationStatus
        self.targetURLPath = targetURLPath
        self.targetSHA256 = targetSHA256
    }

    static func resolve(
        qualifiedFeed: QualifiedArtifactFeed,
        releaseID: String,
        modelKey: String,
        artifactID: String,
        hash: String,
        preflightTargetURL: URL
    ) throws -> NativeMTPResolvedArtifactAuthority {
        guard releaseID == qualifiedFeed.releaseID else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.artifact_authority.release_id")
        }
        guard feedSHA256IsValid(qualifiedFeed.feedSHA256) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.artifact_authority.feed_sha256")
        }
        let matches = qualifiedFeed.artifactIdentities().filter {
            $0.catalogKey == modelKey
                && $0.artifactID == artifactID
                && $0.hashAlgorithm == nativeMTPHashAlgorithm
                && $0.hash == hash
        }
        guard matches.count == 1, let identity = matches.first else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.artifact_authority")
        }
        guard identity.verificationStatus == "verified" else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.artifact_authority.verification_status")
        }
        let targetURLPath = try canonicalTargetURLPath(preflightTargetURL)
        return NativeMTPResolvedArtifactAuthority(
            releaseID: releaseID,
            signerKeyID: qualifiedFeed.signerKeyID,
            feedSHA256: qualifiedFeed.feedSHA256,
            modelKey: modelKey,
            artifactID: artifactID,
            hashAlgorithm: identity.hashAlgorithm,
            hash: identity.hash,
            verificationStatus: identity.verificationStatus,
            targetURLPath: targetURLPath,
            targetSHA256: identity.hash
        )
    }

    private static func canonicalTargetURLPath(_ preflightTargetURL: URL) throws -> String {
        guard preflightTargetURL.isFileURL else {
            throw NativeMTPAdmissionSidecarError.pathRejected("$.artifact_authority.target_url")
        }
        let path = preflightTargetURL.standardizedFileURL.path
        guard path.hasPrefix("/") else {
            throw NativeMTPAdmissionSidecarError.pathRejected("$.artifact_authority.target_url")
        }
        return path
    }

    fileprivate static func feedSHA256IsValid(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    static func uncheckedForTesting(
        releaseID: String,
        signerKeyID: String,
        feedSHA256: String,
        modelKey: String,
        artifactID: String,
        hashAlgorithm: String,
        hash: String,
        verificationStatus: String,
        targetURLPath: String,
        targetSHA256: String
    ) -> NativeMTPResolvedArtifactAuthority {
        NativeMTPResolvedArtifactAuthority(
            releaseID: releaseID,
            signerKeyID: signerKeyID,
            feedSHA256: feedSHA256,
            modelKey: modelKey,
            artifactID: artifactID,
            hashAlgorithm: hashAlgorithm,
            hash: hash,
            verificationStatus: verificationStatus,
            targetURLPath: targetURLPath,
            targetSHA256: targetSHA256
        )
    }
}

extension QualifiedArtifactFeed {
    func nativeMTPResolvedArtifactAuthority(
        releaseID: String,
        modelKey: String,
        artifactID: String,
        hash: String,
        preflightTargetURL: URL
    ) throws -> NativeMTPResolvedArtifactAuthority {
        try NativeMTPResolvedArtifactAuthority.resolve(
            qualifiedFeed: self,
            releaseID: releaseID,
            modelKey: modelKey,
            artifactID: artifactID,
            hash: hash,
            preflightTargetURL: preflightTargetURL
        )
    }
}

final class NativeMTPAdmissionCapturedArtifacts: Equatable, @unchecked Sendable {
    static let captureDirectoryPrefix = ".native-mtp-admission-capture-"
    static let leaseFileName = ".lease"
    private static let maxStaleCaptureReclaims = 8

    let rootURL: URL
    let targetURL: URL
    let mtpURL: URL
    let tokenizerURL: URL
    let manifestURL: URL
    private let rootStamp: NativeMTPAdmissionCapturedNodeStamp
    private let fileStamps: [NativeMTPAdmissionCapturedNodeStamp]
    private let cleanupOnDeinit: Bool
    private let leaseFD: Int32?

    init(
        rootURL: URL,
        targetURL: URL,
        mtpURL: URL,
        tokenizerURL: URL,
        manifestURL: URL,
        rootStamp: NativeMTPAdmissionCapturedNodeStamp,
        fileStamps: [NativeMTPAdmissionCapturedNodeStamp],
        leaseFD: Int32? = nil,
        cleanupOnDeinit: Bool = true
    ) {
        self.rootURL = rootURL
        self.targetURL = targetURL
        self.mtpURL = mtpURL
        self.tokenizerURL = tokenizerURL
        self.manifestURL = manifestURL
        self.rootStamp = rootStamp
        self.fileStamps = fileStamps
        self.leaseFD = leaseFD
        self.cleanupOnDeinit = cleanupOnDeinit
    }

    deinit {
        if cleanupOnDeinit {
            try? Self.removePrivateCaptureTree(rootURL)
        }
        if let leaseFD {
            close(leaseFD)
        }
    }

    static func == (lhs: NativeMTPAdmissionCapturedArtifacts, rhs: NativeMTPAdmissionCapturedArtifacts) -> Bool {
        lhs.rootURL == rhs.rootURL
            && lhs.targetURL == rhs.targetURL
            && lhs.mtpURL == rhs.mtpURL
            && lhs.tokenizerURL == rhs.tokenizerURL
            && lhs.manifestURL == rhs.manifestURL
    }

    func revalidateAfterLoad() throws {
        let current = try Self.captureTreeStamp(rootURL)
        guard current.root == rootStamp, current.files == fileStamps else {
            throw NativeMTPAdmissionSidecarError.artifactDigestMismatch("captured_artifacts")
        }
    }

    static func reclaimStaleCaptureSiblings(of snapshotRoot: URL, fileManager: FileManager = .default) {
        let parent = snapshotRoot.deletingLastPathComponent()
        guard let siblings = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return
        }
        var reclaimed = 0
        for sibling in siblings where sibling.lastPathComponent.hasPrefix(captureDirectoryPrefix) {
            guard reclaimed < maxStaleCaptureReclaims else { return }
            guard let leaseFD = try? openLockedLease(
                for: sibling,
                create: false,
                nonblocking: true
            ) else {
                continue
            }
            defer { close(leaseFD) }
            if (try? removePrivateCaptureTree(sibling, fileManager: fileManager)) != nil {
                reclaimed += 1
            }
        }
    }

    static func openLockedLease(for root: URL, create: Bool, nonblocking: Bool) throws -> Int32 {
        let lease = root.appendingPathComponent(leaseFileName, isDirectory: false)
        let flags = create ? (O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC) : (O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let fd = open(lease.path, flags, 0o600)
        guard fd >= 0 else {
            throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            close(fd)
            throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
        }
        let operation = LOCK_EX | (nonblocking ? LOCK_NB : 0)
        guard flock(fd, operation) == 0 else {
            close(fd)
            throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
        }
        return fd
    }

    static func removePrivateCaptureTree(_ root: URL, fileManager: FileManager = .default) throws {
        try thawPrivateCaptureTree(root, fileManager: fileManager)
        try fileManager.removeItem(at: root)
        var info = stat()
        guard lstat(root.path, &info) != 0, errno == ENOENT else {
            throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
        }
    }

    private static func thawPrivateCaptureTree(_ root: URL, fileManager: FileManager) throws {
        guard root.lastPathComponent.hasPrefix(captureDirectoryPrefix) else {
            throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
        }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
        }
        try validatePrivateCaptureNode(rootInfo, relativePath: "captured_artifacts", allowDirectory: true)
        guard chmod(root.path, 0o700) == 0 else {
            throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
        }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else {
            return
        }
        let base = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else {
                throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
            }
            let relative = String(path.dropFirst(base.count + 1))
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw NativeMTPAdmissionSidecarError.pathRejected(relative)
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try validatePrivateCaptureNode(info, relativePath: relative, allowDirectory: true)
                guard chmod(path, 0o700) == 0 else {
                    throw NativeMTPAdmissionSidecarError.pathRejected(relative)
                }
            case S_IFREG:
                try validatePrivateCaptureNode(info, relativePath: relative, allowDirectory: false)
                guard chmod(path, 0o600) == 0 else {
                    throw NativeMTPAdmissionSidecarError.pathRejected(relative)
                }
            default:
                throw NativeMTPAdmissionSidecarError.pathRejected(relative)
            }
        }
    }

    private static func validatePrivateCaptureNode(_ info: stat, relativePath: String, allowDirectory: Bool) throws {
        let type = info.st_mode & S_IFMT
        guard info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else {
            throw NativeMTPAdmissionSidecarError.pathRejected(relativePath)
        }
        if type == S_IFREG {
            guard info.st_nlink == 1 else {
                throw NativeMTPAdmissionSidecarError.pathRejected(relativePath)
            }
        } else if !(allowDirectory && type == S_IFDIR) {
            throw NativeMTPAdmissionSidecarError.pathRejected(relativePath)
        }
    }

    static func captureTreeStamp(_ root: URL) throws -> (root: NativeMTPAdmissionCapturedNodeStamp, files: [NativeMTPAdmissionCapturedNodeStamp]) {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              (rootInfo.st_mode & 0o222) == 0 else {
            throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
        }
        let rootStamp = NativeMTPAdmissionCapturedNodeStamp(relativePath: ".", info: rootInfo)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound("captured_artifacts")
        }
        let base = root.standardizedFileURL.path
        var files: [NativeMTPAdmissionCapturedNodeStamp] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else {
                throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
            }
            let relative = String(path.dropFirst(base.count + 1))
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw NativeMTPAdmissionSidecarError.artifactNotFound(relative)
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard (info.st_mode & 0o222) == 0 else {
                    throw NativeMTPAdmissionSidecarError.pathRejected(relative)
                }
            case S_IFREG:
                guard info.st_nlink == 1, (info.st_mode & 0o222) == 0 else {
                    throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relative)
                }
                files.append(NativeMTPAdmissionCapturedNodeStamp(relativePath: relative, info: info))
            default:
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relative)
            }
        }
        return (rootStamp, files.sorted { $0.relativePath < $1.relativePath })
    }
}

struct NativeMTPAdmissionCapturedNodeStamp: Equatable, Sendable {
    let relativePath: String
    let size: Int64
    let device: Int64
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let mode: UInt16

    init(relativePath: String, info: stat) {
        self.relativePath = relativePath
        self.size = Int64(info.st_size)
        self.device = Int64(info.st_dev)
        self.inode = UInt64(info.st_ino)
        self.modifiedSeconds = info.st_mtimespec.tv_sec
        self.modifiedNanoseconds = info.st_mtimespec.tv_nsec
        self.changedSeconds = info.st_ctimespec.tv_sec
        self.changedNanoseconds = info.st_ctimespec.tv_nsec
        self.mode = UInt16(info.st_mode & 0o777)
    }
}

enum NativeMTPAdmissionSidecarError: Error, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case unknownField(String)
    case missingField(String)
    case wrongType(String)
    case invalidValue(String)
    case unsupported(String)
    case revocationUnavailable
    case tupleRevoked(String)
    case pathRejected(String)
    case artifactNotFound(String)
    case artifactNotRegularFile(String)
    case artifactNotManifested(String)
    case artifactTooLarge(String)
    case artifactDigestMismatch(String)
    case liveTupleMismatch(String)
    case signatureInvalid(String)

    var description: String {
        switch self {
        case .invalidJSON(let reason): return "invalid JSON: \(reason)"
        case .unknownField(let field): return "unknown field: \(field)"
        case .missingField(let field): return "missing field: \(field)"
        case .wrongType(let field): return "wrong type: \(field)"
        case .invalidValue(let field): return "invalid value: \(field)"
        case .unsupported(let field): return "unsupported: \(field)"
        case .revocationUnavailable: return "revocation state unavailable"
        case .tupleRevoked(let tuple): return "tuple revoked: \(tuple)"
        case .pathRejected(let path): return "artifact path rejected: \(path)"
        case .artifactNotFound(let path): return "artifact not found: \(path)"
        case .artifactNotRegularFile(let path): return "artifact is not a regular file: \(path)"
        case .artifactNotManifested(let path): return "artifact is not manifested: \(path)"
        case .artifactTooLarge(let path): return "artifact exceeds admission ceiling: \(path)"
        case .artifactDigestMismatch(let name): return "artifact digest mismatch: \(name)"
        case .liveTupleMismatch(let field): return "live tuple mismatch: \(field)"
        case .signatureInvalid(let reason): return "signature invalid: \(reason)"
        }
    }
}

enum NativeMTPAdmissionSidecar {
    static let schemaVersion = "macprovider.native-mtp-admission.v1"
    static let greedyRequestFeatureProfile = "native_mtp_greedy_text_v1"
    /// Adds sampled rows (temperature/top_p) verified by target-sample exact
    /// match to the greedy profile (SPEC-023-R024, SPEC-048-R004).
    static let sampledRequestFeatureProfile = "native_mtp_sampled_text_v1"
    static let requestFeatureProfiles: Set<String> = [
        greedyRequestFeatureProfile,
        sampledRequestFeatureProfile,
    ]
    static let maxSidecarBytes = 1 * 1024 * 1024
    static let maxSignatureBytes = 16 * 1024
    static let maxSelfTestChallengeBankBytes = 256 * 1024
    static let hashChunkBytes = 1 * 1024 * 1024
    static let maxSingleArtifactBytes: Int64 = 512 * 1024 * 1024 * 1024
    static let maxSnapshotTreeFiles = 100_000
    static let maxSnapshotTreeBytes: Int64 = 2 * 1024 * 1024 * 1024 * 1024
    private static let admissionSidecarFileName = "native-mtp-admission.json"
    private static let admissionSignatureFileName = "native-mtp-admission.json.sig"
    private static let tupleIdentitySchemaVersion = "macprovider.native-mtp-admission-tuple.v1"
    private static let tupleIdentityDomain = "macprovider.native-mtp-admission-tuple.v1\n"
    private static let defaultChallengeBankPath = "native-mtp-selftest-bank.json"
    private static let defaultChallengeBankSignaturePath = "native-mtp-selftest-bank.json.sig"
    private static let defaultArtifactProjectionManifestPath = "native-mtp-artifact-manifest.json"
    nonisolated(unsafe) static var testingDescriptorCaptureMutationHook: ((String) throws -> Void)?
    nonisolated(unsafe) static var testingExpectedStagingDeviceOverride: dev_t?

    struct RuntimeContext: Equatable, Sendable {
        let modelID: String
        let modelRevision: String
        let upstreamMLXSwiftLMRevision: String
        let hardwareChip: String
        let ramGB: Int
        let osVersion: String
        let slotCount: Int
        let revokedTupleSHA256: Set<String>?

        init(
            modelID: String,
            modelRevision: String,
            upstreamMLXSwiftLMRevision: String,
            hardwareChip: String,
            ramGB: Int,
            osVersion: String,
            slotCount: Int,
            revokedTupleSHA256: Set<String>?
        ) {
            self.modelID = modelID
            self.modelRevision = modelRevision
            self.upstreamMLXSwiftLMRevision = upstreamMLXSwiftLMRevision
            self.hardwareChip = hardwareChip
            self.ramGB = ramGB
            self.osVersion = osVersion
            self.slotCount = slotCount
            self.revokedTupleSHA256 = revokedTupleSHA256
        }
    }

    struct Quantization: Equatable, Sendable {
        let target: String
        let mtp: String
        let blockSizeElements: Int?
        let representationManifestSHA256: String?
        let unquantizedExceptions: [String]
        let perLayerExceptions: [String]

        init(
            target: String,
            mtp: String,
            blockSizeElements: Int? = nil,
            representationManifestSHA256: String? = nil,
            unquantizedExceptions: [String] = [],
            perLayerExceptions: [String] = []
        ) {
            self.target = target
            self.mtp = mtp
            self.blockSizeElements = blockSizeElements
            self.representationManifestSHA256 = representationManifestSHA256
            self.unquantizedExceptions = unquantizedExceptions
            self.perLayerExceptions = perLayerExceptions
        }
    }

    struct TrustedKeyring: Equatable, Sendable {
        let publicKeysByKeyID: [String: String]
        let requiredKeyID: String

        init(publicKeysByKeyID: [String: String], requiredKeyID: String) {
            self.publicKeysByKeyID = publicKeysByKeyID
            self.requiredKeyID = requiredKeyID
        }
    }

    private struct SignatureSidecar: Equatable {
        let keyID: String
        let signature: Data
    }

    private struct Artifact: Equatable {
        let path: String
        let sha256: String
    }

    private struct Parsed: Equatable {
        let tupleSHA256: String
        let sidecarSHA256: String
        let decodePath: String
        let admissionEnabled: Bool
        let modelID: String
        let modelRevision: String
        let familyAdapter: String
        let artifacts: [String: Artifact]
        let mtpManifestSHA256: String
        let sourceLayout: String
        let predictionLayerCount: Int
        let maxProposalDepth: Int
        let completeWindowBytesByDepth: [Int]
        let throughputDeltaPPM: Int
        let adaptationEnabled: Bool
        let adaptationMaxDepth: Int
        let quantization: Quantization
        let cacheClass: String
        let stateClass: String
        let providerRevision: String
        let upstreamMLXSwiftLMRevision: String
        let hardwareChip: String
        let ramGB: Int
        let osVersion: String
        let qualifiedSlots: Int
        let maxSlots: Int
        let maxNativeActiveRows: Int
        let requestProfile: RequestProfile
        let spec023: Spec023
        let challengeBankSignerKeyID: String
        let revocationSignerKeyID: String
        let selfTest: NativeMTPSelfTestChallengeBank
        let admissionAllowed: Bool

        func withSidecarSHA256(_ sidecarSHA256: String) -> Parsed {
            Parsed(
                tupleSHA256: tupleSHA256,
                sidecarSHA256: sidecarSHA256,
                decodePath: decodePath,
                admissionEnabled: admissionEnabled,
                modelID: modelID,
                modelRevision: modelRevision,
                familyAdapter: familyAdapter,
                artifacts: artifacts,
                mtpManifestSHA256: mtpManifestSHA256,
                sourceLayout: sourceLayout,
                predictionLayerCount: predictionLayerCount,
                maxProposalDepth: maxProposalDepth,
                completeWindowBytesByDepth: completeWindowBytesByDepth,
                throughputDeltaPPM: throughputDeltaPPM,
                adaptationEnabled: adaptationEnabled,
                adaptationMaxDepth: adaptationMaxDepth,
                quantization: quantization,
                cacheClass: cacheClass,
                stateClass: stateClass,
                providerRevision: providerRevision,
                upstreamMLXSwiftLMRevision: upstreamMLXSwiftLMRevision,
                hardwareChip: hardwareChip,
                ramGB: ramGB,
                osVersion: osVersion,
                qualifiedSlots: qualifiedSlots,
                maxSlots: maxSlots,
                maxNativeActiveRows: maxNativeActiveRows,
                requestProfile: requestProfile,
                spec023: spec023,
                challengeBankSignerKeyID: challengeBankSignerKeyID,
                revocationSignerKeyID: revocationSignerKeyID,
                selfTest: selfTest,
                admissionAllowed: admissionAllowed
            )
        }
    }

    private struct NativeMTPAdmissionReleaseEntry: Equatable {
        let modelKey: String
        let artifactID: String
        let hashAlgorithm: String
        let artifactHash: String
        let artifactManifestSHA256: String
        let tokenizerSHA256: String
        let decodePath: String
        let mtpManifestSHA256: String
        let familyAdapter: String
        let mtpStateClass: String
        let mtpHeadCount: Int
        let proposalDepth: Int
        let completeWindowBytesByDepth: [Int]
        let runtimeRevision: String
        let providerRevision: String
        let sourceCommit: String
        let reproducibleBuildSHA256: String
        let liveExecutableCDHash: String
        let cacheStateClasses: [String]
        let hardwareClass: String
        let ramBytes: Int
        let qualifiedSlots: Int
        let maxNativeActiveRows: Int
        let requestFeatureProfile: String
        let maxPromptTokens: Int
        let decreaseThresholdPPM: Int
        let increaseThresholdPPM: Int
        let maxVerificationPositionsPerCommittedMilli: Int
        let throughputDeltaPPM: Int
        let benchmarkPolicySHA256: String
        let challengeBankSHA256: String
        let evidenceArtifactSHA256: [String]
        let quantization: Quantization

        var sortKey: [String] {
            [
                modelKey, artifactID, hardwareClass, String(ramBytes),
                String(qualifiedSlots), String(proposalDepth), quantization.target,
            ]
        }

        var sourceLayout: String { "separate_artifact" }

        func matches(context: RuntimeContext) -> Bool {
            modelKey == context.modelID
                && artifactHash == context.modelRevision
                && runtimeRevision == context.upstreamMLXSwiftLMRevision
                && hardwareClass == NativeMTPAdmissionSidecar.canonicalHardwareClass(context.hardwareChip)
                && ramBytes == context.ramGB * 1_073_741_824
                && qualifiedSlots == context.slotCount
        }
    }

    private struct RequestProfile: Equatable {
        let textOnly: Bool
        let streaming: Bool
        let tools: Bool
        let structuredOutputs: Bool
        let logprobs: Bool
        let penalties: Bool
        let conversationCache: Bool
        let diskCache: Bool
        let maxPromptTokens: Int
        let maxCompletionTokens: Int
        var sampling: Bool = false
    }

    private struct Spec023: Equatable {
        let releaseID: String
        let sourceCommit: String
        let reproducibleBuildSHA256: String
        let liveExecutableCDHash: String
        let benchmarkPolicySHA256: String
        let nativeMTPAdmissionTupleSHA256: String
        let evidenceArtifactSHA256: [String]
    }

    /// `snapshotRoot` holds the admission members (sidecar, projection
    /// manifest, self-test bank). The projected artifacts resolve under
    /// `artifactRoot`, which defaults to `snapshotRoot` (a set placed next to
    /// the model bundle). A set fetched from the static-feed origin passes the
    /// durable model store root: its projection then names the content-addressed
    /// store paths of the target and the MTP drafter (SPEC-023 §12.5 Stage A).
    static func load(
        sidecarURL: URL,
        signatureURL: URL,
        snapshotRoot: URL,
        artifactRoot: URL? = nil,
        context: RuntimeContext,
        trustedKeyring: TrustedKeyring,
        resolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority? = nil,
        captureArtifacts: Bool = false,
        fileManager: FileManager = .default
    ) throws -> NativeMTPAdmissionCapability {
        let bytes = try readBoundedRegularFile(
            sidecarURL,
            maxBytes: maxSidecarBytes,
            tooLargeName: admissionSidecarFileName
        )
        let signatureBytes = try readBoundedRegularFile(
            signatureURL,
            maxBytes: maxSignatureBytes,
            tooLargeName: admissionSignatureFileName
        )
        return try load(
            sidecarData: bytes,
            signatureData: signatureBytes,
            snapshotRoot: snapshotRoot,
            artifactRoot: artifactRoot,
            context: context,
            trustedKeyring: trustedKeyring,
            resolvedArtifactAuthority: resolvedArtifactAuthority,
            captureArtifacts: captureArtifacts,
            fileManager: fileManager
        )
    }

    static func load(
        sidecarData: Data,
        signatureData: Data,
        snapshotRoot: URL,
        artifactRoot: URL? = nil,
        context: RuntimeContext,
        trustedKeyring: TrustedKeyring,
        resolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority? = nil,
        captureArtifacts: Bool = false,
        fileManager: FileManager = .default
    ) throws -> NativeMTPAdmissionCapability {
        guard sidecarData.count <= maxSidecarBytes else {
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(admissionSidecarFileName)
        }
        guard signatureData.count <= maxSignatureBytes else {
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(admissionSignatureFileName)
        }
        let signatureKeyID = try verifyDetachedSignature(payload: sidecarData, signatureData: signatureData, trustedKeyring: trustedKeyring)
        guard let text = String(data: sidecarData, encoding: .utf8) else {
            throw NativeMTPAdmissionSidecarError.invalidJSON("sidecar must be UTF-8")
        }
        let value: NativeMTPSidecarJSON
        do {
            value = try NativeMTPSidecarJSONParser.parse(text)
        } catch {
            throw NativeMTPAdmissionSidecarError.invalidJSON(String(describing: error))
        }
        guard case .object(let root) = value else {
            throw NativeMTPAdmissionSidecarError.wrongType("$")
        }
        let sidecarSHA256 = sha256Hex(sidecarData)
        guard root["entries"] != nil else {
            throw NativeMTPAdmissionSidecarError.missingField("$.entries")
        }
        let parsed = try parseReleaseEnvelope(
            root,
            sidecarSHA256: sidecarSHA256,
            signatureKeyID: signatureKeyID,
            snapshotRoot: snapshotRoot,
            artifactRoot: artifactRoot ?? snapshotRoot,
            context: context,
            trustedKeyring: trustedKeyring,
            resolvedArtifactAuthority: resolvedArtifactAuthority
        )
        return try validateParsedCapability(
            parsed,
            snapshotRoot: snapshotRoot,
            artifactRoot: artifactRoot,
            context: context,
            trustedKeyring: trustedKeyring,
            captureArtifacts: captureArtifacts,
            fileManager: fileManager
        )
    }

#if DEBUG
    static func loadLegacyObjectForTesting(
        sidecarURL: URL,
        signatureURL: URL,
        snapshotRoot: URL,
        context: RuntimeContext,
        trustedKeyring: TrustedKeyring,
        captureArtifacts: Bool = false,
        fileManager: FileManager = .default
    ) throws -> NativeMTPAdmissionCapability {
        try loadLegacyObjectForTesting(
            sidecarData: readBoundedRegularFile(
                sidecarURL,
                maxBytes: maxSidecarBytes,
                tooLargeName: admissionSidecarFileName
            ),
            signatureData: readBoundedRegularFile(
                signatureURL,
                maxBytes: maxSignatureBytes,
                tooLargeName: admissionSignatureFileName
            ),
            snapshotRoot: snapshotRoot,
            context: context,
            trustedKeyring: trustedKeyring,
            captureArtifacts: captureArtifacts,
            fileManager: fileManager
        )
    }

    static func loadLegacyObjectForTesting(
        sidecarData: Data,
        signatureData: Data,
        snapshotRoot: URL,
        context: RuntimeContext,
        trustedKeyring: TrustedKeyring,
        captureArtifacts: Bool = false,
        fileManager: FileManager = .default
    ) throws -> NativeMTPAdmissionCapability {
        guard sidecarData.count <= maxSidecarBytes else {
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(admissionSidecarFileName)
        }
        guard signatureData.count <= maxSignatureBytes else {
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(admissionSignatureFileName)
        }
        _ = try verifyDetachedSignature(
            payload: sidecarData,
            signatureData: signatureData,
            trustedKeyring: trustedKeyring
        )
        guard let text = String(data: sidecarData, encoding: .utf8) else {
            throw NativeMTPAdmissionSidecarError.invalidJSON("sidecar must be UTF-8")
        }
        let value: NativeMTPSidecarJSON
        do {
            value = try NativeMTPSidecarJSONParser.parse(text)
        } catch {
            throw NativeMTPAdmissionSidecarError.invalidJSON(String(describing: error))
        }
        guard case .object(let root) = value else {
            throw NativeMTPAdmissionSidecarError.wrongType("$")
        }
        let legacyParsed = try parseRoot(root)
        guard legacyParsed.tupleSHA256 == legacyParsed.spec023.nativeMTPAdmissionTupleSHA256 else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.spec023.native_mtp_admission_tuple_sha256")
        }
        guard legacyParsed.tupleSHA256 == admissionTupleSHA256(legacyParsed) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.tuple_sha256")
        }
        let parsed = legacyParsed.withSidecarSHA256(sha256Hex(sidecarData))
        return try validateParsedCapability(
            parsed,
            snapshotRoot: snapshotRoot,
            context: context,
            trustedKeyring: trustedKeyring,
            captureArtifacts: captureArtifacts,
            fileManager: fileManager
        )
    }
#endif

    private static func validateParsedCapability(
        _ parsed: Parsed,
        snapshotRoot: URL,
        artifactRoot: URL? = nil,
        context: RuntimeContext,
        trustedKeyring: TrustedKeyring,
        captureArtifacts: Bool,
        fileManager: FileManager
    ) throws -> NativeMTPAdmissionCapability {
        try validateSelfTestChallengeBank(parsed, snapshotRoot: snapshotRoot, trustedKeyring: trustedKeyring)
        try validateStaticSupport(parsed)
        try validateLiveTuple(parsed, context: context)
        try validateRevocation(parsed, context: context)
        // A store-rooted projection shares its root with every other model in
        // the store, so only the bundle layout is checked for unmanifested
        // files; each projected directory is still digested in full.
        let capturedArtifacts = try validateArtifacts(
            parsed.artifacts,
            snapshotRoot: artifactRoot ?? snapshotRoot,
            rejectUnmanifestedFiles: artifactRoot == nil,
            captureArtifacts: captureArtifacts,
            allowedAuxiliaryPaths: [
                parsed.selfTest.challengeBankPath,
                parsed.selfTest.signaturePath,
                defaultArtifactProjectionManifestPath,
            ],
            fileManager: fileManager
        )
        return NativeMTPAdmissionCapability(
            tupleSHA256: parsed.tupleSHA256,
            sidecarSHA256: parsed.sidecarSHA256,
            modelID: parsed.modelID,
            modelRevision: parsed.modelRevision,
            targetArtifactSHA256: parsed.artifacts["target"]!.sha256,
            mtpArtifactSHA256: parsed.artifacts["mtp"]!.sha256,
            tokenizerSHA256: parsed.artifacts["tokenizer"]!.sha256,
            mtpManifestSHA256: parsed.mtpManifestSHA256,
            familyAdapter: parsed.familyAdapter,
            sourceLayout: parsed.sourceLayout,
            predictionLayerCount: parsed.predictionLayerCount,
            maxProposalDepth: parsed.maxProposalDepth,
            completeWindowBytesByDepth: parsed.completeWindowBytesByDepth,
            throughputDeltaPPM: parsed.throughputDeltaPPM,
            maxPromptTokens: parsed.requestProfile.maxPromptTokens,
            maxCompletionTokens: parsed.requestProfile.maxCompletionTokens,
            cacheClass: parsed.cacheClass,
            stateClass: parsed.stateClass,
            quantization: parsed.quantization,
            providerRevision: parsed.providerRevision,
            upstreamMLXSwiftLMRevision: parsed.upstreamMLXSwiftLMRevision,
            qualifiedSlots: parsed.qualifiedSlots,
            maxNativeActiveRows: parsed.maxNativeActiveRows,
            spec023ReleaseID: parsed.spec023.releaseID,
            spec023SourceCommit: parsed.spec023.sourceCommit,
            spec023BuildDigestSHA256: parsed.spec023.reproducibleBuildSHA256,
            spec023LiveExecutableCDHash: parsed.spec023.liveExecutableCDHash,
            evidenceArtifactSHA256: parsed.spec023.evidenceArtifactSHA256,
            challengeBankSignerKeyID: parsed.challengeBankSignerKeyID,
            revocationSignerKeyID: parsed.revocationSignerKeyID,
            selfTestChallengeBank: parsed.selfTest,
            capturedArtifacts: capturedArtifacts,
            supportsSampling: parsed.requestProfile.sampling
        )
    }

    static func pinnedRevocationSignerKeyID(
        sidecarData: Data,
        signatureData: Data,
        trustedKeyring: TrustedKeyring
    ) throws -> String {
        guard sidecarData.count <= maxSidecarBytes else {
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(admissionSidecarFileName)
        }
        guard signatureData.count <= maxSignatureBytes else {
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(admissionSignatureFileName)
        }
        let signatureKeyID = try verifyDetachedSignature(
            payload: sidecarData,
            signatureData: signatureData,
            trustedKeyring: trustedKeyring
        )
        guard let text = String(data: sidecarData, encoding: .utf8) else {
            throw NativeMTPAdmissionSidecarError.invalidJSON("sidecar must be UTF-8")
        }
        let value: NativeMTPSidecarJSON
        do {
            value = try NativeMTPSidecarJSONParser.parse(text)
        } catch {
            throw NativeMTPAdmissionSidecarError.invalidJSON(String(describing: error))
        }
        guard case .object(let root) = value else {
            throw NativeMTPAdmissionSidecarError.wrongType("$")
        }
        try requireString(root, "schema_version", path: "$", equals: schemaVersion)
        let signerKeyID = try requireASCIIString(root, "signer_key_id", path: "$", range: 1...128)
        guard signerKeyID == signatureKeyID, signerKeyID == trustedKeyring.requiredKeyID else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("unexpected_key_id")
        }
        let revocationSignerKeyID = try requireASCIIString(root, "revocation_signer_key_id", path: "$", range: 1...128)
        guard trustedKeyring.publicKeysByKeyID[revocationSignerKeyID] != nil else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("missing_revocation_key")
        }
        return revocationSignerKeyID
    }

    private static func parseRoot(_ object: [String: NativeMTPSidecarJSON]) throws -> Parsed {
        try rejectUnknown(object, allowed: [
            "schema_version", "tuple_sha256", "decode_path", "admission_enabled",
            "model", "artifacts", "mtp", "quantization", "cache_state",
            "revisions", "hardware", "request_profile", "spec023", "selftest", "flags",
        ], path: "$")
        try requireString(object, "schema_version", path: "$", equals: schemaVersion)
        let model = try requireObject(object, "model", path: "$")
        try rejectUnknown(model, allowed: ["id", "revision", "family_adapter"], path: "$.model")

        let artifacts = try parseArtifacts(try requireObject(object, "artifacts", path: "$"))
        let mtp = try requireObject(object, "mtp", path: "$")
        try rejectUnknown(mtp, allowed: [
            "manifest_sha256", "source_layout", "prediction_layer_count",
            "max_proposal_depth", "complete_window_bytes_by_depth",
            "throughput_delta_ppm", "adaptation_enabled", "adaptation_max_depth",
        ], path: "$.mtp")
        let sourceLayout = try requireString(mtp, "source_layout", path: "$.mtp", allowed: ["checkpoint_mtp", "config_next_n", "separate_artifact"])
        let predictionLayerCount = try requireInt(mtp, "prediction_layer_count", path: "$.mtp", range: 1...64)
        let maxProposalDepth = try requireInt(
            mtp, "max_proposal_depth", path: "$.mtp", range: 1...nativeMTPMaximumProposalDepth)
        let completeWindowBytesByDepth = try requireCompleteWindowBytesByDepth(
            mtp,
            key: "complete_window_bytes_by_depth",
            path: "$.mtp",
            maxProposalDepth: maxProposalDepth
        )
        let throughputDeltaPPM = try requireInt(
            mtp,
            "throughput_delta_ppm",
            path: "$.mtp",
            range: -1_000_000...1_000_000
        )

        let quantization = try requireObject(object, "quantization", path: "$")
        let targetQuantization = try requireString(
            quantization,
            "target",
            path: "$.quantization",
            allowed: ["bf16", "fp16", "mlx_affine_4bit", "mlx_mxfp8"]
        )
        let mtpQuantization = try requireString(
            quantization,
            "mtp",
            path: "$.quantization",
            allowed: ["bf16", "fp16", "mlx_affine_4bit", "mlx_mxfp8"]
        )
        let normalizedAffine = targetQuantization == "mlx_affine_4bit" || mtpQuantization == "mlx_affine_4bit"
        let quantizationFields: Set<String> = normalizedAffine
            ? [
                "target", "mtp", "representation_manifest_sha256",
                "block_size_elements", "unquantized_exceptions", "per_layer_exceptions",
            ]
            : ["target", "mtp"]
        try rejectUnknownFields(quantization, allowed: quantizationFields, path: "$.quantization")
        let representationManifestSHA256: String?
        let blockSizeElements: Int?
        let unquantizedExceptions: [String]
        let perLayerExceptions: [String]
        if normalizedAffine {
            guard targetQuantization == "mlx_affine_4bit", mtpQuantization == "mlx_affine_4bit" else {
                throw NativeMTPAdmissionSidecarError.invalidValue("$.quantization")
            }
            representationManifestSHA256 = try requireSHA256(
                quantization,
                "representation_manifest_sha256",
                path: "$.quantization"
            )
            let affineBlockSize = try requireInt(
                quantization,
                "block_size_elements",
                path: "$.quantization",
                range: 32...128
            )
            guard [32, 64, 128].contains(affineBlockSize) else {
                throw NativeMTPAdmissionSidecarError.invalidValue("$.quantization.block_size_elements")
            }
            blockSizeElements = affineBlockSize
            unquantizedExceptions = try requirePatternArray(
                quantization,
                "unquantized_exceptions",
                path: "$.quantization"
            )
            perLayerExceptions = try requirePatternArray(
                quantization,
                "per_layer_exceptions",
                path: "$.quantization"
            )
            try validateQuantizationExceptionArray(
                unquantizedExceptions,
                key: "unquantized_exceptions",
                path: "$.quantization"
            )
            try validateQuantizationExceptionArray(
                perLayerExceptions,
                key: "per_layer_exceptions",
                path: "$.quantization"
            )
        } else {
            guard quantization["representation_manifest_sha256"] == nil,
                  quantization["unquantized_exceptions"] == nil,
                  quantization["per_layer_exceptions"] == nil else {
                throw NativeMTPAdmissionSidecarError.invalidValue("$.quantization")
            }
            representationManifestSHA256 = nil
            blockSizeElements = nil
            unquantizedExceptions = []
            perLayerExceptions = []
        }
        let cacheState = try requireObject(object, "cache_state", path: "$")
        try rejectUnknown(cacheState, allowed: ["cache_class", "state_class"], path: "$.cache_state")
        let revisions = try requireObject(object, "revisions", path: "$")
        try rejectUnknown(revisions, allowed: ["provider", "upstream_mlx_swift_lm"], path: "$.revisions")
        let hardware = try requireObject(object, "hardware", path: "$")
        try rejectUnknown(hardware, allowed: ["chip", "ram_gb", "os_version", "qualified_slots", "max_slots"], path: "$.hardware")
        let requestProfile = try parseRequestProfile(try requireObject(object, "request_profile", path: "$"))
        let spec023 = try parseSpec023(try requireObject(object, "spec023", path: "$"))
        let selfTest = try parseSelfTest(try requireObject(object, "selftest", path: "$"))
        let flags = try requireObject(object, "flags", path: "$")
        try rejectUnknown(flags, allowed: ["admission_allowed"], path: "$.flags")

        return Parsed(
            tupleSHA256: try requireSHA256(object, "tuple_sha256", path: "$"),
            sidecarSHA256: String(repeating: "0", count: 64),
            decodePath: try requireString(object, "decode_path", path: "$", allowed: ["native_mtp"]),
            admissionEnabled: try requireBool(object, "admission_enabled", path: "$"),
            modelID: try requireNonEmptyString(model, "id", path: "$.model"),
            modelRevision: try requireNonEmptyString(model, "revision", path: "$.model"),
            familyAdapter: try requireNonEmptyString(model, "family_adapter", path: "$.model"),
            artifacts: artifacts,
            mtpManifestSHA256: try requireSHA256(mtp, "manifest_sha256", path: "$.mtp"),
            sourceLayout: sourceLayout,
            predictionLayerCount: predictionLayerCount,
            maxProposalDepth: maxProposalDepth,
            completeWindowBytesByDepth: completeWindowBytesByDepth,
            throughputDeltaPPM: throughputDeltaPPM,
            adaptationEnabled: try requireBool(mtp, "adaptation_enabled", path: "$.mtp"),
            adaptationMaxDepth: try requireInt(
                mtp, "adaptation_max_depth", path: "$.mtp", range: 1...nativeMTPMaximumProposalDepth),
            quantization: Quantization(
                target: targetQuantization,
                mtp: mtpQuantization,
                blockSizeElements: blockSizeElements,
                representationManifestSHA256: representationManifestSHA256,
                unquantizedExceptions: unquantizedExceptions,
                perLayerExceptions: perLayerExceptions
            ),
            cacheClass: try requireString(cacheState, "cache_class", path: "$.cache_state", allowed: ["paged_kv"]),
            stateClass: try requireString(cacheState, "state_class", path: "$.cache_state", allowed: ["stageable_rewindable", "hybrid_stageable_rewindable"]),
            providerRevision: try requireCommitSHA(revisions, "provider", path: "$.revisions"),
            upstreamMLXSwiftLMRevision: try requireCommitSHA(revisions, "upstream_mlx_swift_lm", path: "$.revisions"),
            hardwareChip: try requireNonEmptyString(hardware, "chip", path: "$.hardware"),
            ramGB: try requireInt(hardware, "ram_gb", path: "$.hardware", range: 1...2048),
            osVersion: try requireNonEmptyString(hardware, "os_version", path: "$.hardware"),
            qualifiedSlots: try requireInt(hardware, "qualified_slots", path: "$.hardware", range: 1...1024),
            maxSlots: try requireInt(hardware, "max_slots", path: "$.hardware", range: 1...1024),
            // The debug-only legacy object predates the R007 load gate; it
            // never reaches a release consumer, so it gates at the slot count.
            maxNativeActiveRows: try requireInt(hardware, "qualified_slots", path: "$.hardware", range: 1...1024),
            requestProfile: requestProfile,
            spec023: spec023,
            challengeBankSignerKeyID: selfTest.signerKeyID,
            revocationSignerKeyID: "",
            selfTest: selfTest,
            admissionAllowed: try requireBool(flags, "admission_allowed", path: "$.flags")
        )
    }

    private static func parseReleaseEnvelope(
        _ object: [String: NativeMTPSidecarJSON],
        sidecarSHA256: String,
        signatureKeyID: String,
        snapshotRoot: URL,
        artifactRoot: URL,
        context: RuntimeContext,
        trustedKeyring: TrustedKeyring,
        resolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority?
    ) throws -> Parsed {
        try rejectUnknown(object, allowed: [
            "schema_version", "release_id", "issued_at", "expires_at",
            "signer_key_id", "challenge_bank_signer_key_id",
            "revocation_signer_key_id", "entries",
        ], path: "$")
        try requireString(object, "schema_version", path: "$", equals: schemaVersion)
        let releaseID = try requireASCIIString(object, "release_id", path: "$", range: 1...128)
        let issuedAt = try requireRFC3339UTCSeconds(object, "issued_at", path: "$")
        let expiresAt = try requireRFC3339UTCSeconds(object, "expires_at", path: "$")
        let now = Date()
        guard issuedAt <= now else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.issued_at")
        }
        guard issuedAt < expiresAt, expiresAt.timeIntervalSince(issuedAt) <= 90 * 24 * 60 * 60 else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.expires_at")
        }
        guard expiresAt > now else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.expires_at")
        }
        let signerKeyID = try requireASCIIString(object, "signer_key_id", path: "$", range: 1...128)
        let challengeBankSignerKeyID = try requireASCIIString(object, "challenge_bank_signer_key_id", path: "$", range: 1...128)
        let revocationSignerKeyID = try requireASCIIString(object, "revocation_signer_key_id", path: "$", range: 1...128)
        guard signerKeyID == signatureKeyID, signerKeyID == trustedKeyring.requiredKeyID else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("unexpected_key_id")
        }
        guard trustedKeyring.publicKeysByKeyID[challengeBankSignerKeyID] != nil else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("missing_challenge_bank_key")
        }
        guard trustedKeyring.publicKeysByKeyID[revocationSignerKeyID] != nil else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("missing_revocation_key")
        }
        guard case .array(let rawEntries) = object["entries"] else {
            throw NativeMTPAdmissionSidecarError.wrongType("$.entries")
        }
        guard (1...256).contains(rawEntries.count) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.entries")
        }

        var lastSortKey: [String]?
        var selected: (entry: NativeMTPAdmissionReleaseEntry, raw: NativeMTPSidecarJSON)?
        for (index, rawEntry) in rawEntries.enumerated() {
            guard case .object(let entryObject) = rawEntry else {
                throw NativeMTPAdmissionSidecarError.wrongType("$.entries[\(index)]")
            }
            let entry = try parseReleaseEntry(entryObject, path: "$.entries[\(index)]")
            let sortKey = entry.sortKey
            if let lastSortKey, !(lastSortKey.lexicographicallyPrecedes(sortKey)) {
                throw NativeMTPAdmissionSidecarError.invalidValue("$.entries")
            }
            lastSortKey = sortKey
            if entry.matches(context: context) {
                guard selected == nil else {
                    throw NativeMTPAdmissionSidecarError.invalidValue("$.entries")
                }
                selected = (entry, rawEntry)
            }
        }
        guard let selected else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.entries")
        }
        guard let resolvedArtifactAuthority else {
            throw NativeMTPAdmissionSidecarError.missingField("$.artifact_authority")
        }
        try validateResolvedArtifactAuthority(
            resolvedArtifactAuthority,
            releaseID: releaseID,
            signerKeyID: signerKeyID,
            selected: selected.entry
        )

        let tupleSHA256 = try admissionTupleSHA256(
            releaseID: releaseID,
            sidecarSHA256: sidecarSHA256,
            entry: selected.raw
        )
        let artifacts = try parseArtifactProjectionManifest(
            snapshotRoot: snapshotRoot,
            artifactRoot: artifactRoot,
            expectedSHA256: selected.entry.artifactManifestSHA256,
            authority: resolvedArtifactAuthority
        )
        // The signed entry's tokenizer digest is the authority; the projection
        // only locates the bytes. A disagreement means the loader would use a
        // tokenizer the admission never named.
        guard artifacts["tokenizer"]?.sha256 == selected.entry.tokenizerSHA256 else {
            throw NativeMTPAdmissionSidecarError.artifactDigestMismatch("$.entries.tokenizer_sha256")
        }
        return Parsed(
            tupleSHA256: tupleSHA256,
            sidecarSHA256: sidecarSHA256,
            decodePath: selected.entry.decodePath,
            admissionEnabled: true,
            modelID: selected.entry.modelKey,
            modelRevision: selected.entry.artifactHash,
            familyAdapter: selected.entry.familyAdapter,
            artifacts: artifacts,
            mtpManifestSHA256: selected.entry.mtpManifestSHA256,
            sourceLayout: selected.entry.sourceLayout,
            predictionLayerCount: selected.entry.mtpHeadCount,
            maxProposalDepth: selected.entry.proposalDepth,
            completeWindowBytesByDepth: selected.entry.completeWindowBytesByDepth,
            throughputDeltaPPM: selected.entry.throughputDeltaPPM,
            adaptationEnabled: true,
            adaptationMaxDepth: selected.entry.proposalDepth,
            quantization: selected.entry.quantization,
            cacheClass: "paged_kv",
            stateClass: selected.entry.mtpStateClass,
            providerRevision: selected.entry.providerRevision,
            upstreamMLXSwiftLMRevision: selected.entry.runtimeRevision,
            hardwareChip: selected.entry.hardwareClass,
            ramGB: selected.entry.ramBytes / 1_073_741_824,
            osVersion: context.osVersion,
            qualifiedSlots: selected.entry.qualifiedSlots,
            maxSlots: selected.entry.qualifiedSlots,
            maxNativeActiveRows: selected.entry.maxNativeActiveRows,
            requestProfile: RequestProfile(
                textOnly: true,
                streaming: true,
                tools: false,
                structuredOutputs: false,
                logprobs: false,
                penalties: false,
                conversationCache: false,
                diskCache: false,
                maxPromptTokens: selected.entry.maxPromptTokens,
                maxCompletionTokens: 1_048_576,
                sampling: selected.entry.requestFeatureProfile == Self.sampledRequestFeatureProfile
            ),
            spec023: Spec023(
                releaseID: releaseID,
                sourceCommit: selected.entry.sourceCommit,
                reproducibleBuildSHA256: selected.entry.reproducibleBuildSHA256,
                liveExecutableCDHash: selected.entry.liveExecutableCDHash,
                benchmarkPolicySHA256: selected.entry.benchmarkPolicySHA256,
                nativeMTPAdmissionTupleSHA256: tupleSHA256,
                evidenceArtifactSHA256: selected.entry.evidenceArtifactSHA256
            ),
            challengeBankSignerKeyID: challengeBankSignerKeyID,
            revocationSignerKeyID: revocationSignerKeyID,
            selfTest: NativeMTPSelfTestChallengeBank(
                releaseID: releaseID,
                challengeBankPath: defaultChallengeBankPath,
                challengeBankSHA256: selected.entry.challengeBankSHA256,
                signaturePath: defaultChallengeBankSignaturePath,
                signerKeyID: challengeBankSignerKeyID,
                signatureSHA256: ""
            ),
            admissionAllowed: true
        )
    }

    private static func validateResolvedArtifactAuthority(
        _ authority: NativeMTPResolvedArtifactAuthority,
        releaseID: String,
        signerKeyID: String,
        selected: NativeMTPAdmissionReleaseEntry
    ) throws {
        guard authority.verificationStatus == "verified" else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.artifact_authority.verification_status")
        }
        guard NativeMTPResolvedArtifactAuthority.feedSHA256IsValid(authority.feedSHA256) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.artifact_authority.feed_sha256")
        }
        guard authority.releaseID == releaseID else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.artifact_authority.release_id")
        }
        guard authority.signerKeyID == signerKeyID else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("artifact_authority_signer")
        }
        guard authority.modelKey == selected.modelKey else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.artifact_authority.model_key")
        }
        guard authority.artifactID == selected.artifactID else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.artifact_authority.artifact_id")
        }
        guard authority.hashAlgorithm == selected.hashAlgorithm else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.artifact_authority.hash_algorithm")
        }
        guard authority.hash == selected.artifactHash else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.artifact_authority.hash")
        }
        guard authority.targetSHA256 == authority.hash else {
            throw NativeMTPAdmissionSidecarError.artifactDigestMismatch("$.artifact_authority.target_sha256")
        }
    }

    private static func parseReleaseEntry(
        _ object: [String: NativeMTPSidecarJSON],
        path: String
    ) throws -> NativeMTPAdmissionReleaseEntry {
        let evidenceKeys: [String] = [
            "fit_evidence_sha256",
            "quality_evidence_sha256",
            "correctness_evidence_sha256",
            "state_rollback_evidence_sha256",
            "batch_evidence_sha256",
            "performance_evidence_sha256",
            "security_negative_evidence_sha256",
        ]
        try rejectUnknown(object, allowed: Set([
            "model_key", "artifact_id", "hash_algorithm", "artifact_hash",
            "artifact_manifest_sha256", "tokenizer_sha256", "decode_path",
            "mtp_manifest_sha256", "mtp_family_adapter", "mtp_state_class",
            "mtp_head_count", "proposal_depth", "complete_window_bytes_by_depth",
            "runtime_revision", "provider_revision", "source_commit",
            "reproducible_build_sha256", "live_executable_cdhash",
            "cache_state_classes", "hardware_class", "ram_bytes",
            "qualified_slots", "max_native_active_rows", "request_feature_profile", "max_prompt_tokens",
            "decrease_threshold_ppm",
            "increase_threshold_ppm", "max_verification_positions_per_committed_milli",
            "throughput_delta_ppm", "benchmark_policy_sha256", "challenge_bank_sha256",
            "quantization", "ordinary_baseline",
        ] + evidenceKeys), path: path)
        let hashAlgorithm = try requireString(
            object,
            "hash_algorithm",
            path: path,
            equals: NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm
        )
        let decodePath = try requireString(object, "decode_path", path: path, allowed: ["native_mtp"])
        let requestFeatureProfile = try requireNonEmptyString(object, "request_feature_profile", path: path)
        guard requestFeatureProfiles.contains(requestFeatureProfile) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).request_feature_profile")
        }
        let proposalDepth = try requireInt(
            object, "proposal_depth", path: path, range: 1...nativeMTPMaximumProposalDepth)
        let completeWindowBytesByDepth = try requireCompleteWindowBytesByDepth(
            object,
            key: "complete_window_bytes_by_depth",
            path: path,
            maxProposalDepth: proposalDepth
        )
        let cacheStateClasses = try requireStringArray(object, "cache_state_classes", path: path, range: 1...16)
        guard cacheStateClasses == cacheStateClasses.sorted(), Set(cacheStateClasses).count == cacheStateClasses.count else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).cache_state_classes")
        }
        let mtpStateClass = try requireString(object, "mtp_state_class", path: path, allowed: Self.releaseStateClasses)
        // The runtime admits only `mtp_state_class` (checked against the live
        // model at load); every signed cache/state class must be one it can
        // stage and rewind, and the admitted class must be among them.
        guard cacheStateClasses.allSatisfy(Self.releaseStateClasses.contains),
              cacheStateClasses.contains(mtpStateClass) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).cache_state_classes")
        }
        let qualifiedSlots = try requireInt(object, "qualified_slots", path: path, range: 2...8)
        let maxNativeActiveRows = try requireInt(object, "max_native_active_rows", path: path, range: 1...8)
        guard maxNativeActiveRows <= qualifiedSlots else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).max_native_active_rows")
        }
        // SPEC-023-R024 / SPEC-048-R004: the signed prompt bound; a longer
        // prompt selects ordinary.
        let maxPromptTokens = try requireInt(object, "max_prompt_tokens", path: path, range: 1...1_048_576)
        let decreaseThreshold = try requireInt(object, "decrease_threshold_ppm", path: path, range: 0...1_000_000)
        let increaseThreshold = try requireInt(object, "increase_threshold_ppm", path: path, range: 0...1_000_000)
        guard decreaseThreshold < increaseThreshold else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).increase_threshold_ppm")
        }
        let quantization = try parseReleaseQuantization(
            try requireObject(object, "quantization", path: path),
            path: "\(path).quantization"
        )
        try parseOrdinaryBaseline(
            try requireObject(object, "ordinary_baseline", path: path),
            path: "\(path).ordinary_baseline",
            entrySlots: qualifiedSlots,
            artifactHash: try requireSHA256(object, "artifact_hash", path: path),
            runtimeRevision: try requireShortString(object, "runtime_revision", path: path),
            providerRevision: try requireShortString(object, "provider_revision", path: path)
        )
        let evidence = try evidenceKeys.map { key in
            try requireSHA256(object, key, path: path)
        }
        return NativeMTPAdmissionReleaseEntry(
            modelKey: try requireNonEmptyString(object, "model_key", path: path),
            artifactID: try requireArtifactID(object, "artifact_id", path: path),
            hashAlgorithm: hashAlgorithm,
            artifactHash: try requireSHA256(object, "artifact_hash", path: path),
            artifactManifestSHA256: try requireSHA256(object, "artifact_manifest_sha256", path: path),
            tokenizerSHA256: try requireSHA256(object, "tokenizer_sha256", path: path),
            decodePath: decodePath,
            mtpManifestSHA256: try requireSHA256(object, "mtp_manifest_sha256", path: path),
            familyAdapter: try requireNonEmptyString(object, "mtp_family_adapter", path: path),
            mtpStateClass: mtpStateClass,
            mtpHeadCount: try requireInt(object, "mtp_head_count", path: path, range: 1...16),
            proposalDepth: proposalDepth,
            completeWindowBytesByDepth: completeWindowBytesByDepth,
            runtimeRevision: try requireShortString(object, "runtime_revision", path: path),
            providerRevision: try requireShortString(object, "provider_revision", path: path),
            sourceCommit: try requireCommitSHA(object, "source_commit", path: path),
            reproducibleBuildSHA256: try requireSHA256(object, "reproducible_build_sha256", path: path),
            liveExecutableCDHash: try requireCDHash(object, "live_executable_cdhash", path: path),
            cacheStateClasses: cacheStateClasses,
            hardwareClass: try requireHardwareClass(object, "hardware_class", path: path),
            ramBytes: try requireInt(object, "ram_bytes", path: path, range: 1...Int.max),
            qualifiedSlots: qualifiedSlots,
            maxNativeActiveRows: maxNativeActiveRows,
            requestFeatureProfile: requestFeatureProfile,
            maxPromptTokens: maxPromptTokens,
            decreaseThresholdPPM: decreaseThreshold,
            increaseThresholdPPM: increaseThreshold,
            maxVerificationPositionsPerCommittedMilli: try requireInt(object, "max_verification_positions_per_committed_milli", path: path, range: 1000...4000),
            throughputDeltaPPM: try requireInt(object, "throughput_delta_ppm", path: path, range: -1_000_000...1_000_000),
            benchmarkPolicySHA256: try requireSHA256(object, "benchmark_policy_sha256", path: path),
            challengeBankSHA256: try requireSHA256(object, "challenge_bank_sha256", path: path),
            evidenceArtifactSHA256: evidence,
            quantization: quantization
        )
    }

    private static let releaseStateClasses: Set<String> = ["stageable_rewindable", "hybrid_stageable_rewindable"]

    private static func parseReleaseQuantization(
        _ object: [String: NativeMTPSidecarJSON],
        path: String
    ) throws -> Quantization {
        try rejectUnknown(object, allowed: [
            "kind", "packed_data_dtype", "packed_layout", "scale_dtype",
            "scale_layout", "block_size_elements", "alignment_bytes",
            "padding_rule", "unquantized_exceptions", "per_layer_exceptions",
            "representation_manifest_sha256",
        ], path: path)
        let kind = try requireString(object, "kind", path: path, allowed: ["base", "mlx_affine", "mlx_mxfp8"])
        let packedDataDType = try requireString(object, "packed_data_dtype", path: path, allowed: ["none", "uint8", "uint32"])
        let packedLayout = try requireString(object, "packed_layout", path: path, allowed: ["none", "mlx_array_native_v1"])
        let scaleDType = try requireString(object, "scale_dtype", path: path, allowed: ["none", "bfloat16", "float16", "float32"])
        let scaleLayout = try requireString(object, "scale_layout", path: path, allowed: ["none", "per_block"])
        let blockSize = try requireNullableInt(object, "block_size_elements", path: path, range: 1...1024)
        let alignmentBytes = try requireNullableInt(object, "alignment_bytes", path: path, range: 1...4096)
        if let alignmentBytes {
            guard alignmentBytes > 0, alignmentBytes & (alignmentBytes - 1) == 0 else {
                throw NativeMTPAdmissionSidecarError.invalidValue("\(path).alignment_bytes")
            }
        }
        let paddingRule = try requireString(object, "padding_rule", path: path, allowed: ["none", "zero_pad_to_alignment"])
        let unquantizedExceptions = try requirePatternArray(object, "unquantized_exceptions", path: path)
        let perLayerExceptions = try requirePatternArray(object, "per_layer_exceptions", path: path)
        let representationManifestSHA256 = try requireSHA256(object, "representation_manifest_sha256", path: path)
        // R024 exception-array grammar applies to every kind, not only affine.
        try validateQuantizationExceptionArray(unquantizedExceptions, key: "unquantized_exceptions", path: path)
        try validateQuantizationExceptionArray(perLayerExceptions, key: "per_layer_exceptions", path: path)
        switch kind {
        case "base":
            guard packedDataDType == "none",
                  packedLayout == "none",
                  scaleDType == "none",
                  scaleLayout == "none",
                  blockSize == nil,
                  alignmentBytes == nil,
                  paddingRule == "none",
                  unquantizedExceptions.isEmpty,
                  perLayerExceptions.isEmpty else {
                throw NativeMTPAdmissionSidecarError.invalidValue(path)
            }
            return Quantization(
                target: "bf16",
                mtp: "bf16",
                blockSizeElements: blockSize,
                representationManifestSHA256: representationManifestSHA256,
                unquantizedExceptions: unquantizedExceptions,
                perLayerExceptions: perLayerExceptions
            )
        case "mlx_affine":
            guard packedDataDType == "uint32",
                  packedLayout == "mlx_array_native_v1",
                  scaleDType == "bfloat16",
                  scaleLayout == "per_block",
                  let blockSize,
                  [32, 64, 128].contains(blockSize),
                  alignmentBytes == nil,
                  paddingRule == "none" else {
                throw NativeMTPAdmissionSidecarError.invalidValue(path)
            }
            return Quantization(
                target: "mlx_affine_4bit",
                mtp: "mlx_affine_4bit",
                blockSizeElements: blockSize,
                representationManifestSHA256: representationManifestSHA256,
                unquantizedExceptions: unquantizedExceptions,
                perLayerExceptions: perLayerExceptions
            )
        case "mlx_mxfp8":
            guard packedDataDType == "uint8",
                  packedLayout == "mlx_array_native_v1",
                  ["float16", "float32"].contains(scaleDType),
                  scaleLayout != "none",
                  blockSize != nil,
                  alignmentBytes != nil,
                  paddingRule == "zero_pad_to_alignment" else {
                throw NativeMTPAdmissionSidecarError.invalidValue(path)
            }
            return Quantization(
                target: "mlx_mxfp8",
                mtp: "mlx_mxfp8",
                blockSizeElements: blockSize,
                representationManifestSHA256: representationManifestSHA256,
                unquantizedExceptions: unquantizedExceptions,
                perLayerExceptions: perLayerExceptions
            )
        default:
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).kind")
        }
    }

    private static func parseOrdinaryBaseline(
        _ object: [String: NativeMTPSidecarJSON],
        path: String,
        entrySlots: Int,
        artifactHash: String,
        runtimeRevision: String,
        providerRevision: String
    ) throws {
        try rejectUnknown(object, allowed: [
            "decode_path", "runtime_revision", "provider_revision", "artifact_hash",
            "qualified_slots", "measurement_sha256", "aggregate_tps_milli",
        ], path: path)
        try requireString(object, "decode_path", path: path, equals: "ordinary")
        guard try requireShortString(object, "runtime_revision", path: path) == runtimeRevision else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).runtime_revision")
        }
        guard try requireShortString(object, "provider_revision", path: path) == providerRevision else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).provider_revision")
        }
        guard try requireSHA256(object, "artifact_hash", path: path) == artifactHash else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).artifact_hash")
        }
        guard try requireInt(object, "qualified_slots", path: path, range: 2...8) == entrySlots else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).qualified_slots")
        }
        _ = try requireSHA256(object, "measurement_sha256", path: path)
        _ = try requireInt(object, "aggregate_tps_milli", path: path, range: 1...Int.max)
    }

    private static func parseArtifactProjectionManifest(
        snapshotRoot: URL,
        artifactRoot: URL,
        expectedSHA256: String,
        authority: NativeMTPResolvedArtifactAuthority
    ) throws -> [String: Artifact] {
        let root = snapshotRoot.standardizedFileURL
        let url = root.appendingPathComponent(defaultArtifactProjectionManifestPath, isDirectory: false).standardizedFileURL
        guard BYOMArtifactPathPolicy.isContained(url, in: root) else {
            throw NativeMTPAdmissionSidecarError.pathRejected(defaultArtifactProjectionManifestPath)
        }
        let data = try readBoundedRegularFile(url, maxBytes: maxSignatureBytes, tooLargeName: defaultArtifactProjectionManifestPath)
        guard sha256Hex(data) == expectedSHA256 else {
            throw NativeMTPAdmissionSidecarError.artifactDigestMismatch("$.entries.artifact_manifest_sha256")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NativeMTPAdmissionSidecarError.invalidJSON("artifact projection manifest must be UTF-8")
        }
        let value: NativeMTPSidecarJSON
        do {
            value = try NativeMTPSidecarJSONParser.parse(text)
        } catch {
            throw NativeMTPAdmissionSidecarError.invalidJSON(String(describing: error))
        }
        guard case .object(let object) = value else {
            throw NativeMTPAdmissionSidecarError.wrongType("$.artifact_manifest")
        }
        try rejectUnknown(object, allowed: ["schema_version", "artifacts"], path: "$.artifact_manifest")
        try requireString(object, "schema_version", path: "$.artifact_manifest", equals: "macprovider.native-mtp-artifact-projection.v1")
        let artifacts = try parseArtifacts(try requireObject(object, "artifacts", path: "$.artifact_manifest"))
        guard let target = artifacts["target"] else {
            throw NativeMTPAdmissionSidecarError.artifactNotManifested("target")
        }
        let projectedTarget = artifactRoot.standardizedFileURL
            .appendingPathComponent(target.path, isDirectory: false).standardizedFileURL
        guard projectedTarget.path == authority.targetURLPath else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.artifact_authority.target_url")
        }
        var authorityTargetStat = stat()
        var projectedTargetStat = stat()
        guard lstat(authority.targetURLPath, &authorityTargetStat) == 0,
              lstat(projectedTarget.path, &projectedTargetStat) == 0,
              authorityTargetStat.st_dev == projectedTargetStat.st_dev,
              authorityTargetStat.st_ino == projectedTargetStat.st_ino,
              authorityTargetStat.st_mtimespec.tv_sec == projectedTargetStat.st_mtimespec.tv_sec,
              authorityTargetStat.st_mtimespec.tv_nsec == projectedTargetStat.st_mtimespec.tv_nsec,
              authorityTargetStat.st_ctimespec.tv_sec == projectedTargetStat.st_ctimespec.tv_sec,
              authorityTargetStat.st_ctimespec.tv_nsec == projectedTargetStat.st_ctimespec.tv_nsec,
              authorityTargetStat.st_size == projectedTargetStat.st_size,
              (authorityTargetStat.st_mode & S_IFMT) == (projectedTargetStat.st_mode & S_IFMT) else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.artifact_authority.target_url")
        }
        guard target.sha256 == authority.targetSHA256 else {
            throw NativeMTPAdmissionSidecarError.artifactDigestMismatch("$.artifact_authority.target_sha256")
        }
        return artifacts
    }

    private static func parseArtifacts(_ object: [String: NativeMTPSidecarJSON]) throws -> [String: Artifact] {
        let required = Set(["target", "mtp", "tokenizer", "manifest"])
        try rejectUnknown(object, allowed: required, path: "$.artifacts")
        var result: [String: Artifact] = [:]
        for name in required.sorted() {
            let fields = try requireObject(object, name, path: "$.artifacts")
            try rejectUnknown(fields, allowed: ["path", "sha256"], path: "$.artifacts.\(name)")
            result[name] = Artifact(
                path: try requireRelativeArtifactPath(fields, "path", path: "$.artifacts.\(name)"),
                sha256: try requireSHA256(fields, "sha256", path: "$.artifacts.\(name)")
            )
        }
        return result
    }

    private static func parseRequestProfile(_ object: [String: NativeMTPSidecarJSON]) throws -> RequestProfile {
        try rejectUnknown(object, allowed: [
            "text_only", "streaming", "tools", "structured_outputs", "logprobs",
            "penalties", "conversation_cache", "disk_cache",
            "max_prompt_tokens", "max_completion_tokens",
        ], path: "$.request_profile")
        return RequestProfile(
            textOnly: try requireBool(object, "text_only", path: "$.request_profile"),
            streaming: try requireBool(object, "streaming", path: "$.request_profile"),
            tools: try requireBool(object, "tools", path: "$.request_profile"),
            structuredOutputs: try requireBool(object, "structured_outputs", path: "$.request_profile"),
            logprobs: try requireBool(object, "logprobs", path: "$.request_profile"),
            penalties: try requireBool(object, "penalties", path: "$.request_profile"),
            conversationCache: try requireBool(object, "conversation_cache", path: "$.request_profile"),
            diskCache: try requireBool(object, "disk_cache", path: "$.request_profile"),
            maxPromptTokens: try requireInt(object, "max_prompt_tokens", path: "$.request_profile", range: 1...1_048_576),
            maxCompletionTokens: try requireInt(object, "max_completion_tokens", path: "$.request_profile", range: 1...1_048_576)
        )
    }

    private static func parseSpec023(_ object: [String: NativeMTPSidecarJSON]) throws -> Spec023 {
        try rejectUnknown(object, allowed: [
            "release_id", "source_commit", "reproducible_build_sha256",
            "live_executable_cdhash",
            "benchmark_policy_sha256", "native_mtp_admission_tuple_sha256",
            "evidence_artifact_sha256",
        ], path: "$.spec023")
        let evidence = try requireSHA256Array(object, "evidence_artifact_sha256", path: "$.spec023")
        guard !evidence.isEmpty else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.spec023.evidence_artifact_sha256")
        }
        return Spec023(
            releaseID: try requireNonEmptyString(object, "release_id", path: "$.spec023"),
            sourceCommit: try requireCommitSHA(object, "source_commit", path: "$.spec023"),
            reproducibleBuildSHA256: try requireSHA256(object, "reproducible_build_sha256", path: "$.spec023"),
            liveExecutableCDHash: try requireCDHash(object, "live_executable_cdhash", path: "$.spec023"),
            benchmarkPolicySHA256: try requireSHA256(object, "benchmark_policy_sha256", path: "$.spec023"),
            nativeMTPAdmissionTupleSHA256: try requireSHA256(object, "native_mtp_admission_tuple_sha256", path: "$.spec023"),
            evidenceArtifactSHA256: evidence
        )
    }

    private static func parseSelfTest(_ object: [String: NativeMTPSidecarJSON]) throws -> NativeMTPSelfTestChallengeBank {
        try rejectUnknown(object, allowed: [
            "release_id", "challenge_bank_path", "challenge_bank_sha256",
            "signature_path", "signer_key_id", "signature_sha256",
        ], path: "$.selftest")
        return NativeMTPSelfTestChallengeBank(
            releaseID: try requireNonEmptyString(object, "release_id", path: "$.selftest"),
            challengeBankPath: try requireRelativeArtifactPath(object, "challenge_bank_path", path: "$.selftest"),
            challengeBankSHA256: try requireSHA256(object, "challenge_bank_sha256", path: "$.selftest"),
            signaturePath: try requireRelativeArtifactPath(object, "signature_path", path: "$.selftest"),
            signerKeyID: try requireNonEmptyString(object, "signer_key_id", path: "$.selftest"),
            signatureSHA256: try requireSHA256(object, "signature_sha256", path: "$.selftest")
        )
    }

    private static func validateSelfTestChallengeBank(
        _ parsed: Parsed,
        snapshotRoot: URL,
        trustedKeyring: TrustedKeyring
    ) throws {
        let root = snapshotRoot.standardizedFileURL
        let bankURL = root.appendingPathComponent(parsed.selfTest.challengeBankPath, isDirectory: false).standardizedFileURL
        let signatureURL = root.appendingPathComponent(parsed.selfTest.signaturePath, isDirectory: false).standardizedFileURL
        guard BYOMArtifactPathPolicy.isContained(bankURL, in: root),
              BYOMArtifactPathPolicy.isContained(signatureURL, in: root) else {
            throw NativeMTPAdmissionSidecarError.pathRejected("$.selftest")
        }
        let bankData = try readBoundedRegularFile(
            bankURL,
            maxBytes: maxSelfTestChallengeBankBytes,
            tooLargeName: parsed.selfTest.challengeBankPath
        )
        guard sha256Hex(bankData) == parsed.selfTest.challengeBankSHA256 else {
            throw NativeMTPAdmissionSidecarError.artifactDigestMismatch("$.selftest.challenge_bank_sha256")
        }
        let signatureData = try readBoundedRegularFile(
            signatureURL,
            maxBytes: maxSignatureBytes,
            tooLargeName: parsed.selfTest.signaturePath
        )
        if !parsed.selfTest.signatureSHA256.isEmpty,
           sha256Hex(signatureData) != parsed.selfTest.signatureSHA256 {
            throw NativeMTPAdmissionSidecarError.artifactDigestMismatch("$.selftest.signature_sha256")
        }
        try verifyDetachedSignature(
            payload: bankData,
            signatureData: signatureData,
            trustedKeyring: trustedKeyring,
            expectedKeyID: parsed.selfTest.signerKeyID
        )
    }

    private static func validateStaticSupport(_ parsed: Parsed) throws {
        guard parsed.decodePath == "native_mtp", parsed.admissionEnabled, parsed.admissionAllowed else {
            throw NativeMTPAdmissionSidecarError.unsupported("admission flags")
        }
        guard parsed.tupleSHA256 == parsed.spec023.nativeMTPAdmissionTupleSHA256 else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.spec023.native_mtp_admission_tuple_sha256")
        }
        if parsed.sidecarSHA256 == String(repeating: "0", count: 64),
           parsed.tupleSHA256 != admissionTupleSHA256(parsed) {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.tuple_sha256")
        }
        guard parsed.mtpManifestSHA256 == parsed.artifacts["manifest"]?.sha256 else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.mtp.manifest_sha256")
        }
        guard parsed.adaptationEnabled, parsed.adaptationMaxDepth <= parsed.maxProposalDepth else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.mtp.adaptation_max_depth")
        }
        let maxDepthCompleteWindowBytes = parsed.completeWindowBytesByDepth[parsed.maxProposalDepth]
        guard parsed.qualifiedSlots <= Int.max / maxDepthCompleteWindowBytes else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.mtp.complete_window_bytes_by_depth")
        }
        guard parsed.qualifiedSlots <= parsed.maxSlots else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.hardware.qualified_slots")
        }
        guard parsed.requestProfile.textOnly,
              parsed.requestProfile.streaming,
              !parsed.requestProfile.tools,
              !parsed.requestProfile.structuredOutputs,
              !parsed.requestProfile.logprobs,
              !parsed.requestProfile.penalties,
              !parsed.requestProfile.conversationCache,
              !parsed.requestProfile.diskCache else {
            throw NativeMTPAdmissionSidecarError.unsupported("$.request_profile")
        }
    }

    private static func validateLiveTuple(_ parsed: Parsed, context: RuntimeContext) throws {
        guard parsed.modelID == context.modelID else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.model.id") }
        guard parsed.modelRevision == context.modelRevision else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.model.revision") }
        guard parsed.upstreamMLXSwiftLMRevision == context.upstreamMLXSwiftLMRevision else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.revisions.upstream_mlx_swift_lm")
        }
        guard parsed.hardwareChip == canonicalHardwareClass(context.hardwareChip) else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.hardware.chip")
        }
        guard parsed.ramGB == context.ramGB else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.hardware.ram_gb") }
        guard parsed.osVersion == context.osVersion else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.hardware.os_version") }
        guard parsed.qualifiedSlots == context.slotCount else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.hardware.qualified_slots") }
    }

    static func canonicalHardwareClass(_ chip: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in chip.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.last == "-" {
            result.removeLast()
        }
        return result
    }

    private static func validateRevocation(_ parsed: Parsed, context: RuntimeContext) throws {
        guard let revoked = context.revokedTupleSHA256 else {
            throw NativeMTPAdmissionSidecarError.revocationUnavailable
        }
        guard !revoked.contains(parsed.tupleSHA256) else {
            throw NativeMTPAdmissionSidecarError.tupleRevoked(parsed.tupleSHA256)
        }
    }

    private static func validateArtifacts(
        _ artifacts: [String: Artifact],
        snapshotRoot: URL,
        rejectUnmanifestedFiles: Bool = true,
        captureArtifacts: Bool,
        allowedAuxiliaryPaths: Set<String>,
        fileManager: FileManager
    ) throws -> NativeMTPAdmissionCapturedArtifacts? {
        let root = snapshotRoot.standardizedFileURL
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(".")
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw NativeMTPAdmissionSidecarError.pathRejected(root.path)
        }
        try validateTrustedSourceMetadata(rootStat, relativePath: ".")
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(".")
        }
        defer { close(rootFD) }
        var openedRootStat = stat()
        guard fstat(rootFD, &openedRootStat) == 0,
              openedRootStat.st_dev == rootStat.st_dev,
              openedRootStat.st_ino == rootStat.st_ino else {
            throw NativeMTPAdmissionSidecarError.pathRejected(".")
        }
        var manifestedDirectories: Set<String> = []
        var validatedByName: [String: ValidatedArtifactHandle] = [:]
        for (name, artifact) in artifacts {
            let url = root.appendingPathComponent(artifact.path, isDirectory: false)
            let standardized = url.standardizedFileURL
            guard BYOMArtifactPathPolicy.isContained(standardized, in: root) else {
                throw NativeMTPAdmissionSidecarError.pathRejected(artifact.path)
            }
            let validated = try openAndDigestArtifactNoFollow(
                relativePath: artifact.path,
                rootFD: rootFD
            )
            if validated.isDirectory {
                manifestedDirectories.insert(artifact.path)
            }
            let digest = validated.sha256
            guard digest == artifact.sha256 else {
                throw NativeMTPAdmissionSidecarError.artifactDigestMismatch(name)
            }
            validatedByName[name] = validated
        }
        if rejectUnmanifestedFiles {
            try rejectUnmanifestedSnapshotArtifacts(
                snapshotRoot: root,
                manifestedPaths: Set(artifacts.values.map(\.path)),
                manifestedDirectories: manifestedDirectories,
                allowedAuxiliaryPaths: allowedAuxiliaryPaths,
                fileManager: fileManager
            )
        }
        guard captureArtifacts else { return nil }
        return try captureValidatedArtifacts(
            artifacts: artifacts,
            validatedByName: validatedByName,
            snapshotRoot: root,
            sourceDevice: rootStat.st_dev,
            fileManager: fileManager
        )
    }

    private final class ValidatedArtifactHandle {
        let relativePath: String
        let leafName: String
        let parentFD: Int32
        let artifactFD: Int32
        let initialStat: stat
        let isDirectory: Bool
        let sha256: String

        init(
            relativePath: String,
            leafName: String,
            parentFD: Int32,
            artifactFD: Int32,
            initialStat: stat,
            isDirectory: Bool,
            sha256: String
        ) {
            self.relativePath = relativePath
            self.leafName = leafName
            self.parentFD = parentFD
            self.artifactFD = artifactFD
            self.initialStat = initialStat
            self.isDirectory = isDirectory
            self.sha256 = sha256
        }

        deinit {
            close(artifactFD)
            close(parentFD)
        }
    }

    private struct DescriptorFileStamp: Equatable {
        let relativePath: String
        let size: Int64
        let device: Int64
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(relativePath: String, info: stat) {
            self.relativePath = relativePath
            self.size = Int64(info.st_size)
            self.device = Int64(info.st_dev)
            self.inode = UInt64(info.st_ino)
            self.modifiedSeconds = info.st_mtimespec.tv_sec
            self.modifiedNanoseconds = info.st_mtimespec.tv_nsec
            self.changedSeconds = info.st_ctimespec.tv_sec
            self.changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private static func openAndDigestArtifactNoFollow(
        relativePath: String,
        rootFD: Int32
    ) throws -> ValidatedArtifactHandle {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let leaf = components.last, !leaf.isEmpty else {
            throw NativeMTPAdmissionSidecarError.pathRejected(relativePath)
        }
        var currentFD = dup(rootFD)
        guard currentFD >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(relativePath)
        }
        var fdsToClose: [Int32] = [currentFD]
        defer {
            for fd in fdsToClose.reversed() {
                close(fd)
            }
        }
        for component in components.dropLast() {
            let nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard nextFD >= 0 else {
                throw NativeMTPAdmissionSidecarError.pathRejected(relativePath)
            }
            var componentStat = stat()
            guard fstat(nextFD, &componentStat) == 0 else {
                close(nextFD)
                throw NativeMTPAdmissionSidecarError.pathRejected(relativePath)
            }
            try validateTrustedSourceMetadata(componentStat, relativePath: relativePath)
            currentFD = nextFD
            fdsToClose.append(nextFD)
        }
        let parentFD = dup(currentFD)
        guard parentFD >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(relativePath)
        }
        let artifactFD = openat(currentFD, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard artifactFD >= 0 else {
            close(parentFD)
            if errno == ENOENT {
                throw NativeMTPAdmissionSidecarError.artifactNotFound(relativePath)
            }
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        var st = stat()
        guard fstat(artifactFD, &st) == 0 else {
            close(artifactFD)
            close(parentFD)
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        try validateTrustedSourceMetadata(st, relativePath: relativePath)
        if (st.st_mode & S_IFMT) == S_IFDIR {
            let identity = try computeDirectoryIdentityDescriptorRelative(directoryFD: artifactFD, relativePath: relativePath)
            return ValidatedArtifactHandle(
                relativePath: relativePath,
                leafName: leaf,
                parentFD: parentFD,
                artifactFD: artifactFD,
                initialStat: st,
                isDirectory: true,
                sha256: identity.digest
            )
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else {
            close(artifactFD)
            close(parentFD)
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        guard st.st_size <= maxSingleArtifactBytes else {
            close(artifactFD)
            close(parentFD)
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
        }
        let digest = try hashRegularFileDescriptorNoClose(artifactFD, expected: st, relativePath: relativePath)
        return ValidatedArtifactHandle(
            relativePath: relativePath,
            leafName: leaf,
            parentFD: parentFD,
            artifactFD: artifactFD,
            initialStat: st,
            isDirectory: false,
            sha256: digest
        )
    }

    private static func hashRegularFileDescriptor(
        _ fd: Int32,
        expected: stat,
        relativePath: String
    ) throws -> String {
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: hashChunkBytes)
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else {
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<count]))
            }
            total += Int64(count)
            guard total <= maxSingleArtifactBytes else {
                throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              sameRegularIdentity(expected, after),
              total == expected.st_size else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func hashRegularFileDescriptorNoClose(
        _ fd: Int32,
        expected: stat,
        relativePath: String
    ) throws -> String {
        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: hashChunkBytes)
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else {
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<count]))
            }
            total += Int64(count)
            guard total <= maxSingleArtifactBytes else {
                throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              sameRegularIdentity(expected, after),
              total == expected.st_size else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func sameRegularIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
            && (rhs.st_mode & S_IFMT) == S_IFREG
            && rhs.st_nlink == 1
    }

    private static func computeDirectoryIdentityDescriptorRelative(
        directoryFD: Int32,
        relativePath: String
    ) throws -> (digest: String, stamps: [DescriptorFileStamp]) {
        let before = try descriptorStamps(directoryFD: directoryFD, prefix: "", relativePath: relativePath)
        guard before.count <= maxSnapshotTreeFiles else {
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
        }
        var total: Int64 = 0
        var manifest = ""
        for stamp in before {
            total += stamp.size
            guard total <= maxSnapshotTreeBytes else {
                throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
            }
            let sha = try hashDescriptorRelativeFile(directoryFD: directoryFD, relativePath: relativePath, stamp: stamp)
            manifest += "\(stamp.relativePath)\n\(stamp.size)\n\(sha)\n"
        }
        guard try descriptorStamps(directoryFD: directoryFD, prefix: "", relativePath: relativePath) == before else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        let digest = Data(SHA256.hash(data: Data(manifest.utf8))).map { String(format: "%02x", $0) }.joined()
        return (digest, before)
    }

    private static func descriptorStamps(
        directoryFD: Int32,
        prefix: String,
        relativePath: String
    ) throws -> [DescriptorFileStamp] {
        // `dup` shares the directory offset with `directoryFD`. Admission walks
        // each directory more than once (before/after identity checks and later
        // capture), so a duplicated descriptor can start at EOF and falsely
        // report that the artifact changed. Reopen `.` to get an independent
        // open-file description and directory cursor for every scan.
        let scanFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scanFD >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(relativePath)
        }
        guard let dir = fdopendir(scanFD) else {
            close(scanFD)
            throw NativeMTPAdmissionSidecarError.artifactNotFound(relativePath)
        }
        defer { closedir(dir) }
        var entries: [(name: String, stat: stat)] = []
        while let entry = readdir(dir) {
            let name = direntName(entry)
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(prefix)\(name)")
            }
            try validateTrustedSourceMetadata(info, relativePath: "\(relativePath)/\(prefix)\(name)")
            entries.append((name, info))
        }
        entries.sort { $0.name < $1.name }

        var stamps: [DescriptorFileStamp] = []
        for entry in entries {
            let childRelative = prefix + entry.name
            switch entry.stat.st_mode & S_IFMT {
            case S_IFDIR:
                let childFD = openat(directoryFD, entry.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else {
                    throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(childRelative)")
                }
                let childStamps = try descriptorStamps(
                    directoryFD: childFD,
                    prefix: childRelative + "/",
                    relativePath: relativePath
                )
                close(childFD)
                stamps.append(contentsOf: childStamps)
            case S_IFREG where entry.stat.st_nlink == 1:
                try ModelArtifactRelativePathPolicy.validate(childRelative)
                guard stamps.count < maxSnapshotTreeFiles else {
                    throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
                }
                stamps.append(DescriptorFileStamp(relativePath: childRelative, info: entry.stat))
            default:
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(childRelative)")
            }
        }
        return stamps.sorted { $0.relativePath < $1.relativePath }
    }

    private static func hashDescriptorRelativeFile(
        directoryFD: Int32,
        relativePath: String,
        stamp: DescriptorFileStamp
    ) throws -> String {
        let components = stamp.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let leaf = components.last, !leaf.isEmpty else {
            throw NativeMTPAdmissionSidecarError.pathRejected(stamp.relativePath)
        }
        var currentFD = dup(directoryFD)
        guard currentFD >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(relativePath)
        }
        var fdsToClose: [Int32] = [currentFD]
        defer {
            for fd in fdsToClose.reversed() {
                close(fd)
            }
        }
        for component in components.dropLast() {
            let nextFD = openat(currentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard nextFD >= 0 else {
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(stamp.relativePath)")
            }
            currentFD = nextFD
            fdsToClose.append(nextFD)
        }
        let fd = openat(currentFD, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(stamp.relativePath)")
        }
        defer { close(fd) }
        var expected = stat()
        expected.st_size = off_t(stamp.size)
        expected.st_dev = dev_t(stamp.device)
        expected.st_ino = ino_t(stamp.inode)
        expected.st_mtimespec.tv_sec = stamp.modifiedSeconds
        expected.st_mtimespec.tv_nsec = stamp.modifiedNanoseconds
        expected.st_ctimespec.tv_sec = stamp.changedSeconds
        expected.st_ctimespec.tv_nsec = stamp.changedNanoseconds
        guard currentDescriptorStamp(fd: fd, relativePath: stamp.relativePath) == stamp else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(stamp.relativePath)")
        }
        return try hashRegularFileDescriptorNoClose(fd, expected: expected, relativePath: "\(relativePath)/\(stamp.relativePath)")
    }

    private static func currentDescriptorStamp(fd: Int32, relativePath: String) -> DescriptorFileStamp? {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else {
            return nil
        }
        return DescriptorFileStamp(relativePath: relativePath, info: info)
    }

    private static func direntName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: entry.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func validateTrustedSourceMetadata(_ st: stat, relativePath: String) throws {
        guard st.st_uid == geteuid(), (st.st_mode & 0o022) == 0 else {
            throw NativeMTPAdmissionSidecarError.pathRejected(relativePath)
        }
    }

    private static func validateArtifactEntryUnchanged(_ handle: ValidatedArtifactHandle) throws {
        var entryStat = stat()
        guard fstatat(handle.parentFD, handle.leafName, &entryStat, AT_SYMLINK_NOFOLLOW) == 0,
              sameArtifactEntryIdentity(handle.initialStat, entryStat, isDirectory: handle.isDirectory) else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(handle.relativePath)
        }
    }

    private static func sameArtifactEntryIdentity(_ lhs: stat, _ rhs: stat, isDirectory: Bool) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
            && (rhs.st_mode & S_IFMT) == (isDirectory ? S_IFDIR : S_IFREG)
            && (isDirectory || rhs.st_nlink == 1)
    }

    private struct CaptureBudget {
        var fileCount = 0
        var byteCount: Int64 = 0

        mutating func chargeRegularFile(bytes: Int64, relativePath: String) throws {
            fileCount += 1
            byteCount += bytes
            guard fileCount <= maxSnapshotTreeFiles, byteCount <= maxSnapshotTreeBytes else {
                throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
            }
        }
    }

    private static func captureValidatedArtifacts(
        artifacts: [String: Artifact],
        validatedByName: [String: ValidatedArtifactHandle],
        snapshotRoot: URL,
        sourceDevice: dev_t,
        fileManager: FileManager
    ) throws -> NativeMTPAdmissionCapturedArtifacts {
        NativeMTPAdmissionCapturedArtifacts.reclaimStaleCaptureSiblings(of: snapshotRoot, fileManager: fileManager)
        let stagingRoot = snapshotRoot.deletingLastPathComponent()
            .appendingPathComponent(
                "\(NativeMTPAdmissionCapturedArtifacts.captureDirectoryPrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        chmod(stagingRoot.path, 0o700)
        let leaseFD = try NativeMTPAdmissionCapturedArtifacts.openLockedLease(
            for: stagingRoot,
            create: true,
            nonblocking: false
        )
        var shouldCloseLease = true
        defer {
            if shouldCloseLease {
                close(leaseFD)
            }
        }
        var stagingStat = stat()
        guard lstat(stagingRoot.path, &stagingStat) == 0,
              (stagingStat.st_mode & S_IFMT) == S_IFDIR,
              stagingStat.st_dev == (testingExpectedStagingDeviceOverride ?? sourceDevice) else {
            try? NativeMTPAdmissionCapturedArtifacts.removePrivateCaptureTree(stagingRoot, fileManager: fileManager)
            throw NativeMTPAdmissionSidecarError.pathRejected("captured_artifacts")
        }
        do {
            if let hook = testingDescriptorCaptureMutationHook {
                try hook("before_capture")
            }
            var stagedURLs: [String: URL] = [:]
            var budget = CaptureBudget()
            for name in ["target", "mtp", "tokenizer", "manifest"] {
                guard let artifact = artifacts[name],
                      let validated = validatedByName[name] else {
                    throw NativeMTPAdmissionSidecarError.artifactNotManifested(name)
                }
                let destination = stagingRoot.appendingPathComponent(artifact.path, isDirectory: validated.isDirectory)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try validateArtifactEntryUnchanged(validated)
                if validated.isDirectory {
                    try copyDirectoryDescriptorRelative(
                        from: validated,
                        to: destination,
                        fileManager: fileManager,
                        budget: &budget
                    )
                    try validateArtifactEntryUnchanged(validated)
                    let sourceDigest = try computeDirectoryIdentityDescriptorRelative(
                        directoryFD: validated.artifactFD,
                        relativePath: artifact.path
                    ).digest
                    guard sourceDigest == artifact.sha256 else {
                        throw NativeMTPAdmissionSidecarError.artifactDigestMismatch(name)
                    }
                    let stagedDigest = try MLXSnapshotIdentity.compute(directory: destination).digest
                    guard stagedDigest == artifact.sha256 else {
                        throw NativeMTPAdmissionSidecarError.artifactDigestMismatch(name)
                    }
                } else {
                    let stagedDigest: String
                    if fileManager.fileExists(atPath: destination.path) {
                        stagedDigest = try hashStagedRegularFileNoFollow(destination, relativePath: artifact.path)
                    } else {
                        let copiedBytes = try copyRegularFileDescriptorNoClose(
                            from: validated.artifactFD,
                            expected: validated.initialStat,
                            to: destination,
                            relativePath: artifact.path
                        )
                        try budget.chargeRegularFile(bytes: copiedBytes, relativePath: artifact.path)
                        stagedDigest = try hashStagedRegularFileNoFollow(destination, relativePath: artifact.path)
                    }
                    try validateArtifactEntryUnchanged(validated)
                    guard stagedDigest == artifact.sha256 else {
                        throw NativeMTPAdmissionSidecarError.artifactDigestMismatch(name)
                    }
                }
                stagedURLs[name] = destination
            }
            try chmodCapturedRoot(stagingRoot, fileManager: fileManager)
            guard let targetURL = stagedURLs["target"],
                  let mtpURL = stagedURLs["mtp"],
                  let tokenizerURL = stagedURLs["tokenizer"],
                  let manifestURL = stagedURLs["manifest"] else {
                throw NativeMTPAdmissionSidecarError.artifactNotManifested("captured_artifacts")
            }
            let capturedStamp = try NativeMTPAdmissionCapturedArtifacts.captureTreeStamp(stagingRoot)
            let captured = NativeMTPAdmissionCapturedArtifacts(
                rootURL: stagingRoot,
                targetURL: targetURL,
                mtpURL: mtpURL,
                tokenizerURL: tokenizerURL,
                manifestURL: manifestURL,
                rootStamp: capturedStamp.root,
                fileStamps: capturedStamp.files,
                leaseFD: leaseFD
            )
            shouldCloseLease = false
            return captured
        } catch {
            try? NativeMTPAdmissionCapturedArtifacts.removePrivateCaptureTree(stagingRoot, fileManager: fileManager)
            throw error
        }
    }

    private static func copyDirectoryDescriptorRelative(
        from source: ValidatedArtifactHandle,
        to destination: URL,
        fileManager: FileManager,
        budget: inout CaptureBudget
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        chmod(destination.path, 0o700)
        try copyDirectoryEntriesDescriptorRelative(
            directoryFD: source.artifactFD,
            destination: destination,
            relativePath: source.relativePath,
            prefix: "",
            fileManager: fileManager,
            budget: &budget
        )
        try chmodTree(destination, fileManager: fileManager)
    }

    private static func copyDirectoryEntriesDescriptorRelative(
        directoryFD: Int32,
        destination: URL,
        relativePath: String,
        prefix: String,
        fileManager: FileManager,
        budget: inout CaptureBudget
    ) throws {
        let entries = try descriptorDirectoryEntries(directoryFD: directoryFD, relativePath: relativePath, prefix: prefix)
        for entry in entries {
            let childRelative = prefix + entry.name
            let destURL = destination.appendingPathComponent(childRelative)
            switch entry.info.st_mode & S_IFMT {
            case S_IFDIR:
                let childFD = openat(directoryFD, entry.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else {
                    throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(childRelative)")
                }
                defer { close(childFD) }
                try fileManager.createDirectory(at: destURL, withIntermediateDirectories: false)
                chmod(destURL.path, 0o700)
                try copyDirectoryEntriesDescriptorRelative(
                    directoryFD: childFD,
                    destination: destination,
                    relativePath: relativePath,
                    prefix: childRelative + "/",
                    fileManager: fileManager,
                    budget: &budget
                )
            case S_IFREG where entry.info.st_nlink == 1:
                try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fd = openat(directoryFD, entry.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else {
                    throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(childRelative)")
                }
                defer { close(fd) }
                let copiedBytes = try copyRegularFileDescriptorNoClose(
                    from: fd,
                    expected: entry.info,
                    to: destURL,
                    relativePath: "\(relativePath)/\(childRelative)"
                )
                try budget.chargeRegularFile(bytes: copiedBytes, relativePath: "\(relativePath)/\(childRelative)")
            default:
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(childRelative)")
            }
        }
    }

    private static func descriptorDirectoryEntries(
        directoryFD: Int32,
        relativePath: String,
        prefix: String
    ) throws -> [(name: String, info: stat)] {
        // Use an independent directory cursor; `dup` would share and consume
        // the source handle's offset across validation and capture passes.
        let scanFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scanFD >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(relativePath)
        }
        guard let dir = fdopendir(scanFD) else {
            close(scanFD)
            throw NativeMTPAdmissionSidecarError.artifactNotFound(relativePath)
        }
        defer { closedir(dir) }
        var entries: [(name: String, info: stat)] = []
        while let entry = readdir(dir) {
            let name = direntName(entry)
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile("\(relativePath)/\(prefix)\(name)")
            }
            try validateTrustedSourceMetadata(info, relativePath: "\(relativePath)/\(prefix)\(name)")
            entries.append((name, info))
        }
        return entries.sorted { $0.name < $1.name }
    }

    private static func copyRegularFileDescriptorNoClose(
        from inputFD: Int32,
        expected before: stat,
        to destination: URL,
        relativePath: String
    ) throws -> Int64 {
        guard (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1 else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        guard before.st_size <= maxSingleArtifactBytes else {
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
        }
        guard lseek(inputFD, 0, SEEK_SET) >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        let outputFD = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o400)
        guard outputFD >= 0 else {
            throw NativeMTPAdmissionSidecarError.pathRejected(destination.path)
        }
        defer { close(outputFD) }
        var buffer = [UInt8](repeating: 0, count: hashChunkBytes)
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(inputFD, $0.baseAddress, $0.count) }
            guard count >= 0 else {
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
            }
            if count == 0 { break }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes {
                    write(outputFD, $0.baseAddress!.advanced(by: written), count - written)
                }
                guard result > 0 else {
                    throw NativeMTPAdmissionSidecarError.pathRejected(destination.path)
                }
                written += result
            }
            total += Int64(count)
            guard total <= maxSingleArtifactBytes else {
                throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
            }
        }
        var after = stat()
        guard fstat(inputFD, &after) == 0,
              sameRegularIdentity(before, after),
              total == before.st_size else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        guard lseek(inputFD, 0, SEEK_SET) >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        guard fsync(outputFD) == 0 else {
            throw NativeMTPAdmissionSidecarError.pathRejected(destination.path)
        }
        chmod(destination.path, 0o400)
        return total
    }

    private static func hashStagedRegularFileNoFollow(_ url: URL, relativePath: String) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_nlink == 1 else {
            close(fd)
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        guard st.st_size <= maxSingleArtifactBytes else {
            close(fd)
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(relativePath)
        }
        return try hashRegularFileDescriptor(fd, expected: st, relativePath: relativePath)
    }

    private static func chmodTree(_ root: URL, fileManager: FileManager) throws {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return
        }
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            chmod(url.path, isDirectory ? 0o500 : 0o400)
        }
        chmod(root.path, 0o500)
    }

    private static func chmodCapturedRoot(_ root: URL, fileManager: FileManager) throws {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return
        }
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            chmod(url.path, isDirectory ? 0o500 : 0o400)
        }
        chmod(root.path, 0o500)
    }

    private static func rejectUnmanifestedSnapshotArtifacts(
        snapshotRoot root: URL,
        manifestedPaths: Set<String>,
        manifestedDirectories: Set<String>,
        allowedAuxiliaryPaths: Set<String>,
        fileManager: FileManager
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(".")
        }
        for case let url as URL in enumerator {
            let relative = relativeArtifactPath(for: url, snapshotRoot: root)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relative)
            }
            if relative == "native-mtp-admission.json"
                || relative == "native-mtp-admission.json.sig"
                || relative == "native-mtp-selftest-bank.json"
                || relative == "native-mtp-selftest-bank.json.sig"
                || allowedAuxiliaryPaths.contains(relative)
            {
                continue
            }
            let coveredByDirectory = manifestedDirectories.contains { directory in
                relative.hasPrefix(directory + "/")
            }
            if values.isRegularFile == true,
               !manifestedPaths.contains(relative),
               !coveredByDirectory {
                throw NativeMTPAdmissionSidecarError.artifactNotManifested(relative)
            }
        }
    }

    private static func rejectSymlinkComponents(
        relativePath: String,
        snapshotRoot root: URL,
        fileManager: FileManager
    ) throws {
        var current = root
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            current.appendPathComponent(String(component), isDirectory: false)
            if (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
            }
        }
    }

    private static func verifyDetachedSignature(
        payload: Data,
        signatureData: Data,
        trustedKeyring: TrustedKeyring,
        expectedKeyID: String? = nil
    ) throws -> String {
        guard let text = String(data: signatureData, encoding: .utf8) else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("sidecar_utf8")
        }
        let value: NativeMTPSidecarJSON
        do {
            value = try NativeMTPSidecarJSONParser.parse(text)
        } catch {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("sidecar_json")
        }
        guard case .object(let object) = value else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("sidecar_type")
        }
        try rejectUnknown(object, allowed: ["key_id", "alg", "signature"], path: "$.signature")
        let keyID = try requireNonEmptyString(object, "key_id", path: "$.signature")
        guard keyID == (expectedKeyID ?? trustedKeyring.requiredKeyID) else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("unexpected_key_id")
        }
        _ = try requireString(object, "alg", path: "$.signature", equals: "ed25519")
        guard let encodedPublicKey = trustedKeyring.publicKeysByKeyID[keyID],
              let publicKeyBytes = Data(base64Encoded: encodedPublicKey),
              publicKeyBytes.count == 32,
              publicKeyBytes.base64EncodedString() == encodedPublicKey,
              let signatureEncoded = try? requireNonEmptyString(object, "signature", path: "$.signature"),
              let signature = Data(base64Encoded: signatureEncoded),
              signature.count == 64,
              signature.base64EncodedString() == signatureEncoded,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes),
              publicKey.isValidSignature(signature, for: payload) else {
            throw NativeMTPAdmissionSidecarError.signatureInvalid("verification_failed")
        }
        return keyID
    }

    private static func readBoundedRegularFile(_ url: URL, maxBytes: Int, tooLargeName: String) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT {
                throw NativeMTPAdmissionSidecarError.artifactNotFound(url.lastPathComponent)
            }
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(url.lastPathComponent)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_nlink == 1 else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(url.lastPathComponent)
        }
        guard st.st_size <= Int64(maxBytes) else {
            throw NativeMTPAdmissionSidecarError.artifactTooLarge(tooLargeName)
        }
        var data = Data()
        data.reserveCapacity(Int(st.st_size))
        var buffer = [UInt8](repeating: 0, count: min(hashChunkBytes, maxBytes))
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else {
                throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(url.lastPathComponent)
            }
            if count == 0 { break }
            total += count
            guard total <= maxBytes else {
                throw NativeMTPAdmissionSidecarError.artifactTooLarge(tooLargeName)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              sameRegularIdentity(st, after),
              total == st.st_size else {
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(url.lastPathComponent)
        }
        return data
    }

    static func admissionTupleSHA256ForTesting(_ object: [String: Any]) throws -> String {
        guard let parsedObject = try NativeMTPSidecarJSONParser.parse(
            String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
        ).objectValue else {
            throw NativeMTPAdmissionSidecarError.wrongType("$")
        }
        if let entriesValue = parsedObject["entries"],
           case .array(let entries) = entriesValue,
           let firstEntry = entries.first {
            let sidecarData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            let sidecarSHA256 = sha256Hex(sidecarData)
            let releaseID = try requireNonEmptyString(parsedObject, "release_id", path: "$")
            return try admissionTupleSHA256(
                releaseID: releaseID,
                sidecarSHA256: sidecarSHA256,
                entry: firstEntry
            )
        }
        return try admissionTupleSHA256(parseRoot(parsedObject))
    }

    private static func admissionTupleSHA256(
        releaseID: String,
        sidecarSHA256: String,
        entry: NativeMTPSidecarJSON
    ) throws -> String {
        let value = RFC8785JCS.Value.object([
            "schema_version": .string(tupleIdentitySchemaVersion),
            "release_id": .string(releaseID),
            "sidecar_sha256": .string(sidecarSHA256),
            "entry": try entry.jcsValue(),
        ])
        let canonical = try RFC8785JCS.canonicalString(value)
        return sha256Hex(Data((tupleIdentityDomain + canonical).utf8))
    }

    private static func admissionTupleSHA256(_ parsed: Parsed) -> String {
        var fields: [String] = [
            "schema_version=\(schemaVersion)",
            "decode_path=\(parsed.decodePath)",
            "admission_enabled=\(parsed.admissionEnabled)",
            "model.id=\(parsed.modelID)",
            "model.revision=\(parsed.modelRevision)",
            "model.family_adapter=\(parsed.familyAdapter)",
            "artifacts.target.sha256=\(parsed.artifacts["target"]?.sha256 ?? "")",
            "artifacts.mtp.sha256=\(parsed.artifacts["mtp"]?.sha256 ?? "")",
            "artifacts.tokenizer.sha256=\(parsed.artifacts["tokenizer"]?.sha256 ?? "")",
            "artifacts.manifest.sha256=\(parsed.artifacts["manifest"]?.sha256 ?? "")",
            "mtp.manifest_sha256=\(parsed.mtpManifestSHA256)",
            "mtp.source_layout=\(parsed.sourceLayout)",
            "mtp.prediction_layer_count=\(parsed.predictionLayerCount)",
            "mtp.max_proposal_depth=\(parsed.maxProposalDepth)",
            "mtp.complete_window_bytes_by_depth=\(parsed.completeWindowBytesByDepth.map(String.init).joined(separator: ","))",
            "mtp.throughput_delta_ppm=\(parsed.throughputDeltaPPM)",
            "mtp.adaptation_enabled=\(parsed.adaptationEnabled)",
            "mtp.adaptation_max_depth=\(parsed.adaptationMaxDepth)",
            "quantization.target=\(parsed.quantization.target)",
            "quantization.mtp=\(parsed.quantization.mtp)",
            "cache_state.cache_class=\(parsed.cacheClass)",
            "cache_state.state_class=\(parsed.stateClass)",
            "revisions.provider=\(parsed.providerRevision)",
            "revisions.upstream_mlx_swift_lm=\(parsed.upstreamMLXSwiftLMRevision)",
            "hardware.chip=\(parsed.hardwareChip)",
            "hardware.ram_gb=\(parsed.ramGB)",
            "hardware.os_version=\(parsed.osVersion)",
            "hardware.qualified_slots=\(parsed.qualifiedSlots)",
            "hardware.max_slots=\(parsed.maxSlots)",
            "request_profile.text_only=\(parsed.requestProfile.textOnly)",
            "request_profile.streaming=\(parsed.requestProfile.streaming)",
            "request_profile.tools=\(parsed.requestProfile.tools)",
            "request_profile.structured_outputs=\(parsed.requestProfile.structuredOutputs)",
            "request_profile.logprobs=\(parsed.requestProfile.logprobs)",
            "request_profile.penalties=\(parsed.requestProfile.penalties)",
            "request_profile.conversation_cache=\(parsed.requestProfile.conversationCache)",
            "request_profile.disk_cache=\(parsed.requestProfile.diskCache)",
            "request_profile.max_prompt_tokens=\(parsed.requestProfile.maxPromptTokens)",
            "request_profile.max_completion_tokens=\(parsed.requestProfile.maxCompletionTokens)",
            "spec023.release_id=\(parsed.spec023.releaseID)",
            "spec023.source_commit=\(parsed.spec023.sourceCommit)",
            "spec023.reproducible_build_sha256=\(parsed.spec023.reproducibleBuildSHA256)",
            "spec023.live_executable_cdhash=\(parsed.spec023.liveExecutableCDHash)",
            "spec023.benchmark_policy_sha256=\(parsed.spec023.benchmarkPolicySHA256)",
            "selftest.release_id=\(parsed.selfTest.releaseID)",
            "selftest.challenge_bank_path=\(parsed.selfTest.challengeBankPath)",
            "selftest.challenge_bank_sha256=\(parsed.selfTest.challengeBankSHA256)",
            "selftest.signature_path=\(parsed.selfTest.signaturePath)",
            "selftest.signer_key_id=\(parsed.selfTest.signerKeyID)",
            "selftest.signature_sha256=\(parsed.selfTest.signatureSHA256)",
            "flags.admission_allowed=\(parsed.admissionAllowed)",
        ]
        if let representationManifestSHA256 = parsed.quantization.representationManifestSHA256 {
            fields.append("quantization.block_size_elements=\(parsed.quantization.blockSizeElements!)")
            fields.append("quantization.representation_manifest_sha256=\(representationManifestSHA256)")
            fields.append("quantization.per_layer_exceptions=\(parsed.quantization.perLayerExceptions.joined(separator: ","))")
            fields.append("quantization.unquantized_exceptions=\(parsed.quantization.unquantizedExceptions.joined(separator: ","))")
        }
        fields.append(contentsOf: parsed.spec023.evidenceArtifactSHA256.enumerated().map { index, digest in
            "spec023.evidence_artifact_sha256.\(index)=\(digest)"
        })
        return sha256Hex(Data(fields.joined(separator: "\n").utf8))
    }

    private static func relativeArtifactPath(for url: URL, snapshotRoot root: URL) -> String {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(resolvedPath.dropFirst(rootPath.count))
    }

    private static func rejectUnknown(_ object: [String: NativeMTPSidecarJSON], allowed: Set<String>, path: String) throws {
        for key in object.keys where !allowed.contains(key) {
            throw NativeMTPAdmissionSidecarError.unknownField("\(path).\(key)")
        }
        for key in allowed where object[key] == nil {
            throw NativeMTPAdmissionSidecarError.missingField("\(path).\(key)")
        }
    }

    private static func rejectUnknownFields(
        _ object: [String: NativeMTPSidecarJSON],
        allowed: Set<String>,
        path: String
    ) throws {
        for key in object.keys where !allowed.contains(key) {
            throw NativeMTPAdmissionSidecarError.unknownField("\(path).\(key)")
        }
    }

    private static func requireObject(_ object: [String: NativeMTPSidecarJSON], _ key: String, path: String) throws -> [String: NativeMTPSidecarJSON] {
        guard let value = object[key] else { throw NativeMTPAdmissionSidecarError.missingField("\(path).\(key)") }
        guard case .object(let fields) = value else { throw NativeMTPAdmissionSidecarError.wrongType("\(path).\(key)") }
        return fields
    }

    @discardableResult
    private static func requireString(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String,
        equals expected: String
    ) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard value == expected else { throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)") }
        return value
    }

    private static func requireString(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String,
        allowed: Set<String>
    ) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard allowed.contains(value) else { throw NativeMTPAdmissionSidecarError.unsupported("\(path).\(key)") }
        return value
    }

    private static func requireNonEmptyString(_ object: [String: NativeMTPSidecarJSON], _ key: String, path: String) throws -> String {
        guard let value = object[key] else { throw NativeMTPAdmissionSidecarError.missingField("\(path).\(key)") }
        guard case .string(let string) = value else { throw NativeMTPAdmissionSidecarError.wrongType("\(path).\(key)") }
        guard !string.isEmpty, string == string.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return string
    }

    private static func requireASCIIString(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String,
        range: ClosedRange<Int>
    ) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard range.contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func requireShortString(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String
    ) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard (1...128).contains(value.utf8.count),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func requireArtifactID(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String
    ) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard value.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func requireHardwareClass(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String
    ) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard value.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil,
              value == canonicalHardwareClass(value) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func requireRFC3339UTCSeconds(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String
    ) throws -> Date {
        let value = try requireNonEmptyString(object, key, path: path)
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return date
    }

    private static func requireStringArray(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String,
        range: ClosedRange<Int>
    ) throws -> [String] {
        guard let value = object[key] else { throw NativeMTPAdmissionSidecarError.missingField("\(path).\(key)") }
        guard case .array(let array) = value else { throw NativeMTPAdmissionSidecarError.wrongType("\(path).\(key)") }
        guard range.contains(array.count) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return try array.enumerated().map { index, value in
            guard case .string(let string) = value, !string.isEmpty, string.utf8.count <= 128 else {
                throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)[\(index)]")
            }
            return string
        }
    }

    private static func requireNullableInt(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String,
        range: ClosedRange<Int>
    ) throws -> Int? {
        guard let value = object[key] else { throw NativeMTPAdmissionSidecarError.missingField("\(path).\(key)") }
        if value == .null { return nil }
        guard case .int(let int) = value, range.contains(int) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return int
    }

    private static func requirePatternArray(
        _ object: [String: NativeMTPSidecarJSON],
        _ key: String,
        path: String
    ) throws -> [String] {
        let values = try requireStringArray(object, key, path: path, range: 0...256)
        guard values == values.sorted(), Set(values).count == values.count else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        for value in values {
            guard (1...128).contains(value.utf8.count),
                  value.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) else {
                throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
            }
        }
        return values
    }

    private static func validateQuantizationExceptionArray(
        _ values: [String],
        key: String,
        path: String
    ) throws {
        for value in values {
            let module: Substring
            if value.hasPrefix("target/") {
                module = value.dropFirst("target/".count)
            } else if value.hasPrefix("mtp/") {
                module = value.dropFirst("mtp/".count)
            } else {
                throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
            }
            guard (1...128).contains(module.utf8.count), !module.contains("/") else {
                throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
            }
        }
    }

    private static func requireRelativeArtifactPath(_ object: [String: NativeMTPSidecarJSON], _ key: String, path: String) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard !value.contains("://"),
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NativeMTPAdmissionSidecarError.pathRejected(value)
        }
        return value
    }

    private static func requireSHA256(_ object: [String: NativeMTPSidecarJSON], _ key: String, path: String) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard isLowercaseSHA256(value) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func requireSHA256Array(_ object: [String: NativeMTPSidecarJSON], _ key: String, path: String) throws -> [String] {
        guard let value = object[key] else { throw NativeMTPAdmissionSidecarError.missingField("\(path).\(key)") }
        guard case .array(let values) = value else { throw NativeMTPAdmissionSidecarError.wrongType("\(path).\(key)") }
        return try values.enumerated().map { index, entry in
            guard case .string(let digest) = entry, isLowercaseSHA256(digest) else {
                throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)[\(index)]")
            }
            return digest
        }
    }

    private static func requireCommitSHA(_ object: [String: NativeMTPSidecarJSON], _ key: String, path: String) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard value.utf8.count == 40,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func requireCDHash(_ object: [String: NativeMTPSidecarJSON], _ key: String, path: String) throws -> String {
        let value = try requireNonEmptyString(object, key, path: path)
        guard value.utf8.count == 40,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        return value
    }

    private static func requireBool(_ object: [String: NativeMTPSidecarJSON], _ key: String, path: String) throws -> Bool {
        guard let value = object[key] else { throw NativeMTPAdmissionSidecarError.missingField("\(path).\(key)") }
        guard case .bool(let bool) = value else { throw NativeMTPAdmissionSidecarError.wrongType("\(path).\(key)") }
        return bool
    }

    private static func requireInt(_ object: [String: NativeMTPSidecarJSON], _ key: String, path: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = object[key] else { throw NativeMTPAdmissionSidecarError.missingField("\(path).\(key)") }
        guard case .int(let int) = value else { throw NativeMTPAdmissionSidecarError.wrongType("\(path).\(key)") }
        guard range.contains(int) else { throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)") }
        return int
    }

    private static func requireCompleteWindowBytesByDepth(
        _ object: [String: NativeMTPSidecarJSON],
        key: String,
        path: String,
        maxProposalDepth: Int
    ) throws -> [Int] {
        guard let value = object[key] else { throw NativeMTPAdmissionSidecarError.missingField("\(path).\(key)") }
        guard case .array(let entries) = value else { throw NativeMTPAdmissionSidecarError.wrongType("\(path).\(key)") }
        guard entries.count == maxProposalDepth + 1 else {
            throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)")
        }
        var values: [Int] = []
        values.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            guard case .int(let bytes) = entry, bytes > 0 else {
                throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)[\(index)]")
            }
            if let previous = values.last, bytes < previous {
                throw NativeMTPAdmissionSidecarError.invalidValue("\(path).\(key)[\(index)]")
            }
            values.append(bytes)
        }
        return values
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension NativeMTPSidecarJSON {
    var objectValue: [String: NativeMTPSidecarJSON]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    func jcsValue() throws -> RFC8785JCS.Value {
        switch self {
        case .object(let object):
            return .object(try object.mapValues { try $0.jcsValue() })
        case .array(let array):
            return .array(try array.map { try $0.jcsValue() })
        case .string(let string):
            return .string(string)
        case .int(let int):
            return .int(int)
        case .bool(let bool):
            return .bool(bool)
        case .null:
            return .null
        }
    }
}

private enum NativeMTPSidecarJSON: Equatable {
    case object([String: NativeMTPSidecarJSON])
    case array([NativeMTPSidecarJSON])
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
}

private enum NativeMTPSidecarJSONParser {
    static func parse(_ text: String) throws -> NativeMTPSidecarJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.parseValue(depth: 1)
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw ParseError.trailingData }
        return value
    }

    enum ParseError: Error, Equatable {
        case unexpectedEnd
        case unexpectedCharacter
        case invalidString
        case invalidNumber
        case duplicateKey(String)
        case trailingData
        case tooDeep
    }

    private struct Parser {
        var scalars: [UnicodeScalar]
        var index = 0
        let maxDepth = 32

        var isAtEnd: Bool { index >= scalars.count }

        mutating func parseValue(depth: Int) throws -> NativeMTPSidecarJSON {
            guard depth <= maxDepth else { throw ParseError.tooDeep }
            skipWhitespace()
            guard !isAtEnd else { throw ParseError.unexpectedEnd }
            switch scalars[index] {
            case "{": return try parseObject(depth: depth)
            case "[": return try parseArray(depth: depth)
            case "\"": return .string(try parseString())
            case "t":
                try consumeLiteral("true")
                return .bool(true)
            case "f":
                try consumeLiteral("false")
                return .bool(false)
            case "n":
                try consumeLiteral("null")
                return .null
            default:
                return .int(try parseInteger())
            }
        }

        mutating func parseObject(depth: Int) throws -> NativeMTPSidecarJSON {
            try consume("{")
            skipWhitespace()
            var object: [String: NativeMTPSidecarJSON] = [:]
            guard !consumeIf("}") else { return .object(object) }
            while true {
                skipWhitespace()
                guard peek() == "\"" else { throw ParseError.unexpectedCharacter }
                let key = try parseString()
                guard object[key] == nil else { throw ParseError.duplicateKey(key) }
                skipWhitespace()
                try consume(":")
                object[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf("}") { return .object(object) }
                try consume(",")
            }
        }

        mutating func parseArray(depth: Int) throws -> NativeMTPSidecarJSON {
            try consume("[")
            skipWhitespace()
            var array: [NativeMTPSidecarJSON] = []
            guard !consumeIf("]") else { return .array(array) }
            while true {
                array.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                if consumeIf("]") { return .array(array) }
                try consume(",")
            }
        }

        mutating func parseString() throws -> String {
            try consume("\"")
            var result = String.UnicodeScalarView()
            while !isAtEnd {
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" { return String(result) }
                if scalar == "\\" {
                    guard !isAtEnd else { throw ParseError.invalidString }
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "\"", "\\", "/": result.append(escaped)
                    case "b": result.append(UnicodeScalar(0x08)!)
                    case "f": result.append(UnicodeScalar(0x0c)!)
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u": result.append(try parseUnicodeEscape())
                    default: throw ParseError.invalidString
                    }
                    continue
                }
                guard scalar.value >= 0x20 else { throw ParseError.invalidString }
                result.append(scalar)
            }
            throw ParseError.unexpectedEnd
        }

        mutating func parseInteger() throws -> Int {
            let start = index
            _ = consumeIf("-")
            if consumeIf("0") {
                if let scalar = peek(), scalar.value >= 48, scalar.value <= 57 {
                    throw ParseError.invalidNumber
                }
            } else {
                try consumeDigit1to9()
                while consumeDigit() {}
            }
            if consumeIf(".") || consumeIf("e") || consumeIf("E") {
                throw ParseError.invalidNumber
            }
            let literal = String(String.UnicodeScalarView(scalars[start..<index]))
            guard let int = Int(literal) else { throw ParseError.invalidNumber }
            return int
        }

        mutating func parseUnicodeEscape() throws -> UnicodeScalar {
            let first = try parseHexQuad()
            if (0xd800 ... 0xdbff).contains(first) {
                guard try consumeUnicodeEscapePrefixIfPresent() else { throw ParseError.invalidString }
                let second = try parseHexQuad()
                guard (0xdc00 ... 0xdfff).contains(second) else { throw ParseError.invalidString }
                let combined = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
                guard let scalar = UnicodeScalar(combined) else { throw ParseError.invalidString }
                return scalar
            }
            guard !(0xdc00 ... 0xdfff).contains(first), let scalar = UnicodeScalar(first) else {
                throw ParseError.invalidString
            }
            return scalar
        }

        mutating func parseHexQuad() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw ParseError.invalidString }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let scalar = scalars[index]
                index += 1
                value <<= 4
                switch scalar.value {
                case 48 ... 57: value += scalar.value - 48
                case 65 ... 70: value += scalar.value - 55
                case 97 ... 102: value += scalar.value - 87
                default: throw ParseError.invalidString
                }
            }
            return value
        }

        mutating func consumeDigit1to9() throws {
            guard !isAtEnd, scalars[index].value >= 49, scalars[index].value <= 57 else {
                throw ParseError.invalidNumber
            }
            index += 1
        }

        mutating func consumeDigit() -> Bool {
            guard !isAtEnd, scalars[index].value >= 48, scalars[index].value <= 57 else { return false }
            index += 1
            return true
        }

        mutating func consumeLiteral(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                try consume(scalar)
            }
        }

        mutating func consume(_ expected: UnicodeScalar) throws {
            guard !isAtEnd, scalars[index] == expected else { throw ParseError.unexpectedCharacter }
            index += 1
        }

        mutating func consumeIf(_ expected: UnicodeScalar) -> Bool {
            guard !isAtEnd, scalars[index] == expected else { return false }
            index += 1
            return true
        }

        mutating func consumeUnicodeEscapePrefixIfPresent() throws -> Bool {
            guard index + 2 <= scalars.count,
                  scalars[index] == "\\",
                  scalars[index + 1] == "u" else {
                return false
            }
            index += 2
            return true
        }

        func peek() -> UnicodeScalar? {
            isAtEnd ? nil : scalars[index]
        }

        mutating func skipWhitespace() {
            while !isAtEnd {
                switch scalars[index] {
                case " ", "\n", "\r", "\t": index += 1
                default: return
                }
            }
        }
    }
}
