import XCTest
@testable import macprovider_cli

/// The relay-blind fixture is compiled and registered only under
/// MACPROVIDER_TEST_FIXTURES (debug/test builds). A release CLI carries
/// neither the subcommand nor its deterministic runtimes.
final class RelayBlindFixtureGatingTests: XCTestCase {
    func testFixtureSubcommandIsRegisteredInFixtureBuildsAndHidden() {
        let names = MacProviderCLI.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertEqual(names.filter { $0 == "relay-blind-fixture" }.count, 1)
        XCTAssertFalse(RelayBlindFixtureCommand.configuration.shouldDisplay)
    }
}
