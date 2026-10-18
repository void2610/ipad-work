#if os(macOS)
import Foundation

/// システムオーディオ録音の許可。公開 API がないので、AudioCap などと同じく TCC の関数を直接呼ぶ。
/// ディスプレイを持たないヘルパーアプリでは Core Audio が許可の有無を確認するだけでダイアログを出さないため、こちらから要求する。ヘルパーアプリは Host の中から起動されるので、Host の許可として扱われる。
public enum AudioCapturePermission {
    public enum Status: Sendable {
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

    public static func current() -> Status {
        guard let symbol = dlsym(framework, "TCCAccessPreflight") else { return .undetermined }
        switch unsafeBitCast(symbol, to: Preflight.self)(serviceName as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let symbol = dlsym(framework, "TCCAccessRequest") else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: Request.self)(serviceName as CFString, nil) { granted in completion(granted) }
    }
}
#endif
