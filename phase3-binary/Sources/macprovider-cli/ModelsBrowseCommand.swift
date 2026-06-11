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

    func run() async throws {
        guard limit > 0 else {
            writeStderr("--limit must be positive")
            throw ExitCode(2)
        }

        let client = HFClient.fromEnvironment()
        let summaries: [HFModelSummary]
        do {
            summaries = try await client.searchMLXCommunity(query: family, limit: limit)
        } catch let error as HFClientError {
            writeStderr("\(error)")
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
            print("\(row.id)\t\(est)\t\(verdictLabel(row.verdict))")
        }
        let summary = rows.isEmpty
            ? "no models match the current filters on a \(ramGB) GB Mac"
            : "\(rows.count) models on a \(ramGB) GB Mac"
        FileHandle.standardError.write(Data((summary + "\n").utf8))
    }
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
