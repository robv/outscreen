import Foundation

/// Decode only display-brightness media keys; ordinary typing is never requested.
struct BrightnessKeyInput: Equatable {
    let direction: Int
    let isDown: Bool
    let fine: Bool

    static func decode(data1: Int, subtype: Int, shift: Bool = false, option: Bool = false,
                       control: Bool = false, command: Bool = false) -> BrightnessKeyInput? {
        guard subtype == 8, !control, !command, shift == option else { return nil }
        let key = (data1 >> 16) & 0xffff
        guard key == 2 || key == 3 else { return nil }
        let state = (data1 >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        return BrightnessKeyInput(direction: key == 2 ? 1 : -1, isDown: state == 0x0a, fine: shift && option)
    }

    func applying(to value: Float) -> Float {
        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
        // Snap to native-style increments without a large first jump.
        let units = value / step
        let next = direction > 0 ? floor(units + 0.0001) + 1 : ceil(units - 0.0001) - 1
        return min(1, max(0, next * step))
    }
}

/// Keep the routing decision for an entire press, including repeats and release.
/// A key held before the tap started remains native until it is released.
struct BrightnessPressRouting {
    private var captured: [Int: Bool] = [:]

    mutating func consumes(key: Int, isDown: Bool, isRepeat: Bool, eligible: Bool) -> Bool {
        guard key == 2 || key == 3 else { return false }
        if !isDown { return captured.removeValue(forKey: key) ?? false }
        if isRepeat { return captured[key] ?? false }
        captured[key] = eligible
        return eligible
    }
}
