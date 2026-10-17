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
    private static let sendFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(PadAudio.sampleRate), channels: 1, interleaved: false)!
    private let engine = AVAudioEngine()
    private(set) var isRunning = false

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
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: Self.sendFormat) else {
            Self.logger.error("マイクの形式を変換できない: \(inputFormat, privacy: .public)")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: Self.tapBlock(converter: ConverterBox(converter), send: send))
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            Self.logger.error("マイクを始められない: \(error, privacy: .public)")
        }
    }

    /// マイクの音を受け取る処理。AVFAudio が自分のスレッドから呼ぶので、メインアクターに属さない場所で作る。
    /// メインアクターのメソッドの中で書いた処理はメインアクターに属するとみなされ、別のスレッドから呼ばれた時点で実行時の検査に止められる。
    private nonisolated static func tapBlock(converter: ConverterBox, send: @escaping @Sendable (Data) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let data = converter.convert(buffer) else { return }
            send(data)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// マイクのスレッドの中でだけ使う変換器。
private nonisolated final class ConverterBox: @unchecked Sendable {
    private let converter: AVAudioConverter

    init(_ converter: AVAudioConverter) {
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.floatChannelData?[0] else { return nil }
        return PadAudio.encode(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}
