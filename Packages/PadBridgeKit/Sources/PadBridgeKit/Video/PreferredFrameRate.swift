import Foundation

/// iPad が受信したい映像のフレームレート。低電力モードのときや本体が熱いときは半分にして、デコードと描画の消費電力と発熱を抑える。
public enum PreferredFrameRate {
    public static let normal = 60
    public static let saving = 30
    /// Mac が受け付ける範囲。これより低いと、指で動かしたときに追従できない。
    public static let range = 15 ... 60

    /// `current` は現在要求しているフレームレート。熱状態が serious と fair の境で上下しても要求し直し続けない (Mac は要求のたびにキャプチャを作り直す) よう、
    /// 減らすのは serious 以上になったとき、戻すのは nominal まで冷えたときにする。
    public static func choose(isLowPowerMode: Bool, thermalState: ProcessInfo.ThermalState, current: Int = normal) -> Int {
        if isLowPowerMode || thermalState == .serious || thermalState == .critical {
            return saving
        }
        return current < normal && thermalState != .nominal ? current : normal
    }
}
