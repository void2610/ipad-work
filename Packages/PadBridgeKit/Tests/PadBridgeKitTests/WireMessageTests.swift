import Foundation
@testable import PadBridgeKit
import Testing

struct WireMessageTests {
    @Test(arguments: [
        ControlMessage.hello(role: .video, deviceName: "iPad", maxVideoWidth: 2752, maxVideoHeight: 2064),
        .welcome(hostName: "MacBook Pro", status: HostStatus(canCaptureScreen: true, canControlInput: false)),
        .mouseMove(NormalizedPoint(x: 0.25, y: 0.75)),
        .mouseButton(.right, isDown: true, at: NormalizedPoint(x: 0.5, y: 0.5)),
        .scroll(dx: -0.01, dy: 0.02),
        .key(usage: 0x28, isDown: true, modifiers: [.command, .shift]),
        .insertText("こんにちは、世界 👋"),
        .voiceInput(isActive: true),
        .voiceInputState(isActive: false),
        .desktopSwipe(.left),
        .requestKeyFrame,
        .videoRegion(VideoRegion(x: 0.25, y: 0.125, width: 0.5, height: 0.5)),
        .macAudio(isEnabled: true),
        .macAudioCodec(.opus),
        .acknowledgeVideoFrames,
        .videoFrameReceived(presentationTimeMicros: 123_456_789),
        .videoQuality(isReduced: true),
        .displays([RemoteDisplay(id: 15, name: "名前のない画面", placement: .left), RemoteDisplay(id: 16, name: "VG258", placement: .main)], shownID: 15),
        .selectDisplay(id: 16),
        .moveFrontWindow(toDisplay: 15),
        .showDock,
        .releaseHeldInput,
        .microphoneRelayHello(token: "abc"),
        .microphoneRelay(isListening: true),
        .microphoneRelayReady(isUsingPadMicrophone: true),
        .microphoneRelayStatus(isAuthorized: false),
        .microphoneRelayFinish,
        .microphoneRelayFinished,
    ])
    func controlMessageRoundTrips(message: ControlMessage) throws {
        let encoded = try WireMessage.control(message).encoded()
        #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == .control(message))
    }

    @Test func videoMessagesRoundTrip() throws {
        let format = WireMessage.videoFormat(VideoFormat(codec: .h264, width: 1920, height: 1200, parameterSets: [Data([0x67, 0x64, 0x00]), Data([0x68, 0xEE])]))
        let hevc = WireMessage.videoFormat(VideoFormat(codec: .hevc, width: 1920, height: 1080, parameterSets: [Data([0x40, 0x01]), Data([0x42, 0x01, 0x01]), Data([0x44, 0x01])]))
        let frame = WireMessage.videoFrame(VideoFrame(isKeyFrame: true, presentationTimeMicros: 123_456_789, region: VideoRegion(x: 0.5, y: 0.25, width: 0.25, height: 0.25), data: Data(repeating: 0xAB, count: 4096)))
        for message in [format, hevc, frame] {
            let encoded = try message.encoded()
            #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == message)
        }
    }

    /// Mac の音は、無圧縮も Opus も中身をそのまま運ぶ。
    @Test func macAudioMessagesRoundTrip() throws {
        for message in [WireMessage.macAudio(Data([1, 0, 2, 0])), .macAudioOpus(Data([0xFC, 0xFF, 0xFE]))] {
            let encoded = try message.encoded()
            #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == message)
        }
        #expect(try WireMessage.macAudioOpus(Data()).encoded().type != WireMessage.macAudio(Data()).encoded().type)
    }

    @Test func truncatedVideoFormatIsRejected() throws {
        let encoded = try WireMessage.videoFormat(VideoFormat(codec: .h264, width: 10, height: 10, parameterSets: [Data([1, 2, 3]), Data([4])])).encoded()
        #expect(throws: WireError.truncated) {
            try WireMessage(type: encoded.type, payload: encoded.payload.dropLast())
        }
    }

    @Test func unknownVideoCodecIsRejected() throws {
        var encoded = try WireMessage.videoFormat(VideoFormat(codec: .hevc, width: 10, height: 10, parameterSets: [Data([1])])).encoded()
        encoded.payload[encoded.payload.startIndex] = 9
        #expect(throws: WireError.unknownVideoCodec(9)) {
            try WireMessage(type: encoded.type, payload: encoded.payload)
        }
    }

    @Test func unknownTypeIsRejected() {
        #expect(throws: WireError.unknownMessageType(99)) {
            try WireMessage(type: 99, payload: Data())
        }
    }

    /// 範囲の外の値で送られてきても、読み取るときに丸める。
    @Test func decodedNormalizedPointIsClamped() throws {
        let json = Data(#"{"mouseMove":{"_0":{"x":-0.2,"y":1.7}}}"#.utf8)
        #expect(try JSONDecoder().decode(ControlMessage.self, from: json) == .mouseMove(NormalizedPoint(x: 0, y: 1)))
    }

    @Test func normalizedPointIsClamped() {
        #expect(NormalizedPoint(x: -0.5, y: 1.5) == NormalizedPoint(x: 0, y: 1))
    }
}
