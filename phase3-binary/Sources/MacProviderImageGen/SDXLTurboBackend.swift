import Foundation
import ImageIO
import MLX
import MLXNN
import UniformTypeIdentifiers

/// Files are resolved only from a verified provider-owned model directory.
public struct ImageModelFiles: Sendable {
    let directory: URL
    public init(directory: URL) { self.directory = directory }
}

public struct ImageDownloadProgress: Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public enum ImageRuntimeError: LocalizedError {
    case invalidWeights(String)
    case downloadFailed(Int)
    case notLoaded
    case invalidRequest
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidWeights(let name): return "Image model verification failed for \(name). Retry the download."
        case .downloadFailed(let status): return "Image model download failed (HTTP \(status))."
        case .notLoaded: return "The image model is not loaded."
        case .invalidRequest: return "Use a prompt of 1–4,000 characters, 512 or 1024 pixels, and 1–4 steps."
        case .encodingFailed: return "The generated image could not be encoded as PNG."
        }
    }
}

/// The provider owns admission, creative hold and warm lifetime. This actor serializes
/// MLX model ownership and never joins a coordinator or records customer usage.
public actor SDXLTurboBackend {
    private let directory: URL
    private var generator: (any TextToImageGenerator)?
    private var quantized: Bool?
    private var hasMLXAllocation = false

    public init(modelDirectory: URL) {
        directory = modelDirectory.appendingPathComponent("sdxl-turbo-\(SDXLTurboManifest.revision)", isDirectory: true)
    }

    public func prepare(
        quantized: Bool,
        progress: @escaping @Sendable (ImageDownloadProgress) -> Void
    ) async throws {
        if generator != nil, self.quantized == quantized { return }
        try await ImageWeightDownloader.prepare(directory: directory, progress: progress)
        try Task.checkCancellation()
        if hasMLXAllocation {
            generator = nil
            Memory.clearCache()
        }
        hasMLXAllocation = true
        let model = try withRandomState(MLXRandom.RandomState(seed: 0)) {
            try StableDiffusionConfiguration.presetSDXLTurbo.textToImageGenerator(
                hub: ImageModelFiles(directory: directory),
                configuration: LoadConfiguration(float16: true, quantize: quantized))
        }
        try Task.checkCancellation()
        model?.ensureLoaded()
        try Task.checkCancellation()
        guard let model else { throw ImageRuntimeError.notLoaded }
        generator = model
        self.quantized = quantized
    }

    public func generate(prompt: String, size: Int, steps: Int, seed: UInt64) async throws -> Data {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= 4000, [512, 1024].contains(size), (1...4).contains(steps) else {
            throw ImageRuntimeError.invalidRequest
        }
        guard generator != nil else { throw ImageRuntimeError.notLoaded }
        return try withRandomState(MLXRandom.RandomState(seed: seed)) {
            try render(prompt: prompt, size: size, steps: steps, seed: seed)
        }
    }

    private func render(prompt: String, size: Int, steps: Int, seed: UInt64) throws -> Data {
        guard let generator else { throw ImageRuntimeError.notLoaded }
        try Task.checkCancellation()
        let parameters = EvaluateParameters(
            cfgWeight: 0, steps: steps, latentSize: [size / 8, size / 8], seed: seed, prompt: prompt)
        var last: MLXArray?
        for latent in generator.generateLatents(parameters: parameters) {
            try Task.checkCancellation()
            eval(latent)
            last = latent
        }
        try Task.checkCancellation()
        guard let last else { throw ImageRuntimeError.encodingFailed }
        let pixels = (generator.decode(xt: last)[0] * 255).asType(.uint8)
        eval(pixels)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageRuntimeError.encodingFailed
        }
        CGImageDestinationAddImage(destination, Image(pixels).asCGImage(), nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageRuntimeError.encodingFailed }
        try Task.checkCancellation()
        return data as Data
    }

    public func unload() {
        guard hasMLXAllocation else { return }
        generator = nil
        quantized = nil
        Memory.clearCache()
        hasMLXAllocation = false
    }
}
