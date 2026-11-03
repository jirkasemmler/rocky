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

    func send(_ message: SyncMessage) {
        guard let session, session.activationState == .activated, let info = try? message.userInfo() else { return }
        switch message {
        case .sessionSaved, .settingsChanged:
            session.transferUserInfo(info)
        case .workoutStarted, .command:
            // Live commands are only useful right now; drop them if the other side is not reachable.
            if session.isReachable {
                session.sendMessage(info, replyHandler: nil, errorHandler: nil)
            }
        }
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
                             error: Error?) {}

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
