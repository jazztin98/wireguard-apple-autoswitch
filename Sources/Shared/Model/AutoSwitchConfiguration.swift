// SPDX-License-Identifier: MIT
import Foundation

/// The entire document is held in the shared keychain, never in VPN preferences.
struct AutoSwitchConfiguration: Codable {
    static let referenceKey = "AutoSwitchReference"
    struct Candidate: Codable {
        let name: String
        let wgQuick: String
    }
    let candidates: [Candidate]
    let latencyThresholdMS: Double
    // Zero disables throughput testing. Tests are bounded, opt-in estimates.
    let minimumMbps: Double

    func validated() -> Bool {
        guard candidates.count == 2, latencyThresholdMS.isFinite,
              (50...10000).contains(latencyThresholdMS), minimumMbps.isFinite,
              (0...1000).contains(minimumMbps) else { return false }
        return candidates.allSatisfy { candidate in
            guard let config = try? TunnelConfiguration(fromWgQuickConfig: candidate.wgQuick, called: candidate.name) else { return false }
            let ipv4 = config.peers.contains { peer in
                peer.allowedIPs.contains { $0.stringRepresentation == "0.0.0.0/0" }
            }
            let ipv6 = config.peers.contains { peer in
                peer.allowedIPs.contains { $0.stringRepresentation == "::/0" }
            }
            return ipv4 && (minimumMbps == 0 || ipv6)
        }
    }
}
