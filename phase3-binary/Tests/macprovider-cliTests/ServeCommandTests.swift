import ArgumentParser
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ServeCommandTests: XCTestCase {
    func testNoJoinFlagParses() throws {
        let command = try ServeCommand.parse([
            "--no-join",
            "--model", "model-a",
            "--port", "18080",
        ])

        XCTAssertTrue(command.noJoin)
        XCTAssertEqual(command.model, "model-a")
        XCTAssertEqual(command.port, 18080)
    }

    func testEnableReceiptsFlagParses() throws {
        let command = try ServeCommand.parse([
            "--enable-receipts",
            "--model", "model-a",
        ])

        XCTAssertEqual(command.enableReceipts, true)
    }

    func testNoJoinSkipsCoordinatorClientInstantiation() {
        var factoryInvoked = false

        let client = ServeCommand.makeCoordinatorClient(noJoin: true) {
            factoryInvoked = true
            return nil
        }

        XCTAssertNil(client)
        XCTAssertFalse(factoryInvoked)
    }

    func testDefaultServePathInvokesCoordinatorClientFactory() {
        var factoryInvoked = false

        _ = ServeCommand.makeCoordinatorClient(noJoin: false) {
            factoryInvoked = true
            return nil
        }

        XCTAssertTrue(factoryInvoked)
    }

    func testReceiptBuilderDisabledByDefault() throws {
        var config = AppConfig.defaults()
        config.providerID = "provider-a"

        XCTAssertNil(try ServeCommand.makeReceiptBuilder(config: config, keyStore: InMemoryReceiptKeyStore()))
    }

    func testReceiptBuilderRequiresProviderID() throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true

        XCTAssertNil(try ServeCommand.makeReceiptBuilder(config: config, keyStore: InMemoryReceiptKeyStore()))
    }

    func testReceiptBuilderEnabledGeneratesCurrentKey() throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true
        config.providerID = "provider-a"
        let store = InMemoryReceiptKeyStore()

        let builder = try XCTUnwrap(ServeCommand.makeReceiptBuilder(config: config, keyStore: store))

        XCTAssertNotNil(try store.loadCurrent(providerId: "provider-a"))
        XCTAssertNotNil(builder)
    }

    func testReceiptRuntimePublishesCurrentKeyPublicBytes() throws {
        var config = AppConfig.defaults()
        config.enableReceipts = true
        config.providerID = "provider-a"
        let store = InMemoryReceiptKeyStore()

        let runtime = try ServeCommand.makeReceiptRuntime(config: config, keyStore: store)
        let current = try XCTUnwrap(store.loadCurrent(providerId: "provider-a"))

        XCTAssertNotNil(runtime.builder)
        XCTAssertEqual(runtime.publicKeyBase64, Data(current.publicKey.rawRepresentation).base64EncodedString())
    }
}
