import AVFoundation
import CoreAudio
import os
import PadBridgeKit

/// iPad のマイク音声を、iPad が接続されている間だけ Mac の入力デバイス「PadBridge iPad マイク」として見せる。
/// Mac は蓋を閉じると内蔵マイクをハードウェアで切り離すので、閉じたままでも Mac の Typeless で話せるようにするため。
/// 届いた音声を自分で再生し、その出力をプロセスタップでキャプチャして機器セットの入力にする。タップが出力をミュートするので、スピーカーからは再生されない。
/// Typeless にはこのデバイスを選択させているので、iPad から話していない間に読み取られたら Mac の既定の入力の音声を流し、Mac で直接話しても音声入力できるようにする。
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
    // iPad の音声は 100ms ごとのチャンクで届く (AVAudioNode のタップは 100〜400ms ごとに渡す) ので、チャンクのジッターを吸収できるよう 150ms 分バッファしてから再生する。
    // Typeless が読み取りを始めるまでは再生せずにバッファしておき、話し始めを欠けさせない。Typeless は前の音声入力を貼り付け終えるまで数秒開始しないことがあるので、6 秒までバッファする
    private var buffer = PCMJitterBuffer(capacity: PadAudio.sampleRate * 6, startThreshold: PadAudio.sampleRate * 15 / 100)
    // 停止直前の音声は、iPad のタップのチャンクに入って停止通知より最大 100ms ほど遅れて届くので、その分を待つ
    private static let inFlightDelay: TimeInterval = 0.2
    // 再生した音声が、タップと機器セットを通って Typeless に届くまでの分
    private static let deliveryDelay: TimeInterval = 0.05
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    // iPad から音声入力を開始している間 (許可を確認したあと) だけ、届いた音声を再生する。それ以外は、Mac のマイクの音声を流していなければ無音を流し続ける。
    // 停止するとタップのみの機器セットは入力を持たなくなり、Typeless (Chromium) がマイクとして認識しない。
    // 許可がないとタップのミュートが効かないが、そのときは無音しか流さないので何も聞こえない
    private var isListening = false
    // ほかのアプリ (Typeless) がこのデバイスを読み取っているか。読み取られていない間に再生した音声は誰にも届かない
    private var isRead = false
    private var listeningBeganAt: TimeInterval = 0
    // iPad から音声入力を開始してから Typeless が読み取りを始めるまでの秒数。話し始めをバッファする長さの目安としてログに出す
    private var readDelay: TimeInterval?
    // 音声入力の間に iPad から届いた音声のバイト数。届いていないのか Typeless が読み取れていないのかを判別するためにログに出す
    private var receivedBytes = 0
    // 経路のチェックのときだけ再生する、聞こえない高さの小さな音の位相。チェックしていないときは nil
    private var checkPhase: Double?
    // 音声入力の間に再生した音声の最大振幅。どこで音声が消えたかを判別するためにログに出す
    private var playedPeak: Float = 0
    // 許可がないとタップのミュートが効かず、iPad の音声が Mac のスピーカーから流れてしまう。確認するまでは再生しない
    private var isAuthorized = false
    private let authorizationLock = NSLock()
    private var reportedAuthorization: Bool?
    // iPad から話していない間に読み取られているときだけ、Mac の既定の入力の音声をこのデバイスに流す
    private var isPassingThrough = false
    private var passThroughEngine: AVAudioEngine?
    // Mac のマイクの音声は同じ Mac の中で約 10ms ごとに届き、ジッターが小さいので、少しだけバッファして再生する。Typeless が停止したときに切れる話し終わりを短くする
    private var passThroughBuffer = PCMJitterBuffer(capacity: PadAudio.sampleRate / 2, startThreshold: PadAudio.sampleRate * 3 / 100)
    private var passThroughGate = PassThroughGate()
    private var readingListener: AudioObjectPropertyListenerBlock?
    private var configurationObserver: (any NSObjectProtocol)?

    /// `onAuthorizationChange` は、システムオーディオ録音の許可の有無が判明するたび (変わったときだけ) に呼ばれる。
    init(onAuthorizationChange: @escaping @Sendable (Bool) -> Void) {
        self.onAuthorizationChange = onAuthorizationChange
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(PadAudio.sampleRate), channels: 1)!
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            guard let data = UnsafeMutableAudioBufferListPointer(bufferList).first?.mData else { return noErr }
            let output = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            if let self {
                renderLock.withLock {
                    if var phase = checkPhase {
                        // 経路のチェック用の音。タップがミュートするので再生されないが、万一のときもほとんどの人に聞こえない高さと大きさにする
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
        // 既定の出力デバイスが変わり、チャンネル数やサンプルレートが変わると、エンジンは自動で停止する。停止したままだとタップが無音になり、iPad で話しても Typeless に何も届かない
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.restartEngineAfterConfigurationChange() }
        }
    }

    private func restartEngineAfterConfigurationChange() {
        guard deviceID != kAudioObjectUnknown, !engine.isRunning else { return }
        do {
            try engine.start()
            Self.logger.notice("出力デバイスが変わって停止した、再生用エンジンを再起動した")
        } catch {
            Self.logger.error("出力デバイスが変わったあと、再生用エンジンを再起動できない: \(error, privacy: .public)")
        }
    }

    /// 許可がないと判明しているか。まだ確認していなければ false。
    var isKnownUnauthorized: Bool {
        authorizationLock.withLock { reportedAuthorization == false }
    }

    /// デバイスを作成し、許可があるかを確認する。Host に接続したときに呼ぶ。
    func start() {
        queue.async { [self] in
            Self.removeLeftovers()
            createDevice()
            checkAuthorization()
            // 話している最中にダイアログが出ないよう、接続したときに確認しておく
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Self.logger.notice("PadBridge Host のマイクの許可: \(granted ? "あり" : "なし", privacy: .public)")
                }
            }
        }
    }

    /// デバイスを削除する。Host との接続が切れたときに呼ぶ。削除が完了するまで待つ (このあとすぐ終了しても Mac に残らないように)。
    func stop() {
        queue.sync { [self] in
            engine.stop()
            destroyDevice()
        }
    }

    /// iPad から音声入力を開始するときに呼ぶ。iPad の音声をこのデバイスに流せるかを `ready` に渡す。
    /// このデバイスは Mac の既定の入力になれない (タップのみの機器セットは CanBeDefaultDevice が 0) ので、
    /// Typeless のマイク設定でこのデバイスを選択する (Host が一度だけ自動で行う)。既定の入力は切り替えない。
    func beginListening(ready: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            if !isAuthorized {
                // システム設定であとから許可された場合に気づけるよう、その都度確認し直す
                setAuthorized(AudioCapturePermission.current() == .authorized)
            }
            let isUsingPadMicrophone = isAuthorized && deviceID != kAudioObjectUnknown
            defer { ready(isUsingPadMicrophone) }
            guard isUsingPadMicrophone else { return }
            stopPassThrough()
            passThroughGate.padListeningBegan()
            let isAlreadyRead = renderLock.withLock {
                // 停止直後にまた開始したときは、Typeless が音声入力を続けているので、まだ再生していない音声を破棄しない
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

    /// iPad で停止したときに呼ぶ。停止時点までの音声を流し終えたら `done` を呼ぶ。そのあとで Typeless を停止すれば、話し終わりが切れない。
    func finishListening(done: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + Self.inFlightDelay) { [self] in
            // iPad はもう送ってこないので、再生開始のバッファ量に届いていなくても残りを再生する。待つと話し終わりが再生されないまま、7 秒のタイムアウトまで Typeless が音声入力を続ける
            let target = renderLock.withLock {
                buffer.playRemaining()
                return buffer.written
            }
            waitUntilPlayed(target, deadline: .now() + 7, done: done)
        }
    }

    private func waitUntilPlayed(_ target: Int, deadline: DispatchTime, done: @escaping @Sendable () -> Void) {
        let (remaining, isPlaying) = renderLock.withLock { (target - buffer.consumed, isListening && isRead) }
        // 読み取られていなければ、待っても流れない (Typeless が自分で停止したときなど)
        guard remaining > 0, isPlaying, DispatchTime.now() < deadline else {
            queue.asyncAfter(deadline: .now() + Self.deliveryDelay) { done() }
            return
        }
        let seconds = Double(remaining) / Double(PadAudio.sampleRate)
        queue.asyncAfter(deadline: .now() + max(seconds, 0.01)) { [self] in
            waitUntilPlayed(target, deadline: deadline, done: done)
        }
    }

    /// 音声入力が終了したら、届いた音声の再生を停止する。
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
                let wait = readDelay.map { String(format: "%.2f 秒", $0) } ?? "読み取られなかった"
                Self.logger.notice("iPad から届いた音声: \(String(format: "%.1f", seconds), privacy: .public) 秒分、Typeless が読み取りを始めるまで \(wait, privacy: .public)、再生した音声の最大振幅 \(String(format: "%.4f", played), privacy: .public)、途切れた回数 \(underruns)")
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

    /// 以前 Host が落ちて残ったデバイスとタップを削除する。作成したプロセスが終了しても、HAL からは消えないため。
    static func removeLeftovers() {
        if let device = device(uid: deviceUID) {
            AudioHardwareDestroyAggregateDevice(device)
            logger.notice("以前から残っていた \(deviceName, privacy: .public) を削除した")
        }
        for tap in objects(kAudioHardwarePropertyTapList) where tapName(tap) == deviceName {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    // MARK: - デバイス

    /// 自分の出力をタップが実際に運んでいるかを、チェック専用の非公開の機器セットで確認してログに出す。
    /// 「PadBridge iPad マイク」を自分で読み取るにはマイクの許可も必要だが、非公開の機器セットならシステムオーディオ録音の許可だけで読み取れる。
    /// 出力デバイスを含める形と、「PadBridge iPad マイク」と同じタップのみの形の両方で測定し、違いがあるかを見る。
    private func checkTapCarriesSound() {
        for includesOutput in [true, false] {
            let peak = measureTap(includingOutputDevice: includesOutput)
            Self.logger.notice("タップのチェック (出力デバイスを\(includesOutput ? "含む" : "含まない", privacy: .public)): 最大 \(peak.map { String(format: "%.4f", $0) } ?? "測定不可", privacy: .public) (再生した音声は 0.0100)")
        }
        // Typeless が読み取るのと同じ「PadBridge iPad マイク」自体も測定する。読み取るにはマイクの許可も必要
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
        Self.logger.notice("\(Self.deviceName, privacy: .public) のチェック: 開始=\(started) 最大 \(String(format: "%.4f", peak.value), privacy: .public) (再生した音声は 0.0100)")
    }

    private func measureTap(includingOutputDevice: Bool) -> Float? {
        let process = Self.ownProcessObject()
        guard process != kAudioObjectUnknown, let output = Self.defaultOutputDevice(), let outputUID = Self.uid(of: output) else { return nil }
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "\(Self.deviceName) のチェック"
        description.muteBehavior = .muted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        defer { AudioHardwareDestroyProcessTap(tap) }
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(Self.deviceName) のチェック",
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
            Self.logger.error("再生用エンジンを起動できない: \(error, privacy: .public)")
            return
        }
        // タップでキャプチャするには自分のプロセスのオブジェクトが必要。出力を開始してから HAL に現れるまで少し待つ
        var process = AudioObjectID(kAudioObjectUnknown)
        for _ in 0 ..< 20 {
            process = Self.ownProcessObject()
            if process != kAudioObjectUnknown { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // 出力を停止したままタップを作成すると、タップのみの機器セットは入力を持たないまま固まる。無音を流したままにする
        guard process != kAudioObjectUnknown else {
            Self.logger.error("自分のプロセスのオーディオオブジェクトが見つからない")
            return
        }
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [process])
        tapDescription.uuid = UUID()
        tapDescription.name = Self.deviceName
        tapDescription.muteBehavior = .muted
        // 既定の非公開のタップは作成したプロセスにしか見えず、ほかのアプリからは機器セットに入力がないように見える
        tapDescription.isPrivate = false
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDescription, &tap) == noErr, tap != kAudioObjectUnknown else {
            Self.logger.error("プロセスタップを作成できない")
            return
        }
        // 出力のサブデバイスを入れると出力デバイスとしても一覧に出てしまうので、タップのみの入力デバイスにする
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.deviceName,
            kAudioAggregateDeviceUIDKey: Self.deviceUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr, device != kAudioObjectUnknown else {
            Self.logger.error("機器セットを作成できない")
            AudioHardwareDestroyProcessTap(tap)
            return
        }
        tapID = tap
        deviceID = device
        Self.logger.notice("\(Self.deviceName, privacy: .public) を作成した")
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

    // MARK: - Mac のマイクの音声を流す

    /// このデバイスが読み取られ始めたか、読み取られなくなった。読み取り開始の通知はすぐ届く。
    /// 自分で読み取るのはチェック (キューを占有したまま終える) のときだけなので、それ以外で読み取られていればほかのアプリ (Typeless) が読み取っている。
    /// iPad から話していない間に読み取られていれば、Mac の既定の入力の音声を流す。
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
        // 録音の許可がないとタップのミュートが効かず、Mac のマイクの音声がそのままスピーカーから流れてしまう
        guard isAuthorized, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Self.logger.notice("\(Self.deviceName, privacy: .public) が読み取られたが、許可がないので Mac のマイクの音声を流さない")
            return
        }
        // 再生中のエンジンで入力を使うと出力が再構成されて途切れるので、キャプチャは別のエンジンで行う
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard let converter = PadAudioConverter(from: format) else {
            Self.logger.notice("\(Self.deviceName, privacy: .public) が読み取られたが、Mac に使えるマイクがない")
            return
        }
        // タップは 100ms ごとにしか音声を渡さない。シンクなら入力の 1 回ごと (この Mac では 512 フレーム、約 10ms) に受け取れる
        let isSendFormat = format.sampleRate == Double(PadAudio.sampleRate) && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
        let sink = AVAudioSinkNode { [weak self] _, frameCount, inputData in
            guard let self else { return noErr }
            if isSendFormat, let data = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)).first?.mData {
                // Mac のマイクは送信するフォーマットと同じ 48kHz のことが多いので、そのときは変換せず先頭のチャンネルを流す
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
            Self.logger.error("Mac のマイクを開始できない: \(error, privacy: .public)")
            return
        }
        passThroughEngine = engine
        Self.logger.notice("iPad から話していない間に読み取られたので、Mac のマイクの音声を流す")
    }

    private func stopPassThrough() {
        guard let engine = passThroughEngine else { return }
        passThroughEngine = nil
        engine.stop()
        renderLock.withLock {
            isPassingThrough = false
            passThroughBuffer.removeAll()
        }
        Self.logger.notice("Mac のマイクの音声を流すのを停止した")
    }

    /// システムオーディオ録音の許可を確認し、まだ要求していなければ要求する。
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

    /// システム設定で許可されたらすぐに iPad の通知を消せるよう、許可がない間は確認し続ける。
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
            Self.logger.notice("システムオーディオ録音の許可: \(authorized ? "あり" : "なし", privacy: .public)")
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

/// 入力の最大振幅を、オーディオスレッドから受け取って記録する。
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
