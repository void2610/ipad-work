@preconcurrency import AVFoundation
import os
import PadBridgeKit

/// 裏に回っても iPadOS にアプリを止めさせないよう、接続中は他のアプリの音と混ぜて無音を流し続ける。
/// 頼まれていれば、同じエンジンで Mac の音も鳴らす。
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

    /// 動かしているはずなのに止まっていたら、流し直す。
    func resumeIfNeeded() {
        guard isRunning, !engine.isRunning || !player.isPlaying else { return }
        Self.logger.notice("無音の再生が止まっていたので流し直す")
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
        // Typeless で話すときにマイクも使うので、録音もできる種類にしておく (切り替えると流している無音が止まるため、最初からこれにする)
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
            Self.logger.error("無音の再生を始められない: \(error, privacy: .public)")
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        // 電話や Siri で止められたあと、再開できるようになったら流し直す
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            MainActor.assumeIsolated {
                self?.applyCategory()
                self?.restartEngine()
            }
        })
        // 音の仕組みが作り直されると、オーディオセッションの設定も消えてエンジンが止まる
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyCategory()
                self?.restartEngine()
            }
        })
        // 出力先の変更や設定の切り替えでエンジンが止まるので、その都度動かし直す
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        })
    }
}
