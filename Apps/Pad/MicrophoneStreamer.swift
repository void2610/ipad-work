@preconcurrency import AVFoundation
import os
import PadBridgeKit

/// Typeless で話している間だけ iPad のマイクの音を取り、Mac へ送る。Mac 側はこれを入力デバイス「PadBridge iPad マイク」として Typeless に渡す。
final class MicrophoneStreamer {
    enum Permission {
        case granted
        case denied
    }

    private static let logger = Logger(subsystem: "dev.void2610.padbridge.pad", category: "microphone")
    private let engine = AVAudioEngine()
    private let meter = LevelMeter()
    private(set) var isRunning = false
    // 話している途中でエンジンが止まったときに、同じ送り先で始め直すために覚える
    private var send: (@Sendable (Data) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // AirPods をつなぐ・外すなどで経路が変わるとエンジンは止まり、マイクの形式も変わる。止まったままだと、話しても Mac に無音しか届かない
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfRunning() }
        })
        // 電話や Siri で止められたあとも、終わったら始め直す
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            MainActor.assumeIsolated { self?.restartIfRunning() }
        })
    }

    private func restartIfRunning() {
        guard isRunning, let send else { return }
        Self.logger.notice("マイクのエンジンが止まったので始め直す")
        stop()
        start(send: send)
    }

    /// 今の声の大きさ (0...1)。マイクを止めている間は 0。
    var level: Float {
        meter.value
    }

    /// マイクの許可を確かめ、まだ尋ねていなければ尋ねる。
    func requestPermission(_ completion: @escaping @MainActor (Permission) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(.granted)
        case .denied:
            completion(.denied)
        default:
            // 返事は別のスレッドから来るので、メインアクターの上で待って受け取る
            Task { @MainActor in
                let granted = await AVAudioApplication.requestRecordPermission()
                completion(granted ? .granted : .denied)
            }
        }
    }

    /// 取った音を `send` に渡し始める。`send` はオーディオのスレッドから呼ばれる。
    func start(send: @escaping @Sendable (Data) -> Void) {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = PadAudioConverter(from: inputFormat) else {
            Self.logger.error("マイクの形式を変換できない: \(inputFormat, privacy: .public)")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: Self.tapBlock(converter: converter, meter: meter, send: send))
        do {
            try engine.start()
            isRunning = true
            self.send = send
        } catch {
            input.removeTap(onBus: 0)
            Self.logger.error("マイクを始められない: \(error, privacy: .public)")
        }
    }

    /// マイクの音を受け取る処理。AVFAudio が自分のスレッドから呼ぶので、メインアクターに属さない場所で作る。
    /// メインアクターのメソッドの中で書いた処理はメインアクターに属するとみなされ、別のスレッドから呼ばれた時点で実行時の検査に止められる。
    private nonisolated static func tapBlock(converter: PadAudioConverter, meter: LevelMeter, send: @escaping @Sendable (Data) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let (data, peak) = converter.convert(buffer) else { return }
            meter.update(peak: peak)
            send(data)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        send = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        meter.reset()
    }
}

/// 声の大きさを、マイクのスレッドで書き込み、画面の側で読み出す。
private nonisolated final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0

    var value: Float {
        lock.withLock { level }
    }

    func update(peak: Float) {
        let value = PadAudio.level(peak: peak)
        lock.withLock { level = value }
    }

    func reset() {
        lock.withLock { level = 0 }
    }
}
