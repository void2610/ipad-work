import AppKit

/// 終了する直前に、作成したデバイスを削除する。Host との接続が切れたときや終了シグナルのほかに、Apple Event で終了させられることもあるため。
final class HelperDelegate: NSObject, NSApplicationDelegate {
    let relay: RelayClient

    init(relay: RelayClient) {
        self.relay = relay
    }

    func applicationWillTerminate(_: Notification) {
        relay.stopBeforeQuitting()
    }
}

// ウィンドウは表示せず、Host から渡された音声を入力デバイスとして見せるだけのヘルパーアプリ
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let relay = RelayClient(arguments: CommandLine.arguments)
let delegate = HelperDelegate(relay: relay)
application.delegate = delegate
relay.start()
application.run()
