import Foundation
import MacProviderCore

/// Read-only inventory of the exact primary MLX targets authorized by the
/// qualified feed. Storage paths never become candidate identity or wire data.
struct DurableModelDiscovery {
    let root: URL
    let namespace: Data?
    var namespaceWarnings: [BYOMDiscoveryWarning] = []
    let catalogMatcher: BYOMCatalogMatcher
    var fileManager: FileManager = .default
    var localInspection: ModelCatalogLocalInspection? = nil

    func discover() -> [BYOMDiscoveryWire.Candidate] {
        let store = DurableModelArtifactStore(root: root, fileManager: fileManager)
        let builder = BYOMMLXCacheDiscovery(
            cacheRoot: root, namespace: namespace, namespaceWarnings: namespaceWarnings,
            catalogMatcher: catalogMatcher, fileManager: fileManager
        )
        let groups = Dictionary(grouping: catalogMatcher.durableTargets) {
            BYOMCandidateIdentity.normalizedServedModelRef($0.modelID)
        }
        return groups.keys.sorted().compactMap { key in
            guard let targets = groups[key], let target = targets.first,
                  let revision = target.identity.sourceRef.revision,
                  let directory = try? store.artifactURL(
                    modelID: target.modelID, revision: revision, sha256: target.identity.hash
                  ) else { return nil }
            if let localInspection {
                let identity = ModelCatalogLocalInspection.Key(modelKey: target.identity.catalogKey,
                    modelID: target.modelID, revision: revision, sha256: target.identity.hash)
                // The command pre-populates this map under one throwing request
                // budget. Consumers never hash or convert lookup failure to absence.
                let entry = localInspection.entry(for: identity)
                let ready = targets.count == 1 && entry?.state == .verified
                return builder.buildCandidate(
                    servedModelRef: target.modelID, revisions: [revision],
                    readinessState: ready ? "ready" : "needs_weights",
                    estimatedGB: ModelFit.estimateWeightSizeGB(modelID: target.modelID).map(Double.init),
                    contextWindowTokens: ready ? entry?.inspection?.configJSONData.flatMap(BYOMDiscoveryJSON.contextWindowTokens) : nil,
                    warningCodes: ready ? [] : [.requiresPreparation])
            }
            // A missing exact revision/hash under an existing model directory
            // means preparation is required. Do not substitute a sibling copy.
            let modelDirectory = directory.deletingLastPathComponent().deletingLastPathComponent()
            var modelStat = stat()
            guard lstat(modelDirectory.path, &modelStat) == 0 else { return nil }
            var inspection: ModelArtifactVerifier.CanonicalArtifactInspection?
            if targets.count == 1, isCanonicalDirectory(root),
               (try? store.validatedContainedDirectory(directory.path)) != nil {
                inspection = try? ModelArtifactVerifier.inspectCanonicalArtifact(directory: directory)
            }
            let ready = inspection?.sha256 == target.identity.hash && inspection?.configJSONData != nil
            return builder.buildCandidate(
                servedModelRef: target.modelID,
                revisions: [revision],
                readinessState: ready ? "ready" : "needs_weights",
                estimatedGB: ModelFit.estimateWeightSizeGB(modelID: target.modelID).map(Double.init),
                contextWindowTokens: ready ? inspection?.configJSONData.flatMap(BYOMDiscoveryJSON.contextWindowTokens) : nil,
                warningCodes: ready ? [] : [.requiresPreparation]
            )
        }
    }

    private func isCanonicalDirectory(_ directory: URL) -> Bool {
        let canonical = directory.standardizedFileURL
        var info = stat()
        return canonical.path == canonical.resolvingSymlinksInPath().path
            && lstat(canonical.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
