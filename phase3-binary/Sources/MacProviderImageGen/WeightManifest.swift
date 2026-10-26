import CryptoKit
import Foundation

/// Trusted file identities for stabilityai/sdxl-turbo, using fp16 variant weights only.
public enum SDXLTurboManifest {
    public static let revision = "71153311d3dbb46851df1931d3ca6e939de83304"
    public static let repository = "stabilityai/sdxl-turbo"
    public static let files: [ImageWeightFile] = [
        .init(path: "unet/config.json", size: 1776, sha256: "6ae877bd8daca6088f44c6251e07d7e252da53ace0d5895a0c6cbcbd5c132cb4"),
        .init(path: "unet/diffusion_pytorch_model.fp16.safetensors", size: 5135149760, sha256: "48fa46161a745f48d4054df3fe13804ee255486bca893403b60373c188fd1bdb"),
        .init(path: "text_encoder/config.json", size: 565, sha256: "f73737aca344421ae12c5302aad65570218d4911872ac2e656d685a23bee270a"),
        .init(path: "text_encoder/model.fp16.safetensors", size: 246144152, sha256: "660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd"),
        .init(path: "text_encoder_2/config.json", size: 575, sha256: "d798a4e0dea19feb3e4f17d311e02507055ce3ee81d015a43123517433f2a7ef"),
        .init(path: "text_encoder_2/model.fp16.safetensors", size: 1389382176, sha256: "ec310df2af79c318e24d20511b601a591ca8cd4f1fce1d8dff822a356bcdb1f4"),
        .init(path: "vae/config.json", size: 607, sha256: "85a181424a5fd0cc292e44e467be66a5263976eee1baf36d208133f9d49d4269"),
        .init(path: "vae/diffusion_pytorch_model.fp16.safetensors", size: 167335342, sha256: "02ee4bd18e5d16e7fe5fc5b85b4aefa2cba6db28897f674226c9d6ddd2f34f06"),
        .init(path: "scheduler/scheduler_config.json", size: 459, sha256: "13847eb34084bc56e9f8b10f84d2c650cf8cb00016b2530429af0b894d4e1aa2"),
        .init(path: "tokenizer/vocab.json", size: 1059962, sha256: "e089ad92ba36837a0d31433e555c8f45fe601ab5c221d4f607ded32d9f7a4349"),
        .init(path: "tokenizer/merges.txt", size: 524619, sha256: "9fd691f7c8039210e0fced15865466c65820d09b63988b0174bfe25de299051a"),
        .init(path: "tokenizer_2/vocab.json", size: 1059962, sha256: "e089ad92ba36837a0d31433e555c8f45fe601ab5c221d4f607ded32d9f7a4349"),
        .init(path: "tokenizer_2/merges.txt", size: 524619, sha256: "9fd691f7c8039210e0fced15865466c65820d09b63988b0174bfe25de299051a")
    ]
    public static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct ImageWeightFile: Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }

    public func verify(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == size else {
            throw ImageRuntimeError.invalidWeights(path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw ImageRuntimeError.invalidWeights(path)
        }
    }
}
