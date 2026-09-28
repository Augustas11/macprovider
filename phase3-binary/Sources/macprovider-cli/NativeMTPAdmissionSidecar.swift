import CryptoKit
import Darwin
import Foundation

struct NativeMTPAdmissionCapability: Equatable, Sendable {
    let tupleSHA256: String
    let modelID: String
    let modelRevision: String
    let targetArtifactSHA256: String
    let mtpArtifactSHA256: String
    let tokenizerSHA256: String
    let mtpManifestSHA256: String
    let familyAdapter: String
    let maxProposalDepth: Int
    let cacheClass: String
    let stateClass: String
    let quantization: NativeMTPAdmissionSidecar.Quantization
    let providerRevision: String
    let upstreamMLXSwiftLMRevision: String
    let qualifiedSlots: Int
    let spec023ReleaseID: String
    let spec023SourceCommit: String
    let spec023BuildDigestSHA256: String
    let evidenceArtifactSHA256: [String]
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
        case .artifactDigestMismatch(let name): return "artifact digest mismatch: \(name)"
        case .liveTupleMismatch(let field): return "live tuple mismatch: \(field)"
        case .signatureInvalid(let reason): return "signature invalid: \(reason)"
        }
    }
}

enum NativeMTPAdmissionSidecar {
    static let schemaVersion = "macprovider.native-mtp-admission.v1"

    struct RuntimeContext: Equatable, Sendable {
        let modelID: String
        let modelRevision: String
        let providerRevision: String
        let upstreamMLXSwiftLMRevision: String
        let hardwareChip: String
        let ramGB: Int
        let osVersion: String
        let slotCount: Int
        let revokedTupleSHA256: Set<String>?

        init(
            modelID: String,
            modelRevision: String,
            providerRevision: String,
            upstreamMLXSwiftLMRevision: String,
            hardwareChip: String,
            ramGB: Int,
            osVersion: String,
            slotCount: Int,
            revokedTupleSHA256: Set<String>?
        ) {
            self.modelID = modelID
            self.modelRevision = modelRevision
            self.providerRevision = providerRevision
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
        let decodePath: String
        let admissionEnabled: Bool
        let modelID: String
        let modelRevision: String
        let familyAdapter: String
        let artifacts: [String: Artifact]
        let mtpManifestSHA256: String
        let maxProposalDepth: Int
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
        let requestProfile: RequestProfile
        let spec023: Spec023
        let admissionAllowed: Bool
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
    }

    private struct Spec023: Equatable {
        let releaseID: String
        let sourceCommit: String
        let reproducibleBuildSHA256: String
        let benchmarkPolicySHA256: String
        let nativeMTPAdmissionTupleSHA256: String
        let evidenceArtifactSHA256: [String]
    }

    static func load(
        sidecarURL: URL,
        signatureURL: URL,
        snapshotRoot: URL,
        context: RuntimeContext,
        trustedKeyring: TrustedKeyring,
        fileManager: FileManager = .default
    ) throws -> NativeMTPAdmissionCapability {
        let bytes = try Data(contentsOf: sidecarURL)
        let signatureBytes = try Data(contentsOf: signatureURL)
        return try load(
            sidecarData: bytes,
            signatureData: signatureBytes,
            snapshotRoot: snapshotRoot,
            context: context,
            trustedKeyring: trustedKeyring,
            fileManager: fileManager
        )
    }

    static func load(
        sidecarData: Data,
        signatureData: Data,
        snapshotRoot: URL,
        context: RuntimeContext,
        trustedKeyring: TrustedKeyring,
        fileManager: FileManager = .default
    ) throws -> NativeMTPAdmissionCapability {
        try verifyDetachedSignature(payload: sidecarData, signatureData: signatureData, trustedKeyring: trustedKeyring)
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
        let parsed = try parseRoot(root)
        try validateStaticSupport(parsed)
        try validateLiveTuple(parsed, context: context)
        try validateRevocation(parsed, context: context)
        try validateArtifacts(parsed.artifacts, snapshotRoot: snapshotRoot, fileManager: fileManager)
        return NativeMTPAdmissionCapability(
            tupleSHA256: parsed.tupleSHA256,
            modelID: parsed.modelID,
            modelRevision: parsed.modelRevision,
            targetArtifactSHA256: parsed.artifacts["target"]!.sha256,
            mtpArtifactSHA256: parsed.artifacts["mtp"]!.sha256,
            tokenizerSHA256: parsed.artifacts["tokenizer"]!.sha256,
            mtpManifestSHA256: parsed.mtpManifestSHA256,
            familyAdapter: parsed.familyAdapter,
            maxProposalDepth: parsed.maxProposalDepth,
            cacheClass: parsed.cacheClass,
            stateClass: parsed.stateClass,
            quantization: parsed.quantization,
            providerRevision: parsed.providerRevision,
            upstreamMLXSwiftLMRevision: parsed.upstreamMLXSwiftLMRevision,
            qualifiedSlots: parsed.qualifiedSlots,
            spec023ReleaseID: parsed.spec023.releaseID,
            spec023SourceCommit: parsed.spec023.sourceCommit,
            spec023BuildDigestSHA256: parsed.spec023.reproducibleBuildSHA256,
            evidenceArtifactSHA256: parsed.spec023.evidenceArtifactSHA256
        )
    }

    private static func parseRoot(_ object: [String: NativeMTPSidecarJSON]) throws -> Parsed {
        try rejectUnknown(object, allowed: [
            "schema_version", "tuple_sha256", "decode_path", "admission_enabled",
            "model", "artifacts", "mtp", "quantization", "cache_state",
            "revisions", "hardware", "request_profile", "spec023", "flags",
        ], path: "$")
        try requireString(object, "schema_version", path: "$", equals: schemaVersion)
        let model = try requireObject(object, "model", path: "$")
        try rejectUnknown(model, allowed: ["id", "revision", "family_adapter"], path: "$.model")

        let artifacts = try parseArtifacts(try requireObject(object, "artifacts", path: "$"))
        let mtp = try requireObject(object, "mtp", path: "$")
        try rejectUnknown(mtp, allowed: [
            "manifest_sha256", "source_layout", "prediction_layer_count",
            "max_proposal_depth", "adaptation_enabled", "adaptation_max_depth",
        ], path: "$.mtp")
        _ = try requireString(mtp, "source_layout", path: "$.mtp", allowed: ["checkpoint_mtp", "config_next_n", "separate_artifact"])
        _ = try requireInt(mtp, "prediction_layer_count", path: "$.mtp", range: 1...64)

        let quantization = try requireObject(object, "quantization", path: "$")
        try rejectUnknown(quantization, allowed: ["target", "mtp"], path: "$.quantization")
        let cacheState = try requireObject(object, "cache_state", path: "$")
        try rejectUnknown(cacheState, allowed: ["cache_class", "state_class"], path: "$.cache_state")
        let revisions = try requireObject(object, "revisions", path: "$")
        try rejectUnknown(revisions, allowed: ["provider", "upstream_mlx_swift_lm"], path: "$.revisions")
        let hardware = try requireObject(object, "hardware", path: "$")
        try rejectUnknown(hardware, allowed: ["chip", "ram_gb", "os_version", "qualified_slots", "max_slots"], path: "$.hardware")
        let requestProfile = try parseRequestProfile(try requireObject(object, "request_profile", path: "$"))
        let spec023 = try parseSpec023(try requireObject(object, "spec023", path: "$"))
        let flags = try requireObject(object, "flags", path: "$")
        try rejectUnknown(flags, allowed: ["admission_allowed"], path: "$.flags")

        return Parsed(
            tupleSHA256: try requireSHA256(object, "tuple_sha256", path: "$"),
            decodePath: try requireString(object, "decode_path", path: "$", allowed: ["native_mtp"]),
            admissionEnabled: try requireBool(object, "admission_enabled", path: "$"),
            modelID: try requireNonEmptyString(model, "id", path: "$.model"),
            modelRevision: try requireNonEmptyString(model, "revision", path: "$.model"),
            familyAdapter: try requireNonEmptyString(model, "family_adapter", path: "$.model"),
            artifacts: artifacts,
            mtpManifestSHA256: try requireSHA256(mtp, "manifest_sha256", path: "$.mtp"),
            maxProposalDepth: try requireInt(mtp, "max_proposal_depth", path: "$.mtp", range: 1...16),
            adaptationEnabled: try requireBool(mtp, "adaptation_enabled", path: "$.mtp"),
            adaptationMaxDepth: try requireInt(mtp, "adaptation_max_depth", path: "$.mtp", range: 1...16),
            quantization: Quantization(
                target: try requireString(
                    quantization,
                    "target",
                    path: "$.quantization",
                    allowed: ["bf16", "fp16", "mlx_affine_4bit", "mlx_mxfp8"]
                ),
                mtp: try requireString(
                    quantization,
                    "mtp",
                    path: "$.quantization",
                    allowed: ["bf16", "fp16", "mlx_affine_4bit", "mlx_mxfp8"]
                )
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
            requestProfile: requestProfile,
            spec023: spec023,
            admissionAllowed: try requireBool(flags, "admission_allowed", path: "$.flags")
        )
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
            benchmarkPolicySHA256: try requireSHA256(object, "benchmark_policy_sha256", path: "$.spec023"),
            nativeMTPAdmissionTupleSHA256: try requireSHA256(object, "native_mtp_admission_tuple_sha256", path: "$.spec023"),
            evidenceArtifactSHA256: evidence
        )
    }

    private static func validateStaticSupport(_ parsed: Parsed) throws {
        guard parsed.decodePath == "native_mtp", parsed.admissionEnabled, parsed.admissionAllowed else {
            throw NativeMTPAdmissionSidecarError.unsupported("admission flags")
        }
        guard parsed.tupleSHA256 == parsed.spec023.nativeMTPAdmissionTupleSHA256 else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.spec023.native_mtp_admission_tuple_sha256")
        }
        guard parsed.tupleSHA256 == admissionTupleSHA256(parsed) else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.tuple_sha256")
        }
        guard parsed.mtpManifestSHA256 == parsed.artifacts["manifest"]?.sha256 else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.mtp.manifest_sha256")
        }
        guard parsed.adaptationEnabled, parsed.adaptationMaxDepth <= parsed.maxProposalDepth else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.mtp.adaptation_max_depth")
        }
        guard parsed.qualifiedSlots <= parsed.maxSlots else {
            throw NativeMTPAdmissionSidecarError.invalidValue("$.hardware.qualified_slots")
        }
        guard parsed.requestProfile.textOnly,
              !parsed.requestProfile.streaming,
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
        guard parsed.providerRevision == context.providerRevision else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.revisions.provider") }
        guard parsed.upstreamMLXSwiftLMRevision == context.upstreamMLXSwiftLMRevision else {
            throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.revisions.upstream_mlx_swift_lm")
        }
        guard parsed.hardwareChip == context.hardwareChip else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.hardware.chip") }
        guard parsed.ramGB == context.ramGB else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.hardware.ram_gb") }
        guard parsed.osVersion == context.osVersion else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.hardware.os_version") }
        guard parsed.qualifiedSlots == context.slotCount else { throw NativeMTPAdmissionSidecarError.liveTupleMismatch("$.hardware.qualified_slots") }
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
        fileManager: FileManager
    ) throws {
        let root = snapshotRoot.standardizedFileURL
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(".")
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw NativeMTPAdmissionSidecarError.pathRejected(root.path)
        }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw NativeMTPAdmissionSidecarError.artifactNotFound(".")
        }
        defer { close(rootFD) }
        var manifestedDirectories: Set<String> = []
        for (name, artifact) in artifacts {
            let url = root.appendingPathComponent(artifact.path, isDirectory: false)
            let standardized = url.standardizedFileURL
            guard BYOMArtifactPathPolicy.isContained(standardized, in: root) else {
                throw NativeMTPAdmissionSidecarError.pathRejected(artifact.path)
            }
            let validated = try digestOpeningArtifactNoFollow(
                relativePath: artifact.path,
                root: root,
                rootFD: rootFD
            )
            if validated.isDirectory {
                manifestedDirectories.insert(artifact.path)
            }
            let digest = validated.sha256
            guard digest == artifact.sha256 else {
                throw NativeMTPAdmissionSidecarError.artifactDigestMismatch(name)
            }
        }
        try rejectUnmanifestedSnapshotArtifacts(
            snapshotRoot: root,
            manifestedPaths: Set(artifacts.values.map(\.path)),
            manifestedDirectories: manifestedDirectories,
            fileManager: fileManager
        )
    }

    private static func digestOpeningArtifactNoFollow(
        relativePath: String,
        root: URL,
        rootFD: Int32
    ) throws -> (sha256: String, isDirectory: Bool) {
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
            currentFD = nextFD
            fdsToClose.append(nextFD)
        }
        let artifactFD = openat(currentFD, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard artifactFD >= 0 else {
            if errno == ENOENT {
                throw NativeMTPAdmissionSidecarError.artifactNotFound(relativePath)
            }
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        var st = stat()
        guard fstat(artifactFD, &st) == 0 else {
            close(artifactFD)
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            close(artifactFD)
            let directory = root.appendingPathComponent(relativePath, isDirectory: true)
            let identity = try MLXSnapshotIdentity.compute(directory: directory)
            return (identity.digest, true)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else {
            close(artifactFD)
            throw NativeMTPAdmissionSidecarError.artifactNotRegularFile(relativePath)
        }
        let handle = FileHandle(fileDescriptor: artifactFD, closeOnDealloc: true)
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        return (sha256Hex(data), false)
    }

    private static func rejectUnmanifestedSnapshotArtifacts(
        snapshotRoot root: URL,
        manifestedPaths: Set<String>,
        manifestedDirectories: Set<String>,
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
        trustedKeyring: TrustedKeyring
    ) throws {
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
        guard keyID == trustedKeyring.requiredKeyID else {
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
    }

    static func admissionTupleSHA256ForTesting(_ object: [String: Any]) throws -> String {
        guard let parsedObject = try NativeMTPSidecarJSONParser.parse(
            String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
        ).objectValue else {
            throw NativeMTPAdmissionSidecarError.wrongType("$")
        }
        return try admissionTupleSHA256(parseRoot(parsedObject))
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
            "mtp.max_proposal_depth=\(parsed.maxProposalDepth)",
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
            "spec023.benchmark_policy_sha256=\(parsed.spec023.benchmarkPolicySHA256)",
            "flags.admission_allowed=\(parsed.admissionAllowed)",
        ]
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
