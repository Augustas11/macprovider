import MLXLMCommon

extension PrefillParameters {
    /// mlx-swift-lm 3.32 defaults prefill to balanced chunking, which moves the
    /// chunk boundaries every prompt was qualified with. Serve, probe and bench
    /// paths keep the legacy fixed-step boundaries until a token-exact parity row
    /// proves balanced chunking (docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md,
    /// "`.remainder` prefill" before "Balanced/adaptive prefill").
    static func legacyRemainder(stepSize: Int?) -> PrefillParameters {
        PrefillParameters(stepSize: stepSize, chunking: .remainder)
    }
}
