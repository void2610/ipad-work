@preconcurrency import AVFAudio
import Foundation

/// マイクの音を、送るときの形 (`PadAudio`) にする。iPad のマイクと、Mac のマイクを「PadBridge iPad マイク」へ流すときに使う。
/// マイクのスレッドの中でだけ使う。
public final class PadAudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter

    public init?(from inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(PadAudio.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        self.converter = converter
    }

    /// 送る形にした音と、その中のいちばん大きな振れ幅を返す。
    public func convert(_ buffer: AVAudioPCMBuffer) -> (Data, Float)? {
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
        let converted = UnsafeBufferPointer(start: samples, count: Int(output.frameLength))
        let peak = converted.reduce(Float(0)) { max($0, abs($1)) }
        return (PadAudio.encode(converted), peak)
    }
}
