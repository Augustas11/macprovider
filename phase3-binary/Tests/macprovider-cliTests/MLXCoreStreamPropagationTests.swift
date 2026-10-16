import Foundation
import XCTest

/// MLX core must keep every internal op on the caller's stream (#2028).
///
/// mlx-swift runs every op on its own pooled GPU stream. A stream-taking core
/// op that creates an internal cast, broadcast or arithmetic op without that
/// stream puts it on the thread's default stream: a second Metal queue, with a
/// cross-queue event wait and a separate submit per op. gpt-oss-20b decode lost
/// 30% to 140 such casts per token. These tests run
/// `scripts/check_mlx_core_streams.py` against the resolved core sources, and
/// check that the resolved core is the reviewed one (SPEC-048 R003), so a core
/// rebase that reintroduces a stream-less internal op fails here.
final class MLXCoreStreamPropagationTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let repositoryRoot = packageRoot.deletingLastPathComponent()
    private static let mlxSwiftCheckout = packageRoot.appendingPathComponent(".build/checkouts/mlx-swift")
    private static let coreRoot = mlxSwiftCheckout.appendingPathComponent("Source/Cmlx/mlx")

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func requireResolvedCore() throws {
        let ops = Self.coreRoot.appendingPathComponent("mlx/ops.h")
        guard FileManager.default.fileExists(atPath: ops.path) else {
            XCTFail("resolved MLX core source missing: \(ops.path)")
            throw XCTSkip("no core checkout")
        }
    }

    func testResolvedCoreKeepsEveryInternalOpOnTheCallersStream() throws {
        try requireResolvedCore()
        let script = Self.repositoryRoot.appendingPathComponent("scripts/check_mlx_core_streams.py")
        let result = try run("/usr/bin/env", ["python3", "-I", script.path, Self.coreRoot.path])
        XCTAssertEqual(
            result.status, 0,
            "MLX core runs internal ops off the caller's stream; pass the stream at each site:\n\(result.output)"
        )
    }

    func testResolvedCoreIsTheReviewedForkRevision() throws {
        try requireResolvedCore()
        let pins = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("scripts/read_swiftpm_pins.py"),
            encoding: .utf8
        )
        let pattern = try NSRegularExpression(pattern: #"SPEC048_MLX_CORE_REVISION = "([0-9a-f]{40})""#)
        guard let match = pattern.firstMatch(in: pins, range: NSRange(pins.startIndex..., in: pins)),
              let range = Range(match.range(at: 1), in: pins)
        else {
            return XCTFail("SPEC048_MLX_CORE_REVISION not found in read_swiftpm_pins.py")
        }
        let reviewed = String(pins[range])
        let swiftPattern = try NSRegularExpression(pattern: #"SPEC048_MLX_SWIFT_REVISION = "([0-9a-f]{40})""#)
        guard let swiftMatch = swiftPattern.firstMatch(in: pins, range: NSRange(pins.startIndex..., in: pins)),
              let swiftRange = Range(swiftMatch.range(at: 1), in: pins)
        else {
            return XCTFail("SPEC048_MLX_SWIFT_REVISION not found in read_swiftpm_pins.py")
        }
        let reviewedSwift = String(pins[swiftRange])

        // #2028 audit carry: the mlx-swift checkout itself must be the reviewed
        // revision and unmodified, so its gitlink is the one that was reviewed.
        let swiftHead = try run("/usr/bin/env", ["git", "-C", Self.mlxSwiftCheckout.path, "rev-parse", "HEAD"])
        XCTAssertEqual(swiftHead.status, 0, swiftHead.output)
        XCTAssertEqual(
            swiftHead.output.trimmingCharacters(in: .whitespacesAndNewlines), reviewedSwift,
            "the resolved mlx-swift checkout is not SPEC048_MLX_SWIFT_REVISION"
        )
        let swiftStatus = try run(
            "/usr/bin/env",
            ["git", "-C", Self.mlxSwiftCheckout.path, "status", "--porcelain", "--ignore-submodules=dirty"]
        )
        XCTAssertEqual(swiftStatus.status, 0, swiftStatus.output)
        XCTAssertTrue(
            swiftStatus.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the resolved mlx-swift checkout has local changes:\n\(swiftStatus.output)"
        )
        // #2028 audit carry (INFO): the core submodule must point at the core fork.
        // `.gitmodules` names it by an arbitrary key, so find it by its path.
        let submodules = try run(
            "/usr/bin/env",
            ["git", "-C", Self.mlxSwiftCheckout.path, "config", "-f", ".gitmodules", "--get-regexp", #"^submodule\..*\.(path|url)$"#]
        )
        XCTAssertEqual(submodules.status, 0, submodules.output)
        var paths: [String: String] = [:]
        var urls: [String: String] = [:]
        for line in submodules.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0].hasSuffix(".path") { paths[String(parts[0].dropLast(5))] = parts[1] }
            if parts[0].hasSuffix(".url") { urls[String(parts[0].dropLast(4))] = parts[1] }
        }
        let coreKeys = paths.filter { $0.value == "Source/Cmlx/mlx" }.map(\.key)
        XCTAssertEqual(coreKeys.count, 1, "expected one .gitmodules entry for Source/Cmlx/mlx: \(submodules.output)")
        let url = coreKeys.first.flatMap { urls[$0] } ?? ""
        XCTAssertTrue(
            ["https://github.com/Augustas11/mlx", "https://github.com/Augustas11/mlx.git"].contains(url),
            "mlx-swift's Source/Cmlx/mlx submodule is not the Augustas11/mlx core fork: \(url)"
        )

        let gitlink = try run("/usr/bin/env", ["git", "-C", Self.mlxSwiftCheckout.path, "ls-tree", "HEAD", "Source/Cmlx/mlx"])
        XCTAssertEqual(gitlink.status, 0, gitlink.output)
        XCTAssertTrue(
            gitlink.output.contains("commit \(reviewed)"),
            "mlx-swift's Source/Cmlx/mlx gitlink is not the reviewed core \(reviewed): \(gitlink.output)"
        )
        let head = try run("/usr/bin/env", ["git", "-C", Self.coreRoot.path, "rev-parse", "HEAD"])
        XCTAssertEqual(head.status, 0, head.output)
        XCTAssertEqual(
            head.output.trimmingCharacters(in: .whitespacesAndNewlines), reviewed,
            "the checked-out core sources are not the reviewed core revision"
        )
    }
}
