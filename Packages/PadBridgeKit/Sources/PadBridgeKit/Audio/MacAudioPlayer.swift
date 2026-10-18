@preconcurrency import AVFAudio
import Foundation

/// Mac から届いたサウンドを再生する `AVAudioSourceNode`。到着間隔のジッターで途切れないよう、少しバッファしてから再生する。
/// iPad のマイクで音声入力している間は再生せず、Mac のサウンドを Typeless に拾わせない。
public final class MacAudioPlayer: @unchecked Sendable {
    public let node: AVAudioSourceNode
    public let format = AVAudioFormat(standardFormatWithSampleRate: Double(MacAudio.sampleRate), channels: AVAudioChannelCount(MacAudio.channelCount))!
    private let state = State()
    private let decoderLock = NSLock()
    private var decoder = MacAudioDecoder()
    /// Opus をデコードできるか。できなければ、Mac に無圧縮で送ってもらう。
    public var canDecodeOpus: Bool {
        decoderLock.withLock { decoder != nil }
    }

    public init() {
        node = AVAudioSourceNode(format: format, renderBlock: Self.renderBlock(state: state))
    }

    public func feed(_ samples: Data) {
        state.lock.withLock {
            if !state.isSuppressed {
                state.buffer.write(samples)
            }
        }
    }

    /// Opus の 1 パケットをデコードして再生する。デコードは再生スレッドとは別に、受信したキューの上で行う。
    public func feedOpus(_ packet: Data) {
        guard let samples = decoderLock.withLock({ decoder?.decode(packet) }) else { return }
        feed(samples)
    }

    /// iPad のマイクを使っている間は true にする。
    public func setSuppressed(_ isSuppressed: Bool) {
        state.lock.withLock {
            state.isSuppressed = isSuppressed
            if isSuppressed {
                state.buffer.removeAll()
            }
        }
    }

    /// 再生を停止したときに、バッファしているサウンドを破棄する。
    public func reset() {
        state.lock.withLock { state.buffer.removeAll() }
        // 次に再生するときは前の音の続きではないのでデコーダも作り直すが、作れなければ前のものを使う (Mac にはもう Opus を要求していて、なくすと無音になる)
        decoderLock.withLock { decoder = MacAudioDecoder() ?? decoder }
    }

    private static func renderBlock(state: State) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2, let leftData = buffers[0].mData, let rightData = buffers[1].mData else { return noErr }
            let left = UnsafeMutableBufferPointer(start: leftData.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            let right = UnsafeMutableBufferPointer(start: rightData.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            state.lock.withLock { state.buffer.read(left: left, right: right) }
            return noErr
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        // Wi-Fi のピアツーピア通信 (awdl) は数十 ms 届かないことがあるので 100ms バッファしてから再生し、0.5 秒より遅れたら 100ms まで古い音を破棄する
        var buffer = PCMJitterBuffer(capacity: MacAudio.sampleRate / 2, startThreshold: MacAudio.sampleRate / 10, channelCount: MacAudio.channelCount, trimsOnOverflow: true)
        var isSuppressed = false
    }
}
