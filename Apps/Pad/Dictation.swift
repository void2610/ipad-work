@preconcurrency import AVFoundation
import Observation
import Speech
import SwiftUI

enum DictationError: LocalizedError {
    case microphoneDenied
    case unsupportedLocale
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "マイクの使用が許可されていません。設定アプリの PadBridge で許可してください。"
        case .unsupportedLocale: "この言語の音声認識に対応していません。"
        case .noAudioFormat: "マイクの音声を音声認識に渡せませんでした。"
        }
    }
}

/// iPad のマイクで話した内容を、この iPad の中で文字にする。Mac 側に仮想マイクなどを入れずに済ませるため、認識は iPad で行う。
@Observable
final class DictationController {
    enum State {
        case idle
        case preparing
        case listening
        case finishing
    }

    private(set) var state = State.idle
    private(set) var transcript = ""
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    private let microphone = MicrophoneCapture()
    private var finalized = AttributedString()
    private var volatile = AttributedString()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    func begin() {
        guard state == .idle else { return }
        state = .preparing
        finalized = AttributedString()
        volatile = AttributedString()
        transcript = ""
        errorMessage = nil
        startTask = Task {
            do {
                try await start()
            } catch {
                errorMessage = error.localizedDescription
                await tearDown()
            }
        }
    }

    /// 録音を止め、確定した文字列を返す。
    func end() async -> String {
        await startTask?.value
        startTask = nil
        guard state == .listening else { return "" }
        state = .finishing
        microphone.stop()
        inputContinuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        let text = String((finalized + volatile).characters)
        await tearDown()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphoneDenied }
        guard let locale = await Self.recognitionLocale() else { throw DictationError.unsupportedLocale }
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            statusMessage = "音声認識モデルをダウンロード中…"
            defer { statusMessage = nil }
            try await request.downloadAndInstall()
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: microphone.inputFormat) else {
            throw DictationError.noAudioFormat
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        inputContinuation = continuation
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.apply(result)
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
        try await analyzer.start(inputSequence: stream)
        try microphone.start(convertingTo: format) { buffer in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        state = .listening
    }

    private func apply(_ result: DictationTranscriber.Result) {
        if result.isFinal {
            finalized += result.text
            volatile = AttributedString()
        } else {
            volatile = result.text
        }
        transcript = String((finalized + volatile).characters)
    }

    private func tearDown() async {
        microphone.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        analyzer = nil
        resultsTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
    }

    private static func recognitionLocale() async -> Locale? {
        // 地域設定ではなく、ユーザーが話す言語として選んでいる優先言語を先に見る
        let candidates = (Locale.preferredLanguages.map(Locale.init(identifier:)) + [Locale(identifier: "ja-JP")])
        for candidate in candidates {
            if let locale = await DictationTranscriber.supportedLocale(equivalentTo: candidate) {
                return locale
            }
        }
        return nil
    }
}

/// マイクの音声を、音声認識が受け付ける形式に変換して渡す。タップはオーディオスレッドで呼ばれるため MainActor から切り離す。
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var isTapInstalled = false

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func start(convertingTo format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else { throw DictationError.noAudioFormat }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let converted = Self.convert(buffer, with: converter, to: format) {
                onBuffer(converted)
            }
        }
        isTapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // 入力ブロックは convert の中で同期的に呼ばれるだけなので、別スレッドから触られることはない
        nonisolated(unsafe) var isConsumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if isConsumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            isConsumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// 押している間だけ聞き取る。短く押した場合は、もう一度押すまで聞き続ける。
struct DictationButton: View {
    private enum Mode {
        case idle
        case holding(since: Date)
        case handsFree
        case stopping
    }

    let dictation: DictationController
    let onText: (String) -> Void
    @State private var mode = Mode.idle

    var body: some View {
        Image(systemName: isActive ? "mic.fill" : "mic")
            .font(.title3)
            .frame(width: 56, height: 36)
            .foregroundStyle(.white)
            .background(isActive ? Color.red : Color.accentColor, in: Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressBegan() }
                    .onEnded { _ in pressEnded() }
            )
            .onChange(of: dictation.state) { _, state in
                if state == .idle, case .handsFree = mode {
                    mode = .idle
                }
            }
            .accessibilityLabel("音声入力")
            .accessibilityAddTraits(.isButton)
    }

    private var isActive: Bool {
        if case .idle = mode { return false }
        return true
    }

    private func pressBegan() {
        switch mode {
        case .idle:
            mode = .holding(since: .now)
            dictation.begin()
        case .handsFree:
            mode = .stopping
            finish()
        case .holding, .stopping:
            break
        }
    }

    private func pressEnded() {
        switch mode {
        case let .holding(since):
            if Date.now.timeIntervalSince(since) < 0.35 {
                mode = .handsFree
            } else {
                mode = .idle
                finish()
            }
        case .stopping:
            mode = .idle
        case .idle, .handsFree:
            break
        }
    }

    private func finish() {
        Task {
            let text = await dictation.end()
            if !text.isEmpty {
                onText(text)
            }
        }
    }
}
