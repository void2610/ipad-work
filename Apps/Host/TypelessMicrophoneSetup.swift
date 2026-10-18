import AppKit
import Foundation
import os
import PadBridgeKit
import Synchronization

/// Typeless に「PadBridge iPad マイク」を使わせる設定を自動で行う。どの場合に選択するかは `TypelessMicrophoneChoice` が決める。
/// このデバイスは Mac の既定の入力になれない (タップのみの機器セットは CanBeDefaultDevice が 0) ので、Typeless の「自動検出」のままでは使われない。
/// Typeless は選択したマイクが現在のマイク一覧になければ自動検出に戻る作りなので、選択したままにしておいても、iPad が接続されていないときの動作は変わらない。
/// iPad が接続中でも iPad から話していない間は、ヘルパーアプリがこのデバイスに Mac の既定の入力の音声を流すので、Mac で直接話しても音声入力できる。
/// Typeless の設定 (electron-store) は外部からの書き換えを再読み込みせず上書きするので、Typeless を終了してから書き換え、再起動する。
nonisolated enum TypelessMicrophoneSetup {
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "typeless")
    private static let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Typeless/app-settings.json")

    enum Result {
        case configured
        case alreadySelected
        case skipped(String)
    }

    /// Typeless が音声入力中でない間に呼ぶ。`deviceName` は Typeless のマイク一覧に表示される名前。
    private static let restarting = Mutex(false)

    /// Typeless を終了して再起動している最中か。
    static var isRestartingTypeless: Bool {
        restarting.withLock { $0 }
    }

    static func selectPadMicrophone(deviceName: String) -> Result {
        guard let settings = readSettings() else { return .skipped("Typeless の設定を読み取れない") }
        switch TypelessMicrophoneChoice.decide(settings: settings, deviceName: deviceName) {
        case .alreadySelected:
            return .alreadySelected
        case .userChoseOther:
            return .skipped("ユーザーが Typeless で別のマイクを選択しているので変更しない")
        case .notListed:
            return .skipped("Typeless のマイク一覧に \(deviceName) がまだない")
        case .select:
            break
        }
        // 終了してから再起動するまでの間は、iPad から開始しても Typeless のショートカットを押すのを待たせる
        restarting.withLock { $0 = true }
        defer { restarting.withLock { $0 = false } }
        // 無音を確認してからここまでの間に、音声入力が始まっていれば終了させない
        guard !TypelessMonitor.isRecording() else { return .skipped("Typeless が音声入力を始めたので、終了させない") }
        // ユーザーが自分で終了していた Typeless を、設定のために勝手に起動しない
        let wasRunning = TypelessApp.isRunning
        guard terminateTypeless() else { return .skipped("Typeless を終了できない") }
        func launchTypeless() {
            if wasRunning { Self.launchTypeless() }
        }
        // 終了時に Typeless が設定を書き出すので、終了後に読み直し、改めて判定してから書き換える
        guard var latest = readSettings() else {
            launchTypeless()
            return .skipped("Typeless の設定を読み取れない")
        }
        guard case let .select(index) = TypelessMicrophoneChoice.decide(settings: latest, deviceName: deviceName),
              let entry = (latest["microphoneDevices"] as? [[String: Any]])?[index]
        else {
            launchTypeless()
            return .skipped("Typeless の終了中に設定が変わった")
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
        logger.notice("Typeless のマイクを \(deviceName, privacy: .public) に設定した")
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
