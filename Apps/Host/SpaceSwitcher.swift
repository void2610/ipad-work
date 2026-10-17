import CoreGraphics
import Foundation

/// トラックパッドで操作スペースを切り替えるときと同じ Dock スワイプのイベントを合成する。
/// 「左右の操作スペースへ」のキーボードショートカットは利用者の設定次第で効かないため、ショートカットには頼らない。
/// 欄の番号と値は InstantSpaceSwitcher (MIT, jurplel) の macOS 26 以前向けの実装に合わせている。macOS 27 では追加の欄が要る。
nonisolated enum SpaceSwitcher {
    private static let eventTypeField = field(55)
    private static let gestureHIDTypeField = field(110)
    private static let swipeMotionField = field(123)
    private static let swipeProgressField = field(124)
    private static let swipeVelocityXField = field(129)
    private static let swipeVelocityYField = field(130)
    private static let gesturePhaseField = field(132)

    private static let dockControlEventType: Int64 = 30
    private static let dockSwipeHIDType: Int64 = 23
    private static let horizontalMotion: Int64 = 1
    // 移動量はほぼ 0 にして、速さで切り替えを確定させる。移動量が大きいと元のスペースが一瞬見える
    private static let progress = 0.000016
    private static let velocity = 2000.0

    private enum Phase: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
    }

    static func switchSpace(toRight: Bool) {
        // 開始・途中・終了の 3 つがそろわないと Dock は切り替えない
        for phase in [Phase.began, .changed, .ended] {
            post(phase, sign: toRight ? 1 : -1)
        }
    }

    private static func post(_ phase: Phase, sign: Double) {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(eventTypeField, value: dockControlEventType)
        event.setIntegerValueField(gestureHIDTypeField, value: dockSwipeHIDType)
        event.setIntegerValueField(gesturePhaseField, value: phase.rawValue)
        event.setDoubleValueField(swipeProgressField, value: sign * progress)
        event.setIntegerValueField(swipeMotionField, value: horizontalMotion)
        event.setDoubleValueField(swipeVelocityXField, value: sign * velocity)
        event.setDoubleValueField(swipeVelocityYField, value: sign * velocity)
        event.post(tap: .cgSessionEventTap)
    }

    /// CGEventField に名前のない非公開の欄も、番号で指定する。
    private static func field(_ number: UInt32) -> CGEventField {
        unsafeBitCast(number, to: CGEventField.self)
    }
}
