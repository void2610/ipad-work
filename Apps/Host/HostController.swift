import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import os
import PadBridgeKit
import ServiceManagement

@Observable
final class HostController {
    private(set) var connectedDeviceName: String?
    private(set) var listenerDescription = "起動中"
    private(set) var canCaptureScreen = false
    private(set) var canControlInput = false
    /// iPad のマイクを渡すための、PadBridge Host に対するシステムオーディオ録音の許可。
    private(set) var canRelayMicrophone = true
    /// Typeless がシステムオーディオの録音を拒否され、iPad のマイクを読み取れなかった。
    private(set) var typelessCannotReadPadMicrophone = false
    /// Mac のサウンドは iPad で再生していて、Mac のスピーカーからは再生されない。
    private(set) var isPlayingMacAudioOnPad = false
    /// iPad に表示しているディスプレイ。iPad が接続中で、ディスプレイが 2 台以上あるときのみ。
    private(set) var shownDisplayOnPad: String?
    /// iPad に送信している映像の状態 (2 秒ごと)。映像を送信していなければ nil。
    private(set) var videoStatsOnPad: VideoStats?
    /// 接続中の iPad アプリのビルドがこの Host と異なるときの、iPad 側のコミット。
    private(set) var mismatchedPadCommit: String?
    /// ログイン時に Host を起動するか。蓋を閉じた Mac では、再起動後に Host を手動で開けないため。
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "app")
    private var server: HostServer?
    private var permissionTimer: Timer?

    init() {
        refreshPermissions()
        // 初回起動で許可が不足していれば、メニューを開かなくても macOS の許可ダイアログを表示する。システム設定は開かない (ログイン時の起動のたびに最前面に出てしまうので、メニューのボタンからのみ開く)
        if !canCaptureScreen {
            _ = CGRequestScreenCaptureAccess()
        }
        if !canControlInput {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        refreshPermissions()
        startServer()
        // システム設定で許可が変わっても通知が来ないので、表示用に定期的に読み直す
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        canCaptureScreen = CGPreflightScreenCaptureAccess()
        canControlInput = AXIsProcessTrusted()
        // システム設定での許可やログイン項目からの削除は通知されないので、ほかの表示と一緒に読み直す。未確認のときは、確認前と同じく許可済みとみなす
        canRelayMicrophone = AudioCapturePermission.current() != .denied
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestScreenCapture() {
        if !CGRequestScreenCaptureAccess() {
            openPrivacySettings("Privacy_ScreenCapture")
        }
        refreshPermissions()
    }

    func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt はグローバル変数として公開されており Swift 6 では参照できないため、同じ値の文字列で渡す
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacySettings("Privacy_Accessibility")
        }
        refreshPermissions()
    }

    /// 画面収録の許可は、プロセスを再起動するまで反映されないことがあるため用意する。
    func relaunch() {
        // 新旧が同時に動くと Bonjour 名が「(2)」付きに変わり、iPad が名前で記憶している接続先から外れるため、終了してから起動し直す
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 古い Host の終了を待ち、新しい Host の起動を確認できるまで開き直す。一定時間だけ待つと古い方を前面に出すだけで終わり、終了直後に開くと -600 で開けずに終わり、どちらも Host が 1 つも残らない
        let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; for _ in 1 2 3 4 5 6 7 8 9 10; do /usr/bin/open \"$0\"; sleep 1; /usr/bin/pgrep -x \"$2\" >/dev/null && exit 0; done"
        let executableName = Bundle.main.executableURL?.lastPathComponent ?? "PadBridge Host"
        process.arguments = ["-c", script, Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier), executableName]
        try? process.run()
        NSApp.terminate(nil)
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.logger.error("ログイン時の起動を変更できません: \(error, privacy: .public)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openAudioCaptureSettings() {
        openPrivacySettings("Privacy_ScreenCapture")
    }

    private func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startServer() {
        server?.stop()
        connectedDeviceName = nil
        let server = HostServer(
            hostName: Host.current().localizedName ?? "Mac",
            doubleClickInterval: NSEvent.doubleClickInterval,
            keyRepeatDelay: NSEvent.keyRepeatDelay,
            keyRepeatInterval: NSEvent.keyRepeatInterval,
            onClientChange: { [weak self] name in
                Task { @MainActor in self?.connectedDeviceName = name }
            },
            onListenerChange: { [weak self] description in
                Task { @MainActor in self?.listenerDescription = description }
            },
            onStatusChange: { [weak self] status in
                Task { @MainActor in
                    self?.canRelayMicrophone = status.canRelayMicrophone
                    self?.typelessCannotReadPadMicrophone = status.typelessCannotReadPadMicrophone
                }
            },
            onMacAudioChange: { [weak self] isPlaying in
                Task { @MainActor in self?.isPlayingMacAudioOnPad = isPlaying }
            },
            onShownDisplayChange: { [weak self] label in
                Task { @MainActor in self?.shownDisplayOnPad = label }
            },
            onVideoStatsChange: { [weak self] stats in
                Task { @MainActor in self?.videoStatsOnPad = stats }
            },
            onBuildMismatch: { [weak self] padCommit in
                Task { @MainActor in self?.mismatchedPadCommit = padCommit }
            }
        )
        server.start()
        self.server = server
    }
}
