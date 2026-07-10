import XCTest
@testable import Malibu

final class MalibuUpdateConfigurationTests: XCTestCase {
    func testAppcastURLMatchesInfoPlistFeed() {
        XCTAssertEqual(
            MalibuUpdateConfiguration.appcastURL.absoluteString,
            "https://download.malibu.tech/appcast.xml"
        )
    }

    func testPublicEdKeyMatchesInfoPlist() {
        XCTAssertEqual(
            MalibuUpdateConfiguration.publicEdKeyBase64,
            "JkTDWnRJfOI3YIlpfJKvasWkxb0O1j/7ObGYiIA7big="
        )
        XCTAssertFalse(MalibuUpdateConfiguration.publicEdKeyBase64.isEmpty)
    }

    func testVersionedDownloadURLUsesTagSuffix() {
        let url = MalibuUpdateConfiguration.releaseDownloadURL(tag: "v1.8.21")
        XCTAssertEqual(url.absoluteString, "https://download.malibu.tech/Malibu-v1.8.21.dmg")
    }

    func testReleaseNotesURLPointsAtGitHubTag() {
        let url = MalibuUpdateConfiguration.releaseNotesURL(tag: "v1.8.21")
        XCTAssertEqual(
            url.absoluteString,
            "https://github.com/Augustas11/macprovider/releases/tag/v1.8.21"
        )
    }
}
