import XCTest
@testable import LlamaBridge

final class ChatMLTemplateTests: XCTestCase {
    func testRendersTurnsInOrderWithGenerationPrompt() {
        let prompt = ChatMLTemplate.render([
            .init(role: "system", content: "Be helpful."),
            .init(role: "user", content: "Hi there"),
        ])
        XCTAssertEqual(
            prompt,
            "<|im_start|>system\nBe helpful.<|im_end|>\n"
            + "<|im_start|>user\nHi there<|im_end|>\n"
            + "<|im_start|>assistant\n"
        )
    }

    func testEmptyTurnsStillOpensAssistant() {
        XCTAssertEqual(ChatMLTemplate.render([]), "<|im_start|>assistant\n")
    }
}

final class JSONGrammarTests: XCTestCase {
    func testGrammarDefinesRootAndCoreRules() {
        for rule in ["root ::=", "object ::=", "string ::=", "number ::="] {
            XCTAssertTrue(JSONGrammar.object.contains(rule), "missing rule: \(rule)")
        }
    }
}

final class UTF8AccumulatorTests: XCTestCase {
    func testPlainASCIIPassesThrough() {
        var accumulator = UTF8Accumulator()
        XCTAssertEqual(accumulator.append(Array("hello".utf8)), "hello")
        XCTAssertEqual(accumulator.flush(), "")
    }

    func testMultiByteCharacterSplitAcrossPieces() {
        // "ü" is 0xC3 0xBC; a token boundary can fall between the bytes.
        var accumulator = UTF8Accumulator()
        XCTAssertEqual(accumulator.append([0xC3]), "")
        XCTAssertEqual(accumulator.append([0xBC]), "ü")
    }

    func testEmojiSplitByteByByte() {
        // 🎉 U+1F389 = F0 9F 8E 89
        var accumulator = UTF8Accumulator()
        XCTAssertEqual(accumulator.append([0xF0]), "")
        XCTAssertEqual(accumulator.append([0x9F]), "")
        XCTAssertEqual(accumulator.append([0x8E]), "")
        XCTAssertEqual(accumulator.append([0x89]), "🎉")
    }

    func testMixedCompleteAndIncomplete() {
        var accumulator = UTF8Accumulator()
        // "ab" plus the first byte of "é" (0xC3 0xA9)
        XCTAssertEqual(accumulator.append([0x61, 0x62, 0xC3]), "ab")
        XCTAssertEqual(accumulator.append([0xA9, 0x63]), "éc")
    }

    func testFlushDrainsIncompleteTail() {
        var accumulator = UTF8Accumulator()
        XCTAssertEqual(accumulator.append([0xC3]), "")
        XCTAssertEqual(accumulator.flush(), "\u{FFFD}")
        XCTAssertEqual(accumulator.flush(), "")
    }

    func testRuntimeAvailabilityFlagMatchesBuild() {
        // Without the vendored llama.xcframework the stub must report false;
        // with it, true. Either way the flag must exist and be consistent
        // with whether LlamaInstance can be constructed.
        if !LlamaInstance.isRuntimeAvailable {
            XCTAssertThrowsError(
                try LlamaInstance(modelPath: "/nonexistent.gguf", contextTokens: 512, gpuOffload: false)
            ) { error in
                XCTAssertEqual(error as? LlamaBridgeError, .runtimeUnavailable)
            }
        }
    }
}
