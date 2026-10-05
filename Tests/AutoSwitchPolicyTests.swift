// Run with swiftc Sources/Shared/Model/AutoSwitchPolicy.swift Tests/AutoSwitchPolicyTests.swift -o /tmp/policy-tests
import Foundation

@main
struct PolicyTests {
    static func main() {
        precondition(!AutoSwitchPolicy.mayTry(now: 119, lastTrial: 0))
        precondition(AutoSwitchPolicy.mayTry(now: 120, lastTrial: 0))
        precondition(AutoSwitchPolicy.mayTry(now: 0, lastTrial: -.infinity))
        // A healthy alternate is enough when the current tunnel is unreachable.
        precondition(AutoSwitchPolicy.preferLatency(candidate: 900, baseline: nil))
        // Small improvements and exact boundary values must not cause oscillation.
        precondition(!AutoSwitchPolicy.preferLatency(candidate: 390, baseline: 400))
        precondition(!AutoSwitchPolicy.preferLatency(candidate: 300, baseline: 400))
        precondition(AutoSwitchPolicy.preferLatency(candidate: 299, baseline: 400))
        precondition(!AutoSwitchPolicy.preferLatency(candidate: .nan, baseline: nil))
        precondition(!AutoSwitchPolicy.preferSpeed(candidate: nil, baseline: 10))
        precondition(!AutoSwitchPolicy.preferSpeed(candidate: 12.5, baseline: 10))
        precondition(AutoSwitchPolicy.preferSpeed(candidate: 12.6, baseline: 10))
        precondition(!AutoSwitchPolicy.preferSpeed(candidate: .infinity, baseline: 10))
        print("AutoSwitch policy tests passed")
    }
}
