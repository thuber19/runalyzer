import os

/// Structured loggers for each subsystem. Use these instead of print() in production code.
/// Logs are visible in Console.app with filtering, and sensitive values are auto-redacted.
enum AppLogger {
    static let ble      = Logger(subsystem: "com.runalyzer.app", category: "BLE")
    static let storage  = Logger(subsystem: "com.runalyzer.app", category: "Storage")
    static let health   = Logger(subsystem: "com.runalyzer.app", category: "Health")
    static let imu      = Logger(subsystem: "com.runalyzer.app", category: "IMU")
    static let scale    = Logger(subsystem: "com.runalyzer.app", category: "Scale")
    static let checkin  = Logger(subsystem: "com.runalyzer.app", category: "CheckIn")
    static let watch    = Logger(subsystem: "com.runalyzer.app", category: "Watch")
}
