import Foundation
import XCTest
@testable import Malibu

final class ManagedPrivacyConsumerTests: XCTestCase {
    func testDirectoryPinRequiresCanonicalLocalOrBundledPublicKey() throws {
        XCTAssertEqual(try ManagedPrivacyConsumer.directoryKey(environment: [:]), ManagedPrivacyConsumer.productionDirectoryPublicKey)
        let pin = Data(repeating: 7, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(try ManagedPrivacyConsumer.directoryKey(environment: [:], bundledKey: pin), pin)
        XCTAssertEqual(try ManagedPrivacyConsumer.directoryKey(environment: ["MACPROVIDER_PRIVACY_DIRECTORY_PUBLIC_KEY": pin], bundledKey: nil), pin)
        for invalid in ["", pin + "=", " " + pin, String(pin.dropLast()), String(repeating: "a", count: 43)] {
            XCTAssertThrowsError(try ManagedPrivacyConsumer.directoryKey(environment: ["MACPROVIDER_PRIVACY_DIRECTORY_PUBLIC_KEY": invalid], bundledKey: pin))
        }
        XCTAssertThrowsError(try ManagedPrivacyConsumer.directoryKey(environment: [:], bundledKey: nil))
    }

    func testPrivacyCannotSilentlyChooseAnUnlimitedBudget() throws {
        for valid in ["1", "1.00", "0.000001"] { XCTAssertEqual(try ManagedPrivacyConsumer.budget(valid), valid) }
        for invalid in ["0", "-1", "1e9", "NaN", "", "1.0000001", " 1", "1;echo bad"] {
            XCTAssertThrowsError(try ManagedPrivacyConsumer.budget(invalid))
        }
    }

    func testEveryManagedProfileTargetsTheFixedLoopbackConsumer() throws {
        let model = ConnectedModel(id: "test-model", contextWindow: 32768, maxOutputTokens: 1024, supportsTools: true)
        for app in [ConnectedApp.codex, .openCode, .goose, .crush] {
            let bytes = try ConnectedAppConfiguration.configuration(app: app, model: model, original: nil,
                catalog: URL(fileURLWithPath: "/private/models.json"))
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(text.contains(ManagedPrivacyEndpoint.baseURL.absoluteString), app.rawValue)
            XCTAssertFalse(text.contains(ConnectedAppConfiguration.gateway.absoluteString), app.rawValue)
        }
    }

    @MainActor
    func testManagedLaunchHandsOffOnlyLocalTokenAndRequiresPrivateEndpoint() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        var reads = 0
        let buyerKey = "buyer-key-must-not-reach-agent"
        let store = ConnectedAppsStore(home: home, keyExists: { true }, readKey: { reads += 1; return buyerKey })
        store.app = .crush
        store.models = [ConnectedModel(id: "test-model", contextWindow: 32768, maxOutputTokens: 1024, supportsTools: true)]
        store.modelID = "test-model"
        store.executable = URL(fileURLWithPath: "/bin/echo")
        store.preview()
        XCTAssertTrue(store.canSetup, store.status)
        store.setup()
        let setupReads = reads
        XCTAssertThrowsError(try store.prepareEmbeddedLaunch(.crush, isolated: true))
        XCTAssertEqual(reads, setupReads)
        let prepared = try store.prepareEmbeddedLaunch(.crush, isolated: true, endpoint: ManagedPrivacyEndpoint(localToken: "local-only-token"))
        XCTAssertEqual(reads, setupReads)
        XCTAssertEqual(try String(contentsOf: prepared.handoff, encoding: .utf8), "local-only-token")
        XCTAssertFalse(try String(contentsOf: prepared.launcher, encoding: .utf8).contains(buyerKey))
    }

    @MainActor
    func testOrdinaryGatewayReceiptCannotReadBuyerKeyOrLaunch() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Application Support/Malibu/ConnectedApps")
        let receipts = ConnectedConfigTransaction(receiptDirectory: root.appendingPathComponent("backups"))
        let target = root.appendingPathComponent("crush/config")
        let handoff = root.appendingPathComponent("handoff/crush.key")
        let model = ConnectedModel(id: "test-model", contextWindow: 32768, maxOutputTokens: 1024)
        let ordinary = String(decoding: try ConnectedAppConfiguration.configuration(app: .crush, model: model, original: nil), as: UTF8.self)
            .replacingOccurrences(of: ManagedPrivacyEndpoint.baseURL.absoluteString, with: ConnectedAppConfiguration.gateway.absoluteString)
        try receipts.apply(receipts.preview(target: target, proposed: Data(ordinary.utf8)), named: "crush-config")
        let launcher = try ConnectedAppConfiguration.launcher(app: .crush, executable: URL(fileURLWithPath: "/bin/echo"),
            config: target, model: model, keyHandoff: handoff)
        try receipts.apply(receipts.preview(target: root.appendingPathComponent("crush/Launch.command"), proposed: launcher),
            named: "crush-launch", executable: true)
        let store = ConnectedAppsStore(home: home, keyExists: { true }, readKey: { XCTFail("ordinary receipts must fail before Keychain"); return "buyer-key" })
        XCTAssertThrowsError(try store.prepareEmbeddedLaunch(.crush, endpoint: ManagedPrivacyEndpoint(localToken: "local-token"))) { error in
            XCTAssertEqual((error as? ConnectedAppsError)?.localizedDescription, ConnectedAppsError.privacySetupUpgrade.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoff.path))
    }
}
