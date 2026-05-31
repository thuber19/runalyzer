import Foundation
import Combine

struct RecordedSample: Codable {
    let timestamp: UInt32
    let ax, ay, az: Int16
    let gx, gy, gz: Int16
}

struct RunSession: Identifiable, Codable {
    let id: UUID
    let date: Date
    var endDate: Date?
    var duration: TimeInterval
    var sampleCount: Int
    var avgCadence: Int
    var totalSteps: Int?
    var samplesFileName: String

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var dateString: String { Self.fmt.string(from: date) }

    var durationString: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}

class SessionStore: ObservableObject {
    @Published var sessions: [RunSession] = []

    private var storageDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Runalyzer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var sessionsURL: URL {
        storageDir.appendingPathComponent("sessions.json")
    }

    init() {
        loadSessions()
    }

    /// Save a session downloaded from device flash. Returns true on success.
    @discardableResult
    func saveDownloadedSession(samples: [RecordedSample], sampleRateHz: Int, durationSec: Double) -> Bool {
        guard !samples.isEmpty else { return false }

        let fileName = "samples_\(UUID().uuidString.prefix(8)).json"
        let analysis = RunMetrics.analyzeRecording(samples)

        let session = RunSession(
            id: UUID(),
            date: Date().addingTimeInterval(-durationSec),
            endDate: Date(),
            duration: durationSec,
            sampleCount: samples.count,
            avgCadence: Int(analysis.avgCadence),
            totalSteps: analysis.totalSteps,
            samplesFileName: fileName
        )

        do {
            let data = try JSONEncoder().encode(samples)
            try data.write(to: storageDir.appendingPathComponent(fileName))
            print("Saved session: \(samples.count) samples, \(analysis.totalSteps) steps")
        } catch {
            print("FAILED to save session: \(error)")
            return false
        }

        sessions.insert(session, at: 0)
        saveSessions()
        return true
    }

    func loadSamples(for session: RunSession) -> [RecordedSample] {
        let url = storageDir.appendingPathComponent(session.samplesFileName)
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([RecordedSample].self, from: data) else { return [] }
        return samples
    }

    func deleteSession(_ session: RunSession) {
        try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(session.samplesFileName))
        sessions.removeAll { $0.id == session.id }
        saveSessions()
    }

    func clearAllSessions() {
        for s in sessions {
            try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(s.samplesFileName))
        }
        sessions.removeAll()
        saveSessions()
    }

    func exportCSV(session: RunSession) -> URL? {
        let samples = loadSamples(for: session)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runalyzer_\(session.id.uuidString.prefix(8)).csv")
        var csv = "timestamp_ms,ax,ay,az,gx,gy,gz,accel_g,gyro_dps\n"
        for s in samples {
            let ag = sqrtf(pow(Float(s.ax) * IMUPacket.accelScale, 2) +
                          pow(Float(s.ay) * IMUPacket.accelScale, 2) +
                          pow(Float(s.az) * IMUPacket.accelScale, 2))
            let gg = sqrtf(pow(Float(s.gx) * IMUPacket.gyroScale, 2) +
                          pow(Float(s.gy) * IMUPacket.gyroScale, 2) +
                          pow(Float(s.gz) * IMUPacket.gyroScale, 2))
            csv += "\(s.timestamp),\(s.ax),\(s.ay),\(s.az),\(s.gx),\(s.gy),\(s.gz),\(String(format: "%.4f", ag)),\(String(format: "%.1f", gg))\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: sessionsURL)
        }
    }

    private func loadSessions() {
        guard let data = try? Data(contentsOf: sessionsURL),
              let loaded = try? JSONDecoder().decode([RunSession].self, from: data) else { return }
        sessions = loaded
    }
}
