import Foundation
import Darwin

enum NativeMTPArtifactObservationError: Error, Equatable, CustomStringConvertible {
    case missingConfig
    case malformedConfig(String)
    case missingMTPPredictionLayerCount
    case invalidMTPPredictionLayerCount
    case missingSafetensors
    case malformedSafetensors(String)
    case unsupportedDType(String)
    case unsupportedQuantization(String)
    case missingQuantizationMetadata(String)
    case incompatibleSafetensorsHeaders(String)
    case observationDrift(String)

    var description: String {
        switch self {
        case .missingConfig:
            return "missing config.json"
        case .malformedConfig(let reason):
            return "malformed config.json: \(reason)"
        case .missingMTPPredictionLayerCount:
            return "missing mtp_num_hidden_layers"
        case .invalidMTPPredictionLayerCount:
            return "invalid mtp_num_hidden_layers"
        case .missingSafetensors:
            return "missing safetensors weights"
        case .malformedSafetensors(let reason):
            return "malformed safetensors: \(reason)"
        case .unsupportedDType(let dtype):
            return "unsupported dtype: \(dtype)"
        case .unsupportedQuantization(let reason):
            return "unsupported quantization: \(reason)"
        case .missingQuantizationMetadata(let field):
            return "missing quantization metadata: \(field)"
        case .incompatibleSafetensorsHeaders(let reason):
            return "incompatible safetensors headers: \(reason)"
        case .observationDrift(let field):
            return "artifact observation drift: \(field)"
        }
    }
}

enum NativeMTPObservedArtifactFormat: Equatable, Sendable {
    case unquantized(dtype: String)
    case mlxAffine4(bits: Int, groupSize: Int)
    case mlxMXFP8(bits: Int, groupSize: Int)

    var sidecarQuantizationLabel: String {
        switch self {
        case .unquantized(let dtype):
            return dtype
        case .mlxAffine4:
            return "mlx_affine_4bit"
        case .mlxMXFP8:
            return "mlx_mxfp8"
        }
    }
}

struct NativeMTPArtifactObservation: Equatable, Sendable {
    let format: NativeMTPObservedArtifactFormat
    let mtpPredictionLayerCount: Int
    let tensorPairs: [NativeMTPObservedTensorPair]
}

struct NativeMTPObservedTensorPair: Equatable, Sendable {
    let weightName: String
    let scaleName: String
    let packedDType: String
    let scaleDType: String
    let packedShape: [Int]
    let scaleShape: [Int]
    let groupSize: Int
    let logicalInputColumns: Int
    let paddedInputColumns: Int
}

struct NativeMTPArtifactPairObservation: Equatable, Sendable {
    let target: NativeMTPArtifactObservation
    let mtp: NativeMTPArtifactObservation
}

enum NativeMTPArtifactObserver {
    static let maxConfigBytes = 256 * 1024
    static let maxSafetensorsHeaderBytes = 16 * 1024 * 1024
    static let maxCumulativeSafetensorsHeaderBytes = 64 * 1024 * 1024
    static let maxSafetensorsFiles = 256
    static let maxSafetensorsTensors = 200_000
    static let maxSafetensorsTensorNameUTF8Bytes = 4 * 1024
    static let maxSafetensorsTensorRank = 8
    static let maxSafetensorsTensorDimension = 1 << 30

    static func observe(directory: URL, fileManager: FileManager = .default) throws -> NativeMTPArtifactObservation {
        try observe(directory: directory, fileManager: fileManager, tensorNamePolicy: .permissive)
    }

    private static func observe(
        directory: URL,
        fileManager: FileManager = .default,
        tensorNamePolicy: TensorNamePolicy
    ) throws -> NativeMTPArtifactObservation {
        let config = try loadConfig(directory: directory)
        let layerCount = try mtpPredictionLayerCount(in: config)
        let headers = try loadSafetensorsHeaders(directory: directory, fileManager: fileManager)
        try validateTensorNames(headers, policy: tensorNamePolicy)
        let format = try observeFormat(config: config, headers: headers)
        return NativeMTPArtifactObservation(
            format: format.format,
            mtpPredictionLayerCount: layerCount,
            tensorPairs: format.tensorPairs
        )
    }

    static func observePair(
        targetDirectory: URL,
        mtpDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> NativeMTPArtifactPairObservation {
        let target = try observe(directory: targetDirectory, fileManager: fileManager, tensorNamePolicy: .target)
        let mtp = try observe(directory: mtpDirectory, fileManager: fileManager, tensorNamePolicy: .mtp)
        guard target.format == mtp.format else {
            throw NativeMTPArtifactObservationError.observationDrift("format")
        }
        guard target.mtpPredictionLayerCount == mtp.mtpPredictionLayerCount else {
            throw NativeMTPArtifactObservationError.observationDrift("mtp_num_hidden_layers")
        }
        return NativeMTPArtifactPairObservation(target: target, mtp: mtp)
    }

    private static func observeFormat(
        config: [String: Any],
        headers: [SafetensorsHeader]
    ) throws -> (format: NativeMTPObservedArtifactFormat, tensorPairs: [NativeMTPObservedTensorPair]) {
        if let quantization = quantizationMetadata(in: config) {
            return try observeQuantizedFormat(
                quantization: quantization,
                representation: representationManifest(in: config),
                headers: headers
            )
        }
        let dtype = try explicitUnquantizedDType(in: config)
        try validateUnquantizedHeaders(dtype: dtype, headers: headers)
        return (.unquantized(dtype: dtype), [])
    }

    private static func explicitUnquantizedDType(in config: [String: Any]) throws -> String {
        let raw = stringValue(config["torch_dtype"])
            ?? stringValue(config["dtype"])
            ?? stringValue(config["model_dtype"])
        guard let raw else {
            throw NativeMTPArtifactObservationError.unsupportedDType("missing")
        }
        switch canonicalDType(raw) {
        case "bf16":
            return "bf16"
        case "fp16":
            return "fp16"
        default:
            throw NativeMTPArtifactObservationError.unsupportedDType(raw)
        }
    }

    private static func observeQuantizedFormat(
        quantization: [String: Any],
        representation: RepresentationManifest,
        headers: [SafetensorsHeader]
    ) throws -> (format: NativeMTPObservedArtifactFormat, tensorPairs: [NativeMTPObservedTensorPair]) {
        guard let mode = quantizationMode(quantization) else {
            throw NativeMTPArtifactObservationError.missingQuantizationMetadata("mode")
        }
        guard let bits = intValue(quantization["bits"]) else {
            throw NativeMTPArtifactObservationError.missingQuantizationMetadata("bits")
        }
        guard let groupSize = intValue(quantization["group_size"]) ?? intValue(quantization["groupSize"]) else {
            throw NativeMTPArtifactObservationError.missingQuantizationMetadata("group_size")
        }

        switch mode {
        case "mlx_affine_4bit":
            guard bits == 4 else {
                throw NativeMTPArtifactObservationError.unsupportedQuantization("mlx affine requires bits=4")
            }
            guard [32, 64, 128].contains(groupSize) else {
                throw NativeMTPArtifactObservationError.unsupportedQuantization("mlx affine unsupported group_size")
            }
            let pairs = try validatePackedHeaders(
                headers,
                quantizationName: "mlx_affine_4bit",
                groupSize: groupSize,
                bitsPerValue: bits,
                requiredPackedDType: "U32",
                valuesPerPackedElement: 8,
                requiresBias: true,
                representation: representation
            )
            return (.mlxAffine4(bits: bits, groupSize: groupSize), pairs)

        case "mlx_mxfp8":
            guard bits == 8, groupSize == 32 else {
                throw NativeMTPArtifactObservationError.unsupportedQuantization("mxfp8 requires bits=8 group_size=32")
            }
            throw NativeMTPArtifactObservationError.unsupportedQuantization("mlx_mxfp8 scale dtype unverified")

        case "fp8", "float8", "int8", "uint8":
            throw NativeMTPArtifactObservationError.unsupportedQuantization(mode)

        default:
            throw NativeMTPArtifactObservationError.unsupportedQuantization(mode)
        }
    }

    private static func validateUnquantizedHeaders(dtype: String, headers: [SafetensorsHeader]) throws {
        let expected: Set<String> = dtype == "bf16" ? ["BF16"] : ["F16"]
        let observed = selectedWeightTensors(headers)
        guard !observed.isEmpty else {
            throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("no selected tensors")
        }
        for tensor in observed where !expected.contains(tensor.dtype) {
            throw NativeMTPArtifactObservationError.unsupportedDType(tensor.dtype)
        }
    }

    private static func validatePackedHeaders(
        _ headers: [SafetensorsHeader],
        quantizationName: String,
        groupSize: Int,
        bitsPerValue: Int,
        requiredPackedDType: String,
        valuesPerPackedElement: Int,
        requiresBias: Bool,
        representation: RepresentationManifest
    ) throws -> [NativeMTPObservedTensorPair] {
        let requiredPackedBits = bytesPerElement(requiredPackedDType) * 8
        guard bitsPerValue > 0,
              requiredPackedBits > 0,
              requiredPackedBits % bitsPerValue == 0,
              requiredPackedBits / bitsPerValue == valuesPerPackedElement else {
            throw NativeMTPArtifactObservationError.unsupportedQuantization("\(quantizationName) invalid packing density")
        }
        let tensors = selectedWeightTensors(headers)
        guard !tensors.isEmpty else {
            throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("no selected tensors")
        }
        var scaleTensors: [String: SafetensorsTensor] = [:]
        for tensor in tensors where isScaleTensorName(tensor.name) {
            guard scaleTensors[tensor.name] == nil else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("duplicate scale tensor \(tensor.name)")
            }
            scaleTensors[tensor.name] = tensor
        }
        guard scaleTensors.values.allSatisfy({ ["F16", "BF16", "F32"].contains($0.dtype) }) else {
            throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("\(quantizationName) scales must be floating point")
        }
        var biasTensors: [String: SafetensorsTensor] = [:]
        for tensor in tensors where isBiasTensorName(tensor.name) {
            guard biasTensors[tensor.name] == nil else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("duplicate bias tensor \(tensor.name)")
            }
            biasTensors[tensor.name] = tensor
        }
        guard biasTensors.values.allSatisfy({ ["F16", "BF16", "F32"].contains($0.dtype) }) else {
            throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("\(quantizationName) biases must be floating point")
        }
        let packed = tensors.filter { !isScaleTensorName($0.name) && !isBiasTensorName($0.name) }
        guard !packed.isEmpty else {
            throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("\(quantizationName) requires packed tensors")
        }
        var pairs: [NativeMTPObservedTensorPair] = []
        var pairedBiases: Set<String> = []
        for tensor in packed.sorted(by: { $0.name < $1.name }) {
            if isFloatingWeightDType(tensor.dtype),
               representation.allowsUnquantizedTensor(tensor.name) {
                guard let expectedByteCount = checkedMultiply(tensor.elementCount, bytesPerElement(tensor.dtype)),
                      tensor.byteCount == expectedByteCount else {
                    throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("unquantized tensor \(tensor.name) byte span")
                }
                continue
            }
            if tensor.dtype.hasPrefix("F8") {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("raw FP8 tensors are not packed \(quantizationName)")
            }
            guard tensor.dtype == requiredPackedDType else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("packed tensor \(tensor.name) dtype \(tensor.dtype)")
            }
            guard tensor.shape.count >= 2, tensor.shape.allSatisfy({ $0 > 0 }) else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("packed tensor \(tensor.name) shape")
            }
            guard let expectedPackedByteCount = checkedMultiply(tensor.elementCount, bytesPerElement(tensor.dtype)),
                  tensor.byteCount == expectedPackedByteCount else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("packed tensor \(tensor.name) byte span")
            }
            guard let scaleName = expectedScaleName(for: tensor.name, available: scaleTensors) else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("missing scale pair for \(tensor.name)")
            }
            let scale = scaleTensors[scaleName]!
            guard scale.shape.count == tensor.shape.count,
                  Array(scale.shape.dropLast()) == Array(tensor.shape.dropLast()) else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("scale shape prefix for \(tensor.name)")
            }
            guard let expectedScaleByteCount = checkedMultiply(scale.elementCount, bytesPerElement(scale.dtype)),
                  scale.byteCount == expectedScaleByteCount else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("scale tensor \(scale.name) byte span")
            }
            if requiresBias {
                guard let biasName = expectedBiasName(for: tensor.name, available: biasTensors) else {
                    throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("missing bias pair for \(tensor.name)")
                }
                let bias = biasTensors[biasName]!
                guard bias.shape == scale.shape else {
                    throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("bias shape for \(tensor.name)")
                }
                guard bias.dtype == scale.dtype else {
                    throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("bias dtype for \(tensor.name)")
                }
                guard let expectedBiasByteCount = checkedMultiply(bias.elementCount, bytesPerElement(bias.dtype)),
                      bias.byteCount == expectedBiasByteCount else {
                    throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("bias tensor \(bias.name) byte span")
                }
                pairedBiases.insert(biasName)
            }
            guard let logicalInputColumns = checkedMultiply(
                tensor.shape[tensor.shape.count - 1],
                valuesPerPackedElement
            ) else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("logical columns overflow for \(tensor.name)")
            }
            let paddedInputColumns = try checkedRoundUp(logicalInputColumns, toMultipleOf: groupSize, tensorName: tensor.name)
            if paddedInputColumns != logicalInputColumns,
               !representation.paddingExceptions.contains(tensor.name) {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("undeclared padding for \(tensor.name)")
            }
            let expectedScaleColumns = max(1, paddedInputColumns / groupSize)
            guard scale.shape[scale.shape.count - 1] == expectedScaleColumns else {
                throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("scale block count for \(tensor.name)")
            }
            pairs.append(NativeMTPObservedTensorPair(
                weightName: tensor.name,
                scaleName: scale.name,
                packedDType: tensor.dtype,
                scaleDType: scale.dtype,
                packedShape: tensor.shape,
                scaleShape: scale.shape,
                groupSize: groupSize,
                logicalInputColumns: logicalInputColumns,
                paddedInputColumns: paddedInputColumns
            ))
        }
        let pairedScales = Set(pairs.map(\.scaleName))
        let unpairedScales = Set(scaleTensors.keys).subtracting(pairedScales)
        guard unpairedScales.isEmpty || unpairedScales.isSubset(of: representation.unpairedScaleExceptions) else {
            throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("unpaired scale tensors")
        }
        let unpairedBiases = Set(biasTensors.keys).subtracting(pairedBiases)
        guard unpairedBiases.isEmpty else {
            throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("unpaired bias tensors")
        }
        return pairs
    }

    private static func mtpPredictionLayerCount(in config: [String: Any]) throws -> Int {
        let root = intValue(config["mtp_num_hidden_layers"])
        let textConfig = (config["text_config"] as? [String: Any])
            .flatMap { intValue($0["mtp_num_hidden_layers"]) }
        guard let count = root ?? textConfig else {
            throw NativeMTPArtifactObservationError.missingMTPPredictionLayerCount
        }
        guard (1...64).contains(count) else {
            throw NativeMTPArtifactObservationError.invalidMTPPredictionLayerCount
        }
        return count
    }

    private static func quantizationMetadata(in config: [String: Any]) -> [String: Any]? {
        for key in ["quantization", "quantization_config", "quantizationConfig"] {
            if let object = config[key] as? [String: Any] {
                return object
            }
        }
        return nil
    }

    private static func representationManifest(in config: [String: Any]) -> RepresentationManifest {
        var unquantizedLayerExceptions: Set<String> = []
        if let quantization = quantizationMetadata(in: config) {
            for (key, value) in quantization {
                guard key.contains(".") else { continue }
                if let bool = value as? Bool, bool == false {
                    unquantizedLayerExceptions.insert(key)
                }
            }
        }
        guard let object = config["native_mtp_representation"] as? [String: Any] else {
            return RepresentationManifest(
                paddingExceptions: [],
                unpairedScaleExceptions: [],
                unquantizedLayerExceptions: unquantizedLayerExceptions
            )
        }
        return RepresentationManifest(
            paddingExceptions: stringArray(object["padding_exceptions"]),
            unpairedScaleExceptions: stringArray(object["unpaired_scale_exceptions"]),
            unquantizedLayerExceptions: unquantizedLayerExceptions.union(stringArray(object["unquantized_layer_exceptions"]))
        )
    }

    private static func quantizationMode(_ object: [String: Any]) -> String? {
        let raw = stringValue(object["mode"])
            ?? stringValue(object["quantization_mode"])
            ?? stringValue(object["quant_method"])
            ?? stringValue(object["quantization"])
        guard let raw else { return nil }
        let lower = raw.lowercased(with: nil)
        switch lower {
        case "mlx_affine_4bit", "mlx-affine-4bit", "mlx_affine4", "affine4":
            return "mlx_affine_4bit"
        case "mxfp8", "mlx_mxfp8", "mlx-mxfp8":
            return "mlx_mxfp8"
        case "fp8", "float8", "int8", "uint8":
            return lower
        default:
            return lower
        }
    }

    private static func selectedWeightTensors(_ headers: [SafetensorsHeader]) -> [SafetensorsTensor] {
        headers.flatMap(\.tensors).filter { tensor in
            let name = tensor.name.lowercased(with: nil)
            return !name.hasPrefix("__")
                && !name.contains("optimizer")
                && !name.contains("adam")
                && !name.contains("moment")
        }
    }

    private enum TensorNamePolicy: Equatable {
        case permissive
        case target
        case mtp
    }

    private static func validateTensorNames(_ headers: [SafetensorsHeader], policy: TensorNamePolicy) throws {
        guard policy != .permissive else { return }
        let tensors = headers.flatMap(\.tensors)
        for tensor in tensors {
            let lower = tensor.name.lowercased(with: nil)
            switch policy {
            case .permissive:
                continue
            case .target:
                if lower.contains("mtp.") {
                    throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("target tensor namespace \(tensor.name)")
                }
            case .mtp:
                let allowed = lower.hasPrefix("model.") || lower.hasPrefix("lm_head.")
                if !allowed || lower.hasPrefix("target.") || lower.hasPrefix("extra.") || lower.hasPrefix("extras.") {
                    throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("mtp tensor namespace \(tensor.name)")
                }
            }
        }
    }

    private static func isScaleTensorName(_ name: String) -> Bool {
        let lower = name.lowercased(with: nil)
        return lower.hasSuffix(".scales")
            || lower.hasSuffix(".scale")
            || lower.hasSuffix(".weight_scale")
    }

    private static func isBiasTensorName(_ name: String) -> Bool {
        name.lowercased(with: nil).hasSuffix(".biases")
    }

    private static func isFloatingWeightDType(_ dtype: String) -> Bool {
        ["F16", "BF16", "F32"].contains(dtype)
    }

    private static func expectedScaleName(
        for weightName: String,
        available: [String: SafetensorsTensor]
    ) -> String? {
        let candidates: [String]
        if weightName.hasSuffix(".weight") {
            let base = String(weightName.dropLast(".weight".count))
            candidates = [
                "\(base).scales",
                "\(base).scale",
                "\(base).weight_scale",
            ]
        } else {
            candidates = [
                "\(weightName).scales",
                "\(weightName).scale",
                "\(weightName).weight_scale",
            ]
        }
        return candidates.first { available[$0] != nil }
    }

    private static func expectedBiasName(
        for weightName: String,
        available: [String: SafetensorsTensor]
    ) -> String? {
        let candidate: String
        if weightName.hasSuffix(".weight") {
            let base = String(weightName.dropLast(".weight".count))
            candidate = "\(base).biases"
        } else {
            candidate = "\(weightName).biases"
        }
        return available[candidate] == nil ? nil : candidate
    }

    private static func loadConfig(directory: URL) throws -> [String: Any] {
        let url = directory.appendingPathComponent("config.json")
        guard fileExistsNoFollow(url) else {
            throw NativeMTPArtifactObservationError.missingConfig
        }
        let data = try boundedRegularFileRead(
            url,
            maxBytes: maxConfigBytes,
            error: { NativeMTPArtifactObservationError.malformedConfig($0) }
        )
        do {
            guard let text = String(data: data, encoding: .utf8) else {
                throw NativeMTPArtifactObservationError.malformedConfig("config.json: utf8")
            }
            guard let object = try DuplicateRejectingJSONParser.parseObject(text) else {
                throw NativeMTPArtifactObservationError.malformedConfig("root must be object")
            }
            return object
        } catch let error as NativeMTPArtifactObservationError {
            throw error
        } catch {
            throw NativeMTPArtifactObservationError.malformedConfig(String(describing: error))
        }
    }

    private static func loadSafetensorsHeaders(directory: URL, fileManager: FileManager) throws -> [SafetensorsHeader] {
        let urls = try safetensorsURLs(directory: directory, fileManager: fileManager)
        guard !urls.isEmpty else {
            throw NativeMTPArtifactObservationError.missingSafetensors
        }
        var cumulativeHeaderBytes = 0
        var cumulativeTensorCount = 0
        var headers: [SafetensorsHeader] = []
        var seenTensorNames: Set<String> = []
        for url in urls {
            let header = try readSafetensorsHeader(url)
            guard let nextHeaderBytes = checkedAdd(cumulativeHeaderBytes, header.headerByteCount),
                  nextHeaderBytes <= maxCumulativeSafetensorsHeaderBytes else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("cumulative header bytes")
            }
            guard let nextTensorCount = checkedAdd(cumulativeTensorCount, header.tensors.count),
                  nextTensorCount <= maxSafetensorsTensors else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("too many tensors")
            }
            for tensor in header.tensors {
                guard seenTensorNames.insert(tensor.name).inserted else {
                    throw NativeMTPArtifactObservationError.malformedSafetensors("duplicate tensor \(tensor.name)")
                }
            }
            cumulativeHeaderBytes = nextHeaderBytes
            cumulativeTensorCount = nextTensorCount
            headers.append(header)
        }
        return headers
    }

    private static func safetensorsURLs(directory: URL, fileManager: FileManager) throws -> [URL] {
        let root = directory.standardizedFileURL
        let safetensors = try recursiveSafetensorsURLs(
            directory: root,
            root: root,
            fileManager: fileManager
        )
        guard safetensors.count <= maxSafetensorsFiles else {
            throw NativeMTPArtifactObservationError.malformedSafetensors("too many safetensors files")
        }
        return safetensors
    }

    private static func recursiveSafetensorsURLs(
        directory: URL,
        root: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        let rootPath = root.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/") else {
            throw NativeMTPArtifactObservationError.malformedSafetensors("containment")
        }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
        var urls: [URL] = []
        for name in names {
            guard !name.isEmpty,
                  name != ".",
                  name != ".." else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("invalid path")
            }
            let url = directory.appendingPathComponent(name, isDirectory: false).standardizedFileURL
            let path = url.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("containment")
            }
            var statBuffer = stat()
            guard Darwin.lstat(path, &statBuffer) == 0 else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("unreadable path")
            }
            let mode = statBuffer.st_mode & S_IFMT
            if mode == S_IFLNK {
                throw NativeMTPArtifactObservationError.malformedSafetensors("symlink path")
            }
            if mode == S_IFDIR {
                urls.append(contentsOf: try recursiveSafetensorsURLs(
                    directory: url,
                    root: root,
                    fileManager: fileManager
                ))
            } else if mode == S_IFREG, url.pathExtension == "safetensors" {
                guard !name.hasPrefix(".") else {
                    throw NativeMTPArtifactObservationError.malformedSafetensors("hidden safetensors")
                }
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func readSafetensorsHeader(_ url: URL) throws -> SafetensorsHeader {
        let file = try openRegularFileNoFollow(
            url,
            error: { NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): \($0)") }
        )
        defer { Darwin.close(file.descriptor) }
        guard file.size >= 8 else {
            throw NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): missing header length")
        }
        let prefix = try readExactly(
            descriptor: file.descriptor,
            count: 8,
            error: { NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): \($0)") }
        )
        let headerLength = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard headerLength > 0,
              headerLength <= UInt64(maxSafetensorsHeaderBytes),
              headerLength <= UInt64(Int.max) else {
            throw NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): header length \(headerLength)")
        }
        let headerByteCount = Int(headerLength)
        guard let dataStart = checkedAdd(8, headerByteCount), dataStart <= file.size else {
            throw NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): truncated header")
        }
        let payloadByteCount = file.size - dataStart
        let headerData = try readExactly(
            descriptor: file.descriptor,
            count: headerByteCount,
            error: { NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): \($0)") }
        )
        do {
            guard let text = String(data: headerData, encoding: .utf8) else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): utf8")
            }
            guard let object = try DuplicateRejectingJSONParser.parseObject(text) else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): header root")
            }
            var tensors: [SafetensorsTensor] = []
            for (name, value) in object {
                guard name != "__metadata__" else { continue }
                guard let tensor = value as? [String: Any],
                      let rawDType = stringValue(tensor["dtype"]),
                      let rawShape = tensor["shape"] as? [Any],
                      let rawOffsets = tensor["data_offsets"] as? [Any] else {
                    throw NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): tensor \(name)")
                }
                guard name.utf8.count <= maxSafetensorsTensorNameUTF8Bytes else {
                    throw NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): tensor name too long")
                }
                let shape = try parseSafetensorsShape(rawShape, fileName: url.lastPathComponent, tensorName: name)
                let offsets = try parseSafetensorsOffsets(rawOffsets, fileName: url.lastPathComponent, tensorName: name)
                let span = try validateDataOffsets(
                    offsets,
                    payloadByteCount: payloadByteCount,
                    fileName: url.lastPathComponent,
                    tensorName: name
                )
                let elementCount = try checkedElementCount(shape, fileName: url.lastPathComponent, tensorName: name)
                tensors.append(SafetensorsTensor(
                    name: name,
                    dtype: safetensorsDType(rawDType),
                    shape: shape,
                    dataOffsets: offsets,
                    elementCount: elementCount,
                    byteCount: span
                ))
            }
            try validateNonOverlappingOffsets(tensors, fileName: url.lastPathComponent)
            return SafetensorsHeader(fileName: url.lastPathComponent, headerByteCount: headerByteCount, tensors: tensors)
        } catch let error as NativeMTPArtifactObservationError {
            throw error
        } catch {
            throw NativeMTPArtifactObservationError.malformedSafetensors("\(url.lastPathComponent): \(error)")
        }
    }

    private static func safetensorsDType(_ value: String) -> String {
        value.uppercased(with: nil)
            .replacingOccurrences(of: "UINT", with: "U")
            .replacingOccurrences(of: "INT", with: "I")
            .replacingOccurrences(of: "FLOAT", with: "F")
    }

    private static func canonicalDType(_ value: String) -> String {
        switch value.lowercased(with: nil) {
        case "bfloat16", "bf16":
            return "bf16"
        case "float16", "fp16", "f16":
            return "fp16"
        default:
            return value.lowercased(with: nil)
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringArray(_ value: Any?) -> Set<String> {
        guard let array = value as? [String] else { return [] }
        return Set(array.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        default:
            return nil
        }
    }

    private struct SafetensorsHeader {
        let fileName: String
        let headerByteCount: Int
        let tensors: [SafetensorsTensor]
    }

    private struct SafetensorsTensor {
        let name: String
        let dtype: String
        let shape: [Int]
        let dataOffsets: [Int]

        let elementCount: Int
        let byteCount: Int
    }

    private struct RepresentationManifest {
        let paddingExceptions: Set<String>
        let unpairedScaleExceptions: Set<String>
        let unquantizedLayerExceptions: Set<String>

        func allowsUnquantizedTensor(_ name: String) -> Bool {
            unquantizedLayerExceptions.contains(where: { exception in
                name == exception || name.hasPrefix(exception + ".")
            })
        }
    }

    private static func bytesPerElement(_ dtype: String) -> Int {
        switch dtype {
        case "U8", "I8":
            return 1
        case "F16", "BF16", "U16", "I16":
            return 2
        case "F32", "U32", "I32":
            return 4
        default:
            return 0
        }
    }

    private struct OpenedRegularFile {
        let descriptor: Int32
        let size: Int
    }

    private static func fileExistsNoFollow(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var statBuffer = stat()
        guard Darwin.fstat(descriptor, &statBuffer) == 0 else { return false }
        return (statBuffer.st_mode & S_IFMT) == S_IFREG
    }

    private static func boundedRegularFileRead<E: Error>(
        _ url: URL,
        maxBytes: Int,
        error: (String) -> E
    ) throws -> Data {
        let file = try openRegularFileNoFollow(url, error: error)
        defer { Darwin.close(file.descriptor) }
        guard file.size <= maxBytes else {
            throw error("\(url.lastPathComponent): file too large")
        }
        return try readExactly(descriptor: file.descriptor, count: file.size, error: error)
    }

    private static func openRegularFileNoFollow<E: Error>(
        _ url: URL,
        error: (String) -> E
    ) throws -> OpenedRegularFile {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw error("unreadable")
        }
        var statBuffer = stat()
        guard Darwin.fstat(descriptor, &statBuffer) == 0 else {
            Darwin.close(descriptor)
            throw error("stat failed")
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw error("not regular file")
        }
        guard statBuffer.st_size >= 0, statBuffer.st_size <= off_t(Int.max) else {
            Darwin.close(descriptor)
            throw error("file size")
        }
        return OpenedRegularFile(descriptor: descriptor, size: Int(statBuffer.st_size))
    }

    private static func readExactly<E: Error>(
        descriptor: Int32,
        count: Int,
        error: (String) -> E
    ) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
            }
            guard readCount > 0 else {
                throw error(readCount == 0 ? "truncated" : "read failed")
            }
            offset += readCount
        }
        return data
    }

    private static func parseSafetensorsShape(
        _ rawShape: [Any],
        fileName: String,
        tensorName: String
    ) throws -> [Int] {
        guard !rawShape.isEmpty, rawShape.count <= maxSafetensorsTensorRank else {
            throw NativeMTPArtifactObservationError.malformedSafetensors("\(fileName): tensor \(tensorName) rank")
        }
        var shape: [Int] = []
        for value in rawShape {
            guard let dimension = intValue(value),
                  dimension > 0,
                  dimension <= maxSafetensorsTensorDimension else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("\(fileName): tensor \(tensorName) dimension")
            }
            shape.append(dimension)
        }
        return shape
    }

    private static func parseSafetensorsOffsets(
        _ rawOffsets: [Any],
        fileName: String,
        tensorName: String
    ) throws -> [Int] {
        guard rawOffsets.count == 2,
              let start = intValue(rawOffsets[0]),
              let end = intValue(rawOffsets[1]) else {
            throw NativeMTPArtifactObservationError.malformedSafetensors("\(fileName): tensor \(tensorName) offsets")
        }
        return [start, end]
    }

    private static func validateDataOffsets(
        _ offsets: [Int],
        payloadByteCount: Int,
        fileName: String,
        tensorName: String
    ) throws -> Int {
        let start = offsets[0]
        let end = offsets[1]
        guard start >= 0, end >= start, end <= payloadByteCount else {
            throw NativeMTPArtifactObservationError.malformedSafetensors("\(fileName): tensor \(tensorName) offsets out of range")
        }
        guard let span = checkedSubtract(end, start) else {
            throw NativeMTPArtifactObservationError.malformedSafetensors("\(fileName): tensor \(tensorName) span overflow")
        }
        return span
    }

    private static func validateNonOverlappingOffsets(_ tensors: [SafetensorsTensor], fileName: String) throws {
        let sorted = tensors.sorted {
            if $0.dataOffsets[0] == $1.dataOffsets[0] {
                return $0.dataOffsets[1] < $1.dataOffsets[1]
            }
            return $0.dataOffsets[0] < $1.dataOffsets[0]
        }
        var previousEnd = 0
        for tensor in sorted {
            guard tensor.dataOffsets[0] >= previousEnd else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("\(fileName): overlapping tensor offsets")
            }
            previousEnd = tensor.dataOffsets[1]
        }
    }

    private static func checkedElementCount(
        _ shape: [Int],
        fileName: String,
        tensorName: String
    ) throws -> Int {
        var product = 1
        for dimension in shape {
            guard let next = checkedMultiply(product, dimension) else {
                throw NativeMTPArtifactObservationError.malformedSafetensors("\(fileName): tensor \(tensorName) element count overflow")
            }
            product = next
        }
        return product
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private static func checkedSubtract(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : value
    }

    private static func checkedRoundUp(
        _ value: Int,
        toMultipleOf multiple: Int,
        tensorName: String
    ) throws -> Int {
        guard multiple > 0 else { return value }
        let remainder = value % multiple
        guard remainder != 0 else { return value }
        guard let delta = checkedSubtract(multiple, remainder),
              let rounded = checkedAdd(value, delta) else {
            throw NativeMTPArtifactObservationError.incompatibleSafetensorsHeaders("padded columns overflow for \(tensorName)")
        }
        return rounded
    }

    private enum DuplicateRejectingJSONParser {
        static func parseObject(_ text: String) throws -> [String: Any]? {
            var parser = Parser(scalars: Array(text.unicodeScalars))
            let value = try parser.parseValue(depth: 1)
            parser.skipWhitespace()
            guard parser.isAtEnd else {
                throw ParseError.trailingData
            }
            return value as? [String: Any]
        }

        enum ParseError: Error, Equatable {
            case unexpectedEnd
            case unexpectedCharacter
            case invalidString
            case invalidNumber
            case duplicateKey(String)
            case trailingData
            case tooDeep
            case tooLarge
        }

        private struct Parser {
            var scalars: [UnicodeScalar]
            var index = 0
            var parsedNodes = 0
            let maxDepth = 64
            let maxNodes = 250_000

            var isAtEnd: Bool { index >= scalars.count }

            mutating func parseValue(depth: Int) throws -> Any {
                guard depth <= maxDepth else { throw ParseError.tooDeep }
                parsedNodes += 1
                guard parsedNodes <= maxNodes else { throw ParseError.tooLarge }
                skipWhitespace()
                guard !isAtEnd else { throw ParseError.unexpectedEnd }
                switch scalars[index] {
                case "{":
                    return try parseObject(depth: depth)
                case "[":
                    return try parseArray(depth: depth)
                case "\"":
                    return try parseString()
                case "t":
                    try consumeLiteral("true")
                    return true
                case "f":
                    try consumeLiteral("false")
                    return false
                case "n":
                    try consumeLiteral("null")
                    return NSNull()
                default:
                    return try parseNumber()
                }
            }

            mutating func parseObject(depth: Int) throws -> [String: Any] {
                try consume("{")
                skipWhitespace()
                var object: [String: Any] = [:]
                guard !consumeIf("}") else { return object }
                while true {
                    skipWhitespace()
                    guard peek() == "\"" else { throw ParseError.unexpectedCharacter }
                    let key = try parseString()
                    guard object[key] == nil else { throw ParseError.duplicateKey(key) }
                    skipWhitespace()
                    try consume(":")
                    object[key] = try parseValue(depth: depth + 1)
                    skipWhitespace()
                    if consumeIf("}") {
                        return object
                    }
                    try consume(",")
                }
            }

            mutating func parseArray(depth: Int) throws -> [Any] {
                try consume("[")
                skipWhitespace()
                var array: [Any] = []
                guard !consumeIf("]") else { return array }
                while true {
                    array.append(try parseValue(depth: depth + 1))
                    skipWhitespace()
                    if consumeIf("]") {
                        return array
                    }
                    try consume(",")
                }
            }

            mutating func parseString() throws -> String {
                try consume("\"")
                var result = String.UnicodeScalarView()
                while !isAtEnd {
                    let scalar = scalars[index]
                    index += 1
                    if scalar == "\"" {
                        return String(result)
                    }
                    if scalar == "\\" {
                        guard !isAtEnd else { throw ParseError.invalidString }
                        let escaped = scalars[index]
                        index += 1
                        switch escaped {
                        case "\"", "\\", "/":
                            result.append(escaped)
                        case "b":
                            result.append(UnicodeScalar(0x08)!)
                        case "f":
                            result.append(UnicodeScalar(0x0c)!)
                        case "n":
                            result.append("\n")
                        case "r":
                            result.append("\r")
                        case "t":
                            result.append("\t")
                        case "u":
                            let first = try parseHexQuad()
                            if (0xd800 ... 0xdbff).contains(first) {
                                guard try consumeUnicodeEscapePrefixIfPresent() else { throw ParseError.invalidString }
                                let second = try parseHexQuad()
                                guard (0xdc00 ... 0xdfff).contains(second) else { throw ParseError.invalidString }
                                let combined = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
                                guard let unicode = UnicodeScalar(combined) else { throw ParseError.invalidString }
                                result.append(unicode)
                            } else {
                                guard !(0xdc00 ... 0xdfff).contains(first),
                                      let unicode = UnicodeScalar(first) else {
                                    throw ParseError.invalidString
                                }
                                result.append(unicode)
                            }
                        default:
                            throw ParseError.invalidString
                        }
                        continue
                    }
                    guard scalar.value >= 0x20 else { throw ParseError.invalidString }
                    result.append(scalar)
                }
                throw ParseError.unexpectedEnd
            }

            mutating func parseNumber() throws -> Any {
                let start = index
                _ = consumeIf("-")
                if consumeIf("0") {
                    if let scalar = peek(), scalar.value >= 48, scalar.value <= 57 {
                        throw ParseError.invalidNumber
                    }
                } else {
                    try consumeDigit1to9()
                    while consumeDigit() {}
                }
                var isDouble = false
                if consumeIf(".") {
                    isDouble = true
                    guard consumeDigit() else { throw ParseError.invalidNumber }
                    while consumeDigit() {}
                }
                if consumeIf("e") || consumeIf("E") {
                    isDouble = true
                    _ = consumeIf("+") || consumeIf("-")
                    guard consumeDigit() else { throw ParseError.invalidNumber }
                    while consumeDigit() {}
                }
                let literal = String(String.UnicodeScalarView(scalars[start..<index]))
                if isDouble {
                    guard let double = Double(literal), double.isFinite else { throw ParseError.invalidNumber }
                    return double
                }
                guard let int = Int(literal) else {
                    throw ParseError.invalidNumber
                }
                return int
            }

            mutating func parseHexQuad() throws -> UInt32 {
                guard index + 4 <= scalars.count else { throw ParseError.invalidString }
                var value: UInt32 = 0
                for _ in 0..<4 {
                    let scalar = scalars[index]
                    index += 1
                    value <<= 4
                    switch scalar.value {
                    case 48 ... 57:
                        value += scalar.value - 48
                    case 65 ... 70:
                        value += scalar.value - 55
                    case 97 ... 102:
                        value += scalar.value - 87
                    default:
                        throw ParseError.invalidString
                    }
                }
                return value
            }

            mutating func consumeUnicodeEscapePrefixIfPresent() throws -> Bool {
                guard index + 2 <= scalars.count else { return false }
                guard scalars[index] == "\\", scalars[index + 1] == "u" else { return false }
                index += 2
                return true
            }

            mutating func consumeLiteral(_ literal: String) throws {
                for scalar in literal.unicodeScalars {
                    try consume(scalar)
                }
            }

            mutating func consume(_ expected: UnicodeScalar) throws {
                guard !isAtEnd, scalars[index] == expected else {
                    throw isAtEnd ? ParseError.unexpectedEnd : ParseError.unexpectedCharacter
                }
                index += 1
            }

            mutating func consumeIf(_ expected: UnicodeScalar) -> Bool {
                guard !isAtEnd, scalars[index] == expected else { return false }
                index += 1
                return true
            }

            mutating func consumeDigit() -> Bool {
                guard let scalar = peek(), scalar.value >= 48, scalar.value <= 57 else { return false }
                index += 1
                return true
            }

            mutating func consumeDigit1to9() throws {
                guard let scalar = peek(), scalar.value >= 49, scalar.value <= 57 else {
                    throw isAtEnd ? ParseError.unexpectedEnd : ParseError.invalidNumber
                }
                index += 1
            }

            mutating func skipWhitespace() {
                while let scalar = peek(), scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                    index += 1
                }
            }

            func peek() -> UnicodeScalar? {
                isAtEnd ? nil : scalars[index]
            }
        }
    }
}
