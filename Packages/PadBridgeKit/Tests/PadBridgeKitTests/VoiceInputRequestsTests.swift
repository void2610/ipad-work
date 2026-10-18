@testable import PadBridgeKit
import Testing

struct VoiceInputRequestsTests {
    /// 離してすぐまた押すと、前の聞き取りの終わりは iPad に知らせない。新しい聞き取りが始まれば、また知らせる。
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

    /// 補助アプリの返事を待つ間に離したら、届いた返事では始めない。
    @Test func startReplyAfterStopIsStale() {
        var requests = VoiceInputRequests()
        let start = requests.receive(isActive: true)
        _ = requests.receive(isActive: false)
        #expect(!requests.isCurrent(start))
    }

    /// 押し直している間に切れたら、残りの押し直しはしない。
    @Test func disconnectCancelsPendingRetries() {
        var requests = VoiceInputRequests()
        let start = requests.receive(isActive: true)
        requests.cancelAll()
        #expect(!requests.isCurrent(start))
        #expect(requests.announcesStop)
    }

    /// 前の要求のあきらめが、新しい要求の待ちを消さない。
    @Test func settlingOldRequestKeepsNewPending() {
        var requests = VoiceInputRequests()
        let old = requests.receive(isActive: true)
        _ = requests.receive(isActive: true)
        requests.settle(old)
        #expect(!requests.announcesStop)
    }
}
