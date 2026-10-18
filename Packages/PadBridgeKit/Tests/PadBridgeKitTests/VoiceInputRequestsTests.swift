@testable import PadBridgeKit
import Testing

struct VoiceInputRequestsTests {
    /// 離してすぐ再度押すと、前の音声入力の終了は iPad に通知しない。新しい音声入力が始まれば、また通知する。
    @Test func quickRestartHidesPreviousStop() {
        var requests = VoiceInputRequests()
        let first = requests.receive(isActive: true)
        requests.settle(first)
        _ = requests.receive(isActive: false)
        #expect(requests.announcesStop)
        let again = requests.receive(isActive: true)
        #expect(!requests.announcesStop)
        requests.settle(again)
        #expect(requests.announcesStop)
    }

    /// ヘルパーアプリの応答を待つ間に離したら、届いた応答では開始しない。
    @Test func startReplyAfterStopIsStale() {
        var requests = VoiceInputRequests()
        let start = requests.receive(isActive: true)
        _ = requests.receive(isActive: false)
        #expect(!requests.isCurrent(start))
    }

    /// 押し直している間に切断されたら、残りの押し直しはしない。
    @Test func disconnectCancelsPendingRetries() {
        var requests = VoiceInputRequests()
        let start = requests.receive(isActive: true)
        requests.cancelAll()
        #expect(!requests.isCurrent(start))
        #expect(requests.announcesStop)
    }

    /// 前の要求の放棄が、新しい要求の待機を解除しない。
    @Test func settlingOldRequestKeepsNewPending() {
        var requests = VoiceInputRequests()
        let old = requests.receive(isActive: true)
        _ = requests.receive(isActive: true)
        requests.settle(old)
        #expect(!requests.announcesStop)
    }
}
