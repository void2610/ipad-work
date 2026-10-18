@preconcurrency import AVFoundation
import os
import PadBridgeKit

/// Typeless で音声入力している間だけ iPad のマイク音声をキャプチャし、Mac へ送る。Mac 側はこれを入力デバイス「PadBridge iPad マイク」として Typeless に渡す。
final class MicrophoneStreamer {
    enum Permission {
        case granted
        case denied
    }

    private static let logger = Logger(subsystem: "dev.void2610.padbridge.pad", category: "microphone")
    private let engine = AVAudioEngine()
    private let meter = LevelMeter()
    private(set) var isRunning = false
    // 音声入力の途中でエンジンが停止したときに、同じ送信先で再開するために保持する
    private var send: (@Sendable (Data) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // AirPods の接続・取り外しなどで経路が変わるとエンジンは停止し、マイクの形式も変わる。停止したままだと、話しても Mac に無音しか届かない
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfRunning() }
        })
        // 電話や Siri による中断のあとも、終了したら再開する
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            MainActor.assumeIsolated { self?.restartIfRunning() }
        })
    }

    private func restartIfRunning() {
        guard isRunning, let send else { return }
        Self.logger.notice("マイクのエンジンが停止したので再開する")
        stop()
        start(send: send)
    }

    /// 現在の音量 (0...1)。マイクの停止中は 0。
    var level: Float {
        meter.value
    }

    /// マイクの権限を確認し、未確認ならユーザーに要求する。
    func requestPermission(_ completion: @escaping @MainActor (Permission) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(.granted)
        case .denied:
            completion(.denied)
        default:
            // 応答は別のスレッドから来るので、メインアクター上で待って受け取る
            Task { @MainActor in
                let granted = await AVAudioApplication.requestRecordPermission()
                completion(granted ? .granted : .denied)
            }
        }
    }

    /// キャプチャした音声を `send` に渡し始める。`send` はオーディオスレッドから呼ばれる。
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
            Self.logger.error("マイクを開始できない: \(error, privacy: .public)")
        }
    }

    /// マイク音声を受け取る処理。AVFAudio が独自のスレッドから呼ぶので、メインアクターに属さない場所で作る。
    /// メインアクターのメソッド内で書いたクロージャはメインアクターに属するとみなされ、別スレッドから呼ばれた時点で実行時チェックに止められる。
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

/// 音量を、マイクのスレッドで書き込み、UI 側で読み出す。
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
