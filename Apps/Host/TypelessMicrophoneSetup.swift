import AppKit
import Foundation
import os
import PadBridgeKit

/// Typeless に「PadBridge iPad マイク」を使わせる設定を自動で行う。どの場合に選ぶかは `TypelessMicrophoneChoice` が決める。
/// このデバイスは Mac の既定の入力になれない (タップだけの集約デバイスは CanBeDefaultDevice が 0) ので、Typeless の「自動検出」のままでは使われない。
/// Typeless は選んだマイクが今のマイクの一覧になければ自動検出に戻る作りなので、選んだままにしておいても、iPad がつながっていないときの使い方は変わらない。
/// iPad がつながっていても iPad から話していない間は、補助アプリがこのデバイスに Mac の既定の入力の音を流すので、Mac で直接話しても聞き取れる。
/// Typeless の設定 (electron-store) は外からの書き換えを読み直さず上書きするので、Typeless を終了してから書き換え、起動し直す。
nonisolated enum TypelessMicrophoneSetup {
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "typeless")
    private static let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Typeless/app-settings.json")

    enum Result {
        case configured
        case alreadySelected
        case skipped(String)
    }

    /// Typeless が聞き取っていない間に呼ぶ。`deviceName` は Typeless のマイクの一覧に出る名前。
    static func selectPadMicrophone(deviceName: String) -> Result {
        guard let settings = readSettings() else { return .skipped("Typeless の設定を読めない") }
        switch TypelessMicrophoneChoice.decide(settings: settings, deviceName: deviceName) {
        case .alreadySelected:
            return .alreadySelected
        case .userChoseOther:
            return .skipped("利用者が Typeless で別のマイクを選んでいるので変えない")
        case .notListed:
            return .skipped("Typeless のマイクの一覧に \(deviceName) がまだない")
        case .select:
            break
        }
        // 利用者が自分で終了させていた Typeless を、設定のために勝手に起動しない
        let wasRunning = TypelessApp.isRunning
        guard terminateTypeless() else { return .skipped("Typeless を終了できない") }
        func launchTypeless() {
            if wasRunning { Self.launchTypeless() }
        }
        // 終了するときに Typeless が設定を書き出すので、終わってから読み直し、改めて決めてから書き換える
        guard var latest = readSettings() else {
            launchTypeless()
            return .skipped("Typeless の設定を読めない")
        }
        guard case let .select(index) = TypelessMicrophoneChoice.decide(settings: latest, deviceName: deviceName),
              let entry = (latest["microphoneDevices"] as? [[String: Any]])?[index]
        else {
            launchTypeless()
            return .skipped("Typeless を終了するあいだに設定が変わった")
        }
        latest["selectedMicrophoneDevice"] = entry
        do {
            let data = try JSONSerialization.data(withJSONObject: latest, options: [.prettyPrinted])
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            launchTypeless()
            return .skipped("Typeless の設定を書き換えられない: \(error.localizedDescription)")
        }
        launchTypeless()
        logger.notice("Typeless のマイクを \(deviceName, privacy: .public) にした")
        return .configured
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func terminateTypeless() -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: TypelessApp.bundleIdentifier)
        apps.forEach { $0.terminate() }
        for _ in 0 ..< 100 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: TypelessApp.bundleIdentifier).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func launchTypeless() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TypelessApp.bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let launched = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in launched.signal() }
        _ = launched.wait(timeout: .now() + 10)
    }
}
