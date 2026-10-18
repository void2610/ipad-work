import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import os
import ServiceManagement

@Observable
final class HostController {
    private(set) var connectedDeviceName: String?
    private(set) var listenerDescription = "起動中"
    private(set) var canCaptureScreen = false
    private(set) var canControlInput = false
    /// iPad のマイクを渡すための、PadBridge Host のシステムオーディオの録音の許可。
    private(set) var canRelayMicrophone = true
    /// Typeless がシステムオーディオの録音を断られ、iPad のマイクを読めなかった。
    private(set) var typelessCannotReadPadMicrophone = false
    /// Mac の音を iPad で鳴らしていて、Mac のスピーカーからは鳴らない。
    private(set) var isPlayingMacAudioOnPad = false
    /// iPad に映している画面。iPad がつながっていて、画面が 2 台以上あるときだけ。
    private(set) var shownDisplayOnPad: String?
    /// ログインしたときに Host を起動するか。蓋を閉じた Mac では、再起動のあと Host を手で開けないため。
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "app")
    private var server: HostServer?
    private var permissionTimer: Timer?

    init() {
        refreshPermissions()
        // 初回起動で許可が足りなければ、メニューを開かなくても macOS の許可ダイアログを出す
        if !canCaptureScreen {
            requestScreenCapture()
        }
        if !canControlInput {
            requestAccessibility()
        }
        startServer()
        // システム設定で許可が変わっても通知が来ないので、表示用に定期的に読み直す
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        canCaptureScreen = CGPreflightScreenCaptureAccess()
        canControlInput = AXIsProcessTrusted()
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

    /// 画面収録の許可は、プロセスを起動し直すまで反映されないことがあるため用意する。
    func relaunch() {
        // 新旧が同時に動くと Bonjour 名が「(2)」付きに変わり、iPad が名前で覚えている接続先から外れるため、終了してから起動し直す
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 古い Host が終わるのを待ってから開く。決まった時間だけ待つと、終わるのが遅れたときに古い方を前に出すだけで終わり、Host が 1 つも残らない
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
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
            Self.logger.error("ログイン時の起動を変えられない: \(error, privacy: .public)")
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
            }
        )
        server.start()
        self.server = server
    }
}
