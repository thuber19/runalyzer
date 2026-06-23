import Foundation

/// A single round within a wellness session (e.g. one 10-minute Finnish sauna stint).
struct WellnessRound: Codable, Identifiable {
    let id: UUID
    let type: WellnessRoundType
    let startDate: Date
    var endDate: Date?

    var isActive: Bool { endDate == nil }

    var durationSec: TimeInterval {
        let end = endDate ?? Date()
        return end.timeIntervalSince(startDate)
    }

    init(type: WellnessRoundType) {
        self.id = UUID()
        self.type = type
        self.startDate = Date()
        self.endDate = nil
    }
}
