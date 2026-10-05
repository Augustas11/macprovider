import XCTest
@testable import MacProviderCore
@testable import macprovider_cli

/// #1816: the configured `pool_model_id` a provider serves a signed pool
/// entry under.
final class PoolModelServeTests: XCTestCase {
    private static let poolModelID = "pool/AbCdEfGhIjKlMnOpQrStUv/my-model"

    private func load(environment: [String: String] = [:], yaml: String?, cli: CLIOverrides = CLIOverrides()) throws -> AppConfig {
        try ConfigLoader.load(
            cli: cli,
            environment: environment,
            fileExists: { _ in yaml != nil },
            readFile: { _ in yaml ?? "" }
        )
    }

    func testPoolModelIDLoadsFromYAMLAndEnvironment() throws {
        XCTAssertNil(try load(yaml: nil).poolModelID)
        XCTAssertEqual(try load(yaml: "pool_model_id: \(Self.poolModelID)\n").poolModelID, Self.poolModelID)
        XCTAssertEqual(
            try load(
                environment: ["MACPROVIDER_POOL_MODEL_ID": "pool/ZZCdEfGhIjKlMnOpQrStUv/other"],
                yaml: "pool_model_id: \(Self.poolModelID)\n"
            ).poolModelID,
            "pool/ZZCdEfGhIjKlMnOpQrStUv/other"
        )
        // A CLI --model that replaces the configured model drops the pool id
        // bound to the old one, like the catalog identity (#745).
        let replaced = try load(
            yaml: "model: llamacpp:my-model\npool_model_id: \(Self.poolModelID)\n",
            cli: CLIOverrides(model: "llamacpp:other-model")
        )
        XCTAssertNil(replaced.poolModelID)
    }

    func testValidationIsStrictAndNeverBesideACatalogIdentity() throws {
        var config = AppConfig.defaults()
        XCTAssertNil(try PoolModelServe.validatedPoolModelID(config))
        config.poolModelID = "  \(Self.poolModelID) "
        XCTAssertEqual(try PoolModelServe.validatedPoolModelID(config), Self.poolModelID)
        for bad in ["qwen3-8b", "pool/short/x", "pool/AbCdEfGhIjKlMnOpQrStUv/Upper", "pool/AbCdEfGhIjKlMnOpQrStUv/"] {
            config.poolModelID = bad
            XCTAssertThrowsError(try PoolModelServe.validatedPoolModelID(config), bad) {
                XCTAssertEqual($0 as? PoolModelServe.ConfigError, .invalidPoolModelID)
            }
        }
        config.poolModelID = Self.poolModelID
        config.modelCatalogModelID = "qwen/qwen3-8b"
        XCTAssertThrowsError(try PoolModelServe.validatedPoolModelID(config)) {
            XCTAssertEqual($0 as? PoolModelServe.ConfigError, .conflictsWithCatalogIdentity)
        }
    }

    func testRequestAliasPrefersTheCatalogIdentity() {
        XCTAssertNil(PoolModelServe.requestAlias(catalogModelID: nil, poolModelID: nil))
        XCTAssertNil(PoolModelServe.requestAlias(catalogModelID: " ", poolModelID: ""))
        XCTAssertEqual(PoolModelServe.requestAlias(catalogModelID: nil, poolModelID: Self.poolModelID), Self.poolModelID)
        XCTAssertEqual(PoolModelServe.requestAlias(catalogModelID: "qwen/qwen3-8b", poolModelID: Self.poolModelID), "qwen/qwen3-8b")
    }

    /// The loopback runtime accepts a pool-route request naming the entry
    /// through the same alias path as a catalog id.
    func testLoopbackRuntimeAcceptsThePoolModelIDAsItsAlias() throws {
        let request = try ChatCompletionRequest.parse(data: Data(#"{"model":"\#(Self.poolModelID)","messages":[{"role":"user","content":"hi"}]}"#.utf8))
        XCTAssertNoThrow(try request.validateModelMatches("llamacpp:my-model", aliases: modelIDAliasList(PoolModelServe.requestAlias(catalogModelID: nil, poolModelID: Self.poolModelID))))
        XCTAssertThrowsError(try request.validateModelMatches("llamacpp:my-model", aliases: modelIDAliasList(nil)))
    }
}
