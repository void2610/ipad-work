import AVFoundation
import CoreAudio
import IOKit
import os
import PadBridgeKit

/// iPad のマイクの音を、iPad がつながっている間だけ Mac の入力デバイス「PadBridge iPad マイク」として見せる。
/// Mac は蓋を閉じると内蔵マイクをハードウェアで切り離すので、閉じたままでも Mac の Typeless で話せるようにするため。
/// 届いた音を自分で鳴らし、その出力をプロセスタップで取り出して集約デバイスの入力にする。タップが出力をミュートするので、スピーカーからは鳴らない。
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
    // 80ms たまってから鳴らし始め、0.5 秒より遅れたら古い音を捨てる
    private var buffer = PCMJitterBuffer(capacity: PadAudio.sampleRate / 2, startThreshold: PadAudio.sampleRate * 8 / 100)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var previousDefaultInputUID: String?
    // 許可がないとタップのミュートが効かず、iPad の声が Mac のスピーカーから流れてしまう。確かめるまでは鳴らさない
    private var isAuthorized = false
    private let authorizationLock = NSLock()
    private var reportedAuthorization: Bool?

    /// `onAuthorizationChange` は、システムオーディオの録音の許可があるかが分かるたび (変わったときだけ) に呼ばれる。
    init(onAuthorizationChange: @escaping @Sendable (Bool) -> Void) {
        self.onAuthorizationChange = onAuthorizationChange
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(PadAudio.sampleRate), channels: 1)!
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            guard let data = UnsafeMutableAudioBufferListPointer(bufferList).first?.mData else { return noErr }
            let output = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            if let self {
                renderLock.withLock { buffer.read(into: output) }
            } else {
                output.update(repeating: 0)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    /// 許可がないと分かっているか。まだ確かめていなければ false。
    var isKnownUnauthorized: Bool {
        authorizationLock.withLock { reportedAuthorization == false }
    }

    /// デバイスを作り、許可があるかを確かめる。iPad がつながったときに呼ぶ。
    func start() {
        queue.async { [self] in
            Self.removeLeftovers()
            createDevice()
            checkAuthorization()
        }
    }

    /// デバイスを消す。iPad の接続が切れたときに呼ぶ。
    func stop() {
        queue.async { [self] in
            restoreDefaultInput()
            engine.stop()
            destroyDevice()
        }
    }

    /// iPad から聞き取りを始めるとき、Typeless が拾うよう Mac の既定の入力をこのデバイスにする。準備ができたら、切り替えたかを `ready` に渡す。
    /// Typeless のマイクは「自動検出」(既定の入力) のままでよく、Typeless の設定は変えない。
    func beginListening(ready: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            defer { ready(previousDefaultInputUID != nil) }
            guard deviceID != kAudioObjectUnknown else { return }
            if !isAuthorized {
                // システム設定であとから許可された場合に気づけるよう、その都度確かめ直す
                setAuthorized(AudioCapturePermission.current() == .authorized)
            }
            guard isAuthorized else { return }
            // 蓋が開いているか、ほかに使えるマイクがあるなら切り替えない。Mac のマイクで動いていた Typeless を巻き込まないため
            if let reason = Self.reasonNotToUsePadMicrophone() {
                Self.logger.info("既定の入力は切り替えない: \(reason, privacy: .public)")
                return
            }
            renderLock.withLock { buffer.removeAll() }
            do {
                try engine.start()
            } catch {
                Self.logger.error("音を鳴らすエンジンを動かせない: \(error, privacy: .public)")
                return
            }
            guard previousDefaultInputUID == nil, let current = Self.defaultInputDevice(), current != deviceID else { return }
            previousDefaultInputUID = Self.uid(of: current)
            Self.setDefaultInput(deviceID)
            Self.logger.info("既定の入力を \(Self.deviceName, privacy: .public) に切り替えた")
        }
    }

    /// 聞き取りが終わったら、鳴らすのをやめ、既定の入力を元に戻す。
    func endListening() {
        queue.async { [self] in
            if engine.isRunning {
                engine.pause()
            }
            restoreDefaultInput()
        }
    }

    func feed(_ samples: Data) {
        renderLock.withLock { buffer.write(samples) }
    }

    /// 前に Host が落ちて残ったデバイスとタップを消す。作ったプロセスが終わっても、HAL からは消えないため。
    static func removeLeftovers() {
        if let device = device(uid: deviceUID) {
            AudioHardwareDestroyAggregateDevice(device)
            logger.info("前に残った \(deviceName, privacy: .public) を消した")
        }
        for tap in objects(kAudioHardwarePropertyTapList) where tapName(tap) == deviceName {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    // MARK: - デバイス

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
        engine.pause()
        guard process != kAudioObjectUnknown else {
            Self.logger.error("自分のプロセスのオーディオオブジェクトが見つからない")
            return
        }
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [process])
        tapDescription.uuid = UUID()
        tapDescription.name = Self.deviceName
        tapDescription.muteBehavior = .muted
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
        Self.logger.info("\(Self.deviceName, privacy: .public) を作った")
    }

    private func destroyDevice() {
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
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
        isAuthorized = authorized
        let changed = authorizationLock.withLock {
            defer { reportedAuthorization = authorized }
            return reportedAuthorization != authorized
        }
        if changed {
            Self.logger.info("システムオーディオの録音の許可: \(authorized ? "あり" : "なし", privacy: .public)")
            onAuthorizationChange(authorized)
        }
    }

    private func restoreDefaultInput() {
        guard let previous = previousDefaultInputUID else { return }
        previousDefaultInputUID = nil
        if let device = Self.device(uid: previous) {
            Self.setDefaultInput(device)
            Self.logger.info("既定の入力を元に戻した")
        }
    }

    // MARK: - CoreAudio

    // マイクとして数えない接続の種類。AVAudioEngine は自分のプロセスの中に既定の入出力をまとめた非公開の集約デバイスを作り、
    // それが入力を持つので数えてしまう (中身は蓋を閉じて使えない内蔵マイク)。このデバイス自身も集約デバイス
    private static let transportsThatAreNotMicrophones: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn,
        kAudioDeviceTransportTypeAggregate,
        kAudioDeviceTransportTypeVirtual,
        kAudioDeviceTransportTypeUnknown,
    ]

    /// iPad のマイクに切り替えない理由。蓋が閉じていて (内蔵マイクはハードウェアで切り離される)、ほかにマイクがなければ nil。
    private static func reasonNotToUsePadMicrophone() -> String? {
        guard isClamshellClosed() else { return "蓋が開いていて Mac の内蔵マイクが使える" }
        let others = objects(kAudioHardwarePropertyDevices).filter { device in
            hasInput(device) && !transportsThatAreNotMicrophones.contains(transportType(device))
        }
        guard others.isEmpty else { return "ほかのマイクがある (\(others.compactMap(name(of:)).joined(separator: "、")))" }
        return nil
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func isClamshellClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(rootDomain) }
        let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (state as? Bool) ?? false
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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

    private static func defaultInputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func setDefaultInput(_ device: AudioObjectID) {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = device
        AudioObjectSetPropertyData(systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
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
