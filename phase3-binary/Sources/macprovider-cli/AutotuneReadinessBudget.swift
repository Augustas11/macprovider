import Foundation

/// Cold loading scales with residency. Keep the old budget for small/unknown
/// models and allow large artifacts up to 30 minutes; the runner separately
/// clamps this allowance to the campaign deadline and polls for process exit.
enum AutotuneReadinessBudget {
    static let floorSeconds: TimeInterval = 120
    static let ceilingSeconds: TimeInterval = 1800

    private static let bakedCatalog = try? JSONDecoder().decode(
        CandidateCatalog.self,
        from: Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
    )

    static func seconds(model: String, artifactBinding: CandidateArtifactBinding? = nil) -> TimeInterval {
        let footprintGB: Double
        if let bytes = artifactBinding?.sizeBytes, bytes > 0 {
            footprintGB = Double(bytes) / 1_073_741_824
        } else {
            let row = bakedCatalog?.rows[model]
                ?? bakedCatalog?.rows.values.first(where: { $0.modelID == model })
            footprintGB = Double(artifactBinding?.minRAMGB ?? row?.minRAMGB ?? 0)
        }
        return max(floorSeconds, min(ceilingSeconds, footprintGB * 10))
    }
}
