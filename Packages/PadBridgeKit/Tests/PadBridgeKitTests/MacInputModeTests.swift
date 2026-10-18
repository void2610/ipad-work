@testable import PadBridgeKit
import Testing

struct MacInputModeTests {
    /// この Mac で有効な ABC と、日本語入力の「ひらがな」。
    @Test func classifiesEnabledSources() {
        #expect(MacInputMode(isKeyboardLayout: true, inputModeID: nil) == .alphanumeric)
        #expect(MacInputMode(isKeyboardLayout: false, inputModeID: "com.apple.inputmethod.Japanese") == .kana)
    }

    /// 日本語入力のほかのモード。英字は英数、カタカナと半角カナはかなのキーで入るので、かなとする。
    @Test(arguments: [
        ("com.apple.inputmethod.Roman", MacInputMode.alphanumeric),
        ("com.apple.inputmethod.Japanese.Katakana", .kana),
        ("com.apple.inputmethod.Japanese.HalfWidthKana", .kana),
        ("com.apple.inputmethod.Japanese.FullWidthRoman", .other),
        ("com.apple.inputmethod.Korean.2SetKorean", .other),
    ])
    func classifiesJapaneseInputModes(modeID: String, mode: MacInputMode) {
        #expect(MacInputMode(isKeyboardLayout: false, inputModeID: modeID) == mode)
    }

    @Test func inputModeRoundTripsOnTheWire() throws {
        let encoded = try WireMessage.control(.macInputMode(.kana)).encoded()
        #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == .control(.macInputMode(.kana)))
    }
}
