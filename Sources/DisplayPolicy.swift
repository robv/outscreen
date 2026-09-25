import Foundation

/// User intent is separate from hardware state so restoration always wins.
struct DisplayPolicy {
    var automatic = false
    private(set) var manualOff: Bool?
    private var previousExternalCount: Int?

    var isPaused: Bool { automatic && manualOff == false }

    mutating func observe(externalCount: Int) {
        if let previous = previousExternalCount, previous != externalCount {
            manualOff = nil
        }
        if externalCount == 0 { manualOff = nil }
        previousExternalCount = externalCount
    }

    mutating func setAutomatic(_ value: Bool) {
        automatic = value
        manualOff = nil
    }

    mutating func requestOff(_ value: Bool) { manualOff = value }

    mutating func emergencyRestore() {
        automatic = false
        manualOff = false
    }

    func wantsOff(externalCount: Int) -> Bool {
        guard externalCount > 0 else { return false }
        return manualOff ?? automatic
    }
}
