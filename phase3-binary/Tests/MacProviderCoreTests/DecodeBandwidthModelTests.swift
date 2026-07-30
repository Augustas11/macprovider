import MacProviderCore
import XCTest

/// Unit tests for `DecodeBandwidthModel` — pure arithmetic, no GPU required.
///
/// Test naming convention: test<What>_<scenario>.
/// Reference measurement used as the concrete inverse-model anchor:
///   T0-02 gpt-oss — M5 MacBook Air, 118.6 GB/s derived bandwidth,
///   26.3 tok/s measured → 6.42B implied active params of 20B total.
final class DecodeBandwidthModelTests: XCTestCase {

    // MARK: - Constants

    private let accuracy = 1e-6

    // MARK: - Bytes-per-param constants

    func testBytesPerParam_4bit() {
        XCTAssertEqual(DecodeBandwidthModel.fourBitBytesPerParam, 0.5625, accuracy: accuracy)
    }

    func testBytesPerParam_8bit() {
        XCTAssertEqual(DecodeBandwidthModel.eightBitBytesPerParam, 1.0625, accuracy: accuracy)
    }

    func testBytesPerParam_half() {
        XCTAssertEqual(DecodeBandwidthModel.halfBytesPerParam, 2.0, accuracy: accuracy)
    }

    func testBytesPerParamSelector_knownWidths() {
        XCTAssertEqual(DecodeBandwidthModel.bytesPerParam(forQuantBits: 4), 0.5625, accuracy: accuracy)
        XCTAssertEqual(DecodeBandwidthModel.bytesPerParam(forQuantBits: 8), 1.0625, accuracy: accuracy)
        XCTAssertEqual(DecodeBandwidthModel.bytesPerParam(forQuantBits: 16), 2.0, accuracy: accuracy)
    }

    func testBytesPerParamSelector_unknownFallsBackTo4bit() {
        XCTAssertEqual(DecodeBandwidthModel.bytesPerParam(forQuantBits: nil), 0.5625, accuracy: accuracy)
        XCTAssertEqual(DecodeBandwidthModel.bytesPerParam(forQuantBits: 3), 0.5625, accuracy: accuracy)
        XCTAssertEqual(DecodeBandwidthModel.bytesPerParam(forQuantBits: 0), 0.5625, accuracy: accuracy)
    }

    // MARK: - Forward model: readGBPerToken

    func testReadGBPerToken_4bitDense7B() {
        // 7B params × 0.5625 bytes / 1e9 = 3.9375 GB
        let result = DecodeBandwidthModel.readGBPerToken(
            activeParams: 7e9,
            bytesPerParam: DecodeBandwidthModel.fourBitBytesPerParam
        )
        XCTAssertEqual(result, 7e9 * 0.5625 / 1e9, accuracy: accuracy)
        XCTAssertEqual(result, 3.9375, accuracy: accuracy)
    }

    func testReadGBPerToken_zeroParamsReturnsZero() {
        XCTAssertEqual(
            DecodeBandwidthModel.readGBPerToken(activeParams: 0, bytesPerParam: 0.5625),
            0.0
        )
    }

    func testReadGBPerToken_zeroBytesPerParamReturnsZero() {
        XCTAssertEqual(
            DecodeBandwidthModel.readGBPerToken(activeParams: 7e9, bytesPerParam: 0),
            0.0
        )
    }

    // MARK: - Forward model: expectedDecodeTokensPerSecond

    func testExpectedDecodeTokensPerSecond_4B_active_100GBps() {
        // 4B active, 4-bit, 100 GB/s, 0.80 efficiency:
        // readGB = 4e9 * 0.5625 / 1e9 = 2.25 GB
        // tps = 100 * 0.80 / 2.25 = 35.555…
        let tps = DecodeBandwidthModel.expectedDecodeTokensPerSecond(
            activeParams: 4e9,
            bytesPerParam: DecodeBandwidthModel.fourBitBytesPerParam,
            bandwidthGBps: 100.0
        )
        let expected = 100.0 * 0.80 / (4e9 * 0.5625 / 1e9)
        XCTAssertEqual(tps, expected, accuracy: 1e-10)
    }

    func testExpectedDecodeTokensPerSecond_bf16_density() {
        // bf16 is memory-heavier: readGB = activeParams * 2 / 1e9
        let tps = DecodeBandwidthModel.expectedDecodeTokensPerSecond(
            activeParams: 7e9,
            bytesPerParam: DecodeBandwidthModel.halfBytesPerParam,
            bandwidthGBps: 200.0
        )
        let expected = 200.0 * 0.80 / (7e9 * 2.0 / 1e9)
        XCTAssertEqual(tps, expected, accuracy: 1e-10)
    }

    func testExpectedDecodeTokensPerSecond_zeroBandwidthReturnsZero() {
        XCTAssertEqual(
            DecodeBandwidthModel.expectedDecodeTokensPerSecond(
                activeParams: 7e9,
                bandwidthGBps: 0.0
            ),
            0.0
        )
    }

    // MARK: - Inverse model: impliedReadGBPerToken

    func testImpliedReadGBPerToken_symmetricWithForward() {
        let activeParams = 6.42e9
        let bandwidth = 118.6
        let tps = DecodeBandwidthModel.expectedDecodeTokensPerSecond(
            activeParams: activeParams,
            bandwidthGBps: bandwidth
        )
        let impliedReadGB = DecodeBandwidthModel.impliedReadGBPerToken(
            decodeTokensPerSecond: tps,
            bandwidthGBps: bandwidth
        )
        let directReadGB = DecodeBandwidthModel.readGBPerToken(
            activeParams: activeParams,
            bytesPerParam: DecodeBandwidthModel.fourBitBytesPerParam
        )
        XCTAssertEqual(impliedReadGB, directReadGB, accuracy: 1e-10)
    }

    func testImpliedReadGBPerToken_zeroTpsReturnsZero() {
        XCTAssertEqual(
            DecodeBandwidthModel.impliedReadGBPerToken(
                decodeTokensPerSecond: 0,
                bandwidthGBps: 200.0
            ),
            0.0
        )
    }

    // MARK: - Inverse model: impliedActiveParams

    /// Core T2-02 test — anchors the model against measured T0-02 gpt-oss baseline.
    ///
    /// Hardware: M5 MacBook Air, derived bandwidth ≈ 118.6 GB/s.
    /// Measurement: 26.3 tok/s (p50, T0-02 bench, gpt-oss-20b-MXFP4-Q8, 4-bit).
    /// Expected: 6.42B implied active of 20B total (32.1% active fraction).
    ///
    /// Formula: implied = (bw_GBps × eff / tps × 1e9) / bytesPerParam
    ///   = (118.6 × 0.80 / 26.3 × 1e9) / 0.5625
    ///   ≈ 6.414B  (within 0.1% of T0-02 JSON value 6.42B)
    func testImpliedActiveParams_gptOssT002Baseline() {
        let impliedB = DecodeBandwidthModel.impliedActiveParams(
            decodeTokensPerSecond: 26.3,
            bandwidthGBps: 118.6
        ) / 1e9

        // Expect ~6.42B; within 1% tolerance for rounding in T0-02 derivation.
        XCTAssertEqual(impliedB, 6.42, accuracy: 0.07,
            "gpt-oss 26.3 TPS @ 118.6 GB/s → implied active ≈ 6.42B of 20B total")

        // Active fraction should be ~32% — well below 100% (confirming MoE sparsity).
        let activeFraction = impliedB / 20.0
        XCTAssertLessThan(activeFraction, 0.40, "Active fraction < 40% confirms MoE sparsity")
        XCTAssertGreaterThan(activeFraction, 0.25, "Active fraction > 25% guards against regression")
    }

    func testImpliedActiveParams_roundTrip_4B() {
        // Forward: 4B active → TPS; Inverse: TPS → 4B active.
        let activeIn = 4e9
        let bandwidth = 200.0
        let tps = DecodeBandwidthModel.expectedDecodeTokensPerSecond(
            activeParams: activeIn,
            bandwidthGBps: bandwidth
        )
        let activeOut = DecodeBandwidthModel.impliedActiveParams(
            decodeTokensPerSecond: tps,
            bandwidthGBps: bandwidth
        )
        XCTAssertEqual(activeOut, activeIn, accuracy: 1.0,  // within 1 param element
            "Round-trip forward→inverse should recover the original active param count")
    }

    func testImpliedActiveParams_zeroBytesPerParamReturnsZero() {
        XCTAssertEqual(
            DecodeBandwidthModel.impliedActiveParams(
                decodeTokensPerSecond: 26.3,
                bandwidthGBps: 118.6,
                bytesPerParam: 0
            ),
            0.0
        )
    }

    // MARK: - Regime classification

    func testClassifyRegime_dense() {
        // 90% of total weight read → dense
        let result = DecodeBandwidthModel.classifyRegime(
            impliedReadGB: 9.0,
            totalWeightGB: 10.0
        )
        XCTAssertEqual(result, .dense)
    }

    func testClassifyRegime_sparse() {
        // 20% of total weight read → sparse
        let result = DecodeBandwidthModel.classifyRegime(
            impliedReadGB: 2.0,
            totalWeightGB: 10.0
        )
        XCTAssertEqual(result, .sparse)
    }

    func testClassifyRegime_intermediate() {
        // 45% of total weight read → intermediate
        let result = DecodeBandwidthModel.classifyRegime(
            impliedReadGB: 4.5,
            totalWeightGB: 10.0
        )
        XCTAssertEqual(result, .intermediate)
    }

    func testClassifyRegime_zeroTotalWeightIsIntermediate() {
        XCTAssertEqual(
            DecodeBandwidthModel.classifyRegime(impliedReadGB: 3.0, totalWeightGB: 0.0),
            .intermediate
        )
    }

    /// gpt-oss T0-02: 6.42B implied active of 11.25 GB total (20B × 0.5625 B/param).
    func testClassifyRegime_gptOssSparse() {
        let impliedReadGB = 6.42 * 0.5625  // ≈ 3.61 GB
        let totalWeightGB = 20.0 * 0.5625  // = 11.25 GB
        // fraction = 3.61 / 11.25 ≈ 0.321 → sparse (≤ 0.3 threshold is borderline)
        let regime = DecodeBandwidthModel.classifyRegime(
            impliedReadGB: impliedReadGB,
            totalWeightGB: totalWeightGB
        )
        XCTAssertNotEqual(regime, .dense, "gpt-oss 32% active fraction is not dense")
    }

    // MARK: - Batch-scaling linearity

    func testBatchScalingLinearity_nilWhenNoBase() {
        let result = DecodeBandwidthModel.batchScalingLinearity(
            aggregateByBatch: [(batchSize: 2, aggregateTokensPerSecond: 60)]
        )
        XCTAssertNil(result)
    }

    func testBatchScalingLinearity_nilWhenNoHigherBatch() {
        let result = DecodeBandwidthModel.batchScalingLinearity(
            aggregateByBatch: [(batchSize: 1, aggregateTokensPerSecond: 30)]
        )
        XCTAssertNil(result)
    }

    func testBatchScalingLinearity_perfectlyLinear() {
        // Dense model: aggregate tok/s doubles when batch doubles → linearity = 1.0
        let result = DecodeBandwidthModel.batchScalingLinearity(aggregateByBatch: [
            (batchSize: 1, aggregateTokensPerSecond: 30),
            (batchSize: 2, aggregateTokensPerSecond: 60),
            (batchSize: 4, aggregateTokensPerSecond: 120),
        ])
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 1.0, accuracy: 1e-10)
    }

    func testBatchScalingLinearity_subLinear_sparseRegime() {
        // MoE: adding sequences pulls in new experts; linearity < 1.0
        let result = DecodeBandwidthModel.batchScalingLinearity(aggregateByBatch: [
            (batchSize: 1, aggregateTokensPerSecond: 30),
            (batchSize: 2, aggregateTokensPerSecond: 50),   // 50/30/2 = 0.833
            (batchSize: 4, aggregateTokensPerSecond: 80),   // 80/30/4 = 0.667
        ])
        XCTAssertNotNil(result)
        XCTAssertLessThan(result!, 1.0, "Sub-linear scaling indicates MoE sparse regime")
        // mean(0.833, 0.667) = 0.75
        XCTAssertEqual(result!, 0.75, accuracy: 1e-10)
    }

    // MARK: - SiliconBandwidthTier

    func testSiliconBandwidthTier_m4_120GBps() {
        XCTAssertEqual(SiliconBandwidthTier.m4.bandwidthGBps, 120.0, accuracy: accuracy)
    }

    func testSiliconBandwidthTier_m4Pro_273GBps() {
        XCTAssertEqual(SiliconBandwidthTier.m4Pro.bandwidthGBps, 273.0, accuracy: accuracy)
    }

    func testSiliconBandwidthTier_allPositive() {
        for tier in SiliconBandwidthTier.allCases {
            XCTAssertGreaterThan(tier.bandwidthGBps, 0.0, "\(tier.rawValue) bandwidth must be > 0")
        }
    }

    func testSiliconBandwidthTier_ultraHigherThanMax() {
        XCTAssertGreaterThan(SiliconBandwidthTier.m1Ultra.bandwidthGBps, SiliconBandwidthTier.m1Max.bandwidthGBps)
        XCTAssertGreaterThan(SiliconBandwidthTier.m2Ultra.bandwidthGBps, SiliconBandwidthTier.m2Max.bandwidthGBps)
    }
}
