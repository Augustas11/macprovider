import ArgumentParser
import Darwin
import Foundation
import MacProviderCore

/// Build 1 Lane A measured artifact-bound staging input.
///
/// `models staging-input` ties three already-landed evidence sources together
/// into one machine-readable handoff for the physical Apple Silicon staging
/// journey:
///
/// 1. the signed Lane A artifact authority fetched from the staging artifact
///    feed (measured `size_bytes`, trusted signer, release-bound);
/// 2. the durable adopted artifact and its private publication receipt; and
/// 3. the local `GET /v1/status` Lane A evidence correlation.
///
/// The report is `staging_input_ready` only when every source is present and
/// each one names the same tuple, release, digest, and private record. Any
/// missing or mismatched source yields `blocked` with explicit blocker codes.
/// The report is a staging input, never acceptance: it grants no admission,
/// settlement, earnings, rewards, payouts, or production activation, and the
/// runtime correlation stays path-observed (no descriptor-pinned custody).
struct Build1LaneAStagingInput: Equatable, Sendable {
    static let schema = "build1_lane_a_staging_input.v1"
    static let observationScope = "path_observed"
    /// Remaining physical-journey steps after this input. Fixed vocabulary
    /// mirrored by the narrow MVP test spec; none of them run here.
    static let nextRequiredSteps = [
        "staging_admission",
        "staging_gateway_non_streaming_request",
        "provider_receipt_audit_correlation",
        "verified_settlement_retrieval",
        "evidence_bundle_validation",
    ]

    enum State: String, Sendable {
        case ready = "staging_input_ready"
        case blocked
    }

    struct ArtifactAuthority: Equatable, Sendable {
        enum State: String, Sendable {
            case verified
            case unavailable
            case mismatch
            case notEvaluated = "not_evaluated"
        }

        var state: State
        var reason: String
        var warnings: [String]
        var releaseID: String?
        var feedSHA256: String?
        var signerKeyID: String?
        var artifactHashAlgorithm: String?
        var artifactSHA256: String?
        var sizeBytes: Int?
        /// `true` only when the signed feed carried a positive measured
        /// `size_bytes` for the primary artifact; the resolver refuses
        /// anything else, so this is `false` whenever `state != .verified`.
        var measuredSize: Bool
    }

    struct PrivateRecord: Equatable, Sendable {
        enum State: String, Sendable {
            case recorded
            case missing
            case invalid
            case unavailable
            case sizeMismatch = "size_mismatch"
            case notEvaluated = "not_evaluated"
        }

        var state: State
        var reason: String
        var artifactIdentityDigest: String?
        var receiptSHA256: String?
        var rootIdentityDigest: String?
        var inventoryGeneration: Int?
        var publishedAt: String?
        var releaseID: String?
        var artifactSHA256: String?
        var estimatedBytes: Int64?
        var matchesAuthority: Bool
    }

    struct StatusCorrelation: Equatable, Sendable {
        enum Source: String, Sendable {
            case statusCaptureFile = "status_capture_file"
            case localStatusEndpoint = "local_status_endpoint"
            case unavailable
        }

        enum State: String, Sendable {
            case correlated
            case unbound
            case missing
            case invalid
            case mismatch
            case expired
            case unavailable
            case notEvaluated = "not_evaluated"
        }

        var source: Source
        var state: State
        var reason: String
        /// `observation.observed_at` / `observation.valid_for_ms` as the
        /// status body declared them; echoed so a blocked report shows why
        /// a capture was refused as stale.
        var observedAt: String?
        var validForMS: Int?
        var providerID: String?
        var providerStatus: String?
        var modelLoaded: Bool?
        var effectiveModel: String?
        var modelHash: String?
        var modelHashAlgorithm: String?
        var weightsManifestSHA256: String?
        var weightsManifestAlgorithm: String?
        var evidenceState: String?
        var evidenceReason: String?
        var matchesPrivateRecord: Bool
        var matchesAuthority: Bool
    }

    var state: State
    var blockers: [String]
    var generatedAt: String
    var authorityTuple: Build1LaneAArtifactAuthority?
    var artifactAuthority: ArtifactAuthority
    var privateRecord: PrivateRecord
    var statusCorrelation: StatusCorrelation

    func jsonObject() -> [String: Any] {
        let authority = artifactAuthority
        let record = privateRecord
        let status = statusCorrelation
        let tuple = authorityTuple
        let expected = tuple.flatMap { Build1PrepareProfileSupport.expectedTuple(for: $0.catalogKey) }
        return [
            "schema": Self.schema,
            "profile": tuple.flatMap { Build1PrepareProfileSupport.profile(for: $0) } ?? Build1LaneAPrepareProfile.profile,
            "state": state.rawValue,
            "blockers": blockers,
            "generated_at": generatedAt,
            "physical_acceptance": false,
            "artifact_authority": [
                "state": authority.state.rawValue,
                "reason": authority.reason,
                "warnings": authority.warnings,
                "release_id": Self.nullable(authority.releaseID),
                "feed_sha256": Self.nullable(authority.feedSHA256),
                "signer_key_id": Self.nullable(authority.signerKeyID),
                "artifact_hash_algorithm": Self.nullable(authority.artifactHashAlgorithm),
                "artifact_sha256": Self.nullable(authority.artifactSHA256),
                "size_bytes": authority.sizeBytes.map { $0 as Any } ?? NSNull(),
                "measured_size": authority.measuredSize,
            ],
            "private_record": [
                "state": record.state.rawValue,
                "reason": record.reason,
                "artifact_identity_digest": Self.nullable(record.artifactIdentityDigest),
                "receipt_sha256": Self.nullable(record.receiptSHA256),
                "root_identity_digest": Self.nullable(record.rootIdentityDigest),
                "inventory_generation": record.inventoryGeneration.map { $0 as Any } ?? NSNull(),
                "published_at": Self.nullable(record.publishedAt),
                "release_id": Self.nullable(record.releaseID),
                "artifact_sha256": Self.nullable(record.artifactSHA256),
                "estimated_bytes": record.estimatedBytes.map { $0 as Any } ?? NSNull(),
                "matches_authority": record.matchesAuthority,
            ],
            "status_correlation": [
                "source": status.source.rawValue,
                "state": status.state.rawValue,
                "reason": status.reason,
                "endpoint": "GET /v1/status",
                "observed_at": Self.nullable(status.observedAt),
                "valid_for_ms": status.validForMS.map { $0 as Any } ?? NSNull(),
                "provider_id": Self.nullable(status.providerID),
                "status": Self.nullable(status.providerStatus),
                "model_loaded": status.modelLoaded.map { $0 as Any } ?? NSNull(),
                "effective_model": Self.nullable(status.effectiveModel),
                "model_hash": Self.nullable(status.modelHash),
                "model_hash_algorithm": Self.nullable(status.modelHashAlgorithm),
                "weights_manifest_sha256": Self.nullable(status.weightsManifestSHA256),
                "weights_manifest_algorithm": Self.nullable(status.weightsManifestAlgorithm),
                "evidence_schema": ProviderBuild1LaneAStatusEvidence.schema,
                "evidence_state": Self.nullable(status.evidenceState),
                "evidence_reason": Self.nullable(status.evidenceReason),
                "matches_private_record": status.matchesPrivateRecord,
                "matches_authority": status.matchesAuthority,
                "runtime_custody": [
                    "descriptor_pinned_runtime_custody": false,
                    "observation_scope": Self.observationScope,
                ],
            ],
            "handoff": [
                "catalog_key": tuple?.catalogKey ?? Build1LaneAPrepareProfile.catalogKey,
                "model_id": tuple?.modelID ?? Build1LaneAPrepareProfile.artifactModelID,
                "model_revision": tuple?.revision ?? Build1LaneAPrepareProfile.artifactRevision,
                "artifact_id": tuple?.artifactID ?? Build1LaneAPrepareProfile.artifactID,
                "runtime_source": expected?.runtimeSource ?? Build1LaneAPrepareProfile.runtimeSource,
                "artifact_hash_algorithm": tuple?.hashAlgorithm ?? ModelArtifactIdentity.snapshotManifestV1,
                "artifact_sha256": tuple?.hash ?? Build1LaneAPrepareProfile.artifactHash,
                "release_id": Self.nullable(authority.releaseID),
                "size_bytes": authority.sizeBytes.map { $0 as Any } ?? NSNull(),
                "next_required_steps": Self.nextRequiredSteps,
            ],
            "proof_boundary": [
                "staging_input_only": true,
                "physical_acceptance": false,
                "local_preparation_only": true,
                "grants_admission": false,
                "grants_settlement": false,
                "production_activation": false,
                "rewards_or_payouts": false,
                "descriptor_pinned_runtime_custody": false,
            ],
        ]
    }

    func jsonLine() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func nullable(_ value: String?) -> Any {
        value ?? NSNull()
    }
}

/// How the local provider status was observed for the staging input.
enum Build1LaneAStatusObservation {
    /// A `GET /v1/status` JSON object, from a saved capture or the live
    /// local endpoint.
    case observed(source: Build1LaneAStagingInput.StatusCorrelation.Source, object: [String: Any])
    /// No status object could be obtained; `reason` is a blocker code.
    case unavailable(source: Build1LaneAStagingInput.StatusCorrelation.Source, reason: String)
    /// Status was not consulted because an earlier guard already blocked.
    case notEvaluated
}

enum Build1LaneAStagingInputAssembler {
    static let statusEvidenceKey = "build1_lane_a"

    /// `authority == nil` means the signed authority was never consulted
    /// because a guard refused first; `preconditionBlockers` carries those
    /// guard codes (and a config-load failure) ahead of the evidence blockers.
    static func assemble(
        authority: Result<Build1LaneAArtifactAuthority, Build1LaneAArtifactAuthorityError>?,
        privateRecord: ProviderBuild1LaneAStatusContext?,
        status: Build1LaneAStatusObservation,
        preconditionBlockers: [String] = [],
        now: Date = Date()
    ) -> Build1LaneAStagingInput {
        var blockers = preconditionBlockers

        let authoritySection = describeAuthority(authority)
        let resolvedAuthority = authority.flatMap { try? $0.get() }
        if resolvedAuthority == nil {
            blockers.append(authoritySection.reason)
        }

        let recordSection = describeRecord(privateRecord, authority: resolvedAuthority)
        if recordSection.state != .recorded || !recordSection.matchesAuthority {
            blockers.append(recordSection.reason)
        }

        let binding = recordSection.state == .recorded && recordSection.matchesAuthority
            ? privateRecord?.binding
            : nil
        let statusSection = describeStatus(status, authority: resolvedAuthority, binding: binding, now: now)
        if statusSection.state != .correlated {
            blockers.append(statusSection.reason)
        }

        var unique: [String] = []
        for blocker in blockers where !unique.contains(blocker) {
            unique.append(blocker)
        }
        return Build1LaneAStagingInput(
            state: unique.isEmpty ? .ready : .blocked,
            blockers: unique,
            generatedAt: ModelSwitchingWireCodec.timestamp(now),
            authorityTuple: resolvedAuthority,
            artifactAuthority: authoritySection,
            privateRecord: recordSection,
            statusCorrelation: statusSection
        )
    }

    // MARK: - Artifact authority

    static func describeAuthority(
        _ authority: Result<Build1LaneAArtifactAuthority, Build1LaneAArtifactAuthorityError>?
    ) -> Build1LaneAStagingInput.ArtifactAuthority {
        switch authority {
        case .none:
            return Build1LaneAStagingInput.ArtifactAuthority(
                state: .notEvaluated,
                reason: "artifact_authority_not_evaluated",
                warnings: [],
                releaseID: nil,
                feedSHA256: nil,
                signerKeyID: nil,
                artifactHashAlgorithm: nil,
                artifactSHA256: nil,
                sizeBytes: nil,
                measuredSize: false
            )
        case .success(let verified):
            return Build1LaneAStagingInput.ArtifactAuthority(
                state: .verified,
                reason: "artifact_authority_verified",
                warnings: [],
                releaseID: verified.releaseID,
                feedSHA256: verified.feedSHA256,
                signerKeyID: verified.feedSignerKeyID,
                artifactHashAlgorithm: verified.hashAlgorithm,
                artifactSHA256: verified.hash,
                sizeBytes: verified.sizeBytes,
                measuredSize: verified.sizeBytes > 0
            )
        case .failure(let error):
            let state: Build1LaneAStagingInput.ArtifactAuthority.State
            let reason: String
            var warnings: [String] = []
            switch error {
            case .stagingCoordinatorUnavailable:
                state = .unavailable
                reason = "staging_coordinator_required"
            case .staticCatalogUnavailable:
                state = .unavailable
                reason = "static_catalog_unavailable"
            case .staticCatalogTupleMismatch:
                state = .mismatch
                reason = "static_catalog_tuple_mismatch"
            case .artifactAuthorityUnavailable(let feedWarnings):
                state = .unavailable
                warnings = feedWarnings
                // An empty warning set means the staging coordinator served no
                // artifact feed at all; a non-empty set names the strict
                // validator refusal (unmeasured size, bad signature, stale,
                // cross-release, ...). Both are "no measured artifact-bound
                // staging input exists yet".
                reason = feedWarnings.isEmpty ? "artifact_feed_not_served" : "artifact_feed_rejected"
            case .artifactTupleMismatch:
                state = .mismatch
                reason = "artifact_tuple_mismatch"
            }
            return Build1LaneAStagingInput.ArtifactAuthority(
                state: state,
                reason: reason,
                warnings: warnings,
                releaseID: nil,
                feedSHA256: nil,
                signerKeyID: nil,
                artifactHashAlgorithm: nil,
                artifactSHA256: nil,
                sizeBytes: nil,
                measuredSize: false
            )
        }
    }

    // MARK: - Private record

    static func describeRecord(
        _ context: ProviderBuild1LaneAStatusContext?,
        authority: Build1LaneAArtifactAuthority?
    ) -> Build1LaneAStagingInput.PrivateRecord {
        guard let authority else {
            return Build1LaneAStagingInput.PrivateRecord(
                state: .notEvaluated,
                reason: "private_record_not_evaluated",
                artifactIdentityDigest: nil,
                receiptSHA256: nil,
                rootIdentityDigest: nil,
                inventoryGeneration: nil,
                publishedAt: nil,
                releaseID: nil,
                artifactSHA256: nil,
                estimatedBytes: nil,
                matchesAuthority: false
            )
        }
        guard let context else {
            return Build1LaneAStagingInput.PrivateRecord(
                state: .unavailable,
                reason: "private_record_unavailable",
                artifactIdentityDigest: nil,
                receiptSHA256: nil,
                rootIdentityDigest: nil,
                inventoryGeneration: nil,
                publishedAt: nil,
                releaseID: nil,
                artifactSHA256: nil,
                estimatedBytes: nil,
                matchesAuthority: false
            )
        }
        guard context.recordState == .recorded, let binding = context.binding else {
            let state: Build1LaneAStagingInput.PrivateRecord.State
            switch context.recordState {
            case .missing: state = .missing
            case .invalid: state = .invalid
            case .unavailable, .recorded: state = .unavailable
            }
            return Build1LaneAStagingInput.PrivateRecord(
                state: state,
                reason: context.reason,
                artifactIdentityDigest: nil,
                receiptSHA256: nil,
                rootIdentityDigest: nil,
                inventoryGeneration: nil,
                publishedAt: nil,
                releaseID: nil,
                artifactSHA256: nil,
                estimatedBytes: nil,
                matchesAuthority: false
            )
        }
        // The status reader already filtered on the exact profile tuple,
        // release, and digest. The measured feed size is the one input it
        // does not check: a receipt written against a different declared size
        // is not evidence for this measured staging input.
        let matches = binding.artifactSHA256 == authority.hash
            && binding.releaseID == authority.releaseID
            && binding.displayModelID == authority.modelID
            && binding.modelRevision == authority.revision
            && binding.artifactID == authority.artifactID
            && binding.estimatedBytes == Int64(authority.sizeBytes)
        return Build1LaneAStagingInput.PrivateRecord(
            state: matches ? .recorded : .sizeMismatch,
            reason: matches ? context.reason : "private_record_size_mismatch",
            artifactIdentityDigest: binding.artifactIdentityDigest,
            receiptSHA256: binding.receiptSHA256,
            rootIdentityDigest: binding.rootIdentityDigest,
            inventoryGeneration: binding.inventoryGeneration,
            publishedAt: binding.publishedAt,
            releaseID: binding.releaseID,
            artifactSHA256: binding.artifactSHA256,
            estimatedBytes: binding.estimatedBytes,
            matchesAuthority: matches
        )
    }

    // MARK: - Status correlation

    /// A status body is only evidence while its own observation window is
    /// open. `now` is the command time; a saved capture whose
    /// `observed_at + valid_for_ms` lies before it is a replay, not a
    /// measurement of the provider that is serving right now.
    static func describeStatus(
        _ observation: Build1LaneAStatusObservation,
        authority: Build1LaneAArtifactAuthority?,
        binding: Build1LaneAStatusArtifactBinding?,
        now: Date = Date()
    ) -> Build1LaneAStagingInput.StatusCorrelation {
        let source: Build1LaneAStagingInput.StatusCorrelation.Source
        let object: [String: Any]
        switch observation {
        case .notEvaluated, .unavailable:
            let observedSource: Build1LaneAStagingInput.StatusCorrelation.Source
            let state: Build1LaneAStagingInput.StatusCorrelation.State
            let reason: String
            if case .unavailable(let source, let unavailableReason) = observation {
                observedSource = source
                state = .unavailable
                reason = unavailableReason
            } else {
                observedSource = .unavailable
                state = .notEvaluated
                reason = "status_not_evaluated"
            }
            return Build1LaneAStagingInput.StatusCorrelation(
                source: observedSource,
                state: state,
                reason: reason,
                observedAt: nil,
                validForMS: nil,
                providerID: nil,
                providerStatus: nil,
                modelLoaded: nil,
                effectiveModel: nil,
                modelHash: nil,
                modelHashAlgorithm: nil,
                weightsManifestSHA256: nil,
                weightsManifestAlgorithm: nil,
                evidenceState: nil,
                evidenceReason: nil,
                matchesPrivateRecord: false,
                matchesAuthority: false
            )
        case .observed(let observedSource, let observedObject):
            source = observedSource
            object = observedObject
        }

        let evidence = object[statusEvidenceKey] as? [String: Any]
        let observationBlock = object["observation"] as? [String: Any]
        var section = Build1LaneAStagingInput.StatusCorrelation(
            source: source,
            state: .notEvaluated,
            reason: "status_not_evaluated",
            observedAt: string(observationBlock?["observed_at"]),
            validForMS: observationBlock?["valid_for_ms"] as? Int,
            providerID: string(object["provider_id"]),
            providerStatus: string(object["status"]),
            modelLoaded: object["model_loaded"] as? Bool,
            effectiveModel: string(object["model"]),
            modelHash: string(object["model_hash"]),
            modelHashAlgorithm: string(object["model_hash_algorithm"]),
            weightsManifestSHA256: string(object["weights_manifest_sha256"]),
            weightsManifestAlgorithm: string(object["weights_manifest_algorithm"]),
            evidenceState: string(evidence?["state"]),
            evidenceReason: string(evidence?["reason"]),
            matchesPrivateRecord: false,
            matchesAuthority: false
        )

        guard let authority, let binding else {
            return section
        }
        switch validateStatusObservation(object, now: now) {
        case .valid:
            break
        case .invalid:
            section.state = .invalid
            section.reason = observationReason(source, suffix: "invalid")
            return section
        case .expired:
            section.state = .expired
            section.reason = observationReason(source, suffix: "expired")
            return section
        }
        guard let evidence else {
            section.state = .missing
            section.reason = "status_evidence_missing"
            return section
        }
        guard string(evidence["schema"]) == ProviderBuild1LaneAStatusEvidence.schema else {
            section.state = .invalid
            section.reason = "status_evidence_schema_unsupported"
            return section
        }
        // This milestone only knows path-observed correlation. A status body
        // that claims any other custody scope is from a contract this input
        // cannot vouch for, so it is refused rather than echoed.
        let custody = evidence["runtime_custody"] as? [String: Any]
        guard custody?["descriptor_pinned_runtime_custody"] as? Bool == false,
              string(custody?["observation_scope"]) == Build1LaneAStagingInput.observationScope
        else {
            section.state = .invalid
            section.reason = "status_runtime_custody_scope_unexpected"
            return section
        }
        guard string(evidence["state"]) == ProviderBuild1LaneAStatusEvidence.correlatedState else {
            section.state = .unbound
            section.reason = "status_not_correlated"
            return section
        }

        let record = evidence["private_record"] as? [String: Any]
        let recordMatches = string(record?["artifact_identity_digest"]) == binding.artifactIdentityDigest
            && string(record?["receipt_sha256"]) == binding.receiptSHA256
            && string(record?["root_identity_digest"]) == binding.rootIdentityDigest
            && (record?["inventory_generation"] as? Int) == binding.inventoryGeneration
        section.matchesPrivateRecord = recordMatches
        guard recordMatches else {
            section.state = .mismatch
            section.reason = "status_private_record_mismatch"
            return section
        }

        let artifact = evidence["artifact"] as? [String: Any]
        let authorityMatches = string(artifact?["release_id"]) == authority.releaseID
            && string(artifact?["artifact_sha256"]) == authority.hash
            && string(artifact?["model_id"]) == authority.modelID
            && string(artifact?["model_revision"]) == authority.revision
            && string(artifact?["artifact_id"]) == authority.artifactID
            && string(evidence["model_hash"]) == authority.hash
            && section.modelHash == authority.hash
            && section.modelHashAlgorithm == authority.hashAlgorithm
        section.matchesAuthority = authorityMatches
        guard authorityMatches else {
            section.state = .mismatch
            section.reason = "status_artifact_mismatch"
            return section
        }

        guard section.modelLoaded == true,
              let providerStatus = section.providerStatus,
              [ProviderHealthState.ready.rawValue, ProviderHealthState.busy.rawValue].contains(providerStatus)
        else {
            section.state = .unbound
            section.reason = "status_model_not_serving"
            return section
        }

        section.state = .correlated
        section.reason = "status_matches_private_record_and_authority_path_observed"
        return section
    }

    // MARK: - Status observation validity

    enum StatusObservationValidity: Equatable, Sendable {
        case valid
        case invalid
        case expired
    }

    /// Upper bound on a `valid_for_ms` this reader will honour, matching the
    /// other local status readers (`credentials`, `doctor`). The producer
    /// declares 5 s; anything past a minute is not a live-status contract.
    static let maxStatusObservationValidityMS = 60_000
    /// Tolerated forward clock skew between the producer and this command.
    static let statusObservationClockSkewSeconds: TimeInterval = 1

    /// Checks that `object` is a `GET /v1/status` body from a `serve`
    /// instance under the local status contract this reader understands and
    /// that its observation window still covers `now`. Shape and contract
    /// failures are `.invalid`; a well-formed body whose window closed before
    /// `now` is `.expired`. Nothing here trusts the body's own claims about
    /// the artifact; that correlation follows separately.
    static func validateStatusObservation(_ object: [String: Any], now: Date) -> StatusObservationValidity {
        guard let contract = object["local_status_contract"] as? [String: Any],
              contract["version"] as? Int == RouterHandler.localStatusContractVersion,
              let minimumReaderVersion = contract["minimum_reader_version"] as? Int,
              minimumReaderVersion <= RouterHandler.localStatusContractVersion,
              string(contract["lifecycle_owner"]) == "macprovider_cli",
              let service = object["service_instance"] as? [String: Any],
              string(service["role"]) == "serve",
              let observation = object["observation"] as? [String: Any],
              let observedAtText = string(observation["observed_at"]),
              let observedAt = parseISO8601(observedAtText),
              let validForMS = observation["valid_for_ms"] as? Int,
              (1...maxStatusObservationValidityMS).contains(validForMS),
              observedAt <= now.addingTimeInterval(statusObservationClockSkewSeconds)
        else {
            return .invalid
        }
        guard observedAt.addingTimeInterval(Double(validForMS) / 1_000) >= now else {
            return .expired
        }
        return .valid
    }

    private static func observationReason(
        _ source: Build1LaneAStagingInput.StatusCorrelation.Source,
        suffix: String
    ) -> String {
        switch source {
        case .localStatusEndpoint: return "local_status_\(suffix)"
        case .statusCaptureFile, .unavailable: return "status_capture_\(suffix)"
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }
}

struct ModelsStagingInputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "staging-input",
        abstract: "Assemble the Build 1 Lane A measured artifact-bound staging input under staging-only guards."
    )

    static let maxStatusCaptureBytes = 1024 * 1024
    static let validPortRange = 1...65_535
    static let jsonRequiredReason = "models staging-input is JSON-only in this release; pass --json"

    /// Test seams. Production resolves the signed authority from the staging
    /// artifact feed and reads the live local status endpoint.
    nonisolated(unsafe) static var resolveAuthority: @Sendable (String?) async throws -> Build1LaneAArtifactAuthority = { coordinatorURL in
        try await Build1LaneAArtifactAuthorityResolver.resolve(coordinatorURL: coordinatorURL)
    }
    nonisolated(unsafe) static var loadPrivateAuthority: @Sendable (URL, URL) throws -> Build1LaneAArtifactAuthority = {
        try Build1PrivateAuthorityLoader.load(authorityURL: $0, signatureURL: $1)
    }
    nonisolated(unsafe) static var fetchLocalStatus: @Sendable (Int) async throws -> [String: Any] = { port in
        try await LocalStatusClient.fetch(port: port)
    }

    @Argument(help: "Build 1 model key or id. Only the exact tuple selected by --profile is accepted.")
    var catalogKey: String

    @Flag(name: .customLong("json"), help: "Emit one build1_lane_a_staging_input.v1 object on stdout.")
    var emitJSON = false

    @Option(help: "Preparation profile: build1-lane-a or build1-orcarouter-private.")
    var profile: String = Build1LaneAPrepareProfile.profile

    @Option(help: "Explicit staging coordinator URL. Only loopback and approved staging hosts are accepted.")
    var coordinatorURL: String?

    @Option(help: "build1-orcarouter-private only: path to the signed private authority JSON.")
    var authorityFile: String?

    @Option(help: "build1-orcarouter-private only: path to the detached authority signature JSON.")
    var authoritySignature: String?

    @Option(help: "YAML config path used to resolve model_artifact_root and the local status port. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "Path to a saved GET /v1/status JSON object to correlate instead of the live local endpoint.")
    var statusCapture: String?

    func run() async throws {
        guard emitJSON else {
            writeStagingInputStderr(Self.jsonRequiredReason)
            throw ExitCode(2)
        }

        var guardBlockers: [String] = []
        if ![Build1LaneAPrepareProfile.profile, Build1PrivatePrepareProfile.profile].contains(profile) {
            guardBlockers.append("unsupported_profile")
        }
        if profile == Build1PrivatePrepareProfile.profile {
            if !Build1PrivatePrepareProfile.isApprovedModel(catalogKey) {
                guardBlockers.append("unsupported_model_tuple")
            }
            if coordinatorURL != nil {
                guardBlockers.append("coordinator_not_allowed_for_private_profile")
            }
            if authorityFile?.isEmpty != false || authoritySignature?.isEmpty != false {
                guardBlockers.append("private_authority_required")
            }
        } else if profile == Build1LaneAPrepareProfile.profile {
            if !Build1LaneAPrepareProfile.isApprovedCatalogKey(catalogKey) {
                guardBlockers.append("unsupported_model_tuple")
            }
            if !Build1LaneAPrepareProfile.coordinatorIsAllowedForStaging(coordinatorURL) {
                guardBlockers.append("staging_coordinator_required")
            }
            if authorityFile != nil || authoritySignature != nil {
                guardBlockers.append("private_authority_not_allowed")
            }
        }
        if !guardBlockers.isEmpty {
            let report = Build1LaneAStagingInputAssembler.assemble(
                authority: nil,
                privateRecord: nil,
                status: .notEvaluated,
                preconditionBlockers: guardBlockers
            )
            try Self.emit(report)
            return
        }

        let authority: Result<Build1LaneAArtifactAuthority, Build1LaneAArtifactAuthorityError>
        do {
            if profile == Build1PrivatePrepareProfile.profile,
               let authorityFile,
               let authoritySignature {
                authority = .success(try Self.loadPrivateAuthority(
                    URL(fileURLWithPath: authorityFile),
                    URL(fileURLWithPath: authoritySignature)
                ))
            } else {
                authority = .success(try await Self.resolveAuthority(coordinatorURL))
            }
        } catch let error as Build1LaneAArtifactAuthorityError {
            authority = .failure(error)
        } catch {
            authority = .failure(.artifactAuthorityUnavailable([]))
        }

        // Config is read only, exactly as `serve` preflight reads it, so the
        // private record is the one the provider runtime would bind to.
        let appConfig: AppConfig?
        do {
            appConfig = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        } catch {
            appConfig = nil
        }

        var privateRecord: ProviderBuild1LaneAStatusContext?
        if let appConfig, case .success(let verified) = authority {
            privateRecord = ProviderBuild1LaneAStatusResolver(
                durableRoot: ProviderBuild1LaneAStatusResolver.durableRoot(config: appConfig),
                expectedArtifactSHA256: verified.hash,
                expectedReleaseID: verified.releaseID,
                catalogKey: verified.catalogKey
            ).resolve()
        }

        let status = await Self.observeStatus(capturePath: statusCapture, port: appConfig?.port)
        let report = Build1LaneAStagingInputAssembler.assemble(
            authority: authority,
            privateRecord: privateRecord,
            status: status,
            preconditionBlockers: appConfig == nil ? [Build1LaneAPrepareProfile.configUnavailableReason] : []
        )
        try Self.emit(report)
    }

    /// Prints the report as one JSON line. A blocked report exits 2 so the
    /// evidence driver cannot mistake it for a usable staging input.
    private static func emit(_ report: Build1LaneAStagingInput) throws {
        print(try report.jsonLine())
        fflush(stdout)
        switch report.state {
        case .ready:
            writeStagingInputStderr(
                "models staging-input ready for the physical staging journey; "
                    + "this is a staging input only and grants no admission, settlement, earnings, rewards, payouts, or production activation"
            )
        case .blocked:
            writeStagingInputStderr("models staging-input blocked: \(report.blockers.joined(separator: ","))")
            throw ExitCode(2)
        }
    }

    static func observeStatus(capturePath: String?, port: Int?) async -> Build1LaneAStatusObservation {
        if let capturePath {
            do {
                return .observed(source: .statusCaptureFile, object: try loadStatusCapture(path: capturePath))
            } catch {
                return .unavailable(source: .statusCaptureFile, reason: "status_capture_unreadable")
            }
        }
        guard let port else {
            return .unavailable(source: .localStatusEndpoint, reason: "local_status_unavailable")
        }
        // The config loader accepts any integer; only a real TCP port names a
        // local endpoint this command can observe.
        guard validPortRange.contains(port) else {
            return .unavailable(source: .localStatusEndpoint, reason: "local_status_port_invalid")
        }
        do {
            return .observed(source: .localStatusEndpoint, object: try await fetchLocalStatus(port))
        } catch {
            return .unavailable(source: .localStatusEndpoint, reason: "local_status_unavailable")
        }
    }

    /// Reads a saved `GET /v1/status` object. Regular files only, bounded
    /// size, JSON object at the top level; anything else is unreadable.
    static func loadStatusCapture(path: String) throws -> [String: Any] {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw ModelsStagingInputError.captureUnreadable
        }
        defer { _ = close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0,
              st.st_size <= Int64(maxStatusCaptureBytes)
        else {
            throw ModelsStagingInputError.captureUnreadable
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: maxStatusCaptureBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelsStagingInputError.captureUnreadable
        }
        return object
    }
}

enum ModelsStagingInputError: Error, Equatable, Sendable {
    case captureUnreadable
}

private func writeStagingInputStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
