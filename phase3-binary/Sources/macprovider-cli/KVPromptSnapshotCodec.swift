import Foundation
import MLX
import MLXLMCommon

/// codec-v3 archives a complete prompt-bound target/head pair. Tensor values are
/// copied as bytes, never converted, quantized or recomputed. Like oMLX's boundary
/// snapshot store, restoration uses the cache's state contract; unlike its current
/// MTP memory-only path, this versioned contract also carries the folded head pair.
struct KVPromptSnapshotTensor: Sendable, Equatable {
    let dims: [Int]
    let dtype: KVCodecDType
    let bytes: Data
}

struct KVPromptSnapshotLayer: Sendable, Equatable {
    let classID: String
    let parameters: [Int]
    let metadata: [String]
    let offset: Int
    let tensors: [KVPromptSnapshotTensor]
}

struct KVPromptSnapshotPayload: Sendable, Equatable {
    let tokens: [Int32]
    let layers: [KVPromptSnapshotLayer]
    let head: [KVPromptSnapshotLayer]
    let resumeBoundaryPlan: Bool
    let nextPosition: Int
    let foldedNextToken: Int32
}

enum KVPromptSnapshotCodec {
    private static let magic = Data("KVC3".utf8)
    private static let maxSlots = 16

    static func template(layers: [KVCache]) -> [KVLayerGeometry]? {
        let records = layers.enumerated().compactMap { index, cache -> KVLayerGeometry? in
            guard let identity = identity(cache) else { return nil }
            return KVLayerGeometry(layerIndex: index, classID: identity.0, layoutVersion: 3,
                                   ndim: identity.1.count, dims: identity.1, dtype: .i32, sequenceAxis: -1)
        }
        return !records.isEmpty && records.count == layers.count ? records : nil
    }

    private static func identity(_ cache: KVCache) -> (String, [Int])? {
        if let cache = cache as? GLM5NextAttentionCache {
            return ("GLM5NextAttentionCache", [cache.kpool, cache.maxTrim, cache.step])
        }
        if cache is MambaCache, cache.metaState == ["2", "0,1"] {
            return ("MambaCache", [])
        }
        // Empty model-load recurrent caches have no present slots yet.
        if cache is MambaCache, cache.state.isEmpty { return ("MambaCache", []) }
        return nil
    }

    /// Geometry-only upper bound, before any tensor materialization. The binary
    /// encoding size is exact because all strings, shapes and slots are known.
    static func estimatedLength(_ cache: ConversationCacheLayers, tokens: [Int32]) -> Int? {
        guard cache.promptSnapshot, cache.recurrentCheckpoints.isEmpty,
              template(layers: cache.layers) != nil else { return nil }
        var size = 4 + 4 + tokens.count * 4 + 4 + 4 + 1 + 8 + 4
        let all = cache.layers + (cache.nativeMTPDrafter?.cache ?? [])
        for layer in all {
            guard let (classID, params) = identity(layer), layer.state.count <= maxSlots else { return nil }
            let metadata = layer.metaState
            guard metadata.count <= maxSlots, metadata.allSatisfy({ $0.utf8.count <= KVDiskCacheFormat.maxStringBytes }) else { return nil }
            size += 2 + classID.utf8.count + 2 + params.count * 8 + 2
                + metadata.reduce(0) { $0 + 2 + $1.utf8.count } + 8 + 2
            for array in layer.state {
                guard array.ndim <= KVDiskCacheFormat.maxNdim,
                      let dtype = KVCacheSerialization.codecDType(array.dtype),
                      let bytes = try? KVPayloadCodec.expectedTensorBytes(dims: array.shape, dtype: dtype),
                      size <= Int.max - bytes - 32 - array.ndim * 8 else { return nil }
                size += 1 + array.ndim * 8 + 1 + 8 + bytes
            }
        }
        return size
    }

    static func capture(_ cache: ConversationCacheLayers, tokens: [Int32]) -> KVPromptSnapshotPayload? {
        guard estimatedLength(cache, tokens: tokens) != nil else { return nil }
        func copy(_ caches: [KVCache]) -> [KVPromptSnapshotLayer]? {
            var result: [KVPromptSnapshotLayer] = []
            for cache in caches {
                guard let (classID, params) = identity(cache) else { return nil }
                var tensors: [KVPromptSnapshotTensor] = []
                for state in cache.state {
                    let data = state.asData(access: .copy)
                    guard let dtype = KVCacheSerialization.codecDType(data.dType) else { return nil }
                    tensors.append(.init(dims: data.shape, dtype: dtype, bytes: data.data))
                }
                result.append(.init(classID: classID, parameters: params, metadata: cache.metaState,
                                    offset: cache.offset, tensors: tensors))
            }
            return result
        }
        guard let layers = copy(cache.layers), let head = copy(cache.nativeMTPDrafter?.cache ?? []),
              let folded = Int32(exactly: cache.nativeMTPDrafter?.foldedNextToken ?? 0) else { return nil }
        let result = KVPromptSnapshotPayload(tokens: tokens, layers: layers, head: head,
            resumeBoundaryPlan: cache.resumeBoundaryPlan,
            nextPosition: cache.nativeMTPDrafter?.nextPosition ?? 0,
            foldedNextToken: folded)
        return valid(result) ? result : nil
    }

    static func records(_ payload: KVPromptSnapshotPayload) -> [KVLayerRecord] {
        payload.layers.enumerated().map { index, layer in
            KVLayerRecord(layerIndex: index, classID: layer.classID, layoutVersion: 3,
                          ndim: layer.parameters.count, dims: layer.parameters, dtype: .i32)
        }
    }

    static func encodeSegments(_ payload: KVPromptSnapshotPayload) throws -> [Data] {
        guard valid(payload) else { throw KVFormatError.encodeFailed("invalid prompt snapshot") }
        var header = magic
        header.append(try KVByteWriter.u32LE(payload.tokens.count))
        for token in payload.tokens { header.append(KVByteWriter.i32LE(token)) }
        header.append(try KVByteWriter.u32LE(payload.layers.count))
        header.append(try KVByteWriter.u32LE(payload.head.count))
        header.append(Data([payload.resumeBoundaryPlan ? 1 : 0]))
        header.append(try KVByteWriter.u64LE(payload.nextPosition))
        header.append(KVByteWriter.i32LE(payload.foldedNextToken))
        var segments = [header]
        for layer in payload.layers + payload.head {
            var descriptor = try string(layer.classID)
            descriptor.append(try KVByteWriter.u16LE(layer.parameters.count))
            for parameter in layer.parameters { descriptor.append(try KVByteWriter.u64LE(parameter)) }
            descriptor.append(try KVByteWriter.u16LE(layer.metadata.count))
            for value in layer.metadata { descriptor.append(try string(value)) }
            descriptor.append(try KVByteWriter.u64LE(layer.offset))
            descriptor.append(try KVByteWriter.u16LE(layer.tensors.count))
            segments.append(descriptor)
            for tensor in layer.tensors {
                var record = Data([UInt8(tensor.dims.count)])
                for dim in tensor.dims { record.append(try KVByteWriter.u64LE(dim)) }
                record.append(Data([UInt8(tensor.dtype.rawValue)]))
                record.append(try KVByteWriter.u64LE(tensor.bytes.count))
                segments += [record, tensor.bytes]
            }
        }
        return segments
    }

    static func decode(_ data: Data, expectedLayers: [KVLayerRecord], tokenCount: Int) throws -> KVPromptSnapshotPayload {
        func corrupt() -> KVManifestParseError { .corrupt("invalid prompt snapshot archive") }
        var reader = KVByteReader(data)
        guard reader.readBytes(4) == magic, let count = reader.readU32LE(),
              count == tokenCount, count <= KVDiskCacheFormat.maxTokenCount else { throw corrupt() }
        var tokens: [Int32] = []
        for _ in 0..<count { guard let token = reader.readI32LE() else { throw corrupt() }; tokens.append(token) }
        guard let layerCount = reader.readU32LE(), layerCount == expectedLayers.count,
              let headCount = reader.readU32LE(), headCount <= 1,
              let boundary = reader.readU8(), boundary <= 1,
              let position = reader.readU64LE(), let folded = reader.readI32LE() else { throw corrupt() }
        func readString(_ reader: inout KVByteReader) -> String? {
            guard let count = reader.readU16LE(), count <= KVDiskCacheFormat.maxStringBytes,
                  let bytes = reader.readBytes(count) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
        var layers: [KVPromptSnapshotLayer] = []
        for _ in 0..<(layerCount + headCount) {
            guard let classID = readString(&reader), let parameterCount = reader.readU16LE(), parameterCount <= 8 else { throw corrupt() }
            var parameters: [Int] = []
            for _ in 0..<parameterCount { guard let value = reader.readU64LE() else { throw corrupt() }; parameters.append(value) }
            guard let metadataCount = reader.readU16LE(), metadataCount <= maxSlots else { throw corrupt() }
            var metadata: [String] = []
            for _ in 0..<metadataCount { guard let value = readString(&reader) else { throw corrupt() }; metadata.append(value) }
            guard let offset = reader.readU64LE(), let slotCount = reader.readU16LE(), slotCount <= maxSlots else { throw corrupt() }
            var tensors: [KVPromptSnapshotTensor] = []
            for _ in 0..<slotCount {
                guard let ndim = reader.readU8(), ndim <= KVDiskCacheFormat.maxNdim else { throw corrupt() }
                var dims: [Int] = []
                for _ in 0..<ndim { guard let dim = reader.readU64LE(), UInt64(dim) <= KVDiskCacheFormat.maxDim else { throw corrupt() }; dims.append(dim) }
                guard let rawType = reader.readU8(), let dtype = KVCodecDType(rawValue: rawType),
                      let size = reader.readU64LE(),
                      let expected = try? KVPayloadCodec.expectedTensorBytes(dims: dims, dtype: dtype), size == expected,
                      let bytes = reader.readBytes(size) else { throw corrupt() }
                tensors.append(.init(dims: dims, dtype: dtype, bytes: bytes))
            }
            layers.append(.init(classID: classID, parameters: parameters, metadata: metadata, offset: offset, tensors: tensors))
        }
        let payload = KVPromptSnapshotPayload(tokens: tokens, layers: Array(layers.prefix(layerCount)),
            head: Array(layers.dropFirst(layerCount)), resumeBoundaryPlan: boundary == 1,
            nextPosition: position, foldedNextToken: folded)
        guard reader.isAtEnd, valid(payload), records(payload) == expectedLayers else { throw corrupt() }
        return payload
    }

    static func restore(_ payload: KVPromptSnapshotPayload) -> ConversationCacheLayers? {
        guard valid(payload) else { return nil }
        func restoreLayers(_ layers: [KVPromptSnapshotLayer]) -> [KVCache] {
            layers.map { layer in
                let arrays = layer.tensors.map { MLXArray($0.bytes, $0.dims, dtype: KVCacheSerialization.mlxDType($0.dtype)) }
                if layer.classID == "MambaCache" {
                    let cache = MambaCache()
                    cache.state = arrays
                    cache.offset = layer.offset
                    return cache
                }
                let cache = GLM5NextAttentionCache(kpool: layer.parameters[0], maxTrim: layer.parameters[1])
                cache.step = layer.parameters[2]
                cache.state = arrays
                return cache
            }
        }
        let head = payload.head.isEmpty ? nil : NativeMTPDrafterPrefixSnapshot(
            cache: restoreLayers(payload.head), nextPosition: payload.nextPosition,
            foldedNextToken: Int(payload.foldedNextToken))
        return ConversationCacheLayers(restoreLayers(payload.layers), promptSnapshot: true,
                                       nativeMTPDrafter: head, resumeBoundaryPlan: payload.resumeBoundaryPlan)
    }

    private static func valid(_ payload: KVPromptSnapshotPayload) -> Bool {
        guard !payload.tokens.isEmpty, payload.tokens.count <= KVDiskCacheFormat.maxTokenCount,
              payload.tokens.allSatisfy({ $0 >= 0 }),
              !payload.layers.isEmpty, payload.layers.count <= KVDiskCacheFormat.maxLayers,
              payload.head.count <= 1 else { return false }
        let recurrent = payload.layers.enumerated().filter { $0.element.classID == "MambaCache" }
        if !recurrent.isEmpty {
            let layouts = Dictionary(uniqueKeysWithValues: recurrent.map { index, layer in
                (index, layer.tensors.map { RecurrentStateSlotLayout(shape: $0.dims, dtype: KVCacheSerialization.mlxDType($0.dtype)) })
            })
            guard PagedKVSharedForwardBackend.recurrentCheckpointLayoutIsValid(
                layouts, recurrentLayerIndices: recurrent.map { $0.offset }) else { return false }
        }
        for layer in payload.layers + payload.head {
            guard layer.offset >= 0, layer.offset <= payload.tokens.count,
                  layer.tensors.allSatisfy({ tensor in
                      [.f16, .bf16, .f32].contains(tensor.dtype)
                          && (try? KVPayloadCodec.expectedTensorBytes(dims: tensor.dims, dtype: tensor.dtype)) == tensor.bytes.count
                  }) else { return false }
            if layer.classID == "MambaCache" {
                guard layer.parameters.isEmpty, layer.metadata == ["2", "0,1"], layer.tensors.count == 2,
                      layer.tensors.allSatisfy({ !$0.dims.isEmpty && $0.dims.allSatisfy { $0 > 0 } }) else { return false }
            } else if layer.classID == "GLM5NextAttentionCache" {
                guard layer.parameters.count == 3, layer.parameters[0] > 0, layer.parameters[0] <= 65536,
                      layer.parameters[1] >= 0, layer.parameters[1] <= 65536,
                      layer.parameters[2] > 0, layer.parameters[2] <= 65536,
                      layer.metadata == [String(layer.parameters[0])], layer.tensors.count == 6 else { return false }
                let shapes = layer.tensors.map(\.dims)
                guard shapes[0].count == 4, shapes[0][0] == 1, shapes[0][1] == 1,
                      shapes[0][2] == layer.offset, layer.offset == payload.tokens.count,
                      shapes[0][3] > 0 else { return false }
                // Empty optional slots use the cache's canonical [0] sentinel.
                for index in 1..<6 {
                    guard shapes[index] == [0] || (shapes[index].count == 3 && shapes[index][0] == 1) else { return false }
                }
                guard shapes[2] == shapes[3], shapes[4] == shapes[5],
                      (shapes[1] == [0] || shapes[1][1] == layer.offset / layer.parameters[0]) else { return false }
            } else { return false }
        }
        if let head = payload.head.first {
            guard payload.resumeBoundaryPlan, payload.nextPosition == payload.tokens.count,
                  head.classID == "GLM5NextAttentionCache", head.offset == payload.nextPosition, payload.foldedNextToken >= 0,
                  payload.layers.contains(where: { $0.classID == head.classID && $0.parameters[0] == head.parameters[0] }) else { return false }
        } else if payload.nextPosition != 0 || payload.foldedNextToken != 0 { return false }
        return true
    }

    private static func string(_ value: String) throws -> Data {
        guard value.utf8.count <= KVDiskCacheFormat.maxStringBytes else { throw KVFormatError.encodeFailed("snapshot string exceeds bound") }
        var bytes = try KVByteWriter.u16LE(value.utf8.count)
        bytes.append(Data(value.utf8))
        return bytes
    }
}
