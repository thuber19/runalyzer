import Foundation
import Combine
import WatchConnectivity
import os

/// iOS-side WatchConnectivity delegate. Receives sauna sessions
/// from the watchOS companion app via `transferUserInfo`.
class WatchConnectivityManager: NSObject, ObservableObject {
    private let logger = AppLogger.watch
    private var saunaSyncProvider: SaunaSyncProvider?

    func configure(saunaSyncProvider: SaunaSyncProvider) {
        self.saunaSyncProvider = saunaSyncProvider
    }

    func activate() {
        guard WCSession.isSupported() else {
            logger.info("WatchConnectivity not supported on this device")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            logger.error("WCSession activation failed: \(error.localizedDescription)")
        } else {
            logger.info("WCSession activated on iOS (state: \(activationState.rawValue))")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        logger.info("WCSession became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        logger.info("WCSession deactivated, reactivating")
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let type = userInfo["type"] as? String else {
            logger.warning("Received userInfo without type field")
            return
        }

        switch type {
        case "sauna_session":
            logger.info("Received sauna session from watch")
            saunaSyncProvider?.handleWatchPayload(userInfo)
        default:
            logger.warning("Unknown watch payload type: \(type)")
        }
    }
}
