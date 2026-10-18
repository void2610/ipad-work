@preconcurrency import AVFAudio
import CoreAudio
import Foundation
import os
import PadBridgeKit
import Synchronization

/// Mac で再生中のサウンドをプロセスタップでキャプチャし、`MacAudio` の形式にして渡す。キャプチャ中は、Mac のスピーカーから再生しない。
/// iPad のマイク音声を再生しているヘルパーアプリの出力はキャプチャしない (iPad に送り返さない)。
nonisolated final class MacAudioCapture: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.host", category: "mac-audio")
    private static let name = "PadBridge Mac サウンド"
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let helperBundleIdentifier = "dev.void2610.padbridge.mic"

    private let queue = DispatchQueue(label: "dev.void2610.padbridge.host.mac-audio")
    // 処理待ちのコピーの数。キューが混雑したときに、オーディオスレッドがコピーを際限なく積まないように上限で破棄する (約 0.5 秒分)
    private let backlog = Atomic(0)
    private static let maxBacklog = 50
    private let send: @Sendable (Data) -> Void
    private var isRunning = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var excludedProcesses: [AudioObjectID] = []
    private var processListener: AudioObjectPropertyListenerBlock?
    private var formatListener: AudioObjectPropertyListenerBlock?
    // 20ms のチャンクにまとめてから送る
    private var pending = Data()
    private var sentChunks = 0
    // 作成に連続して失敗した回数。出力先を切り替えた直後などは一時的に作成できないことがあるので、少し待って作り直す
    private var failedBuilds = 0

    private let onGiveUp: @Sendable () -> Void

    /// `send` はキャプチャしたチャンクごとに、このクラスのキューから呼ばれる。無音の間は呼ばれない。
    /// `onGiveUp` は、何度作り直しても読み取れずに断念したときに呼ばれる。
    init(send: @escaping @Sendable (Data) -> Void, onGiveUp: @escaping @Sendable () -> Void = {}) {
        self.send = send
        self.onGiveUp = onGiveUp
    }

    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            // ヘルパーアプリは再起動するとプロセスが変わるので、そのたびに除外するプロセスを更新する
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processesChanged() }
            if AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, queue, listener) == noErr {
                processListener = listener
            }
            build()
        }
    }

    /// キャプチャを停止する。停止すると Mac のスピーカーから再生されるようになる。
    func stop() {
        queue.async { [self] in
            guard isRunning else { return }
            isRunning = false
            if let processListener {
                var address = Self.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, queue, processListener)
                self.processListener = nil
            }
            tearDown()
            Self.logger.notice("Mac のサウンドの送信を停止した (送信したチャンク \(self.sentChunks))")
        }
    }

    private func processesChanged() {
        // 作成できていない間は、ヘルパーアプリのプロセスが前と同じでも作り直す
        guard isRunning, deviceID == kAudioObjectUnknown || Self.helperProcesses() != excludedProcesses else { return }
        tearDown()
        build()
    }

    /// 出力先のデバイスが変わると、タップのフォーマット (サンプルレート) も変わる。
    private func formatChanged() {
        guard isRunning else { return }
        tearDown()
        build()
    }

    private func build() {
        let excluded = Self.helperProcesses()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = Self.name
        // 読み取っている間だけ Mac で再生させない。Host が落ちてタップが残っても、Mac のサウンドは消えない
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            Self.logger.error("Mac のサウンドのタップを作成できない")
            scheduleRebuild()
            return
        }
        guard let format = Self.format(of: tap),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(MacAudio.sampleRate), channels: AVAudioChannelCount(MacAudio.channelCount)),
              let converter = AVAudioConverter(from: format, to: outputFormat)
        else {
            Self.logger.error("Mac のサウンドのフォーマットを変換できない")
            AudioHardwareDestroyProcessTap(tap)
            scheduleRebuild()
            return
        }
        // 出力デバイスを含めず、タップだけを入力に持たせる。出力先が変わっても作り直さずに済む
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr, device != kAudioObjectUnknown else {
            Self.logger.error("Mac のサウンドの機器セットを作成できない")
            AudioHardwareDestroyProcessTap(tap)
            scheduleRebuild()
            return
        }
        var procID: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { [weak self, queue] _, inputData, _, _, _ in
            // 入力バッファの中身はコールバック中しか使えないのでコピーし、変換はオーディオスレッドの外で行う
            guard let self, backlog.load(ordering: .relaxed) < Self.maxBacklog, let copy = Self.copy(inputData, format: format) else { return }
            backlog.add(1, ordering: .relaxed)
            queue.async {
                self.process(copy)
                self.backlog.subtract(1, ordering: .relaxed)
            }
        }
        guard let procID, AudioDeviceStart(device, procID) == noErr else {
            Self.logger.error("Mac のサウンドの読み取りを開始できない")
            if let procID { AudioDeviceDestroyIOProcID(device, procID) }
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(tap)
            scheduleRebuild()
            return
        }
        failedBuilds = 0
        tapID = tap
        deviceID = device
        self.procID = procID
        self.converter = converter
        excludedProcesses = excluded
        pending.removeAll()
        var formatAddress = Self.address(kAudioTapPropertyFormat)
        let formatListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.formatChanged() }
        if AudioObjectAddPropertyListenerBlock(tap, &formatAddress, queue, formatListener) == noErr {
            self.formatListener = formatListener
        }
        Self.logger.notice("Mac のサウンドの送信を開始した: \(format, privacy: .public)、除外したプロセス \(excluded.count)")
    }

    /// 作成に失敗したときに、少し待って作り直す。作成できないまま iPad に何も届かず、Mac のスピーカーも鳴らない状態を残さない。
    private func scheduleRebuild() {
        failedBuilds += 1
        guard failedBuilds <= 5 else {
            Self.logger.error("Mac のサウンドの読み取りが何度作り直しても成功しない")
            // キャプチャしていないので Mac のスピーカーは再生中。「再生中」と表示したままにならないよう通知する
            onGiveUp()
            return
        }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, isRunning, deviceID == kAudioObjectUnknown else { return }
            build()
        }
    }

    private func tearDown() {
        if let procID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            if let formatListener {
                var address = Self.address(kAudioTapPropertyFormat)
                AudioObjectRemovePropertyListenerBlock(tapID, &address, queue, formatListener)
            }
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        formatListener = nil
        converter = nil
        pending.removeAll()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let converter, buffer.format == converter.inputFormat else { return }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        // 入力ブロックは convert の中で同じスレッドから呼ばれる
        nonisolated(unsafe) var consumed = false
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
        guard error == nil, output.frameLength > 0, let channels = output.floatChannelData else { return }
        let frames = Int(output.frameLength)
        pending.append(MacAudio.encode(left: UnsafeBufferPointer(start: channels[0], count: frames), right: UnsafeBufferPointer(start: channels[1], count: frames)))
        let chunkBytes = MacAudio.chunkFrames * MacAudio.channelCount * 2
        while pending.count >= chunkBytes {
            let chunk = Data(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
            guard !MacAudio.isSilent(chunk) else { continue }
            sentChunks += 1
            if sentChunks == 1 {
                Self.logger.notice("Mac のサウンドの最初のチャンクを送信した")
            }
            send(chunk)
        }
    }

    // MARK: - CoreAudio

    private static func copy(_ inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = source.first, first.mDataByteSize > 0, format.streamDescription.pointee.mBytesPerFrame > 0 else { return nil }
        let frames = first.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        copy.frameLength = frames
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    private static func format(of tap: AudioObjectID) -> AVAudioFormat? {
        var address = address(kAudioTapPropertyFormat)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &description)
    }

    /// ヘルパーアプリのプロセスのオーディオオブジェクト。再生を開始するまでは現れない。
    private static func helperProcesses() -> [AudioObjectID] {
        processObjects().filter { bundleIdentifier(of: $0) == helperBundleIdentifier }.sorted()
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func bundleIdentifier(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var identifier: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &identifier) == noErr else { return nil }
        return identifier?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
