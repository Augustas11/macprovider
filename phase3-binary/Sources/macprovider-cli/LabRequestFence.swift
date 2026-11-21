#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation

/// Lab-only (#2448): a request set that names its own batch-composition fence
/// through its request ids, so a lab client of `serve` can hold one cell of
/// concurrent rows as one fixed admission.
///
/// A request whose id is `labfence-<token>-<rows>-<index>` (token 1-64
/// ASCII letters or digits, rows 1...64, index 0..<rows) names the fence
/// `labfence-<token>-<rows>-0` ... `labfence-<token>-<rows>-<rows - 1>`. The
/// first such row to reach an idle scheduler installs that composition
/// (`ContinuousBatchScheduler.installLabBatchComposition`): the pump stays
/// stopped until every named row is queued, then the rows are consumed in
/// index order and take admission sequences in index order, so prefill
/// order, decode row order and the waves the scheduler forms do not depend on
/// the order the HTTP requests happened to arrive in.
///
/// This fixes admission only. It does not change a kernel, a forward width or
/// a token: the rows still decode through the served route (on `stock_order`
/// a 3-16-row forward still takes the batch kernel). A fence row that never
/// arrives holds the pump until the rows already queued time out, so only
/// lab clients that send every row of a cell use it.
enum LabRequestFence {
    static let prefix = "labfence-"
    static let maximumRows = 64

    /// The fence `requestID` names, in index order, or nil when it names none.
    static func composition(forRequestID requestID: String) -> [String]? {
        guard requestID.hasPrefix(prefix) else { return nil }
        let parts = requestID.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let token = parts[0]
        guard (1 ... 64).contains(token.count),
              token.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }),
              let rows = decimal(parts[1]), (1 ... maximumRows).contains(rows),
              let index = decimal(parts[2]), index < rows
        else { return nil }
        return (0 ..< rows).map { "\(prefix)\(token)-\(rows)-\($0)" }
    }

    /// A canonical non-negative decimal (no sign, no leading zero).
    private static func decimal(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 3, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              text == "0" || text.first != "0" else { return nil }
        return Int(text)
    }
}
#endif
