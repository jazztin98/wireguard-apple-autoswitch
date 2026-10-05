// SPDX-License-Identifier: MIT
import Foundation

enum AutoSwitchPolicy {
    static func mayTry(now: TimeInterval, lastTrial: TimeInterval) -> Bool {
        return now - lastTrial >= 120
    }

    static func preferLatency(candidate: Double, baseline: Double?) -> Bool {
        guard candidate.isFinite, candidate > 0 else { return false }
        guard let baseline = baseline else { return true }
        return candidate < baseline * 0.75
    }

    static func preferSpeed(candidate: Double?, baseline: Double?) -> Bool {
        guard let candidate = candidate, let baseline = baseline,
              candidate.isFinite, baseline.isFinite, candidate > 0, baseline > 0 else { return false }
        return candidate > baseline * 1.25
    }
}
