import Foundation
import MLX
import MLXLMCommon

/// codec-v2 describes every cache layer in model order. Attention layers carry
/// their K/V tensors; recurrent layers carry no mutable "current" state here --
/// their reusable states are represented by complete token-bound checkpoints.
enum KVCacheLayerPayload: Sendable, Equatable {
    case attention(KVLayerPayload)
    case recurrent(layerIndex: Int, classID: String, cacheOffset: Int)

    var layerIndex: Int {
        switch self {
        case .attention(let payload): payload.layerIndex
        case .recurrent(let layerIndex, _, _): layerIndex
        }
    }

    var classID: String {
        switch self {
        case .attention(let payload): payload.classID
        case .recurrent(_, let classID, _): classID
        }
    }
}

struct KVRecurrentSlotPayload: Sendable, Equatable {
    let slotIndex: Int
    let dims: [Int]
    let dtype: KVCodecDType
    let bytes: Data
}

struct KVRecurrentLayerPayload: Sendable, Equatable {
    let layerIndex: Int
    let slots: [KVRecurrentSlotPayload]
}

struct KVRecurrentCheckpointPayload: Sendable, Equatable {
    let tokenCount: Int
    let layers: [KVRecurrentLayerPayload]
}

struct KVDecodedPayloadV2: Sendable, Equatable {
    let tokens: [Int32]
    let layers: [KVCacheLayerPayload]
    let checkpoints: [KVRecurrentCheckpointPayload]

    var tensorBytes: Int {
        let attention = layers.reduce(0) { total, layer in
            guard case .attention(let payload) = layer else { return total }
            return total + payload.keyBytes.count + payload.valueBytes.count
        }
        return checkpoints.reduce(attention) { total, checkpoint in
            total + checkpoint.layers.reduce(0) { layerTotal, layer in
                layerTotal + layer.slots.reduce(0) { $0 + $1.bytes.count }
            }
        }
    }
}

enum KVPayloadCodecV2 {
    private static let magic = Data("KVC2".utf8)
    private static let attentionKind: UInt8 = 1
    private static let recurrentKind: UInt8 = 2

    static func encodeSegments(
        tokens: [Int32], layers: [KVCacheLayerPayload], checkpoints: [KVRecurrentCheckpointPayload]
    ) throws -> [Data] {
        guard checkpoints.count <= KVDiskCacheFormat.maxRecurrentCheckpoints else {
            throw KVFormatError.encodeFailed("checkpoint count exceeds bound")
        }
        var segments: [Data] = []
        var header = magic
        header.append(try KVByteWriter.u32LE(tokens.count))
        for token in tokens { header.append(KVByteWriter.i32LE(token)) }
        header.append(try KVByteWriter.u32LE(layers.count))
        segments.append(header)

        for (expectedIndex, layer) in layers.enumerated() {
            guard layer.layerIndex == expectedIndex else {
                throw KVFormatError.encodeFailed("codec-v2 layers are not complete and ordered")
            }
            switch layer {
            case .attention(let payload):
                let expected = try KVPayloadCodec.expectedTensorBytes(dims: payload.dims, dtype: payload.dtype)
                guard payload.keyBytes.count == expected, payload.valueBytes.count == expected else {
                    throw KVFormatError.encodeFailed("attention tensor byte length disagrees with dims")
                }
                var pre = try layerPrefix(index: expectedIndex, kind: attentionKind, classID: payload.classID)
                pre.append(Data([UInt8(payload.ndim)]))
                for dim in payload.dims { pre.append(try KVByteWriter.u64LE(dim)) }
                pre.append(Data([UInt8(payload.dtype.rawValue)]))
                pre.append(try KVByteWriter.u64LE(payload.cacheOffset))
                pre.append(try KVByteWriter.u64LE(payload.keyBytes.count))
                segments += [pre, payload.keyBytes, try KVByteWriter.u64LE(payload.valueBytes.count), payload.valueBytes]
            case .recurrent(_, let classID, let cacheOffset):
                var recurrent = try layerPrefix(index: expectedIndex, kind: recurrentKind, classID: classID)
                recurrent.append(try KVByteWriter.u64LE(cacheOffset))
                segments.append(recurrent)
            }
        }

        segments.append(try KVByteWriter.u32LE(checkpoints.count))
        let recurrentIndices = layers.compactMap { layer -> Int? in
            if case .recurrent(let index, _, _) = layer { return index }
            return nil
        }
        var previousTokenCount = -1
        for checkpoint in checkpoints {
            guard checkpoint.tokenCount > previousTokenCount,
                  checkpoint.tokenCount >= 0,
                  checkpoint.tokenCount <= tokens.count,
                  checkpoint.layers.map(\.layerIndex) == recurrentIndices else {
                throw KVFormatError.encodeFailed("checkpoint token order or recurrent coverage invalid")
            }
            previousTokenCount = checkpoint.tokenCount
            var checkpointHeader = Data()
            checkpointHeader.append(try KVByteWriter.u32LE(checkpoint.tokenCount))
            checkpointHeader.append(try KVByteWriter.u32LE(checkpoint.layers.count))
            segments.append(checkpointHeader)
            for layer in checkpoint.layers {
                var layerHeader = Data()
                layerHeader.append(try KVByteWriter.u32LE(layer.layerIndex))
                layerHeader.append(try KVByteWriter.u16LE(layer.slots.count))
                segments.append(layerHeader)
                for (expectedSlot, slot) in layer.slots.enumerated() {
                    guard slot.slotIndex == expectedSlot,
                          slot.dims.count <= KVDiskCacheFormat.maxNdim else {
                        throw KVFormatError.encodeFailed("checkpoint slots are not complete and ordered")
                    }
                    let expected = try KVPayloadCodec.expectedTensorBytes(dims: slot.dims, dtype: slot.dtype)
                    guard slot.bytes.count == expected else {
                        throw KVFormatError.encodeFailed("checkpoint slot byte length disagrees with dims")
                    }
                    var slotHeader = Data()
                    slotHeader.append(try KVByteWriter.u16LE(slot.slotIndex))
                    slotHeader.append(Data([UInt8(slot.dims.count)]))
                    for dim in slot.dims { slotHeader.append(try KVByteWriter.u64LE(dim)) }
                    slotHeader.append(Data([UInt8(slot.dtype.rawValue)]))
                    slotHeader.append(try KVByteWriter.u64LE(slot.bytes.count))
                    segments += [slotHeader, slot.bytes]
                }
            }
        }
        return segments
    }

    static func decode(
        _ data: Data, expectedDecodedLength: Int, expectedLayers: [KVLayerRecord],
        expectedCheckpoints: [KVRecurrentCheckpointRecord]
    ) throws -> KVDecodedPayloadV2 {
        guard data.count == expectedDecodedLength else { throw corrupt("payload length disagrees with decoded_length") }
        var reader = KVByteReader(data)
        guard reader.readBytes(4) == magic,
              let tokenCount = reader.readU32LE(), tokenCount <= KVDiskCacheFormat.maxTokenCount else {
            throw corrupt("codec-v2 header invalid")
        }
        var tokens: [Int32] = []
        tokens.reserveCapacity(tokenCount)
        for _ in 0..<tokenCount {
            guard let token = reader.readI32LE() else { throw corrupt("token array truncated") }
            tokens.append(token)
        }
        guard let layerCount = reader.readU32LE(), layerCount == expectedLayers.count else {
            throw corrupt("layer count mismatch")
        }
        var layers: [KVCacheLayerPayload] = []
        layers.reserveCapacity(layerCount)
        for expected in expectedLayers {
            guard let index = reader.readU32LE(), index == expected.layerIndex,
                  let kind = reader.readU8(),
                  let classLength = reader.readU16LE(), classLength <= KVDiskCacheFormat.maxStringBytes,
                  let classData = reader.readBytes(classLength),
                  let classID = String(data: classData, encoding: .utf8), classID == expected.classID else {
                throw corrupt("ordered layer identity mismatch")
            }
            if kind == Int(attentionKind) {
                guard classID == "KVCacheSimple", let ndim = reader.readU8(), ndim == expected.ndim else {
                    throw corrupt("attention layer geometry mismatch")
                }
                var dims: [Int] = []
                for _ in 0..<ndim {
                    guard let dim = reader.readU64LE() else { throw corrupt("attention dims truncated") }
                    dims.append(dim)
                }
                guard dims == expected.dims,
                      let dtypeRaw = reader.readU8(), let dtype = KVCodecDType(rawValue: dtypeRaw), dtype == expected.dtype,
                      let offset = reader.readU64LE(),
                      let expectedBytes = try? KVPayloadCodec.expectedTensorBytes(dims: dims, dtype: dtype),
                      let keyLength = reader.readU64LE(), keyLength == expectedBytes,
                      let key = reader.readBytes(keyLength),
                      let valueLength = reader.readU64LE(), valueLength == expectedBytes,
                      let value = reader.readBytes(valueLength) else {
                    throw corrupt("attention tensor invalid")
                }
                layers.append(.attention(KVLayerPayload(
                    layerIndex: index, classID: classID, ndim: ndim, dims: dims, dtype: dtype,
                    cacheOffset: offset, keyBytes: key, valueBytes: value)))
            } else if kind == Int(recurrentKind) {
                guard classID == "MambaCache" || classID == "ArraysCache",
                      expected.ndim == 0, expected.dims.isEmpty,
                      let cacheOffset = reader.readU64LE(), cacheOffset == expected.cacheOffset else {
                    throw corrupt("recurrent layer record invalid")
                }
                layers.append(.recurrent(layerIndex: index, classID: classID, cacheOffset: cacheOffset))
            } else {
                throw corrupt("unknown layer kind")
            }
        }
        guard let checkpointCount = reader.readU32LE(), checkpointCount == expectedCheckpoints.count else {
            throw corrupt("checkpoint count mismatch")
        }
        var checkpoints: [KVRecurrentCheckpointPayload] = []
        for expectedCheckpoint in expectedCheckpoints {
            guard let checkpointTokenCount = reader.readU32LE(), checkpointTokenCount == expectedCheckpoint.tokenCount,
                  let recurrentLayerCount = reader.readU32LE(), recurrentLayerCount == expectedCheckpoint.layers.count else {
                throw corrupt("checkpoint identity mismatch")
            }
            var recurrentLayers: [KVRecurrentLayerPayload] = []
            for expectedLayer in expectedCheckpoint.layers {
                guard let layerIndex = reader.readU32LE(), layerIndex == expectedLayer.layerIndex,
                      let slotCount = reader.readU16LE(), slotCount == expectedLayer.slots.count else {
                    throw corrupt("checkpoint layer coverage mismatch")
                }
                var slots: [KVRecurrentSlotPayload] = []
                for expectedSlot in expectedLayer.slots {
                    guard let slotIndex = reader.readU16LE(), slotIndex == expectedSlot.slotIndex,
                          let ndim = reader.readU8(), ndim == expectedSlot.dims.count else {
                        throw corrupt("checkpoint slot identity mismatch")
                    }
                    var dims: [Int] = []
                    for _ in 0..<ndim {
                        guard let dim = reader.readU64LE() else { throw corrupt("checkpoint slot dims truncated") }
                        dims.append(dim)
                    }
                    guard dims == expectedSlot.dims,
                          let dtypeRaw = reader.readU8(), let dtype = KVCodecDType(rawValue: dtypeRaw), dtype == expectedSlot.dtype,
                          let byteCount = reader.readU64LE(), byteCount == expectedSlot.byteCount,
                          let bytes = reader.readBytes(byteCount) else {
                        throw corrupt("checkpoint slot geometry or bytes mismatch")
                    }
                    slots.append(.init(slotIndex: slotIndex, dims: dims, dtype: dtype, bytes: bytes))
                }
                recurrentLayers.append(.init(layerIndex: layerIndex, slots: slots))
            }
            checkpoints.append(.init(tokenCount: checkpointTokenCount, layers: recurrentLayers))
        }
        guard reader.isAtEnd else { throw corrupt("trailing codec-v2 bytes") }
        return .init(tokens: tokens, layers: layers, checkpoints: checkpoints)
    }

    private static func layerPrefix(index: Int, kind: UInt8, classID: String) throws -> Data {
        let classBytes = Data(classID.utf8)
        var data = Data()
        data.append(try KVByteWriter.u32LE(index))
        data.append(Data([kind]))
        data.append(try KVByteWriter.u16LE(classBytes.count))
        data.append(classBytes)
        return data
    }

    private static func corrupt(_ message: String) -> KVManifestParseError { .corrupt(message) }
}

enum KVRecurrentCacheSerialization {
    static func geometry(
        layers: [KVCache], checkpoints: [RecurrentStateCheckpoint]
    ) -> (layers: [KVLayerRecord], recurrent: [KVRecurrentLayerRecord])? {
        let recurrentIndices = layers.indices.filter { layers[$0] is ArraysCache }
        guard !recurrentIndices.isEmpty, let exemplar = checkpoints.last else { return nil }
        let layouts = exemplar.states.mapValues { $0.map { RecurrentStateSlotLayout(shape: $0.shape, dtype: $0.dtype) } }
        guard PagedKVSharedForwardBackend.recurrentCheckpointLayoutIsValid(
            layouts, recurrentLayerIndices: recurrentIndices) else { return nil }
        var layerRecords: [KVLayerRecord] = []
        for (index, cache) in layers.enumerated() {
            if let cache = cache as? KVCacheSimple {
                let state = cache.state
                guard state.count == 2, state[0].shape == state[1].shape,
                      state[0].dtype == state[1].dtype,
                      let dtype = KVCacheSerialization.codecDType(state[0].dtype) else { return nil }
                layerRecords.append(.init(
                    layerIndex: index, classID: "KVCacheSimple", layoutVersion: 2,
                    ndim: state[0].shape.count, dims: state[0].shape, dtype: dtype))
            } else if cache is MambaCache {
                guard cache.metaState == ["2", "0,1"] else { return nil }
                // `decodedLengthV2` charges the recurrent u64 captured_offset only
                // when the record carries it; without it the estimate is nil (#2015).
                layerRecords.append(.init(
                    layerIndex: index, classID: "MambaCache", layoutVersion: 2, ndim: 0, dims: [], dtype: .f16,
                    cacheOffset: cache.offset))
            } else if cache is ArraysCache {
                guard cache.metaState == ["2", "0,1"] else { return nil }
                layerRecords.append(.init(
                    layerIndex: index, classID: "ArraysCache", layoutVersion: 2, ndim: 0, dims: [], dtype: .f16,
                    cacheOffset: cache.offset))
            } else { return nil }
        }
        let recurrent = recurrentIndices.map { index in
            KVRecurrentLayerRecord(
                layerIndex: index,
                slots: (exemplar.states[index] ?? []).enumerated().compactMap { slotIndex, array in
                    guard let dtype = KVCacheSerialization.codecDType(array.dtype),
                          let bytes = try? KVPayloadCodec.expectedTensorBytes(dims: array.shape, dtype: dtype) else { return nil }
                    return KVRecurrentSlotRecord(slotIndex: slotIndex, dims: array.shape, dtype: dtype, byteCount: bytes)
                })
        }
        guard recurrent.allSatisfy({ $0.slots.count == PagedKVSharedForwardBackend.mambaCacheSlotCount }) else { return nil }
        return (layerRecords, recurrent)
    }

    static func estimatedDecodedLength(
        layers: [KVCache], checkpoints: [RecurrentStateCheckpoint], tokenCount: Int
    ) -> Int? {
        guard let geometry = geometry(layers: layers, checkpoints: checkpoints) else { return nil }
        let records = checkpoints.sorted(by: { $0.tokenCount < $1.tokenCount }).map {
            KVRecurrentCheckpointRecord(tokenCount: $0.tokenCount, layers: geometry.recurrent)
        }
        return KVDiskCacheFormat.decodedLengthV2(tokenCount: tokenCount, layers: geometry.layers, checkpoints: records)
    }

    static func snapshot(
        layers: [KVCache], checkpoints: [RecurrentStateCheckpoint]
    ) -> (layers: [KVCacheLayerPayload], checkpoints: [KVRecurrentCheckpointPayload])? {
        let recurrentIndices = layers.indices.filter { layers[$0] is ArraysCache }
        guard !recurrentIndices.isEmpty, !checkpoints.isEmpty else { return nil }
        var payloadLayers: [KVCacheLayerPayload] = []
        for (index, cache) in layers.enumerated() {
            if let cache = cache as? KVCacheSimple {
                guard let payload = KVCacheSerialization.snapshotLayers([cache])?.first else { return nil }
                payloadLayers.append(.attention(KVLayerPayload(
                    layerIndex: index, classID: payload.classID, ndim: payload.ndim, dims: payload.dims,
                    dtype: payload.dtype, cacheOffset: payload.cacheOffset,
                    keyBytes: payload.keyBytes, valueBytes: payload.valueBytes)))
            } else if cache is MambaCache {
                guard cache.metaState == ["2", "0,1"] else { return nil }
                payloadLayers.append(.recurrent(layerIndex: index, classID: "MambaCache", cacheOffset: cache.offset))
            } else if cache is ArraysCache {
                guard cache.metaState == ["2", "0,1"] else { return nil }
                payloadLayers.append(.recurrent(layerIndex: index, classID: "ArraysCache", cacheOffset: cache.offset))
            } else { return nil }
        }

        var payloadCheckpoints: [KVRecurrentCheckpointPayload] = []
        var prior = -1
        var referenceLayouts: [Int: [RecurrentStateSlotLayout]]?
        for checkpoint in checkpoints.sorted(by: { $0.tokenCount < $1.tokenCount }) {
            guard checkpoint.tokenCount > prior else { return nil }
            prior = checkpoint.tokenCount
            let layouts = checkpoint.states.mapValues { $0.map { RecurrentStateSlotLayout(shape: $0.shape, dtype: $0.dtype) } }
            guard PagedKVSharedForwardBackend.recurrentCheckpointLayoutIsValid(
                layouts, recurrentLayerIndices: recurrentIndices) else { return nil }
            if let referenceLayouts {
                guard layouts == referenceLayouts else { return nil }
            } else {
                referenceLayouts = layouts
            }
            var layerPayloads: [KVRecurrentLayerPayload] = []
            for index in recurrentIndices {
                guard let states = checkpoint.states[index] else { return nil }
                var slots: [KVRecurrentSlotPayload] = []
                for (slotIndex, state) in states.enumerated() {
                    let copied = state.asData(access: .copy)
                    guard let dtype = KVCacheSerialization.codecDType(copied.dType) else { return nil }
                    slots.append(.init(slotIndex: slotIndex, dims: copied.shape, dtype: dtype, bytes: copied.data))
                }
                layerPayloads.append(.init(layerIndex: index, slots: slots))
            }
            payloadCheckpoints.append(.init(tokenCount: checkpoint.tokenCount, layers: layerPayloads))
        }
        return (payloadLayers, payloadCheckpoints)
    }

    static func restore(_ decoded: KVDecodedPayloadV2) -> ConversationCacheLayers? {
        let recurrentIndices = decoded.layers.compactMap { layer -> Int? in
            if case .recurrent(let index, _, _) = layer { return index }
            return nil
        }
        var caches: [KVCache] = []
        for layer in decoded.layers {
            switch layer {
            case .attention(let payload):
                caches.append(KVCacheSerialization.restore([payload])[0])
            case .recurrent(_, let classID, let cacheOffset):
                guard classID == "MambaCache" || classID == "ArraysCache" else { return nil }
                let cache: ArraysCache = classID == "MambaCache" ? MambaCache() : ArraysCache(size: 2)
                cache.offset = cacheOffset
                caches.append(cache)
            }
        }
        var restored: [RecurrentStateCheckpoint] = []
        for checkpoint in decoded.checkpoints {
            var states: [Int: [MLXArray]] = [:]
            for layer in checkpoint.layers {
                states[layer.layerIndex] = layer.slots.map {
                    MLXArray($0.bytes, $0.dims, dtype: KVCacheSerialization.mlxDType($0.dtype))
                }
            }
            let layouts = states.mapValues { $0.map { RecurrentStateSlotLayout(shape: $0.shape, dtype: $0.dtype) } }
            guard PagedKVSharedForwardBackend.recurrentCheckpointLayoutIsValid(
                layouts, recurrentLayerIndices: recurrentIndices) else { return nil }
            restored.append(.init(tokenCount: checkpoint.tokenCount, states: states))
        }
        guard let terminal = restored.last else { return nil }
        for index in recurrentIndices {
            guard let state = terminal.states[index], let cache = caches[index] as? ArraysCache else { return nil }
            cache.state = state
        }
        return ConversationCacheLayers(caches, recurrentCheckpoints: restored)
    }
}
