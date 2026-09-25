import Foundation

@main
struct PolicyTests {
    static func main() {
        var policy = DisplayPolicy()
        policy.observe(externalCount: 1)
        assert(!policy.wantsOff(externalCount: 1), "Fresh installs must be manual")
        policy.requestOff(true)
        assert(policy.wantsOff(externalCount: 1), "Manual off with monitor attached")
        assert(!policy.wantsOff(externalCount: 0), "Never disable the only display")
        policy.observe(externalCount: 0)
        policy.observe(externalCount: 1)
        assert(!policy.wantsOff(externalCount: 1), "Manual off must not survive unplug/replug")

        policy.setAutomatic(true)
        assert(policy.wantsOff(externalCount: 1), "Automatic mode applies when a monitor is attached")
        policy.requestOff(false)
        assert(policy.isPaused && !policy.wantsOff(externalCount: 1), "Manual on pauses automation")
        policy.observe(externalCount: 1)
        assert(policy.isPaused, "Self-generated display events cannot cancel the override")
        policy.observe(externalCount: 0)
        assert(!policy.wantsOff(externalCount: 0), "Unplug always restores")
        policy.observe(externalCount: 1)
        assert(policy.wantsOff(externalCount: 1), "Reconnect resumes automatic mode")

        policy.emergencyRestore()
        assert(!policy.automatic && !policy.wantsOff(externalCount: 1), "Emergency must win over automation")
        policy.observe(externalCount: 0)
        policy.observe(externalCount: 1)
        assert(!policy.wantsOff(externalCount: 1), "Emergency must stay restored even after reconnect")
        policy.setAutomatic(true)
        policy.setAutomatic(false)
        assert(!policy.wantsOff(externalCount: 1), "Turning automation off requests an on display")
        print("PASS: 12 display policy checks (no hardware changes)")
    }
}
