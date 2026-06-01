import Foundation

/// Protocol for any measurement type from any device.
/// Provides enough info for unified listing and storage.
protocol MeasurementData: Codable, Identifiable {
    nonisolated var id: UUID { get }
    var date: Date { get }
    var deviceType: String { get }      // matches DeviceDescriptor.id
    var deviceName: String { get }      // user-visible device name at time of capture
    var summary: String { get }         // one-line summary for list views
}

/// Type-erased entry in the measurement index.
/// The actual data lives in a separate file, decoded by the appropriate type.
struct MeasurementEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let deviceType: String
    let deviceName: String
    let summary: String
    let dataFileName: String

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var dateString: String { Self.fmt.string(from: date) }
}
