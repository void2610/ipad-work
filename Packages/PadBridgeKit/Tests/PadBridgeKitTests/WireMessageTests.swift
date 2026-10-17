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
        .microphoneRelayHello(token: "abc"),
        .microphoneRelay(isListening: true),
        .microphoneRelayReady(isUsingPadMicrophone: true),
        .microphoneRelayStatus(isAuthorized: false),
    ])
    func controlMessageRoundTrips(message: ControlMessage) throws {
        let encoded = try WireMessage.control(message).encoded()
        #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == .control(message))
    }

    @Test func videoMessagesRoundTrip() throws {
        let format = WireMessage.videoFormat(VideoFormat(width: 1920, height: 1200, sps: Data([0x67, 0x64, 0x00]), pps: Data([0x68, 0xEE])))
        let frame = WireMessage.videoFrame(VideoFrame(isKeyFrame: true, presentationTimeMicros: 123_456_789, region: VideoRegion(x: 0.5, y: 0.25, width: 0.25, height: 0.25), data: Data(repeating: 0xAB, count: 4096)))
        for message in [format, frame] {
            let encoded = try message.encoded()
            #expect(try WireMessage(type: encoded.type, payload: encoded.payload) == message)
        }
    }

    @Test func truncatedVideoFormatIsRejected() throws {
        let encoded = try WireMessage.videoFormat(VideoFormat(width: 10, height: 10, sps: Data([1, 2, 3]), pps: Data([4]))).encoded()
        #expect(throws: WireError.truncated) {
            try WireMessage(type: encoded.type, payload: encoded.payload.dropLast())
        }
    }

    @Test func unknownTypeIsRejected() {
        #expect(throws: WireError.unknownMessageType(99)) {
            try WireMessage(type: 99, payload: Data())
        }
    }

    @Test func normalizedPointIsClamped() {
        #expect(NormalizedPoint(x: -0.5, y: 1.5) == NormalizedPoint(x: 0, y: 1))
    }
}
