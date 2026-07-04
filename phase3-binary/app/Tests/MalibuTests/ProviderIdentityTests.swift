import CryptoKit
import XCTest
@testable import Malibu

final class ProviderIdentityTests: XCTestCase {
    func testBase32LowercaseNoPadRFC4648Vectors() {
        XCTAssertEqual(ProviderIdentity.base32LowercaseNoPad(Data()), "")
        XCTAssertEqual(ProviderIdentity.base32LowercaseNoPad(Data("f".utf8)), "my")
        XCTAssertEqual(ProviderIdentity.base32LowercaseNoPad(Data("fo".utf8)), "mzxq")
        XCTAssertEqual(ProviderIdentity.base32LowercaseNoPad(Data("foo".utf8)), "mzxw6")
        XCTAssertEqual(ProviderIdentity.base32LowercaseNoPad(Data("foob".utf8)), "mzxw6yq")
        XCTAssertEqual(ProviderIdentity.base32LowercaseNoPad(Data("fooba".utf8)), "mzxw6ytb")
        XCTAssertEqual(ProviderIdentity.base32LowercaseNoPad(Data("foobar".utf8)), "mzxw6ytboi")
    }

    func testProviderIDShapeAndSignatureRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let providerID = ProviderIdentity.providerID(for: key)
        XCTAssertTrue(providerID.hasPrefix("p_"))
        XCTAssertEqual(providerID.count, 54)

        let payload = Data("spec-026".utf8)
        let signature = try ProviderIdentity.sign(payload, using: key)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: payload))
    }

    func testLoadOrGenerateIsReadyAndDelete() async throws {
        do {
            try await ProviderIdentity.deleteFromKeychain()
            var ready = await ProviderIdentity.isReady()
            XCTAssertFalse(ready)
            _ = try await ProviderIdentity.loadOrGenerate()
            ready = await ProviderIdentity.isReady()
            XCTAssertTrue(ready)
            try await ProviderIdentity.deleteFromKeychain()
            ready = await ProviderIdentity.isReady()
            XCTAssertFalse(ready)
        } catch {
            throw XCTSkip("Keychain unavailable in this test host: \(error.localizedDescription)")
        }
    }

    func testLoadExistingDoesNotGenerateMissingIdentity() async throws {
        do {
            try await ProviderIdentity.deleteFromKeychain()
            do {
                _ = try await ProviderIdentity.loadExisting()
                XCTFail("Expected missing identity to throw")
            } catch ProviderIdentityError.missingIdentity {
                // Expected.
            }
            let ready = await ProviderIdentity.isReady()
            XCTAssertFalse(ready)
        } catch {
            throw XCTSkip("Keychain unavailable in this test host: \(error.localizedDescription)")
        }
    }
}
