import Foundation
@testable import PadBridgeKit
import Testing

struct TypelessMicrophoneChoiceTests {
    private let name = "PadBridge iPad マイク"
    private let devices: [[String: Any]] = [
        ["deviceId": "default", "label": "Auto-detect (MacBook Proのマイク)", "kind": "audioinput"],
        ["deviceId": "builtin", "label": "MacBook Proのマイク", "kind": "audioinput"],
        ["deviceId": "pad", "label": "PadBridge iPad マイク", "kind": "audioinput"],
    ]

    private func decide(selected: [String: Any]?, devices: [[String: Any]]? = nil) -> TypelessMicrophoneChoice {
        var settings: [String: Any] = ["microphoneDevices": devices ?? self.devices]
        settings["selectedMicrophoneDevice"] = selected ?? NSNull()
        return TypelessMicrophoneChoice.decide(settings: settings, deviceName: name)
    }

    /// 選んでいない (null) なら、一覧の中の iPad のマイクを選ぶ。
    @Test func selectsWhenNothingChosen() {
        #expect(decide(selected: nil) == .select(index: 2))
    }

    /// 自動検出を選んでいるときも選ぶ。蓋を閉じると録音できないため。
    @Test func selectsWhenAutoDetect() {
        #expect(decide(selected: ["deviceId": "default"]) == .select(index: 2))
    }

    @Test func keepsWhenAlreadySelected() {
        #expect(decide(selected: ["deviceId": "pad"]) == .alreadySelected)
    }

    /// ユーザーが特定のマイクを選んでいれば、現在接続されていなくても変えない。
    @Test(arguments: ["builtin", "unplugged-usb"])
    func keepsUserChoice(deviceID: String) {
        #expect(decide(selected: ["deviceId": deviceID]) == .userChoseOther)
    }

    @Test func waitsUntilListed() {
        #expect(decide(selected: nil, devices: Array(devices.prefix(2))) == .notListed)
        #expect(TypelessMicrophoneChoice.decide(settings: [:], deviceName: name) == .notListed)
    }
}
