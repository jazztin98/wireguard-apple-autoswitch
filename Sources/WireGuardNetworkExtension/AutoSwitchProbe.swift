// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension

/// Explicit through-tunnel sockets prevent accidentally measuring direct internet.
final class AutoSwitchProbe {
    struct Measurement {
        let latencyMS: Double
        let mbps: Double?
    }
    private let queue: DispatchQueue
    private let connection: NWTCPConnection
    private let speed: Bool
    private let request: Data
    private let started = ProcessInfo.processInfo.systemUptime
    private var headerTime: TimeInterval?
    private var observation: NSKeyValueObservation?
    private var timeout: DispatchWorkItem?
    private var buffer = Data()
    private var headerEnd: Int?
    private var bodyLength = 0
    private var didWrite = false
    private var completion: ((Measurement?) -> Void)?

    init(provider: NEPacketTunnelProvider, queue: DispatchQueue, speed: Bool,
         completion: @escaping (Measurement?) -> Void) {
        self.queue = queue
        self.speed = speed
        self.completion = completion
        let host = speed ? "speed.cloudflare.com" : "1.1.1.1"
        let path = speed ? "/__down?bytes=524288" : "/cdn-cgi/trace"
        request = Data(("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nAccept-Encoding: identity\r\n" +
            "Cache-Control: no-cache\r\nConnection: close\r\n\r\n").utf8)
        connection = provider.createTCPConnectionThroughTunnel(
            to: NWHostEndpoint(hostname: host, port: "443"), enableTLS: true, tlsParameters: nil, delegate: nil)
    }

    func start() {
        observation = connection.observe(\.state, options: [.initial, .new]) { [weak self] _, _ in
            guard let self = self else { return }
            self.queue.async { self.handleState() }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + (speed ? 15 : 5), execute: timeout)
    }

    func cancel() { finish(nil) }

    private func handleState() {
        guard completion != nil else { return }
        switch connection.state {
        case .connected:
            guard !didWrite else { return }
            didWrite = true
            connection.write(request) { [weak self] error in
                guard let self = self else { return }
                self.queue.async {
                    if error != nil { self.finish(nil) } else { self.read() }
                }
            }
        case .disconnected:
            // An orderly HTTP Connection: close may occur while response data is
            // still buffered. Let the read completion drain it, or hit timeout.
            if !didWrite { finish(nil) }
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func read() {
        guard completion != nil else { return }
        connection.readMinimumLength(1, maximumLength: 16384) { [weak self] data, error in
            guard let self = self else { return }
            self.queue.async {
                guard self.completion != nil else { return }
                guard error == nil, let data = data, !data.isEmpty else { self.finish(nil); return }
                self.buffer.append(data)
                guard self.buffer.count <= 557056 else { self.finish(nil); return }
                if self.headerEnd == nil {
                    if let range = self.buffer.range(of: Data([13, 10, 13, 10])) {
                        let end = range.upperBound
                        guard end <= 16384,
                              let headers = String(data: self.buffer.prefix(end), encoding: .utf8),
                              let status = headers.components(separatedBy: "\r\n").first,
                              status.hasPrefix("HTTP/1."),
                              status.components(separatedBy: " ").dropFirst().first == "200" else {
                            self.finish(nil); return
                        }
                        self.headerTime = ProcessInfo.processInfo.systemUptime
                        self.headerEnd = end
                        if !self.speed {
                            self.finish(Measurement(latencyMS: (self.headerTime! - self.started) * 1000, mbps: nil))
                            return
                        }
                        // Reject chunked/compressed bodies rather than report misleading byte rates.
                        let lines = headers.lowercased().components(separatedBy: "\r\n")
                        guard !lines.contains(where: { $0.hasPrefix("transfer-encoding:") }),
                              !lines.contains(where: { $0.hasPrefix("content-encoding:") && !$0.hasSuffix("identity") }),
                              let length = lines.first(where: { $0.hasPrefix("content-length:") }),
                              let count = Int(length.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                              count == 524288 else { self.finish(nil); return }
                        self.bodyLength = count
                    } else if self.buffer.count > 16384 {
                        self.finish(nil); return
                    }
                }
                if let end = self.headerEnd, self.speed, self.buffer.count - end >= self.bodyLength {
                    let elapsed = max(ProcessInfo.processInfo.systemUptime - self.started, 0.001)
                    self.finish(Measurement(latencyMS: (self.headerTime! - self.started) * 1000,
                        mbps: Double(self.bodyLength) * 8 / elapsed / 1_000_000))
                } else {
                    self.read()
                }
            }
        }
    }

    private func finish(_ measurement: Measurement?) {
        guard let completion = completion else { return }
        self.completion = nil
        timeout?.cancel()
        observation?.invalidate()
        observation = nil
        connection.cancel()
        buffer.removeAll()
        completion(measurement)
    }
}
