import Foundation

/// Typeless の設定 (app-settings.json) を見て、マイクを「PadBridge iPad マイク」にするかを決める。
/// 自動検出のままだと蓋を閉じた Mac では録音できないので選択する。ユーザーが特定のマイクを選んでいれば、その選択を維持する。
/// 自動検出に戻っているときは選び直すので、Typeless を再インストールしたり設定が消えたりしても、iPad のマイクで話せる。
public enum TypelessMicrophoneChoice: Equatable, Sendable {
    case alreadySelected
    case userChoseOther
    /// Typeless のマイクの一覧にまだ載っていない (Typeless がデバイスの変化を再読み込みする前)
    case notListed
    /// マイクの一覧の `index` 番目を選択する
    case select(index: Int)

    // Typeless (Chromium) が自動検出に使う既定の入力の deviceId
    private static let defaultDeviceID = "default"

    public static func decide(settings: [String: Any], deviceName: String) -> TypelessMicrophoneChoice {
        guard let devices = settings["microphoneDevices"] as? [[String: Any]],
              let index = devices.firstIndex(where: { $0["label"] as? String == deviceName }),
              let deviceID = devices[index]["deviceId"] as? String
        else { return .notListed }
        let selectedID = (settings["selectedMicrophoneDevice"] as? [String: Any])?["deviceId"] as? String
        if selectedID == deviceID {
            return .alreadySelected
        }
        if let selectedID, selectedID != defaultDeviceID {
            return .userChoseOther
        }
        return .select(index: index)
    }
}
