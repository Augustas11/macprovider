import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-049 v0.2 provider side: shared framing parity with the Go
/// coordinator, the supervisor channel framing and closed messages, the
/// enrollment state machine, and fallback to the Beta label.
final class PrivacyCodeBoundTests: XCTestCase {
    // MARK: Framing parity with the Go coordinator

    func testPrivacyCodeBoundFramingMatchesGoVector() throws {
        let vector = try codeBoundFixture()
        let posture = try PrivacyPostureV2Statement(object: try XCTUnwrap(vector["posture_v2"] as? [String: Any]))
        let postureFraming = try posture.framing()
        XCTAssertEqual(postureFraming.hex, try XCTUnwrap(vector["posture_v2_framing_hex"] as? String))
        XCTAssertEqual(Data(SHA256.hash(data: postureFraming)).hex, try XCTUnwrap(vector["posture_v2_client_data_hash_hex"] as? String))
        XCTAssertTrue(posture.childCheckConsistent)

        let enrollment = try PrivacyEnrollmentStatement(object: try XCTUnwrap(vector["enrollment"] as? [String: Any]))
        let enrollmentFraming = try enrollment.framing()
        XCTAssertEqual(enrollmentFraming.hex, try XCTUnwrap(vector["enrollment_framing_hex"] as? String))
        XCTAssertEqual(Data(SHA256.hash(data: enrollmentFraming)).hex, try XCTUnwrap(vector["enrollment_client_data_hash_hex"] as? String))
        XCTAssertTrue(enrollment.supervisorConsistent)

        // The wire object round-trips through the closed decoder unchanged.
        XCTAssertEqual(try PrivacyPostureV2Statement(object: posture.wireObject), posture)
        XCTAssertEqual(try PrivacyEnrollmentStatement(object: enrollment.wireObject), enrollment)
    }

    func testPrivacyCodeBoundStatementDecodersAreClosed() throws {
        let vector = try codeBoundFixture()
        let posture = try XCTUnwrap(vector["posture_v2"] as? [String: Any])
        var extra = posture
        extra["extra"] = "x"
        XCTAssertThrowsError(try PrivacyPostureV2Statement(object: extra))
        var missing = posture
        missing.removeValue(forKey: "child_cs_flags")
        XCTAssertThrowsError(try PrivacyPostureV2Statement(object: missing))
        var wrongType = posture
        wrongType["child_channel_peer_verified"] = 1
        XCTAssertThrowsError(try PrivacyPostureV2Statement(object: wrongType))
        var boolAsInt = posture
        boolAsInt["sequence"] = true
        XCTAssertThrowsError(try PrivacyPostureV2Statement(object: boolAsInt))
        var beta = posture
        beta["assurance"] = PrivacyClassConstants.assurance
        XCTAssertThrowsError(try PrivacyPostureV2Statement(object: beta))
        var unsorted = posture
        unsorted["privacy_key_record_digests"] = (posture["privacy_key_record_digests"] as? [String])?.reversed()
        XCTAssertThrowsError(try PrivacyPostureV2Statement(object: unsorted))

        let enrollment = try XCTUnwrap(vector["enrollment"] as? [String: Any])
        var shortKey = enrollment
        shortKey["se_public_key"] = PrivacySupervisorBase64URL.encode(Data(repeating: 1, count: 63))
        XCTAssertThrowsError(try PrivacyEnrollmentStatement(object: shortKey))
        var draftOnly = enrollment
        for key in PrivacySupervisorEnrollmentFields.fieldNames { draftOnly.removeValue(forKey: key) }
        XCTAssertNoThrow(try PrivacyEnrollmentDraft(object: draftOnly))
        XCTAssertThrowsError(try PrivacyEnrollmentStatement(object: draftOnly))
    }

    // MARK: Channel framing and closed messages

    func testPrivacySupervisorChannelFramingRoundTrip() throws {
        let draft = try fixtureEnrollmentDraft()
        let posture = try fixturePosture()
        let requests: [PrivacySupervisorRequest] = [
            .key(discard: nil),
            .key(discard: posture.draft.appAttestKeyID),
            .attest(draft),
            .assert(posture.draft),
        ]
        for request in requests {
            let frame = try PrivacySupervisorFrame.encode(request.wireObject)
            XCTAssertEqual(try PrivacySupervisorRequest(object: try PrivacySupervisorFrame.decode(frame)), request)
        }
        let replies: [PrivacySupervisorReply] = [
            .key(appAttestKeyID: posture.draft.appAttestKeyID),
            .attestation(try fixtureEnrollment(), attestation: Data(repeating: 0xa5, count: 900)),
            .assertion(posture, assertion: Data(repeating: 0x5a, count: 120)),
        ] + PrivacySupervisorErrorReason.allCases.map { .error($0) }
        for reply in replies {
            let frame = try PrivacySupervisorFrame.encode(reply.wireObject)
            XCTAssertEqual(try PrivacySupervisorReply(object: try PrivacySupervisorFrame.decode(frame)), reply)
        }
    }

    func testPrivacySupervisorChannelRejectsNonCanonicalFrames() throws {
        func frame(_ body: String) -> Data {
            var data = Data()
            let bytes = Array(body.utf8)
            let count = UInt32(bytes.count)
            data.append(contentsOf: [UInt8(count >> 24), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)])
            data.append(contentsOf: bytes)
            return data
        }
        let valid = "{\"discard_app_attest_key_id\":\"\",\"type\":\"privacy_supervisor_key_request\",\"version\":1}"
        XCTAssertNoThrow(try PrivacySupervisorFrame.decode(frame(valid)))
        // Duplicate key, whitespace, unsorted keys, trailing bytes.
        for body in [
            "{\"discard_app_attest_key_id\":\"\",\"type\":\"privacy_supervisor_key_request\",\"type\":\"privacy_supervisor_key_request\",\"version\":1}",
            "{\"discard_app_attest_key_id\": \"\",\"type\":\"privacy_supervisor_key_request\",\"version\":1}",
            "{\"type\":\"privacy_supervisor_key_request\",\"discard_app_attest_key_id\":\"\",\"version\":1}",
            valid + " ",
            "[]",
        ] {
            XCTAssertThrowsError(try PrivacySupervisorFrame.decode(frame(body)), body)
        }
        // Length header disagrees with the body, zero length, and oversize.
        var truncated = frame(valid)
        truncated.removeLast()
        XCTAssertThrowsError(try PrivacySupervisorFrame.decode(truncated))
        XCTAssertThrowsError(try PrivacySupervisorFrame.bodyLength(header: Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try PrivacySupervisorFrame.bodyLength(header: Data([0, 1, 0, 1])))
        XCTAssertThrowsError(try PrivacySupervisorFrame.encode(["blob": String(repeating: "a", count: 70_000)]))

        // Closed message schemas.
        XCTAssertThrowsError(try PrivacySupervisorRequest(object: ["type": "privacy_supervisor_key_request", "version": 2, "discard_app_attest_key_id": ""]))
        XCTAssertThrowsError(try PrivacySupervisorRequest(object: ["type": "privacy_supervisor_key_request", "version": 1]))
        XCTAssertThrowsError(try PrivacySupervisorRequest(object: ["type": "privacy_supervisor_key_request", "version": 1, "discard_app_attest_key_id": "short"]))
        XCTAssertThrowsError(try PrivacySupervisorRequest(object: ["type": "unknown", "version": 1]))
        XCTAssertThrowsError(try PrivacySupervisorReply(object: ["type": "privacy_supervisor_error", "version": 1, "reason": "kernel said no"]))
        XCTAssertThrowsError(try PrivacySupervisorReply(object: ["type": "privacy_supervisor_error", "version": true, "reason": "unsupported"]))
        let oversizeAssertion: [String: Any] = [
            "type": "privacy_supervisor_assertion", "version": 1, "statement": try fixturePosture().wireObject,
            "assertion": PrivacySupervisorBase64URL.encode(Data(repeating: 1, count: PrivacySupervisorConstants.maxAssertionBytes + 1)),
        ]
        XCTAssertThrowsError(try PrivacySupervisorReply(object: oversizeAssertion))
    }

    func testAppAttestKeyIDConversion() {
        let raw = Data((0..<32).map { UInt8($0 * 7 & 0xff) })
        let standard = raw.base64EncodedString()
        let wire = PrivacySupervisorBase64URL.fromAppAttestKeyID(standard)
        XCTAssertEqual(wire, PrivacySupervisorBase64URL.encode(raw))
        XCTAssertEqual(wire.flatMap(PrivacySupervisorBase64URL.toAppAttestKeyID), standard)
        XCTAssertNil(PrivacySupervisorBase64URL.fromAppAttestKeyID(Data(repeating: 1, count: 31).base64EncodedString()))
    }

    func testChildRequirementTextRejectsInjection() {
        XCTAssertEqual(
            PrivacySupervisorPeer.requirement(identifier: "tech.malibu.app", teamID: "AB12CD34EF"),
            "anchor apple generic and identifier \"tech.malibu.app\" and certificate leaf[subject.OU] = \"AB12CD34EF\""
        )
        XCTAssertEqual(
            PrivacySupervisorPeer.requirement(identifier: "live.malibu.provider.cli", teamID: "AB12CD34EF", cdhash: String(repeating: "ab", count: 20)),
            "anchor apple generic and identifier \"live.malibu.provider.cli\" and certificate leaf[subject.OU] = \"AB12CD34EF\" and cdhash H\"abababababababababababababababababababab\""
        )
        XCTAssertNil(PrivacySupervisorPeer.requirement(identifier: "x\" or anchor trusted", teamID: "AB12CD34EF"))
        XCTAssertNil(PrivacySupervisorPeer.requirement(identifier: "tech.malibu.app", teamID: "AB\" or 1\""))
        XCTAssertNil(PrivacySupervisorPeer.requirement(identifier: "tech.malibu.app", teamID: "AB12CD34EF", cdhash: "ABAB"))
    }

    func testChildCSFlagMasks() {
        XCTAssertTrue(PrivacySupervisorConstants.childCSFlagsOK(0x2201_1311))
        XCTAssertFalse(PrivacySupervisorConstants.childCSFlagsOK(0x2201_1311 & ~0x0001_0000))
        XCTAssertFalse(PrivacySupervisorConstants.childCSFlagsOK(0x2201_1311 | 0x1000_0000))
        XCTAssertFalse(PrivacySupervisorConstants.childCSFlagsOK(0x2201_1311 | 0x0000_0004))
        XCTAssertFalse(PrivacySupervisorConstants.childCSFlagsOK(0x1_0000_0000 | 0x0001_0301))
    }

    func testSocketClientRefusesAPeerThatIsNotTheVerifiedParentApp() async throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mpc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ps.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        // The listener is this test process, not the parent Malibu.app, so
        // the client must refuse it before sending anything.
        let client = PrivacySupervisorSocketClient(path: path, teamID: "AB12CD34EF")
        do {
            _ = try await client.exchange(.key(discard: nil), timeout: 2)
            XCTFail("an unverified peer must be refused")
        } catch {
            XCTAssertEqual(error as? PrivacySupervisorChannelError, .peerRejected)
        }
        let missing = PrivacySupervisorSocketClient(path: directory.appendingPathComponent("absent.sock").path, teamID: "AB12CD34EF")
        do {
            _ = try await missing.exchange(.key(discard: nil), timeout: 2)
            XCTFail("an absent supervisor must fail")
        } catch {
            XCTAssertEqual(error as? PrivacySupervisorChannelError, .unavailable)
        }
        XCTAssertNil(ServeCommand.privacySupervisorChannel(codeBound: false, socketPath: path, privacyMode: true, teamID: { "AB12CD34EF" }))
        XCTAssertNil(ServeCommand.privacySupervisorChannel(codeBound: true, socketPath: path, privacyMode: false, teamID: { "AB12CD34EF" }))
        XCTAssertNil(ServeCommand.privacySupervisorChannel(codeBound: true, socketPath: nil, privacyMode: true, teamID: { "AB12CD34EF" }))
        XCTAssertNotNil(ServeCommand.privacySupervisorChannel(codeBound: true, socketPath: path, privacyMode: true, teamID: { "AB12CD34EF" }))
    }

    // MARK: Coordinator messages

    func testCoordinatorEnrollmentMessagesAreClosed() throws {
        let keyID = PrivacySupervisorBase64URL.encode(Data(repeating: 0x11, count: 32))
        let challenge: [String: Any] = [
            "type": "privacy_app_attest_enroll_challenge", "version": 1, "app_attest_key_id": keyID,
            "challenge": PrivacySupervisorBase64URL.encode(Data(repeating: 0x22, count: 32)), "issued_at_unix": 1_700_000_000,
        ]
        XCTAssertEqual(try PrivacyAppAttestCoordinatorMessage.challenge(challenge).appAttestKeyID, keyID)
        var extra = challenge
        extra["x"] = 1
        XCTAssertThrowsError(try PrivacyAppAttestCoordinatorMessage.challenge(extra))
        var badVersion = challenge
        badVersion["version"] = 1.5
        XCTAssertThrowsError(try PrivacyAppAttestCoordinatorMessage.challenge(badVersion))
        for status in ["enrolled", "reenroll_required", "unavailable", "rejected"] {
            let result: [String: Any] = ["type": "privacy_app_attest_enroll_result", "version": 1, "app_attest_key_id": keyID, "status": status]
            XCTAssertEqual(try PrivacyAppAttestCoordinatorMessage.result(result).status, status)
        }
        XCTAssertThrowsError(try PrivacyAppAttestCoordinatorMessage.result(["type": "privacy_app_attest_enroll_result", "version": 1, "app_attest_key_id": keyID, "status": "ok"]))
    }

    // MARK: State machine

    func testControllerEnrollmentLifecycle() {
        let controller = PrivacyCodeBoundController()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = PrivacySupervisorBase64URL.encode(Data(repeating: 1, count: 32))
        let second = PrivacySupervisorBase64URL.encode(Data(repeating: 2, count: 32))
        XCTAssertNil(controller.beginEnrollmentIfDue(now: now), "no session, no enrollment")
        controller.bind(session: "s1")
        XCTAssertEqual(controller.advertisement, .beta)
        XCTAssertEqual(controller.postureMode, .v1)

        XCTAssertEqual(controller.beginEnrollmentIfDue(now: now), .some(nil))
        XCTAssertEqual(controller.advertisement, .suppressed)
        XCTAssertEqual(controller.postureMode, .skip)
        XCTAssertNil(controller.beginEnrollmentIfDue(now: now), "one outstanding request")
        controller.enrollmentRequested(appAttestKeyID: first)
        XCTAssertTrue(controller.takeChallenge(appAttestKeyID: first))
        XCTAssertFalse(controller.takeChallenge(appAttestKeyID: first), "challenge is single-use")
        XCTAssertEqual(controller.apply(result: "enrolled", appAttestKeyID: second, now: now), .none, "other keyIds are ignored")
        XCTAssertEqual(controller.apply(result: "enrolled", appAttestKeyID: first, now: now), .readvertise)
        XCTAssertEqual(controller.advertisement, .codeBound)
        XCTAssertEqual(controller.postureMode, .v2(appAttestKeyID: first))
        XCTAssertNil(controller.beginEnrollmentIfDue(now: now))

        // Key loss while enrolled: postures stop, code-bound records stay,
        // and a new key is enrolled with the old one discarded.
        controller.noteAssertionFailure(.keyInvalid, keyID: first)
        XCTAssertEqual(controller.postureMode, .skip)
        XCTAssertEqual(controller.advertisement, .codeBound)
        XCTAssertEqual(controller.beginEnrollmentIfDue(now: now), .some(first))
        controller.enrollmentRequested(appAttestKeyID: second)
        XCTAssertEqual(controller.advertisement, .codeBound)
        XCTAssertEqual(controller.apply(result: "enrolled", appAttestKeyID: second, now: now), .readvertise)
        XCTAssertEqual(controller.postureMode, .v2(appAttestKeyID: second))

        // An unsolicited reenroll_required returns to Beta at once.
        XCTAssertEqual(controller.apply(result: "reenroll_required", appAttestKeyID: second, now: now), .readvertise)
        XCTAssertEqual(controller.advertisement, .beta)
        XCTAssertEqual(controller.postureMode, .v1)
        XCTAssertEqual(controller.beginEnrollmentIfDue(now: now), .some(second))
        controller.enrollmentRequested(appAttestKeyID: first)

        // unavailable: Beta, retry no sooner than 300 seconds.
        XCTAssertEqual(controller.apply(result: "unavailable", appAttestKeyID: first, now: now), .none)
        XCTAssertEqual(controller.advertisement, .beta)
        XCTAssertNil(controller.beginEnrollmentIfDue(now: now.addingTimeInterval(299)))
        XCTAssertEqual(controller.beginEnrollmentIfDue(now: now.addingTimeInterval(300)), .some(nil))
        controller.enrollmentRequested(appAttestKeyID: first)

        // A new session drops the in-memory enrolled state.
        controller.bind(session: "s2")
        XCTAssertEqual(controller.advertisement, .beta)
        XCTAssertEqual(controller.postureMode, .v1)

        // rejected latches for the process lifetime.
        XCTAssertEqual(controller.beginEnrollmentIfDue(now: now.addingTimeInterval(301)), .some(nil))
        controller.enrollmentRequested(appAttestKeyID: first)
        XCTAssertEqual(controller.apply(result: "rejected", appAttestKeyID: first, now: now), .none)
        XCTAssertTrue(controller.isRejected)
        controller.bind(session: "s3")
        XCTAssertNil(controller.beginEnrollmentIfDue(now: now.addingTimeInterval(10_000)))
        XCTAssertEqual(controller.postureMode, .v1)
    }

    func testControllerLocalFailureFallsBackToBeta() {
        let controller = PrivacyCodeBoundController()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        controller.bind(session: "s1")
        XCTAssertNotNil(controller.beginEnrollmentIfDue(now: now))
        controller.enrollmentFailedLocally(now: now)
        XCTAssertEqual(controller.advertisement, .beta)
        XCTAssertEqual(controller.postureMode, .v1)
        XCTAssertNil(controller.beginEnrollmentIfDue(now: now.addingTimeInterval(1)))
    }

    func testSendFilterDropsStaleLabels() {
        let beta: [String: Any] = ["privacy_key_attestation": ["assurance": PrivacyClassConstants.assurance]]
        let bound: [String: Any] = ["privacy_key_attestation": ["assurance": PrivacyClassConstants.assuranceCodeBound]]
        var message: [String: Any] = ["type": "heartbeat", "privacy_key_records": [beta]]
        PrivacyRecordSendFilter.apply(&message, advertisement: .beta)
        XCTAssertNotNil(message["privacy_key_records"])
        PrivacyRecordSendFilter.apply(&message, advertisement: .codeBound)
        XCTAssertNil(message["privacy_key_records"])
        message["privacy_key_records"] = [bound]
        PrivacyRecordSendFilter.apply(&message, advertisement: .suppressed)
        XCTAssertNil(message["privacy_key_records"])
        message["privacy_key_records"] = [[String: Any]]()
        PrivacyRecordSendFilter.apply(&message, advertisement: .suppressed)
        XCTAssertNotNil(message["privacy_key_records"], "an empty advertisement carries no label")
    }

    // MARK: Provider end to end with a supervisor double

    func testPrivacyCodeBoundFallsBackToBetaWhenSupervisorUnavailable() async throws {
        for failure in [FakeSupervisor.Failure.channel, .unsupported] {
            let supervisor = FakeSupervisor(failure: failure)
            let harness = try makeHarness(supervisor: supervisor)
            await harness.client.acceptAssignedSessionForTest(assignedID: "session-accepted")
            try await harness.client.handleCoordinatorPayloadForTest(postureChallenge(0x31))
            let frames = await harness.recorder.frames()
            XCTAssertEqual(frames.map { $0["type"] as? String }, ["privacy_posture_response"])
            XCTAssertEqual(frames.first?["version"] as? Int, 1)
            try await harness.client.sendHeartbeatForTest()
            let heartbeatFrames = await harness.recorder.frames()
            let heartbeat = try XCTUnwrap(heartbeatFrames.last)
            XCTAssertEqual(try assurances(heartbeat), [PrivacyClassConstants.assurance])
            // Nothing code-bound is accepted from the coordinator either.
            try await harness.client.handleCoordinatorPayloadForTest(result("enrolled", key: supervisor.keyID))
            try await harness.client.handleCoordinatorPayloadForTest(postureChallenge(0x32))
            let after = await harness.recorder.frames()
            XCTAssertEqual(after.last?["version"] as? Int, 1)
            XCTAssertFalse(after.contains { $0["type"] as? String == "privacy_app_attest_enroll_request" })
        }
    }

    func testPrivacyCodeBoundWithoutSupervisorNeverEnrolls() async throws {
        let harness = try makeHarness(supervisor: nil)
        await harness.client.acceptAssignedSessionForTest(assignedID: "session-accepted")
        try await harness.client.handleCoordinatorPayloadForTest(postureChallenge(0x31))
        try await harness.client.handleCoordinatorPayloadForTest(result("enrolled", key: PrivacySupervisorBase64URL.encode(Data(repeating: 0x11, count: 32))))
        try await harness.client.handleCoordinatorPayloadForTest(postureChallenge(0x32))
        let frames = await harness.recorder.frames()
        XCTAssertEqual(frames.map { $0["type"] as? String }, ["privacy_posture_response", "privacy_posture_response"])
        XCTAssertTrue(frames.allSatisfy { $0["version"] as? Int == 1 })
    }

    func testPrivacyCodeBoundEnrollmentAndPostureV2() async throws {
        let supervisor = FakeSupervisor(failure: nil)
        let harness = try makeHarness(supervisor: supervisor)
        let client = harness.client
        await client.acceptAssignedSessionForTest(assignedID: "session-accepted")

        // 1. A posture challenge proves the records were accepted: answer v1,
        //    then request enrollment for the supervisor's keyId.
        try await client.handleCoordinatorPayloadForTest(postureChallenge(0x31))
        var frames = await harness.recorder.frames()
        XCTAssertEqual(frames.map { $0["type"] as? String }, ["privacy_posture_response", "privacy_app_attest_enroll_request"])
        XCTAssertEqual(frames[0]["version"] as? Int, 1)
        XCTAssertEqual(frames[1]["app_attest_key_id"] as? String, supervisor.keyID)
        XCTAssertEqual(Set(frames[1].keys), ["type", "version", "app_attest_key_id"])

        // 2. While the request is outstanding, records are withheld.
        try await client.sendHeartbeatForTest()
        frames = await harness.recorder.frames()
        XCTAssertNil(frames.last?["privacy_key_records"])

        // 3. Enrollment: the supervisor fills its fields and attests; the
        //    provider signs the framing it recomputed.
        let challengeBytes = Data(repeating: 0x77, count: 32)
        try await client.handleCoordinatorPayloadForTest([
            "type": "privacy_app_attest_enroll_challenge", "version": 1, "app_attest_key_id": supervisor.keyID,
            "challenge": PrivacySupervisorBase64URL.encode(challengeBytes), "issued_at_unix": 1_700_000_000,
        ])
        frames = await harness.recorder.frames()
        let enrollment = try XCTUnwrap(frames.last)
        XCTAssertEqual(enrollment["type"] as? String, "privacy_app_attest_enrollment")
        XCTAssertEqual(Set(enrollment.keys), ["type", "version", "statement", "attestation", "se_signature", "identity_signature"])
        let enrollmentStatement = try PrivacyEnrollmentStatement(object: try XCTUnwrap(enrollment["statement"] as? [String: Any]))
        XCTAssertEqual(enrollmentStatement.draft.challenge, PrivacySupervisorBase64URL.encode(challengeBytes))
        XCTAssertEqual(enrollmentStatement.draft.sePublicKey, RelayBlindBase64URL.encode(harness.signer.publicKeyRaw))
        try assertSignatures(enrollment, framing: try enrollmentStatement.framing(), harness: harness)
        XCTAssertEqual(try RelayBlindBase64URL.decode(try XCTUnwrap(enrollment["attestation"] as? String)), FakeSupervisor.attestation)

        // 4. enrolled: re-advertise every record as code_bound_attested.
        try await client.handleCoordinatorPayloadForTest(result("enrolled", key: supervisor.keyID))
        frames = await harness.recorder.frames()
        XCTAssertEqual(frames.last?["type"] as? String, "heartbeat")
        XCTAssertEqual(try assurances(try XCTUnwrap(frames.last)), [PrivacyClassConstants.assuranceCodeBound])
        let hello = await client.helloMessage()
        XCTAssertEqual(try assurances(hello), [PrivacyClassConstants.assuranceCodeBound])

        // 5. Postures are now version 2 with the supervisor's assertion.
        try await client.handleCoordinatorPayloadForTest(postureChallenge(0x32))
        frames = await harness.recorder.frames()
        let v2 = try XCTUnwrap(frames.last)
        XCTAssertEqual(v2["type"] as? String, "privacy_posture_response")
        XCTAssertEqual(v2["version"] as? Int, 2)
        XCTAssertEqual(Set(v2.keys), ["type", "version", "statement", "se_signature", "identity_signature", "app_attest_assertion"])
        let statement = try PrivacyPostureV2Statement(object: try XCTUnwrap(v2["statement"] as? [String: Any]))
        XCTAssertEqual(statement.draft.appAttestKeyID, supervisor.keyID)
        XCTAssertEqual(statement.draft.assurance, PrivacyClassConstants.assuranceCodeBound)
        XCTAssertTrue(statement.childCheckConsistent)
        try assertSignatures(v2, framing: try statement.framing(), harness: harness)
        XCTAssertEqual(try RelayBlindBase64URL.decode(try XCTUnwrap(v2["app_attest_assertion"] as? String)), FakeSupervisor.assertion)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: v2).count, 12288)

        // 6. A tampered supervisor statement is never signed or sent.
        supervisor.tamperChildCDHash = true
        let before = await harness.recorder.frames().count
        try await client.handleCoordinatorPayloadForTest(postureChallenge(0x33))
        let afterTamper = await harness.recorder.frames().count
        XCTAssertEqual(afterTamper, before)
        supervisor.tamperChildCDHash = false

        // 7. Key loss: no posture, no version 1, a new enrollment request.
        supervisor.assertFailure = .keyInvalid
        try await client.handleCoordinatorPayloadForTest(postureChallenge(0x34))
        try await client.handleCoordinatorPayloadForTest(postureChallenge(0x35))
        frames = await harness.recorder.frames()
        XCTAssertFalse(frames.dropFirst(afterTamper).contains { $0["type"] as? String == "privacy_posture_response" })
        XCTAssertEqual(frames.last?["type"] as? String, "privacy_app_attest_enroll_request")
        XCTAssertEqual(supervisor.requests.last, .key(discard: supervisor.firstKeyID))
        supervisor.assertFailure = nil

        // 8. reenroll_required for the active key ends the enrolled state.
        try await client.handleCoordinatorPayloadForTest(result("reenroll_required", key: supervisor.firstKeyID))
        frames = await harness.recorder.frames()
        XCTAssertEqual(frames.last?["type"] as? String, "heartbeat")
        XCTAssertNil(frames.last?["privacy_key_records"], "withheld while the new key's request is outstanding")
        try await client.handleCoordinatorPayloadForTest(result("unavailable", key: supervisor.keyID))
        try await client.sendHeartbeatForTest()
        frames = await harness.recorder.frames()
        XCTAssertEqual(try assurances(try XCTUnwrap(frames.last)), [PrivacyClassConstants.assurance])
        try await client.handleCoordinatorPayloadForTest(postureChallenge(0x36))
        frames = await harness.recorder.frames()
        XCTAssertEqual(frames.last?["version"] as? Int, 1)
    }

    // MARK: Helpers

    private struct Harness {
        let client: CoordinatorClient
        let recorder: CodeBoundFrameRecorder
        let signer: SELivenessTestSigning
        let runtimeRoot: URL
    }

    private func makeHarness(supervisor: FakeSupervisor?) throws -> Harness {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macprovider-privacy-code-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let signer = try SELivenessTestSigning.generate()
        let recorder = CodeBoundFrameRecorder()
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-privacy-code-bound-test.yaml")
        config.coordinatorURL = "wss://127.0.0.1:8444/ws/provider"
        config.providerID = "provider-test"
        config.model = "model-a"
        config.relayBlindEnabled = true
        config.privacyClassBeta = true
        config.relayBlindStateDirectory = root.path
        let client = try XCTUnwrap(CoordinatorClient(
            config: config,
            modelRuntime: CodeBoundIdleRuntime(),
            providerStatus: ProviderStatus(
                modelID: "model-a",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: 1)
            ),
            sendOverride: { frame in
                await recorder.append(frame)
            },
            attestationGenerator: ManagedDeviceAttestationGenerator(),
            privacyPostureProbeOverride: FixedPrivacyProbe(),
            privacySESignerOverride: signer,
            privacySupervisorChannel: supervisor,
            sleepAssertionFactory: { nil },
            installedCompatibilityManifest: { _, _ in nil },
            watchdogExitHook: { _ in }
        ))
        return Harness(client: client, recorder: recorder, signer: signer, runtimeRoot: root)
    }

    private func assertSignatures(_ message: [String: Any], framing: Data, harness: Harness) throws {
        var x963 = Data([0x04])
        x963.append(harness.signer.publicKeyRaw)
        let publicKey = try P256.Signing.PublicKey(x963Representation: x963)
        let der = try RelayBlindBase64URL.decode(try XCTUnwrap(message["se_signature"] as? String))
        XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der), for: framing))
        let keys = try RelayBlindKeyManager(directory: harness.runtimeRoot, models: ["model-a"], persistAgreementKey: false)
        let identity = try Curve25519.Signing.PublicKey(
            rawRepresentation: try RelayBlindBase64URL.decode(keys.identityPublicKeyBase64URL(), exactCount: 32)
        )
        let signature = try RelayBlindBase64URL.decode(try XCTUnwrap(message["identity_signature"] as? String), exactCount: 64)
        XCTAssertTrue(identity.isValidSignature(signature, for: framing))
    }

    private func assurances(_ message: [String: Any]) throws -> Set<String> {
        let records = try XCTUnwrap(message["privacy_key_records"] as? [[String: Any]])
        XCTAssertFalse(records.isEmpty)
        return Set(try records.map { try XCTUnwrap(($0["privacy_key_attestation"] as? [String: Any])?["assurance"] as? String) })
    }

    private func postureChallenge(_ byte: UInt8) -> [String: Any] {
        [
            "type": "privacy_posture_challenge",
            "version": 1,
            "nonce": RelayBlindBase64URL.encode(Data(repeating: byte, count: 32)),
            "issued_at_unix": 1_700_000_000,
        ]
    }

    private func result(_ status: String, key: String) -> [String: Any] {
        ["type": "privacy_app_attest_enroll_result", "version": 1, "app_attest_key_id": key, "status": status]
    }

    private func codeBoundFixture() throws -> [String: Any] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = tests.appendingPathComponent("../../../test/fixtures/relay-blind/privacy-code-bound-v2.json").standardizedFileURL
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func fixturePosture() throws -> PrivacyPostureV2Statement {
        try PrivacyPostureV2Statement(object: try XCTUnwrap(try codeBoundFixture()["posture_v2"] as? [String: Any]))
    }

    private func fixtureEnrollment() throws -> PrivacyEnrollmentStatement {
        try PrivacyEnrollmentStatement(object: try XCTUnwrap(try codeBoundFixture()["enrollment"] as? [String: Any]))
    }

    private func fixtureEnrollmentDraft() throws -> PrivacyEnrollmentDraft {
        try fixtureEnrollment().draft
    }
}

/// Supervisor double. Real `DCAppAttestService` cannot run in tests.
private final class FakeSupervisor: PrivacySupervisorChannel, @unchecked Sendable {
    enum Failure { case channel, unsupported }
    static let attestation = Data(repeating: 0xa7, count: 700)
    static let assertion = Data(repeating: 0x3c, count: 90)

    private let lock = NSLock()
    private let failure: Failure?
    private var keyIndex: UInt8 = 0x11
    private var recorded: [PrivacySupervisorRequest] = []
    private var tamper = false
    private var assertError: PrivacySupervisorErrorReason?
    let firstKeyID = PrivacySupervisorBase64URL.encode(Data(repeating: 0x11, count: 32))

    init(failure: Failure?) {
        self.failure = failure
    }

    var keyID: String {
        lock.lock()
        defer { lock.unlock() }
        return PrivacySupervisorBase64URL.encode(Data(repeating: keyIndex, count: 32))
    }

    var requests: [PrivacySupervisorRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var tamperChildCDHash: Bool {
        get { lock.lock(); defer { lock.unlock() }; return tamper }
        set { lock.lock(); tamper = newValue; lock.unlock() }
    }

    var assertFailure: PrivacySupervisorErrorReason? {
        get { lock.lock(); defer { lock.unlock() }; return assertError }
        set { lock.lock(); assertError = newValue; lock.unlock() }
    }

    func exchange(_ request: PrivacySupervisorRequest, timeout: TimeInterval) async throws -> PrivacySupervisorReply {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        switch failure {
        case .channel: throw PrivacySupervisorChannelError.unavailable
        case .unsupported: return .error(.unsupported)
        case nil: break
        }
        switch request {
        case .key(let discard):
            if discard != nil { keyIndex += 1 }
            return .key(appAttestKeyID: PrivacySupervisorBase64URL.encode(Data(repeating: keyIndex, count: 32)))
        case .attest(let draft):
            let fields = PrivacySupervisorEnrollmentFields(
                teamID: "AB12CD34EF",
                bundleID: PrivacySupervisorConstants.supervisorBundleID,
                environment: PrivacySupervisorConstants.environment,
                childCDHash: String(repeating: "ab", count: 20),
                childCSFlags: 0x2201_1311,
                supervisorBundleVersion: "213",
                issuedAtUnix: 1_700_000_000
            )
            return .attestation(PrivacyEnrollmentStatement(draft: draft, supervisor: fields), attestation: Self.attestation)
        case .assert(let draft):
            if let assertError { return .error(assertError) }
            let fields = PrivacySupervisorPostureFields(
                supervisorTeamID: draft.teamID,
                supervisorBundleID: PrivacySupervisorConstants.supervisorBundleID,
                supervisorBundleVersion: "213",
                childCDHash: tamper ? String(repeating: "cd", count: 20) : draft.codeCDHash,
                childSigningIdentifier: PrivacySupervisorConstants.childSigningIdentifier,
                childCSFlags: 0x2201_1311,
                childCheckedAtUnix: draft.issuedAtUnix,
                childChannelPeerVerified: true
            )
            return .assertion(PrivacyPostureV2Statement(draft: draft, supervisor: fields), assertion: Self.assertion)
        }
    }
}

private actor CodeBoundFrameRecorder {
    private var stored: [[String: Any]] = []

    func append(_ frame: [String: Any]) {
        stored.append(frame)
    }

    func frames() -> [[String: Any]] { stored }
}

private struct FixedPrivacyProbe: PrivacyPostureProbe {
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

private actor CodeBoundIdleRuntime: ModelRuntimeServing {
    func complete(
        _ request: ChatCompletionRequest,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> CompletionResult {
        throw RelayBlindProviderError.providerUnsupported
    }

    func stream(
        _ request: ChatCompletionRequest,
        with handle: RequestHandle,
        shouldCancel: @escaping @Sendable () -> Bool,
        onChunk: @escaping @Sendable (StreamChunk) -> Void
    ) async throws -> CompletionResult {
        throw RelayBlindProviderError.providerUnsupported
    }

    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
        throw RelayBlindProviderError.providerUnsupported
    }

    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
        throw RelayBlindProviderError.providerUnsupported
    }

    func unregisterInFlight(_ id: Int) {}

    var loadedModelHash: String? { nil }
    var loadedModelHashAlgorithm: String? { nil }
    var loadedWeightsManifestSHA256: String? { nil }
    var isLoaded: Bool { false }
    func setProviderStatus(_ providerStatus: ProviderStatus) async {}
    nonisolated var isSettlementReceiptEligible: Bool { false }
    nonisolated var settlementRuntimeSource: String? { nil }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
