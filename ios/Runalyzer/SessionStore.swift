import Foundation
import Combine

// RecordedSample, IMUDeviceEvent (DeviceEvent) are defined in IMUDataTypes.swift

struct RunSession: Identifiable, Codable {
    let id: UUID
    var date: Date
    var endDate: Date?
    var duration: TimeInterval
    var sampleCount: Int
    var avgCadence: Int
    var totalSteps: Int?
    var linkedWorkoutID: String?
    var events: [IMUDeviceEvent]?  // event log from device
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

    /// Save a session downloaded from device flash. Completion called with success flag.
    /// M2: Heavy work (analysis, encoding) done on background queue.
    func saveDownloadedSession(samples: [RecordedSample], sampleRateHz: Int, durationSec: Double, startUnixMs: UInt64 = 0, events: [IMUDeviceEvent]? = nil, completion: @escaping (Bool) -> Void) {
        guard !samples.isEmpty else { completion(false); return }

        // H8: Check for duplicate
        if startUnixMs > 0 {
            let isDuplicate = sessions.contains { s in
                let existingStart = UInt64(s.date.timeIntervalSince1970 * 1000)
                return abs(Int64(existingStart) - Int64(startUnixMs)) < 5000 && s.sampleCount == samples.count
            }
            if isDuplicate {
                print("Duplicate session detected — skipping save")
                completion(true)
                return
            }
        }

        let dir = storageDir
        let fileName = "samples_\(UUID().uuidString.prefix(8)).json"

        DispatchQueue.global(qos: .userInitiated).async {
            // Heavy work on background thread
            let analysis = RunMetrics.analyzeRecording(samples)

            let startDate: Date
            let endDate: Date
            if startUnixMs > 0 {
                startDate = Date(timeIntervalSince1970: Double(startUnixMs) / 1000.0)
                endDate = startDate.addingTimeInterval(durationSec)
            } else {
                startDate = Date().addingTimeInterval(-durationSec)
                endDate = Date()
            }

            let session = RunSession(
                id: UUID(),
                date: startDate,
                endDate: endDate,
                duration: durationSec,
                sampleCount: samples.count,
                avgCadence: Int(analysis.avgCadence),
                totalSteps: analysis.totalSteps,
                events: events,
                samplesFileName: fileName
            )

            // Save samples file
            do {
                let data = try JSONEncoder().encode(samples)
                try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
            } catch {
                print("FAILED to save samples: \(error)")
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Update UI on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(false); return }
                self.sessions.insert(session, at: 0)
                if !self.saveSessions() {
                    self.sessions.removeFirst()
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
                    print("FAILED to save session index — rolled back")
                    completion(false)
                    return
                }
                print("Saved session: \(samples.count) samples, \(analysis.totalSteps) steps")
                completion(true)
            }
        }
    }

    func linkWorkout(_ workoutID: String, to sessionID: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].linkedWorkoutID = workoutID
        saveSessions()
    }

    func unlinkWorkout(from sessionID: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].linkedWorkoutID = nil
        saveSessions()
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

    @discardableResult
    private func saveSessions() -> Bool {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: sessionsURL, options: .atomic)
            return true
        } catch {
            print("ERROR: failed to save sessions index: \(error)")
            return false
        }
    }

    private func loadSessions() {
        guard let data = try? Data(contentsOf: sessionsURL),
              let loaded = try? JSONDecoder().decode([RunSession].self, from: data) else { return }
        sessions = loaded
    }
}
