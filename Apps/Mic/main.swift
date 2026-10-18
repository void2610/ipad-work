import AppKit

/// 終わる直前に、作ったデバイスを消す。Host との接続が切れたときや終了の合図のほかに、Apple Event で終わらされることもあるため。
final class HelperDelegate: NSObject, NSApplicationDelegate {
    let relay: RelayClient

    init(relay: RelayClient) {
        self.relay = relay
    }

    func applicationWillTerminate(_: Notification) {
        relay.stopBeforeQuitting()
    }
}

// 画面には何も出さず、Host から渡された音を入力デバイスとして見せるだけの補助アプリ
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let relay = RelayClient(arguments: CommandLine.arguments)
let delegate = HelperDelegate(relay: relay)
application.delegate = delegate
relay.start()
application.run()
