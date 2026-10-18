import CoreAudio
import Foundation

/// Typeless が現在マイクで音声入力しているかを、CoreAudio のプロセスごとの入力状態から読み取る。
/// Typeless は音声入力の状態を外部に公開しておらず、音声入力中だけマイクを使うので、それを実際の状態とする。
nonisolated final class TypelessMonitor: @unchecked Sendable {
    // Typeless は Electron 製で、マイクは本体ではなく Typeless Helper のプロセスが使う
    private static let bundleIDPrefix = TypelessApp.bundleIdentifier
    // プロセスの入力状態は、変わっても AudioObjectAddPropertyListenerBlock の通知が来ないので読み直す
    private static let pollInterval: TimeInterval = 0.2
    // Typeless を再起動したときに追従できるよう、プロセス一覧は定期的に取得し直す
    private static let processRefreshInterval: TimeInterval = 2
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private let queue = DispatchQueue(label: "dev.void2610.padbridge.host.typeless")
    private let onChange: @Sendable (Bool) -> Void
    private var timer: DispatchSourceTimer?
    private var processes: [AudioObjectID] = []
    private var processesFetchedAt = -TimeInterval.infinity
    private var isRecording = false

    /// `onChange` は音声入力の開始と終了のたびに、このクラスのキューから呼ばれる。
    init(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    /// iPad が接続されている間だけ監視する。
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            processesFetchedAt = -.infinity
            isRecording = Self.isRecording()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// 現時点の状態を CoreAudio に問い合わせる。どのスレッドからでも呼べる。
    static func isRecording() -> Bool {
        typelessProcesses().contains(where: isRunningInput)
    }

    /// Typeless が現在録音に使っている入力デバイスの UID。
    static func inputDeviceUIDs() -> [String] {
        typelessProcesses().flatMap { process -> [String] in
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
            var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &devices) == noErr else { return [] }
            return devices.compactMap(uid(of:))
        }
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - processesFetchedAt >= Self.processRefreshInterval {
            processes = Self.typelessProcesses()
            processesFetchedAt = now
        }
        let isRecording = processes.contains(where: Self.isRunningInput)
        guard isRecording != self.isRecording else { return }
        self.isRecording = isRecording
        onChange(isRecording)
    }

    private static func typelessProcesses() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return processes.filter { bundleID(of: $0)?.hasPrefix(bundleIDPrefix) == true }
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var bundleID: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &bundleID) == noErr, let bundleID else { return nil }
        return bundleID.takeRetainedValue() as String
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningInput)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var isRunning: UInt32 = 0
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &isRunning) == noErr else { return false }
        return isRunning != 0
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
