import Foundation

/// iPad が受けたい映像の毎秒の枚数。低電力モードのときや本体が熱いときは半分にして、復号と描画の電池と熱を抑える。
public enum PreferredFrameRate {
    public static let normal = 60
    public static let saving = 30
    /// Mac が受け付ける範囲。これより少ないと、指で動かしたときに追いつかない。
    public static let range = 15 ... 60

    /// `current` は今頼んでいる枚数。熱さが serious と fair の境で揺れても頼み直し続けない (Mac は頼まれるたびに取り込みを作り直す) よう、
    /// 減らすのは serious 以上になったとき、戻すのは nominal まで冷えたときにする。
    public static func choose(isLowPowerMode: Bool, thermalState: ProcessInfo.ThermalState, current: Int = normal) -> Int {
        if isLowPowerMode || thermalState == .serious || thermalState == .critical {
            return saving
        }
        return current < normal && thermalState != .nominal ? current : normal
    }
}
