import Foundation
import Combine
import WatchConnectivity
import os

/// Watch-side WatchConnectivity manager. Sends completed wellness sessions
/// to the iOS app via `transferUserInfo` (reliable, queued delivery).
class WatchSyncManager: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.runalyzer.watch", category: "Sync")

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Queue a completed session for transfer to the iOS app.
    func syncSession(_ session: WellnessSession) {
        guard WCSession.default.activationState == .activated else {
            logger.warning("WCSession not activated, session will sync later")
            return
        }

        let payload = encodeSession(session)
        WCSession.default.transferUserInfo(payload)
        logger.info("Queued wellness session \(session.id) for transfer")
    }

    /// Retry syncing all unsynced sessions (called on activation or app foreground).
    func syncPending(from store: WatchSessionStore) {
        for session in store.unsyncedSessions() {
            syncSession(session)
        }
    }

    // MARK: - Encoding

    private func encodeSession(_ session: WellnessSession) -> [String: Any] {
        let rounds: [[String: Any]] = session.rounds.compactMap { round in
            guard let endDate = round.endDate else { return nil }
            return [
                "id": round.id.uuidString,
                "type": round.type.rawValue,
                "startDate": round.startDate.timeIntervalSince1970,
                "endDate": endDate.timeIntervalSince1970
            ]
        }

        return [
            "type": "wellness_session",
            "version": 1,
            "session": [
                "id": session.id.uuidString,
                "date": session.date.timeIntervalSince1970,
                "rounds": rounds
            ]
        ]
    }
}

// MARK: - WCSessionDelegate

extension WatchSyncManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            logger.error("WCSession activation failed: \(error.localizedDescription)")
        } else {
            logger.info("WCSession activated on watch")
        }
    }
}
