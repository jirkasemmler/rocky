import Foundation
import RockyCore
import WatchConnectivity

/// iPhone <-> Watch sync. Live control (start/pause/skip/...) uses `sendMessage` when the
/// counterpart is reachable (target: mirrored within 2 s). Durable data (finished sessions,
/// settings) uses `transferUserInfo`, which WatchConnectivity queues and delivers later, so the
/// watch works without the phone nearby and syncs when back in range (PRD 8a).
@MainActor
protocol WatchSyncing: AnyObject {
    var onMessage: ((SyncMessage) -> Void)? { get set }
    var isReachable: Bool { get }
    func activate()
    func send(_ message: SyncMessage)
}

@MainActor
final class WatchSyncService: NSObject, WatchSyncing {
    var onMessage: ((SyncMessage) -> Void)?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    var isReachable: Bool { session?.isReachable ?? false }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Messages sent before the WCSession finished activating (e.g. settings at app launch).
    private var pending: [SyncMessage] = []
    /// Latest application context sent: `settings` and `catalog` slots.
    private var context: [String: Any] = [:]

    func send(_ message: SyncMessage) {
        guard let session else { return }
        guard session.activationState == .activated else {
            // Live commands are only useful now; durable data waits for the activation.
            switch message {
            case .sessionSaved, .sessionDiscarded, .settingsChanged, .catalogChanged: pending.append(message)
            case .workoutStarted, .command: break
            }
            return
        }
        guard let info = try? message.userInfo() else { return }
        switch message {
        case .settingsChanged, .catalogChanged:
            // Latest wins: the application context only keeps the newest dict, so a quick A→B
            // change can never end with the older A on the other device. Settings and catalog
            // share the one context under separate keys.
            let slot = if case .catalogChanged = message { "catalog" } else { "settings" }
            if let payload = info[SyncMessage.payloadKey] { context[slot] = payload }
            try? session.updateApplicationContext(context)
        case .sessionSaved, .sessionDiscarded:
            // Durable, queued delivery (works when the other side is away)...
            session.transferUserInfo(info)
            // ...plus immediate delivery when reachable, so the other device closes its summary
            // right away. Duplicates are harmless: sessions are merged by id.
            if session.isReachable {
                session.sendMessage(info, replyHandler: nil, errorHandler: nil)
            }
        case .workoutStarted, .command:
            // Live commands are only useful right now; drop them if the other side is not reachable.
            if session.isReachable {
                session.sendMessage(info, replyHandler: nil, errorHandler: nil)
            }
        }
    }

    private func flushPending() {
        let queued = pending
        pending = []
        queued.forEach(send)
    }

    nonisolated private func deliver(_ info: [String: Any]) {
        guard let message = try? SyncMessage.decode(userInfo: info) else { return }
        Task { @MainActor in
            self.onMessage?(message)
        }
    }
}

extension WatchSyncService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.flushPending() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        for value in applicationContext.values {
            deliver([SyncMessage.payloadKey: value])
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after switching to a different watch.
        session.activate()
    }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(userInfo)
    }
}
