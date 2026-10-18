import AVFoundation
import CoreAudio
import os
import PadBridgeKit

/// iPad のマイクの音を、iPad がつながっている間だけ Mac の入力デバイス「PadBridge iPad マイク」として見せる。
/// Mac は蓋を閉じると内蔵マイクをハードウェアで切り離すので、閉じたままでも Mac の Typeless で話せるようにするため。
/// 届いた音を自分で鳴らし、その出力をプロセスタップで取り出して集約デバイスの入力にする。タップが出力をミュートするので、スピーカーからは鳴らない。
/// Typeless にはこのデバイスを選ばせているので、iPad から話していない間に読まれたら Mac の既定の入力の音を流し、Mac で直接話しても聞き取れるようにする。
nonisolated final class PadMicrophone: @unchecked Sendable {
    static let deviceName = "PadBridge iPad マイク"
    private static let deviceUID = "dev.void2610.padbridge.ipad-mic"
    private static let logger = Logger(subsystem: "dev.void2610.padbridge.mic", category: "microphone")
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    // デバイスの作成や確認は時間がかかるので、通信のキューとは分ける
    private let queue = DispatchQueue(label: "dev.void2610.padbridge.host.microphone")
    private let onAuthorizationChange: @Sendable (Bool) -> Void
    private let engine = AVAudioEngine()
    private let renderLock = NSLock()
    // iPad の音は 100ms ごとの塊で届く (AVAudioNode のタップは 100〜400ms ごとに渡す) ので、塊の揺れを吸収できるよう 150ms たまってから鳴らす。
    // Typeless が読み始めるまでは鳴らさずにためておき、話し始めを落とさない。Typeless は前の聞き取りを貼り付け終えるまで数秒始まらないことがあるので、6 秒までためる
    private var buffer = PCMJitterBuffer(capacity: PadAudio.sampleRate * 6, startThreshold: PadAudio.sampleRate * 15 / 100)
    // 止める直前の声は、iPad のタップの塊に入って止めた知らせより最大 100ms ほど遅れて届くので、その分を待つ
    private static let inFlightDelay: TimeInterval = 0.2
    // 鳴らした音が、タップと集約デバイスを通って Typeless に届くまでの分
    private static let deliveryDelay: TimeInterval = 0.05
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    // iPad から聞き取りを始めている間 (許可を確かめたあと) だけ、届いた音を鳴らす。それ以外は、Mac のマイクの音を流していなければ無音を流し続ける。
    // 止めるとタップだけの集約デバイスは入力を持たなくなり、Typeless (Chromium) がマイクとして数えない。
    // 許可がないとタップのミュートが効かないが、そのときは無音しか流さないので何も聞こえない
    private var isListening = false
    // ほかのアプリ (Typeless) がこのデバイスを読んでいるか。読まれていない間に鳴らした音は誰にも届かない
    private var isRead = false
    private var listeningBeganAt: TimeInterval = 0
    // iPad から聞き取りを始めてから Typeless が読み始めるまでの秒数。話し始めをためておく長さの目安として記録に出す
    private var readDelay: TimeInterval?
    // 聞き取りの間に iPad から届いた音のバイト数。届いていないのか Typeless が読めていないのかを見分けるために記録に出す
    private var receivedBytes = 0
    // 経路の点検のときだけ鳴らす、聞こえない高さの小さな音の位相。点検していないときは nil
    private var checkPhase: Double?
    // 聞き取りの間に鳴らした音の最大の振れ幅。どこで音が消えたかを記録に出して見分ける
    private var playedPeak: Float = 0
    // 許可がないとタップのミュートが効かず、iPad の声が Mac のスピーカーから流れてしまう。確かめるまでは鳴らさない
    private var isAuthorized = false
    private let authorizationLock = NSLock()
    private var reportedAuthorization: Bool?
    // iPad から話していない間に読まれているときだけ、Mac の既定の入力の音をこのデバイスに流す
    private var isPassingThrough = false
    private var passThroughEngine: AVAudioEngine?
    // Mac のマイクの音は同じ Mac の中で約 10ms ごとに届き、揺れが小さいので、少しだけためて鳴らす。Typeless が止めたときに切れる話し終わりを短くする
    private var passThroughBuffer = PCMJitterBuffer(capacity: PadAudio.sampleRate / 2, startThreshold: PadAudio.sampleRate * 3 / 100)
    private var passThroughGate = PassThroughGate()
    private var readingListener: AudioObjectPropertyListenerBlock?
    private var configurationObserver: (any NSObjectProtocol)?

    /// `onAuthorizationChange` は、システムオーディオの録音の許可があるかが分かるたび (変わったときだけ) に呼ばれる。
    init(onAuthorizationChange: @escaping @Sendable (Bool) -> Void) {
        self.onAuthorizationChange = onAuthorizationChange
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(PadAudio.sampleRate), channels: 1)!
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            guard let data = UnsafeMutableAudioBufferListPointer(bufferList).first?.mData else { return noErr }
            let output = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            if let self {
                renderLock.withLock {
                    if var phase = checkPhase {
                        // 経路の点検の音。タップがミュートするので鳴らないが、万一のときもほとんどの人に聞こえない高さと大きさにする
                        for index in output.indices {
                            output[index] = Float(sin(phase)) * 0.01
                            phase += 2 * Double.pi * 20_000 / Double(PadAudio.sampleRate)
                        }
                        checkPhase = phase.truncatingRemainder(dividingBy: 2 * .pi)
                    } else if isRead, isPassingThrough {
                        passThroughBuffer.read(into: output)
                    } else if isRead, isListening {
                        buffer.read(into: output)
                        playedPeak = output.reduce(playedPeak) { max($0, abs($1)) }
                    } else {
                        output.update(repeating: 0)
                    }
                }
            } else {
                output.update(repeating: 0)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        // 既定の出力の機器が変わり、チャンネル数やサンプルレートが変わると、エンジンは自分で止まる。止まったままだとタップが無音になり、iPad で話しても Typeless に何も届かない
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.restartEngineAfterConfigurationChange() }
        }
    }

    private func restartEngineAfterConfigurationChange() {
        guard deviceID != kAudioObjectUnknown, !engine.isRunning else { return }
        do {
            try engine.start()
            Self.logger.notice("出力の機器が変わって止まった、音を鳴らすエンジンを動かし直した")
        } catch {
            Self.logger.error("出力の機器が変わったあと、音を鳴らすエンジンを動かし直せない: \(error, privacy: .public)")
        }
    }

    /// 許可がないと分かっているか。まだ確かめていなければ false。
    var isKnownUnauthorized: Bool {
        authorizationLock.withLock { reportedAuthorization == false }
    }

    /// デバイスを作り、許可があるかを確かめる。Host につながったときに呼ぶ。
    func start() {
        queue.async { [self] in
            Self.removeLeftovers()
            createDevice()
            checkAuthorization()
            // 話している最中にダイアログが出ないよう、つながったときに尋ねておく
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Self.logger.notice("PadBridge Host のマイクの許可: \(granted ? "あり" : "なし", privacy: .public)")
                }
            }
        }
    }

    /// デバイスを消す。Host との接続が切れたときに呼ぶ。消し終えるまで待つ (このあとすぐ終わっても Mac に残らないように)。
    func stop() {
        queue.sync { [self] in
            engine.stop()
            destroyDevice()
        }
    }

    /// iPad から聞き取りを始めるときに呼ぶ。iPad の声をこのデバイスに流せるかを `ready` に渡す。
    /// このデバイスは Mac の既定の入力になれない (タップだけの集約デバイスは CanBeDefaultDevice が 0) ので、
    /// Typeless のマイクの設定でこのデバイスを選ぶ (Host が一度だけ自動で行う)。既定の入力は切り替えない。
    func beginListening(ready: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            if !isAuthorized {
                // システム設定であとから許可された場合に気づけるよう、その都度確かめ直す
                setAuthorized(AudioCapturePermission.current() == .authorized)
            }
            let isUsingPadMicrophone = isAuthorized && deviceID != kAudioObjectUnknown
            defer { ready(isUsingPadMicrophone) }
            guard isUsingPadMicrophone else { return }
            stopPassThrough()
            passThroughGate.padListeningBegan()
            let isAlreadyRead = renderLock.withLock {
                // 止めた直後にまた始めたときは、Typeless が聞き取りを続けているので、まだ鳴らしていない声を捨てない
                if !isListening {
                    buffer.removeAll()
                    receivedBytes = 0
                    playedPeak = 0
                }
                isListening = true
                return isRead
            }
            listeningBeganAt = ProcessInfo.processInfo.systemUptime
            readDelay = isAlreadyRead ? 0 : nil
        }
    }

    /// iPad で止めたときに呼ぶ。止めたところまでの声を流し終えたら `done` を呼ぶ。そのあとで Typeless を止めれば、話し終わりが切れない。
    func finishListening(done: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + Self.inFlightDelay) { [self] in
            // iPad はもう送ってこないので、鳴らし始めのたまり具合に届いていなくても残りを鳴らす。待つと話し終わりが鳴らないまま、7 秒の時間切れまで Typeless が聞き取り続ける
            let target = renderLock.withLock {
                buffer.playRemaining()
                return buffer.written
            }
            waitUntilPlayed(target, deadline: .now() + 7, done: done)
        }
    }

    private func waitUntilPlayed(_ target: Int, deadline: DispatchTime, done: @escaping @Sendable () -> Void) {
        let (remaining, isPlaying) = renderLock.withLock { (target - buffer.consumed, isListening && isRead) }
        // 読まれていなければ、待っても流れない (Typeless が自分で止めたときなど)
        guard remaining > 0, isPlaying, DispatchTime.now() < deadline else {
            queue.asyncAfter(deadline: .now() + Self.deliveryDelay) { done() }
            return
        }
        let seconds = Double(remaining) / Double(PadAudio.sampleRate)
        queue.asyncAfter(deadline: .now() + max(seconds, 0.01)) { [self] in
            waitUntilPlayed(target, deadline: deadline, done: done)
        }
    }

    /// 聞き取りが終わったら、届いた音を鳴らすのをやめる。
    func endListening() {
        queue.async { [self] in
            let (wasListening, received, played, underruns) = renderLock.withLock {
                defer {
                    isListening = false
                    buffer.removeAll()
                }
                return (isListening, receivedBytes, playedPeak, buffer.underruns)
            }
            if wasListening {
                let seconds = Double(received) / 2 / Double(PadAudio.sampleRate)
                let wait = readDelay.map { String(format: "%.2f 秒", $0) } ?? "読まれなかった"
                Self.logger.notice("iPad から届いた音: \(String(format: "%.1f", seconds), privacy: .public) 秒分、Typeless が読み始めるまで \(wait, privacy: .public)、鳴らした音の最大 \(String(format: "%.4f", played), privacy: .public)、途切れた回数 \(underruns)")
            }
            deviceReadingChanged()
        }
    }

    func feed(_ samples: Data) {
        renderLock.withLock {
            if isListening {
                buffer.write(samples)
                receivedBytes += samples.count
            }
        }
    }

    /// 前に Host が落ちて残ったデバイスとタップを消す。作ったプロセスが終わっても、HAL からは消えないため。
    static func removeLeftovers() {
        if let device = device(uid: deviceUID) {
            AudioHardwareDestroyAggregateDevice(device)
            logger.notice("前に残った \(deviceName, privacy: .public) を消した")
        }
        for tap in objects(kAudioHardwarePropertyTapList) where tapName(tap) == deviceName {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    // MARK: - デバイス

    /// 自分の出力をタップが本当に運んでいるかを、点検専用の非公開の集約デバイスで確かめて記録に出す。
    /// 「PadBridge iPad マイク」を自分で読むにはマイクの許可も要るが、非公開の集約デバイスならシステムオーディオの録音の許可だけで読める。
    /// 出力デバイスを含める形と、「PadBridge iPad マイク」と同じタップだけの形の両方で測り、違いがあるかを見る。
    private func checkTapCarriesSound() {
        for includesOutput in [true, false] {
            let peak = measureTap(includingOutputDevice: includesOutput)
            Self.logger.notice("タップの点検 (出力デバイスを\(includesOutput ? "含む" : "含まない", privacy: .public)): 最大 \(peak.map { String(format: "%.4f", $0) } ?? "測れない", privacy: .public) (鳴らした音は 0.0100)")
        }
        // Typeless が読むのと同じ「PadBridge iPad マイク」そのものも測る。読むにはマイクの許可も要る
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, deviceID != kAudioObjectUnknown else { return }
        let peak = PeakMeter()
        var procID: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, inputData, _, _, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)) {
                guard let data = buffer.mData else { continue }
                peak.add(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
            }
        }
        guard let procID else { return }
        renderLock.withLock { checkPhase = 0 }
        let started = AudioDeviceStart(deviceID, procID)
        Thread.sleep(forTimeInterval: 0.5)
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        renderLock.withLock { checkPhase = nil }
        Self.logger.notice("\(Self.deviceName, privacy: .public) の点検: 開始=\(started) 最大 \(String(format: "%.4f", peak.value), privacy: .public) (鳴らした音は 0.0100)")
    }

    private func measureTap(includingOutputDevice: Bool) -> Float? {
        let process = Self.ownProcessObject()
        guard process != kAudioObjectUnknown, let output = Self.defaultOutputDevice(), let outputUID = Self.uid(of: output) else { return nil }
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "\(Self.deviceName) の点検"
        description.muteBehavior = .muted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        defer { AudioHardwareDestroyProcessTap(tap) }
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(Self.deviceName) の点検",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        if includingOutputDevice {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else { return nil }
        defer { AudioHardwareDestroyAggregateDevice(device) }
        let peak = PeakMeter()
        var procID: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, inputData, _, _, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)) {
                guard let data = buffer.mData else { continue }
                peak.add(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
            }
        }
        guard let procID else { return nil }
        renderLock.withLock { checkPhase = 0 }
        AudioDeviceStart(device, procID)
        Thread.sleep(forTimeInterval: 0.5)
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        renderLock.withLock { checkPhase = nil }
        return peak.value
    }

    private func createDevice() {
        guard deviceID == kAudioObjectUnknown else { return }
        do {
            try engine.start()
        } catch {
            Self.logger.error("音を鳴らすエンジンを動かせない: \(error, privacy: .public)")
            return
        }
        // タップで取り出すには自分のプロセスのオブジェクトが要る。出力を始めてから HAL に現れるまで少し待つ
        var process = AudioObjectID(kAudioObjectUnknown)
        for _ in 0 ..< 20 {
            process = Self.ownProcessObject()
            if process != kAudioObjectUnknown { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // 出力を止めたままタップを作ると、タップだけの集約デバイスは入力を持たないまま固まる。無音を流したままにする
        guard process != kAudioObjectUnknown else {
            Self.logger.error("自分のプロセスのオーディオオブジェクトが見つからない")
            return
        }
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [process])
        tapDescription.uuid = UUID()
        tapDescription.name = Self.deviceName
        tapDescription.muteBehavior = .muted
        // 既定の非公開のタップは作ったプロセスにしか見えず、ほかのアプリからは集約デバイスに入力がないように見える
        tapDescription.isPrivate = false
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDescription, &tap) == noErr, tap != kAudioObjectUnknown else {
            Self.logger.error("プロセスタップを作れない")
            return
        }
        // 出力のサブデバイスを入れると出力デバイスとしても一覧に出てしまうので、タップだけの入力デバイスにする
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.deviceName,
            kAudioAggregateDeviceUIDKey: Self.deviceUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr, device != kAudioObjectUnknown else {
            Self.logger.error("集約デバイスを作れない")
            AudioHardwareDestroyProcessTap(tap)
            return
        }
        tapID = tap
        deviceID = device
        Self.logger.notice("\(Self.deviceName, privacy: .public) を作った")
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.deviceReadingChanged() }
        if AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr {
            readingListener = listener
        }
    }

    private func destroyDevice() {
        stopPassThrough()
        if let readingListener, deviceID != kAudioObjectUnknown {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, readingListener)
            self.readingListener = nil
        }
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - Mac のマイクの音を流す

    /// このデバイスが読まれ始めたか、読まれなくなった。読まれ始めた通知はすぐ届く。
    /// 自分で読むのは点検 (キューを占めたまま終える) のときだけなので、それ以外で読まれていればほかのアプリ (Typeless) が読んでいる。
    /// iPad から話していない間に読まれていれば、Mac の既定の入力の音を流す。
    private func deviceReadingChanged() {
        let isRead = deviceID != kAudioObjectUnknown && Self.isRunningSomewhere(deviceID)
        let isListening = renderLock.withLock {
            self.isRead = isRead
            return self.isListening
        }
        if isRead, isListening, readDelay == nil {
            readDelay = ProcessInfo.processInfo.systemUptime - listeningBeganAt
        }
        if passThroughGate.shouldPassThrough(isRead: isRead, isPadListening: isListening) {
            startPassThrough()
        } else {
            stopPassThrough()
        }
    }

    private func startPassThrough() {
        guard passThroughEngine == nil else { return }
        // 録音の許可がないとタップのミュートが効かず、Mac のマイクの音がそのままスピーカーから流れてしまう
        guard isAuthorized, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Self.logger.notice("\(Self.deviceName, privacy: .public) が読まれたが、許可がないので Mac のマイクの音を流さない")
            return
        }
        // 鳴らしている方のエンジンで入力を使うと出力が組み直されて途切れるので、取り込みは別のエンジンで行う
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard let converter = PadAudioConverter(from: format) else {
            Self.logger.notice("\(Self.deviceName, privacy: .public) が読まれたが、Mac に使えるマイクがない")
            return
        }
        // タップは 100ms ごとにしか音を渡さない。シンクなら入力の 1 回ごと (この Mac では 512 フレーム、約 10ms) に受け取れる
        let isSendFormat = format.sampleRate == Double(PadAudio.sampleRate) && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
        let sink = AVAudioSinkNode { [weak self] _, frameCount, inputData in
            guard let self else { return noErr }
            if isSendFormat, let data = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)).first?.mData {
                // Mac のマイクは送る形と同じ 48kHz のことが多いので、そのときは変換せず先頭のチャンネルを流す
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
                renderLock.withLock {
                    if isPassingThrough {
                        passThroughBuffer.write(samples)
                    }
                }
            } else if let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData), let (samples, _) = converter.convert(buffer) {
                renderLock.withLock {
                    if isPassingThrough {
                        passThroughBuffer.write(samples)
                    }
                }
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: format)
        renderLock.withLock {
            passThroughBuffer.removeAll()
            isPassingThrough = true
        }
        do {
            try engine.start()
        } catch {
            renderLock.withLock { isPassingThrough = false }
            Self.logger.error("Mac のマイクを始められない: \(error, privacy: .public)")
            return
        }
        passThroughEngine = engine
        Self.logger.notice("iPad から話していない間に読まれたので、Mac のマイクの音を流す")
    }

    private func stopPassThrough() {
        guard let engine = passThroughEngine else { return }
        passThroughEngine = nil
        engine.stop()
        renderLock.withLock {
            isPassingThrough = false
            passThroughBuffer.removeAll()
        }
        Self.logger.notice("Mac のマイクの音を流すのをやめた")
    }

    /// システムオーディオの録音の許可を確かめ、まだ尋ねていなければ尋ねる。
    private func checkAuthorization() {
        switch AudioCapturePermission.current() {
        case .authorized:
            setAuthorized(true)
        case .denied:
            setAuthorized(false)
        case .undetermined:
            setAuthorized(false)
            AudioCapturePermission.request { [weak self] granted in
                guard let self else { return }
                queue.async { self.setAuthorized(granted) }
            }
        }
        checkAuthorizationLater()
    }

    /// システム設定で許可されたらすぐに iPad の知らせを消せるよう、許可がない間は確かめ続ける。
    private func checkAuthorizationLater() {
        guard !isAuthorized else { return }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, deviceID != kAudioObjectUnknown, !isAuthorized else { return }
            setAuthorized(AudioCapturePermission.current() == .authorized)
            checkAuthorizationLater()
        }
    }

    private func setAuthorized(_ authorized: Bool) {
        let becameAuthorized = authorized && !isAuthorized
        isAuthorized = authorized
        if becameAuthorized {
            checkTapCarriesSound()
        }
        let changed = authorizationLock.withLock {
            defer { reportedAuthorization = authorized }
            return reportedAuthorization != authorized
        }
        if changed {
            Self.logger.notice("システムオーディオの録音の許可: \(authorized ? "あり" : "なし", privacy: .public)")
            onAuthorizationChange(authorized)
        }
    }

    // MARK: - CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &isRunning) == noErr else { return false }
        return isRunning != 0
    }

    private static func ownProcessObject() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        return process
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func tapName(_ tap: AudioObjectID) -> String? {
        var address = address(kAudioTapPropertyDescription)
        var description: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description) == noErr else { return nil }
        return description?.takeRetainedValue().name
    }

    private static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}

/// システムオーディオの録音の許可。公開の API がないので、AudioCap などと同じく TCC の関数を直接呼ぶ。
/// 画面を持たない補助アプリでは Core Audio が許可の有無を確かめるだけで尋ねないため、こちらから尋ねる。
private nonisolated enum AudioCapturePermission {
    enum Status {
        case authorized
        case denied
        case undetermined
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let serviceName = "kTCCServiceAudioCapture"
    // dlopen は同じライブラリなら同じハンドルを返すので、呼ぶたびに開いてよい
    private static var framework: UnsafeMutableRawPointer? {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }

    static func current() -> Status {
        guard let symbol = dlsym(framework, "TCCAccessPreflight") else { return .undetermined }
        switch unsafeBitCast(symbol, to: Preflight.self)(serviceName as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let symbol = dlsym(framework, "TCCAccessRequest") else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: Request.self)(serviceName as CFString, nil) { granted in completion(granted) }
    }
}

/// 入力の最大の振れ幅を、オーディオのスレッドから受け取って記録する。
private nonisolated final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    var value: Float {
        lock.withLock { peak }
    }

    func add(_ samples: UnsafeBufferPointer<Float>) {
        let local = samples.reduce(Float(0)) { max($0, abs($1)) }
        lock.withLock { peak = max(peak, local) }
    }

    func reset() {
        lock.withLock { peak = 0 }
    }
}
