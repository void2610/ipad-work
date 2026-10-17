import AppKit
import CoreMedia
import Network
import VideoToolbox

// Host は同じペアリングコードで先に起動しておく必要がある (`just e2e` が両方まとめて行う)

@MainActor
final class Harness {
    private let code: PairingCode
    private let loopbackPort: NWEndpoint.Port
    private var failures: [String] = []
    private let window: NSWindow
    private let probe = ProbeView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
    private let axTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
    private let fallbackTextView = AXRefusingTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
    private var animationTimer: Timer?

    init(code: PairingCode, loopbackPort: NWEndpoint.Port) {
        self.code = code
        self.loopbackPort = loopbackPort
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "PadBridge E2E"
        // 合成したクリックが他のアプリの窓に当たらないよう、常に最前面に置く
        window.level = .floating
        // NSTextView は固有の大きさを持たず、スタックに入れると潰れるので高さを固定する
        for textView in [axTextView, fallbackTextView] {
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.heightAnchor.constraint(equalToConstant: 60).isActive = true
            textView.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        let stack = NSStackView(views: [probe, axTextView, fallbackTextView])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        window.contentView = stack
    }

    func run() async -> Int32 {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let originalCursor = NSEvent.mouseLocation
        defer {
            CGWarpMouseCursorPosition(CGPoint(x: originalCursor.x, y: Self.mainHeight - originalCursor.y))
            window.close()
        }

        // ローカルネットワークの許可が下りていない間も残りを確かめられるよう、見つからなければループバックで続ける
        let discovered = await step("Bonjour で Host を見つける") { try await Self.discoverHost() }
        let endpoint = discovered ?? .hostPort(host: "127.0.0.1", port: loopbackPort)
        await step("違うコードは TLS で拒否される") { try await Self.expectRejected(endpoint: endpoint) }
        guard let session = await step("正しいコードで接続して welcome を受け取る", { try await ClientSession.connect(endpoint: endpoint, code: self.code) }) else { return 1 }
        defer { session.close() }
        print("  Host の状態: 画面収録=\(session.status.canCaptureScreen) アクセシビリティ=\(session.status.canControlInput)")

        startAnimating()
        await step("映像を受け取って復号できる") { try await self.checkVideo(session: session) }
        await step("キーフレームの要求に応える") { try await session.video.expectKeyFrame(after: { session.send(.requestKeyFrame) }) }
        animationTimer?.invalidate()

        await step("タップした位置がクリックされる") { try await self.checkClick(session: session) }
        await step("連続タップがダブルクリックになる") { try await self.checkDoubleClick(session: session) }
        await step("2 本指の移動がスクロールになる") { try await self.checkScroll(session: session) }
        await step("AX 経由で文字が入る") { try await self.checkInsert(session: session, into: self.axTextView, text: "AX経由の挿入テスト") }
        await step("AX が効かない欄にはキー入力で文字が入る") {
            try await self.checkInsert(session: session, into: self.fallbackTextView, text: "フォールバック入力テスト😀")
        }
        await step("Return キーが届く") { try await self.checkReturnKey(session: session) }
        await step("Command+A が届く") { try await self.checkShortcut(session: session) }

        if failures.isEmpty {
            print("\n全項目成功")
            return 0
        }
        print("\n失敗: \(failures.count) 件")
        failures.forEach { print("  - \($0)") }
        return 1
    }

    @discardableResult
    private func step<T>(_ name: String, _ body: () async throws -> T) async -> T? {
        do {
            let value = try await body()
            print("✓ \(name)")
            return value
        } catch {
            print("✗ \(name): \(error)")
            failures.append("\(name): \(error)")
            return nil
        }
    }

    // MARK: - 映像

    private func startAnimating() {
        // 画面が変わらないと ScreenCaptureKit はフレームを出さないので、窓の色を変え続ける
        var hue: CGFloat = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [probe] _ in
            MainActor.assumeIsolated {
                hue = (hue + 0.01).truncatingRemainder(dividingBy: 1)
                probe.fillColor = NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1)
            }
        }
    }

    private func checkVideo(session: ClientSession) async throws {
        let stats = try await session.video.collect(for: 3)
        print("  映像: \(stats.width)x\(stats.height)、3 秒で \(stats.decodedFrames) フレーム復号、平均 \(stats.averageFrameBytes / 1024) KiB/フレーム")
        guard stats.width <= 1280, stats.height <= 800 else { throw HarnessError("要求した 1280x800 を超えている") }
        let display = CGDisplayBounds(CGMainDisplayID())
        let aspectError = abs(Double(stats.width) / Double(stats.height) - display.width / display.height)
        guard aspectError < 0.02 else { throw HarnessError("縦横比がディスプレイと違う (誤差 \(aspectError))") }
        guard stats.decodedFrames >= 30 else { throw HarnessError("フレームが少ない (\(stats.decodedFrames))") }
    }

    // MARK: - 操作

    private func normalizedPoint(of view: NSView) -> NormalizedPoint {
        let rectInWindow = view.convert(view.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        let center = CGPoint(x: rectOnScreen.midX, y: Self.mainHeight - rectOnScreen.midY)
        let display = CGDisplayBounds(CGMainDisplayID())
        return NormalizedPoint(x: (center.x - display.minX) / display.width, y: (center.y - display.minY) / display.height)
    }

    private func click(_ view: NSView, session: ClientSession) {
        let point = normalizedPoint(of: view)
        session.send(.mouseMove(point))
        session.send(.mouseButton(.left, isDown: true, at: point))
        session.send(.mouseButton(.left, isDown: false, at: point))
    }

    private func checkClick(session: ClientSession) async throws {
        probe.reset()
        click(probe, session: session)
        try await waitUntil { self.probe.clicks.count == 1 }
        let location = probe.clicks[0].location
        let distance = hypot(location.x - probe.bounds.midX, location.y - probe.bounds.midY)
        guard distance < 3 else { throw HarnessError("中心から \(distance) pt ずれた") }
    }

    private func checkDoubleClick(session: ClientSession) async throws {
        try await Task.sleep(for: .seconds(1))
        probe.reset()
        click(probe, session: session)
        click(probe, session: session)
        try await waitUntil { self.probe.clicks.count == 2 }
        guard probe.clicks.map(\.clickCount) == [1, 2] else { throw HarnessError("クリック回数が \(probe.clicks.map(\.clickCount))") }
    }

    private func checkScroll(session: ClientSession) async throws {
        probe.reset()
        session.send(.mouseMove(normalizedPoint(of: probe)))
        session.send(.scroll(dx: 0, dy: 0.05))
        try await waitUntil { !self.probe.scrollDeltas.isEmpty }
        // 指を下へ動かしたら、iPad と同じく中身が下へ動く (上の内容が見える) 向きになること
        guard probe.scrollDeltas.reduce(0, +) > 0 else { throw HarnessError("スクロールの向きが逆 \(probe.scrollDeltas)") }
    }

    private func checkInsert(session: ClientSession, into textView: NSTextView, text: String) async throws {
        textView.string = ""
        click(textView, session: session)
        try await waitUntil { self.window.firstResponder === textView }
        session.send(.insertText(text))
        do {
            try await waitUntil { textView.string == text }
        } catch {
            throw HarnessError("欄の中身: \(textView.string.debugDescription)、変換中: \(textView.hasMarkedText())")
        }
    }

    private func checkReturnKey(session: ClientSession) async throws {
        axTextView.string = "改行"
        click(axTextView, session: session)
        try await waitUntil { self.window.firstResponder === self.axTextView }
        axTextView.setSelectedRange(NSRange(location: axTextView.string.utf16.count, length: 0))
        tapKey(usage: 0x28, modifiers: [], session: session)
        try await waitUntil { self.axTextView.string == "改行\n" }
    }

    private func checkShortcut(session: ClientSession) async throws {
        click(probe, session: session)
        try await waitUntil { self.window.firstResponder === self.probe }
        probe.reset()
        session.send(.key(usage: 0xE3, isDown: true, modifiers: [.command]))
        tapKey(usage: 0x04, modifiers: [.command], session: session)
        session.send(.key(usage: 0xE3, isDown: false, modifiers: []))
        try await waitUntil { !self.probe.keys.isEmpty }
        let key = probe.keys[0]
        guard key.keyCode == 0x00, key.modifiers == .command else { throw HarnessError("届いたキー: \(probe.keys)") }
    }

    private func tapKey(usage: Int, modifiers: KeyModifiers, session: ClientSession) {
        session.send(.key(usage: usage, isDown: true, modifiers: modifiers))
        session.send(.key(usage: usage, isDown: false, modifiers: modifiers))
    }

    private func waitUntil(timeout: Double = 3, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { throw HarnessError("\(timeout) 秒待っても条件を満たさない") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static var mainHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    // MARK: - 接続

    private static func discoverHost() async throws -> NWEndpoint {
        let hostName = Host.current().localizedName ?? ""
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: PadBridgeService.type, domain: nil), using: parameters)
        defer { browser.cancel() }
        let found = AsyncStream.makeStream(of: NWEndpoint.self)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint, name == hostName {
                    found.continuation.yield(result.endpoint)
                }
            }
        }
        browser.start(queue: .main)
        return try await withTimeout(seconds: 10) {
            for await endpoint in found.stream {
                return endpoint
            }
            throw HarnessError("見つからない")
        }
    }

    private static func expectRejected(endpoint: NWEndpoint) async throws {
        var wrong = PairingCode.generate()
        while wrong == PairingCode.generate() { wrong = PairingCode.generate() }
        let channel = MessageChannel(connection: NWConnection(to: endpoint, using: .padBridge(pairingCode: wrong)), queue: .main)
        defer { channel.cancel() }
        let states = AsyncStream.makeStream(of: NWConnection.State.self)
        channel.start(onStateChange: { states.continuation.yield($0) }, onMessage: { _ in })
        try await withTimeout(seconds: 5) {
            for await state in states.stream {
                switch state {
                case .ready: throw HarnessError("違うコードで接続できてしまった")
                case let .failed(error), let .waiting(error):
                    if case .tls = error { return }
                    throw HarnessError("TLS 以外で失敗: \(error)")
                default: continue
                }
            }
        }
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw HarnessError("\(seconds) 秒でタイムアウト")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

// MARK: - iPad 役のクライアント

@MainActor
final class ClientSession {
    let control: MessageChannel
    let video: VideoReceiver
    let status: HostStatus

    private init(control: MessageChannel, video: VideoReceiver, status: HostStatus) {
        self.control = control
        self.video = video
        self.status = status
    }

    static func connect(endpoint: NWEndpoint, code: PairingCode) async throws -> ClientSession {
        let control = MessageChannel(connection: NWConnection(to: endpoint, using: .padBridge(pairingCode: code)), queue: .main)
        let welcome = AsyncStream.makeStream(of: HostStatus.self)
        control.start(
            onStateChange: { state in
                if case .ready = state {
                    control.send(.control(.hello(role: .control, deviceName: "E2E", maxVideoWidth: 0, maxVideoHeight: 0)))
                }
            },
            onMessage: { message in
                if case let .control(.welcome(_, status)) = message { welcome.continuation.yield(status) }
            }
        )
        let status = try await withTimeout(seconds: 5) {
            for await status in welcome.stream { return status }
            throw HarnessError("welcome が来ない")
        }
        let video = VideoReceiver(endpoint: endpoint, code: code)
        return ClientSession(control: control, video: video, status: status)
    }

    func send(_ message: ControlMessage) {
        control.send(.control(message))
    }

    func close() {
        video.close()
        control.cancel()
    }
}

struct VideoStats {
    var width = 0
    var height = 0
    var decodedFrames = 0
    var averageFrameBytes = 0
}

/// 映像用の接続で届いたフレームを、iPad と同じ手順 (VideoFormat → CMSampleBuffer) で復号する。
nonisolated final class VideoReceiver: @unchecked Sendable {
    private let channel: MessageChannel
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var description: CMVideoFormatDescription?
    private var stats = VideoStats()
    private var totalBytes = 0
    private var keyFrames = 0

    init(endpoint: NWEndpoint, code: PairingCode) {
        channel = MessageChannel(connection: NWConnection(to: endpoint, using: .padBridge(pairingCode: code)), queue: DispatchQueue(label: "e2e.video"))
        channel.start(
            onStateChange: { [channel] state in
                if case .ready = state {
                    channel.send(.control(.hello(role: .video, deviceName: "", maxVideoWidth: 1280, maxVideoHeight: 800)))
                }
            },
            onMessage: { [weak self] message in self?.handle(message) }
        )
    }

    func collect(for seconds: Double) async throws -> VideoStats {
        lock.withLock {
            stats.decodedFrames = 0
            totalBytes = 0
        }
        try await Task.sleep(for: .seconds(seconds))
        return lock.withLock {
            var result = stats
            result.averageFrameBytes = stats.decodedFrames == 0 ? 0 : totalBytes / stats.decodedFrames
            return result
        }
    }

    func expectKeyFrame(after trigger: () -> Void) async throws {
        try await Task.sleep(for: .milliseconds(200))
        let before = lock.withLock { keyFrames }
        trigger()
        let deadline = Date.now.addingTimeInterval(2)
        while lock.withLock({ keyFrames }) == before {
            guard Date.now < deadline else { throw HarnessError("2 秒以内にキーフレームが来ない") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() {
        channel.cancel()
    }

    private func handle(_ message: WireMessage) {
        lock.lock()
        defer { lock.unlock() }
        switch message {
        case let .videoFormat(format):
            guard let description = try? format.makeFormatDescription() else { return }
            self.description = description
            stats.width = format.width
            stats.height = format.height
            var session: VTDecompressionSession?
            VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
            self.session = session
        case let .videoFrame(frame):
            if frame.isKeyFrame { keyFrames += 1 }
            guard let description, let session, let sampleBuffer = try? frame.makeSampleBuffer(formatDescription: description) else { return }
            var decoded = false
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
                decoded = status == noErr && imageBuffer != nil
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if decoded {
                stats.decodedFrames += 1
                totalBytes += frame.data.count
            }
        case .control:
            break
        }
    }
}

// MARK: - 確認用のビュー

final class ProbeView: NSView {
    struct Click {
        var location: CGPoint
        var clickCount: Int
    }

    var fillColor = NSColor.systemTeal {
        didSet { needsDisplay = true }
    }

    private(set) var clicks: [Click] = []
    private(set) var scrollDeltas: [CGFloat] = []
    private(set) var keys: [(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)] = []

    override var acceptsFirstResponder: Bool {
        true
    }

    // 窓が前面に来ていない状態でも、最初のクリックをそのまま受け取る
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        keys.append((event.keyCode, event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 240, height: 160)
    }

    func reset() {
        clicks.removeAll()
        scrollDeltas.removeAll()
        keys.removeAll()
    }

    override func draw(_: NSRect) {
        fillColor.setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        clicks.append(Click(location: convert(event.locationInWindow, from: nil), clickCount: event.clickCount))
    }

    override func scrollWheel(with event: NSEvent) {
        scrollDeltas.append(event.scrollingDeltaY)
    }
}

/// AX からの書き込みを成功扱いで握りつぶす欄。Electron 製アプリと同じ振る舞いを再現し、キー入力への切り替えを確かめる。
final class AXRefusingTextView: NSTextView {
    override func setAccessibilitySelectedText(_: String?) {}
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let code = PairingCode(arguments[1]), let port = NWEndpoint.Port(arguments[2]) else {
    print("使い方: e2e <ペアリングコード> <Host の待ち受けポート>")
    exit(2)
}
let app = NSApplication.shared
Task { @MainActor in
    let status = await Harness(code: code, loopbackPort: port).run()
    exit(status)
}
app.run()
