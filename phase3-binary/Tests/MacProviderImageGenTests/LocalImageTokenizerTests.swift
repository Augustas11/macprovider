import XCTest
@testable import MacProviderImageGen

final class LocalImageTokenizerTests: XCTestCase {
    // Reduced to the merges used by these fixtures, in their original rank
    // order, from both tokenizers in SDXLTurboManifest.revision. IDs were
    // obtained with Hugging Face CLIP's UTF-8 byte encoding and BPE reference
    // algorithm against the pinned vocabulary and complete merge table.
    // Reference: transformers v4.46.3, models/clip/tokenization_clip.py.
    private func tokenizer() -> CLIPTokenizer {
        CLIPTokenizer(merges: [
            "ð Ł", "v e</w>", "ðŁ ĺ", "a f", "n a", "ðŁ Ĳ", "c af",
            "Ã ©</w>", "ðŁĺ Ģ</w>", "caf Ã©</w>", "å ¥", "Ã ¯", "ä ½",
        ], vocabulary: [
            "<|startoftext|>": 49406, "<|endoftext|>": 49407,
            "ç": 163, "Į": 234, "«</w>": 360, "cafÃ©</w>": 15304,
            "ðŁĺĢ</w>": 7334, "ðŁĲ": 2074, "Ī</w>": 486,
            "ä½": 47466, "ł": 254, "å¥": 29290, "½</w>": 377,
            "na": 1097, "Ã¯": 35689, "ve</w>": 563,
        ])
    }

    func testUnicodePromptsMatchPinnedCLIPReferenceIDs() {
        let tokenizer = tokenizer()
        let fixtures: [(String, [Int32])] = [
            ("猫", [49406, 163, 234, 360, 49407]),
            ("你好", [49406, 47466, 254, 29290, 377, 49407]),
            ("café", [49406, 15304, 49407]),
            ("CAFÉ", [49406, 15304, 49407]),
            ("naïve", [49406, 1097, 35689, 563, 49407]),
            ("😀", [49406, 7334, 49407]),
            ("🐈", [49406, 2074, 486, 49407]),
        ]
        for (prompt, expected) in fixtures {
            XCTAssertEqual(tokenizer.tokenize(text: prompt), expected, prompt)
            // Exercise cached BPE results as well as the first encoding.
            XCTAssertEqual(tokenizer.tokenize(text: prompt), expected, prompt)
        }
    }

    func testCanonicalAccentAndMixedPromptRetainConditioning() {
        let tokenizer = tokenizer()
        XCTAssertEqual(tokenizer.tokenize(text: "cafe\u{301}"), [49406, 15304, 49407])
        XCTAssertEqual(tokenizer.tokenize(text: "猫 café 😀"), [49406, 163, 234, 360, 15304, 7334, 49407])
    }

    func testMissingVocabularyPieceUsesReferenceUnknownTokenInsteadOfDroppingIt() {
        let tokenizer = CLIPTokenizer(merges: [], vocabulary: [
            "<|startoftext|>": 49406, "<|endoftext|>": 49407,
        ])
        XCTAssertEqual(tokenizer.tokenize(text: "猫"), [49406, 49407, 49407, 49407, 49407])
    }
}
