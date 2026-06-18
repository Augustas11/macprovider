import ArgumentParser
import XCTest
@testable import macprovider_cli

final class AutotuneCommandTests: XCTestCase {
    func testDefaultCandidatePlanIsLargestFirst() throws {
        let command = try AutotuneCommand.parse(["--dry-run"])
        let plan = try command.candidatePlan()

        XCTAssertEqual(plan.source, .defaultList)
        XCTAssertEqual(plan.candidates, [
            "mlx-community/Qwen2.5-32B-Instruct-4bit",
            "mlx-community/Qwen2.5-14B-Instruct-4bit",
            "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            "mlx-community/Llama-3.2-1B-Instruct-4bit",
        ])
    }

    func testExplicitCandidateOrderBeatsSizeFlags() throws {
        let command = try AutotuneCommand.parse([
            "--candidate-models", "one,two",
            "--max-model-size", "7B",
            "--min-model-size", "3B",
            "--dry-run",
        ])
        let plan = try command.candidatePlan()

        XCTAssertEqual(plan.source, .explicit)
        XCTAssertEqual(plan.candidates, ["one", "two"])
        XCTAssertEqual(plan.warning, "warning: --candidate-models supplied; ignoring --max-model-size/--min-model-size")
    }

    func testMaxModelSizeTrimsDefaultList() throws {
        let command = try AutotuneCommand.parse(["--max-model-size", "8B", "--dry-run"])
        let plan = try command.candidatePlan()

        XCTAssertEqual(plan.candidates.first, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        XCTAssertFalse(plan.candidates.contains("mlx-community/Qwen2.5-32B-Instruct-4bit"))
        XCTAssertFalse(plan.candidates.contains("mlx-community/Qwen2.5-14B-Instruct-4bit"))
    }

    func testMaxContextAxisRejectsBelowTargetCell() throws {
        XCTAssertThrowsError(
            try AutotuneCommand.parse([
                "--target-context", "4000",
                "--max-context-axis", "2000,4000",
                "--dry-run",
            ])
        )
    }

    func testKvBitsAxisAcceptsUnsetFourEight() throws {
        let values = try AutotuneCommand.parseKvBitsAxis("unset,4,8")

        XCTAssertEqual(values.count, 3)
        XCTAssertNil(values[0])
        XCTAssertEqual(values[1], 4)
        XCTAssertEqual(values[2], 8)
    }
}
