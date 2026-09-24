import ArgumentParser
import Darwin
import Foundation
import MacProviderCore

// SPEC-010-R008 (#1689 part 4): operator diagnostics that compare the bytes a
// provider holds against the signed catalog row, and a catalog preparation path
// that reuses the serve/autotune downloader. Read-only except for the explicit
// `--repair-cache` removal of this model's own interrupted-download leftovers.

/// The signed catalog authority for one model, resolved through the same
/// verified candidate-catalog / rate-card / artifact-feed loader serve uses.
struct ModelArtifactSignedRow: Equatable {
    var catalogKey: String
    var buyerModelKey: String?
    var catalogRow: CandidateCatalog.Row
    var catalogVersion: String
    var catalogDigest: String
    var catalogSignerKeyID: String?
    /// `live_signed` when the fetched feed verified, `baked_signed` when the
    /// signed snapshot compiled into this CLI was selected.
    var catalogSource: String
    var artifactSizeBytes: Int?
    var artifactFeedReleaseID: String?
    var artifactFeedSHA256: String?

    var modelID: String { catalogRow.modelID }
    var revision: String { catalogRow.modelRevision ?? "" }
    var sha256: String { catalogRow.modelSHA256 ?? "" }
}

enum ModelArtifactSignedRowError: Error, Equatable, CustomStringConvertible {
    case catalogUntrusted(String)
    case unknownModel(String)
    case rowUnpinned(String)

    var description: String {
        switch self {
        case .catalogUntrusted(let state):
            return "\(state): the signed candidate catalog is not trusted; refusing to compare against it"
        case .unknownModel(let key):
            return "unknown_model: \(key) is not a row in the signed candidate catalog"
        case .rowUnpinned(let key):
            return "row_unpinned: catalog row \(key) has no pinned revision/model_sha256"
        }
    }
}

enum ModelArtifactSignedRowResolver {
    static func resolve(
        key: String,
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs()
    ) async throws -> ModelArtifactSignedRow {
        let inputs = await staticInputs.loadRecommendationInputs()
        let catalog = inputs.candidate
        // Same trust-blocking set the serve catalog preflight refuses on.
        if catalog.warnings.contains(.candidateCatalogIntegrityFailure) {
            throw ModelArtifactSignedRowError.catalogUntrusted("catalog_integrity_failure")
        }
        if catalog.warnings.contains(.candidateCatalogUpdateRequired) {
            throw ModelArtifactSignedRowError.catalogUntrusted("catalog_update_required")
        }
        guard let (catalogKey, row) = lookup(key, in: catalog.value) else {
            throw ModelArtifactSignedRowError.unknownModel(key)
        }
        guard let revision = row.modelRevision, !revision.isEmpty,
              let sha = row.modelSHA256, sha.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else {
            throw ModelArtifactSignedRowError.rowUnpinned(catalogKey)
        }
        let rateCard = inputs.rateCard
        let rateCardTrusted = rateCard.warnings.isDisjoint(with: [.rateCardIntegrityFailure, .rateCardUpdateRequired])
        let buyerKey = rateCardTrusted
            ? rateCard.value.rowForRecommendation(modelKey: catalogKey).map {
                rateCard.value.servedModelKey(modelKey: catalogKey, rateCardKey: $0.key)
            }
            : nil
        let feed = inputs.artifactFeed.value
        let primary = feed?.feed.models[catalogKey]?.primary
        let primaryMatchesRow = primary?.hash == sha && primary?.sourceRef.revision == revision
        return ModelArtifactSignedRow(
            catalogKey: catalogKey,
            buyerModelKey: buyerKey,
            catalogRow: row,
            catalogVersion: catalog.value.version,
            catalogDigest: AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalog.selectedBytes),
            catalogSignerKeyID: catalog.signerKeyID,
            catalogSource: catalog.usedFallback ? "baked_signed" : "live_signed",
            artifactSizeBytes: primaryMatchesRow ? primary?.sizeBytes : nil,
            artifactFeedReleaseID: primaryMatchesRow ? feed?.releaseID : nil,
            artifactFeedSHA256: primaryMatchesRow ? feed?.feedSHA256 : nil
        )
    }

    /// Catalog key first (exact, then case-insensitive), then the row's
    /// `model_id`, then the autotune key normalizer.
    static func lookup(_ key: String, in catalog: CandidateCatalog) -> (String, CandidateCatalog.Row)? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let row = catalog.rows[trimmed] {
            return (trimmed, row)
        }
        let lower = trimmed.lowercased()
        let sorted = catalog.rows.sorted { $0.key < $1.key }
        if let match = sorted.first(where: { $0.key.lowercased() == lower }) {
            return (match.key, match.value)
        }
        if let match = sorted.first(where: { $0.value.modelID.lowercased() == lower }) {
            return (match.key, match.value)
        }
        let normalized = AutotuneModelKeyNormalizer.normalize(trimmed)
        if normalized != "default", let row = catalog.rows[normalized] {
            return (normalized, row)
        }
        return nil
    }
}

enum ModelArtifactVerdict: String {
    case match
    case mismatch
    case missing
    case unverifiable
}

/// SPEC-010-R008 likely-source classes for a verdict other than `match`.
enum ModelArtifactLikelySource: String {
    case none
    case notDownloaded = "not_downloaded"
    /// (a) local bytes are for a different revision than the row pins.
    case revisionPin = "revision_pin"
    /// (b) local bytes are incomplete or an interrupted download is present.
    case localDownload = "local_download"
    /// (c) complete local bytes at the pinned revision hash differently.
    case catalogRow = "catalog_row"
    case undetermined
}

enum ModelArtifactLocationKind: String {
    case durableStore = "durable_store"
    case hfSnapshot = "hf_cache_snapshot"
    case hfPrefetch = "hf_cache_prefetch"
    case configuredPath = "configured_path"
}

struct ModelArtifactPartial: Equatable {
    enum Kind: String {
        case hfDownloadStaging = "hf_download_staging"
        case hfIncompleteBlob = "hf_incomplete_blob"
        case durableCopyStaging = "durable_copy_staging"
    }

    var url: URL
    var kind: Kind
    var bytes: Int64
}

struct ModelArtifactDiagnosis {
    var row: ModelArtifactSignedRow
    var verdict: ModelArtifactVerdict
    var likelySource: ModelArtifactLikelySource
    var locationKind: ModelArtifactLocationKind?
    var localPath: URL?
    var computedSHA256: String?
    var localBytes: Int64?
    var evidence: [String]
    var otherLocalRevisions: [String]
    var partials: [ModelArtifactPartial]
    var hubRoot: URL
    var durableRoot: URL
}

enum ModelArtifactDiagnostics {
    static let signedHashAlgorithm = ModelArtifactIdentity.snapshotManifestV1

    static func diagnose(
        row: ModelArtifactSignedRow,
        resolver: CachedModelArtifactResolver,
        configuredArtifactPath: String? = nil
    ) -> ModelArtifactDiagnosis {
        let partials = findPartials(row: row, resolver: resolver)
        let otherRevisions = otherLocalRevisions(row: row, resolver: resolver)
        var diagnosis = ModelArtifactDiagnosis(
            row: row,
            verdict: .missing,
            likelySource: .notDownloaded,
            locationKind: nil,
            localPath: nil,
            computedSHA256: nil,
            localBytes: nil,
            evidence: [],
            otherLocalRevisions: otherRevisions,
            partials: partials,
            hubRoot: resolver.hubRoot.standardizedFileURL,
            durableRoot: resolver.durableRoot.standardizedFileURL
        )

        let candidates = candidateLocations(row: row, resolver: resolver, configuredArtifactPath: configuredArtifactPath)
        var firstFailure: ModelArtifactDiagnosis?
        for (kind, url) in candidates where isDirectory(url) {
            var attempt = diagnosis
            attempt.locationKind = kind
            attempt.localPath = url
            attempt.localBytes = regularFileBytes(in: url)
            let completeness = incompletenessEvidence(directory: url, signedSizeBytes: row.artifactSizeBytes)
            do {
                let actual = try ModelArtifactVerifier.canonicalArtifactHash(directory: url)
                attempt.computedSHA256 = actual
                if actual == row.sha256 {
                    attempt.verdict = .match
                    attempt.likelySource = .none
                    return attempt
                }
                attempt.verdict = .mismatch
                attempt.evidence = completeness
                if !completeness.isEmpty {
                    attempt.likelySource = .localDownload
                } else if kind == .configuredPath && !isAtPinnedRevision(url, row: row) {
                    attempt.likelySource = .revisionPin
                    attempt.evidence.append("configured artifact path is not the pinned revision \(row.revision)")
                } else if kind == .durableStore {
                    // The store names the copy by the signed hash it verified
                    // on adoption, so different bytes there drifted locally.
                    attempt.likelySource = .localDownload
                    attempt.evidence.append(
                        "the durable-store copy for the signed hash no longer hashes to it; --repair-cache replaces it from verified bytes"
                    )
                } else {
                    attempt.likelySource = .catalogRow
                    attempt.evidence.append(
                        "local bytes are complete at the pinned revision but hash differently from the signed row"
                    )
                }
            } catch {
                attempt.verdict = .unverifiable
                attempt.evidence = completeness + ["canonical hash failed: \(error)"]
                attempt.likelySource = completeness.isEmpty ? .undetermined : .localDownload
            }
            // Serve loads an existing configured or durable copy and never
            // falls back past it, so its failure is the verdict.
            if kind == .configuredPath || kind == .durableStore {
                return attempt
            }
            if firstFailure == nil {
                firstFailure = attempt
            }
        }
        if let firstFailure {
            return firstFailure
        }

        if !partials.isEmpty {
            diagnosis.likelySource = .localDownload
            diagnosis.evidence.append("\(partials.count) interrupted download artifact(s) present; no complete snapshot")
        } else if !otherRevisions.isEmpty {
            diagnosis.likelySource = .revisionPin
            diagnosis.evidence.append(
                "local snapshot(s) exist only for revision(s) \(otherRevisions.joined(separator: ", ")); "
                    + "catalog pins \(row.revision)"
            )
        }
        return diagnosis
    }

    // MARK: Locations

    static func repoDirectory(row: ModelArtifactSignedRow, resolver: CachedModelArtifactResolver) -> URL {
        resolver.snapshotURL(modelID: row.modelID, revision: row.revision)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// `<durable-root>/<escaped-model-id>` for this model, or nil when the
    /// model id cannot form a durable path.
    static func durableModelDirectory(row: ModelArtifactSignedRow, resolver: CachedModelArtifactResolver) -> URL? {
        (try? resolver.durableStore.artifactURL(modelID: row.modelID, revision: row.revision, sha256: row.sha256))?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Locations in serve's order (`ServeCommand.pinnedArtifactLoadCandidate`):
    /// an existing configured directory is the only candidate, because serve
    /// loads it and never falls back. Otherwise the durable-store copy, which
    /// is likewise decisive when it exists, then the Hugging Face cache
    /// snapshots `prepare` adopts into the durable store.
    static func candidateLocations(
        row: ModelArtifactSignedRow,
        resolver: CachedModelArtifactResolver,
        configuredArtifactPath: String?
    ) -> [(ModelArtifactLocationKind, URL)] {
        if let configuredArtifactPath, configuredArtifactPath.hasPrefix("/"),
           case .configured(let path) = ServeCommand.pinnedArtifactLoadCandidate(
               configuredPath: URL(fileURLWithPath: configuredArtifactPath).standardizedFileURL.path,
               modelID: row.modelID,
               revision: row.revision,
               expectedSHA256: row.sha256,
               artifactResolver: resolver
           ) {
            let configured = URL(fileURLWithPath: path).standardizedFileURL
            let durable = try? resolver.durableStore.artifactURL(modelID: row.modelID, revision: row.revision, sha256: row.sha256)
            return [(durable?.standardizedFileURL.path == configured.path ? .durableStore : .configuredPath, configured)]
        }
        var result: [(ModelArtifactLocationKind, URL)] = []
        if let durable = try? resolver.durableStore.artifactURL(
            modelID: row.modelID,
            revision: row.revision,
            sha256: row.sha256
        ) {
            result.append((.durableStore, durable.standardizedFileURL))
        }
        result.append((.hfSnapshot, resolver.snapshotURL(modelID: row.modelID, revision: row.revision).standardizedFileURL))
        result.append((
            .hfPrefetch,
            resolver.prefetchSnapshotURL(modelID: row.modelID, revision: row.revision, sha256: row.sha256)
                .standardizedFileURL
        ))
        return result
    }

    private static func isAtPinnedRevision(_ url: URL, row: ModelArtifactSignedRow) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.contains(row.revision)
            || components.contains { $0.hasPrefix(row.revision + ".macprovider-prefetch.") }
    }

    static func otherLocalRevisions(row: ModelArtifactSignedRow, resolver: CachedModelArtifactResolver) -> [String] {
        var revisions = Set<String>()
        let snapshots = repoDirectory(row: row, resolver: resolver).appendingPathComponent("snapshots", isDirectory: true)
        for name in directoryEntries(snapshots) where !name.hasPrefix(".") {
            let revision = name.components(separatedBy: ".macprovider-prefetch.").first ?? name
            if revision != row.revision, isDirectory(snapshots.appendingPathComponent(name)) {
                revisions.insert(revision)
            }
        }
        if let durableModel = durableModelDirectory(row: row, resolver: resolver) {
            for name in directoryEntries(durableModel) where !name.hasPrefix(".") && name != row.revision {
                if isDirectory(durableModel.appendingPathComponent(name)) {
                    revisions.insert(name)
                }
            }
        }
        return revisions.sorted()
    }

    // MARK: Partial downloads

    /// Interrupted-download leftovers for THIS model only: the HF downloader's
    /// `.download-*` staging directories and `*.incomplete` blobs under this
    /// model's cache repo, and the durable store's `.tmp-<uuid>` copy staging
    /// directories under this model's durable directory. A `.tmp-replaced-*`
    /// directory is a parked previous copy, not a partial, and is never listed.
    static func findPartials(row: ModelArtifactSignedRow, resolver: CachedModelArtifactResolver) -> [ModelArtifactPartial] {
        var partials: [ModelArtifactPartial] = []
        let repo = repoDirectory(row: row, resolver: resolver)
        let snapshots = repo.appendingPathComponent("snapshots", isDirectory: true)
        for name in directoryEntries(snapshots) where name.hasPrefix(".download-") {
            let url = snapshots.appendingPathComponent(name)
            partials.append(ModelArtifactPartial(url: url, kind: .hfDownloadStaging, bytes: regularFileBytes(in: url) ?? 0))
        }
        let blobs = repo.appendingPathComponent("blobs", isDirectory: true)
        for name in directoryEntries(blobs) where name.hasSuffix(".incomplete") {
            let url = blobs.appendingPathComponent(name)
            partials.append(ModelArtifactPartial(url: url, kind: .hfIncompleteBlob, bytes: fileBytes(url) ?? 0))
        }
        if let durableModel = durableModelDirectory(row: row, resolver: resolver) {
            for revision in directoryEntries(durableModel) where !revision.hasPrefix(".") {
                let revisionDirectory = durableModel.appendingPathComponent(revision, isDirectory: true)
                for name in directoryEntries(revisionDirectory) where isDurableCopyStaging(name) {
                    let url = revisionDirectory.appendingPathComponent(name)
                    partials.append(ModelArtifactPartial(
                        url: url,
                        kind: .durableCopyStaging,
                        bytes: regularFileBytes(in: url) ?? 0
                    ))
                }
            }
        }
        return partials.sorted { $0.url.path < $1.url.path }
    }

    private static func isDurableCopyStaging(_ name: String) -> Bool {
        guard name.hasPrefix(".tmp-") else { return false }
        return UUID(uuidString: String(name.dropFirst(".tmp-".count))) != nil
    }

    /// Removes the listed partials. Each entry is re-checked against a fresh
    /// scan of this model's partials, so nothing outside that set is removed.
    static func removePartials(
        _ partials: [ModelArtifactPartial],
        row: ModelArtifactSignedRow,
        resolver: CachedModelArtifactResolver
    ) -> (removed: [ModelArtifactPartial], failures: [String]) {
        let allowed = Set(findPartials(row: row, resolver: resolver).map(\.url.path))
        var removed: [ModelArtifactPartial] = []
        var failures: [String] = []
        for partial in partials where allowed.contains(partial.url.path) {
            do {
                try FileManager.default.removeItem(at: partial.url)
                removed.append(partial)
            } catch {
                failures.append("\(partial.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (removed, failures)
    }

    // MARK: Completeness evidence

    /// Local evidence that a snapshot directory is incomplete. The signed row
    /// carries no file list, so this uses what the bytes themselves declare:
    /// download markers, safetensors index shards, safetensors header lengths,
    /// and the signed artifact-feed size estimate when one is bound.
    static func incompletenessEvidence(directory: URL, signedSizeBytes: Int?) -> [String] {
        var evidence: [String] = []
        let files = regularFiles(in: directory)
        let names = Set(files.map(\.relative))
        for file in files where [".incomplete", ".part", ".partial", ".download"].contains(where: file.relative.hasSuffix) {
            evidence.append("incomplete file marker: \(file.relative)")
        }
        if !names.contains("config.json") {
            evidence.append("config.json missing")
        }
        let weightExtensions: Set<String> = ["safetensors", "gguf", "bin", "npz", "pt"]
        if !files.contains(where: { weightExtensions.contains(($0.relative as NSString).pathExtension.lowercased()) }) {
            evidence.append("no weight files present")
        }
        for file in files where file.relative.hasSuffix(".safetensors.index.json") {
            guard let data = try? Data(contentsOf: file.url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weightMap = object["weight_map"] as? [String: Any]
            else {
                evidence.append("unreadable safetensors index: \(file.relative)")
                continue
            }
            let base = (file.relative as NSString).deletingLastPathComponent
            let shards = Set(weightMap.values.compactMap { $0 as? String })
            for shard in shards.sorted() {
                let relative = base.isEmpty ? shard : base + "/" + shard
                if !names.contains(relative) {
                    evidence.append("index references missing shard: \(relative)")
                }
            }
        }
        for file in files where file.relative.hasSuffix(".safetensors") {
            if let problem = safetensorsTruncation(file.url, size: file.size) {
                evidence.append("truncated safetensors \(file.relative): \(problem)")
            }
        }
        if let signedSizeBytes, signedSizeBytes > 0 {
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            // size_bytes is a preparation estimate (SPEC-023 §3.7), so only a
            // large shortfall counts as evidence of missing bytes.
            if Double(total) < Double(signedSizeBytes) * 0.9 {
                evidence.append("local bytes \(total) are well below the signed artifact size \(signedSizeBytes)")
            }
        }
        return evidence
    }

    /// A safetensors file starts with a little-endian u64 header length, then a
    /// JSON header whose tensor `data_offsets` end at the last data byte.
    static func safetensorsTruncation(_ url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unreadable" }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else {
            return "\(size) bytes, shorter than the 8-byte header length"
        }
        let headerLength = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard headerLength <= 100 * 1024 * 1024, Int64(headerLength) + 8 <= size else {
            return "header declares \(headerLength) bytes but file has \(size)"
        }
        guard let header = try? handle.read(upToCount: Int(headerLength)),
              header.count == Int(headerLength),
              let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any]
        else {
            return "unreadable header"
        }
        var dataEnd: Int64 = 0
        for (name, value) in object where name != "__metadata__" {
            if let tensor = value as? [String: Any],
               let offsets = tensor["data_offsets"] as? [NSNumber],
               offsets.count == 2 {
                dataEnd = max(dataEnd, offsets[1].int64Value)
            }
        }
        let expected = 8 + Int64(headerLength) + dataEnd
        return size < expected ? "\(size) of \(expected) bytes" : nil
    }

    // MARK: Redaction and output

    /// Replaces local roots with placeholders so a report can be filed without
    /// leaking the operator's home directory or volume names.
    static func redact(_ text: String, hubRoot: URL, durableRoot: URL) -> String {
        var replacements: [(String, String)] = [
            (hubRoot.standardizedFileURL.path, "<hf_cache>"),
            (durableRoot.standardizedFileURL.path, "<durable_store>"),
            (FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path, "~"),
            (NSHomeDirectory(), "~"),
        ]
        replacements.sort { $0.0.count > $1.0.count }
        var result = text
        for (path, placeholder) in replacements where path.count > 1 {
            result = result.replacingOccurrences(of: path, with: placeholder)
        }
        return result
    }

    /// `redact`, plus the diagnosed local path itself when it lies outside
    /// the known roots (a configured path), shown as `<external>/<name>`.
    static func redact(_ text: String, diagnosis: ModelArtifactDiagnosis) -> String {
        var text = text
        if let local = diagnosis.localPath?.standardizedFileURL.path,
           let shown = redactedPath(diagnosis.localPath, diagnosis: diagnosis),
           shown.hasPrefix("<external>/"), local.count > 1 {
            text = text.replacingOccurrences(of: local, with: shown)
        }
        return redact(text, hubRoot: diagnosis.hubRoot, durableRoot: diagnosis.durableRoot)
    }

    static func redactedPath(_ url: URL?, diagnosis: ModelArtifactDiagnosis) -> String? {
        guard let url else { return nil }
        let redacted = redact(url.standardizedFileURL.path, hubRoot: diagnosis.hubRoot, durableRoot: diagnosis.durableRoot)
        if redacted.hasPrefix("<") || redacted.hasPrefix("~") {
            return redacted
        }
        return "<external>/" + url.lastPathComponent
    }

    static func reportBlock(_ diagnosis: ModelArtifactDiagnosis) -> String {
        let row = diagnosis.row
        var lines = [
            "### Model artifact verification report",
            "- tool: malibu-cli \(CoordinatorClient.binaryVersion) models verify-artifact",
            "- verdict: \(diagnosis.verdict.rawValue)",
            "- likely_source: \(diagnosis.likelySource.rawValue)",
            "- catalog_key: \(row.catalogKey)",
            "- buyer_model_key: \(row.buyerModelKey ?? "unknown")",
            "- catalog_model_id: \(row.modelID)",
            "- artifact_repo: \(row.modelID)",
            "- pinned_revision: \(row.revision)",
            "- hash_algorithm: \(signedHashAlgorithm)",
            "- signed_hash: \(row.sha256)",
            "- computed_hash: \(diagnosis.computedSHA256 ?? "none")",
            "- catalog_release: \(row.catalogVersion) (\(row.catalogSource))",
            "- catalog_digest: \(row.catalogDigest)",
            "- catalog_signer_key_id: \(row.catalogSignerKeyID ?? "unknown")",
            "- artifact_feed_release: \(row.artifactFeedReleaseID ?? "unbound")",
            "- artifact_feed_sha256: \(row.artifactFeedSHA256 ?? "unbound")",
            "- signed_size_bytes: \(row.artifactSizeBytes.map(String.init) ?? "unknown")",
            "- local_location: \(diagnosis.locationKind?.rawValue ?? "none")",
            "- local_path: \(redactedPath(diagnosis.localPath, diagnosis: diagnosis) ?? "none")",
            "- local_bytes: \(diagnosis.localBytes.map(String.init) ?? "none")",
            "- other_local_revisions: \(diagnosis.otherLocalRevisions.isEmpty ? "none" : diagnosis.otherLocalRevisions.joined(separator: ", "))",
            "- partial_download_artifacts: \(diagnosis.partials.count)",
        ]
        for item in diagnosis.evidence {
            lines.append("- evidence: \(item)")
        }
        let body = lines.joined(separator: "\n")
        return redact(body, diagnosis: diagnosis)
    }

    static func nextStep(_ diagnosis: ModelArtifactDiagnosis) -> String {
        let key = diagnosis.row.catalogKey
        switch diagnosis.likelySource {
        case .none:
            return "local bytes match the signed row; nothing to do"
        case .notDownloaded:
            return "not downloaded; run: malibu-cli models prepare \(key) --repair-cache"
        case .revisionPin:
            return "local bytes are for a different revision; run: malibu-cli models prepare \(key) --repair-cache"
        case .localDownload:
            return "local download is incomplete; run: malibu-cli models prepare \(key) --repair-cache"
        case .catalogRow:
            return "the signed catalog row is the likely source; file the report below (do not re-download)"
        case .undetermined:
            return "could not classify; file the report below"
        }
    }

    static func jsonObject(_ diagnosis: ModelArtifactDiagnosis) -> [String: Any] {
        let row = diagnosis.row
        func nullable(_ value: Any?) -> Any { value ?? NSNull() }
        return [
            "schema": "model_artifact_verification.v1",
            "verdict": diagnosis.verdict.rawValue,
            "likely_source": diagnosis.likelySource.rawValue,
            "catalog_key": row.catalogKey,
            "buyer_model_key": nullable(row.buyerModelKey),
            "catalog_model_id": row.modelID,
            "artifact_repo": row.modelID,
            "pinned_revision": row.revision,
            "hash_algorithm": signedHashAlgorithm,
            "signed_hash": row.sha256,
            "computed_hash": nullable(diagnosis.computedSHA256),
            "catalog_release": row.catalogVersion,
            "catalog_source": row.catalogSource,
            "catalog_digest": row.catalogDigest,
            "catalog_signer_key_id": nullable(row.catalogSignerKeyID),
            "artifact_feed_release": nullable(row.artifactFeedReleaseID),
            "artifact_feed_sha256": nullable(row.artifactFeedSHA256),
            "signed_size_bytes": nullable(row.artifactSizeBytes),
            "local_location": nullable(diagnosis.locationKind?.rawValue),
            "local_path": nullable(redactedPath(diagnosis.localPath, diagnosis: diagnosis)),
            "local_bytes": nullable(diagnosis.localBytes),
            "other_local_revisions": diagnosis.otherLocalRevisions,
            "partial_download_artifacts": diagnosis.partials.map {
                ["kind": $0.kind.rawValue, "bytes": $0.bytes] as [String: Any]
            },
            "evidence": diagnosis.evidence.map { redact($0, diagnosis: diagnosis) },
            "next_step": nextStep(diagnosis),
            "report_markdown": reportBlock(diagnosis),
        ]
    }

    static func humanText(_ diagnosis: ModelArtifactDiagnosis) -> String {
        let row = diagnosis.row
        var lines = [
            "verdict:          \(diagnosis.verdict.rawValue)"
                + (diagnosis.likelySource == .none ? "" : " (likely source: \(diagnosis.likelySource.rawValue))"),
            "buyer model key:  \(row.buyerModelKey ?? "unknown")",
            "catalog key:      \(row.catalogKey)",
            "catalog model_id: \(row.modelID)",
            "artifact:         \(row.modelID)@\(row.revision)",
            "local path:       \(redactedPath(diagnosis.localPath, diagnosis: diagnosis) ?? "none") (\(diagnosis.locationKind?.rawValue ?? "not found"))",
            "computed hash:    \(diagnosis.computedSHA256 ?? "none")",
            "signed hash:      \(row.sha256) (\(signedHashAlgorithm))",
            "signed catalog:   \(row.catalogVersion) digest=\(row.catalogDigest) source=\(row.catalogSource)",
        ]
        if !diagnosis.partials.isEmpty {
            let bytes = diagnosis.partials.reduce(Int64(0)) { $0 + $1.bytes }
            lines.append("partials:         \(diagnosis.partials.count) interrupted download artifact(s), \(bytes) bytes")
        }
        for item in diagnosis.evidence {
            lines.append("evidence:         \(redact(item, diagnosis: diagnosis))")
        }
        lines.append("next step:        \(nextStep(diagnosis))")
        if diagnosis.verdict != .match {
            lines.append("")
            lines.append("Redacted report (safe to paste into an issue):")
            lines.append("```")
            lines.append(reportBlock(diagnosis))
            lines.append("```")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Filesystem helpers (never follow symlinks)

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func directoryEntries(_ url: URL) -> [String] {
        guard isDirectory(url) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private static func fileBytes(_ url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    private struct RegularFile {
        var url: URL
        var relative: String
        var size: Int64
    }

    private static func regularFiles(in directory: URL) -> [RegularFile] {
        guard isDirectory(directory),
              let enumerator = FileManager.default.enumerator(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: []
              )
        else {
            return []
        }
        let base = directory.standardizedFileURL.path
        var files: [RegularFile] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/"), let size = fileBytes(url) else { continue }
            files.append(RegularFile(url: url, relative: String(path.dropFirst(base.count + 1)), size: size))
        }
        return files.sorted { $0.relative < $1.relative }
    }

    static func regularFileBytes(in directory: URL) -> Int64? {
        guard isDirectory(directory) else { return nil }
        return regularFiles(in: directory).reduce(Int64(0)) { $0 + $1.size }
    }
}

// MARK: - models verify-artifact

struct ModelsVerifyArtifactCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-artifact",
        abstract: "Check a model's local bytes against its signed catalog row.",
        discussion: "Resolves the signed catalog row (the same verified feed serve uses), finds the local "
            + "snapshot serve would load, computes the macprovider.snapshot-manifest.v1 hash, and reports match "
            + "or mismatch. On a mismatch it names the likely source (revision_pin, local_download, or "
            + "catalog_row) and prints a redacted report. Exit 0 = match, 3 = mismatch/missing/unverifiable, "
            + "2 = refused."
    )

    @Argument(help: "Catalog key or model id, e.g. qwen/qwen3.6-27b or mlx-community/Qwen3.6-27B-4bit.")
    var model: String

    @Flag(name: .customLong("json"), help: "Emit the model_artifact_verification.v1 JSON object.")
    var emitJSON = false

    @Option(help: "YAML config path used to resolve model_artifact_root. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    func run() async throws {
        let appConfig = try loadDiagnosticsConfig(config, command: "models verify-artifact")
        let row: ModelArtifactSignedRow
        do {
            row = try await ModelArtifactSignedRowResolver.resolve(key: model)
        } catch {
            writeDiagnosticsStderr("models verify-artifact refused: \(error)")
            throw ExitCode(2)
        }
        let resolver = CachedModelArtifactResolver.forConfig(appConfig)
        let configuredPath = appConfig.modelCatalogKey == row.catalogKey ? appConfig.modelArtifactPath : nil
        let diagnosis = ModelArtifactDiagnostics.diagnose(
            row: row,
            resolver: resolver,
            configuredArtifactPath: configuredPath
        )
        if emitJSON {
            try printDiagnosticsJSON(ModelArtifactDiagnostics.jsonObject(diagnosis))
        } else {
            print(ModelArtifactDiagnostics.humanText(diagnosis))
        }
        if diagnosis.verdict != .match {
            throw ExitCode(3)
        }
    }
}

// MARK: - models identity

/// Served-model identity mapping read from the running provider's /v1/status.
struct ModelServedIdentity: Equatable {
    var buyerModelKey: String?
    var catalogKey: String?
    var catalogModelID: String?
    var modelRevision: String?
    var catalogArtifactSHA256: String?
    var modelHash: String?
    var modelHashAlgorithm: String?
    var weightsManifestSHA256: String?
    var catalogState: String?
    var catalogReleaseID: String?
    var catalogDigest: String?
    var catalogSignerKeyID: String?
    var identityAdmissionMode: String?

    init(status: [String: Any]) {
        let catalog = status["catalog"] as? [String: Any] ?? [:]
        let coordinator = status["coordinator"] as? [String: Any] ?? [:]
        buyerModelKey = status["model"] as? String
        catalogKey = catalog["catalog_key"] as? String
        catalogModelID = catalog["model_id"] as? String
        modelRevision = catalog["model_revision"] as? String
        catalogArtifactSHA256 = catalog["artifact_sha256"] as? String
        modelHash = status["model_hash"] as? String
        modelHashAlgorithm = status["model_hash_algorithm"] as? String
        weightsManifestSHA256 = status["weights_manifest_sha256"] as? String
        catalogState = catalog["state"] as? String
        catalogReleaseID = catalog["release_id"] as? String
        catalogDigest = catalog["digest"] as? String
        catalogSignerKeyID = catalog["signer_key_id"] as? String
        identityAdmissionMode = coordinator["identity_admission_mode"] as? String
    }

    /// nil when either side is absent; otherwise whether the served canonical
    /// hash is the configured catalog artifact hash.
    var hashesAgree: Bool? {
        guard let modelHash, let catalogArtifactSHA256 else { return nil }
        return modelHash == catalogArtifactSHA256
    }

    var jsonObject: [String: Any] {
        func nullable(_ value: Any?) -> Any { value ?? NSNull() }
        return [
            "schema": "model_served_identity.v1",
            "buyer_model_key": nullable(buyerModelKey),
            "catalog_key": nullable(catalogKey),
            "catalog_model_id": nullable(catalogModelID),
            "model_revision": nullable(modelRevision),
            "catalog_artifact_sha256": nullable(catalogArtifactSHA256),
            "model_hash": nullable(modelHash),
            "model_hash_algorithm": nullable(modelHashAlgorithm),
            "weights_manifest_sha256": nullable(weightsManifestSHA256),
            "hashes_agree": nullable(hashesAgree),
            "catalog_state": nullable(catalogState),
            "catalog_release_id": nullable(catalogReleaseID),
            "catalog_digest": nullable(catalogDigest),
            "catalog_signer_key_id": nullable(catalogSignerKeyID),
            "identity_admission_mode": nullable(identityAdmissionMode),
        ]
    }

    var humanText: String {
        let agree: String
        switch hashesAgree {
        case .some(true): agree = "yes"
        case .some(false): agree = "NO — served hash differs from the configured catalog artifact"
        case .none: agree = "unknown"
        }
        return [
            "buyer model key:        \(buyerModelKey ?? "none")",
            "catalog key:            \(catalogKey ?? "none")",
            "catalog model_id:       \(catalogModelID ?? "none")",
            "artifact revision:      \(modelRevision ?? "none")",
            "catalog artifact hash:  \(catalogArtifactSHA256 ?? "none")",
            "served model hash:      \(modelHash ?? "none") (\(modelHashAlgorithm ?? "no algorithm"))",
            "weights manifest:       \(weightsManifestSHA256 ?? "none") (diagnostic only)",
            "hashes agree:           \(agree)",
            "catalog:                \(catalogState ?? "unknown") release=\(catalogReleaseID ?? "none") digest=\(catalogDigest ?? "none")",
            "admission mode:         \(identityAdmissionMode ?? "unknown")",
        ].joined(separator: "\n")
    }
}

struct ModelsIdentityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identity",
        abstract: "Show the served model's buyer key, catalog row, artifact, and hash identity."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "Local provider HTTP port. Defaults to the configured serve port.")
    var port: Int?

    @Flag(name: .customLong("json"), help: "Emit the model_served_identity.v1 JSON object.")
    var emitJSON = false

    func run() async throws {
        let resolvedPort: Int
        if let port {
            resolvedPort = port
        } else {
            resolvedPort = try ConfigLoader.load(cli: CLIOverrides(configPath: config)).port
        }
        let status: [String: Any]
        do {
            status = try await LocalStatusClient.fetch(port: resolvedPort)
        } catch {
            writeDiagnosticsStderr("malibu-cli serve is not reachable on 127.0.0.1:\(resolvedPort); start serve, or use models verify-artifact <key> for on-disk identity")
            throw ExitCode(4)
        }
        let identity = ModelServedIdentity(status: status)
        if emitJSON {
            try printDiagnosticsJSON(identity.jsonObject)
        } else {
            print(identity.humanText)
        }
    }
}

// MARK: - models prepare --profile catalog

enum ModelPrepareFinalState: String {
    case readyVerified = "ready_verified"
    case hashMismatch = "downloaded_hash_mismatch"
    case incomplete
}

struct ModelPrepareOutcome {
    var finalState: ModelPrepareFinalState
    var diagnosis: ModelArtifactDiagnosis
    var requiredBytes: Int64?
    var availableBytes: Int64?
    var partialsFound: [ModelArtifactPartial]
    var partialsRemoved: [ModelArtifactPartial]
    var downloadAttempted: Bool
    var error: String?
    var retryCommand: String?
    /// Partials `--repair-cache` could not remove. Kept apart from `error`,
    /// which a verified artifact clears, so a cleanup failure is never hidden.
    var cleanupFailures: [String] = []
    var repairCacheRequested = false

    var finalLine: String {
        switch finalState {
        case .readyVerified:
            return "ready (verified)"
        case .hashMismatch:
            return "downloaded but hash mismatch (see verify-artifact)"
        case .incomplete:
            return "incomplete (retry: \(retryCommand ?? ModelCatalogPreparation.retryCommand(catalogKey: diagnosis.row.catalogKey, config: nil)))"
        }
    }

    var jsonObject: [String: Any] {
        func nullable(_ value: Any?) -> Any { value ?? NSNull() }
        let row = diagnosis.row
        return [
            "schema": "model_prepare_result.v1",
            "final_state": finalState.rawValue,
            "final_line": finalLine,
            "catalog_key": row.catalogKey,
            "catalog_model_id": row.modelID,
            "pinned_revision": row.revision,
            "signed_hash": row.sha256,
            "computed_hash": nullable(diagnosis.computedSHA256),
            "verdict": diagnosis.verdict.rawValue,
            "likely_source": diagnosis.likelySource.rawValue,
            "required_bytes": nullable(requiredBytes),
            "available_bytes": nullable(availableBytes),
            "partials_found": partialsFound.count,
            "partials_removed": partialsRemoved.count,
            "cleanup_failed": cleanupFailures.map {
                ModelArtifactDiagnostics.redact($0, diagnosis: diagnosis)
            },
            "download_attempted": downloadAttempted,
            "error": nullable(error.map {
                ModelArtifactDiagnostics.redact($0, diagnosis: diagnosis)
            }),
            "retry_command": nullable(retryCommand),
        ]
    }
}

enum ModelCatalogPreparation {
    typealias FreeSpace = @Sendable (URL) -> Int64?

    static func retryCommand(catalogKey: String, config: String?) -> String {
        var command = "malibu-cli models prepare \(shellWord(catalogKey)) --repair-cache"
        if let config {
            command += " --config \(shellWord(config))"
        }
        return command
    }

    /// The printed retry command is meant to be pasted into a shell, so any
    /// argument outside a conservative safe set is POSIX single-quoted.
    static func shellWord(_ value: String) -> String {
        let safe = !value.isEmpty && value.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_./:=@%+,".unicodeScalars.contains($0)
        }
        return safe ? value : "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Prepares the signed row's pinned snapshot through the serve/autotune
    /// resolver (`CachedModelArtifactResolver.verifiedArtifact`): HF download
    /// with in-run resume, canonical verification, durable-store adoption. It
    /// never changes config or the active model.
    static func prepare(
        row: ModelArtifactSignedRow,
        resolver: CachedModelArtifactResolver,
        repairCache: Bool,
        configuredArtifactPath: String? = nil,
        config: String? = nil,
        freeSpace: FreeSpace = defaultFreeSpace,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> ModelPrepareOutcome {
        let retry = retryCommand(catalogKey: row.catalogKey, config: config)
        let found = ModelArtifactDiagnostics.findPartials(row: row, resolver: resolver)
        var removed: [ModelArtifactPartial] = []
        var failures: [String] = []
        if repairCache, !found.isEmpty {
            (removed, failures) = ModelArtifactDiagnostics.removePartials(found, row: row, resolver: resolver)
            progress?("repair-cache: removed \(removed.count) interrupted download artifact(s) for \(row.catalogKey)")
        }
        let initial = ModelArtifactDiagnostics.diagnose(
            row: row,
            resolver: resolver,
            configuredArtifactPath: configuredArtifactPath
        )
        var outcome = ModelPrepareOutcome(
            finalState: .incomplete,
            diagnosis: initial,
            requiredBytes: nil,
            availableBytes: nil,
            partialsFound: found,
            partialsRemoved: removed,
            downloadAttempted: false,
            error: nil,
            retryCommand: retry,
            cleanupFailures: failures,
            repairCacheRequested: repairCache
        )
        if initial.verdict == .match {
            // Serve loads a configured or durable copy, never the Hugging
            // Face cache, so a match there is ready only once adopted into
            // the durable store and verified where serve loads it (#1689 F5).
            if let kind = initial.locationKind, [.hfSnapshot, .hfPrefetch].contains(kind), let matched = initial.localPath {
                do {
                    _ = try resolver.verifiedExistingArtifact(for: row.catalogRow, at: matched)
                } catch {
                    outcome.error = "could not adopt the verified snapshot into the durable store: \(error)"
                }
                outcome.diagnosis = ModelArtifactDiagnostics.diagnose(
                    row: row,
                    resolver: resolver,
                    configuredArtifactPath: configuredArtifactPath
                )
            }
            return finalize(outcome)
        }
        if initial.verdict == .mismatch, initial.likelySource == .catalogRow {
            outcome.finalState = .hashMismatch
            outcome.retryCommand = nil
            return outcome
        }
        // The resolver replaces an unverifiable pinned copy (HF snapshot or
        // durable store) with verified bytes. A failing configured or durable
        // copy is what serve loads, so it alone is named; otherwise no pinned
        // location verified above and any that exists is failing. Only the
        // explicit repair flag may replace one (SPEC-010-R008).
        let pinnedSnapshot = resolver.snapshotURL(modelID: row.modelID, revision: row.revision)
        let decisive: Set<ModelArtifactLocationKind> = [.configuredPath, .durableStore]
        let failing = ModelArtifactDiagnostics.candidateLocations(
            row: row,
            resolver: resolver,
            configuredArtifactPath: configuredArtifactPath
        ).filter { ModelArtifactDiagnostics.isDirectory($0.1) }
            .filter { initial.locationKind.map(decisive.contains) != true || $0.0 == initial.locationKind }
        if !repairCache, !failing.isEmpty {
            let kinds = failing.map(\.0.rawValue).joined(separator: ", ")
            outcome.error = "the pinned copy (\(kinds)) exists but does not verify; rerun with --repair-cache to replace it"
            return outcome
        }

        if let size = row.artifactSizeBytes, size > 0 {
            let hubVolume = existingAncestor(of: resolver.hubRoot)
            let durableVolume = existingAncestor(of: resolver.durableRoot)
            let sameVolume = volumeIdentifier(hubVolume) != nil
                && volumeIdentifier(hubVolume) == volumeIdentifier(durableVolume)
            let required = Int64(size) * (sameVolume ? 2 : 1)
            let available = freeSpace(hubVolume)
            outcome.requiredBytes = required
            outcome.availableBytes = available
            if let available, available < required {
                outcome.error = "insufficient_disk_space required_bytes=\(required) available_bytes=\(available)"
                return outcome
            }
            if !sameVolume, let durableAvailable = freeSpace(durableVolume), durableAvailable < Int64(size) {
                outcome.error = "insufficient_disk_space durable_store required_bytes=\(size) available_bytes=\(durableAvailable)"
                return outcome
            }
            progress?("disk: needs ~\(formatBytes(required)), \(available.map(formatBytes) ?? "unknown") free")
        } else {
            progress?("disk: requirement unknown (no bound signed artifact size)")
        }

        outcome.downloadAttempted = true
        progress?("downloading \(row.modelID)@\(row.revision)")
        let monitor = progress.map { report in
            startProgressMonitor(
                snapshots: pinnedSnapshot.deletingLastPathComponent(),
                expectedBytes: row.artifactSizeBytes,
                report: report
            )
        }
        do {
            _ = try await resolver.verifiedArtifact(for: row.catalogRow)
        } catch {
            outcome.error = String(describing: error)
        }
        monitor?.cancel()

        outcome.diagnosis = ModelArtifactDiagnostics.diagnose(
            row: row,
            resolver: resolver,
            configuredArtifactPath: configuredArtifactPath
        )
        return finalize(outcome)
    }

    private static func finalize(_ outcome: ModelPrepareOutcome) -> ModelPrepareOutcome {
        var outcome = outcome
        let servedFrom: Set<ModelArtifactLocationKind> = [.configuredPath, .durableStore]
        switch (outcome.diagnosis.verdict, outcome.diagnosis.likelySource) {
        case (.match, _) where outcome.diagnosis.locationKind.map(servedFrom.contains) == true:
            outcome.finalState = .readyVerified
            outcome.retryCommand = nil
            outcome.error = nil
        case (.mismatch, .catalogRow):
            outcome.finalState = .hashMismatch
            outcome.retryCommand = nil
        default:
            outcome.finalState = .incomplete
        }
        return outcome
    }

    static let defaultFreeSpace: FreeSpace = { url in
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else {
            return nil
        }
        return capacity
    }

    private static func existingAncestor(of url: URL) -> URL {
        var current = url.standardizedFileURL
        while current.path != "/", !FileManager.default.fileExists(atPath: current.path) {
            current.deleteLastPathComponent()
        }
        return current
    }

    private static func volumeIdentifier(_ url: URL) -> String? {
        guard let value = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return nil
        }
        return String(describing: value)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The downloader moves each finished file into a `.download-*` staging
    /// directory, so summing that directory gives per-file progress without
    /// touching the downloader.
    private static func startProgressMonitor(
        snapshots: URL,
        expectedBytes: Int?,
        report: @escaping @Sendable (String) -> Void
    ) -> Task<Void, Never> {
        Task.detached {
            var last: Int64 = -1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
                let staged = names.filter { $0.hasPrefix(".download-") }.reduce(Int64(0)) {
                    $0 + (ModelArtifactDiagnostics.regularFileBytes(in: snapshots.appendingPathComponent($1)) ?? 0)
                }
                guard staged != last else { continue }
                last = staged
                let total = expectedBytes.map { " of ~" + formatBytes(Int64($0)) } ?? ""
                report("downloaded \(formatBytes(staged))\(total) (completed files)")
            }
        }
    }

    static func humanText(_ outcome: ModelPrepareOutcome) -> String {
        var lines: [String] = []
        let row = outcome.diagnosis.row
        lines.append("model:     \(row.catalogKey) (\(row.modelID)@\(row.revision))")
        if !outcome.partialsFound.isEmpty {
            lines.append(
                "partials:  \(outcome.partialsFound.count) found, \(outcome.partialsRemoved.count) removed"
                    + (!outcome.repairCacheRequested && outcome.partialsRemoved.count < outcome.partialsFound.count
                        ? " (pass --repair-cache to remove interrupted downloads)" : "")
            )
        }
        if !outcome.cleanupFailures.isEmpty {
            let failures = outcome.cleanupFailures
                .map { ModelArtifactDiagnostics.redact($0, diagnosis: outcome.diagnosis) }
                .joined(separator: "; ")
            lines.append("warning:   --repair-cache could not remove \(outcome.cleanupFailures.count) interrupted download artifact(s): \(failures); remove them by hand")
        }
        if let required = outcome.requiredBytes {
            lines.append("disk:      needs ~\(formatBytes(required)), \(outcome.availableBytes.map(formatBytes) ?? "unknown") free")
        }
        lines.append("hash:      \(outcome.diagnosis.computedSHA256 ?? "none") (signed \(row.sha256))")
        if let error = outcome.error {
            lines.append("error:     \(ModelArtifactDiagnostics.redact(error, diagnosis: outcome.diagnosis))")
        }
        lines.append("final:     \(outcome.finalLine)")
        return lines.joined(separator: "\n")
    }
}

/// `models prepare --profile catalog` entry point, kept out of the Lane A
/// command body so that staging transaction is unchanged.
enum ModelsCatalogPrepareRunner {
    static let profile = "catalog"

    static func run(key: String, repairCache: Bool, emitJSON: Bool, config: String?) async throws {
        let appConfig = try loadDiagnosticsConfig(config, command: "models prepare")
        let row: ModelArtifactSignedRow
        do {
            row = try await ModelArtifactSignedRowResolver.resolve(key: key)
        } catch {
            writeDiagnosticsStderr("models prepare refused: \(error)")
            throw ExitCode(2)
        }
        let resolver = CachedModelArtifactResolver.forConfig(appConfig)
        let configuredPath = appConfig.modelCatalogKey == row.catalogKey ? appConfig.modelArtifactPath : nil
        var progress: (@Sendable (String) -> Void)?
        if !emitJSON && isatty(STDERR_FILENO) != 0 {
            progress = { writeDiagnosticsStderr("models prepare: " + $0) }
        }
        let outcome = await ModelCatalogPreparation.prepare(
            row: row,
            resolver: resolver,
            repairCache: repairCache,
            configuredArtifactPath: configuredPath,
            config: config,
            progress: progress
        )
        if emitJSON {
            try printDiagnosticsJSON(outcome.jsonObject)
        } else {
            print(ModelCatalogPreparation.humanText(outcome))
        }
        switch outcome.finalState {
        case .readyVerified:
            return
        case .hashMismatch:
            throw ExitCode(3)
        case .incomplete:
            throw ExitCode(2)
        }
    }
}

/// Loads the config the diagnostics commands resolve roots from. A config
/// that fails to load refuses the command (exit 2) instead of silently
/// falling back to the default roots, where `--repair-cache` would act.
func loadDiagnosticsConfig(_ path: String?, command: String) throws -> AppConfig {
    do {
        return try ConfigLoader.load(cli: CLIOverrides(configPath: path))
    } catch {
        writeDiagnosticsStderr("\(command) refused: config could not be loaded: \(error)")
        throw ExitCode(2)
    }
}

func printDiagnosticsJSON(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func writeDiagnosticsStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
