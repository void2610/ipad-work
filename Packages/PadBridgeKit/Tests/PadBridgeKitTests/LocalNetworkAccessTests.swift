import Network
@testable import PadBridgeKit
import Testing

struct LocalNetworkAccessTests {
    /// TN3179 にある値 (-65570) で止まったときだけ、許可がないとみなす。
    @Test func onlyPolicyDeniedMeansNoAccess() {
        #expect(kDNSServiceErr_PolicyDenied == -65570)
        #expect(LocalNetworkAccess.isDenied(.waiting(.dns(-65570))))
        #expect(LocalNetworkAccess.isDenied(.failed(.dns(-65570))))
        #expect(!LocalNetworkAccess.isDenied(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_Unknown)))))
        #expect(!LocalNetworkAccess.isDenied(.waiting(.posix(.ENETDOWN))))
        #expect(!LocalNetworkAccess.isDenied(.ready))
    }
}
