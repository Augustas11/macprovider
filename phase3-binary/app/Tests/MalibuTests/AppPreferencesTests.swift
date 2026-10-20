import XCTest
@testable import Malibu

@MainActor
final class AppPreferencesTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPreferencesTests.\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("prefs.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        fileURL = nil
        directory = nil
        super.tearDown()
    }

    func testDefaultsMatchExistingAppPresenceAndStableUpdaterContract() {
        let preferences = AppPreferences(fileURL: fileURL)
        XCTAssertEqual(preferences.updateChannel, .stable)
        XCTAssertTrue(preferences.showsMenuBarIcon)
        XCTAssertFalse(preferences.keepsDockIcon)
    }

    func testAppearancePreferencesPersistAndAlwaysKeepOneShortcutVisible() {
        let preferences = AppPreferences(fileURL: fileURL)
        preferences.setShowsMenuBarIcon(false)
        XCTAssertFalse(preferences.showsMenuBarIcon)
        XCTAssertTrue(preferences.keepsDockIcon)

        preferences.setKeepsDockIcon(false)
        XCTAssertTrue(preferences.showsMenuBarIcon)
        XCTAssertFalse(preferences.keepsDockIcon)

        let reloaded = AppPreferences(fileURL: fileURL)
        XCTAssertTrue(reloaded.showsMenuBarIcon)
        XCTAssertFalse(reloaded.keepsDockIcon)
    }

    func testOnlyUpdaterSupportedChannelIsExposedAndPersisted() {
        XCTAssertEqual(AppPreferences.UpdateChannel.allCases, [.stable])
        let preferences = AppPreferences(fileURL: fileURL)
        preferences.setUpdateChannel(.stable)
        XCTAssertEqual(AppPreferences(fileURL: fileURL).updateChannel, .stable)
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes?[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testWritingPreservesPreferencesOwnedByOtherAppFeatures() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"windowWidth":1040,"future":{"enabled":true}}"#.utf8).write(to: fileURL)

        let preferences = AppPreferences(fileURL: fileURL)
        preferences.setKeepsDockIcon(true)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["windowWidth"] as? Int, 1040)
        XCTAssertEqual((object["future"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual(object["keepsDockIcon"] as? Bool, true)
    }

    func testPersistenceFailureIsPublishedForSettingsToExplain() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let regularFile = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: regularFile)
        let preferences = AppPreferences(fileURL: regularFile.appendingPathComponent("prefs.json"))

        preferences.setShowsMenuBarIcon(false)

        XCTAssertTrue(preferences.persistenceFailed)
        XCTAssertFalse(preferences.showsMenuBarIcon, "the live preference still applies")
        XCTAssertTrue(preferences.keepsDockIcon, "reachability remains enforced")
        XCTAssertFalse(SettingsPresentation.preferenceSaveFailed.isEmpty)
    }
}
