import AppKit

// 画面には何も出さず、Host から渡された音を入力デバイスとして見せるだけの補助アプリ
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let relay = RelayClient(arguments: CommandLine.arguments)
relay.start()
application.run()
