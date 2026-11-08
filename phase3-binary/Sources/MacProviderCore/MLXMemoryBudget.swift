import Foundation

/// SPEC-038 FR-CB2 (v0.3.36): MLX's process memory limit below Metal's
/// recommended working set, and the admission check that keeps continuous
/// batching and native-MTP rounds under it.
///
/// MLX defaults its limit to `min(1.5 x working set, 0.95 x RAM)`, which is
/// above the working set on every Mac, so the provider could ask Metal to make
/// more bytes resident than it can hold. The limit here sits at 90% of the
/// working set and never above 90% of physical RAM (the SPEC-048-R012 10%
/// free-memory floor). On a 256 GB M3 Ultra (working set 239.14 GB) that is
/// 215.2 GB, at the size of the largest IOGPU `prepare` fault observed while
/// GLM-5.3-Flash served there (198-215 GB prepared, #2249).
public enum MLXMemoryBudget {
    /// Headroom below the working set: `workingSet / 10` (10%).
    public static let workingSetHeadroomDivisor = 10
    /// SPEC-048-R012: at least `physical / 10` stays outside MLX's limit.
    public static let physicalFreeFloorDivisor = 10
    /// Workspace kept above the loaded model by the small-Mac floor.
    public static let minimumWorkspaceBytes = 512 * 1024 * 1024

    /// The limit to set, or nil when Metal reports no working set (MLX's
    /// default then stays). `residentBytes` is MLX's active memory once the
    /// model is loaded: a model that fits the working set but not the 90%
    /// cap keeps `residentBytes + minimumWorkspaceBytes`, never more than
    /// the working set, so small Macs still load and serve it.
    public static func limitBytes(
        recommendedWorkingSetBytes: Int?,
        physicalMemoryBytes: UInt64,
        residentBytes: Int = 0
    ) -> Int? {
        guard let workingSet = recommendedWorkingSetBytes, workingSet > 0 else { return nil }
        var cap = workingSet - workingSet / workingSetHeadroomDivisor
        let physical = Int(clamping: physicalMemoryBytes)
        if physical > 0 {
            cap = min(cap, physical - physical / physicalFreeFloorDivisor)
        }
        let (floorBytes, overflow) = max(0, residentBytes).addingReportingOverflow(minimumWorkspaceBytes)
        let floor = min(workingSet, overflow ? Int.max : floorBytes)
        return max(cap, floor)
    }

    /// Bytes `tokens` more KV tokens take at `bytesPerToken` (0 when either
    /// is unknown or non-positive), saturating.
    public static func kvBytes(tokens: Int, bytesPerToken: Int) -> Int {
        guard tokens > 0, bytesPerToken > 0 else { return 0 }
        let (bytes, overflow) = tokens.multipliedReportingOverflow(by: bytesPerToken)
        return overflow ? Int.max : bytes
    }

    /// True when `activeBytes + requestedBytes` stays at or under `limitBytes`.
    public static func admits(activeBytes: Int, requestedBytes: Int, limitBytes: Int) -> Bool {
        let (total, overflow) = max(0, activeBytes).addingReportingOverflow(max(0, requestedBytes))
        return !overflow && total <= limitBytes
    }
}
