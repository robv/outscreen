import Foundation

@main
struct BrightnessKeyTests {
    static func main() {
        let up = BrightnessKeyInput.decode(data1: (2 << 16) | 0x0a00, subtype: 8)!
        let down = BrightnessKeyInput.decode(data1: (3 << 16) | 0x0a00, subtype: 8)!
        assert(up.direction == 1 && up.isDown && !up.fine)
        assert(down.direction == -1 && down.isDown)
        assert(BrightnessKeyInput.decode(data1: (2 << 16) | 0x0b00, subtype: 8)?.isDown == false)
        assert(BrightnessKeyInput.decode(data1: (2 << 16) | 0x0a01, subtype: 8) == up, "Held keys repeat")
        assert(BrightnessKeyInput.decode(data1: (0 << 16) | 0x0a00, subtype: 8) == nil, "Volume must pass through")
        assert(BrightnessKeyInput.decode(data1: (16 << 16) | 0x0a00, subtype: 8) == nil, "Playback must pass through")
        assert(BrightnessKeyInput.decode(data1: (2 << 16) | 0x0a00, subtype: 1) == nil)
        assert(BrightnessKeyInput.decode(data1: (2 << 16) | 0x0c00, subtype: 8) == nil)
        assert(BrightnessKeyInput.decode(data1: (2 << 16) | 0x0a00, subtype: 8, control: true) == nil, "Keep native external shortcut")
        assert(BrightnessKeyInput.decode(data1: (3 << 16) | 0x0a00, subtype: 8, command: true) == nil, "Keep native mirroring shortcut")
        assert(BrightnessKeyInput.decode(data1: (2 << 16) | 0x0a00, subtype: 8, option: true) == nil, "Keep Display Settings shortcut")
        assert(BrightnessKeyInput.decode(data1: (2 << 16) | 0x0a00, subtype: 8, shift: true) == nil)
        let fine = BrightnessKeyInput.decode(data1: (2 << 16) | 0x0a00, subtype: 8, shift: true, option: true)!
        assert(fine.fine && fine.applying(to: 0.5) == 0.515625)
        assert(up.applying(to: 0.5) == 0.5625)
        assert(down.applying(to: 0.5) == 0.4375)
        assert(up.applying(to: 1) == 1 && down.applying(to: 0) == 0)
        assert(up.applying(to: 0.51) == 0.5625 && down.applying(to: 0.51) == 0.5)
        var routing = BrightnessPressRouting()
        assert(routing.consumes(key: 2, isDown: true, isRepeat: false, eligible: true))
        assert(routing.consumes(key: 2, isDown: true, isRepeat: true, eligible: false), "A captured press stays captured if target/modifiers change")
        assert(routing.consumes(key: 2, isDown: false, isRepeat: false, eligible: false))
        assert(!routing.consumes(key: 3, isDown: true, isRepeat: false, eligible: false))
        assert(!routing.consumes(key: 3, isDown: true, isRepeat: true, eligible: true), "Do not hijack a native hold mid-press")
        assert(!routing.consumes(key: 3, isDown: false, isRepeat: false, eligible: true))
        assert(!routing.consumes(key: 2, isDown: true, isRepeat: true, eligible: true), "A preexisting hold remains native")
        print("PASS: brightness key decoding, modifier passthrough, repeats, fine steps and bounds")
    }
}
