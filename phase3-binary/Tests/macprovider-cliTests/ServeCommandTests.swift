import ArgumentParser
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
}
