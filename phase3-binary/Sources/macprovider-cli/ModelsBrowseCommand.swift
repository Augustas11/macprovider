import ArgumentParser
import Foundation
import MacProviderCore

struct ModelsBrowseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browse",
        abstract: "Browse mlx-community models on HuggingFace and check which fit this Mac."
    )

    @Option(help: "Substring filter passed to HuggingFace search (e.g. 'qwen', 'llama').")
    var family: String?

    @Option(help: "Max number of results to fetch from HuggingFace.")
    var limit: Int = 30

    @Flag(help: "Show only models that fit this Mac comfortably (drops .tight and .wontFit).")
    var fitsOnly = false

    @Option(help: "Drop models whose estimated weight size exceeds this many GB.")
    var maxGb: Int?

    static let maxAllowedLimit = 200

    func run() async throws {
        // Round-2 (codex code MINOR + security MINOR): cap --limit to bound
        // memory + network use; reject non-positive --max-gb.
        guard limit > 0 && limit <= Self.maxAllowedLimit else {
            writeStderr("--limit must be between 1 and \(Self.maxAllowedLimit)")
            throw ExitCode(2)
        }
        if let maxGb, maxGb <= 0 {
            writeStderr("--max-gb must be positive")
            throw ExitCode(2)
        }

        let client = HFClient.fromEnvironment()
        let summaries: [HFModelSummary]
        do {
            summaries = try await client.searchMLXCommunity(query: family, limit: limit)
        } catch let error as HFClientError {
            writeStderr("\(error)")
            throw ExitCode(4)
        } catch {
            // Round-2 (codex code MAJOR): raw URLSession errors (DNS, TLS,
            // offline, request timeout) previously escaped to ArgumentParser's
            // default handler and produced an ugly stack-trace-style exit.
            // Route them through ExitCode(4) with a one-line message.
            writeStderr("HuggingFace request failed: \(error.localizedDescription)")
            throw ExitCode(4)
        }

        let ramGB = ModelFit.detectRAMGB()
        let rows = filterAndAnnotate(
            summaries: summaries,
            ramGB: ramGB,
            fitsOnly: fitsOnly,
            maxGB: maxGb
        )
        renderTable(rows: rows, ramGB: ramGB)
    }

    private func renderTable(rows: [BrowseRow], ramGB: Int) {
        print("model_id\test_gb\tfit")
        for row in rows {
            let est = row.estimateGB.map { "\($0)" } ?? "?"
            print("\(sanitizeForTable(row.id))\t\(est)\t\(verdictLabel(row.verdict))")
        }
        let summary = rows.isEmpty
            ? "no models match the current filters on a \(ramGB) GB Mac"
            : "\(rows.count) models on a \(ramGB) GB Mac"
        FileHandle.standardError.write(Data((summary + "\n").utf8))
    }
}

/// HF-returned ids are user content (anyone can publish to HuggingFace).
/// Strip C0 controls (U+0000-U+001F), DEL (U+007F), AND C1 controls
/// (U+0080-U+009F) so a malicious model name can't break the tab-separated
/// rendering or paint terminal escape sequences. R2 originally covered
/// C0+DEL only; R3 extends to C1 after the Codex round-2 audit flagged
/// U+009B CSI as an escape vector. Above U+009F (printable Unicode +
/// bidi/zero-width controls) is preserved — bidi attacks are a separate
/// homoglyph concern and would need a different mitigation than
/// substitution.
func sanitizeForTable(_ raw: String) -> String {
    var out = String()
    out.reserveCapacity(raw.count)
    for scalar in raw.unicodeScalars {
        let isC0OrDel = scalar.value < 0x20 || scalar.value == 0x7F
        let isC1 = (0x80...0x9F).contains(scalar.value)
        if isC0OrDel || isC1 {
            out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

struct BrowseRow: Sendable, Equatable {
    let id: String
    let estimateGB: Int?
    let verdict: ModelFit.Verdict
}

/// Annotate HF results with fit verdicts and apply the user-facing filters.
/// Free function so tests can exercise it without driving the command-line
/// parser.
func filterAndAnnotate(
    summaries: [HFModelSummary],
    ramGB: Int,
    fitsOnly: Bool,
    maxGB: Int?
) -> [BrowseRow] {
    var rows: [BrowseRow] = []
    rows.reserveCapacity(summaries.count)
    for summary in summaries {
        let estimate = ModelFit.estimateWeightSizeGB(modelID: summary.id)
        let verdict = ModelFit.evaluate(modelID: summary.id, ramGB: ramGB)
        if let maxGB, let estimate, estimate > maxGB {
            continue
        }
        if fitsOnly {
            guard case .fits = verdict else { continue }
        }
        rows.append(BrowseRow(id: summary.id, estimateGB: estimate, verdict: verdict))
    }
    return rows
}

func verdictLabel(_ verdict: ModelFit.Verdict) -> String {
    switch verdict {
    case .fits: return "fits"
    case .tight: return "tight"
    case .wontFit: return "wont_fit"
    case .unknown: return "unknown"
    }
}

private func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
