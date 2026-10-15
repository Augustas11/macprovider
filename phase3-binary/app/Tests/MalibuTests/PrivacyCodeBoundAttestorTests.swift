import CryptoKit
import Darwin
import DeviceCheck
import XCTest
@testable import Malibu

/// SPEC-049-R035: the attestor asserts only for the verified provider runtime,
/// only with the recorded key, and only over the statement it framed itself.
final class PrivacyCodeBoundAttestorTests: XCTestCase {
    private let team = "AB12CD34EF"
    private let providerID = "mp-0123456789abcdef0123456789abcdef"
    private let keyID = Data(repeating: 0xC4, count: 32).base64EncodedString()
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PrivacyCodeBoundAttestorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAssertsTheStatementItFramedWithTheRecordedKey() async throws {
        store.setKeyID(keyID, for: providerID)
        let keys = AssertingKeyService()
        let core = makeCore(keys: keys)
        let request = sampleRequest()
        let reply = await core.handle(request.wireObject, peer: genuinePeer())
        guard case let .asserted(statement, assertion) = reply else { return XCTFail("reply \(reply)") }
        XCTAssertEqual(statement.request, request)
        XCTAssertEqual(statement.appAttestKeyID, PrivacyCodeBoundBase64URL.fromAppAttestKeyID(keyID))
        XCTAssertEqual(statement.runtimeTeamID, team)
        XCTAssertEqual(statement.runtimeCDHash, genuinePeer().cdhash)
        XCTAssertEqual(statement.runtimeCSFlags, genuinePeer().csFlags)
        XCTAssertEqual(statement.checkedAtUnix, 1_700_000_000)
        XCTAssertEqual(PrivacyCodeBoundBase64URL.decode(assertion), AssertingKeyService.assertion)
        let calls = keys.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.keyID, keyID)
        XCTAssertEqual(calls.first?.hash, Data(SHA256.hash(data: try statement.framing())))
    }

    func testRefusesAnyOtherPeer() async {
        store.setKeyID(keyID, for: providerID)
        let keys = AssertingKeyService()
        let genuine = genuinePeer()
        for peer in [
            nil,
            PrivacyCodeBoundPeer(teamID: "ZZ12CD34EF", signingIdentifier: genuine.signingIdentifier, cdhash: genuine.cdhash, csFlags: genuine.csFlags),
            PrivacyCodeBoundPeer(teamID: team, signingIdentifier: "live.malibu.other", cdhash: genuine.cdhash, csFlags: genuine.csFlags),
            PrivacyCodeBoundPeer(teamID: team, signingIdentifier: genuine.signingIdentifier, cdhash: genuine.cdhash, csFlags: genuine.csFlags | 0x1000_0000),
            PrivacyCodeBoundPeer(teamID: team, signingIdentifier: genuine.signingIdentifier, cdhash: genuine.cdhash, csFlags: genuine.csFlags | 0x4),
            PrivacyCodeBoundPeer(teamID: team, signingIdentifier: genuine.signingIdentifier, cdhash: genuine.cdhash, csFlags: genuine.csFlags & ~0x0001_0000),
            PrivacyCodeBoundPeer(teamID: team, signingIdentifier: genuine.signingIdentifier, cdhash: "zz", csFlags: genuine.csFlags),
        ] {
            let reply = await makeCore(keys: keys).handle(sampleRequest().wireObject, peer: peer)
            XCTAssertEqual(reply, .unavailable(reason: "peer_rejected"), "\(String(describing: peer))")
        }
        XCTAssertTrue(keys.calls.isEmpty)
    }

    func testRefusesWithoutAKeyOrAfterTheKeyFailed() async {
        let keys = AssertingKeyService(error: NSError(domain: DCError.errorDomain, code: DCError.Code.invalidKey.rawValue))
        let core = makeCore(keys: keys)
        let noKey = await core.handle(sampleRequest().wireObject, peer: genuinePeer())
        XCTAssertEqual(noKey, .unavailable(reason: "no_key"))
        store.setKeyID(keyID, for: providerID)
        let invalid = await core.handle(sampleRequest().wireObject, peer: genuinePeer())
        XCTAssertEqual(invalid, .unavailable(reason: "key_invalid"))
        XCTAssertTrue(store.isKeyInvalid(keyID, for: providerID))
        // An unusable key is never tried again.
        let again = await makeCore(keys: keys).handle(sampleRequest().wireObject, peer: genuinePeer())
        XCTAssertEqual(again, .unavailable(reason: "key_invalid"))
        XCTAssertEqual(keys.calls.count, 1)
    }

    func testRefusesMalformedRequestsUnsupportedPlatformsAndFloods() async {
        store.setKeyID(keyID, for: providerID)
        var extra = sampleRequest().wireObject
        extra["extra"] = 1
        let malformed = await makeCore(keys: AssertingKeyService()).handle(extra, peer: genuinePeer())
        XCTAssertEqual(malformed, .unavailable(reason: "invalid_request"))
        let unsupported = await makeCore(keys: AssertingKeyService(isSupported: false)).handle(sampleRequest().wireObject, peer: genuinePeer())
        XCTAssertEqual(unsupported, .unavailable(reason: "unsupported"))
        let core = makeCore(keys: AssertingKeyService())
        let first = await core.handle(sampleRequest().wireObject, peer: genuinePeer())
        guard case .asserted = first else { return XCTFail("first \(first)") }
        let second = await core.handle(sampleRequest().wireObject, peer: genuinePeer())
        XCTAssertEqual(second, .unavailable(reason: "rate_limited"))
    }

    func testServerAnswersOverItsSocketAndReadsThePeerFromTheKernel() async throws {
        store.setKeyID(keyID, for: providerID)
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("mp-at-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("a.sock")
        let inspector = RecordingInspector(peer: genuinePeer())
        let server = PrivacyCodeBoundAttestorServer(core: makeCore(keys: AssertingKeyService()), inspector: inspector, socketURL: socketURL)
        try server.start()
        defer { server.stop() }
        var info = stat()
        XCTAssertEqual(lstat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(socketURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let reply = try await Task.detached { try Self.exchange(self.sampleRequest(), socketURL: socketURL) }.value
        guard case let .asserted(statement, _) = reply else { return XCTFail("reply \(reply)") }
        XCTAssertEqual(statement.request, sampleRequest())
        XCTAssertEqual(inspector.teams, [team])
        server.stop()
        XCTAssertNotEqual(lstat(socketURL.path, &info), 0, "stop removes the socket")
    }

    // MARK: - helpers

    private var store: AppAttestEnrollmentStore { AppAttestEnrollmentStore(defaults: defaults) }

    private func makeCore(keys: AssertingKeyService) -> PrivacyCodeBoundAttestorCore {
        PrivacyCodeBoundAttestorCore(teamID: team, keyService: keys, store: store, now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    private func genuinePeer() -> PrivacyCodeBoundPeer {
        PrivacyCodeBoundPeer(teamID: team, signingIdentifier: PrivacyCodeBoundConstants.runtimeSigningIdentifier, cdhash: String(repeating: "ab", count: 20), csFlags: 0x2621_0301)
    }

    private func sampleRequest() -> PrivacyCodeBoundRequest {
        var se = Data([0x6b, 0x17, 0xd1, 0xf2])
        se.append(Data(repeating: 0x11, count: 60))
        return PrivacyCodeBoundRequest(
            providerID: providerID,
            assignedSession: "session-1",
            nonce: PrivacyCodeBoundBase64URL.encode(Data(repeating: 0x31, count: 32)),
            postureDigest: PrivacyCodeBoundBase64URL.encode(Data(repeating: 0x42, count: 32)),
            sePublicKey: se.base64EncodedString(),
            identityPublicKey: PrivacyCodeBoundBase64URL.encode(Data(repeating: 0x53, count: 32))
        )
    }

    private static func exchange(_ request: PrivacyCodeBoundRequest, socketURL: URL) throws -> PrivacyCodeBoundReply {
        var address = sockaddr_un()
        let pathBytes = Array(socketURL.path.utf8)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw PrivacyCodeBoundWireError.invalid }
        try PrivacyCodeBoundFrame.write(request.wireObject, to: fd)
        return try PrivacyCodeBoundReply(object: try PrivacyCodeBoundFrame.read(from: fd))
    }
}

private final class AssertingKeyService: AppAttestKeyService, @unchecked Sendable {
    static let assertion = Data(repeating: 0xA7, count: 70)

    let isSupported: Bool
    private let error: Error?
    private let lock = NSLock()
    private var recorded: [(keyID: String, hash: Data)] = []

    init(isSupported: Bool = true, error: Error? = nil) {
        self.isSupported = isSupported
        self.error = error
    }

    var calls: [(keyID: String, hash: Data)] { lock.withLock { recorded } }

    func generateKey() async throws -> String { throw POSIXError(.ENOTSUP) }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { throw POSIXError(.ENOTSUP) }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { recorded.append((keyID, clientDataHash)) }
        if let error { throw error }
        return Self.assertion
    }
}

private final class RecordingInspector: PrivacyCodeBoundPeerInspecting, @unchecked Sendable {
    private let peer: PrivacyCodeBoundPeer
    private let lock = NSLock()
    private var seen: [String] = []

    init(peer: PrivacyCodeBoundPeer) { self.peer = peer }

    var teams: [String] { lock.withLock { seen } }

    func inspect(socket fd: Int32, teamID: String) -> PrivacyCodeBoundPeer? {
        lock.withLock { seen.append(teamID) }
        // The real inspector must at least see a kernel audit token here.
        return KernelPrivacyCodeBoundPeerInspector.auditToken(socket: fd) == nil ? nil : peer
    }
}
