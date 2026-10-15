import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-049 §4.13 and SPEC-049-R035 item 4, provider runtime side.
final class PrivacyCodeBoundTests: XCTestCase {
    func testStatementFramingMatchesSharedVector() throws {
        let vector = try codeBoundFixture()
        let object = try XCTUnwrap(vector["statement"] as? [String: Any])
        let statement = try PrivacyCodeBoundStatement(object: object)
        let framing = try statement.framing()
        XCTAssertEqual(framing.codeBoundHex, vector["framing_hex"] as? String)
        XCTAssertEqual(Data(SHA256.hash(data: framing)).codeBoundHex, vector["client_data_hash_hex"] as? String)
        // The wire object round-trips through the closed decoder.
        XCTAssertEqual(try PrivacyCodeBoundStatement(object: statement.wireObject), statement)
        XCTAssertEqual(Set(statement.wireObject.keys), Set(object.keys))
    }

    func testStatementDecodeIsClosed() throws {
        let object = try XCTUnwrap(try codeBoundFixture()["statement"] as? [String: Any])
        var extra = object
        extra["extra"] = 1
        XCTAssertThrowsError(try PrivacyCodeBoundStatement(object: extra))
        var missing = object
        missing.removeValue(forKey: "runtime_cdhash")
        XCTAssertThrowsError(try PrivacyCodeBoundStatement(object: missing))
        var boolFlags = object
        boolFlags["runtime_cs_flags"] = true
        XCTAssertThrowsError(try PrivacyCodeBoundStatement(object: boolFlags))
        var badKeyID = object
        badKeyID["app_attest_key_id"] = "AAAA"
        XCTAssertThrowsError(try PrivacyCodeBoundStatement(object: badKeyID))
    }

    func testPostureReplyNamesThePostureAndItsKeys() throws {
        let root = try makeCodeBoundKeyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = try SELivenessTestSigning.generate()
        let (responder, runtime) = try makeCodeBoundResponder(root: root, signer: signer)
        let challenge: [String: Any] = [
            "type": "privacy_posture_challenge", "version": 1,
            "nonce": RelayBlindBase64URL.encode(Data(repeating: 0x31, count: 32)), "issued_at_unix": 1_700_000_000,
        ]
        let reply = try XCTUnwrap(try responder.respondWithCodeBound(to: challenge, assignedSession: "session-1"))
        let request = reply.codeBoundRequest
        XCTAssertNoThrow(try request.validate())
        XCTAssertEqual(request.providerID, "provider-test")
        XCTAssertEqual(request.assignedSession, "session-1")
        XCTAssertEqual(request.nonce, challenge["nonce"] as? String)
        XCTAssertEqual(request.sePublicKey, signer.publicKeyRaw.base64EncodedString())
        XCTAssertEqual(request.identityPublicKey, runtime.identityPublicKeyBase64URL())
        let posture = try codeBoundPosture(try XCTUnwrap(reply.response["statement"] as? [String: Any]))
        XCTAssertEqual(posture.nonce, request.nonce)
        // The digest is SHA-256 of the framing the posture was signed over.
        let framing = try posture.framing()
        XCTAssertEqual(request.postureDigest, PrivacyCodeBoundBase64URL.encode(Data(SHA256.hash(data: framing))))
        let seSignature = try RelayBlindBase64URL.decode(try XCTUnwrap(reply.response["se_signature"] as? String))
        var x963 = Data([0x04])
        x963.append(signer.publicKeyRaw)
        let publicKey = try P256.Signing.PublicKey(x963Representation: x963)
        XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: seSignature), for: framing))
    }

    func testEvidenceOnlyForAnEchoingAttestor() async throws {
        let request = sampleRequest()
        let statement = sampleStatement(for: request)
        let assertion = PrivacyCodeBoundBase64URL.encode(Data(repeating: 0xa5, count: 64))

        let fetched = await PrivacyCodeBoundEvidence.fetch(request: request, attestor: FakeAttestor(reply: .asserted(statement: statement, assertion: assertion)))
        let encoded = try XCTUnwrap(fetched)
        let message = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(message["type"] as? String, "privacy_code_bound_evidence")
        XCTAssertEqual(message["assertion"] as? String, assertion)
        XCTAssertEqual(try PrivacyCodeBoundStatement(object: try XCTUnwrap(message["statement"] as? [String: Any])), statement)

        var otherPosture = statement
        otherPosture.postureDigest = PrivacyCodeBoundBase64URL.encode(Data(repeating: 0x01, count: 32))
        var debugged = statement
        debugged.runtimeCSFlags |= 0x1000_0000
        var otherRuntime = statement
        otherRuntime.runtimeSigningIdentifier = "live.malibu.other"
        for reply in [
            PrivacyCodeBoundReply.asserted(statement: otherPosture, assertion: assertion),
            .asserted(statement: debugged, assertion: assertion),
            .asserted(statement: otherRuntime, assertion: assertion),
            .unavailable(reason: "no_key"),
        ] {
            let evidence = await PrivacyCodeBoundEvidence.fetch(request: request, attestor: FakeAttestor(reply: reply))
            XCTAssertNil(evidence, "\(reply)")
        }
        let none = await PrivacyCodeBoundEvidence.fetch(request: request, attestor: FakeAttestor(reply: nil))
        XCTAssertNil(none)
    }

    func testSocketAttestorExchangesOneFrame() async throws {
        let directory = try makeCodeBoundStateRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("a.sock")
        let request = sampleRequest()
        let statement = sampleStatement(for: request)
        let assertion = PrivacyCodeBoundBase64URL.encode(Data(repeating: 0x5a, count: 70))
        let listener = try bindTestListener(socketURL)
        defer { close(listener) }
        let received = ReceivedBox()
        DispatchQueue.global().async {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer { close(fd) }
            if let object = try? PrivacyCodeBoundFrame.read(from: fd) {
                received.request = try? PrivacyCodeBoundRequest(object: object)
            }
            try? PrivacyCodeBoundFrame.write(PrivacyCodeBoundReply.asserted(statement: statement, assertion: assertion).wireObject, to: fd)
        }
        let reply = await PrivacyCodeBoundSocketAttestor(socketURL: socketURL, timeout: 2).assert(request)
        XCTAssertEqual(reply, .asserted(statement: statement, assertion: assertion))
        XCTAssertEqual(received.request, request)
    }

    func testSocketAttestorFailsFastWithoutTheApp() async throws {
        let directory = try makeCodeBoundStateRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let absent = PrivacyCodeBoundSocketAttestor(socketURL: directory.appendingPathComponent("missing.sock"), timeout: 2)
        XCTAssertFalse(absent.mayBeAvailable)
        let missing = await absent.assert(sampleRequest())
        XCTAssertNil(missing)
        // A regular file in the socket's place is not the attestor.
        let file = directory.appendingPathComponent("file.sock")
        try Data().write(to: file)
        let notSocket = await PrivacyCodeBoundSocketAttestor(socketURL: file, timeout: 2).assert(sampleRequest())
        XCTAssertNil(notSocket)
    }

    func testChannelFramesAreCanonicalAndBounded() throws {
        let request = sampleRequest()
        let frame = try PrivacyCodeBoundFrame.encode(request.wireObject)
        let body = frame.dropFirst(PrivacyCodeBoundFrame.headerBytes)
        XCTAssertEqual(try PrivacyCodeBoundRequest(object: try PrivacyCodeBoundFrame.decodeBody(Data(body))), request)
        // Whitespace is not canonical.
        var spaced = Data("{ ".utf8)
        spaced.append(body.dropFirst())
        XCTAssertThrowsError(try PrivacyCodeBoundFrame.decodeBody(spaced))
        var tooLong = Data()
        tooLong.cbAppendUnsigned32(UInt32(PrivacyCodeBoundConstants.maxChannelFrameBytes + 1))
        XCTAssertThrowsError(try PrivacyCodeBoundFrame.bodyLength(header: tooLong))
        XCTAssertThrowsError(try PrivacyCodeBoundReply(object: ["type": PrivacyCodeBoundConstants.resultType, "version": 1, "status": "unavailable", "reason": "anything"]))
    }
}

private final class ReceivedBox: @unchecked Sendable {
    var request: PrivacyCodeBoundRequest?
}

private struct FakeAttestor: PrivacyCodeBoundAttesting {
    let reply: PrivacyCodeBoundReply?
    var mayBeAvailable: Bool { true }
    func assert(_ request: PrivacyCodeBoundRequest) async -> PrivacyCodeBoundReply? { reply }
}

private func sampleRequest() -> PrivacyCodeBoundRequest {
    var se = Data([0x6b, 0x17, 0xd1, 0xf2])
    se.append(Data(repeating: 0x11, count: 60))
    return PrivacyCodeBoundRequest(
        providerID: "provider-test",
        assignedSession: "session-1",
        nonce: PrivacyCodeBoundBase64URL.encode(Data(repeating: 0x31, count: 32)),
        postureDigest: PrivacyCodeBoundBase64URL.encode(Data(repeating: 0x42, count: 32)),
        sePublicKey: se.base64EncodedString(),
        identityPublicKey: PrivacyCodeBoundBase64URL.encode(Data(repeating: 0x53, count: 32))
    )
}

private func sampleStatement(for request: PrivacyCodeBoundRequest) -> PrivacyCodeBoundStatement {
    PrivacyCodeBoundStatement(
        request: request,
        appAttestKeyID: PrivacyCodeBoundBase64URL.encode(Data(repeating: 0x33, count: 32)),
        runtimeTeamID: "AB12CD34EF",
        runtimeSigningIdentifier: PrivacyCodeBoundConstants.runtimeSigningIdentifier,
        runtimeCDHash: String(repeating: "ab", count: 20),
        runtimeCSFlags: 0x2621_0301,
        checkedAtUnix: 1_700_000_001
    )
}

private func bindTestListener(_ url: URL) throws -> Int32 {
    var address = sockaddr_un()
    let pathBytes = Array(url.path.utf8)
    XCTAssertLessThan(pathBytes.count, MemoryLayout.size(ofValue: address.sun_path))
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard fd >= 0, bound == 0, listen(fd, 1) == 0 else {
        close(fd)
        throw PrivacyCodeBoundWireError.invalid
    }
    return fd
}

private struct StaticCodeBoundProbe: PrivacyPostureProbe {
    func observe() -> PrivacyPostureObservation {
        PrivacyPostureObservation(
            hardenedRuntime: true,
            libraryValidation: true,
            getTaskAllow: false,
            csDebugged: false,
            pTraced: false,
            ptDenyAttachApplied: true,
            coreDumpsDisabled: true,
            sipEnabled: true,
            diagnosticEnvClear: true,
            kvDiskTierDisabled: true,
            runtimeSource: PrivacyClassConstants.runtimeSource,
            codeCDHash: String(repeating: "ab", count: 20),
            teamID: "AB12CD34EF",
            signingIdentifier: "live.malibu.provider.cli",
            binaryVersion: CoordinatorClient.binaryVersion,
            failureReasons: []
        )
    }

    func isTracedOrDebugged() -> Bool { false }
}

private func makeCodeBoundResponder(root: URL, signer: SELivenessTestSigning) throws -> (responder: PrivacyPostureResponder, runtime: RelayBlindProviderRuntime) {
    let keys = try RelayBlindKeyManager(directory: root, models: ["model-a"], persistAgreementKey: false)
    let journal = try RelayBlindExecutionJournal(directory: try PrivacyStateDirectory.executionJournal(stateRoot: root))
    let runtime = RelayBlindProviderRuntime(keyManager: keys, journal: journal)
    let responder = PrivacyPostureResponder(
        probe: StaticCodeBoundProbe(),
        seSigner: signer,
        seKeyBackend: PrivacyClassConstants.seBackendFile,
        relayBlindRuntime: runtime,
        providerID: "provider-test",
        binaryVersion: CoordinatorClient.binaryVersion
    )
    return (responder, runtime)
}

/// The relay-blind key directory needs parents that are not world-writable.
private func makeCodeBoundKeyRoot() throws -> URL {
    var temporaryRoot = NSTemporaryDirectory()
    if temporaryRoot.hasPrefix("/var/") { temporaryRoot = "/private" + temporaryRoot }
    let root = URL(fileURLWithPath: temporaryRoot, isDirectory: true)
        .appendingPathComponent("macprovider-privacy-code-bound-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

/// Short paths: a Unix socket path must fit in 104 bytes.
private func makeCodeBoundStateRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("mp-cb-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

private func codeBoundFixture() throws -> [String: Any] {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let url = tests.appendingPathComponent("../../../test/fixtures/relay-blind/privacy-code-bound-v1.json").standardizedFileURL
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func codeBoundPosture(_ object: [String: Any]) throws -> PrivacyPostureStatement {
    func string(_ key: String) throws -> String { try XCTUnwrap(object[key] as? String) }
    func flag(_ key: String) throws -> Bool { try XCTUnwrap((object[key] as? NSNumber)?.boolValue) }
    return PrivacyPostureStatement(
        version: try string("version"),
        privacyClass: try string("privacy_class"),
        providerID: try string("provider_id"),
        assignedSession: try string("assigned_session"),
        nonce: try string("nonce"),
        sequence: try XCTUnwrap((object["sequence"] as? NSNumber)?.uint64Value),
        issuedAtUnix: try XCTUnwrap((object["issued_at_unix"] as? NSNumber)?.int64Value),
        binaryVersion: try string("binary_version"),
        codeCDHash: try string("code_cdhash"),
        teamID: try string("team_id"),
        signingIdentifier: try string("signing_identifier"),
        hardenedRuntime: try flag("hardened_runtime"),
        libraryValidation: try flag("library_validation"),
        getTaskAllow: try flag("get_task_allow"),
        csDebugged: try flag("cs_debugged"),
        pTraced: try flag("p_traced"),
        ptDenyAttachApplied: try flag("pt_deny_attach_applied"),
        coreDumpsDisabled: try flag("core_dumps_disabled"),
        sipEnabled: try flag("sip_enabled"),
        runtimeSource: try string("runtime_source"),
        diagnosticEnvClear: try flag("diagnostic_env_clear"),
        kvDiskTierDisabled: try flag("kv_disk_tier_disabled"),
        seKeyBackend: try string("se_key_backend"),
        privacyKeyRecordDigests: try XCTUnwrap(object["privacy_key_record_digests"] as? [String])
    )
}

private extension Data {
    var codeBoundHex: String { map { String(format: "%02x", $0) }.joined() }
}
