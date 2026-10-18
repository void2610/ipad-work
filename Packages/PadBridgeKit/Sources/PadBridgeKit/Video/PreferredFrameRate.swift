import Foundation

/// iPad が受けたい映像の毎秒の枚数。低電力モードのときや本体が熱いときは半分にして、復号と描画の電池と熱を抑える。
public enum PreferredFrameRate {
    public static let normal = 60
    public static let saving = 30
    /// Mac が受け付ける範囲。これより少ないと、指で動かしたときに追いつかない。
    public static let range = 15 ... 60

    public static func choose(isLowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> Int {
        isLowPowerMode || thermalState == .serious || thermalState == .critical ? saving : normal
    }
}
