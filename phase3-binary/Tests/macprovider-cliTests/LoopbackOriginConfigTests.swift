import XCTest
@testable import MacProviderCore
@testable import macprovider_cli

// #1690 freeze audit R1 ARCH-3: the generic loopback origin loads from yaml
// `loopback_origin` and env `MACPROVIDER_LOOPBACK_ORIGIN` (env wins), and the
// legacy `MACPROVIDER_OLLAMA_ORIGIN` still wins for Ollama only.
final class LoopbackOriginConfigTests: XCTestCase {
    private func load(environment: [String: String], yaml: String?) throws -> String? {
        try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: environment,
            fileExists: { _ in yaml != nil },
            readFile: { _ in yaml ?? "" }
        ).loopbackOrigin
    }

    func testLoopbackOriginLoadsFromYAMLAndEnvironment() throws {
        XCTAssertNil(try load(environment: [:], yaml: nil))
        XCTAssertEqual(try load(environment: [:], yaml: "loopback_origin: http://127.0.0.1:8081\n"), "http://127.0.0.1:8081")
        XCTAssertEqual(
            try load(
                environment: ["MACPROVIDER_LOOPBACK_ORIGIN": "http://127.0.0.1:9091"],
                yaml: "loopback_origin: http://127.0.0.1:8081\n"
            ),
            "http://127.0.0.1:9091"
        )
    }

    func testRuntimeOriginPrecedence() {
        XCTAssertEqual(LlamaCppLoopbackServeModel.resolveOrigin(configured: nil), LlamaCppLoopbackServeModel.defaultOrigin)
        XCTAssertEqual(LlamaCppLoopbackServeModel.resolveOrigin(configured: "http://127.0.0.1:9091"), "http://127.0.0.1:9091")
        XCTAssertEqual(
            OllamaLoopbackServeModel.resolveOrigin(configured: "http://127.0.0.1:9091", environment: [:]),
            "http://127.0.0.1:9091"
        )
        XCTAssertEqual(
            OllamaLoopbackServeModel.resolveOrigin(
                configured: "http://127.0.0.1:9091",
                environment: ["MACPROVIDER_OLLAMA_ORIGIN": "http://127.0.0.1:11500"]
            ),
            "http://127.0.0.1:11500"
        )
        XCTAssertEqual(OllamaLoopbackServeModel.resolveOrigin(configured: nil, environment: [:]), OllamaLoopbackServeModel.defaultOrigin)
    }
}
