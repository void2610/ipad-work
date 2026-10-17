import AppKit
import ApplicationServices
import CoreGraphics
import Observation

@Observable
final class HostController {
    private(set) var connectedDeviceName: String?
    private(set) var listenerDescription = "起動中"
    private(set) var canCaptureScreen = false
    private(set) var canControlInput = false

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
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
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
            onClientChange: { [weak self] name in
                Task { @MainActor in self?.connectedDeviceName = name }
            },
            onListenerChange: { [weak self] description in
                Task { @MainActor in self?.listenerDescription = description }
            }
        )
        server.start()
        self.server = server
    }
}
