@preconcurrency import AVFAudio
import Foundation

/// Mac から届いた音を鳴らす `AVAudioSourceNode`。届く間隔の揺れで途切れないよう、少したまってから鳴らす。
/// iPad のマイクで聞き取っている間は鳴らさず、Mac の音を Typeless に拾わせない。
public final class MacAudioPlayer: @unchecked Sendable {
    public let node: AVAudioSourceNode
    public let format = AVAudioFormat(standardFormatWithSampleRate: Double(MacAudio.sampleRate), channels: AVAudioChannelCount(MacAudio.channelCount))!
    private let state = State()

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

    /// iPad のマイクを使っている間は true にする。
    public func setSuppressed(_ isSuppressed: Bool) {
        state.lock.withLock {
            state.isSuppressed = isSuppressed
            if isSuppressed {
                state.buffer.removeAll()
            }
        }
    }

    /// 鳴らすのをやめたときに、ためている音を捨てる。
    public func reset() {
        state.lock.withLock { state.buffer.removeAll() }
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
        // Wi-Fi の直接通信 (awdl) は数十 ms 届かないことがあるので 100ms たまってから鳴らし、0.5 秒より遅れたら 100ms まで古い音を捨てる
        var buffer = PCMJitterBuffer(capacity: MacAudio.sampleRate / 2, startThreshold: MacAudio.sampleRate / 10, channelCount: MacAudio.channelCount, trimsOnOverflow: true)
        var isSuppressed = false
    }
}
