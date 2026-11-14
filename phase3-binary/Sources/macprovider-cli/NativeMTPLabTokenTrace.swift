import Foundation
import MLX

#if DEBUG || MACPROVIDER_LAB_HARNESS
/// Lab-only (#2328), on only with `MACPROVIDER_MTP_TOKEN_TRACE=1`: one line
/// per committed token of a request's first `limit` sampler steps, from the
/// forward that chose it. Two runs of the same prompt (ordinary decode and
/// native MTP) diff offline: the first `idx` whose `token` differs is the
/// divergence, and its `col`, `src` and both `margin`s say whether the native
/// token came from verify column 0 (the decode position) or a later column,
/// and how close the tie was. Token ids only, no text.
enum NativeMTPLabTokenTrace {
    static let enabled = ProcessInfo.processInfo.environment["MACPROVIDER_MTP_TOKEN_TRACE"] == "1"
    static let limit = 64

    struct Entry: Equatable {
        /// Sampler step of the committed token.
        let index: Int
        /// Column of the forward whose logits chose it, and that forward's width.
        let column: Int
        let width: Int
        /// `draft`: the token equals an accepted proposal; `target`: the
        /// forward's own pick after the accepted prefix (or a decode step).
        let source: String
        let token: Int
        let top1: Int
        let top2: Int
        let margin: Float
        /// Row KV length before the forward and after the commit.
        let kvBefore: Int
        let kvAfter: Int
    }

    /// Top-2 token ids and the logit margin between them, per row of
    /// `[columns, vocab]` logits. Ties resolve to the lower id, as argmax does.
    static func topTwo(_ logits: MLXArray) -> [(top1: Int, top2: Int, margin: Float)] {
        let values = logits.asType(.float32)
        let top1 = argMax(values, axis: -1)
        let ids = MLXArray.arange(values.dim(-1)).reshaped([1, -1])
        let rest = which(ids .== top1.reshaped([-1, 1]), MLXArray(-Float.infinity), values)
        let top2 = argMax(rest, axis: -1)
        let margin = values.max(axis: -1) - rest.max(axis: -1)
        eval(top1, top2, margin)
        let first = top1.asType(.int32).asArray(Int32.self)
        let second = top2.asType(.int32).asArray(Int32.self)
        let gaps = margin.asArray(Float.self)
        return (0 ..< first.count).map { (Int(first[$0]), Int(second[$0]), gaps[$0]) }
    }

    /// The committed tokens of one verify forward over
    /// `[current, proposals...]`: the accepted proposals, then the target's
    /// pick at the first mismatch (or the bonus column).
    static func verifyEntries(
        samplerStep: Int,
        proposals: [Int],
        targets: [Int],
        tops: [(top1: Int, top2: Int, margin: Float)],
        kvBefore: Int
    ) -> [Entry] {
        guard targets.count == proposals.count + 1, tops.count == targets.count else { return [] }
        var accepted = 0
        while accepted < proposals.count, targets[accepted] == proposals[accepted] { accepted += 1 }
        return (0 ... accepted).compactMap { column in
            guard samplerStep + column < limit else { return nil }
            return Entry(
                index: samplerStep + column, column: column, width: targets.count,
                source: column < accepted ? "draft" : "target", token: targets[column],
                top1: tops[column].top1, top2: tops[column].top2, margin: tops[column].margin,
                kvBefore: kvBefore, kvAfter: kvBefore + accepted + 1
            )
        }
    }

    static func line(requestID: String, path: String, _ entry: Entry) -> String {
        "[mtp-token] req=\(requestID) path=\(path) idx=\(entry.index) col=\(entry.column) width=\(entry.width)"
            + " src=\(entry.source) token=\(entry.token) top1=\(entry.top1) top2=\(entry.top2)"
            + " margin=\(entry.margin) kv=\(entry.kvBefore)->\(entry.kvAfter)\n"
    }

    static func write(requestID: String, path: String, _ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        let text = entries.map { line(requestID: requestID, path: path, $0) }.joined()
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }
}
#endif
