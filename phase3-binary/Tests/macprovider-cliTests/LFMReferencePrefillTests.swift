#if MACPROVIDER_LAB_HARNESS
import Foundation
import MLX
import MLXLLM
import MLXNN
import XCTest

final class LFMReferencePrefillTests: XCTestCase {
    func testLFMQuantizationKeepsReferencePrefillOnEveryLinearProjection() throws {
        try Device.withDefaultDevice(.cpu) {
            let config = try JSONDecoder().decode(LFM2MoEConfiguration.self, from: Data("""
                {"model_type":"lfm2_moe","vocab_size":32,"hidden_size":64,
                 "intermediate_size":64,"moe_intermediate_size":64,"num_hidden_layers":3,
                 "num_experts":4,"num_experts_per_tok":2,"norm_topk_prob":true,
                 "num_attention_heads":1,"num_key_value_heads":1,"max_position_embeddings":128,
                 "use_expert_bias":true,"num_dense_layers":2,"norm_eps":0.00001,
                 "conv_bias":false,"conv_L_cache":3,"full_attn_idxs":[2]}
                """.utf8))
            let model = LFM2MoEModel(config)
            let projections = model.leafModules().flattened().compactMap { path, module in
                (module as? Linear).map { (path, $0) }
            }
            XCTAssertFalse(projections.isEmpty)
            for (path, linear) in projections {
                XCTAssertTrue(linear.referencePrefill, path)
                let quantized = try XCTUnwrap(linear.toQuantized(
                    groupSize: 64, bits: 4, mode: .affine) as? QuantizedLinear)
                XCTAssertTrue(quantized.referencePrefill, path)
            }
            XCTAssertFalse(Linear(64, 64).referencePrefill,
                           "Other model families keep the existing numeric route")
        }
    }
}
#endif
