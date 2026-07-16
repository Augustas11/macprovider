import XCTest
@testable import macprovider_cli

final class BootstrapAuthCommandTests: XCTestCase {
    func testCredentialBootstrapPrincipalRequiresExactLowercase128BitSuffix() {
        XCTAssertTrue(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789abcdef0123456789abcdef"
        ))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal("office-mac"))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789ABCDEF0123456789ABCDEF"
        ))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789abcdef0123456789abcde"
        ))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789abcdef0123456789abcdef0"
        ))
        XCTAssertFalse(BootstrapAuthCommand.isCredentialBootstrapPrincipal(
            "mp-0123456789abcdef0123456789abcd٢"
        ))
    }

    func testExistingCLIKeychainCredentialSkipsBootstrapForAnyProviderID() throws {
        let store = InMemoryProviderCredentialStore(values: [
            "office-mac": "existing-token",
            "mp-0123456789abcdef0123456789abcdef": "existing-token",
        ])

        XCTAssertTrue(try BootstrapAuthCommand.storedCredentialPresent(
            providerID: "office-mac",
            store: store
        ))
        XCTAssertTrue(try BootstrapAuthCommand.storedCredentialPresent(
            providerID: "mp-0123456789abcdef0123456789abcdef",
            store: store
        ))
    }
}
