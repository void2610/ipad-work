@preconcurrency import AVFoundation
import os
import PadBridgeKit

/// バックグラウンドに移っても iPadOS にアプリを停止させないよう、接続中は他のアプリのオーディオとミックスして無音を再生し続ける。
/// 要求があれば、同じエンジンで Mac のオーディオも再生する。
final class BackgroundAudio {
    static let shared = BackgroundAudio()
    let macAudio = MacAudioPlayer()

    private static let logger = Logger(subsystem: "dev.void2610.padbridge.pad", category: "audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let silence: AVAudioPCMBuffer
    private var isRunning = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        silence.frameLength = silence.frameCapacity
        if let samples = silence.floatChannelData?[0] {
            samples.update(repeating: 0, count: Int(silence.frameLength))
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.attach(macAudio.node)
        engine.connect(macAudio.node, to: engine.mainMixerNode, format: macAudio.format)
        observeSystemEvents()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        applyCategory()
        restartEngine()
    }

    /// 動いているはずなのに停止していたら、再生し直す。
    func resumeIfNeeded() {
        guard isRunning, !engine.isRunning || !player.isPlaying else { return }
        Self.logger.notice("無音の再生が停止していたので再開する")
        applyCategory()
        restartEngine()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func applyCategory() {
        do {
            try setCategory()
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.logger.error("オーディオセッションを設定できない: \(error, privacy: .public)")
        }
    }

    private func setCategory() throws {
        // Typeless の音声入力でマイクも使うので、録音可能なカテゴリにしておく (切り替えると再生中の無音が止まるため、最初からこれにする)
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
    }

    private func restartEngine() {
        guard isRunning else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            if !player.isPlaying {
                player.scheduleBuffer(silence, at: nil, options: .loops)
                player.play()
            }
        } catch {
            Self.logger.error("無音の再生を開始できない: \(error, privacy: .public)")
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        // 電話や Siri による中断のあと、再開可能になったら再生し直す
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            MainActor.assumeIsolated {
                self?.applyCategory()
                self?.restartEngine()
            }
        })
        // オーディオ系が再構築されると、オーディオセッションの設定も消えてエンジンが停止する
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyCategory()
                self?.restartEngine()
            }
        })
        // 出力先の変更や設定の切り替えでエンジンが停止するので、その都度再起動する
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        })
    }
}
