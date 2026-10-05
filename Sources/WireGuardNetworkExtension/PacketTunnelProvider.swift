// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import NetworkExtension
import os

class PacketTunnelProvider: NEPacketTunnelProvider {
    #if os(iOS)
    private var autoSwitchController: AutoSwitchController?
    #endif

    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { logLevel, message in
            wg_log(logLevel.osLogLevel, message: message)
        }
    }()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let activationAttemptId = options?["activationAttemptId"] as? String
        let errorNotifier = ErrorNotifier(activationAttemptId: activationAttemptId)

        Logger.configureGlobal(tagged: "NET", withFilePath: FileManager.logFileURL?.path)

        wg_log(.info, message: "Starting tunnel from the " + (activationAttemptId == nil ? "OS directly, rather than the app" : "app"))

        guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol,
              let tunnelConfiguration = tunnelProviderProtocol.asTunnelConfiguration() else {
            errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        #if os(iOS)
        var autoSettings: AutoSwitchConfiguration?
        if let reference = tunnelProviderProtocol.providerConfiguration?[AutoSwitchConfiguration.referenceKey] as? Data {
            guard let json = Keychain.openReference(called: reference),
                  let data = json.data(using: .utf8),
                  let settings = try? JSONDecoder().decode(AutoSwitchConfiguration.self, from: data),
                  settings.validated() else {
                completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
                return
            }
            autoSettings = settings
        }
        #endif

        func startConfiguration(_ config: TunnelConfiguration, index: Int) {
            self.adapter.start(tunnelConfiguration: config) { adapterError in
                #if os(iOS)
                if adapterError != nil, index == 0, let settings = autoSettings,
                   let alternative = try? TunnelConfiguration(fromWgQuickConfig: settings.candidates[1].wgQuick, called: settings.candidates[1].name) {
                    startConfiguration(alternative, index: 1)
                    return
                }
                #endif
                guard let adapterError = adapterError else {
                    let interfaceName = self.adapter.interfaceName ?? "unknown"

                    wg_log(.info, message: "Tunnel interface is \(interfaceName)")
                    #if os(iOS)
                    if let settings = autoSettings {
                        let controller = AutoSwitchController(provider: self, adapter: self.adapter, settings: settings, initialIndex: index)
                        self.autoSwitchController = controller
                        controller.start()
                    }
                    #endif

                    completionHandler(nil)
                    return
                }

                switch adapterError {
                case .cannotLocateTunnelFileDescriptor:
                    wg_log(.error, staticMessage: "Starting tunnel failed: could not determine file descriptor")
                    errorNotifier.notify(PacketTunnelProviderError.couldNotDetermineFileDescriptor)
                    completionHandler(PacketTunnelProviderError.couldNotDetermineFileDescriptor)

                case .dnsResolution(let dnsErrors):
                    let hostnamesWithDnsResolutionFailure = dnsErrors.map { $0.address }
                        .joined(separator: ", ")
                    wg_log(.error, message: "DNS resolution failed for the following hostnames: \(hostnamesWithDnsResolutionFailure)")
                    errorNotifier.notify(PacketTunnelProviderError.dnsResolutionFailure)
                    completionHandler(PacketTunnelProviderError.dnsResolutionFailure)

                case .setNetworkSettings(let error):
                    wg_log(.error, message: "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
                    errorNotifier.notify(PacketTunnelProviderError.couldNotSetNetworkSettings)
                    completionHandler(PacketTunnelProviderError.couldNotSetNetworkSettings)

                case .startWireGuardBackend(let errorCode):
                    wg_log(.error, message: "Starting tunnel failed with wgTurnOn returning \(errorCode)")
                    errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
                    completionHandler(PacketTunnelProviderError.couldNotStartBackend)

                case .invalidState:
                    // Must never happen
                    fatalError()
                }
            }
        }
        #if os(iOS)
        let initial = autoSettings.flatMap {
            try? TunnelConfiguration(fromWgQuickConfig: $0.candidates[0].wgQuick, called: $0.candidates[0].name)
        } ?? tunnelConfiguration
        startConfiguration(initial, index: 0)
        #else
        startConfiguration(tunnelConfiguration, index: 0)
        #endif
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        wg_log(.info, staticMessage: "Stopping tunnel")

        let stopAdapter = {
            self.adapter.stop { error in
                ErrorNotifier.removeLastErrorFile()

                if let error = error {
                    wg_log(.error, message: "Failed to stop WireGuard adapter: \(error.localizedDescription)")
                }
                completionHandler()

                #if os(macOS)
                // HACK: This is a filthy hack to work around Apple bug 32073323 (dup'd by us as 47526107).
                // Remove it when they finally fix this upstream and the fix has been rolled out to
                // sufficient quantities of users.
                exit(0)
                #endif
            }
        }
        #if os(iOS)
        if let controller = autoSwitchController {
            autoSwitchController = nil
            controller.stop(completion: stopAdapter)
        } else { stopAdapter() }
        #else
        stopAdapter()
        #endif
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler = completionHandler else { return }
        #if os(iOS)
        if messageData == Data([1]) {
            if let controller = autoSwitchController {
                controller.status { completionHandler($0) }
            } else {
                completionHandler(Data("This is a manual WireGuard profile.".utf8))
            }
            return
        }
        #endif

        if messageData.count == 1 && messageData[0] == 0 {
            adapter.getRuntimeConfiguration { settings in
                var data: Data?
                if let settings = settings {
                    data = settings.data(using: .utf8)!
                }
                completionHandler(data)
            }
        } else {
            completionHandler(nil)
        }
    }
}

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}
