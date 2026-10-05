// SPDX-License-Identifier: MIT
import Foundation
import Network
import NetworkExtension

/// All mutable state lives on queue. Only one WireGuard configuration is active.
final class AutoSwitchController {
    private weak var provider: NEPacketTunnelProvider?
    private let adapter: WireGuardAdapter
    private let settings: AutoSwitchConfiguration
    private let queue = DispatchQueue(label: "AutoSwitch")
    private let pathMonitor = NWPathMonitor()
    private var timer: DispatchSourceTimer?
    private var probe: AutoSwitchProbe?
    private var running = false
    private var available = false
    private var busy = false
    private var active = 0
    private var failures = 0
    private var slowChecks = 0
    private var lastTrial: TimeInterval = -.infinity
    private var lastSpeed: TimeInterval = -.infinity
    private var latency: Double?
    private var speed: Double?
    private var reason = "Starting"
    private var pathSignature: String?
    private var generation = 0

    init(provider: NEPacketTunnelProvider, adapter: WireGuardAdapter, settings: AutoSwitchConfiguration, initialIndex: Int) {
        self.provider = provider
        self.adapter = adapter
        self.settings = settings
        active = initialIndex
    }

    func start() {
        queue.async {
            self.running = true
            self.pathMonitor.pathUpdateHandler = { [weak self] path in
                guard let self = self, self.running else { return }
                self.available = path.status == .satisfied
                let signature = "\(path.status):\(path.availableInterfaces.map { $0.name }.sorted())"
                if signature != self.pathSignature {
                    self.pathSignature = signature
                    self.failures = 0
                    self.slowChecks = 0
                    self.reason = self.available ? "Network changed; checking gateway" : "Waiting for internet"
                    // Allow WireGuard's own roaming handler time to rebind its transport.
                    self.queue.asyncAfter(deadline: .now() + 3) { self.check() }
                }
            }
            self.pathMonitor.start(queue: self.queue)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 15, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.check() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop(completion: @escaping () -> Void) {
        queue.async {
            self.running = false
            self.generation += 1
            self.timer?.cancel()
            self.timer = nil
            self.pathMonitor.cancel()
            self.probe?.cancel()
            self.probe = nil
            completion()
        }
    }

    func status(completion: @escaping (Data) -> Void) {
        queue.async {
            var lines = ["Gateway: " + self.settings.candidates[self.active].name, self.reason]
            if let latency = self.latency { lines.append(String(format: "HTTPS response latency: %.0f ms", latency)) }
            if let speed = self.speed { lines.append(String(format: "Bounded download estimate: %.2f Mbps", speed)) }
            lines.append("Checks may pause during device sleep. Gateway trials can interrupt sessions.")
            completion(Data(lines.joined(separator: "\n").utf8))
        }
    }

    private func measure(speed: Bool = false, completion: @escaping (AutoSwitchProbe.Measurement?) -> Void) {
        guard running, let provider = provider else { completion(nil); return }
        let token = generation
        let probe = AutoSwitchProbe(provider: provider, queue: queue, speed: speed) { [weak self] result in
            guard let self = self, self.running, token == self.generation else { return }
            self.probe = nil
            completion(result)
        }
        self.probe = probe
        probe.start()
    }

    private func check() {
        guard running, available, !busy else { return }
        busy = true
        measure { result in
            guard let result = result else {
                self.latency = nil
                self.failures += 1
                self.reason = "Health check failed (\(self.failures)/3)"
                if self.failures >= 3 && self.canTrial {
                    self.trial(baseline: nil, speedMode: false)
                } else { self.busy = false }
                return
            }
            self.failures = 0
            self.latency = result.latencyMS
            self.reason = "Gateway healthy"
            self.slowChecks = result.latencyMS > self.settings.latencyThresholdMS ? self.slowChecks + 1 : 0
            if self.slowChecks >= 3 && self.canTrial {
                self.trial(baseline: result, speedMode: false)
            } else if self.settings.minimumMbps > 0 && self.now - self.lastSpeed >= 900 {
                self.lastSpeed = self.now
                self.measure(speed: true) { sample in
                    self.speed = sample?.mbps
                    if let sample = sample, let mbps = sample.mbps,
                       mbps < self.settings.minimumMbps && self.canTrial {
                        self.trial(baseline: sample, speedMode: true)
                    } else { self.busy = false }
                }
            } else { self.busy = false }
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var canTrial: Bool { AutoSwitchPolicy.mayTry(now: now, lastTrial: lastTrial) }

    private func apply(_ index: Int, completion: @escaping (Bool) -> Void) {
        guard let config = try? TunnelConfiguration(fromWgQuickConfig: settings.candidates[index].wgQuick,
                                                   called: settings.candidates[index].name) else { completion(false); return }
        let token = generation
        adapter.update(tunnelConfiguration: config) { error in
            self.queue.async {
                guard self.running, token == self.generation else { return }
                guard error == nil else { completion(false); return }
                self.active = index
                self.latency = nil
                self.speed = nil
                self.queue.asyncAfter(deadline: .now() + 3) {
                    guard self.running, token == self.generation else { return }
                    completion(true)
                }
            }
        }
    }

    private func trial(baseline: AutoSwitchProbe.Measurement?, speedMode: Bool) {
        lastTrial = now
        let original = active
        let alternative = 1 - original
        reason = "Trying " + settings.candidates[alternative].name
        apply(alternative) { success in
            guard success else { self.rollback(original); return }
            // Always validate connectivity first, even when comparing throughput.
            self.measure { health in
                guard let health = health else { self.rollback(original); return }
                if speedMode {
                    self.measure(speed: true) { sample in
                        guard let sample = sample,
                              AutoSwitchPolicy.preferSpeed(candidate: sample.mbps, baseline: baseline?.mbps) else { self.rollback(original); return }
                        self.accept(sample)
                    }
                } else if AutoSwitchPolicy.preferLatency(candidate: health.latencyMS, baseline: baseline?.latencyMS) {
                    self.accept(health)
                } else { self.rollback(original) }
            }
        }
    }

    private func accept(_ sample: AutoSwitchProbe.Measurement) {
        latency = sample.latencyMS
        speed = sample.mbps
        failures = 0
        slowChecks = 0
        reason = "Switched to " + settings.candidates[active].name
        wg_log(.info, message: reason)
        busy = false
    }

    private func rollback(_ original: Int) {
        apply(original) { success in
            self.reason = success ? "Restored previous gateway; alternative did not improve service" : "Gateway update failed"
            self.failures = 0
            self.slowChecks = 0
            self.busy = false
        }
    }
}
