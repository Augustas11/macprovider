import XCTest
@testable import MacProviderCore

final class ShardStageFrameTests: XCTestCase {
    private func activationFrame(width: Int = 8, sequence: UInt64 = 0) -> ShardStageFrame {
        let header = ShardStageFrameHeader(
            kind: .activation,
            dtype: .bfloat16,
            groupEpoch: 7,
            requestID: 0x1122_3344_5566_7788,
            microBatchID: 3,
            tokenStep: 42,
            sourceStage: 0,
            destinationStage: 1,
            layerStart: 0,
            layerEnd: 8,
            sequence: sequence,
            shape: [1, 1, UInt32(width)]
        )
        let payload = Data((0..<(2 * width)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        return ShardStageFrame(header: header, payload: payload)
    }

    /// Overwrite `bytes` at `offset`, then recompute the trailing CRC so the decoder
    /// reaches the semantic check under test instead of failing on the checksum.
    private func patched(_ data: Data, at offset: Int, with replacement: [UInt8]) -> Data {
        var bytes = [UInt8](data)
        bytes.replaceSubrange(offset..<(offset + replacement.count), with: replacement)
        let crcOffset = bytes.count - 4
        let crc = CRC32C.checksum(bytes[0..<crcOffset])
        withUnsafeBytes(of: crc.littleEndian) { bytes.replaceSubrange(crcOffset..<bytes.count, with: $0) }
        return Data(bytes)
    }

    private func assertDecodeThrows(
        _ data: Data,
        _ expected: ShardFrameError,
        limits: ShardFrameLimits = ShardFrameLimits(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ShardStageFrameCodec.decode(data, limits: limits), file: file, line: line) { error in
            XCTAssertEqual(error as? ShardFrameError, expected, file: file, line: line)
        }
    }

    // MARK: - CRC32C

    func testCRC32CKnownVectors() {
        XCTAssertEqual(CRC32C.checksum(Array("123456789".utf8)), 0xE306_9283)
        XCTAssertEqual(CRC32C.checksum([UInt8]()), 0)
        // RFC 3720 B.4: 32 bytes of zeros and 32 bytes of 0xFF.
        XCTAssertEqual(CRC32C.checksum([UInt8](repeating: 0, count: 32)), 0x8A91_36AA)
        XCTAssertEqual(CRC32C.checksum([UInt8](repeating: 0xFF, count: 32)), 0x62A8_AB43)
    }

    func testCRC32CIncrementalMatchesOneShot() {
        let bytes = Array("pipeline stage activation".utf8)
        let split = CRC32C.update(CRC32C.update(0, bytes[0..<9]), bytes[9...])
        XCTAssertEqual(split, CRC32C.checksum(bytes))
    }

    // MARK: - Round trip

    func testActivationRoundTrip() throws {
        let frame = activationFrame()
        let encoded = try ShardStageFrameCodec.encode(frame)
        XCTAssertEqual(encoded.count, ShardStageFrameCodec.frameSize(rank: 3, payloadLength: 16))
        XCTAssertEqual(try ShardStageFrameCodec.frameLength(fixedHeader: encoded.prefix(60)), encoded.count)
        XCTAssertEqual(try ShardStageFrameCodec.decode(encoded), frame)
    }

    func testEveryKindRoundTrips() throws {
        let frames: [ShardStageFrame] = [
            ShardStageFrame(header: ShardStageFrameHeader(kind: .hello, groupEpoch: 1), payload: Data(#"{"role":"head"}"#.utf8)),
            ShardStageFrame(header: ShardStageFrameHeader(kind: .heartbeat, groupEpoch: 1, sequence: 9)),
            ShardStageFrame(header: ShardStageFrameHeader(kind: .abort, groupEpoch: 1, requestID: 5)),
            ShardStageFrame(header: ShardStageFrameHeader(kind: .error, groupEpoch: 1), payload: Data("boom".utf8)),
            ShardStageFrame(
                header: ShardStageFrameHeader(kind: .control, groupEpoch: 1, requestID: 5),
                payload: Data(#"{"op":"open","temperature":0,"top_p":1}"#.utf8)),
            ShardStageFrame(
                header: ShardStageFrameHeader(kind: .token, dtype: .int32, groupEpoch: 1, shape: [2]),
                payload: Data([1, 0, 0, 0, 2, 0, 0, 0])
            ),
            ShardStageFrame(
                header: ShardStageFrameHeader(kind: .activation, dtype: .float32, groupEpoch: 1, shape: [1]),
                payload: Data([0, 0, 0x80, 0x3F])
            ),
            ShardStageFrame(
                header: ShardStageFrameHeader(kind: .activation, dtype: .float16, groupEpoch: 1, shape: [2, 1]),
                payload: Data([0, 0x3C, 0, 0x40])
            ),
        ]
        for frame in frames {
            XCTAssertEqual(try ShardStageFrameCodec.decode(try ShardStageFrameCodec.encode(frame)), frame)
        }
    }

    // MARK: - Rejections

    func testRejectsBadMagic() throws {
        let encoded = try ShardStageFrameCodec.encode(activationFrame())
        assertDecodeThrows(patched(encoded, at: 0, with: [0x4D, 0x50, 0x53, 0x00]), .badMagic)
    }

    func testRejectsUnsupportedVersion() throws {
        let encoded = try ShardStageFrameCodec.encode(activationFrame())
        assertDecodeThrows(patched(encoded, at: 4, with: [2, 0]), .unsupportedVersion(2))
    }

    func testRejectsUnknownKindAndDType() throws {
        let encoded = try ShardStageFrameCodec.encode(activationFrame())
        assertDecodeThrows(patched(encoded, at: 6, with: [99]), .unknownKind(99))
        assertDecodeThrows(patched(encoded, at: 7, with: [77]), .unknownDType(77))
    }

    func testRejectsNonzeroReserved() throws {
        let encoded = try ShardStageFrameCodec.encode(activationFrame())
        assertDecodeThrows(patched(encoded, at: 58, with: [1]), .nonzeroReserved)
    }

    func testFillOnlyFlagRoundTripsOnActivationsOnly() throws {
        var frame = activationFrame()
        frame.header.flags = .fillOnly
        let encoded = try ShardStageFrameCodec.encode(frame)
        XCTAssertEqual([UInt8](encoded)[57], 1)
        XCTAssertEqual(try ShardStageFrameCodec.decode(encoded), frame)
        XCTAssertEqual(try ShardStageFrameCodec.decode(try ShardStageFrameCodec.encode(activationFrame())).header.flags, [])

        assertDecodeThrows(patched(encoded, at: 57, with: [0x03]), .unknownFlags(0x03))
        var unknown = activationFrame()
        unknown.header.flags = ShardFrameFlags(rawValue: 0x80)
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(unknown)) { error in
            XCTAssertEqual(error as? ShardFrameError, .unknownFlags(0x80))
        }

        let token = ShardStageFrame(
            header: ShardStageFrameHeader(kind: .token, dtype: .int32, groupEpoch: 7, shape: [1]),
            payload: Data([1, 0, 0, 0]))
        assertDecodeThrows(patched(try ShardStageFrameCodec.encode(token), at: 57, with: [1]), .flagsOnNonActivation(kind: .token))
        var flaggedToken = token
        flaggedToken.header.flags = .fillOnly
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(flaggedToken)) { error in
            XCTAssertEqual(error as? ShardFrameError, .flagsOnNonActivation(kind: .token))
        }
    }

    func testRejectsRankAboveLimit() throws {
        let encoded = try ShardStageFrameCodec.encode(activationFrame())
        assertDecodeThrows(patched(encoded, at: 56, with: [9]), .rankTooLarge(9))
        var frame = activationFrame()
        frame.header.shape = Array(repeating: 1, count: 9)
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(frame)) { error in
            XCTAssertEqual(error as? ShardFrameError, .rankTooLarge(9))
        }
    }

    func testRejectsOversizePayloadOnDecodeAndEncode() throws {
        let frame = activationFrame(width: 64)
        let encoded = try ShardStageFrameCodec.encode(frame)
        let small = ShardFrameLimits(payloadCap: 100)
        assertDecodeThrows(encoded, .payloadTooLarge(length: 128, cap: 100), limits: small)
        XCTAssertThrowsError(try ShardStageFrameCodec.frameLength(fixedHeader: encoded.prefix(60), limits: small)) { error in
            XCTAssertEqual(error as? ShardFrameError, .payloadTooLarge(length: 128, cap: 100))
        }
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(frame, limits: small)) { error in
            XCTAssertEqual(error as? ShardFrameError, .payloadTooLarge(length: 128, cap: 100))
        }
        // A header claiming a 4 GiB payload is refused before anything is allocated for it.
        assertDecodeThrows(
            patched(encoded, at: 52, with: [0xFF, 0xFF, 0xFF, 0xFF]),
            .payloadTooLarge(length: Int(UInt32.max), cap: ShardFrameLimits.defaultPayloadCap)
        )
    }

    func testRejectsShapePayloadMismatch() throws {
        let encoded = try ShardStageFrameCodec.encode(activationFrame(width: 8))
        // Last dim 8 -> 9: shape now implies 18 bytes against a 16-byte payload.
        assertDecodeThrows(
            patched(encoded, at: 60 + 8, with: [9, 0, 0, 0]),
            .shapePayloadMismatch(expectedBytes: 18, payloadBytes: 16)
        )
        var frame = activationFrame(width: 8)
        frame.payload.removeLast()
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(frame)) { error in
            XCTAssertEqual(error as? ShardFrameError, .shapePayloadMismatch(expectedBytes: 16, payloadBytes: 15))
        }
    }

    func testRejectsOverflowingShape() throws {
        var frame = activationFrame(width: 8)
        frame.header.shape = [UInt32.max, UInt32.max, UInt32.max]
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(frame)) { error in
            guard case .shapePayloadMismatch = error as? ShardFrameError else {
                return XCTFail("expected shapePayloadMismatch, got \(error)")
            }
        }
    }

    func testRejectsKindDTypeMismatch() throws {
        let tokenAsFloat = ShardStageFrame(
            header: ShardStageFrameHeader(kind: .token, dtype: .float32, groupEpoch: 1, shape: [1]),
            payload: Data(count: 4)
        )
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(tokenAsFloat)) { error in
            XCTAssertEqual(error as? ShardFrameError, .kindDTypeMismatch(kind: .token, dtype: .float32))
        }
        let encoded = try ShardStageFrameCodec.encode(activationFrame())
        // Activation re-labelled int32 (same width class is irrelevant; the kind forbids it).
        assertDecodeThrows(patched(encoded, at: 7, with: [4]), .kindDTypeMismatch(kind: .activation, dtype: .int32))
        // Heartbeat carrying a tensor dtype.
        let heartbeat = try ShardStageFrameCodec.encode(ShardStageFrame(header: ShardStageFrameHeader(kind: .heartbeat, groupEpoch: 1)))
        assertDecodeThrows(patched(heartbeat, at: 7, with: [1]), .kindDTypeMismatch(kind: .heartbeat, dtype: .bfloat16))
    }

    func testRejectsOpaqueFrameWithShape() throws {
        let frame = ShardStageFrame(header: ShardStageFrameHeader(kind: .error, groupEpoch: 1, shape: [4]), payload: Data(count: 4))
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(frame)) { error in
            XCTAssertEqual(error as? ShardFrameError, .shapePayloadMismatch(expectedBytes: 0, payloadBytes: 4))
        }
    }

    func testRejectsInvertedLayerRange() throws {
        let encoded = try ShardStageFrameCodec.encode(activationFrame())
        assertDecodeThrows(patched(encoded, at: 36, with: [9, 0, 0, 0]), .invalidLayerRange(start: 9, end: 8))
    }

    func testRejectsChecksumMismatchOnAnyFlippedBit() throws {
        let encoded = try ShardStageFrameCodec.encode(activationFrame())
        // Flip one bit in the payload, in the request id, and in the CRC itself.
        for offset in [60 + 12 + 3, 17, encoded.count - 1] {
            var bytes = [UInt8](encoded)
            bytes[offset] ^= 0x10
            XCTAssertThrowsError(try ShardStageFrameCodec.decode(Data(bytes))) { error in
                guard case .checksumMismatch = error as? ShardFrameError else {
                    return XCTFail("offset \(offset): expected checksumMismatch, got \(error)")
                }
            }
        }
    }

    func testRejectsTrailingBytes() throws {
        var encoded = try ShardStageFrameCodec.encode(activationFrame())
        encoded.append(0)
        assertDecodeThrows(encoded, .trailingBytes(1))
    }

    func testEveryTruncationIsRejectedNeverTraps() throws {
        let encoded = try ShardStageFrameCodec.encode(activationFrame(width: 16))
        for length in 0..<encoded.count {
            XCTAssertThrowsError(try ShardStageFrameCodec.decode(encoded.prefix(length))) { error in
                guard case .truncated = error as? ShardFrameError else {
                    return XCTFail("length \(length): expected truncated, got \(error)")
                }
            }
        }
    }

    func testRandomCorruptionNeverDecodesToADifferentFrame() throws {
        let frame = activationFrame(width: 32)
        let encoded = [UInt8](try ShardStageFrameCodec.encode(frame))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            var bytes = encoded
            let flips = Int.random(in: 1...4, using: &generator)
            for _ in 0..<flips {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            let cut = Bool.random(using: &generator) ? bytes.count : Int.random(in: 0...bytes.count, using: &generator)
            let candidate = Data(bytes.prefix(cut))
            if let decoded = try? ShardStageFrameCodec.decode(candidate) {
                // Only an unchanged frame may decode (a random byte can equal the original).
                XCTAssertEqual(decoded, frame)
            }
        }
    }

    // MARK: - Receiver state machine

    func testReceiveStateAcceptsConsecutiveSequence() throws {
        var state = ShardLinkReceiveState(groupEpoch: 7)
        for sequence in 0..<5 as Range<UInt64> {
            try state.accept(activationFrame(sequence: sequence).header)
        }
        XCTAssertEqual(state.expectedSequence, 5)
    }

    func testReceiveStateRejectsGapReplayAndEpoch() throws {
        var state = ShardLinkReceiveState(groupEpoch: 7)
        try state.accept(activationFrame(sequence: 0).header)
        XCTAssertThrowsError(try state.accept(activationFrame(sequence: 2).header)) { error in
            XCTAssertEqual(error as? ShardFrameError, .sequenceGap(expected: 1, actual: 2))
        }
        XCTAssertThrowsError(try state.accept(activationFrame(sequence: 0).header)) { error in
            XCTAssertEqual(error as? ShardFrameError, .sequenceReplay(expected: 1, actual: 0))
        }
        var wrongEpoch = activationFrame(sequence: 1).header
        wrongEpoch.groupEpoch = 8
        XCTAssertThrowsError(try state.accept(wrongEpoch)) { error in
            XCTAssertEqual(error as? ShardFrameError, .epochMismatch(expected: 7, actual: 8))
        }
        // Rejected frames do not advance the expected sequence.
        XCTAssertEqual(state.expectedSequence, 1)
    }

    // MARK: - Request control

    func testRequestControlRoundTripsAndRefusesUnknownOrOutOfRangeFields() throws {
        let control = ShardRequestControl(temperature: 0.7, topP: 0.9, seed: 51)
        let encoded = try JSONEncoder().encode(control)
        XCTAssertEqual(try JSONDecoder().decode(ShardRequestControl.self, from: encoded), control)
        XCTAssertEqual(
            try JSONDecoder().decode(ShardRequestControl.self, from: Data(#"{"op":"open","temperature":0,"top_p":1}"#.utf8)),
            ShardRequestControl(temperature: 0))
        for bad in [
            #"{"op":"open","temperature":0,"top_p":1,"top_k":5}"#,
            #"{"op":"close","temperature":0,"top_p":1}"#,
            #"{"op":"open","temperature":-1,"top_p":1}"#,
            #"{"op":"open","temperature":0,"top_p":0}"#,
            #"{"op":"open","temperature":0}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(ShardRequestControl.self, from: Data(bad.utf8)), bad)
        }
    }

    func testControlFramesCarryNoTensor() {
        let frame = ShardStageFrame(
            header: ShardStageFrameHeader(kind: .control, dtype: .int32, groupEpoch: 1, shape: [1]), payload: Data(count: 4))
        XCTAssertThrowsError(try ShardStageFrameCodec.encode(frame))
    }
}
