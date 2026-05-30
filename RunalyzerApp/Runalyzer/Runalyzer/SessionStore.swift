import Foundation
import Combine

struct RecordedSample: Codable {
    let timestamp: UInt32
    let ax: Int16
    let ay: Int16
    let az: Int16
    let gx: Int16
    let gy: Int16
    let gz: Int16
}

struct RunSession: Identifiable, Codable {
    let id: UUID
    let date: Date
    var endDate: Date?
    var duration: TimeInterval
    var sampleCount: Int
    var avgCadence: Int
    var totalSteps: Int?
    // Samples stored in separate file, not in the session list
    var samplesFileName: String

    var dateString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    var durationString: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}

class SessionStore: ObservableObject {
    @Published var sessions: [RunSession] = []
    @Published var isRecording: Bool = false

    private var currentSamples: [RecordedSample] = []
    private var recordingStart: Date?
    private var cadenceSum: Int = 0
    private var cadenceCount: Int = 0

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

    func startRecording(healthKit: HealthKitManager? = nil) {
        currentSamples.removeAll()
        recordingStart = Date()
        cadenceSum = 0
        cadenceCount = 0
        isRecording = true
        healthKit?.startWorkout()
    }

    func stopRecording(metrics: RunMetrics, healthKit: HealthKitManager? = nil) {
        isRecording = false
        guard let start = recordingStart, !currentSamples.isEmpty else { return }

        let endDate = Date()
        let fileName = "samples_\(UUID().uuidString.prefix(8)).json"

        // Run offline step analysis
        let analysis = RunMetrics.analyzeRecording(currentSamples)
        print("Recording analysis: \(analysis.totalSteps) steps, \(String(format: "%.0f", analysis.avgCadence)) avg SPM")

        let session = RunSession(
            id: UUID(),
            date: start,
            endDate: endDate,
            duration: endDate.timeIntervalSince(start),
            sampleCount: currentSamples.count,
            avgCadence: Int(analysis.avgCadence),
            totalSteps: analysis.totalSteps,
            samplesFileName: fileName
        )

        healthKit?.stopWorkout { _ in }

        // Save samples to separate file
        print("Saving \(currentSamples.count) samples to \(fileName)")
        do {
            let data = try JSONEncoder().encode(currentSamples)
            let fileURL = storageDir.appendingPathComponent(fileName)
            try data.write(to: fileURL)
            print("Saved \(data.count) bytes to \(fileURL.path)")
        } catch {
            print("Failed to save samples: \(error)")
        }

        sessions.insert(session, at: 0)
        saveSessions()
        currentSamples.removeAll()
    }

    func addSample(_ packet: IMUPacket) {
        currentSamples.append(RecordedSample(
            timestamp: packet.timestamp,
            ax: packet.ax, ay: packet.ay, az: packet.az,
            gx: packet.gx, gy: packet.gy, gz: packet.gz
        ))
    }

    func loadSamples(for session: RunSession) -> [RecordedSample] {
        let url = storageDir.appendingPathComponent(session.samplesFileName)
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([RecordedSample].self, from: data) else { return [] }
        return samples
    }

    func deleteSession(_ session: RunSession) {
        let samplesURL = storageDir.appendingPathComponent(session.samplesFileName)
        try? FileManager.default.removeItem(at: samplesURL)
        sessions.removeAll { $0.id == session.id }
        saveSessions()
    }

    func exportCSV(session: RunSession) -> URL? {
        let samples = loadSamples(for: session)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runalyzer_\(session.id.uuidString.prefix(8)).csv")
        var csv = "timestamp_ms,ax_raw,ay_raw,az_raw,gx_raw,gy_raw,gz_raw,accel_g,gyro_dps\n"
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
            try csv.write(to: tmpURL, atomically: true, encoding: .utf8)
            return tmpURL
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
