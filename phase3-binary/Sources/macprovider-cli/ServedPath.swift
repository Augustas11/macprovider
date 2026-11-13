import Foundation

/// Issue #2341 (SPEC-001/SPEC-002): the path that served one coordinator relay
/// request, sent once as the top-level `served_path` member of the ordinary
/// `inference_response_end` frame. It labels a telemetry sample; it is not part
/// of `usage` or of anything a SPEC-015 receipt signs.
struct ServedPath: Sendable, Equatable {
    enum Path: String, Sendable {
        case serial
        case continuousBatching = "continuous_batching"
        case nativeMTP = "native_mtp"
        case shardGroup = "shard_group"
    }

    static let rowRange = 1...256
    static let serial = ServedPath(path: .serial, rows: 1)
    /// The shard group head pipelines requests through its stages; their row
    /// count is not measured, so a shard group sample reports one row.
    static let shardGroup = ServedPath(path: .shardGroup, rows: 1)

    let path: Path
    let rows: Int

    init(path: Path, rows: Int) {
        self.path = path
        self.rows = min(Self.rowRange.upperBound, max(Self.rowRange.lowerBound, rows))
    }

    /// A continuous-batching row: native MTP when at least half of the row's own
    /// decode steps proposed native-MTP draft tokens; rows is the mean active row
    /// count (prefilling plus decoding, this row included) over those steps,
    /// rounded to nearest. A row with no decode step reports one row.
    static func continuousBatching(
        decodeSteps: UInt64,
        nativeMTPSteps: UInt64,
        activeRowSum: UInt64
    ) -> ServedPath {
        guard decodeSteps > 0 else { return ServedPath(path: .continuousBatching, rows: 1) }
        let (doubled, overflow) = nativeMTPSteps.multipliedReportingOverflow(by: 2)
        let nativeMTP = overflow || doubled >= decodeSteps
        let mean = activeRowSum / decodeSteps
            + (activeRowSum % decodeSteps >= decodeSteps - decodeSteps / 2 ? 1 : 0)
        return ServedPath(path: nativeMTP ? .nativeMTP : .continuousBatching, rows: Int(clamping: mean))
    }

    var wireObject: [String: Any] {
        ["path": path.rawValue, "rows": rows]
    }
}
