/// Mac の文字入力が英数とかなのどちらか。iPad の特殊キーの列で、効いている方のキーを示す。
public enum MacInputMode: String, Codable, Sendable {
    case alphanumeric
    case kana
    /// 全角英字や、中国語・韓国語の入力など、英数・かなのキーでは表せないもの。
    case other

    /// 入力ソースの種類と入力モードの ID から決める。`isKeyboardLayout` は ABC などのキー配列そのもの (入力メソッドを通さない)。
    /// 日本語入力の ID は、この Mac に入っている日本語入力 (ローマ字入力・かな入力) の入力ソースから読んだもの。
    public init(isKeyboardLayout: Bool, inputModeID: String?) {
        if isKeyboardLayout {
            self = .alphanumeric
            return
        }
        switch inputModeID {
        case "com.apple.inputmethod.Roman":
            self = .alphanumeric
        case "com.apple.inputmethod.Japanese", "com.apple.inputmethod.Japanese.Katakana", "com.apple.inputmethod.Japanese.HalfWidthKana":
            self = .kana
        default:
            self = .other
        }
    }
}
