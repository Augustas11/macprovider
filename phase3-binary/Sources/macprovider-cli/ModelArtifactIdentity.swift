import Foundation

enum ModelArtifactIdentity {
    static let snapshotManifestV1 = "macprovider.snapshot-manifest.v1"
    static let safetensorsManifestV1 = "macprovider.safetensors-manifest.v1"
    /// SPEC-010 v1.7 R002/R007(a): lowercase SHA-256 of the complete GGUF file
    /// bytes, computed by the CLI over the bytes it holds.
    static let ggufFileV1 = "macprovider.gguf-file.v1"
}
