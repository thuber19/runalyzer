import Foundation

// MARK: - IMU Packet (live streaming data)

struct IMUPacket {
    let timestamp: UInt32
    let ax, ay, az: Int16
    let gx, gy, gz: Int16

    static let accelScale: Float = 2.0 / 32768.0
    static let gyroScale: Float = 245.0 / 32768.0

    var accelG: (x: Float, y: Float, z: Float) {
        (Float(ax) * Self.accelScale, Float(ay) * Self.accelScale, Float(az) * Self.accelScale)
    }
    var gyroDPS: (x: Float, y: Float, z: Float) {
        (Float(gx) * Self.gyroScale, Float(gy) * Self.gyroScale, Float(gz) * Self.gyroScale)
    }
    var accelMagnitude: Float {
        let a = accelG
        return sqrtf(a.x*a.x + a.y*a.y + a.z*a.z)
    }
    var gyroMagnitude: Float {
        let g = gyroDPS
        return sqrtf(g.x*g.x + g.y*g.y + g.z*g.z)
    }
}

// MARK: - Recorded Sample (stored on device flash, downloaded)

struct RecordedSample: Codable {
    let timestamp: UInt32
    let ax, ay, az: Int16
    let gx, gy, gz: Int16
}

// MARK: - Device Event Log

struct IMUDeviceEvent: Codable, Identifiable {
    let reason: UInt8
    let offsetMs: UInt32

    var id: String { "\(reason)-\(offsetMs)" }

    private enum CodingKeys: String, CodingKey {
        case reason, offsetMs
    }

    var reasonString: String {
        switch reason {
        case 1: return "Started (app)"
        case 2: return "Started (button)"
        case 3: return "Stopped (app)"
        case 4: return "Stopped (button)"
        case 5: return "Stopped (low battery)"
        case 6: return "Stopped (memory full)"
        case 7: return "Recovered (power loss)"
        case 8: return "Download started"
        case 9: return "Data erased"
        default: return "Unknown (\(reason))"
        }
    }

    var icon: String {
        switch reason {
        case 1, 2: return "record.circle"
        case 3, 4: return "stop.circle"
        case 5: return "battery.25"
        case 6: return "externaldrive.badge.exclamationmark"
        case 7: return "bolt.trianglebadge.exclamationmark"
        case 8: return "arrow.down.circle"
        case 9: return "trash"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - IMU Device Status (from firmware status characteristic)

enum IMUDeviceState: UInt8 {
    case idle = 0, recording = 1, hasData = 2, downloading = 3
}

struct IMUDeviceStatus {
    static let expectedProtocolVersion: UInt8 = 1
    var state: IMUDeviceState = .idle
    var sampleCount: UInt32 = 0
    var sampleRateHz: UInt8 = 25
    var batteryPercent: UInt8 = 0
    var isCharging: Bool = false
    var isTimeSynced: Bool = false
    var maxSamples: UInt32 = 0
    var recordingDurationSec: UInt32 = 0
    var recordingStartUnixMs: UInt64 = 0
    var protocolVersion: UInt8 = 0
    var headerVersion: UInt8 = 0

    var recordingStartDate: Date? {
        recordingStartUnixMs > 0 ? Date(timeIntervalSince1970: Double(recordingStartUnixMs) / 1000.0) : nil
    }

    var durationString: String {
        let m = recordingDurationSec / 60
        let s = recordingDurationSec % 60
        return String(format: "%d:%02d", m, s)
    }

    var maxDurationAtRate: String {
        guard sampleRateHz > 0, maxSamples > 0 else { return "--" }
        let sec = maxSamples / UInt32(sampleRateHz)
        let h = sec / 3600; let m = (sec % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - IMU App State (user intent, independent of device state)

enum IMUAppState: Equatable {
    case disconnected
    case idle
    case recording
    case stopping
    case downloading
    case error(String)

    static func == (lhs: IMUAppState, rhs: IMUAppState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected), (.idle, .idle),
             (.recording, .recording), (.stopping, .stopping),
             (.downloading, .downloading): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - IMU Session (the full recording, stored on phone)

struct IMUSession: MeasurementData, Identifiable, Codable {
    let id: UUID
    var date: Date
    var endDate: Date?
    var duration: TimeInterval
    var sampleCount: Int
    var avgCadence: Int
    var totalSteps: Int?
    var linkedWorkoutID: String?
    var events: [IMUDeviceEvent]?
    var samplesFileName: String

    var deviceType: String { "imu_sensor" }
    var deviceName: String { "Runalyzer IMU" }

    var summary: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d · %d steps · %d spm", m, s, totalSteps ?? 0, avgCadence)
    }

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
