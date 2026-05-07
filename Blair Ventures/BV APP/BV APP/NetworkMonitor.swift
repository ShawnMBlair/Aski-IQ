// NetworkMonitor.swift
// BV APP – Real-time network connectivity monitoring
// Uses NWPathMonitor to publish connection state across the app.

import Foundation
import Network
import Combine

// MARK: - Network Monitor

final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    /// `true` when any usable network path is available (Wi-Fi or cellular).
    @Published private(set) var isConnected: Bool = true

    /// The interface type of the current path (wifi, cellular, wiredEthernet, etc.)
    @Published private(set) var connectionType: NWInterface.InterfaceType? = nil

    private let monitor  = NWPathMonitor()
    private let queue    = DispatchQueue(label: "ca.askiiq.networkmonitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                let wasConnected = self.isConnected
                self.isConnected    = connected
                self.connectionType = path.availableInterfaces.first?.type

                // Push any queued submissions when connectivity is restored
                if connected && !wasConnected {
                    Task { await SyncEngine.shared.pushPending() }
                }

                // 2026-04 audit fix (Phase 9): mirror connectivity
                // into AppStore.isOfflineMode so any view can read
                // a single source of truth without importing
                // NetworkMonitor directly. Pre-fix this flag was
                // declared but never set — banners couldn't tell
                // "actually offline" from "transient sync failure".
                AppStore.shared.isOfflineMode = !connected
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
