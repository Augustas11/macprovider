import XCTest
import SwiftUI
@testable import Malibu

@MainActor
final class SettingsWindowPresenterTests: XCTestCase {
    func testSettingsPresenterCreatesReusableVisibleWindow() {
        let presenter = SettingsWindowPresenter()

        let first = presenter.present()
        XCTAssertTrue(first.isVisible)
        XCTAssertEqual(first.title, "Malibu Settings")
        XCTAssertTrue(first.contentViewController is NSHostingController<ModelSettingsView>)

        let second = presenter.present()
        XCTAssertTrue(first === second, "Settings should reuse and foreground the existing window instead of depending on the fragile SwiftUI settings selector.")

        first.close()
    }
}
