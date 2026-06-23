import Foundation
import Combine
import os

/// Persists wellness sessions as JSON on the watch's local file system.
/// Sessions are stored until synced to the iOS app, then cleaned up.
class WatchSessionStore: ObservableObject {
    @Published var sessions: [WellnessSession] = []

    private static let maxStoredSessions = 30
    private static let logger = Logger(subsystem: "com.runalyzer.watch", category: "SessionStore")

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("sauna_sessions.json")
    }

    init() {
        load()
    }

    // MARK: - CRUD

    func save(_ session: WellnessSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        persist()
    }

    func markSynced(_ sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].synced = true
        persist()
        cleanup()
    }

    func unsyncedSessions() -> [WellnessSession] {
        sessions.filter { !$0.synced && !$0.isActive }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            sessions = try JSONDecoder().decode([WellnessSession].self, from: data)
        } catch {
            Self.logger.error("Failed to load sessions: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to persist sessions: \(error.localizedDescription)")
        }
    }

    /// Remove old synced sessions, keeping at most `maxStoredSessions`.
    private func cleanup() {
        let synced = sessions.filter(\.synced)
        if synced.count > Self.maxStoredSessions {
            let toRemove = Set(synced.dropFirst(Self.maxStoredSessions).map(\.id))
            sessions.removeAll { toRemove.contains($0.id) }
            persist()
        }
    }
}
